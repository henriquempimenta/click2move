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

-- Cached config table (populated on init/load)
---@type C2MConfig
local config = {
  character_margin = 0.45,
  proximity_threshold = 1.5,
  update_interval = 1,
  vehicle_proximity_threshold = 6.0,
  stuck_threshold = 30,
  vehicle_path_margin = 2.0
}

function Config.load()
  ---@diagnostic disable: assign-type-mismatch
  config.character_margin = settings.global["c2m-character-margin"].value or 0.45
  config.proximity_threshold = settings.startup["c2m-character-proximity-threshold"].value or 1.5
  config.update_interval = settings.startup["c2m-update-interval"].value or 1
  config.vehicle_proximity_threshold = settings.startup["c2m-vehicle-proximity-threshold"].value or 6.0
  config.stuck_threshold = settings.startup["c2m-stuck-threshold"].value or 30
  config.vehicle_path_margin = settings.startup["c2m-vehicle-path-margin"].value or 2.0
  ---@diagnostic enable: assign-type-mismatch
end

-- Get the current config table (read-only by convention)
---@return C2MConfig
function Config.get()
  return config
end

-- Check if debug mode is enabled for a player
---@param player_index integer|string
---@return boolean
function Config.is_debug(player_index)
  local p = game.players[player_index]
  if not p then return false end
  return settings.get_player_settings(p)["c2m-debug-mode"].value ~= false  -- Simplified check
end

return Config
