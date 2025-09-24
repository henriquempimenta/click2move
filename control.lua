--[[
  Click2Move control.lua
  Author: Henrique
  Description: Allows players to click to move their character.
]]

-- Declare local variables that will be populated later
local util_vector
local util = require("util")

-- Forward-declare event handlers so they can be registered before they are defined
local on_custom_input
local on_path_request_finished
local on_tick

-- Constants
local PROXIMITY_THRESHOLD = 1.5
local UPDATE_INTERVAL = 5 -- Ticks between movement updates

-- Generate a unique event ID for pathfinding callbacks
local C2M_PATH_EVENT = script.generate_event_name()

-- A non-persistent table to store active paths. It will be cleared on game load.
local active_paths = {}

-- Handles the custom input to initiate movement
on_custom_input = function(event)
  if event.input_name ~= "c2m-move-command" then return end

  local player = game.players[event.player_index]
  local position = event.location

  if not player or not position or not player.character then return end

  player.surface.request_path {
    source = player.character.position,
    goal = position,
    pathfind_flags = { allow_destroy_friendly_entities = true },
    force = "character",
    player_index = player.index,
    event = C2M_PATH_EVENT -- Tell Factorio to fire our custom event on completion
  }
end

-- Handles the result of the path request
on_path_request_finished = function(event)
  local player = game.players[event.player_index]
  if not player then return end

  if event.path and #event.path > 0 then
    player.print("Path found! It has " .. #event.path .. " waypoints.")
    active_paths[player.index] = { path = event.path, current_waypoint = 1 }
  else
    player.print("Path not found.")
  end
end

-- Handles player movement each tick
on_tick = function(event)
  if event.tick % UPDATE_INTERVAL ~= 0 then return end

  for player_index, data in pairs(active_paths) do
    local player = game.players[player_index]
    local stop_movement = false

    if not player or not player.character then
      stop_movement = true
    elseif player.walking then -- Movement interruption by the player
      stop_movement = true
      player.print("Movement cancelled.")
    else
      local waypoint = data.path[data.current_waypoint]
      if not waypoint then
        stop_movement = true
        if player.character then
          player.character.walking_state = { walking = false }
        end
      else
        local distance = util_vector.distance(player.character.position, waypoint.position)
        if distance < PROXIMITY_THRESHOLD then
          data.current_waypoint = data.current_waypoint + 1
        else
          local angle = util_vector.angle(player.character.position, waypoint.position)
          local direction = defines.direction.from_angle(angle)
          player.character.walking_state = { walking = true, direction = direction }
        end
      end
    end

    if stop_movement then
      active_paths[player_index] = nil
    end
  end
end

-- This function handles all initialization and event registration.
local function initialize()
  -- Populate local variables for performance and convenience
  util_vector = util.vector

  -- Register event handlers. It's safe to call this multiple times,
  -- as new registrations for an event simply replace the old ones.
  script.on_event("c2m-move-command", on_custom_input)
  script.on_event(C2M_PATH_EVENT, on_path_request_finished)
  script.on_event(defines.events.on_tick, on_tick)
end

-- Initializes global data on new game
script.on_init(function()
  initialize()
end)

-- Handles loading data from a save file
script.on_load(function()
  -- The script.global table is loaded automatically by the game before this event.
  -- Re-running initialize is safe and handles mod updates gracefully.
  initialize()
end)

-- Ensures data structure exists and events are registered when mod configuration changes
script.on_configuration_changed(function()
  initialize()
end)
