-- Run from the mod root with a Lua 5.2-compatible interpreter.
package.path = "./?.lua;" .. package.path

rawset(_G, "defines", {
  direction = {
    north = 0, northeast = 1, east = 2, southeast = 3,
    south = 4, southwest = 5, west = 6, northwest = 7,
  },
})
rawset(_G, "script", { active_mods = {} })

local rendered = 0
local function render_object() return { valid = true, destroy = function() end } end
rawset(_G, "rendering", {
  draw_line = function() rendered = rendered + 1; return render_object() end,
  draw_circle = function() rendered = rendered + 1; return render_object() end,
  draw_text = function() rendered = rendered + 1; return render_object() end,
})

local player_settings = {
  ["c2m-character-margin"] = { value = 0.45 },
  ["c2m-character-proximity-threshold"] = { value = 1.5 },
  ["c2m-vehicle-proximity-threshold"] = { value = 6 },
  ["c2m-stuck-threshold"] = { value = 30 },
  ["c2m-vehicle-path-margin"] = { value = 2 },
  ["c2m-vehicle-prefer-straight-paths"] = { value = false },
  ["c2m-cancel-on-manual-move"] = { value = true },
  ["c2m-routing-strategy"] = { value = "dual-phase" },
  ["c2m-belt-ride"] = { value = true },
  ["c2m-squeeze-margin"] = { value = 0 },
  ["c2m-never-give-up"] = { value = true },
  ["c2m-debug-mode"] = { value = false },
}
rawset(_G, "settings", {
  global = { ["c2m-update-interval"] = { value = 1 } },
  get_player_settings = function() return player_settings end,
})

local requests = {}
local next_request_id = 0
local surface = {
  index = 1,
  request_path = function(params)
    next_request_id = next_request_id + 1
    requests[next_request_id] = params
    return next_request_id
  end,
  find_entities_filtered = function() return {} end,
}
local entity = {
  valid = true,
  type = "character",
  position = { x = 0, y = 0 },
  surface = surface,
  prototype = {
    collision_box = {
      left_top = { x = -0.2, y = -0.2 },
      right_bottom = { x = 0.2, y = 0.2 },
    },
    collision_mask = {},
  },
}
local player = {
  index = 1,
  valid = true,
  connected = true,
  character = entity,
  surface = surface,
  force = { name = "player" },
  color = { r = 0, g = 1, b = 0 },
}
rawset(_G, "game", { tick = 100, players = { [1] = player } })

local Config = require("scripts/config")
Config.load()
local PlayerData = require("scripts/player-data")
local BeltGraph = require("scripts/belt-graph")
local Belts = require("scripts/belts")
local Pathfinding = require("scripts/pathfinding")
local GUI = require("scripts/gui")
GUI.update = function() end

-- Make the connected candidate decisively better than the incumbent while
-- preserving the stale-prefix ordering needed by the rebase check.
BeltGraph.cost_of = function(_, _, route)
  if route[1].x < 4 then return 100 end
  if route[1].x < 9 then return 10 end
  return 20
end
Belts.route_cost = function() return 200, 100 end

local incumbent = {
  { position = { x = 0, y = 20 } },
  { position = { x = 10, y = 0 } },
}
local goal = { position = { x = 10, y = 0 }, path = incumbent }
local data = PlayerData.ensure(1)
data.move_entity = entity
data.goals = { goal }
data.current_waypoint = 1

assert(Pathfinding.begin_candidate_path(player, data, goal, {
  { x = 0, y = 0 },
  { x = 5, y = 5 },
  { x = 10, y = 0 },
}), "corridor validation should start")
assert(next_request_id == 1 and requests[1].goal.x == 5,
  "first nontrivial corridor leg should be requested")
assert(goal.path == incumbent, "incumbent must remain active during corridor validation")

Pathfinding.on_path_request_finished({
  id = 1,
  path = {
    { position = { x = 0, y = 0 } },
    { position = { x = 5, y = 5 } },
  },
})
assert(next_request_id == 2 and requests[2].goal.x == 10,
  "second corridor leg should be connected independently")
assert(goal.path == incumbent, "partial validation must not replace the route")

-- Simulate progress on Phase 1 while the background requests are resolving.
entity.position = { x = 4, y = 1 }
Pathfinding.on_path_request_finished({
  id = 2,
  path = {
    { position = { x = 5, y = 5 } },
    { position = { x = 10, y = 0 } },
  },
})
assert(next_request_id == 3 and requests[3].start.x == 4,
  "validated corridor should request a fresh join from the current position")
assert(goal.path == incumbent, "route must remain unchanged until the join is validated")

Pathfinding.on_path_request_finished({
  id = 3,
  path = {
    { position = { x = 4, y = 1 } },
    { position = { x = 5, y = 5 } },
  },
})
assert(goal.path ~= incumbent, "fully connected candidate should replace the incumbent")
assert(goal.path[1].position.x == 4 and goal.path[#goal.path].position.x == 10,
  "installed route should contain the current join and final destination")
assert(rendered > 0, "successful validated swap should refresh path rendering")

print("pathfinding corridor validation test passed")
