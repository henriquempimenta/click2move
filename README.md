# Click2Move for Factorio

A quality-of-life mod that enables point-and-click movement for your character and vehicles. Inspired by ARPG and RTS games, simply click where you want to go, and the pathfinder will take you there.

## Features

*   **Point-and-Click Movement**: Use a mouse click to set a destination for your character or the vehicle you are driving.
*   **Path Queuing**: Hold **Shift** while clicking to queue up multiple destinations.
*   **Waypoint Skipping**: Straight sections consume multiple waypoints already passed between updates, keeping fast characters with exoskeletons and vehicles moving toward the next target. Turns retain their normal proximity rule, and final destinations are checked separately.
*   **Numbered Destinations**: Queued destinations are numbered on the map so the route order is visible at a glance.
*   **Vehicle Support**: Control cars, tanks, and occupied spidertrons as well as your character. Spidertrons use their own autopilot and finish exactly where it stops.
*   **Vehicle Braking**: Vehicles retain control at destinations until their speed and scripted drift settle before advancing the queue. If braking leaves a vehicle outside the arrival radius, it approaches farther inside and stops again.
*   **Visual Path**: See the calculated path drawn on the ground, so you know exactly where you're headed. The route and numbered destinations also appear on the map when remote view is zoomed out.
*   **Destination Marker**: A crosshair marks your final destination.
*   **Movement GUI**: A small panel appears in the top-left showing your current destination and the number of queued goals. It also includes a "Cancel" button to immediately stop all automatic movement.
*   **Shortcut Mode**: Toggle Click2Move on or off from the shortcut bar.
*   **Disable on Arrival**: Optionally turn Click2Move off after reaching the last queued destination, so the middle mouse button returns to its normal use.
*   **Stuck Detection**: If your character or vehicle gets stuck, the mod will automatically attempt to find a new path to your destination.
*   **Configurable**: Customize the mod's behavior through a variety of settings in the "Mod settings" menu.

## How to Use

*   **Move**: Press **Mouse Button 3** (the middle mouse button by default) on the terrain to move to that location.
*   **Queue Moves**: Hold **Shift** and press **Mouse Button 3** to add a destination to your movement queue.
*   **Cancel Movement**:
    *   Click the "Cancel" button in the top-left GUI.
    *   Use the "**Cancel Click2Move**" custom input if you bind one in Factorio's controls.
    *   Move your character manually with the keyboard (WASD).
    *   Use the vehicle movement keys to take over driving in normal view. Panning in remote view does not cancel movement.
    *   Set a new destination without holding Shift (this will clear the old queue).
*   **Toggle Mode**: Press **Control + Shift + M** or use the shortcut bar button to enable or disable Click2Move. Disabling it cancels the current movement and ignores future movement clicks until re-enabled. With **Disable on arrival** enabled, the mode turns off by itself after the last queued destination is reached; cancelled or unreachable routes leave it on.

Movement continues while map or remote view is open, so you can inspect the route and pan the camera. Use the cancel command or GUI to stop it from those views.

Car and tank commands require the driver's seat. Changing drivers clears the previous driver's route while preserving the new driver's input.

Giving a spidertron a command with a spidertron remote, or another mod assigning it a destination, takes over from Click2Move and clears its route without overwriting that command.

The default keybind can be changed in Factorio's control settings. Look for "**Click to Move**".

## Known Issues

*   **Flickering with Mech Armor**: When moving horizontally with mech armor, the character sprite may flicker.
*   **Vehicle Steering**: Steering can overshoot or oscillate, particularly around tight turns or with vehicles that have strong inertia.
*   **Spidertron Remote View**: Ordering selected spidertrons from remote view is not supported yet. Remote-view clicks still control the player character or current vehicle.

## Mod Settings

You can adjust these settings in `Settings -> Mod settings`.

| Setting Name                      | Type    | Scope             | Default | Description                                                                                             |
| --------------------------------- | ------- | ----------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| **Debug mode**                    | `Bool`  | Per-Player        | `false` | Enables printing of debug messages to the console for your player.                                      |
| **Debug: Pathfinding / Queue / Stuck Recovery / Vehicle Control** | `Bool` | Per-Player | `true` | Four separate filters for debug output. Only used when Debug mode is on.                        |
| **Character margin**              | `Float` | Per-Player        | `0.45`  | The safety margin added to the character's bounding box for pathfinding. Larger values avoid tighter gaps. |
| **Update interval**               | `Int`   | Global            | `1`     | The number of game ticks between movement updates. Lower is smoother but uses more UPS.                 |
| **Character proximity threshold** | `Float` | Per-Player        | `1.5`   | Base arrival radius in tiles for characters on ground paths or in flight; increases with running speed. |
| **Vehicle proximity threshold**   | `Float` | Per-Player        | `6.0`   | How close (in tiles) a car or tank must be to the final goal to consider it "reached". Spidertrons stop where their autopilot stops instead. |
| **Stuck threshold**               | `Int`   | Per-Player        | `30`    | No-progress limit in game ticks. Ordinary paths wait twice this value; straight-line movement waits this value. |
| **Vehicle path margin**           | `Float` | Per-Player        | `2.0`   | The safety margin added to the vehicle's bounding box for pathfinding.                                  |
| **Vehicle Prefer Straight Paths** | `Bool`  | Per-Player        | `false` | Asks Factorio's pathfinder to prefer straighter vehicle paths. Can be slower to compute.                |
| **Disable on arrival**            | `Bool`  | Per-Player        | `false` | Turns Click2Move mode off after the last queued destination is reached.                                  |

> **Note**: Settings can be changed on the fly. The global update interval re-registers the movement scheduler when changed. Characters on ground paths or in flight check arrival every tick once the destination is close enough to reach before the next scheduled update. Vehicles finishing a move keep applying their brakes every tick regardless of this interval.

Stuck recovery lasts 30 game ticks for a character slide and 60 game ticks for a vehicle reverse. These durations and the no-progress limit are independent of the update interval; a larger interval can delay detection until the next scheduled update.

## Installation

1.  Install **Click to Move** from Factorio's in-game Mods menu, or download it from the [Factorio Mod Portal](https://mods.factorio.com/mod/click2move).
2.  If downloading manually, place the `.zip` file into your Factorio `mods` directory.
    *   **Windows**: `C:\Users\<YourUsername>\AppData\Roaming\Factorio\mods`
    *   **Linux**: `~/.factorio/mods`
    *   **macOS**: `~/Library/Application Support/factorio/mods`
3.  Launch Factorio and enable the mod from the "Mods" menu if it's not already enabled.

---

## Development and releases

Run `python3 tools/check.py` from the mod directory to check Lua syntax, run every `tests/*.lua` regression script, and verify packaging. Tests that boot the real `control.lua` share the fake engine in `tests/support/fake-factorio.lua`; add new events and engine APIs there. Python 3.10 or newer and Lua with `luac` are required; CI uses Lua 5.2. Install `jq` to include mocked publish-workflow tests.

Build a local release archive with `python3 tools/package.py`. It includes only the files listed in `package-manifest.json`, checks local Lua dependencies and assets, and verifies the finished ZIP. Add new runtime files to the manifest when introducing them. Downloaded mods, tests, editor files, and tooling are excluded.

Optional engine checks require a Factorio 2.1 executable and an unpacked Hovercrafts 2.1.4 directory:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --hovercraft /path/to/Hovercrafts_2.1.4
```

Run the waypoint suite separately; it requires the Factorio executable:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --waypoints
```

Spidertron autopilot ownership has its own native suite, which also requires only the Factorio executable:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --spiders
```

It drives nine real spidertrons through the production handlers: a normal route; one with five exoskeletons that must measurably move faster; another mod assigning a destination or a follow order after a leg completes; another mod's command finishing 2.2–6 tiles from the goal; a takeover followed by a disconnect; and 0.1.14 routes whose autopilot is still theirs or has been replaced. It also checks that every real arrival lands inside the 2-tile completion radius Click2Move uses to recognise its own arrivals. Spidertron remote input cannot be simulated headlessly.

The waypoint suite's 18 base-game cases test straight and diagonal traversal with real powered exoskeletons, running-speed bonuses, forward/reverse cars, update intervals of 1, 10, and 60 ticks, and saved movement history. With Space Age installed, add `--space-age` to include powered mech armor flight, giving 21 cases:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --waypoints --space-age
```

The runner uses temporary mod, configuration, and save directories. It tests native entities, Hovercraft physics, rendering, storage, save/load, and configuration migration through the production movement handlers. Initial motion is seeded, scheduler registration is instrumented, and player/UI calls are mocked because the headless saves have no connected players. Arrival cases must reach the requested destination and finish the queue; clearing a route alone does not count as success. Interactive controls, obstacle steering, and live multiplayer still require in-game validation.

Before tagging a release, update `info.json` and `changelog.txt`, the only changelog (it is shown on the mod portal and in-game). The publishing workflow runs the checks and requires the tag version to match `info.json`; it does not regenerate release notes or rewrite the version. Pushing a matching `vX.Y.Z` tag publishes to the mod portal using the `Portal` environment's API key.

*Author: Henrique*
