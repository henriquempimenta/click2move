local VehicleBraking = {}

local hovercrafts = {
  ["hovercraft"] = true,
  ["missile-hovercraft"] = true,
  ["electric-hovercraft"] = true,
  ["laser-hovercraft"] = true
}

-- Returns the speed/position tolerances and observation time for a stopped
-- vehicle. Hovercrafts' New mode has sub-tile jitter even with no control input.
---@param vehicle LuaEntity
---@param previous_speed? number
---@return number speed_tolerance, number position_tolerance, integer stationary_ticks
function VehicleBraking.apply(vehicle, previous_speed)
  local speed_tolerance, position_tolerance, stationary_ticks = 0, 0.0001, 10
  local drift_setting = hovercrafts[vehicle.name] and settings.startup["hovercraft-drifting"]
  if drift_setting and drift_setting.value == "new" then
    -- Quantized virtual friction can move a few position quanta during the
    -- observation window, especially on laser models. Tolerate fewer than four quanta;
    -- the fixed anchor still rejects sustained drift over the whole window.
    speed_tolerance, position_tolerance, stationary_ticks = 0.001, 1 / 64, 120
  end

  local acceleration = defines.riding.acceleration.braking
  local crossed_zero = previous_speed and vehicle.speed * previous_speed < 0
  if speed_tolerance > 0 and (math.abs(vehicle.speed) <= speed_tolerance or crossed_zero) then
    -- Hovercrafts 2.1.4 applies reverse thrust while braking, including at rest.
    -- A braking impulse can cross zero without ever reporting zero (especially
    -- on electric models). End that impulse and let drift friction settle.
    -- Setting speed to zero also lets Hovercrafts clear its remembered drift.
    acceleration = defines.riding.acceleration.nothing
    vehicle.speed = 0
  end
  vehicle.riding_state = {direction = defines.riding.direction.straight, acceleration = acceleration}
  return speed_tolerance, position_tolerance, stationary_ticks
end

return VehicleBraking
