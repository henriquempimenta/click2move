--[[
  Click2Move - Pathfinding
  Path request creation, dispatching, and response handling.
]]

local Util = require("scripts/util")
local Config = require("scripts/config")
local PlayerData = require("scripts/player-data")
local Rendering = require("scripts/rendering")
local GUI = require("scripts/gui")

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

-- Only a small prefix is prefetched. Completion and queue edits refill it.
Pathfinding.PREFETCH_GOALS = 3
local requests, retries, next_retry_tick

function Pathfinding.init()
  storage.c2m_path_requests = storage.c2m_path_requests or {}
  storage.c2m_path_retries = storage.c2m_path_retries or {}
  Pathfinding.load()
end

function Pathfinding.load()
  requests = storage.c2m_path_requests
  retries = storage.c2m_path_retries
  next_retry_tick = storage.c2m_next_retry_tick
end

local function ensure_state()
  if not requests or not retries then Pathfinding.init() end
end

local function notify_changed()
  if PlayerData.notify_changed then PlayerData.notify_changed() end
end

local function recalculate_retry_deadline()
  next_retry_tick = nil
  for _, retry in pairs(retries) do
    if not next_retry_tick or retry.tick < next_retry_tick then next_retry_tick = retry.tick end
  end
  storage.c2m_next_retry_tick = next_retry_tick
end

local function schedule_retry(player_index, data, tick)
  local retry = retries[player_index]
  if not retry or retry.data ~= data or tick < retry.tick then
    retries[player_index] = {data = data, tick = tick}
  end
  if not next_retry_tick or tick < next_retry_tick then
    next_retry_tick = tick
    storage.c2m_next_retry_tick = tick
  end
end

function Pathfinding.cancel_player(player_index, data)
  ensure_state()
  for _, goal in ipairs(data and data.goals or {}) do
    if goal.path_id then requests[goal.path_id] = nil end
    goal.path_id = nil
    goal.retry_at = nil
  end
  retries[player_index] = nil
  recalculate_retry_deadline()
end

function Pathfinding.invalidate_goal(player_index, goal_index)
  ensure_state()
  local data = PlayerData.get_all()[player_index]
  local goal = data and data.goals[goal_index or 1]
  if not goal then return end
  if (goal_index or 1) == 1 then PlayerData.stop_input(data.move_entity, data) end
  if goal.path_id then requests[goal.path_id] = nil end
  goal.path_generation = (goal.path_generation or 0) + 1
  goal.path, goal.path_id, goal.retry_at = nil, nil, nil
  data.paths_dirty = true
  Rendering.clear_goal(goal)
  -- A revoked leg must not leave a stale retry wake-up behind. Other prefetched
  -- legs can still have independent deadlines, so retain their earliest one.
  if retries[player_index] then
    local earliest
    for index = 1, math.min(#data.goals, Pathfinding.PREFETCH_GOALS) do
      local deadline = data.goals[index].retry_at
      if deadline and (not earliest or deadline < earliest) then earliest = deadline end
    end
    retries[player_index] = earliest and {data = data, tick = earliest} or nil
    recalculate_retry_deadline()
  end
end

-- Failed legs change the successor's starting position. Completed legs do not.
function Pathfinding.remove_goal(player_index, goal_index, completed)
  ensure_state()
  local data = PlayerData.get_all()[player_index]
  local goal = data and data.goals[goal_index]
  if not goal then return false end
  if goal.path_id then requests[goal.path_id] = nil end
  Rendering.clear_goal(goal)
  table.remove(data.goals, goal_index)
  if goal_index == 1 then
    if not completed then PlayerData.stop_input(data.move_entity, data) end
    PlayerData.reset_movement_state(data, true)
  end
  if not completed then Pathfinding.invalidate_goal(player_index, goal_index) end
  data.paths_dirty = true
  if #data.goals > 0 then
    Pathfinding.request_paths_for_player(player_index)
  else
    PlayerData.remove(player_index)
  end
  Rendering.render_paths_for_player(player_index, PlayerData.get_all())
  GUI.update(player_index)
  notify_changed()
  return true
end

---@param player_index uint32
---@param force? boolean Queue edits force a bounded prefetch check.
---@return boolean
function Pathfinding.request_paths_for_player(player_index, force)
  ensure_state()
  local player = game.players[player_index]
  local data = PlayerData.get_all()[player_index]
  if not player or not player.valid or not player.connected or not data then return false end
  if not force and data.paths_dirty == false then return false end
  local entity = data.move_entity or player.vehicle or player.character
  if not entity or not entity.valid then return false end
  if not PlayerData.can_control_entity(player, entity) or not PlayerData.check_route_surface(data, entity) then
    PlayerData.cleanup_movement(entity, data)
    PlayerData.remove(player_index)
    GUI.update(player_index)
    return false
  end
  local refresh_rendering = force or data.paths_dirty ~= false
  data.paths_dirty = false
  if data.is_straight_line_move then
    if refresh_rendering then Rendering.render_paths_for_player(player_index, PlayerData.get_all()) end
    notify_changed()
    return false
  end
  local changed = false
  for index = 1, math.min(#data.goals, Pathfinding.PREFETCH_GOALS) do
    local goal = data.goals[index]
    if goal.retry_at and game.tick >= goal.retry_at then goal.retry_at = nil end
    if goal.retry_at then schedule_retry(player_index, data, goal.retry_at) end
    if not goal.path and not goal.path_id and not goal.retry_at then
      if entity.type == "spider-vehicle" then
        goal.path = {{position = goal.position}}
        changed = true
      else
        local start = index == 1 and entity.position or data.goals[index - 1].position
        local params = Pathfinding.create_path_request_params(player, start, goal.position)
        if not params then return Pathfinding.remove_goal(player_index, index, false) end
        local id = entity.surface.request_path(params)
        if id then
          goal.path_id = id
          requests[id] = {player_index = player_index, data = data, goal = goal,
            generation = goal.path_generation or 0, entity = entity, surface_index = entity.surface.index}
        else
          goal.retry_at = game.tick + PlayerData.PATH_RETRY_DELAY_TICKS
          schedule_retry(player_index, data, goal.retry_at)
        end
        changed = true
        if Config.is_debug(player_index, "path") then
          player.print("Click2Move: Requested queued path for " .. Util.format_pos(goal.position))
        end
      end
    end
  end
  if force or changed then Rendering.render_paths_for_player(player_index, PlayerData.get_all()) end
  notify_changed()
  return changed
end

function Pathfinding.on_tick(tick)
  ensure_state()
  if not next_retry_tick or tick < next_retry_tick then return end
  local due = {}
  for player_index, retry in pairs(retries) do
    if retry.tick <= tick then
      retries[player_index] = nil
      if PlayerData.get_all()[player_index] == retry.data then due[#due + 1] = player_index end
    end
  end
  recalculate_retry_deadline()
  table.sort(due)
  for _, player_index in ipairs(due) do
    Pathfinding.request_paths_for_player(player_index, true)
    GUI.update(player_index)
  end
end

function Pathfinding.on_path_request_finished(event)
  ensure_state()
  local request = requests[event.id]
  if not request then return end
  requests[event.id] = nil
  local player_index = request.player_index
  local data = PlayerData.get_all()[player_index]
  local goal = request.goal
  if data ~= request.data or goal.path_id ~= event.id
      or (goal.path_generation or 0) ~= request.generation
      or data.move_entity ~= request.entity then return end
  local goal_index
  for index = 1, math.min(#data.goals, Pathfinding.PREFETCH_GOALS) do
    if data.goals[index] == goal then goal_index = index; break end
  end
  if not goal_index then return end
  goal.path_id = nil
  local player = game.players[player_index]
  if not player or not player.valid or not player.connected or not request.entity.valid
      or not PlayerData.can_control_entity(player, request.entity)
      or not PlayerData.check_route_surface(data, request.entity)
      or (request.surface_index and request.surface_index ~= request.entity.surface.index) then
    PlayerData.cleanup_movement(data.move_entity, data)
    PlayerData.remove(player_index)
    if player and player.valid then GUI.update(player_index) end
    return
  end
  if event.path and #event.path > 0 then
    goal.path = event.path
    goal.retry_count = 0
    goal.retry_at = nil
    if goal_index == 1 then PlayerData.reset_movement_state(data, true) end
    Rendering.render_goal(player_index, data, goal, goal_index)
    if Config.is_debug(player_index, "path") then
      player.print("Click2Move: Path found with " .. #event.path .. " waypoints")
    end
  elseif event.try_again_later then
    goal.retry_count = (goal.retry_count or 0) + 1
    if goal.retry_count <= PlayerData.MAX_PATH_RETRIES then
      goal.retry_at = game.tick + PlayerData.PATH_RETRY_DELAY_TICKS
      schedule_retry(player_index, data, goal.retry_at)
    else
      Pathfinding.remove_goal(player_index, goal_index, false)
    end
  else
    player.print({"click2move.no-path-found", Util.format_pos(goal.position)})
    Pathfinding.remove_goal(player_index, goal_index, false)
  end
  GUI.update(player_index)
  notify_changed()
end

return Pathfinding
