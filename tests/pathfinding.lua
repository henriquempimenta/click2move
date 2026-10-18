-- Run from the mod directory: lua tests/pathfinding.lua
package.path = "./?.lua;" .. package.path
local Fake = dofile("tests/support/fake-factorio.lua")
local count = 0
local function test(name, run)
  run()
  count = count + 1
  print("PASS " .. name)
end
local function equal(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local all, submitted, rendered, destroyed, reads
local surface, entity, player, Pathfinding, Rendering
local function fixture(goals)
  for _, name in ipairs({"scripts/pathfinding", "scripts/rendering"}) do package.loaded[name] = nil end
  storage = {}
  all, submitted, rendered, destroyed, reads = {}, {}, {}, 0, 0
  surface = {index = 1, request_path = function(params)
    submitted[#submitted + 1] = params
    return #submitted
  end}
  entity = {valid = true, type = "character", position = {x = 0, y = 0}, surface = surface,
    prototype = {collision_box = {left_top = {x = -.2, y = -.2}, right_bottom = {x = .2, y = .2}}, collision_mask = {layers = {}}}}
  player = {index = 1, valid = true, connected = true, character = entity, surface = surface,
    force = {name = "player"}, color = {r = 1, g = 1, b = 1}, print = function() end}
  game = Fake.game({tick = 0, player = player})
  local data = {goals = {}, move_entity = entity, current_waypoint = 7, stuck_state = "sliding", stuck_timer = 12}
  for i = 1, goals or 2 do data.goals[i] = {position = {x = i * 100, y = 0}} end
  all[1] = data
  package.loaded["scripts/player-data"] = {
    MAX_PATH_RETRIES = 5, PATH_RETRY_DELAY_TICKS = 60,
    get_all = function() reads = reads + 1; return all end,
    check_route_surface = function(d, e)
      return d.route_surface_index == nil or d.route_surface_index == e.surface.index
    end,
    can_control_entity = function() return true end,
    reset_movement_state = function(d) d.current_waypoint = 1; d.stuck_state = "none"; d.stuck_timer = 0 end,
    stop_input = function(e) if e and e.valid then e.walking_state = {walking = false} end end,
    cleanup_movement = function(e, d) if e.valid then e.walking_state = {walking = false} end; Rendering.destroy_paths(d) end,
    remove = function(i) Pathfinding.cancel_player(i, all[i]); Rendering.destroy_paths(all[i]); all[i] = nil end
  }
  package.loaded["scripts/config"] = {get = function() return {character_margin = .45, vehicle_path_margin = 2} end,
    is_debug = function() return false end}
  package.loaded["scripts/gui"] = {update = function() end}
  local function draw(options)
    equal(options.time_to_live, 0)
    local object = {valid = true, options = options, color = options.color, text = options.text}
    object.destroy = function() if object.valid then object.valid = false; destroyed = destroyed + 1 end end
    rendered[#rendered + 1] = object
    return object
  end
  rendering = {draw_line = draw, draw_circle = draw, draw_text = draw}
  Rendering = require("scripts/rendering")
  Pathfinding = require("scripts/pathfinding")
  Pathfinding.init()
  return data
end
local function finish(id, start, goal)
  Pathfinding.on_path_request_finished({id = id, path = {{position = {x = start, y = 0}}, {position = {x = goal, y = 0}}}})
end

test("characters and cars request obstacle-safe paths directly regardless of their force", function()
  local clean = {{position = {x = 0, y = 0}}, {position = {x = 50, y = 20}}, {position = {x = 100, y = 0}}}
  for _, kind in ipairs({"character", "car"}) do
    for _, force in ipairs({"player", "enemy", "custom"}) do
      local data = fixture(1)
      entity.type, entity.force, player.force = kind, {name = force}, {name = force}
      Pathfinding.request_paths_for_player(1)
      equal(submitted[1].force, "neutral")
      equal(submitted[1].pathfind_flags.allow_destroy_friendly_entities, false)
      equal(submitted[1].collision_mask, entity.prototype.collision_mask)
      Pathfinding.on_path_request_finished({id = 1, path = clean})
      equal(data.goals[1].path, clean)
      equal(#submitted, 1)
      equal(next(storage.c2m_path_requests), nil)
    end
  end
end)

test("destructive paths are rejected without another request, including results from older saves", function()
  local through = {{position = {x = 0, y = 0}}, {position = {x = 50, y = 0}, needs_destroy_to_reach = true},
    {position = {x = 100, y = 0}}}
  for _, saved in ipairs({"current", "legacy"}) do
    fixture(1)
    local printed = {}
    player.print = function(message) printed[#printed + 1] = message end
    entity.walking_state = {walking = true}
    Pathfinding.request_paths_for_player(1)
    if saved == "legacy" then
      storage.c2m_path_requests[1].params = {force = "player"}
      package.loaded["scripts/pathfinding"] = nil
      Pathfinding = require("scripts/pathfinding")
      Pathfinding.load()
    end
    Pathfinding.on_path_request_finished({id = 1, path = through})
    equal(#submitted, 1)
    equal(all[1], nil)
    equal(entity.walking_state.walking, false)
    equal(next(storage.c2m_path_requests), nil)
    equal(printed[1][1], "click2move.no-path-found")
    equal(#printed, 1)
  end
end)

test("failed first leg repaths its successor from the actual position and resets controller", function()
  local data = fixture()
  Pathfinding.request_paths_for_player(1)
  finish(2, 100, 200)
  entity.walking_state = {walking = true}
  Pathfinding.on_path_request_finished({id = 1})
  equal(entity.walking_state.walking, false)
  equal(#submitted, 3)
  equal(submitted[3].start.x, 0)
  equal(submitted[3].goal.x, 200)
  equal(data.goals[1].path, nil)
  equal(data.current_waypoint, 1)
  equal(data.stuck_state, "none")
end)

test("failed intermediate leg invalidates successor and rejects its old callback", function()
  local data = fixture(3)
  Pathfinding.request_paths_for_player(1)
  Pathfinding.on_path_request_finished({id = 2})
  equal(submitted[4].start.x, 100)
  equal(submitted[4].goal.x, 300)
  Pathfinding.on_path_request_finished({id = 3, path = {{position = {x = 200, y = 0}}}})
  equal(data.goals[2].path, nil)
  equal(data.goals[2].path_id, 4)
end)

test("completed goal retains successor path and refills only the bounded window", function()
  local data = fixture(100)
  Pathfinding.request_paths_for_player(1)
  equal(#submitted, 3)
  finish(1, 0, 100); finish(2, 100, 200); finish(3, 200, 300)
  local path = data.goals[2].path
  Pathfinding.remove_goal(1, 1, true)
  equal(data.goals[1].path, path)
  equal(#submitted, 4)
  local before = reads
  for tick = 1, 600 do Pathfinding.on_tick(tick) end
  equal(reads, before)
  before = reads
  Pathfinding.on_path_request_finished({id = 999999})
  equal(reads, before)
end)

test("busy retries dispatch exactly at their deadline and survive binding on load", function()
  local data = fixture(1)
  Pathfinding.request_paths_for_player(1)
  equal(submitted[1].force, "neutral")
  Pathfinding.on_path_request_finished({id = 1, try_again_later = true})
  for tick = 1, 59 do game.tick = tick; Pathfinding.on_tick(tick) end
  equal(#submitted, 1)
  package.loaded["scripts/pathfinding"] = nil
  Pathfinding = require("scripts/pathfinding")
  Pathfinding.load()
  game.tick = 60
  Pathfinding.on_tick(60)
  equal(#submitted, 2)
  equal(submitted[2].force, "neutral")
  finish(2, 0, 100)
  assert(data.goals[1].path)
end)

test("invalidating a busy leg cancels only its retry deadline", function()
  fixture(2)
  Pathfinding.request_paths_for_player(1)
  Pathfinding.on_path_request_finished({id = 1, try_again_later = true})
  game.tick = 5
  Pathfinding.on_path_request_finished({id = 2, try_again_later = true})
  Pathfinding.invalidate_goal(1, 1)
  equal(storage.c2m_next_retry_tick, 65)
  Pathfinding.request_paths_for_player(1)
  equal(#submitted, 3)
  local before = reads
  game.tick = 60
  Pathfinding.on_tick(60)
  equal(reads, before)
  game.tick = 65
  Pathfinding.on_tick(65)
  equal(#submitted, 4)
end)

test("active repathing stops old walking input while awaiting its new route", function()
  local data = fixture(1)
  Pathfinding.request_paths_for_player(1)
  finish(1, 0, 100)
  entity.walking_state = {walking = true}
  Pathfinding.invalidate_goal(1)
  equal(entity.walking_state.walking, false)
  Pathfinding.request_paths_for_player(1)
  equal(data.goals[1].path_id, 2)
end)

test("queue replacement removes associations and ignores old results", function()
  local data = fixture(2)
  Pathfinding.request_paths_for_player(1)
  Pathfinding.cancel_player(1, data)
  data.goals = {{position = {x = 300, y = 0}}}
  Pathfinding.request_paths_for_player(1, true)
  finish(1, 0, 100); finish(2, 100, 200)
  equal(data.goals[1].path, nil)
  finish(3, 0, 300)
  equal(data.goals[1].path[2].position.x, 300)
end)

test("disconnect during a path callback stops entity input before state removal", function()
  fixture(2)
  entity.walking_state = {walking = true}
  Pathfinding.request_paths_for_player(1)
  player.connected = false
  finish(1, 0, 100)
  equal(entity.walking_state.walking, false)
  equal(all[1], nil)
  equal(next(storage.c2m_path_requests), nil)
  equal(destroyed, #rendered)
end)

test("destroyed movement entities cannot accept delayed path results", function()
  fixture(1)
  Pathfinding.request_paths_for_player(1)
  entity.valid = false
  finish(1, 0, 100)
  equal(all[1], nil)
  equal(next(storage.c2m_path_requests), nil)
end)

test("pending requests survive module reload through persisted direct associations", function()
  local data = fixture(1)
  Pathfinding.request_paths_for_player(1)
  package.loaded["scripts/pathfinding"] = nil
  Pathfinding = require("scripts/pathfinding")
  Pathfinding.load()
  finish(1, 0, 100)
  assert(data.goals[1].path)
end)

test("flying queues keep markers without native requests and resume after landing", function()
  local data = fixture(3)
  data.is_straight_line_move = true
  Pathfinding.request_paths_for_player(1, true)
  equal(#submitted, 0)
  equal(#rendered, 12)
  Pathfinding.remove_goal(1, 1, true)
  equal(#submitted, 0)
  data.is_straight_line_move = nil
  Pathfinding.request_paths_for_player(1, true)
  equal(#submitted, 2)
end)

test("100 route responses create each persistent segment once, merge map lines and keep the physical surface", function()
  local data = fixture(100)
  player.surface = {index = 2}
  Rendering.render_paths_for_player(1, all)
  for i, goal in ipairs(data.goals) do
    goal.path = {}
    for j = 0, 100 do goal.path[#goal.path + 1] = {position = {x = (i - 1) * 100 + j, y = 0}} end
    Rendering.render_goal(1, data, goal, i)
  end
  equal(#rendered, 10500)
  equal(destroyed, 0)
  -- Map view gets one merged line and one zoom-scaled number per straight goal.
  local chart_lines, chart_numbers = 0, 0
  for _, object in ipairs(rendered) do
    if object.options.render_mode == "chart" then
      if object.options.text then
        chart_numbers = chart_numbers + 1
        equal(object.options.scale_with_zoom, true)
      else
        chart_lines = chart_lines + 1
        equal(object.options.to.x - object.options.from.x, 100)
      end
    end
  end
  equal(chart_lines, 100)
  equal(chart_numbers, 100)
  for _, object in ipairs(rendered) do equal(object.options.surface, surface) end
  Rendering.render_paths_for_player(1, all)
  equal(#rendered, 10500)
  local removed = table.remove(data.goals, 1)
  Rendering.clear_goal(removed)
  Rendering.render_paths_for_player(1, all)
  equal(data.goals[1].rendering.numbers[1].text, "1")
  equal(data.goals[1].rendering.numbers[2].text, "1")
  equal(#rendered, 10500)
  Rendering.destroy_paths(data)
  equal(destroyed, 10500)
end)

test("debug overlays ignore absent or invalid tracked entities", function()
  fixture(1)
  package.loaded["scripts/config"].get = function() return {debug_margins = true, debug_curve = true} end
  local debug_rendering = require("scripts/debug-rendering")
  local before = #rendered
  debug_rendering.draw(player, {}, {path_clearance = 2}, {{x = 0, y = 0}}, surface, {})
  local invalid = setmetatable({valid = false}, {__index = function(_, key) error("invalid entity read: " .. key) end})
  debug_rendering.draw(player, {move_entity = invalid}, {path_clearance = 2}, {{x = 0, y = 0}}, surface, {})
  equal(#rendered, before)
end)

print(count .. " pathfinding/rendering tests passed")
