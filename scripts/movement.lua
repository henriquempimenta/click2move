--[[
  Click2Move - Movement Handlers
  All tick-based movement logic: stuck detection, character, vehicle, and straight-line handlers.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Navigation = require("scripts/navigation")
local VehicleBraking = require("scripts/vehicle-braking")
local Pathfinding = require("scripts/pathfinding")
local Mode = require("scripts/mode")
local GUI = require("scripts/gui")

local Movement = {}

-- Start braking with half a second of travel in hand. Keep control until both
-- native speed and scripted movement have settled; hovercrafts can drift at speed 0.
local VEHICLE_BRAKING_LOOKAHEAD = 30
-- The native autopilot completes a destination once the spider is under two
-- tiles from it, measured after that tick's movement, for any speed or spider
-- size. tests/engine/spiders.lua checks every native arrival against this.
Movement.SPIDER_ARRIVAL_RADIUS = 2
-- Position quantization (1/256 tile) between our arithmetic and the engine's.
local SPIDER_ARRIVAL_EPSILON = 1 / 256

local function latch_character_arrival(data, character, goal, config, arrival_radius)
  if data.character_arrival then return end
  local lookahead = (character.character_running_speed or 0) * (config.update_interval or 1)
    + arrival_radius + 1 / 64
  if Util.distance_sq(character.position, goal.position) <= lookahead ^ 2 then
    data.character_arrival = true
  end
end

local function brake_at_goal(data, vehicle, goal, config)
  local arrival = data.vehicle_arrival
  local speed = vehicle.speed
  local speed_tolerance, position_tolerance, stationary_ticks = VehicleBraking.apply(vehicle, arrival.speed)
  arrival.speed = speed

  local elapsed = game.tick - arrival.tick
  if math.abs(vehicle.speed) <= speed_tolerance
      and Util.distance_sq(vehicle.position, arrival.position) < position_tolerance ^ 2 then
    arrival.stationary_ticks = arrival.stationary_ticks + elapsed
  else
    arrival.stationary_ticks = 0
    -- Keep a fixed anchor during the observation window, so slow continuous
    -- drift cannot look stationary just because each individual step is small.
    arrival.position = {x = vehicle.position.x, y = vehicle.position.y}
  end
  arrival.tick = game.tick

  if arrival.stationary_ticks < stationary_ticks then return false end
  if Util.distance_sq(vehicle.position, goal.position) <= config.vehicle_proximity_threshold ^ 2 then
    return true
  end

  -- Braking distance varies by vehicle/mod. If we stopped short or overshot,
  -- approach again from rest instead of finishing away from the destination.
  data.vehicle_arrival = nil
  Navigation.reset_waypoint_motion(data)
  data.vehicle_reapproach = true
  PlayerData.notify_changed()
  data.closest_dist_to_goal = math.huge
  data.no_progress_ticks = 0
  return false
end

-- The spider's own autopilot decides arrival and raises on_spider_command_completed.
-- A destination already in reach completes in this tick's entity update, after
-- the write, so the engine's stored (quantized) destination can be recorded.
---@param data PlayerMoveData
---@param spider LuaEntity
function Movement.command_spider(data, spider)
  local goal = data.goals[1]
  if not goal or not goal.path then return end
  data.spider_arrived = nil
  -- Only reached for a new click or a command we still own; a click overrides a follow order.
  spider.follow_target = nil
  spider.autopilot_destination = goal.position
  local stored = spider.autopilot_destination or goal.position
  data.spider_destination = {x = stored.x, y = stored.y}
end

Movement.owns_spider_autopilot = PlayerData.owns_spider_autopilot

-- on_spider_command_completed does not identify the command, so proximity
-- alone cannot prove ownership. Accept it only with nothing queued behind it
-- and with the spider inside the engine's own completion radius of our
-- destination: then our command completes in this same update. Another
-- command finishing farther away is rejected, and the next update cancels
-- the route because the autopilot is no longer ours.
---@param data PlayerMoveData
---@param spider LuaEntity
function Movement.on_spider_command_completed(data, spider)
  if data.move_entity ~= spider or data.spider_arrived or not data.spider_destination then return end
  if #spider.autopilot_destinations == 0 and not spider.follow_target
      and Util.distance_sq(spider.position, data.spider_destination)
        < (Movement.SPIDER_ARRIVAL_RADIUS + SPIDER_ARRIVAL_EPSILON) ^ 2 then
    data.spider_arrived = true
  end
end

-- Advanced stuck detection based on progress towards goal
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param goal_pos MapPosition
---@return boolean is_stuck
function Movement.check_progress_and_stuck(data, current_pos, goal_pos, player_index)
  local config = Config.get(player_index)
  local elapsed = data.last_progress_tick and game.tick - data.last_progress_tick or 0
  data.last_progress_tick = game.tick
  local dist = Util.distance_sq(current_pos, goal_pos)

  -- A 0.25 squared-distance buffer keeps tiny back-and-forth movement from counting as progress.
  if dist < (data.closest_dist_to_goal - 0.25) then
    data.closest_dist_to_goal = dist
    data.no_progress_ticks = 0 -- Reset counter, we are moving forward
  else
    data.no_progress_ticks = data.no_progress_ticks + elapsed
  end

  -- Without a new best distance for twice the configured threshold, we are stuck.
  local stuck_limit = config.stuck_threshold * 2
  return data.no_progress_ticks > stuck_limit
end

-- Handle straight-line movement for mech-armor / jetpack (extracted branch)
---@param player_index integer
---@param data PlayerMoveData
---@param player LuaPlayer
---@param request_paths_fn fun(player_index: integer|string, force?: boolean): boolean
---@return boolean stop_movement, boolean changed_gui
function Movement.handle_straight_line(player_index, data, player, request_paths_fn)
  local config = Config.get(player_index)
  local character = data.move_entity
  local goal = data.goals[1]
  local changed_gui = false
  Navigation.reset_waypoint_motion(data)

  if not character or not character.valid or not goal then return true, false end
  if character.type ~= "character" or not PlayerData.is_bypassing_pathfinding(player) then
    data.is_straight_line_move = nil
    PlayerData.reset_movement_state(data)
    PlayerData.stop_input(character, data)
    Pathfinding.invalidate_goal(player_index)
    changed_gui = request_paths_fn(player_index, true)
    return false, changed_gui
  end

  local dist_sq_to_goal = Util.distance_sq(character.position, goal.position)
  local arrival_radius = config.proximity_threshold + (character.character_running_speed or 0) * 1.5
  local threshold_sq = arrival_radius ^ 2
  local was_arriving = data.character_arrival
  latch_character_arrival(data, character, goal, config, arrival_radius)
  if was_arriving ~= data.character_arrival then PlayerData.notify_changed() end
  if dist_sq_to_goal < threshold_sq then
    return true, changed_gui
  end

  local elapsed = data.last_straight_line_tick and game.tick - data.last_straight_line_tick or 0
  data.last_straight_line_tick = game.tick
  if data.last_position and Util.distance_sq(character.position, data.last_position) < (0.03*0.03) then
    data.stuck_counter = data.stuck_counter + elapsed
  else
    data.stuck_counter = 0
    -- Retain the anchor until cumulative travel is meaningful. Per-tick final
    -- checks must not turn steady slow movement into an apparent obstruction.
    data.last_position = { x = character.position.x, y = character.position.y }
  end
  if data.stuck_counter > config.stuck_threshold then
    if Config.is_debug(player_index, "stuck") then player.print("Click2Move: Straight-line movement stopped (stuck).") end
    data.goal_failed = true
    return true, changed_gui
  end

  -- Move
  Navigation.set_character_walking(character, goal.position)
  return false, changed_gui  -- Continue
end

-- Handle vehicle movement
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param vehicle LuaEntity
---@return boolean
function Movement.handle_vehicle(player_index, data, player, vehicle)
  if vehicle.type == "spider-vehicle" then
    if not data.goals[1] then return true end
    if not data.spider_destination then
      if not PlayerData.reconcile_spider(data, vehicle) then
        GUI.cancel_movement(player, "spider command replaced", true)
      elseif not data.spider_destination then
        Movement.command_spider(data, vehicle)
      end
      return false
    end
    -- Validate ownership before accepting arrival: another script may have
    -- assigned a destination after our command finished.
    if not Movement.owns_spider_autopilot(data, vehicle) then
      -- A spidertron remote or another mod replaced the command; it now owns the spider.
      GUI.cancel_movement(player, "spider command replaced", true)
      return false
    end
    return data.spider_arrived == true
  end

  local config = Config.get(player_index)
  local goal = data.goals[1]
  if not goal then return true end

  -- Arrival bypasses stuck recovery: braking and sideways drift are not a jam.
  if data.vehicle_arrival then
    Navigation.reset_waypoint_motion(data)
    return brake_at_goal(data, vehicle, goal, config)
  end

  -- Continue a timed reverse maneuver while recovering from an obstruction.
  if data.stuck_state == "reversing" then
    Navigation.reset_waypoint_motion(data)
    local elapsed = game.tick - (data.last_recovery_tick or game.tick)
    data.last_recovery_tick = game.tick
    data.stuck_timer = data.stuck_timer - elapsed

    -- Drive backwards and turn left hard to unwedge
    vehicle.riding_state = {
      acceleration = defines.riding.acceleration.reversing,
      direction = defines.riding.direction.left
    }

    if data.stuck_timer <= 0 then
      if Config.is_debug(player_index, "vehicle") then player.print("Click2Move: Reverse complete. Retrying path.") end
      data.stuck_state = "none"
      data.last_recovery_tick = nil
      VehicleBraking.apply(vehicle)
      Pathfinding.invalidate_goal(player_index)
      Pathfinding.request_paths_for_player(player_index)
      data.closest_dist_to_goal = math.huge
      data.no_progress_ticks = 0
      PlayerData.notify_changed()
    end
    return false -- Consume tick, don't do normal movement
  end

  if not goal.path or #goal.path == 0 then return true end
  local speed = math.abs(vehicle.speed or 0)
  local dynamic_threshold_sq = (config.vehicle_proximity_threshold + speed * 3.0) ^ 2
  local was_pending = data.waypoint_scan_pending
  local advanced, pending = Navigation.advance_waypoints(data, vehicle, goal.path, dynamic_threshold_sq, game.tick)
  if was_pending ~= data.waypoint_scan_pending then PlayerData.notify_changed() end
  if advanced > 0 then
    data.closest_dist_to_goal = math.huge
    data.no_progress_ticks = 0
    data.last_progress_tick = game.tick
  end
  if pending then PlayerData.stop_input(vehicle, data); return false end
  local waypoint = goal.path[data.current_waypoint]
  if not waypoint or not waypoint.position then return true end

  local target_pos = waypoint.position
  if data.current_waypoint == #goal.path then
    target_pos = goal.position
    -- Initial approaches brake conservatively. After stopping outside the
    -- destination radius, approach farther inside before braking again so
    -- quantized drift cannot trap the vehicle in repeated stops at the edge.
    local braking_distance = config.vehicle_proximity_threshold * 0.5 + speed * VEHICLE_BRAKING_LOOKAHEAD
    if not data.vehicle_reapproach then
      braking_distance = math.max(config.vehicle_proximity_threshold, braking_distance)
    end
    if Util.distance_sq(vehicle.position, goal.position) <= braking_distance ^ 2 then
      Navigation.reset_waypoint_motion(data)
      data.vehicle_arrival = {
        position = {x = vehicle.position.x, y = vehicle.position.y},
        tick = game.tick,
        stationary_ticks = 0
      }
      PlayerData.notify_changed()
      return brake_at_goal(data, vehicle, goal, config)
    end
  end

  -- Recover if no progress has been made for the configured time.
  local target_for_stuck_check = target_pos
  if Movement.check_progress_and_stuck(data, vehicle.position, target_for_stuck_check, player_index) then

    if Config.is_debug(player_index, "vehicle") then player.print("Click2Move: Vehicle stuck detected (No progress). Initiating Reverse.") end

    goal.recovery_attempts = (goal.recovery_attempts or 0) + 1
    if goal.recovery_attempts > PlayerData.MAX_PATH_RETRIES then
      data.goal_failed = true
      return true
    end
    Navigation.reset_waypoint_motion(data)
    data.last_recovery_tick = game.tick
    data.stuck_state = "reversing"
    data.stuck_timer = 60
    data.no_progress_ticks = 0
    vehicle.riding_state = {acceleration = defines.riding.acceleration.reversing, direction = defines.riding.direction.left}
    PlayerData.notify_changed()
    return false
  end

  -- Move to current/next waypoint
  Navigation.set_vehicle_riding(vehicle, target_pos)

  return false
end

-- Handle character movement
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param character LuaEntity
---@return boolean
function Movement.handle_character(player_index, data, player, character)
  local config = Config.get(player_index)

  -- Continue a timed slide maneuver while recovering from an obstruction.
  if data.stuck_state == "sliding" then
    Navigation.reset_waypoint_motion(data)
    data.character_arrival = nil
    local elapsed = game.tick - (data.last_recovery_tick or game.tick)
    data.last_recovery_tick = game.tick
    data.stuck_timer = data.stuck_timer - elapsed

    character.walking_state = { walking = true, direction = data.slide_direction }

    if data.stuck_timer <= 0 then
      if Config.is_debug(player_index, "stuck") then player.print("Click2Move: Slide complete. Retrying path.") end
      data.stuck_state = "none"
      data.last_recovery_tick = nil
      character.walking_state = {walking = false, direction = defines.direction.north}
      Pathfinding.invalidate_goal(player_index)
      Pathfinding.request_paths_for_player(player_index)
      data.closest_dist_to_goal = math.huge
      data.no_progress_ticks = 0
      PlayerData.notify_changed()
    end
    return false -- Consume tick
  end

  local goal = data.goals[1]
  if not goal or not goal.path then return true end

  if #goal.path == 0 then return true end
  local speed_per_tick = character.character_running_speed or 0
  local dynamic_threshold_sq = (config.proximity_threshold + speed_per_tick * 1.5) ^ 2
  local was_pending, was_arriving = data.waypoint_scan_pending, data.character_arrival
  local advanced, pending = Navigation.advance_waypoints(data, character, goal.path, dynamic_threshold_sq, game.tick)
  local at_final = data.current_waypoint == #goal.path
  if not at_final then
    data.character_arrival = nil
  else
    latch_character_arrival(data, character, goal, config, config.proximity_threshold + speed_per_tick * 1.5)
  end
  if was_pending ~= data.waypoint_scan_pending or was_arriving ~= data.character_arrival then
    PlayerData.notify_changed()
  end
  if advanced > 0 then
    data.closest_dist_to_goal = math.huge
    data.no_progress_ticks = 0
    data.last_progress_tick = game.tick
  end
  if pending then PlayerData.stop_input(character, data); return false end
  local waypoint = goal.path[data.current_waypoint]
  if not waypoint or not waypoint.position then return true end
  local target_pos = at_final and goal.position or waypoint.position
  if at_final and Util.distance_sq(character.position, goal.position) < dynamic_threshold_sq then
    return true
  end

  -- Stuck detection
  local target_for_stuck_check = target_pos
  if Movement.check_progress_and_stuck(data, character.position, target_for_stuck_check, player_index) then
    if Config.is_debug(player_index, "stuck") then player.print("Click2Move: Character stuck; initiating slide.") end

    goal.recovery_attempts = (goal.recovery_attempts or 0) + 1
    if goal.recovery_attempts > PlayerData.MAX_PATH_RETRIES then
      data.goal_failed = true
      return true
    end
    Navigation.reset_waypoint_motion(data)
    data.character_arrival = nil
    data.last_recovery_tick = game.tick
    data.stuck_state = "sliding"
    data.stuck_timer = 30 -- slide for half a second
    data.no_progress_ticks = 0

    -- Alternate sides so repeated recovery tries both perpendicular directions.
    local dir = Navigation.get_character_direction(character.position, target_for_stuck_check) or defines.direction.north
    local offset = goal.recovery_attempts % 2 == 1 and 4 or 12
    data.slide_direction = (dir + offset) % 16
    character.walking_state = {walking = true, direction = data.slide_direction}
    PlayerData.notify_changed()
    return false
  end
  Navigation.set_character_walking(character, target_pos)

  return false  -- Continue
end

-- Finish or abandon the current goal and advance the queue.
---@param player_index uint32
---@param data PlayerMoveData
---@param entity_to_move LuaEntity
---@return boolean
function Movement.cleanup_and_next_goal(player_index, data, entity_to_move)
  local failed = data.goal_failed
  PlayerData.stop_input(entity_to_move, data)
  Pathfinding.remove_goal(player_index, 1, not failed)
  if #data.goals == 0 then
    PlayerData.remove(player_index)
    if not failed then Mode.on_route_arrived(game.players[player_index]) end
  elseif entity_to_move.valid and entity_to_move.type == "spider-vehicle" then
    -- Leave no idle gap in which a newer remote command could be overwritten.
    Movement.command_spider(data, entity_to_move)
  end
  PlayerData.notify_changed()
  return true
end

return Movement
