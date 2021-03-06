local pl_tablex = require "pl.tablex"
local singletons = require "kong.singletons"

-- due to startup/require order, cannot use the ones from 'singletons' here
local dns_client = require "resty.dns.client"

local table_concat = table.concat
local crc32 = ngx.crc32_short
local toip = dns_client.toip
local log = ngx.log

local ERR   = ngx.ERR
local WARN  = ngx.WARN
local DEBUG = ngx.DEBUG
local EMPTY_T = pl_tablex.readonly {}

-- for unit-testing purposes only
local _load_upstreams_dict_into_memory
local _load_upstream_into_memory
local _load_targets_into_memory


--==============================================================================
-- Ring-balancer based resolution
--==============================================================================


-- table holding our balancer objects, indexed by upstream name
local balancers = {}


-- objects whose lifetimes are bound to that of a balancer
local healthcheckers = setmetatable({}, { __mode = "k" })
local healthchecker_callbacks = setmetatable({}, { __mode = "k" })
local target_histories = setmetatable({}, { __mode = "k" })


-- Caching logic
--
-- We retain 3 entities in singletons.cache:
--
-- 1) `"balancer:upstreams"` - a list of upstreams
--    to be invalidated on any upstream change
-- 2) `"balancer:upstreams:" .. id` - individual upstreams
--    to be invalidated on individual basis
-- 3) `"balancer:targets:" .. id`
--    target history for an upstream, invalidated:
--    a) along with the upstream it belongs to
--    b) upon any target change for the upstream (can only add entries)
--
-- Distinction between 1 and 2 makes it possible to invalidate individual
-- upstreams, instead of all at once forcing to rebuild all balancers


local function stop_healthchecker(balancer)
  local healthchecker = healthcheckers[balancer]
  if healthchecker then
    local ok, err = healthchecker:clear()
    if not ok then
      log(ERR, "[healthchecks] error clearing healthcheck data: ", err)
    end
    healthchecker:stop()
    local hc_callback = healthchecker_callbacks[balancer]
    singletons.worker_events.unregister(hc_callback, healthchecker.EVENT_SOURCE)
  end
  healthcheckers[balancer] = nil
end


local get_upstream_by_id
do
  ------------------------------------------------------------------------------
  -- Loads a single upstream entity.
  -- @param upstream_id string
  -- @return the upstream table, or nil+error
  local function load_upstream_into_memory(upstream_id)
    log(DEBUG, "fetching upstream: ", tostring(upstream_id))

    local upstream, err = singletons.dao.upstreams:find_all {id = upstream_id}
    if not upstream then
      return nil, err
    end

    return upstream[1]  -- searched by id, so only 1 row in the returned set
  end
  _load_upstream_into_memory = load_upstream_into_memory

  get_upstream_by_id = function(upstream_id)
    local upstream_cache_key = "balancer:upstreams:" .. upstream_id
    return singletons.cache:get(upstream_cache_key, nil,
                                load_upstream_into_memory, upstream_id)
  end
end


local fetch_target_history
do
  ------------------------------------------------------------------------------
  -- Loads the target history from the DAO.
  -- @param upstream_id Upstream uuid for which to load the target history
  -- @return The target history array, with target entity tables.
  local function load_targets_into_memory(upstream_id)
    log(DEBUG, "fetching targets for upstream: ",tostring(upstream_id))

    local target_history, err = singletons.dao.targets:find_all {upstream_id = upstream_id}
    if not target_history then
      return nil, err
    end

    -- perform some raw data updates
    for _, target in ipairs(target_history) do
      -- split `target` field into `name` and `port`
      local port
      target.name, port = string.match(target.target, "^(.-):(%d+)$")
      target.port = tonumber(port)

      -- need exact order, so create sort-key by created-time and uuid
      target.order = target.created_at .. ":" .. target.id
    end

    table.sort(target_history, function(a,b)
      return a.order < b.order
    end)

    return target_history
  end
  _load_targets_into_memory = load_targets_into_memory


  ------------------------------------------------------------------------------
  -- Fetch target history, from cache or the DAO.
  -- @param upstream The upstream entity object
  -- @return The target history array, with target entity tables.
  fetch_target_history = function(upstream)
    local targets_cache_key = "balancer:targets:" .. upstream.id
    return singletons.cache:get(targets_cache_key, nil,
                                load_targets_into_memory, upstream.id)
  end
end


--------------------------------------------------------------------------------
-- Applies the history of lb transactions from index `start` forward.
-- @param rb ring balancer object
-- @param history list of targets/transactions to be applied
-- @param start the index where to start in the `history` parameter
-- @return true
local function apply_history(rb, history, start)

  for i = start, #history do
    local target = history[i]

    if target.weight > 0 then
      assert(rb:addHost(target.name, target.port, target.weight))
    else
      assert(rb:removeHost(target.name, target.port))
    end

    target_histories[rb][i] = {
      name = target.name,
      port = target.port,
      weight = target.weight,
      order = target.order,
    }
  end

  return true
end


local function populate_healthchecker(hc, balancer)
  for weight, addr, host in balancer:addressIter() do
    if weight > 0 then
      local ipaddr = addr.ip
      local port = addr.port
      local hostname = host.hostname
      local ok, err = hc:add_target(ipaddr, port, hostname)
      if ok then
        -- Get existing health status which may have been initialized
        -- with data from another worker, and apply to the new balancer.
        local tgt_status = hc:get_target_status(ipaddr, port)
        balancer:setPeerStatus(tgt_status, ipaddr, port, hostname)

      else
        log(ERR, "[healthchecks] failed adding target: ", err)
      end
    end
  end
end


local create_balancer
do
  local ring_balancer = require "resty.dns.balancer"

  local create_healthchecker
  do
    local healthcheck -- delay initialization

    ------------------------------------------------------------------------------
    -- Callback function that informs the healthchecker when targets are added
    -- or removed to a balancer.
    -- @param balancer the ring balancer object that triggers this callback.
    -- @param action "added" or "removed"
    -- @param ip string
    -- @param port number
    -- @param hostname string
    local function ring_balancer_callback(balancer, action, ip, port, hostname)
      local healthchecker = healthcheckers[balancer]
      if action == "added" then
        local ok, err = healthchecker:add_target(ip, port, hostname)
        if not ok then
          log(ERR, "[healthchecks] failed adding a target: ", err)
        end

      elseif action == "removed" then
        local ok, err = healthchecker:remove_target(ip, port)
        if not ok then
          log(ERR, "[healthchecks] failed adding a target: ", err)
        end

      else
        log(WARN, "[healthchecks] unknown status from balancer: ",
                  tostring(action))
      end
    end

    -- @param healthchecker The healthchecker object
    -- @param balancer The balancer object
    local function attach_healthchecker_to_balancer(healthchecker, balancer)
      local hc_callback = function(tgt, event)
        local ok, err = true, nil
        if event == healthchecker.events.healthy then
          ok, err = balancer:setPeerStatus(true, tgt.ip, tgt.port, tgt.hostname)
        elseif event == healthchecker.events.unhealthy then
          ok, err = balancer:setPeerStatus(false, tgt.ip, tgt.port, tgt.hostname)
        end
        if not ok then
          log(ERR, "[healthchecks] failed setting peer status: ", err)
        end
      end

      -- Register event using a weak-reference in worker-events,
      -- and attach lifetime of callback to that of the balancer.
      singletons.worker_events.register_weak(hc_callback, healthchecker.EVENT_SOURCE)
      healthchecker_callbacks[balancer] = hc_callback

      -- The lifetime of the healthchecker is based on that of the balancer.
      healthcheckers[balancer] = healthchecker

      balancer.report_http_status = function(ip, port, status)
        local ok, err = healthchecker:report_http_status(ip, port, status,
                                                         "passive")
        if not ok then
          log(ERR, "[healthchecks] failed reporting status: ", err)
        end
      end

      balancer.report_tcp_failure = function(ip, port)
        local ok, err = healthchecker:report_tcp_failure(ip, port, nil,
                                                         "passive")
        if not ok then
          log(ERR, "[healthchecks] failed reporting status: ", err)
        end
      end
    end

    ----------------------------------------------------------------------------
    -- Create a healthchecker object.
    -- @param upstream An upstream entity table.
    create_healthchecker = function(balancer, upstream)
      if not healthcheck then
        healthcheck = require("resty.healthcheck") -- delayed initialization
      end
      local healthchecker, err = healthcheck.new({
        name = upstream.name,
        shm_name = "kong_healthchecks",
        checks = upstream.healthchecks,
      })
      if not healthchecker then
        log(ERR, "[healthchecks] error creating health checker: ", err)
        return nil, err
      end

      populate_healthchecker(healthchecker, balancer)

      attach_healthchecker_to_balancer(healthchecker, balancer)

      -- only enable the callback after the target history has been replayed.
      balancer:setCallback(ring_balancer_callback)
    end
  end

  ------------------------------------------------------------------------------
  -- @return The new balancer object, or nil+error
  create_balancer = function(upstream, history, start)
    local balancer, err = ring_balancer.new({
        wheelSize = upstream.slots,
        order = upstream.orderlist,
        dns = dns_client,
      })
    if not balancer then
      return nil, err
    end

    target_histories[balancer] = {}

    if not history then
      history, err = fetch_target_history(upstream)
      if not history then
        return nil, err
      end
      start = 1
    end

    apply_history(balancer, history, start)

    create_healthchecker(balancer, upstream)

    -- only make the new balancer available for other requests after it
    -- is fully set up.
    balancers[upstream.id] = balancer

    return balancer
  end
end


--------------------------------------------------------------------------------
-- Compare the target history of the upstream with that of the
-- current balancer object, updating or recreating the balancer if necessary.
-- @param upstream The upstream entity object
-- @param balancer The ring balancer object
-- @return true if all went well, or nil + error in case of failures.
local function check_target_history(upstream, balancer)
  -- Fetch the upstream's targets, from cache or the db
  local new_history, err = fetch_target_history(upstream)
  if err then
    return nil, err
  end

  local old_history = target_histories[balancer]

  -- check history state
  local old_size = #old_history
  local new_size = #new_history

  if old_size == new_size and
    (old_history[old_size] or EMPTY_T).order ==
    (new_history[new_size] or EMPTY_T).order then
    -- No history update is necessary in the balancer object.
    return true
  end

  -- last entries in history don't match, so we must do some updates.

  -- compare balancer history with db-loaded history
  local last_equal_index = 0  -- last index where history is the same
  for i, entry in ipairs(old_history) do
    if entry.order ~= (new_history[i] or EMPTY_T).order then
      last_equal_index = i - 1
      break
    end
  end

  if last_equal_index == old_size then
    -- history is the same, so we only need to add new entries
    apply_history(balancer, new_history, last_equal_index + 1)
    return true
  end

  -- history not the same.
  -- TODO: ideally we would undo the last ones until we're equal again
  -- and can replay changes, but not supported by ring-balancer yet.
  -- for now; create a new balancer from scratch

  stop_healthchecker(balancer)

  local new_balancer, err = create_balancer(upstream, new_history, 1)
  if not new_balancer then
    return nil, err
  end

  return true
end


local get_all_upstreams
do
  ------------------------------------------------------------------------------
  -- Implements a simple dictionary with all upstream-ids indexed
  -- by their name.
  -- @return The upstreams dictionary, a map with upstream names as string keys
  -- and upstream entity tables as values, or nil+error
  local function load_upstreams_dict_into_memory()
    log(DEBUG, "fetching all upstreams")
    local upstreams, err = singletons.dao.upstreams:find_all()
    if err then
      return nil, err
    end

    -- build a dictionary, indexed by the upstream name
    local upstreams_dict = {}
    for _, up in ipairs(upstreams) do
      upstreams_dict[up.name] = up.id
    end

    return upstreams_dict
  end
  _load_upstreams_dict_into_memory = load_upstreams_dict_into_memory


  ------------------------------------------------------------------------------
  -- Finds and returns an upstream entity. This function covers
  -- caching, invalidation, db access, et al.
  -- @param upstream_name string.
  -- @return upstream table, or `false` if not found, or nil+error
  get_all_upstreams = function()
    local upstreams_dict, err = singletons.cache:get("balancer:upstreams", nil,
                                                load_upstreams_dict_into_memory)
    if err then
      return nil, err
    end

    return upstreams_dict
  end
end


------------------------------------------------------------------------------
-- Finds and returns an upstream entity. This function covers
-- caching, invalidation, db access, et al.
-- @param upstream_name string.
-- @return upstream table, or `false` if not found, or nil+error
local function get_upstream_by_name(upstream_name)
  local upstreams_dict, err = get_all_upstreams()
  if err then
    return nil, err
  end

  local upstream_id = upstreams_dict[upstream_name]
  if not upstream_id then
    return false -- no upstream by this name
  end

  return get_upstream_by_id(upstream_id)
end


-- looks up a balancer for the target.
-- @param target the table with the target details
-- @param no_create (optional) if true, do not attempt to create
-- (for thorough testing purposes)
-- @return balancer if found, `false` if not found, or nil+error on error
local function get_balancer(target, no_create)
  -- NOTE: only called upon first lookup, so `cache_only` limitations
  -- do not apply here
  local hostname = target.host

  -- first go and find the upstream object, from cache or the db
  local upstream, err = get_upstream_by_name(hostname)
  if upstream == false then
    return false -- no upstream by this name
  end
  if err then
    return nil, err -- there was an error
  end

  local balancer = balancers[upstream.id]
  if not balancer then
    if no_create then
      return nil, "balancer not found"
    else
      log(ERR, "balancer not found for ", upstream.name, ", will create it")
      return create_balancer(upstream)
    end
  end

  return balancer, upstream
end


--==============================================================================
-- Event Callbacks
--==============================================================================


--------------------------------------------------------------------------------
-- Called on any changes to a target.
-- @param operation "create", "update" or "delete"
-- @param upstream Target table with `upstream_id` field
local function on_target_event(operation, target)
  local upstream_id = target.upstream_id

  singletons.cache:invalidate_local("balancer:targets:" .. upstream_id)

  local upstream = get_upstream_by_id(upstream_id)
  if not upstream then
    log(ERR, "target ", operation, ": upstream not found for ", upstream_id)
    return
  end

  local balancer = balancers[upstream.id]
  if not balancer then
    log(ERR, "target ", operation, ": balancer not found for ", upstream.name)
    return
  end

  local ok, err = check_target_history(upstream, balancer)
  if not ok then
    log(ERR, "failed checking target history for ", upstream.name, ":  ", err)
  end
end


--------------------------------------------------------------------------------
-- Called on any changes to an upstream.
-- @param operation "create", "update" or "delete"
-- @param upstream Upstream table with `id` and `name` fields
local function on_upstream_event(operation, upstream)

  if operation == "create" then

    singletons.cache:invalidate_local("balancer:upstreams")

    local _, err = create_balancer(upstream)
    if err then
      log(ERR, "failed creating balancer for ", upstream.name, ": ", err)
    end

  elseif operation == "delete" or operation == "update" then

    singletons.cache:invalidate_local("balancer:upstreams")
    singletons.cache:invalidate_local("balancer:upstreams:" .. upstream.id)
    singletons.cache:invalidate_local("balancer:targets:"   .. upstream.id)

    local balancer = balancers[upstream.id]
    if balancer then
      stop_healthchecker(balancer)
    end

    if operation == "delete" then
      balancers[upstream.id] = nil
    else
      local _, err = create_balancer(upstream)
      if err then
        log(ERR, "failed recreating balancer for ", upstream.name, ": ", err)
      end
    end

  end

end


-- Calculates hash-value.
-- Will only be called once per request, on first try.
-- @param upstream the upstream enity
-- @return integer value or nil if there is no hash to calculate
local create_hash = function(upstream)
  local hash_on = upstream.hash_on
  if hash_on == "none" then
    return -- not hashing, exit fast
  end

  local ctx = ngx.ctx
  local identifier
  local header_field_name = "hash_on_header"

  for _ = 1,2 do

    if hash_on == "consumer" then
      -- consumer, fallback to credential
      identifier = (ctx.authenticated_consumer or EMPTY_T).id or
                   (ctx.authenticated_credential or EMPTY_T).id

    elseif hash_on == "ip" then
      identifier = ngx.var.remote_addr

    elseif hash_on == "header" then
      identifier = ngx.req.get_headers()[upstream[header_field_name]]
      if type(identifier) == "table" then
        identifier = table_concat(identifier)
      end
    end

    if identifier then
      return crc32(identifier)
    end

    -- we missed the first, so now try the fallback
    hash_on = upstream.hash_fallback
    header_field_name = "hash_fallback_header"
    if hash_on == "none" then
      return nil
    end
  end
  -- nothing found, leave without a hash
end


--==============================================================================
-- Initialize balancers
--==============================================================================


local function init()
  local upstreams, err = get_all_upstreams()
  if not upstreams then
    log(ngx.STDERR, "failed loading initial list of upstreams: ", err)
    return
  end

  local oks, errs = 0, 0
  for name, id in pairs(upstreams) do
    local upstream = get_upstream_by_id(id)
    local ok, err = create_balancer(upstream)
    if ok ~= nil then
      oks = oks + 1
    else
      log(ngx.STDERR, "failed creating balancer for ", name, ": ", err)
      errs = errs + 1
    end
  end
  log(DEBUG, "initialized ", oks, " balancer(s), ", errs, " error(s)")
end


--==============================================================================
-- Main entry point when resolving
--==============================================================================


--------------------------------------------------------------------------------
-- Resolves the target structure in-place (fields `ip`, `port`, and `hostname`).
--
-- If the hostname matches an 'upstream' pool, then it must be balanced in that
-- pool, in this case any port number provided will be ignored, as the pool
-- provides it.
--
-- @param target the data structure as defined in `core.access.before` where
-- it is created.
-- @param silent Do not produce body data (to be used in OpenResty contexts
-- which do not support sending it)
-- @return true on success, nil+error message+status code otherwise
local function execute(target)

  if target.type ~= "name" then
    -- it's an ip address (v4 or v6), so nothing we can do...
    target.ip = target.host
    target.port = target.port or 80 -- TODO: remove this fallback value
    target.hostname = target.host
    return true
  end

  -- when tries == 0,
  --   it runs before the `balancer` context (in the `access` context),
  -- when tries >= 2,
  --   then it performs a retry in the `balancer` context
  local dns_cache_only = target.try_count ~= 0
  local balancer, upstream, hash_value

  if dns_cache_only then
    -- retry, so balancer is already set if there was one
    balancer = target.balancer

  else
    -- first try, so try and find a matching balancer/upstream object
    balancer, upstream = get_balancer(target)
    if balancer == nil then -- `false` means no balancer, `nil` is error
      return nil, upstream, 500
    end

    if balancer then
      -- store for retries
      target.balancer = balancer

      -- calculate hash-value
      -- only add it if it doesn't exist, in case a plugin inserted one
      hash_value = target.hash_value
      if not hash_value then
        hash_value = create_hash(upstream)
        target.hash_value = hash_value
      end
    end
  end

  local ip, port, hostname
  if balancer then
    -- have to invoke the ring-balancer
    ip, port, hostname = balancer:getPeer(hash_value,
                                          target.try_count,
                                          dns_cache_only)
    if not ip and port == "No peers are available" then
      return nil, "failure to get a peer from the ring-balancer", 503
    end
    target.hash_value = hash_value

  else
    -- have to do a regular DNS lookup
    local try_list
    ip, port, try_list = toip(target.host, target.port, dns_cache_only)
    hostname = target.host
    if not ip then
      log(ERR, "[dns] ", port, ". Tried: ", tostring(try_list))
      if port == "dns server error: 3 name error" then
        return nil, "name resolution failed", 503
      end
    end
  end

  if not ip then
    return nil, port, 500
  end

  target.ip = ip
  target.port = port
  target.hostname = hostname
  return true
end


--------------------------------------------------------------------------------
-- Update health status and broadcast to workers
-- @param upstream a table with upstream data
-- @param ip target IP
-- @param port target port
-- @param is_healthy boolean: true if healthy, false if unhealthy
-- @return true if posting event was successful, nil+error otherwise
local function post_health(upstream, ip, port, is_healthy)

  local balancer = balancers[upstream.id]
  if not balancer then
    return nil, "Upstream " .. tostring(upstream.name) .. " has no balancer"
  end

  local healthchecker = healthcheckers[balancer]
  if not healthchecker then
    return nil, "no healthchecker found for " .. tostring(upstream.name)
  end

  return healthchecker:set_target_status(ip, port, is_healthy)
end


--------------------------------------------------------------------------------
-- for unit-testing purposes only
local function _get_healthchecker(balancer)
  return healthcheckers[balancer]
end


--------------------------------------------------------------------------------
-- for unit-testing purposes only
local function _get_target_history(balancer)
  return target_histories[balancer]
end


return {
  init = init,
  execute = execute,
  on_target_event = on_target_event,
  on_upstream_event = on_upstream_event,
  get_upstream_by_name = get_upstream_by_name,
  get_all_upstreams = get_all_upstreams,
  post_health = post_health,

  -- ones below are exported for test purposes only
  _create_balancer = create_balancer,
  _get_balancer = get_balancer,
  _get_healthchecker = _get_healthchecker,
  _get_target_history = _get_target_history,
  _load_upstreams_dict_into_memory = _load_upstreams_dict_into_memory,
  _load_upstream_into_memory = _load_upstream_into_memory,
  _load_targets_into_memory = _load_targets_into_memory,
  _create_hash = create_hash,
}
