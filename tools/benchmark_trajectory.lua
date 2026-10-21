-- Offline benchmark bridge. Run from the repository root with a generated
-- Lua input file; only construction is timed, not process startup or encoding.
local Trajectory = require("scripts/vehicle-trajectory")
local requests = dofile(assert(arg[1], "missing benchmark input"))
local function encode(value)
  if type(value) == "number" then
    assert(value == value and math.abs(value) < math.huge, "non-finite benchmark value")
    return string.format("%.17g", value)
  elseif type(value) == "string" then return string.format("%q", value)
  elseif type(value) == "boolean" then return tostring(value)
  elseif type(value) == "table" then
    local parts = {}
    if #value > 0 then
      for _, item in ipairs(value) do parts[#parts + 1] = encode(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do parts[#parts + 1] = encode(key) .. ":" .. encode(item) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("unsupported benchmark value")
end
for _, request in ipairs(requests) do
  local path = {}
  for i, p in ipairs(request.points) do path[i] = {position = {x = p[1], y = p[2]}} end
  Trajectory.build(path, request.clearance, request.work)
  local times, plan = {}, nil
  for trial = 1, request.repeats do
    collectgarbage("collect")
    local started = os.clock()
    plan = Trajectory.build(path, request.clearance, request.work)
    times[trial] = (os.clock() - started) * 1000
  end
  local checks = {}
  for index, segment in ipairs(plan.segments) do
    local p = Trajectory.segment_position(segment, .5)
    checks[index] = {p.x, p.y}
  end
  print(encode({id = request.id, times_ms = times, plan = plan, midpoint_checks = checks}))
end
