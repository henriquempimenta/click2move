data:extend({
  {
    type = "bool-setting",
    name = "c2m-debug-mode",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "a"
  },
  {
    type = "double-setting",
    name = "c2m-character-margin",
    setting_type = "runtime-global",
    default_value = 0.45,
    minimum_value = 0.0,
    maximum_value = 2.0,
    order = "b"
  },
  {
    type = "int-setting",
    name = "c2m-update-interval",
    setting_type = "startup",
    default_value = 1,
    minimum_value = 1,
    maximum_value = 60,
    order = "c"
  },
  {
    type = "double-setting",
    name = "c2m-character-proximity-threshold",
    setting_type = "startup",
    default_value = 1.5,
    minimum_value = 0.5,
    maximum_value = 5.0,
    order = "d"
  },
  {
    type = "double-setting",
    name = "c2m-vehicle-proximity-threshold",
    setting_type = "startup",
    default_value = 6.0,
    minimum_value = 2.0,
    maximum_value = 10.0,
    order = "e"
  },
  {
    type = "int-setting",
    name = "c2m-stuck-threshold",
    setting_type = "startup",
    default_value = 30,
    minimum_value = 5,
    maximum_value = 120,
    order = "f"
  },
  {
    type = "double-setting",
    name = "c2m-vehicle-path-margin",
    setting_type = "startup",
    default_value = 2.0,
    minimum_value = 0.0,
    maximum_value = 5.0,
    order = "g"
  }
})