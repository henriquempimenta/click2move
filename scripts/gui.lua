--[[
  Click2Move - GUI
  HUD frame creation, updating, and cancel button handling.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")

local GUI = {}

-- GUI element names
GUI.ROOT_NAME = "c2m_root_flow"
GUI.LABEL_NAME = "c2m_status_label"
GUI.CANCEL_NAME = "c2m_cancel_button"

---@param player LuaPlayer
---@param data PlayerMoveData
local function create_gui_for_player(player, data)
  if not player or not player.valid then return end
  -- create top-left small frame if not present
  if player.gui.top[GUI.ROOT_NAME] and player.gui.top[GUI.ROOT_NAME].valid then
    -- update existing
    local status = player.gui.top[GUI.ROOT_NAME][GUI.LABEL_NAME]
    if status and status.valid then
      local next_goal = data.goals[1]
      if next_goal then
        status.caption = "Auto-walking to " .. Util.format_pos(next_goal.position)
      else
        status.caption = nil
      end
    end
    return
  end

  local frame = player.gui.top.add{ type = "flow", name = GUI.ROOT_NAME, direction = "horizontal" }
  frame.add{ type = "label", name = GUI.LABEL_NAME, caption = "" }
  frame.add{ type = "button", name = GUI.CANCEL_NAME, caption = "Cancel" }
end

-- Update the GUI for a specific player (show/hide based on goal state)
---@param player_index integer|string
function GUI.update(player_index)
  local player = game.players[player_index]
  if not player or not player.valid then return end
  local data = PlayerData.get_all()[player_index]
  if data and data.goals and #data.goals > 0 then
    create_gui_for_player(player, data)
    -- set label text
    local root = player.gui.top[GUI.ROOT_NAME]
    if root and root[GUI.LABEL_NAME] and root[GUI.LABEL_NAME].valid then
      local next_goal = data.goals[1]
      root[GUI.LABEL_NAME].caption = "Auto-walking to " .. Util.format_pos(next_goal.position) .. ( (#data.goals > 1) and ("  [queued: " .. tostring(#data.goals - 1) .. "]") or "" )
    end
  else
    -- destroy gui if exists
    if player.gui.top[GUI.ROOT_NAME] and player.gui.top[GUI.ROOT_NAME].valid then
      player.gui.top[GUI.ROOT_NAME].destroy()
    end
  end
end

-- Handle GUI cancel button click
---@param event EventData.on_gui_click
function GUI.on_click(event)
  if not event.element or not event.element.valid then return end
  if event.element.name ~= GUI.CANCEL_NAME then return end

  local player = game.players[event.player_index]
  if not player or not player.valid then return end

  local data = PlayerData.get_all()[player.index]
  local changed = true
  if data then
    -- clear everything for this player
    Util.safe_destroy_renderings(data.render_objs)
    PlayerData.remove(player.index)
  end
  -- destroy GUI (update will remove if anything left)
  if Config.is_debug(player.index) then player.print("Click2Move: Auto-walk cancelled by player.") end
  if changed then GUI.update(player.index) end
end

return GUI
