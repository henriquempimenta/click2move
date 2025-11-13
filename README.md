# Click2Move for Factorio

A quality-of-life mod that enables point-and-click movement for your character and vehicles. Inspired by ARPG and RTS games, simply click where you want to go, and the pathfinder will take you there.

## Features

*   **Point-and-Click Movement**: Use a mouse click to set a destination for your character or the vehicle you are driving.
*   **Path Queuing**: Hold **Shift** while clicking to queue up multiple destinations.
*   **Vehicle Support**: Works seamlessly whether you are on foot or in a vehicle.
*   **Visual Path**: See the calculated path drawn on the ground, so you know exactly where you're headed.
*   **Destination Marker**: A crosshair marks your final destination.
*   **Movement GUI**: A small panel appears in the top-left showing your current destination and the number of queued goals. It also includes a "Cancel" button to immediately stop all automatic movement.
*   **Stuck Detection**: If your character or vehicle gets stuck, the mod will automatically attempt to find a new path to your destination.
*   **Configurable**: Customize the mod's behavior through a variety of settings in the "Mod settings" menu.

## How to Use

*   **Move**: Press **Mouse Button 3** (the middle mouse button by default) on the terrain to move to that location.
*   **Queue Moves**: Hold **Shift** and press **Mouse Button 3** to add a destination to your movement queue.
*   **Cancel Movement**:
    *   Click the "Cancel" button in the top-left GUI.
    *   Move your character manually with the keyboard (WASD).
    *   Set a new destination without holding Shift (this will clear the old queue).

The default keybind can be changed in Factorio's control settings. Look for "**c2m-move-command**".

## Known Issues

*   **Flickering with Mech Armor**: When moving horizontally with mech armor, the character sprite may flicker.
*   ~~**GUI Command Confusion**: The mod's move command can sometimes be triggered when interacting with other GUIs, leading to unintentional movement~~.
*   **Uncontrolled Vehicle Movement**: Vehicles may occasionally move erratically. This is likely due to a narrow margin of error in the path following logic.
*   **Basic Stuck Detection**: The current stuck detection is rudimentary and cannot navigate around obstacles that were not already avoided by the initial pathfinding.
*   **Vehicle Continues in Map View**: The vehicle does not automatically stop when the player opens the map view, which can lead to the vehicle driving off-course while the player is not watching.

## Mod Settings

You can adjust these settings in `Settings -> Mod settings`.

| Setting Name                      | Type    | Scope             | Default | Description                                                                                             |
| --------------------------------- | ------- | ----------------- | ------- | ------------------------------------------------------------------------------------------------------- |
| **Debug mode**                    | `Bool`  | Per-Player        | `false` | Enables printing of debug messages to the console for your player.                                      |
| **Character margin**              | `Float` | Global            | `0.45`  | The safety margin added to the character's bounding box for pathfinding. Larger values avoid tighter gaps. |
| **Update interval**               | `Int`   | Startup           | `1`     | The number of game ticks between movement updates. Lower is smoother but uses more UPS.                 |
| **Character proximity threshold** | `Float` | Startup           | `1.5`   | How close (in tiles) the character must be to a waypoint to consider it "reached".                      |
| **Vehicle proximity threshold**   | `Float` | Startup           | `6.0`   | How close (in tiles) a vehicle must be to the final goal to consider it "reached".                      |
| **Stuck threshold**               | `Int`   | Startup           | `30`    | How many update intervals of no movement before the character/vehicle is considered stuck.              |
| **Vehicle path margin**           | `Float` | Startup           | `1.0`   | The safety margin added to the vehicle's bounding box for pathfinding.                                  |

> **Note**: `Startup` settings require a game restart to take effect. `Global` and `Per-Player` settings can be changed on the fly.

## Installation

1.  Download the mod from the Factorio Mod Portal (link to be added).
2.  Place the downloaded `.zip` file into your Factorio `mods` directory.
    *   **Windows**: `C:\Users\<YourUsername>\AppData\Roaming\Factorio\mods`
    *   **Linux**: `~/.factorio/mods`
    *   **macOS**: `~/Library/Application Support/factorio/mods`
3.  Launch Factorio and enable the mod from the "Mods" menu if it's not already enabled.

---

*Author: Me*
