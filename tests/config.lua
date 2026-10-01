-- Run from the mod directory: lua tests/config.lua
package.path = "./?.lua;" .. package.path
local reads = 0
local values = {}
local defaults = {
  ["c2m-character-margin"] = .45, ["c2m-character-proximity-threshold"] = 1.5,
  ["c2m-vehicle-proximity-threshold"] = 6, ["c2m-stuck-threshold"] = 30,
  ["c2m-vehicle-path-margin"] = 2, ["c2m-vehicle-prefer-straight-paths"] = false,
  ["c2m-debug-mode"] = false, ["c2m-debug-path"] = true, ["c2m-debug-queue"] = true,
  ["c2m-debug-stuck"] = true, ["c2m-debug-vehicle"] = true
}
for index = 1, 2 do
  values[index] = {}
  for name, value in pairs(defaults) do values[index][name] = {value = value} end
end
values[2]["c2m-character-margin"].value = 1
values[2]["c2m-debug-mode"].value = true
values[2]["c2m-debug-path"].value = false
game = {players = {[1] = {valid = true, index = 1}, [2] = {valid = true, index = 2}}}
settings = {global = {["c2m-update-interval"] = {value = 1}},
  get_player_settings = function(player) reads = reads + 1; return values[player.index] end}
local Config = require("scripts/config")
Config.load()
local first, second = Config.get(1), Config.get(2)
assert(first ~= second and first.character_margin == .45 and second.character_margin == 1)
for i = 1, 1000 do Config.get(1); Config.get(2); Config.is_debug(2, "path") end
assert(reads == 2)
assert(not Config.is_debug(1) and Config.is_debug(2) and not Config.is_debug(2, "path"))
values[1]["c2m-character-margin"].value = .75
Config.on_setting_changed({player_index = 1, setting = "c2m-character-margin"})
assert(Config.get(1).character_margin == .75)
assert(Config.get(2) == second and reads == 3)
settings.global["c2m-update-interval"].value = 7
Config.on_setting_changed({setting = "c2m-update-interval"})
assert(Config.get().update_interval == 7)
assert(Config.get(1).update_interval == 7 and Config.get(2).update_interval == 7)
assert(reads == 5)
values[2]["c2m-debug-path"].value = true
Config.on_setting_changed({player_index = 2, setting = "c2m-debug-path"})
assert(Config.is_debug(2, "path"))
Config.load()
assert(Config.get(1).character_margin == .75)
Config.remove_player(1)
local before = reads
Config.get(1)
assert(reads == before + 1)
print("PASS isolated player settings, cached debug, per-player invalidation, global interval invalidation and reload")
