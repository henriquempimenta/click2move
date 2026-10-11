-- Appended only to the isolated native test copy. Players/UI are mocked;
-- walking, powered equipment, driving, positions and saves are native.
local PlayerData = require("scripts/player-data")
local Config = require("scripts/config")
local Movement = require("scripts/movement")
local Pathfinding = require("scripts/pathfinding")
local remove_goal = Pathfinding.remove_goal
Pathfinding.remove_goal = function(player_index, goal_index, completed)
  local fixture = storage.c2m_waypoint_fixture
  local case = fixture and fixture.cases[player_index]
  if case and goal_index == 1 then
    assert(completed == true, case.name .. " abandoned its route instead of arriving")
    case.successful_completion = true
  end
  return remove_goal(player_index, goal_index, completed)
end
local native_game
local function bind_game()
  native_game = native_game or game
  local players = {}
  for index, case in ipairs(storage.c2m_waypoint_fixture.cases) do
    local top = {}
    top.add = function(spec)
      local frame = {valid = true}
      frame.add = function(child)
        frame[child.name] = {valid = true, caption = child.caption}
        return frame[child.name]
      end
      frame.destroy = function() frame.valid = false; top[spec.name] = nil end
      top[spec.name] = frame
      return frame
    end
    players[index] = {index = index, valid = true, connected = true,
      force = native_game.forces.player, surface = case.entity.surface,
      character = case.entity.type == "car" and case.entity.get_driver() or case.entity,
      color = {r = 1, g = 0, b = 0}, gui = {top = top}, print = function() end}
  end
  game = setmetatable({players = players}, {__index = native_game})
end
local get_config = Config.get
Config.get = function(index) return get_config(index and 0 or nil) end

local function add_case(surface, name, entity, goal, equipment, flight)
  local fixture = storage.c2m_waypoint_fixture
  local index = #fixture.cases + 1
  local data = PlayerData.ensure(index)
  data.move_entity = entity
  local path = {}
  local start = entity.position
  local dx, dy = goal.x - start.x, goal.y - start.y
  local steps = math.ceil(math.sqrt(dx * dx + dy * dy) / 0.5)
  for step = 0, steps do
    path[#path + 1] = {position = {x = start.x + dx * step / steps, y = start.y + dy * step / steps}}
  end
  data.goals = {{position = goal, path = not flight and path or nil}}
  data.is_straight_line_move = flight or nil
  fixture.cases[index] = {name = name, entity = entity, data = data,
    goal = goal, previous_index = 1, previous_x = entity.position.x,
    direction = dx > 0 and 1 or -1, equipment = equipment, flight = flight, max_advance = 0}
end

c2m_test_bootstrap.on_init(function()
  c2m_test_init_handler()
  local surface = game.create_surface("c2m-waypoint-test", {width = 512, height = 256})
  surface.request_to_generate_chunks({0, 0}, 8)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities()) do entity.destroy() end
  local tiles = {}
  for x = -160, 160 do
    for y = -64, 64 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles)
  storage.c2m_waypoint_fixture = {cases = {}, started = game.tick}
  for index, name in ipairs({"base-character", "powered-exoskeletons", "exoskeletons-and-speed-bonus"}) do
    local position = {x = -100, y = -48 + index * 16}
    local character = surface.create_entity{name = "character", position = position, force = "player"}
    local equipment = {}
    if index > 1 then
      local inventory = character.get_inventory(defines.inventory.character_armor)
      inventory.insert{name = "power-armor-mk2", count = 1}
      local grid = inventory[1].grid
      for _ = 1, 5 do
        local exoskeleton = assert(grid.put{name = "exoskeleton-equipment"})
        exoskeleton.energy = 1000000
        equipment[#equipment + 1] = exoskeleton
      end
      assert(character.character_running_speed > 0.15, "powered exoskeletons did not increase native speed")
    end
    if index == 3 then character.character_running_speed_modifier = 2 end
    add_case(surface, name, character, {x = -20, y = position.y}, equipment)
  end
  local diagonal = surface.create_entity{name = "character", position = {40, -48}, force = "player"}
  local armor = diagonal.get_inventory(defines.inventory.character_armor)
  armor.insert{name = "power-armor-mk2", count = 1}
  local diagonal_equipment = {}
  for _ = 1, 5 do
    local exoskeleton = assert(armor[1].grid.put{name = "exoskeleton-equipment"})
    exoskeleton.energy = 1000000
    diagonal_equipment[#diagonal_equipment + 1] = exoskeleton
  end
  diagonal.character_running_speed_modifier = 2
  add_case(surface, "diagonal-exoskeletons-and-speed-bonus", diagonal, {x = 120, y = 32}, diagonal_equipment)
  if C2M_NATIVE_WITH_SPACE_AGE then
    assert(prototypes.item["mech-armor"], "Space Age mech armor is required for the expansion suite")
    local mech = surface.create_entity{name = "character", position = {40, 48}, force = "player"}
    local mech_armor = mech.get_inventory(defines.inventory.character_armor)
    mech_armor.insert{name = "mech-armor", count = 1}
    local mech_equipment = {}
    for _ = 1, 5 do
      local exoskeleton = assert(mech_armor[1].grid.put{name = "exoskeleton-equipment"})
      exoskeleton.energy = 1000000
      mech_equipment[#mech_equipment + 1] = exoskeleton
    end
    mech.character_running_speed_modifier = 2
    add_case(surface, "mech-flight-speed-bonus", mech, {x = 120, y = 48}, mech_equipment, true)
  end
  for index, name in ipairs({"forward-car", "reverse-car"}) do
    local position = {x = -100, y = 16 + index * 16}
    local car = surface.create_entity{name = "car", position = position, force = "player"}
    car.orientation = index == 1 and 0.25 or 0.75
    car.set_driver(surface.create_entity{name = "character", position = position, force = "player"})
    car.get_fuel_inventory().insert{name = "nuclear-fuel", count = 10}
    car.speed = index == 1 and 0.5 or -0.5
    add_case(surface, name, car, {x = -20, y = position.y})
  end
  bind_game()
  settings.global["c2m-update-interval"] = {value = C2M_NATIVE_INTERVAL}
  Config.load()
  c2m_test_bootstrap.get_event_handler(defines.events.on_runtime_mod_setting_changed){setting = "c2m-update-interval"}
  -- Seed through production handlers before saving, so the real engine must
  -- serialize and restore shared path references and entity history safely.
  for index, case in ipairs(storage.c2m_waypoint_fixture.cases) do
    if case.flight then
      Movement.handle_straight_line(index, case.data, game.players[index], Pathfinding.request_paths_for_player)
    elseif case.entity.type == "character" then
      Movement.handle_character(index, case.data, game.players[index], case.entity)
    else
      Movement.handle_vehicle(index, case.data, game.players[index], case.entity)
    end
    assert(case.flight or case.data.waypoint_motion, "production handler did not seed waypoint history")
    case.previous_index = case.data.current_waypoint
  end
  PlayerData.notify_changed()
end)
c2m_test_bootstrap.on_load(function() c2m_test_load_handler() end)
c2m_test_bootstrap.on_event(defines.events.on_tick, function(event)
  if not native_game then bind_game() end
  local fixture = storage.c2m_waypoint_fixture
  if not fixture.reloaded then
    for _, case in ipairs(fixture.cases) do
      if case.flight then
        assert(case.data.is_straight_line_move, "saved flight mode lost")
      else
        local motion = assert(case.data.waypoint_motion, "saved motion history lost")
        assert(motion.path == case.data.goals[1].path and motion.entity == case.entity,
          "saved path/entity history aliases changed")
      end
    end
    fixture.reloaded = true
  end
  for _, case in ipairs(fixture.cases) do
    for _, equipment in ipairs(case.equipment or {}) do equipment.energy = 1000000 end
  end
  if c2m_test_tick_handler then c2m_test_tick_handler(event) end
  for interval, handler in pairs(c2m_test_nth_handlers) do
    if event.tick % interval == 0 then handler(event) end
  end
  local completed = 0
  for index, case in ipairs(fixture.cases) do
    local active = PlayerData.get_all()[index]
    if not case.completed then
      if active then
        if case.name == "diagonal-exoskeletons-and-speed-bonus" then
          assert(math.abs(case.entity.position.x - case.entity.position.y - 88) <= 1 / 64,
            "diagonal character left its straight route at tick " .. event.tick
              .. " x=" .. case.entity.position.x .. " y=" .. case.entity.position.y
              .. " waypoint=" .. active.current_waypoint .. " direction=" .. case.entity.walking_state.direction)
        end
        case.max_advance = math.max(case.max_advance, active.current_waypoint - case.previous_index)
        case.previous_index = active.current_waypoint
        assert(not active.goal_failed, case.name .. " failed recovery")
        assert(active.stuck_state == "none", case.name .. " entered recovery on a clear straight route")
        if not active.vehicle_arrival and not case.flight and active.current_waypoint < #active.goals[1].path then
          assert((case.entity.position.x - case.previous_x) * case.direction >= -0.01,
            case.name .. " backtracked toward a stale waypoint at tick " .. event.tick
              .. " x=" .. case.entity.position.x .. " previous=" .. case.previous_x
              .. " waypoint=" .. active.current_waypoint)
        end
      else
        assert(case.successful_completion, case.name .. " lost its route without successful completion")
        local threshold = case.entity.type == "character" and 1.5 + case.entity.character_running_speed * 1.5 or 6
        local dx, dy = case.entity.position.x - case.goal.x, case.entity.position.y - case.goal.y
        assert(dx * dx + dy * dy <= threshold ^ 2, case.name .. " skipped final destination")
        if case.entity.type == "car" then assert(case.entity.speed == 0, case.name .. " released while moving") end
        if not case.flight and (C2M_NATIVE_INTERVAL > 1 or case.name:find("speed%-bonus")) then
          assert(case.max_advance > 1, case.name .. " never skipped multiple waypoints")
        end
        case.completed = true
      end
      case.previous_x = case.entity.position.x
    end
    if case.completed then completed = completed + 1 end
  end
  if completed == #fixture.cases and not fixture.done then
    fixture.done = true
    log("C2M_NATIVE_WAYPOINTS_OK " .. completed .. " interval=" .. C2M_NATIVE_INTERVAL)
  end
  if event.tick - fixture.started >= 3599 then assert(fixture.done, "native waypoint timeout") end
end)
