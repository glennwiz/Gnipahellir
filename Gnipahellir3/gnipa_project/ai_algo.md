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

---

# Hero AI — the agent-driven hero's senses and behaviours

How the hero acts while an outside agent drives it (card 149, after the goal
queue of card 137). Code: the second half of `src/agent_exec.odin`; state:
`gs.hero` (`Hero_Brain`), transient, zeroed by a New Game.

The design goal (Glenn 2026-11-03): **the playerbot notices the enemies around
it and the voids it could fall too far into, and acts like a person between
and during goals.** Goals say what to do; this layer is the hero's own sense
of danger.

## Where it sits

```
agent goals ──► goal queue ──► hero_think ──► gs.agent.cmd ──► agent_input
                                  │  sense → score → pick → run → tell
                                  ▼
                               gs.hero (senses, current behaviour, notes)
```

`update_agent_goals` (game_update step 0) takes the running goal, then on the
play screen hands it to `hero_think`. On every other screen (title, menus,
death, book, win) the goal plays straight through, so dismiss and tithe acts
work as before. The brain writes `gs.agent.cmd`, the seam a goal writes, and
never touches world state.

## Senses (`Hero_Senses`, rebuilt every tick)

- **Threats**: every enemy inside the watcher's framing (`AGENT_VIEW_W` x
  `AGENT_VIEW_H` round the hero: what a player sees on screen, no more),
  nearest first, at most `HERO_THREATS_MAX`. Each has kind, distance, signed
  dx, closing (it moved toward the hero, or came nearer by its own move,
  within `HERO_CLOSING_MEMORY_S`: a Vargr hunts in stops and starts, and a
  pause is not a retreat; the hero walking at one standing still is not it
  coming, card 164, playtest 136's beetle in a pit), in_line (a clear
  `sight_line_clear` between the two), the damage of one blow
  (`hero_threat_damage`, a roamer's from `roamer_table`, a Draugr's a quarter
  of max hp) and how long it has been in sight. The risen hero holding its
  post (`risen_hero_guarding`: the player more than `RISEN_GUARD_RANGE` from
  its stone) is marked `guarding`: it comes for no one outside its ring, so
  it holds no goal and makes no one wary, and an unarmed hero walks past it
  as a player runs past (card 169, playtest 133). It still counts as in
  sight, so a goal into its ring, driven off each time the guard hunts, fails
  `hunted` after `HERO_HUNTED_PAUSES` with the hero alive. Inside the ring it
  hunts and is a threat like any other.
- **Danger map**: `2*HERO_SENSE_REACH+1` columns round the hero, each judged
  as a step from the feet row (`hero_column`): a wall, the drop below, the hp
  the fall rule in `update_player` takes for it (`SAFE_FALL_TILES`,
  `FALL_TILES_PER_HP`; water breaks the fall; in the sky a fall whose body
  passes `SKY_FALL_Y` before it lands is none, as the fall through the clouds
  lands on the surface unhurt, card 164), a burn (a `.Damaging` tile at
  the step or the landing), and a loose block (a faller) hanging over the head.
- **Safe ground**: a ring of the last `HERO_SAFE_MAX` tiles the hero stood on,
  grounded, not burning, no damaging enemy nearer than `HERO_SAFE_CLEAR`,
  spaced `HERO_SAFE_SPACING` apart.

A threat is *noticed* (`hero_threat`) once it has been in sight
`HERO_REACTION_S`, does damage, and is in line, within sword reach, or hunting
(`Hunt` or `Wave_Hunt`) and coming at the hero within `HERO_THREAT_NEAR`
(card 158: a Builder digging up at the hero through the rock is answered, as a
player sees it coming; one fetching ore that passes under the hero's shaft is
not, seed 999). Any other enemy
behind rock is seen, not answered. Once noticed it stays in mind while it is
within `HERO_THREAT_FAR` + `HERO_CLEAR_MARGIN`, line or no line: a bump that
cuts the sight line for a step does not make the wolf go away.

## Behaviours (utility AI, `hero_behaviours`)

One row per behaviour, a score proc and a run proc:

| Behaviour | Score | Run |
|---|---|---|
| goal | `HERO_GOAL_SCORE` (50) with a goal running; 0 while a closing threat within `HERO_THREAT_FAR` hunts a hero that cannot fight it (card 155: no work goal starts or goes on in a hunter's reach; flee takes over until it is gone); also for an armed hero under `HERO_LOW_HP_FRAC` while it digs (card 156: a dig pins it where it stands) | one tick of the goal |
| fight | press x (30 + 60 x hp fraction), armed only (a sword, or a fire wand with mana); 0 while a fight goal runs | `hero_strike`: the sword in reach, else the wand within `HERO_WAND_RANGE` along a clear line from the body's centre (where the orb leaves) to the enemy's; the weapon taken up first; a sword swing every `HERO_SWING_S`. With the wand, a threat nearer than `HERO_KITE_TILES` is backed off from as it is shot. No blow from here: walk at it |
| flee | press x (30 + 60 x (1 - hp fraction)), +`HERO_UNARMED_FLEE` (40) unarmed | to the safe spot farthest from the threat at least `HERO_SAFE_CLEAR` from it, never one back past the threat, else straight away; a gap the jump arc clears (up to `HERO_GAP_MAX`, head room over take-off, gap and landing) it jumps as a player does, held until its feet are down (card 155); cornered at a drop it will not walk, it takes the drop only if the fall costs less hp than `HERO_PASS_BLOWS` of the threat's blows plus the hp this flight has already cost (card 155: blows taken since no threat was in mind) (every threat is slower than the hero, so running back past it costs that much at most) and no burn waits below, else runs past the threat and keeps going until it is behind. A way that makes no headway for `HERO_BREAK_STUCK_S` with the threat on it (within `HERO_MAULED_TILES` across) is shut: an unarmed hero with a pick first digs through the wall ahead, head or feet tile, any the pick takes (no structure), the pick taken in hand first (card 155); else it turns back, and at a drop with the threat on it takes a fall that leaves it standing even after one more blow, burns excepted, rather than be mauled; with the threat still off it keeps at the way it is going; the shut mark clears when it gets clear. Drops both ways (card 156): a flight that turned back from a drop, or from a way found shut with the threat on it (dearer than any fall), takes the drop on the other side if it hurts no more, else turns once more and takes the first, each only if the hero stands after one more blow; no running back and forth past the threat. The turn is forgotten when it gets clear or no threat is in mind. The gap jump only leaves the ground: in the air it carried the hero over drops it could not clear. With only the wand it shoots as it runs; 0 while a fight goal runs |
| ledge | `HERO_LEDGE_SCORE` (100) when the goal walks the hero into a step that hurts or burns, or into a drop of `HERO_LEDGE_LOOK_TILES`+ not yet looked at | stand and look `HERO_LEDGE_LOOK_S`; then step if the fall is free, else fail the goal ("a 10-tile drop ahead", "a burn ahead") |
| idle | `HERO_IDLE_SCORE` (10) with the queue empty | stand; with a threat noticed, make for safe ground as flee does, cornered included; on a burn, back to the last safe spot |
| retreat | `HERO_RETREAT_SCORE` (70) when the hero is spent (under `HERO_LOW_HP_FRAC` with no heal in the bag), no threat is noticed, the queue is empty or a work goal runs (never a go, home or fight: the client's own walk), the retreat has not given up, and the hero stands where the way out costs more than `HERO_WARY_EXIT_HP`, with a remembered safe spot whose way out does not (card 157) | a go walk the brain runs itself (`gs.hero.retreat`) toward the latest such safe spot, digging with the pick as a go does; the spot holds while its own way out stays cheap (the walk's own spots may push it out of the ring), and if it closes on the way the next spot that has one is picked, and with none left the retreat gives up; the way out is judged from the ground only, so a jump on the way never ends it; it ends when the hero stands anywhere the way out is cheap; a walk that fails gives up (`retreat_off`) until the hero stands on cheap ground again |

*Press* is how much the nearest noticed threat matters: 1 within
`HERO_THREAT_NEAR`, falling to 0 at `HERO_THREAT_FAR`, halved for one out there
that is not closing. Health decides between fight and flee: a full-health hero
with a sword fights a Vargr, the same hero at a fifth of its health runs. Once
fleeing, the hero keeps running until the threat is past `HERO_THREAT_FAR` or
gone, so it never turns back toward a hunter at the threshold. A goal paused for flight
more than `HERO_HUNTED_PAUSES` times by a hunting threat (`Hunt` or
`Wave_Hunt`) still in sight fails "hunted: a Vargr keeps coming" (card 158:
playtest 129's go flapped between goal and flight 884 times); one on an
errand of its own is fled from but never counted, and the count clears when
nothing is in sight. A goal paused by any behaviour more than
`HERO_PAUSE_MAX_S` at a stretch fails "held: paused by flee for 60 s" (card
164: playtest 136's hero, boxed in by trunks and a pond, held every goal on
flight for 104k frames).
Flight and idle dig out (cornered with a pick) never through the player's
placed blocks, and never a tile whose loss would drop the hero far
(`hero_dig_safe`; card 158: playtest 127's hero dug out its own shelter and
fell 36 tiles).

Every movement a behaviour makes goes through `hero_walk`: never into a step
that hurts or burns (flight and leaf fall excepted), a jump at a wall two high,
and a still tick to sweep open windows shut first, the window rule a goal keeps.

## Picking (`hero_pick`, pure)

The best score wins, held back by hysteresis:

- the running behaviour keeps the tick unless a rival beats it by
  `HERO_SWITCH_MARGIN` after it has run `HERO_MIN_HOLD_S`;
- a score of `HERO_URGENT_SCORE` or more takes over at once (the ledge);
- a running behaviour that scores 0 lets go at once. A score is 0 only when
  its cause is gone (the goal ended, the threat died, left the screen or went
  past `HERO_THREAT_FAR`, the look at a ledge ended): every sense a score reads
  remembers (noticed, closing, a look begun runs to its end), so no one tick's
  read zeroes it.

## Goals paused, not lost

The running goal is the goal row. When another row wins, the goal stays
running with its frames unspent; when the goal row wins again it carries on
from where it was. A connected client hears (after its first `goals`):

- `goal_paused` `{id, reason}` — reason fight, flee, ledge or retreat;
  when the hero dies every running or queued goal but an act fails `died`,
  once (the next life may be a new world; an act stays, to work the death
  screen; failed on the death event itself, so goals queued on the death
  screen run in the next life, whatever opens over it or reconnects);
- `goal_resumed` `{id, reason}` — the reason that paused it;
- `idle` `{threats}` — once each time the queue runs dry, with the number of
  enemies in sight then that can hurt the hero.

These sit in the goal queue's `notes` (a ring of `HERO_NOTES_MAX` with a
running count, kept with the queue so a New Game loses none);
`agent_after_tick` pushes each once, before the goal ends it settles, so a
resume reads before its goal_done.

## Pacing (named constants, first guesses: Glenn's to tune)

```
HERO_REACTION_S   = 0.3 s   HERO_LEDGE_LOOK_S  = 0.4 s   HERO_LEDGE_LOOK_TILES = 3
HERO_MIN_HOLD_S   = 0.5 s   HERO_SWITCH_MARGIN = 10      HERO_URGENT_SCORE     = 95
HERO_SWING_S      = 0.45 s  HERO_THREAT_NEAR   = 5       HERO_THREAT_FAR       = 12
HERO_SAFE_CLEAR   = 8       HERO_WAND_RANGE    = 8       HERO_UNARMED_FLEE     = 40
HERO_CLOSING_MEMORY_S = 1.5 s HERO_CLEAR_MARGIN  = 4       HERO_HUNTED_PAUSES    = 3
HERO_WARY_S       = 8 s
```

## Going somewhere: go and home (card 138)

`{"do":"go","to":[x,y]}` and `{"do":"home"}` (the tile `{"cmd":"home","at":[x,y]}`
marked on this level, else the surface spawn) are goal kinds whose tick is
`hero_go_tick`. The path comes from `hero_plan`, an A* over feet tiles in a
`HERO_NAV_W` x `HERO_NAV_H` window round the hero, at most `HERO_NAV_BUDGET`
nodes, its scratch (`Hero_Nav`) sized once in `gs.hero`. A tile is stood in
when it and the one above are open (not solid, not burning, not water) and
the one below is solid. Moves and their price:

| Move | When | Cost |
|---|---|---|
| walk | the next column, level or a step up; level, also into a structure, scroll chest or door the body walks through from the side (`hero_walk_in`, card 164: a 2-high tunnel with a chest in it was `no_route`) | 1, a step 1.5 |
| jump | a step two up, headroom clear | 2 + `HERO_NAV_JUMP_COST` |
| drop | off an edge to wherever it lands | 1 + 0.3/tile + `HERO_NAV_HP_COST` per hp; never onto a burn or water, never one that kills or leaves hp under `HERO_LOW_HP_FRAC` |
| gap | a running jump over open columns, landing up to `HERO_GAP_MAX` over | columns + `HERO_NAV_JUMP_COST` |
| bridge | a plain block from the bag (`HERO_BRIDGE_BLOCKS`: of stone, dirt, turf and mossy stone the one with the most to spare past what the queued and running craft goals need of it, `hero_craft_reserve`, never a log, plank, ore or sand; card 159) set under the next column, never into a cell holding a pile | 1 + `HERO_NAV_BRIDGE_COST`; at most that spare, counted over every stack |
| dig | with the pick, or by hand through wood: a tunnel (2 tiles), a step cut up (3), a stair down, one down and one across (3); never a shaft, never the floor under the feet, never a tile beside water or lava, never the goal tile's own floor | 1 + `HERO_NAV_DIG_COST` per tile dug |

A drop that hurts at all is taken only when no way without one reaches: the
search runs once with no hurtful drop, and again with them only if that fails
(card 158). No walk, step-up, jump or dig stands on a floor a dig of the
last `HERO_NAV_DUG_BACK` (4) steps on its way takes away; a seeded cave fuzz
holds the plan to 4, since a shorter look back plans onto cuts 3 and 4 steps
back (card 159, playtest 127: a stair up cut the floor of
its own turn back, every plan again the same, and the craft walked west 1500
frames). The search ends at the goal tile, or keeps the tile nearest it; an
empty path is `no_route`. A path longer than `HERO_PATH_MAX` keeps its start and is
planned again from its end. The executor writes only `gs.agent.cmd`: it walks
toward each step's tile, jumps at a two-high wall or a gap's edge, selects the
pick (with none, puts a sword or wand away and cuts wood by hand) and mines a
dig step's tiles from where it stands, selects the block and
places it for a bridge (a pile come to lie in the cell since: plan again),
and shuts an open window first. It plans again when
the path runs out, when the hero lands outside the box between a step's two
tiles (an edge still holding the body up is inside it), and once after `HERO_GO_REPLAN_S` with no headway; a tile dug
is headway. `HERO_GO_STUCK_S` with none is `blocked`; a goal tile on top of a
structure (walked through from the side, so not stood on by walking up to it)
says so (card 159). A goal tile that burns
or drowns is `hazard` at the start; a solid one means the tile on top of it.
The ledge row leaves a go alone: its drops are priced already.

## Reflexes

After the brain, under every goal and with none, each reflex the agent has
not switched off (`{"cmd":"reflexes","potion":false,...}`, `Hero_Reflex`,
`hero_reflexes` table) may change the tick's input:

- leave_hazard: in lava, water or a burn, or in the air over one, walk (and
  jump) for the nearest column on dry ground, or ground a jump reaches, that
  no wall stands before;
- potion: under `HERO_LOW_HP_FRAC` of max hp, drink a health potion, else eat
  a Sky Egg (`hero_heal_items`, card 156), then not again for
  `HERO_POTION_COOLDOWN_S`;
- floor_dig: no pick or wand dig of the floor under the body when the fall
  through it would kill or land in a burn; a body still on another column's
  floor does not fall (card 159: at x 45.201 the body's edge read into the
  next column, and its ore was refused as the floor, playtests 127 and 128);
- rim_dig: no dig of a tile beside water or lava. A weapon's swing is no dig.

A dig refused names itself (`gs.hero.refused_by`, `refused_at`): a work goal
whose tile a reflex kept the pick off fails `refused: the <reflex> reflex keeps
the pick off [x,y]` at once, not `blocked` after `HERO_MINE_GIVE_UP_S`.
- fight_back: hurt, the hero strikes back for `HERO_FIGHT_BACK_S` at the
  nearest enemy of the kind that hurt it (`gs.hurt_by`), the sword in reach or
  the wand at range, unless a verb (a potion) is set or a window is open. It
  answers blows the brain does not: in the first `HERO_REACTION_S`, and while
  the hero flees with only a sword.

## Fighting: the fight goal (card 140)

`{"do":"fight","kind":"Pond_Frog"}` (the nearest of that kind in sight) or
`{"do":"fight","slot":12}` fights one enemy until it is gone (`agent_fight.odin`).
It strikes through `hero_strike`, as the brain does: the sword in reach, else
the fire wand with mana at range along a clear line to the body's centre (the
enemy's w,h). With no blow from where it stands it walks, as a go does but never
digging, to the stand nearest the target's row (then nearest the hero) from
which one lands, so from a pit or behind a ridge it climbs out first and never
shoots into a wall (run 8 tunnelled under a frog and shot the dirt). A stand no
walk gets to is passed over, `HERO_FIGHT_SKIP` at most; with no stand at all
(an eel hugging the far wall of its pool) it waits `HERO_FIGHT_WAIT_S` in all for the
target to come out. With the wand it keeps `HERO_KITE_TILES` off. Under
`HERO_FIGHT_RETREAT_FRAC` of its hp it backs off all the way out of
`HERO_THREAT_FAR`, shooting with the wand as it goes, and fails `low_hp`.
While it runs, the brain's fight and flee score 0: the goal does both. It
fails `no_item` (no sword or fire wand), `no_target` (none in sight, or the
slot is empty), `unreachable` or `low_hp`.

## Working: mine, gather, craft, place, store (card 139)

Eight more goal kinds, each a row of `agent_goal_kinds`, all in
`agent_work.odin`. The add check reads the fields (`hero_work_parse`), the
start finds what the goal works on in the world as it is then, and the tick
walks with `hero_go_tick` (a failed walk is `unreachable: <why>`) and works
with the input a player gives.

| Kind | Fields | What it does |
|---|---|---|
| mine | `tile`, or `item` (+ `near`) | the nearest tile that gives the item round `near` (else the feet), no rim, a tool in the bag that mines it; walks into reach, takes the tool up, holds the button on it until the tile changes; hovering in flight (`hero_hovering`: no floor under the feet row, so no walk starts there) it works a tile in reach from the hover and fails `unreachable: ... out of reach of the hover in flight` for the rest (card 164, goal 316) |
| gather | `item`, `count` (1) | piles of it first (a pile lies on the ground: stood in, it is picked up), then the tiles that give it, nearest each time, until the bag holds count; a cut trunk falls and may give more |
| craft | `item`, `count` (1) | the revealed recipe; walks to its station, opens it (TAB's window for a hand recipe), clicks the card, then CRAFT count times |
| place | `item`, `at` or `near:"home"` | walks into reach and sets it down (a stand that leaves the body over the tile is walked to its middle, else `blocked`, card 164); near home walks to the home goal's tile and takes the free tile nearest it that takes the item; refused in reach, it fails `refused: <the game's own note>` (`place_refusal_full`, the click's note too: the cell, a template's foundation, a machine's gate; card 159) |
| store | `item`, `count` (all), `at` (else nearest barrel) | drags the bag's stacks of it into the barrel |
| withdraw | `at`: barrel or scroll chest (+ `item`, `count`), silo, smelter; no `at`: the nearest barrel or chest holding `item` (a chest never opened holds its own scroll) | barrel stacks to the bag; a silo's click empties it (no window); a smelter's ore back |
| feed | `item` (ore or wood), `count` (all), `at` (else nearest smelter) | drags it onto the furnace's ore or fuel slot |
| collect | `at` (else nearest smelter) | drags the cast bars from the tray to the bag |

Tools: the longest mine wand the mana fires (it mines from where the hero
stands, in its range), else the pickaxe (its swing round the body), else bare
hands, and those only on wood. Reach is measured from the feet tile.

A tile under the ground (stone and ore lie under the turf) is reached as a
player reaches it: with a pickaxe the stand tile may be one still to dig, and
the walk there digs its way as go does (a tunnel, a step cut up, a stair down,
never a shaft); each tile to dig weighs `HERO_WORK_DIG_COST` tiles of walk. A
tile that gave the item but that no walk reaches is passed over for the next,
`HERO_WORK_SKIP` at most, in a gather and in a mine by item; a mine of a named
tile fails.

No work dig takes the hero's own floor over a drop that hurts or burns
(`hero_dig_safe`, 138's fall rule: free to `SAFE_FALL_TILES`, water breaks the
fall). The stand search refuses a stand on top of the tile, and a hero already
standing on it steps aside first. A lone ore sticking into a cave is mined from
the side or, with no side in reach, a named tile fails `unsafe` and a mine by
item or a gather passes it over.

A wary hero takes no stand a hunter would corner it at (card 157). Wary is a
threat in the senses inside `HERO_WARY_S`, noticed or not, or spent (under
`HERO_LOW_HP_FRAC` with no Health Potion or Sky Egg in the bag). Wary, a stand
whose way out (`hero_exit_cost`) costs more than `HERO_WARY_EXIT_HP` hp is
skipped, and with none left the goal fails as `cornered`: mine, place and every window kind (card 157); a gather or a mine by item passes the tile over and, when none is left and one it passed over was cornered, fails `cornered` too, never a false `no_item` or `unreachable`. The way out is
walked each way for `HERO_THREAT_FAR` steps as a player walks: a step up of one
or two tiles with head room, a walk or a free drop, a gap the jump arc clears.
It costs the hp of the first drop that hurts (`hero_column`'s fall rule), 0 if
the way runs on clear, and nothing gets through a wall, water or a burn; a
feet tile in a burn or water has no way out.

Windows are worked as a person works them (Glenn 2026-11-03): the click on the
machine opens it, `HERO_WINDOW_LOOK_S` of looking, then for each step the
cursor (`gs.hero.cursor`, in UI pixels) glides at `HERO_CURSOR_SPEED` to the
card, the button or the stack, waits `HERO_CLICK_PAUSE_S`, grabs, glides with
the stack riding it to where it goes, waits, lets go; then another look and the
window is shut. A drag moves a whole stack, as a mouse does; a store, feed or
withdraw stops once count have moved, or when a drag moved nothing (`full`).
A collect, or an ore withdraw from a smelter, is one drag; what a full bag
leaves stays in the furnace and the goal is done.
The goal hands the cursor and the carried stack to `agent_input` in
`gs.agent.cmd` (`has_cursor`, `cursor`, `carry`), which points
`inp.mouse_screen` there and shows the stack as `ui.drag_item`; the UI draws
the arrow. What a click or a let-go does is the event the same mouse gesture
pushes (`Craft_Request`, `Barrel_Store`, `Smelter_Feed`, ...), so the counts
are a human drag's. The hero does not move while the window is open. A threat
that pauses the goal shuts the window to fight or flee; back on the goal, the
hero walks to the machine again and reopens it.

A failure says why first: `no_recipe`, `no_station`, `no_item`,
`out_of_reach`, `unreachable`, `unsafe` (digging it from its only stand drops
the hero further than a free fall), `blocked` (a tile in reach gave nothing for
`HERO_MINE_GIVE_UP_S`, as when the rim reflex holds the dig), `refused` (a
place the game turns away, or a dig a reflex keeps the pick off) or `full`.

## Not built (yet)

- heal, take_cover, pick_up_loot: the table takes them as rows. Loose blocks are
  sensed but nothing scores them yet; a block that lands in a body crumbles
  and does not hurt.
- An act goal cannot ask for a drop the fall would charge for: the ledge row
  fails it. A go plans such drops itself, priced, above the reflex line.
- The planner sees falling blocks as solid: a tunnel through dirt or sand
  refills behind the hero.
- Work goals search the planner's window round the hero (`HERO_WORK_SEARCH_*`)
  and give up on the first target the walk cannot reach.
