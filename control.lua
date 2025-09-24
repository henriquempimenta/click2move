--[[
  Click2Move control.lua
  Author: Me
  Description: Allows players to click to move their character.
]]

-- Declare local variables that will be populated later
local util_vector = {}

-- Vector utility functions
util_vector.distance = function(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

util_vector.angle = function(a, b)
  local dx = b.x - a.x
  local dy = b.y - a.y
  return math.atan2(dy, dx)
end

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
-- Track which players have had their movement cancelled to avoid spamming messages
local movement_cancelled = {}

-- Handles the custom input to initiate movement
on_custom_input = function(event)
  if event.input_name ~= "c2m-move-command" then return end

  local player = game.players[event.player_index]
  local position = event.location
  player.print("left click!") -- To check if event is working

  if not player or not position or not player.character then return end

  local code = player.surface.request_path {
    bounding_box = player.character.prototype.collision_box,
    collision_mask = player.character.prototype.collision_mask or {"player-layer", "object-layer", "water-tile"},
    start = player.character.position,
    goal = position,
    pathfind_flags = { allow_destroy_friendly_entities = true },
    force = "character",
    player_index = player.index,
    event = C2M_PATH_EVENT -- Tell Factorio to fire our custom event on completion
  }
  player.print(code)
end

-- Handles the result of the path request
on_path_request_finished = function(event)
  if not event.player_index or not game.players[event.player_index] then return end
  local player = game.players[event.player_index]
  player.print("path request  finished")
  if not player then return end

  if event.path and #event.path > 0 then
    -- Uncomment the next line for debugging:
    -- player.print("Path found! It has " .. #event.path .. " waypoints.")
    active_paths[player.index] = { path = event.path, current_waypoint = 1 }
  else
    player.print("Path not found.")
  end
  -- else
  --   player.print("Path not found.") -- Uncomment for debugging if needed
end

-- Handles player movement each tick
on_tick = function(event)
  if not util_vector then return end
  if event.tick % UPDATE_INTERVAL ~= 0 then return end

  for player_index, data in pairs(active_paths) do
    local player = game.players[player_index]
    local stop_movement = false

    if not player or not player.character then
      stop_movement = true
    elseif player.character.walking_state.walking then -- Movement interruption by the player
      stop_movement = true
      if not movement_cancelled[player_index] then
        player.print("Movement cancelled.")
        movement_cancelled[player_index] = true
      end
    else
      local waypoint = data.path[data.current_waypoint]
      if waypoint then
        movement_cancelled[player_index] = nil
        local distance = util_vector.distance(player.character.position, waypoint.position)
        if distance < PROXIMITY_THRESHOLD then
          data.current_waypoint = data.current_waypoint + 1
          if data.current_waypoint > #data.path then
            stop_movement = true
          end
        else
          local angle = util_vector.angle(player.character.position, waypoint.position)
          -- Use defines.direction constants directly from the global defines
          -- local direction = defines.direction.from_angle(angle)
        end
      end
    end
 end
end

local function initialize()
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
