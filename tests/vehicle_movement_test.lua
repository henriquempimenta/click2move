-- Run from the mod root with a Lua 5.2-compatible interpreter.
package.path = "./?.lua;" .. package.path

local test_defines = {
  direction = {
    north = 0, northeast = 1, east = 2, southeast = 3,
    south = 4, southwest = 5, west = 6, northwest = 7,
  },
  riding = {
    acceleration = { accelerating = 1, braking = 2, reversing = 3 },
    direction = { straight = 0, left = 1, right = 2 },
  },
}
rawset(_G, "defines", test_defines)

local player_settings = {
  ["c2m-character-margin"] = { value = 0.45 },
  ["c2m-character-proximity-threshold"] = { value = 1.5 },
  ["c2m-vehicle-proximity-threshold"] = { value = 2.0 },
  ["c2m-stuck-threshold"] = { value = 30 },
  ["c2m-vehicle-path-margin"] = { value = 2.0 },
  ["c2m-vehicle-prefer-straight-paths"] = { value = false },
  ["c2m-cancel-on-manual-move"] = { value = true },
  ["c2m-routing-strategy"] = { value = "belt-aware" },
  ["c2m-belt-ride"] = { value = true },
  ["c2m-squeeze-margin"] = { value = 0 },
  ["c2m-never-give-up"] = { value = true },
  ["c2m-debug-mode"] = { value = false },
}

local player = { index = 1, valid = true }
rawset(_G, "game", { players = { [1] = player } })
rawset(_G, "script", { active_mods = {} })
rawset(_G, "settings", {
  global = { ["c2m-update-interval"] = { value = 10 } },
  get_player_settings = function() return player_settings end,
})

local Config = require("scripts/config")
Config.load()
local Movement = require("scripts/movement")

local vehicle = {
  type = "car",
  valid = true,
  position = { x = 5, y = 0 },
  orientation = 0.25, -- east
  speed = 0.5,
}

local data = {
  current_waypoint = 2,
  goals = {
    {
      position = { x = 20, y = 5 },
      path = {
        { position = { x = 0, y = 0 } },
        { position = { x = 10, y = 0 } },
        { position = { x = 20, y = 5 } },
      },
    },
  },
  closest_dist_to_goal = 999999,
  no_progress_ticks = 0,
  stuck_state = "none",
  stuck_timer = 0,
}

local stopped = Movement.handle_vehicle(1, data, player, vehicle)
assert(stopped == false, "vehicle movement should continue")
assert(data.current_waypoint == 3, "predicted crossing should advance to the next waypoint")
assert(vehicle.riding_state.direction == test_defines.riding.direction.right,
  "steering should use the newly selected waypoint in the same update")
assert(vehicle.riding_state.acceleration == test_defines.riding.acceleration.accelerating,
  "vehicle should continue accelerating toward the new waypoint")

print("vehicle movement integration test passed")
