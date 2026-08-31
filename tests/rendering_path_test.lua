-- Run from the mod root with a Lua 5.2-compatible interpreter.
package.path = "./?.lua;" .. package.path

local calls = { lines = {}, circles = {}, texts = {} }
local function object() return { valid = true, destroy = function() end } end
rawset(_G, "rendering", {
  draw_line = function(args) calls.lines[#calls.lines + 1] = args; return object() end,
  draw_circle = function(args) calls.circles[#calls.circles + 1] = args; return object() end,
  draw_text = function(args) calls.texts[#calls.texts + 1] = args; return object() end,
})

local surface = { index = 1 }
local player = { index = 1, valid = true, surface = surface, color = { r = 0, g = 1, b = 0 } }
rawset(_G, "game", { players = { [1] = player } })

local Rendering = require("scripts/rendering")
local entity = { valid = true, surface = surface, position = { x = 5, y = 0 } }
local data = {
  move_entity = entity,
  current_waypoint = 2,
  goals = {{
    position = { x = 20, y = 0 },
    path = {
      { position = { x = 0, y = 0 } },
      { position = { x = 10, y = 0 } },
      { position = { x = 20, y = 0 } },
    },
  }},
}

Rendering.render_paths_for_player(1, { [1] = data })

-- First two lines are the route; the following two form the target crosshair.
assert(#calls.lines == 4, "remaining route and target crosshair should be rendered")
assert(calls.lines[1].from == entity, "first remaining segment should track the moving entity")
assert(calls.lines[1].to.x == 10, "rendering should begin at the current waypoint")
assert(calls.lines[2].to.x == 20, "rendering should include the final waypoint")
assert(calls.lines[1].time_to_live == nil and calls.lines[2].time_to_live == nil,
  "route rendering should persist until explicitly replaced")

print("rendering path test passed")
