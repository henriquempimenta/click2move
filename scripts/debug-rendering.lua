-- Optional, player-private diagnostics. Draw the same geometry steering uses;
-- never run the controller or change its projection progress for a preview.
local Config = require("scripts/config")
local VehicleSpeed = require("scripts/vehicle-speed")
local Trajectory = require("scripts/vehicle-trajectory")
local Bezier = require("scripts/bezier-preview")
local DebugRendering = {}
local CYAN = {r = .1, g = .8, b = 1, a = .65}
local ORANGE = {r = 1, g = .45, b = .05, a = .7}
local MAGENTA = {r = 1, g = .15, b = .8, a = 1}
local WHITE = {r = 1, g = 1, b = 1, a = 1}
local GREEN = {r = .2, g = 1, b = .25, a = 1}
local MODES = {"game", "chart"}
local MAX_OBJECTS = 4096

function DebugRendering.draw(player, data, goal, points, surface, objects)
  local config = Config.get(player.index)
  local entity = data.move_entity
  if not entity or not entity.valid or #points == 0 then return end
  local car = entity.type == "car"
  local geometry, available, tracking
  if car and goal.path then
    geometry, available, tracking = VehicleSpeed.trajectory(entity, goal.path, goal.path_clearance, nil, goal, data.preview)
  end
  local bezier = config.debug_bezier and geometry and Bezier.build(goal.path, math.max(0, available-tracking))
  local count, limited = 0, false
  local function draw(kind, options, mode)
    if count >= MAX_OBJECTS then limited = true; return end
    options.surface, options.players = surface, {player}
    options.render_mode, options.time_to_live = mode, 0
    objects[#objects + 1] = rendering[kind](options)
    count = count + 1
  end
  -- A union of segment capsules shows allowed centerline deviation around the
  -- original path. This is NOT the actor's swept collision box or obstacle edge.
  local function corridor(radius, color, mode)
    if not radius or radius <= 0 then return end
    for index, point in ipairs(points) do
      if count >= MAX_OBJECTS then limited = true; break end
      draw("draw_circle", {color = color, radius = radius, width = 1,
        filled = false, target = point}, mode)
      local previous = points[index - 1]
      if previous then
        local dx, dy = point.x - previous.x, point.y - previous.y
        local length = math.sqrt(dx * dx + dy * dy)
        if length > 0 then
          for _, side in ipairs({-1, 1}) do
            local x, y = -dy / length * radius * side, dx / length * radius * side
            draw("draw_line", {color = color, width = 1,
              from = {x = previous.x + x, y = previous.y + y},
              to = {x = point.x + x, y = point.y + y}}, mode)
          end
        end
      end
    end
  end
  for _, mode in ipairs(MODES) do
    if config.debug_curve and geometry then
      for _, segment in ipairs(geometry.segments) do
        if count >= MAX_OBJECTS then limited = true; break end
        -- Drawing chords stay within .02 tiles of the exact arc, also for
        -- very wide turns. The sine form avoids cancellation at large radii.
        -- Steering continues to sample the exact arc.
        local steps = 1
        if segment.radius then
          local angle = math.min(.1, 4 * math.asin(math.sqrt(math.min(1, .02 / (2 * segment.radius)))))
          steps = math.max(1, math.ceil(math.abs(segment.sweep) / angle))
        end
        local previous = Trajectory.segment_position(segment, 0)
        for step = 1, steps do
          local point = Trajectory.segment_position(segment, step / steps)
          draw("draw_line", {color = MAGENTA, width = 3, from = previous, to = point}, mode)
          previous = point
          if count >= MAX_OBJECTS then limited = true; break end
        end
      end
    end
    if bezier then
      for _, piece in ipairs(bezier.pieces) do
        if count >= MAX_OBJECTS then limited = true; break end
        local steps = piece.kind == "line" and 1 or 32
        local previous = piece.a
        for step = 1, steps do
          local point = Bezier.position(piece, step/steps)
          draw("draw_line", {color = GREEN, width = 2, from = previous, to = point}, mode)
          previous = point
          if count >= MAX_OBJECTS then limited = true; break end
        end
      end
    end
    if config.debug_margins and not data.is_straight_line_move and entity.type ~= "spider-vehicle" then
      corridor(goal.path_clearance, CYAN, mode)
      if geometry then corridor(math.max(0, available - tracking), ORANGE, mode) end
    end
  end
  local margin = goal.path_clearance
  local text = {"click2move.debug-legend", data.preview and {"click2move.debug-preview"} or "",
    config.debug_margins and (margin ~= nil and string.format("%.2f", margin) or "?") or "-",
    config.debug_margins and available and string.format("%.2f", math.max(0, available - tracking)) or "-",
    config.debug_curve and geometry and {"click2move.debug-reference"} or "-"}
  if bezier then
    text = {"", text, "\n", {"click2move.debug-bezier-reference"}}
    if bezier.fallback then text = {"", text, "\n", {"click2move.debug-bezier-fallback"}} end
    if bezier.limited then text = {"", text, "\n", {"click2move.debug-bezier-limit"}} end
  end
  for _, mode in ipairs(MODES) do
    -- The legend always survives an object cap and states that the overlay is partial.
    objects[#objects + 1] = rendering.draw_text{
      text = limited and {"", text, "\n", {"click2move.debug-overlay-limit"}} or text,
      color = WHITE, target = {x = points[1].x, y = points[1].y - 2},
      surface = surface, players = {player}, render_mode = mode,
      alignment = "left", scale = 1, scale_with_zoom = mode == "chart", time_to_live = 0
    }
  end
end

return DebugRendering
