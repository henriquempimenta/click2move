-- Appended only to an isolated test copy of control.lua. The bootstrap shim
-- captures movement schedules and mocks player/UI calls (headless has no
-- players). Real Factorio entities, physics, rendering and saves run.
local PlayerData = require("scripts/player-data")
local Config = require("scripts/config")
local Rendering = require("scripts/rendering")
local Pathfinding = require("scripts/pathfinding")
local reloaded = false
local native_game
local function bind_game()
  native_game = native_game or game
  local fixture = storage.c2m_engine_fixture
  local surface = native_game.surfaces["c2m-engine-test"]
  local players = {}
  for index = 1, 1 + #fixture.cases do
    local top = {}
    local function add_frame()
      local frame = {valid = true}
      frame.add = function(parameters)
        frame[parameters.name] = {valid = true, caption = parameters.caption}
        return frame[parameters.name]
      end
      frame.destroy = function() frame.valid = false; top.c2m_root_flow = nil end
      top.c2m_root_flow = frame
      return frame
    end
    top.add = add_frame
    local frame = add_frame()
    frame.c2m_status_label = {valid = true}
    players[index] = {index = index, valid = true, connected = true, force = native_game.forces.player,
      surface = surface, color = {r = 1, g = 0, b = 0}, gui = {top = top},
      print = function() end,
      is_shortcut_toggled = function() return fixture.preference end,
      set_shortcut_toggled = function(_, enabled) fixture.preference = enabled end}
  end
  game = setmetatable({players = players}, {__index = native_game})
  return players[1]
end
-- Settings APIs/render player filters require real LuaPlayers. These two
-- fixture facades keep all physics/render-object operations native.
local get_config = Config.get
Config.get = function(player_index) return get_config(player_index and 0 or nil) end
local native_rendering = rendering
rendering = setmetatable({}, {__index = native_rendering})
for _, name in ipairs({"draw_line", "draw_text", "draw_circle"}) do
  rendering[name] = function(parameters)
    parameters.players = nil
    return native_rendering[name](parameters)
  end
end

local function setup()
  local surface = game.create_surface("c2m-engine-test", {width = 512, height = 512})
  surface.request_to_generate_chunks({0, 0}, 8)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities()) do entity.destroy() end
  local tiles = {}
  for x = -160, 160 do
    for y = -80, 80 do tiles[#tiles + 1] = {name = "grass-1", position = {x, y}} end
  end
  surface.set_tiles(tiles)
  storage.c2m_engine_fixture = {player_index = 1, cases = {}, started = game.tick, preference = false}
  local player = bind_game()
  settings.global["c2m-update-interval"] = {value = 1}
  Config.load()
  local setting_handler = c2m_test_bootstrap.get_event_handler(defines.events.on_runtime_mod_setting_changed)
  setting_handler{setting = "c2m-update-interval"}
  local vehicle = surface.create_entity{name = "car", position = {-140, -60}, force = player.force}
  vehicle.orientation = 0.25
  vehicle.set_driver(surface.create_entity{name = "character", position = {-140, -60}, force = player.force})
  vehicle.get_fuel_inventory().insert{name = "nuclear-fuel", count = 10}
  vehicle.speed = 0.2
  local data = PlayerData.ensure(player.index)
  data.move_entity = vehicle
  data.goals = {{position = {x = -138, y = -60}, path = {{position = {x = -138, y = -60}}}},
    {position = {x = -100, y = -60}}}
  data.vehicle_arrival = {position = {x = -140, y = -60}, tick = game.tick, stationary_ticks = 5, speed = 0.2}
  Rendering.render_paths_for_player(player.index, PlayerData.get_all())
  Pathfinding.request_paths_for_player(player.index, true)
  storage.c2m_engine_fixture.render_handles = {}
  for _, goal in ipairs(data.goals) do
    for _, object in ipairs(goal.rendering.markers) do
      storage.c2m_engine_fixture.render_handles[#storage.c2m_engine_fixture.render_handles + 1] = object
    end
    for _, object in ipairs(goal.rendering.path_objects) do
      storage.c2m_engine_fixture.render_handles[#storage.c2m_engine_fixture.render_handles + 1] = object
    end
  end
  storage.c2m_engine_fixture.pending_id = data.goals[2].path_id
  storage.c2m_engine_fixture.pending_goal = data.goals[2]
  assert(data.goals[2].path_id, "native queued path not submitted")
  PlayerData.notify_changed()
  for model_index, name in ipairs({"hovercraft", "missile-hovercraft", "electric-hovercraft", "laser-hovercraft"}) do
    for case_index, approach in ipairs({"forward", "reverse", "near"}) do
      local position = {x = -100 + (model_index - 1) * 75, y = -30 + (case_index - 1) * 30}
      local craft = surface.create_entity{name = name, position = position, force = player.force, raise_built = true}
      assert(craft, "could not create " .. name)
      craft.orientation = 0.25
      local driver = surface.create_entity{name = "character", position = position, force = player.force}
      craft.set_driver(driver)
      if craft.get_fuel_inventory() then craft.get_fuel_inventory().insert{name = "nuclear-fuel", count = 10} end
      if craft.burner then craft.burner.heat = craft.burner.heat_capacity end
      craft.speed = approach == "reverse" and -0.12 or approach == "near" and 0.01 or 0.2
      local goal = {x = position.x + (approach == "reverse" and -20 or approach == "near" and 0 or 20), y = position.y}
      local player_index = #storage.c2m_engine_fixture.cases + 2
      local move = PlayerData.ensure(player_index)
      move.goals = {{position = goal, path = {{position = goal}}}}
      move.move_entity = craft
      storage.c2m_engine_fixture.cases[#storage.c2m_engine_fixture.cases + 1] = {
        name = name .. "/" .. approach, player_index = player_index, vehicle = craft, data = move, goal = goal}
    end
  end
  bind_game()
end

local function verify_reload()
  assert(reloaded, "engine did not execute the load handler")
  local fixture = storage.c2m_engine_fixture
  local data = PlayerData.get_all()[fixture.player_index]
  assert(PlayerData.get_all() == storage.c2m_player_move_data, "local state not rebound to storage")
  assert(data and #data.goals == 2 and data.move_entity.valid, "saved route/entity lost")
  assert(data.vehicle_arrival and data.vehicle_arrival.stationary_ticks == 5, "braking state lost")
  assert(data.goals[1].rendering and data.goals[1].rendering.markers[1].valid, "render handles lost")
  local pending = storage.c2m_path_requests[fixture.pending_id]
  assert(fixture.callback_verified or (pending and pending.goal == data.goals[2] and pending.data == data),
    "pending path associations not restored")
  assert(c2m_test_nth_handlers[1], "movement schedule not restored")
  assert(not game.players[fixture.player_index].is_shortcut_toggled("c2m-toggle-mode"), "disabled preference reset")
  if c2m_test_expect_migration then assert(fixture.migration_called, "configuration handler did not run") end
  log("C2M_NATIVE_RELOAD_OK")
end

local function install_path_handler()
  c2m_test_bootstrap.on_event(defines.events.on_script_path_request_finished, function(event)
    if not native_game then bind_game() end
    Pathfinding.on_path_request_finished(event)
    local fixture = storage.c2m_engine_fixture
    if event.id == fixture.pending_id then
      assert(fixture.pending_goal.path, "native saved callback did not attach its path")
      fixture.callback_verified = true
      log("C2M_NATIVE_CALLBACK_OK")
    end
  end)
end

c2m_test_bootstrap.on_init(function()
  c2m_test_init_handler()
  setup()
  install_path_handler()
end)
c2m_test_bootstrap.on_load(function()
  c2m_test_load_handler()
  install_path_handler()
  reloaded = true
end)
c2m_test_bootstrap.on_configuration_changed(function(event)
  bind_game()
  c2m_test_config_handler(event)
  install_path_handler()
  storage.c2m_engine_fixture.migration_called = true
end)
c2m_test_bootstrap.on_event(defines.events.on_tick, function(event)
  if not native_game then bind_game() end
  local fixture = storage.c2m_engine_fixture
  if not fixture.verified then
    verify_reload()
    fixture.verified = true
    -- All mods have now initialized. Hovercrafts clears its tracking table
    -- after Click2Move's init, so register and seed real moving drift here.
    for _, case in ipairs(fixture.cases) do
      c2m_test_bootstrap.raise_script_built{entity = case.vehicle}
      assert(remote.call("c2m-native-hovercraft", "initialize", case.vehicle))
    end
  end
  -- Exercise the production orchestrator, including native callback results,
  -- queue completion, rendering cleanup and conditional tick subscriptions.
  if c2m_test_tick_handler then c2m_test_tick_handler(event) end
  for interval, handler in pairs(c2m_test_nth_handlers) do
    if event.tick % interval == 0 then handler(event) end
  end
  local finished = 0
  for _, case in ipairs(fixture.cases) do
    -- Keep every model powered. Electric variants otherwise exhaust the
    -- small initial burner buffer without a charged vehicle transformer.
    case.vehicle.energy = case.vehicle.burner.heat_capacity
    if not case.completed_tick then
      if not PlayerData.get_all()[case.player_index] then
        local dx, dy = case.vehicle.position.x - case.goal.x, case.vehicle.position.y - case.goal.y
        assert(dx * dx + dy * dy <= 36, case.name .. " completed outside arrival radius; failed="
          .. tostring(case.data.goal_failed) .. " x=" .. case.vehicle.position.x)
        case.completed_tick = event.tick
        case.stopped_position = {x = case.vehicle.position.x, y = case.vehicle.position.y}
      end
    else
      local dx, dy = case.vehicle.position.x - case.stopped_position.x, case.vehicle.position.y - case.stopped_position.y
      -- New mode quantizes virtual friction/teleports even with no input.
      -- Observe two seconds of near-stationarity, then reject runaway motion
      -- outside the destination radius for the rest of the two-minute run.
      local elapsed = event.tick - case.completed_tick
      local position_tolerance = settings.startup["hovercraft-drifting"].value == "new" and 1 / 32 or 0.0001
      assert(elapsed > 120 or dx * dx + dy * dy <= position_tolerance ^ 2, case.name .. " drifted after release: dx="
        .. dx .. " dy=" .. dy .. " ticks=" .. (event.tick - case.completed_tick) .. " speed=" .. case.vehicle.speed)
      local goal_dx, goal_dy = case.vehicle.position.x - case.goal.x, case.vehicle.position.y - case.goal.y
      assert(goal_dx * goal_dx + goal_dy * goal_dy <= 36, case.name .. " left destination after release")
      assert(math.abs(case.vehicle.speed) <= 0.001, case.name .. " restarted after release")
      if event.tick - case.completed_tick >= 120 then finished = finished + 1 end
    end
  end
  if finished == #fixture.cases and not fixture.done then
    fixture.done = true
    log("C2M_NATIVE_STOPPING_OK " .. finished .. " " .. settings.startup["hovercraft-drifting"].value)
  end
  if fixture.done and not fixture.scheduler_verified and not PlayerData.get_all()[fixture.player_index] then
    assert(fixture.callback_verified, "saved native callback never completed")
    for _, object in ipairs(fixture.render_handles) do assert(not object.valid, "saved rendering leaked") end
    assert(not next(storage.c2m_path_requests), "native request index leaked")
    assert(not next(storage.c2m_path_retries), "native retry state leaked")
    fixture.scheduler_verified = true
    log("C2M_NATIVE_SCHEDULER_OK")
  end
  if event.tick - fixture.started >= 7199 and not fixture.done then
    local pending = {}
    for _, case in ipairs(fixture.cases) do
      if not case.completed_tick or event.tick - case.completed_tick < 120 then
        pending[#pending + 1] = case.name .. " speed=" .. case.vehicle.speed .. " x=" .. case.vehicle.position.x
          .. " completion=" .. tostring(case.completed_tick) .. " recovery=" .. tostring(case.data.stuck_state)
          .. " stationary=" .. tostring(case.data.vehicle_arrival and case.data.vehicle_arrival.stationary_ticks)
          .. " arrival_x=" .. tostring(case.data.vehicle_arrival and case.data.vehicle_arrival.position.x)
          .. " y=" .. case.vehicle.position.y .. " path=" .. tostring(case.data.goals[1] and case.data.goals[1].path ~= nil)
      end
    end
    error("stopping timeout: " .. table.concat(pending, "; "))
  end
end)
