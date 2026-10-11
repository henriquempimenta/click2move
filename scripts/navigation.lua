--[[
  Click2Move - Navigation
  Direction calculation, waypoint advancement, and movement state setting.
]]

local Util = require("scripts/util")

local Navigation = {}

-- 8-way direction selection (returns defines.direction)
---@param from MapPosition
---@param to MapPosition
---@return defines.direction | nil
function Navigation.get_character_direction(from, to)
  local distance_threshold = 0.15
  local dx = to.x - from.x
  local dy = to.y - from.y

  if math.abs(dx) <= distance_threshold and math.abs(dy) <= distance_threshold then
    return nil
  end

  -- Equal diagonal offsets can differ by a few floating-point subtraction
  -- units, especially when the waypoint has a fractional world coordinate.
  if math.abs(dx) + 0.0000001 >= math.abs(dy) then
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
function Navigation.get_vehicle_riding_state(vehicle, target_pos)
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

-- Keep extra advancement on the straight corridor that the pathfinder already
-- validated. A velocity estimate cannot prove that a corner has been reached.
Navigation.MAX_WAYPOINT_ADVANCES = 16
local MAX_SAMPLE_TICKS = 60
local MAX_SAMPLE_SPEED = 4
local CORRIDOR_TOLERANCE = 1 / 64
local COLLINEAR_TOLERANCE = 0.000001

function Navigation.reset_waypoint_motion(data)
  data.waypoint_motion = nil
  data.waypoint_scan_pending = nil
end

local function valid_motion(history, entity, path, waypoint, position, tick, surface_index)
  if not history or history.path ~= path or history.entity ~= entity
      or history.surface_index ~= surface_index or history.waypoint ~= waypoint then return false end
  local elapsed = tick - history.tick
  if elapsed <= 0 or elapsed > MAX_SAMPLE_TICKS then return false end
  local distance_sq = Util.distance_sq(position, history.position)
  local allowance = MAX_SAMPLE_SPEED * elapsed + CORRIDOR_TOLERANCE
  if entity.type == "character" then
    -- This engine value already includes exoskeletons and terrain modifiers.
    local speed = math.max(history.running_speed or 0, entity.character_running_speed or 0)
    allowance = speed * elapsed * 1.05 + CORRIDOR_TOLERANCE
  end
  return distance_sq <= allowance * allowance
end

local function straight_corridor(path, index, previous, position)
  if index <= 1 or index >= #path then return nil end
  local incoming, waypoint, outgoing = path[index - 1], path[index], path[index + 1]
  if not incoming or not waypoint or not outgoing
      or not incoming.position or not waypoint.position or not outgoing.position then return nil end
  local before, target, after = incoming.position, waypoint.position, outgoing.position
  local ax, ay = target.x - before.x, target.y - before.y
  local bx, by = after.x - target.x, after.y - target.y
  local length_a_sq, length_b_sq = ax * ax + ay * ay, bx * bx + by * by
  if length_a_sq == 0 or length_b_sq == 0 or ax * bx + ay * by <= 0 then return nil end
  local cross = ax * by - ay * bx
  -- An absolute endpoint tolerance avoids accepting a distant corner merely
  -- because its very long segments have a small angle between them.
  if cross * cross > COLLINEAR_TOLERANCE ^ 2 * length_a_sq then return nil end

  local px, py = previous.x - target.x, previous.y - target.y
  local cx, cy = position.x - target.x, position.y - target.y
  local previous_cross, current_cross = ax * py - ay * px, ax * cy - ay * cx
  local corridor_sq = CORRIDOR_TOLERANCE ^ 2 * length_a_sq
  if previous_cross * previous_cross > corridor_sq or current_cross * current_cross > corridor_sq then return nil end
  return ax, ay, px, py, cx, cy
end

local function crossed_straight_waypoint(path, index, previous, position)
  local ax, ay, px, py, cx, cy = straight_corridor(path, index, previous, position)
  if not ax then return false end
  return ax * px + ay * py <= 0 and ax * cx + ay * cy >= 0
    and ax * (position.x - previous.x) + ay * (position.y - previous.y) > 0
end

-- Consume observed, already-passed straight nodes, keeping corners and the last
-- path node explicit. Work is bounded; a retained sweep lets later scans finish
-- a dense run without steering back towards nodes that were physically passed.
---@param data PlayerMoveData
---@param entity LuaEntity
---@param path PathfinderWaypoint[]
---@param threshold_sq number
---@param tick uint32
---@return integer advanced, boolean pending_scan
function Navigation.advance_waypoints(data, entity, path, threshold_sq, tick)
  if not path or #path == 0 then Navigation.reset_waypoint_motion(data); return 0, false end
  local position = entity.position
  local surface_index = entity.surface and entity.surface.index
  local index = math.max(1, math.min(data.current_waypoint or 1, #path))
  local history = data.waypoint_motion
  local observed = valid_motion(history, entity, path, index, position, tick, surface_index)
  local previous = observed and (history.sweep_start or history.position)
  local endpoint = observed and (history.sweep_end or position)
  if observed and history.sweep_end then
    local ax, ay = straight_corridor(path, index, history.position, position)
    if ax and ax * (history.position.x - endpoint.x) + ay * (history.position.y - endpoint.y) <= 0
        and ax * (position.x - endpoint.x) + ay * (position.y - endpoint.y) >= 0 then
      -- Overlapping evidence can extend the same sweep after a small reversal.
      -- Requiring the samples to equal its endpoint would lose later travel
      -- while a very dense backlog was still being consumed.
      endpoint = position
    end
  end
  local advanced = 0

  -- Retain the original single proximity advance. Additional consumption must
  -- have geometric proof, even if several corner nodes fit inside that radius.
  local waypoint = path[index]
  if not (observed and data.waypoint_scan_pending) and index < #path and waypoint and waypoint.position
      and Util.distance_sq(position, waypoint.position) < threshold_sq then
    index = index + 1
    advanced = 1
  end
  if observed then
    while advanced < Navigation.MAX_WAYPOINT_ADVANCES
        and crossed_straight_waypoint(path, index, previous, endpoint) do
      index = index + 1
      advanced = advanced + 1
    end
    -- A saved sweep stays valid while the vehicle drifts during bounded scans.
    -- New motion is a separate piece of evidence when it cannot extend that
    -- same straight corridor; it must independently cross the next waypoint.
    if advanced < Navigation.MAX_WAYPOINT_ADVANCES and history.sweep_end then
      previous, endpoint = history.position, position
      while advanced < Navigation.MAX_WAYPOINT_ADVANCES
          and crossed_straight_waypoint(path, index, previous, endpoint) do
        index = index + 1
        advanced = advanced + 1
      end
    end
  end
  local pending = observed and advanced == Navigation.MAX_WAYPOINT_ADVANCES
    and crossed_straight_waypoint(path, index, previous, endpoint) or false
  if observed and advanced == Navigation.MAX_WAYPOINT_ADVANCES and not pending
      and history.sweep_end and crossed_straight_waypoint(path, index, history.position, position) then
    -- The old sweep may end exactly at the work limit. Do not lose a newer
    -- observed segment merely because there was no budget to inspect it yet.
    previous, endpoint = history.position, position
    pending = true
  end
  data.current_waypoint = index
  data.waypoint_scan_pending = pending or nil
  data.waypoint_motion = {
    path = path, entity = entity, surface_index = surface_index,
    position = {x = position.x, y = position.y}, tick = tick, waypoint = index,
    running_speed = entity.type == "character" and entity.character_running_speed or nil,
    sweep_start = pending and {x = previous.x, y = previous.y} or nil,
    sweep_end = pending and {x = endpoint.x, y = endpoint.y} or nil
  }
  return advanced, pending
end

-- Set character walking state
---@param character LuaEntity
---@param waypoint_pos MapPosition
function Navigation.set_character_walking(character, waypoint_pos)
  local direction = Navigation.get_character_direction(character.position, waypoint_pos)
  if direction then
    character.walking_state = { walking = true, direction = direction }
  else
    character.walking_state = { walking = false, direction = defines.direction.north }
  end
end

-- Set vehicle riding state
---@param vehicle LuaEntity
---@param target_pos MapPosition
function Navigation.set_vehicle_riding(vehicle, target_pos)
  local riding = Navigation.get_vehicle_riding_state(vehicle, target_pos)
  vehicle.riding_state = riding
end

return Navigation
