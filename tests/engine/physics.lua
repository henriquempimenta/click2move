-- Loaded as the isolated test mod's control script. No player, entity or
-- physics APIs are mocked. Check the production speed limit against the
-- engine's actual braking distance, without assuming a braking formula.
local VehicleSpeed = require("scripts/vehicle-speed")
local WARMUP_TICKS = 30
local STOP_DEADLINE = 4000
local FRICTIONS = {0, 1e-16, 1}

local function path_from(position, length)
  return {{position = {x = position.x, y = position.y}},
    {position = {x = position.x + length, y = position.y}}}
end

local function name(case)
  return string.format("%s %s %s friction=%.3g distance=%d", case.actor.name, case.actor.quality.name,
    case.fueled and "fueled" or "unfueled", case.friction, case.distance)
end

script.on_init(function()
  local surface = game.create_surface("c2m-native-physics", {width = 2048, height = 512})
  surface.request_to_generate_chunks({320, 0}, 12)
  surface.force_generate_chunk_requests()
  for _, entity in pairs(surface.find_entities()) do entity.destroy() end
  local tiles = {}
  for x = -8, 700 do
    for y = -128, 128 do tiles[#tiles + 1] = {name = "concrete", position = {x, y}} end
  end
  surface.set_tiles(tiles)
  storage.physics = {cases = {}}
  local cases = storage.physics.cases
  for _, prototype in ipairs({"car", "tank"}) do
    for _, quality in ipairs({"normal", "legendary"}) do
      for _, fueled in ipairs({false, true}) do
        for _, friction in ipairs(FRICTIONS) do
          for _, distance in ipairs({100, 300}) do
            local position = {x = 0, y = (#cases + 1) * 5 - 122.5}
            local actor = surface.create_entity{name = prototype, quality = quality,
              position = position, force = "player"}
            local driver = surface.create_entity{name = "character", position = position, force = "player"}
            assert(actor and driver, "could not create native physics actors")
            actor.set_driver(driver)
            actor.orientation = .25
            actor.friction_modifier = friction
            assert(friction == 0 and actor.friction_modifier == 0 or friction > 0 and actor.friction_modifier > 0,
              "the engine did not accept the requested friction modifier")
            if fueled then
              assert(actor.get_fuel_inventory().insert{name = "nuclear-fuel", quality = quality, count = 1} == 1)
              actor.riding_state = {acceleration = defines.riding.acceleration.accelerating,
                direction = defines.riding.direction.straight}
            end
            cases[#cases + 1] = {actor = actor, fueled = fueled, friction = friction, distance = distance}
          end
        end
      end
    end
  end
  assert(#cases == 48, "incomplete native physics matrix")
end)

script.on_event(defines.events.on_tick, function(event)
  local probe = storage.physics
  if probe.done then return end
  if event.tick < WARMUP_TICKS then return end
  if not probe.armed then
    for _, case in ipairs(probe.cases) do
      local actor = case.actor
      assert((actor.burner.currently_burning ~= nil) == case.fueled, name(case) .. " has the wrong fuel state")
      case.start = {x = actor.position.x, y = actor.position.y}
      case.path = path_from(case.start, case.distance)
      -- Use the same path and live entity for every call: changing friction
      -- must invalidate both the braking model and its backward speed profile.
      actor.friction_modifier = 1
      local stock = VehicleSpeed.limit(actor, case.path, 2, 2, 0)
      actor.friction_modifier = 0
      local zero = VehicleSpeed.limit(actor, case.path, 2, 2, 0)
      actor.friction_modifier = 1
      local restored = VehicleSpeed.limit(actor, case.path, 2, 2, 0)
      assert(zero > 0 and zero < stock, name(case) .. " retained its stock-friction cached limit")
      assert(math.abs(restored - stock) < 1e-9, name(case) .. " retained its zero-friction cached limit")
      actor.friction_modifier = case.friction
      case.limit = VehicleSpeed.limit(actor, case.path, 2, 2, 0)
      assert(case.limit > 0 and case.limit < math.huge, name(case) .. " returned an invalid limit")
      actor.speed = case.limit
      actor.riding_state = {acceleration = defines.riding.acceleration.braking,
        direction = defines.riding.direction.straight}
    end
    probe.armed = event.tick
    return
  end
  local finished = 0
  for _, case in ipairs(probe.cases) do
    local actor = case.actor
    assert(actor.valid, name(case) .. " was destroyed")
    local traveled = actor.position.x - case.start.x
    assert(traveled <= case.distance + .05, string.format("%s could not stop: traveled %.3f at limit %.6f",
      name(case), traveled, case.limit))
    assert(math.abs(actor.position.y - case.start.y) < .05, name(case) .. " left its straight test lane")
    if actor.speed == 0 then
      if not case.stopped then
        case.stopped = event.tick
        print(string.format("C2M_PHYSICS_STOP %s limit=%.9f traveled=%.6f ticks=%d", name(case),
          case.limit, traveled, event.tick - probe.armed))
      end
      finished = finished + 1
    end
  end
  if finished == #probe.cases then
    print(string.format("C2M_NATIVE_PHYSICS_OK %d actual native braking distances and live friction cache changes", finished))
    probe.done = true
  else
    assert(event.tick - probe.armed < STOP_DEADLINE, "native physics cases did not stop before the deadline")
  end
end)
