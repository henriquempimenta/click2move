-- Run from the mod directory with: lua tests/vehicle-arrival.lua
-- The fake engine releases input each tick and has no passive friction.
package.path = "./?.lua;" .. package.path

defines = {
  riding = {
    acceleration = {nothing = 0, accelerating = 1, braking = 2, reversing = 3},
    direction = {straight = 0, left = 1, right = 2}
  },
  direction = {north = 0},
  controllers = {character = 1, remote = 2},
  gui_type = {none = 0},
  events = {
    on_tick = 1, on_script_path_request_finished = 2, on_gui_click = 3,
    on_lua_shortcut = 4, on_player_created = 5, on_runtime_mod_setting_changed = 6,
    on_player_driving_changed_state = 7
  }
}
local acceleration = defines.riding.acceleration
local direction = defines.riding.direction
local config = {vehicle_proximity_threshold = 6, stuck_threshold = 30, update_interval = 1}
package.loaded["scripts/config"] = {
  get = function() return config end,
  load = function() end,
  on_setting_changed = function() end,
  is_debug = function() return false end
}
local gui_updates = 0
package.loaded["scripts/rendering"] = {render_paths_for_player = function() end, clear_player = function() end}
package.loaded["scripts/pathfinding"] = {
  request_paths_for_player = function() return false end,
  on_path_request_finished = function() end,
  init = function() end, load = function() end, on_tick = function() end,
  cancel_player = function() end,
  invalidate_goal = function(index)
    local data = require("scripts/player-data").get_all()[index]
    data.goals[1].path = nil
  end,
  remove_goal = function(index, goal_index)
    local pd = require("scripts/player-data")
    local data = pd.get_all()[index]
    table.remove(data.goals, goal_index)
    pd.reset_movement_state(data, true)
  end
}
local PlayerData = require("scripts/player-data")
local Movement = require("scripts/movement")
local GUI = require("scripts/gui")
GUI.update = function() gui_updates = gui_updates + 1 end

local handlers, nth_handlers, init, load_handler = {}, {}
script = {
  on_event = function(event, handler) handlers[event] = handler end,
  on_nth_tick = function(interval, handler) nth_handlers[interval] = handler end,
  on_init = function(handler) init = handler end,
  on_configuration_changed = function() end,
  on_load = function(handler) load_handler = handler end
}
storage = {}
game = {tick = 0, players = {}}
settings = {startup = {}}
require("control")

local function fixture(position, speed, goal_position)
  PlayerData.clear_all()
  game.tick = 0
  config.update_interval = 1
  settings.startup = {}
  local vehicle = {
    valid = true, type = "car", position = {x = position or 0, y = 0},
    orientation = 0.25, speed = speed or 0,
    riding_state = {direction = direction.straight, acceleration = acceleration.nothing},
    surface = {index = 1}
  }
  local player = {
    index = 1, valid = true, connected = true, vehicle = vehicle,
    physical_vehicle = vehicle, surface = vehicle.surface, opened_gui_type = defines.gui_type.none,
    controller_type = defines.controllers.character,
    is_shortcut_toggled = function() return true end,
    set_shortcut_toggled = function() end, print = function() end
  }
  game.players[1] = player
  init()
  local data = PlayerData.ensure(1)
  local goal = {position = {x = goal_position or 0, y = 0}}
  goal.path = {{position = goal.position}}
  data.goals = {goal}
  data.move_entity = vehicle
  return data, player, vehicle
end

local function tick()
  game.tick = game.tick + 1
  local on_tick = handlers[defines.events.on_tick]
  if on_tick then on_tick({tick = game.tick}) end
  for interval, handler in pairs(nth_handlers) do
    if game.tick % interval == 0 then handler({tick = game.tick}) end
  end
end

local tests = {}
local function test(name, fn) tests[#tests + 1] = {name, fn} end

test("arrival holds brakes until a moving vehicle actually stops", function()
  local data, player, vehicle = fixture(0, 0.2, 2)
  tick()
  assert(data.vehicle_arrival and PlayerData.get_all()[1])
  for _ = 1, 80 do
    vehicle.riding_state = {acceleration = acceleration.nothing, direction = direction.straight}
    tick()
    assert(vehicle.riding_state.acceleration == acceleration.braking)
    assert(PlayerData.get_all()[1], "moving vehicle was released")
    assert(data.stuck_state == "none", "braking triggered stuck recovery")
  end
  vehicle.speed = 0
  for _ = 1, 9 do tick(); assert(PlayerData.get_all()[1]) end
  tick()
  assert(not PlayerData.get_all()[1], "settled vehicle did not complete")
end)

test("scripted sideways drift delays completion even with zero native speed", function()
  local data, player, vehicle = fixture()
  tick()
  for _ = 1, 30 do
    vehicle.position.y = vehicle.position.y + 0.02
    tick()
    assert(PlayerData.get_all()[1], "drifting vehicle was released")
  end
  for _ = 1, 10 do tick() end
  assert(not PlayerData.get_all()[1])
end)

test("tiny nonzero speed is not released on frictionless vehicles", function()
  local data, player, vehicle = fixture(0, 0.00001)
  for _ = 1, 20 do tick() end
  assert(PlayerData.get_all()[1])
end)

test("New-mode hovercrafts settle without restarting from cleanup brake input", function()
  for _, name in ipairs({"hovercraft", "missile-hovercraft", "electric-hovercraft", "laser-hovercraft"}) do
    local data, player, vehicle = fixture(0, 0.00025)
    vehicle.name = name
    settings.startup["hovercraft-drifting"] = {value = "new"}
    tick()
    assert(vehicle.speed == 0 and vehicle.riding_state.acceleration == acceleration.nothing)
    for i = 1, 119 do
      -- The mod's friction calculation jitters below one position quantum.
      vehicle.speed = (i % 2 == 0) and 0.00025 or -0.00025
      vehicle.position.y = (i % 2 == 0) and 0 or 1 / 256
      tick()
      assert(PlayerData.get_all()[1], "released before drift observation completed")
    end
    tick()
    assert(not PlayerData.get_all()[1])
    assert(vehicle.speed == 0 and vehicle.riding_state.acceleration == acceleration.nothing)
  end
end)

test("scripted braking impulses that cross zero are stopped instead of reversed", function()
  for _, sign in ipairs({1, -1}) do
    local data, player, vehicle = fixture(0, 0.015 * sign)
    vehicle.name = "electric-hovercraft"
    settings.startup["hovercraft-drifting"] = {value = "new"}
    tick()
    assert(vehicle.riding_state.acceleration == acceleration.braking)
    vehicle.speed = -0.013 * sign
    tick()
    assert(vehicle.speed == 0 and vehicle.riding_state.acceleration == acceleration.nothing)
    assert(PlayerData.get_all()[1], "zero crossing completed the goal before settling")
  end
end)

test("slow cumulative hovercraft drift cannot pass the stationary check", function()
  local data, player, vehicle = fixture()
  vehicle.name = "hovercraft"
  settings.startup["hovercraft-drifting"] = {value = "new"}
  tick()
  for _ = 1, 200 do
    vehicle.position.y = vehicle.position.y + 0.002
    tick()
    assert(PlayerData.get_all()[1], "small steps hid ongoing drift")
  end
  for _ = 1, 120 do tick() end
  assert(not PlayerData.get_all()[1])
end)

test("New-mode laser hovercraft friction jitter can settle across several position quanta", function()
  local data, player, vehicle = fixture()
  vehicle.name = "laser-hovercraft"
  settings.startup["hovercraft-drifting"] = {value = "new"}
  tick()
  for elapsed = 1, 119 do
    -- New-mode friction can accumulate one position quantum every forty ticks
    -- even though the reported speed has settled at zero.
    if elapsed % 40 == 0 then vehicle.position.y = vehicle.position.y + 1 / 256 end
    tick()
    assert(PlayerData.get_all()[1], "released before the full observation window")
  end
  vehicle.position.y = vehicle.position.y + 1 / 256
  tick()
  assert(not PlayerData.get_all()[1], "harmless quantized friction jitter prevented completion")
  assert(vehicle.speed == 0 and vehicle.riding_state.acceleration == acceleration.nothing)
end)

test("New-mode drift spanning the full position tolerance keeps the vehicle controlled", function()
  local data, player, vehicle = fixture()
  vehicle.name = "laser-hovercraft"
  settings.startup["hovercraft-drifting"] = {value = "new"}
  tick()
  for elapsed = 1, 300 do
    if elapsed % 30 == 0 then vehicle.position.y = vehicle.position.y + 1 / 256 end
    tick()
    assert(PlayerData.get_all()[1], "four position quanta per observation window looked stationary")
  end
end)

test("a stopped vehicle outside the arrival radius approaches farther inside before braking again", function()
  local data, player, vehicle = fixture(6.01, 0, 0)
  -- It stopped just outside the goal after an initial, conservative brake.
  data.vehicle_arrival = {position = {x = 6.01, y = 0}, tick = 0, stationary_ticks = 0}
  for _ = 1, 10 do tick() end
  assert(not data.vehicle_arrival and data.vehicle_reapproach)
  vehicle.position.x = 5.99
  tick()
  assert(not data.vehicle_arrival, "reapproach immediately braked again at the outer edge")
  assert(vehicle.riding_state.acceleration == acceleration.reversing)
  vehicle.position.x = 2.99
  tick()
  assert(data.vehicle_arrival, "reapproach did not brake inside the destination radius")
  for _ = 1, 10 do tick() end
  assert(not PlayerData.get_all()[1] and not data.vehicle_reapproach)
end)

test("other drift modes keep native braking and require zero speed", function()
  for _, mode in ipairs({"off", "old", "low-latency", "low-latency-b"}) do
    local data, player, vehicle = fixture(0, 0.00001)
    vehicle.name = "hovercraft"
    settings.startup["hovercraft-drifting"] = {value = mode}
    for _ = 1, 130 do tick() end
    assert(PlayerData.get_all()[1] and vehicle.speed == 0.00001)
    assert(vehicle.riding_state.acceleration == acceleration.braking)
  end
end)

test("slow update intervals still apply brakes on every arrival tick", function()
  local data, player, vehicle = fixture(0, -0.2)
  config.update_interval = 60
  handlers[defines.events.on_runtime_mod_setting_changed]({setting = "c2m-update-interval"})
  game.tick = 59
  tick()
  for _ = 1, 70 do
    vehicle.riding_state = {acceleration = acceleration.nothing, direction = direction.straight}
    tick()
    assert(vehicle.riding_state.acceleration == acceleration.braking)
    assert(PlayerData.get_all()[1])
  end
  config.update_interval = 1
  handlers[defines.events.on_runtime_mod_setting_changed]({setting = "c2m-update-interval"})
  assert(handlers[defines.events.on_tick] == nil and nth_handlers[60] == nil)
end)

test("queued goals advance only after the current vehicle stop settles", function()
  local data, player, vehicle = fixture(0, 0.2)
  local next_goal = {position = {x = 100, y = 0}, path = {{position = {x = 100, y = 0}}}}
  data.goals[2] = next_goal
  tick()
  assert(#data.goals == 2)
  vehicle.speed = 0
  for _ = 1, 10 do tick() end
  assert(#data.goals == 1 and data.goals[1] == next_goal)
  assert(not data.vehicle_arrival and data.move_entity == vehicle)
  tick()
  assert(vehicle.riding_state.acceleration == acceleration.accelerating)
end)

test("manual movement cancels the whole queue without overwriting player input", function()
  for _, input in ipairs({"move-up", "move-down", "move-left", "move-right"}) do
    local data, player, vehicle = fixture(0, 0.2)
    tick()
    vehicle.riding_state = {acceleration = acceleration.reversing, direction = direction.left}
    handlers["c2m-manual-" .. input]({player_index = 1})
    assert(not PlayerData.get_all()[1])
    tick()
    assert(vehicle.riding_state.acceleration == acceleration.reversing)
    assert(vehicle.riding_state.direction == direction.left)
  end
end)

test("remote-view movement keys and remote vehicle changes preserve the route", function()
  local data, player, vehicle = fixture(0, 0.2)
  tick()
  player.controller_type = defines.controllers.remote
  player.vehicle = nil -- physical_vehicle still points to the occupied vehicle
  for _, input in ipairs({"move-up", "move-down", "move-left", "move-right"}) do
    handlers["c2m-manual-" .. input]({player_index = 1})
    assert(PlayerData.get_all()[1] == data and data.vehicle_arrival)
  end
  handlers[defines.events.on_player_driving_changed_state]({player_index = 1})
  assert(PlayerData.get_all()[1] == data)
  tick()
  assert(vehicle.riding_state.acceleration == acceleration.braking)
  vehicle.speed = 0
  for _ = 1, 10 do tick() end
  assert(not PlayerData.get_all()[1], "arrival did not finish in remote view")

  data, player, vehicle = fixture(0, 0.2, 100)
  player.controller_type = defines.controllers.remote
  player.vehicle = nil
  for _, input in ipairs({"move-up", "move-down", "move-left", "move-right"}) do
    handlers["c2m-manual-" .. input]({player_index = 1})
    assert(PlayerData.get_all()[1] == data)
  end
  tick()
  assert(vehicle.riding_state.acceleration == acceleration.accelerating)
end)

test("cancel, vehicle exit and a new destination discard the stopping state", function()
  local data, player, vehicle = fixture(0, 0.2)
  tick()
  handlers["c2m-cancel-command"]({player_index = 1, input_name = "c2m-cancel-command"})
  assert(not data.vehicle_arrival and not PlayerData.get_all()[1])
  data, player, vehicle = fixture(0, 0.2)
  tick()
  player.vehicle, player.physical_vehicle = nil, nil
  handlers[defines.events.on_player_driving_changed_state]({player_index = 1})
  assert(not data.vehicle_arrival and not PlayerData.get_all()[1])
  data, player, vehicle = fixture(0, 0.2)
  tick()
  handlers["c2m-move-command"]({player_index = 1, input_name = "c2m-move-command", cursor_position = {x = 100, y = 0}})
  assert(not data.vehicle_arrival and data.goals[1].position.x == 100)
end)

test("the final path point remains active while approaching the destination", function()
  local data, player, vehicle = fixture(0, 0, 100)
  data.current_waypoint = 2 -- an exhausted path from a previous update
  tick()
  assert(PlayerData.get_all()[1] and not data.vehicle_arrival)
  assert(vehicle.riding_state.acceleration == acceleration.accelerating)
end)

test("forward and reverse frictionless approaches finish inside the goal radius", function()
  for _, initial in ipairs({{0, 0.6, 60}, {60, -0.6, 0}, {0, 1.2, 4}, {0, 0, 10}}) do
    local data, player, vehicle = fixture(initial[1], initial[2], initial[3])
    local stopped = false
    for _ = 1, 3000 do
      vehicle.riding_state = {acceleration = acceleration.nothing, direction = direction.straight}
      tick()
      local input = vehicle.riding_state.acceleration
      if input == acceleration.braking then
        if vehicle.speed > 0 then vehicle.speed = math.max(0, vehicle.speed - 0.015)
        else vehicle.speed = math.min(0, vehicle.speed + 0.015) end
      elseif input == acceleration.accelerating then vehicle.speed = vehicle.speed + 0.005
      elseif input == acceleration.reversing then vehicle.speed = vehicle.speed - 0.005 end
      vehicle.position.x = vehicle.position.x + vehicle.speed
      if not PlayerData.get_all()[1] then
        assert(vehicle.speed == 0)
        assert(math.abs(vehicle.position.x - initial[3]) <= config.vehicle_proximity_threshold)
        stopped = true
        break
      end
    end
    assert(stopped, "approach failed to settle")
  end
end)

test("load re-registers braking and manual takeover handlers", function()
  fixture()
  config.update_interval = 5
  handlers, nth_handlers = {}, {}
  load_handler()
  assert(not handlers[defines.events.on_tick] and nth_handlers[5])
  assert(handlers["c2m-manual-move-up"])
end)

for _, entry in ipairs(tests) do
  entry[2]()
  print("PASS " .. entry[1])
end
print(string.format("%d vehicle arrival tests passed", #tests))
