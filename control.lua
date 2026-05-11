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

local on_tick
local registered_update_interval = nil

local function register_tick_handler()
  Config.load()
  local interval = Config.get().update_interval
  if registered_update_interval and registered_update_interval ~= interval then
    script.on_nth_tick(registered_update_interval, nil)
  end
  script.on_nth_tick(interval, on_tick)
  registered_update_interval = interval
end

local function toggle_click2move_mode(player)
  if not player or not player.valid then return end
  local enabled = not player.is_shortcut_toggled("c2m-toggle-mode")
  player.set_shortcut_toggled("c2m-toggle-mode", enabled)
  if not enabled then
    GUI.cancel_movement(player, "mode disabled")
  end
  if Config.is_debug(player.index, "queue") then
    player.print("Click2Move: Mode " .. (enabled and "enabled." or "disabled."))
  end
end

local function enable_click2move_mode(player)
  if player and player.valid then
    player.set_shortcut_toggled("c2m-toggle-mode", true)
  end
end

local function on_lua_shortcut(event)
  if event.prototype_name ~= "c2m-toggle-mode" then return end
  toggle_click2move_mode(game.players[event.player_index])
end

local function on_player_created(event)
  enable_click2move_mode(game.players[event.player_index])
end

local function on_runtime_mod_setting_changed(event)
  if event.setting == "c2m-update-interval" then
    register_tick_handler()
  end
end

local function get_command_entity(player)
  if not player then return nil end
  if player.vehicle and player.vehicle.valid then return player.vehicle end
  return player.character
end

local function is_remote_view(player)
  return defines.controllers.remote and player.controller_type == defines.controllers.remote
end

-- Handles the custom input to initiate movement
---@param event EventData.CustomInputEvent
local function on_custom_input(event)
  local player = game.players[event.player_index]
  if event.input_name == "c2m-cancel-command" then
    GUI.cancel_movement(player, "input")
    return
  end
  if event.input_name == "c2m-toggle-mode" then
    toggle_click2move_mode(player)
    return
  end
  if event.input_name ~= "c2m-move-command" and event.input_name ~= "c2m-move-command-queue" then return end
  if is_remote_view(player) then return end
  local entity_to_move = get_command_entity(player)
  if not entity_to_move or not player.connected then return end
  if not event.cursor_position then return end

  -- Prevents the mod to be triggered when interacting with other GUIs, leading to unintentional movement.
  if player.opened_gui_type ~= defines.gui_type.none then return end
  if not player.is_shortcut_toggled("c2m-toggle-mode") then
    if Config.is_debug(player.index, "queue") then player.print("Click2Move: Ignored movement click because mode is disabled.") end
    return
  end

  local changed = false

  local data = PlayerData.ensure(player.index)
  local goal = { x = event.cursor_position.x, y = event.cursor_position.y }

  -- If wearing mech armor or jetpacking, use straight-line movement and bypass pathfinding
  if entity_to_move.type == "character" and PlayerData.is_bypassing_pathfinding(player) then
    data.move_entity = entity_to_move
    data.goals = { { position = goal } }
    changed = true
    data.is_straight_line_move = true -- Custom flag for our new mode
    if changed then GUI.update(player.index) end
    return
  end
  changed = true

  if event.input_name == "c2m-move-command-queue" then
    -- queue this goal
    if not data.move_entity or not data.move_entity.valid then
      data.move_entity = entity_to_move
    end
    table.insert(data.goals, { position = goal })
    if Config.is_debug(player.index, "queue") then player.print("Click2Move: Added goal to queue: " .. Util.format_pos(goal)) end
  else
    -- replace queue with this goal
    data.move_entity = entity_to_move
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

    if Config.is_debug(player.index, "queue") then player.print("Click2Move: Set new goal: " .. Util.format_pos(goal)) end
  end

  -- Ensure GUI reflects queue state
  -- If not currently waiting for a path, immediately request one for first goal
  local path_request_changed = Pathfinding.request_paths_for_player(player.index)
  changed = changed or path_request_changed
  if changed then GUI.update(player.index) end
end

-- Main per-interval update
on_tick = function(event)
  for player_index, data in pairs(PlayerData.get_all()) do
    local player = game.players[player_index]
    if not player or not player.connected then
      Util.safe_destroy_renderings(data.render_objs)
      PlayerData.remove(player_index)
      goto continue_player_loop
    end

    local stop_movement = false
    local entity_to_move = data.move_entity or player.vehicle or player.character
    if not entity_to_move or not entity_to_move.valid then
      Util.safe_destroy_renderings(data.render_objs)
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
        local path_request_changed = Pathfinding.request_paths_for_player(player_index)
        changed = changed or path_request_changed

        local goal = data.goals[1]
        if not goal or not goal.path then goto continue_player_loop end -- Waiting; skip
      else
        goto continue_player_loop
      end

      local vehicle = entity_to_move.type ~= "character" and entity_to_move or nil
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
  script.on_event("c2m-cancel-command", on_custom_input)
  script.on_event("c2m-toggle-mode", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, Pathfinding.on_path_request_finished)
  script.on_event(defines.events.on_gui_click, GUI.on_click)
  script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)
  script.on_event(defines.events.on_player_created, on_player_created)
  script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)

  register_tick_handler()
  for _, player in pairs(game.players) do
    enable_click2move_mode(player)
  end

  PlayerData.clear_all()
end

script.on_init(initialize)
script.on_configuration_changed(initialize)
script.on_load(function()
  Config.load()
  -- re-register handlers on load
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("c2m-move-command-queue", on_custom_input)
  script.on_event("c2m-cancel-command", on_custom_input)
  script.on_event("c2m-toggle-mode", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, Pathfinding.on_path_request_finished)
  script.on_event(defines.events.on_gui_click, GUI.on_click)
  script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)
  script.on_event(defines.events.on_player_created, on_player_created)
  script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)
  register_tick_handler()
end)
