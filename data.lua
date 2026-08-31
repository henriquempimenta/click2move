data:extend {
  {
    type = "custom-input",
    name = "c2m-move-command",
    key_sequence = "mouse-button-3",
    localised_name = {"custom-input-name.c2m-move-command"}
  },
  {
    type = "custom-input",
    name = "c2m-move-command-queue",
    key_sequence = "SHIFT + mouse-button-3",
    localised_name = {"custom-input-name.c2m-move-command-queue"}
  },
  {
    type = "custom-input",
    name = "c2m-cancel-command",
    key_sequence = "",
    localised_name = {"custom-input-name.c2m-cancel-command"}
  },
  {
    type = "custom-input",
    name = "c2m-toggle-mode",
    key_sequence = "CONTROL + SHIFT + M",
    localised_name = {"custom-input-name.c2m-toggle-mode"}
  },
  {
    type = "custom-input",
    name = "c2m-toggle-strategy-panel",
    key_sequence = "CONTROL + SHIFT + R",
    localised_name = {"custom-input-name.c2m-toggle-strategy-panel"}
  },
  -- Linked to the vanilla movement controls: these fire on the same keypress
  -- as normal walking *without* consuming it, which is what lets an auto-walk
  -- be cancelled the instant the player takes over. Inferring the same thing
  -- from `walking_state` does not work, because the mod writes that field
  -- itself every tick it drives the character.
  {
    type = "custom-input",
    name = "c2m-manual-move-up",
    key_sequence = "",
    linked_game_control = "move-up",
    localised_name = {"custom-input-name.c2m-manual-move"}
  },
  {
    type = "custom-input",
    name = "c2m-manual-move-down",
    key_sequence = "",
    linked_game_control = "move-down",
    localised_name = {"custom-input-name.c2m-manual-move"}
  },
  {
    type = "custom-input",
    name = "c2m-manual-move-left",
    key_sequence = "",
    linked_game_control = "move-left",
    localised_name = {"custom-input-name.c2m-manual-move"}
  },
  {
    type = "custom-input",
    name = "c2m-manual-move-right",
    key_sequence = "",
    linked_game_control = "move-right",
    localised_name = {"custom-input-name.c2m-manual-move"}
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
