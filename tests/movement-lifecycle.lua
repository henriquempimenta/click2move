-- Run from the mod directory: lua tests/movement-lifecycle.lua
-- Each VM has a fresh environment and module cache. Only engine/storage state
-- crosses reloads, unlike calling on_load inside an already-loaded Lua module.
local Fake = dofile("tests/support/fake-factorio.lua")

local function engine(interval)
  local state = {storage = {}, tick = 0, next_path = 0, requests = {}, objects = {}}
  state.global_settings = {["c2m-update-interval"] = {value = interval or 1}}
  state.player_settings = Fake.player_settings()
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
  state.character.get_inventory = Fake.armor_inventory(state)
  state.player = Fake.player(state, {character = state.character, surface = surface, color = {r = 0.3, g = 0.7, b = 0.2}})
  return state
end

local function vm(state)
  local runtime = Fake.vm(state)
  runtime.command = function(x, y, queue) runtime.command_at({x = x, y = y or 0}, queue) end
  runtime.tick = function(amount) runtime.advance(amount or 1) end
  runtime.path = function(id, path)
    runtime.events[runtime.env.defines.events.on_script_path_request_finished]({id = id, path = path})
  end
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

local function arrive(runtime, state, x, path_id)
  runtime.path(path_id, {{position = {x = x, y = 0}}})
  state.character.position = {x = x, y = 0}
  runtime.tick()
end

local function printed_key(state, key)
  for _, message in ipairs(state.printed) do
    if type(message) == "table" and message[1] == key then return true end
  end
  return false
end

test("disable on arrival turns the mode off only after the last queued goal", function()
  local state = engine()
  state.player_settings = Fake.player_settings({["c2m-disable-on-arrival"] = true})
  local runtime = vm(state); runtime.init()
  runtime.command(100); runtime.command(200, 0, true)
  arrive(runtime, state, 100, 1)
  assert(state.enabled and #runtime.pd.get_all()[1].goals == 1, "an intermediate goal disabled the mode")
  arrive(runtime, state, 200, 2)
  assert(not runtime.pd.get_all()[1] and state.enabled == false)
  assert(printed_key(state, "click2move.disabled-on-arrival"))
  runtime.command(300)
  assert(not runtime.pd.get_all()[1], "a disabled mode accepted a movement click")
end)

test("disable on arrival leaves the mode on when the setting is off", function()
  local state = engine(); local runtime = vm(state); runtime.init()
  runtime.command(100); arrive(runtime, state, 100, 1)
  assert(not runtime.pd.get_all()[1] and state.enabled and not printed_key(state, "click2move.disabled-on-arrival"))
end)

test("disable on arrival ignores cancelled and unreachable routes", function()
  local state = engine()
  state.player_settings = Fake.player_settings({["c2m-disable-on-arrival"] = true})
  local runtime = vm(state); runtime.init()
  runtime.command(100); runtime.tick()
  runtime.events[runtime.env.defines.events.on_gui_click]({player_index = 1,
    element = {valid = true, name = "c2m_cancel_button"}})
  assert(not runtime.pd.get_all()[1] and state.enabled, "GUI cancel disabled the mode")
  runtime.command(200)
  runtime.path(2, {})
  assert(not runtime.pd.get_all()[1] and state.enabled, "an unreachable goal disabled the mode")
  assert(printed_key(state, "click2move.no-path-found"))
end)

test("disable on arrival also applies to straight-line flight", function()
  local state = engine(); state.flying = true
  state.player_settings = Fake.player_settings({["c2m-disable-on-arrival"] = true})
  local runtime = vm(state); runtime.init(); runtime.command(1)
  runtime.tick()
  assert(not runtime.pd.get_all()[1] and state.enabled == false)
end)

local function spider_engine(interval)
  local state = engine(interval)
  local spider = {valid = true, type = "spider-vehicle", position = {x = 0, y = 0},
    surface = state.surface, walking_state = {walking = false, direction = 0}, writes = 0}
  setmetatable(spider, {
    __index = function(self, key)
      if key == "autopilot_destination" then return self.destinations[1] end
      if key == "autopilot_destinations" then return self.destinations end
      if key == "follow_target" then return self.following end
    end,
    __newindex = function(self, key, value)
      if key == "follow_target" then rawset(self, "following", value); return end
      assert(key == "autopilot_destination", "unexpected spider write " .. tostring(key))
      rawset(self, "destinations", value and {{x = value.x, y = value.y}} or {})
      rawset(self, "writes", self.writes + 1)
    end
  })
  rawset(spider, "destinations", {})
  state.player.vehicle, state.player.physical_vehicle = spider, spider
  state.player.spidertron_remote_selection = {}
  return state, spider
end

-- Native spiders finish under two tiles short, remove the finished destination,
-- then raise the event; the event does not say which destination finished.
local function finish_spider_command(runtime, spider)
  local destination = table.remove(spider.destinations, 1)
  spider.position = {x = destination.x - 1.9, y = destination.y}
  runtime.events[runtime.env.defines.events.on_spider_command_completed]({vehicle = spider})
end

local function use_remote(runtime, state, spider, position, selected)
  rawset(spider, "destinations", selected and {position} or spider.destinations)
  state.player.spidertron_remote_selection = selected and {spider} or {}
  runtime.events[runtime.env.defines.events.on_player_used_spidertron_remote]({player_index = 1, position = position})
end

test("occupied spidertron takeover clears autopilot and preserves walking input", function()
  local state, spider = spider_engine()
  spider.walking_state = {walking = true, direction = 12}
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

test("spidertrons follow their autopilot until on_spider_command_completed", function()
  local state, spider = spider_engine(60)
  state.player_settings = Fake.player_settings({["c2m-disable-on-arrival"] = true})
  local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
  assert(spider.autopilot_destination.x == 100 and spider.writes == 1, "the click did not command the spider")
  spider.position = {x = 97, y = 0} -- Inside the old 6-tile radius; the autopilot has not finished.
  for _ = 1, 120 do runtime.tick() end
  assert(spider.writes == 1, "autopilot destination was rewritten")
  assert(#runtime.pd.get_all()[1].goals == 2, "spider stopped before its autopilot finished")
  finish_spider_command(runtime, spider); runtime.tick()
  assert(#runtime.pd.get_all()[1].goals == 1 and spider.autopilot_destination.x == 200)
  finish_spider_command(runtime, spider); runtime.tick()
  assert(not runtime.pd.get_all()[1] and state.enabled == false)
end)

test("a completed remote command cannot restart the replaced spider route", function()
  for _, remote_event in ipairs({true, false}) do
    local state, spider = spider_engine(60)
    local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
    runtime.tick(); local writes = spider.writes
    local remote = {x = 40, y = 40}
    if remote_event then use_remote(runtime, state, spider, remote, true)
    else rawset(spider, "destinations", {remote}) end -- Another mod's script command.
    finish_spider_command(runtime, spider)
    for _ = 1, 120 do runtime.tick() end
    assert(not runtime.pd.get_all()[1] and state.enabled, "replaced route survived")
    assert(spider.writes == writes and #spider.destinations == 0, "old route moved the spider after the remote command")
  end
end)

test("a remote command before the first movement update is never overwritten", function()
  local state, spider = spider_engine(60)
  local runtime = vm(state); runtime.init(); runtime.command(100)
  local writes = spider.writes
  use_remote(runtime, state, spider, {x = -50, y = 0}, true)
  for _ = 1, 120 do runtime.tick() end
  assert(not runtime.pd.get_all()[1] and spider.writes == writes and spider.autopilot_destination.x == -50)
end)

test("remote commands for other spiders and queued remote stops keep or end routes correctly", function()
  local state, spider = spider_engine(60)
  local runtime = vm(state); runtime.init(); runtime.command(100)
  use_remote(runtime, state, spider, {x = -50, y = 0}, false)
  assert(runtime.pd.get_all()[1], "another spider's remote command cancelled this route")
  spider.destinations[2] = {x = 300, y = 0} -- Queued behind ours by script.
  finish_spider_command(runtime, spider)
  runtime.tick()
  assert(not runtime.pd.get_all()[1] and spider.autopilot_destination.x == 300, "a queued foreign stop was overwritten")
end)

test("a destination assigned after our completion is never overwritten", function()
  for _, interval in ipairs({1, 60}) do
    local state, spider = spider_engine(interval)
    local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
    runtime.tick(); local writes = spider.writes
    finish_spider_command(runtime, spider)
    assert(runtime.pd.get_all()[1].spider_arrived, "our own completion was rejected")
    rawset(spider, "destinations", {{x = -50, y = 0}}) -- Another mod's completion handler.
    for _ = 1, 120 do runtime.tick() end
    assert(not runtime.pd.get_all()[1], "route survived a newer foreign destination")
    assert(spider.writes == writes and spider.autopilot_destination.x == -50, "foreign destination was overwritten")
  end
end)

test("a foreign command finishing near our goal is not accepted as arrival", function()
  local state, spider = spider_engine(60)
  local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
  runtime.tick(); local writes = spider.writes
  rawset(spider, "destinations", {{x = 96, y = 0}}) -- Script command inside the 6-tile vehicle radius.
  finish_spider_command(runtime, spider) -- Stops at x = 94, six tiles short of our goal.
  assert(not runtime.pd.get_all()[1].spider_arrived, "foreign completion was accepted")
  for _ = 1, 120 do runtime.tick() end
  assert(not runtime.pd.get_all()[1] and spider.writes == writes and #spider.destinations == 0)
end)

test("a foreign command finishing just outside the native completion radius is rejected", function()
  local state, spider = spider_engine(1)
  local runtime = vm(state); runtime.init(); runtime.command(40); runtime.command(80, 0, true)
  runtime.tick(); local writes = spider.writes
  -- Native reproduction: at x = 37.355 another mod sends the spider half a tile
  -- ahead, which the engine completes at once, 2.645 tiles from our goal.
  spider.position = {x = 37.355, y = 0}
  rawset(spider, "destinations", {})
  runtime.events[runtime.env.defines.events.on_spider_command_completed]({vehicle = spider})
  assert(not runtime.pd.get_all()[1].spider_arrived, "foreign completion 2.645 tiles away was accepted")
  runtime.tick()
  assert(not runtime.pd.get_all()[1] and spider.writes == writes and #spider.destinations == 0)
end)

test("a remote for another spider does not cancel a completed leg", function()
  local state, spider = spider_engine(60)
  local runtime = vm(state); runtime.init(); runtime.command(100); runtime.command(200, 0, true)
  runtime.tick()
  finish_spider_command(runtime, spider)
  use_remote(runtime, state, spider, {x = -50, y = 0}, false)
  assert(runtime.pd.get_all()[1], "unrelated remote cancelled a pending completion")
  for _ = 1, 60 do runtime.tick() end
  local data = runtime.pd.get_all()[1]
  assert(data and #data.goals == 1 and spider.autopilot_destination.x == 200)
end)

test("disconnect and migration cleanup never erase a newer foreign spider command", function()
  for _, cleanup in ipairs({"disconnect", "migration"}) do
    local state, spider = spider_engine(1)
    local runtime = vm(state); runtime.init(); runtime.command(40); runtime.command(80, 0, true)
    runtime.tick(); local writes = spider.writes
    rawset(spider, "destinations", {{x = -50, y = 0}}) -- Another script takes over.
    state.player.connected = false
    if cleanup == "disconnect" then runtime.tick() else runtime.migrate() end
    assert(not runtime.pd.get_all()[1], cleanup .. " kept the route")
    assert(spider.writes == writes and spider.autopilot_destination.x == -50, cleanup .. " erased the foreign command")
  end
end)

test("cleanup still stops Click2Move's own spider command, including 0.1.14 routes", function()
  for _, saved in ipairs({"current", "0.1.14"}) do
    local state, spider = spider_engine(1)
    local runtime = vm(state); runtime.init(); runtime.command(40)
    runtime.tick()
    if saved == "0.1.14" then runtime.pd.get_all()[1].spider_destination = nil end
    state.player.connected = false
    runtime.migrate()
    assert(not runtime.pd.get_all()[1] and #spider.destinations == 0, saved .. " route left the spider walking")
  end
end)

-- 0.1.14 sent the current goal to the autopilot without recording it.
local function legacy_spider_route(runtime, spider)
  local data = runtime.pd.get_all()[1]
  data.spider_destination = nil
  rawset(spider, "destinations", {{x = 40, y = 0}})
  return data
end

test("0.1.14 spider routes adopt an autopilot still following their goal", function()
  for _, upgrade in ipairs({"first update", "migration"}) do
    local state, spider = spider_engine(1)
    local runtime = vm(state); runtime.init(); runtime.command(40); runtime.command(80, 0, true)
    local data = legacy_spider_route(runtime, spider); local writes = spider.writes
    if upgrade == "migration" then runtime.migrate() end
    runtime.tick()
    assert(runtime.pd.get_all()[1] == data and data.spider_destination.x == 40, upgrade .. " did not adopt the command")
    assert(spider.writes == writes, upgrade .. " rewrote the adopted command")
    finish_spider_command(runtime, spider); runtime.tick()
    assert(#data.goals == 1 and spider.autopilot_destination.x == 80)
  end
end)

test("0.1.14 spider routes replaced by a newer command are removed without overwriting it", function()
  for _, upgrade in ipairs({"first update", "migration"}) do
    local state, spider = spider_engine(1)
    local runtime = vm(state); runtime.init(); runtime.command(40); runtime.command(80, 0, true)
    legacy_spider_route(runtime, spider)
    rawset(spider, "destinations", {{x = -50, y = 0}})
    local writes = spider.writes
    if upgrade == "migration" then
      runtime.migrate()
      assert(not runtime.pd.get_all()[1], "migration kept the stale route until the next update")
    end
    for _ = 1, 5 do runtime.tick() end
    assert(not runtime.pd.get_all()[1], upgrade .. " kept the stale route")
    assert(spider.writes == writes and spider.autopilot_destination.x == -50, upgrade .. " overwrote the newer command")
  end
end)

test("a follow order is foreign during a leg, after its completion and during cleanup", function()
  for _, moment in ipairs({"en route", "after completion", "before disconnect"}) do
    local state, spider = spider_engine(1)
    local runtime = vm(state); runtime.init(); runtime.command(40); runtime.command(80, 0, true)
    runtime.tick()
    local leader = {valid = true, type = "character"}
    if moment == "after completion" then finish_spider_command(runtime, spider) end
    -- Native follow orders leave the destination queue empty.
    rawset(spider, "destinations", {}); rawset(spider, "following", leader)
    local writes = spider.writes
    if moment == "before disconnect" then state.player.connected = false end
    for _ = 1, 5 do runtime.tick() end
    assert(not runtime.pd.get_all()[1], moment .. ": route survived a follow order")
    assert(spider.follow_target == leader and spider.writes == writes, moment .. ": follow order was overwritten")
  end
end)

test("a new click overrides a follow order the player gave earlier", function()
  local state, spider = spider_engine(1)
  rawset(spider, "following", {valid = true, type = "character"})
  local runtime = vm(state); runtime.init(); runtime.command(40)
  runtime.tick()
  assert(runtime.pd.get_all()[1] and not spider.follow_target and spider.autopilot_destination.x == 40)
end)

test("migration rebuilds markers for an active flight route", function()
  local state = engine(); state.flying = true
  local runtime = vm(state); runtime.init(); runtime.command(100)
  local data = runtime.pd.get_all()[1]
  local markers = data.goals[1].rendering
  markers.number, markers.numbers = markers.numbers[1], nil -- The 0.1.14 layout.
  runtime.migrate()
  local numbers = data.goals[1].rendering.numbers
  assert(numbers and #numbers == 2 and numbers[2].spec.render_mode == "chart", "flight markers were not rebuilt")
  assert(data.is_straight_line_move and #data.goals == 1)
end)

for _, entry in ipairs(tests) do entry[2](); print("PASS " .. entry[1]) end
print(#tests .. " movement/lifecycle tests passed")
