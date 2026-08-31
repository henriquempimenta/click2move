-- Run from the mod root with a Lua 5.2-compatible interpreter.
package.path = "./?.lua;" .. package.path

rawset(_G, "defines", {
  direction = {
    north = 0, northeast = 1, east = 2, southeast = 3,
    south = 4, southwest = 5, west = 6, northwest = 7,
  },
})
rawset(_G, "game", { tick = 100, players = {} })
rawset(_G, "script", { active_mods = {} })

local player_settings = {
  ["c2m-character-margin"] = { value = 0.45 },
  ["c2m-character-proximity-threshold"] = { value = 1.5 },
  ["c2m-vehicle-proximity-threshold"] = { value = 6 },
  ["c2m-stuck-threshold"] = { value = 30 },
  ["c2m-vehicle-path-margin"] = { value = 2 },
  ["c2m-vehicle-prefer-straight-paths"] = { value = false },
  ["c2m-cancel-on-manual-move"] = { value = true },
  ["c2m-routing-strategy"] = { value = "dual-phase" },
  ["c2m-belt-ride"] = { value = true },
  ["c2m-squeeze-margin"] = { value = 0 },
  ["c2m-never-give-up"] = { value = true },
  ["c2m-debug-mode"] = { value = false },
}

local player = { index = 1, valid = true }
game.players[1] = player
rawset(_G, "settings", {
  global = { ["c2m-update-interval"] = { value = 1 } },
  get_player_settings = function() return player_settings end,
})

local Config = require("scripts/config")
Config.load()
local Belts = require("scripts/belts")
local Movement = require("scripts/movement")

local escape_calls = 0
Belts.escape_direction = function()
  escape_calls = escape_calls + 1
  return { x = 0, y = 3 }
end

local character = {
  valid = true,
  type = "character",
  position = { x = 10.2, y = 0 },
  surface = {},
  character_running_speed = 0.1,
  walking_state = { walking = false, direction = defines.direction.north },
}
player.character = character

local final_data = {
  current_waypoint = 1,
  goals = {{
    position = { x = 10, y = 0 },
    path = {{ position = { x = 10, y = 0 } }},
  }},
  closest_dist_to_goal = 999999,
  no_progress_ticks = 0,
  stuck_state = "none",
  stuck_timer = 0,
}

assert(Movement.handle_character(1, final_data, player, character),
  "a reached final waypoint on a belt should complete")
assert(final_data.current_waypoint == 2, "completion should consume the final waypoint")
assert(escape_calls == 0, "belt escape must not run after the goal is reached")

local intermediate_data = {
  current_waypoint = 1,
  goals = {{
    position = { x = 20, y = 0 },
    path = {
      { position = { x = 10, y = 0 } },
      { position = { x = 20, y = 0 } },
    },
  }},
  closest_dist_to_goal = 999999,
  no_progress_ticks = 0,
  stuck_state = "none",
  stuck_timer = 0,
}

assert(not Movement.handle_character(1, intermediate_data, player, character),
  "an intermediate belt waypoint should continue moving")
assert(intermediate_data.current_waypoint == 1,
  "belt escape should not consume an intermediate waypoint")
assert(escape_calls == 1, "intermediate belt waypoint should still invoke escape correction")

print("character belt arrival test passed")
