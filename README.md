# Click2Move for Factorio

A quality-of-life mod that enables point-and-click movement for your character and vehicles. Inspired by ARPG and RTS games, simply click where you want to go, and the pathfinder will take you there.

## Features

*   **Point-and-Click Movement**: Use a mouse click to set a destination for your character or the vehicle you are driving.
*   **Path Queuing**: Hold **Shift** while clicking to queue up multiple destinations.
*   **Waypoint Skipping**: Straight sections consume multiple waypoints already passed between updates, keeping fast characters with exoskeletons and vehicles moving toward the next target. Turns retain their normal proximity rule, and final destinations are checked separately.
*   **Numbered Destinations**: Queued destinations are numbered on the map so the route order is visible at a glance.
*   **Vehicle Support**: Control cars, tanks, and occupied spidertrons as well as your character. Spidertrons use their own autopilot and finish exactly where it stops.
*   **Corner Speed**: Cars and tanks brake for rounded corners, heading corrections and the destination, forwards and in reverse. Steering and speed planning use the same route of straight sections and tangent arcs. Corners are taken on a racing line that uses both sides of the cleared corridor, and a lane shift round an obstacle becomes one wide curve; every curve is checked against the original path. A bounded refinement widens neighboring bends together, reduces peak and total bending, and lets the final curve reach the destination without imposing an unnecessary final heading. Gentle approach corrections use wider radii to avoid an extra braking cycle. Rounding stays within the path's recorded clearance after allowing for the rotated vehicle body and tracking error; zero or unknown clearance keeps explicit waypoint steering. Speed limits use each vehicle's braking force, weight, friction and turning rate, including the fuel's effect on braking and, for tanks, the fuel and powered exoskeletons' effect on turning. A vehicle outside its cleared corridor crawls back towards it, and fast cars reserve enough distance to brake before a turn.
*   **Obstacle-Free Routes**: Routes are requested with the neutral force so the pathfinder treats rocks, trees and buildings as obstacles. If the returned route still requires destruction, the mod reports "No path found". Each leg uses one initial request; busy pathfinder responses can retry later.
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

## Inspecting margins and curves

In **Settings → Mod settings → Per player**, enable **Debug: Draw Path Margins** and **Debug: Draw Smooth Curve**. They work independently of the chat debug switch. Yellow is the original path, cyan shows its recorded margin, orange shows the smaller allowance available for smoothing after reserving room for the rotated vehicle body and tracking error, and magenta is the exact steering reference. The margin outlines show allowed centerline deviation around the route, not obstacle boundaries or the vehicle's full swept footprint. Circular pieces are sampled only for drawing.

Enable **Debug: Preview Without Moving**, then middle-click a destination to calculate its route without starting movement. A vehicle already moving brakes to a stop first. Change Character Margin or Vehicle Path Margin to recalculate the preview and compare the result. The GUI identifies paused previews; turning preview off keeps the displayed route paused until you click a fresh destination. Cancel clears the overlay. Queued previews calculate the first three paths, matching the normal prefetch window. Flight and spidertron routes have no pathfinder margin or car steering curve. Very large overlays are capped and display a notice when partial.

Enable **Debug: Preview Bézier Curve** to compare an experimental green curve with the magenta steering reference. The green curve is visual only: vehicles continue to use the magenta route. Its cubic bends have zero endpoint curvature and are certified inside the usable smoothing allowance by subdividing their control hulls. Reversals, bends that cannot be certified, or an exhausted preview budget retain the original legs. Long previews are bounded and label missing or unsmoothed portions. This is a local curve construction, separate from the offline convex solver experiments. It smooths bends individually and does not optimize driving time or guarantee the lowest possible peak curvature, even with a large margin.

## Known Issues

*   **Flickering with Mech Armor**: When moving horizontally with mech armor, the character sprite may flicker.
*   **Vehicle Steering**: Steering can overshoot or oscillate, particularly around tight turns or with vehicles that have strong inertia. Vehicles whose prototypes do not describe braking and turning, and scripted vehicles such as Hovercrafts in drift mode, are not slowed for corners as precisely.
*   **Hovercrafts on Factorio 2.0**: Hovercrafts compatibility is optional. With Hovercrafts 2.0.x, New drift mode is not supported: it reports reverse movement as forward speed, so a reversing hovercraft can accelerate instead of stopping, and a hovercraft on a pathfinder route can stop short and abandon its destination. Off and Old drift work with the standard and missile hovercrafts. The electric and laser hovercrafts, which Hovercrafts 2.0.x adds only with the Laser Tanks mod, have not been tested. On Factorio 2.1, Hovercrafts 2.1.4 works in every drift mode.
*   **Spidertron Remote View**: Ordering selected spidertrons from remote view is not supported yet. Remote-view clicks still control the player character or current vehicle.

## Mod Settings

You can adjust these settings in `Settings -> Mod settings`.

| Setting Name                      | Type    | Scope             | Default | Description                                                                                             |
| --------------------------------- | ------- | ----------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| **Debug mode**                    | `Bool`  | Per-Player        | `false` | Enables printing of debug messages to the console for your player.                                      |
| **Debug: Pathfinding / Queue / Stuck Recovery / Vehicle Control** | `Bool` | Per-Player | `true` | Four separate filters for debug output. Only used when Debug mode is on.                        |
| **Debug: Draw Path Margins**       | `Bool`  | Per-Player        | `false` | Draws the recorded margin and usable smoothing allowance with a color legend. |
| **Debug: Draw Smooth Curve**       | `Bool`  | Per-Player        | `false` | Draws the vehicle's actual steering reference in magenta. |
| **Debug: Preview Bézier Curve**    | `Bool`  | Per-Player        | `false` | Draws a certified experimental curve in green; never changes driving. |
| **Debug: Preview Without Moving**  | `Bool`  | Per-Player        | `false` | Calculates paused routes; margin changes recalculate the preview. Independent of chat debug mode. |
| **Character margin**              | `Float` | Per-Player        | `0.45`  | The safety margin added to the character's bounding box for pathfinding. Larger values avoid tighter gaps. |
| **Update interval**               | `Int`   | Global            | `1`     | The number of game ticks between movement updates. Lower is smoother but uses more UPS.                 |
| **Character proximity threshold** | `Float` | Per-Player        | `1.5`   | Base arrival radius in tiles for characters on ground paths or in flight; increases with running speed. |
| **Vehicle proximity threshold**   | `Float` | Per-Player        | `6.0`   | How close (in tiles) a car or tank must be to the final goal to consider it "reached". Spidertrons stop where their autopilot stops instead. |
| **Stuck threshold**               | `Int`   | Per-Player        | `30`    | No-progress limit in game ticks. Ordinary paths wait twice this value; straight-line movement waits this value. |
| **Vehicle path margin**           | `Float` | Per-Player        | `2.0`   | The safety margin added to the vehicle's bounding box for pathfinding.                                  |
| **Vehicle Prefer Straight Paths** | `Bool`  | Per-Player        | `false` | Asks Factorio's pathfinder to prefer straighter vehicle paths. Can be slower to compute.                |
| **Disable on arrival**            | `Bool`  | Per-Player        | `false` | Turns Click2Move mode off after the last queued destination is reached.                                  |

> **Note**: Settings can be changed on the fly. The global update interval re-registers the movement scheduler when changed. Characters on ground paths or in flight check arrival every tick once the destination is close enough to reach before the next scheduled update. Cars and characters also steer every tick while the next update could take them past a corner, or past a waypoint that straight-line movement cannot prove they passed, and vehicles while one update of turning could carry them past the heading they need. Margin settings apply to paths requested after the change. Vehicles finishing a move keep applying their brakes every tick regardless of this interval.

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

Build local release archives with `python3 tools/package.py`. It includes only the files listed in `package-manifest.json`, checks local Lua dependencies and assets, and verifies each finished ZIP. Add new runtime files to the manifest when introducing them. Downloaded mods, tests, editor files, and tooling are excluded.

### Releasing for several Factorio versions

`master` is the only source branch. `targets.json` lists the supported Factorio versions, and `tools/package.py` builds one ZIP for each (`--target 2.0` builds just one). Every ZIP gets that game version's `factorio_version` and `base` dependency, and a version with the game version in its last part: `100 × line + patch`, where the line is 210 for Factorio 2.1 and 200 for 2.0. Source version `0.1.16` therefore ships as `0.1.21016` and `0.1.20016`. The patch must stay below 100. Changelog entries from `0.1.16` (`first_version` in `targets.json`) onwards are renumbered the same way; older entries keep the version they were published as.

To release, set `info.json` and the newest `changelog.txt` entry to the new version, commit, and push tag `v<version>`, such as `v0.1.16`. The publish workflow runs the checks, builds every game version, then uploads each ZIP to the Mod Portal one at a time. A failed upload can be re-run on its own from the workflow page. Before uploading, each job compares its ZIP's SHA-1 with the Portal's release of the same version: an identical release is skipped as already published, and a different one stops the job, because a published version cannot be replaced. CI rebuilds are byte-identical, but local builds can differ when Python uses another zlib, such as zlib-ng on Arch-based systems.

When a game version needs different code, put the replacement file under `targets/<factorio version>/` at the same path, for example `targets/2.0/scripts/vehicle-braking.lua`. It replaces the shared file in that version's ZIP only, and must replace a file listed in `package-manifest.json`. For small differences, prefer a runtime check such as `script.active_mods.base`. To support another Factorio version, add it to `targets.json`.

Optional engine checks require a Factorio executable and an unpacked Hovercrafts directory for the same game version: 2.1.4 for Factorio 2.1, 2.0.4 for 2.0. They install the build for the first version in `targets.json`; add `--target 2.0` when the executable is Factorio 2.0:

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

Driving across generated Vulcanus terrain, with its cliffs, rocks, lava and trees, needs Space Age:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --vulcanus
```

A legendary car on legendary nuclear fuel drives between points about 80 tiles apart at 64 sites, one route at a time, at update intervals of 1 and 10 ticks. Most sites are cut off by lava or by rocks that would need destroying and are reported as unreachable. Every reachable route, at least eight, must arrive without damage, without a sudden loss of speed against a cliff and without stuck recovery.

High-speed driving has its own native suite. It needs the quality mod, which ships with Space Age:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --fast-cars
```

Legendary cars on legendary nuclear fuel drive down 300- and 700-tile walled corridors that end in a right angle, a hairpin or an S-bend. A tank on legendary nuclear fuel and a car on coal take the right angle too. Further legendary cars start facing the closed end of a short corridor that leads the other way, north, north-west or south, and must turn slowly in the tight space without being taken for stuck, once at the default margin and once at a margin of 0. Every vehicle must arrive at update intervals of 1 and 10 ticks without touching a wall or entering stuck recovery. Each case also has a minimum peak speed and an arrival deadline based on earlier native measurements, so slowing every route to a crawl cannot pass the suite. The Vulcanus runner rejects incomplete summaries and requires at least eight reachable routes at each interval.

Braking distances are measured natively against the planner's speed limits, without assuming a braking formula. It needs the quality mod:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --physics
```

Cars and tanks of normal and legendary quality, with and without nuclear fuel of the same quality, on frictionless, nearly frictionless and ordinary ground, brake from the planned limit for 100 and 300 tiles. All 48 must stop within the planned distance, and changing a live vehicle's friction must rebuild its cached speed profile.

Measure trajectory construction in the native engine:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --profile-build
```

This runs 12 routes, including a recorded 403-node path and synthetic paths up to 16,384 nodes. Each gets one warmup and five timed builds, one build per tick. The runner reports median and maximum construction times, curve pieces, tightest radius, refinement work and construction attempts. It checks complete results, repeatable geometry metadata and work limits; timings have no hardware-dependent pass threshold.

Optional curve refinement shares a deterministic weighted work budget, including rejected construction attempts and clearance checks. Results do not depend on elapsed time, so multiplayer peers make the same decisions. Required path processing still grows with the number of nodes: very large paths can exceed one tick even after refinement stops. Compare construction times alongside the driving suites, since reducing search too far can produce tighter bends and slower journeys.

The refinement cap is 32,768 work units. Smaller caps reduced construction cost in synthetic benchmarks but either failed a generated Vulcanus route or slowed the hardest routes, so they are not the production default. For owned routes with at most 1,024 raw waypoints, 128 pieces and enough remaining work, the planner compares its certified route before refitting, after bend polishing and after the terminal-circle change. A linear estimate uses the vehicle's turning law, braking force and explicit heading changes; it omits acceleration and friction and ranks candidates without replacing the conservative safety speed profile. A better certified curve may also be reused when allowance increases on an identical raw path, including a fresh pathfinder result with the same coordinates. The committed reference is saved with its goal, so cache collection, reloads and late joins cannot discard that choice. Live fuel and equipment changes still update speed limits. Normal debug drawing only reads this reference. This preserves previously found candidates, rather than guaranteeing globally optimal or monotonic results on newly requested paths.

Offline curve experiments compare the current planner at three work budgets, a length-minimizing convex program followed by smoothing, and cubic Bézier fits with continuous first and second derivatives. The Bézier fits constrain every control point relative to a straight reference piece, proving containment between samples too. Their bending penalty is a convex surrogate in the reference parameter, rather than geometric curvature or driving time. These optional tools stay outside the mod package:

```sh
python3 -m venv /tmp/c2m-bench-venv
/tmp/c2m-bench-venv/bin/pip install -r tools/benchmark-requirements.txt
/tmp/c2m-bench-venv/bin/python tools/benchmark_curves.py --lua lua5.2 --output /tmp/c2m-curves
python3 tools/benchmark_native_budgets.py --factorio /path/to/bin/x64/factorio --output /tmp/c2m-native-budgets
```

The offline tool writes CSV/JSON measurements, solver status, source metadata and a curve comparison image. It uses four **smoothing allowances after vehicle-body and tracking reserves**, not four player margin settings. Python solver times include model construction and are not Lua runtime predictions. The curvature-only time diagnostic assumes instant acceleration and braking with perfect tracking; it cannot replace native arrival measurements. Fixed-correspondence constraints also restrict the convex candidates more than the production geometric corridor. Nearly singular curves omit that time diagnostic, and an `optimal_inaccurate` solver status provides no optimality certificate even when geometry checks pass.

The visual-only Bézier overlay has a native rendering check too. It creates and destroys actual engine rendering objects at five margins and verifies that the preview does not move the vehicle or change controller progress:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --debug-preview
```

The native budget comparison uses isolated mod copies and records performance deadline/speed-floor violations while retaining collision, stuck-recovery, completion and destination assertions. Run it without other CPU benchmarks. Its output directory must not exist yet. Add `--target 2.0` for a matching Factorio 2.0 executable.

Cornering round real stone walls has a native suite too:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --corners
```

A car and a character each start at rest beside the end of a wall, where the path's first corners are inside the arrival radius, and each must also go round the end of a long wall at speed. An ordinary and a powered character with a margin of 0 must also go round a single wall between them and a destination two tiles away, and twelve characters with five exoskeletons and +50% running speed go round three wall shapes from four starting alignments. The same walls and alignments are then mirrored into all four quadrants as separate scenes, at +50% and +200% running speed (0.5625 and 1.125 tiles per tick) and margins of 0 and 0.45: 192 more characters. Characters that have arrived are moved out of the way. All of them must arrive at update intervals of 1 and 10 ticks without touching a wall or entering stuck recovery, and the characters also at 60. At 60 ticks a car holds one steering input for a whole second and circles tight corners, as 0.1.15 did, so the cars do not run at that interval.

The waypoint suite's 18 base-game cases test straight and diagonal traversal with real powered exoskeletons, running-speed bonuses, forward/reverse cars, update intervals of 1, 10, and 60 ticks, and saved movement history. With Space Age installed, add `--space-age` to include powered mech armor flight, giving 21 cases:

```sh
python3 tests/engine/run.py --factorio /path/to/bin/x64/factorio --waypoints --space-age
```

The runner uses temporary mod, configuration, and save directories. It tests native entities, Hovercraft physics, rendering, storage, save/load, and configuration migration through the production movement handlers. Initial motion is seeded, scheduler registration is instrumented, and player/UI calls are mocked because the headless saves have no connected players. Arrival cases must reach the requested destination and finish the queue; clearing a route alone does not count as success. Interactive controls, obstacle steering beyond the cornering cases, and live multiplayer still require in-game validation.

Before tagging a release, update `info.json` and `changelog.txt`, the only changelog (it is shown on the mod portal and in-game). The publishing workflow runs the checks and requires the tag version to match `info.json`; it does not regenerate release notes or rewrite the version. Pushing a matching `vX.Y.Z` tag publishes to the mod portal using the `Portal` environment's API key.

*Author: Henrique*
