-- Each queued goal owns its persistent markers and path segments. Routes are
-- drawn twice: "game" objects show in the world and close remote view, while
-- "chart" objects show once remote view zooms out to the map.
local Util = require("scripts/util")
local Config = require("scripts/config")
local DebugRendering = require("scripts/debug-rendering")
local Rendering = {}

local RENDER_MODES = {"game", "chart"}

local function copy_color(color, alpha)
  local source = color or {r = 0.1, g = 0.8, b = 0.1, a = 0.9}
  return {r = source.r or source[1] or 0.1, g = source.g or source[2] or 0.8,
    b = source.b or source[3] or 0.1, a = alpha or source.a or source[4] or 0.9}
end

function Rendering.draw_target_crosshair(player, position, color, surface)
  local objects = {}
  for _, offset in ipairs({{x = 0.5, y = 0}, {x = 0, y = 0.5}}) do
    objects[#objects + 1] = rendering.draw_line{
      color = copy_color(color or player.color, 0.9), width = 3,
      from = {x = position.x - offset.x, y = position.y - offset.y},
      to = {x = position.x + offset.x, y = position.y + offset.y},
      surface = surface or player.surface, players = {player}, time_to_live = 0
    }
  end
  return objects
end

function Rendering.draw_goal_number(player, position, index, color, surface, render_mode)
  local chart = render_mode == "chart"
  return rendering.draw_text{
    text = tostring(index), color = copy_color(color or player.color, index == 1 and 1 or 0.65),
    target = position, surface = surface or player.surface, players = {player},
    scale = chart and 1.5 or 1.2, scale_with_zoom = chart, render_mode = render_mode,
    alignment = "center", vertical_alignment = "middle", time_to_live = 0
  }
end

function Rendering.clear_goal(goal)
  local state = goal.rendering
  if state then
    Util.safe_destroy_renderings(state.markers)
    Util.safe_destroy_renderings(state.path_objects)
    goal.rendering = nil
  end
end

function Rendering.destroy_paths(data)
  Util.safe_destroy_renderings(data.render_objs) -- Pre-release rendering layout.
  data.render_objs = nil
  for _, goal in ipairs(data.goals or {}) do Rendering.clear_goal(goal) end
end
Rendering.clear_player = Rendering.destroy_paths

-- The map is viewed zoomed out, so straight runs of waypoints become one line.
local function merge_straight_runs(points)
  local merged = {points[1]}
  for index = 2, #points do
    local a, b, c = merged[#merged - 1], merged[#merged], points[index]
    local abx, aby, bcx, bcy = a and b.x - a.x, a and b.y - a.y, c.x - b.x, c.y - b.y
    if a and math.abs(abx * bcy - aby * bcx) < 0.000001 and abx * bcx + aby * bcy > 0 then
      merged[#merged] = c
    else
      merged[#merged + 1] = c
    end
  end
  return merged
end

local function draw_path(player, data, goal, index, surface)
  local state = goal.rendering
  Util.safe_destroy_renderings(state.path_objects)
  state.path_objects = {}
  state.path = goal.path
  state.drawn = true
  local config = Config.get(player.index)
  state.debug_margins, state.debug_curve = config.debug_margins, config.debug_curve
  state.debug_bezier = config.debug_bezier
  state.preview = data.preview
  local vehicle = data.move_entity and data.move_entity.type ~= "character"
  local debug = config.debug_margins or config.debug_curve or config.debug_bezier
  local color = debug and {r = 1, g = 0.85, b = 0.1, a = 0.95} or copy_color(player.color, (vehicle and 0.5 or 0.9) * (index > 1 and 0.5 or 1))
  local points = {}
  for _, waypoint in ipairs(goal.path or {}) do
    if waypoint.position then points[#points + 1] = waypoint.position end
  end
  if debug and #points == 0 and data.is_straight_line_move then
    points = {index == 1 and data.move_entity.position or data.goals[index - 1].position, goal.position}
  elseif debug and vehicle and data.move_entity.type == "spider-vehicle" and #points == 1 then
    table.insert(points, 1, index == 1 and data.move_entity.position or data.goals[index - 1].position)
  end
  if #points == 0 then return end
  local polylines = {game = points, chart = merge_straight_runs(points)}
  for _, render_mode in ipairs(RENDER_MODES) do
    local polyline = polylines[render_mode]
    for point = 2, #polyline do
      state.path_objects[#state.path_objects + 1] = rendering.draw_line{
        color = color, width = (vehicle and render_mode == "game") and 1 or 2,
        from = polyline[point - 1], to = polyline[point], surface = surface, players = {player},
        render_mode = render_mode, time_to_live = 0
      }
    end
    if #points == 1 then
      state.path_objects[#state.path_objects + 1] = rendering.draw_circle{
        color = color, radius = 0.3, target = points[1], surface = surface,
        players = {player}, render_mode = render_mode, time_to_live = 0
      }
    end
  end
  if debug then
    DebugRendering.draw(player, data, goal, merge_straight_runs(points), surface, state.path_objects)
  end
  state.curve_reference = goal.vehicle_reference and goal.vehicle_reference.geometry
end

function Rendering.render_goal(player_index, data, goal, index)
  local player = game.players[player_index]
  if not player or not player.valid then return end
  local entity = data.move_entity
  local surface = entity and entity.valid and entity.surface or player.surface
  local state = goal.rendering
  -- Saves from 0.1.14 and earlier have a single game-mode number and no map copy.
  if state and (state.surface ~= surface or not state.numbers or not state.numbers[1].valid) then
    Rendering.clear_goal(goal)
    state = nil
  end
  if not state then
    local markers = Rendering.draw_target_crosshair(player, goal.position, player.color, surface)
    local numbers = {}
    for _, render_mode in ipairs(RENDER_MODES) do
      numbers[#numbers + 1] = Rendering.draw_goal_number(player, goal.position, index, player.color, surface, render_mode)
      markers[#markers + 1] = numbers[#numbers]
    end
    state = {markers = markers, numbers = numbers, surface = surface, path_objects = {}}
    goal.rendering = state
  end
  if state.index ~= index then
    for _, number in ipairs(state.numbers) do
      if number.valid then
        number.text = tostring(index)
        number.color = copy_color(player.color, index == 1 and 1 or 0.65)
      end
    end
    state.index = index
    if not state.debug_margins and not state.debug_curve and not state.debug_bezier then
      for _, object in ipairs(state.path_objects) do
        if object.valid then
          local vehicle = entity and entity.type ~= "character"
          object.color = copy_color(player.color, (vehicle and 0.5 or 0.9) * (index > 1 and 0.5 or 1))
        end
      end
    end
  end
  local config = Config.get(player_index)
  if not state.drawn or state.path ~= goal.path or state.debug_margins ~= config.debug_margins
      or state.debug_curve ~= config.debug_curve or state.debug_bezier ~= config.debug_bezier or state.preview ~= data.preview
      or ((config.debug_curve or config.debug_bezier or config.debug_margins)
        and state.curve_reference ~= (goal.vehicle_reference and goal.vehicle_reference.geometry)) then
    draw_path(player, data, goal, index, surface)
  end
end

function Rendering.render_paths_for_player(player_index, player_move_data)
  local data = player_move_data[player_index]
  if not data then return end
  if data.render_objs then
    Util.safe_destroy_renderings(data.render_objs)
    data.render_objs = nil
  end
  for index, goal in ipairs(data.goals) do Rendering.render_goal(player_index, data, goal, index) end
end

return Rendering
