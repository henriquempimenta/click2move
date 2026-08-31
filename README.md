# Click2Move for Factorio

A quality-of-life mod that enables point-and-click movement for your character and vehicles. Inspired by ARPG and RTS games, simply click where you want to go, and the pathfinder will take you there.

## Features

*   **Point-and-Click Movement**: Use a mouse click to set a destination for your character or the vehicle you are driving.
*   **Path Queuing**: Hold **Shift** while clicking to queue up multiple destinations.
*   **Numbered Destinations**: Queued destinations are numbered on the map so the route order is visible at a glance.
*   **Vehicle Support**: Works seamlessly whether you are on foot or in a vehicle.
*   **Visual Path**: See the calculated path drawn on the ground, so you know exactly where you're headed.
*   **Destination Marker**: A crosshair marks your final destination.
*   **Movement GUI**: A small panel appears in the top-left showing your current destination and the number of queued goals. It also includes a "Cancel" button to immediately stop all automatic movement.
*   **Shortcut Mode**: Toggle Click2Move on or off from the shortcut bar.
*   **Stuck Detection**: If your character or vehicle gets stuck, the mod will automatically attempt to find a new path to your destination.
*   **Belt-Aware Routing**: Factorio's pathfinder does not know transport belts exist — they do not block you, so it will happily route you straight down a belt that shoves you backwards the whole way. This build accounts for them: it steps off belts that oppose your travel, rides ones going your way when that is actually faster, and can compute a better route in the background while you are already walking. See [Routing strategies](#routing-strategies).
*   **Configurable**: Customize the mod's behavior through a variety of settings in the "Mod settings" menu.

## How to Use

*   **Move**: Press **Mouse Button 3** (the middle mouse button by default) on the terrain to move to that location.
*   **Queue Moves**: Hold **Shift** and press **Mouse Button 3** to add a destination to your movement queue.
*   **Cancel Movement**:
    *   Click the "Cancel" button in the top-left GUI.
    *   Use the "**Cancel Click2Move**" custom input if you bind one in Factorio's controls.
    *   Move your character manually with the keyboard (WASD).
    *   Set a new destination without holding Shift (this will clear the old queue).
*   **Toggle Mode**: Press **Control + Shift + M** or use the shortcut bar button to enable or disable Click2Move. Disabling it cancels the current movement and ignores future movement clicks until re-enabled.

The default keybind can be changed in Factorio's control settings. Look for "**c2m-move-command**".

## Routing strategies

Factorio's pathfinder treats transport belts as ordinary walkable ground. They
do not collide with you, so the shortest path it returns may run straight down
a belt that pushes you the other way — measured on a four-lane bus, that is not
"a bit slower" but net *backwards* movement.

Three strategies are available. Switch between them live with
**Control + Shift + R**, or in `Settings -> Mod settings -> Per player`.

| Strategy | What it does | When to use it |
| --- | --- | --- |
| **Naive** | Walks the pathfinder's route as-is, ignoring belts. The original behaviour. | Bases with few belts, or if you want the old feel back. |
| **Belt-aware** (default) | Steps off belts that oppose you and rides ones going your way when that is genuinely faster. Decided once, when the route is found. | Almost always. |
| **Dual-phase** | Starts walking on the belt-aware route immediately, while a better route is computed in the background and swapped in only if it is *still* faster from wherever you have walked to by then. | Long trips across a belt-dense base. |

Dual-phase never delays your first step: the background search runs while you
are already moving, and a route that has stopped being an improvement by the
time it lands is discarded rather than applied.

Measured on a deterministic test arena (3 trials each, ticks to arrival — lower
is better, identical numbers mean the strategies chose the same route):

| Route | Naive | Belt-aware | Dual-phase |
| --- | --- | --- | --- |
| Open ground | 455 | 455 | 455 |
| Around a wall | 471 | 471 | 471 |
| Along a belt, with it | 652 | 652 | 652 |
| Along a belt, against it | 610 | **605** | 610 |
| Across the map | **1578** | 1589 | 1589 |
| Against a four-lane bus | never arrives | 2748 | **2500** |
| Bus goal, express lane available | 1196 | 620 | **619** |
| Crossing the bus perpendicular | 184 | 184 | 184 |

Most routes are identical across all three, which is the point: belt handling
should do nothing when there are no belts worth handling. Crossing a bus
perpendicular costs a few ticks and detouring around it would be slower, so
both belt strategies correctly leave it alone.

Dual-phase only re-routes when the remaining trip is genuinely belt-dominated.
Its background search understands belts but not walls, so on an ordinary
walking route it would be second-guessing the pathfinder with less information
— it declines rather than risk it.

For how this is implemented, see [`docs/routing.md`](docs/routing.md).

## Known Issues

*   **Flickering with Mech Armor**: When moving horizontally with mech armor, the character sprite may flicker.
*   ~~**GUI Command Confusion**: The mod's move command can sometimes be triggered when interacting with other GUIs, leading to unintentional movement~~.
*   **Uncontrolled Vehicle Movement**: Vehicles may occasionally move erratically. This is likely due to a narrow margin of error in the path following logic.
*   ~~**Basic Stuck Detection**: The current stuck detection is rudimentary and cannot navigate around obstacles that were not already avoided by the initial pathfinding.~~
*   **Vehicle Continues in Map View**: The vehicle does not automatically stop when the player opens the map view, which can lead to the vehicle driving off-course while the player is not watching.
*   **Spidertron Remote View**: Ordering selected spidertrons from remote view is not supported yet. Remote-view clicks still control the player character or current vehicle.
*   When removing an item from the hotbar (using MMB), the mod places a walk target. Disable Click2Move from the shortcut bar to avoid this conflict.
*   ~~The path may cross over pipes.~~
## Mod Settings

You can adjust these settings in `Settings -> Mod settings`.

| Setting Name                      | Type    | Scope             | Default | Description                                                                                             |
| --------------------------------- | ------- | ----------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| **Enable benchmark interface**    | `Bool`  | Startup            | `false` | Exposes the `click2move-debug` remote interface for automated testing. Leave disabled during normal play. |
| **Debug mode**                    | `Bool`  | Per-Player        | `false` | Enables printing of debug messages to the console for your player.                                      |
| **Debug categories**              | `Bool`  | Per-Player        | `true`  | Filter debug output for pathfinding, queue, stuck recovery, and vehicle control.                        |
| **Character margin**              | `Float` | Per-Player        | `0.45`  | The safety margin added to the character's bounding box for pathfinding. Larger values avoid tighter gaps. |
| **Update interval**               | `Int`   | Global            | `1`     | The number of game ticks between movement updates. Lower is smoother but uses more UPS.                 |
| **Character proximity threshold** | `Float` | Per-Player        | `1.5`   | How close (in tiles) the character must be to a waypoint to consider it "reached".                      |
| **Vehicle proximity threshold**   | `Float` | Per-Player        | `6.0`   | How close (in tiles) a vehicle must be to the final goal to consider it "reached".                      |
| **Stuck threshold**               | `Int`   | Per-Player        | `30`    | How many update intervals of no movement before the character/vehicle is considered stuck.              |
| **Vehicle path margin**           | `Float` | Per-Player        | `2.0`   | The safety margin added to the vehicle's bounding box for pathfinding.                                  |
| **Vehicle Prefer Straight Paths** | `Bool`  | Per-Player        | `false` | Asks Factorio's pathfinder to prefer straighter vehicle paths. Can be slower to compute.                |
| **Routing strategy**              | `Enum`  | Per-Player        | `belt-aware` | `naive`, `belt-aware`, or `dual-phase`. See [Routing strategies](#routing-strategies).              |
| **Ride belts going your way**     | `Bool`  | Per-Player        | `true`  | Allow small detours onto belts moving in your direction when they are faster. Off = avoid belts only.   |
| **Cancel on manual move**         | `Bool`  | Per-Player        | `true`  | Stop an auto-walk the moment you press a movement key, instead of fighting you for control.            |
| **Tight-gap margin**              | `Float` | Per-Player        | `0` (auto) | Bounding box margin used when a route fails and you are wedged among buildings. Auto-tightens with Squeak Through. |
| **Never give up on a route**      | `Bool`  | Per-Player        | `true`  | Retry failed routes with progressively looser constraints instead of refusing to move.                 |

> **Note**: Settings can be changed on the fly. The global update interval re-registers the movement scheduler when changed.

## Releasing

Releases are built and uploaded to the Factorio Mod Portal when a semantic
version tag such as `v0.2.0` is pushed. The tag version is written into
`info.json` in the release workspace, and the archive is built from tracked
files only.

## Installation

1.  Download the mod from the Factorio Mod Portal (link to be added).
2.  Place the downloaded `.zip` file into your Factorio `mods` directory.
    *   **Windows**: `C:\Users\<YourUsername>\AppData\Roaming\Factorio\mods`
    *   **Linux**: `~/.factorio/mods`
    *   **macOS**: `~/Library/Application Support/factorio/mods`
3.  Launch Factorio and enable the mod from the "Mods" menu if it's not already enabled.

---

*Author: Henrique*
