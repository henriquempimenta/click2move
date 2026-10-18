--[[
  Click2Move - Vehicle speed
  Slows vehicles in time for corners and the destination. Fast cars need
  hundreds of tiles to brake and turn in circles more than ten tiles wide.

  Measured on native cars and tanks of every quality and vanilla fuel:
  - braking removes braking_force / weight / 3600 * T^2 from half the square
    of the speed per tick, where T is the burning fuel's top speed multiplier
    with its quality bonus (1 with an empty burner); exoskeletons and vehicle
    quality do not change it;
  - friction deceleration is friction_force * (1 + (tile modifier - 1) *
    terrain_friction_modifier) * speed;
  - cars turn rotation_speed * sqrt(speed) turns per tick, so their turning
    radius is sqrt(speed) / (2 pi rotation_speed), whatever the fuel;
  - tank_driving vehicles turn at a constant rate at every speed and pedal:
    rotation_speed * (0.75 + 0.25 * A * (1 + B)) turns per tick, where A is
    the burning fuel's acceleration multiplier with its quality bonus (1 with
    an empty burner) and B the equipment grid's movement bonus, which drops
    to 0 while exoskeletons are unpowered or the bonus is switched off.
]]

local Util = require("scripts/util")
local Trajectory = require("scripts/vehicle-trajectory")

local VehicleSpeed = {}

-- A little under the native 1/3600 energy step. In particular, frictionless
-- cars cannot rely on friction hiding an optimistic braking-force estimate.
local BRAKING_SCALE = 1 / 3700
-- Twenty seconds of full throttle: far longer than braking from top speed.
local FUEL_RESERVE_TICKS = 1200
-- Leave steering authority to correct tracking error while following an arc.
local RADIUS_SAFETY = 0.9
-- Speed planning needs some corridor even when a path has no recorded margin.
-- This only sets corner speeds; it never approves a shortcut.
local MIN_PLANNING_CLEARANCE = 0.5
-- Vehicles can always crawl round a corner.
local MIN_CORNER_SPEED = 0.03
-- Distance kept in hand for the reaction before braking takes effect.
local REACTION_TILES = 1

local min_tile_friction
local function tile_friction()
  if not min_tile_friction then
    -- The most slippery tile anywhere, so friction is never overestimated.
    min_tile_friction = 1
    for _, tile in pairs(prototypes.tile) do
      local modifier = tile.vehicle_friction_modifier
      if modifier and modifier < min_tile_friction then min_tile_friction = math.max(0, modifier) end
    end
  end
  return min_tile_friction
end

-- The fuel's acceleration and top speed multipliers, the weakest of the fuel
-- burning and the fuel waiting to burn. Braking burns no fuel, so a vehicle
-- that is told to plan without its fuel still brakes with it while it slows.
-- Without fuel waiting, the burning item only counts while it holds at least
-- FUEL_RESERVE_TICKS of full throttle.
local function fuel_multipliers(vehicle, prototype)
  local burner = vehicle.burner
  local burning = burner and burner.currently_burning
  if not (burning and burning.name) then return 1, 1 end
  local inventory = vehicle.get_fuel_inventory and vehicle.get_fuel_inventory()
  local acceleration, top_speed, waiting = math.huge, math.huge, false
  local function consider(item, quality)
    local level = quality and quality.level or 0
    acceleration = math.min(acceleration, (item.fuel_acceleration_multiplier or 1)
      + (item.fuel_acceleration_multiplier_quality_bonus or 0) * level)
    top_speed = math.min(top_speed, (item.fuel_top_speed_multiplier or 1)
      + (item.fuel_top_speed_multiplier_quality_bonus or 0) * level)
  end
  consider(burning.name, burning.quality)
  for slot = 1, inventory and #inventory or 0 do
    local stack = inventory[slot]
    if stack.valid_for_read then consider(stack.prototype, stack.quality); waiting = true end
  end
  if not waiting then
    local usage = prototype.consumption or 0
    local source = prototype.burner_prototype
    local effectivity = source and source.effectivity or 1
    if usage <= 0 or effectivity <= 0
        or (burner.remaining_burning_fuel or 0) < usage / effectivity * FUEL_RESERVE_TICKS then
      return 1, 1
    end
  end
  return acceleration, top_speed
end

---@return {brake: number, friction: number, rotation: number, tank: boolean}?
local function vehicle_model(vehicle)
  local prototype = vehicle.prototype
  if not prototype then return nil end
  local braking, weight, rotation = prototype.braking_force, prototype.weight, prototype.rotation_speed
  if not (braking and weight and rotation and weight > 0 and braking > 0 and rotation > 0) then return nil end
  local acceleration, top_speed = fuel_multipliers(vehicle, prototype)
  local tank = prototype.tank_driving == true
  if tank then
    -- Turns per tick at any speed; a car's rate per square root of speed
    -- does not depend on fuel or equipment.
    local grid = vehicle.grid
    local bonus = grid and grid.movement_bonus or 0
    rotation = rotation * math.max(0.75, 0.75 + 0.25 * acceleration * (1 + bonus))
  end
  local terrain = prototype.terrain_friction_modifier or 1
  return {
    brake = braking / weight * BRAKING_SCALE * top_speed ^ 2,
    friction = (prototype.friction_force or 0) * (vehicle.friction_modifier or 1)
      * math.max(0, 1 + (tile_friction() - 1) * terrain),
    rotation = rotation,
    tank = tank
  }
end

-- Distance to brake from speed to rest: the integral of v^2 / (P + f v^2).
local function stopping_distance(model, speed)
  local p, f = model.brake, model.friction
  if f <= 0 then return speed ^ 3 / (3 * p) end
  local z_squared = speed * speed * f / p
  if z_squared < .01 then
    -- z - atan(z) loses its significant digits near zero. This alternating
    -- series ends on a positive term, bounding the integral from above.
    return speed ^ 3 / p * (1 / 3 - z_squared * (1 / 5 - z_squared * (1 / 7
      - z_squared * (1 / 9 - z_squared / 11))))
  end
  return speed / f - math.sqrt(p / f ^ 3) * math.atan(speed * math.sqrt(f / p))
end

-- The highest speed that can still brake to `target` within `distance`.
local function speed_before(model, target, distance)
  if distance <= 0 then return target end
  local needed = stopping_distance(model, target) + distance
  local low, high = target, math.max(target, 1)
  while stopping_distance(model, high) < needed and high < 64 do high = high * 2 end
  for _ = 1, 32 do
    local middle = (low + high) / 2
    if stopping_distance(model, middle) < needed then low = middle else high = middle end
  end
  return low
end

local function turning_speed(model, radius)
  local turn = 2 * math.pi * model.rotation * RADIUS_SAFETY * radius
  return math.max(MIN_CORNER_SPEED, model.tank and turn or turn * turn)
end

-- The fastest speed that turns a heading error of `angle` within `clearance`
-- of the line ahead. The turn can only start now: a circle of radius R drifts
-- R * (1 - cos angle) sideways before the heading is corrected.
local function heading_speed(model, angle, clearance)
  if angle < 0.001 then return math.huge end
  return turning_speed(model, clearance / (1 - math.cos(angle)))
end

local function heading_change(ax, ay, bx, by)
  local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
  if la < 0.0001 or lb < 0.0001 then return 0 end
  return math.acos(math.max(-1, math.min(1, (ax * bx + ay * by) / (la * lb))))
end

-- The reference can spend part of the corridor on a rounded corner. What is
-- left for correcting the vehicle depends on its distance from the original
-- path, not its distance from that reference. Locate the corresponding source
-- leg by distance, then inspect a fixed local window. Missing a nearer leg is
-- conservative: it can only reduce the room, never invent clearance.
local function path_offset(path, distances, source, position)
  if #path < 2 then return 0 end
  local low, high = 1, #path - 1
  while low < high do
    local middle = math.floor((low + high) / 2)
    if distances[middle + 1] < source then low = middle + 1 else high = middle end
  end
  local best = math.huge
  for index = math.max(1, low - 2), math.min(#path - 1, low + 2) do
    local a, b = path[index].position, path[index + 1].position
    local dx, dy = b.x - a.x, b.y - a.y
    local length_sq = dx * dx + dy * dy
    local t = length_sq > 0 and math.max(0, math.min(1,
      ((position.x - a.x) * dx + (position.y - a.y) * dy) / length_sq)) or 0
    best = math.min(best, Util.distance_sq(position, {x = a.x + t * dx, y = a.y + t * dy}))
  end
  return math.sqrt(best)
end

-- Fastest speed at each node from which the vehicle can still slow for every
-- later corner and stop at the destination. Rebuilt after loading.
local profiles = setmetatable({}, {__mode = "k"})

local function profile(path, vehicle, clearance)
  local cached = profiles[path]
  local friction_modifier = vehicle.friction_modifier or 1
  local same_shape = cached and cached.vehicle == vehicle.name and cached.clearance == clearance
  -- Fuel and exoskeleton power change braking and a tank's turning rate,
  -- not the route.
  local model = vehicle_model(vehicle)
  if not model then return nil end
  if same_shape and cached.friction_modifier == friction_modifier and cached.model.rotation == model.rotation
      and cached.model.brake == model.brake then
    return cached
  end
  local available, tracking, geometry
  if same_shape then
    available, tracking, geometry = cached.available, cached.tracking_reserve, cached.geometry
  else
    -- A rotated rectangle can extend farther sideways than the box supplied to
    -- the pathfinder. Reserve that difference, then some space for tracking.
    local box, padding = vehicle.prototype.collision_box, 0
    if box and box.left_top and box.right_bottom then
      local x = math.max(-box.left_top.x, box.right_bottom.x)
      local y = math.max(-box.left_top.y, box.right_bottom.y)
      padding = math.sqrt(x * x + y * y) - math.min(x, y)
    end
    available = math.max(0, (clearance or 0) - padding)
    tracking = math.min(0.4, available * 0.25)
    geometry = Trajectory.build(path, available - tracking)
  end
  local segments, count = geometry.segments, #geometry.segments
  local limits = {}
  limits[count + 1] = 0
  for index = count, 1, -1 do
    local segment = segments[index]
    local cap = segment.radius and turning_speed(model, segment.radius) or math.huge
    if index < count then
      -- Zero/unknown clearance and exact reversals retain explicit corners.
      local _, incoming = Trajectory.sample(geometry, segment.end_s - 0.000001)
      local _, outgoing = Trajectory.sample(geometry, segment.end_s + 0.000001)
      if heading_change(incoming.x, incoming.y, outgoing.x, outgoing.y) > 0.01 then
        limits[index + 1] = math.min(limits[index + 1], MIN_CORNER_SPEED)
      end
    end
    limits[index] = math.min(cap, speed_before(model, limits[index + 1], segment.length))
  end
  cached = {vehicle = vehicle.name, clearance = clearance, friction_modifier = friction_modifier,
    model = model, limits = limits, available = available, tracking_reserve = tracking,
    geometry = geometry, smooth = available > 0,
    corridor = available > 0 and available or MIN_PLANNING_CLEARANCE,
    tracking = available > 0 and tracking or MIN_PLANNING_CLEARANCE}
  profiles[path] = cached
  return cached
end

-- Highest speed for the vehicle now, forwards or in reverse, or nil when its
-- prototype does not describe braking and turning.
---@param vehicle LuaEntity
---@param path PathfinderWaypoint[]
---@param index integer current waypoint
---@param clearance? number
---@param step number distance travelled before the next update
---@return number?
function VehicleSpeed.control(vehicle, path, index, clearance, step, state)
  if not path or #path == 0 then return nil end
  local plan = profile(path, vehicle, clearance)
  if not plan then return nil end
  index = math.max(1, math.min(index, #path))
  local position, geometry = vehicle.position, plan.geometry
  local history = state and state.vehicle_trajectory
  local reference_s = history and history.revision == Trajectory.REVISION
    and history.path == path and history.entity == vehicle and history.s or nil
  -- Explicit waypoint steering has already accepted every node before index.
  -- The vehicle body may reach a corner before its centre does; do not keep
  -- braking for that old corner after steering has moved to the next leg.
  local minimum_s = not plan.smooth and geometry.waypoint_s[math.max(1, index - 1)] or nil
  if minimum_s and index > 1 then minimum_s = math.min(geometry.total_length, minimum_s + 0.000001) end
  local s, offset, segment_index = Trajectory.project(geometry, position, index, minimum_s, reference_s)
  if not reference_s and plan.smooth then
    -- A first proximity scan can already be several raw nodes ahead. Compare
    -- the start too, instead of mistaking the current line for off-route ground.
    local start_s, start_offset, start_index = Trajectory.project(geometry, position, 1)
    if start_offset < offset then s, offset, segment_index = start_s, start_offset, start_index end
  end
  if state then state.vehicle_trajectory = {path = path, entity = vehicle, s = s, revision = Trajectory.REVISION} end
  local reached, advances = index, 0
  if plan.smooth and offset <= plan.tracking then
    while reached < #path and advances < 16 and geometry.waypoint_s[reached] <= s do
      reached, advances = reached + 1, advances + 1
    end
  end
  local segment = geometry.segments[segment_index]
  local distance = segment and segment.end_s - s or math.sqrt(Util.distance_sq(position, path[index].position))
  local cap = segment and plan.limits[segment_index + 1] or 0
  -- Near an explicit corner, commit to controlling every tick. The braking
  -- reaction then needs one tick of travel, rather than the configured update
  -- interval, without changing the corner's speed or inventing clearance.
  local precise_corner = not plan.smooth and segment and cap <= MIN_CORNER_SPEED
    and distance <= math.max(2, step + REACTION_TILES + 1)
  if precise_corner then step = math.min(step, math.abs(vehicle.speed or 0)) end
  local limit = speed_before(plan.model, cap, distance - step - REACTION_TILES)
  if segment and segment.radius then limit = math.min(limit, turning_speed(plan.model, segment.radius)) end
  local lookahead = math.max(0.8, math.abs(vehicle.speed or 0) * 6, offset * 2)
  if segment and segment.radius and offset <= plan.tracking then
    lookahead = math.min(lookahead, math.max(0.8, segment.radius * 0.6))
  end
  local target, _, curvature = Trajectory.sample(geometry, s + lookahead)
  target = plan.smooth and target or path[index].position
  local room = plan.corridor - path_offset(path, geometry.path_distances,
    Trajectory.source_distance(geometry, s), position)
  if room <= 0 then return MIN_CORNER_SPEED, plan.smooth and target or nil, true, reached end
  if distance > 0.5 then
    -- A heading error towards the current waypoint must be turned out within
    -- the room left in the corridor.
    local radians = vehicle.orientation * 2 * math.pi
    local angle = heading_change(math.sin(radians), -math.cos(radians), target.x - position.x, target.y - position.y)
    -- While rolling, plan for the actual travel direction. Gear hysteresis
    -- can deliberately keep driving forwards towards a target over 90° to
    -- the side; assuming the nearer rear heading would allow too much speed.
    local signed_speed = vehicle.speed or 0
    if signed_speed < -0.005 or (math.abs(signed_speed) <= 0.005 and angle > math.pi / 2) then
      angle = math.pi - angle
    end
    limit = math.min(limit, heading_speed(plan.model, angle, room))
  end
  return limit, plan.smooth and target or nil,
    offset > plan.tracking or curvature ~= 0 or (segment and segment.radius ~= nil)
      or precise_corner, reached
end

function VehicleSpeed.limit(vehicle, path, index, clearance, step)
  return (VehicleSpeed.control(vehicle, path, index, clearance, step))
end

-- The exact reference used for steering and its curvature speed limits.
function VehicleSpeed.trajectory(vehicle, path, clearance)
  local plan = profile(path, vehicle, clearance)
  return plan and plan.geometry, plan and plan.available, plan and plan.tracking_reserve
end

-- True when one update of braking would take the vehicle below the limit.
---@param vehicle LuaEntity
---@param speed_limit? number
---@param interval integer ticks between updates
---@return boolean
function VehicleSpeed.braking_overshoots(vehicle, speed_limit, interval)
  local model = speed_limit and vehicle_model(vehicle)
  if not model then return false end
  local speed = math.abs(vehicle.speed or 0)
  if speed <= speed_limit then return false end
  local step = model.brake / speed + model.friction * speed
  return speed - step * interval < speed_limit
end

-- Ticks for one and a half turning circles at the speed limit: how long a
-- vehicle slowed for a tight turn may go without getting closer to its target.
---@param vehicle LuaEntity
---@param speed_limit? number
---@return number?
function VehicleSpeed.maneuver_ticks(vehicle, speed_limit)
  local model = speed_limit and vehicle_model(vehicle)
  if not model then return nil end
  -- Tanks turn at the same rate at any speed.
  local turn = model.tank and model.rotation or model.rotation * math.sqrt(math.max(speed_limit, MIN_CORNER_SPEED))
  return 1.5 / turn
end

-- True while the vehicle is turning and one update's worth of turning could
-- carry it past the heading towards the target: it then steers every tick.
---@param vehicle LuaEntity
---@param target MapPosition
---@param interval integer ticks between updates
---@return boolean
function VehicleSpeed.steering_overshoots(vehicle, target, interval)
  if interval <= 1 then return false end
  local model = vehicle_model(vehicle)
  if not model then return false end
  local speed = math.abs(vehicle.speed or 0)
  -- An upper bound: a tank's rate is exact, a car's grows with speed.
  local turn = model.tank and model.rotation * 1.1 or model.rotation * math.sqrt(speed)
  local position = vehicle.position
  local radians = vehicle.orientation * 2 * math.pi
  local error = heading_change(math.sin(radians), -math.cos(radians), target.x - position.x, target.y - position.y)
  -- Reversing towards a target behind steers by the rear.
  if error > math.pi / 2 then error = math.pi - error end
  return error / (2 * math.pi) <= turn * (interval + 1)
end

return VehicleSpeed
