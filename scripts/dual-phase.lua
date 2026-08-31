--[[
  Click2Move - Dual-phase routing

  The user-facing requirement is "absolute fastest route, but no delay before
  the character starts walking". Those pull in opposite directions: the better
  route costs more to compute, and computing it up front is exactly the delay
  that must not happen.

  So the two are decoupled:

    Phase 1  The vanilla pathfinder request that already existed. The character
             starts walking the moment it resolves, as it always has. Nothing
             about the mod's responsiveness changes.

    Phase 2  A belt-graph A* (`belt-graph.lua`) started at the same moment and
             advanced a little each tick. When it finishes, its route is
             compared against continuing on the Phase-1 route, and swapped in
             only if it wins.

  The comparison is deliberately made **from the character's current position at
  the moment Phase 2 finishes**, not from where it started. By then the
  character has been walking for anywhere from a few ticks to a couple of
  seconds, and a belt-aware route that was better from the start line is often
  no longer better from here — the detour it recommends may now be behind the
  character. Comparing from the origin would swap in routes that make the trip
  longer while appearing, on paper, to have improved it.

  A swap is also suppressed when the win is marginal (see SWAP_MIN_GAIN): a
  visible re-route that saves a handful of ticks reads as the mod changing its
  mind for no reason, which is worse than the ticks are worth.
]]

local BeltGraph = require("scripts/belt-graph")
local Belts = require("scripts/belts")
local DebugCounters = require("scripts/debug-counters")

local DualPhase = {}

-- Phase 2 must beat continuing on the current route by at least this fraction
-- to be worth a visible re-route mid-walk.
local SWAP_MIN_GAIN = 1.15

-- Do not even start a Phase 2 search for trips shorter than this many tiles.
-- Short trips finish before a background search would, and re-routing a
-- character that is nearly there is pure disruption.
local MIN_TRIP_TILES = 24

-- Abandon a search that has not finished within this many ticks. By then the
-- character has usually travelled far enough that the answer is stale anyway.
local SEARCH_TIMEOUT_TICKS = 300

-- How many ticks of the remaining route must be spent fighting belts before a
-- swap is allowed at all.
--
-- This is the "does the graph know anything useful here" test. Below this the
-- route is a walking problem, not a belt problem, and the graph's blind spots
-- (walls, water, buildings) outweigh the one thing it models better.
--
-- 60 ticks is a second of being pushed around — enough to be worth re-routing
-- for, comfortably above the handful of ticks a route picks up from clipping a
-- belt corner. `around-wall` measured 17 belt_ticks total and must not qualify;
-- the bus routes measure hundreds to thousands and must.
local MIN_OPPOSED_TICKS_TO_SWAP = 60

-- A belt detour may be longer than the incumbent and still be faster, but an
-- extreme geometric detour is usually a stale search or a graph blind spot.
-- Allow substantial freedom plus a small fixed allowance for leaving a belt,
-- while rejecting routes that visibly send the character around the map.
local MAX_GEOMETRIC_DETOUR = 1.75
local GEOMETRIC_DETOUR_ALLOWANCE = 8

---@param a MapPosition
---@param b MapPosition
---@return number
local function distance(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  return math.sqrt(dx * dx + dy * dy)
end

---@param from MapPosition
---@param waypoints MapPosition[]
---@return number
local function route_distance(from, waypoints)
  local total, previous = 0, from
  for _, waypoint in ipairs(waypoints) do
    total = total + distance(previous, waypoint)
    previous = waypoint
  end
  return total
end

-- A background search starts from the character's old position, but the
-- character keeps walking while it runs. Choose the cheapest suffix from the
-- current position instead of retaining a stale prefix that can send the
-- character back to where the search began.
---@param surface LuaSurface
---@param here MapPosition
---@param route MapPosition[]
---@return MapPosition[] candidate, number cost
local function rebase_candidate(surface, here, route)
  local best, best_cost, best_distance = {}, math.huge, math.huge

  for first = 1, #route do
    local suffix = {}
    for i = first, #route do suffix[#suffix + 1] = route[i] end
    local cost = BeltGraph.cost_of(surface, here, suffix)
    local geometry = route_distance(here, suffix)
    if cost < best_cost or (math.abs(cost - best_cost) < 1e-6 and geometry < best_distance) then
      best = suffix
      best_cost = cost
      best_distance = geometry
    end
  end

  return best, best_cost
end

-- Start a Phase 2 search for a goal, if one is worth starting.
--
-- Called when a Phase-1 path arrives. Never blocks: this only builds the search
-- state, which is then advanced a slice at a time by `DualPhase.tick`.
---@param player LuaPlayer
---@param data PlayerMoveData
---@param goal_data MoveGoal
function DualPhase.maybe_start(player, data, goal_data)
  local entity = data.move_entity or player.vehicle or player.character
  -- Vehicles are not pushed around by belts, so there is nothing to optimise.
  if not entity or not entity.valid or entity.type ~= "character" then return end
  if goal_data.belt_search or goal_data.belt_search_done then return end

  if distance(entity.position, goal_data.position) < MIN_TRIP_TILES then return end

  goal_data.belt_search = BeltGraph.begin(
    entity.surface, entity.position, goal_data.position)
  goal_data.belt_search_started = game.tick
  DebugCounters.count("belt_searches")
end

local function remaining_positions(data, goal_data)
  local remaining = {}
  for i = data.current_waypoint or 1, #(goal_data.path or {}) do
    local wp = goal_data.path[i]
    if wp and wp.position then remaining[#remaining + 1] = wp.position end
  end
  return remaining
end

-- Apply the common swap gates to either the graph corridor or its subsequently
-- pathfinder-connected route. Running them twice is intentional: connecting
-- around real obstacles can erase the graph's predicted win, and the character
-- continues moving while those asynchronous requests resolve.
local function candidate_is_better(entity, data, goal_data, candidate)
  local here = entity.position
  local remaining = remaining_positions(data, goal_data)
  if #remaining == 0 or #candidate == 0 then return false end

  local candidate_cost = BeltGraph.cost_of(entity.surface, here, candidate)
  local current_cost
  if goal_data.belt_info and goal_data.belt_info.ride then
    current_cost = Belts.route_cost(entity.surface, here, remaining)
  else
    current_cost = BeltGraph.cost_of(entity.surface, here, remaining)
  end

  if candidate_cost * SWAP_MIN_GAIN >= current_cost then return false end

  local opposed = select(2, Belts.route_cost(entity.surface, here, remaining))
  if opposed < MIN_OPPOSED_TICKS_TO_SWAP then return false end

  local current_distance = route_distance(here, remaining)
  local candidate_distance = route_distance(here, candidate)
  return current_distance <= 1e-6
    or candidate_distance <= current_distance * MAX_GEOMETRIC_DETOUR
      + GEOMETRIC_DETOUR_ALLOWANCE
end

-- Public rebasing hook for the pathfinder connector. The graph search and the
-- validation requests are asynchronous, so both can acquire stale prefixes.
function DualPhase.rebase_route(surface, here, route)
  return rebase_candidate(surface, here, route)
end

-- Install a fully pathfinder-connected candidate, after rechecking it from the
-- character's latest position. Sparse graph points are never installed here:
-- callers must provide the complete concatenated pathfinder result.
function DualPhase.try_install_validated(player, data, goal_data, candidate)
  local entity = data.move_entity or player.vehicle or player.character
  if not entity or not entity.valid or not candidate_is_better(entity, data, goal_data, candidate) then
    DebugCounters.count("belt_swaps_rejected")
    return false
  end

  local rebuilt = {}
  for _, pos in ipairs(candidate) do rebuilt[#rebuilt + 1] = { position = pos } end
  goal_data.path = rebuilt
  goal_data.path_id = nil
  goal_data.belt_info = nil
  goal_data.belt_validation = nil
  data.current_waypoint = 1
  data.closest_dist_to_goal = 999999
  data.no_progress_ticks = 0
  DebugCounters.count("belt_swaps")
  return true
end

-- Advance the active search and submit its winning corridor for pathfinder
-- validation. The connector owns the asynchronous leg requests and calls
-- `try_install_validated` only after every segment is traversable.
--
-- Returns true only if a connected route was installed synchronously (the
-- normal connector is asynchronous, so this is normally false).
---@param player LuaPlayer
---@param data PlayerMoveData
---@param connect_candidate? fun(player: LuaPlayer, data: PlayerMoveData, goal_data: MoveGoal, candidate: MapPosition[]): boolean
---@return boolean swapped
function DualPhase.tick(player, data, connect_candidate)
  local goal_data = data.goals and data.goals[1]
  if not goal_data then return false end
  local search = goal_data.belt_search
  if not search then return false end

  local entity = data.move_entity or player.vehicle or player.character
  if not entity or not entity.valid then
    goal_data.belt_search = nil
    return false
  end

  if game.tick - (goal_data.belt_search_started or 0) > SEARCH_TIMEOUT_TICKS then
    goal_data.belt_search = nil
    goal_data.belt_search_done = true
    return false
  end

  -- Errors here must never take the move down with them: Phase 2 is an
  -- optimisation, and the Phase-1 route is always a valid answer.
  local ok, done = pcall(BeltGraph.step, search)
  if not ok then
    goal_data.belt_search = nil
    goal_data.belt_search_done = true
    return false
  end
  if not done then return false end

  goal_data.belt_search = nil
  goal_data.belt_search_done = true

  if not search.result or #search.result < 2 then return false end

  -- Re-evaluate from where the character actually is now, not from where the
  -- search started. This is the whole point of the phase split.
  local here = entity.position

  local candidate = rebase_candidate(entity.surface, here, search.result)
  if #candidate == 0 then return false end

  if not candidate_is_better(entity, data, goal_data, candidate) then
    DebugCounters.count("belt_swaps_rejected")
    return false
  end

  if not connect_candidate or not connect_candidate(player, data, goal_data, candidate) then
    DebugCounters.count("belt_swaps_rejected")
    return false
  end
  return false
end

-- Drop any in-flight search for a goal. Called when a goal is cancelled or
-- completed so a stale search cannot rewrite the next goal's route.
---@param goal_data MoveGoal
function DualPhase.cancel(goal_data)
  if not goal_data then return end
  goal_data.belt_search = nil
  goal_data.belt_search_done = nil
  goal_data.belt_search_started = nil
  goal_data.belt_validation = nil
end

DualPhase.SWAP_MIN_GAIN = SWAP_MIN_GAIN
DualPhase.MIN_TRIP_TILES = MIN_TRIP_TILES
DualPhase.MAX_GEOMETRIC_DETOUR = MAX_GEOMETRIC_DETOUR

return DualPhase
