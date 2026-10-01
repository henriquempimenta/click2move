-- Settings are cached per player and rebuilt when their settings change.
local Config = {}

---@class C2MConfig
---@field character_margin number
---@field proximity_threshold number
---@field update_interval number
---@field vehicle_proximity_threshold number
---@field stuck_threshold number
---@field vehicle_path_margin number
---@field vehicle_prefer_straight_paths boolean

local defaults = {
  character_margin = 0.45, proximity_threshold = 1.5,
  vehicle_proximity_threshold = 6.0, stuck_threshold = 30,
  vehicle_path_margin = 2.0, vehicle_prefer_straight_paths = false
}
local setting_names = {
  character_margin = "c2m-character-margin",
  proximity_threshold = "c2m-character-proximity-threshold",
  vehicle_proximity_threshold = "c2m-vehicle-proximity-threshold",
  stuck_threshold = "c2m-stuck-threshold",
  vehicle_path_margin = "c2m-vehicle-path-margin",
  vehicle_prefer_straight_paths = "c2m-vehicle-prefer-straight-paths"
}
local update_interval = 1
local player_configs = {}

function Config.load()
  update_interval = settings.global["c2m-update-interval"].value
  player_configs = {}
end

function Config.on_setting_changed(event)
  if event.setting == "c2m-update-interval" then
    Config.load()
  elseif event.player_index then
    player_configs[event.player_index] = nil
  else
    player_configs = {}
  end
end

function Config.remove_player(player_index)
  player_configs[player_index] = nil
end

---@param player_index? uint32
---@return C2MConfig
function Config.get(player_index)
  if not player_index then return {update_interval = update_interval} end
  if player_configs[player_index] then return player_configs[player_index] end
  local player = game.players[player_index]
  local player_settings = player and player.valid and settings.get_player_settings(player)
  local config = {update_interval = update_interval}
  for key, fallback in pairs(defaults) do
    local setting = player_settings and player_settings[setting_names[key]]
    config[key] = setting and setting.value
    if config[key] == nil then config[key] = fallback end
  end
  config.debug_mode = player_settings and player_settings["c2m-debug-mode"].value == true or false
  config.debug_categories = {}
  for _, category in ipairs({"path", "queue", "stuck", "vehicle"}) do
    local setting = player_settings and player_settings["c2m-debug-" .. category]
    config.debug_categories[category] = not setting or setting.value ~= false
  end
  if player and player.valid then player_configs[player_index] = config end
  return config
end

function Config.is_debug(player_index, category)
  local config = Config.get(player_index)
  return config.debug_mode and (not category or config.debug_categories[category] ~= false)
end

return Config
