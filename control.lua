--[[
  Click2Move control.lua
  Author: Me
  Description: Allows players to click to move their character.

  This is the orchestrator — it requires all modules and wires up events.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Navigation = require("scripts/navigation")
local Rendering = require("scripts/rendering")
local GUI = require("scripts/gui")
local Pathfinding = require("scripts/pathfinding")
local Movement = require("scripts/movement")

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

  local changed = false

  local data = PlayerData.ensure(player.index)
  local goal = { x = event.cursor_position.x, y = event.cursor_position.y }

  -- If wearing mech armor or jetpacking, use straight-line movement and bypass pathfinding
  if PlayerData.is_bypassing_pathfinding(player) and not (player.vehicle or player.character.vehicle) then
    data.goals = { { position = goal } }
    changed = true
    data.is_straight_line_move = true -- Custom flag for our new mode
    if changed then GUI.update(player.index) end
    return
  end
  changed = true

  if event.input_name == "c2m-move-command-queue" then
    -- queue this goal
    table.insert(data.goals, { position = goal })
    if Config.is_debug(player.index) then player.print("Click2Move: Added goal to queue: " .. Util.format_pos(goal)) end
  else
    -- replace queue with this goal
    data.goals = { { position = goal } }
    -- clear any in-progress path so we start fresh
    data.current_waypoint = 1
    Util.safe_destroy_renderings(data.render_objs)
    data.render_objs = nil
    data.stuck_counter = 0
    data.last_position = nil
    data.is_auto_walking = false
    data.vehicle_stuck_counter = 0
    data.last_vehicle_position = nil

    -- Reset advanced stuck fields
    data.closest_dist_to_goal = 999999
    data.no_progress_ticks = 0
    data.stuck_state = "none"
    data.stuck_timer = 0
    data.slide_direction = nil

    if Config.is_debug(player.index) then player.print("Click2Move: Set new goal: " .. Util.format_pos(goal)) end
  end

  -- Ensure GUI reflects queue state
  -- If not currently waiting for a path, immediately request one for first goal
  local path_request_changed = Pathfinding.request_paths_for_player(player.index)
  changed = changed or path_request_changed
  if changed then GUI.update(player.index) end
end

-- Main per-interval update
local function on_tick(event)
  for player_index, data in pairs(PlayerData.get_all()) do
    local player = game.players[player_index]
    if not player or not player.connected then
      Util.safe_destroy_renderings(data.render_objs)
      PlayerData.remove(player_index)
      goto continue_player_loop
    end

    local stop_movement = false
    local entity_to_move = player.vehicle or player.character
    if not entity_to_move then
      PlayerData.remove(player_index)
      goto continue_player_loop
    end

    local changed = false
    local gui_update_from_handler = false

    -- Mech-armor straight-line
    if data.is_straight_line_move then
      stop_movement, gui_update_from_handler = Movement.handle_straight_line(player_index, data, player,
        Pathfinding.request_paths_for_player)
      changed = changed or gui_update_from_handler
    else
      -- Ensure path if needed
      if data.goals and #data.goals > 0 then
        local goal = data.goals[1]
        if not goal.path and not goal.path_id and not goal.retry_at then
          local path_request_changed = Pathfinding.request_paths_for_player(player_index)
          changed = changed or path_request_changed
        end

        if not goal.path then goto continue_player_loop end -- Waiting; skip
      else
        goto continue_player_loop
      end

      local vehicle = player.vehicle or player.character.vehicle
      if vehicle then
        stop_movement = Movement.handle_vehicle(player_index, data, player, vehicle)
      else
        stop_movement = Movement.handle_character(player_index, data, player, player.character)
      end
    end

    -- If movement stopped (arrived, stuck, manual override, or invalid state)
    if stop_movement then
      changed = Movement.cleanup_and_next_goal(player_index, data, player, entity_to_move, changed,
        Pathfinding.request_paths_for_player, Rendering.render_paths_for_player)
    end

    if changed then
      GUI.update(player_index)
    end

    ::continue_player_loop::
  end
end

-- Event registration and initialization
local function initialize()
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("c2m-move-command-queue", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, Pathfinding.on_path_request_finished)
  script.on_event(defines.events.on_gui_click, GUI.on_click)

  Config.load()
  script.on_nth_tick(Config.get().update_interval, on_tick)

  PlayerData.clear_all()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_load(function()
  Config.load()
  -- re-register handlers on load
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("c2m-move-command-queue", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, Pathfinding.on_path_request_finished)
  script.on_event(defines.events.on_gui_click, GUI.on_click)
  script.on_nth_tick(Config.get().update_interval, on_tick)
end)
