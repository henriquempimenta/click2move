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
---@field cancel_on_manual_move boolean
---@field routing_strategy string
---@field belt_ride boolean
---@field squeeze_margin number
---@field never_give_up boolean

-- Cached config table (populated on init/load)
---@type C2MConfig
local config = {
  character_margin = 0.45,
  proximity_threshold = 1.5,
  update_interval = 1,
  vehicle_proximity_threshold = 6.0,
  stuck_threshold = 30,
  vehicle_path_margin = 2.0,
  vehicle_prefer_straight_paths = false,
  cancel_on_manual_move = true,
  routing_strategy = "belt-aware",
  belt_ride = true,
  squeeze_margin = 0.05,
  never_give_up = true
}

local per_player_defaults = {
  character_margin = 0.45,
  proximity_threshold = 1.5,
  vehicle_proximity_threshold = 6.0,
  stuck_threshold = 30,
  vehicle_path_margin = 2.0,
  vehicle_prefer_straight_paths = false,
  cancel_on_manual_move = true,
  routing_strategy = "belt-aware",
  belt_ride = true,
  never_give_up = true
}

-- Squeak Through shrinks entity collision boxes so characters fit through gaps
-- that are otherwise solid. Our own `character_margin` inflates the character
-- box, which would re-close exactly those gaps — so when it is present the
-- fallback squeeze margin drops to near zero.
--
-- The mod has shipped under several internal names across its ports, so match
-- on any of them rather than a single string.
local SQUEAK_THROUGH_NAMES = {
  ["Squeak Through"] = true,
  ["squeak-through"] = true,
  ["SqueakThrough"] = true,
  ["Squeak Through Updated"] = true,
  ["squeak-through-2"] = true,
}

local squeak_through_present = nil

-- Whether a Squeak-Through-like mod is active. Cached: `script.active_mods` is
-- constant for the lifetime of a session.
---@return boolean
function Config.has_squeak_through()
  if squeak_through_present == nil then
    squeak_through_present = false
    for name in pairs(script.active_mods) do
      if SQUEAK_THROUGH_NAMES[name] then
        squeak_through_present = true
        break
      end
    end
  end
  return squeak_through_present
end

-- Margin to use for tight-gap retries. A player-set non-zero value wins;
-- 0 means "auto", which is near-zero with Squeak Through (its whole purpose is
-- to make those gaps passable) and a small non-zero value without it.
---@param configured number
---@return number
local function resolve_squeeze_margin(configured)
  if configured and configured > 0 then return configured end
  return Config.has_squeak_through() and 0.0 or 0.05
end

-- Per-player config cache. Reading settings.get_player_settings() is an API call;
-- movement handlers call Config.get() multiple times per player per tick, so an
-- uncached read multiplies into many settings lookups/sec/player in multiplayer.
-- Populated lazily, invalidated per-player on_runtime_mod_setting_changed.
---@type table<integer|string, C2MConfig>
local player_config_cache = {}

function Config.load()
  ---@diagnostic disable: assign-type-mismatch
  config.update_interval = settings.global["c2m-update-interval"].value or 1
  ---@diagnostic enable: assign-type-mismatch
end

-- Invalidate a single player's cached config (call on setting change)
---@param player_index integer|string
function Config.invalidate(player_index)
  player_config_cache[player_index] = nil
end

-- Does this player's strategy use belt-aware routing at all?
--
-- Both `belt-aware` and `dual-phase` run the Phase-1 belt post-pass and the
-- per-tick escape; `dual-phase` merely adds the async search on top. Asking
-- through one predicate keeps the three call sites from drifting apart — an
-- earlier `== "belt-aware"` check silently disabled the per-tick escape for
-- dual-phase players, which is the kind of bug that shows up only as "the
-- numbers are worse than they should be".
---@param player_index integer|string
---@return boolean
function Config.uses_belts(player_index)
  local strategy = Config.get(player_index).routing_strategy
  return strategy == "belt-aware" or strategy == "dual-phase"
end

-- Does this player's strategy run the async Phase-2 search?
---@param player_index integer|string
---@return boolean
function Config.uses_dual_phase(player_index)
  return Config.get(player_index).routing_strategy == "dual-phase"
end

-- Test-only per-player config overrides.
--
-- Per-player mod settings can only be written by the owning player or the mod
-- that declared them, so a benchmark driving the game over RCON cannot switch
-- routing strategy through the settings API. These overrides give the debug
-- interface a way in. Empty in normal play, and applied on top of the real
-- settings so anything not overridden still comes from the player's config.
---@type table<integer|string, table>
local overrides = {}

---@param player_index integer|string
---@param key string
---@param value any
function Config.set_override(player_index, key, value)
  overrides[player_index] = overrides[player_index] or {}
  overrides[player_index][key] = value
  Config.invalidate(player_index)
end

---@param player_index? integer|string
function Config.clear_overrides(player_index)
  if player_index then
    overrides[player_index] = nil
    Config.invalidate(player_index)
  else
    for index in pairs(overrides) do Config.invalidate(index) end
    overrides = {}
  end
end

-- Get the current config table for a player (read-only by convention).
-- Cached per player_index; only re-reads the settings API when the cache
-- is empty (first use, or after Config.invalidate on a setting change).
---@param player_index? integer|string
---@return C2MConfig
function Config.get(player_index)
  if not player_index then return config end

  local cached = player_config_cache[player_index]
  if cached then return cached end

  local player = game.players[player_index]
  if not (player and player.valid) then return config end

  local player_settings = settings.get_player_settings(player)
  local player_config = {
    character_margin = player_settings["c2m-character-margin"].value or per_player_defaults.character_margin,
    proximity_threshold = player_settings["c2m-character-proximity-threshold"].value or per_player_defaults.proximity_threshold,
    update_interval = config.update_interval,
    vehicle_proximity_threshold = player_settings["c2m-vehicle-proximity-threshold"].value or per_player_defaults.vehicle_proximity_threshold,
    stuck_threshold = player_settings["c2m-stuck-threshold"].value or per_player_defaults.stuck_threshold,
    vehicle_path_margin = player_settings["c2m-vehicle-path-margin"].value or per_player_defaults.vehicle_path_margin,
    vehicle_prefer_straight_paths = player_settings["c2m-vehicle-prefer-straight-paths"].value == true,
    cancel_on_manual_move = player_settings["c2m-cancel-on-manual-move"].value ~= false,
    routing_strategy = player_settings["c2m-routing-strategy"].value or per_player_defaults.routing_strategy,
    belt_ride = player_settings["c2m-belt-ride"].value ~= false,
    squeeze_margin = resolve_squeeze_margin(player_settings["c2m-squeeze-margin"].value),
    never_give_up = player_settings["c2m-never-give-up"].value ~= false,
  }

  local player_overrides = overrides[player_index]
  if player_overrides then
    for key, value in pairs(player_overrides) do
      player_config[key] = value
    end
  end

  player_config_cache[player_index] = player_config
  return player_config
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
