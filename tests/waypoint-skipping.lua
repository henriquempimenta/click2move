-- Run from the mod directory: lua tests/waypoint-skipping.lua
-- Positions below model observed engine motion. The actual production control,
-- movement, navigation, path callback, cancellation and braking handlers run.
local Fake = dofile("tests/support/fake-factorio.lua")
local function equal(actual, expected, reason)
  assert(actual == expected, (reason or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function point(x, y) return {x = x, y = y or 0} end
local function path(points)
  local result = {}
  for _, position in ipairs(points) do result[#result + 1] = {position = position} end
  return result
end
local function engine(kind, interval, speed)
  local state = {storage = {}, tick = 0, next_path = 0, requests = {}, kind = kind or "character", interval = interval or 1}
  state.surface = {index = 1, valid = true}
  state.surface.request_path = function(params)
    state.next_path = state.next_path + 1; state.requests[state.next_path] = params
    return state.next_path
  end
  local prototype = {collision_box = {left_top = point(-.2, -.2), right_bottom = point(.2, .2)}, collision_mask = {layers = {player = true}}}
  state.character = {valid = true, name = "character", type = "character", position = point(0), surface = state.surface,
    character_running_speed = speed or .5, prototype = prototype, walking_state = {walking = false, direction = 0}}
  state.character.get_inventory = Fake.armor_inventory(state)
  state.entity = state.character
  if state.kind ~= "character" then
    state.entity = {valid = true, name = state.kind == "hovercraft" and "hovercraft" or "car", type = "car",
      position = point(0), surface = state.surface, speed = speed or .2, orientation = .25, prototype = prototype,
      riding_state = {acceleration = 0, direction = 0}}
    state.driver = state.character
    state.entity.get_driver = function() return state.driver end
  end
  state.player = Fake.player(state, {character = state.character, surface = state.surface})
  if state.kind ~= "character" then state.player.vehicle, state.player.physical_vehicle = state.entity, state.entity end
  state.global_settings = {["c2m-update-interval"] = {value = state.interval}}
  state.player_settings = Fake.player_settings({
    ["c2m-character-margin"] = 0, ["c2m-character-proximity-threshold"] = .5,
    ["c2m-vehicle-proximity-threshold"] = 2, ["c2m-stuck-threshold"] = 120, ["c2m-vehicle-path-margin"] = 0
  })
  return state
end
local function vm(state)
  local runtime = Fake.vm(state)
  runtime.command = runtime.command_at
  runtime.result = function(id, points) runtime.events[2]({id = id, path = path(points)}) end
  runtime.tick = function(amount, position)
    if position then state.entity.position = point(position.x, position.y) end
    runtime.advance(amount or state.interval)
  end
  runtime.route = function(points)
    runtime.command(points[#points])
    local data = runtime.pd.get_all()[1]
    runtime.result(data.goals[1].path_id, points)
    return data
  end
  return runtime
end
local function fixture(kind, interval, speed)
  local state = engine(kind, interval, speed); local runtime = vm(state); runtime.init()
  return state, runtime
end
local function straight(sign)
  sign = sign or 1
  return {point(0), point(10 * sign), point(20 * sign), point(30 * sign), point(200 * sign)}
end
local function record_completions(runtime)
  local completions = {}
  local remove = runtime.pathfinding.remove_goal
  runtime.pathfinding.remove_goal = function(player_index, goal_index, completed)
    completions[#completions + 1] = completed
    return remove(player_index, goal_index, completed)
  end
  return completions
end
local function replace_driver(state)
  state.driver = {valid = true, type = "character", name = "character"}
  local input = {acceleration = 3, direction = 2}
  state.entity.riding_state = input
  state.entity.speed = .25
  return input
end
local tests = {}
local function test(name, body) tests[#tests + 1] = {name, body} end

for _, kind in ipairs({"character", "car", "hovercraft"}) do
  test(kind .. " consumes multiple observed straight intermediates and steers ahead immediately", function()
    local state, runtime = fixture(kind, 60, kind == "character" and .5 or .2)
    local data = runtime.route(straight())
    runtime.tick(60, point(0)); equal(data.current_waypoint, 2)
    runtime.tick(60, point(24))
    equal(data.current_waypoint, 4, "crossed nodes must not cause backtracking")
    equal(data.stuck_state, "none")
    if kind == "character" then equal(state.entity.walking_state.direction, 4)
    else equal(state.entity.riding_state.acceleration, 1) end
  end)
end

test("powered-speed characters steer and consume observed45-degree nodes in every quadrant", function()
  for _, diagonal in ipairs({{x = 1, y = 1, direction = 6}, {x = 1, y = -1, direction = 2},
      {x = -1, y = 1, direction = 10}, {x = -1, y = -1, direction = 14}}) do
    local state, runtime = fixture("character", 60, .6)
    local points = {}
    for _, distance in ipairs({0, 10, 20, 30, 200}) do points[#points + 1] = point(distance * diagonal.x, distance * diagonal.y) end
    local data = runtime.route(points)
    runtime.tick(60, point(0))
    equal(state.entity.walking_state.direction, diagonal.direction, "initial direction must follow the path corridor")
    runtime.tick(60, point(24 * diagonal.x, 24 * diagonal.y))
    equal(data.current_waypoint, 4)
    equal(state.entity.walking_state.direction, diagonal.direction, "consuming nodes must preserve diagonal direction")
  end
end)

test("fractional world coordinates preserve diagonal direction across subtraction roundoff", function()
  local from = point(40, -48)
  -- Generate a real fractional native path node. Rounding its coordinates to
  -- printed decimal text can hide the imbalance caused by subtraction.
  local offset = 80 * 55 / 227
  for _, target in ipairs({point(40 + offset, -48 + offset),
      point(40 + 80 / 227, -48 + 80 / 227 + .0000000001)}) do
    local state, runtime = fixture("character", 60, .6)
    local dx, dy = target.x - from.x, target.y - from.y
    assert(dy > dx and dy - dx < .0000001, "fixture must exercise a nearly equal direction tie after world-coordinate subtraction")
    equal(runtime.navigation.get_character_direction(from, target), 6,
      "roundoff must not turn a diagonal corridor into southward movement")
    state.entity.position = from
    local data = runtime.route({from, target, point(240, 152)})
    runtime.tick(60, from)
    equal(data.current_waypoint, 2)
    equal(state.entity.walking_state.direction, 6, "production movement must follow the fractional diagonal node")
  end
end)

test("character running bonuses permit observed movement without inventing forward travel", function()
  local state, runtime = fixture("character", 10, 2.5)
  local data = runtime.route(straight())
  runtime.tick(10, point(0)); runtime.tick(10, point(24))
  equal(data.current_waypoint, 4)
  local still = data.current_waypoint
  state.entity.character_running_speed = 20
  runtime.tick(10, point(24))
  assert(data.current_waypoint <= still + 1, "speed changes must not invent an additional observed sweep")
end)

test("fast character bonuses permit more than64 tiles of real movement at interval60", function()
  local state, runtime = fixture("character", 60, 1.2)
  local data = runtime.route(straight())
  runtime.tick(60, point(0)); runtime.tick(60, point(67.5))
  equal(data.current_waypoint, 5, "a fixed displacement cap must not reject legitimate boosted motion")
  equal(state.entity.walking_state.direction, 4)
  assert(runtime.pd.get_all()[1], "selecting a distant final node must preserve the route")
end)

test("character speed loss at the next sample cannot invalidate travel observed before the loss", function()
  for _, reload in ipairs({false, true}) do
    local state, runtime = fixture("character", 10, 2.5)
    local data = runtime.route(straight())
    runtime.tick(10, point(0))
    -- An exoskeleton power or terrain change can reduce the current engine speed
    -- after the actor already travelled most of the interval at the old speed.
    state.entity.character_running_speed = .5
    if reload then
      runtime = vm(state); runtime.env.game = nil; runtime.load()
      runtime.env.game = {tick = state.tick, players = {[1] = state.player}}
    end
    runtime.tick(10, point(24))
    equal(data.current_waypoint, 4, "old valid speed must bound the preceding observed interval")
    equal(state.entity.walking_state.direction, 4)
  end
end)

test("scripted lateral hovercraft drift advances despite zero native speed and a perpendicular heading", function()
  local state, runtime = fixture("hovercraft", 60, 0)
  state.entity.orientation = 0
  local data = runtime.route(straight())
  runtime.tick(60, point(0)); runtime.tick(60, point(24))
  equal(data.current_waypoint, 4)
  equal(data.stuck_state, "none")
end)

test("reverse vehicle travel uses observed displacement rather than forward heading", function()
  local state, runtime = fixture("car", 60, -.2)
  local data = runtime.route(straight(-1))
  runtime.tick(60, point(0)); runtime.tick(60, point(-24))
  equal(data.current_waypoint, 4)
  equal(state.entity.riding_state.acceleration, 3)
end)

test("forward speed cannot predictively consume an unpassed intermediate", function()
  local state, runtime = fixture("car", 20, .25)
  local data = runtime.route(straight())
  runtime.tick(20, point(0)); runtime.tick(20, point(5))
  equal(data.current_waypoint, 2)
  equal(state.entity.riding_state.acceleration, 1)
end)

for _, corner in ipairs({{name = "sharp", next = point(20, 10)}, {name = "gentle", next = point(30, 3)},
    {name = "small-angle", next = point(30, .05)}}) do
  test(corner.name .. " route corner remains active after crossing the straight incoming leg", function()
    for _, kind in ipairs({"character", "car", "hovercraft"}) do
      local state, runtime = fixture(kind, 60, kind == "character" and .5 or 0)
      -- Obstacles occupy the shortcut from (24,0) to the outgoing waypoint;
      -- retaining (20,0) keeps the controller on the original corner route.
      if corner.name ~= "small-angle" then
        state.surface.obstacles = corner.name == "sharp" and {{left_top = point(22.9, 2.4), right_bottom = point(23.1, 2.6)}}
          or {{left_top = point(25.9, .8), right_bottom = point(26.1, 1.2)}}
        local obstacle = state.surface.obstacles[1]
        local center = point((obstacle.left_top.x + obstacle.right_bottom.x) / 2,
          (obstacle.left_top.y + obstacle.right_bottom.y) / 2)
        local dx, dy = corner.next.x - 24, corner.next.y
        local cross = math.abs((center.x - 24) * dy - center.y * dx)
        assert(cross < .1, "fixture obstacle must obstruct the unsafe outgoing shortcut")
        local original_dx, original_dy = corner.next.x - 20, corner.next.y
        local original_cross = math.abs((center.x - 20) * original_dy - center.y * original_dx)
        assert(original_cross / math.sqrt(original_dx ^ 2 + original_dy ^ 2) > .3,
          "fixture obstacle must leave the original outgoing corridor clear")
      end
      local data = runtime.route({point(0), point(10), point(20), corner.next, point(200, corner.next.y)})
      runtime.tick(60, point(0)); runtime.tick(60, point(24))
      equal(data.current_waypoint, 3, kind .. " must retain the corner")
    end
  end)
end

test("sharp and gentle corners after a diagonal incoming corridor stay explicit", function()
  for _, outgoing in ipairs({point(30, 10), point(30, 29)}) do
    for _, kind in ipairs({"character", "car", "hovercraft"}) do
      local state, runtime = fixture(kind, 60, kind == "character" and .6 or 0)
      local data = runtime.route({point(0), point(10, 10), point(20, 20), outgoing, point(200, outgoing.y)})
      runtime.tick(60, point(0)); runtime.tick(60, point(24, 24))
      equal(data.current_waypoint, 3, "a diagonal approach cannot validate the next corner")
    end
  end
end)

test("sideways corridor deviation and a path U-turn reject swept advancement", function()
  local state, runtime = fixture("hovercraft", 60, 0)
  local data = runtime.route(straight())
  runtime.tick(60, point(0)); runtime.tick(60, point(24, 2))
  equal(data.current_waypoint, 2, "off-corridor displacement is not proof of passing the route")
  data = runtime.route({point(0), point(10), point(20), point(10), point(-200)})
  runtime.tick(60, point(0)); runtime.tick(60, point(24))
  equal(data.current_waypoint, 3, "same line in the opposite direction is a corner")
end)

test("vehicle arrival radius cannot widen the corridor used as movement evidence", function()
  local state, runtime = fixture("hovercraft", 60, 0)
  local data = runtime.route(straight())
  state.player_settings["c2m-vehicle-proximity-threshold"].value = 6
  runtime.events[6]({setting = "c2m-vehicle-proximity-threshold", player_index = 1})
  data.current_waypoint = 2
  runtime.tick(60, point(5, 5)); equal(data.current_waypoint, 2)
  runtime.tick(60, point(15, 5)); equal(data.current_waypoint, 2,
    "offset5 must remain outside the straight corridor even with radius6")
end)

test("very long segments do not turn a real corner into an apparently negligible angle", function()
  local state, runtime = fixture("car", 60, 0)
  local data = runtime.route({point(0), point(1000000), point(2000000, .5), point(3000000, .5)})
  data.current_waypoint = 2
  state.entity.position = point(999999)
  runtime.navigation.advance_waypoints(data, state.entity, data.goals[1].path, .000001, 60)
  state.entity.position = point(1000001)
  runtime.navigation.advance_waypoints(data, state.entity, data.goals[1].path, .000001, 120)
  equal(data.current_waypoint, 2, "relative angle tolerance must not permit a half-tile deviation")
end)

test("character final arrival uses the requested goal and cannot be swept away", function()
  local state, runtime = fixture("character", 60, 1)
  local data = runtime.route({point(0), point(10), point(20), point(30)})
  runtime.tick(60, point(0)); runtime.tick(60, point(34))
  equal(data.current_waypoint, 4)
  assert(runtime.pd.get_all()[1], "crossing the final point cannot finish outside the goal radius")
  equal(state.entity.walking_state.direction, 12)
  runtime.tick(60, point(30))
  equal(runtime.pd.get_all()[1], nil)
end)

test("the requested destination remains authoritative when the final path node differs", function()
  for _, kind in ipairs({"character", "car", "hovercraft"}) do
    local state, runtime = fixture(kind, 60, kind == "character" and .5 or 0)
    runtime.command(point(40))
    local data = runtime.pd.get_all()[1]
    runtime.result(data.goals[1].path_id, {point(0), point(10), point(20), point(30)})
    runtime.tick(60, point(0)); runtime.tick(60, point(30))
    equal(data.current_waypoint, 4)
    assert(runtime.pd.get_all()[1], kind .. " must not finish at the path endpoint")
    if kind == "character" then equal(state.entity.walking_state.direction, 4)
    else equal(state.entity.riding_state.acceleration, 1) end
  end
end)

test("far single-node character routes retain regular updates until the final arrival horizon", function()
  local state, runtime = fixture("character", 60, .5)
  local data = runtime.route({point(100)})
  for _, x in ipairs({0, 30, 60}) do
    runtime.tick(60, point(x))
    equal(data.current_waypoint, 1)
    equal(state.entity.walking_state.direction, 4)
    assert(not data.character_arrival and not runtime.events[1],
      "a far final node must not turn the whole route into every-tick work")
  end
  runtime.tick(60, point(75))
  assert(data.character_arrival and runtime.events[1], "approach must switch before the next full interval can cross the goal")
  local x = 75
  for _ = 1, 52 do
    if not runtime.pd.get_all()[1] then break end
    x = x + .5; runtime.tick(1, point(x))
  end
  assert(not runtime.pd.get_all()[1], "continuous final approach failed to complete")
  assert(math.abs(x - 100) <= 1.25, "final approach completed outside the actual destination radius")
  assert(not runtime.events[1], "completed final approach must release continuous updates")
  equal(state.entity.walking_state.walking, false)
end)

test("powered mech flight completes queued final approaches at interval60 across a fresh load", function()
  local state, runtime = fixture("character", 60, 1.125)
  state.flying = true
  runtime.command(point(80)); runtime.command(point(160), true)
  local data = runtime.pd.get_all()[1]
  local queued = data.goals[2]
  runtime.tick(60, point(0))
  assert(not data.character_arrival and not runtime.events[1])
  runtime.tick(60, point(67.5))
  assert(data.character_arrival and runtime.events[1], "flight must check arrival before the next long update overshoots")
  runtime = vm(state); runtime.env.game = nil; runtime.load()
  runtime.env.game = {tick = state.tick, players = {[1] = state.player}}
  assert(runtime.events[1], "load must restore the flight arrival subscription")
  local completions = record_completions(runtime)
  local x = 67.5
  for _ = 1, 15 do
    if #data.goals == 1 then break end
    x = x + 1.125; runtime.tick(1, point(x))
  end
  equal(#data.goals, 1)
  equal(data.goals[1], queued)
  equal(completions[1], true, "the first flight goal must complete instead of being abandoned")
  assert(math.abs(x - 80) <= 2.1875)
  assert(data.is_straight_line_move and not data.character_arrival)
  equal(data.waypoint_motion, nil)
  equal(state.next_path, 0)
  runtime.tick(state.interval - state.tick % state.interval, point(x))
  runtime.tick(60, point(x + 67.5)); x = x + 67.5
  assert(data.character_arrival and runtime.events[1])
  for _ = 1, 15 do
    if not runtime.pd.get_all()[1] then break end
    x = x + 1.125; runtime.tick(1, point(x))
  end
  equal(runtime.pd.get_all()[1], nil)
  equal(completions[2], true)
  assert(math.abs(x - 160) <= 2.1875)
  equal(state.entity.walking_state.walking, false)
  assert(not runtime.events[1])
end)

test("minimum flight proximity cannot cause a high-speed half-step arrival oscillation", function()
  local state, runtime = fixture("character", 60, 1.125)
  state.flying = true
  runtime.command(point(80.4375))
  local completions = record_completions(runtime)
  runtime.tick(60, point(0)); runtime.tick(60, point(67.5))
  local x = 67.5
  for _ = 1, 15 do
    if not runtime.pd.get_all()[1] then break end
    x = x + 1.125; runtime.tick(1, point(x))
  end
  equal(runtime.pd.get_all()[1], nil, "a final point between discrete walking samples must still finish")
  equal(completions[1], true)
  assert(math.abs(x - 80.4375) <= 2.1875)
  assert(math.abs(x - 80.4375) >= .5625, "fixture must remain outside the original fixed .5 radius")
  equal(state.entity.walking_state.walking, false)
end)

test("slow flight makes cumulative progress under continuous final checks without false stuck recovery", function()
  local state, runtime = fixture("character", 60, .01)
  state.flying = true
  state.player_settings["c2m-stuck-threshold"].value = 5
  runtime.events[6]({setting = "c2m-stuck-threshold", player_index = 1})
  runtime.command(point(.8))
  local completions = record_completions(runtime)
  runtime.tick(60, point(0))
  local x = 0
  for _ = 1, 40 do
    if not runtime.pd.get_all()[1] then break end
    x = x + .01; runtime.tick(1, point(x))
  end
  equal(runtime.pd.get_all()[1], nil)
  equal(completions[1], true, "sub-.03 per-tick progress must accumulate rather than time out")
  assert(math.abs(x - .8) <= .515)
end)

test("continuous flight checks still abandon genuine stationary jitter after the configured timeout", function()
  local state, runtime = fixture("character", 60, .01)
  state.flying = true
  state.player_settings["c2m-stuck-threshold"].value = 5
  runtime.events[6]({setting = "c2m-stuck-threshold", player_index = 1})
  runtime.command(point(.8))
  local completions = record_completions(runtime)
  runtime.tick(60, point(0))
  for index = 1, 10 do
    if not runtime.pd.get_all()[1] then break end
    runtime.tick(1, point(index % 2 * .005))
  end
  equal(runtime.pd.get_all()[1], nil)
  equal(completions[1], false, "small stationary jitter must not indefinitely hide a stalled route")
  equal(state.entity.walking_state.walking, false)
end)

test("hovercraft final waypoint retains braking and queue ownership until drift settles", function()
  local state, runtime = fixture("hovercraft", 10, .2)
  local data = runtime.route({point(0), point(10), point(20), point(30)})
  runtime.command(point(100), true)
  local queued = data.goals[2]
  runtime.result(queued.path_id, {point(30), point(50), point(100)})
  runtime.tick(10, point(0)); runtime.tick(10, point(29))
  equal(data.current_waypoint, 4)
  assert(data.vehicle_arrival and #data.goals == 2)
  equal(state.entity.riding_state.acceleration, 2)
  state.entity.speed = 0
  for index = 1, 15 do runtime.tick(1, point(29 + index * .01, .1)) end
  equal(#data.goals, 2, "scripted movement must delay completion even at native speed zero")
  for _ = 1, 12 do runtime.tick(1, point(30)) end
  equal(#data.goals, 1)
  equal(data.goals[1], queued)
  equal(data.current_waypoint, 1)
  runtime.tick(state.interval - state.tick % state.interval, point(30))
  assert(data.current_waypoint <= 2, "old motion cannot consume a successor route")
end)

for _, discontinuity in ipairs({"path", "entity", "surface", "index", "time-gap", "teleport", "same-tick"}) do
  test(discontinuity .. " discontinuity discards motion evidence", function()
    local state, runtime = fixture("car", 60, 0)
    local data = runtime.route(straight())
    runtime.tick(60, point(0))
    local elapsed = 60
    if discontinuity == "path" then
      data.goals[1].path = path(straight())
    elseif discontinuity == "entity" then
      local replacement = {}; for key, value in pairs(state.entity) do replacement[key] = value end
      state.entity = replacement; state.player.vehicle = replacement; state.player.physical_vehicle = replacement; data.move_entity = replacement
    elseif discontinuity == "surface" then
      state.entity.surface = {index = 2, valid = true}
    elseif discontinuity == "index" then
      data.current_waypoint = 3
    elseif discontinuity == "time-gap" then elapsed = 120
    elseif discontinuity == "teleport" then elapsed = 1
    elseif discontinuity == "same-tick" then elapsed = 0 end
    state.entity.position = discontinuity == "teleport" and point(100) or point(24)
    state.tick = state.tick + elapsed; runtime.env.game.tick = state.tick
    local before = data.current_waypoint
    runtime.movement.handle_vehicle(1, data, state.player, state.entity)
    equal(data.current_waypoint, before, "untrusted sample must not consume passed-looking points")
  end)
end

test("a physical surface change cancels the whole route and releases input for every actor", function()
  for _, kind in ipairs({"character", "car", "hovercraft"}) do
    local state, runtime = fixture(kind, 60, kind == "character" and .5 or 0)
    local data = runtime.route(straight())
    runtime.command(point(300), true)
    runtime.tick(60, point(0))
    local old_request = data.goals[2].path_id
    state.entity.surface = {valid = true, index = 2}
    runtime.tick(60, point(24))
    equal(runtime.pd.get_all()[1], nil, "coordinates from another surface must not continue controlling the actor")
    assert(not next(state.storage.c2m_path_requests))
    if kind == "character" then equal(state.entity.walking_state.walking, false)
    else equal(state.entity.riding_state.acceleration, 2) end
    runtime.result(old_request, {point(200), point(300)})
    equal(runtime.pd.get_all()[1], nil, "a delayed old-surface callback must not recreate the route")
  end
end)

test("passenger commands cannot start a car or hovercraft route or change the driver's input", function()
  for _, kind in ipairs({"car", "hovercraft"}) do
    local state, runtime = fixture(kind, 60, .2)
    local input = replace_driver(state)
    runtime.command(point(200))
    equal(runtime.pd.get_all()[1], nil)
    equal(state.next_path, 0)
    equal(state.entity.riding_state, input)
    equal(state.entity.speed, .25)
  end
end)

test("car ownership accepts LuaPlayer and remote character driver identities", function()
  for _, representation in ipairs({"player", "remote character"}) do
    local state, runtime = fixture("car", 60, .2)
    if representation == "player" then state.driver = state.player
    else
      state.character.object_name = "LuaEntity"; state.character.player = state.player
      state.player.character = nil; state.player.controller_type = 2
    end
    local data = runtime.route(straight())
    runtime.tick(60, point(0)); runtime.tick(60, point(24))
    equal(runtime.pd.get_all()[1], data)
    equal(data.current_waypoint, 4)
    equal(state.entity.riding_state.acceleration, 1)
  end
end)

test("an active driver handoff cancels the old route without braking the replacement driver", function()
  for _, kind in ipairs({"car", "hovercraft"}) do
    local state, runtime = fixture(kind, 60, .2)
    runtime.route(straight()); runtime.tick(60, point(0))
    local input = replace_driver(state)
    runtime.tick(60, point(24))
    equal(runtime.pd.get_all()[1], nil)
    equal(state.entity.riding_state, input)
    equal(state.entity.speed, .25)
  end
end)

test("a pending path callback cannot seize a vehicle after the driver changes", function()
  local state, runtime = fixture("car", 60, .2)
  runtime.command(point(200))
  local goal = runtime.pd.get_all()[1].goals[1]
  local request = goal.path_id
  local input = replace_driver(state)
  runtime.result(request, straight())
  equal(runtime.pd.get_all()[1], nil)
  equal(goal.path, nil)
  equal(state.entity.riding_state, input)
  equal(state.entity.speed, .25)
  assert(not next(state.storage.c2m_path_requests))
end)

test("an old owner's callback preserves a new player's route, pending request and vehicle input", function()
  for _, kind in ipairs({"car", "hovercraft"}) do
    local state, runtime = fixture(kind, 60, .2)
    runtime.command(point(200))
    local old_data = runtime.pd.get_all()[1]
    local old_request = old_data.goals[1].path_id
    local second = {}
    for key, value in pairs(state.player) do second[key] = value end
    second.index = 2; second.object_name = "LuaPlayer"; second.gui = {top = Fake.gui()}
    second.character = {valid = true, type = "character", position = point(0), surface = state.surface}
    runtime.env.game.players[2] = second
    state.driver = second
    runtime.events["c2m-move-command"]({player_index = 2, input_name = "c2m-move-command", cursor_position = point(300)})
    local new_data = assert(runtime.pd.get_all()[2], "new driver must receive an independent route")
    equal(new_data.owner_index, 2)
    local new_goal = new_data.goals[1]
    local new_request = assert(new_goal.path_id)
    local new_rendering = new_goal.rendering
    local input = {acceleration = 1, direction = 2}
    state.entity.riding_state = input
    state.entity.speed = .25
    runtime.result(old_request, straight())
    equal(runtime.pd.get_all()[1], nil)
    equal(runtime.pd.get_all()[2], new_data, "old callback must remove only its own player's state")
    equal(state.entity.riding_state, input)
    equal(state.entity.speed, .25)
    local association = assert(state.storage.c2m_path_requests[new_request], "old cleanup must retain the new pending request")
    equal(association.player_index, 2)
    equal(association.data, new_data)
    equal(association.goal, new_goal)
    for _, object in ipairs(new_rendering.markers) do assert(object.valid, "old cleanup destroyed the new route's rendering") end
    runtime.result(new_request, {point(0), point(150), point(300)})
    equal(runtime.pd.get_all()[2], new_data)
    assert(new_goal.path and new_goal.path[3].position.x == 300, "new callback must attach its own path after old-owner cleanup")
    equal(state.storage.c2m_path_requests[new_request], nil)
    equal(state.entity.riding_state, input)
  end
end)

test("continuous pending-path brakes yield to a replacement driver before the next interval", function()
  local state, runtime = fixture("hovercraft", 60, .2)
  runtime.command(point(200))
  assert(runtime.events[1], "waiting vehicles must originally receive continuous braking updates")
  local input = replace_driver(state)
  runtime.tick(1, point(0))
  equal(runtime.pd.get_all()[1], nil)
  equal(state.entity.riding_state, input)
  equal(state.entity.speed, .25)
  assert(not runtime.events[1])
end)

for _, action in ipairs({"manual input", "cancel command", "GUI cancel", "seat event", "disconnect", "migration", "path invalidation"}) do
  test(action .. " clears stale driver ownership without changing replacement vehicle input", function()
    local state, runtime = fixture("car", 60, .2)
    runtime.route(straight()); runtime.tick(60, point(0))
    local input = replace_driver(state)
    if action == "manual input" then
      runtime.events["c2m-manual-move-left"]({player_index = 1})
    elseif action == "cancel command" then
      runtime.events["c2m-cancel-command"]({player_index = 1, input_name = "c2m-cancel-command"})
    elseif action == "GUI cancel" then
      runtime.events[3]({player_index = 1, element = {valid = true, name = "c2m_cancel_button"}})
    elseif action == "seat event" then
      runtime.events[7]({player_index = 1})
    elseif action == "disconnect" then
      state.player.connected = false; runtime.tick(60, point(0))
    elseif action == "migration" then runtime.migrate()
    elseif action == "path invalidation" then
      runtime.pathfinding.invalidate_goal(1)
      equal(state.entity.riding_state, input)
      runtime.pathfinding.request_paths_for_player(1, true)
    end
    equal(runtime.pd.get_all()[1], nil)
    equal(state.entity.riding_state, input)
    equal(state.entity.speed, .25)
  end)
end

test("disconnect still brakes the owned car when the offline character is only available through its driver", function()
  local state, runtime = fixture("car", 60, .2)
  runtime.route(straight()); runtime.tick(60, point(0))
  state.character.object_name = "LuaEntity"; state.character.player = state.player
  state.player.character = nil; state.player.connected = false
  state.entity.riding_state = {acceleration = 1, direction = 0}
  runtime.tick(60, point(0))
  equal(runtime.pd.get_all()[1], nil)
  equal(state.entity.riding_state.acceleration, 2)
end)

test("remote camera surface changes preserve the actor's physical route", function()
  for _, kind in ipairs({"character", "car", "hovercraft"}) do
    local state, runtime = fixture(kind, 60, kind == "character" and .5 or 0)
    local data = runtime.route(straight())
    runtime.tick(60, point(0))
    state.player.controller_type = 2
    state.player.surface = {valid = true, index = 2}
    runtime.tick(60, point(24))
    equal(runtime.pd.get_all()[1], data)
    equal(data.current_waypoint, 4)
    equal(data.route_surface_index, 1)
  end
end)

test("a delayed path result cancels a physically transferred actor before any movement tick", function()
  local state, runtime = fixture("character", 60, .5)
  runtime.command(point(200))
  local data = runtime.pd.get_all()[1]
  local goal = data.goals[1]
  local request = goal.path_id
  state.entity.walking_state = {walking = true, direction = 4}
  state.entity.surface = {valid = true, index = 2}
  runtime.result(request, straight())
  equal(runtime.pd.get_all()[1], nil)
  equal(goal.path, nil, "the callback must not attach an old-surface path")
  equal(state.entity.walking_state.walking, false)
  assert(not next(state.storage.c2m_path_requests))
end)

test("migration recovers the original surface from saved rendering before checking a transferred actor", function()
  local state, runtime = fixture("character", 60, .5)
  local data = runtime.route(straight())
  runtime.tick(60, point(0))
  equal(data.goals[1].rendering.surface.index, 1)
  data.route_surface_index = nil
  state.entity.surface = {valid = true, index = 2}
  runtime.migrate()
  equal(runtime.pd.get_all()[1], nil)
  equal(state.entity.walking_state.walking, false)
end)

test("migration safely cancels a route whose saved rendering surface has been deleted", function()
  local state, runtime = fixture("character", 60, .5)
  local data = runtime.route(straight())
  runtime.tick(60, point(0))
  data.route_surface_index = nil
  data.goals[1].rendering.surface = setmetatable({valid = false}, {
    __index = function(_, name) if name == "index" then error("deleted LuaSurface index was accessed") end end})
  runtime.migrate()
  equal(runtime.pd.get_all()[1], nil)
  equal(state.entity.walking_state.walking, false)
end)

test("fresh module load preserves valid history but stationary reload cannot fabricate skipped nodes", function()
  local state, runtime = fixture("car", 60, 0)
  local data = runtime.route(straight())
  equal(data.owner_index, 1, "saved ownership must use the numeric player index")
  runtime.tick(60, point(0))
  local reloaded = vm(state); reloaded.env.game = nil; reloaded.load()
  equal(reloaded.pd.get_all()[1].owner_index, 1, "fresh load must retain the persistent driver identity")
  reloaded.env.game = {tick = state.tick, players = {[1] = state.player}}
  reloaded.tick(60, point(0)); equal(data.current_waypoint, 2)
  reloaded.tick(60, point(24)); equal(data.current_waypoint, 4)
end)

test("reset, recovery, manual takeover and flight leave no reusable ground sweep", function()
  local state, runtime = fixture("character", 60, .5)
  local data = runtime.route(straight()); runtime.tick(60, point(0))
  assert(data.waypoint_motion)
  runtime.pd.reset_movement_state(data)
  equal(data.waypoint_motion, nil)
  data.current_waypoint = 2
  runtime.tick(60, point(24)); equal(data.current_waypoint, 2)
  data.closest_dist_to_goal, data.no_progress_ticks, data.last_progress_tick = 0, 240, state.tick
  runtime.tick(60, point(24))
  equal(data.stuck_state, "sliding", "fixture must enter actual production recovery")
  equal(data.waypoint_motion, nil)
  runtime.tick(1, point(25))
  equal(data.waypoint_motion, nil)
  state.entity.walking_state = {walking = true, direction = 12}
  runtime.events["c2m-manual-move-left"]({player_index = 1})
  equal(runtime.pd.get_all()[1], nil)
  equal(data.waypoint_motion, nil)
  equal(state.entity.walking_state.direction, 12)
  data = runtime.route(straight())
  runtime.tick(state.interval - state.tick % state.interval, point(0))
  state.flying = true; runtime.command(point(300), true)
  equal(data.waypoint_motion, nil); assert(data.is_straight_line_move)
  state.entity.position = point(24); state.flying = false
  runtime.tick(state.interval - state.tick % state.interval)
  equal(data.waypoint_motion, nil)
  assert(data.goals[1].path_id and not data.is_straight_line_move)
end)

test("bounded scans drain continuously while stopping input instead of steering toward consumed nodes", function()
  local state, runtime = fixture("car", 60, 0)
  local points = {}
  for index = 0, 230 do points[#points + 1] = point(index / 10) end
  points[#points + 1] = point(30)
  points[#points + 1] = point(200)
  local data = runtime.route(points)
  runtime.tick(60, point(0)); runtime.tick(60, point(24))
  assert(data.waypoint_scan_pending, "dense crossed nodes must defer bounded work")
  equal(state.entity.riding_state.acceleration, 2)
  assert(runtime.events[1], "pending scan must register continuous updates")
  local iterations = 0
  while data.waypoint_scan_pending do
    runtime.tick(1, point(24)); iterations = iterations + 1
    assert(iterations < 30, "saved sweep never finished draining")
    if data.waypoint_scan_pending then equal(state.entity.riding_state.acceleration, 2) end
  end
  assert(data.current_waypoint > 230 and data.current_waypoint < #points,
    "bounded continuation lost its original observed crossing evidence")
  equal(state.entity.riding_state.acceleration, 1)
  assert(not runtime.events[1], "completed scan must release the extra tick subscription")
end)

test("load resumes a bounded character sweep and cancellation clears the retained proof", function()
  local state, runtime = fixture("character", 60, .5)
  local points = {}
  for index = 0, 230 do points[#points + 1] = point(index / 10) end
  points[#points + 1] = point(30); points[#points + 1] = point(200)
  local data = runtime.route(points)
  runtime.tick(60, point(0)); runtime.tick(60, point(24))
  assert(data.waypoint_scan_pending and data.waypoint_motion.sweep_start)
  equal(state.entity.walking_state.walking, false)
  local reloaded = vm(state); reloaded.env.game = nil; reloaded.load()
  reloaded.env.game = {tick = state.tick, players = {[1] = state.player}}
  assert(reloaded.events[1], "load must restore the pending scan subscription without accessing game")
  local iterations = 0
  while data.waypoint_scan_pending do
    reloaded.tick(1, point(24)); iterations = iterations + 1
    assert(iterations < 30)
    if data.waypoint_scan_pending then equal(state.entity.walking_state.walking, false) end
  end
  assert(data.current_waypoint > 230 and data.current_waypoint < #points)
  equal(state.entity.walking_state.direction, 4)
  assert(not reloaded.events[1], "a distant final target must not preserve scan subscriptions")
  reloaded.events["c2m-cancel-command"]({player_index = 1, input_name = "c2m-cancel-command"})
  equal(reloaded.pd.get_all()[1], nil)
  equal(data.waypoint_motion, nil)
  equal(data.waypoint_scan_pending, nil)
  equal(state.entity.walking_state.walking, false)
end)

test("lateral drift during a bounded scan cannot erase an already observed straight sweep", function()
  local state, runtime = fixture("hovercraft", 60, 0)
  local points = {}
  for x = 0, 300 do points[#points + 1] = point(x) end
  local data = runtime.route(points)
  runtime.tick(60, point(0)); runtime.tick(60, point(24))
  equal(data.current_waypoint, 18)
  assert(data.waypoint_scan_pending)
  equal(state.entity.riding_state.acceleration, 2)
  runtime.tick(1, point(24, .02))
  equal(data.current_waypoint, 26, "a saved crossing remains proven when later drift leaves its corridor")
  assert(not data.waypoint_scan_pending)
  assert(data.goals[1].path[data.current_waypoint].position.x > state.entity.position.x,
    "losing frozen proof would steer back toward already consumed nodes")
  equal(state.entity.riding_state.acceleration, 1)
end)

test("a full budget spent on saved proof retains the independently crossed newer segment", function()
  local state, runtime = fixture("hovercraft", 60, 0)
  local points = {}
  for index = 0, 100 do points[#points + 1] = point(index / 10) end
  points[#points + 1] = point(20)
  local data = runtime.route(points)
  for _, sample in ipairs({{tick = 60, x = 0}, {tick = 120, x = 6.45}, {tick = 121, x = 6.35},
      {tick = 122, x = 6.4}, {tick = 123, x = 7.1}}) do
    state.entity.position = point(sample.x)
    runtime.navigation.advance_waypoints(data, state.entity, data.goals[1].path, .000001, sample.tick)
  end
  assert(data.waypoint_scan_pending, "newly crossed nodes must remain pending when old proof uses the entire budget")
  local tick = 123
  while data.waypoint_scan_pending do
    tick = tick + 1
    assert(tick < 130, "independent newer sweep was lost while draining")
    runtime.navigation.advance_waypoints(data, state.entity, data.goals[1].path, .000001, tick)
  end
  assert(data.goals[1].path[data.current_waypoint].position.x > 7.1,
    "a spent scan budget must not make the controller return to the newer crossed segment")
end)

test("overlapping forward motion survives a denser saved backlog and a small reversal", function()
  local state, runtime = fixture("hovercraft", 60, 0)
  local points = {}
  for index = 0, 200 do points[#points + 1] = point(index / 20) end
  points[#points + 1] = point(20)
  local data = runtime.route(points)
  for _, sample in ipairs({{tick = 60, x = 0}, {tick = 120, x = 6.45}, {tick = 121, x = 6.35},
      {tick = 122, x = 6.4}, {tick = 123, x = 6.6}, {tick = 124, x = 6.8}, {tick = 125, x = 7.1}}) do
    state.entity.position = point(sample.x)
    runtime.navigation.advance_waypoints(data, state.entity, data.goals[1].path, .000001, sample.tick)
  end
  assert(data.waypoint_scan_pending, "dense backlog must still be drained within bounded updates")
  local tick = 125
  while data.waypoint_scan_pending do
    tick = tick + 1
    assert(tick < 140, "overlapping observed segments failed to finish")
    runtime.navigation.advance_waypoints(data, state.entity, data.goals[1].path, .000001, tick)
  end
  assert(data.goals[1].path[data.current_waypoint].position.x > 7.1,
    "new forward travel after reversal must extend old evidence while the backlog is large")
end)

test("long paths have bounded node inspection and never consume the final index", function()
  local state, runtime = fixture("car", 60, 0)
  local data = runtime.route(straight())
  local values = {}
  for index = 1, 10000 do values[index] = {position = point((index - 1) / 100)} end
  local reads = 0
  local proxy = setmetatable({}, {__len = function() return #values end,
    __index = function(_, key) reads = reads + 1; return values[key] end})
  data.current_waypoint = 1
  state.entity.position = point(0)
  runtime.navigation.advance_waypoints(data, state.entity, proxy, .000001, 60)
  reads = 0
  state.entity.position = point(24)
  local advanced = runtime.navigation.advance_waypoints(data, state.entity, proxy, .000001, 120)
  assert(advanced <= 16 and reads <= 512, "a single update performed unbounded work")
  assert(data.current_waypoint <= 18 and data.current_waypoint < #proxy)
  data.current_waypoint = #proxy
  runtime.navigation.advance_waypoints(data, state.entity, proxy, 1000000, 180)
  equal(data.current_waypoint, #proxy)
end)

for _, entry in ipairs(tests) do entry[2](); print("PASS " .. entry[1]) end
print(#tests .. " waypoint skipping tests passed")
