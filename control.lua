--[[
  Click2Move control.lua
  Author: Me
  Description: Allows players to click to move their character.
]]

-- Vector utility functions
local util_vector = {}
util_vector.distance = function(a, b)
  return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end
util_vector.angle = function(a, b)
  return math.atan2(b.y - a.y, b.x - a.x)
end

-- Forward-declare event handlers
local on_custom_input
local on_path_request_finished
local on_tick

-- Constants
local PROXIMITY_THRESHOLD = 1.5
local UPDATE_INTERVAL = 1 -- Ticks between movement updates (1 for smoother movement)
local DEBUG_MODE = true -- Set to false to disable debug messages

-- A non-persistent table to store active movement data.
-- It will be cleared on game load.
local player_move_data = {}

-- Handles the custom input to initiate movement
on_custom_input = function(event)
  if event.input_name ~= "c2m-move-command" then return end

  local player = game.players[event.player_index]
  -- Ensure player, character, and location are valid. Also, don't allow movement if in a vehicle.
  if not player or not player.character or not event.cursor_position or player.vehicle then return end

  if not player.connected then return end

  -- If a new move command is issued, clear any existing path data for this player.
  if player_move_data[player.index] then
    player_move_data[player.index] = nil
  end

  if DEBUG_MODE then player.print("Click2Move: Path request initiated.") end

  -- Store the original goal for potential retries
  local goal = event.cursor_position

  -- Request path and store the ID for matching in the callback
  local path_id = player.surface.request_path {
    bounding_box = player.character.prototype.collision_box,
    collision_mask = player.character.prototype.collision_mask,
    start = player.position,
    goal = goal,
    pathfind_flags = { allow_destroy_friendly_entities = true },
    force = player.force.name,
    entity_to_ignore = player.character
  }

  -- Temporarily store the path ID and goal
  player_move_data[player.index] = { path_id = path_id, goal = goal, requesting_player_index = player.index }
end

-- Handles the result of the path request
on_path_request_finished = function(event)
  -- Find the player who requested this path ID
  local matched_player_index = nil
  for p_index, data in pairs(player_move_data) do
    if data.path_id == event.id then
      matched_player_index = p_index
      break
    end
  end

  if not matched_player_index then return end

  local player = game.players[matched_player_index]
  if not player or not player.connected then return end

  local current_data = player_move_data[matched_player_index]
  -- Clean up temp path_id storage
  current_data.path_id = nil

  if event.path and #event.path > 0 then
    if DEBUG_MODE then player.print("Path found with " .. #event.path .. " waypoints.") end
    -- Store the path and reset state
    player_move_data[matched_player_index] = {
      path = event.path,
      current_waypoint = 1,
      is_cancelling = false,
      is_auto_walking = false, -- Flag to ignore self-induced walking
      goal = current_data.goal -- Preserve for any future needs
    }

    -- Render the path for the player to see (store rendering IDs to clean up later if needed)
    local render_ids = {}
    for _, waypoint in ipairs(event.path) do
      local render_id = rendering.draw_circle{
        color = {r = 0.1, g = 0.8, b = 0.1, a = 0.5},
        radius = 0.5,
        target = waypoint,  -- waypoint is {x,y}
        surface = player.surface,
        players = {player}, -- Only show to the requesting player
        time_to_live = 600 -- 10 seconds
      }
      table.insert(render_ids, render_id)
    end
    player_move_data[matched_player_index].render_ids = render_ids
  else
    if event.try_again_later then
      -- Re-request after a short delay, using stored goal
      if DEBUG_MODE then player.print("Click2Move: Path temporarily unavailable, retrying...") end
      local retry_goal = current_data.goal
      local retry_start = player.position -- Use current position for retry
      script.on_nth_tick(game.tick + 60, function()
        local still_valid_player = game.players[matched_player_index]
        if still_valid_player and still_valid_player.character and not still_valid_player.vehicle then
          local retry_path_id = still_valid_player.surface.request_path {
            bounding_box = still_valid_player.character.prototype.collision_box,
            collision_mask = still_valid_player.character.prototype.collision_mask,
            start = retry_start,
            goal = retry_goal,
            pathfind_flags = { allow_destroy_friendly_entities = true },
            force = still_valid_player.force.name,
            entity_to_ignore = still_valid_player.character
          }
          player_move_data[matched_player_index] = { path_id = retry_path_id, goal = retry_goal, requesting_player_index = matched_player_index }
        else
          player_move_data[matched_player_index] = nil
        end
      end)
    else
      player.print("Click2Move: No path found.")
      -- Clear data if failed
      player_move_data[matched_player_index] = nil
    end
  end
end

-- Handles player movement each tick
on_tick = function(event)
  for player_index, data in pairs(player_move_data) do
    -- Skip if still waiting for path (no path yet)
    if not data.path then
      goto continue
    end

    local player = game.players[player_index]
    local stop_movement = false
    local character = player and player.character

    if not character or not player.connected then
      stop_movement = true
    elseif data.is_cancelling then
      stop_movement = true
    -- Player is manually moving (and not in a vehicle)
    elseif character.walking_state.walking and not character.driving and not data.is_auto_walking then
      stop_movement = true
      -- Print cancellation message only once
      if not data.is_cancelling then
        if player.connected then player.print("Movement cancelled.") end
        data.is_cancelling = true
      end
    else
      local waypoint = data.path[data.current_waypoint]
      if waypoint then
        data.is_cancelling = false -- Reset cancellation flag
        local distance = util_vector.distance(character.position, waypoint)

        if distance < PROXIMITY_THRESHOLD then
          data.current_waypoint = data.current_waypoint + 1
        end

        if data.current_waypoint > #data.path then
          stop_movement = true
        else
          -- Re-check waypoint after potential increment
          waypoint = data.path[data.current_waypoint]
          if waypoint then
            data.is_auto_walking = true -- Set flag for this tick's auto-move
            local angle = util_vector.angle(character.position, waypoint)
            -- Continuous direction (0.0 east to 1.0 full circle CCW)
            local direction = ((angle + 2 * math.pi) % (2 * math.pi)) / (2 * math.pi)
            -- Move the character towards the current waypoint
            character.walking_state.walking = true
            character.walking_state.direction = direction
            data.is_auto_walking = false -- Reset after move
          end
        end
      else
        stop_movement = true -- Path is finished
      end
    end

    if stop_movement then
      if character then
        character.walking_state.walking = false
        -- Direction persists automatically
      end
      -- Clean up renderings if present
      if data.render_ids then
        for _, render_id in ipairs(data.render_ids) do
          rendering.destroy(render_id)
        end
      end
      -- Remove the player's path from the active list
      player_move_data[player_index] = nil
    end

    ::continue::
  end
end

-- Centralized function for event registration
local function initialize()
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("bazinga", function (event) game.print("bazinga!") end)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_nth_tick(UPDATE_INTERVAL, on_tick)
  -- Clear data on load
  player_move_data = {}
end

script.on_init(initialize)
script.on_load(initialize)
script.on_configuration_changed(initialize)