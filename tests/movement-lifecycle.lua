-- Run from the mod directory: lua tests/movement-lifecycle.lua
-- Each VM has a fresh environment and module cache. Only engine/storage state
-- crosses reloads, unlike calling on_load inside an already-loaded Lua module.
local function gui_container()
  local container = {}
  container.add = function(spec)
    local child = gui_container()
    child.valid, child.name = true, spec.name
    child.destroy = function() child.valid = false; container[spec.name] = nil end
    container[spec.name] = child
    return child
  end
  return container
end

local function engine(interval)
  local state = {storage = {}, tick = 0, next_path = 0, requests = {}, objects = {}}
  state.global_settings = {["c2m-update-interval"] = {value = interval or 1}}
  state.player_settings = {
    ["c2m-debug-mode"] = {value = false},
    ["c2m-character-margin"] = {value = 0.45},
    ["c2m-character-proximity-threshold"] = {value = 1.5},
    ["c2m-vehicle-proximity-threshold"] = {value = 6},
    ["c2m-stuck-threshold"] = {value = 30},
    ["c2m-vehicle-path-margin"] = {value = 2},
    ["c2m-vehicle-prefer-straight-paths"] = {value = false}
  }
  local surface = {index = 1}
  surface.request_path = function(params)
    state.next_path = state.next_path + 1
    state.requests[state.next_path] = params
    return state.next_path
  end
  state.surface = surface
  state.character = {
    valid = true, type = "character", position = {x = 0, y = 0}, surface = surface,
    character_running_speed = 0.15, walking_state = {walking = false, direction = 0},
    prototype = {collision_box = {left_top = {x = -0.2, y = -0.2}, right_bottom = {x = 0.2, y = 0.2}}, collision_mask = {layers = {player = true}}}
  }
  state.character.get_inventory = function()
    return {get_contents = function() return state.flying and {{name = "mech-armor"}} or {} end}
  end
  state.player = {
    index = 1, valid = true, connected = true, character = state.character,
    controller_type = 1, opened_gui_type = 0, surface = surface,
    force = {name = "player"}, color = {r = 0.3, g = 0.7, b = 0.2}, gui = {top = gui_container()}
  }
  state.player.is_shortcut_toggled = function() return state.enabled end
  state.player.set_shortcut_toggled = function(_, enabled) state.enabled = enabled end
  state.player.print = function() end
  return state
end

local function vm(state)
  local env = setmetatable({}, {__index = _G})
  local loaded = {}
  local runtime = {events = {}, nth = {}, env = env, booting = true}
  env._G = env
  env.storage = state.storage
  env.defines = {
    direction = {north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14},
    riding = {direction = {straight = 0, left = 1, right = 2}, acceleration = {nothing = 0, accelerating = 1, braking = 2, reversing = 3}},
    controllers = {character = 1, remote = 2}, gui_type = {none = 0}, inventory = {character_armor = 1},
    events = {on_tick = 1, on_script_path_request_finished = 2, on_gui_click = 3, on_lua_shortcut = 4,
      on_player_created = 5, on_runtime_mod_setting_changed = 6, on_player_driving_changed_state = 7}
  }
  env.settings = {global = state.global_settings, startup = {}, get_player_settings = function() return state.player_settings end}
  env.remote = {interfaces = {}}
  env.game = {tick = state.tick, players = {[1] = state.player}}
  env.script = {
    on_event = function(event, handler) runtime.events[event] = handler end,
    on_nth_tick = function(interval, handler) runtime.nth[interval] = handler end,
    on_init = function(handler) runtime.init = handler end,
    on_load = function(handler) runtime.load = handler end,
    on_configuration_changed = function(handler) runtime.migrate = handler end
  }
  local function draw(spec)
    local object = {valid = true, spec = spec}
    object.destroy = function() object.valid = false end
    state.objects[#state.objects + 1] = object
    return object
  end
  env.rendering = {draw_line = draw, draw_text = draw, draw_circle = draw}
  env.require = function(name)
    assert(runtime.booting, "Factorio does not allow require() inside event handlers")
    if loaded[name] then return loaded[name] end
    local result = assert(loadfile(name:gsub("%.", "/") .. ".lua", "t", env))()
    loaded[name] = result or true
    return loaded[name]
  end
  env.require("control")
  runtime.pd = env.require("scripts/player-data")
  runtime.movement = env.require("scripts/movement")
  runtime.pathfinding = env.require("scripts/pathfinding")
  runtime.command = function(x, y, queue)
    local input = queue and "c2m-move-command-queue" or "c2m-move-command"
    runtime.events[input]({player_index = 1, input_name = input, cursor_position = {x = x, y = y or 0}})
  end
  runtime.tick = function(amount)
    state.tick = state.tick + (amount or 1)
    env.game.tick = state.tick
    local handler = runtime.events[env.defines.events.on_tick]
    if handler then handler({tick = state.tick}) end
    for interval, nth_handler in pairs(runtime.nth) do
      if state.tick % interval == 0 then nth_handler({tick = state.tick}) end
    end
  end
  runtime.path = function(id, path)
    runtime.events[env.defines.events.on_script_path_request_finished]({id = id, path = path})
  end
  runtime.booting = false
  return runtime
end

local tests = {}
local function test(name, body) tests[#tests + 1] = {name, body} end

test("fresh VM load keeps active paths, pending callbacks and rendering handles", function()
  local state = engine()
  local first = vm(state); first.init()
  first.command(100); first.command(200, 0, true)
  first.path(1, {{position = {x = 100, y = 0}}})
  first.tick()
  local original = first.pd.get_all()[1]
  local markers = original.goals[1].rendering
  local loaded = vm(state)
  loaded.env.game = nil -- Factorio does not expose game during on_load.
  loaded.load()
  assert(loaded.pd.get_all()[1] == original and original.goals[1].rendering == markers)
  loaded.env.game = {tick = state.tick, players = {[1] = state.player}}
  loaded.path(2, {{position = {x = 200, y = 0}}})
  assert(original.goals[2].path, "saved pending request index was lost")
  loaded.tick()
  assert(state.character.walking_state.walking)
end)

test("fresh VM reload retains braking until a car actually settles", function()
  local state = engine(10)
  local vehicle = {valid = true, name = "car", type = "car", position = {x = 0, y = 0},
    speed = 0.2, orientation = 0.25, surface = state.surface, prototype = state.character.prototype}
  vehicle.get_driver = function() return state.character end
  state.player.vehicle, state.player.physical_vehicle = vehicle, vehicle
  local first = vm(state); first.init(); first.command(2)
  first.path(1, {{position = {x = 2, y = 0}}}); first.tick(10)
  local data = first.pd.get_all()[1]
  assert(data.vehicle_arrival)
  local loaded = vm(state); loaded.env.game = nil; loaded.load()
  loaded.env.game = {tick = state.tick, players = {[1] = state.player}}
  assert(loaded.events[loaded.env.defines.events.on_tick], "braking scheduler was not rebound")
  loaded.tick(); assert(vehicle.riding_state.acceleration == 2 and loaded.pd.get_all()[1])
  vehicle.speed = 0
  for _ = 1, 10 do loaded.tick() end
  assert(not loaded.pd.get_all()[1] and not loaded.events[loaded.env.defines.events.on_tick])
end)

test("configuration migration keeps valid routes and disabled preferences", function()
  local state = engine(); local runtime = vm(state); runtime.init(); runtime.command(100)
  local data = runtime.pd.get_all()[1]
  state.enabled = false
  runtime.migrate()
  assert(not state.enabled and runtime.pd.get_all()[1] == data)
  state.character.valid = false
  runtime.migrate()
  assert(not runtime.pd.get_all()[1] and not state.player.gui.top.c2m_root_flow)
  for _, object in ipairs(state.objects) do assert(not object.valid) end
end)

test("manual character takeover clears the whole queue and preserves input", function()
  local state = engine(); local runtime = vm(state); runtime.init()
  runtime.command(100); runtime.command(200, 0, true)
  runtime.path(1, {{position = {x = 100, y = 0}}}); runtime.tick()
  state.character.walking_state = {walking = true, direction = 12}
  runtime.events["c2m-manual-move-left"]({player_index = 1})
  assert(not runtime.pd.get_all()[1] and state.character.walking_state.direction == 12)
  runtime.tick(); assert(state.character.walking_state.direction == 12)
end)

test("remote-view panning keeps character routes", function()
  local state = engine(); local runtime = vm(state); runtime.init(); runtime.command(100)
  state.player.controller_type = 2
  local data = runtime.pd.get_all()[1]
  runtime.events["c2m-manual-move-left"]({player_index = 1})
  assert(runtime.pd.get_all()[1] == data)
end)

test("flight queues survive landing and return to pathfinding", function()
  local state = engine(); state.flying = true
  local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
  local data = runtime.pd.get_all()[1]
  assert(#data.goals == 2 and state.next_path == 0 and data.is_straight_line_move)
  runtime.tick(); state.flying = false; runtime.tick()
  assert(#data.goals == 2 and not data.is_straight_line_move and state.next_path == 2)
  assert(not state.character.walking_state.walking)
  runtime.path(1, {{position = {x = 100, y = 0}}}); runtime.tick()
  assert(state.character.walking_state.walking and #data.goals == 2)
end)

test("flight completion keeps following queued flight destinations", function()
  local state = engine(); state.flying = true
  local runtime = vm(state); runtime.init(); runtime.command(1); runtime.command(200, 0, true)
  runtime.tick()
  local data = runtime.pd.get_all()[1]
  assert(#data.goals == 1 and data.is_straight_line_move and state.next_path == 0)
  runtime.tick(); assert(state.character.walking_state.walking)
end)

test("vehicle commands clear a surviving flight mode", function()
  local state = engine(); state.flying = true
  local runtime = vm(state); runtime.init(); runtime.command(100)
  local vehicle = {valid = true, name = "car", type = "car", position = {x = 0, y = 0},
    speed = 0, orientation = 0.25, surface = state.surface, prototype = state.character.prototype}
  vehicle.get_driver = function() return state.character end
  state.player.vehicle, state.player.physical_vehicle = vehicle, vehicle
  runtime.command(200)
  local data = runtime.pd.get_all()[1]
  assert(data.move_entity == vehicle and not data.is_straight_line_move)
  runtime.path(1, {{position = {x = 200, y = 0}}}); runtime.tick()
  assert(vehicle.riding_state.acceleration == 1)
end)

test("pending car paths receive brakes every tick only while needed", function()
  local state = engine(60)
  local vehicle = {valid = true, name = "car", type = "car", position = {x = 0, y = 0},
    speed = 0.2, orientation = 0.25, surface = state.surface, prototype = state.character.prototype}
  vehicle.get_driver = function() return state.character end
  state.player.vehicle, state.player.physical_vehicle = vehicle, vehicle
  local runtime = vm(state); runtime.init()
  assert(not runtime.events[runtime.env.defines.events.on_tick])
  runtime.command(100)
  for _ = 1, 5 do vehicle.riding_state = {acceleration = 0}; runtime.tick(); assert(vehicle.riding_state.acceleration == 2) end
  runtime.path(1, {{position = {x = 100, y = 0}}})
  assert(not runtime.events[runtime.env.defines.events.on_tick])
end)

test("progress timeout and recovery duration use game ticks at intervals 1, 10, 60", function()
  for _, interval in ipairs({1, 10, 60}) do
    local state = engine(interval); local runtime = vm(state); runtime.init(); runtime.command(0, -100)
    runtime.path(1, {{position = {x = 0, y = -100}}})
    local data = runtime.pd.get_all()[1]
    for _ = 1, math.floor(60 / interval) + 2 do runtime.tick(interval) end
    assert(data.stuck_state == "sliding", "timeout scaled with scheduler interval")
    assert(data.slide_direction == 4 or data.slide_direction == 12, "slide was not perpendicular")
    local start = state.tick
    while data.stuck_state == "sliding" do runtime.tick(interval) end
    assert(state.tick - start >= 30 and state.tick - start < 30 + interval)
    assert(data.goals[1].path_id and not state.character.walking_state.walking)
  end
end)

test("slide and reverse input start immediately and repeat for 30/60 game ticks", function()
  for _, interval in ipairs({1, 10, 60}) do
    for _, kind in ipairs({"character", "car"}) do
      local state = engine(interval)
      local entity = state.character
      if kind == "car" then
        entity = {valid = true, name = "car", type = "car", position = {x = 0, y = 0},
          speed = 0, orientation = 0.25, surface = state.surface, prototype = state.character.prototype}
        entity.get_driver = function() return state.character end
        state.player.vehicle, state.player.physical_vehicle = entity, entity
      end
      local runtime = vm(state); runtime.init(); runtime.command(1000)
      runtime.path(1, {{position = {x = 1000, y = 0}}})
      local data = runtime.pd.get_all()[1]
      while data.stuck_state == "none" do runtime.tick(interval) end
      local duration = kind == "car" and 60 or 30
      local function assert_recovery_input()
        if kind == "car" then assert(entity.riding_state.acceleration == 3)
        else assert(entity.walking_state.walking and entity.walking_state.direction == data.slide_direction) end
      end
      assert_recovery_input()
      for _ = 1, duration - 1 do
        entity.walking_state = {walking = false}
        entity.riding_state = {acceleration = 0}
        runtime.tick()
        assert_recovery_input()
      end
      runtime.tick()
      assert(data.stuck_state == "none" and data.goals[1].path_id)
      if kind == "car" then assert(entity.riding_state.acceleration == 2)
      else assert(not entity.walking_state.walking) end
    end
  end
end)

test("ground paths are discarded when a flying queue later lands", function()
  local state = engine(); local runtime = vm(state); runtime.init()
  runtime.command(100); runtime.command(200, 0, true)
  runtime.path(1, {{position = {x = 0, y = 0}}, {position = {x = 50, y = 0}}, {position = {x = 100, y = 0}}})
  state.flying = true; runtime.command(300, 0, true)
  local data = runtime.pd.get_all()[1]
  assert(data.is_straight_line_move and not data.goals[1].path)
  runtime.path(2, {{position = {x = 200, y = 0}}}) -- Callback from the cancelled ground queue.
  assert(not data.goals[2].path)
  state.character.position.x = 70; runtime.tick(); state.flying = false; runtime.tick()
  assert(not data.is_straight_line_move and #data.goals == 3)
  assert(state.requests[3].start.x == 70 and not state.character.walking_state.walking)
end)

test("unsupported vehicle commands are ignored without creating a route", function()
  local state = engine()
  local locomotive = {valid = true, type = "locomotive", surface = state.surface}
  state.player.vehicle, state.player.physical_vehicle = locomotive, locomotive
  local runtime = vm(state); runtime.init(); runtime.command(100)
  assert(not runtime.pd.get_all()[1] and state.next_path == 0)
end)

test("repeated character recovery alternates perpendicular sides deterministically", function()
  local state = engine(); local runtime = vm(state); runtime.init(); runtime.command(0, -100)
  runtime.path(1, {{position = {x = 0, y = -100}}})
  local data = runtime.pd.get_all()[1]
  local sides = {}
  for attempt = 1, 2 do
    while data.stuck_state == "none" do runtime.tick() end
    sides[attempt] = data.slide_direction
    while data.stuck_state == "sliding" do runtime.tick() end
    runtime.path(data.goals[1].path_id, {{position = {x = 0, y = -100}}})
  end
  assert(sides[1] == 4 and sides[2] == 12)
end)

test("occupied spidertron takeover clears autopilot and preserves walking input", function()
  local state = engine()
  local spider = {valid = true, type = "spider-vehicle", position = {x = 0, y = 0},
    surface = state.surface, walking_state = {walking = true, direction = 12}}
  state.player.vehicle, state.player.physical_vehicle = spider, spider
  local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
  runtime.tick(); assert(spider.autopilot_destination)
  state.player.controller_type = 2
  runtime.events["c2m-manual-move-left"]({player_index = 1})
  assert(runtime.pd.get_all()[1] and spider.autopilot_destination)
  state.player.controller_type = 1
  runtime.events["c2m-manual-move-left"]({player_index = 1})
  assert(not runtime.pd.get_all()[1] and not spider.autopilot_destination)
  assert(spider.walking_state.walking and spider.walking_state.direction == 12)
end)

for _, entry in ipairs(tests) do entry[2](); print("PASS " .. entry[1]) end
print(#tests .. " movement/lifecycle tests passed")
