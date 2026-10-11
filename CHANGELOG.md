# Changelog

## 0.1.14 — 2026-10-11

- Consume multiple already-passed waypoints on straight path sections using observed character or vehicle motion, including exoskeleton movement and Hovercraft drift.
- Retain normal turn handling and explicit final destination checks while bounding waypoint work per update and preserving pending motion evidence across save/load.
- Check ground-path character arrival every tick near the destination to prevent overshooting at larger update intervals.
- Check flying character arrival every tick near the destination, including powered mech armor at larger update intervals.
- Cancel stale routes and pending requests when the movement entity changes physical surface.
- Ignore car passenger commands and clear routes on driver handoff without overwriting the new driver's input.
- Choose the correct diagonal walking direction when horizontal and vertical distances are equal.

## 0.1.13 — 2026-10-01

- Keep braking vehicles at destinations until native speed and scripted drift settle before advancing the queue.
- Handle Hovercrafts 2.1.4 New-mode reverse thrust at rest and braking impulses that cross zero.
- Approach farther inside the destination radius after braking stops short or overshoots, preventing repeated stops at its edge.
- Account for harmless quantized Hovercraft New-mode drift jitter when deciding a vehicle has settled.
- Allow manual vehicle takeover in normal view while remote-view panning preserves the route.
- Preserve active routes, pending path requests, and destination markers across save/load and configuration changes.
- Clear the whole character queue on manual takeover, while remote-view panning preserves movement.
- Preserve queued destinations through flight transitions and recompute ground paths after landing.
- Measure stuck detection and recovery in game ticks and correct perpendicular slides for Factorio's direction enum.
- Recompute affected queue legs after a path failure and stop movement when a disconnected player's path callback arrives.
- Limit path prefetching, reuse persistent path rendering, and cache player settings with proper invalidation.
- Check Lua syntax, regression tests, and runtime package contents before publishing.
- Build releases from an explicit runtime allowlist and retain curated native Factorio release notes.
- Prevent API keys and upload URLs from being exposed by publish-workflow tracing or response logging.

## Earlier changes

- chore: Mark the mod compatible with Factorio 2.1 and base 2.1
- fix: Ignore move commands fired from GUI elements so middle-click UI interactions do not create walk targets
- feat: Refactor mod archive creation to use versioned directory structure
- feat: Improve API key validation in publish workflow
- feat: Add GitHub Actions workflow for mod publishing and update info.json with contact and homepage
- feat: Add README
- feat: Add thumbnail image for improved project visibility
- feat: Add vehicle path margin setting and enhance vehicle stuck detection logic
- feat: Refactor movement logic and enhance GUI interactions for character pathfinding
- feat: Improve path rendering and entity handling
- feat: Enhance character movement logic with improved stuck detection and pathfinding; refactor rendering and event handling
- feat: Add stuck detection and repathing logic for character movement; update settings and descriptions
- feat: Refactor movement settings to use global settings and improve debug functionality
- feat: Add configuration settings for debug mode and movement thresholds
- feat: Update character movement handling to use character position and improve walking state management
- feat: Add 8-way movement direction detection and improve vehicle state handling
- feat: Enhance movement handling by adding crosshair rendering and improving vehicle state management
- feat: Improve character movement handling by immediately stopping movement on manual direction change
- feat: Enhance movement handling with manual direction detection and path request improvements
- feat: Update input handling and add new custom input command
- feat: Improve movement handling and pathfinding logic
- feat: Refactor movement logic and improve pathfinding handling
- feat: Initial implementation of click-to-move
