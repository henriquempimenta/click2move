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
    minimun_value = 1,
    maximun_value = 60,
    order = "c"
  },
  {
    type = "double-setting",
    name = "c2m-character-proximity-threshold",
    setting_type = "startup",
    default_value = 1.5,
    minimun_value = 0.5,
    maximun_value = 5.0,
    order = "d"
  },
  {
    type = "double-setting",
    name = "c2m-vehicle-proximity-threshold",
    setting_type = "startup",
    default_value = 6.0,
    minimun_value = 2.0,
    maximun_value = 10.0,
    order = "e"
  }
})