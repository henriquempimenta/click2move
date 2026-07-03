data:extend {
  {
    type = "custom-input",
    name = "c2m-move-command",
    key_sequence = "mouse-button-3",
    consuming = "none",
    action = "lua",
    localised_name = {"custom-input-name.c2m-move-command"}
  },
  {
    type = "custom-input",
    name = "c2m-move-command-queue",
    key_sequence = "SHIFT + mouse-button-3",
    consuming = "none",
    action = "lua",
    localised_name = {"custom-input-name.c2m-move-command-queue"}
  },
  {
    type = "custom-input",
    name = "c2m-cancel-command",
    key_sequence = "",
    consuming = "none",
    action = "lua",
    localised_name = {"custom-input-name.c2m-cancel-command"}
  },
  {
    type = "custom-input",
    name = "c2m-toggle-mode",
    key_sequence = "CONTROL + SHIFT + M",
    consuming = "none",
    action = "lua",
    localised_name = {"custom-input-name.c2m-toggle-mode"}
  },
  {
    type = "shortcut",
    name = "c2m-toggle-mode",
    toggleable = true,
    icon = "__click2move__/thumbnail.png",
    icon_size = 144,
    small_icon = "__click2move__/thumbnail.png",
    small_icon_size = 144,
    action = "lua",
    localised_name = {"shortcut-name.c2m-toggle-mode"}
  }
}
