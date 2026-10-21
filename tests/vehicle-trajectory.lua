-- Run from the mod directory: lua tests/vehicle-trajectory.lua
local Trajectory = require("scripts/vehicle-trajectory")
local function point(x, y) return {x = x, y = y or 0} end
local function path(points)
  local result = {}
  for index, p in ipairs(points) do result[index] = {position = p} end
  return result
end
local function near(actual, expected, tolerance, reason)
  assert(math.abs(actual - expected) <= (tolerance or 0.00000001),
    (reason or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function same(actual, expected, tolerance)
  near(actual.x, expected.x, tolerance, "x")
  near(actual.y, expected.y, tolerance, "y")
end
local function segment_distance(p, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local length = dx * dx + dy * dy
  local t = length > 0 and math.max(0, math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) or 0
  return math.sqrt((p.x - a.x - t * dx) ^ 2 + (p.y - a.y - t * dy) ^ 2)
end
local function path_distance(p, points)
  local nearest = math.huge
  for index = 1, #points - 1 do nearest = math.min(nearest, segment_distance(p, points[index], points[index + 1])) end
  return nearest
end
local tests = {}
local function test(name, body) tests[#tests + 1] = {name, body} end

test("straight grid nodes collapse without losing original waypoint distances", function()
  local points = {}
  for x = 0, 1000 do points[#points + 1] = point(x) end
  local plan = Trajectory.build(path(points), 2)
  assert(#plan.segments == 1 and plan.segments[1].kind == "line")
  near(plan.total_length, 1000)
  for index, source in ipairs(plan.path_distances) do
    near(source, index - 1)
    near(plan.waypoint_s[index], source)
    assert(plan.waypoint_segments[index] == 1)
  end
  local p, tangent, curvature = Trajectory.sample(plan, 123.25)
  same(p, point(123.25)); same(tangent, point(1)); near(curvature, 0)
end)

test("a right-angle racing line is tangent and uses both sides of its corridor", function()
  local clearance = 2
  local points = {point(0), point(100), point(100, 100)}
  local plan = Trajectory.build(path(points), clearance)
  local kinds = {}
  for index, segment in ipairs(plan.segments) do kinds[index] = segment.kind end
  assert(table.concat(kinds, " ") == "line arc arc arc line", table.concat(kinds, " "))
  local main = plan.segments[3]
  local fillet = clearance / (1 - math.sqrt(.5))
  -- Built to 90% of the clearance, leaving room for the certificate.
  near(main.radius, 2 * .9 * clearance / (1 - math.sqrt(.5)), .000001)
  assert(main.radius > 1.75 * fillet, "the racing line is no wider than the inside fillet")
  -- It starts and ends at the middle of each leg, tangent to the centreline.
  same(plan.segments[2].a, point(50)); same(plan.segments[4].b, point(100, 50), .000001)
  for index = 2, #plan.segments do
    local previous, segment = plan.segments[index - 1], plan.segments[index]
    same(previous.b, segment.a, .000001)
    near(previous.path_end, segment.path_start)
    assert(segment.path_end >= segment.path_start)
    local _, incoming = Trajectory.sample(plan, previous.end_s - .000000001)
    local _, outgoing = Trajectory.sample(plan, segment.start_s + .000000001)
    near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1, .0000001)
  end
  -- Out to the outer edge before the corner, in to the inner edge at the apex.
  local outside, apex = 0, 0
  for step = 0, 2000 do
    local p = Trajectory.sample(plan, plan.total_length * step / 2000)
    local offset = path_distance(p, points)
    assert(offset <= clearance + .00000001, "the racing line left the corridor")
    if p.y < 0 and p.x < 100 then outside = math.max(outside, offset) end
    if p.x < 100 and p.y > 0 then apex = math.max(apex, offset) end
  end
  near(outside, .9 * clearance, .001); near(apex, .9 * clearance, .001)
  -- The apex maps to the corner's original path distance.
  local middle = (main.start_s + main.end_s) / 2
  near(Trajectory.source_distance(plan, middle), 100, 1)
  same(Trajectory.sample(plan, 0), points[1])
  same(Trajectory.sample(plan, plan.total_length), points[#points], .000001)
end)

test("short terminal legs can stop without imposing the final raw heading", function()
  local points = {point(0), point(4), point(4, 4)}
  local plan = Trajectory.build(path(points), 1)
  local terminal = plan.segments[#plan.segments]
  -- A tangent-to-both-legs fillet used radius 2. The stopping endpoint has
  -- no heading constraint, allowing a wider certified curve on short legs.
  assert(terminal.terminal and terminal.radius > 3, "short endpoint retained its half-leg turn")
  same(Trajectory.sample(plan, 0), points[1])
  same(Trajectory.sample(plan, plan.total_length), points[#points])
  for index = 2, #plan.segments do
    local before, after = plan.segments[index - 1], plan.segments[index]
    same(before.b, after.a)
    local _, incoming = Trajectory.sample(plan, before.end_s - .000000001)
    local _, outgoing = Trajectory.sample(plan, after.start_s + .000000001)
    near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1)
  end
  for step = 0, 500 do
    local s = plan.total_length * step / 500
    assert(path_distance(Trajectory.sample(plan, s), points) <= 1 + .00000001)
    near(Trajectory.at_source(plan, Trajectory.source_distance(plan, s)), s)
  end
end)

test("racing lines through an S-bend meet on the centreline of the shared leg", function()
  local points = {point(0), point(60), point(60, 40), point(120, 40)}
  local plan = Trajectory.build(path(points), 1.5)
  local arcs = 0
  for index, segment in ipairs(plan.segments) do
    if segment.kind == "arc" then arcs = arcs + 1 end
    if index > 1 then
      local previous = plan.segments[index - 1]
      same(previous.b, segment.a, .000001)
      local _, incoming = Trajectory.sample(plan, previous.end_s - .000000001)
      local _, outgoing = Trajectory.sample(plan, segment.start_s + .000000001)
      near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1, .0000001)
    end
  end
  assert(arcs == 6, "both corners should be racing lines")
  same(Trajectory.sample(plan, Trajectory.at_source(plan, 80)), point(60, 20), .000001)
  for step = 0, 2000 do
    assert(path_distance(Trajectory.sample(plan, plan.total_length * step / 2000), points) <= 1.5 + .00000001)
  end
end)

test("a lane shift round an obstacle becomes one wide curve across both corners", function()
  -- The native pathfinder's route along a walled corridor: a 3-tile diagonal
  -- step towards the inside of the next turn, 120 tiles before it.
  for _, sign in ipairs({-1, 1}) do
    local points = {point(0), point(174), point(177, 3 * sign), point(295, 3 * sign), point(295, 100 * sign)}
    local clearance = 1.109
    local plan = Trajectory.build(path(points), clearance)
    -- A fillet at either corner could use only half of the 4.2-tile step.
    local fillet = 4.24 / 2 / math.tan(math.pi / 8)
    local tightest = math.huge
    for index, segment in ipairs(plan.segments) do
      if segment.radius and segment.start_s < 200 then tightest = math.min(tightest, segment.radius) end
      if index > 1 then
        local previous = plan.segments[index - 1]
        same(previous.b, segment.a, .000001)
        assert(segment.path_start >= previous.path_start)
        local _, before = Trajectory.sample(plan, previous.end_s - .000001)
        local _, after = Trajectory.sample(plan, segment.start_s + .000001)
        near(before.x * after.x + before.y * after.y, 1, .000001)
      end
    end
    assert(tightest > 5 * fillet, "the lane shift still limits the speed: " .. tightest)
    for step = 0, 3000 do
      local p = Trajectory.sample(plan, plan.total_length * step / 3000)
      assert(path_distance(p, points) <= clearance + .00000001, "the lane shift left the corridor")
    end
    assert(plan.bridge_work > 0 and plan.bridge_work <= 32768)
  end
end)

test("left and right fillets stay inside their actual finite path corridor", function()
  for _, degrees in ipairs({1, 15, 45, 90, 135, 170}) do
    for _, sign in ipairs({-1, 1}) do
      for _, clearance in ipairs({0.000001, .1, 2, 100}) do
        local angle = math.rad(degrees) * sign
        local points = {point(-8), point(0), point(13 * math.cos(angle), 13 * math.sin(angle))}
        local plan = Trajectory.build(path(points), clearance)
        for step = 0, 300 do
          local p, tangent = Trajectory.sample(plan, plan.total_length * step / 300)
          assert(path_distance(p, points) <= clearance + 0.00000001, "arc left the path corridor")
          near(tangent.x ^ 2 + tangent.y ^ 2, 1)
        end
      end
    end
  end
end)

test("adjacent fillets never overlap and remain tangent when their trims meet", function()
  local points = {point(0), point(2), point(2, 2), point(4, 2), point(4, 4)}
  local plan = Trajectory.build(path(points), .5)
  local previous
  for _, segment in ipairs(plan.segments) do
    assert(segment.length > 0 and segment.path_end >= segment.path_start)
    if segment.kind == "arc" then
      if segment.trim then near(segment.trim, 1) end
      -- The terminal pass may truncate a fillet before replacing its tail;
      -- neither the retained prefix nor its replacement may be tighter.
      assert(segment.radius >= 1 - .00000001)
    end
    if previous then
      same(previous.b, segment.a)
      near(previous.end_s, segment.start_s)
      near(previous.path_end, segment.path_start)
      local _, before = Trajectory.sample(plan, previous.end_s - 0.000000001)
      local _, after = Trajectory.sample(plan, segment.start_s + 0.000000001)
      near(before.x * after.x + before.y * after.y, 1)
    end
    previous = segment
  end
  for step = 0, 1000 do
    assert(path_distance(Trajectory.sample(plan, plan.total_length * step / 1000), points) <= .5 + .00000001)
  end
end)

test("short staircases simplify without taking clearance from unrelated exact corners", function()
  local points = {point(0)}
  for index = 1, 20 do
    points[#points + 1] = point(index, index - 1)
    points[#points + 1] = point(index, index)
  end
  points[#points + 1], points[#points + 2] = point(40, 20), point(40, 50)
  local plan = Trajectory.build(path(points), 2)
  assert(#plan.segments < 10, "the grid staircase retained dozens of tiny arcs")
  for step = 0, 1000 do
    local p = Trajectory.sample(plan, plan.total_length * step / 1000)
    assert(path_distance(p, points) <= 2 + .00000001, "simplification and rounding exceeded their shared clearance")
  end
  local final_arc
  for _, segment in ipairs(plan.segments) do if segment.kind == "arc" then final_arc = segment end end
  near(final_arc.radius, 2 / (1 - math.sqrt(.5)), .00000001,
    "an unrelated exact corner lost its usable clearance")
end)

test("rounding reserves the error already spent simplifying both adjacent legs", function()
  -- Both original legs bow away from the inside of the turn. Rounding the
  -- simplified right angle with the whole budget would stray 2.8 tiles from
  -- the original path, despite either operation fitting the budget alone.
  local points = {point(0), point(80), point(90, -.8), point(99.9, -.8), point(100),
    point(100.8, .1), point(100.8, 10), point(100, 20), point(100, 100)}
  local plan = Trajectory.build(path(points), 2)
  local tightest = math.huge
  for _, segment in ipairs(plan.segments) do
    if segment.kind == "arc" then tightest = math.min(tightest, segment.radius) end
  end
  -- A racing line on the simplified corner, built inside the clearance left
  -- after the simplification error, so narrower than one with the whole budget.
  assert(tightest < 2 * .9 * 2 / (1 - math.sqrt(.5)), "the simplification error was not reserved")
  for step = 0, 1000 do
    local p = Trajectory.sample(plan, plan.total_length * step / 1000)
    assert(path_distance(p, points) <= 2 + .00000001, "simplification and rounding spent the same clearance twice")
  end
end)

test("certified same-turn chamfers become one racing line round their exterior corner", function()
  for _, sign in ipairs({-1, 1}) do
    for _, shift in ipairs({0, 1000000.25}) do
      local clearance = 1.109
      local points = {point(-100 + shift, -shift), point(-1 + shift, -shift),
        point(shift, sign - shift), point(shift, 100 * sign - shift)}
      local plan = Trajectory.build(path(points), clearance)
      assert(#plan.segments == 5)
      local arc = plan.segments[3]
      assert(arc.merged_corners == 2 and arc.certificate_error <= clearance)
      -- Twice the inside-only arc of the merged right angle, less the share
      -- left for the certificate.
      assert(arc.radius > 1.75 * clearance / (1 - math.sqrt(.5)), "the racing line is no wider than the merged arc")
      local _, incoming = Trajectory.sample(plan, plan.segments[2].start_s + .000000001)
      local _, outgoing = Trajectory.sample(plan, plan.segments[4].end_s)
      same(incoming, point(1), .00000001); same(outgoing, point(0, sign), .00000001)
      for index = 2, #plan.segments do
        local previous, segment = plan.segments[index - 1], plan.segments[index]
        local _, before = Trajectory.sample(plan, previous.end_s - .000001)
        local _, after = Trajectory.sample(plan, segment.start_s + .000001)
        near(before.x * after.x + before.y * after.y, 1, .000001)
      end
      local last = -1
      for step = 0, 1000 do
        local s = plan.total_length * step / 1000
        local p = Trajectory.sample(plan, s)
        assert(path_distance(p, points) <= clearance + .00000001)
        local source = Trajectory.source_distance(plan, s)
        assert(source >= last); near(Trajectory.at_source(plan, source), s, .00000001)
        last = source
      end
    end
  end
end)

test("several convex bends merge only with an original-path corridor certificate", function()
  local points = {point(-100), point(-2), point(-1, .4), point(0, 1.4), point(0, 100)}
  local plan = Trajectory.build(path(points), 1.109)
  local merged
  for _, segment in ipairs(plan.segments) do merged = merged or (segment.merged_corners == 3 and segment) end
  assert(merged and merged.certificate_error <= 1.109)
  for step = 0, 1500 do
    local p, tangent = Trajectory.sample(plan, plan.total_length * step / 1500)
    assert(path_distance(p, points) <= 1.109 + .00000001)
    near(tangent.x * tangent.x + tangent.y * tangent.y, 1)
  end
end)

test("merged arcs share exterior legs with neighboring fillets without gaps or tangent jumps", function()
  local points = {point(0), point(80), point(90, -.8), point(99, -.8), point(100),
    point(100.8, 1), point(100.8, 10), point(100, 20), point(100, 100)}
  local plan = Trajectory.build(path(points), 2)
  local merged, polished, tightest, energy = false, false, math.huge, 0
  for index, segment in ipairs(plan.segments) do
    merged = merged or segment.merged_corners ~= nil
    polished = polished or segment.polished == true
    if segment.radius then
      tightest = math.min(tightest, segment.radius)
      energy = energy + segment.length / (segment.radius * segment.radius)
    end
    if index > 1 then
      local previous = plan.segments[index - 1]
      same(previous.b, segment.a)
      near(previous.path_end, segment.path_start)
      local _, incoming = Trajectory.sample(plan, previous.end_s - .000000001)
      local _, outgoing = Trajectory.sample(plan, segment.start_s + .000000001)
      near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1)
    end
  end
  assert(merged or polished, "the chamfer retained separate tight corners")
  -- The previous certified merged group had radius 6.3 and bending energy
  -- .24935. Refitting its shared legs must improve both, rather than only
  -- remove the metadata naming the original merge.
  assert(tightest >= 7.5 and energy <= .22, "shared-leg refitting did not improve peak and total bending")
  assert((plan.polish_work or 0) <= 16384)
  for step = 0, 1500 do
    assert(path_distance(Trajectory.sample(plan, plan.total_length * step / 1500), points) <= 2 + .00000001)
  end
end)

test("asymmetric interior corners share their legs to reduce peak and total curvature", function()
  for _, sign in ipairs({-1, 1}) do
    for _, shift in ipairs({0, 1000000.25}) do
      local points = {point(shift, -shift), point(100 + shift, -shift),
        point(100 + shift, 5 * sign - shift), point(105 + shift, 10 * sign - shift),
        point(105 + shift, 100 * sign - shift), point(200 + shift, 100 * sign - shift)}
      local plan = Trajectory.build(path(points), 2)
      local tightest, energy, polished = math.huge, 0, false
      for index, segment in ipairs(plan.segments) do
        polished = polished or segment.polished == true
        if segment.radius then
          tightest = math.min(tightest, segment.radius)
          energy = energy + segment.length / (segment.radius * segment.radius)
        end
        if index > 1 then
          local before = plan.segments[index - 1]
          same(before.b, segment.a, .0000001)
          near(before.path_end, segment.path_start, .000001)
          local _, incoming = Trajectory.sample(plan, before.end_s - .00000001)
          local _, outgoing = Trajectory.sample(plan, segment.start_s + .00000001)
          near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1, .0000001)
        end
      end
      -- Half-leg construction: radius 3.618, energy .64581. The interior
      -- optimization doubles that limiting radius without adding a detour.
      assert(polished and tightest >= 7.2 and energy <= .33,
        "asymmetric interior corners still impose their old half-leg bottleneck")
      assert(plan.total_length <= plan.path_distances[#points] * 1.05)
      assert(plan.polish_work > 0 and plan.polish_work <= 16384)
      same(Trajectory.sample(plan, 0), points[1], .0000001)
      same(Trajectory.sample(plan, plan.total_length), points[#points], .0000001)
      local previous_source = -1
      for step = 0, 2000 do
        local s = plan.total_length * step / 2000
        local p = Trajectory.sample(plan, s)
        assert(path_distance(p, points) <= 2 + .0000001, "interior refit left its finite corridor")
        local source = Trajectory.source_distance(plan, s)
        assert(source >= previous_source - .0000001)
        near(Trajectory.at_source(plan, source), s, .000001)
        previous_source = source
      end
    end
  end
end)

test("full-clearance chords remove repeated opposite-turn lane shifts", function()
  local points = {point(0)}
  for index = 1, 10 do
    local y = (index - 1) % 2
    points[#points + 1] = point(index * 20 - 1, y)
    points[#points + 1] = point(index * 20, 1 - y)
  end
  local plan = Trajectory.build(path(points), 1.109)
  assert(#plan.segments == 1 and plan.segments[1].kind == "line",
    "one-tile lane shifts still force repeated small-radius turns")
  for step = 0, 1000 do
    assert(path_distance(Trajectory.sample(plan, plan.total_length * step / 1000), points) <= 1.109)
  end
end)

test("unsafe wide chamfers, reversals and tiny-angle merges keep a safe fallback", function()
  local cases = {
    {point(-100), point(-50), point(0, 50), point(0, 100)},
    {point(0), point(10), point(0), point(0, 10)},
    {point(0), point(10), point(20, .000000001), point(30, .000000003), point(40, 1)},
  }
  for _, points in ipairs(cases) do
    for _, clearance in ipairs({0, .000000001, .01, 1}) do
      local plan = Trajectory.build(path(points), clearance)
      for _, segment in ipairs(plan.segments) do
        assert(not segment.merged_corners, "an uncertain or nonconvex group was merged")
      end
      for step = 0, 500 do
        local p = Trajectory.sample(plan, plan.total_length * step / 500)
        assert(path_distance(p, points) <= clearance + .00000001)
      end
    end
  end
end)

test("merge certification has one fixed work budget on long winding paths", function()
  local points, x, y, dx, dy = {point(0)}, 0, 0, 1, 0
  for index = 1, 200 do
    x, y = x + dx * 20, y + dy * 20
    points[#points + 1] = point(x, y)
    x, y = x + dx - dy, y + dy + dx
    points[#points + 1] = point(x, y)
    dx, dy = -dy, dx
  end
  local plan = Trajectory.build(path(points), 1.109)
  assert(plan.merge_work > 0 and plan.merge_work <= 8192)
  assert(plan.racing_work > 0 and plan.racing_work <= 8192)
  assert(plan.bridge_work > 0 and plan.bridge_work <= 32768 + 64, "bridges overran their work budget")
  assert(plan.build_work <= Trajectory.WORK_LIMIT)
  assert(plan.total_length > 0)
  near(Trajectory.source_distance(plan, plan.total_length), plan.path_distances[#points])
  local last = -1
  for index, s in ipairs(plan.waypoint_s) do
    assert(s >= last)
    near(Trajectory.source_distance(plan, s), plan.path_distances[index], .00000001)
    last = s
  end
  for step = 0, 1000 do
    local p = Trajectory.sample(plan, plan.total_length * step / 1000)
    assert(path_distance(p, points) <= 1.109 + .00000001)
  end
end)

test("simplification never erases a reversal or reduces a closed path to a point", function()
  local reverse = Trajectory.build(path({point(0), point(4), point(0), point(0, 4)}), 100)
  assert(reverse.segments[1].kind == "line" and reverse.segments[2].kind == "line")
  same(reverse.segments[1].b, point(4))
  same(reverse.segments[2].a, point(4))
  local closed = {point(0), point(1), point(1, 1), point(0, 1), point(0)}
  local plan = Trajectory.build(path(closed), 100)
  assert(plan.total_length > 0 and #plan.segments > 0)
  same(Trajectory.sample(plan, 0), closed[1])
  same(Trajectory.sample(plan, plan.total_length), closed[#closed])
  near(Trajectory.source_distance(plan, plan.total_length), 4)
end)

test("zero and unknown clearance preserve every real corner and reversal", function()
  local points = {point(0), point(4), point(0), point(0, 4)}
  for _, clearance in ipairs({0, -1}) do
    local plan = Trajectory.build(path(points), clearance)
    assert(#plan.segments == 3)
    near(plan.total_length, 12)
    for index, p in ipairs(points) do same(Trajectory.sample(plan, plan.waypoint_s[index]), p) end
  end
  local unknown = Trajectory.build(path(points))
  assert(#unknown.segments == 3)
  near(unknown.total_length, 12)
  local rounded = Trajectory.build(path(points), 2)
  assert(rounded.segments[1].kind == "line" and rounded.segments[2].kind == "line")
  same(rounded.segments[1].b, points[2])
  same(rounded.segments[2].a, points[2])
end)

test("duplicate nodes, a stationary path and an empty path are well defined", function()
  local plan = Trajectory.build(path({point(0), point(0), point(2), point(2), point(4)}), 1)
  assert(#plan.segments == 1)
  near(plan.total_length, 4)
  near(plan.waypoint_s[1], plan.waypoint_s[2])
  near(plan.waypoint_s[3], plan.waypoint_s[4])
  local stationary = Trajectory.build(path({point(3, 4), point(3, 4)}), 1)
  assert(#stationary.segments == 0 and stationary.total_length == 0)
  same(Trajectory.sample(stationary, 100), point(3, 4))
  local s, offset, index = Trajectory.project(stationary, point(6, 8), 1)
  near(s, 0); near(offset, 5); assert(index == 0)
  local empty = Trajectory.build({}, 1)
  assert(Trajectory.sample(empty, 0) == nil)
  s, offset, index = Trajectory.project(empty, point(0))
  assert(s == 0 and offset == math.huge and index == 0)
end)

test("trajectory and original path distances map monotonically both ways", function()
  local points = {point(0), point(1), point(4), point(4, 1), point(4, 4), point(7, 4), point(10, 4)}
  local plan = Trajectory.build(path(points), .75)
  local last_source = -1
  for step = 0, 500 do
    local s = plan.total_length * step / 500
    local source = Trajectory.source_distance(plan, s)
    assert(source >= last_source)
    near(Trajectory.at_source(plan, source), s)
    last_source = source
  end
  for index, source in ipairs(plan.path_distances) do near(Trajectory.source_distance(plan, plan.waypoint_s[index]), source) end
end)

test("analytic projection finds on-arc points, endpoints and respects the progress floor", function()
  for _, turn in ipairs({-1, 1}) do
    local plan = Trajectory.build(path({point(0), point(10), point(10, 10 * turn)}), 1)
    for step = 0, 100 do
      local expected = plan.total_length * step / 100
      local p = Trajectory.sample(plan, expected)
      local s, offset = Trajectory.project(plan, p, 2)
      near(s, expected); near(offset, 0)
    end
    local s = Trajectory.project(plan, point(-10), 1, 3)
    near(s, 3)
    s = Trajectory.project(plan, point(10, 100 * turn), 3)
    near(s, plan.total_length)
  end
end)

test("projection inspects only a fixed local window on long winding paths", function()
  local points = {point(0)}
  for index = 1, 1000 do points[#points + 1] = point(index % 2, index) end
  local plan = Trajectory.build(path(points), .1)
  local original, reads = plan.segments, 0
  plan.segments = setmetatable({}, {__len = function() return #original end,
    __index = function(_, index) reads = reads + 1; return original[index] end})
  local s = Trajectory.project(plan, point(0, 500), 500)
  assert(s and reads <= 5, "projection work grew with path length")
end)

test("saved reference progress anchors projection when raw waypoints have advanced ahead", function()
  local points = {point(0)}
  for index = 1, 100 do points[#points + 1] = point(index % 2, index) end
  local plan = Trajectory.build(path(points), .1)
  local expected = plan.segments[2].start_s + plan.segments[2].length / 2
  local p = Trajectory.sample(plan, expected)
  local s, offset = Trajectory.project(plan, p, 90, 0, expected)
  near(s, expected); near(offset, 0)
  local wrong_s, wrong_offset = Trajectory.project(plan, p, 90)
  assert(wrong_s > expected + 10 and wrong_offset > 10, "fixture did not expose the advanced raw hint")
end)

test("translation and shallow turns preserve sampling and projection accuracy", function()
  local original = {point(0), point(10), point(20, .001), point(30, .001)}
  local translated = {}
  for index, p in ipairs(original) do translated[index] = point(p.x + 1000000.25, p.y - 1000000.5) end
  local plan, shifted = Trajectory.build(path(original), .01), Trajectory.build(path(translated), .01)
  near(plan.total_length, shifted.total_length, 0.00000001)
  for step = 0, 100 do
    local s = plan.total_length * step / 100
    local a = Trajectory.sample(plan, s)
    local b = Trajectory.sample(shifted, s)
    same(b, point(a.x + 1000000.25, a.y - 1000000.5), 0.00000001)
    local projected, offset = Trajectory.project(shifted, b, step < 50 and 2 or 3)
    near(projected, s, 0.000001); near(offset, 0, 0.00000001)
  end
end)

test("combined simplification and fillets preserve clearance on varied winding paths", function()
  math.randomseed(2371)
  for trial = 1, 80 do
    local points, heading = {point(0)}, 0
    for index = 1, 20 do
      heading = heading + (math.random() - .5) * math.pi
      local length = .1 + math.random() * 4
      local previous = points[#points]
      points[#points + 1] = point(previous.x + math.cos(heading) * length,
        previous.y + math.sin(heading) * length)
    end
    local clearance = .05 + math.random() * 3
    local plan = Trajectory.build(path(points), clearance)
    local source = -1
    for step = 0, 150 do
      local s = plan.total_length * step / 150
      local p, tangent = Trajectory.sample(plan, s)
      assert(path_distance(p, points) <= clearance + .00000001, "combined curve left its original corridor")
      near(tangent.x ^ 2 + tangent.y ^ 2, 1)
      local next_source = Trajectory.source_distance(plan, s)
      assert(next_source >= source)
      near(Trajectory.at_source(plan, next_source), s)
      source = next_source
    end
  end
end)

test("a short terminal chamfer uses extra margin without forcing the final leg's heading", function()
  -- The screenshot-shaped route: west, a north-west lane shift, west again,
  -- then a short south-west chamfer and a short final south leg. The goal is
  -- a stopping point; its final raw leg does not impose a parking heading.
  local original = {point(80, 60), point(40, 60), point(20, 40),
    point(-40, 40), point(-44, 44), point(-44, 48)}
  for _, mirror_x in ipairs({-1, 1}) do
    for _, mirror_y in ipairs({-1, 1}) do
      for _, shift in ipairs({0, 1000000.25}) do
        local points = {}
        for index, p in ipairs(original) do
          points[index] = point(p.x * mirror_x + shift, p.y * mirror_y - shift)
        end
        local peaks = {}
        for _, clearance in ipairs({1, 3}) do
          local plan = Trajectory.build(path(points), clearance)
          assert((plan.terminal_work or 0) <= 16384, "terminal certification exceeded its work budget")
          local tail_source = plan.path_distances[4]
          local peak = 0
          same(Trajectory.sample(plan, 0), points[1], .0000001)
          same(Trajectory.sample(plan, plan.total_length), points[#points], .0000001)
          local previous_source, previous_s = -1, 0
          for step = 0, 2000 do
            local s = plan.total_length * step / 2000
            local p, tangent, curvature = Trajectory.sample(plan, s)
            assert(path_distance(p, points) <= clearance + .0000001,
              "terminal smoothing left the finite original corridor")
            near(tangent.x * tangent.x + tangent.y * tangent.y, 1, .0000001)
            local source = Trajectory.source_distance(plan, s)
            assert(source >= previous_source - .0000001, "terminal source distance went backwards")
            near(Trajectory.at_source(plan, source), s, .000001)
            local projected, offset = Trajectory.project(plan, p, #points, nil, previous_s)
            near(projected, s, .000001)
            near(offset, 0, .0000001)
            if source >= tail_source then peak = math.max(peak, math.abs(curvature)) end
            previous_source, previous_s = source, s
          end
          for index = 2, #plan.segments do
            local before, after = plan.segments[index - 1], plan.segments[index]
            same(before.b, after.a, .0000001)
            near(before.path_end, after.path_start, .000001)
            local _, incoming = Trajectory.sample(plan, before.end_s - .00000001)
            local _, outgoing = Trajectory.sample(plan, after.start_s + .00000001)
            near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1, .0000001,
              "terminal smoothing introduced a heading discontinuity")
          end
          assert(peak > 0, "fixture lost its terminal turn")
          peaks[clearance] = peak
        end
        -- The former half-leg construction retained radius 7.236 even at
        -- clearance 3 and 5. Extra room must improve the tightest tail turn.
        assert(peaks[3] <= 1 / 15, "the terminal chamfer still imposes a tight turn: " .. peaks[3])
        assert(peaks[3] <= peaks[1] * .8, "extra margin did not meaningfully reduce terminal curvature")
      end
    end
  end
end)

test("gentle entry corrections do not inherit a distant corner's tight radius", function()
  -- A native hairpin regression exposed an extra brake/accelerate cycle:
  -- equal-radius refitting put a tiny tight arc far before the main bend.
  -- This compact route reproduces that geometry with ordinary Lua math.
  local points = {point(0), point(40), point(40, 10), point(120, 10), point(120, 90)}
  local plan = Trajectory.build(path(points), 2)
  local first_arc, tightest = nil, math.huge
  for index, piece in ipairs(plan.segments) do
    if piece.radius then first_arc, tightest = first_arc or piece, math.min(tightest, piece.radius) end
    if index > 1 then
      local before = plan.segments[index - 1]
      same(before.b, piece.a)
      near(before.path_end, piece.path_start)
      local _, incoming = Trajectory.sample(plan, before.end_s - 1e-9)
      local _, outgoing = Trajectory.sample(plan, piece.start_s + 1e-9)
      near(incoming.x * outgoing.x + incoming.y * outgoing.y, 1)
    end
  end
  assert(first_arc and first_arc.radius > 100 and first_arc.radius > tightest * 8,
    "a tiny approach correction introduced an early low-radius braking bottleneck")
  for step = 0, 1000 do
    local s = plan.total_length * step / 1000
    assert(path_distance(Trajectory.sample(plan, s), points) <= 2 + 1e-8)
    near(Trajectory.at_source(plan, Trajectory.source_distance(plan, s)), s)
  end
end)

local function private(fn, name)
  for index = 1, 100 do
    local key, value = debug.getupvalue(fn, index)
    if key == name then return value end
    if not key then break end
  end
  error("missing test fixture upvalue " .. name)
end

test("bend scoring measures the surviving arcs after an empty correction disappears", function()
  local polish = private(Trajectory.build, "polish_bends")
  local connect, score = private(polish, "arc_line_arc"), private(polish, "bend_score")
  local pieces = connect(point(0), point(1), point(10 + 16 * math.sin(.5), 16 * (1 - math.cos(.5))),
    point(math.cos(.5), math.sin(.5)), 1, 1, 1, 16)
  assert(pieces and #pieces == 2 and pieces[1].kind == "line" and pieces[2].kind == "arc",
    "fixture must omit the nominal one-tile correction arc")
  local length, energy, radius = score(pieces)
  near(length, 18); near(energy, .5 / 16); near(radius, 16)
  local _, _, narrower = score({{kind = "arc", radius = 2, sweep = .5}})
  assert(radius > narrower, "the omitted nominal radius undervalued the wider candidate")
  local _, straight_energy, straight_radius = score({{kind = "line", length = 10}})
  assert(straight_radius == math.huge and straight_energy == 0)
end)

test("bend selection prefers the actual surviving radius over a larger nominal proposal", function()
  local polish = private(Trajectory.build, "polish_bends")
  local fillet = private(Trajectory.build, "fillet")
  local append, append_line = private(Trajectory.build, "append"), private(Trajectory.build, "append_line")
  local make_budget = private(Trajectory.build, "budget")
  local angle, trim = .5, math.tan(.25)
  local q = point(10 + 32 * math.sin(angle), 32 * (1 - math.cos(angle)))
  local points = path({point(0), point(q.x - q.y / math.tan(angle)),
    point(q.x + 2 * trim * math.cos(angle), q.y + 2 * trim * math.sin(angle))})
  points[4] = {position = point(points[3].position.x + 2 * trim + 1000, points[3].position.y)}
  local distances, raw = {}, {}
  for index, p in ipairs(points) do
    local before = points[index - 1]
    local distance = before and math.sqrt((p.position.x - before.position.x) ^ 2
      + (p.position.y - before.position.y) ^ 2) or 0
    p.index, p.original_index, p.source = index, index, (distances[index - 1] or 0) + distance
    distances[index] = p.source
    raw[index] = p.position
  end
  -- A valid starting reference with two tight bends. Refitting its shared
  -- legs produces candidates whose nominal correction arcs disappear.
  local a = fillet(points[1], points[2], points[3], 1 - math.cos(.25))
  local b = fillet(points[2], points[3], points[4], 2 * (1 - math.cos(.25)))
  near(a.radius, 1); near(b.radius, 2)
  local plan = {segments = {}, total_length = 0, path_distances = distances, point = points[4].position}
  append_line(plan, points[1].position, a.a, 0, a.path_start, 1, 2)
  append(plan, a, a.radius * math.abs(a.sweep))
  append_line(plan, a.b, b.a, a.path_end, b.path_start, 2, 3)
  append(plan, b, b.radius * math.abs(b.sweep))
  append_line(plan, b.b, points[4].position, b.path_end, distances[4], 3, 4)
  polish(plan, points, 5, make_budget(8192))
  local tightest = math.huge
  for index, piece in ipairs(plan.segments) do
    if piece.radius then tightest = math.min(tightest, piece.radius) end
    if index > 1 then same(plan.segments[index - 1].b, piece.a) end
  end
  assert(tightest > 3.9, "nominal scoring discarded the wider surviving arcs")
  same(Trajectory.sample(plan, 0), points[1].position)
  same(Trajectory.sample(plan, plan.total_length), points[4].position)
  for step = 0, 500 do
    local s = plan.total_length * step / 500
    assert(path_distance(Trajectory.sample(plan, s), raw) <= 5 + 1e-8)
    near(Trajectory.at_source(plan, Trajectory.source_distance(plan, s)), s, 1e-6)
  end
end)

test("direct piece positions match route sampling without aliasing its geometry", function()
  local plan = Trajectory.build(path({point(0), point(30), point(30, 20), point(70, 20)}), 2)
  for _, segment in ipairs(plan.segments) do
    for _, t in ipairs({0, .1, .5, .9, 1}) do
      local direct = Trajectory.segment_position(segment, t)
      same(direct, Trajectory.sample(plan, segment.start_s + t * segment.length), 1e-7)
      local original_x = segment.a.x
      direct.x = direct.x + 100
      near(segment.a.x, original_x)
    end
    same(Trajectory.segment_position(segment, -1), segment.a)
    same(Trajectory.segment_position(segment, 2), segment.b)
  end
end)

test("scalar projection preserves endpoint floors and shallow-arc tracking distances", function()
  local arc_from = private(private(Trajectory.build, "terminal_curve"), "arc_from")
  local project = private(Trajectory.project, "project_segment")
  -- Slow reference: project an angle, then sample the actual point. This
  -- independently checks the rationalized distance used by the hot path.
  local function reference(piece, position, floor)
    local minimum = math.max(0, math.min(1, (floor - piece.start_s) / (piece.end_s - piece.start_s)))
    local dx, dy = position.x - piece.a.x, position.y - piece.a.y
    local ux, uy = piece.tangent.x, piece.tangent.y
    local sign = piece.sweep > 0 and 1 or -1
    local angle = (math.atan2 or function(y, x) return math.atan(y, x) end)(
      dx * ux + dy * uy, piece.radius - (-dx * uy + dy * ux) * sign) % (2 * math.pi)
    local t
    if angle >= minimum * math.abs(piece.sweep) and angle <= math.abs(piece.sweep) then
      t = angle / math.abs(piece.sweep)
    else
      local first = Trajectory.segment_position(piece, minimum)
      local a = (position.x - first.x) ^ 2 + (position.y - first.y) ^ 2
      local b = (position.x - piece.b.x) ^ 2 + (position.y - piece.b.y) ^ 2
      t = a <= b and minimum or 1
    end
    local s = math.min(piece.end_s, math.max(floor, piece.start_s + t * piece.length))
    local closest = Trajectory.segment_position(piece, (s - piece.start_s) / (piece.end_s - piece.start_s))
    return s, math.sqrt((position.x - closest.x) ^ 2 + (position.y - closest.y) ^ 2)
  end
  for _, radius in ipairs({.001, 3, 1e6, 1e12, 1e20}) do
    for _, sign in ipairs({-1, 1}) do
      for _, origin in ipairs({0, 1000000.25}) do
        local piece = arc_from(point(origin, -origin), point(.6, .8), radius,
          sign * math.min(.8, 100 / radius))
        piece.length = radius * math.abs(piece.sweep)
        piece.start_s, piece.end_s = 11, 11 + piece.length
        for _, t in ipairs({-.2, 0, .1, .5, .99, 1, 1.2}) do
          local angle = math.abs(piece.sweep) * t
          local along, across = radius * math.sin(angle), radius * 2 * math.sin(angle / 2) ^ 2 * sign
          for _, offset in ipairs({-.001, 0, .001, 3}) do
            local position = point(piece.a.x + .6 * along - .8 * across - .8 * offset,
              piece.a.y + .8 * along + .6 * across + .6 * offset)
            for _, minimum in ipairs({0, .4, .9}) do
              local floor = piece.start_s + minimum * piece.length
              local expected_s, expected_distance = reference(piece, position, floor)
              local s, distance = project(piece, position, floor)
              near(s, expected_s, 1e-7); near(distance, expected_distance, 1e-7)
              assert(s >= floor - 1e-8)
            end
          end
        end
      end
    end
  end
  local piece = arc_from(point(0), point(1), 10, 1)
  piece.length, piece.start_s, piece.end_s = 10, 0, 10
  local position = point(4, 2)
  for _ = 1, 100 do project(piece, position) end
  collectgarbage("collect"); collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 2000 do project(piece, position) end
  local growth = collectgarbage("count") - before
  collectgarbage("restart")
  assert(growth < 16, "projection allocated temporary positions or tangents: " .. growth .. " KiB")
end)

test("clearance certificates pair both chord endpoints with the same finite leg", function()
  local certify = private(private(Trajectory.build, "certify"), "certify_pieces")
  local make_budget = private(Trajectory.build, "budget")
  local original = path({point(0), point(0, 10), point(10, 10)})
  local diagonal = {kind = "line", a = point(0), b = point(10, 10), length = math.sqrt(200),
    tangent = point(math.sqrt(.5), math.sqrt(.5))}
  -- Both endpoints lie ON the path, but the middle is five tiles away.
  -- Using max(nearest endpoint distances) would falsely accept this chord.
  for _, clearance in ipairs({1, 4.99}) do
    assert(not certify({diagonal}, original, 1, 3, clearance, make_budget(4096)), "unsafe diagonal was certified")
  end
  local safe, bound = certify({diagonal}, original, 1, 3, 5.01, make_budget(4096))
  assert(safe and bound >= 5 and bound <= 5.01)
end)

test("every optional stage shares one build budget and safely handles exhaustion", function()
  local points = {point(0)}
  for index = 1, 80 do points[#points + 1] = point(index * 2, index % 2 * 4) end
  for _, limit in ipairs({0, 1, 7, 32, 128, 512, 2048, Trajectory.WORK_LIMIT}) do
    local plan = Trajectory.build(path(points), 1, limit)
    assert(plan.work_limit == limit and plan.build_work <= limit)
    local sum = 0
    for _, stage in ipairs({"simplify", "merge", "racing", "bridge", "polish", "terminal"}) do
      sum = sum + (plan[stage .. "_work"] or 0)
    end
    assert(sum == plan.build_work, "a stage escaped the shared budget")
    same(Trajectory.sample(plan, 0), points[1])
    same(Trajectory.sample(plan, plan.total_length), points[#points])
    local previous = -1
    for step = 0, 300 do
      local distance = plan.total_length * step / 300
      assert(path_distance(Trajectory.sample(plan, distance), points) <= 1 + 1e-8)
      local source = Trajectory.source_distance(plan, distance)
      assert(source >= previous)
      near(Trajectory.at_source(plan, source), distance, 1e-7)
      previous = source
    end
  end
end)

test("construction attempts debit both budgets before acceptance or rejection", function()
  local make_budget = private(Trajectory.build, "budget")
  local construct = private(private(Trajectory.build, "polish_bends"), "construct")
  -- Either the stage or the shared build can be the limiting budget. A
  -- charged attempt counts even when its caller later rejects the shape.
  for _, limits in ipairs({{8, 16}, {16, 8}}) do
    local shared = make_budget(limits[2])
    local stage = make_budget(limits[1], shared)
    assert(construct(stage, 8), "the first construction should fit")
    assert(stage.used == 8 and shared.used == 8 and shared.attempts == 1,
      "construction escaped the local or shared budget")
    local local_remaining, shared_remaining = stage.remaining, shared.remaining
    assert(not construct(stage, 1), "exhaustion allowed another construction")
    assert(stage.remaining == local_remaining and shared.remaining == shared_remaining
      and stage.used == 8 and shared.used == 8 and shared.attempts == 1,
      "a rejected debit partially spent work or counted an unperformed attempt")
  end
end)

test("actual rejected constructors and recursive DP checks stay bounded", function()
  local points = {}
  for index = 1, 1024 do points[index] = point(index * 10, index % 2 * 10) end
  for _, limit in ipairs({0, 512, Trajectory.WORK_LIMIT}) do
    local calls = {shapes = 0, distances = 0}
    local previous, mask, count = debug.gethook()
    debug.sethook(function()
      local info = debug.getinfo(2, "n")
      if info.name == "arc_line_arc" or info.name == "lane_shift" or info.name == "arc_from" then
        calls.shapes = calls.shapes + 1
      elseif info.name == "segment_distance_sq" then calls.distances = calls.distances + 1 end
    end, "c")
    local ok, plan = pcall(Trajectory.build, path(points), 2, limit)
    if previous then debug.sethook(previous, mask, count) else debug.sethook() end
    assert(ok, plan)
    if limit == 0 then assert(calls.shapes == 0, "exhausted budget still constructed optional curves") end
    assert(calls.shapes <= limit, "rejected shape construction bypassed the work budget")
    assert(calls.distances <= #points + plan.build_work, "recursive simplification or certificates escaped accounting")
  end
end)

test("easy long staircases still compress after optional refinement is exhausted", function()
  local points = {}
  for index = 0, 4095 do points[#points + 1] = point(index, math.floor(index / 2)) end
  local plan = Trajectory.build(path(points), 2.08, 0)
  assert(#plan.segments < 300, "exhaustion expanded a straight staircase into thousands of tight corners")
  assert(plan.build_work == 0)
  for step = 0, 500 do
    local distance = plan.total_length * step / 500
    assert(path_distance(Trajectory.sample(plan, distance), points) <= 2.08 + 1e-8)
    near(Trajectory.at_source(plan, Trajectory.source_distance(plan, distance)), distance, 1e-7)
  end
end)

test("a worse vehicle-cost refit restores the banked certified reference", function()
  local points = {point(0), point(100), point(100, 5), point(105, 10), point(105, 100), point(200, 100)}
  local calls = 0
  local function reject(pieces)
    calls = calls+1
    for _, piece in ipairs(pieces) do if piece.polished or piece.terminal then return 1000 end end
    return 1
  end
  local plan = Trajectory.build(path(points), 2, nil, reject)
  assert(calls >= 2 and calls <= 3 and plan.refit_rejected and plan.scoring_work > 0)
  local sum = plan.scoring_work
  for _, stage in ipairs({"simplify", "merge", "racing", "bridge", "polish", "terminal"}) do sum = sum+(plan[stage.."_work"] or 0) end
  assert(sum == plan.build_work and sum <= plan.work_limit)
  for _, piece in ipairs(plan.segments) do assert(not piece.polished and not piece.terminal) end
  local previous = -1
  for step = 0, 500 do
    local s = plan.total_length*step/500
    assert(path_distance(Trajectory.sample(plan, s), points) <= 2+1e-7)
    local source = Trajectory.source_distance(plan, s)
    assert(source >= previous)
    near(Trajectory.at_source(plan, source), s, 1e-6)
    previous = source
  end
end)

for _, entry in ipairs(tests) do entry[2](); print("PASS " .. entry[1]) end
print(#tests .. " vehicle trajectory tests passed")
