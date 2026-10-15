-- Shared fake engine for tests that run the production control.lua.
-- Load from the mod directory: local Fake = dofile("tests/support/fake-factorio.lua")
-- Tests own their entities and settings in a `state` table; Fake.vm boots a
-- fresh Lua environment over that state, so only engine/storage state crosses
-- reloads, as in Factorio.
local Fake = {}

function Fake.defines()
  return {
    direction = {north = 0, northeast = 2, east = 4, southeast = 6, south = 8, southwest = 10, west = 12, northwest = 14},
    riding = {direction = {straight = 0, left = 1, right = 2}, acceleration = {nothing = 0, accelerating = 1, braking = 2, reversing = 3}},
    controllers = {character = 1, remote = 2}, gui_type = {none = 0}, inventory = {character_armor = 1},
    events = {on_tick = 1, on_script_path_request_finished = 2, on_gui_click = 3, on_lua_shortcut = 4,
      on_player_created = 5, on_runtime_mod_setting_changed = 6, on_player_driving_changed_state = 7,
      on_spider_command_completed = 8, on_player_used_spidertron_remote = 9}
  }
end

function Fake.gui()
  local parent = {}
  parent.add = function(spec)
    local child = Fake.gui()
    child.valid, child.name = true, spec.name
    child.destroy = function() child.valid = false; parent[spec.name] = nil end
    parent[spec.name] = child
    return child
  end
  return parent
end

function Fake.player_settings(overrides)
  local values = {
    ["c2m-debug-mode"] = false, ["c2m-character-margin"] = 0.45,
    ["c2m-character-proximity-threshold"] = 1.5, ["c2m-vehicle-proximity-threshold"] = 6,
    ["c2m-stuck-threshold"] = 30, ["c2m-vehicle-path-margin"] = 2,
    ["c2m-vehicle-prefer-straight-paths"] = false, ["c2m-disable-on-arrival"] = false
  }
  for name, value in pairs(overrides or {}) do values[name] = value end
  local result = {}
  for name, value in pairs(values) do result[name] = {value = value} end
  return result
end

-- Armor slot whose contents follow state.flying.
function Fake.armor_inventory(state)
  return function()
    return {
      is_empty = function() return not state.flying end,
      [1] = {valid_for_read = true, prototype = {provides_flight = true}}
    }
  end
end

-- A shortcut-toggle player with a GUI and a print log.
function Fake.player(state, fields)
  local player = {index = 1, valid = true, connected = true, controller_type = 1, opened_gui_type = 0,
    force = {name = "player"}, color = {r = 0.2, g = 0.8, b = 0.2}, gui = {top = Fake.gui()}}
  for key, value in pairs(fields or {}) do player[key] = value end
  state.printed = state.printed or {}
  player.is_shortcut_toggled = function() return state.enabled end
  player.set_shortcut_toggled = function(_, enabled) state.enabled = enabled end
  player.print = function(message) state.printed[#state.printed + 1] = message end
  return player
end

---@param state table storage, tick, surface, player, global_settings and player_settings
function Fake.vm(state)
  local env = setmetatable({}, {__index = _G}); env._G = env
  local loaded, runtime = {}, {env = env, events = {}, nth = {}, booting = true}
  state.objects = state.objects or {}
  env.storage = state.storage
  env.defines = Fake.defines()
  env.settings = {global = state.global_settings, startup = {}, get_player_settings = function() return state.player_settings end}
  env.remote = {interfaces = {}}
  env.game = {tick = state.tick, players = {[1] = state.player}}
  env.script = {
    on_event = function(event, handler)
      assert(event ~= nil, "handler registered for an event missing from Fake.defines")
      runtime.events[event] = handler
    end,
    on_nth_tick = function(interval, handler) runtime.nth[interval] = handler end,
    on_init = function(handler) runtime.init = handler end,
    on_load = function(handler) runtime.load = handler end,
    on_configuration_changed = function(handler) runtime.migrate = handler end
  }
  local function draw(spec)
    local object = {valid = true, spec = spec, color = spec.color, text = spec.text}
    object.destroy = function() object.valid = false end
    state.objects[#state.objects + 1] = object
    return object
  end
  env.rendering = {draw_line = draw, draw_text = draw, draw_circle = draw}
  env.require = function(name)
    assert(runtime.booting, "Factorio does not allow require() inside event handlers")
    if not loaded[name] then loaded[name] = assert(loadfile(name:gsub("%.", "/") .. ".lua", "t", env))() or true end
    return loaded[name]
  end
  env.require("control")
  runtime.pd = env.require("scripts/player-data")
  runtime.navigation = env.require("scripts/navigation")
  runtime.movement = env.require("scripts/movement")
  runtime.pathfinding = env.require("scripts/pathfinding")
  runtime.command_at = function(position, queued)
    local name = queued and "c2m-move-command-queue" or "c2m-move-command"
    runtime.events[name]({player_index = 1, input_name = name, cursor_position = position})
  end
  -- Advance game time and fire on_tick, then any due on_nth_tick handlers.
  runtime.advance = function(amount)
    state.tick = state.tick + amount
    env.game.tick = state.tick
    local handler = runtime.events[env.defines.events.on_tick]
    if handler then handler({tick = state.tick}) end
    for interval, nth_handler in pairs(runtime.nth) do
      if state.tick % interval == 0 then nth_handler({tick = state.tick}) end
    end
  end
  runtime.booting = false
  return runtime
end

return Fake
