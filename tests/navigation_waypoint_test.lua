-- Run from the mod root with a Lua 5.2-compatible interpreter.
-- This exercises the integrated scripts/navigation.lua module.
package.path = "./?.lua;" .. package.path

local Navigation = require("scripts/navigation")

local function point(x, y)
  return { position = { x = x, y = y } }
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function assert_close(actual, expected, message)
  if math.abs(actual - expected) > 0.000001 then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

do
  local predicted = Navigation.predict_vehicle_position({
    orientation = 0,
    speed = 0.5,
    position = { x = 3, y = 4 }
  }, 2)
  assert_close(predicted.x, 3, "north prediction x")
  assert_close(predicted.y, 3, "north prediction y")
end

do
  local data = { current_waypoint = 1 }
  local path = { point(0, 0), point(10, 0) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 0, y = 0 }, { x = 5, y = 0 }, path, 1)
  assert_equal(advanced, 1, "proximity advances only current waypoint")
  assert_equal(data.current_waypoint, 2)
end

do
  local data = { current_waypoint = 2 }
  local path = { point(0, 0), point(10, 0), point(20, 0) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 5, y = 0 }, { x = 12, y = 0 }, path, 1)
  assert_equal(advanced, 1, "predicted straight crossing")
  assert_equal(data.current_waypoint, 3)
end

do
  local data = { current_waypoint = 2 }
  local path = { point(0, 0), point(10, 0), point(20, 0), point(30, 0), point(40, 0) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 5, y = 0 }, { x = 35, y = 0 }, path, 1)
  assert_equal(advanced, 3, "multiple straight crossings")
  assert_equal(data.current_waypoint, 5)
end

do
  local data = { current_waypoint = 2 }
  local path = { point(0, 0), point(10, 0), point(10, 10) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 5, y = 0 }, { x = 12, y = 0 }, path, 1)
  assert_equal(advanced, 0, "sharp corner is not predictively skipped")
  assert_equal(data.current_waypoint, 2)
end

do
  local data = { current_waypoint = 2 }
  local path = { point(0, 0), point(10, 0), point(10, 10) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 12, y = 0 }, { x = 13, y = 0 }, path, 1)
  assert_equal(advanced, 1, "already passed sharp corner is stale")
  assert_equal(data.current_waypoint, 3)
end

do
  local data = { current_waypoint = 2 }
  local path = { point(0, 0), point(10, 0), point(20, 0) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 5, y = 5 }, { x = 12, y = 5 }, path, 1)
  assert_equal(advanced, 0, "parallel motion outside corridor")
  assert_equal(data.current_waypoint, 2)
end

do
  local data = { current_waypoint = 2 }
  local path = { point(0, 0), point(10, 0), point(20, 0) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 5, y = 2 }, { x = 15, y = -2 }, path, 1)
  assert_equal(advanced, 1, "diagonal swept motion crosses arrival corridor")
  assert_equal(data.current_waypoint, 3)
end

do
  local data = { current_waypoint = 1 }
  local path = { point(0, 0), point(0.5, 0), point(0.5, 0.5) }
  local advanced = Navigation.advance_vehicle_waypoints(data, { x = 0, y = 0 }, { x = 0, y = 0 }, path, 1)
  assert_equal(advanced, 1, "large proximity radius does not consume a sharp corner")
  assert_equal(data.current_waypoint, 2)
end

print("navigation waypoint tests passed")
