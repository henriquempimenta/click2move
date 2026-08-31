--[[
  Click2Move - Debug remote interface

  Exposes the mod's internal movement state so an out-of-game harness (RCON)
  can drive movement and measure it. Movement is normally only reachable via
  `custom-input` events, which RCON cannot fire, and `player_move_data` is a
  module-local table, so without this interface the mod is untestable at
  runtime.

  Registered only when the `c2m-enable-debug-interface` startup setting is on.
  The interface is disabled by default in normal play.

  Usage from RCON:
    /silent-command rcon.print(helpers.table_to_json(
      remote.call("click2move-debug", "get_state", 1)))
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Pathfinding = require("scripts/pathfinding")
local DebugCounters = require("scripts/debug-counters")
local GUI = require("scripts/gui")
local Belts = require("scripts/belts")
local BeltGraph = require("scripts/belt-graph")

local DebugInterface = {}

---@param player_index uint32
---@return table
local function get_state(player_index)
  local player = game.players[player_index]
  if not player then return { error = "no such player" } end

  local data = PlayerData.get_all()[player_index]
  local character = player.character
  local pos = character and character.position or player.position

  local state = {
    tick = game.tick,
    position = { x = pos.x, y = pos.y },
    walking = character and character.walking_state.walking or false,
    has_data = data ~= nil,
    goal_count = 0,
    current_waypoint = 0,
    stuck_state = "none",
    stuck_counter = 0,
    no_progress_ticks = 0,
    closest_dist_to_goal = -1,
    is_straight_line_move = false,
    render_obj_count = 0,
    waiting_for_path = false,
  }

  if data then
    state.goal_count = #data.goals
    state.current_waypoint = data.current_waypoint
    state.stuck_state = data.stuck_state or "none"
    state.stuck_counter = data.stuck_counter or 0
    state.no_progress_ticks = data.no_progress_ticks or 0
    state.closest_dist_to_goal = data.closest_dist_to_goal or -1
    state.is_straight_line_move = data.is_straight_line_move or false
    state.render_obj_count = data.render_objs and #data.render_objs or 0

    local goal = data.goals[1]
    if goal then
      state.goal = { x = goal.position.x, y = goal.position.y }
      state.waiting_for_path = goal.path == nil
      state.path_length = goal.path and #goal.path or 0
      state.retry_count = goal.retry_count or 0
      state.fallback_stage = goal.fallback_stage or 0
      -- What the belt planner decided, so a benchmark can attribute a timing
      -- difference to a specific routing decision rather than guessing.
      if goal.belt_info then
        state.belt_info = {
          detours = goal.belt_info.detours,
          ride = goal.belt_info.ride and true or false,
          base_ticks = goal.belt_info.base_ticks,
          final_ticks = goal.belt_info.final_ticks,
        }
      end
    end
  end

  -- Whether the character is currently standing on a belt. This is the metric
  -- that actually proves a route left the bus, rather than arriving on time by
  -- luck.
  if character then
    state.on_belt = Belts.on_belt(character.surface, character.position)
  end
  state.squeak_through = Config.has_squeak_through()

  state.counters = DebugCounters.snapshot()
  return state
end

-- Mirrors the `c2m-move-command` branch of on_custom_input so the harness
-- exercises the real code path rather than a parallel implementation.
---@param player_index uint32
---@param goal MapPosition
---@return boolean
local function set_goal(player_index, goal)
  local player = game.players[player_index]
  if not player then return false end
  local entity_to_move = (player.vehicle and player.vehicle.valid)
    and player.vehicle or player.character
  if not entity_to_move then return false end

  local data = PlayerData.ensure(player_index)
  data.move_entity = entity_to_move
  data.goals = { { position = { x = goal.x, y = goal.y } } }
  data.current_waypoint = 1
  Util.safe_destroy_renderings(data.render_objs)
  data.render_objs = nil
  data.stuck_counter = 0
  data.last_position = nil
  data.is_auto_walking = false
  data.vehicle_stuck_counter = 0
  data.last_vehicle_position = nil
  data.closest_dist_to_goal = 999999
  data.no_progress_ticks = 0
  data.stuck_state = "none"
  data.stuck_timer = 0
  data.slide_direction = nil

  if entity_to_move.type == "character" and PlayerData.is_bypassing_pathfinding(player) then
    data.is_straight_line_move = true
    return true
  end
  data.is_straight_line_move = nil

  Pathfinding.request_paths_for_player(player_index)
  return true
end

function DebugInterface.register()
  local enabled = settings.startup["c2m-enable-debug-interface"]
  if not enabled or enabled.value ~= true then return end

  remote.add_interface("click2move-debug", {
    -- Read the full movement state for a player.
    get_state = function(player_index) return get_state(player_index) end,

    -- Issue a move command as if the player middle-clicked at `goal`.
    set_goal = function(player_index, goal) return set_goal(player_index, goal) end,

    -- Clear any in-progress movement for a player.
    cancel = function(player_index)
      local player = game.players[player_index]
      local data = PlayerData.get_all()[player_index]
      if player and data then
        PlayerData.cleanup_movement(data.move_entity, player, data)
        data.goals = {}
      end
      return true
    end,

    reset_counters = function()
      DebugCounters.reset()
      return true
    end,

    -- Effective per-player config, for asserting a harness run used the
    -- settings it thinks it did.
    get_config = function(player_index) return Config.get(player_index) end,

    -- Override a config value for a player. Exists because per-player mod
    -- settings can only be written by the owning player or the declaring mod,
    -- so a benchmark driving the game over RCON cannot switch routing strategy
    -- any other way.
    set_config = function(player_index, key, value)
      Config.set_override(player_index, key, value)
      return true
    end,

    clear_config = function(player_index)
      Config.clear_overrides(player_index)
      return true
    end,

    -- Run the Phase-2 belt-graph A* to completion between two points and
    -- report what it produced, without moving anything.
    --
    -- The search is normally spread across ticks and its result is only visible
    -- as a swap that did or did not happen, which makes "the swap was rejected"
    -- indistinguishable from "the search found nothing" and from "the cost
    -- model is wrong". This runs it synchronously and returns the route plus
    -- both cost estimates, so those three cases can be told apart.
    probe_route = function(origin, goal)
      local surface = game.surfaces[1]
      local search = BeltGraph.begin(surface, origin, goal)
      -- Bounded: BeltGraph.step enforces MAX_EXPANSIONS internally, this is
      -- only a guard against an unterminating driver loop.
      local slices = 0
      while not BeltGraph.step(search) and slices < 1000 do
        slices = slices + 1
      end

      local out = {
        slices = slices,
        expansions = search.expansions,
        done = search.done,
        found = search.result ~= nil,
        straight_cost = Belts.route_cost(surface, origin, { goal }),
      }
      if search.result then
        out.waypoints = {}
        for _, wp in ipairs(search.result) do
          out.waypoints[#out.waypoints + 1] = { x = wp.x, y = wp.y }
        end
        out.graph_cost = BeltGraph.route_cost(search, origin)
        out.belts_cost = Belts.route_cost(surface, origin, search.result)
      end
      return out
    end,

    -- Drive the routing-strategy panel from a test.
    --
    -- GUI events cannot be raised with `script.raise_event`, so a harness has no
    -- way to click a button. These call the same handlers the real events call,
    -- with a synthetic event table, so the panel's build and selection paths are
    -- actually executed rather than assumed to work.
    gui_toggle_strategy = function(player_index)
      local player = game.players[player_index]
      if not player then return { error = "no such player" } end
      GUI.toggle_strategy_panel(player)
      local frame = player.gui.left[GUI.STRATEGY_ROOT]
      return { open = frame ~= nil and frame.valid }
    end,

    gui_select_strategy = function(player_index, strategy)
      local player = game.players[player_index]
      if not player then return { error = "no such player" } end
      local frame = player.gui.left[GUI.STRATEGY_ROOT]
      if not frame or not frame.valid then
        GUI.build_strategy_panel(player)
        frame = player.gui.left[GUI.STRATEGY_ROOT]
      end
      local dropdown = frame and frame[GUI.STRATEGY_SELECT]
      if not dropdown or not dropdown.valid then return { error = "no dropdown" } end

      local index
      for i, name in ipairs(GUI.STRATEGIES) do
        if name == strategy then index = i end
      end
      if not index then return { error = "unknown strategy: " .. tostring(strategy) } end

      dropdown.selected_index = index
      GUI.on_selection_changed({ element = dropdown, player_index = player_index })
      return {
        selected = GUI.STRATEGIES[dropdown.selected_index],
        effective = Config.get(player_index).routing_strategy,
      }
    end,

    -- Cheap liveness probe.
    ping = function() return game.tick end,
  })
end

return DebugInterface
