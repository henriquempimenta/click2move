--[[
  Click2Move - Mode
  The per-player mode lives in the shortcut toggle, so the game persists it.
]]

local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local GUI = require("scripts/gui")

local Mode = {}

Mode.SHORTCUT_NAME = "c2m-toggle-mode"

---@param player LuaPlayer
---@return boolean
function Mode.is_enabled(player)
  return player.is_shortcut_toggled(Mode.SHORTCUT_NAME)
end

-- Disabling cancels any active route; arrival disables after the queue is gone.
---@param player LuaPlayer
---@param enabled boolean
---@param reason? string
function Mode.set(player, enabled, reason)
  if not player or not player.valid then return end
  player.set_shortcut_toggled(Mode.SHORTCUT_NAME, enabled)
  if not enabled and PlayerData.get_all()[player.index] then
    GUI.cancel_movement(player, reason or "mode disabled")
  end
  if Config.is_debug(player.index, "queue") then
    player.print("Click2Move: Mode " .. (enabled and "enabled." or "disabled.")
      .. (reason and (" (" .. reason .. ")") or ""))
  end
end

---@param player LuaPlayer
function Mode.toggle(player)
  if not player or not player.valid then return end
  Mode.set(player, not Mode.is_enabled(player))
end

-- Called once the final queued goal has been reached, never on cancel or failure.
---@param player LuaPlayer
function Mode.on_route_arrived(player)
  if not player or not player.valid or not Config.get(player.index).disable_on_arrival then return end
  if not Mode.is_enabled(player) then return end
  Mode.set(player, false, "arrival")
  player.print({"click2move.disabled-on-arrival"})
end

return Mode
