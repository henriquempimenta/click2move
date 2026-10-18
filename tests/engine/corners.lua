-- Appended only to the isolated native test copy. Players/UI are mocked;
-- walls, pathfinding, driving, walking, collisions and positions are native.
-- Every actor is ordered by the production input handler and must go round
-- stone walls without touching them or entering stuck recovery.
--   1/2: car/character starting at rest beside the end of a wall, so the
--        path's first corners are inside the arrival radius from the start.
--   3/4: car/character that must go round the end of a long wall between the
--        start and the destination, turning back towards it at speed.
--   5/6: ordinary/powered character with margin 0 and a single wall between
--        the start and a destination two tiles away.
--   7-18: characters with five exoskeletons and +50% running speed (0.5625
--        tiles per tick) and margin 0, at four starting alignments past a
--        single wall, a wall column and an L-shaped wall. The cases are five
--        tiles apart, so neighbouring walls are part of each scene. At this
--        speed a character can step across a waypoint's tolerance every tick,
--        and at longer intervals walk past a corner further along the path.
--   19-210: the same three walls and four alignments, mirrored into all four
--        quadrants, at 0.5625 and 1.125 tiles per tick (+200%), with margins
--        0 and the default 0.45. Each scene stands alone, at least ten tiles
--        from the next. Steering along only the larger axis, as 0.1.15 did,
--        traps a 1.125 character at the default margin.
-- Arrived actors are parked out of the way, so they cannot block a later route.
-- C2M_NATIVE_INTERVAL (1, 10 or 60) is prepended by run.py. At 60 a car would
-- hold one steering input for a second and circle tight corners, as 0.1.15 did,
-- unless it is controlled every tick near them.
local Config = require("scripts/config")
local Pathfinding = require("scripts/pathfinding")
local PlayerData = require("scripts/player-data")
-- {kind, start, goal, walls as {x1, y1, x2, y2} inclusive tile rectangles, options}
local ALL_CASES = {
  {"car", {0, -60}, {24, -60}, {{5, -72, 5, -59}}},
  {"character", {.5, -29.5}, {12, -30}, {{2, -38, 2, -30}}},
  {"car", {-80, 10}, {-50, 10}, {{-65, -4, -65, 28}}},
  {"character", {-80, 60}, {-55, 60}, {{-68, 52, -68, 78}}},
  {"character", {60, -59.5}, {62, -59.5}, {{60, -60, 60, -60}}, {margin = 0}},
  {"character", {60, -39.5}, {62, -39.5}, {{60, -40, 60, -40}}, {margin = 0, powered = true}},
}
local FAST = {margin = 0, powered = true, bonus = .5}
for shape = 0, 2 do
  for alignment = 0, 3 do
    local y = 20 + (shape * 4 + alignment) * 5
    local walls = ({{{71, y, 71, y}}, {{72, y - 2, 72, y + 1}}, {{72, y - 2, 72, y + 1}, {69, y - 2, 72, y - 2}}})[shape + 1]
    ALL_CASES[#ALL_CASES + 1] = {"character", {70.5, y + .5 + alignment / 4}, {75, y + .5}, walls, FAST}
  end
end
-- Wall tiles {x1, y1, x2, y2} and positions in scene coordinates, mirrored by sx, sy.
local function tile_span(a, b, sign, origin)
  if sign > 0 then return origin + a, origin + b end
  return origin - b - 1, origin - a - 1
end
local scene = 0
for _, margin in ipairs({0, .45}) do
for _, bonus in ipairs({.5, 2}) do
  for _, sx in ipairs({1, -1}) do
    for _, sy in ipairs({1, -1}) do
      for shape = 0, 2 do
        for alignment = 0, 3 do
          local ox, oy = 110 + scene % 12 * 16, -84 + math.floor(scene / 12) * 12
          scene = scene + 1
          local walls = {}
          for _, w in ipairs(({{{1, 0, 1, 0}}, {{2, -2, 2, 1}}, {{2, -2, 2, 1}, {-1, -2, 2, -2}}})[shape + 1]) do
            local x1, x2 = tile_span(w[1], w[3], sx, ox)
            local y1, y2 = tile_span(w[2], w[4], sy, oy)
            walls[#walls + 1] = {x1, y1, x2, y2}
          end
          ALL_CASES[#ALL_CASES + 1] = {"character", {ox + sx * .5, oy + sy * (.5 + alignment / 4)},
            {ox + sx * 5, oy + sy * .5}, walls, {margin = margin, powered = true, bonus = bonus}}
        end
      end
    end
  end
end
end
local CASES = ALL_CASES
local get_config = Config.get
Config.get = function(index)
  local config = get_config(index and 0 or nil)
  local options = index and CASES[index] and CASES[index][5]
  if not options or options.margin == nil then return config end
  local copy = {}
  for key, value in pairs(config) do copy[key] = value end
  copy.character_margin = options.margin
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
  local result = remove_goal(i, g, completed)
  local case = storage.probe and storage.probe.cases[i]
  if case and completed and not PlayerData.get_all()[i] then
    case.arrived_at = {x = case.actor.position.x, y = case.actor.position.y}
    case.actor.teleport({x = 312 + i % 4 * 2, y = -88 + math.floor(i / 4) * 2})
  end
  return result
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
    local vehicle = case.actor.type == "car" and case.actor or nil
    players[i] = {index = i, valid = true, connected = true, force = native_game.forces.player,
      surface = case.actor.surface, vehicle = vehicle, physical_vehicle = vehicle, character = case.driver,
      color = {r = 1, g = 0, b = 0}, gui = {top = top}, print = function() end,
      opened_gui_type = defines.gui_type.none, controller_type = defines.controllers.character,
      is_shortcut_toggled = function() return true end, set_shortcut_toggled = function() end}
  end
  game = setmetatable({players = players}, {__index = native_game})
end

local function setup()
  local s = game.create_surface("c2m-corners", {width = 1024, height = 1024})
  s.request_to_generate_chunks({0, 0}, 11); s.force_generate_chunk_requests()
  for _, ent in pairs(s.find_entities()) do ent.destroy() end
  local t = {} for x = -100, 320 do for y = -90, 112 do t[#t + 1] = {name = "grass-1", position = {x, y}} end end
  s.set_tiles(t)
  storage.probe = {cases = {}, walls = {}, started = game.tick}
  for i, spec in ipairs(CASES) do
    for _, w in ipairs(spec[4]) do
      for x = w[1], w[3] do
        for y = w[2], w[4] do
          storage.probe.walls[#storage.probe.walls + 1] =
            s.create_entity{name = "stone-wall", position = {x + .5, y + .5}, force = "player"}
        end
      end
    end
    local driver = s.create_entity{name = "character", position = spec[2], force = "player"}
    local actor = driver
    local equipment = {}
    if spec[5] and spec[5].powered then
      local armor = driver.get_inventory(defines.inventory.character_armor)
      armor.insert{name = "power-armor-mk2", count = 1}
      for _ = 1, 5 do
        local exoskeleton = assert(armor[1].grid.put{name = "exoskeleton-equipment"})
        exoskeleton.energy = exoskeleton.max_energy
        equipment[#equipment + 1] = exoskeleton
      end
      assert(driver.character_running_speed > 0.3, "powered exoskeletons did not increase native speed")
      driver.character_running_speed_modifier = spec[5].bonus or 0
    end
    if spec[1] == "car" then
      actor = s.create_entity{name = "car", position = spec[2], force = "player"}
      actor.orientation = .25
      actor.get_fuel_inventory().insert{name = "nuclear-fuel", count = 10}
      actor.set_driver(driver)
    end
    storage.probe.cases[i] = {name = spec[1] .. " " .. i, actor = actor, driver = driver, equipment = equipment,
      goal = {x = spec[3][1], y = spec[3][2]}, health = actor.health}
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
    for _, exoskeleton in ipairs(case.equipment) do exoskeleton.energy = exoskeleton.max_energy end
    local active = data[i]
    if active then
      assert(active.stuck_state == "none" and not active.goal_failed and not active.goals[1].recovery_attempts,
        case.name .. " entered stuck recovery at tick " .. e.tick .. " x=" .. case.actor.position.x
          .. " y=" .. case.actor.position.y .. " waypoint=" .. tostring(active.current_waypoint))
    elseif not case.ticks then
      case.ticks = e.tick - probe.started
    end
  end
  if e.tick - probe.started < 3000 then return end
  for i, case in ipairs(probe.cases) do
    assert(completions[i] == "C", case.name .. " did not arrive: " .. tostring(completions[i]))
    assert(case.actor.health == case.health, case.name .. " collided with a wall")
    local stop = case.arrived_at or case.actor.position
    local dx, dy = stop.x - case.goal.x, stop.y - case.goal.y
    -- The production arrival radii, with a little room for the last tick's step.
    local radius = case.actor.type == "car" and 7 or 1.5 + case.actor.character_running_speed * 1.5 + .1
    assert(dx * dx + dy * dy <= radius ^ 2, case.name .. " stopped away from its destination")
  end
  for _, wall in ipairs(probe.walls) do
    assert(wall.valid and wall.health == wall.max_health, "a wall was damaged")
  end
  local ticks = {}
  for i, case in ipairs(probe.cases) do ticks[i] = case.ticks end
  print(string.format("C2M_NATIVE_CORNERS_OK %d interval=%d ticks=%s",
    #probe.cases, C2M_NATIVE_INTERVAL, table.concat(ticks, ",")))
  probe.started = math.huge
end)
