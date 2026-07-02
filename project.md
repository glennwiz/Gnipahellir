# Gnipahellir Project

A Norse-mythology-themed underground exploration and survival game written in **Odin** with **Raylib**. Two development branches exist in this repo, each with distinct strengths.

---

## Versions at a Glance

| Feature | Gnipahellir2 | Gnipahellir3 |
|---------|-------------|-------------|
| Grid size | 50×50 @ 16px | 192×108 @ 10px (1920×1080 fullscreen) |
| Terrain types | 17 | 25 |
| Enemy | Garm (hell hound) | Builder |
| Enemy AI style | Planning system, project phases | Dig-aware A*, 5-state machine |
| Crafting | 5 recipes | Planned (items present) |
| Audio | Full (64 slots, 16 channels, music) | None yet |
| Save / Load | Yes (binary serialization) | No |
| Multi-level | Yes (8 caves + 4 sky levels) | No (single cave) |
| Stats tracking | 20+ persistent metrics | No |
| UI | Full (inventory, crafting, settings, menus) | Minimal |
| Build system | `odin run src` | `odin run src` |
| Documentation | README, RULES, GARM_AI_BEHAVIOR, AUDIO_INTEGRATION | CLAUDE.md, plan.md, enemy_ai.md, ai_algo.md |

**Bottom line**: Gnipahellir2 is the more complete game. Gnipahellir3 has the superior enemy AI.

---

## Gnipahellir2

### Overview
Multi-level procedural mining/exploration roguelike with a full game loop: mine → craft → build → descend. Features save/load, persistent stats, audio, and a complete UI stack.

### World & Levels
- 50×50 tile grid per level
- Surface + 8 cave levels + 4 sky levels, each independently generated and saved
- 17 terrain types: Air, Void, Grass, Stone, Water, Lava, Magic Lava, Wood, Leaves, Crafting_Bench, Tree_Grower, Iron, Silver, Gold, Gold_Rare, Smelter, Cave_Entrance
- Lava spreads over time; Tree_Grower tiles grow trunks with a timer

### Player Systems
- Continuous physics: gravity, velocity, AABB collision
- WASD/Arrow movement, Space to jump
- 24-slot inventory with stacking and drag-drop
- Health + mana (mana regenerates over time)
- Mining via projectile wand (travels to target, impacts with delay)
- Wearable equipment equipped by double-click

### Crafting & Building
- 5 recipes at Crafting Bench: Bench, Tree Grower, Planks, Smelter, Iron Bucket
- Drag inventory items to world to place; placement validates terrain rules
- Tile-entity map enforces one entity per tile

### Audio
- 97 defined sound types, 64 sound slots, 16 simultaneous channels
- Master / SFX / Music volume sliders
- Event-driven: all audio triggered through the event queue
- Music streaming with fade-in/out and looping

### UI
- Inventory (B), Character (C), Build Menu (N), Crafting (bench proximity)
- Repositionable windows, hover tooltips, stats screen
- Main menu, settings, save/quit dialogs
- Sound debug window for testing

### Persistence
- Binary save: full world state, player position/inventory, Garm state
- 20+ persistent stats: blocks destroyed, ores collected, deaths, depth reached, distance traveled, crafting attempts, etc.

### Garm Enemy AI
Garm is a hell-hound boss with a **planning + project** architecture.

**States**: Idle → Wandering → Distracted → Chasing → Charging

**Planning system**:
- Builds a 20-step action buffer (MoveTo / Mine / Place / Jump)
- Locks the first 15 steps before replanning, ensuring committed execution
- Stuck detection triggers automatic mining/placing to escape

**Project phases** (world modification goals):
1. **Center_Column** — places stone in a vertical line, keeps void above
2. **Perimeter** — builds a ring structure at set radius
3. **Filling_Lava** — mines interior solids then floods with lava

**Combat**: Throws fireballs when chasing; uses jump heuristics to clear obstacles.

**Debug overlay** (`garm_scan.md`): color-coded tile check visualization (yellow=move, red=mine, green=place, sky-blue=support, magenta=headroom, orange=gap).

### Particles
128-max particle system: sparks (mining), lava bubbles, magic sparkles, death explosions (50 particles).

---

## Gnipahellir3

### Overview
Fullscreen 1920×1080 grid-based underground survival game. Single cave level with a highly sophisticated Builder enemy that autonomously mines ore, constructs a fortified den, and hunts the player. The architecture is cleaner than G2 and built for future expansion.

### World
- 192×108 tile grid at 10px = exact 1920×1080 fullscreen
- 25 terrain types, including ores (Iron, Silver, Gold), hazards (Lava, Magic Lava, Void_Sky), workstations (Crafting_Bench, Smelter, Sky_Altar), and portals
- Cave generation via cellular automata (5 smoothing passes) + stalactites/stalagmites + depth-scaled ore veins
- Surface: seeded-hash procedural trees and flowers
- Deterministic world via `whash()` 32-bit seed

### Player
- Stats: 10 HP, 100 mana (regenerates 5/sec)
- Speed 8 tiles/s, jump -13 tiles/s, gravity 28 tiles/s²
- Left-click to mine (consumes mana via Mine_Wand)
- 24-slot inventory

### Progression
- 3 tiers: Cave → find Blueprint → build sky structure → unlock deeper cave
- Dual-axis: descend into caves AND ascend to sky
- Sky rituals (material-consuming) gate cave unlocks
- Final boss in the deepest cave

### Builder Enemy AI (the standout feature)

Two builders spawn per level (left and right cave positions, 6 HP each). They run a **five-state machine** backed by **dig-aware A* pathfinding**.

#### States (`Builder_Goal` enum)

| State | Behavior |
|-------|---------|
| **Build_Den** | Finds cave floor with ≥4 tile vertical clearance, spaced ≥20 tiles from other builders; carves 3×3 interior, builds wood walls and 2-high door |
| **Fetch_Mineral** | Scans for nearest ore (Iron/Silver/Gold preferred, stone fallback), excludes den-protected zones, uses 4-slot ring buffer of abandoned targets to prevent ping-pong |
| **Encase_Den** | Returns home, fits carried block into next open shell slot (patches first, then 3 shell rings outward); door corridor always kept open |
| **Hunt** | Activates when player enters 12-tile radius with line-of-sight; replans A* when player drifts >2 tiles; bites at Chebyshev ≤1 for 1 HP every 0.8s; gives up beyond 20 tiles or after 3s without LoS |
| **Cooldown** | 1–2s pause between objectives |

#### Dig-Aware A* (`astar_dig`)

| Action | Cost | Condition |
|--------|------|-----------|
| Walk / step up / drop / jump | 1 | Normal platformer movement |
| Bridge gap (conjure block underfoot) | 4 | Target & floor open |
| Tunnel through wall | 6 | Mineable, solid below, not den-protected |
| Dig through floor | 6 | Mineable, solid two below |
| Diagonal mine | 7 | Mineable, head clearance |

- Fixed 4,096-node budget; Euclidean heuristic; lazy-delete open list
- **Best-effort fallback**: on budget exhaustion, paths toward closest expanded node — always makes progress
- Jump arc checks intermediate columns to prevent jumping into overhangs
- Max 64 waypoints; trims to start-side prefix if longer

#### Path Execution
- `builder_exec_action`: mines/places waypoint tiles at max 1 action per 0.4s
- Loose deadzone (0.15) for normal waypoints; tight (0.03) above drops
- Final waypoint requires precise landing (0.35 radius) to prevent replan livelock
- Physics snaps flush to tile boundaries on collision to prevent epsilon-wedging

#### Never-Stuck Machinery
- **Progress watchdog** tracks waypoint completions, mines, and placements — not raw position
- **3-strike rule**: no progress for 3s = one strike; on 3rd strike, per-goal recovery:
  - Den building → abandon site, cooldown
  - Mineral fetching → blacklist target, cooldown
  - Encasing → drop block, return to fetching
  - Hunting → give up, return to work
- `builder_dig_free()` mines through overlapping solids on first strike

#### Den Protection (`den_protected`)
- Only placed materials (wood, carried minerals) protected — never natural rock
- Only tiles matching den template or shell ring geometry
- Ore veins outside the dome remain harvestable
- Prevents A* from pathfinding through den walls

#### Debug Logging
Actions logged to `enemy_action.log` (ring buffer, 256 KB, flushed every 300 frames):
```
[f0000001] Builder#0 starts den at (11,90)
[f0000255] Builder mines (15,89)
[f0000289] Builder places at (182,93)
```

---

## Shared Architecture

Both versions follow the same core patterns:

- **Fat struct**: all mutable state in one `Game_State`; no module-level globals
- **Event-driven**: ring-buffer event queue; systems communicate only through events
- **Fixed-size buffers**: no heap allocation during gameplay
- **Render read-only**: draw procs never mutate state
- **Table-driven behaviors**: terrain/item properties in static lookup tables
- **One entity per tile**: enforced via `entity_map`
- **Deterministic update order**: input → player → enemies → projectiles → sim → events → particles → audio

---

## Key Differences Summary

**Gnipahellir2 is further gamified** — it has the full game loop, crafting, audio, save/load, UI, multi-level world, and persistent stats. It is the closer-to-shippable version.

**Gnipahellir3 has better enemy AI** — the Builder's dig-aware A* pathfinding, den construction lifecycle, mineral harvesting loop, never-stuck machinery, and LOS-based hunting are significantly more sophisticated than Garm's planning system. The architecture is also cleaner and more explicitly documented.

A merged version combining G3's Builder AI and G2's game systems would make the strongest game.

---

## Build Instructions

Both versions use the same build command from their respective directory:

```
odin run src
```

or to produce an executable:

```
odin build src -out:game.exe
```

Requires Odin compiler with Raylib vendor bindings available.
