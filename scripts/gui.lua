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
---@param reason? string
---@param preserve_input? boolean
---@return boolean
function GUI.cancel_movement(player, reason, preserve_input)
  if not player or not player.valid then return false end

  local data = PlayerData.get_all()[player.index]
  if data then
    local entity = data.move_entity or player.vehicle or player.character
    if preserve_input then entity = nil end
    PlayerData.cleanup_movement(entity, data)
    PlayerData.remove(player.index)
  end

  if Config.is_debug(player.index, "queue") then
    player.print("Click2Move: Auto-walk cancelled" .. (reason and (" (" .. reason .. ").") or "."))
  end
  GUI.update(player.index)
  return data ~= nil
end

---@param player LuaPlayer
local function create_gui_for_player(player)
  if not player or not player.valid then return end
  -- create top-left small frame if not present
  if player.gui.top[GUI.ROOT_NAME] and player.gui.top[GUI.ROOT_NAME].valid then
    return
  end

  local frame = player.gui.top.add{ type = "flow", name = GUI.ROOT_NAME, direction = "horizontal" }
  frame.add{ type = "label", name = GUI.LABEL_NAME, caption = "" }
  frame.add{ type = "button", name = GUI.CANCEL_NAME, caption = {"click2move.cancel"} }
end

-- Update the GUI for a specific player (show/hide based on goal state)
---@param player_index integer|string
function GUI.update(player_index)
  local player = game.players[player_index]
  if not player or not player.valid then return end
  local data = PlayerData.get_all()[player_index]
  if data and data.goals and #data.goals > 0 then
    create_gui_for_player(player)
    -- set label text
    local root = player.gui.top[GUI.ROOT_NAME]
    if root and root[GUI.LABEL_NAME] and root[GUI.LABEL_NAME].valid then
      local next_goal = data.goals[1]
      local caption = {"click2move.moving-to", Util.format_pos(next_goal.position)}
      if #data.goals > 1 then
        caption = {"click2move.moving-to-queued", Util.format_pos(next_goal.position), #data.goals - 1}
      end
      if data.preview then
        caption = #data.goals > 1 and {"click2move.preview-to-queued", Util.format_pos(next_goal.position), #data.goals - 1}
          or {"click2move.preview-to", Util.format_pos(next_goal.position)}
      end
      root[GUI.LABEL_NAME].caption = caption
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

  GUI.cancel_movement(player, "GUI")
end

return GUI
