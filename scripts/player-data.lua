--[[
  Click2Move - Player Data Management
  Owns the player_move_data table and provides data lifecycle functions.
]]

local Util = require("scripts/util")

local PlayerData = {}

---@class MoveGoal
---@field position MapPosition
---@field path_id? uint32
---@field path? PathfinderWaypoint[]
---@field retry_count? uint32
---@field retry_at? uint32

---@class PlayerMoveData
---@field current_waypoint uint32
---@field render_objs? LuaRenderObject[]
---@field last_position? MapPosition
---@field stuck_counter uint32
---@field is_auto_walking boolean
---@field goals MoveGoal[]
---@field vehicle_stuck_counter uint32
---@field last_vehicle_position? MapPosition
---@field closest_dist_to_goal number   -- Best progress made so far
---@field no_progress_ticks uint32      -- How long we haven't improved our distance
---@field stuck_state string            -- "none", "reversing", "repathing", "sliding"
---@field stuck_timer uint32            -- Timer for the reverse maneuver
---@field slide_direction? defines.direction
---@field is_straight_line_move? boolean

-- Persistent-in-session table (cleared on init/config change)
---@type table<uint32, PlayerMoveData>
local player_move_data = {}

-- Retry constants
PlayerData.MAX_PATH_RETRIES = 5
PlayerData.PATH_RETRY_DELAY_TICKS = 60

-- Get the raw data table (for iteration in on_tick)
---@return table<uint32, PlayerMoveData>
function PlayerData.get_all()
  return player_move_data
end

-- Clear all player data (called on init/config change)
function PlayerData.clear_all()
  player_move_data = {}
end

-- Remove data for a specific player
---@param player_index uint32
function PlayerData.remove(player_index)
  player_move_data[player_index] = nil
end

-- Get or create player's movement data
---@param player_index uint32
---@return PlayerMoveData
function PlayerData.ensure(player_index)
  local d = player_move_data[player_index]
  if not d then
    d = {
      current_waypoint = 1,
      render_objs = nil,
      last_position = nil,
      stuck_counter = 0,
      is_auto_walking = false,
      goals = {},
      vehicle_stuck_counter = 0,
      last_vehicle_position = nil,
      closest_dist_to_goal = 999999,
      no_progress_ticks = 0,
      stuck_state = "none",
      stuck_timer = 0,
      slide_direction = nil
    }
    player_move_data[player_index] = d
  end
  return d
end

-- Cleanup movement state (shared for character/vehicle)
---@param entity_to_move LuaEntity
---@param player LuaPlayer
---@param data PlayerMoveData
function PlayerData.cleanup_movement(entity_to_move, player, data)
  if entity_to_move and entity_to_move.valid then
    if entity_to_move.type == "character" then
      entity_to_move.walking_state = { walking = false, direction = defines.direction.north }
    elseif player.vehicle then
      entity_to_move.riding_state = { direction = defines.riding.direction.straight, acceleration = defines.riding.acceleration.braking }
    end
  end
  Util.safe_destroy_renderings(data.render_objs)
  data.render_objs = nil
  data.current_waypoint = 1
  data.is_auto_walking = false
  data.stuck_counter = 0
  data.last_position = nil
  data.vehicle_stuck_counter = 0
  data.last_vehicle_position = nil
  -- Reset new stuck logic fields
  data.closest_dist_to_goal = 999999
  data.no_progress_ticks = 0
  data.stuck_state = "none"
  data.stuck_timer = 0
  data.slide_direction = nil
  data.is_straight_line_move = nil
end

-- Check if the player is wearing "mech-armor"
---@param player LuaPlayer
---@return boolean
function PlayerData.is_wearing_mech(player)
  if not player or not player.character or not player.character.get_inventory then return false end
  local armor_inv = player.character.get_inventory(defines.inventory.character_armor).get_contents()
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
