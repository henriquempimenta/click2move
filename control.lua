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

-- Draws a crosshair at a given position for a player
local function draw_target_crosshair(player, position)
  local size = 0.5
  local color = {r = 0.1, g = 0.8, b = 0.1, a = 0.7}
  local surface = player.surface
  local players = {player}
  local time_to_live = 600 -- 10 seconds

  return {
    rendering.draw_line{ color = color, width = 3, from = {x = position.x - size, y = position.y}, to = {x = position.x + size, y = position.y}, surface = surface, players = players, time_to_live = time_to_live },
    rendering.draw_line{ color = color, width = 3, from = {x = position.x, y = position.y - size}, to = {x = position.x, y = position.y + size}, surface = surface, players = players, time_to_live = time_to_live }
  }
end

-- Determines 8-way direction for character movement (as double 0.0-1.0)
local function get_character_direction(from, to)
  local distance = 0.1 -- Threshold to stop
  local dx = from.x - to.x
  local dy = from.y - to.y
  if dx > distance then
    -- west
    if dy > distance then
      return defines.direction.northwest
    elseif dy < -distance then
      return defines.direction.southwest
    else
      return defines.direction.west
    end
  elseif dx < -distance then
    -- east
    if dy > distance then
      return defines.direction.northeast
    elseif dy < -distance then
      return defines.direction.southeast
    else
      return defines.direction.east
    end
  else
    -- north/south
    if dy > distance then
      return defines.direction.north
    elseif dy < -distance then
      return defines.direction.south
    end
  end
  return nil
end

-- Determines vehicle riding state to move towards a target
local function get_vehicle_riding_state(vehicle, target_pos)
  local radians = vehicle.orientation * 2 * math.pi
  local v1 = {x = target_pos.x - vehicle.position.x, y = target_pos.y - vehicle.position.y}
  local dir = v1.x * math.sin(radians + math.pi / 2) - v1.y * math.cos(radians + math.pi / 2)
  local acc = v1.x * math.sin(radians) - v1.y * math.cos(radians)
  local direction = (dir < -0.2 and defines.riding.direction.left) or (dir > 0.2 and defines.riding.direction.right) or defines.riding.direction.straight
  local acceleration = (acc < -0.2 and defines.riding.acceleration.reversing) or (acc > 0.2 and defines.riding.acceleration.accelerating) or defines.riding.acceleration.braking
  return {direction = direction, acceleration = acceleration}
end

-- Forward-declare event handlers
local on_custom_input
local on_path_request_finished
local on_tick

-- Helper function to create path request parameters
local function create_path_request_params(player, goal)
  local entity_to_move = player.vehicle or player.character
  if not entity_to_move then return nil end

  local start_pos = entity_to_move.position
  local pathfind_for_character = not player.vehicle

  local bounding_box = entity_to_move.prototype.collision_box
  -- For characters, use a slightly larger bounding box to avoid getting stuck on corners.
  if pathfind_for_character then
    local margin = settings.global["c2m-character-margin"].value -- Increase this value for more clearance
    bounding_box = {
      left_top = { x = bounding_box.left_top.x - margin, y = bounding_box.left_top.y - margin },
      right_bottom = { x = bounding_box.right_bottom.x + margin, y = bounding_box.right_bottom.y + margin }
    }
  end

  return {
    bounding_box = bounding_box,
    collision_mask = entity_to_move.prototype.collision_mask,
    start = start_pos,
    goal = goal,
    pathfind_flags = { allow_destroy_friendly_entities = pathfind_for_character, cache = not pathfind_for_character },
    force = player.force.name,
    entity_to_ignore = entity_to_move
  }
end

-- Constants
local PROXIMITY_THRESHOLD = function ()
  return settings.startup["c2m-character-proximity-threshold"].value
end
-- Ticks between movement updates
local UPDATE_INTERVAL = function ()
  return settings.startup["c2m-update-interval"].value
end
local VEHICLE_PROXIMITY_THRESHOLD = function ()
  return settings.startup["c2m-vehicle-proximity-threshold"].value
end
local STUCK_THRESHOLD = function ()
  return settings.startup["c2m-stuck-threshold"].value
end
local DEBUG_MODE = function (player_index)
  return settings.get_player_settings(game.players[player_index])["c2m-debug-mode"].value
end

-- A non-persistent table to store active movement data.
-- It will be cleared on game load.
local player_move_data = {}

-- Handles the custom input to initiate movement
on_custom_input = function(event)
  if event.input_name ~= "c2m-move-command" then return end

  local player = game.players[event.player_index]
  -- Ensure player, character or vehicle, and location are valid.
  if not player or not (player.character or player.vehicle) or not event.cursor_position then return end

  if not player.connected then return end

  -- If a new move command is issued, clear any existing path data for this player.
  if player_move_data[player.index] then
    player_move_data[player.index] = nil
  end

  if DEBUG_MODE(event.player_index) then player.print("Click2Move: Path request initiated.") end

  -- Store the original goal for potential retries
  local goal = event.cursor_position

  local path_params = create_path_request_params(player, goal)
  if not path_params then return end

  -- Request path and store the ID for matching in the callback
  local path_id = player.surface.request_path(path_params)

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
    if DEBUG_MODE(matched_player_index) then player.print("Path found with " .. #event.path .. " waypoints.") end
    -- Store the path and reset state
    player_move_data[matched_player_index] = {
      path = event.path,
      current_waypoint = 1,
      is_cancelling = false,
      is_auto_walking = false, -- Flag to prevent self-cancellation
      goal = current_data.goal, -- Preserve for any future needs
      last_position = nil,
      stuck_counter = 0
    }

    -- Render the path for the player to see (store rendering IDs to clean up later if needed)
    local render_ids = {}
    -- Only draw waypoints if we have a path for a character
    if not player.vehicle then
      for _, waypoint in ipairs(event.path) do
        local render_id = rendering.draw_circle{
          color = {r = 0.1, g = 0.8, b = 0.1, a = 0.5},
          radius = 0.5,
          target = waypoint.position,
          surface = player.surface,
          players = {player}, -- Only show to the requesting player
          time_to_live = 600 -- 10 seconds
        }
        table.insert(render_ids, render_id)
      end
    end
    player_move_data[matched_player_index].render_ids = render_ids

    -- Draw a crosshair at the final destination
    local crosshair_ids = draw_target_crosshair(player, current_data.goal)
    for _, id in ipairs(crosshair_ids) do table.insert(player_move_data[matched_player_index].render_ids, id) end
  else
    if event.try_again_later then
      -- Re-request after a short delay, using stored goal
      if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Path temporarily unavailable, retrying...") end
      local retry_goal = current_data.goal
      script.on_nth_tick(game.tick + 60, function()
        local still_valid_player = game.players[matched_player_index]
        if still_valid_player and (still_valid_player.character or still_valid_player.vehicle) then
          local path_params = create_path_request_params(still_valid_player, retry_goal)
          if not path_params then player_move_data[matched_player_index] = nil; return end
          local retry_path_id = still_valid_player.surface.request_path(path_params)
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
    local entity_to_move = player and (player.vehicle or player.character)
    local vehicle = player.vehicle

    if not entity_to_move or not player.connected then
      stop_movement = true
    elseif vehicle then
      -- Handle vehicle movement (follow waypoints for safety)
      local distance = util_vector.distance(vehicle.position, data.goal)

      if distance < VEHICLE_PROXIMITY_THRESHOLD() then
        stop_movement = true
        player.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
      else
        -- If player takes manual control of vehicle, cancel auto-drive
        if player.driving then
          stop_movement = true
        else
          player.riding_state = get_vehicle_riding_state(vehicle, data.goal)
        end
      end
    else
      -- Handle character movement
      local character = player.character
      local waypoint = data.path[data.current_waypoint]

      -- Stuck detection
      if data.last_position then
        local moved_dist = util_vector.distance(character.position, data.last_position)
        if moved_dist < 0.05 then -- If moved less than a small amount
          data.stuck_counter = data.stuck_counter + 1
        else
          data.stuck_counter = 0 -- Reset if moved
        end
      end
      data.last_position = character.position

      if data.stuck_counter > STUCK_THRESHOLD() then
        if DEBUG_MODE(player_index) then player.print("Click2Move: Character is stuck, attempting to repath.") end
        local path_params = create_path_request_params(player, data.goal)
        if path_params then
          data.path_id = player.surface.request_path(path_params)
          data.path = nil -- Clear old path to indicate we are waiting for a new one
        end
        goto continue -- Skip rest of movement logic for this tick
      end

      if waypoint and waypoint.position then
        ---@diagnostic disable-next-line: need-check-nil
        local distance = util_vector.distance(character.position, waypoint.position)

        if distance < PROXIMITY_THRESHOLD() then
          data.current_waypoint = data.current_waypoint + 1
        end

        if data.current_waypoint > #data.path then
          stop_movement = true
        else
          -- Re-check waypoint after potential increment
          waypoint = data.path[data.current_waypoint]
          if waypoint and waypoint.position then
            local direction = get_character_direction(character.position, waypoint.position)
            if direction then
              if DEBUG_MODE(player_index) then
                player.print("Click2Move: Setting walk to true, direction: " .. direction)
              end
              character.walking_state = {
                walking = true,
                direction = direction
              }
            else
              -- Reached waypoint, let's check next one on next tick
              character.walking_state = {
                walking = false,
                direction = defines.direction.north,
              }
            end
          else
            stop_movement = true
          end
        end
      else
        stop_movement = true -- Path is finished or invalid waypoint
      end
    end

    if stop_movement then
      if entity_to_move then
        if entity_to_move.type == "character" then
          entity_to_move.walking_state.walking = false
        elseif entity_to_move.type == "car" then
          -- Stop the vehicle
          player.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
        end
      end
      -- Clean up renderings if present (use get_object_by_id and :destroy)
      if data.render_ids then
        for _, render_id in ipairs(data.render_ids) do
          if render_id and render_id.valid then
            render_id:destroy()
          end
        end
        data.render_ids = nil
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
  script.on_event("bazinga", function (event)
    game.print("bazinga!")
    local player = game.players[event.player_index]
    if player and player.character then
      player.character.walking_state = {
        walking = true,
        direction = 0.875  -- North as double
      }
    end
  end)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_nth_tick(UPDATE_INTERVAL(), on_tick)
  -- Clear data on load
  player_move_data = {}
end

script.on_init(initialize)
script.on_load(initialize)
script.on_configuration_changed(initialize)