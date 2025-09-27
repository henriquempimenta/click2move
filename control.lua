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

  local ids = {}
  table.insert(ids, rendering.draw_line{ color = color, width = 3, from = {x = position.x - size, y = position.y}, to = {x = position.x + size, y = position.y}, surface = surface, players = players, time_to_live = time_to_live })
  table.insert(ids, rendering.draw_line{ color = color, width = 3, from = {x = position.x, y = position.y - size}, to = {x = position.x, y = position.y + size}, surface = surface, players = players, time_to_live = time_to_live })
  return ids
end

-- Determines 8-way direction for character movement (returns defines.direction constants)
local function get_character_direction(from, to)
  local distance_threshold = 0.15 -- small threshold to consider equal
  local dx = to.x - from.x
  local dy = to.y - from.y

  if math.abs(dx) <= distance_threshold and math.abs(dy) <= distance_threshold then
    return nil
  end

  -- Prefer cardinal if dominant component is large
  if math.abs(dx) > math.abs(dy) then
    if dx > 0 then
      -- east
      if dy > distance_threshold then return defines.direction.southeast end
      if dy < -distance_threshold then return defines.direction.northeast end
      return defines.direction.east
    else
      -- west
      if dy > distance_threshold then return defines.direction.southwest end
      if dy < -distance_threshold then return defines.direction.northwest end
      return defines.direction.west
    end
  else
    if dy > 0 then
      return defines.direction.south
    else
      return defines.direction.north
    end
  end
end

-- Determines vehicle riding state to move towards a target
local function get_vehicle_riding_state(vehicle, target_pos)
  -- orientation is [0,1) where 0 = north, increases clockwise
  local radians = vehicle.orientation * 2 * math.pi
  local v1 = {x = target_pos.x - vehicle.position.x, y = target_pos.y - vehicle.position.y}

  -- Convert to vehicle-local coordinates (x forward, y right)
  local forward = v1.x * math.cos(radians) + v1.y * math.sin(radians)
  local right = -v1.x * math.sin(radians) + v1.y * math.cos(radians)

  local steer_threshold = 0.2
  local accel_threshold = 0.2

  local direction = defines.riding.direction.straight
  if right < -steer_threshold then
    direction = defines.riding.direction.left
  elseif right > steer_threshold then
    direction = defines.riding.direction.right
  end

  local acceleration = defines.riding.acceleration.braking
  if forward > accel_threshold then
    acceleration = defines.riding.acceleration.accelerating
  elseif forward < -accel_threshold then
    acceleration = defines.riding.acceleration.reversing
  else
    acceleration = defines.riding.acceleration.braking
  end

  return {direction = direction, acceleration = acceleration}
end

-- Helper function to create path request parameters
local function create_path_request_params(player, goal)
  local entity_to_move = player.vehicle or player.character
  if not entity_to_move then return nil end

  local start_pos = entity_to_move.position
  local pathfind_for_character = not player.vehicle

  local bounding_box = entity_to_move.prototype.collision_box or {{-0.2,-0.2},{0.2,0.2}}
  -- For characters, use a slightly larger bounding box to avoid getting stuck on corners.
  if pathfind_for_character then
    local margin = settings.global["c2m-character-margin"] and settings.global["c2m-character-margin"].value or 0.45
    bounding_box = {
      left_top = { x = bounding_box.left_top.x - margin, y = bounding_box.left_top.y - margin },
      right_bottom = { x = bounding_box.right_bottom.x + margin, y = bounding_box.right_bottom.y + margin }
    }
  end

  -- Defensive access to collision_mask (vehicles/characters have one)
  local collision_mask = entity_to_move.prototype.collision_mask or {}

  return {
    bounding_box = bounding_box,
    collision_mask = collision_mask,
    start = start_pos,
    goal = goal,
    pathfind_flags = { allow_destroy_friendly_entities = pathfind_for_character, cache = not pathfind_for_character },
    force = player.force.name,
    entity_to_ignore = entity_to_move
  }
end

-- Config getters (wrapped as functions so they reflect updated startup/global values)
local function PROXIMITY_THRESHOLD()
  return settings.startup["c2m-character-proximity-threshold"] and settings.startup["c2m-character-proximity-threshold"].value or 1.5
end
local function UPDATE_INTERVAL()
  return settings.startup["c2m-update-interval"] and settings.startup["c2m-update-interval"].value or 1
end
local function VEHICLE_PROXIMITY_THRESHOLD()
  return settings.startup["c2m-vehicle-proximity-threshold"] and settings.startup["c2m-vehicle-proximity-threshold"].value or 6.0
end
local function STUCK_THRESHOLD()
  return settings.startup["c2m-stuck-threshold"] and settings.startup["c2m-stuck-threshold"].value or 30
end
local function DEBUG_MODE(player_index)
  local p = game.players[player_index]
  if not p then return false end
  local s = settings.get_player_settings(p)
  return s and s["c2m-debug-mode"] and s["c2m-debug-mode"].value
end

-- A non-persistent table to store active movement data (cleared on load)
local player_move_data = {}

-- Maximum number of path retry attempts when try_again_later is signaled
local MAX_PATH_RETRIES = 5
-- number of ticks to wait before retrying path request
local PATH_RETRY_DELAY_TICKS = 60

-- Handles the custom input to initiate movement
local function on_custom_input(event)
  if event.input_name ~= "c2m-move-command" then return end

  local player = game.players[event.player_index]
  if not player then return end
  if not player.connected then return end
  if not (player.character or player.vehicle) then return end
  if not event.cursor_position then return end

  -- reset any previous data for this player
  player_move_data[player.index] = nil

  if DEBUG_MODE(player.index) then player.print("Click2Move: Path request initiated.") end

  local goal = event.cursor_position
  local path_params = create_path_request_params(player, goal)
  if not path_params then return end

  local path_id = player.surface.request_path(path_params)

  player_move_data[player.index] = {
    path_id = path_id,
    goal = goal,
    requesting_player_index = player.index,
    retry_count = 0,
    retry_at = nil,       -- tick when to retry
    path = nil,
    current_waypoint = 1,
    render_objs = nil,
    last_position = nil,
    stuck_counter = 0,
    is_auto_walking = false
  }
end

-- Handles the result of the path request
local function on_path_request_finished(event)
  -- match player by path id
  local matched_player_index = nil
  for p_index, data in pairs(player_move_data) do
    if data.path_id == event.id then
      matched_player_index = p_index
      break
    end
  end

  if not matched_player_index then return end

  local player = game.players[matched_player_index]
  if not player or not player.connected then
    -- player not available, clear data
    player_move_data[matched_player_index] = nil
    return
  end

  local data = player_move_data[matched_player_index]
  -- clear stored path_id (we're done with that request)
  data.path_id = nil

  if event.path and #event.path > 0 then
    if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Path found with " .. #event.path .. " waypoints.") end

    -- store path and reset counters
    data.path = event.path
    data.current_waypoint = 1
    data.stuck_counter = 0
    data.last_position = nil
    data.retry_count = 0
    data.retry_at = nil

    -- render visual waypoints (characters only)
    local render_objs = {}
    if not player.vehicle then
      for _, waypoint in ipairs(event.path) do
        local render_obj = rendering.draw_circle{
          color = {r = 0.1, g = 0.8, b = 0.1, a = 0.5},
          radius = 0.5,
          target = waypoint.position,
          surface = player.surface,
          players = {player},
          time_to_live = 600
        }
        table.insert(render_objs, render_obj)
      end
    end
    -- crosshair at destination
    local crosshair_ids = draw_target_crosshair(player, data.goal)
    for _, id in ipairs(crosshair_ids) do table.insert(render_objs, id) end

    data.render_objs = render_objs
  else
    -- no path returned
    if event.try_again_later then
      -- schedule a retry (store tick to attempt later)
      data.retry_count = (data.retry_count or 0) + 1
      if data.retry_count <= MAX_PATH_RETRIES then
        data.retry_at = game.tick + PATH_RETRY_DELAY_TICKS
        if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Path temporarily unavailable, will retry in " .. PATH_RETRY_DELAY_TICKS .. " ticks (attempt " .. data.retry_count .. ").") end
      else
        if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Max retry attempts reached. Cancelling.") end
        player.print("Click2Move: No path found.")
        player_move_data[matched_player_index] = nil
      end
    else
      player.print("Click2Move: No path found.")
      player_move_data[matched_player_index] = nil
    end
  end
end

-- Helper to safely destroy rendering Objects
local function safe_destroy_renderings(render_objs)
  if not render_objs then return end
  for _, robj in ipairs(render_objs) do
    if robj then
      robj:destroy()
    end
  end
end

-- Handles player movement each update interval
local function on_tick(event)
  for player_index, data in pairs(player_move_data) do
    local player = game.players[player_index]
    if not player or not player.connected then
      -- cleanup
      safe_destroy_renderings(data.render_objs)
      player_move_data[player_index] = nil
      goto continue
    end

    -- If we are waiting for a path and a retry time has arrived, re-request
    if (not data.path) and (not data.path_id) and data.retry_at and data.retry_at <= game.tick then
      local path_params = create_path_request_params(player, data.goal)
      if path_params then
        data.path_id = player.surface.request_path(path_params)
        data.retry_at = nil
      else
        -- can't path (maybe player dead or no entity), cancel
        safe_destroy_renderings(data.render_objs)
        player_move_data[player_index] = nil
        goto continue
      end
    end

    -- If still waiting for path, skip per-player movement
    if not data.path then goto continue end

    local stop_movement = false
    local entity_to_move = player.vehicle or player.character
    local vehicle = player.vehicle

    if not entity_to_move then
      stop_movement = true
    elseif vehicle then
      -- VEHICLE handling
      local dist_to_goal = util_vector.distance(vehicle.position, data.goal or vehicle.position)
      if dist_to_goal < VEHICLE_PROXIMITY_THRESHOLD() then
        stop_movement = true
        player.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
      else
        -- Cancel auto-drive if player is manually driving
        if player.driving then
          stop_movement = true
        else
          local ride_state = get_vehicle_riding_state(vehicle, data.goal)
          player.riding_state = ride_state
        end
      end
    else
      -- CHARACTER handling
      local character = player.character
      if not character then
        stop_movement = true
      else
        -- check if player manually moved (cancel)
        if character.walking_state and character.walking_state.walking and not data.is_auto_walking then
          if DEBUG_MODE(player_index) then player.print("Click2Move: Player manually moved, cancelling auto-walk.") end
          stop_movement = true
        else
          local waypoint = data.path[data.current_waypoint]

          -- stuck detection
          if data.last_position then
            local moved_dist = util_vector.distance(character.position, data.last_position)
            if moved_dist < 0.03 then
              data.stuck_counter = data.stuck_counter + 1
            else
              data.stuck_counter = 0
            end
          end
          data.last_position = { x = character.position.x, y = character.position.y }

          if data.stuck_counter > STUCK_THRESHOLD() then
            if DEBUG_MODE(player_index) then player.print("Click2Move: Character stuck; requesting re-path.") end
            -- attempt re-path (throttle by retry_count)
            data.retry_count = (data.retry_count or 0) + 1
            if data.retry_count <= MAX_PATH_RETRIES then
              local path_params = create_path_request_params(player, data.goal)
              if path_params then
                data.path_id = player.surface.request_path(path_params)
                data.path = nil -- now waiting for new path
                data.retry_at = nil
              else
                -- can't create path params -> cancel
                stop_movement = true
              end
            else
              if DEBUG_MODE(player_index) then player.print("Click2Move: Max re-path attempts reached, cancelling.") end
              stop_movement = true
            end
            goto continue
          end

          if waypoint and waypoint.position then
            local distance = util_vector.distance(character.position, waypoint.position)
            -- if close enough to waypoint, advance
            if distance < PROXIMITY_THRESHOLD() then
              data.current_waypoint = data.current_waypoint + 1
            end

            if data.current_waypoint > #data.path then
              stop_movement = true
            else
              -- recalc waypoint after maybe incrementing
              waypoint = data.path[data.current_waypoint]
              if waypoint and waypoint.position then
                local direction = get_character_direction(character.position, waypoint.position)
                if direction then
                  -- Set walking_state. Mark that we are controlling the walking (is_auto_walking)
                  data.is_auto_walking = true
                  character.walking_state = {
                    walking = true,
                    direction = direction
                  }
                else
                  -- reached the waypoint precisely; stop walking this tick
                  data.is_auto_walking = false
                  character.walking_state = {
                    walking = false,
                    direction = defines.direction.north -- must have a direction
                  }
                end
              else
                -- no valid waypoint
                stop_movement = true
              end
            end
          else
            stop_movement = true
          end
        end
      end
    end

    if stop_movement then
      if entity_to_move then
        if entity_to_move.type == "character" and entity_to_move.valid then
          -- prefer turning off walking without forcing direction
          entity_to_move.walking_state = { walking = false, direction = defines.direction.north }
        elseif vehicle and player.valid then
          player.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
        end
      end

      -- cleanup renderings
      safe_destroy_renderings(data.render_objs)
      player_move_data[player_index] = nil
    end

    ::continue::
  end
end

-- Centralized function for event registration
local function initialize()
  -- register inputs & event handlers
  script.on_event("c2m-move-command", on_custom_input)

  script.on_event("bazinga", function (event)
    local player = game.players[event.player_index]
    if player and player.character then
      -- use defines.direction constants; here: north (0)
      player.character.walking_state = { walking = true, direction = defines.direction.north }
    end
    game.print("bazinga!")
  end)

  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)

  -- main loop: register with startup interval
  local interval = UPDATE_INTERVAL() or 1
  script.on_nth_tick(interval, on_tick)

  -- we do not persist player_move_data across saves; clear on init/config changes
  -- (it's safe to keep it empty on load; not serializable)
  player_move_data = {}
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
-- script.on_load should not perform heavy initialization, but to be safe we re-register handlers
script.on_load(function()
  -- rebind the handlers so closures are valid after load
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("bazinga", function (event)
    local player = game.players[event.player_index]
    if player and player.character then
      player.character.walking_state = { walking = true, direction = defines.direction.north }
    end
    game.print("bazinga!")
  end)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_nth_tick(UPDATE_INTERVAL() or 1, on_tick)
end)
