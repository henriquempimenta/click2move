-- Run from the mod directory: lua tests/vehicle-speed.lua
-- The speed planner against a tick-by-tick simulation of native vehicle
-- physics measured in Factorio 2.1, and through the production handlers.
local Fake = dofile("tests/support/fake-factorio.lua")
-- Lua 5.3+ dropped math.atan2 for a two-argument math.atan.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local Trajectory = dofile("scripts/vehicle-trajectory.lua")
local function equal(actual, expected, reason)
  assert(actual == expected, (reason or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function near(actual, expected, tolerance, reason)
  assert(math.abs(actual - expected) <= tolerance * math.max(1, math.abs(expected)),
    reason .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function point(x, y) return {x = x, y = y or 0} end

-- Native car and tank prototypes, and tiles from concrete (0.8) to sand (1.8).
local CAR = {braking_force = 10000 / 3, weight = 700, rotation_speed = .015, friction_force = .002,
  consumption = 10000, burner_prototype = {effectivity = .5},
  terrain_friction_modifier = 1, tank_driving = false,
  collision_box = {left_top = point(-.7, -1), right_bottom = point(.7, 1)}, collision_mask = {layers = {}}}
local TANK = {braking_force = 40000 / 3, weight = 20000, rotation_speed = .0035, friction_force = .002,
  consumption = 10000, burner_prototype = {effectivity = .9},
  terrain_friction_modifier = .2, tank_driving = true,
  collision_box = {left_top = point(-.9, -1.3), right_bottom = point(.9, 1.3)}, collision_mask = {layers = {}}}
local TILES = {concrete = {vehicle_friction_modifier = .8}, ["grass-1"] = {vehicle_friction_modifier = 1.6},
  ["sand-1"] = {vehicle_friction_modifier = 1.8}}

-- Conservative Euler approximation to the measured native energy step:
-- v_next² = v² - 2 * braking_force / weight / 3600, before friction.
local function native_stop(prototype, speed, tile_modifier, friction_modifier)
  local brake = prototype.braking_force / prototype.weight / 3600
  local friction = prototype.friction_force * (friction_modifier or 1)
    * (1 + (tile_modifier - 1) * prototype.terrain_friction_modifier)
  local distance = 0
  while speed > 0 do
    distance = distance + speed
    speed = speed - (brake / math.max(speed, .01) + friction * speed)
  end
  return distance
end

local function fixture(prototype, interval, speed, margin)
  local state = {storage = {}, tick = 0, next_path = 0, requests = {}}
  state.surface = {index = 1, valid = true}
  state.surface.request_path = function(params)
    state.next_path = state.next_path + 1; state.requests[state.next_path] = params
    return state.next_path
  end
  state.character = {valid = true, name = "character", type = "character", position = point(0), surface = state.surface}
  state.entity = {valid = true, name = prototype == TANK and "tank" or "car", type = "car", position = point(0),
    surface = state.surface, speed = speed or 0, orientation = .25, prototype = prototype,
    riding_state = {acceleration = 0, direction = 0}}
  state.entity.get_driver = function() return state.character end
  state.player = Fake.player(state, {character = state.character, surface = state.surface,
    vehicle = state.entity, physical_vehicle = state.entity})
  state.global_settings = {["c2m-update-interval"] = {value = interval or 1}}
  state.player_settings = Fake.player_settings({["c2m-vehicle-path-margin"] = margin or 2})
  local runtime = Fake.vm(state)
  runtime.env.prototypes = {tile = TILES}
  runtime.init()
  runtime.route = function(points)
    runtime.command_at(points[#points])
    local data = runtime.pd.get_all()[1]
    local path = {}
    for i, p in ipairs(points) do path[i] = {position = p} end
    runtime.events[2]({id = data.goals[1].path_id, path = path})
    return data
  end
  return state, runtime
end

-- A straight path with one node per tile, optionally turning south after `turn` tiles.
local function line(length, turn)
  local points = {}
  for x = 0, length do points[#points + 1] = point(x) end
  for y = 1, turn or 0 do points[#points + 1] = point(length, y) end
  return points
end

local tests = {}
local function test(name, body) tests[#tests + 1] = {name, body} end

test("planned speeds can always stop in time and are not grossly conservative", function()
  for _, prototype in ipairs({CAR, TANK}) do
    for _, distance in ipairs({10, 50, 200, 600}) do
      local state, runtime = fixture(prototype, 1)
      local path = {}
      for i, p in ipairs(line(distance)) do path[i] = {position = p} end
      local limit = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
      local name = state.entity.name .. " over " .. distance .. " tiles"
      -- The most slippery tile is the binding case; rougher tiles only stop sooner.
      assert(native_stop(prototype, limit, .8) <= distance, name .. " cannot stop from " .. limit)
      assert(native_stop(prototype, limit, .8) >= .7 * (distance - 2), name .. " brakes far too early at " .. limit)
    end
  end
end)

test("live friction modifiers rebuild the profile and never overestimate stopping power", function()
  local state, runtime = fixture(CAR, 1)
  local path = {}
  for i, p in ipairs(line(100)) do path[i] = {position = p} end
  local ordinary = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
  for _, modifier in ipairs({0, 1e-20, 1e-16, 1e-10, .1, 2, 0, 1}) do
    state.entity.friction_modifier = modifier
    local limit = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
    assert(native_stop(CAR, limit, .8, modifier) <= 100,
      "friction modifier " .. modifier .. " cannot stop from the cached limit " .. limit)
    if modifier == 0 then
      assert(limit < ordinary * .95, "removing friction retained an optimistic profile")
    elseif modifier == 1 then
      assert(math.abs(limit - ordinary) < 1e-10, "restoring friction kept a stale profile")
    end
  end
end)

test("corners lower the limit in proportion to how sharp they are and the path clearance", function()
  local function corner_limit(degrees, clearance)
    local state, runtime = fixture(CAR, 1)
    local radians = math.rad(degrees)
    local path = {}
    for x = 0, 400 do path[#path + 1] = {position = point(x)} end
    for step = 1, 400 do path[#path + 1] = {position = point(400 + step * math.cos(radians), step * math.sin(radians))} end
    -- Measure on the same rounded trajectory the steering follows, rather
    -- than at the discarded grid corner outside that trajectory.
    local geometry = runtime.vehicle_speed.trajectory(state.entity, path, clearance)
    local position, tangent = Trajectory.sample(geometry, geometry.waypoint_s[401])
    state.entity.position = position
    state.entity.orientation = atan2(tangent.x, -tangent.y) / (2 * math.pi)
    return runtime.vehicle_speed.limit(state.entity, path, 401, clearance, 0)
  end
  local right_angle, gentle, hairpin = corner_limit(90, 2), corner_limit(20, 2), corner_limit(170, 2)
  assert(hairpin < right_angle and right_angle < gentle, "sharper corners must be slower")
  assert(corner_limit(90, 0.5) < right_angle, "less clearance must be slower")
  -- Turning radius sqrt(v) / (2 pi rotation_speed) must fit the corridor,
  -- 2 tiles either side: a circle swinging from the outer edge to the inner
  -- edge at the apex has R(1 - cos 45°) <= 4.
  local radius = math.sqrt(right_angle) / (2 * math.pi * CAR.rotation_speed)
  assert(radius * (1 - math.sqrt(.5)) <= 4, "a right-angle turn at " .. right_angle .. " leaves the corridor")
  -- After the rotated body and tracking reserves, 1.109 tiles remain. Cutting
  -- only the inside of the corner would allow a radius of 1.109 / (1 - cos 45°).
  assert(radius > 1.5 * 1.109 / (1 - math.sqrt(.5)), "the turn does not use the outside of the corridor")
  assert(right_angle > .03, "a clear right angle should not need a crawl")
end)

-- Nuclear fuel as the runtime describes it, burning and waiting in the fuel slots.
local NUCLEAR = {fuel_acceleration_multiplier = 2.5, fuel_acceleration_multiplier_quality_bonus = .45,
  fuel_top_speed_multiplier = 1.15, fuel_top_speed_multiplier_quality_bonus = .045}
local function fuel(entity, burning, waiting, remaining)
  entity.burner = burning and {currently_burning = {name = burning[1], quality = {level = burning[2]}},
    remaining_burning_fuel = remaining or 0} or nil
  local inventory = {}
  for index, item in ipairs(waiting or {}) do
    inventory[index] = {valid_for_read = true, prototype = item[1], quality = {level = item[2]}}
  end
  inventory[#inventory + 1] = {valid_for_read = false}
  entity.get_fuel_inventory = function() return inventory end
end

test("one handler snapshot shares live fuel reads and preserves helper results", function()
  local state, runtime = fixture(TANK, 10, .2)
  fuel(state.entity, {NUCLEAR, 5}, {{NUCLEAR, 5}})
  local inventory = state.entity.get_fuel_inventory
  local reads = 0
  state.entity.get_fuel_inventory = function() reads = reads + 1; return inventory() end
  local path = {}
  for _, p in ipairs(line(100)) do path[#path + 1] = {position = p} end
  local speed = runtime.vehicle_speed
  local target = point(50, -30)
  local function results(context)
    local limit = speed.limit(state.entity, path, 2, 2, 2, context)
    return {limit, speed.maneuver_ticks(state.entity, limit, context),
      speed.braking_overshoots(state.entity, limit, 1, context),
      speed.steering_overshoots(state.entity, target, 10, context),
      speed.braking_overshoots(state.entity, limit, 11, context)}
  end
  local separate = results()
  equal(reads, 5, "the compatibility calls must still read live state separately")
  reads = 0
  local context = speed.create_context(state.entity)
  local shared = results(context)
  equal(reads, 1, "one handler must scan the live fuel inventory only once")
  for index, expected in ipairs(separate) do equal(shared[index], expected, "sharing changed helper " .. index) end
  -- A snapshot belonging to another vehicle cannot bypass live reads.
  reads = 0
  local other = {}; for key, value in pairs(state.entity) do other[key] = value end
  speed.maneuver_ticks(other, .1, context)
  equal(reads, 1, "a foreign vehicle context was accepted")
end)

test("fresh contexts see same-tick fuel power and friction changes", function()
  local state, runtime = fixture(TANK, 10, .2)
  local speed = runtime.vehicle_speed
  fuel(state.entity, {NUCLEAR, 5}, {{NUCLEAR, 5}})
  state.entity.grid = {movement_bonus = 3}
  local path = {}
  for _, p in ipairs(line(300)) do path[#path + 1] = {position = p} end
  local powered = speed.create_context(state.entity)
  local strong = speed.limit(state.entity, path, 2, 2, 0, powered)
  local turn = speed.maneuver_ticks(state.entity, .1, powered)
  -- No tick advance: another handler can see a changed inventory or power.
  state.entity.grid.movement_bonus = 0
  state.entity.friction_modifier = 0
  fuel(state.entity, {NUCLEAR, 5}, {}, 0)
  local depleted = speed.create_context(state.entity)
  local weak = speed.limit(state.entity, path, 2, 2, 0, depleted)
  assert(weak < strong, "the fresh context retained old fuel or friction")
  assert(speed.maneuver_ticks(state.entity, .1, depleted) > turn * 2, "the fresh context retained old equipment power")
  equal(weak, speed.limit(state.entity, path, 2, 2, 0), "unshared compatibility call used a stale model")
  -- Rebuilding a profile must not mutate an earlier context's model.
  equal(speed.maneuver_ticks(state.entity, .1, powered), turn)
  equal(state.tick, 0, "the invalidation check accidentally advanced game time")
end)

test("prototype constants are reused while prototype replacement rebuilds geometry", function()
  local state, runtime = fixture(TANK, 1)
  local reads = {}
  state.entity.prototype = setmetatable({}, {__index = function(_, key)
    reads[key] = (reads[key] or 0) + 1; return TANK[key]
  end})
  local speed = runtime.vehicle_speed
  local first = speed.create_context(state.entity)
  speed.body_radius(state.entity)
  speed.create_context(state.entity)
  for _, key in ipairs({"braking_force", "weight", "rotation_speed", "friction_force", "collision_box"}) do
    equal(reads[key], 1, "immutable prototype field " .. key .. " was reread")
  end
  local path = {{position = point(0)}, {position = point(100)}}
  local original, original_room = speed.trajectory(state.entity, path, 2, first)
  local replacement = {}; for key, value in pairs(TANK) do replacement[key] = value end
  replacement.collision_box = {left_top = point(-5, -5), right_bottom = point(5, 5)}
  state.entity.prototype = replacement
  local changed, changed_room = speed.trajectory(state.entity, path, 2, speed.create_context(state.entity))
  assert(changed ~= original and changed_room < original_room,
    "a different prototype reused the old shape or collision allowance")
end)

test("recreated native-style prototype wrappers retain the cached shape", function()
  local state, runtime = fixture(CAR, 1)
  local wrappers = 0
  state.entity.prototype = nil
  setmetatable(state.entity, {__index = function(_, key)
    if key == "prototype" then
      wrappers = wrappers + 1
      return setmetatable({name = "wrapped-car"}, {__index = CAR})
    end
  end})
  local path = {{position = point(0)}, {position = point(100)}}
  local speed = runtime.vehicle_speed
  local first = speed.create_context(state.entity)
  local original = speed.trajectory(state.entity, path, 2, first)
  collectgarbage("collect")
  local second = speed.create_context(state.entity)
  local repeated = speed.trajectory(state.entity, path, 2, second)
  assert(wrappers >= 2, "the fixture did not recreate the native-style wrapper")
  equal(second.model.shape, first.model.shape, "wrapper recreation lost immutable prototype constants")
  equal(repeated, original, "wrapper recreation rebuilt identical path geometry")
end)

test("the movement handler scans fuel once and reuses state after observing acceleration", function()
  local state, runtime = fixture(TANK, 1, .2)
  fuel(state.entity, {NUCLEAR, 5}, {{NUCLEAR, 5}})
  local inventory = state.entity.get_fuel_inventory
  local reads = 0
  state.entity.get_fuel_inventory = function() reads = reads + 1; return inventory() end
  local data = runtime.route(line(300))
  reads = 0
  runtime.advance(1)
  equal(reads, 1, "production movement rescanned the fuel inventory")
  local progress, position, sample = data.vehicle_trajectory, data.vehicle_last_position, data.vehicle_speed_sample
  local old_s, old_x, old_tick = progress.s, position.x, sample.tick
  -- The next sample represents native acceleration from the previous command.
  state.entity.position, state.entity.speed = point(.25), .3
  reads = 0
  runtime.advance(1)
  equal(reads, 1, "the next handler did not take exactly one fresh snapshot")
  equal(data.vehicle_trajectory, progress, "curve progress table was reallocated")
  equal(data.vehicle_last_position, position, "last-position table was reallocated")
  equal(data.vehicle_speed_sample, sample, "speed-sample table was reallocated")
  assert(progress.s > old_s and position.x > old_x and sample.tick > old_tick, "reused state was not updated")
  assert(data.vehicle_acceleration and data.vehicle_acceleration > .09,
    "the speed sample was overwritten before acceleration was observed")
end)

test("backwards planning computes ordinary boundary tangents without sampling positions", function()
  local trajectory = dofile("scripts/vehicle-trajectory.lua")
  local sample, samples = trajectory.sample, 0
  trajectory.sample = function(...) samples = samples + 1; return sample(...) end
  local env = setmetatable({prototypes = {tile = TILES}, require = function(name)
    return name == "scripts/vehicle-trajectory" and trajectory or require(name)
  end}, {__index = _G})
  local speed = assert(loadfile("scripts/vehicle-speed.lua", "t", env))()
  local state = fixture(CAR, 1)
  local path = {{position = point(0)}, {position = point(10)}, {position = point(10, 30)}}
  local geometry = speed.trajectory(state.entity, path, 0)
  assert(#geometry.segments > 1, "fixture did not contain an explicit corner")
  equal(samples, 0, "backwards planning sampled at every segment boundary")
  state.entity.position = point(9.8)
  equal(speed.limit(state.entity, path, 2, 0, 0), .03, "the explicit sharp corner lost its speed cap")
  samples = 0
  geometry = speed.trajectory(state.entity, path, 2)
  assert(#geometry.segments > 2, "fixture did not contain smooth joins")
  equal(samples, 0, "arc exit tangents were found through curve sampling")
end)

test("a microscopic joining line cannot create an artificial speed bump", function()
  local trajectory = dofile("scripts/vehicle-trajectory.lua")
  local tiny = 1e-8
  -- A numerical joining sliver between two otherwise straight pieces has an
  -- arbitrary vertical heading, despite requiring no meaningful car turn.
  local geometry = {total_length = 40 + tiny, path_distances = {0, 40}, point = point(40, tiny),
    waypoint_s = {0, 40 + tiny}, waypoint_segments = {1, 3}, segments = {
      {kind = "line", a = point(0), b = point(10), tangent = point(1), length = 10,
        start_s = 0, end_s = 10, path_start = 0, path_end = 10},
      {kind = "line", a = point(10), b = point(10, tiny), tangent = point(0, 1), length = tiny,
        start_s = 10, end_s = 10 + tiny, path_start = 10, path_end = 10},
      {kind = "line", a = point(10, tiny), b = point(40, tiny), tangent = point(1), length = 30,
        start_s = 10 + tiny, end_s = 40 + tiny, path_start = 10, path_end = 40}
    }}
  trajectory.build = function() return geometry end
  local env = setmetatable({prototypes = {tile = TILES}, require = function(name)
    return name == "scripts/vehicle-trajectory" and trajectory or require(name)
  end}, {__index = _G})
  local speed = assert(loadfile("scripts/vehicle-speed.lua", "t", env))()
  local state = fixture(CAR, 1)
  state.entity.position = point(9.8)
  local path = {{position = point(0)}, {position = point(40)}}
  assert(speed.limit(state.entity, path, 2, 2, 0) > .1,
    "an insignificant joining line imposed a crawl on a straight route")
end)

test("tank corner speed follows the fuel and exoskeleton turning rate, and falls when power does", function()
  local state, runtime = fixture(TANK, 1)
  local path = {}
  for x = 0, 400 do path[#path + 1] = {position = point(x)} end
  for y = 1, 400 do path[#path + 1] = {position = point(400, y)} end
  local geometry = runtime.vehicle_speed.trajectory(state.entity, path, 2)
  local position, tangent = Trajectory.sample(geometry, geometry.waypoint_s[401])
  state.entity.position = position
  state.entity.orientation = atan2(tangent.x, -tangent.y) / (2 * math.pi)
  local function limit() return runtime.vehicle_speed.limit(state.entity, path, 401, 2, 0) end
  local empty = limit()
  -- Measured natively: rotation_speed * (0.75 + 0.25 * A * (1 + B)).
  fuel(state.entity, {NUCLEAR, 5}, {{NUCLEAR, 5}})
  local legendary = limit()
  near(legendary / empty, .75 + .25 * 4.75, .000001, "legendary nuclear fuel")
  state.entity.grid = {movement_bonus = 11.25}
  -- Fifteen legendary exoskeletons turn 15 times faster than an empty tank;
  -- braking for the destination then binds first.
  local exoskeletons = limit()
  assert(exoskeletons > legendary * 2, "exoskeletons did not speed up the corner")
  -- Unpowered exoskeletons give no bonus: the next update must slow down.
  state.entity.grid.movement_bonus = 0
  near(limit(), legendary, .000001, "exoskeletons without power")
  -- Weaker fuel waiting in the slots, or none at all, sets the plan.
  fuel(state.entity, {NUCLEAR, 5}, {{NUCLEAR, 0}})
  near(limit() / empty, .75 + .25 * 2.5, .000001, "normal nuclear fuel waiting")
  -- The last item counts while it holds twenty seconds of full throttle.
  fuel(state.entity, {NUCLEAR, 5}, {}, 1199 * 10000 / .9)
  near(limit(), empty, .000001, "the last burning fuel can run out")
  fuel(state.entity, {NUCLEAR, 5}, {}, 1201 * 10000 / .9)
  near(limit(), legendary, .000001, "a nearly full last item")
  state.entity.burner, state.entity.grid = nil, nil
  near(limit(), empty, .000001, "an empty burner turns at rotation_speed")
  -- Cars turn at rotation_speed * sqrt(speed) whatever the fuel.
  local car_state, car_runtime = fixture(CAR, 1)
  local car_geometry = car_runtime.vehicle_speed.trajectory(car_state.entity, path, 2)
  car_state.entity.position, tangent = Trajectory.sample(car_geometry, car_geometry.waypoint_s[401])
  car_state.entity.orientation = atan2(tangent.x, -tangent.y) / (2 * math.pi)
  local car = car_runtime.vehicle_speed.limit(car_state.entity, path, 401, 2, 0)
  fuel(car_state.entity, {NUCLEAR, 5}, {{NUCLEAR, 5}})
  car_state.entity.grid = {movement_bonus = 3}
  near(car_runtime.vehicle_speed.limit(car_state.entity, path, 401, 2, 0), car, .000001, "car turning changed")
end)

test("fuel with a higher top speed brakes harder, by the square of its multiplier", function()
  for _, prototype in ipairs({CAR, TANK}) do
    local state, runtime = fixture(prototype, 1)
    local path = {}
    for i, p in ipairs(line(300)) do path[i] = {position = p} end
    local empty = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
    fuel(state.entity, {NUCLEAR, 5}, {{NUCLEAR, 5}})
    local legendary = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
    -- Native braking with legendary nuclear fuel is 1.376^2 = 1.89 times as strong.
    local strong = {}
    for key, value in pairs(prototype) do strong[key] = value end
    strong.braking_force = prototype.braking_force * 1.376 ^ 2
    assert(native_stop(strong, legendary, .8) <= 300, state.entity.name .. " cannot stop from " .. legendary)
    -- Friction does most of a tank's braking, so its gain is smaller.
    assert(legendary > empty * (prototype == CAR and 1.15 or 1.01), state.entity.name .. " ignored the fuel's braking")
    fuel(state.entity, {NUCLEAR, 5}, {}, 0)
    near(runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0), empty, .000001, "last fuel burning")
  end
end)

test("the destination and corners far ahead limit speed long before they are reached", function()
  local state, runtime = fixture(CAR, 1)
  local path = {}
  for i, p in ipairs(line(300, 40)) do path[i] = {position = p} end
  local far = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
  state.entity.position = point(250)
  local near = runtime.vehicle_speed.limit(state.entity, path, 252, 2, 0)
  assert(near < far, "the limit must fall towards the corner")
  assert(native_stop(CAR, far, .8) < 340, "the start limit must allow stopping at the destination")
end)

test("vehicles brake above the limit, coast just below it and accelerate otherwise", function()
  local state, runtime = fixture(CAR, 1)
  local riding = runtime.navigation.get_vehicle_riding_state
  local defines = runtime.env.defines
  for _, case in ipairs({{.5, .4, defines.riding.acceleration.braking}, {.39, .4, defines.riding.acceleration.nothing},
      {.3, .4, defines.riding.acceleration.accelerating}, {.5, nil, defines.riding.acceleration.accelerating}}) do
    state.entity.speed = case[1]
    equal(riding(state.entity, point(50), case[2]).acceleration, case[3], "speed " .. case[1] .. " limit " .. tostring(case[2]))
  end
end)

test("turning vehicles steer every tick only while an update could overshoot the heading", function()
  local state, runtime = fixture(CAR, 10)
  local overshoots = runtime.vehicle_speed.steering_overshoots
  state.entity.speed = .4
  -- 0.4 tiles per tick turns 0.0095 turns per tick: 0.1 turns (37 degrees) in 11 ticks.
  assert(overshoots(state.entity, point(10, 3), 10), "a 17-degree turn completes within one update")
  assert(not overshoots(state.entity, point(0, 10), 10), "a 90-degree turn needs several updates")
  assert(not overshoots(state.entity, point(10, 3), 1), "every-tick updates cannot overshoot")
end)

test("turning vehicles keep their gear through a sideways target and still reverse when needed", function()
  local state, runtime = fixture(CAR, 1)
  local riding = runtime.navigation.get_vehicle_riding_state
  local acceleration = runtime.env.defines.riding.acceleration
  for _, precise in ipairs({false, true}) do
    state.entity.speed = .03
    equal(riding(state.entity, point(-.3, -.8), .1, precise).acceleration, acceleration.accelerating,
      "a target just behind the side must not reverse forward travel")
    equal(riding(state.entity, point(-1, -.2), .1, precise).acceleration, acceleration.reversing,
      "a target clearly behind must still reverse forward travel")
    state.entity.speed = -.03
    equal(riding(state.entity, point(.3, -.8), .1, precise).acceleration, acceleration.reversing,
      "a target just behind the side must not reverse backward travel")
    equal(riding(state.entity, point(1, -.2), .1, precise).acceleration, acceleration.accelerating,
      "a target clearly behind backward travel must still select forward")
    state.entity.speed = 0
    equal(riding(state.entity, point(-.3, -.8), .1, precise).acceleration, acceleration.reversing,
      "stationary vehicles choose gear from the target")
    state.entity.speed = .5
    equal(riding(state.entity, point(-.3, -.8), .1, precise).acceleration, acceleration.braking,
      "keeping a gear must not bypass its speed limit")
    state.entity.speed = .03
    equal(riding(state.entity, point(-.3, -.8), nil, precise).acceleration, acceleration.reversing,
      "vehicles without speed control retain their previous gear choice")
  end
end)

test("a fast car brakes before a corner through the production handlers", function()
  local state, runtime = fixture(CAR, 1, 1.2)
  local data = runtime.route(line(300, 40))
  state.entity.position = point(200)
  data.current_waypoint = 205
  runtime.advance(1)
  equal(state.entity.riding_state.acceleration, runtime.env.defines.riding.acceleration.braking,
    "1.2 tiles per tick a hundred tiles before a right angle")
  state.entity.speed, state.entity.position = .2, point(20)
  data.current_waypoint = 25
  runtime.advance(1)
  equal(state.entity.riding_state.acceleration, runtime.env.defines.riding.acceleration.accelerating,
    "slow and far from the corner")
end)

local function nodes(points)
  local path = {}
  for i, p in ipairs(points) do path[i] = {position = p} end
  return path
end

-- Speed allowed with the car at `position` heading `orientation` towards waypoint `index`.
local function limit_at(path, index, position, orientation, clearance, speed)
  local state, runtime = fixture(CAR, 1, speed)
  state.entity.position, state.entity.orientation = position, orientation
  return runtime.vehicle_speed.limit(state.entity, path, index, clearance or 2, 0)
end

test("a staircase of small turns is planned as the sharp curve it adds up to", function()
  -- The path of Vulcanus route 38: east, then 45-degree turns to north-east,
  -- east, north-east and north within about 23 tiles. Judged one corner at a
  -- time, every turn looks gentle and a turning radius of 13 tiles is allowed;
  -- natively that drove into a cliff.
  local points = {}
  for x = -300, 0 do points[#points + 1] = point(x) end
  local x, y = 0, 0
  for _, leg in ipairs({{1, -1, 8}, {1, 0, 6}, {1, -1, 4}, {0, -1, 300}}) do
    for _ = 1, leg[3] do x, y = x + leg[1], y + leg[2]; points[#points + 1] = point(x, y) end
  end
  local limit = limit_at(nodes(points), 301, point(-1), .25)
  local radius = math.sqrt(limit) / (2 * math.pi * CAR.rotation_speed)
  assert(radius < 11, "the staircase allows a turning radius of " .. radius .. " tiles")
end)

test("a heading error is turned out from where the vehicle is, within the room left", function()
  local path = nodes(line(100))
  -- Pointing 60 degrees off the path towards a waypoint 20 tiles ahead.
  local off = limit_at(path, 21, point(0), .25 - 60 / 360)
  local radius = math.sqrt(off) / (2 * math.pi * CAR.rotation_speed)
  assert(radius * (1 - math.cos(math.rad(60))) <= 2, "turning a 60-degree error at " .. off .. " leaves the corridor")
  -- Outside the cleared corridor the ground is unchecked.
  equal(limit_at(path, 21, point(0, 3), .25), .03, "three tiles off a path with two tiles of clearance")
  -- A single-node path has no corridor to leave.
  assert(limit_at(nodes({point(20)}), 1, point(0, 3), .25) > .03, "a single-node path cannot be left")
end)

test("capturing a straight reference uses the original corridor beyond the tracking reserve", function()
  local state, runtime = fixture(CAR, 1, .2)
  local path = nodes(line(100))
  state.entity.position = point(0, .6)
  local limit, target, continuous = runtime.vehicle_speed.control(state.entity, path, 2, 2, 0)
  assert(limit > .1, "0.6 tiles from a path with two tiles of margin must not force a crawl")
  assert(target.x >= 1.19, "the capture target must look ahead far enough to rejoin the line")
  assert(continuous, "a car outside the reference tracking reserve must steer every tick while rejoining")
  -- The diagonal of the car's box must still fit in the original corridor.
  -- Being inside the requested margin alone does not permit the reserved
  -- rotation envelope to be spent on steering too.
  state.entity.position = point(0, 1.6)
  equal(runtime.vehicle_speed.control(state.entity, path, 2, 2, 0), .03,
    "the rotation envelope leaves less than 1.6 tiles of usable clearance")
end)

test("heading limits follow actual travel during a sideways gear transition", function()
  local path = nodes(line(1000))
  local orientation = .25 - 100 / 360
  local forward = limit_at(path, 21, point(0), orientation, 10, .1)
  local reverse = limit_at(path, 21, point(0), orientation, 10, -.1)
  assert(forward < reverse * .75, "forward travel planned for the rear's smaller heading error")
  local radius = math.sqrt(forward) / (2 * math.pi * CAR.rotation_speed)
  assert(radius * (1 - math.cos(math.rad(100))) <= 10,
    "holding forward gear at 100 degrees leaves the path corridor")
end)

test("a waypoint off to the side is never left inside the turning circle", function()
  local path = nodes({point(0), point(5, -5), point(5, -60)})
  -- Five tiles ahead and five to the left: a circle of radius 5 reaches it.
  local limit = limit_at(path, 2, point(0), .25)
  local radius = math.sqrt(limit) / (2 * math.pi * CAR.rotation_speed)
  assert(radius <= 5, "a waypoint 45 degrees off at 7 tiles needs a radius of at most 5, got " .. radius)
end)

test("a right angle at the next waypoint slows the approach to it", function()
  local path = nodes({point(0), point(30), point(30, 1), point(30, 2), point(30, 60)})
  local corner = limit_at(path, 2, point(0), .25)
  local straight = limit_at(nodes({point(0), point(30), point(60), point(90)}), 2, point(0), .25)
  assert(corner < straight, "the turn after the waypoint must slow the approach")
end)

test("reversing towards a waypoint behind is limited by the rear's heading", function()
  local state, runtime = fixture(CAR, 1, -.6)
  local defines = runtime.env.defines
  local path = nodes({point(0), point(-10), point(-20)})
  -- The car points east and backs west along the path, rear first.
  local limit = runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0)
  assert(limit < .6, "reversing at 0.6 tiles per tick must be limited")
  equal(runtime.navigation.get_vehicle_riding_state(state.entity, point(-10), limit).acceleration,
    defines.riding.acceleration.braking, "reversing faster than the limit")
  state.entity.speed = -limit / 2
  equal(runtime.navigation.get_vehicle_riding_state(state.entity, point(-10), limit).acceleration,
    defines.riding.acceleration.reversing, "reversing below the limit")
end)

test("acceleration that could pass the limit within an update is controlled every tick", function()
  local state, runtime = fixture(CAR, 10, 0)
  local data = runtime.route(line(300, 40))
  -- At rest, far from the corner: a car gains at most 0.8 tiles per tick in ten ticks.
  runtime.advance(10)
  equal(data.corner_approach, nil, "far below the limit")
  -- Still accelerating 40 tiles before the corner, close enough to the limit
  -- that holding acceleration for the entire ten-tick interval would pass it.
  state.entity.speed, state.entity.position = .4, point(260)
  data.current_waypoint = 262
  runtime.advance(10)
  equal(state.entity.riding_state.acceleration, runtime.env.defines.riding.acceleration.accelerating)
  equal(data.corner_approach, true, "just below the limit before a corner")
end)

test("braking that could pass the limit within an update is controlled every tick, not cut short", function()
  local state, runtime = fixture(CAR, 10, .2)
  local data = runtime.route(line(300))
  local control = runtime.vehicle_speed.control
  -- At 0.2 tiles per tick this car brakes about 0.0067 a tick: eleven ticks
  -- would pass a limit of 0.15, one would not.
  runtime.vehicle_speed.control = function(...)
    local _, target, curve, reached = control(...)
    return .15, target, curve, reached
  end
  runtime.advance(10)
  runtime.vehicle_speed.control = control
  equal(state.entity.speed, .2, "the speed was cut by more than one tick of braking")
  equal(state.entity.riding_state.acceleration, runtime.env.defines.riding.acceleration.braking)
  equal(data.corner_approach, true, "braking towards the limit is controlled every tick")
end)

test("a vehicle manoeuvring slowly is not taken for stuck, while a stationary one still is", function()
  for _, moving in ipairs({true, false}) do
    local state, runtime = fixture(CAR, 1, moving and .03 or 0)
    local data = runtime.route(line(300))
    data.current_waypoint = 101
    -- Circling eight tiles from the waypoint gets no closer to it: a slow
    -- turn in a tight space looks exactly like this.
    local angle, recovered = math.pi / 2, false
    for tick = 1, 150 do
      if moving then angle = angle + .03 / 8 end
      state.entity.position = point(100 + 8 * math.cos(angle), 8 * math.sin(angle))
      runtime.advance(1)
      recovered = recovered or data.stuck_state ~= "none"
      if moving then
        equal(data.stuck_state, "none", "manoeuvring at a crawl was taken for stuck at tick " .. tick)
        data.current_waypoint = 101
      end
    end
    if not moving then assert(recovered, "a stationary vehicle must still be detected") end
  end
end)

test("a stopped vehicle creeps towards a target beside it instead of braking for good", function()
  local state, runtime = fixture(CAR, 1, 0)
  local riding = runtime.navigation.get_vehicle_riding_state
  local defines = runtime.env.defines
  -- Facing east with the target 0.1 ahead and two tiles to the left.
  local target = point(.1, -2)
  equal(riding(state.entity, target, .03).acceleration, defines.riding.acceleration.accelerating)
  equal(riding(state.entity, target, .03).direction, defines.riding.direction.left)
  equal(riding(state.entity, target).acceleration, defines.riding.acceleration.braking,
    "without a speed limit the old rule applies")
end)

test("a waypoint under the vehicle's body counts as reached", function()
  -- Margin 0 leaves no clearance for a shortcut past the node.
  local state, runtime = fixture(CAR, 1, 0, 0)
  local data = runtime.route({point(0), point(.3, -.9), point(.3, -30)})
  runtime.advance(1)
  equal(data.current_waypoint, 3, "a node 0.95 tiles from the centre of a car two tiles long")
end)

test("explicit waypoint progress releases only the already accepted corner", function()
  local state, runtime = fixture(CAR, 1, .03, 0)
  local path = nodes({point(0), point(10), point(40, 30)})
  state.entity.position, state.entity.orientation = point(9.5), .375
  local before = runtime.vehicle_speed.limit(state.entity, path, 2, 0, .03)
  equal(before, .03, "an unaccepted explicit corner must retain the crawl cap")
  local progress = {}
  local after, target, _, reached = runtime.vehicle_speed.control(state.entity, path, 3, 0, .03, progress)
  assert(after > before * 2, "the profile still brakes for the accepted corner behind the target")
  local geometry = runtime.vehicle_speed.trajectory(state.entity, path, 0)
  assert(progress.vehicle_trajectory.s >= geometry.waypoint_s[2], "projection fell behind an accepted node")
  equal(target, nil, "zero clearance must retain raw waypoint steering")
  equal(reached, 3, "speed planning must not advance explicit waypoints")
  for _, segment in ipairs(geometry.segments) do equal(segment.kind, "line", "zero clearance rounded a corner") end
end)

test("explicit corners request every-tick control before using its shorter reaction", function()
  local state, runtime = fixture(CAR, 10, .03, 0)
  local path = nodes({point(0), point(10), point(40, 30)})
  state.entity.position = point(8)
  local coarse, target, continuous, reached = runtime.vehicle_speed.control(state.entity, path, 2, 0, .3)
  local single = runtime.vehicle_speed.control(state.entity, path, 2, 0, .03)
  near(coarse, single, 1e-10, "an explicit corner retained ten ticks of reaction after requesting every-tick control")
  assert(continuous, "the shorter braking reaction requires every-tick control")
  equal(target, nil, "a shorter reaction must not approve a geometric shortcut")
  equal(reached, 2)
  -- The explicit corner itself still has the same minimum speed.
  state.entity.position = point(9.8)
  equal(runtime.vehicle_speed.control(state.entity, path, 2, 0, .3), .03)
  -- Far from a corner, ordinary configured cadence remains available.
  state.entity.position = point(1)
  local _, _, distant_continuous = runtime.vehicle_speed.control(state.entity, path, 2, 0, .3)
  assert(not distant_continuous, "straight travel unnecessarily became continuous")
end)

test("the last braking step to a crawl ends at the limit instead of reversing", function()
  local state, runtime = fixture(CAR, 1, .04)
  local defines = runtime.env.defines
  -- At 0.04 tiles per tick, power-limited braking removes about 0.04 in a tick.
  assert(runtime.vehicle_speed.braking_overshoots(state.entity, .03, 1))
  runtime.navigation.set_vehicle_riding(state.entity, point(30), .03, true)
  equal(state.entity.speed, .03)
  equal(state.entity.riding_state.acceleration, defines.riding.acceleration.nothing)
  -- Faster vehicles brake normally over several ticks.
  state.entity.speed = .2
  assert(not runtime.vehicle_speed.braking_overshoots(state.entity, .03, 1))
  runtime.navigation.set_vehicle_riding(state.entity, point(30), .03, false)
  equal(state.entity.speed, .2)
  equal(state.entity.riding_state.acceleration, defines.riding.acceleration.braking)
end)

test("vehicles without braking and turning data keep their previous control", function()
  local state, runtime = fixture({collision_box = CAR.collision_box, collision_mask = {layers = {}}}, 1)
  local path = {}
  for i, p in ipairs(line(50)) do path[i] = {position = p} end
  equal(runtime.vehicle_speed.limit(state.entity, path, 2, 2, 0), nil)
end)

test("turning ceilings avoid repeated brake searches without changing the backward profile", function()
  local function private(fn, name)
    for index = 1, 100 do
      local key, value = debug.getupvalue(fn, index)
      if key == name then return value elseif not key then break end
    end
    error("missing helper "..name)
  end
  for _, prototype in ipairs({CAR, TANK}) do
    local state, runtime = fixture(prototype, 1)
    local profile = private(runtime.vehicle_speed.trajectory, "profile")
    local before, turn = private(profile, "speed_before"), private(profile, "turning_speed")
    local path = {}
    for index = 1, 200 do path[index] = {position = point(index*10, index%2*10)} end
    local calls = 0
    debug.sethook(function()
      if debug.getinfo(2, "n").name == "speed_before" then calls = calls+1 end
    end, "c")
    local geometry = runtime.vehicle_speed.trajectory(state.entity, path, 3)
    debug.sethook()
    local lines = 0
    for _, piece in ipairs(geometry.segments) do if not piece.radius then lines = lines+1 end end
    assert(calls <= lines+(#geometry.segments-lines)/10,
      "long turning chain repeated binary brake searches beyond its straight pieces")
    local cached = private(profile, "profiles")[path]
    local limit = 0
    for index = #geometry.segments, 1, -1 do
      local piece = geometry.segments[index]
      limit = math.min(piece.radius and turn(cached.model, piece.radius) or math.huge,
        before(cached.model, limit, piece.length))
      near(cached.limits[index], limit, 1e-9, "optimized turning ceiling changed the braking envelope")
    end
  end
end)

test("increasing allowance on the same raw hairpin retains a better certified curve", function()
  local file = assert(io.open("tests/engine/build-profile.lua"))
  local source = file:read("*a"); file:close()
  local trace = source:match("local hairpin_trace = %[%[(.-)%]%]")
  local path = {}
  for x, y in trace:gmatch("([%-%d%.]+),([%-%d%.]+)") do path[#path+1] = {position = point(tonumber(x), tonumber(y))} end
  local state, runtime = fixture(CAR, 1)
  local goal = {path = path}
  local smaller = runtime.vehicle_speed.trajectory(state.entity, path, 3, nil, goal, true)
  local larger = runtime.vehicle_speed.trajectory(state.entity, path, 4, nil, goal, true)
  assert(larger == smaller, "larger margin discarded the faster certified hairpin")
  local copy = {}
  for index, waypoint in ipairs(path) do copy[index] = {position = point(waypoint.position.x, waypoint.position.y)} end
  goal.path = copy
  local refreshed = runtime.vehicle_speed.trajectory(state.entity, copy, 4, nil, goal, true)
  assert(refreshed == smaller, "fresh pathfinder table lost the better certified reference")
  local env = setmetatable({prototypes = {tile = TILES}, require = require}, {__index = _G})
  local cold = assert(loadfile("scripts/vehicle-speed.lua", "t", env))()
  local context = runtime.vehicle_speed.create_context(state.entity)
  context.model.brake = context.model.brake*2
  collectgarbage("collect")
  assert(cold.trajectory(state.entity, copy, 4, context, goal) == smaller,
    "a cold script VM or changed braking model discarded the saved curve")
  local narrow = runtime.vehicle_speed.trajectory(state.entity, copy, 1, nil, goal, true)
  assert(narrow ~= larger, "a reduced allowance reused an uncertified wider curve")
  local changed = {}
  for index, waypoint in ipairs(path) do changed[index] = {position = point(waypoint.position.x, waypoint.position.y)} end
  changed[200].position.y = changed[200].position.y+.25
  goal.path = changed
  local different = runtime.vehicle_speed.trajectory(state.entity, changed, 4, nil, goal, true)
  assert(different ~= larger and different ~= narrow, "a different raw path reused stale geometry")
end)

for _, entry in ipairs(tests) do entry[2](); print("PASS " .. entry[1]) end
print(#tests .. " vehicle speed tests passed")
