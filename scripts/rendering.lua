--[[
  Click2Move - Rendering
  Visual feedback: crosshairs and path line drawing.
]]

local Util = require("scripts/util")

local Rendering = {}

-- Draws a crosshair at a given position for a player. color optional (defaults to green)
---@param player LuaPlayer
---@param position MapPosition
---@param color Color
---@return LuaRenderObject[]
function Rendering.draw_target_crosshair(player, position, color)
  local size = 0.5
  local default_color = {r = 0.1, g = 0.8, b = 0.1, a = 0.9}
  local col = color or player.color or default_color
  if not col.a then col.a = 0.9 end
  local surface = player.surface
  local players = {player}
  local time_to_live = 600 -- 10 seconds

  ---@type LuaRenderObject[]
  local objs = {}
  table.insert(objs, rendering.draw_line{
    color = col,
    width = 3,
    from = {x = position.x - size, y = position.y},
    to   = {x = position.x + size, y = position.y},
    surface = surface,
    players = players,
    time_to_live = time_to_live
  })
  table.insert(objs, rendering.draw_line{
    color = col,
    width = 3,
    from = {x = position.x, y = position.y - size},
    to   = {x = position.x, y = position.y + size},
    surface = surface,
    players = players,
    time_to_live = time_to_live
  })
  return objs
end

-- Render all paths and crosshairs for a player's goal queue
---@param player_index integer|string
---@param player_move_data table<uint32, PlayerMoveData>
function Rendering.render_paths_for_player(player_index, player_move_data)
  local player = game.players[player_index]
  local data = player_move_data[player_index]
  if not player or not data then return end

  Util.safe_destroy_renderings(data.render_objs)
  data.render_objs = {}

  for i, goal_data in ipairs(data.goals) do
    if goal_data.path and #goal_data.path > 0 then
      local points = {}
      for _, wp in ipairs(goal_data.path) do
        if wp and wp.position then table.insert(points, wp.position) end
      end

      local path_color = player.color or {r = 0.1, g = 0.8, b = 0.1, a = 0.9}
      local path_width = 2
      if player.vehicle then
        path_color.a = 0.5
        path_width = 1
      else
        path_color.a = 0.9
      end
      
      if i > 1 then path_color.a = path_color.a * 0.5 end

      for j = 1, math.max(0, #points - 1) do
        local from = points[j]; local to = points[j+1]
        local seg = rendering.draw_line{
          color = path_color, 
          width = path_width,
          from = from,
          to = to,
          surface = player.surface,
          players = {player},
          time_to_live = 600
        }
        table.insert(data.render_objs, seg)
      end

      if #points == 1 then
        local dot = rendering.draw_circle{
          color = path_color,
          radius = 0.3,
          target = points[1],
          surface = player.surface,
          players = {player},
          time_to_live = 600
        }
        table.insert(data.render_objs, dot)
      end
    end
    local crosshair_objs = Rendering.draw_target_crosshair(player, goal_data.position, player.color)
    for _, o in ipairs(crosshair_objs) do table.insert(data.render_objs, o) end
  end
end

return Rendering
