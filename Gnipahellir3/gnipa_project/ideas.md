# ideas.md — raw idea capture

Quick-capture backlog for design ideas before they're lost. Not committed scope —
these graduate to `context.md` §5 (queued work) or `flagg.md` once picked up.
Keep entries faithful to how they were said; add just enough structure to build from.

---

## 2026-08-05 — early-zone environmental buffs (Glenn)

### 1. Persistent altar rune halo → Fly buff aura (early sky)
After the Sky Altar ritual completes, the ceremony runes shouldn't fully vanish —
leave a **smaller version of the first ritual runes spinning forever**, looping
over the Sky Altar.
- **Effect:** standing **in range of the spinning runes grants a 1-minute Fly
  buff** (refreshes/recharges while in range).
- Notes for build: this is the "leftover" state of `draw_ritual` / the rune ring
  (see context.md — ritual ceremony, `Ritual_State`, `draw_ritual`). Persistent
  visual + a proximity check around the altar tile → apply timed Fly buff. Buff
  timer is a new transient (probably) player state.

### 2. Glowing cave moss/berries → Leaf-Fall buff (first underground)
In the **first underground zone** (through the first portal), spawn **cave
moss / bush with green glowing berries**.
- **Effect:** harvesting/eating the berries gives a **20-second Leaf-Fall** effect
  (slow-fall / feather-fall — take the berry, drift down safely).
- Notes for build: new terrain/decoration tile in cave-1 gen (green glow), a
  pickup that applies a timed "Leaf_Fall" status. Pairs thematically with the
  sky Fly buff — both are early, environmental, timed-mobility boons.

**Common thread:** timed player buffs sourced from the environment, one per early
zone (sky = Fly, cave = Leaf-Fall). Suggests a small shared **timed-buff system**
(a `Buff_State` with an enum + timer) worth designing once for both.

---

## 2026-08-05 — enemy roster brainstorm (Glenn)

**The Builder DNA (why it works — reuse this):** autonomous agent with its own
agenda + player's own world verbs (mine/place/bridge/pillar via `astar_dig` +
`builder_exec_action`) + raidable den & stockpile + only hostile when provoked
(`builder_alert`). New enemies twist a facet of this, not just "walk and bite."
Two structural gaps to fill: **the sky/ascend axis has no enemies** (descending is
dangerous, ascending is a free build zone), and **nothing threatens your machines**
(the long arc is automation, but a base you never defend has no stakes).

Roster (role tags: [AGENT] autonomous · [THREAT] hunts player · [STUFF] targets your base):

1. **Draugr — dead builders** [THREAT] · *build first, cheapest.*
   A killed builder rises as an undead hunter. Slow, relentless, no economy goal —
   just the player. **Phases through the den it once built** (thematic + reuses
   door-permeability idea). Norse: draugr = grave-dweller. Reuses the builder body
   + AI with goal locked to `Hunt`; makes permadeath/combat *matter*. New
   `Enemy_Kind.Draugr`; spawn on builder death; skip den/economy goals in
   `update_builder`.

2. **Anti-machine creature — gnawer / hoard-thief** [STUFF] · *fills the biggest gap.*
   Two flavors (pick one or both):
   - **Rock-gnawer / grave-worm** — burrows its own tunnels, **eats ore piles and
     placed blocks**, chews a silo/barrel down over time. First anti-hoard threat →
     stockpiles now need walls.
   - **Magpie / hoard-thief** — darts in, grabs from a pile or open silo, flees to
     its own stash. Non-lethal but infuriating; **raid its nest to reclaim** (mirror
     of raiding a den). Turns loot into something to guard.
   Both give the automation arc real defensive stakes.

3. **Sky predator — raven / valkyrie / harpy** [THREAT] · *fills the empty ascend axis.*
   Aerial diver. Attacks while you place Cloud Stone, or **pecks apart sky
   platforms** so falling actually threatens the ascend axis. Needs a flying-body
   movement mode (no gravity/A* — steer toward target); the first non-walking enemy.
   Pairs with the queued sky Fly-buff idea (risk on the fun toy).

4. **Rival dvergr clan** [AGENT] · *three-way tension, cheap.*
   The builders are dwarves; a second clan that fights the first **and** you, racing
   for the same ore. Mostly a faction tag on existing builder AI + friend/foe checks
   in targeting; turns a level into a contest. Raid either clan's den.

**Suggested build order:** Draugr (re-skinned builder, death gains weight) →
anti-machine creature (the gap automation structurally needs) → sky predator (the
other gap) → rival clan (variety once faction plumbing exists).

**Shared tech these imply (design once):** `Enemy_Kind` already dispatches body
size/speed (`enemy_body_size`/`enemy_speed`) — extend that spine. Likely wants a
flying movement mode (sky predator), a faction/allegiance field (rival clan,
draugr-vs-builder), and an "attack nearest machine/pile" targeting goal
(anti-machine). None break the fat-struct / event-driven / table-driven laws —
new `Enemy_Kind` rows + new goal procs.

---

## 2026-08-06 — time-rewind brainstorm (Glenn) — NOT SOLD YET, parked for review

Sparked by noticing `save_game`/`load_game` round-trip nearly all of `Game_State`
as one POD `mem.copy` (`save.odin`), which makes "snapshot now, restore later"
cheap to build in principle. Glenn's opening idea: **a wearable ring that lets
time run backwards.** Nothing here is scoped — capturing the spread before it's
lost.

1. **Ring of the Norns (personal rewind)** — active ability, rewinds just the
   player (pos/vel/hp) a few seconds back. Cheap: sample only `Player` into a
   short ring buffer every frame, not the full 3.17MB `Save_Data`. Panic button
   for lava/fall/Garm-combo deaths. Cost should mirror the reward (mana drain,
   or a charge that only refills at a shrine/altar) per the design north star.

2. **Thread-snip (golem rewind)** — same trick scoped to one `Golem` — rewind a
   worker that wandered into lava or got buried, without touching the world.
   Very cheap (one small struct), and doubles as in-fiction cover for exactly
   the kind of stuck-golem recovery already being hand-tested this session.

3. **Hel's Hourglass (checkpoint item)** — rare consumable: drink to set a
   checkpoint, drink a second later to snap back to it. Full `Save_Data` cost,
   so scarce/craftable by design, one active checkpoint at a time (not a
   buffer).

4. **World-undo (dig-mistake insurance)** — periodic full checkpoints as a
   late-game machine/altar ritual: "undo the last 30 seconds of terrain
   change." Expensive and rare on purpose — fits the automation endgame more
   than an early ring.

5. **Echo/decoy** — not a rewind at all: record the last N seconds of player
   movement and spawn a replaying ghost as a combat/misdirection tool. Reuses
   the cheap position-buffer from #1 but for offense, not safety.

**Open fork:** early defensive tool (cheap, personal, frequent — #1/#2) vs.
rare/late "undo the world" item (expensive, scarce — #3/#4) — decides whether
this is a small per-frame buffer or a periodic full-state checkpoint. Also
worth deciding before building: none of these rewind transient state (camera,
particles, gravity falling-block pool, notifications, ritual swirl) since it
isn't in `Save_Data` — a restore reads as a jump-cut, not a smooth rewind.

---

## 2026-08-09 — gem economy: the SINK half (parked when the Replicator shipped)

The Gem Replicator (`gem_industry.md`, built 2026-08-09) closed the SOURCE
half — gems are now renewable, so future gem sinks stop being one-shot traps.
The sink half was deliberately left out of that build (its §6); parked here so
it isn't lost:

1. **Gem conversion** — e.g. 3 Emerald → 1 Jade at the Rune Altar. Gives the
   lower tiers a floor and makes a surplus meaningful.
2. **A gem socket on every machine** — generalise `miner_gem_tier`
   (miner.odin) into sim.odin so the Smelter / Tree Grower / Flower Bed each
   accept a gem to permanently tier up. This is Glenn's north star ("the gem
   you feed a machine is the speed you get back") spelled out, and the
   natural next step now that gems are farmable.
3. **Gem-tier gear above runic**, or socketed upgrades on existing gear
   (`gem_progression.md` §"Gem sinks").
4. **Gem dimensions** (`gem_progression.md` steps 2–4) — the *other* bulk
   route, with the "richer world = nastier world" hazard table. Still blocked
   on enemy variety.
5. **Fix the contradictory gem ladders** — miner speed uses
   Emerald/Jade/Diamond/Hel, golem slots only Emerald/Hel: Jade and Diamond
   still do nothing for golems. (A gem socket on the wand/hearth, or a
   conversion floor, both address it.)

---

## 2026-08-10 — input recording for true replay (dev tool, feasibility checked)

Grew out of explaining the save-replay debugging pattern: the save is a
single-frame snapshot (zero seconds of history), so today's playback is
"logs hold the past, the save holds the present, the deterministic sim
manufactures the future." Input recording would add the missing piece:
**re-run Glenn's exact playtest session, keystroke for keystroke** — the whole
evening becomes an attachable repro, watchable at 1× or replayed headless at
max speed. A diagnostic tool, not game content (though it's the same tech the
time-rewind brainstorm's #5 echo/decoy would need).

**Feasibility was checked 2026-08-10 — the codebase passes the three usual
killers clean:**

1. **The sim has zero RNG.** No `core:math/rand`, no `GetRandomValue` anywhere
   in `src/` — all "randomness" is position/seed hashing. Bit-deterministic
   given state + inputs + dt, for free.
2. **Hardware input has one chokepoint.** All raylib input reads live in
   `input.odin` (64 calls) + exactly 1 in `main.odin`. Nothing else polls
   hardware.
3. **The only other nondeterminism is dt** — `gs.delta_time = rl.GetFrameTime()`
   (`main.odin:69`), so record dt per frame. `rl.GetTime` appears only in draw
   code (read-only), wall clock never touches the sim.

**Design sketch:**

- **Recording file** = a `Save_Data` snapshot at record-start (keyframe zero)
  + one record per frame: `{dt, key/button bitfield, mouse pos, wheel}` —
  everything `input.odin` consumes. ~25 bytes/frame ≈ 5–6 MB per hour of play
  before compression.
- **The refactor (bulk of the work):** funnel the ~65 raw
  `rl.IsKeyDown`/`GetMousePosition`/etc. calls through a thin shim
  (`inp_down(.Jump)`, `inp_mouse()`) that reads live hardware (and records) or
  the current replay frame. Mechanical change to input.odin; sim untouched.
- **Playback:** `load_game_from` the embedded snapshot, feed recorded frames
  through the shim — headless at max speed for diagnosis, windowed at 1× to
  watch.
- **Desync tripwire (essential, cheap):** hash `Save_Data` every N seconds
  into the recording; replay compares and pinpoints the exact frame
  determinism broke. State is one POD blob, so the hash is one call. A soak
  test (record a scripted session, replay, assert hashes match) makes
  determinism CI-enforceable.

**Tradeoffs, stated honestly:** recordings are only valid against the binary
that recorded them (any behavior change desyncs — stricter than save
versioning), so replays are a diagnostic artifact of the current build, not a
durable format. And it's a standing discipline cost: any future hardware/clock
read sneaking into the sim silently breaks recording (the checkpoint hashes
turn that from mystery into a pinpointed frame). Estimated 1–2 sessions.
**Not an unblocker** — save-replay + action.log has cracked every bug so far;
this is leverage, not need. Build if/when a playtest bug resists the current
workflow.
