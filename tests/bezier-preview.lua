local Preview = require("scripts/bezier-preview")
local function p(x, y) return {x = x, y = y or 0} end
local function distance(q, a, b)
  local dx, dy = b.x-a.x, b.y-a.y
  local t = math.max(0, math.min(1, ((q.x-a.x)*dx+(q.y-a.y)*dy)/(dx*dx+dy*dy)))
  return math.sqrt((q.x-a.x-t*dx)^2+(q.y-a.y-t*dy)^2)
end
local function near(a, b, tolerance)
  assert(math.abs(a.x-b.x) <= tolerance and math.abs(a.y-b.y) <= tolerance, "position mismatch")
end
local tests = 0
for _, origin in ipairs({0, 1000000.25}) do
  for _, sign in ipairs({-1, 1}) do
    for _, allowance in ipairs({.0001, .36, 1.11, 2.08, 3}) do
      local points = {p(origin, origin), p(origin+40, origin), p(origin+40, origin+20*sign),
        p(origin+60, origin+20*sign), p(origin+60, origin+60*sign)}
      local curve = Preview.build(points, allowance)
      near(curve.pieces[1].a, points[1], 1e-8)
      near(curve.pieces[#curve.pieces].b, points[#points], 1e-8)
      assert(curve.work <= Preview.WORK_LIMIT)
      local bends = 0
      for index, piece in ipairs(curve.pieces) do
        if index > 1 then near(curve.pieces[index-1].b, piece.a, 1e-8) end
        if piece.kind == "bezier" then
          bends = bends+1
          -- Both inner controls coincide at vertex. C'(0), C''(0) are
          -- parallel, likewise at 1: endpoint curvature is exactly zero.
          local ux, uy = piece.vertex.x-piece.a.x, piece.vertex.y-piece.a.y
          local vx, vy = piece.b.x-piece.vertex.x, piece.b.y-piece.vertex.y
          local previous = curve.pieces[index-1]
          if previous and previous.kind == "line" then
            assert(math.abs(ux*(previous.b.y-previous.a.y)-uy*(previous.b.x-previous.a.x)) < 1e-7)
          end
          for step = 0, 300 do
            local t = step/300
            local point = Preview.position(piece, t)
            local nearest = math.huge
            for edge = 1, #points-1 do nearest = math.min(nearest, distance(point, points[edge], points[edge+1])) end
            assert(nearest <= allowance+1e-8, "Bezier left original corridor")
            local dx, dy = (1-t)^2*ux+t*t*vx, (1-t)^2*uy+t*t*vy
            assert(dx*dx+dy*dy > 0, "Bezier developed a cusp")
          end
        end
      end
      assert(bends > 0, "ordinary bends did not get a Bezier preview")
      near(points[2], p(origin+40, origin), 0)
      tests = tests+1
    end
  end
end
for _, allowance in ipairs({0, .5, 3}) do
  local points = {p(0), p(10), p(0)}
  local curve = Preview.build(points, allowance)
  assert(curve.fallback and #curve.pieces == 2)
  near(curve.pieces[1].b, p(10), 0)
  near(curve.pieces[2].b, p(0), 0)
  tests = tests+1
end
local points = {}
for index = 1, Preview.NODE_LIMIT+100 do points[index] = p(index, index%2) end
local large = Preview.build(points, .36)
assert(large.limited and large.work <= Preview.WORK_LIMIT and #large.pieces <= Preview.NODE_LIMIT*2)
assert(Preview.build({}, 2).work == nil)
assert(#Preview.build({p(0), p(0)}, 2).pieces == 0)
print(string.format("%d Bezier corridor/symmetry/reversal cases plus bounded-input checks passed", tests))
