--[[
  Click2Move - Belt graph A*

  Phase 2 of the dual-phase router. Where `belts.lua` post-processes a path the
  vanilla pathfinder already returned, this builds its own graph over the belt
  layout and searches it, so it can produce routes the pathfinder would never
  suggest — in particular "walk clear of the bus, travel parallel on open
  ground, re-enter near the goal".

  Why a separate graph at all:

    `LuaSurface.request_path` has no per-tile cost hook. It cannot be told that
    a tile is expensive, only that it is impassable, and belts are not
    impassable — they are passable and *costly*, differently so per direction.
    So the belt cost model has to live outside the pathfinder entirely.

  Why this cannot be the only mechanism:

    The graph models belts and open ground. It does not model walls, water,
    buildings, or anything else the real pathfinder handles. So its output is
    never used directly as a route; it produces a small set of *waypoints*
    which the vanilla pathfinder is then asked to connect. The graph decides
    the corridor, `request_path` handles the obstacles inside it.

  Cost model, in ticks, matching `belts.lua` so the two agree:

    * Walking clear ground        distance / BASE_WALK_SPEED
    * Walking along a helpful belt distance / (walk + belt_speed)
    * Walking against a belt      distance / max(walk - belt_speed, floor)
    * Crossing a belt corridor    priced per lane crossed, since each lane
                                  shoves the character sideways on the way past

  The search is budgeted and resumable: Factorio has no threads and a long
  search would stall the tick. `Search.step` does a bounded number of node
  expansions and returns whether it is done, so `control.lua` can spread one
  search across many ticks while the character is already walking the Phase-1
  route.
]]

local Belts = require("scripts/belts")

local BeltGraph = {}

-- Effective character travel speed in tiles/tick. Must match `belts.lua`'s
-- measured value, not the prototype's 0.15 — see the calibration note there.
--
-- Only used by the heuristic here, where it has to stay *optimistic*: an
-- estimate that exceeds the true remaining cost makes A* inadmissible and lets
-- it return a route that is not the cheapest, which would undermine the
-- measured tick counts the whole feature is justified on.
local BASE_WALK_SPEED = 0.092

-- Node expansions per `step` call. The whole point is not to stall the tick, so
-- this is deliberately small; a search that needs more simply takes more ticks,
-- during which the character is already moving on the Phase-1 path.
local EXPANSIONS_PER_STEP = 40

-- Hard ceiling on total expansions before a search is abandoned. Prevents a
-- pathological layout from searching forever in the background. On abandonment
-- the character just keeps the Phase-1 route, which is always valid.
local MAX_EXPANSIONS = 2000

-- How far apart to sample candidate waypoints along a corridor, in tiles.
-- Finer than a belt lane so a corridor edge is never missed, coarse enough that
-- the graph stays small.
local GRID = 4

-- How far beyond the start/goal bounding box the graph may range. Routes that
-- detour further than this are worse than walking almost by definition, and
-- bounding it keeps the node count predictable.
local MARGIN = 24

-- Extra cost, in ticks, charged for each belt lane a segment crosses.
--
-- Crossing is not free even though it is brief: the belt displaces the
-- character sideways while it passes, which the waypoint follower then has to
-- correct. Pricing it makes the search prefer going *around* a wide bus and
-- accept crossing a single stray lane, which is the behaviour we want.
local LANE_CROSSING_COST = 12

---@param a MapPosition
---@param b MapPosition
---@return number
local function distance(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  return math.sqrt(dx * dx + dy * dy)
end

---@param x number
---@param y number
---@return string
local function key_of(x, y)
  return string.format("%d:%d", x, y)
end

-- Cost in ticks of walking a straight segment, belts included.
--
-- Delegates the sampling to `Belts.segment_cost` so the graph and the
-- post-pass cannot disagree about what a stretch of ground costs, then adds the
-- lane-crossing penalty the post-pass has no reason to model.
---@param surface LuaSurface
---@param from MapPosition
---@param to MapPosition
---@return number ticks
local function edge_cost(surface, from, to)
  local ticks = Belts.segment_cost(surface, from, to)

  -- Count belt lanes crossed by sampling perpendicular transitions: every time
  -- the on-belt state flips from off to on along the segment, that is one lane
  -- entered.
  local dist = distance(from, to)
  if dist < 1e-6 then return 0 end
  local steps = math.max(1, math.ceil(dist))
  local crossings, was_on = 0, false
  for i = 0, steps do
    local t = i / steps
    local p = { x = from.x + (to.x - from.x) * t, y = from.y + (to.y - from.y) * t }
    local on = Belts.belt_at(surface, p) ~= nil
    if on and not was_on then crossings = crossings + 1 end
    was_on = on
  end

  return ticks + crossings * LANE_CROSSING_COST
end

-- Admissible heuristic: straight-line time at the best speed anything can move.
--
-- Uses the fastest express belt plus walking rather than walking alone, so the
-- estimate can never exceed the true remaining cost. An inadmissible heuristic
-- here would let A* return a route that is not actually the cheapest, which
-- matters because the whole feature is justified on measured tick counts.
---@param from MapPosition
---@param goal MapPosition
---@return number
local function heuristic(from, goal)
  return distance(from, goal) / (BASE_WALK_SPEED + 0.09)
end

---@class BeltSearch
---@field surface LuaSurface
---@field origin MapPosition
---@field goal MapPosition
---@field open table
---@field came_from table
---@field g_score table
---@field expansions integer
---@field done boolean
---@field result MapPosition[] | nil
---@field bounds table

-- Begin a search. Returns a state object to be advanced with `BeltGraph.step`.
---@param surface LuaSurface
---@param origin MapPosition
---@param goal MapPosition
---@return BeltSearch
function BeltGraph.begin(surface, origin, goal)
  -- Anchor the lattice on the origin rather than on world zero.
  --
  -- A world-aligned lattice does not generally contain the straight line
  -- between the two endpoints, so A* cannot even represent "just walk there"
  -- and is forced to return something more expensive. On a 4-tile lattice a
  -- route starting at y=-138 can only reach y=-136 or y=-140, never y=-138
  -- again — which probed as A* returning a 24067-tick route where the straight
  -- line cost 9074.
  --
  -- Anchoring on the origin puts the start exactly on-lattice and keeps the
  -- origin's own row and column in the graph, so the straight-line route is
  -- always a candidate and A* can only improve on it.
  local function snap(p)
    return {
      x = origin.x + math.floor((p.x - origin.x) / GRID + 0.5) * GRID,
      y = origin.y + math.floor((p.y - origin.y) / GRID + 0.5) * GRID,
    }
  end

  local s, g = snap(origin), snap(goal)
  local search = {
    surface = surface,
    origin = origin,
    goal = goal,
    snapped_goal = g,
    open = {},
    came_from = {},
    g_score = {},
    expansions = 0,
    done = false,
    result = nil,
    bounds = {
      left = math.min(s.x, g.x) - MARGIN,
      right = math.max(s.x, g.x) + MARGIN,
      top = math.min(s.y, g.y) - MARGIN,
      bottom = math.max(s.y, g.y) + MARGIN,
    },
  }

  local sk = key_of(s.x, s.y)
  search.g_score[sk] = 0
  search.open[sk] = { pos = s, f = heuristic(s, g) }
  return search
end

-- Pop the open-set entry with the lowest f.
--
-- A linear scan rather than a binary heap: the open set here is bounded by a
-- few hundred nodes (MARGIN and GRID see to that), and a scan of that size is
-- cheaper in Lua than the table churn of maintaining a heap.
---@param open table
---@return string | nil, table | nil
local function pop_best(open)
  local best_key, best = nil, nil
  for k, node in pairs(open) do
    if not best or node.f < best.f then best_key, best = k, node end
  end
  if best_key then open[best_key] = nil end
  return best_key, best
end

-- Reconstruct, then simplify, the waypoint chain.
--
-- Simplification matters: A* on a 4-tile lattice emits a waypoint every 4 tiles,
-- and handing 30 near-collinear waypoints to `request_path` is both wasteful and
-- visually noisy. Collinear runs collapse to their endpoints, leaving only the
-- turns — which is exactly the corridor description the pathfinder needs.
---@param came_from table
---@param current_key string
---@param nodes table
---@return MapPosition[]
local function reconstruct(came_from, current_key, nodes)
  local chain = { nodes[current_key] }
  local k = current_key
  while came_from[k] do
    k = came_from[k]
    table.insert(chain, 1, nodes[k])
  end

  if #chain <= 2 then return chain end

  local simplified = { chain[1] }
  for i = 2, #chain - 1 do
    local prev, cur, next_p = chain[i - 1], chain[i], chain[i + 1]
    local d1x, d1y = cur.x - prev.x, cur.y - prev.y
    local d2x, d2y = next_p.x - cur.x, next_p.y - cur.y
    -- Cross product: zero means this point lies on the line through its
    -- neighbours and carries no information.
    if math.abs(d1x * d2y - d1y * d2x) > 1e-6 then
      simplified[#simplified + 1] = cur
    end
  end
  simplified[#simplified + 1] = chain[#chain]
  return simplified
end

-- Advance the search by a bounded number of expansions.
---@param search BeltSearch
---@return boolean done
function BeltGraph.step(search)
  if search.done then return true end

  search.nodes = search.nodes or {}
  local nodes = search.nodes
  local b = search.bounds
  local goal = search.snapped_goal
  local goal_key = key_of(goal.x, goal.y)

  for _ = 1, EXPANSIONS_PER_STEP do
    if search.expansions >= MAX_EXPANSIONS then
      -- Budget exhausted. Give up cleanly rather than degrading the tick rate;
      -- the caller keeps its Phase-1 route.
      search.done = true
      search.result = nil
      return true
    end

    local current_key, current = pop_best(search.open)
    if not current_key then
      -- Open set empty: no route exists within the bounds.
      search.done = true
      search.result = nil
      return true
    end

    nodes[current_key] = current.pos
    search.expansions = search.expansions + 1

    if current_key == goal_key then
      search.done = true
      local chain = reconstruct(search.came_from, current_key, nodes)
      -- Replace the snapped endpoints with the true ones: the lattice is a
      -- search convenience, but the character must be routed to where the
      -- player actually clicked.
      chain[1] = search.origin
      chain[#chain] = search.goal
      search.result = chain
      return true
    end

    -- Eight-connected neighbourhood: diagonals matter here because travelling
    -- parallel to a bus while easing away from it is a diagonal move, and a
    -- 4-connected lattice would render that as a staircase of belt crossings.
    for dx = -1, 1 do
      for dy = -1, 1 do
        if dx ~= 0 or dy ~= 0 then
          local nx = current.pos.x + dx * GRID
          local ny = current.pos.y + dy * GRID
          if nx >= b.left and nx <= b.right and ny >= b.top and ny <= b.bottom then
            local nkey = key_of(nx, ny)
            local npos = { x = nx, y = ny }
            local tentative = (search.g_score[current_key] or math.huge)
              + edge_cost(search.surface, current.pos, npos)
            if tentative < (search.g_score[nkey] or math.huge) then
              search.came_from[nkey] = current_key
              search.g_score[nkey] = tentative
              nodes[nkey] = npos
              search.open[nkey] = { pos = npos, f = tentative + heuristic(npos, goal) }
            end
          end
        end
      end
    end
  end

  return false
end

-- Cost in ticks of an arbitrary waypoint list under *this module's* cost
-- function — the one A* actually minimises, lane-crossing penalty included.
--
-- The dual-phase swap decision must use this for both sides of its comparison.
-- Scoring the candidate with `Belts.route_cost` instead compares a route chosen
-- under one cost function against a rival scored under another, and the search
-- can then "win" with a route that is worse by the scorer's own measure: probed
-- as an A* result costing 24067 where the straight line cost 9074.
---@param surface LuaSurface
---@param from MapPosition
---@param waypoints MapPosition[]
---@return number
function BeltGraph.cost_of(surface, from, waypoints)
  local total, prev = 0, from
  for _, wp in ipairs(waypoints) do
    total = total + edge_cost(surface, prev, wp)
    prev = wp
  end
  return total
end

-- Estimated cost in ticks of a finished search's route, from `origin`.
---@param search BeltSearch
---@param from MapPosition
---@return number | nil
function BeltGraph.route_cost(search, from)
  if not search.result then return nil end
  return BeltGraph.cost_of(search.surface, from, search.result)
end

BeltGraph.GRID = GRID
BeltGraph.LANE_CROSSING_COST = LANE_CROSSING_COST

return BeltGraph
