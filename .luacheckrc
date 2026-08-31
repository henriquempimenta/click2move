std = "lua51"
max_line_length = false

globals = {
  "storage",
}

read_globals = {
  "game", "script", "settings", "remote", "rendering", "commands",
  "defines", "global", "table_size", "log", "localised_print",
  "serpent", "mods",
  -- Data stage: `data.lua` / `settings.lua` run before `game` exists and get
  -- their own global, which has a `:extend` method rather than being a table
  -- the mod defines.
  data = { fields = { "extend", "raw" } },
  "helpers",
  table = { fields = { "deepcopy" } },
}

exclude_files = {
  "dist/",
  "NEW/",
}

-- W211: unused variable, W212: unused argument, W311: unused assigned
-- value, W312: overwritten before use, W122: setting a read-only
-- global's field (Factorio's LuaGuiElement.caption is settable at
-- runtime; luacheck can't know that). Pre-existing in upstream's code
-- at fork time; not fixed here since they're judgment calls in logic
-- this fork didn't write. Real errors still fail CI.
ignore = { "211", "212", "311", "312", "122" }
