data:extend({
  {
    type = "bool-setting",
    name = "c2m-debug-mode",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "a"
  },
  {
    type = "int-setting",
    name = "c2m-update-interval",
    setting_type = "startup",
    default_value = 1,
    min_value = 1,
    max_value = 60,
    order = "b"
  },
  {
    type = "double-setting",
    name = "c2m-character-proximity-threshold",
    setting_type = "startup",
    default_value = 1.5,
    min_value = 0.5,
    max_value = 5.0,
    order = "c"
  },
  {
    type = "double-setting",
    name = "c2m-vehicle-proximity-threshold",
    setting_type = "startup",
    default_value = 6.0,
    min_value = 2.0,
    max_value = 10.0,
    order = "d"
  }
})