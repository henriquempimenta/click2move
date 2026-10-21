-- Actual engine rendering objects; headless saves have no player to assign
-- visibility to. Player-private options are checked by the lifecycle mocks.
local Config = require("scripts/config")
local DebugRendering = require("scripts/debug-rendering")
local Speed = require("scripts/vehicle-speed")
script.on_init(function()
  local native = rendering
  rendering = setmetatable({}, {__index = native})
  for _, name in ipairs({"draw_line", "draw_circle", "draw_text"}) do
    rendering[name] = function(options) options.players = nil; return native[name](options) end
  end
  Config.get = function() return {debug_margins = true, debug_curve = true, debug_bezier = true} end
  local surface = game.surfaces[1]
  local car = surface.create_entity{name = "car", position = {0, 0}, force = "player"}
  local path = {{position = {x = 0, y = 0}}, {position = {x = 20, y = 0}},
    {position = {x = 20, y = 20}}, {position = {x = 40, y = 20}}}
  local points = {} for i, p in ipairs(path) do points[i] = p.position end
  local data = {move_entity = car, preview = true, current_waypoint = 1}
  for _, margin in ipairs({.5, 1, 2, 3, 4}) do
    local objects = {}
    DebugRendering.draw({index = 1}, data, {path = path, path_clearance = margin}, points, surface, objects)
    local green, magenta = 0, 0
    for _, object in ipairs(objects) do
      assert(object.valid)
      local color = object.color
      if color and math.abs(color.g-1) < 1e-6 and math.abs(color.b-.25) < 1e-6 then green = green+1 end
      if color and math.abs(color.g-.15) < 1e-6 and math.abs(color.b-.8) < 1e-6 then magenta = magenta+1 end
      object.destroy()
      assert(not object.valid)
    end
    assert(green > 0 and magenta > 0, "missing experimental or actual reference")
    assert(car.speed == 0 and car.position.x == 0 and car.position.y == 0, "preview moved the car")
    assert(not data.vehicle_trajectory and data.current_waypoint == 1, "preview changed controller progress")
  end
  local goal = {path = path, path_clearance = 3}
  Speed.trajectory(car, path, 3, nil, goal, true)
  assert(goal.vehicle_reference, "preview did not save its committed reference")
  storage.reference_probe = {actor = car, goal = goal}
  print("C2M_NATIVE_BEZIER_PREVIEW_OK margins=5")
end)
script.on_event(defines.events.on_tick, function()
  local probe = storage.reference_probe
  if not probe then return end
  local goal = probe.goal
  local saved = goal.vehicle_reference.geometry
  local context = Speed.create_context(probe.actor)
  context.model.brake = context.model.brake*2
  local geometry = Speed.trajectory(probe.actor, goal.path, goal.path_clearance, context, goal)
  assert(geometry == saved, "reload/model changes replaced the committed reference")
  assert(probe.actor.speed == 0, "reload check moved the vehicle")
  print("C2M_NATIVE_REFERENCE_RELOAD_OK")
  storage.reference_probe = nil
end)
