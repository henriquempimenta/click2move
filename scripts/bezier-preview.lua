-- Experimental visual reference only. Cubics with coincident inner controls
-- meet straight legs tangentially with zero endpoint curvature. No solver,
-- movement state or controller consumes this module.
local Preview = {}
Preview.WORK_LIMIT = 4096
Preview.NODE_LIMIT = 1024
local function copy(p) return {x = p.x, y = p.y} end
local function midpoint(a, b) return {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2} end
local function distance(p, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local length = dx * dx + dy * dy
  local t = length > 0 and math.max(0, math.min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/length)) or 0
  return (p.x-a.x-t*dx)^2 + (p.y-a.y-t*dy)^2
end
local function spend(work, cost)
  if work.used + cost > Preview.WORK_LIMIT then work.limited = true; return false end
  work.used = work.used + cost
  return true
end
local function split(c)
  local a, b, d = midpoint(c[1], c[2]), midpoint(c[2], c[3]), midpoint(c[3], c[4])
  local e, f = midpoint(a, b), midpoint(b, d)
  local p = midpoint(e, f)
  return {c[1], a, e, p}, {p, f, d, c[4]}
end
local function certify(c, a, vertex, b, allowance, work)
  local stack = {{c, 0}}
  while #stack > 0 do
    if not spend(work, 24) then return false end
    local entry = table.remove(stack)
    local controls, depth = entry[1], entry[2]
    local d1, d2 = 0, 0
    for _, p in ipairs(controls) do
      d1, d2 = math.max(d1, distance(p, a, vertex)), math.max(d2, distance(p, vertex, b))
    end
    -- A segment capsule is convex. Containing all controls in ONE capsule
    -- proves containment of its entire Bezier convex hull; otherwise split.
    if math.min(d1, d2) > allowance * allowance then
      if depth == 12 then return false end
      local left, right = split(controls)
      local p = left[4]
      if math.min(distance(p, a, vertex), distance(p, vertex, b)) > allowance*allowance then return false end
      stack[#stack+1], stack[#stack+2] = {right, depth+1}, {left, depth+1}
    end
  end
  return true
end

function Preview.position(piece, t)
  if t == 0 then return copy(piece.a) elseif t == 1 then return copy(piece.b) end
  if piece.kind == "line" then
    return {x = piece.a.x + (piece.b.x-piece.a.x)*t, y = piece.a.y + (piece.b.y-piece.a.y)*t}
  end
  -- Local coordinates reduce cancellation far from the origin.
  local u, p = 1-t, piece.vertex
  local w, z = 3*u*u*t+3*u*t*t, t*t*t
  return {x = piece.a.x + w*(p.x-piece.a.x)+z*(piece.b.x-piece.a.x),
    y = piece.a.y + w*(p.y-piece.a.y)+z*(piece.b.y-piece.a.y)}
end

function Preview.build(path, clearance)
  local points, work = {}, {used = 0}
  local truncated = #path > Preview.NODE_LIMIT
  for index = 1, math.min(#path, Preview.NODE_LIMIT) do
    local p = path[index].position or path[index]
    local b, a = points[#points], points[#points-1]
    if not b or p.x ~= b.x or p.y ~= b.y then
      while a and (b.x-a.x)*(p.y-b.y)-(b.y-a.y)*(p.x-b.x) == 0
          and (b.x-a.x)*(p.x-b.x)+(b.y-a.y)*(p.y-b.y) > 0 do
        points[#points] = nil
        b, a = points[#points], points[#points-1]
      end
      points[#points+1] = p
    end
  end
  local result = {pieces = {}, limited = truncated, fallback = false}
  if #points == 0 then return result end
  local cursor = points[1]
  local function line(to)
    if to.x ~= cursor.x or to.y ~= cursor.y then
      result.pieces[#result.pieces+1] = {kind = "line", a = copy(cursor), b = copy(to)}
    end
    cursor = to
  end
  for index = 2, #points-1 do
    local a, v, b = points[index-1], points[index], points[index+1]
    local ix, iy, ox, oy = v.x-a.x, v.y-a.y, b.x-v.x, b.y-v.y
    local incoming, outgoing = math.sqrt(ix*ix+iy*iy), math.sqrt(ox*ox+oy*oy)
    local ux, uy, vx, vy = ix/incoming, iy/incoming, ox/outgoing, oy/outgoing
    local dot, piece = ux*vx+uy*vy, nil
    if clearance and clearance > 0 and dot > -1 + 1e-6 and dot < 1 - 1e-10 and not work.limited then
      local trim = math.min(incoming/2, outgoing/2, clearance*8)
      local magnitude = math.max(math.abs(a.x), math.abs(a.y), math.abs(v.x), math.abs(v.y), math.abs(b.x), math.abs(b.y))
      local allowance = clearance - 64*2.220446049250313e-16*(1+magnitude)
      for _ = 1, 8 do
        if allowance <= 0 or not spend(work, 8) then break end
        local start, finish = {x = v.x-ux*trim, y = v.y-uy*trim}, {x = v.x+vx*trim, y = v.y+vy*trim}
        if (start.x == v.x and start.y == v.y) or (finish.x == v.x and finish.y == v.y) then break end
        if certify({start, v, v, finish}, a, v, b, allowance, work) then
          piece = {kind = "bezier", a = start, vertex = copy(v), b = finish}; break
        end
        trim = trim * .7
      end
    end
    if piece then
      line(piece.a)
      result.pieces[#result.pieces+1], cursor = piece, piece.b
    else
      line(v)
      result.fallback = true
    end
  end
  line(points[#points])
  result.work, result.limited = work.used, result.limited or work.limited == true
  return result
end

return Preview
