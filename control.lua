--[[
  Click2Move control.lua
  Author: Me
  Description: Allows players to click to move their character.
]]

-- Vector utilities
local util_vector = {}
util_vector.distance = function(a, b)
  return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end

-- Format position for GUI text
local function format_pos(pos)
  if not pos then return "(?, ?)" end
  return string.format("(%.2f, %.2f)", pos.x, pos.y)
end

-- Draws a crosshair at a given position for a player. color optional (defaults to green)
local function draw_target_crosshair(player, position, color)
  local size = 0.5
  local default_color = {r = 0.1, g = 0.8, b = 0.1, a = 0.9}
  local col = color or player.color or default_color
  if not col.a then col.a = 0.9 end
  local surface = player.surface
  local players = {player}
  local time_to_live = 600 -- 10 seconds

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
local function get_vehicle_riding_state(vehicle, target_pos)
  local radians = vehicle.orientation * 2 * math.pi
  local v1 = {x = target_pos.x - vehicle.position.x, y = target_pos.y - vehicle.position.y}

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

-- Build path request parameters
local function create_path_request_params(player, goal)
  local entity_to_move = player.vehicle or player.character
  if not entity_to_move then return nil end

  local start_pos = entity_to_move.position
  local pathfind_for_character = not player.vehicle

  local bounding_box = entity_to_move.prototype and entity_to_move.prototype.collision_box or {{-0.2,-0.2},{0.2,0.2}}
  if pathfind_for_character then
    local margin = settings.global["c2m-character-margin"] and settings.global["c2m-character-margin"].value or 0.45
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
  end

  local collision_mask = (entity_to_move.prototype and entity_to_move.prototype.collision_mask) and entity_to_move.prototype.collision_mask or {}

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

-- Config getters
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

-- Persistent-in-session table (cleared on init/config change)
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
      goals = {} -- queue of goals (each is {x=..., y=...})
    }
    player_move_data[player_index] = d
  end
  return d
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

-- Safe destroy of rendering Lua objects (they are LuaRenderObject instances)
local function safe_destroy_renderings(render_objs)
  if not render_objs then return end
  for _, robj in ipairs(render_objs) do
    if robj and robj.valid then
      robj:destroy()
    end
  end
end

-- Start a path request for the player's current first goal (if any)
local function start_path_request_for_player(player_index)
  local player = game.players[player_index]
  if not player or not player.valid or not player.connected then return end
  local data = ensure_player_data(player_index)
  if not data.goals or #data.goals == 0 then return end
  if data.path or data.path_id then return end -- already waiting or following a path

  local goal = data.goals[1]
  if not goal then return end

  local params = create_path_request_params(player, goal)
  if not params then
    -- cannot make path; drop this goal and try next
    table.remove(data.goals, 1)
    update_gui_for_player(player_index)
    -- try next if present
    if data.goals[1] then start_path_request_for_player(player_index) end
    return
  end

  -- request path
  local path_id = player.surface.request_path(params)
  data.path_id = path_id
  data.retry_count = data.retry_count or 0
  if DEBUG_MODE(player_index) then player.print("Click2Move: Requested path for " .. format_pos(goal) .. " (player " .. player_index .. ")") end
end

-- Handles the custom input to initiate movement
local function on_custom_input(event)
  if event.input_name ~= "c2m-move-command" then return end
  local player = game.players[event.player_index]
  if not player or not player.connected then return end
  if not (player.character or player.vehicle) then return end
  if not event.cursor_position then return end

  local data = ensure_player_data(player.index)
  local goal = { x = event.cursor_position.x, y = event.cursor_position.y }

  if event.shift then -- TO FIX -- event.shift is undefined
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
    if DEBUG_MODE(player.index) then player.print("Click2Move: Set new goal: " .. format_pos(goal)) end
  end

  -- Ensure GUI reflects queue state
  update_gui_for_player(player.index)
  -- If not currently waiting for a path, immediately request one for first goal
  start_path_request_for_player(player.index)
end

-- Handles path request finished
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
  data.path_id = nil

  -- if path present and non-empty
  if event.path and #event.path > 0 then
    if DEBUG_MODE(matched_player_index) then player.print("Click2Move: Path found with " .. #event.path .. " waypoints for player " .. matched_player_index) end
    data.path = event.path
    data.current_waypoint = 1
    data.stuck_counter = 0
    data.last_position = nil
    data.retry_count = 0
    data.retry_at = nil

    -- render polyline using player's color (characters only)
    safe_destroy_renderings(data.render_objs)
    data.render_objs = {}

    if not player.vehicle and data.path and #data.path > 0 then
      -- collect positions
      local points = {}
      for _, wp in ipairs(data.path) do
        if wp and wp.position then table.insert(points, wp.position) end
      end

      local path_color = player.color or {r = 0.1, g = 0.8, b = 0.1, a = 0.9}
      if not path_color.a then path_color.a = 0.9 end

      for i = 1, math.max(0, #points - 1) do
        local from = points[i]; local to = points[i+1]
        local seg = rendering.draw_line{
          color = path_color,
          width = 2,
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

    update_gui_for_player(matched_player_index)
  else
    -- no path returned
    if event.try_again_later then
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
        update_gui_for_player(matched_player_index)
        -- start next if present
        if data.goals[1] then start_path_request_for_player(matched_player_index) end
      end
    else
      -- permanent failure; notify and drop current goal
      player.print("Click2Move: No path found to " .. format_pos(data.goals[1]))
      table.remove(data.goals, 1)
      safe_destroy_renderings(data.render_objs)
      data.render_objs = nil
      data.path = nil
      data.path_id = nil
      update_gui_for_player(matched_player_index)
      if data.goals[1] then start_path_request_for_player(matched_player_index) end
    end
  end
end

-- GUI click: cancel
local function on_gui_click(event)
  if not event.element or not event.element.valid then return end
  if event.element.name ~= GUI_CANCEL_NAME then return end

  local player = game.players[event.player_index]
  if not player or not player.valid then return end

  local data = player_move_data[player.index]
  if data then
    -- clear everything for this player
    safe_destroy_renderings(data.render_objs)
    player_move_data[player.index] = nil
  end
  -- destroy GUI (update will remove if anything left)
  if player.gui.top[GUI_ROOT_NAME] and player.gui.top[GUI_ROOT_NAME].valid then
    player.gui.top[GUI_ROOT_NAME].destroy()
  end
  if DEBUG_MODE(player.index) then player.print("Click2Move: Auto-walk cancelled by player.") end
end

-- Main per-interval update
local function on_tick(event)
  for player_index, data in pairs(player_move_data) do
    local player = game.players[player_index]
    if not player or not player.connected then
      safe_destroy_renderings(data.render_objs)
      player_move_data[player_index] = nil
      goto continue
    end

    -- if no active path and retry time arrived, request again
    if (not data.path) and (not data.path_id) and data.retry_at and data.retry_at <= game.tick then
      start_path_request_for_player(player_index)
    end

    -- If no path and not waiting, but have queued goals, ensure we request a path for first goal
    if (not data.path) and (not data.path_id) and data.goals and #data.goals > 0 and (not data.retry_at) then
      start_path_request_for_player(player_index)
    end

    -- If still waiting for path, skip movement
    if not data.path then goto continue end

    local stop_movement = false
    local entity_to_move = player.vehicle or player.character
    local vehicle = player.vehicle

    if not entity_to_move then
      stop_movement = true
    elseif vehicle then
      local dist = util_vector.distance(vehicle.position, data.goals[1] or data.path[#data.path].position)
      if dist < VEHICLE_PROXIMITY_THRESHOLD() then
        stop_movement = true
        player.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
      else
        if player.driving then
          stop_movement = true
        else
          player.riding_state = get_vehicle_riding_state(vehicle, data.goals[1])
        end
      end
    else
      -- character handling
      local character = player.character
      if not character then stop_movement = true
      else
        if character.walking_state and character.walking_state.walking and not data.is_auto_walking then
          if DEBUG_MODE(player_index) then player.print("Click2Move: Player manually moved, cancelling auto-walk.") end
          stop_movement = true
        else
          local waypoint = data.path[data.current_waypoint]
          -- stuck detection
          if data.last_position then
            local moved = util_vector.distance(character.position, data.last_position)
            if moved < 0.03 then data.stuck_counter = data.stuck_counter + 1 else data.stuck_counter = 0 end
          end
          data.last_position = { x = character.position.x, y = character.position.y }

          if data.stuck_counter > STUCK_THRESHOLD() then
            if DEBUG_MODE(player_index) then player.print("Click2Move: Character stuck; re-pathing/drop goal.") end
            data.retry_count = (data.retry_count or 0) + 1
            if data.retry_count <= MAX_PATH_RETRIES then
              data.path = nil
              data.path_id = nil
              data.retry_at = game.tick + PATH_RETRY_DELAY_TICKS
            else
              -- drop this goal and move to next
              table.remove(data.goals, 1)
              safe_destroy_renderings(data.render_objs)
              data.render_objs = nil
              data.path = nil
              data.path_id = nil
              data.retry_count = 0
              update_gui_for_player(player_index)
              if data.goals[1] then start_path_request_for_player(player_index) end
            end
            goto continue
          end

          if waypoint and waypoint.position then
            local dist_wp = util_vector.distance(character.position, waypoint.position)
            if dist_wp < PROXIMITY_THRESHOLD() then
              data.current_waypoint = data.current_waypoint + 1
            end

            if data.current_waypoint > #data.path then
              stop_movement = true
            else
              waypoint = data.path[data.current_waypoint]
              if waypoint and waypoint.position then
                local direction = get_character_direction(character.position, waypoint.position)
                if direction then
                  data.is_auto_walking = true
                  character.walking_state = { walking = true, direction = direction }
                else
                  data.is_auto_walking = false
                  character.walking_state = { walking = false, direction = defines.direction.north }
                end
              else
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
      -- arrived or cancelled for this path/goal
      if entity_to_move and entity_to_move.valid then
        if entity_to_move.type == "character" then
          entity_to_move.walking_state = { walking = false, direction = defines.direction.north }
        elseif vehicle and player.valid then
          player.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
        end
      end

      -- cleanup render objects for this goal
      safe_destroy_renderings(data.render_objs)
      data.render_objs = nil
      data.path = nil
      data.path_id = nil
      data.current_waypoint = 1
      data.is_auto_walking = false
      data.stuck_counter = 0
      data.last_position = nil
      data.retry_count = 0
      data.retry_at = nil

      -- remove completed goal from queue (it was goals[1])
      if data.goals and #data.goals > 0 then
        table.remove(data.goals, 1)
      end

      -- if next goal exists, start path request
      if data.goals and #data.goals > 0 then
        update_gui_for_player(player_index)
        start_path_request_for_player(player_index)
      else
        -- no more goals -> cleanup data and GUI
        update_gui_for_player(player_index)
        player_move_data[player_index] = nil
      end
    end

    ::continue::
  end
end

-- Event registration and initialization
local function initialize()
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("bazinga", function(event)
    local player = game.players[event.player_index]
    if player and player.character then
      player.character.walking_state = { walking = true, direction = defines.direction.north }
    end
    game.print("bazinga!")
  end)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_event(defines.events.on_gui_click, on_gui_click)

  local interval = UPDATE_INTERVAL() or 1
  script.on_nth_tick(interval, on_tick)

  player_move_data = {}
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_load(function()
  -- re-register handlers on load
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("bazinga", function(event)
    local player = game.players[event.player_index]
    if player and player.character then
      player.character.walking_state = { walking = true, direction = defines.direction.north }
    end
    game.print("bazinga!")
  end)
  script.on_event(defines.events.on_script_path_request_finished, on_path_request_finished)
  script.on_event(defines.events.on_gui_click, on_gui_click)
  script.on_nth_tick(UPDATE_INTERVAL() or 1, on_tick)
end)
