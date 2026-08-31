--[[
  Click2Move - Belt awareness

  Factorio's pathfinder has no concept of transport belts. Belts do not collide
  with characters, so `request_path` will happily route a straight line down a
  belt lane that then shoves the character backwards the whole way. Walking
  against an express belt nets roughly a third of normal speed; walking with one
  is substantially faster than running on dirt.

  There is no hook to give the pathfinder a cost function, so belt awareness is
  applied in two places instead:

    1. `Belts.plan` — a post-pass over the path the pathfinder returned. It
       samples the belts under each segment and, where a segment fights a belt,
       splices in a short lateral detour that steps off the belt block, runs
       clear of it, and rejoins. It can also route *onto* a nearby belt heading
       the right way when riding it beats walking, detour included.

    2. `Belts.escape_direction` — a per-tick correction. If the character is
       standing on a belt opposing travel, walk perpendicular to leave it
       immediately rather than grinding along it.

  Both are opt-in via the `c2m-routing-strategy` setting so the naive behaviour
  stays available for A/B measurement.
]]

local Util = require("scripts/util")

local Belts = {}

-- Effective character travel speed in tiles/tick along a route.
--
-- Deliberately *not* the prototype's 0.15 running speed. That is the speed of a
-- character running flat out in a straight line; a character following waypoints
-- spends part of every tick turning and correcting, and measures 0.092 tiles/tick
-- of actual progress on clear ground over a 1149-tick traced sample.
--
-- Using 0.15 here is not a harmless constant-factor error, because it is only
-- applied to *clear* ground: it makes walking look 60% better than it is
-- relative to riding a belt, which suppresses exactly the belt-assisted routes
-- this module exists to find.
local BASE_WALK_SPEED = 0.092

-- Multiplier on a belt's opposing component (see `effective_speed`).
--
-- Calibrated, not guessed: a traced `main-bus-against` run measured -0.0066
-- tiles/tick of westward progress while on an opposing yellow belt. Solving
-- `0.15 - 0.03 * P = -0.0066` gives P = 5.22, which reproduces that number.
--
-- Calibrated against *yellow* belts specifically. Extrapolating linearly to red
-- and blue predicts -0.16 and -0.32 tiles/tick, i.e. being carried backwards
-- fast, which matches the qualitative behaviour but has not been measured
-- directly — the bench arena's bus is yellow. Worth re-deriving per tier if a
-- route ever hinges on express-belt opposition.
local OPPOSING_BELT_PENALTY = 5.22

-- Belts are 1 tile; a character occupies well under a tile. Sampling the tile
-- centre a segment passes through is enough to know whether it is on a belt.
local SAMPLE_STEP = 0.5

-- How far off-path to look for a belt worth riding. Beyond this the detour
-- overhead swamps any speed gain, and the search cost stops being free.
local RIDE_SEARCH_RADIUS = 8

-- A ride must beat walking by this fraction to be worth the disruption of
-- getting on and off. Riding is jerkier than walking, so a marginal win is not
-- actually a win from the player's seat.
--
-- Set high deliberately. Measured against the benchmark, an optimistic ride
-- estimate is much more costly than a missed one: taking a bad ride on the
-- main-bus route cost 2216 ticks where walking cost 565, because a ride commits
-- the character to a lane it then has to fight to stay on. A missed ride just
-- means walking, which is never catastrophic. So the bar to ride is high.
local RIDE_MIN_ADVANTAGE = 1.6

-- Fixed overhead, in ticks, for getting onto a belt lane and off it again.
--
-- Boarding is not free: the character has to align to a one-tile-wide lane,
-- and the waypoint logic spends time converging on it rather than travelling.
-- Without this the planner scores a ride as pure distance/speed and takes rides
-- that measure far worse than walking.
local RIDE_BOARDING_OVERHEAD = 120

-- How directly a belt must oppose travel before escaping it is worth the
-- detour, as |cos| between the belt direction and the heading.
--
-- 1.0 is a belt pointing exactly back at us; 0.0 is one we cross at a right
-- angle. At 0.7 (~45 degrees) a belt has to be meaningfully in our way, so
-- crossings are walked through and only genuine head-on fights are escaped.
local ESCAPE_MIN_OPPOSITION = 0.7

-- Do not leave a belt for a momentary pathfinder kink. Factorio paths are made
-- of short cardinal/diagonal steps, so an otherwise perpendicular crossing can
-- contain one segment that points against the belt. Avoidance is worthwhile
-- only when a contiguous belt encounter contains this much genuinely opposed
-- travel along the belt axis.
local MIN_AVOID_OPPOSED_DISTANCE = 2.0

-- Whole-route safeguards for Phase 1. The belt model is deliberately severe
-- against sustained opposition, but a modelled win must still be meaningful
-- and geometrically plausible before it changes the vanilla route.
local AVOID_MIN_GAIN = 1.10
local MAX_AVOID_DISTANCE_RATIO = 1.5
local AVOID_DISTANCE_ALLOWANCE = 4

-- How close (squared, in tiles) counts as having reached an escape exit point.
-- The character never lands exactly on a target, and a belt at the boundary
-- nudges it, so this has to be loose enough to latch. Half a tile.
local ESCAPE_ARRIVE_DIST_SQ = 0.25

local BELT_TYPES = { "transport-belt", "underground-belt", "splitter", "linked-belt", "loader", "loader-1x1" }

---@class BeltPlan
---@field avoid_until? uint32          -- Tick after which the off-belt correction stops being applied
---@field ride_target? MapPosition     -- Belt tile we are deliberately riding, if any
---@field ride_until? uint32

-- Unit vector for a belt direction. Factorio 2.x `defines.direction` has 16
-- values (north = 0, northeast = 2, east = 4, ...); belts can only face the
-- four cardinals, so only those need mapping.
local DIR_VECTORS = {
  [defines.direction.north] = { x = 0, y = -1 },
  [defines.direction.east]  = { x = 1, y = 0 },
  [defines.direction.south] = { x = 0, y = 1 },
  [defines.direction.west]  = { x = -1, y = 0 },
}

---@param direction defines.direction
---@return MapPosition
local function direction_vector(direction)
  return DIR_VECTORS[direction] or { x = 0, y = 0 }
end

-- Belt movement speed in tiles/tick. `prototype.belt_speed` is already in
-- tiles/tick (yellow 0.03, red 0.06, blue 0.09).
---@param entity LuaEntity
---@return number
local function belt_speed(entity)
  local proto = entity.prototype
  return (proto and proto.belt_speed) or 0.03
end

-- Normalize a vector; returns nil for a zero vector rather than dividing by 0.
---@param v MapPosition
---@return MapPosition | nil
local function normalize(v)
  local len = math.sqrt(v.x * v.x + v.y * v.y)
  if len < 1e-6 then return nil end
  return { x = v.x / len, y = v.y / len }
end

-- The belt entity under a position, if any.
--
-- Uses a small area rather than a point lookup because `find_entities_filtered`
-- with a zero-size area misses entities whose collision box merely contains the
-- point.
---@param surface LuaSurface
---@param position MapPosition
---@return LuaEntity | nil
function Belts.belt_at(surface, position)
  local found = surface.find_entities_filtered {
    area = {
      { position.x - 0.1, position.y - 0.1 },
      { position.x + 0.1, position.y + 0.1 },
    },
    type = BELT_TYPES,
  }
  return found[1]
end

-- How much a belt helps (positive) or hinders (negative) travel in `heading`.
-- Returns the belt's contribution to velocity along the heading, in tiles/tick.
---@param belt LuaEntity
---@param heading MapPosition  -- unit vector
---@return number
local function belt_contribution(belt, heading)
  -- Splitters and sideloaded belts move items in ways that are not worth
  -- modelling; treat them as neutral obstacles rather than guessing.
  if belt.type ~= "transport-belt" then return 0 end
  local v = direction_vector(belt.direction)
  local speed = belt_speed(belt)
  return (v.x * heading.x + v.y * heading.y) * speed
end

-- Effective travel speed along `heading` while standing on `belt`.
--
-- The obvious model — `walk + belt_contribution`, floored just above zero — is
-- badly wrong against a belt, and wrong in the direction that matters. It says
-- fighting a yellow belt costs 0.15 - 0.03 = 0.12 tiles/tick, a mere 20%
-- penalty, so no detour can ever look worthwhile.
--
-- Measured from a per-tick trace of `main-bus-against` (2560 ticks, character
-- walking west along an eastward bus):
--
--     on belt, opposing    -0.0066 tiles/tick   (net *backward*)
--     off belt, clear       0.0920 tiles/tick
--
-- So the true penalty is not 20%: progress is negative. The character is not
-- walking a straight line, it is chasing waypoints while being shoved sideways,
-- and most of its speed budget goes into correcting rather than travelling. A
-- floor of 0.01 encodes forward progress the game does not actually deliver.
--
-- Modelled instead as: the belt's opposing component is amplified, because
-- fighting it also costs steering, and the result is allowed to go to a very
-- small positive number representing "effectively stuck" rather than "slow".
-- Kept positive only so cost arithmetic cannot divide by zero — a segment that
-- hits this floor is priced as catastrophic, which is the intent.
---@param belt LuaEntity | nil
---@param heading MapPosition
---@return number
local function effective_speed(belt, heading)
  if not belt then return BASE_WALK_SPEED end
  local contribution = belt_contribution(belt, heading)
  if contribution >= 0 then
    -- Riding with a belt does add cleanly; the measured off-belt rate already
    -- reflects the steering overhead that applies everywhere.
    return BASE_WALK_SPEED + contribution
  end

  -- The penalty applies to fighting a belt *along its axis*, which is what was
  -- measured. Crossing one is a different situation and must not be priced the
  -- same: a character walking perpendicular over a belt is displaced sideways
  -- for the tile-width of the crossing and then out the other side, which costs
  -- a few ticks, not a stall.
  --
  -- Getting this wrong makes the model incoherent rather than merely
  -- pessimistic. Charging the stall rate per crossed tile priced "step off the
  -- bus, walk clear, step back on" at 1000 ticks for the four belt tiles alone
  -- — so the planner preferred grinding 100 tiles up the bus, which is the
  -- exact behaviour the penalty was introduced to stop.
  local speed = belt_speed(belt)
  local alignment = speed > 1e-6 and (-contribution / speed) or 0
  if alignment < ESCAPE_MIN_OPPOSITION then
    -- Crossing: the belt's push is mostly sideways. Charge the sideways
    -- component as drag, without the along-axis amplification.
    return math.max(BASE_WALK_SPEED + contribution, 0.02)
  end

  return math.max(BASE_WALK_SPEED + contribution * OPPOSING_BELT_PENALTY, 0.004)
end

-- Walk a straight segment, sampling belts, and return what it costs in ticks
-- plus how many of those ticks are spent fighting a belt.
---@param surface LuaSurface
---@param from MapPosition
---@param to MapPosition
---@return number ticks, number opposed_ticks, number opposed_distance, number belt_distance
function Belts.segment_cost(surface, from, to)
  local delta = { x = to.x - from.x, y = to.y - from.y }
  local length = math.sqrt(delta.x * delta.x + delta.y * delta.y)
  if length < 1e-6 then return 0, 0, 0, 0 end

  local heading = { x = delta.x / length, y = delta.y / length }
  local steps = math.max(1, math.ceil(length / SAMPLE_STEP))
  local step_len = length / steps

  local ticks, opposed, opposed_distance, belt_distance = 0, 0, 0, 0
  for i = 0, steps - 1 do
    -- Sample the midpoint of each step: the endpoints of a segment often sit
    -- exactly on a tile boundary, where which belt you get is a coin flip.
    local t = (i + 0.5) * step_len
    local pos = { x = from.x + heading.x * t, y = from.y + heading.y * t }
    local belt = Belts.belt_at(surface, pos)
    local speed = effective_speed(belt, heading)
    local segment_ticks = step_len / speed
    ticks = ticks + segment_ticks
    -- Count only belts we are fighting head-on, using the same threshold the
    -- per-tick escape applies. A belt crossed at a steep angle costs a couple
    -- of ticks and is already priced into `ticks` above; flagging it as
    -- "opposed" as well would invite a detour that costs far more than the
    -- crossing it avoids. Planner and per-tick correction must agree on what
    -- counts as opposition, or they undo each other's decisions.
    if belt then
      belt_distance = belt_distance + step_len
      local contribution = belt_contribution(belt, heading)
      if contribution < 0
        and (-contribution / math.max(belt_speed(belt), 1e-6)) >= ESCAPE_MIN_OPPOSITION
      then
        opposed = opposed + segment_ticks
        opposed_distance = opposed_distance + step_len
      end
    end
  end

  return ticks, opposed, opposed_distance, belt_distance
end

-- Total cost of a waypoint list, starting from `origin`.
---@param surface LuaSurface
---@param origin MapPosition
---@param waypoints MapPosition[]
---@return number ticks, number opposed_ticks
function Belts.route_cost(surface, origin, waypoints)
  local ticks, opposed = 0, 0
  local prev = origin
  for _, wp in ipairs(waypoints) do
    local t, o = Belts.segment_cost(surface, prev, wp)
    ticks = ticks + t
    opposed = opposed + o
    prev = wp
  end
  return ticks, opposed
end

local function route_distance(origin, waypoints)
  local total, previous = 0, origin
  for _, waypoint in ipairs(waypoints) do
    local dx = waypoint.x - previous.x
    local dy = waypoint.y - previous.y
    total = total + math.sqrt(dx * dx + dy * dy)
    previous = waypoint
  end
  return total
end

-- Find the nearest position clear of belts, searching outward perpendicular to
-- travel. Returns nil if everything nearby is belt-covered.
---@param surface LuaSurface
---@param from MapPosition
---@param heading MapPosition
---@param max_offset number
---@param preferred? MapPosition
---@return MapPosition | nil
local function nearest_clear_offset(surface, from, heading, max_offset, preferred)
  -- Perpendicular to the heading, both ways.
  local perp = { x = -heading.y, y = heading.x }
  local best, best_distance_sq = nil, math.huge
  for offset = 1, max_offset do
    for _, sign in ipairs({ 1, -1 }) do
      local candidate = {
        x = from.x + perp.x * offset * sign,
        y = from.y + perp.y * offset * sign,
      }
      if not Belts.belt_at(surface, candidate)
        and surface.can_place_entity { name = "character", position = candidate }
      then
        if not preferred then return candidate end
        local dx = candidate.x - preferred.x
        local dy = candidate.y - preferred.y
        local distance_sq = dx * dx + dy * dy
        if distance_sq < best_distance_sq then
          best = candidate
          best_distance_sq = distance_sq
        end
      end
    end
  end
  return best
end

-- Look for a belt near the route that runs the way we are going and is fast
-- enough to be worth a detour. Returns the boarding and exit positions.
---@param surface LuaSurface
---@param from MapPosition
---@param to MapPosition
---@return MapPosition | nil board, MapPosition | nil exit
local function find_ride(surface, from, to)
  local delta = { x = to.x - from.x, y = to.y - from.y }
  local heading = normalize(delta)
  if not heading then return nil, nil end
  local direct_length = math.sqrt(delta.x * delta.x + delta.y * delta.y)

  -- Only bother for trips long enough that boarding overhead can amortize.
  if direct_length < RIDE_SEARCH_RADIUS * 2 then return nil, nil end

  local candidates = surface.find_entities_filtered {
    area = {
      { math.min(from.x, to.x) - RIDE_SEARCH_RADIUS, math.min(from.y, to.y) - RIDE_SEARCH_RADIUS },
      { math.max(from.x, to.x) + RIDE_SEARCH_RADIUS, math.max(from.y, to.y) + RIDE_SEARCH_RADIUS },
    },
    type = "transport-belt",
  }
  if #candidates == 0 then return nil, nil end

  -- Group belts by the lane they belong to: same direction, and same fixed
  -- coordinate on the axis they do not run along. A "lane" is what you can
  -- actually ride; individual tiles are not useful on their own.
  local lanes = {}
  for _, belt in ipairs(candidates) do
    local v = direction_vector(belt.direction)
    -- Only belts pointing broadly our way are worth considering.
    if (v.x * heading.x + v.y * heading.y) > 0.7 then
      local horizontal = math.abs(v.x) > 0.5
      local lane_key = string.format("%d:%s:%d", belt.direction,
        horizontal and "h" or "v",
        horizontal and belt.position.y or belt.position.x)
      local lane = lanes[lane_key]
      if not lane then
        lane = { belts = {}, horizontal = horizontal, direction = belt.direction,
                 speed = belt_speed(belt), min = nil, max = nil }
        lanes[lane_key] = lane
      end
      local along = horizontal and belt.position.x or belt.position.y
      if not lane.min or along < lane.min then lane.min = along end
      if not lane.max or along > lane.max then lane.max = along end
      lane.belts[#lane.belts + 1] = belt
      lane.fixed = horizontal and belt.position.y or belt.position.x
    end
  end

  local walk_ticks = direct_length / BASE_WALK_SPEED
  local best_board, best_exit, best_ticks = nil, nil, walk_ticks / RIDE_MIN_ADVANTAGE

  for _, lane in pairs(lanes) do
    local v = direction_vector(lane.direction)
    -- Project start and goal onto the lane axis, clamped to where belt exists.
    local start_along = lane.horizontal and from.x or from.y
    local goal_along = lane.horizontal and to.x or to.y

    -- Board as early as possible, leave as late as still helps.
    local board_along = math.max(lane.min, math.min(lane.max, start_along))
    local exit_along = math.max(lane.min, math.min(lane.max, goal_along))

    -- Never board *behind* the start relative to where we are going.
    --
    -- Clamping to the lane extent alone can put the boarding point on the far
    -- side of the start: the character then walks the wrong way to reach the
    -- on-ramp, and on a bus that walk is itself against the belts. Measured as
    -- a 2246-tick route where 1500 of those ticks were spent travelling east
    -- to board a westward belt.
    local goal_dir = goal_along - start_along
    if (board_along - start_along) * goal_dir < 0 then
      board_along = start_along
      -- If the lane does not reach back to us, it is not usable.
      if board_along < lane.min or board_along > lane.max then
        goto next_lane
      end
    end

    -- The lane has to carry us in the direction we want along its axis.
    local travel = exit_along - board_along
    local lane_forward = lane.horizontal and v.x or v.y
    if travel * lane_forward > 0 and math.abs(travel) > 1 then
      local board = lane.horizontal
        and { x = board_along, y = lane.fixed }
        or { x = lane.fixed, y = board_along }
      local exit_pos = lane.horizontal
        and { x = exit_along, y = lane.fixed }
        or { x = lane.fixed, y = exit_along }

      -- Cost = walk to the belt + ride it + walk from it to the goal.
      --
      -- The approach and departure walks are costed with `segment_cost` rather
      -- than as plain distance, because they routinely cross other belts — on
      -- a bus, the walk to an on-ramp can be straight up the opposing lanes,
      -- which a distance-only estimate scores as free and badly overvalues the
      -- ride.
      local to_board = Belts.segment_cost(surface, from, board)
      -- A rider does keep walking along the belt, so the speeds do add — but
      -- only while it stays on a one-tile-wide lane, which costs real time to
      -- hold. `RIDE_BOARDING_OVERHEAD` covers that; costing the ride itself at
      -- belt speed alone was too pessimistic and stopped rides ever winning,
      -- including the one case that measured as a genuine 2x improvement.
      local ride = math.abs(travel) / (BASE_WALK_SPEED + lane.speed)
      local from_exit = Belts.segment_cost(surface, exit_pos, to)
      local total = to_board + ride + from_exit + RIDE_BOARDING_OVERHEAD

      if total < best_ticks then
        best_ticks = total
        best_board = board
        best_exit = exit_pos
      end
    end
    ::next_lane::
  end

  return best_board, best_exit
end

-- Nearest point clear of the belt block containing `from`, leaving
-- perpendicular to the belt.
--
-- Walks outward across the block rather than stepping one tile, because on a
-- multi-lane bus one tile sideways just lands on the next belt. Picks the side
-- that does not send us backwards relative to travel, but falls back to the
-- other side when this one has no clear exit within reach.
---@param surface LuaSurface
---@param from MapPosition
---@param belt LuaEntity
---@param heading MapPosition
---@return MapPosition | nil
function Belts.belt_exit_point(surface, from, belt, heading)
  local belt_vec = direction_vector(belt.direction)
  local perp = { x = -belt_vec.y, y = belt_vec.x }
  local preferred = (perp.x * heading.x + perp.y * heading.y) >= 0 and 1 or -1

  for _, sign in ipairs({ preferred, -preferred }) do
    for offset = 1, 12 do
      local candidate = {
        x = from.x + perp.x * sign * offset,
        y = from.y + perp.y * sign * offset,
      }
      if not Belts.belt_at(surface, candidate)
        and surface.can_place_entity { name = "character", position = candidate }
      then
        -- One extra tile clear of the edge, so belt drift at the boundary does
        -- not immediately push the character back onto the block.
        return {
          x = from.x + perp.x * sign * (offset + 1),
          y = from.y + perp.y * sign * (offset + 1),
        }
      end
    end
  end
  return nil
end

-- Rewrite a pathfinder result to account for belts.
--
-- Returns a new waypoint list (positions only) and a summary of what changed.
-- The input path is left untouched so the caller can fall back to it, and so a
-- benchmark can compare the two directly.
---@param surface LuaSurface
---@param origin MapPosition
---@param path PathfinderWaypoint[]
---@param goal MapPosition
---@param opts { belt_ride: boolean }
---@return MapPosition[] waypoints, table info
function Belts.plan(surface, origin, path, goal, opts)
  local waypoints = {}
  for _, wp in ipairs(path) do
    waypoints[#waypoints + 1] = { x = wp.position.x, y = wp.position.y }
  end
  if #waypoints == 0 then
    return waypoints, { changed = false, reason = "empty path" }
  end

  local base_ticks, base_opposed = Belts.route_cost(surface, origin, waypoints)
  local info = {
    changed = false,
    base_ticks = base_ticks,
    base_opposed_ticks = base_opposed,
    detours = 0,
    ride = false,
  }

  -- Phase 0: if we are *starting* on a belt that opposes travel, the first
  -- thing to do is get off it.
  --
  -- This is a planned waypoint rather than a per-tick correction on purpose.
  -- Doing it reactively means the decision is recomputed from a position the
  -- belt is actively changing, which oscillates: measured as the same route
  -- taking 565, 2313, or never finishing, from identical input. Committing to
  -- an exit point up front makes the route deterministic.
  local start_belt = Belts.belt_at(surface, origin)
  if start_belt and start_belt.type == "transport-belt" then
    local first = waypoints[1]
    local heading = normalize({ x = first.x - origin.x, y = first.y - origin.y })
    if heading and belt_contribution(start_belt, heading) < 0 then
      local exit_point = Belts.belt_exit_point(surface, origin, start_belt, heading)
      if exit_point then
        info.start_exit = exit_point
      end
    end
  end

  -- Phase 1: step off belts that oppose us.
  --
  -- Walk the segments; wherever one is fighting a belt, insert a waypoint on
  -- clear ground beside it so the character leaves the belt rather than
  -- grinding down it. This is what produces "walk off the bus immediately"
  -- instead of being dragged along four lanes of it.
  local phase1_input = waypoints
  local adjusted = {}
  if info.start_exit then adjusted[1] = info.start_exit end

  -- Classify whole contiguous belt encounters before changing individual
  -- segments. A perpendicular crossing may contain a one-tile adverse kink in
  -- the pathfinder's staircase; treating that fragment in isolation creates a
  -- detour parallel to the belt that costs more than simply crossing it.
  local segment_samples = {}
  local prev = origin
  for index, wp in ipairs(waypoints) do
    local _, _, opposed_distance, belt_distance = Belts.segment_cost(surface, prev, wp)
    segment_samples[index] = {
      opposed_distance = opposed_distance,
      belt_distance = belt_distance,
    }
    prev = wp
  end

  local avoid_segment = {}
  local index = 1
  while index <= #segment_samples do
    if segment_samples[index].belt_distance <= 0 then
      index = index + 1
    else
      local run_start = index
      local run_opposed = 0
      while index <= #segment_samples and segment_samples[index].belt_distance > 0 do
        run_opposed = run_opposed + segment_samples[index].opposed_distance
        index = index + 1
      end
      if run_opposed >= MIN_AVOID_OPPOSED_DISTANCE then
        for run_index = run_start, index - 1 do
          avoid_segment[run_index] = segment_samples[run_index].opposed_distance > 0
        end
      end
    end
  end

  prev = origin
  for waypoint_index, wp in ipairs(waypoints) do
    local replaced = false
    if avoid_segment[waypoint_index] then
      local heading = normalize({ x = wp.x - prev.x, y = wp.y - prev.y })
      if heading then
        local clear = nearest_clear_offset(surface, prev, heading, 4, adjusted[#adjusted])
        if clear then
          -- Only worth it if leaving actually saves time: a one-tile brush
          -- against a slow belt is cheaper to walk through than to detour.
          local detour_ticks = Belts.route_cost(surface, prev, { clear, wp })
          local direct_ticks = Belts.segment_cost(surface, prev, wp)
          if detour_ticks < direct_ticks then
            adjusted[#adjusted + 1] = clear
            info.detours = info.detours + 1
            replaced = true
          end
        end
      end
    end
    -- Do not immediately append the raw on-belt waypoint after its lateral
    -- escape point. Doing both creates a clear/belt/clear/belt triangle for
    -- every raw pathfinder waypoint, which is the sawtooth route visible in
    -- play. Consecutive opposed segments now form one smooth off-belt lane;
    -- the first non-opposed waypoint (or the final goal below) rejoins the
    -- original route once.
    if not replaced then adjusted[#adjusted + 1] = wp end
    prev = wp
  end

  -- An opposed final segment may have replaced the goal with its clear point;
  -- always finish at the actual last waypoint.
  local final_wp = phase1_input[#phase1_input]
  local adjusted_last = adjusted[#adjusted]
  if final_wp and (not adjusted_last
      or math.abs(adjusted_last.x - final_wp.x) > 1e-6
      or math.abs(adjusted_last.y - final_wp.y) > 1e-6) then
    adjusted[#adjusted + 1] = final_wp
  end

  -- Judge the whole rewritten run, not each triangle in isolation. The local
  -- checks above choose plausible exits; this final check prevents their
  -- interaction from making the complete route slower than the input route.
  local input_ticks = Belts.route_cost(surface, origin, phase1_input)
  local adjusted_ticks = Belts.route_cost(surface, origin, adjusted)
  local input_distance = route_distance(origin, phase1_input)
  local adjusted_distance = route_distance(origin, adjusted)
  if info.detours > 0
    and adjusted_ticks * AVOID_MIN_GAIN < input_ticks
    and adjusted_distance <= input_distance * MAX_AVOID_DISTANCE_RATIO
      + AVOID_DISTANCE_ALLOWANCE
  then
    waypoints = adjusted
    info.changed = true
  else
    waypoints = phase1_input
    info.detours = 0
    info.start_exit = nil
    info.changed = false
  end

  -- Phase 2: ride a belt that is going our way, if one beats walking.
  if opts and opts.belt_ride then
    local board, exit_pos = find_ride(surface, origin, goal)
    if board and exit_pos then
      -- Keep the phase-0 exit in front of the ride. Replacing the whole
      -- waypoint list here would drop it, and the route would then start by
      -- walking down the bus to reach the on-ramp — the exact thing phase 0
      -- exists to prevent.
      local ride_route = {}
      if info.start_exit then ride_route[1] = info.start_exit end
      ride_route[#ride_route + 1] = board
      ride_route[#ride_route + 1] = exit_pos
      ride_route[#ride_route + 1] = { x = goal.x, y = goal.y }

      local ride_ticks = Belts.route_cost(surface, origin, ride_route)
      local current_ticks = Belts.route_cost(surface, origin, waypoints)
      if ride_ticks * RIDE_MIN_ADVANTAGE < current_ticks then
        waypoints = ride_route
        info.changed = true
        info.ride = true
        info.ride_board = board
        info.ride_exit = exit_pos
      end
    end
  end

  info.final_ticks = Belts.route_cost(surface, origin, waypoints)
  return waypoints, info
end

-- Per-tick belt lookup cache.
--
-- `escape_direction` runs every tick for every moving player, and an uncached
-- `find_entities_filtered` there is exactly the kind of per-tick API traffic
-- that shows up as multiplayer stutter. The character does not leave a tile
-- every tick, so the answer is keyed on the tile it is standing in and only
-- recomputed when that changes.
--
-- Module-local rather than `storage`: it is a pure function of world state, so
-- a stale entry after load is harmless and it must not enter the save.
local belt_cache = {}
local belt_cache_tick = nil

---@param surface LuaSurface
---@param position MapPosition
---@return LuaEntity | nil
local function cached_belt_at(surface, position)
  -- Cheap generational flush: keeping one tick of entries is enough to
  -- deduplicate the repeated lookups within a tick, and it bounds the table.
  if belt_cache_tick ~= game.tick then
    belt_cache = {}
    belt_cache_tick = game.tick
  end
  local key = string.format("%d:%d:%d", surface.index,
    math.floor(position.x), math.floor(position.y))
  local hit = belt_cache[key]
  if hit ~= nil then
    -- `false` is the memoized "no belt here" answer; nil means "not looked up".
    if hit == false then return nil end
    if hit.valid then return hit end
  end
  local belt = Belts.belt_at(surface, position)
  belt_cache[key] = belt or false
  return belt
end

-- Per-tick correction: if the character is on a belt pushing against travel,
-- the fastest thing to do is leave the belt sideways, not push through it.
--
-- Returns a direction to walk instead of the waypoint direction, or nil to
-- keep the normal heading.
---@param surface LuaSurface
---@param position MapPosition
---@param target MapPosition
---@param data PlayerMoveData
---@return MapPosition | nil escape_target
function Belts.escape_direction(surface, position, target, data)
  local plan = data.belt_plan

  -- Commitment window.
  --
  -- Without this the decision is recomputed from scratch every tick, and it
  -- oscillates: the character steps off the belt, the next tick's waypoint
  -- heading points back across it, it steps on again, and it thrashes there
  -- indefinitely. Measured as a 630 vs 3069 tick spread on identical input.
  --
  -- The window must run until the character actually *reaches the exit point*,
  -- not merely until it is off a belt for one tick. Ending it on "no belt
  -- underfoot" looks equivalent and is not: `belt_exit_point` aims one tile
  -- past the edge of the block, so the first clear tile is still adjacent to
  -- it. Releasing there hands control straight back to the waypoint heading,
  -- which on a bus points back along the lanes — so the character re-enters on
  -- the very next tick and the whole thing repeats.
  --
  -- That failure is not subtle in the numbers: a traced `main-bus-against` run
  -- oscillated on a 27-ticks-on / 1-tick-off cycle for 126 transitions, and the
  -- belt dragged the character 43 tiles *east* of its start while the goal lay
  -- 100 tiles west. Holding to the exit point is what makes the escape
  -- monotonic instead of a tug-of-war the belt wins.
  if plan and plan.escape_target and game.tick < (plan.escape_until or 0) then
    local dx = plan.escape_target.x - position.x
    local dy = plan.escape_target.y - position.y
    -- Arrived at the exit and genuinely clear: escape done, resume routing.
    -- Both conditions matter — "close to the target" alone can still be on a
    -- belt if the exit was clamped, and "off a belt" alone is the bug above.
    if (dx * dx + dy * dy) <= ESCAPE_ARRIVE_DIST_SQ
      and not cached_belt_at(surface, position)
    then
      data.belt_plan = nil
      -- Ask for a replan from where we actually ended up.
      --
      -- The remaining waypoints were computed from a position on the belt, so
      -- they lead back onto it — following them is what re-enters the block the
      -- escape just paid to leave. Escaping without replanning trades a fast
      -- oscillation for a slow one.
      data.belt_needs_replan = true
      return nil
    end
    return plan.escape_target
  end

  -- Timed out short of the exit. Drop the plan so a fresh one can be made from
  -- the current position rather than re-walking toward a target that has proven
  -- unreachable; replan too, since the route is equally stale either way.
  if plan and plan.escape_target then
    data.belt_plan = nil
    data.belt_needs_replan = true
  end

  local belt = cached_belt_at(surface, position)
  if not belt or belt.type ~= "transport-belt" then
    if plan then data.belt_plan = nil end
    return nil
  end

  local heading = normalize({ x = target.x - position.x, y = target.y - position.y })
  if not heading then return nil end

  local contribution = belt_contribution(belt, heading)
  -- Only bail out when the belt is genuinely costing us. A belt that helps, or
  -- one we are crossing perpendicular to, is fine to stay on.
  if contribution >= 0 then return nil end

  -- Distinguish a belt we are travelling *along* from one we are *crossing*.
  --
  -- `contribution < 0` alone conflates them. Walking west across a north-south
  -- belt has a small negative component, which looks like opposition but costs
  -- only the tile-width of the crossing — about 7 ticks. Escaping instead sends
  -- the character perpendicular, i.e. *along* the belt wall it was trying to
  -- get past, and the follow-up replan routes it straight back to the same
  -- crossing point.
  --
  -- That is not hypothetical: it pinned a traced run at x≈-31.5 for ~1700 of
  -- its 2473 ticks, sawtoothing y between -135 and -141 while the distance to
  -- goal sat unchanged at 28.3. Crossing costs a few ticks; refusing to cross
  -- cost more than half the route.
  --
  -- Escape only when the belt runs substantially *against* our heading, which
  -- is when grinding along it actually dominates the trip.
  local alignment = -contribution / math.max(belt_speed(belt), 1e-6)
  if alignment < ESCAPE_MIN_OPPOSITION then return nil end

  -- Mirror the planner's contiguous-exposure gate for its per-tick safety net.
  -- A one-waypoint adverse kink while crossing a belt is not enough reason to
  -- abandon the route and walk laterally along the belt block.
  local target_dx = target.x - position.x
  local target_dy = target.y - position.y
  local target_distance = math.sqrt(target_dx * target_dx + target_dy * target_dy)
  if target_distance * alignment < MIN_AVOID_OPPOSED_DISTANCE then return nil end

  -- Only fires when the planned route did not already handle this — the
  -- character was pushed onto a belt mid-route, or the route was planned before
  -- it drifted here. The planner is the primary mechanism; this is the net.
  local escape_target = Belts.belt_exit_point(surface, position, belt, heading)
  if not escape_target then return nil end

  -- Hold this decision for long enough to actually cross the belts. Generous:
  -- the window ends early as soon as the character is clear.
  local span = math.abs(escape_target.x - position.x) + math.abs(escape_target.y - position.y)
  data.belt_plan = {
    escape_target = escape_target,
    escape_until = game.tick + 60 + span * 20,
  }
  return escape_target
end

-- Is this position on a belt at all? Used by the benchmark's belt_ticks metric,
-- which is what actually proves a route avoided the bus rather than got lucky,
-- and by the per-tick waypoint hold.
--
-- Goes through the tick cache: this is called every tick per moving player, and
-- an uncached entity query there is the per-tick API traffic that shows up as
-- multiplayer stutter.
---@param surface LuaSurface
---@param position MapPosition
---@return boolean
function Belts.on_belt(surface, position)
  return cached_belt_at(surface, position) ~= nil
end

return Belts
