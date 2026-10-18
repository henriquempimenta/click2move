-- Appended only to the isolated native test copy. Players/UI are mocked;
-- walls, pathfinding, driving, quality, fuel, collisions and positions are
-- native. Every vehicle is ordered by the production input handler to the end
-- of a walled corridor and must arrive without touching a wall or entering
-- stuck recovery. Measured speed floors and arrival deadlines also reject
-- controllers that pass by crawling. A legendary car on legendary nuclear
-- fuel reaches 1.25 tiles per tick on the long straight.
--   1: fast car, straight then a right-angle turn.
--   2: fast car, straight then a hairpin back along a parallel corridor.
--   3: fast car, straight then two right-angle turns (an S-bend).
--   4: tank on legendary nuclear fuel, straight then a right-angle turn.
--   5: car on coal, straight then a right-angle turn.
--   6: fast car, a 700-tile straight then a right-angle turn.
--   7: fast car facing the closed end of a corridor that leads the other way.
--   8-10: fast car facing east at the closed end of a corridor that leads
--      north, north-west or south, so it must turn slowly in a tight space
--      without being taken for stuck.
--   11-13: the same with a vehicle path margin of 0, which leaves the planner
--      no clearance: the car crawls through the turn, which once tripped the
--      stuck detector in a loop.
-- C2M_NATIVE_INTERVAL (1 or 10) is prepended by run.py.
local Config = require("scripts/config")
local Pathfinding = require("scripts/pathfinding")
local PlayerData = require("scripts/player-data")
local get_config = Config.get
local CASES
Config.get = function(index)
  local config = get_config(index and 0 or nil)
  local margin = index and CASES and CASES[index] and CASES[index][6]
  if margin == nil then return config end
  local copy = {}
  for key, value in pairs(config) do copy[key] = value end
  copy.vehicle_path_margin = margin
  return copy
end
local native_rendering = rendering
rendering = setmetatable({}, {__index = native_rendering})
for _, name in ipairs({"draw_line", "draw_text", "draw_circle"}) do
  rendering[name] = function(p) p.players = nil; return native_rendering[name](p) end
end
local completions = {}
local remove_goal = Pathfinding.remove_goal
Pathfinding.remove_goal = function(i, g, completed)
  completions[i] = (completions[i] or "") .. (completed and "C" or "F")
  return remove_goal(i, g, completed)
end

local HALF_WIDTH = 6
-- Corridor centrelines relative to each lane's origin; the destination is the last point.
local SHAPES = {
  turn = {{0, 0}, {300, 0}, {300, 50}},
  hairpin = {{0, 0}, {300, 0}, {300, 2 * HALF_WIDTH + 2}, {200, 2 * HALF_WIDTH + 2}},
  s_bend = {{0, 0}, {300, 0}, {300, 30}, {360, 30}},
  long_turn = {{0, 0}, {700, 0}, {700, 50}},
  turn_round = {{0, 0}, {-40, 0}},
  north = {{0, 0}, {0, -40}},
  north_west = {{0, 0}, {-28, -28}},
  south = {{0, 0}, {0, 40}},
}
-- {shape, vehicle, quality, fuel, fuel quality, vehicle path margin}
CASES = {
  {"turn", "car", "legendary", "nuclear-fuel", "legendary"},
  {"hairpin", "car", "legendary", "nuclear-fuel", "legendary"},
  {"s_bend", "car", "legendary", "nuclear-fuel", "legendary"},
  {"turn", "tank", "legendary", "nuclear-fuel", "legendary"},
  {"turn", "car", "normal", "coal", "normal"},
  {"long_turn", "car", "legendary", "nuclear-fuel", "legendary"},
  {"turn_round", "car", "legendary", "nuclear-fuel", "legendary"},
  {"north", "car", "legendary", "nuclear-fuel", "legendary"},
  {"north_west", "car", "legendary", "nuclear-fuel", "legendary"},
  {"south", "car", "legendary", "nuclear-fuel", "legendary"},
  {"north", "car", "legendary", "nuclear-fuel", "legendary", 0},
  {"north_west", "car", "legendary", "nuclear-fuel", "legendary", 0},
  {"south", "car", "legendary", "nuclear-fuel", "legendary", 0},
}
-- Passing native measurements before tightening the compound-turn planner.
-- Permit 25% plus half a second for simulation phase and controller tuning;
-- do not replace these baselines with the candidate's slower results.
local BASELINE_TICKS = {
  [1] = {581, 721, 616, 945, 1071, 938, 119, 189, 126, 189, 658, 203, 287},
  [10] = {588, 742, 658, 987, 1064, 938, 133, 203, 133, 203, 294, 210, 294}
}
local MIN_TOP_SPEED = {.90, .90, .90, .50, .35, 1.10, .35, .35, .35, .35, .35, .35, .35}

local function segment_distance(px, py, a, b)
  local dx, dy = b[1] - a[1], b[2] - a[2]
  local t = math.max(0, math.min(1, ((px - a[1]) * dx + (py - a[2]) * dy) / (dx * dx + dy * dy)))
  local x, y = a[1] + t * dx - px, a[2] + t * dy - py
  return math.sqrt(x * x + y * y)
end

-- One-tile walls around a corridor of HALF_WIDTH tiles either side of the centreline.
local function build_corridor(surface, ox, oy, line, walls)
  local points = {}
  for i, p in ipairs(line) do points[i] = {ox + p[1], oy + p[2]} end
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(points) do
    x1, y1, x2, y2 = math.min(x1, p[1]), math.min(y1, p[2]), math.max(x2, p[1]), math.max(y2, p[2])
  end
  for x = math.floor(x1) - HALF_WIDTH - 2, math.ceil(x2) + HALF_WIDTH + 2 do
    for y = math.floor(y1) - HALF_WIDTH - 2, math.ceil(y2) + HALF_WIDTH + 2 do
      local d = math.huge
      for i = 1, #points - 1 do d = math.min(d, segment_distance(x + .5, y + .5, points[i], points[i + 1])) end
      -- Close both ends too: they are farther than the half width from any segment interior.
      if d > HALF_WIDTH and d <= HALF_WIDTH + 1.5 then
        walls[#walls + 1] = surface.create_entity{name = "stone-wall", position = {x + .5, y + .5}, force = "player"}
      end
    end
  end
  return points[1], points[#points]
end

local native_game
local function bind()
  native_game = native_game or game
  local players = {}
  for i, case in ipairs(storage.probe.cases) do
    local top = {}
    top.add = function(spec)
      local f = {valid = true}
      f.add = function(c) f[c.name] = {valid = true}; return f[c.name] end
      f.destroy = function() f.valid = false; top[spec.name] = nil end
      top[spec.name] = f; return f
    end
    players[i] = {index = i, valid = true, connected = true, force = native_game.forces.player,
      surface = case.actor.surface, vehicle = case.actor, physical_vehicle = case.actor, character = case.driver,
      color = {r = 1, g = 0, b = 0}, gui = {top = top}, print = function() end,
      opened_gui_type = defines.gui_type.none, controller_type = defines.controllers.character,
      is_shortcut_toggled = function() return true end, set_shortcut_toggled = function() end}
  end
  game = setmetatable({players = players}, {__index = native_game})
end

local function setup()
  local s = game.create_surface("c2m-fast-cars", {width = 1024, height = 1024})
  s.request_to_generate_chunks({0, 0}, 15); s.force_generate_chunk_requests()
  for _, ent in pairs(s.find_entities()) do ent.destroy() end
  local t = {} for x = -460, 320 do for y = -420, 470 do t[#t + 1] = {name = "grass-1", position = {x, y}} end end
  s.set_tiles(t)
  storage.probe = {cases = {}, walls = {}, started = game.tick}
  for i, spec in ipairs(CASES) do
    -- Lanes 90 tiles apart; the last cases form a second column, clear of the first.
    local column, lane = i <= 10 and 0 or 1, i <= 10 and i - 1 or i - 11
    local start, goal = build_corridor(s, -400 + column * 600, -400 + lane * 90, SHAPES[spec[1]], storage.probe.walls)
    local driver = s.create_entity{name = "character", position = start, force = "player"}
    local actor = s.create_entity{name = spec[2], position = start, force = "player", quality = spec[3]}
    actor.orientation = .25
    actor.get_fuel_inventory().insert{name = spec[4], count = 5, quality = spec[5]}
    actor.set_driver(driver)
    storage.probe.cases[i] = {name = spec[2] .. " " .. i .. " (" .. spec[1] .. ")", actor = actor, driver = driver,
      goal = {x = goal[1], y = goal[2]}, health = actor.health, top = 0}
  end
  bind()
  settings.global["c2m-update-interval"] = {value = C2M_NATIVE_INTERVAL}
  Config.load()
  script.get_event_handler(defines.events.on_runtime_mod_setting_changed){setting = "c2m-update-interval"}
  local move = script.get_event_handler("c2m-move-command")
  for i, case in ipairs(storage.probe.cases) do
    move({player_index = i, input_name = "c2m-move-command", cursor_position = case.goal})
  end
end

script.on_nth_tick(7, function(e)
  if not storage.probe then setup(); return end
  if not native_game then bind() end
  local probe = storage.probe
  local data = PlayerData.get_all()
  for i, case in ipairs(probe.cases) do
    case.top = math.max(case.top, math.abs(case.actor.speed))
    local active = data[i]
    if active then
      assert(active.stuck_state == "none" and not active.goal_failed and not (active.goals[1] and active.goals[1].recovery_attempts),
        case.name .. " entered stuck recovery at tick " .. e.tick .. " x=" .. case.actor.position.x
          .. " y=" .. case.actor.position.y .. " speed=" .. case.actor.speed)
      assert(case.actor.health == case.health, case.name .. " hit a wall at tick " .. e.tick .. " x="
        .. case.actor.position.x .. " y=" .. case.actor.position.y .. " speed=" .. case.actor.speed)
    elseif not case.ticks then
      case.ticks = e.tick - probe.started
    end
  end
  if e.tick - probe.started < 5000 then return end
  for i, case in ipairs(probe.cases) do
    assert(completions[i] == "C", case.name .. " did not arrive: " .. tostring(completions[i]))
    assert(case.actor.health == case.health, case.name .. " hit a wall")
    assert(case.top >= MIN_TOP_SPEED[i], string.format("%s was too slow: peak %.3f, minimum %.3f",
      case.name, case.top, MIN_TOP_SPEED[i]))
    local deadline = math.ceil(BASELINE_TICKS[C2M_NATIVE_INTERVAL][i] * 1.25 + 30)
    assert(case.ticks and case.ticks <= deadline, string.format("%s took %s ticks, maximum %d",
      case.name, tostring(case.ticks), deadline))
    local dx, dy = case.actor.position.x - case.goal.x, case.actor.position.y - case.goal.y
    assert(dx * dx + dy * dy <= 7 ^ 2, case.name .. " stopped away from its destination")
  end
  for _, wall in ipairs(probe.walls) do
    assert(wall.valid and wall.health == wall.max_health, "a wall was damaged")
  end
  local report = {}
  for i, case in ipairs(probe.cases) do report[i] = string.format("%d:%.2f", case.ticks, case.top) end
  print(string.format("C2M_NATIVE_FAST_CARS_OK %d interval=%d ticks:top_speed=%s",
    #probe.cases, C2M_NATIVE_INTERVAL, table.concat(report, ",")))
  probe.started = math.huge
end)
