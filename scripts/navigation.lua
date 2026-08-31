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

-- Predict where a vehicle will be the next time movement is updated.
---@param vehicle LuaEntity
---@param ticks number
---@return MapPosition
function Navigation.predict_vehicle_position(vehicle, ticks)
  local radians = vehicle.orientation * 2 * math.pi - (math.pi / 2)
  local distance = (vehicle.speed or 0) * ticks
  return {
    x = vehicle.position.x + math.cos(radians) * distance,
    y = vehicle.position.y + math.sin(radians) * distance
  }
end

---@param point MapPosition
---@param line_start MapPosition
---@param line_end MapPosition
---@return number
local function distance_sq_to_line(point, line_start, line_end)
  local dx = line_end.x - line_start.x
  local dy = line_end.y - line_start.y
  local length_sq = dx * dx + dy * dy
  if length_sq == 0 then return Util.distance_sq(point, line_end) end

  local cross = (point.x - line_start.x) * dy - (point.y - line_start.y) * dx
  return (cross * cross) / length_sq
end

---@param point MapPosition
---@param segment_start MapPosition
---@param segment_end MapPosition
---@return number
local function distance_sq_to_segment(point, segment_start, segment_end)
  local dx = segment_end.x - segment_start.x
  local dy = segment_end.y - segment_start.y
  local length_sq = dx * dx + dy * dy
  if length_sq == 0 then return Util.distance_sq(point, segment_start) end

  local projection = ((point.x - segment_start.x) * dx + (point.y - segment_start.y) * dy) / length_sq
  projection = math.max(0, math.min(1, projection))
  local closest = {
    x = segment_start.x + projection * dx,
    y = segment_start.y + projection * dy
  }
  return Util.distance_sq(point, closest)
end

---@param path PathfinderWaypoint[]
---@param waypoint_index uint32
---@return boolean
local function is_gentle_turn(path, waypoint_index)
  local previous = path[waypoint_index - 1]
  local current = path[waypoint_index]
  local following = path[waypoint_index + 1]
  if not previous or not current or not following then return false end
  if not previous.position or not current.position or not following.position then return false end

  local incoming_x = current.position.x - previous.position.x
  local incoming_y = current.position.y - previous.position.y
  local outgoing_x = following.position.x - current.position.x
  local outgoing_y = following.position.y - current.position.y
  local incoming_length_sq = incoming_x * incoming_x + incoming_y * incoming_y
  local outgoing_length_sq = outgoing_x * outgoing_x + outgoing_y * outgoing_y
  if incoming_length_sq == 0 or outgoing_length_sq == 0 then return false end

  local cosine = (incoming_x * outgoing_x + incoming_y * outgoing_y)
    / math.sqrt(incoming_length_sq * outgoing_length_sq)

  -- Predictive skipping is restricted to turns of at most 60 degrees. Sharp
  -- corners must still be explicitly reached so vehicles do not cut obstacles.
  return cosine >= 0.5
end

---@param current_pos MapPosition
---@param predicted_pos MapPosition
---@param previous_pos MapPosition
---@param waypoint_pos MapPosition
---@param threshold_sq number
---@return boolean
local function crosses_waypoint(current_pos, predicted_pos, previous_pos, waypoint_pos, threshold_sq)
  local segment_x = waypoint_pos.x - previous_pos.x
  local segment_y = waypoint_pos.y - previous_pos.y
  local segment_length_sq = segment_x * segment_x + segment_y * segment_y
  if segment_length_sq == 0 then return false end

  local current_progress = (current_pos.x - waypoint_pos.x) * segment_x
    + (current_pos.y - waypoint_pos.y) * segment_y
  local predicted_progress = (predicted_pos.x - waypoint_pos.x) * segment_x
    + (predicted_pos.y - waypoint_pos.y) * segment_y

  if current_progress > 0 then
    return distance_sq_to_line(current_pos, previous_pos, waypoint_pos) <= threshold_sq
  end

  if predicted_progress < 0 then return false end

  -- The swept motion before the next update must pass through the waypoint's
  -- arrival corridor. This rejects a coincidental projection past a waypoint
  -- on another path leg while still allowing diagonal crossings.
  return distance_sq_to_segment(waypoint_pos, current_pos, predicted_pos) <= threshold_sq
end

-- Advance over every vehicle waypoint already reached, physically passed, or
-- projected to be crossed before the next update. The final destination is
-- handled separately by movement.lua and is never skipped by this function.
---@param data PlayerMoveData
---@param current_pos MapPosition
---@param predicted_pos MapPosition
---@param path PathfinderWaypoint[]
---@param threshold_sq number
---@return uint32 advanced_count
function Navigation.advance_vehicle_waypoints(data, current_pos, predicted_pos, path, threshold_sq)
  local advanced_count = 0

  while data.current_waypoint <= #path do
    local waypoint_index = data.current_waypoint
    local waypoint = path[waypoint_index]
    if not waypoint or not waypoint.position then break end

    local within_threshold = Util.distance_sq(current_pos, waypoint.position) < threshold_sq
    -- Preserve the existing proximity behavior for the current waypoint. Any
    -- additional waypoint advanced in this tick must pass the stricter crossing
    -- checks below, otherwise a large threshold could cut a sharp corner.
    local should_advance = within_threshold and advanced_count == 0
    local previous = path[waypoint_index - 1]

    if not should_advance and previous and previous.position then
      local crossed = crosses_waypoint(
        current_pos,
        predicted_pos,
        previous.position,
        waypoint.position,
        threshold_sq
      )

      -- A waypoint already behind the vehicle is always stale. Predictively
      -- skipping an upcoming waypoint is allowed only when the next turn is
      -- gentle, preventing look-ahead from cutting sharp corners.
      local segment_x = waypoint.position.x - previous.position.x
      local segment_y = waypoint.position.y - previous.position.y
      local current_progress = (current_pos.x - waypoint.position.x) * segment_x
        + (current_pos.y - waypoint.position.y) * segment_y
      should_advance = crossed and (current_progress > 0 or is_gentle_turn(path, waypoint_index))
    end

    if not should_advance then break end

    data.current_waypoint = waypoint_index + 1
    advanced_count = advanced_count + 1
  end

  return advanced_count
end

-- Set character walking state
---@param character LuaEntity
---@param data PlayerMoveData
---@param waypoint_pos MapPosition
function Navigation.set_character_walking(character, data, waypoint_pos)
  local direction = Navigation.get_character_direction(character.position, waypoint_pos)
  Navigation.walk_in_direction(character, data, direction)
end

-- Drive the character in an explicit direction (or stop, if nil).
-- Keeping the commanded direction lets movement.lua distinguish the mod's own
-- walking state from a player or another mod taking control.
---@param character LuaEntity
---@param data PlayerMoveData
---@param direction defines.direction | nil
function Navigation.walk_in_direction(character, data, direction)
  if direction then
    data.is_auto_walking = true
    data.commanded_direction = direction
    character.walking_state = { walking = true, direction = direction }
  else
    data.is_auto_walking = false
    data.commanded_direction = nil
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
