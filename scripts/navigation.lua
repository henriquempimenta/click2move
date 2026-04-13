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

-- Advance to next waypoint if close enough (shared for char/vehicle)
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param waypoint_pos MapPosition
---@param threshold_sq number
---@return boolean
function Navigation.advance_waypoint(data, current_pos, waypoint_pos, threshold_sq)
  if Util.distance_sq(current_pos, waypoint_pos) < threshold_sq then
    data.current_waypoint = data.current_waypoint + 1
    return true -- Advanced
  end
  return false
end

-- Set character walking state
---@param character LuaEntity
---@param data PlayerMoveData
---@param waypoint_pos MapPosition
function Navigation.set_character_walking(character, data, waypoint_pos)
  local direction = Navigation.get_character_direction(character.position, waypoint_pos)
  if direction then
    data.is_auto_walking = true
    character.walking_state = { walking = true, direction = direction }
  else
    data.is_auto_walking = false
    character.walking_state = { walking = false, direction = defines.direction.north }
  end
end

-- Set vehicle riding state
---@param player LuaPlayer
---@param vehicle LuaEntity
---@param target_pos MapPosition
function Navigation.set_vehicle_riding(player, vehicle, target_pos)
  local riding = Navigation.get_vehicle_riding_state(vehicle, target_pos)
  vehicle.riding_state = riding
end

return Navigation
