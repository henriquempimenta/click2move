--[[
  Click2Move - Pathfinding
  Path request creation, dispatching, and response handling.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Rendering = require("scripts/rendering")
local GUI = require("scripts/gui")
local DebugCounters = require("scripts/debug-counters")
local Belts = require("scripts/belts")
local DualPhase = require("scripts/dual-phase")
local Navigation = require("scripts/navigation")

local Pathfinding = {}

-- Build path request parameters
---@param player LuaPlayer
---@param start_pos MapPosition
---@param goal MapPosition
---@return LuaSurface.request_path_param | nil
function Pathfinding.create_path_request_params(player, start_pos, goal)
  local data = PlayerData.get_all()[player.index]
  local entity_to_move = data and data.move_entity or player.vehicle or player.character
  if not entity_to_move then return nil end

  local config = Config.get(player.index)
  local is_vehicle_path = entity_to_move.type ~= "character"
  local bounding_box = entity_to_move.prototype and entity_to_move.prototype.collision_box or {{-0.2,-0.2},{0.2,0.2}}
  ---@type number
  local margin = 0
  if is_vehicle_path then
    margin = config.vehicle_path_margin
  else
    margin = config.character_margin
  end

  if bounding_box.left_top and bounding_box.right_bottom then
    bounding_box = {
      left_top = { x = bounding_box.left_top.x - margin, y = bounding_box.left_top.y - margin },
      right_bottom = { x = bounding_box.right_bottom.x + margin, y = bounding_box.right_bottom.y + margin }
    }
  else
    bounding_box = {
      left_top = { x = -margin, y = -margin },
      right_bottom = { x = margin, y = margin }
    }
  end

  local collision_mask = (entity_to_move.prototype and entity_to_move.prototype.collision_mask) and entity_to_move.prototype.collision_mask or {}
  return {
    bounding_box = bounding_box,
    collision_mask = collision_mask,
    start = start_pos,
    goal = goal,
    pathfind_flags = {
      allow_destroy_friendly_entities = false,
      cache = is_vehicle_path,
      prefer_straight_paths = is_vehicle_path and config.vehicle_prefer_straight_paths,
    },
    force = player.force.name,
    entity_to_ignore = entity_to_move
  }
end

-- Start path requests for the player's queued goals
---@param player_index integer | string
---@return boolean
function Pathfinding.request_paths_for_player(player_index)
  local player = game.players[player_index]
  if not player or not player.valid or not player.connected then return false end
  local data = PlayerData.ensure(player_index)
  if not data.goals or #data.goals == 0 then return false end
  local entity_to_move = data.move_entity or player.vehicle or player.character
  if not entity_to_move or not entity_to_move.valid then return false end

  local changed = false

  if entity_to_move.type == "spider-vehicle" then
    for _, goal_data in ipairs(data.goals) do
      if not goal_data.path then
        goal_data.path = { { position = goal_data.position } }
        goal_data.path_id = nil
        goal_data.retry_at = nil
        changed = true
      end
    end
    if changed then
      Rendering.render_paths_for_player(player_index, PlayerData.get_all())
    end
    return changed
  end

  for i, goal_data in ipairs(data.goals) do
    if goal_data.retry_at and game.tick >= goal_data.retry_at then
      goal_data.retry_at = nil
    end

    if not goal_data.path and not goal_data.path_id and not goal_data.retry_at then
      local start_pos
      if i == 1 then
        start_pos = entity_to_move.position
      else
        start_pos = data.goals[i-1].position
      end

      local params = Pathfinding.create_path_request_params(player, start_pos, goal_data.position)
      if params then
        local path_id = entity_to_move.surface.request_path(params)
        goal_data.path_id = path_id
        goal_data.retry_count = goal_data.retry_count or 0
        changed = true
        DebugCounters.count("path_requests")
        if Config.is_debug(player_index, "path") then
          player.print("Click2Move: Requested queued path for " .. Util.format_pos(goal_data.position) .. " (player " .. player_index .. ")")
        end
      else
        table.remove(data.goals, i)
        changed = true
        break
      end
    end
  end

  if changed then
    Rendering.render_paths_for_player(player_index, PlayerData.get_all())
  end

  return changed
end

-- Post-process a pathfinder result for belt drift.
--
-- The pathfinder does not model transport belts, so its "shortest" path can run
-- straight down a belt that pushes the character backwards. This rewrites the
-- waypoint list to step off opposing belts, and optionally to ride helpful
-- ones. Returns a waypoint list in the same shape the caller expects
-- (`{ position = ... }` entries), so nothing downstream needs to care.
---@param player LuaPlayer
---@param data PlayerMoveData
---@param goal_data MoveGoal
---@param raw_path PathfinderWaypoint[]
---@return PathfinderWaypoint[]
function Pathfinding.apply_belt_awareness(player, data, goal_data, raw_path)
  local config = Config.get(player.index)
  if not Config.uses_belts(player.index) then return raw_path end

  local entity = data.move_entity or player.vehicle or player.character
  -- Vehicles are unaffected by belts; only characters get dragged.
  if not entity or not entity.valid or entity.type ~= "character" then return raw_path end

  local ok, waypoints, info = pcall(Belts.plan,
    entity.surface, entity.position, raw_path, goal_data.position,
    { belt_ride = config.belt_ride })

  -- Belt planning is an optimization, never a requirement: if it errors, fall
  -- back to the pathfinder's own path rather than failing the move.
  if not ok or not waypoints or #waypoints == 0 then
    if Config.is_debug(player.index, "path") then
      player.print("Click2Move: Belt planning failed, using raw path.")
    end
    return raw_path
  end

  if not info.changed then return raw_path end

  DebugCounters.count("belt_replans")
  if info.ride then DebugCounters.count("belt_rides") end
  goal_data.belt_info = info

  if Config.is_debug(player.index, "path") then
    player.print(string.format(
      "Click2Move: Belt-aware route: %d detour(s)%s, %.0f -> %.0f ticks est.",
      info.detours, info.ride and " + belt ride" or "",
      info.base_ticks or 0, info.final_ticks or 0))
  end

  local rebuilt = {}
  for _, wp in ipairs(waypoints) do
    rebuilt[#rebuilt + 1] = { position = wp }
  end
  return rebuilt
end

-- Progressive fallbacks used when a path request comes back empty.
--
-- The stock behaviour was to print "No path found" and drop the goal, which is
-- how the mod ends up refusing to move a character standing in a one-tile gap
-- between buildings. Most of those failures are not "genuinely blocked in" —
-- they are the request being over-constrained:
--
--   * `character_margin` inflates the bounding box, so a gap the character
--     actually fits through reads as solid;
--   * the start position itself can be inside something's collision box, which
--     fails the request before it explores anything;
--   * the goal can be on top of a building, which has no valid destination.
--
-- Each rung loosens one of those and re-requests. They are ordered cheapest and
-- least surprising first, and only run on the failure path, so a normal
-- successful move pays nothing for any of this.
Pathfinding.FALLBACKS = { "tight_margin", "nudge_start", "relax_goal", "escape" }

-- Build a request with an overridden margin and/or start/goal.
---@param player LuaPlayer
---@param data PlayerMoveData
---@param start_pos MapPosition
---@param goal MapPosition
---@param margin number | nil
---@return LuaSurface.request_path_param | nil
local function build_request(player, data, start_pos, goal, margin)
  local params = Pathfinding.create_path_request_params(player, start_pos, goal)
  if not params then return nil end
  if margin then
    local entity = data.move_entity or player.vehicle or player.character
    local box = entity and entity.prototype and entity.prototype.collision_box
      or { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } }
    params.bounding_box = {
      left_top = { x = box.left_top.x - margin, y = box.left_top.y - margin },
      right_bottom = { x = box.right_bottom.x + margin, y = box.right_bottom.y + margin },
    }
  end
  return params
end

local function positions_close(a, b)
  return Util.distance_sq(a, b) < 0.01
end

local function append_position(route, position)
  local last = route[#route]
  if not last or not positions_close(last, position) then
    route[#route + 1] = { x = position.x, y = position.y }
  end
end

local function request_validation_leg(player, data, goal_data)
  local state = goal_data.belt_validation
  local entity = data.move_entity or player.vehicle or player.character
  if not state or not entity or not entity.valid then return false end

  while state.leg_index <= #state.corridor do
    local target = state.corridor[state.leg_index]
    local start_pos = state.connected[#state.connected] or state.origin
    if positions_close(start_pos, target) then
      append_position(state.connected, target)
      state.leg_index = state.leg_index + 1
    else
      local params = Pathfinding.create_path_request_params(player, start_pos, target)
      if not params then return false end
      state.request_id = entity.surface.request_path(params)
      DebugCounters.count("path_requests")
      return true
    end
  end

  -- Every corridor leg is now a real pathfinder route. Rebase it once more
  -- because the character kept walking while those legs were connected, then
  -- ask the pathfinder for a final join from its current position.
  local suffix = DualPhase.rebase_route(entity.surface, entity.position, state.connected)
  if #suffix == 0 then return false end
  state.phase = "join"
  state.suffix = suffix

  if positions_close(entity.position, suffix[1]) then
    goal_data.belt_validation = nil
    if DualPhase.try_install_validated(player, data, goal_data, suffix) then
      Rendering.render_paths_for_player(player.index, PlayerData.get_all())
      GUI.update(player.index)
    end
    return true
  end

  local params = Pathfinding.create_path_request_params(player, entity.position, suffix[1])
  if not params then return false end
  state.request_id = entity.surface.request_path(params)
  DebugCounters.count("path_requests")
  return true
end

-- Connect every sparse BeltGraph corridor point through Factorio's real
-- pathfinder. The incumbent route remains active throughout validation.
function Pathfinding.begin_candidate_path(player, data, goal_data, corridor)
  local entity = data.move_entity or player.vehicle or player.character
  if not entity or not entity.valid or #corridor == 0 then return false end

  local copied = {}
  for _, point in ipairs(corridor) do
    append_position(copied, point)
  end
  goal_data.belt_validation = {
    phase = "corridor",
    corridor = copied,
    leg_index = 1,
    connected = {},
    origin = { x = entity.position.x, y = entity.position.y },
  }

  if request_validation_leg(player, data, goal_data) then return true end
  goal_data.belt_validation = nil
  return false
end

local function handle_validation_result(player_index, goal_index, event)
  local data = PlayerData.get_all()[player_index]
  local player = game.players[player_index]
  local goal_data = data and data.goals and data.goals[goal_index]
  local state = goal_data and goal_data.belt_validation
  if not player or not player.connected or not state or state.request_id ~= event.id then return false end

  state.request_id = nil
  if goal_index ~= 1 or not event.path or #event.path == 0 then
    goal_data.belt_validation = nil
    DebugCounters.count("belt_swaps_rejected")
    return true
  end

  if state.phase == "corridor" then
    for _, waypoint in ipairs(event.path) do
      if waypoint and waypoint.position then append_position(state.connected, waypoint.position) end
    end
    state.leg_index = state.leg_index + 1
    if not request_validation_leg(player, data, goal_data) then
      goal_data.belt_validation = nil
      DebugCounters.count("belt_swaps_rejected")
    end
    return true
  end

  local connected = {}
  for _, waypoint in ipairs(event.path) do
    if waypoint and waypoint.position then append_position(connected, waypoint.position) end
  end
  for i = 2, #(state.suffix or {}) do append_position(connected, state.suffix[i]) end
  goal_data.belt_validation = nil
  if DualPhase.try_install_validated(player, data, goal_data, connected) then
    Rendering.render_paths_for_player(player_index, PlayerData.get_all())
    GUI.update(player_index)
  end
  return true
end

-- Try the next fallback for a goal that failed to path. Returns true if a new
-- request was dispatched (so the caller should keep the goal alive and wait).
---@param player LuaPlayer
---@param data PlayerMoveData
---@param goal_data MoveGoal
---@return boolean dispatched
function Pathfinding.try_fallback(player, data, goal_data)
  local config = Config.get(player.index)
  if not config.never_give_up then return false end

  local entity = data.move_entity or player.vehicle or player.character
  if not entity or not entity.valid then return false end
  local surface = entity.surface

  goal_data.fallback_stage = (goal_data.fallback_stage or 0) + 1
  local stage = Pathfinding.FALLBACKS[goal_data.fallback_stage]
  if not stage then return false end

  local start_pos = entity.position
  local goal = goal_data.position
  local margin = nil

  if stage == "tight_margin" then
    -- Same route, but stop pretending the character is bigger than it is.
    margin = config.squeeze_margin

  elseif stage == "nudge_start" then
    -- The character's own position may be inside a collision box (common right
    -- after being pushed by a belt or spawned against a wall). Start from the
    -- nearest spot it can legitimately stand.
    margin = config.squeeze_margin
    local free = surface.find_non_colliding_position("character", start_pos, 8, 0.25)
    if not free then return Pathfinding.try_fallback(player, data, goal_data) end
    start_pos = free

  elseif stage == "relax_goal" then
    -- Clicking on a building has no reachable destination. Walk to the nearest
    -- standable tile to it instead, which is what the player meant.
    margin = config.squeeze_margin
    local free = surface.find_non_colliding_position("character", goal, 16, 0.25)
    if not free then return Pathfinding.try_fallback(player, data, goal_data) end
    goal = free
    goal_data.relaxed_goal = free

  elseif stage == "escape" then
    -- Every pathfinder attempt failed. Before declaring defeat, walk a short
    -- way toward the goal under the stuck-recovery machinery: the character is
    -- probably in a pocket the pathfinder cannot start from, and a couple of
    -- tiles of movement is usually enough to get somewhere it can.
    data.stuck_state = "sliding"
    data.stuck_timer = 30
    data.slide_direction = Navigation.get_character_direction(start_pos, goal)
      or defines.direction.north
    goal_data.path = nil
    goal_data.path_id = nil
    goal_data.retry_at = game.tick + 30
    DebugCounters.count("path_fallbacks")
    if Config.is_debug(player.index, "path") then
      player.print("Click2Move: No route; attempting to walk clear and retry.")
    end
    return true
  end

  local params = build_request(player, data, start_pos, goal, margin)
  if not params then return false end

  goal_data.path_id = surface.request_path(params)
  goal_data.path = nil
  DebugCounters.count("path_requests")
  DebugCounters.count("path_fallbacks")
  if Config.is_debug(player.index, "path") then
    player.print("Click2Move: Route failed; retrying (" .. stage .. ").")
  end
  return true
end

-- Handle path request finished event
---@param event EventData.on_script_path_request_finished
function Pathfinding.on_path_request_finished(event)
  -- find matching player
  local matched_player_index = nil
  local matched_goal_index = nil
  for p_index, p_data in pairs(PlayerData.get_all()) do
    for g_index, goal_data in ipairs(p_data.goals) do
      if goal_data.belt_validation and goal_data.belt_validation.request_id == event.id then
        handle_validation_result(p_index, g_index, event)
        return
      end
      if goal_data.path_id == event.id then
        matched_player_index = p_index
        matched_goal_index = g_index
        break
      end
    end
    if matched_player_index then break end
  end
  if not matched_player_index or not matched_goal_index then return end

  local player = game.players[matched_player_index]
  if not player or not player.connected then
    PlayerData.remove(matched_player_index)
    return
  end

  local data = PlayerData.get_all()[matched_player_index]
  local goal_data = data.goals[matched_goal_index]
  local changed = false
  goal_data.path_id = nil

  -- if path present and non-empty
  if event.path and #event.path > 0 then
    if Config.is_debug(matched_player_index, "path") then player.print("Click2Move: Path found with " .. #event.path .. " waypoints for player " .. matched_player_index) end
    goal_data.path = Pathfinding.apply_belt_awareness(player, data, goal_data, event.path)

    -- Phase 1 has landed and the character is about to start walking. Kick off
    -- the Phase-2 belt-graph search now so it runs *while* the character moves,
    -- which is what keeps the better route from costing any startup delay.
    if Config.uses_dual_phase(player.index) then
      DualPhase.maybe_start(player, data, goal_data)
    end
    if matched_goal_index == 1 then
      data.current_waypoint = 1
      data.stuck_counter = 0
      data.last_position = nil
      data.vehicle_stuck_counter = 0
      data.last_vehicle_position = nil
      data.closest_dist_to_goal = 999999
      data.no_progress_ticks = 0
      data.stuck_state = "none"
      data.stuck_timer = 0
      data.slide_direction = nil
    end
    goal_data.retry_count = 0
    changed = true
    goal_data.retry_at = nil

    Rendering.render_paths_for_player(matched_player_index, PlayerData.get_all())
  else
    -- no path returned
    if event.try_again_later then
      changed = true
      goal_data.retry_count = (goal_data.retry_count or 0) + 1
      if goal_data.retry_count <= PlayerData.MAX_PATH_RETRIES then
        goal_data.retry_at = game.tick + PlayerData.PATH_RETRY_DELAY_TICKS
        if Config.is_debug(matched_player_index, "path") then player.print("Click2Move: try_again_later - retrying in " .. PlayerData.PATH_RETRY_DELAY_TICKS .. " ticks (attempt " .. goal_data.retry_count .. ")") end
      elseif Pathfinding.try_fallback(player, data, goal_data) then
        -- Retries exhausted, but a looser request may still succeed.
        changed = true
      else
        if Config.is_debug(matched_player_index, "path") then player.print("Click2Move: Max retries reached, dropping goal.") end
        -- drop current goal and try next
        table.remove(data.goals, matched_goal_index)
        Rendering.render_paths_for_player(matched_player_index, PlayerData.get_all())
        changed = true
        Pathfinding.request_paths_for_player(matched_player_index)
      end
    else
      -- Permanent failure from the pathfinder's point of view. That usually
      -- means the request was over-constrained rather than the character being
      -- genuinely walled in, so work down the fallback ladder before giving up.
      if Pathfinding.try_fallback(player, data, goal_data) then
        changed = true
      else
        player.print("Click2Move: No route to " .. Util.format_pos(goal_data.position)
          .. " — the character appears to be blocked in.")
        changed = true
        table.remove(data.goals, matched_goal_index)
        Rendering.render_paths_for_player(matched_player_index, PlayerData.get_all())
        Pathfinding.request_paths_for_player(matched_player_index)
      end
    end
  end
  if changed then GUI.update(matched_player_index) end
end

return Pathfinding
