--[[
  Click2Move - Utility Functions
  Pure helper functions with no dependencies on game state.
]]

local Util = {}

-- Format position for GUI text
---@param pos MapPosition?
---@return string
function Util.format_pos(pos)
  if not pos then return "(?, ?)" end
  return string.format("(%.2f, %.2f)", pos.x, pos.y)
end

-- Squared distance (faster than sqrt for comparisons)
---@param a MapPosition
---@param b MapPosition
---@return number
function Util.distance_sq(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return dx * dx + dy * dy
end

-- Safe destroy of rendering Lua objects (they are LuaRenderObject instances)
---@param render_objs LuaRenderObject[]?
function Util.safe_destroy_renderings(render_objs)
  if not render_objs then return end
  for _, render_obj in ipairs(render_objs) do
    if render_obj and render_obj.valid then
      render_obj:destroy()
    end
  end
end

-- Debug utility: recursively convert a table to a printable string
---@param tbl any
---@return string
function Util.tableToString(tbl)
  if type(tbl) ~= "table" then return tostring(tbl) end
  local str = "{ "
  for k, v in pairs(tbl) do
    str = str .. "[" .. tostring(k) .. "] = " .. Util.tableToString(v) .. ", "
  end
  str = str:sub(1, -3) .. " }"
  return str
end

return Util
