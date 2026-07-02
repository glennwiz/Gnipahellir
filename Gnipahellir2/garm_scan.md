# Garm Scan & Debug Overlay

This document explains how the Garm AI scans the world and how the on-screen debug overlay colors map to different checks/targets.

## What the overlay shows

- A colored line from Garm’s center to a target tile.
- A colored outline around that target tile.
- The color indicates the purpose of the check/target (see legend below).
- Rays fade out over time (each has a small lifetime that decrements each frame; alpha increases with lifetime, then the ray disappears).

Implementation reference: `src/render.odin` draws `game.garm.debug_rays` every frame. Rays are added via `enemy_debug_ray_add` within `src/enemy.odin`.

## Color legend (what each color means)

- Yellow (rl.YELLOW)
  - “MoveTo” plan target tile. Used when the planner sets a navigation target.
  - Even with movement disabled (current reset), these are still emitted so you can see plan intentions.

- Red (rl.RED)
  - Mining target tile for a plan “Mine” step.
  - Obstacle probe while chasing (e.g., wall-in-front checks before considering a jump).

- Green (rl.GREEN)
  - Placement target tile for a plan “Place” step (Stone/Lava/Air/Void depending on the plan).
  - Note: The reserved void channel above the center stone column is respected by logic; the color does not change for reserved tiles, but you’ll see log messages for “skip reserved”.

- Sky Blue (rl.SKYBLUE)
  - Support/step placement checks during stuck assistance or when attempting to climb (e.g., place a step ahead or fill a pit one tile below).

- Magenta (rl.MAGENTA)
  - Headroom clearance checks when stuck (tiles above Garm that may be mined to free space).

- Orange (rl.ORANGE)
  - Gap detection checks during chase (e.g., testing if the next step is a hole so it would consider a jump).

## Where scans happen (high level)

The planner generates steps in phases (see `enemy_generate_build_plan` in `src/enemy.odin`). During execution, rays mark the current step/check.

- Center_Column phase
  - Works around the Garm’s current Y near the center X:
    - If (center X, y) is empty: plan Place Stone (Green).
    - For tiles one and two above each stone (y-1, y-2): ensure empty by Mine/Place Air/Void (Red/Green as appropriate).
- Perimeter phase
  - Samples a ring around the project center at a fixed radius and plans Place Stone at empty perimeter tiles (Green), with MoveTo markers (Yellow).
- Filling_Lava phase
  - Scans rings from outer to inner inside the perimeter, skipping the reserved void channel and existing lava, planning Mine then Place Lava as needed (Red/Green), with MoveTo markers (Yellow).

Other non-plan probes that emit rays:
- Stuck assistance: headroom checks (Magenta) and step/pit support checks (Sky Blue).
- Chase heuristics: wall probe (Red) and gap probe (Orange).

## Ray lifetime and fading

- Typical lifetimes used:
  - MoveTo (Yellow): ~14 frames
  - Mine (Red): ~16 frames
  - Place (Green): ~16 frames
  - Stuck/Support (Sky Blue, Magenta): ~18 frames
  - Gap probe (Orange): ~14 frames
- Rendering applies a fade based on remaining life; tile outlines are drawn in the same color.

## Logs that pair with scans

- Text logs (`garm_log`) include entries like:
  - SCAN … lines for terrain inspection during planning.
  - STEP MoveTo/Mine/Place … lines when executing/advancing plan steps.
  - PLAN … lines when generating or advancing plans.
- These logs complement the overlay and appear in the in-memory buffer (and any log output the game writes).

## Note about the current reset

- As part of resetting Garm movement, plan steps are currently marked complete immediately, but the corresponding debug rays (colors above) are still emitted so you can see what the planner and probes are targeting. This preserves a rich debug foundation while movement logic is rebuilt.
