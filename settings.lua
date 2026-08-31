data:extend({
  {
    type = "bool-setting",
    name = "c2m-enable-debug-interface",
    setting_type = "startup",
    default_value = false,
    order = "a-0"
  },
  {
    type = "bool-setting",
    name = "c2m-debug-mode",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "a"
  },
  {
    type = "bool-setting",
    name = "c2m-debug-path",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "a-a"
  },
  {
    type = "bool-setting",
    name = "c2m-debug-queue",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "a-b"
  },
  {
    type = "bool-setting",
    name = "c2m-debug-stuck",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "a-c"
  },
  {
    type = "bool-setting",
    name = "c2m-debug-vehicle",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "a-d"
  },
  {
    type = "double-setting",
    name = "c2m-character-margin",
    setting_type = "runtime-per-user",
    default_value = 0.45,
    minimum_value = 0.0,
    maximum_value = 2.0,
    order = "b"
  },
  {
    type = "int-setting",
    name = "c2m-update-interval",
    setting_type = "runtime-global",
    default_value = 1,
    minimum_value = 1,
    maximum_value = 60,
    order = "c"
  },
  {
    type = "double-setting",
    name = "c2m-character-proximity-threshold",
    setting_type = "runtime-per-user",
    default_value = 1.5,
    minimum_value = 0.5,
    maximum_value = 5.0,
    order = "d"
  },
  {
    type = "double-setting",
    name = "c2m-vehicle-proximity-threshold",
    setting_type = "runtime-per-user",
    default_value = 6.0,
    minimum_value = 2.0,
    maximum_value = 10.0,
    order = "e"
  },
  {
    type = "int-setting",
    name = "c2m-stuck-threshold",
    setting_type = "runtime-per-user",
    default_value = 30,
    minimum_value = 5,
    maximum_value = 120,
    order = "f"
  },
  {
    type = "double-setting",
    name = "c2m-vehicle-path-margin",
    setting_type = "runtime-per-user",
    default_value = 2.0,
    minimum_value = 0.0,
    maximum_value = 5.0,
    order = "g"
  },
  {
    type = "bool-setting",
    name = "c2m-vehicle-prefer-straight-paths",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "h"
  },
  {
    type = "bool-setting",
    name = "c2m-cancel-on-manual-move",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "i"
  },
  -- Routing strategy, exposed as a setting rather than hardcoded so the options
  -- can be A/B/C benchmarked against each other rather than argued about:
  --
  --   naive       stock behaviour - walk the pathfinder's path as-is
  --   belt-aware  post-process that path for the conveyor drift the pathfinder
  --               knows nothing about, and step off opposing belts per tick
  --   dual-phase  belt-aware, plus a belt-graph A* running in the background
  --               that hot-swaps in a better route if it finds one and that
  --               route is still faster from wherever the character is by then
  {
    type = "string-setting",
    name = "c2m-routing-strategy",
    setting_type = "runtime-per-user",
    default_value = "belt-aware",
    allowed_values = { "naive", "belt-aware", "dual-phase" },
    order = "j"
  },
  {
    type = "bool-setting",
    name = "c2m-belt-ride",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "k"
  },
  -- 0 means "auto": use no extra margin when Squeak Through is installed (it
  -- shrinks entity collision boxes, and re-inflating ours would close exactly
  -- the gaps it opened), otherwise use a small fallback margin.
  {
    type = "double-setting",
    name = "c2m-squeeze-margin",
    setting_type = "runtime-per-user",
    default_value = 0.0,
    minimum_value = 0.0,
    maximum_value = 0.45,
    order = "l"
  },
  {
    type = "bool-setting",
    name = "c2m-never-give-up",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "m"
  }
})
