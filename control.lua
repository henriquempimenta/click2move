--[[
  Click2Move control.lua
  Author: Me
  Description: Allows players to click to move their character.
]]

-- Format position for GUI text
local function format_pos(pos)
  if not pos then return "(?, ?)" end
  return string.format("(%.2f, %.2f)", pos.x, pos.y)
end

-- Draws a crosshair at a given position for a player. color optional (defaults to green)
---@param player LuaPlayer
---@param position MapPosition
---@param color Color
---@return LuaRenderObject[]
local function draw_target_crosshair(player, position, color)
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

-- 8-way direction selection (returns defines.direction)
---@param from MapPosition
---@param to MapPosition
---@return defines.direction | nil
local function get_character_direction(from, to)
  local distance_threshold = 0.15
  local dx = to.x - from.x
  local dy = to.y - from.y

  if math.abs(dx) <= distance_threshold and math.abs(dy) <= distance_threshold then
    return nil
  end

  if math.abs(dx) > math.abs(dy) then
    if dx > 0 then
      if dy > distance_threshold then return defines.direction.southeast end
      if dy < -distance_threshold then return defines.direction.northeast end
      return defines.direction.east
    else
      if dy > distance_threshold then return defines.direction.southwest end
      if dy < -distance_threshold then return defines.direction.northwest end
      return defines.direction.west
    end
  else
    if dy > 0 then return defines.direction.south else return defines.direction.north end
  end
end

-- Vehicle riding state towards a target
---@param vehicle LuaEntity
---@param target_pos MapPosition
---@return RidingState
local function get_vehicle_riding_state(vehicle, target_pos)
  -- Factorio orientation: 0 is North, clockwise. Math functions: 0 is East, counter-clockwise.
  -- We need to adjust the angle. A 90-degree (pi/2) clockwise rotation is needed.
  -- Or, equivalently, subtract pi/2 from the standard angle.
  local radians = vehicle.orientation * 2 * math.pi - (math.pi / 2)
  local v1 = {x = target_pos.x - vehicle.position.x, y = target_pos.y - vehicle.position.y}

  local forward = v1.x * math.cos(radians) + v1.y * math.sin(radians)
  local right = -v1.x * math.sin(radians) + v1.y * math.cos(radians)

  local steer_threshold = 0.2
  local accel_threshold = 0.2

  ---@type defines.riding.direction
  local direction = defines.riding.direction.straight
  if right < -steer_threshold then
    direction = defines.riding.direction.left
  elseif right > steer_threshold then
    direction = defines.riding.direction.right
  end

  ---@type defines.riding.acceleration
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

-- Safe destroy of rendering Lua objects (they are LuaRenderObject instances)
---@param render_objs LuaRenderObject[]
local function safe_destroy_renderings(render_objs)
  if not render_objs then return end
  for _, render_obj in ipairs(render_objs) do
    if render_obj and render_obj.valid then
      render_obj:destroy()
    end
  end
end

-- Squared distance (faster than sqrt for comparisons)
---@param a MapPosition
---@param b MapPosition
---@return number
local function distance_sq(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

-- Advance to next waypoint if close enough (shared for char/vehicle)
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param waypoint_pos MapPosition
---@param threshold_sq number
---@return boolean
local function advance_waypoint(data, current_pos, waypoint_pos, threshold_sq)
  if distance_sq(current_pos, waypoint_pos) < threshold_sq then
    data.current_waypoint = data.current_waypoint + 1
    return true -- Advanced
  end
  return false
end

-- Detect stuck (shared, returns true if stuck)
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param last_pos MapPosition
---@param counter_field "stuck_counter" | "vehicle_stuck_counter
---@param threshold number
---@param min_move number
---@return boolean
local function detect_stuck(data, current_pos, last_pos, counter_field, threshold, min_move)
  if not last_pos then return false end
  local moved_sq = distance_sq(current_pos, last_pos)
  if math.sqrt(moved_sq) < min_move then  -- Use sqrt only here (rare)
    data[counter_field] = data[counter_field] + 1
  else
    data[counter_field] = 0
  end
  return data[counter_field] > threshold
end

-- Set character walking state
local function set_character_walking(character, data, waypoint_pos)
  local direction = get_character_direction(character.position, waypoint_pos)
  if direction then
    data.is_auto_walking = true
    character.walking_state = { walking = true, direction = direction }
  else
    data.is_auto_walking = false
    character.walking_state = { walking = false, direction = defines.direction.north }
  end
end

-- Set vehicle riding state
---@param player LuaPlayer
---@param vehicle LuaEntity
---@param target_pos MapPosition
local function set_vehicle_riding(player, vehicle, target_pos)
  local riding = get_vehicle_riding_state(vehicle, target_pos)
  vehicle.riding_state = riding
end

-- Cleanup movement state (shared)
---@param entity_to_move LuaEntity
---@param player LuaPlayer
---@param data PlayerMoveData
local function cleanup_movement(entity_to_move, player, data)
  if entity_to_move and entity_to_move.valid then
    if entity_to_move.type == "character" then
      entity_to_move.walking_state = { walking = false, direction = defines.direction.north }
    elseif player.vehicle then
      entity_to_move.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
    end
  end
  safe_destroy_renderings(data.render_objs)
  data.render_objs = nil
  data.path = nil
  data.path_id = nil
  data.current_waypoint = 1
  data.is_auto_walking = false
  data.stuck_counter = 0
  data.last_position = nil
  data.vehicle_stuck_counter = 0
  data.last_vehicle_position = nil
  data.retry_count = 0
  data.retry_at = nil
  data.is_straight_line_move = nil
end


---@class Config
---@field character_margin number
---@field proximity_threshold number
---@field update_interval number
---@field vehicle_proximity_threshold number
---@field stuck_threshold number
---@field vehicle_path_margin number

-- Cached config table (populated on init/load)
---@type Config
local config = {
  character_margin = 0.45,
  proximity_threshold = 1.5,
  update_interval = 1,
  vehicle_proximity_threshold = 6.0,
  stuck_threshold = 30,
  vehicle_path_margin = 2.0
}

local function load_config()
  ---@diagnostic disable: assign-type-mismatch
  config.character_margin = settings.global["c2m-character-margin"].value or 0.45
  config.proximity_threshold = settings.startup["c2m-character-proximity-threshold"].value or 1.5
  config.update_interval = settings.startup["c2m-update-interval"].value or 1
  config.vehicle_proximity_threshold = settings.startup["c2m-vehicle-proximity-threshold"].value or 6.0
  config.stuck_threshold = settings.startup["c2m-stuck-threshold"].value or 30
  config.vehicle_path_margin = settings.startup["c2m-vehicle-path-margin"].value or 2.0
  ---@diagnostic enable: assign-type-mismatch
end

---@param player_index integer|string
---@return boolean
local function DEBUG_MODE(player_index)
  local p = game.players[player_index]
  if not p then return false end
  return settings.get_player_settings(p)["c2m-debug-mode"].value ~= false  -- Simplified check
end

-- Check if the player is wearing "mech-armor" or jetpack flying armor
---@param player LuaPlayer
---@return boolean
local function is_flying(player)
  if not player or not player.character then return false end
  
  local armor_inv = player.character.get_inventory(defines.inventory.character_armor)
  if not (armor_inv and armor_inv[1] and armor_inv[1].valid_for_read) then return false end
  
  -- Check for mech-armor
  if armor_inv[1].name == "mech-armor" then return true end
  
  -- Check if Jetpack mod is loaded and player is jetpacking
  if script.active_mods["jetpack"] then
    local is_jetpacking = remote.call("jetpack", "is_jetpacking", {character = player.character})
    if is_jetpacking then return true end
  end
  
  return false
end

---@class PlayerMoveData
---@field path_id? uint32
---@field path? PathfinderWaypoint[]
---@field current_waypoint uint32
---@field retry_count uint32
---@field retry_at? uint32
---@field render_objs? LuaRenderObject[]
---@field last_position? MapPosition
---@field stuck_counter uint32
---@field is_auto_walking boolean
---@field goals MapPosition[]
---@field vehicle_stuck_counter uint32
---@field last_vehicle_position? MapPosition
---@field is_straight_line_move? boolean

-- Persistent-in-session table (cleared on init/config change)
---@type table<uint32, PlayerMoveData>
local player_move_data = {}

-- Retry constants
local MAX_PATH_RETRIES = 5
local PATH_RETRY_DELAY_TICKS = 60

-- Helper: create or get player's data
local function ensure_player_data(player_index)
  local d = player_move_data[player_index]
  if not d then
    d = {
      path_id = nil,
      path = nil,
      current_waypoint = 1,
      retry_count = 0,
      retry_at = nil,
      render_objs = nil,
      last_position = nil,
      stuck_counter = 0,
      is_auto_walking = false,
      goals = {}, -- queue of goals (each is {x=..., y=...})
      vehicle_stuck_counter = 0,
      last_vehicle_position = nil
    }
    player_move_data[player_index] = d
  end
  return d
end

function tableToString(tbl)
    if type(tbl) ~= "table" then return tostring(tbl) end
    local str = "{ "
    for k, v in pairs(tbl) do
        str = str .. "[" .. tostring(k) .. "] = " .. tableToString(v) .. ", "
    end
    str = str:sub(1, -3) .. " }"
    return str
end

-- Build path request parameters
---@param player LuaPlayer
---@param goal MapPosition
---@return LuaSurface.request_path_param | nil
local function create_path_request_params(player, goal)
  local entity_to_move = player.vehicle or player.character
  if not entity_to_move then return nil end

  local start_pos = entity_to_move.position
  local bounding_box = entity_to_move.prototype and entity_to_move.prototype.collision_box or {{-0.2,-0.2},{0.2,0.2}}
  ---@type number
  local margin = 0
  if player.character.vehicle then
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
      allow_destroy_friendly_entities = (not player.vehicle),
      cache = (player.vehicle ~= nil),
    },
    force = player.force.name,
    entity_to_ignore = entity_to_move
  }
end

-- GUI utilities
local GUI_ROOT_NAME = "c2m_root_flow"
local GUI_LABEL_NAME = "c2m_status_label"
local GUI_CANCEL_NAME = "c2m_cancel_button"

local function create_gui_for_player(player, data)
  if not player or not player.valid then return end
  -- create top-left small frame if not present
  if player.gui.top[GUI_ROOT_NAME] and player.gui.top[GUI_ROOT_NAME].valid then
    -- update existing
    local status = player.gui.top[GUI_ROOT_NAME][GUI_LABEL_NAME]
    if status and status.valid then
      local next_goal = data.goals[1]
      if next_goal then
        status.caption = "Auto-walking to " .. format_pos(next_goal)
      else
        status.caption = nil
      end
    end
    return
  end

  local frame = player.gui.top.add{ type = "flow", name = GUI_ROOT_NAME, direction = "horizontal" }
  frame.add{ type = "label", name = GUI_LABEL_NAME, caption = "" }
  frame.add{ type = "button", name = GUI_CANCEL_NAME, caption = "Cancel" }
end

local function update_gui_for_player(player_index)
  local player = game.players[player_index]
  if not player or not player.valid then return end
  local data = player_move_data[player_index]
  if data and data.goals and #data.goals > 0 then
    create_gui_for_player(player, data)
    -- set label text
    local root = player.gui.top[GUI_ROOT_NAME]
    if root and root[GUI_LABEL_NAME] and root[GUI_LABEL_NAME].valid then
      local next_goal = data.goals[1]
      root[GUI_LABEL_NAME].caption = "Auto-walking to " .. format_pos(next_goal) .. ( (#data.goals > 1) and ("  [queued: " .. tostring(#data.goals - 1) .. "]") or "" )
    end
  else
    -- destroy gui if exists
    if player.gui.top[GUI_ROOT_NAME] and player.gui.top[GUI_ROOT_NAME].valid then
      player.gui.top[GUI_ROOT_NAME].destroy()
    end
  end
end

-- Start a path request for the player's current first goal (if any)
---@param player_index integer | string
---@return boolean
local function start_path_request_for_player(player_index)
  local player = game.players[player_index]
  if not player or not player.valid or not player.connected then return false end
  local data = ensure_player_data(player_index)
  if not data.goals or #data.goals == 0 then return false end
  if data.path or data.path_id then return true end -- already waiting or following a path
  local entity_to_move = player.vehicle or player.character
  if not entity_to_move then return false end

  local goal = data.goals[1]
  if not goal then return false end

  local params = create_path_request_params(player, goal)
  if not params then
    -- Cannot make path; drop this goal and try next
    table.remove(data.goals, 1)
    update_gui_for_player(player_index)
    -- try next if present
    if data.goals[1] then start_path_request_for_player(player_index) end
    return true
  end

  -- Request path on the correct surface (where the entity is)
  local path_id = entity_to_move.surface.request_path(params)
  data.path_id = path_id
  data.retry_count = data.retry_count or 0
  if DEBUG_MODE(player_index) then
    player.print("Click2Move: Requested path for " .. format_pos(goal) .. " (player " .. player_index .. ")")
  end
  return true
end


-- Handle straight-line mech-armor movement (extracted branch)
---@param player_index integer
---@param data PlayerMoveData
---@param player LuaPlayer
---@return boolean stop_movement, boolean changed_gui
local function handle_straight_line_movement(player_index, data, player)
  local character = player.character
  local goal = data.goals[1]
  local changed_gui = false

  if not character or not goal or not is_flying(player) then
    if character and goal and not is_flying(player) then
      if DEBUG_MODE(player_index) then player.print("Click2Move: Mech-armor removed, switching to pathfinding.") end
      data.is_straight_line_move = nil
      changed_gui = start_path_request_for_player(player_index) -- Capture changed from path request
    end
    return true, changed_gui  -- Stop
  end

  local dist_sq_to_goal = distance_sq(character.position, goal)
  local threshold_sq = config.proximity_threshold ^ 2

  -- Stuck detection
  if detect_stuck(data, character.position, data.last_position, "stuck_counter", config.stuck_threshold, 0.03) then
    if DEBUG_MODE(player_index) then player.print("Click2Move: Mech movement stopped (stuck).") end
    return true, changed_gui
  end
  data.last_position = { x = character.position.x, y = character.position.y }

  if dist_sq_to_goal < threshold_sq then
    return true, changed_gui  -- Arrived
  end

  -- Move
  set_character_walking(character, data, goal)
  return false, changed_gui  -- Continue
end

-- Handles the custom input to initiate movement
---@param event EventData.CustomInputEvent
local function on_custom_input(event)
  if event.input_name ~= "c2m-move-command" and event.input_name ~= "c2m-move-command-queue" then return end
  local player = game.players[event.player_index]
  local entity_to_move = player and (player.vehicle or player.character)
  if not entity_to_move or not player.connected then return end
  if not event.cursor_position then return end

  -- Prevents the mod to be triggered when interacting with other GUIs, leading to unintentional movement.
  if player.opened_gui_type ~= defines.gui_type.none then return end

  -- Check if the click was on a different surface than the entity being controlled
  local changed = false

  local data = ensure_player_data(player.index)
  local goal = { x = event.cursor_position.x, y = event.cursor_position.y }

  -- If wearing mech armor, use straight-line movement and bypass pathfinding
  if is_flying(player) and not (player.vehicle or player.character.vehicle) then
    data.goals = { goal }
    changed = true
    data.is_straight_line_move = true -- Custom flag for our new mode
    if changed then update_gui_for_player(player.index) end
    return
  end
  changed = true

  if event.input_name == "c2m-move-command-queue" then
    -- queue this goal
    table.insert(data.goals, goal)
    if DEBUG_MODE(player.index) then player.print("Click2Move: Added goal to queue: " .. format_pos(goal)) end
  else
    -- replace queue with this goal
    data.goals = { goal }
    -- clear any in-progress path so we start fresh
    data.path = nil
    data.path_id = nil
    data.current_waypoint = 1
    data.retry_count = 0
    data.retry_at = nil
    safe_destroy_renderings(data.render_objs)
    data.render_objs = nil
    data.stuck_counter = 0
    data.last_position = nil
    data.is_auto_walking = false
    data.vehicle_stuck_counter = 0
    data.last_vehicle_position = nil
    if DEBUG_MODE(player.index) then player.print("Click2Move: Set new goal: " .. format_pos(goal)) end
  end

  -- Ensure GUI reflects queue state
  -- If not currently waiting for a path, immediately request one for first goal
  local path_request_changed = start_path_request_for_player(player.index)
  changed = changed or path_request_changed
  if changed then update_gui_for_player(player.index) end
end

-- Handles path request finished
---@param event EventData.on_script_path_request_finished
local function on_path_request_finished(event)
  -- find matching player
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
    player_move_data[matched_player_index] = nil
    return
  end

  local data = player_move_data[matched_player_index]
  local changed = false
  data.path_id = nil

  -- if path present and non-empty
  if event.path and #event.path > 0 then
    if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Path found with " .. #event.path .. " waypoints for player " .. matched_player_index) end
    data.path = event.path
    data.current_waypoint = 1
    data.stuck_counter = 0
    data.last_position = nil
    data.vehicle_stuck_counter = 0
    data.last_vehicle_position = nil
    data.retry_count = 0
    changed = true
    data.retry_at = nil

    -- render polyline using player's color (characters only)
    safe_destroy_renderings(data.render_objs)
    data.render_objs = {}
    
    if data.path and #data.path > 0 then
      -- collect positions
      local points = {}
      for _, wp in ipairs(data.path) do
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

      for i = 1, math.max(0, #points - 1) do
        local from = points[i]; local to = points[i+1]
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

    -- crosshair at destination
    local crosshair_objs = draw_target_crosshair(player, data.goals[1], player.color)
    for _, o in ipairs(crosshair_objs) do table.insert(data.render_objs, o) end

  else
    -- no path returned
    if event.try_again_later then
      changed = true
      data.retry_count = (data.retry_count or 0) + 1
      if data.retry_count <= MAX_PATH_RETRIES then
        data.retry_at = game.tick + PATH_RETRY_DELAY_TICKS
        if DEBUG_MODE(matched_player_index) then player.print("Click2Move: try_again_later - retrying in " .. PATH_RETRY_DELAY_TICKS .. " ticks (attempt " .. data.retry_count .. ")") end
      else
        if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Max retries reached, dropping goal.") end
        -- drop current goal and try next
        table.remove(data.goals, 1)
        safe_destroy_renderings(data.render_objs)
        data.render_objs = nil
        data.path = nil
        data.path_id = nil
        data.retry_at = nil
        data.retry_count = 0
        -- start next if present
        if data.goals[1] then changed = changed or start_path_request_for_player(matched_player_index) end
      end
    else
      -- permanent failure; notify and drop current goal
      player.print("Click2Move: No path found to " .. format_pos(data.goals[1]))
      changed = true
      table.remove(data.goals, 1)
      safe_destroy_renderings(data.render_objs)
      data.render_objs = nil
      data.path = nil
      data.path_id = nil
      if data.goals[1] then changed = changed or start_path_request_for_player(matched_player_index) end
    end
  end
  if changed then update_gui_for_player(matched_player_index) end
end

-- GUI click: cancel
local function on_gui_click(event)
  if not event.element or not event.element.valid then return end
  if event.element.name ~= GUI_CANCEL_NAME then return end

  local player = game.players[event.player_index]
  if not player or not player.valid then return end

  local data = player_move_data[player.index]
  local changed = true
  if data then
    -- clear everything for this player
    safe_destroy_renderings(data.render_objs)
    player_move_data[player.index] = nil
  end
  -- destroy GUI (update will remove if anything left)
  if DEBUG_MODE(player.index) then player.print("Click2Move: Auto-walk cancelled by player.") end
  if changed then update_gui_for_player(player.index) end
end

-- Main per-interval update
-- Handle vehicle movement
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param vehicle LuaEntity
---@return boolean
local function handle_vehicle_movement(player_index, data, player, vehicle)
  local waypoint = data.path[data.current_waypoint]
  if not waypoint or not waypoint.position then return true end  -- Invalid, stop

  local waypoint_pos = waypoint.position

  -- Stuck detection
  if detect_stuck(data, vehicle.position, data.last_vehicle_position, "vehicle_stuck_counter", config.stuck_threshold, 0.1) then
    if DEBUG_MODE(player_index) then player.print("Click2Move: Vehicle stuck; re-pathing.") end
    data.retry_count = (data.retry_count or 0) + 1
    if data.retry_count > MAX_PATH_RETRIES then
      -- This will be handled by cleanup_and_next_goal
      return true -- Signal to stop and cleanup
    else
      data.path = nil
      data.path_id = nil
      data.retry_at = game.tick + PATH_RETRY_DELAY_TICKS
    end
    return false  -- Don't move this tick, wait for retry
  end
  data.last_vehicle_position = { x = vehicle.position.x, y = vehicle.position.y }

  -- Dynamic threshold
  local speed = vehicle.speed or 0
  local dynamic_threshold_sq = (config.vehicle_proximity_threshold + speed * 2.0) ^ 2  -- Squared
  advance_waypoint(data, vehicle.position, waypoint_pos, dynamic_threshold_sq)

  if data.current_waypoint > #data.path then
    local goal_pos = data.goals[1]
    if distance_sq(vehicle.position, goal_pos) < dynamic_threshold_sq then
      return true  -- Arrived
    end
  end

  -- Move to current/next waypoint
  local target_pos = waypoint_pos
  if data.current_waypoint > #data.path then target_pos = data.goals[1] end
  set_vehicle_riding(player, vehicle, target_pos)
  return false  -- Continue
end

-- Handle character movement
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param character LuaEntity
---@return boolean
local function handle_character_movement(player_index, data, player, character)
  if character.walking_state and character.walking_state.walking and not data.is_auto_walking then
    if DEBUG_MODE(player_index) then player.print("Click2Move: Player manually moved, cancelling auto-walk.") end
    return true  -- Stop
  end

  local waypoint = data.path[data.current_waypoint]
  if not waypoint or not waypoint.position then return true end  -- Invalid, stop

  -- Stuck detection
  if detect_stuck(data, character.position, data.last_position, "stuck_counter", config.stuck_threshold, 0.03) then
    if DEBUG_MODE(player_index) then player.print("Click2Move: Character stuck; re-pathing/drop goal.") end
    data.retry_count = (data.retry_count or 0) + 1
    if data.retry_count > MAX_PATH_RETRIES then
      -- This will be handled by cleanup_and_next_goal
      return true -- Signal to stop and cleanup
    else
      data.path = nil
      data.path_id = nil
      data.retry_at = game.tick + PATH_RETRY_DELAY_TICKS
    end
    return false
  end
  data.last_position = { x = character.position.x, y = character.position.y }

  -- Dynamic threshold
  local speed_per_tick = character.character_running_speed or 0
  local dynamic_threshold_sq = (config.proximity_threshold + speed_per_tick * 1.5) ^ 2
  advance_waypoint(data, character.position, waypoint.position, dynamic_threshold_sq)

  if data.current_waypoint > #data.path then
    return true  -- Arrived
  end

  waypoint = data.path[data.current_waypoint]
  if waypoint and waypoint.position then
    set_character_walking(character, data, waypoint.position)
  else
    return true  -- Invalid waypoint
  end

  return false  -- Continue
end

-- Cleanup and advance to next goal
---@param player_index integer | string
---@param data PlayerMoveData
---@param player LuaPlayer
---@param entity_to_move LuaEntity
---@param changed boolean
---@return boolean
local function cleanup_and_next_goal(player_index, data, player, entity_to_move, changed)
  cleanup_movement(entity_to_move, player, data)
  changed = true -- Cleanup always changes state relevant to GUI
  if data.goals and #data.goals > 0 then
    table.remove(data.goals, 1)
  end
  if data.goals and #data.goals > 0 then
    local path_request_changed = start_path_request_for_player(player_index)
    changed = changed or path_request_changed
  else
    player_move_data[player_index] = nil
  end
  return changed
end

-- Simplified on_tick
local function on_tick(event)
  for player_index, data in pairs(player_move_data) do
    local player = game.players[player_index]
    if not player or not player.connected then
      safe_destroy_renderings(data.render_objs)
      player_move_data[player_index] = nil
      goto continue_player_loop
    end

    local stop_movement = false
    -- Declare these here to avoid goto jumping over their scope
    local entity_to_move = player.vehicle or player.character
    if not entity_to_move then
      player_move_data[player_index] = nil
      goto continue_player_loop
    end

    local changed = false
    local gui_update_from_handler = false

    -- Mech-armor straight-line
    if data.is_straight_line_move then
      stop_movement, gui_update_from_handler = handle_straight_line_movement(player_index, data, player)
      changed = changed or gui_update_from_handler
    else
      -- Ensure path if needed
      if not data.path and not data.path_id and data.goals and #data.goals > 0 and not data.retry_at then
        local path_request_changed = start_path_request_for_player(player_index)
        changed = changed or path_request_changed
      end

      if not data.path then goto continue_player_loop end  -- Waiting; skip

      local vehicle = player.vehicle or player.character.vehicle
      if vehicle then
        stop_movement = handle_vehicle_movement(player_index, data, player, vehicle)
      else
        stop_movement = handle_character_movement(player_index, data, player, player.character)
      end
    end

    -- If movement stopped (arrived, stuck, manual override, or invalid state)
    if stop_movement then
      changed = cleanup_and_next_goal(player_index, data, player, entity_to_move, changed)
    end

    if changed then
      update_gui_for_player(player_index)
    end

    ::continue_player_loop::
  end
end

-- Event registration and initialization
local function initialize()
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("c2m-move-command-queue", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_event(defines.events.on_gui_click, on_gui_click)

  load_config()
  script.on_nth_tick(config.update_interval, on_tick)

  player_move_data = {}
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_load(function()
  load_config()
  -- re-register handlers on load
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("c2m-move-command-queue", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_event(defines.events.on_gui_click, on_gui_click)
  script.on_nth_tick(config.update_interval, on_tick)
end)
