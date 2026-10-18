--[[
  Click2Move - Navigation
  Direction calculation, waypoint advancement, and movement state setting.
]]

local Util = require("scripts/util")

local Navigation = {}

-- 8-way direction selection (returns defines.direction). Each axis is
-- corrected while its error exceeds the dead zone, whichever error is larger:
-- moving along only the larger axis can cross the target's line every tick
-- while the other error never shrinks. Nil once both are inside it.
---@param from MapPosition
---@param to MapPosition
---@return defines.direction | nil
function Navigation.get_character_direction(from, to)
  local distance_threshold = 0.15
  local dx = to.x - from.x
  local dy = to.y - from.y
  local east = dx > distance_threshold and 1 or dx < -distance_threshold and -1 or 0
  local south = dy > distance_threshold and 1 or dy < -distance_threshold and -1 or 0
  if east == 0 and south == 0 then return nil end
  if south == 0 then return east > 0 and defines.direction.east or defines.direction.west end
  if east == 0 then return south > 0 and defines.direction.south or defines.direction.north end
  if south > 0 then return east > 0 and defines.direction.southeast or defines.direction.southwest end
  return east > 0 and defines.direction.northeast or defines.direction.northwest
end

-- Vehicle riding state towards a target
---@param vehicle LuaEntity
---@param target_pos MapPosition
---@param speed_limit? number brake above this speed, forwards or in reverse, and coast just below it
---@return RidingState
function Navigation.get_vehicle_riding_state(vehicle, target_pos, speed_limit, precise_steering)
  -- Factorio orientation: 0 is North, clockwise. Math functions: 0 is East, counter-clockwise.
  -- We need to adjust the angle. A 90-degree (pi/2) clockwise rotation is needed.
  -- Or, equivalently, subtract pi/2 from the standard angle.
  local radians = vehicle.orientation * 2 * math.pi - (math.pi / 2)
  local v1 = {x = target_pos.x - vehicle.position.x, y = target_pos.y - vehicle.position.y}

  local forward = v1.x * math.cos(radians) + v1.y * math.sin(radians)
  local right = -v1.x * math.sin(radians) + v1.y * math.cos(radians)

  local steer_threshold = 0.2
  if precise_steering then
    steer_threshold = math.max(0.01, math.sqrt(v1.x * v1.x + v1.y * v1.y) * 0.005)
  end
  local accel_threshold = 0.2

  ---@type defines.riding.direction
  local direction = defines.riding.direction.straight
  if right < -steer_threshold then
    direction = defines.riding.direction.left
  elseif right > steer_threshold then
    direction = defines.riding.direction.right
  end

  -- Within the speed limit, a target beside the vehicle is turned towards by
  -- creeping forward: braking to a standstill would hold the vehicle there
  -- for good. Without a speed limit the old rule applies.
  local speed = vehicle.speed or 0
  local gear
  if forward > accel_threshold or (speed_limit and forward >= -accel_threshold
      and direction ~= defines.riding.direction.straight) then
    gear = "forward"
  elseif forward < -accel_threshold then
    gear = "reverse"
  end

  -- A nearby pursuit target crosses the side of the car during a turn. Do
  -- not alternate forward and reverse there: opposite yaw cancels the turn.
  -- Keep the current travel direction until the target is over 120 degrees
  -- behind it. Actual speed supplies the hysteresis across save/load too.
  if speed_limit and math.abs(speed) > 0.005 and direction ~= defines.riding.direction.straight then
    local alignment = forward * (speed > 0 and 1 or -1)
    local distance = math.sqrt(v1.x * v1.x + v1.y * v1.y)
    if alignment >= -distance * 0.5 then gear = speed > 0 and "forward" or "reverse" end
  end

  ---@type defines.riding.acceleration
  local acceleration = defines.riding.acceleration.braking
  if gear then
    local travel = gear == "forward" and speed or -speed
    if speed_limit and travel > speed_limit then
      acceleration = defines.riding.acceleration.braking
    elseif speed_limit and travel > speed_limit * 0.95 then
      acceleration = defines.riding.acceleration.nothing
    else
      acceleration = gear == "forward" and defines.riding.acceleration.accelerating
        or defines.riding.acceleration.reversing
    end
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
-- Positional tolerance only: characters stop within 0.15 tiles per axis of a
-- node (get_character_direction). It never stands in for path clearance.
local REACH = 0.25
-- Segment-distance evaluations allowed for shortcut checks in one update. The
-- defaults need a few hundred; tiny margins would need millions.
local SHORTCUT_WORK = 2048
-- Path nodes inspected for corners within one update's travel.
local LOOKAHEAD_NODES = 64

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

local function segment_distance_sq(px, py, from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  local length_sq = dx * dx + dy * dy
  local t = 0
  if length_sq > 0 then
    t = math.max(0, math.min(1, ((px - from.x) * dx + (py - from.y) * dy) / length_sq))
  end
  return (px - (from.x + t * dx)) ^ 2 + (py - (from.y + t * dy)) ^ 2
end

-- A shortcut to path[target] is safe while it stays within the path margin of
-- the route it replaces: the pathfinder cleared that corridor. Distance to the
-- path changes by at most the distance moved, so samples within 3/4 of the
-- margin, half a margin apart, also prove the line between them. A check whose
-- worst case exceeds the remaining work budget is refused before sampling: the
-- actor then follows the explicit waypoints, and the margin is never enlarged.
local function shortcut_clear(path, from, target, position, margin, budget)
  local goal = path[target].position
  local dx, dy = goal.x - position.x, goal.y - position.y
  local samples = math.ceil(math.sqrt(dx * dx + dy * dy) / (margin / 2))
  local work = (samples + 1) * (target - from)
  if not (work <= budget.work) then return false end
  budget.work = budget.work - work
  local limit_sq = (margin * 3 / 4) ^ 2
  for sample = 0, samples do
    local t = samples > 0 and sample / samples or 0
    local px, py = position.x + dx * t, position.y + dy * t
    local clear = false
    for index = from, target - 1 do
      if segment_distance_sq(px, py, path[index].position, path[index + 1].position) <= limit_sq then
        clear = true; break
      end
    end
    if not clear then return false end
  end
  return true
end

-- An actor past a node along its incoming segment, e.g. a car whose turning
-- circle overshot it, must not steer back to it.
local function passed_waypoint(path, index, position)
  local incoming = path[index - 1] and path[index - 1].position
  if not incoming then return true end
  local waypoint = path[index].position
  return (position.x - waypoint.x) * (waypoint.x - incoming.x)
    + (position.y - waypoint.y) * (waypoint.y - incoming.y) >= 0
end

-- Proximity alone is not proof of progress: a stationary actor would consume
-- one nearby corner per update and steer through the obstacle the path goes
-- round. Nodes inside the radius are consumed once the actor has reached or
-- passed them, or while the line to the next node stays in the clearance the
-- pathfinder checked for this path. Possible travel is not progress, so where
-- an update could overshoot a corner the actor steers every tick instead
-- (Navigation.near_unproven_waypoint). A node also counts as reached when the
-- movement observed over the last tick, a single straight physics step, came
-- within the tolerance: a fast character can step across a node's tolerance
-- every tick without either end landing in it. This has its own advance
-- budget, so a drained backlog cannot leave the actor steering towards a node
-- beside it.
local function advance_nearby(path, index, position, step_from, threshold_sq, clearance, budget, reach)
  local from, advanced = math.max(1, index - 1), 0
  while advanced < Navigation.MAX_WAYPOINT_ADVANCES and index < #path
      and path[index].position and path[index + 1].position do
    local waypoint = path[index].position
    local distance_sq = Util.distance_sq(position, waypoint)
    if distance_sq >= threshold_sq or not (distance_sq <= reach * reach or passed_waypoint(path, index, position)
        or (step_from and segment_distance_sq(waypoint.x, waypoint.y, step_from, position) <= reach * reach)
        or (clearance and clearance > 0 and shortcut_clear(path, from, index + 1, position, clearance, budget))) then
      break
    end
    index = index + 1
    advanced = advanced + 1
  end
  return index, advanced
end

-- Returns the incoming segment when path[index] continues it straight ahead.
local function straight_node(path, index)
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
  return ax, ay, length_a_sq
end

local function straight_corridor(path, index, previous, position)
  local ax, ay, length_a_sq = straight_node(path, index)
  if not ax then return nil end
  local target = path[index].position

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
---@param clearance? number margin the pathfinder kept clear around this path; nil when unknown
---@param reach? number distance at which a waypoint counts as reached; a vehicle's own size
---@return integer advanced, boolean pending_scan
function Navigation.advance_waypoints(data, entity, path, threshold_sq, tick, clearance, reach)
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
  local advanced, nearby = 0, 0

  local step_from = observed and tick - history.tick == 1 and history.position or nil
  local budget = {work = SHORTCUT_WORK}
  if not (observed and data.waypoint_scan_pending) then
    index, nearby = advance_nearby(path, index, position, step_from, threshold_sq, clearance, budget, math.max(reach or 0, REACH))
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
  if observed and data.waypoint_scan_pending and not pending then
    -- The backlog drained in this update. Continue to the nodes beside the
    -- actor, or it would steer towards one of them until the next update.
    index, nearby = advance_nearby(path, index, position, step_from, threshold_sq, clearance, budget, math.max(reach or 0, REACH))
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
  return advanced + nearby, pending
end

-- True while the actor could reach or overshoot a waypoint before the next
-- update, and observed motion along a straight corridor cannot prove it was
-- passed: the current waypoint while the actor is off its corridor, or any
-- corner or the destination within one update's travel along the path. The
-- actor then steers every tick. On an open straight run it keeps the
-- configured update interval.
---@param path PathfinderWaypoint[]
---@param index integer
---@param position MapPosition
---@param step number distance the actor can travel in one update
---@return boolean
function Navigation.near_unproven_waypoint(path, index, position, step)
  if index >= #path or not path[index] or not path[index].position then return false end
  local horizon = step + REACH
  local travelled = math.sqrt(Util.distance_sq(position, path[index].position))
  if travelled > horizon then return false end
  if not straight_corridor(path, index, position, position) then return true end
  local last = math.min(#path, index + LOOKAHEAD_NODES)
  for node = index + 1, last do
    if not path[node].position then return true end
    travelled = travelled + math.sqrt(Util.distance_sq(path[node - 1].position, path[node].position))
    if travelled > horizon then return false end
    if node == #path or not straight_node(path, node) then return true end
  end
  -- Nodes beyond the scan may still be reachable: assume one is a corner.
  return last < #path
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
---@param speed_limit? number
---@param braking_overshoots? boolean one tick of braking would end below the limit
function Navigation.set_vehicle_riding(vehicle, target_pos, speed_limit, braking_overshoots, precise_steering)
  local riding = Navigation.get_vehicle_riding_state(vehicle, target_pos, speed_limit, precise_steering)
  -- Braking power grows as speed falls, and the brake pedal reverses once the
  -- vehicle stops, so the last braking step towards a crawl overshoots into
  -- reverse. Finish that step at the limit and coast.
  local speed = vehicle.speed or 0
  if braking_overshoots and riding.acceleration == defines.riding.acceleration.braking then
    vehicle.speed = speed > 0 and speed_limit or -speed_limit
    riding.acceleration = defines.riding.acceleration.nothing
  end
  vehicle.riding_state = riding
end

return Navigation
