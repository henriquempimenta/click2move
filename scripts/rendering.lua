-- Each queued goal owns its persistent markers and path segments.
local Util = require("scripts/util")
local Rendering = {}

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

function Rendering.draw_goal_number(player, position, index, color, surface)
  return rendering.draw_text{
    text = tostring(index), color = copy_color(color or player.color, index == 1 and 1 or 0.65),
    target = position, surface = surface or player.surface, players = {player},
    scale = 1.2, alignment = "center", vertical_alignment = "middle", time_to_live = 0
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

local function draw_path(player, data, goal, index, surface)
  local state = goal.rendering
  Util.safe_destroy_renderings(state.path_objects)
  state.path_objects = {}
  state.path = goal.path
  local vehicle = data.move_entity and data.move_entity.type ~= "character"
  local color = copy_color(player.color, (vehicle and 0.5 or 0.9) * (index > 1 and 0.5 or 1))
  local previous
  for _, waypoint in ipairs(goal.path or {}) do
    if waypoint.position then
      if previous then
        state.path_objects[#state.path_objects + 1] = rendering.draw_line{
          color = color, width = vehicle and 1 or 2, from = previous, to = waypoint.position,
          surface = surface, players = {player}, time_to_live = 0
        }
      end
      previous = waypoint.position
    end
  end
  if goal.path and #goal.path == 1 and previous then
    state.path_objects[#state.path_objects + 1] = rendering.draw_circle{
      color = color, radius = 0.3, target = previous, surface = surface,
      players = {player}, time_to_live = 0
    }
  end
end

function Rendering.render_goal(player_index, data, goal, index)
  local player = game.players[player_index]
  if not player or not player.valid then return end
  local entity = data.move_entity
  local surface = entity and entity.valid and entity.surface or player.surface
  local state = goal.rendering
  if state and (state.surface ~= surface or not state.number.valid) then
    Rendering.clear_goal(goal)
    state = nil
  end
  if not state then
    local markers = Rendering.draw_target_crosshair(player, goal.position, player.color, surface)
    local number = Rendering.draw_goal_number(player, goal.position, index, player.color, surface)
    markers[#markers + 1] = number
    state = {markers = markers, number = number, surface = surface, path_objects = {}}
    goal.rendering = state
  end
  if state.index ~= index then
    state.number.text = tostring(index)
    state.number.color = copy_color(player.color, index == 1 and 1 or 0.65)
    state.index = index
    for _, object in ipairs(state.path_objects) do
      if object.valid then
        local vehicle = entity and entity.type ~= "character"
        object.color = copy_color(player.color, (vehicle and 0.5 or 0.9) * (index > 1 and 0.5 or 1))
      end
    end
  end
  if state.path ~= goal.path then draw_path(player, data, goal, index, surface) end
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
