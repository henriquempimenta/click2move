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

-- Strategy switcher. Separate from the status flow above because that one only
-- exists while a move is in progress, and the point of the switcher is to
-- change strategy *between* moves and immediately try the same route again.
GUI.STRATEGY_ROOT = "c2m_strategy_frame"
GUI.STRATEGY_SELECT = "c2m_strategy_dropdown"
GUI.STRATEGY_TOGGLE = "c2m_strategy_toggle"

-- Order matters: it is the mapping between dropdown index and setting value,
-- and it is also the order the options are presented in, cheapest first.
GUI.STRATEGIES = { "naive", "belt-aware", "dual-phase" }

-- One-line description per strategy, shown under the dropdown so the switcher
-- is self-explanatory without needing the mod settings screen open alongside.
local STRATEGY_TOOLTIP = {
  ["naive"] = { "c2m-gui.strategy-naive-tooltip" },
  ["belt-aware"] = { "c2m-gui.strategy-belt-aware-tooltip" },
  ["dual-phase"] = { "c2m-gui.strategy-dual-phase-tooltip" },
}

---@param strategy string
---@return integer
local function strategy_index(strategy)
  for i, name in ipairs(GUI.STRATEGIES) do
    if name == strategy then return i end
  end
  return 2 -- belt-aware, the default
end

---@param player LuaPlayer
---@param reason? string
---@return boolean
function GUI.cancel_movement(player, reason)
  if not player or not player.valid then return false end

  local data = PlayerData.get_all()[player.index]
  if data then
    PlayerData.cleanup_movement(data.move_entity or player.vehicle or player.character, player, data)
    PlayerData.remove(player.index)
  end

  if Config.is_debug(player.index, "queue") then
    player.print("Click2Move: Auto-walk cancelled" .. (reason and (" (" .. reason .. ").") or "."))
  end
  GUI.update(player.index)
  return data ~= nil
end

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

-- Build (or refresh) the routing-strategy panel.
--
-- Exists so the strategies can be compared by feel in a real base, which is the
-- half of the question the automated benchmark cannot answer: the harness
-- measures ticks-to-arrival on a synthetic arena, but "does this feel like it
-- is fighting me" is a judgement only a player makes. Switching here takes
-- effect on the next move, so the same route can be walked back-to-back under
-- different strategies.
---@param player LuaPlayer
function GUI.build_strategy_panel(player)
  if not player or not player.valid then return end
  local existing = player.gui.left[GUI.STRATEGY_ROOT]
  if existing and existing.valid then existing.destroy() end

  local config = Config.get(player.index)
  local frame = player.gui.left.add {
    type = "frame",
    name = GUI.STRATEGY_ROOT,
    direction = "vertical",
    caption = { "c2m-gui.strategy-title" },
  }

  local items = {}
  for _, name in ipairs(GUI.STRATEGIES) do
    items[#items + 1] = { "c2m-gui.strategy-" .. name }
  end

  local dropdown = frame.add {
    type = "drop-down",
    name = GUI.STRATEGY_SELECT,
    items = items,
    selected_index = strategy_index(config.routing_strategy),
  }
  dropdown.tooltip = STRATEGY_TOOLTIP[config.routing_strategy]
end

---@param player LuaPlayer
function GUI.destroy_strategy_panel(player)
  if not player or not player.valid then return end
  local frame = player.gui.left[GUI.STRATEGY_ROOT]
  if frame and frame.valid then frame.destroy() end
end

-- Show or hide the strategy panel.
---@param player LuaPlayer
function GUI.toggle_strategy_panel(player)
  if not player or not player.valid then return end
  local frame = player.gui.left[GUI.STRATEGY_ROOT]
  if frame and frame.valid then
    frame.destroy()
  else
    GUI.build_strategy_panel(player)
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

-- Handle strategy dropdown selection.
---@param event EventData.on_gui_selection_state_changed
function GUI.on_selection_changed(event)
  if not event.element or not event.element.valid then return end
  if event.element.name ~= GUI.STRATEGY_SELECT then return end

  local player = game.players[event.player_index]
  if not player or not player.valid then return end

  local strategy = GUI.STRATEGIES[event.element.selected_index]
  if not strategy then return end

  -- Written through the player's own mod setting rather than an override, so
  -- the choice persists across sessions and shows up in the settings screen —
  -- a switcher whose state disagreed with the settings menu would be its own
  -- source of confusion.
  --
  -- Wrapped because writing a per-user setting can be refused (it is only
  -- writable by the owning player), and an uncaught error in a GUI handler
  -- takes the whole event down rather than just this click.
  local ok = pcall(function()
    local setting = player.mod_settings["c2m-routing-strategy"]
    setting.value = strategy
    player.mod_settings["c2m-routing-strategy"] = setting
  end)
  if not ok then
    player.print({ "c2m-gui.strategy-write-failed" })
    -- Put the dropdown back where it was, so it cannot show a strategy that is
    -- not actually in effect.
    event.element.selected_index = strategy_index(Config.get(player.index).routing_strategy)
    return
  end

  Config.invalidate(player.index)
  event.element.tooltip = STRATEGY_TOOLTIP[strategy]
  player.print({ "c2m-gui.strategy-changed", { "c2m-gui.strategy-" .. strategy } })
end

return GUI
