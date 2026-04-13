--[[
  Click2Move - Movement Handlers
  All tick-based movement logic: stuck detection, character, vehicle, and straight-line handlers.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Navigation = require("scripts/navigation")

local Movement = {}

-- Advanced stuck detection based on progress towards goal
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param goal_pos MapPosition
---@return boolean is_stuck
function Movement.check_progress_and_stuck(data, current_pos, goal_pos)
  local config = Config.get()
  -- 1. Calculate distance to actual target
  local dist = Util.distance_sq(current_pos, goal_pos)

  -- 2. Check if we made progress (with a small buffer to prevent jitter resetting it)
  -- We use a buffer of 0.5 tiles squared (~0.25) so tiny back-and-forth movements don't count as progress
  if dist < (data.closest_dist_to_goal - 0.25) then
    data.closest_dist_to_goal = dist
    data.no_progress_ticks = 0 -- Reset counter, we are moving forward
  else
    data.no_progress_ticks = data.no_progress_ticks + 1
  end

  -- 3. Threshold check
  -- If we haven't made a new "best distance" record in X ticks, we are stuck.
  -- We use a higher threshold than the old function because we are checking "progress", not "movement"
  -- Stuck threshold is usually ~30, we double it here for progress checks to be generous
  local stuck_limit = config.stuck_threshold * 2 
  
  return data.no_progress_ticks > stuck_limit
end

-- Handle straight-line movement for mech-armor / jetpack (extracted branch)
---@param player_index integer
---@param data PlayerMoveData
---@param player LuaPlayer
---@param request_paths_fn fun(player_index: integer|string): boolean
---@return boolean stop_movement, boolean changed_gui
function Movement.handle_straight_line(player_index, data, player, request_paths_fn)
  local config = Config.get()
  local character = player.character
  local goal = data.goals[1]
  local changed_gui = false

  if not character or not goal or not PlayerData.is_bypassing_pathfinding(player) then
    if character and goal and not PlayerData.is_bypassing_pathfinding(player) then
      if Config.is_debug(player_index) then player.print("Click2Move: Straight-line condition ended, switching to pathfinding.") end
      data.is_straight_line_move = nil
      changed_gui = request_paths_fn(player_index) -- Capture changed from path request
    end
    return true, changed_gui  -- Stop
  end

  local dist_sq_to_goal = Util.distance_sq(character.position, goal.position)
  local threshold_sq = config.proximity_threshold ^ 2

  -- Stuck detection for Mech (Simple straight line doesn't need complex state)
  if data.last_position and Util.distance_sq(character.position, data.last_position) < (0.03*0.03) then
    data.stuck_counter = data.stuck_counter + 1
  else
    data.stuck_counter = 0
  end
  if data.stuck_counter > config.stuck_threshold then
    if Config.is_debug(player_index) then player.print("Click2Move: Straight-line movement stopped (stuck).") end
    return true, changed_gui
  end
  data.last_position = { x = character.position.x, y = character.position.y }

  if dist_sq_to_goal < threshold_sq then
    return true, changed_gui  -- Arrived
  end

  -- Move
  Navigation.set_character_walking(character, data, goal.position)
  return false, changed_gui  -- Continue
end

-- Handle vehicle movement
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param vehicle LuaEntity
---@return boolean
function Movement.handle_vehicle(player_index, data, player, vehicle)
  local config = Config.get()

  -- A. HANDLE ACTIVE UNSTUCK MANEUVER (REVERSING)
  if data.stuck_state == "reversing" then
    data.stuck_timer = data.stuck_timer - 1
    
    -- Drive backwards and turn left hard to unwedge
    vehicle.riding_state = {
      acceleration = defines.riding.acceleration.reversing,
      direction = defines.riding.direction.left
    }

    if data.stuck_timer <= 0 then
      if Config.is_debug(player_index) then player.print("Click2Move: Reverse complete. Retrying path.") end
      data.stuck_state = "none"
      if data.goals[1] then
        data.goals[1].path = nil 
        data.goals[1].path_id = nil
      end
      data.closest_dist_to_goal = 999999 -- Reset progress tracking
      -- The on_tick loop will see data.goals[1].path is nil and request a new path
    end
    return false -- Consume tick, don't do normal movement
  end

  local goal = data.goals[1]
  if not goal then return true end

  -- Standard validation
  local waypoint = goal.path[data.current_waypoint]
  if not waypoint or not waypoint.position then return true end

  -- B. CHECK STUCK (New Logic)
  local target_for_stuck_check = waypoint.position
  if Movement.check_progress_and_stuck(data, vehicle.position, target_for_stuck_check) then
    
    if Config.is_debug(player_index) then player.print("Click2Move: Vehicle stuck detected (No progress). Initiating Reverse.") end
    
    -- Enter Reversing Mode
    data.stuck_state = "reversing"
    data.stuck_timer = 60 -- Reverse for 1 second (60 ticks)
    data.no_progress_ticks = 0
    return false
  end

  -- C. NORMAL MOVEMENT (Your existing logic, slightly cleaned up)
  local speed = vehicle.speed or 0
  local dynamic_threshold_sq = (config.vehicle_proximity_threshold + math.abs(speed) * 3.0) ^ 2

  if Navigation.advance_waypoint(data, vehicle.position, waypoint.position, dynamic_threshold_sq) then
    -- If we advanced, reset our "closest distance" tracker so we don't false-flag stuck
    data.closest_dist_to_goal = 999999
  end

  if data.current_waypoint > #goal.path then
    local goal_pos = goal.position
    if Util.distance_sq(vehicle.position, goal_pos) < dynamic_threshold_sq then
      return true  -- Arrived
    end
  end

  -- Move to current/next waypoint
  local target_pos = waypoint.position
  if data.current_waypoint > #goal.path then target_pos = goal.position end
  Navigation.set_vehicle_riding(player, vehicle, target_pos)
  
  return false
end

-- Handle character movement
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param character LuaEntity
---@return boolean
function Movement.handle_character(player_index, data, player, character)
  local config = Config.get()

  if character.walking_state and character.walking_state.walking and not data.is_auto_walking then
    if Config.is_debug(player_index) then player.print("Click2Move: Player manually moved, cancelling auto-walk.") end
    return true  -- Stop
  end

  -- A. HANDLE ACTIVE SLIDING MANEUVER
  if data.stuck_state == "sliding" then
    data.stuck_timer = data.stuck_timer - 1
    
    character.walking_state = { walking = true, direction = data.slide_direction }
    data.is_auto_walking = true

    if data.stuck_timer <= 0 then
      if Config.is_debug(player_index) then player.print("Click2Move: Slide complete. Retrying path.") end
      data.stuck_state = "none"
      local goal = data.goals[1]
      if goal then
        goal.path = nil
        goal.path_id = nil
        goal.retry_count = (goal.retry_count or 0) + 1
        if goal.retry_count > PlayerData.MAX_PATH_RETRIES then
          return true -- Stop and cleanup
        end
      end
      data.closest_dist_to_goal = 999999
      data.no_progress_ticks = 0
    end
    return false -- Consume tick
  end

  local goal = data.goals[1]
  if not goal or not goal.path then return true end

  local waypoint = goal.path[data.current_waypoint]
  if not waypoint or not waypoint.position then return true end  -- Invalid, stop

  -- Stuck detection
  local target_for_stuck_check = waypoint.position
  if Movement.check_progress_and_stuck(data, character.position, target_for_stuck_check) then
    if Config.is_debug(player_index) then player.print("Click2Move: Character stuck; initiating slide.") end
    
    data.stuck_state = "sliding"
    data.stuck_timer = 30 -- slide for half a second
    data.no_progress_ticks = 0
    
    -- Pick a semi-random orthogonal direction relative to the goal or current direction
    local dir = Navigation.get_character_direction(character.position, target_for_stuck_check) or defines.direction.north
    local offset = (math.random() > 0.5) and 2 or 6 -- +2 is 90 deg clockwise, +6 is 90 deg CCW
    data.slide_direction = (dir + offset) % 8
    
    return false
  end
  data.last_position = { x = character.position.x, y = character.position.y }

  -- Dynamic threshold
  local speed_per_tick = character.character_running_speed or 0
  local dynamic_threshold_sq = (config.proximity_threshold + speed_per_tick * 1.5) ^ 2
  
  if Navigation.advance_waypoint(data, character.position, waypoint.position, dynamic_threshold_sq) then
      -- Reset stuck tracker on waypoint advance
      data.closest_dist_to_goal = 999999
  end

  if data.current_waypoint > #goal.path then
    return true  -- Arrived
  end

  waypoint = goal.path[data.current_waypoint]
  if waypoint and waypoint.position then
    Navigation.set_character_walking(character, data, waypoint.position)
  else
    return true  -- Invalid waypoint
  end

  return false  -- Continue
end

-- Cleanup current goal and advance to next
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param entity_to_move LuaEntity
---@param changed boolean
---@param request_paths_fn fun(player_index: integer|string): boolean
---@param render_fn fun(player_index: integer|string, data_table: table)
---@return boolean
function Movement.cleanup_and_next_goal(player_index, data, player, entity_to_move, changed, request_paths_fn, render_fn)
  PlayerData.cleanup_movement(entity_to_move, player, data)
  changed = true -- Cleanup always changes state relevant to GUI
  if data.goals and #data.goals > 0 then
    table.remove(data.goals, 1)
  end
  if data.goals and #data.goals > 0 then
    local path_request_changed = request_paths_fn(player_index)
    changed = changed or path_request_changed
  else
    PlayerData.remove(player_index)
  end
  render_fn(player_index, PlayerData.get_all())
  return changed
end

return Movement
