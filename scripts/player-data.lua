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
---@field owner_index uint32
---@field route_surface_index? uint32
---@field waypoint_motion? {path: PathfinderWaypoint[], entity: LuaEntity, surface_index: uint32, position: MapPosition, tick: uint32, waypoint: uint32, running_speed: number?, sweep_start: MapPosition?, sweep_end: MapPosition?}
---@field waypoint_scan_pending? boolean
---@field character_arrival? boolean
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
---@field spider_destination? MapPosition -- The current goal as sent to the spider autopilot
---@field spider_arrived? boolean      -- on_spider_command_completed fired for that command

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

-- Car passengers cannot drive. Driver ownership can be represented by either
-- a LuaPlayer or its character; an offline player's character may be nil.
function PlayerData.can_control_entity(player, entity)
  if not entity or not entity.valid then return false end
  if entity.type ~= "car" then return true end
  if not player or not player.valid then return false end
  local driver = entity.get_driver()
  return driver == player or (player.character ~= nil and driver == player.character)
    or (driver and driver.object_name == "LuaEntity" and driver.type == "character" and driver.player == player)
    or false
end

-- Routes belong to the tracked entity's physical surface, never the remote
-- camera surface. Older saves retain this association in their goal rendering.
function PlayerData.check_route_surface(data, entity)
  local surface_index = entity.surface and entity.surface.index
  if data.route_surface_index == nil then
    local goal = data.goals and data.goals[1]
    local rendered_surface = goal and goal.rendering and goal.rendering.surface
    if rendered_surface and rendered_surface.valid == false then return false end
    data.route_surface_index = rendered_surface and rendered_surface.index or surface_index
  end
  return data.route_surface_index == nil or data.route_surface_index == surface_index
end

-- Reset the controller independently of its queue/entity/renderings.
---@param data PlayerMoveData
---@param preserve_mode? boolean
function PlayerData.reset_movement_state(data, preserve_mode)
  data.current_waypoint = 1
  data.waypoint_motion = nil
  data.waypoint_scan_pending = nil
  data.character_arrival = nil
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
  data.spider_destination = nil
  data.spider_arrived = nil
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
    data.owner_index = player_index
    local player = game.players[player_index]
    local entity = data.move_entity
    if not player or not player.valid or not player.connected or not entity or not entity.valid
        or (entity.type ~= "character" and entity.type ~= "car" and entity.type ~= "spider-vehicle")
        or not data.goals or #data.goals == 0 or not PlayerData.can_control_entity(player, entity)
        or not PlayerData.check_route_surface(data, entity)
        or (entity.type == "spider-vehicle" and not PlayerData.reconcile_spider(data, entity)) then
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
  data.owner_index = player_index
  return data
end

local SPIDER_DESTINATION_TOLERANCE = 0.1

-- True while the autopilot follows only the destination Click2Move sent, or,
-- once that command has finished, while nothing else has been assigned since.
-- A follow order also leaves the destination queue empty, so it is foreign.
-- Routes saved by 0.1.14 sent the current goal without recording it.
---@param data PlayerMoveData
---@param spider LuaEntity
---@return boolean
function PlayerData.owns_spider_autopilot(data, spider)
  if spider.follow_target then return false end
  local destinations = spider.autopilot_destinations
  if data.spider_arrived then return data.spider_destination ~= nil and #destinations == 0 end
  local legacy_goal = data.goals and data.goals[1]
  local destination = data.spider_destination or (legacy_goal and legacy_goal.position)
  if not destination or #destinations ~= 1 then return false end
  local dx, dy = destinations[1].x - destination.x, destinations[1].y - destination.y
  return dx * dx + dy * dy <= SPIDER_DESTINATION_TOLERANCE ^ 2
end

-- Before Click2Move writes to a spider without a recorded command (0.1.14 saves,
-- or after input was released), adopt an autopilot still following our goal.
-- Returns false when a remote, script or follow order now owns the spider.
---@param data PlayerMoveData
---@param spider LuaEntity
---@return boolean
function PlayerData.reconcile_spider(data, spider)
  if data.spider_destination then return true end
  if spider.follow_target then return false end
  local destinations = spider.autopilot_destinations
  if #destinations == 0 then return true end
  if not PlayerData.owns_spider_autopilot(data, spider) then return false end
  data.spider_destination = {x = destinations[1].x, y = destinations[1].y}
  return true
end

-- Release the actuator without changing goals, paths, or controller state.
---@param entity_to_move? LuaEntity
---@param data? PlayerMoveData
function PlayerData.stop_input(entity_to_move, data)
  if entity_to_move and entity_to_move.valid then
    if data and entity_to_move.type == "car"
        and not PlayerData.can_control_entity(data.owner_index and game.players[data.owner_index], entity_to_move) then return end
    if entity_to_move.type == "character" then
      entity_to_move.walking_state = { walking = false, direction = defines.direction.north }
    elseif entity_to_move.type == "spider-vehicle" then
      -- Like cars, never clear a command that a remote or another script assigned.
      if not data or PlayerData.owns_spider_autopilot(data, entity_to_move) then
        entity_to_move.autopilot_destination = nil
      end
      if data then data.spider_destination = nil end
    elseif entity_to_move.type == "car" then
      VehicleBraking.apply(entity_to_move)
    end
  end
end

-- Stop input and clear controller/rendering state; the caller owns goal removal.
---@param entity_to_move? LuaEntity
---@param data PlayerMoveData
function PlayerData.cleanup_movement(entity_to_move, data)
  PlayerData.stop_input(entity_to_move, data)
  Rendering.clear_player(data)
  data.move_entity = nil
  data.route_surface_index = nil
  PlayerData.reset_movement_state(data)
end

-- Check if the player is wearing armor that provides flight, such as mech armor
---@param player LuaPlayer
---@return boolean
function PlayerData.is_wearing_mech(player)
  if not player or not player.character or not player.character.get_inventory then return false end
  local inventory = player.character.get_inventory(defines.inventory.character_armor)
  if not inventory or inventory.is_empty() then return false end
  local armor = inventory[1]
  return armor.valid_for_read and armor.prototype.provides_flight == true
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
