--[[
  Click2Move - Debug counters

  Deliberately dependency-free. Instrumented modules (pathfinding, rendering,
  movement) require this, and `debug-interface` reads it — so the counters can
  be incremented from anywhere without creating a require cycle.

  Factorio only allows `require` while control.lua is being parsed, so a lazy
  require inside a function body is not an option; the dependency has to be
  acyclic at load time.

  Module-local, not `storage`: these are diagnostics for a benchmark run, so
  they must never enter the save or influence the simulation.
]]

-- Counters live in one table so that adding a metric is a single edit here
-- rather than three (declare, reset, snapshot) that can fall out of step.
-- `count` ignores keys that are not declared, which makes a typo silently lose
-- data — so the declared set is the contract.
local KEYS = {
  "render_objects_created",
  "path_requests",
  "stuck_transitions",
  -- Belt-aware routing
  "belt_replans",     -- paths rewritten because a belt opposed travel
  "belt_rides",       -- routes that deliberately boarded a helpful belt
  "belt_escapes",     -- per-tick "step off this belt" corrections applied
  -- Dual-phase (Phase 2 belt-graph A*)
  "belt_searches",       -- async searches started
  "belt_swaps",          -- searches that won and replaced the walking route
  "belt_swaps_rejected", -- searches that finished but lost from the current position
  -- Never-give-up ladder
  "path_fallbacks",   -- loosened re-requests after a route failure
  "manual_cancels",   -- auto-walks cancelled by player input
}

local DebugCounters = { _keys = KEYS }

local values = {}

---@param key string
---@param n? number
function DebugCounters.count(key, n)
  if values[key] == nil then return end
  values[key] = values[key] + (n or 1)
end

function DebugCounters.reset()
  for _, key in ipairs(KEYS) do
    values[key] = 0
  end
end

---@return table
function DebugCounters.snapshot()
  local out = {}
  for _, key in ipairs(KEYS) do
    out[key] = values[key]
  end
  return out
end

DebugCounters.reset()

return DebugCounters
