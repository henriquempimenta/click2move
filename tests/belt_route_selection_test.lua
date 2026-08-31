-- Run from the mod root with a Lua 5.2-compatible interpreter.
package.path = "./?.lua;" .. package.path

local test_defines = {
  direction = { north = 0, east = 4, south = 8, west = 12 },
}
rawset(_G, "defines", test_defines)
rawset(_G, "game", { tick = 100 })

local belt = {
  type = "transport-belt",
  direction = test_defines.direction.east,
  prototype = { belt_speed = 0.03 },
}

local surface = { index = 1 }
surface.find_entities_filtered = function(args)
  local area = args.area
  local x = (area[1][1] + area[2][1]) / 2
  local y = (area[1][2] + area[2][2]) / 2
  if x >= 0 and x <= 10 and math.abs(y) < 0.5 then return { belt } end
  return {}
end
surface.can_place_entity = function() return true end

local Belts = require("scripts/belts")

local path = {}
for x = 9, 0, -1 do path[#path + 1] = { position = { x = x, y = 0 } } end

local origin = { x = 10, y = 0 }
local route, info = Belts.plan(surface, origin, path, { x = 0, y = 0 }, { belt_ride = false })

assert(info.changed, "opposing belt route should be rewritten")
assert(info.detours > 1, "the test route should exercise a consecutive opposed run")
assert(route[#route].x == 0 and route[#route].y == 0, "rewritten route must retain the final goal")

-- Every intermediate point should stay in one clear lane. The previous
-- implementation alternated clear/raw points and rendered a triangle at each
-- pathfinder waypoint.
local lane_side = route[1].y > 0 and 1 or -1
for i = 1, #route - 1 do
  assert(math.abs(route[i].y) >= 0.5,
    "opposed run should not alternate back onto the belt at waypoint " .. tostring(i))
  assert(route[i].y * lane_side > 0,
    "opposed run should stay on one side of the belt at waypoint " .. tostring(i))
end

local original_positions = {}
for _, waypoint in ipairs(path) do original_positions[#original_positions + 1] = waypoint.position end
local original_cost = Belts.route_cost(surface, origin, original_positions)
local rewritten_cost = Belts.route_cost(surface, origin, route)
assert(rewritten_cost < original_cost, "rewritten route should improve modeled travel cost")

-- An orthogonal crossing can contain a one-tile adverse kink in Factorio's
-- staircase path. It is not sustained travel against the belt and must not
-- trigger a lateral avoidance route.
local crossing_path = {
  { position = { x = 5, y = 0 } },
  { position = { x = 4, y = 0 } },
  { position = { x = 4, y = 2 } },
}
local crossing_route, crossing_info = Belts.plan(
  surface, { x = 5, y = -2 }, crossing_path, { x = 4, y = 2 }, { belt_ride = false })
assert(not crossing_info.changed, "short adverse kink inside a crossing should not detour")
assert(#crossing_route == #crossing_path, "orthogonal crossing should retain the naive path")
for i, waypoint in ipairs(crossing_path) do
  assert(crossing_route[i].x == waypoint.position.x and crossing_route[i].y == waypoint.position.y,
    "orthogonal crossing waypoint should remain unchanged at index " .. tostring(i))
end

local short_escape = Belts.escape_direction(
  surface, { x = 5, y = 0 }, { x = 4, y = 0 }, {})
assert(short_escape == nil, "reactive escape should ignore the same short adverse kink")

local long_escape = Belts.escape_direction(
  surface, { x = 5, y = 0 }, { x = 2, y = 0 }, {})
assert(long_escape ~= nil, "reactive escape should retain sustained opposing-belt protection")

print("belt route selection test passed")
