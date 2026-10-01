--[[
  Click2Move control.lua
  Author: Me
  Description: Allows players to click to move their character.

  This is the orchestrator — it requires all modules and wires up events.
]]

local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Rendering = require("scripts/rendering")
local GUI = require("scripts/gui")
local Pathfinding = require("scripts/pathfinding")
local Movement = require("scripts/movement")

PlayerData.set_cancel_handler(Pathfinding.cancel_player)

local on_tick
local registered_update_interval
local registered_continuous_handler = false

local function needs_continuous_updates(data)
  local entity = data.move_entity
  local goal = data.goals and data.goals[1]
  return entity and entity.valid and (data.stuck_state == "sliding" or data.stuck_state == "reversing"
    or (entity.type == "car" and (data.vehicle_arrival ~= nil or (goal and not goal.path))))
end

local function between_movement_updates(event)
  if event.tick % registered_update_interval ~= 0 then on_tick(event, true) end
end

local function register_tick_handler()
  local interval = Config.get().update_interval
  if registered_update_interval ~= interval then
    if registered_update_interval then script.on_nth_tick(registered_update_interval, nil) end
    script.on_nth_tick(interval, on_tick)
    registered_update_interval = interval
  end
  local needs_continuous_handler = false
  if interval > 1 then
    for _, data in pairs(PlayerData.get_all()) do
      if needs_continuous_updates(data) then needs_continuous_handler = true; break end
    end
  end
  if needs_continuous_handler ~= registered_continuous_handler then
    script.on_event(defines.events.on_tick, needs_continuous_handler and between_movement_updates or nil)
    registered_continuous_handler = needs_continuous_handler
  end
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
  Config.on_setting_changed(event)
  if event.setting == "c2m-update-interval" then
    register_tick_handler()
  end
end

local function get_command_entity(player)
  if not player then return nil end
  if player.physical_vehicle and player.physical_vehicle.valid then return player.physical_vehicle end
  if player.vehicle and player.vehicle.valid then return player.vehicle end
  return player.character
end

local function on_manual_movement(event)
  local player = game.players[event.player_index]
  local data = PlayerData.get_all()[event.player_index]
  local entity = data and data.move_entity
  if player and entity and entity.valid
      and (entity.type == "car" or entity.type == "character" or entity.type == "spider-vehicle")
      and player.controller_type ~= defines.controllers.remote
      and not event.in_gui and player.opened_gui_type == defines.gui_type.none then
    if entity.type == "spider-vehicle" then entity.autopilot_destination = nil end
    GUI.cancel_movement(player, "manual control", true)
  end
end

local function on_player_driving_changed_state(event)
  local player = game.players[event.player_index]
  local data = PlayerData.get_all()[event.player_index]
  local vehicle = data and data.move_entity
  if vehicle and vehicle.valid and get_command_entity(player) ~= vehicle then
    GUI.cancel_movement(player, "vehicle changed", true)
  end
end

local function register_override_handlers()
  for _, control in ipairs({"move-up", "move-down", "move-left", "move-right"}) do
    script.on_event("c2m-manual-" .. control, on_manual_movement)
  end
  script.on_event(defines.events.on_player_driving_changed_state, on_player_driving_changed_state)
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
  local entity_to_move = get_command_entity(player)
  if not entity_to_move or not entity_to_move.valid or not player.connected then return end
  if entity_to_move.type ~= "character" and entity_to_move.type ~= "car"
      and entity_to_move.type ~= "spider-vehicle" then return end
  if not event.cursor_position then return end

  if event.in_gui or (event.element and event.element.valid) then return end

  if player.surface and entity_to_move.surface and player.surface.index ~= entity_to_move.surface.index then
    if Config.is_debug(player.index, "path") then
      player.print("Click2Move: Ignored remote-view command because the viewed surface differs from the vehicle surface.")
    end
    return
  end

  -- Prevents the mod to be triggered when interacting with other GUIs, leading to unintentional movement.
  if player.opened_gui_type ~= defines.gui_type.none then return end
  if not player.is_shortcut_toggled("c2m-toggle-mode") then
    if Config.is_debug(player.index, "queue") then player.print("Click2Move: Ignored movement click because mode is disabled.") end
    return
  end

  local data = PlayerData.ensure(player.index)
  local goal = {x = event.cursor_position.x, y = event.cursor_position.y}
  local queue = event.input_name == "c2m-move-command-queue"
    and data.move_entity == entity_to_move and #data.goals > 0

  if not queue then
    Pathfinding.cancel_player(player.index, data)
    PlayerData.cleanup_movement(data.move_entity, data)
    data.move_entity = entity_to_move
    data.goals = {{position = goal}}
  else
    table.insert(data.goals, {position = goal})
  end
  local straight_line = entity_to_move.type == "character" and PlayerData.is_bypassing_pathfinding(player)
  if straight_line ~= (data.is_straight_line_move == true) then
    Pathfinding.cancel_player(player.index, data)
    PlayerData.stop_input(entity_to_move)
    PlayerData.reset_movement_state(data)
    for index in ipairs(data.goals) do Pathfinding.invalidate_goal(player.index, index) end
  end
  data.is_straight_line_move = straight_line or nil

  if data.is_straight_line_move then
    Rendering.render_paths_for_player(player.index, PlayerData.get_all())
  else
    Pathfinding.request_paths_for_player(player.index, true)
  end
  PlayerData.notify_changed()
  GUI.update(player.index)
end

-- Main per-interval update
on_tick = function(event, continuous_only)
  if not continuous_only then Pathfinding.on_tick(event.tick) end
  for player_index, data in pairs(PlayerData.get_all()) do
    if continuous_only and not needs_continuous_updates(data) then goto continue_player_loop end
    local player = game.players[player_index]
    if not player or not player.connected then
      PlayerData.cleanup_movement(data.move_entity, data)
      PlayerData.remove(player_index)
      if player and player.valid then GUI.update(player_index) end
      goto continue_player_loop
    end

    local stop_movement = false
    local entity_to_move = data.move_entity
    if not entity_to_move or not entity_to_move.valid then
      PlayerData.cleanup_movement(nil, data)
      PlayerData.remove(player_index)
      if player and player.valid then GUI.update(player_index) end
      goto continue_player_loop
    end

    local changed = false
    local gui_update_from_handler = false

    -- Mech-armor straight-line
    if data.is_straight_line_move then
      stop_movement, gui_update_from_handler = Movement.handle_straight_line(player_index, data, player,
        Pathfinding.request_paths_for_player)
      changed = changed or gui_update_from_handler
    elseif data.vehicle_arrival then
      stop_movement = Movement.handle_vehicle(player_index, data, player, entity_to_move)
    else
      local goal = data.goals and data.goals[1]
      if not goal then
        PlayerData.cleanup_movement(entity_to_move, data)
        PlayerData.remove(player_index)
        GUI.update(player_index)
        goto continue_player_loop
      end
      if not goal.path then
        PlayerData.stop_input(entity_to_move)
        goto continue_player_loop
      end
      local vehicle = entity_to_move.type ~= "character" and entity_to_move or nil
      if vehicle then
        stop_movement = Movement.handle_vehicle(player_index, data, player, vehicle)
      else
        stop_movement = Movement.handle_character(player_index, data, player, entity_to_move)
      end
    end

    -- If movement stopped (arrived, stuck, manual override, or invalid state)
    if stop_movement then
      changed = Movement.cleanup_and_next_goal(player_index, data, entity_to_move)
    end

    if changed then
      GUI.update(player_index)
    end

    ::continue_player_loop::
  end
end

-- Event wiring is identical on first initialization and save load.
local function register_handlers()
  Config.load()
  register_override_handlers()
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event("c2m-move-command-queue", on_custom_input)
  script.on_event("c2m-cancel-command", on_custom_input)
  script.on_event("c2m-toggle-mode", on_custom_input)
  script.on_event(defines.events.on_script_path_request_finished, Pathfinding.on_path_request_finished)
  script.on_event(defines.events.on_gui_click, GUI.on_click)
  script.on_event(defines.events.on_lua_shortcut, on_lua_shortcut)
  script.on_event(defines.events.on_player_created, on_player_created)
  script.on_event(defines.events.on_runtime_mod_setting_changed, on_runtime_mod_setting_changed)
  PlayerData.set_change_handler(register_tick_handler)
  register_tick_handler()
end

script.on_init(function()
  PlayerData.init()
  Pathfinding.init()
  register_handlers()
  for _, player in pairs(game.players) do enable_click2move_mode(player) end
end)

script.on_configuration_changed(function()
  PlayerData.migrate()
  Pathfinding.init()
  register_handlers()
  for player_index, data in pairs(PlayerData.get_all()) do
    if not data.is_straight_line_move then Pathfinding.request_paths_for_player(player_index, true) end
  end
  for _, player in pairs(game.players) do GUI.update(player.index) end
end)

script.on_load(function()
  PlayerData.load()
  Pathfinding.load()
  register_handlers()
end)
