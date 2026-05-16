--[[
  Click2Move - Pathfinding
  Path request creation, dispatching, and response handling.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Rendering = require("scripts/rendering")
local GUI = require("scripts/gui")

local Pathfinding = {}

-- Build path request parameters
---@param player LuaPlayer
---@param start_pos MapPosition
---@param goal MapPosition
---@return LuaSurface.request_path_param | nil
function Pathfinding.create_path_request_params(player, start_pos, goal)
  local data = PlayerData.get_all()[player.index]
  local entity_to_move = data and data.move_entity or player.vehicle or player.character
  if not entity_to_move then return nil end

  local config = Config.get(player.index)
  local is_vehicle_path = entity_to_move.type ~= "character"
  local bounding_box = entity_to_move.prototype and entity_to_move.prototype.collision_box or {{-0.2,-0.2},{0.2,0.2}}
  ---@type number
  local margin = 0
  if is_vehicle_path then
    margin = config.vehicle_path_margin
  else
    margin = config.character_margin
  end

  if bounding_box.left_top and bounding_box.right_bottom then
    bounding_box = {
      left_top = { x = bounding_box.left_top.x - margin, y = bounding_box.left_top.y - margin },
      right_bottom = { x = bounding_box.right_bottom.x + margin, y = bounding_box.right_bottom.y + margin }
    }
  else
    bounding_box = {
      left_top = { x = -margin, y = -margin },
      right_bottom = { x = margin, y = margin }
    }
  end

  local collision_mask = (entity_to_move.prototype and entity_to_move.prototype.collision_mask) and entity_to_move.prototype.collision_mask or {}
  return {
    bounding_box = bounding_box,
    collision_mask = collision_mask,
    start = start_pos,
    goal = goal,
    pathfind_flags = {
      allow_destroy_friendly_entities = false,
      cache = is_vehicle_path,
      prefer_straight_paths = is_vehicle_path and config.vehicle_prefer_straight_paths,
    },
    force = player.force.name,
    entity_to_ignore = entity_to_move
  }
end

-- Start path requests for the player's queued goals
---@param player_index integer | string
---@return boolean
function Pathfinding.request_paths_for_player(player_index)
  local player = game.players[player_index]
  if not player or not player.valid or not player.connected then return false end
  local data = PlayerData.ensure(player_index)
  if not data.goals or #data.goals == 0 then return false end
  local entity_to_move = data.move_entity or player.vehicle or player.character
  if not entity_to_move or not entity_to_move.valid then return false end

  local changed = false

  if entity_to_move.type == "spider-vehicle" then
    for _, goal_data in ipairs(data.goals) do
      if not goal_data.path then
        goal_data.path = { { position = goal_data.position } }
        goal_data.path_id = nil
        goal_data.retry_at = nil
        changed = true
      end
    end
    if changed then
      Rendering.render_paths_for_player(player_index, PlayerData.get_all())
    end
    return changed
  end

  for i, goal_data in ipairs(data.goals) do
    if goal_data.retry_at and game.tick >= goal_data.retry_at then
      goal_data.retry_at = nil
    end

    if not goal_data.path and not goal_data.path_id and not goal_data.retry_at then
      local start_pos
      if i == 1 then
        start_pos = entity_to_move.position
      else
        start_pos = data.goals[i-1].position
      end

      local params = Pathfinding.create_path_request_params(player, start_pos, goal_data.position)
      if params then
        local path_id = entity_to_move.surface.request_path(params)
        goal_data.path_id = path_id
        goal_data.retry_count = goal_data.retry_count or 0
        changed = true
        if Config.is_debug(player_index, "path") then
          player.print("Click2Move: Requested queued path for " .. Util.format_pos(goal_data.position) .. " (player " .. player_index .. ")")
        end
      else
        table.remove(data.goals, i)
        changed = true
        break
      end
    end
  end

  if changed then
    Rendering.render_paths_for_player(player_index, PlayerData.get_all())
  end

  return changed
end

-- Handle path request finished event
---@param event EventData.on_script_path_request_finished
function Pathfinding.on_path_request_finished(event)


  -- find matching player
  local matched_player_index = nil
  local matched_goal_index = nil
  for p_index, p_data in pairs(PlayerData.get_all()) do
    for g_index, goal_data in ipairs(p_data.goals) do
      if goal_data.path_id == event.id then
        matched_player_index = p_index
        matched_goal_index = g_index
        break
      end
    end
    if matched_player_index then break end
  end
  if not matched_player_index or not matched_goal_index then return end

  local player = game.players[matched_player_index]
  if not player or not player.connected then
    PlayerData.remove(matched_player_index)
    return
  end

  local data = PlayerData.get_all()[matched_player_index]
  local goal_data = data.goals[matched_goal_index]
  local changed = false
  goal_data.path_id = nil

  -- if path present and non-empty
  if event.path and #event.path > 0 then
    if Config.is_debug(matched_player_index, "path") then player.print("Click2Move: Path found with " .. #event.path .. " waypoints for player " .. matched_player_index) end
    goal_data.path = event.path
    if matched_goal_index == 1 then
      data.current_waypoint = 1
      data.stuck_counter = 0
      data.last_position = nil
      data.vehicle_stuck_counter = 0
      data.last_vehicle_position = nil
      data.closest_dist_to_goal = 999999
      data.no_progress_ticks = 0
      data.stuck_state = "none"
      data.stuck_timer = 0
      data.slide_direction = nil
    end
    goal_data.retry_count = 0
    changed = true
    goal_data.retry_at = nil
    
    Rendering.render_paths_for_player(matched_player_index, PlayerData.get_all())
  else
    -- no path returned
    if event.try_again_later then
      changed = true
      goal_data.retry_count = (goal_data.retry_count or 0) + 1
      if goal_data.retry_count <= PlayerData.MAX_PATH_RETRIES then
        goal_data.retry_at = game.tick + PlayerData.PATH_RETRY_DELAY_TICKS
        if Config.is_debug(matched_player_index, "path") then player.print("Click2Move: try_again_later - retrying in " .. PlayerData.PATH_RETRY_DELAY_TICKS .. " ticks (attempt " .. goal_data.retry_count .. ")") end
      else
        if Config.is_debug(matched_player_index, "path") then player.print("Click2Move: Max retries reached, dropping goal.") end
        -- drop current goal and try next
        table.remove(data.goals, matched_goal_index)
        Rendering.render_paths_for_player(matched_player_index, PlayerData.get_all())
        changed = true
        Pathfinding.request_paths_for_player(matched_player_index)
      end
    else
      -- permanent failure; notify and drop current goal
      player.print("Click2Move: No path found to " .. Util.format_pos(goal_data.position))
      changed = true
      table.remove(data.goals, matched_goal_index)
      Rendering.render_paths_for_player(matched_player_index, PlayerData.get_all())
      Pathfinding.request_paths_for_player(matched_player_index)
    end
  end
  if changed then GUI.update(matched_player_index) end
end

return Pathfinding
