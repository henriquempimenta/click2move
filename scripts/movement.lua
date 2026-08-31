--[[
  Click2Move - Movement Handlers
  All tick-based movement logic: stuck detection, character, vehicle, and straight-line handlers.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Navigation = require("scripts/navigation")
local DebugCounters = require("scripts/debug-counters")
local Belts = require("scripts/belts")

local Movement = {}

local function set_spider_autopilot(spider, position)
  return pcall(function()
    spider.autopilot_destination = position
  end)
end

-- Advanced stuck detection based on progress towards goal
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param goal_pos MapPosition
---@return boolean is_stuck
function Movement.check_progress_and_stuck(data, current_pos, goal_pos, player_index)
  local config = Config.get(player_index)
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
  local config = Config.get(player_index)
  local character = player.character
  local goal = data.goals[1]
  local changed_gui = false

  local bypassing_pathfinding = character and goal and PlayerData.is_bypassing_pathfinding(player)
  if not character or not goal or not bypassing_pathfinding then
    if character and goal then
      if Config.is_debug(player_index, "path") then player.print("Click2Move: Straight-line condition ended, switching to pathfinding.") end
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
    if Config.is_debug(player_index, "stuck") then player.print("Click2Move: Straight-line movement stopped (stuck).") end
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
  local config = Config.get(player_index)

  if vehicle.type == "spider-vehicle" then
    local goal = data.goals[1]
    if not goal then return true end

    local threshold_sq = config.vehicle_proximity_threshold ^ 2
    if Util.distance_sq(vehicle.position, goal.position) < threshold_sq then
      set_spider_autopilot(vehicle, nil)
      return true
    end

    local ok = set_spider_autopilot(vehicle, goal.position)
    if not ok then
      if Config.is_debug(player_index, "vehicle") then player.print("Click2Move: Spidertron autopilot is not available for this vehicle.") end
      return true
    end

    return false
  end

  -- A. HANDLE ACTIVE UNSTUCK MANEUVER (REVERSING)
  if data.stuck_state == "reversing" then
    data.stuck_timer = data.stuck_timer - 1

    -- Drive backwards and turn left hard to unwedge
    vehicle.riding_state = {
      acceleration = defines.riding.acceleration.reversing,
      direction = defines.riding.direction.left
    }

    if data.stuck_timer <= 0 then
      if Config.is_debug(player_index, "vehicle") then player.print("Click2Move: Reverse complete. Retrying path.") end
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

  if not goal.path or #goal.path == 0 then return true end

  -- B. ADVANCE WAYPOINTS
  local speed = vehicle.speed or 0
  local dynamic_threshold_sq = (config.vehicle_proximity_threshold + math.abs(speed) * 3.0) ^ 2
  local predicted_pos = Navigation.predict_vehicle_position(vehicle, math.max(1, config.update_interval))
  local advanced_count = Navigation.advance_vehicle_waypoints(
    data,
    vehicle.position,
    predicted_pos,
    goal.path,
    dynamic_threshold_sq
  )

  if advanced_count > 0 then
    -- Advancing changes the progress target, so the stuck detector must start a
    -- fresh distance measurement instead of comparing two different waypoints.
    data.closest_dist_to_goal = 999999
    data.no_progress_ticks = 0
  end

  local target_pos
  if data.current_waypoint > #goal.path then
    if Util.distance_sq(vehicle.position, goal.position) < dynamic_threshold_sq then
      return true  -- Arrived
    end
    target_pos = goal.position
  else
    local waypoint = goal.path[data.current_waypoint]
    if not waypoint or not waypoint.position then return true end
    target_pos = waypoint.position
  end

  -- C. CHECK STUCK AGAINST THE UPDATED TARGET
  if Movement.check_progress_and_stuck(data, vehicle.position, target_pos, player_index) then
    if Config.is_debug(player_index, "vehicle") then player.print("Click2Move: Vehicle stuck detected (No progress). Initiating Reverse.") end

    data.stuck_state = "reversing"
    data.stuck_timer = 60 -- Reverse for 1 second (60 ticks)
    data.no_progress_ticks = 0
    DebugCounters.count("stuck_transitions")
    return false
  end

  -- D. MOVE TOWARDS THE FIRST WAYPOINT THAT HAS NOT BEEN SKIPPED
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
  local config = Config.get(player_index)

  -- Manual-override detection, fallback path.
  --
  -- The primary mechanism is the linked movement custom-inputs in control.lua,
  -- which fire on the keypress itself. This check is the backstop for input
  -- sources that do not raise those events (controllers, other mods driving
  -- the character).
  --
  -- Note it cannot be written as `walking and not data.is_auto_walking`: the
  -- mod sets `is_auto_walking` true every tick it drives the character, so
  -- that condition is false exactly when the player is fighting us. Compare
  -- against the direction we actually commanded instead — if the character is
  -- walking somewhere we did not send it, something else is steering.
  if config.cancel_on_manual_move
    and character.walking_state
    and character.walking_state.walking
    and data.commanded_direction ~= nil
    and character.walking_state.direction ~= data.commanded_direction
  then
    if Config.is_debug(player_index, "queue") then player.print("Click2Move: Player manually moved, cancelling auto-walk.") end
    return true  -- Stop
  end

  -- A. HANDLE ACTIVE SLIDING MANEUVER
  if data.stuck_state == "sliding" then
    data.stuck_timer = data.stuck_timer - 1

    -- Routed through Navigation so `commanded_direction` stays in sync; setting
    -- walking_state directly here would look like manual input next tick.
    Navigation.walk_in_direction(character, data, data.slide_direction)

    if data.stuck_timer <= 0 then
      if Config.is_debug(player_index, "stuck") then player.print("Click2Move: Slide complete. Retrying path.") end
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

  -- Finish before applying belt correction when the final waypoint has already
  -- been reached. A destination may legitimately be on a transport belt. If
  -- escape wins this ordering, the character steps away from the goal, drops
  -- the now-stale route, paths back onto the same belt, and repeats until the
  -- replan budget is exhausted.
  --
  -- Intermediate waypoints deliberately do not use this shortcut: reaching one
  -- on an opposing belt should still trigger the escape net before continuing.
  local speed_per_tick = character.character_running_speed or 0
  local dynamic_threshold_sq = (config.proximity_threshold + speed_per_tick * 1.5) ^ 2
  if data.current_waypoint == #goal.path
    and Util.distance_sq(character.position, waypoint.position) < dynamic_threshold_sq
  then
    data.current_waypoint = data.current_waypoint + 1
    return true
  end

  -- Belt drift correction. Runs before anything else that consumes the route.
  --
  -- While standing on a belt that opposes travel, getting *off* it takes
  -- priority over following the route: the escape target replaces the waypoint
  -- heading entirely rather than blending with it, and no waypoints are
  -- consumed while it runs.
  --
  -- Blending the two does not work, and this is worth spelling out because the
  -- naive version looks reasonable. The pathfinder returns waypoints roughly a
  -- tile apart, so the next waypoint is usually *along* the belt. Steering
  -- partly toward it while partly escaping means the character crabs diagonally
  -- across the lanes, is carried by each one it touches, and never accumulates
  -- enough lateral movement to clear the block — measured as a route that
  -- drifted 15 tiles the wrong way and never arrived. Letting waypoints advance
  -- during the escape has the same effect for the same reason: the route is
  -- consumed while the character has not actually travelled along it.
  --
  -- Committing fully to the perpendicular exit crosses a 4-lane bus in well
  -- under a second, after which normal routing resumes.
  if Config.uses_belts(player_index) and not goal.belt_disabled then
    local escape = Belts.escape_direction(
      character.surface, character.position, waypoint.position, data)
    if escape then
      DebugCounters.count("belt_escapes")
      Navigation.set_character_walking(character, data, escape)
      return false
    end

    -- An escape that just finished leaves a route planned from *on* the belt,
    -- whose waypoints lead straight back onto it. Drop it and re-path from
    -- where the character actually stands, the same way the slide maneuver
    -- does when it completes.
    --
    -- Without this the escape succeeds and is then immediately undone: measured
    -- as a 27-ticks-on / 1-tick-off oscillation that the belt wins, carrying
    -- the character 43 tiles past its own start.
    if data.belt_needs_replan then
      data.belt_needs_replan = nil
      goal.belt_replan_count = (goal.belt_replan_count or 0) + 1
      if goal.belt_replan_count > PlayerData.MAX_BELT_REPLANS then
        -- Every replan is landing back on a belt. Disable belt handling for the
        -- rest of this goal and walk the route as the pathfinder gave it: slow,
        -- but it terminates. This has to latch on the goal — leaving it unset
        -- would re-enter the escape next tick and count up forever.
        goal.belt_disabled = true
        return false
      end
      goal.path = nil
      goal.path_id = nil
      data.current_waypoint = 1
      data.closest_dist_to_goal = 999999
      data.no_progress_ticks = 0
      DebugCounters.count("belt_replans")
      return false -- Consume the tick; the new path arrives asynchronously.
    end
  end

  -- Stuck detection.
  --
  -- Suspended while deliberately escaping a belt: the escape moves
  -- perpendicular to the waypoint on purpose, so progress toward that waypoint
  -- legitimately stalls and the stuck detector would otherwise fire a slide
  -- maneuver that fights the escape.
  local escaping = data.belt_plan ~= nil and game.tick < (data.belt_plan.escape_until or 0)
  local target_for_stuck_check = waypoint.position
  if not escaping
    and Movement.check_progress_and_stuck(data, character.position, target_for_stuck_check, player_index) then
    if Config.is_debug(player_index, "stuck") then player.print("Click2Move: Character stuck; initiating slide.") end

    data.stuck_state = "sliding"
    data.stuck_timer = 30 -- slide for half a second
    data.no_progress_ticks = 0
    DebugCounters.count("stuck_transitions")

    -- Pick a semi-random orthogonal direction relative to the goal or current direction
    local dir = Navigation.get_character_direction(character.position, target_for_stuck_check) or defines.direction.north
    local offset = (math.random() > 0.5) and 2 or 6 -- +2 is 90 deg clockwise, +6 is 90 deg CCW
    data.slide_direction = (dir + offset) % 8

    return false
  end
  data.last_position = { x = character.position.x, y = character.position.y }

  if Navigation.advance_waypoint(data, character.position, waypoint.position, dynamic_threshold_sq) then
      -- Reset stuck tracker on waypoint advance
      data.closest_dist_to_goal = 999999
  end

  if data.current_waypoint > #goal.path then
    return true  -- Arrived
  end

  waypoint = goal.path[data.current_waypoint]
  if not waypoint or not waypoint.position then
    return true  -- Invalid waypoint
  end

  Navigation.set_character_walking(character, data, waypoint.position)

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
  local move_entity = data.move_entity
  PlayerData.cleanup_movement(entity_to_move, player, data)
  changed = true -- Cleanup always changes state relevant to GUI
  if data.goals and #data.goals > 0 then
    table.remove(data.goals, 1)
  end
  if data.goals and #data.goals > 0 then
    if move_entity and move_entity.valid then
      data.move_entity = move_entity
    end
    local path_request_changed = request_paths_fn(player_index)
    changed = changed or path_request_changed
  else
    PlayerData.remove(player_index)
  end
  render_fn(player_index, PlayerData.get_all())
  return changed
end

return Movement
