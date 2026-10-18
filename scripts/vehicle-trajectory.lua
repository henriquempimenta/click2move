-- A reference trajectory inside the corridor of a pathfinder polyline.
-- Straight grid runs become one segment. Corners get tangent circular fillets
-- only when their clearance is known; half-leg trims cannot overlap. Where a
-- corner allows, a racing line across both sides of the corridor replaces its
-- fillet, and one curve replaces a lane shift's two corners. Each stays within
-- the half legs of its corners and is certified against the original path.
-- A bounded refit then shares space across neighboring bends, and a terminal
-- circle can stop at the goal without preserving the final waypoint heading.
local Trajectory = {}
-- Saved arc-length anchors belong to a particular reference construction.
-- Bump when that construction changes, so old anchors are projected afresh.
Trajectory.REVISION = 3

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local TAU = 2 * math.pi
local PROJECT_NEIGHBORS = 2
local SIMPLIFY_NODES = 64
local SIMPLIFY_WORK = 2048
local MERGE_CORNERS = 8
local MERGE_EDGES = 64
local MERGE_WORK = 8192
-- Racing lines are built to this share of the clearance; the rest absorbs
-- the certificate's sampling interval.
local RACING_SHARE = .9
-- A racing line replaces a fillet only when it is clearly wider.
local RACING_GAIN = 1.05
local RACING_WORK = 2048
-- At most this many corners are smoothed by one curve across them.
local BRIDGE_CORNERS = 4
local BRIDGE_WORK = 16384
local POLISH_WORK = 8192
local TERMINAL_WORK = 1024
local TERMINAL_PIECES = 16

-- Deterministic weighted work, shared by all optional refinement stages.
-- Elapsed-time cutoffs could produce different curves on multiplayer peers.
-- Required linear construction still finishes when refinement runs out.
Trajectory.WORK_LIMIT = 40960
local function budget(limit, parent)
  local work = {limit = limit, remaining = limit, used = 0, parent = parent}
  work.build = parent and parent.build or work
  return work
end
local function active(work) return not work.exhausted and work.remaining > 0 end
local function spend(work, cost)
  if work.exhausted or work.remaining < cost then work.exhausted = true; return false end
  if work.parent and not spend(work.parent, cost) then work.exhausted = true; return false end
  work.remaining, work.used = work.remaining - cost, work.used + cost
  return true
end
local function construct(work, cost)
  if not spend(work, cost) then return false end
  local build = work.build or work
  build.attempts = (build.attempts or 0) + 1
  return true
end
local certify_pieces

local function copy(p) return {x = p.x, y = p.y} end
local function distance(a, b)
  return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

local function segment_distance_sq(p, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local length = dx * dx + dy * dy
  local t = length > 0 and clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0, 1) or 0
  return (p.x - a.x - t * dx) ^ 2 + (p.y - a.y - t * dy) ^ 2
end

local function segment_at(plan, s)
  local low, high = 1, #plan.segments
  while low < high do
    local middle = math.floor((low + high) / 2)
    if plan.segments[middle].end_s < s then low = middle + 1 else high = middle end
  end
  return low
end

local function segment_at_source(plan, source)
  local low, high = 1, #plan.segments
  while low < high do
    local middle = math.floor((low + high) / 2)
    if plan.segments[middle].path_end < source then low = middle + 1 else high = middle end
  end
  return low
end

local function fraction(value, low, high)
  return high > low and clamp((value - low) / (high - low), 0, 1) or 0
end

-- Original path distance corresponding to reference distance s. The source
-- distance traverses the trimmed original subpath linearly along its arc.
function Trajectory.source_distance(plan, s)
  if #plan.segments == 0 then return 0 end
  s = clamp(s, 0, plan.total_length)
  local segment = plan.segments[segment_at(plan, s)]
  local t = fraction(s, segment.start_s, segment.end_s)
  return segment.path_start + t * (segment.path_end - segment.path_start)
end

-- Reference distance corresponding to a cumulative original path distance.
function Trajectory.at_source(plan, source)
  if #plan.segments == 0 then return 0 end
  source = clamp(source, 0, plan.path_distances[#plan.path_distances] or 0)
  local segment = plan.segments[segment_at_source(plan, source)]
  local t = fraction(source, segment.path_start, segment.path_end)
  return segment.start_s + t * (segment.end_s - segment.start_s)
end

local function append(plan, segment, length)
  if length <= 0 then return end
  segment.start_s, segment.end_s = plan.total_length, plan.total_length + length
  segment.length = length
  plan.total_length = segment.end_s
  plan.segments[#plan.segments + 1] = segment
end

local function append_line(plan, a, b, source_start, source_end, first, last)
  local length = distance(a, b)
  -- Racing lines meet at a leg's middle, computed from either end; a
  -- rounding-sized line between them would have an arbitrary heading.
  if length <= 1e-9 then return end
  append(plan, {kind = "line", a = copy(a), b = copy(b),
    tangent = {x = (b.x - a.x) / length, y = (b.y - a.y) / length},
    path_start = source_start, path_end = source_end,
    source_start = first, source_end = last}, length)
end

local function collapse(path, distances)
  local points = {}
  for index, waypoint in ipairs(path) do
    local p = waypoint.position
    local last = points[#points]
    if last and last.position.x == p.x and last.position.y == p.y then
      -- Retain the latest index for repeated endpoints without a zero leg.
      last.index, last.source = index, distances[index]
    else
      local current
      while #points >= 2 do
        local a, b = points[#points - 1].position, points[#points].position
        local ax, ay, bx, by = b.x - a.x, b.y - a.y, p.x - b.x, p.y - b.y
        -- Exact collinearity never removes a real shallow corner at a large
        -- coordinate or enlarges a zero-clearance path's corridor.
        if ax * by - ay * bx ~= 0 or ax * bx + ay * by <= 0 then break end
        current = points[#points]
        points[#points] = nil
      end
      if current then
        current.position.x, current.position.y = p.x, p.y
        current.index, current.source = index, distances[index]
      else current = {position = copy(p), index = index, source = distances[index]} end
      points[#points + 1] = current
    end
  end
  for index, p in ipairs(points) do p.original_index = index end
  return points
end

-- Bounded Douglas-Peucker chunks replace short grid staircases by chords.
-- The original subpath stays inside the convex tube of each accepted chord.
-- Its projection continuously covers that chord from end to end, so every
-- chord point is also within the recorded error of the original subpath.
local function simplify(points, clearance, protected, work)
  if #points < 3 or clearance <= 0 then return points end
  protected = protected or {}
  for index = 2, #points - 1 do
    local a, b, c = points[index - 1].position, points[index].position, points[index + 1].position
    local ax, ay, bx, by = b.x - a.x, b.y - a.y, c.x - b.x, c.y - b.y
    if ax * by - ay * bx == 0 and ax * bx + ay * by < 0 then
      protected[index - 1], protected[index], protected[index + 1] = true, true, true
    end
  end
  local result = {points[1]}
  for first = 1, #points - 1, SIMPLIFY_NODES do
    local stack = {{first, math.min(first + SIMPLIFY_NODES, #points), true}}
    while #stack > 0 do
      local range = table.remove(stack)
      local from, to = range[1], range[2]
      -- One chord scan per fixed-size chunk is linear preprocessing. Only
      -- recursive refinement costs extra search work. Keep exact legs when
      -- that work runs out, but still compress later easy chunks in one pass.
      if not range[3] and not spend(work, to - from + 2) then
        for index = from + 1, to do result[#result + 1] = points[index] end
      else
        local a, b = points[from].position, points[to].position
        local maximum, split, forced = 0, nil, nil
        for index = from + 1, to - 1 do
          local error = segment_distance_sq(points[index].position, a, b)
          if error > maximum then maximum, split = error, index end
          if protected[index] then forced = index; break end
        end
        if not forced and a.x == b.x and a.y == b.y and to > from + 1 then
          forced = split or math.floor((from + to) / 2)
        end
        if forced or maximum > clearance * clearance then
          split = forced or split
          stack[#stack + 1], stack[#stack + 2] = {split, to}, {from, split}
        else
          local endpoint = points[to]
          result[#result + 1] = {position = endpoint.position, index = endpoint.index,
            source = endpoint.source, original_index = endpoint.original_index,
            incoming_error = math.sqrt(maximum)}
        end
      end
    end
  end
  return result
end

local function arc_position(segment, t)
  if t == 0 then return copy(segment.a) elseif t == 1 then return copy(segment.b) end
  local angle = math.abs(segment.sweep) * t
  local sign = segment.sweep > 0 and 1 or -1
  -- Local tangent coordinates avoid subtracting two huge circle coordinates
  -- when a shallow turn has a very large radius.
  local along = segment.radius * math.sin(angle)
  local across = segment.radius * 2 * math.sin(angle / 2) ^ 2 * sign
  local ux, uy = segment.tangent.x, segment.tangent.y
  return {x = segment.a.x + ux * along - uy * across,
    y = segment.a.y + uy * along + ux * across}
end

local function fillet(before, vertex, after, clearance)
  local a, b, c = before.position, vertex.position, after.position
  local incoming, outgoing = distance(a, b), distance(b, c)
  local ux, uy = (b.x - a.x) / incoming, (b.y - a.y) / incoming
  local vx, vy = (c.x - b.x) / outgoing, (c.y - b.y) / outgoing
  local cross, dot = ux * vy - uy * vx, clamp(ux * vx + uy * vy, -1, 1)
  local sweep = atan2(cross, dot)
  local angle = math.abs(sweep)
  -- A reversal has no unique inside and no nonzero tangent fillet.
  if angle == 0 or math.pi - angle < 0.00000001 then return nil end
  local tangent_half = math.tan(angle / 2)
  -- On the first half of the arc the nearest incoming-leg projection lies
  -- between its tangent point and the vertex; on the second half the outgoing
  -- leg does. The maximum distance to that nearer leg is R*(1-cos(angle/2)).
  local radius_limit = clearance / (2 * math.sin(angle / 4) ^ 2)
  local trim = math.min(radius_limit * tangent_half, incoming / 2, outgoing / 2)
  local radius = trim / tangent_half
  if radius <= 0 or radius == math.huge then return nil end
  local sign = sweep > 0 and 1 or -1
  local start = {x = b.x - ux * trim, y = b.y - uy * trim}
  local finish = {x = b.x + vx * trim, y = b.y + vy * trim}
  local center = {x = start.x - uy * sign * radius, y = start.y + ux * sign * radius}
  return {kind = "arc", a = start, b = finish, center = center, radius = radius,
    start_angle = atan2(start.y - center.y, start.x - center.x), sweep = sweep,
    tangent = {x = ux, y = uy}, trim = trim,
    path_start = vertex.source - trim / incoming * (vertex.source - before.source),
    path_end = vertex.source + trim / outgoing * (after.source - vertex.source),
    source_start = before.index, source_end = after.index}
end

-- A distance to a finite polyline is 1-Lipschitz. Every arc point is at most
-- half a sample interval's arc length from a sample; the sampled maximum plus
-- that half interval therefore bounds the ENTIRE arc, not just its samples.
-- Check against the original, unsimplified legs, so DP error cannot be spent
-- again. A fixed per-plan work budget rejects uncertain or expensive merges.
local function certify(arc, original, first, last, clearance, work)
  local safe, bound = certify_pieces({arc}, original, first, last, clearance, work)
  if safe then arc.certificate_error = bound end
  return safe
end

local function merged_fillet(points, corners, original, first, last, clearance, work)
  if not construct(work, 8) then return nil end
  local sweep, largest = 0, 0
  for index = first, last do
    local corner = corners[index]
    if corner == nil then
      if not construct(work, 4) then return nil end
      corner = fillet(points[index - 1], points[index], points[index + 1], clearance)
      corners[index] = corner or false
    end
    if not corner or sweep * corner.sweep < 0 then return nil end
    sweep, largest = sweep + corner.sweep, math.max(largest, corner.radius)
  end
  local angle = math.abs(sweep)
  if angle < .00001 or angle >= math.pi - .00001 then return nil end
  local before, entry, exit, after = points[first - 1], points[first], points[last], points[last + 1]
  local a, b, c, d = before.position, entry.position, exit.position, after.position
  local incoming, outgoing = distance(a, b), distance(c, d)
  local ux, uy, vx, vy = (b.x - a.x) / incoming, (b.y - a.y) / incoming,
    (d.x - c.x) / outgoing, (d.y - c.y) / outgoing
  local cross = ux * vy - uy * vx
  local dx, dy = c.x - b.x, c.y - b.y
  local to_vertex = (dx * vy - dy * vx) / cross
  local from_vertex = (ux * dy - uy * dx) / cross
  if to_vertex < 0 or from_vertex < 0 then return nil end
  local tangent_half = math.tan(angle / 2)
  local radius_limit = clearance / (2 * math.sin(angle / 4) ^ 2)
  -- Try the full radius, then leave a little more room for certification.
  for _, share in ipairs({1, .95}) do
    local trim = math.min(radius_limit * share * tangent_half,
      to_vertex + incoming / 2, from_vertex + outgoing / 2)
    local radius = trim / tangent_half
    -- Endpoints must stay on the original exterior chords. Half-leg trims
    -- leave their other halves to neighboring fillets without overlap.
    if trim >= math.max(to_vertex, from_vertex) and radius > largest then
      local sign = sweep > 0 and 1 or -1
      local entry_trim = trim == to_vertex + incoming / 2 and incoming / 2 or trim - to_vertex
      local exit_trim = trim == from_vertex + outgoing / 2 and outgoing / 2 or trim - from_vertex
      local start = {x = b.x - ux * entry_trim, y = b.y - uy * entry_trim}
      local finish = {x = c.x + vx * exit_trim, y = c.y + vy * exit_trim}
      local center = {x = start.x - uy * sign * radius, y = start.y + ux * sign * radius}
      local arc = {kind = "arc", a = start, b = finish, center = center, radius = radius,
        start_angle = atan2(start.y - center.y, start.x - center.x), sweep = sweep,
        tangent = {x = ux, y = uy}, merged_corners = last - first + 1, last_corner = last,
        path_start = entry.source - entry_trim / incoming * (entry.source - before.source),
        path_end = exit.source + exit_trim / outgoing * (after.source - exit.source),
        source_start = before.index, source_end = after.index}
      if certify(arc, original, before.original_index, after.original_index, clearance, work) then return arc end
    end
  end
end

local function merge_corners(points, corners, original, clearance, work)
  local first = 2
  while first < #points - 1 and active(work) do
    local merged
    for last = math.min(first + MERGE_CORNERS - 1, #points - 1), first + 1, -1 do
      merged = merged_fillet(points, corners, original, first, last, clearance, work)
      if merged then break end
    end
    if merged then corners[first], first = merged, merged.last_corner + 1 else first = first + 1 end
  end
end

local function arc_from(start, tangent, radius, sweep)
  local sign = sweep > 0 and 1 or -1
  local center = {x = start.x - tangent.y * sign * radius, y = start.y + tangent.x * sign * radius}
  local arc = {kind = "arc", a = copy(start), center = center, radius = radius,
    start_angle = atan2(start.y - center.y, start.x - center.x), sweep = sweep, tangent = copy(tangent)}
  local along, across = radius * math.sin(math.abs(sweep)), radius * 2 * math.sin(math.abs(sweep) / 2) ^ 2 * sign
  arc.b = {x = start.x + tangent.x * along - tangent.y * across, y = start.y + tangent.y * along + tangent.x * across}
  local cosine, sine = math.cos(sweep), math.sin(sweep)
  return arc, {x = tangent.x * cosine - tangent.y * sine, y = tangent.y * cosine + tangent.x * sine}
end

-- Whether a racing arc of radius R fits the half leg: the gentle arc that
-- swings out from the centreline at the leg's middle must be no tighter
-- than R where it meets the main circle.
local function racing_fits(radius, half, clearance, tangent_half)
  local run = half - (radius - clearance) * tangent_half
  return run >= 0 and run * run >= 4 * radius * clearance - clearance * clearance
end

-- A racing line round one corner. The fillet above cuts only the inside of
-- the corner; the corridor is as wide on the outside. Swinging out to its
-- outer edge before and after the corner, and in to the inner edge at the
-- apex, roughly doubles the radius. In local coordinates, the corner at the
-- origin turning left by φ from the +x axis, the main circle touches the
-- outer edge of both legs and passes within the clearance of the corner:
-- R(1 - cos(φ/2)) <= 2c, centred at (-(R - c) tan(φ/2), R - c). A gentle arc
-- turning the other way joins it from the middle of each leg, tangent to the
-- centreline there, so the racing line never overlaps a neighbouring corner.
-- Those arcs stay within c of their own leg, beside it; the main arc is
-- certified against the original path.
local function racing(before, vertex, after, clearance, certified_clearance, original, work, minimum)
  if not construct(work, 24) then return nil end
  if clearance <= 0 then return nil end
  local a, b, c = before.position, vertex.position, after.position
  local incoming, outgoing = distance(a, b), distance(b, c)
  local ux, uy = (b.x - a.x) / incoming, (b.y - a.y) / incoming
  local vx, vy = (c.x - b.x) / outgoing, (c.y - b.y) / outgoing
  local cross, dot = ux * vy - uy * vx, clamp(ux * vx + uy * vy, -1, 1)
  local turn = math.abs(atan2(cross, dot))
  if turn < 0.001 or math.pi - turn < 0.001 then return nil end
  local sign = cross > 0 and 1 or -1
  -- Leave room for the certificate's sampling interval.
  local room = clearance * RACING_SHARE
  local tangent_half = math.tan(turn / 2)
  local half_in, half_out = incoming / 2, outgoing / 2
  local function fits(radius)
    return racing_fits(radius, half_in, room, tangent_half) and racing_fits(radius, half_out, room, tangent_half)
  end
  local low, high = math.max(minimum * RACING_GAIN, room), 2 * room / (2 * math.sin(turn / 4) ^ 2)
  if low >= high or not fits(low) then return nil end
  if fits(high) then low = high else
    for _ = 1, 40 do
      if not spend(work, 1) then return nil end
      local middle = (low + high) / 2
      if fits(middle) then low = middle else high = middle end
    end
  end
  local radius = low
  -- Gentle arcs as wide as the half legs allow, and the angle each swings out.
  local function swing(half)
    local run = half - (radius - room) * tangent_half
    local gentle = (run * run - 2 * radius * room + room * room) / (2 * room)
    return gentle, math.pi / 2 - atan2(radius - room + gentle, run)
  end
  local entry_radius, entry_angle = swing(half_in)
  local exit_radius, exit_angle = swing(half_out)
  local start = {x = b.x - ux * half_in, y = b.y - uy * half_in}
  local first, heading = arc_from(start, {x = ux, y = uy}, entry_radius, -sign * entry_angle)
  local main
  main, heading = arc_from(first.b, heading, radius, sign * (turn + entry_angle + exit_angle))
  local last = arc_from(main.b, heading, exit_radius, -sign * exit_angle)
  if not certify(main, original, before.original_index, after.original_index, certified_clearance, work) then
    return nil
  end
  -- Map each joint to where it projects onto its own leg, so the original
  -- path distance stays close to the curve and the apex maps to the corner.
  local function source_in(back) return vertex.source - back / incoming * (vertex.source - before.source) end
  local function source_out(ahead) return vertex.source + ahead / outgoing * (after.source - vertex.source) end
  local entry = source_in(math.max(0, -((first.b.x - b.x) * ux + (first.b.y - b.y) * uy)))
  local exit = source_out(math.max(0, (main.b.x - b.x) * vx + (main.b.y - b.y) * vy))
  first.path_start, first.path_end = source_in(half_in), entry
  main.path_start, main.path_end = entry, exit
  last.path_start, last.path_end = exit, source_out(half_out)
  for _, piece in ipairs({first, main, last}) do piece.source_start, piece.source_end = before.index, after.index end
  return {kind = "racing", pieces = {first, main, last}, a = start, b = last.b, radius = radius,
    path_start = first.path_start, path_end = last.path_end}
end

local function line_piece(a, b)
  local length = distance(a, b)
  return {kind = "line", a = copy(a), b = copy(b), length = length,
    tangent = length > 0 and {x = (b.x - a.x) / length, y = (b.y - a.y) / length} or {x = 0, y = 0}}
end

local function piece_length(piece)
  return piece.kind == "line" and piece.length or piece.radius * math.abs(piece.sweep)
end

local function piece_point(piece, t)
  if piece.kind == "arc" then return arc_position(piece, t) end
  return {x = piece.a.x + (piece.b.x - piece.a.x) * t, y = piece.a.y + (piece.b.y - piece.a.y) * t}
end

-- Proves every point of the pieces lies within the clearance of the original
-- legs first..last. Distance to a polyline is 1-Lipschitz, so an interval of
-- length h whose ends are d1 and d2 away stays within (d1 + d2 + h) / 2.
-- Intervals are halved where that bound is too loose, within a work budget.
certify_pieces = function(pieces, original, first, last, clearance, work)
  local edges = last - first
  if edges <= 0 or edges > MERGE_EDGES or clearance <= 0 then return false end
  local function sample(piece, t)
    -- Trigonometry, temporary vectors and distance checks all count.
    if not spend(work, edges + 4) then return nil end
    local point, values, nearest = piece_point(piece, t), {}, math.huge
    for edge = first, last - 1 do
      local d = segment_distance_sq(point, original[edge].position, original[edge + 1].position)
      values[edge - first + 1], nearest = d, math.min(nearest, d)
    end
    values.nearest = math.sqrt(nearest)
    return values
  end
  local maximum = 0
  for _, piece in ipairs(pieces) do
    if not spend(work, 4) then return false end
    local length = piece_length(piece)
    local magnitude = math.max(math.abs(piece.a.x), math.abs(piece.a.y), math.abs(piece.b.x), math.abs(piece.b.y),
      piece.radius or 0)
    local roundoff = 64 * 2.220446049250313e-16 * (1 + magnitude)
    local allowance = clearance - roundoff
    local a, b = sample(piece, 0), sample(piece, 1)
    if not a or not b or a.nearest > allowance or b.nearest > allowance then return false end
    local stack = {{0, 1, a, b}}
    while #stack > 0 do
      if not spend(work, edges + 2) then return false end
      local span = table.remove(stack)
      local low, high, d0, d1 = span[1], span[2], span[3], span[4]
      local h = (high - low) * length
      local bound = (d0.nearest + d1.nearest + h) / 2
      local angle = piece.radius and math.abs(piece.sweep) * (high - low) or 0
      if angle <= math.pi then
        -- A finite segment's radius-r tube is convex. A chord whose BOTH
        -- endpoints lie in the SAME tube stays in it; a circular subarc
        -- lies within its sagitta of that chord. Pair edges before taking min.
        local same_edge = math.huge
        for edge = 1, edges do same_edge = math.min(same_edge, math.max(d0[edge], d1[edge])) end
        local sagitta = piece.radius and piece.radius * 2 * math.sin(angle / 4) ^ 2 or 0
        bound = math.min(bound, math.sqrt(same_edge) + sagitta)
      end
      if bound <= allowance then maximum = math.max(maximum, bound + roundoff)
      else
        if h < clearance * .01 then return false end
        local middle = (low + high) / 2
        local d = sample(piece, middle)
        if not d or d.nearest > allowance then return false end
        stack[#stack + 1], stack[#stack + 2] = {low, middle, d0, d}, {middle, high, d, d1}
      end
    end
  end
  return true, maximum
end

-- Arc, straight, arc from p0 heading t0 to p1 heading t1, both arcs of the
-- given radii, the first turning `first_turn` (1 left, -1 right) and the
-- second `second_turn`. Optional second_radius permits a gentler correction.
-- Nil when the arcs would loop or cannot connect.
local function arc_line_arc(p0, t0, p1, t1, radius, first_turn, second_turn, second_radius)
  second_radius = second_radius or radius
  local c0 = {x = p0.x - t0.y * first_turn * radius, y = p0.y + t0.x * first_turn * radius}
  local c1 = {x = p1.x - t1.y * second_turn * second_radius, y = p1.y + t1.x * second_turn * second_radius}
  local dx, dy = c1.x - c0.x, c1.y - c0.y
  local span = math.sqrt(dx * dx + dy * dy)
  local across = second_turn * second_radius - first_turn * radius
  if span <= math.abs(across) then return nil end
  local straight = math.sqrt(span * span - across * across)
  local heading = atan2(dy, dx) - atan2(across, straight)
  local w = {x = math.cos(heading), y = math.sin(heading)}
  local function sweep(from, to, turn)
    local angle = (turn * (atan2(to.y, to.x) - atan2(from.y, from.x))) % TAU
    if angle > math.pi - .000001 then return nil end
    return turn * angle
  end
  local first_sweep, second_sweep = sweep(t0, w, first_turn), sweep(w, t1, second_turn)
  if not (first_sweep and second_sweep) then return nil end
  local q0 = {x = c0.x + w.y * first_turn * radius, y = c0.y - w.x * first_turn * radius}
  local q1 = {x = c1.x + w.y * second_turn * second_radius, y = c1.y - w.x * second_turn * second_radius}
  local pieces = {}
  if math.abs(first_sweep) * radius > 1e-9 then pieces[#pieces + 1] = (arc_from(p0, t0, radius, first_sweep)) end
  if straight > 1e-9 then pieces[#pieces + 1] = line_piece(q0, q1) end
  if math.abs(second_sweep) * second_radius > 1e-9 then pieces[#pieces + 1] = (arc_from(q1, w, second_radius, second_sweep)) end
  -- Chain exactly: each piece starts where the previous one ended.
  for index = 2, #pieces do
    local previous, piece = pieces[index - 1], pieces[index]
    if distance(previous.b, piece.a) > 1e-6 then return nil end
    piece.a = copy(previous.b)
    if piece.kind == "line" then pieces[index] = line_piece(piece.a, piece.b) end
  end
  if #pieces == 0 or distance(pieces[#pieces].b, p1) > 1e-6 then return nil end
  return pieces
end

local function smallest_radius(corner)
  if not corner then return 0 end
  if not corner.pieces then return corner.radius end
  local smallest = math.huge
  for _, piece in ipairs(corner.pieces) do
    if piece.radius then smallest = math.min(smallest, piece.radius) end
  end
  return smallest
end

-- A lane shift: two opposite corners joined by a short leg. The curve stays
-- on the incoming leg's centreline, crosses the middle of the short leg on a
-- line flatter than it, and returns to the outgoing leg's centreline, with
-- the widest fillets that fit at both ends. The flatter the crossing, the
-- wider the fillets, until the line strays too far from the short leg.
local function lane_shift(p0, t0, p1, t1, entry, exit, fraction, share)
  local m = {x = exit.x - entry.x, y = exit.y - entry.y}
  local middle_length = math.sqrt(m.x * m.x + m.y * m.y)
  if middle_length <= 0 then return nil end
  m.x, m.y = m.x / middle_length, m.y / middle_length
  local delta = atan2(t0.x * m.y - t0.y * m.x, t0.x * m.x + t0.y * m.y)
  local angle = delta * fraction
  local w = {x = t0.x * math.cos(angle) - t0.y * math.sin(angle), y = t0.y * math.cos(angle) + t0.x * math.sin(angle)}
  local j = {x = (entry.x + exit.x) / 2, y = (entry.y + exit.y) / 2}
  -- Where the crossing line meets each leg's line: base + direction * along.
  local function meet(base, direction)
    local cross = direction.x * w.y - direction.y * w.x
    if math.abs(cross) < 1e-12 then return nil end
    return ((j.x - base.x) * w.y - (j.y - base.y) * w.x) / cross
  end
  local before_along, after_along = meet(p0, t0), meet(p1, t1)
  if not (before_along and after_along) or before_along <= 0 or after_along >= 0 then return nil end
  local v1 = {x = p0.x + t0.x * before_along, y = p0.y + t0.y * before_along}
  local v2 = {x = p1.x + t1.x * after_along, y = p1.y + t1.y * after_along}
  local to_j, from_j = (j.x - v1.x) * w.x + (j.y - v1.y) * w.y, (v2.x - j.x) * w.x + (v2.y - j.y) * w.y
  if to_j <= 0 or from_j <= 0 then return nil end
  local first_turn = atan2(t0.x * w.y - t0.y * w.x, t0.x * w.x + t0.y * w.y)
  local second_turn = atan2(w.x * t1.y - w.y * t1.x, w.x * t1.x + w.y * t1.y)
  if math.abs(first_turn) < 1e-6 or math.abs(second_turn) < 1e-6 then return nil end
  local first_trim = math.min(before_along, to_j) * share
  local second_trim = math.min(-after_along, from_j) * share
  local first_radius = first_trim / math.tan(math.abs(first_turn) / 2)
  local second_radius = second_trim / math.tan(math.abs(second_turn) / 2)
  local first_start = {x = v1.x - t0.x * first_trim, y = v1.y - t0.y * first_trim}
  local lead = line_piece(p0, first_start)
  lead.on_path = true
  local first_arc = arc_from(first_start, t0, first_radius, first_turn)
  local second_start = {x = v2.x - w.x * second_trim, y = v2.y - w.y * second_trim}
  local crossing = line_piece(first_arc.b, second_start)
  local second_arc = arc_from(second_start, w, second_radius, second_turn)
  local tail = line_piece(second_arc.b, p1)
  tail.on_path = true
  local pieces = {}
  for _, piece in ipairs({lead, first_arc, crossing, second_arc, tail}) do
    if piece_length(piece) > 1e-9 then pieces[#pieces + 1] = piece end
  end
  return pieces, math.min(first_radius, second_radius)
end

-- One curve across corners first..last, from the middle of the leg before
-- them to the middle of the leg after, so neighbouring corners keep their
-- halves. Neither corner of a lane shift round an obstacle can use more than
-- half of the short leg between them, but a curve across both can. Other
-- spans try arc, straight, arc paths from wide to tight. The widest curve
-- certified against the original path replaces the corners when it is
-- clearly wider than every curve it replaces.
local function bridge(points, corners, covered, first, last, clearance, original, work)
  if not spend(work, 16) then return nil end
  local before, after = points[first - 1], points[last + 1]
  local entry, exit = points[first], points[last]
  local current = math.huge
  for index = first, last do
    if corners[index] or not covered[index] then current = math.min(current, smallest_radius(corners[index])) end
  end
  local incoming, outgoing = distance(before.position, entry.position), distance(exit.position, after.position)
  local t0 = {x = (entry.position.x - before.position.x) / incoming, y = (entry.position.y - before.position.y) / incoming}
  local t1 = {x = (after.position.x - exit.position.x) / outgoing, y = (after.position.y - exit.position.y) / outgoing}
  local p0 = {x = entry.position.x - t0.x * incoming / 2, y = entry.position.y - t0.y * incoming / 2}
  local p1 = {x = exit.position.x + t1.x * outgoing / 2, y = exit.position.y + t1.y * outgoing / 2}
  local function turn_at(index)
    local a, b, c = points[index - 1].position, points[index].position, points[index + 1].position
    return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 0 and 1 or -1
  end
  local first_turn, second_turn = turn_at(first), turn_at(last)
  local minimum = math.max(current * RACING_GAIN, clearance)
  local function certified(pieces)
    local check = {}
    for _, piece in ipairs(pieces) do if not piece.on_path then check[#check + 1] = piece end end
    return certify_pieces(check, original, before.original_index, after.original_index, clearance, work)
  end
  local best, best_radius
  if last == first + 1 and first_turn ~= second_turn then
    for _, fraction in ipairs({.1, .2, .3, .45, .6, .8}) do
      for _, share in ipairs({1, .5}) do
        if not construct(work, 16) then break end
        local pieces, radius = lane_shift(p0, t0, p1, t1, entry.position, exit.position, fraction, share)
        if pieces and radius > minimum and (not best_radius or radius > best_radius) and certified(pieces)
            and spend(work, #pieces * (last - first + 2) + 4) then
          best, best_radius = pieces, radius
          break
        end
      end
    end
  end
  local radius = distance(p0, p1) * 2
  while radius > math.max(minimum, best_radius or 0) and active(work) do
    if not construct(work, 8) then break end
    local pieces = arc_line_arc(p0, t0, p1, t1, radius, first_turn, second_turn)
    if pieces and certified(pieces) and spend(work, #pieces * (last - first + 2) + 4) then
      best, best_radius = pieces, radius; break
    end
    radius = radius * .7
  end
  if not best then return nil end
  -- Map each joint to the nearest leg, keeping original distances monotonic.
  local source = (before.source + entry.source) / 2
  local start = source
  for _, piece in ipairs(best) do
    local nearest, nearest_source = math.huge, source
    for index = first - 1, last do
      local a, b = points[index], points[index + 1]
      local length = distance(a.position, b.position)
      if length > 0 then
        local t = clamp(((piece.b.x - a.position.x) * (b.position.x - a.position.x)
          + (piece.b.y - a.position.y) * (b.position.y - a.position.y)) / (length * length), 0, 1)
        local d = segment_distance_sq(piece.b, a.position, b.position)
        if d < nearest then nearest, nearest_source = d, a.source + t * (b.source - a.source) end
      end
    end
    piece.path_start, source = source, math.max(source, nearest_source)
    piece.path_end, piece.source_start, piece.source_end = source, before.index, after.index
  end
  best[#best].path_end = math.max(source, (exit.source + after.source) / 2)
  return {kind = "bridge", pieces = best, a = p0, b = best[#best].b, radius = best_radius, current = current,
    path_start = start, path_end = best[#best].path_end, first_corner = first, last_corner = last}
end

-- Bridges lane shifts first, those that widen their corners most first:
-- they are the commonest bottleneck in pathfinder routes. Then bridges the
-- tightest remaining corners, choosing for each the widest curve across it
-- and up to BRIDGE_CORNERS - 1 neighbours, so the work budget goes to the
-- bottlenecks that set the speed.
local function bridge_corners(points, corners, covered, clearance, original, work)
  local count = #points
  local levels, power = 0, 1
  while power < count do power, levels = power * 2, levels + 1 end
  local sort_cost = math.ceil(count * levels / 8)
  if not spend(work, math.ceil(count / 8) + sort_cost + 16) then return end
  -- Merged groups are units: member[index] is the group's first corner.
  local order, member, radius = {}, {}, {}
  for index = 2, #points - 1 do
    if corners[index] or not covered[index] then
      order[#order + 1] = index
      radius[index] = smallest_radius(corners[index])
    end
    local group = corners[index] and corners[index].last_corner
    for inside = index, group or index - 1 do member[inside] = index end
  end
  table.sort(order, function(a, b) return radius[a] < radius[b] or (radius[a] == radius[b] and a < b) end)
  local used = {}
  local function whole(first, last)
    if last > #points - 1 or (member[first] and member[first] ~= first)
        or (member[last + 1] and member[last + 1] ~= last + 1) then
      return false
    end
    for inside = first, last do if used[inside] then return false end end
    return true
  end
  local function apply(chosen)
    for inside = chosen.first_corner, chosen.last_corner do used[inside], corners[inside] = true, nil end
    corners[chosen.first_corner] = chosen
  end
  local function turn_at(index)
    local a, b, c = points[index - 1].position, points[index].position, points[index + 1].position
    return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
  end
  -- Failed windows cannot improve later: accepted replacements only widen
  -- corners, and used windows are excluded by whole(). Cache failures too.
  local candidates = {}
  local function candidate(first, last)
    local key = first * (#points + 1) + last
    if candidates[key] == nil then
      candidates[key] = bridge(points, corners, covered, first, last, clearance, original, work) or false
    end
    return candidates[key]
  end
  local shifts = {}
  for _, index in ipairs(order) do
    if not active(work) then break end
    for _, first in ipairs({index - 1, index}) do
      local last = first + 1
      if first >= 2 and not member[first] and not member[last] and whole(first, last)
          and turn_at(first) * turn_at(last) < 0 and shifts[first] == nil then
        shifts[first] = candidate(first, last)
      end
    end
  end
  local found = {}
  for _, candidate in pairs(shifts) do if candidate then found[#found + 1] = candidate end end
  table.sort(found, function(a, b)
    local ga, gb = a.radius / math.max(a.current, 1e-9), b.radius / math.max(b.current, 1e-9)
    return ga > gb or (ga == gb and a.first_corner < b.first_corner)
  end)
  for _, candidate in ipairs(found) do
    if whole(candidate.first_corner, candidate.last_corner) then apply(candidate) end
  end
  for _, index in ipairs(order) do
    if not active(work) then break end
    if not used[index] then
      local best
      for length = 2, BRIDGE_CORNERS do
        if not active(work) then break end
        for first = math.max(2, index - length + 1), index do
          if not active(work) then break end
          local last = first + length - 1
          local found = whole(first, last) and candidate(first, last)
          if found and (not best or found.radius > best.radius) then best = found end
        end
      end
      if best then apply(best) end
    end
  end
end

-- Refit complete neighboring pieces instead of committing every corner to
-- half of its legs. The objective improves both peak curvature and integrated
-- squared curvature, with a small length bound. Constant-radius arc/line/arc
-- candidates keep tangent joins and are accepted only with a certificate
-- against the ORIGINAL corridor. Search and certification work are bounded.
local function polish_bends(plan, original, clearance, work)
  local tried = {}
  local function end_tangent(piece)
    if not piece.radius then return piece.tangent end
    local c, s = math.cos(piece.sweep), math.sin(piece.sweep)
    return {x = piece.tangent.x * c - piece.tangent.y * s, y = piece.tangent.y * c + piece.tangent.x * s}
  end
  local function source_edge(source)
    local low, high = 1, #original - 1
    while low < high do
      local middle = math.floor((low + high) / 2)
      if original[middle + 1].source < source then low = middle + 1 else high = middle end
    end
    return low
  end
  for attempt = 1, 8 do
    if not spend(work, math.ceil(#plan.segments / 4) + 8) then break end
    local segments, bottleneck, tightest = plan.segments, nil, math.huge
    for index, piece in ipairs(segments) do
      if piece.radius and not tried[piece] and piece.radius < tightest then bottleneck, tightest = index, piece.radius end
    end
    if not bottleneck or not active(work) then break end
    tried[segments[bottleneck]] = true
    local best, seen = nil, {}
    for _, width in ipairs({3, 5, 9}) do
      for _, shift in ipairs({math.floor(width / 2), width - 1, 0}) do
        local first = math.max(1, math.min(bottleneck - shift, #segments - width + 1))
        local last = math.min(#segments, first + width - 1)
        local key = first .. ":" .. last
        if not seen[key] and first <= bottleneck and last >= bottleneck and active(work) then
          if not spend(work, 32 + width * 2) then break end
          seen[key] = true
          local a, b = segments[first], segments[last]
          local source_start, source_end = a.path_start, b.path_end
          local original_first, original_last = source_edge(source_start), source_edge(source_end) + 1
          local energy, continuous = 0, true
          if first > 1 then
            local incoming = end_tangent(segments[first - 1])
            continuous = incoming.x * a.tangent.x + incoming.y * a.tangent.y > 1 - 1e-8
          end
          if last < #segments then
            local outgoing, incoming = segments[last + 1].tangent, end_tangent(b)
            continuous = continuous and incoming.x * outgoing.x + incoming.y * outgoing.y > 1 - 1e-8
          end
          for index = first, last do
            local piece = segments[index]
            if piece.radius then energy = energy + piece.length / (piece.radius * piece.radius) end
            if index > first then
              local incoming, outgoing = end_tangent(segments[index - 1]), piece.tangent
              if incoming.x * outgoing.x + incoming.y * outgoing.y < 1 - 1e-8 then continuous = false; break end
            end
          end
          if continuous and source_end > source_start and original_last - original_first <= MERGE_EDGES then
            local length = b.end_s - a.start_s
            for _, gain in ipairs({2, 1.5, 1.2, 4, 8}) do
              local radius = tightest * gain
              if not best or radius >= best.radius then
                -- A tiny entry correction must not inherit the main bend's
                -- tight radius hundreds of tiles before it. Unequal circles
                -- can spread that correction with much gentler curvature.
                for _, radii in ipairs({{1, 1}, {16, 1}, {1, 16}}) do
                  for _, turns in ipairs({{1, 1}, {-1, -1}, {1, -1}, {-1, 1}}) do
                    if not construct(work, 8) then break end
                    local pieces = arc_line_arc(a.a, a.tangent, b.b, end_tangent(b), radius * radii[1], turns[1], turns[2], radius * radii[2])
                    if pieces then
                      local candidate_length, candidate_energy = 0, 0
                      for _, piece in ipairs(pieces) do
                        local l = piece_length(piece)
                        candidate_length = candidate_length + l
                        if piece.radius then candidate_energy = candidate_energy + l / (piece.radius * piece.radius) end
                      end
                      if candidate_length <= length * 1.05 and candidate_energy < energy * .99
                          and (not best or radius > best.radius or candidate_energy < best.energy)
                          and distance(pieces[1].a, a.a) <= 1e-7 then
                        local check = budget(math.min(work.remaining, 768), work)
                        local safe = certify_pieces(pieces, original, original_first, original_last, clearance, check)
                        if safe then safe = spend(work, math.ceil(#segments / 4) + #pieces * (original_last - original_first + 4)) end
                        if safe then
                          best = {pieces = pieces, radius = radius, energy = candidate_energy, first = first, last = last,
                            original_first = original_first, original_last = original_last}
                          break
                        end
                      end
                    end
                  end
                end
              end
              if best then break end
            end
          end
        end
      end
    end
    if best then
      local source_start, source_end = segments[best.first].path_start, segments[best.last].path_end
      local source, raw_source, traveled, total_length = source_start, source_start, 0, 0
      for _, piece in ipairs(best.pieces) do total_length = total_length + piece_length(piece) end
      for index, piece in ipairs(best.pieces) do
        local nearest, mapped = math.huge, source
        for edge = best.original_first, best.original_last - 1 do
          local a, b = original[edge], original[edge + 1]
          local dx, dy = b.position.x - a.position.x, b.position.y - a.position.y
          local fraction = clamp(((piece.b.x - a.position.x) * dx + (piece.b.y - a.position.y) * dy) / (dx * dx + dy * dy), 0, 1)
          local d = segment_distance_sq(piece.b, a.position, b.position)
          if d < nearest then nearest, mapped = d, a.source + fraction * (b.source - a.source) end
        end
        raw_source = clamp(mapped, raw_source, source_end)
        traveled = traveled + piece_length(piece)
        -- Closest-point source can plateau on a corner. Blend a small amount
        -- of proportional arc length so the inverse remains well conditioned.
        local finish = index == #best.pieces and source_end or source_start
          + (raw_source - source_start) * .999 + (source_end - source_start) * traveled / total_length * .001
        piece.path_start, piece.path_end = source, finish
        piece.source_start, piece.source_end = original[best.original_first].index, original[best.original_last].index
        piece.polished, tried[piece], source = true, true, finish
      end
      plan.segments, plan.total_length = {}, 0
      for index = 1, best.first - 1 do append(plan, segments[index], piece_length(segments[index])) end
      for _, piece in ipairs(best.pieces) do append(plan, piece, piece_length(piece)) end
      for index = best.last + 1, #segments do append(plan, segments[index], piece_length(segments[index])) end
    end
  end
  plan.polish_work = work.used
end

-- Endpoint heading is unconstrained: the vehicle stops there. A tiny final
-- leg must not force a tight turn merely to face along that leg. Search a
-- bounded tail for a wider circle starting tangent to the current reference
-- and ending at the exact goal, then prove the whole circle against the
-- original finite polyline. The existing route remains the safe fallback.
local function terminal_curve(plan, original, clearance, work)
  local segments, count = plan.segments, #plan.segments
  if count == 0 then return end
  if not spend(work, 32) then return end
  local goal, best = plan.point
  local tightest, bottleneck, continuous = math.huge, nil, true
  local first_piece = math.max(1, count - TERMINAL_PIECES + 1)
  local seen_arc = false
  for index = count, first_piece, -1 do
    local piece = segments[index]
    if piece.radius then seen_arc = true end
    if seen_arc and piece.kind == "line" and piece.length > math.max(4, clearance * 2) then
      first_piece = index
      break
    end
  end
  for index = first_piece, count do
    local piece = segments[index]
    if piece.radius and piece.radius <= tightest then tightest, bottleneck = piece.radius, index end
  end
  if not bottleneck then return end
  local function tangent(piece, t)
    if piece.kind == "line" then return copy(piece.tangent) end
    local angle = piece.sweep * t
    return {x = piece.tangent.x * math.cos(angle) - piece.tangent.y * math.sin(angle),
      y = piece.tangent.y * math.cos(angle) + piece.tangent.x * math.sin(angle)}
  end
  -- Work backwards, so an earlier reversal cannot invalidate a later tail.
  for index = count, first_piece, -1 do
    if not active(work) then break end
    local piece = segments[index]
    if index < count then
      local a, b = tangent(piece, 1), tangent(segments[index + 1], 0)
      continuous = continuous and a.x * b.x + a.y * b.y > 1 - 1e-8
    end
    if not continuous then break end
    for _, fraction in ipairs({0, .25, .5, .75, .8125, .828125, .84375, .875, .9375, .96875}) do
      if not construct(work, 8) then break end
      local start, heading = piece_point(piece, fraction), tangent(piece, fraction)
      local dx, dy = goal.x - start.x, goal.y - start.y
      local along, across = dx * heading.x + dy * heading.y, heading.x * dy - heading.y * dx
      if (index < bottleneck or (index == bottleneck and fraction == 0))
          and along > 1e-8 and math.abs(across) > 1e-8 then
        local radius = (along * along + across * across) / (2 * math.abs(across))
        local sweep = 2 * atan2(math.abs(across), along) * (across > 0 and 1 or -1)
        local length = radius * math.abs(sweep)
        local tail = plan.total_length - piece.start_s - fraction * piece.length
        local start_source = piece.path_start + fraction * (piece.path_end - piece.path_start)
        -- Preserve an explicit reversal at the boundary as well as inside the
        -- replaced span. A later fraction leaves the incoming straight intact.
        local aligned = true
        if fraction == 0 and index > 1 then
          local previous = tangent(segments[index - 1], 1)
          aligned = previous.x * heading.x + previous.y * heading.y > 1 - 1e-8
        end
        if aligned and radius > tightest * RACING_GAIN and (not best or radius > best.arc.radius)
            and length <= tail * 1.05 then
          local first, last = 1, #original - 1
          while first < last do
            local middle = math.floor((first + last) / 2)
            if original[middle + 1].source < start_source then first = middle + 1 else last = middle end
          end
          if not construct(work, 16) then break end
          local arc = arc_from(start, heading, radius, sweep)
          if distance(arc.b, goal) <= 1e-7
              and certify_pieces({arc}, original, first, #original, clearance, work)
              and spend(work, math.ceil(count / 4) + 8) then
            arc.b, arc.terminal = copy(goal), true
            arc.path_start, arc.path_end = start_source, plan.path_distances[#plan.path_distances]
            arc.source_start, arc.source_end = piece.source_start, #plan.path_distances
            best = {arc = arc, index = index, fraction = fraction}
          end
        end
      end
    end
  end
  plan.terminal_work = work.used
  if not best then return end
  local replacement = {}
  for index = 1, best.index - 1 do replacement[#replacement + 1] = segments[index] end
  local piece = segments[best.index]
  if best.fraction > 0 then
    local prefix
    if piece.kind == "line" then
      prefix = line_piece(piece.a, best.arc.a)
    else
      prefix = arc_from(piece.a, piece.tangent, piece.radius, piece.sweep * best.fraction)
      prefix.b = copy(best.arc.a)
    end
    prefix.path_start, prefix.path_end = piece.path_start, best.arc.path_start
    prefix.source_start, prefix.source_end = piece.source_start, piece.source_end
    replacement[#replacement + 1] = prefix
  end
  replacement[#replacement + 1] = best.arc
  plan.segments, plan.total_length = {}, 0
  for _, segment in ipairs(replacement) do append(plan, segment, piece_length(segment)) end
end

---@param path PathfinderWaypoint[]
---@param clearance? number usable clearance; nil/zero keeps the original polyline
---@return table plan
function Trajectory.build(path, clearance, work_limit)
  local shared = budget(math.max(0, math.min(Trajectory.WORK_LIMIT, work_limit or Trajectory.WORK_LIMIT)))
  local distances = {}
  local plan = {segments = {}, total_length = 0, path_distances = distances,
    waypoint_segments = {}, waypoint_s = {}}
  for index, waypoint in ipairs(path) do
    distances[index] = index == 1 and 0 or distances[index - 1] + distance(path[index - 1].position, waypoint.position)
  end
  if #path == 0 then return plan end
  plan.point = copy(path[#path].position)
  local original = collapse(path, distances)
  local points = original
  local corners = {}
  if clearance and clearance > 0 then
    local work, racing_work = budget(MERGE_WORK, shared), budget(RACING_WORK, shared)
    -- Preserve certified chamfers before DP can erase one end and change its
    -- exterior headings. Their exterior chords remain exact through DP.
    local original_corners = {}
    merge_corners(original, original_corners, original, clearance, work)
    local protected, merged, original_cursor = {}, {}, 2
    while original_cursor < #original do
      local corner = original_corners[original_cursor]
      if corner and corner.merged_corners then
        merged[#merged + 1] = {first = original_cursor, last = corner.last_corner, arc = corner}
        for keep = original_cursor - 1, corner.last_corner + 1 do protected[keep] = true end
        original_cursor = corner.last_corner + 1
      else original_cursor = original_cursor + 1 end
    end
    local simplify_work = budget(SIMPLIFY_WORK, shared)
    points = simplify(points, clearance, protected, simplify_work)
    plan.simplify_work = simplify_work.used
    local simplified, covered = {}, {}
    for position, p in ipairs(points) do simplified[p.original_index] = position end
    for _, group in ipairs(merged) do
      local first, last = simplified[group.first], simplified[group.last]
      group.arc.last_corner = last
      corners[first] = group.arc
      for skip = first, last do covered[skip] = true end
      -- A racing line round the corner the exterior legs would make.
      local before, entry, exit, after = points[first - 1], points[first], points[last], points[last + 1]
      local u = {x = entry.position.x - before.position.x, y = entry.position.y - before.position.y}
      local v = {x = after.position.x - exit.position.x, y = after.position.y - exit.position.y}
      local cross = u.x * v.y - u.y * v.x
      if cross ~= 0 then
        local along = ((exit.position.x - entry.position.x) * v.y - (exit.position.y - entry.position.y) * v.x) / cross
        local vertex = {position = {x = entry.position.x + u.x * along, y = entry.position.y + u.y * along}}
        local incoming = distance(before.position, vertex.position)
        vertex.source = clamp(before.source + incoming, entry.source, exit.source)
        -- Each racing line starts at least halfway along its real leg.
        if along > 0 and incoming / 2 >= incoming - distance(before.position, entry.position)
            and distance(vertex.position, after.position) / 2
              >= distance(vertex.position, after.position) - distance(exit.position, after.position) then
          local race = racing(before, vertex, after, clearance, clearance, original, racing_work, group.arc.radius)
          if race then
            race.last_corner, race.pieces[2].merged_corners = last, group.arc.merged_corners
            corners[first] = race
          end
        end
      end
    end
    for index = 2, #points - 1 do
      if not covered[index] then
        local error = math.max(points[index].incoming_error or 0, points[index + 1].incoming_error or 0)
        local before, vertex, after = points[index - 1], points[index], points[index + 1]
        -- The error-reserved fillet is always safe. A larger fillet may instead
        -- be proved directly against the original path, keeping useful radius
        -- where a discarded staircase is already close to the rounded curve.
        local corner = fillet(before, vertex, after, clearance - error)
        if error > 0 and construct(work, 4) then
          local candidate = fillet(before, vertex, after, clearance)
          if candidate and (not corner or candidate.radius > corner.radius)
              and certify(candidate, original, before.original_index, after.original_index, clearance, work) then
            corner = candidate
          end
        end
        corners[index] = racing(before, vertex, after, clearance - error, clearance, original, racing_work,
          corner and corner.radius or 0) or corner
      end
    end
    local bridge_work = budget(BRIDGE_WORK, shared)
    bridge_corners(points, corners, covered, clearance, original, bridge_work)
    plan.merge_work = work.used
    plan.racing_work = racing_work.used
    plan.bridge_work = bridge_work.used
  end
  local position, cursor_source, source_index, cursor = points[1].position, points[1].source, points[1].index, 2
  while cursor <= #points do
    local corner, p = corners[cursor], points[cursor]
    append_line(plan, position, corner and corner.a or p.position,
      cursor_source, corner and corner.path_start or p.source, source_index, p.index)
    if corner and corner.pieces then
      for _, piece in ipairs(corner.pieces) do append(plan, piece, piece_length(piece)) end
      cursor = (corner.last_corner or cursor) + 1
      position, cursor_source, source_index = corner.b, corner.path_end, points[cursor - 1].index
    elseif corner then
      append(plan, corner, corner.radius * math.abs(corner.sweep))
      cursor = (corner.last_corner or cursor) + 1
      position, cursor_source, source_index = corner.b, corner.path_end, points[cursor - 1].index
    else
      position, cursor_source, source_index, cursor = p.position, p.source, p.index, cursor + 1
    end
  end
  if clearance and clearance > 0 then
    local polish = budget(math.min(POLISH_WORK, math.max(0, shared.remaining - 512)), shared)
    polish_bends(plan, original, clearance, polish)
    local terminal = budget(TERMINAL_WORK, shared)
    terminal_curve(plan, original, clearance, terminal)
    plan.polish_work, plan.terminal_work = polish.used, terminal.used
  end
  -- Source distances are monotone; find each containing piece once instead
  -- of performing two binary searches per raw waypoint.
  local segment_index, count = 1, #plan.segments
  for index, source in ipairs(distances) do
    while segment_index < count and plan.segments[segment_index].path_end < source do segment_index = segment_index + 1 end
    local segment = plan.segments[segment_index]
    plan.waypoint_segments[index] = segment and segment_index or 0
    plan.waypoint_s[index] = segment and segment.start_s
      + fraction(source, segment.path_start, segment.path_end) * segment.length or 0
  end
  plan.build_work, plan.work_limit = shared.used, shared.limit
  plan.construction_attempts = shared.attempts or 0
  return plan
end

local function sample_segment(segment, s)
  local t = fraction(s, segment.start_s, segment.end_s)
  if segment.kind == "line" then
    return {x = segment.a.x + (segment.b.x - segment.a.x) * t,
      y = segment.a.y + (segment.b.y - segment.a.y) * t}, copy(segment.tangent), 0
  end
  local angle = math.abs(segment.sweep) * t
  local sign = segment.sweep > 0 and 1 or -1
  local cosine, sine = math.cos(angle), math.sin(angle)
  local ux, uy = segment.tangent.x, segment.tangent.y
  return arc_position(segment, t), {x = ux * cosine - uy * sine * sign,
    y = uy * cosine + ux * sine * sign}, sign / segment.radius
end

-- Position, unit tangent, signed curvature and segment index at arc length s.
function Trajectory.sample(plan, s)
  if #plan.segments == 0 then return plan.point and copy(plan.point), {x = 0, y = 0}, 0, 0 end
  s = clamp(s, 0, plan.total_length)
  local index = segment_at(plan, s)
  local position, tangent, curvature = sample_segment(plan.segments[index], s)
  return position, tangent, curvature, index
end

local function project_segment(segment, position, minimum_s)
  local t
  local minimum = fraction(minimum_s or segment.start_s, segment.start_s, segment.end_s)
  if segment.kind == "line" then
    local dx, dy = segment.b.x - segment.a.x, segment.b.y - segment.a.y
    t = clamp(((position.x - segment.a.x) * dx + (position.y - segment.a.y) * dy)
      / (segment.length * segment.length), 0, 1)
  else
    local dx, dy = position.x - segment.a.x, position.y - segment.a.y
    local ux, uy = segment.tangent.x, segment.tangent.y
    local sign = segment.sweep > 0 and 1 or -1
    local along, across = dx * ux + dy * uy, (-dx * uy + dy * ux) * sign
    local angle = atan2(along, segment.radius - across) % TAU
    local sweep = math.abs(segment.sweep)
    if angle >= minimum * sweep and angle <= sweep then
      t = angle / sweep
    else
      local first = sample_segment(segment, segment.start_s + minimum * segment.length)
      t = distance(position, first) <= distance(position, segment.b) and minimum or 1
    end
  end
  local s = math.max(minimum_s or 0, segment.start_s + t * segment.length)
  s = clamp(s, segment.start_s, segment.end_s)
  local nearest = sample_segment(segment, s)
  return s, distance(position, nearest)
end

-- Local projection, never an all-path scan. The caller supplies its current
-- original waypoint index and can forbid backwards progress with minimum_s.
-- A saved reference_s overrides the raw-waypoint anchor, which may already
-- have advanced ahead of the vehicle. At most five local pieces are inspected.
function Trajectory.project(plan, position, path_index, minimum_s, reference_s)
  if #plan.segments == 0 then return 0, plan.point and distance(position, plan.point) or math.huge, 0 end
  local waypoint = clamp(path_index or 1, 1, #plan.path_distances)
  local anchor = reference_s and segment_at(plan, clamp(reference_s, 0, plan.total_length))
    or plan.waypoint_segments[waypoint]
  local floor = clamp(minimum_s or 0, 0, plan.total_length)
  if minimum_s then anchor = math.max(anchor, segment_at(plan, floor)) end
  local first, last = math.max(1, anchor - PROJECT_NEIGHBORS), math.min(#plan.segments, anchor + PROJECT_NEIGHBORS)
  local best_s, best_distance, best_index
  for index = first, last do
    local segment = plan.segments[index]
    if segment.end_s >= floor then
      local s, offset = project_segment(segment, position, floor)
      if not best_distance or offset < best_distance or (offset == best_distance and s < best_s) then
        best_s, best_distance, best_index = s, offset, index
      end
    end
  end
  return best_s, best_distance, best_index
end

return Trajectory
