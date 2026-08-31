-- Run from the mod root with a Lua 5.2-compatible interpreter.
package.path = "./?.lua;" .. package.path

rawset(_G, "defines", { direction = { north = 0, east = 4, south = 8, west = 12 } })
rawset(_G, "game", { tick = 100 })

local BeltGraph = require("scripts/belt-graph")
local Belts = require("scripts/belts")
local DualPhase = require("scripts/dual-phase")

BeltGraph.step = function() return true end
Belts.route_cost = function() return 200, 100 end

local surface = {}
local entity = { valid = true, type = "character", position = { x = 0, y = 0 }, surface = surface }
local player = { character = entity }

-- The search began behind the character. The winning suffix starts at (5, 5),
-- so accepting the candidate must not send the character back to (-10, 0).
BeltGraph.cost_of = function(_, _, route)
  local first = route[1]
  if first.x == -10 then return 300 end
  if first.x == 5 and first.y == 5 then return 20 end
  if first.x == 0 and first.y == 20 then return 200 end
  return 100
end

local goal = {
  position = { x = 10, y = 0 },
  path = {
    { position = { x = 0, y = 20 } },
    { position = { x = 10, y = 0 } },
  },
  belt_search = {
    result = {
      { x = -10, y = 0 },
      { x = 5, y = 5 },
      { x = 10, y = 0 },
    },
  },
  belt_search_started = 90,
}
local data = { move_entity = entity, current_waypoint = 1, goals = { goal } }

local submitted
local function submit_candidate(_, _, _, candidate)
  submitted = candidate
  return true
end

assert(not DualPhase.tick(player, data, submit_candidate),
  "a sparse graph corridor must not be installed directly")
assert(submitted, "better rebased candidate should be submitted for pathfinder validation")
assert(goal.path[1].position.y == 20, "incumbent path should remain active during validation")
assert(DualPhase.try_install_validated(player, data, goal, submitted),
  "connected candidate should be accepted after validation")
assert(goal.path[1].position.x == 5 and goal.path[1].position.y == 5,
  "accepted candidate should discard the stale search prefix")

-- Even an optimistic cost estimate must not authorize a wildly disproportionate
-- geometric detour.
BeltGraph.cost_of = function(_, _, route)
  local first = route[1]
  if first.y == 30 then return 10 end
  return 100
end

local direct_path = { { position = { x = 10, y = 0 } } }
local detour_goal = {
  position = { x = 10, y = 0 },
  path = direct_path,
  belt_search = {
    result = {
      { x = 0, y = 30 },
      { x = 10, y = 0 },
    },
  },
  belt_search_started = 90,
}
local detour_data = { move_entity = entity, current_waypoint = 1, goals = { detour_goal } }

local detour_submitted = false
assert(not DualPhase.tick(player, detour_data, function()
  detour_submitted = true
  return true
end), "oversized geometric detour should be rejected")
assert(not detour_submitted, "rejected geometric detour must not reach pathfinder validation")
assert(detour_goal.path == direct_path, "rejected candidate must leave the incumbent route untouched")

print("dual-phase route selection test passed")
