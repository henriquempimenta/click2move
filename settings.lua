data:extend({
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
  }
})
