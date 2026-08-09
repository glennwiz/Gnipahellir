# gem_industry.md — the Gem Replicator (BUILT 2026-08-09)

**Status:** design agreed with Glenn 2026-08-08; **implemented in full
2026-08-09** exactly per §4's build steps — tests 241 → 246, save probe
unchanged at 3,171,512, not yet eyeballed in-game (see `context.md`, the
source of truth, for current state). §6 (the sink half) remains open and is
parked in `ideas.md`. The sections below are kept as the design record.

**Companion docs:** `gem_progression.md` (the original 2026-07-13 gem ladder
design — this closes its missing "bulk" half), `context.md` (source of truth),
`CLAUDE.md` (architecture law).

---

## 1. Why — the two-economy diagnosis

Glenn's opening observation this session: *"we have two economies in game now i
feel, wood AND gems."* That's right, but they are not two economies of the same
**kind**, and only one of them is finished.

### Wood is a flow economy (healthy — do not touch)

Every log is either **4 planks** or **2 units of smelter fuel**, and you choose
every time. Plank sinks today: Crafting Bench, Tree Grower, Sky Altar, Sword,
all five Iron armor pieces, Mine Wand, Door, Flower Bed, Barrel, Command Wand.
Fuel sink: `FUEL_PER_BAR`=2 logs per bar (`sim.odin:15`). Renewable but *slow*
via the Tree Grower (20 s/tree). Genuine competing demand — that IS the economy.
Charcoal/alternate fuel was offered as relief and **declined**; the competition
is the point.

### Gems are not an economy — they are a key ring (broken)

Non-renewable, non-convertible, spent once for **permanent capability**:

| Sink | Cost | Where |
|---|---|---|
| Auto-Miner recipe | 1 Emerald | `crafting.odin:110` |
| Void Charm | 1 Emerald | `crafting.odin:135` |
| Jade Ring | 1 Jade | `crafting.odin:143` |
| Command Wand → 5 golem slots | 1 Emerald | `golem.odin:1602` |
| Command Wand → 15 golem slots | 1 Hel Gem | `golem.odin:1613` |
| Auto-Miner speed tier (permanent) | any gem | `miner.odin:26` |

Natural supply is tiny and one kind per layer (`levels.odin:545-550`): Emerald
cave 1 deep rows, Jade cave 2 (`depth > 60`, 6/1000), Diamond cave 3 (3/1000),
Hel Gem only in the arena band (4/1000). Roughly 4 / 9 / 13 / 8 per level.

**Three concrete faults:**

1. **Gems are the only material in the game with no renewal path.** Wood has the
   Tree Grower, ore has regen (flagg G7), flowers have beds. Mine out cave 2's
   ~9 jade and that is it, forever.
2. **Diamond has exactly one sink in the entire game** (miner tier 3). Jade has
   two, Hel Gem two. Surplus gems are dead weight in the bag.
3. **The two gem ladders contradict each other.** Miner speed uses
   Emerald/Jade/Diamond/Hel; golem slots use only Emerald/Hel. Jade and Diamond
   do nothing for golems.

### What `gem_progression.md` intended, and what actually shipped

That doc designed gems as a full ladder: sparse natural veins for **seed stock**,
industrialisation later for **bulk** ("Rarity in nature stays LOW — bulk comes
only from dimensions"), plus a menu of sinks marked *"pick some."*

Only **step 1 (natural veins)** and **one sink (Auto-Miner)** ever shipped. The
bulk half was never built. That is the hole this document fills.

Glenn's north star — *"the cost mirrors the reward; the gem you feed a machine
is the speed you get back"* — is literally implemented exactly once, in
`miner_gem_tier` (`miner.odin:26`), and was never generalised.

---

## 2. The decision

Glenn's calls this session, in order:

1. **Lean into the two-economy split rather than merge it.** State it as a law:
   **wood/stone/metal buy OBJECTS; gems buy PERMANENT CAPABILITY.** Merging gems
   into the metal ladder was offered and rejected.
2. **The gap that bites is renewability**, in his words: *"we need a gem
   replicator to stand like the tree grower."* Not gem dimensions — a **machine**.
3. **Seed model: the seed stays and copies forever** (Tree Grower parity), not a
   consume-and-double.
4. **Placement rule: depth-gated.** Trees need open sky; gems need pressure.
5. **Output: a tray + auto-chute into an adjacent Silo / Golem Depot**, exactly
   as `tick_smelter` already does.

Outcome: one gem found in nature seeds a farm that slowly yields more of that
gem. The gem ladder can no longer dead-end, and **future gem sinks stop being
one-shot traps** — which is what unblocks the sink half later.

---

## 3. The machine

**Feed it one gem. It keeps that gem and slowly grows copies of it.** The rate
depends on which gem — the north star as a table row, same shape as
`miner_gem_tier`.

### Numbers (all knobs, all tunable)

| Knob | Value | Rationale |
|---|---|---|
| `REPLICATOR_DEPTH_Y` | `CAVE_LVL_TOP + 60` (= **63**) | The exact row gems naturally form at (`levels.odin:547-550` uses `depth > 60`, and `CAVE_LVL_TOP`=3, `levels.odin:465`). "It only works as deep as gems actually form." |
| Emerald period | 180 s (3 min) | Deliberately long — this is a bulk source for a permanent-upgrade currency |
| Jade period | 300 s (5 min) | |
| Diamond period | 600 s (10 min) | |
| Hel Gem period | 1200 s (20 min) | rarer gem = longer wait = cost mirrors reward |
| Seed capacity | **1** (`in_count`) | One gem is all it wants; a whole stack must never vanish into it |
| Recipe | Rune Altar: 8 Iron Bar + 4 Gold Bar + 10 Cloud Stone | Mid-game: gems appear in cave 1, but the Rune Altar needs Cloud Stone (sky, post-ritual-A). The farm is the *industrialisation* step |
| Unlock gate | `.Emerald` | Same gate as Auto-Miner/Void Charm — the card appears the moment you hold your first gem and **tells you the farm exists** |

All periods live in one `#partial [Item]f32` table. Expect to retune by feel
after the first playtest; that is one number each.

### No new UI — deliberately

- **Seeding:** drop a gem on an adjacent cell with the existing drag-to-drop
  primitive; the machine auto-pulls it. Mirrors `smelter_autopull`
  (`sim.odin:142`). Side effect worth having: **golems can seed it and haul from
  it**, so it plugs straight into the automation arc.
- **Collecting:** press `E` to empty the tray, or let a Silo / Golem Depot next
  door take the output directly.
- Fallback if hand-seeding feels clumsy in play: a drag window like the
  smelter's. Not built; do not build it speculatively.

### Nothing is ever lost

Mining or reclaiming it spills **both the seed and the tray** as ground piles,
reusing the smelter branch already in `handle_tile_mined` (`events.odin:551-565`).

Because of that it needs **no `structure_reclaim_block` entry and no
"withdraw seed" verb** — strictly simpler than the smelter, which blocks reclaim
while loaded. Do not add a block; the spill makes it unnecessary.

### No save bump

`Sim_Tile_Data` (`game_state.odin:10`) already carries everything needed, all of
it unused by the grower:

- `growth_timer: f32` → replication progress
- `in_item: Item` / `in_count: u8` → the seed gem
- `store_item: Item` / `store_count: u8` → the output tray
- (`fuel_count` stays 0 — smelter-only)

`Item` and `Tile_Type` are append-only, and **v24 sized `recipe_unlocked` to
`MAX_ITEM_SLOTS`**, so appending an item is now free. `save.odin` has no
`[Item]`/`[Tile_Type]`-keyed arrays left. Confirm with the existing
`save_data_size_probe` test — expect **3,171,512 unchanged**.

---

## 4. Build steps (with exact touch points)

### 1. Enums — `src/types.odin`
Append `Gem_Replicator` to `Tile_Type` (the block around `:68`) and to `Item`
(around `:154`). **Append-only — never reorder or remove.**
→ verify: `odin build src` green.

### 2. Tables — mirror the `Tree_Grower` rows exactly
- **`src/world.odin`** — `terrain_table` row modelled on `.Tree_Grower`
  (`:132-140`): `{.Solid, .Placeable, .Mineable}`, a prismatic color,
  `drop_item = .Gem_Replicator`. Then add `.Gem_Replicator = true` to
  **`is_structure_tile`** (`:541`). That one table already gates the pickaxe
  (`mining.odin:72`), wands (`mining.odin:171`), golem mining
  (`golem.odin:687/719`), sideways walk-through (`physics.odin:51`) and
  `update_reclaim` — the same single-table trick the rune coffers used.
- **`src/items.odin`** — `Item_Info` row modelled on `.Tree_Grower` (`:36`):
  name, color, `place_tile = .Gem_Replicator`, and a `desc` that names **both**
  the depth rule and the seed (the crafting card's description is player-facing
  teaching — that is how the bucket taught springs).
- **`src/item_art.odin`** — icon: stone plinth + faceted crystal. `CRYSTAL_GRID`
  (`:639`) is the palette reference; `TREE_GROWER_GRID` (`:586`) is the
  machine-silhouette reference.
- **`src/render.odin`** — `station_glow` entry (`:110`), prismatic violet-white.
  This table also drives `update_ambience`'s rising sparks for free.

### 3. The machine — `src/sim.odin`
- `REPLICATOR_DEPTH_Y` const, next to `TREE_GROW_TIME` (`:17`).
- `gem_replicate_time :: #partial [Item]f32{...}` — copy the shape of
  `miner_gem_tier` (`miner.odin:26`). A nonzero row is also the `is_gem` test.
- `gem_replicate_time_for(it) -> (f32, bool)` — mirrors `smelt_rule_for` (`:63`).
- `replicator_autopull(gs, x, y, sd)` — scan the 8 neighbours for one gem pile,
  pull **1** into `in_item`/`in_count` if the seed slot is empty. Copy the loop
  shape from `smelter_autopull` (`:142`), including its `return` after one pile
  ("one pile per tick keeps it cheap").
- `tick_gem_replicator(gs, x, y)` — the core. Order:
  1. `replicator_autopull`
  2. no seed → `growth_timer = 0`, return
  3. resolve `out_silo := silo_adjacent(...)` / `out_depot :=
     golem_depot_adjacent(...)` **verbatim as `tick_smelter` does** (`:101-104`),
     including the `has_room` nil-outs
  4. tray-full check → `growth_timer = 0`, return (same `tray_ok` shape as `:106`)
  5. advance `growth_timer` by `gs.delta_time`; below the period → return
  6. on fill: reset the timer, **leave `in_count` at 1**, deposit one gem into
     silo → depot → tray in that priority, spawn a particle burst, push a
     `Play_Sound` event, `log_action`
- Register `.Gem_Replicator = tick_gem_replicator` in **`tile_on_tick`** (`:36`).
- `replicator_collect(gs, tile)` — a sibling of `smelter_collect` (`:272`) with
  its own wording. Keep the `BENCH_RANGE` check and the lossless partial-take
  (whatever the bag cannot hold stays in the tray).

### 4. Placement gate — `src/placement.odin`
Refuse in `placement_ok` above `REPLICATOR_DEPTH_Y` and in `LEVEL_SKY`, with the
matching explanatory `notify` in the failure block. This is the **paired**
pattern the Auto-Miner (gate `:23`, explanation `:109`) and the Silo (gate `:30`,
explanation `:117`) already use — follow it, do not invent a new one.

Why refuse at placement rather than silently not tick: the depth condition is
*static per cell*, unlike the Tree Grower's sky check which is dynamic (chop the
tree above and it resumes). A refusal with a reason is unambiguous feedback.

### 5. Wiring — `src/events.odin` + `src/reclaim.odin`
- **`events.odin:99`** `Tile_Placed` teach-notify — add a case beside the
  Smelter/Tree Grower ones: *"drop a gem beside it — it grows more of that gem."*
- **`events.odin:555`** widen `if old_tile == .Smelter` to include
  `.Gem_Replicator` so the seed (`in_*`) and tray (`store_*`) spill on mine. The
  `fuel_count` branch is a harmless no-op (a replicator never sets it), and
  `sd^ = {}` at `:566` already clears everything.
- **`reclaim.odin:66`** — add `case .Gem_Replicator: replicator_collect(...)` to
  the `E`-interact switch, beside the `.Tree_Grower` notify case.

### 6. Progress art — `src/render.odin` `draw_machine_progress` (`:1031`)
A crystal climbing out of the plinth as `growth_timer` fills, **tinted by the
seed gem's own color** read from `item_table` — so the machine visibly reads as
"growing an emerald." Direct mirror of the `.Tree_Grower` sapling case (`:1041`),
which is the best reference for how to pace a growing shape (it was already
tuned once: the stalk climbs the full `TREE_MAX_H` rather than popping).

Render is read-only — read `sim_data`, call raylib, mutate nothing.

### 7. Recipe — `src/crafting.odin`
- Append the row to the **END** of `recipe_table`. Recipe indices are
  load-bearing for tests (`tests.odin:1209`, `:2068`) — every prior recipe was
  appended for the same reason.
  ```odin
  { .Gem_Replicator, 1, .Rune_Altar, {{.Iron_Bar, 8}, {.Gold_Bar, 4}, {.Cloud_Stone, 10}} },
  ```
- Add `.Gem_Replicator = .Emerald` to `recipe_unlock` (the `:185` block, beside
  `.Auto_Miner` and `.Void_Charm`).

### 8. Tests — `src/tests.odin`
Mirror the existing sim tests. Five new:

| Test | Asserts |
|---|---|
| `gem_replicator_copies_its_seed` | seeded deep, after the emerald period the tray holds an Emerald **and `in_count` is still 1** |
| `gem_replicator_needs_depth` | `placement_ok` refuses above `REPLICATOR_DEPTH_Y` |
| `gem_replicator_casts_into_a_silo` | an adjacent silo receives; the tray stays empty |
| `gem_replicator_rate_scales_with_gem` | a Hel Gem seed yields nothing in the window an Emerald seed completes in |
| `mined_gem_replicator_spills_seed_and_tray` | both land as ground piles, nothing lost |

`tests.odin:4160` (the Tree Grower test) is the closest fixture to copy.

**Fixture warning, learned twice already:** two prior sessions had tests break
because their fixture sat at x=30, where the default seed's pond generates. Park
new fixtures at **x=76** (the pond-free band) unless the coordinate is the point
of the test.

### 9. Docs
- `context.md` — header bullet + §4 entry; state the **wood buys objects / gems
  buy permanent capability** law so it survives the session.
- `gem_progression.md` — tick the renewal item; its "Gem sinks" list and build
  order both predate this.
- `ideas.md` — park the still-open gem gaps (below).

---

## 5. Verification

```
odin build src                    # green
odin test src -all-packages       # 226 existing + 5 new
```

- `save_data_size_probe` still logs **3,171,512** — no save bump, the live
  playtest run keeps loading.
- **Then eyeball it in-game.** There is already a backlog of un-eyeballed work
  (fluids, springs, the Scroll of Waters, the camera pass) — do not add to it.
  F1 → give an Emerald + a Gem Replicator, dig below y=63, place it, drop the
  emerald beside it. Confirm: the auto-pull fires, the crystal grows **in the
  machine's own gem color**, the tray fills, `E` collects, and a silo next door
  takes the output.
- Rate check by feel — 180 s for an emerald is a deliberate guess.

---

## 6. Explicitly NOT in scope

This change is the **source** half of the gem economy. The **sink** half is
still open and was deliberately left out:

- **Gem conversion** — e.g. 3 Emerald → 1 Jade at the Rune Altar. Would give the
  lower tiers a floor and make a surplus meaningful.
- **A gem socket on every machine** — generalising `miner_gem_tier` to `sim.odin`
  so the Smelter / Tree Grower / Flower Bed each accept a gem to permanently tier
  up. This is the north star spelled out and is the natural next step once gems
  are farmable.
- **Gem-tier gear above runic**, or socketed upgrades on existing gear
  (`gem_progression.md` §"Gem sinks").
- **Gem dimensions** (`gem_progression.md` steps 2–4) — the *other* bulk route,
  with its "richer world = nastier world" hazard table. Still blocked on enemy
  variety.
- **Fixing the contradictory gem ladders** — Jade and Diamond still do nothing
  for golems while they do something for the miner.

Also declined this session: merging gems into the metal ladder, and adding
charcoal/alternate smelter fuel to relieve wood (the competing demand *is* the
wood economy).
