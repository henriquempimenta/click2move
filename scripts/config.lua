--[[
  Click2Move - Configuration
  Settings loading and debug mode checker.
]]

local Config = {}

---@class C2MConfig
---@field character_margin number
---@field proximity_threshold number
---@field update_interval number
---@field vehicle_proximity_threshold number
---@field stuck_threshold number
---@field vehicle_path_margin number
---@field vehicle_prefer_straight_paths boolean

-- Cached config table (populated on init/load)
---@type C2MConfig
local config = {
  character_margin = 0.45,
  proximity_threshold = 1.5,
  update_interval = 1,
  vehicle_proximity_threshold = 6.0,
  stuck_threshold = 30,
  vehicle_path_margin = 2.0,
  vehicle_prefer_straight_paths = false
}

local per_player_defaults = {
  character_margin = 0.45,
  proximity_threshold = 1.5,
  vehicle_proximity_threshold = 6.0,
  stuck_threshold = 30,
  vehicle_path_margin = 2.0,
  vehicle_prefer_straight_paths = false
}

function Config.load()
  ---@diagnostic disable: assign-type-mismatch
  config.update_interval = settings.global["c2m-update-interval"].value or 1
  ---@diagnostic enable: assign-type-mismatch
end

-- Get the current config table (read-only by convention)
---@param player_index? integer|string
---@return C2MConfig
function Config.get(player_index)
  local player = player_index and game.players[player_index]
  if player and player.valid then
    local player_settings = settings.get_player_settings(player)
    config.character_margin = player_settings["c2m-character-margin"].value or per_player_defaults.character_margin
    config.proximity_threshold = player_settings["c2m-character-proximity-threshold"].value or per_player_defaults.proximity_threshold
    config.vehicle_proximity_threshold = player_settings["c2m-vehicle-proximity-threshold"].value or per_player_defaults.vehicle_proximity_threshold
    config.stuck_threshold = player_settings["c2m-stuck-threshold"].value or per_player_defaults.stuck_threshold
    config.vehicle_path_margin = player_settings["c2m-vehicle-path-margin"].value or per_player_defaults.vehicle_path_margin
    config.vehicle_prefer_straight_paths = player_settings["c2m-vehicle-prefer-straight-paths"].value == true
  end
  return config
end

-- Check if debug mode is enabled for a player
---@param player_index integer|string
---@param category? "path"|"queue"|"stuck"|"vehicle"
---@return boolean
function Config.is_debug(player_index, category)
  local p = game.players[player_index]
  if not p then return false end
  local player_settings = settings.get_player_settings(p)
  if player_settings["c2m-debug-mode"].value == false then return false end
  if not category then return true end
  local category_setting = player_settings["c2m-debug-" .. category]
  return not category_setting or category_setting.value ~= false
end

return Config
