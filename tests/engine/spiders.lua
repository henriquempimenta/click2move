-- Appended only to the isolated native test copy. Players/UI are mocked;
-- spidertron autopilot, completion events, equipment, positions and rendering
-- are native. Every spider is ordered 40 -> 80 by the production input handlers.
--   1: plain route.
--   2: another mod assigns a destination in its completion handler.
--   3: fast spider: five placed exoskeletons on two charged batteries.
--   4/5: another mod's command finishes 4-6 and 2.2-3 tiles from our goal,
--        outside the native completion radius.
--   6: another script takes over and the player disconnects before the next
--      movement check.
--   7: another mod gives a follow order in its completion handler.
--   8: a 0.1.14 route (no recorded command) still owns the autopilot.
--   9: a 0.1.14 route whose autopilot another script has since replaced.
-- Spiders drift a few tiles after stopping, so routes are judged by direction.
local Config = require("scripts/config")
local Pathfinding = require("scripts/pathfinding")
local Movement = require("scripts/movement")
local PlayerData = require("scripts/player-data")
local get_config = Config.get
Config.get = function(index) return get_config(index and 0 or nil) end
local native_rendering = rendering
rendering = setmetatable({}, {__index = native_rendering})
for _, name in ipairs({"draw_line", "draw_text", "draw_circle"}) do
  rendering[name] = function(p) p.players = nil; return native_rendering[name](p) end
end
local SPIDERS = 9
local ROWS = {-80, -60, -40, -20, 0, 20, 40, 60, 80}
local completions = {}
local remove_goal = Pathfinding.remove_goal
Pathfinding.remove_goal = function(i, g, completed)
  completions[i] = (completions[i] or "") .. (completed and "C" or "F")
  return remove_goal(i, g, completed)
end
local native_game
local function bind()
  native_game = native_game or game
  local players = {}
  for i, spider in ipairs(storage.probe.spiders) do
    local top = {}
    top.add = function(spec)
      local f = {valid = true}
      f.add = function(c) f[c.name] = {valid = true}; return f[c.name] end
      f.destroy = function() f.valid = false; top[spec.name] = nil end
      top[spec.name] = f; return f
    end
    players[i] = {index = i, valid = true, connected = true, force = native_game.forces.player,
      surface = spider.surface, vehicle = spider, physical_vehicle = spider, color = {r = 1, g = 0, b = 0},
      gui = {top = top}, print = function() end, opened_gui_type = defines.gui_type.none,
      controller_type = defines.controllers.character, spidertron_remote_selection = {},
      is_shortcut_toggled = function() return true end, set_shortcut_toggled = function() end}
  end
  game = setmetatable({players = players}, {__index = native_game})
end

local function equip_fast_spider(spider)
  local grid = spider.grid
  for column = 0, 8, 2 do
    assert(grid.put{name = "exoskeleton-equipment", position = {column, 0}}, "exoskeleton did not fit")
  end
  for column = 0, 1 do
    local battery = assert(grid.put{name = "battery-equipment", position = {column, 4}}, "battery did not fit")
    battery.energy = battery.max_energy
  end
  assert(grid.count("exoskeleton-equipment") == 5, "fast spider does not have five exoskeletons")
end

-- Spiders 4 and 5: a foreign command half a tile ahead completes during this
-- tick's entity update, before the next movement update.
local foreign_windows = {[4] = {34, 36}, [5] = {37, 37.8}}
script.on_nth_tick(2, function()
  local probe = storage.probe
  if not probe then return end
  local spiders = probe.spiders
  for _, i in ipairs({1, 3}) do probe.peak[i] = math.max(probe.peak[i], math.abs(spiders[i].speed)) end
  probe.bonus = math.max(probe.bonus, spiders[3].grid.movement_bonus)
  for i, window in pairs(foreign_windows) do
    local spider = spiders[i]
    if not probe.near_goal[i] and spider.position.x >= window[1] and spider.position.x <= window[2] then
      probe.near_goal[i] = spider.position.x
      spider.autopilot_destination = {spider.position.x + 0.5, spider.position.y}
    end
  end
  if not probe.disconnected and spiders[6].position.x >= 20 then
    probe.disconnected = true
    spiders[6].autopilot_destination = {-50, spiders[6].position.y}
    game.players[6].connected = false
  end
  -- 0.1.14 sent the goal to the autopilot without recording it.
  for _, i in ipairs({8, 9}) do
    if not probe.legacy[i] and spiders[i].position.x >= 10 then
      probe.legacy[i] = true
      PlayerData.get_all()[i].spider_destination = nil
      if i == 9 then spiders[i].autopilot_destination = {-50, spiders[i].position.y} end
    end
  end
end)

script.on_nth_tick(5, function(e)
  if not storage.probe then
    local s = game.create_surface("c2m-spider", {width = 512, height = 512})
    s.request_to_generate_chunks({0, 0}, 6); s.force_generate_chunk_requests()
    for _, ent in pairs(s.find_entities()) do ent.destroy() end
    local t = {} for x = -100, 140 do for y = -90, 90 do t[#t + 1] = {name = "grass-1", position = {x, y}} end end
    s.set_tiles(t)
    storage.probe = {spiders = {}, peak = {[1] = 0, [3] = 0}, bonus = 0, near_goal = {}, legacy = {}}
    for i = 1, SPIDERS do
      storage.probe.spiders[i] = s.create_entity{name = "spidertron", position = {0, ROWS[i]}, force = "player"}
    end
    equip_fast_spider(storage.probe.spiders[3])
    storage.probe.leader = s.create_entity{name = "character", position = {0, ROWS[7] + 3}, force = "player"}
    bind()
    local move = script.get_event_handler("c2m-move-command")
    local queue = script.get_event_handler("c2m-move-command-queue")
    for i, sp in ipairs(storage.probe.spiders) do
      move({player_index = i, input_name = "c2m-move-command", cursor_position = {x = 40, y = sp.position.y}})
      queue({player_index = i, input_name = "c2m-move-command-queue", cursor_position = {x = 80, y = sp.position.y}})
    end
    local completed = script.get_event_handler(defines.events.on_spider_command_completed)
    script.on_event(defines.events.on_spider_command_completed, function(event)
      local probe = storage.probe
      for _, i in ipairs({1, 3, 8}) do
        local data = PlayerData.get_all()[i]
        local spider = probe.spiders[i]
        if spider == event.vehicle and data and data.spider_destination then
          local d = data.spider_destination
          local distance = math.sqrt((spider.position.x - d.x) ^ 2 + (spider.position.y - d.y) ^ 2)
          probe.stop = math.max(probe.stop or 0, distance)
        end
      end
      completed(event)
      -- Other mods' completion handlers run after Click2Move's.
      if event.vehicle == probe.spiders[2] and not probe.foreign then
        probe.foreign = true
        event.vehicle.autopilot_destination = {-50, event.vehicle.position.y}
      elseif event.vehicle == probe.spiders[7] and not probe.follow then
        probe.follow = true
        event.vehicle.follow_target = probe.leader
      end
    end)
  end

  if e.tick == 1800 then
    local probe = storage.probe
    local spiders, data = probe.spiders, PlayerData.get_all()
    for i = 1, SPIDERS do assert(not data[i], "spider " .. i .. " still has a route") end
    for _, i in ipairs({1, 3, 8}) do
      assert(completions[i] == "CC", "spider " .. i .. " did not arrive twice: " .. tostring(completions[i]))
    end
    assert(probe.bonus > 0 and probe.peak[3] > probe.peak[1] * 1.2,
      string.format("fast spider was not faster: bonus %.2f, peak %.3f vs %.3f", probe.bonus, probe.peak[3], probe.peak[1]))
    assert(not completions[2] and spiders[2].position.x < -40, "foreign destination after completion was overwritten")
    for i = 4, 5 do
      assert(probe.near_goal[i], "spider " .. i .. " never reached its foreign-command window")
      assert(not completions[i] and spiders[i].position.x < 60, "spider " .. i .. ": foreign completion near the goal was accepted")
    end
    assert(probe.disconnected and not completions[6] and spiders[6].position.x < -40,
      "disconnect cleanup erased the foreign command")
    assert(probe.follow and spiders[7].follow_target == probe.leader and spiders[7].position.x < 60,
      "follow order after completion was overwritten")
    assert(probe.legacy[9] and not completions[9] and spiders[9].position.x < -40,
      "0.1.14 route overwrote a newer command")
    -- Every genuine arrival must lie inside the radius used to accept arrivals.
    assert(probe.stop < Movement.SPIDER_ARRIVAL_RADIUS,
      string.format("native arrival at %.3f tiles exceeds the arrival radius", probe.stop))
    print(string.format("C2M_NATIVE_SPIDERS_OK %d max_completion_distance=%.3f foreign_at=%.3f speedup=%.2f",
      SPIDERS, probe.stop, probe.near_goal[5], probe.peak[3] / probe.peak[1]))
  end
end)
