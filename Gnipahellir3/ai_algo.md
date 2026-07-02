# Builder AI — Implemented Algorithm

How the Builder enemy works. All code lives in `src/enemy.odin`, with state types
in `src/game_state.odin`. Supersedes the suggestions in `enemy_ai.md`.

The design goal: **never stuck, always an objective, always something to build.**

---

## Overview

Each builder lives one loop: build a den, then endlessly harvest minerals and
encase the den in them — unless it sees the player, in which case it hunts.

```
┌───────────┐  den done   ┌───────────────┐  ore mined  ┌────────────┐
│ Build_Den ├────────────►│ Fetch_Mineral │────────────►│ Encase_Den │
└───────────┘             └──────┬────────┘             └──────┬─────┘
                                 ▲                             │ block placed
                                 └─────────────────────────────┘
                                 ▲ player escapes / dies
                          ┌──────┴─────┐
                          │    Hunt    │◄── player within 12 tiles + line of sight
                          └────────────┘    (while fetching or encasing)
```

States (`Builder_Goal` in `game_state.odin`): `Build_Den` → `Fetch_Mineral` ⇄
`Encase_Den`, `Hunt` interrupting the work states, and `Cooldown` (short pause,
then `resume` goal). All per-builder state sits in `Enemy.builder`
(`Builder_State`) inside the `Game_State` fat struct — no globals, fixed sizes.

## 1. Build_Den

- Site selection: up to 8 hash-seeded attempts, preferring floor tiles near the
  builder (`find_cave_floor`, ≥4 tiles vertical clearance, template must fit the
  cave shell, ≥`SITE_SPACING` (20) from other builders' dens).
- The den is the shelter template: carved interior, wood walls and roof, and a
  **2-high door** (a 1-high door with a ledge outside proved to be a jump trap).
- Steps are worked through `builder_travel` + `builder_do_step` (carve wrong
  solids, place the desired tile), verified against the world each frame — so
  construction survives interference and resumes after interruptions.
- The anchor persists for the builder's lifetime; the den is home.

## 2. Fetch_Mineral

- `builder_find_mineral` scans the cave for the nearest ore (`Iron_Ore`,
  `Silver_Ore`, `Gold_Ore`, `Gold_Rare_Ore`; plain stone as a fallback if the
  cave runs dry), excluding:
  - anything within dome-extent + reach (8 tiles chebyshev) of ANY den — both
    to protect shells and because closer targets sit in pockets whose approach
    the den protection forbids digging through;
  - a 4-slot ring buffer of recently given-up targets (prevents A↔B ping-pong).
- Travels within `BUILDER_REACH` (3) — tunneling through rock if that's the
  cheapest route — then mines the block and carries it (`Builder_State.carry`).

## 3. Encase_Den

- The builder carries the block **home** (travel to the den anchor, stop 2 —
  always reachable through its own door), then fits it into the next open slot
  from there. Per-slot approach across the dome was a reachability minefield.
- Slot order (`den_next_build_tile`): damaged den tiles first (patched with
  whatever is carried), then shell rings closest-first — perimeter boxes 1..3
  tiles around the den, keeping the 2-high door corridor open through every
  layer. Naturally-solid slots count as already encased.
- Fully encased + intact → short cooldown, re-check (i.e. it repairs anything
  the player mines out of the dome).

### Den protection

`den_protected` forbids the pathfinder and path executor from **mining** den
material — otherwise builders tunnel through their own walls en route to ore
and then loop forever repairing them. Two hard-learned constraints:

- Only **placed materials** (wood, minerals) are protected, never natural rock,
  even inside the den footprint — otherwise a builder returning from below is
  walled out of its own home.
- Only tiles matching the den template or shell ring shape are checked, so
  natural ore veins just outside the dome stay harvestable.

## 4. Hunt

- **Detection** (checked while fetching/encasing; den construction stays
  focused): player within `HUNT_RADIUS` (12) AND line of sight — the sight line
  is sampled every half tile, any solid tile blocks it. Walls hide the player.
- **Chase**: dig-aware A* to the player's tile (stop 1), replanned when the
  player drifts >2 tiles off the planned intercept. Builders will tunnel
  toward you.
- **Attack**: adjacent (chebyshev ≤1) → `Damage_Dealt` event every
  `ATTACK_TIME` (0.8s) for `ATTACK_DAMAGE` (1). The event system applies it:
  hp → 0 chains `Entity_Died` → `Player_Died` → permadeath flag.
- **Give up**: beyond `HUNT_LOSE_DIST` (20), or `LOS_MEMORY` (3s) without
  sight, or 3 pathing strikes → back to `Fetch_Mineral`/`Encase_Den`
  (whichever matches whether it's carrying). Verified end-to-end in a soak:
  spot → chase → 10 bites → kill → "prey eliminated — back to work".

## 5. Dig-aware A* (`astar_dig`)

Cost-based platformer pathfinding over grid tiles; world modifications are
edges with costs:

| Move | Cost | Condition |
|---|---|---|
| Walk / step up / drop / jump | 1 | normal platformer checks |
| Bridge a gap (place block underfoot) | 4 | target and floor tile both open |
| Tunnel into a wall | 6 | mineable, solid below, not den-protected |
| Dig through the floor | 6 | mineable, solid two below, not den-protected |
| Mine a diagonal step up | 7 | mineable, head clearance, not den-protected |

Mechanics: per-cell `g_cost`, closed set, lazy-deletion open list, euclidean
heuristic, `MAX_ASTAR_NODES = 4096` budget — all fixed-size stack arrays.
Succeeds within chebyshev `stop_within` of the goal. **Best-effort fallback**:
on budget exhaustion it paths to the expanded node closest to the goal, so the
builder progresses and replans. Reconstruction keeps the start-side prefix if
the path exceeds `MAX_NAV_PATH` (64).

Jump feasibility: landings require head clearance (`!is_solid(nx, y-2)` — a
1-high notch is standable but un-jumpable-into), and forward jumps check arc
clearance through every intermediate column (no jumping into overhangs).

## 6. Path execution & physics

- `builder_exec_action` mines solid waypoints / bridges floorless ones
  (rate-limited by `MINE_TIME` 0.4s); `enemy_follow_path` steers and jumps.
  The waypoint deadzone shrinks (0.15 → 0.03) when the waypoint is below, so
  the body centers over drops instead of toenail-hanging on ledges. The FINAL
  waypoint must be stood on precisely (0.35 radius) — arrival checks are
  tile-based and the loose radius caused replan livelocks.
- `enemy_physics` snaps flush to tile boundaries on collision; epsilon overlaps
  used to wedge bodies inside solid corners permanently.

## 7. Never-stuck machinery

- **Progress watchdog**: no waypoint/mine/place progress for `STUCK_TIME` (3s)
  = strike (raw movement doesn't count — jump-bouncing must register as stuck).
- **3 strikes** on one objective (`builder_strike`): dig-free rescue if the
  body is embedded, then per-goal recovery — abandon den site / blacklist the
  ore target / drop the carried block / give up the hunt. There is always a
  next objective.
- Baseline soak (150s, 2 builders): 2 dens built, continuous harvest/encase,
  **0 strikes, 0 give-ups**.

## Constants (top of `enemy.odin`)

```
BUILDER_REACH   = 3 (chebyshev)     MINE_TIME    = 0.4s
BUILDER_JUMP    = -10 (apex ~2.5)   REPLAN_MIN   = 0.5s
MAX_ASTAR_NODES = 4096              STUCK_TIME   = 3s
MAX_NAV_PATH    = 64 (types.odin)   MAX_STRIKES  = 3
SITE_SPACING    = 20                JOB_COOLDOWN = 2s
COST_WALK/PLACE/MINE = 1 / 4 / 6
HUNT_RADIUS = 12    HUNT_LOSE_DIST = 20    LOS_MEMORY = 3s
ATTACK_TIME = 0.8s  ATTACK_DAMAGE  = 1     DEN_SHELL_LAYERS = 3
```

## Known quirks / future work

- Builders conjure nothing anymore for the shell (they genuinely ferry mined
  blocks), but bridge blocks while pathing are still conjured stone.
- Ore round trips are leisurely (~40-60s per block): dig to vein, mine, dig
  home. Tune `MINE_TIME` / `BUILDER_SPEED` for busier-looking builders.
- The "player escapes → back to work" transition is code-verified but only the
  kill path is soak-verified (an idle test player can't flee) — worth one
  manual playtest.
- The planner assumes a static world per plan; `builder_exec_action` recovers
  at execution time.
- Cairn/pillar templates remain in the table but are currently unused (dens
  only). Garm, Undead and Fire_Sprite still need behavior — same
  `update_<kind>` pattern.
