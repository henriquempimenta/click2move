--[[
  Click2Move - Player Data Management
  Owns the player_move_data table and provides data lifecycle functions.
]]

local Rendering = require("scripts/rendering")

local VehicleBraking = require("scripts/vehicle-braking")

local PlayerData = {}

---@class MoveGoal
---@field position MapPosition
---@field path_id? uint32
---@field path? PathfinderWaypoint[]
---@field retry_count? uint32
---@field retry_at? uint32

---@class PlayerMoveData
---@field current_waypoint uint32
---@field move_entity? LuaEntity
---@field render_objs? LuaRenderObject[]
---@field last_position? MapPosition
---@field stuck_counter uint32
---@field goals MoveGoal[]
---@field vehicle_reapproach? boolean
---@field vehicle_arrival? {position: MapPosition, tick: uint32, stationary_ticks: uint32, speed: number?}
---@field closest_dist_to_goal number   -- Best progress made so far
---@field no_progress_ticks uint32      -- Actual game ticks without progress
---@field last_progress_tick? uint32
---@field last_recovery_tick? uint32
---@field last_straight_line_tick? uint32
---@field stuck_state string            -- "none", "reversing", "repathing", "sliding"
---@field stuck_timer uint32            -- Timer for the reverse maneuver
---@field slide_direction? defines.direction
---@field is_straight_line_move? boolean

-- Bind this reference to storage on init/load; local tables alone do not survive saves.
---@type table<uint32, PlayerMoveData>
local player_move_data = {}
local change_handler
local cancel_handler

-- Retry constants
PlayerData.MAX_PATH_RETRIES = 5
PlayerData.PATH_RETRY_DELAY_TICKS = 60

-- Get the raw data table (for iteration in on_tick)
---@return table<uint32, PlayerMoveData>
function PlayerData.get_all()
  return player_move_data
end

-- Initialize persistent state only when the mod is first added.
function PlayerData.init()
  storage.c2m_player_move_data = {}
  player_move_data = storage.c2m_player_move_data
end

-- on_load may read storage, but must not modify it.
function PlayerData.load()
  player_move_data = storage.c2m_player_move_data or {}
end

function PlayerData.set_cancel_handler(handler)
  cancel_handler = handler
end

function PlayerData.set_change_handler(handler)
  change_handler = handler
end

function PlayerData.notify_changed()
  if change_handler then change_handler() end
end

-- Reset the controller independently of its queue/entity/renderings.
---@param data PlayerMoveData
---@param preserve_mode? boolean
function PlayerData.reset_movement_state(data, preserve_mode)
  data.current_waypoint = 1
  data.is_auto_walking = nil
  data.stuck_counter = 0
  data.last_position = nil
  data.vehicle_arrival = nil
  data.vehicle_reapproach = nil
  data.goal_failed = nil
  data.closest_dist_to_goal = math.huge
  data.no_progress_ticks = 0
  data.last_progress_tick = nil
  data.last_recovery_tick = nil
  data.last_straight_line_tick = nil
  data.stuck_state = "none"
  data.stuck_timer = 0
  data.slide_direction = nil
  if not preserve_mode then data.is_straight_line_move = nil end
  -- Discard obsolete fields from saves made with older versions.
  data.vehicle_stuck_counter = nil
  data.last_vehicle_position = nil
end

---@param player_index uint32
function PlayerData.remove(player_index)
  local data = player_move_data[player_index]
  if data then
    if cancel_handler then cancel_handler(player_index, data) end
    Rendering.clear_player(data)
    player_move_data[player_index] = nil
    PlayerData.notify_changed()
  end
end

-- Normalize saved state without resetting valid routes or player preferences.
function PlayerData.migrate()
  storage.c2m_player_move_data = storage.c2m_player_move_data or {}
  player_move_data = storage.c2m_player_move_data
  for player_index, data in pairs(player_move_data) do
    local player = game.players[player_index]
    local entity = data.move_entity
    if not player or not player.valid or not player.connected or not entity or not entity.valid
        or (entity.type ~= "character" and entity.type ~= "car" and entity.type ~= "spider-vehicle")
        or not data.goals or #data.goals == 0 then
      PlayerData.cleanup_movement(entity, data)
      PlayerData.remove(player_index)
    else
      data.current_waypoint = data.current_waypoint or 1
      data.closest_dist_to_goal = data.closest_dist_to_goal or math.huge
      data.no_progress_ticks = data.no_progress_ticks or 0
      data.stuck_counter = data.stuck_counter or 0
      data.stuck_state = data.stuck_state or "none"
      data.stuck_timer = data.stuck_timer or 0
      data.vehicle_stuck_counter = nil
      data.last_vehicle_position = nil
    end
  end
end

-- Explicit clearing is used by tests and deliberate cancellation, never by load.
function PlayerData.clear_all()
  for player_index, data in pairs(player_move_data) do
    PlayerData.cleanup_movement(data.move_entity, data)
    PlayerData.remove(player_index)
  end
end

---@param player_index uint32
---@return PlayerMoveData
function PlayerData.ensure(player_index)
  local data = player_move_data[player_index]
  if not data then
    data = {goals = {}}
    PlayerData.reset_movement_state(data)
    player_move_data[player_index] = data
  end
  return data
end

-- Release the actuator without changing goals, paths, or controller state.
---@param entity_to_move? LuaEntity
function PlayerData.stop_input(entity_to_move)
  if entity_to_move and entity_to_move.valid then
    if entity_to_move.type == "character" then
      entity_to_move.walking_state = { walking = false, direction = defines.direction.north }
    elseif entity_to_move.type == "spider-vehicle" then
      entity_to_move.autopilot_destination = nil
    elseif entity_to_move.type == "car" then
      VehicleBraking.apply(entity_to_move)
    end
  end
end

-- Stop input and clear controller/rendering state; the caller owns goal removal.
---@param entity_to_move? LuaEntity
---@param data PlayerMoveData
function PlayerData.cleanup_movement(entity_to_move, data)
  PlayerData.stop_input(entity_to_move)
  Rendering.clear_player(data)
  data.move_entity = nil
  PlayerData.reset_movement_state(data)
end

-- Check if the player is wearing "mech-armor"
---@param player LuaPlayer
---@return boolean
function PlayerData.is_wearing_mech(player)
  if not player or not player.character or not player.character.get_inventory then return false end
  local inventory = player.character.get_inventory(defines.inventory.character_armor)
  if not inventory then return false end
  local armor_inv = inventory.get_contents()
  if not armor_inv or #armor_inv == 0 then return false end
  return armor_inv[1].name == "mech-armor"
end

-- Check if the player is currently jetpacking (requires jetpack mod)
---@param player LuaPlayer
---@return boolean
function PlayerData.is_jetpacking(player)
  if not player or not player.character then return false end
  if not remote.interfaces["jetpack"] or not remote.interfaces["jetpack"]["is_jetpacking"] then
    return false
  end
  return remote.call("jetpack", "is_jetpacking", { character = player.character })
end

-- Check if the player should bypass pathfinding (mech armor or jetpack)
---@param player LuaPlayer
---@return boolean
function PlayerData.is_bypassing_pathfinding(player)
  return PlayerData.is_wearing_mech(player) or PlayerData.is_jetpacking(player)
end

return PlayerData
