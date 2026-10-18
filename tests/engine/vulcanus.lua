-- Appended only to the isolated native test copy. Players/UI are mocked;
-- Vulcanus terrain, cliffs, rocks, lava, pathfinding, driving and collisions
-- are native. A legendary car on legendary nuclear fuel is ordered by the
-- production input handler between points about 80 tiles apart at 64 sites,
-- one route at a time, so test cars never meet or block each other's paths.
-- Cliffs stop a car without damaging it, so a sudden loss of speed counts as
-- a bump. Routes the pathfinder cannot reach without destroying rocks, or at
-- all, are counted separately; every other route must arrive without damage,
-- bumps or stuck recovery. C2M_NATIVE_INTERVAL is prepended by run.py.
local Config = require("scripts/config")
local Pathfinding = require("scripts/pathfinding")
local PlayerData = require("scripts/player-data")
local get_config = Config.get
Config.get = function(index) return get_config(index and 0 or nil) end
local native_rendering = rendering
rendering = setmetatable({}, {__index = native_rendering})
for _, name in ipairs({"draw_line", "draw_text", "draw_circle"}) do
  rendering[name] = function(p) p.players = nil; return native_rendering[name](p) end
end
local completion
local remove_goal = Pathfinding.remove_goal
Pathfinding.remove_goal = function(i, g, completed)
  completion = (completion or "") .. (completed and "C" or "F")
  return remove_goal(i, g, completed)
end

local SITES = 64
local MIN_REACHABLE = 8
local ROUTE_TICKS = 2400

local native_game
local function bind()
  native_game = native_game or game
  local probe = storage.probe
  local case = probe.cases[probe.current]
  local top = {}
  top.add = function(spec)
    local f = {valid = true}
    f.add = function(c) f[c.name] = {valid = true}; return f[c.name] end
    f.destroy = function() f.valid = false; top[spec.name] = nil end
    top[spec.name] = f; return f
  end
  local player = {index = 1, valid = true, connected = true, force = native_game.forces.player,
    surface = probe.surface, vehicle = case and case.actor, physical_vehicle = case and case.actor,
    character = case and case.driver, color = {r = 1, g = 0, b = 0}, gui = {top = top},
    print = function(message)
      if case and type(message) == "table" and message[1] == "click2move.no-path-found" then case.no_path = true end
    end,
    opened_gui_type = defines.gui_type.none, controller_type = defines.controllers.character,
    is_shortcut_toggled = function() return true end, set_shortcut_toggled = function() end}
  game = setmetatable({players = {[1] = player}}, {__index = native_game})
end

local function start_route(probe)
  probe.current = probe.current + 1
  local case = probe.cases[probe.current]
  if not case then return false end
  local s = probe.surface
  case.driver = s.create_entity{name = "character", position = case.start, force = "player"}
  case.actor = s.create_entity{name = "car", position = case.start, force = "player", quality = "legendary"}
  case.actor.get_fuel_inventory().insert{name = "nuclear-fuel", count = 5, quality = "legendary"}
  case.actor.set_driver(case.driver)
  case.health, case.started = case.actor.health, game.tick
  completion = nil
  bind()
  script.get_event_handler("c2m-move-command")({player_index = 1, input_name = "c2m-move-command",
    cursor_position = case.goal})
  return true
end

local function setup()
  local s = game.planets.vulcanus.create_surface()
  s.request_to_generate_chunks({0, 0}, 10); s.force_generate_chunk_requests()
  for _, ent in pairs(s.find_entities_filtered{force = "enemy"}) do ent.destroy() end
  storage.probe = {cases = {}, current = 0, surface = s}
  for i = 0, SITES - 1 do
    -- Routes start within 210 tiles of the centre, so they end inside the 320 generated.
    local centre = {-210 + i % 8 * 60, -210 + math.floor(i / 8) * 60}
    local start = s.find_non_colliding_position("car", centre, 30, 0.5)
    if start then
      local angle = i * 2.4
      local goal = s.find_non_colliding_position("car", {start.x + 80 * math.cos(angle), start.y + 80 * math.sin(angle)}, 20, 0.5)
      if goal then
        storage.probe.cases[#storage.probe.cases + 1] = {name = "route " .. (#storage.probe.cases + 1),
          goal = goal, start = start, hits = 0, bumps = 0, recoveries = 0, top = 0, speed = 0}
      end
    end
  end
  bind()
  settings.global["c2m-update-interval"] = {value = C2M_NATIVE_INTERVAL}
  Config.load()
  script.get_event_handler(defines.events.on_runtime_mod_setting_changed){setting = "c2m-update-interval"}
  start_route(storage.probe)
end

local function report(probe)
  local failures, reachable = 0, 0
  for _, case in ipairs(probe.cases) do
    local unreachable = case.no_path and case.top == 0
    local ok = unreachable or (case.result == "C" and case.hits == 0 and case.bumps == 0 and case.recoveries == 0)
    if not unreachable then reachable = reachable + 1 end
    if not ok then failures = failures + 1 end
    print(string.format("C2M_VULCANUS %s %s result=%s ticks=%d hits=%d bumps=%d recoveries=%d top=%.2f away=%.1f from=(%.1f,%.1f) to=(%.1f,%.1f) first_hit=%s first_bump=%s first_recovery=%s",
      unreachable and "UNREACHABLE" or ok and "OK" or "FAIL", case.name, tostring(case.result), case.ticks, case.hits,
      case.bumps, case.recoveries, case.top, case.away, case.start.x, case.start.y, case.goal.x, case.goal.y,
      tostring(case.first_hit), tostring(case.first_bump), tostring(case.first_recovery)))
  end
  if reachable < MIN_REACHABLE then failures = failures + 1 end
  print(string.format("C2M_NATIVE_VULCANUS_DONE %d interval=%d reachable=%d failures=%d", #probe.cases,
    C2M_NATIVE_INTERVAL, reachable, failures))
end

script.on_nth_tick(3, function(e)
  if not storage.probe then setup(); return end
  if not native_game then bind() end
  local probe = storage.probe
  local case = probe.cases[probe.current]
  if not case then return end
  local car = case.actor
  case.top = math.max(case.top, math.abs(car.speed))
  if car.health < case.health then
    case.hits = case.hits + 1
    case.first_hit = case.first_hit or string.format("tick %d at (%.1f,%.1f) speed %.3f", e.tick - case.started,
      car.position.x, car.position.y, car.speed)
    case.health = car.health
  end
  -- Above 0.2 tiles per tick, brakes and friction take under 0.04 tiles per
  -- tick of speed in three ticks.
  if math.abs(case.speed) > 0.2 and math.abs(case.speed) - math.abs(car.speed) > 0.1 then
    case.bumps = case.bumps + 1
    case.first_bump = case.first_bump or string.format("tick %d at (%.1f,%.1f) from speed %.3f", e.tick - case.started,
      car.position.x, car.position.y, case.speed)
  end
  case.speed = car.speed
  local active = PlayerData.get_all()[1]
  if active and active.stuck_state ~= "none" and not case.recovering then
    case.recoveries = case.recoveries + 1
    case.first_recovery = case.first_recovery or string.format("tick %d at (%.1f,%.1f)", e.tick - case.started,
      car.position.x, car.position.y)
  end
  case.recovering = active and active.stuck_state ~= "none"
  if active and e.tick - case.started < ROUTE_TICKS then return end
  -- The route ended or ran out of time: record it and drive the next one.
  case.result, case.ticks = completion or "timeout", e.tick - case.started
  case.away = math.sqrt((car.position.x - case.goal.x) ^ 2 + (car.position.y - case.goal.y) ^ 2)
  if active then script.get_event_handler("c2m-cancel-command")({player_index = 1, input_name = "c2m-cancel-command"}) end
  car.destroy(); case.driver.destroy()
  case.actor, case.driver = nil, nil
  if not start_route(probe) then report(probe) end
end)
