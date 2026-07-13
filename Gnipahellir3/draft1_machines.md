# Draft 1 — Mana Machines & the Magic Economy

Status: **brainstorm / design menu**, not a build plan. This is the *what* and
*why*. The *how* (machine store, global power pool, adjacency item handoff, the
reclaimed `update_sim` tick) is already answered in `architecture_findings.md` —
read that for implementation shape. Nothing here contradicts it.

Goal of this doc: pick a direction for **what mana is for**, so the machine
system we build has a point. Everything below is meant to be **fully automatable
by end game** — the player's hands are only on the loop early; late game they
design factories, not click tiles.

---

## 0. The core idea: mana is fuel, and it has two flavors

Mana is the single fuel that runs every magic machine. But the game already has
a **descend/ascend dual axis** (`plan.md` core loop), so lean into it: mana
comes in **two flavors that mirror the two axes**.

| Flavor | Source axis | Feel | Availability |
|--------|-------------|------|--------------|
| **Earth Mana** (Jörð) | Underground / ground-set machines | Steady, cheap, heavy | From the start |
| **Sky Mana** (Aether) | Sky levels / solar & wind collectors | Bursty, high-yield, weightless | Late game |

Early game runs on Earth Mana. Late game the *best* machines need **both** — a
recipe that demands Earth + Sky mana forces the player to have conquered both
axes. This makes the mana economy *reinforce the progression the game already
has* instead of bolting on a parallel system.

**Simplest first version:** one global `power` pool (per the architecture doc).
Two flavors is a v2 — just two pools (`earth_power`, `sky_power`) once the
single-pool loop is proven fun. Don't build two on day one.

---

## 1. Where mana comes from (sources)

Ordered by roughly when the player unlocks them. Each is a **generator machine**
(`power_gen > 0`, in the machine recipe table).

### Earth-flavor sources (early → mid)

1. **Rune Well / Earth Tap** — *the starter.* Placed on the ground at the start
   of the game, low steady trickle of Earth Mana, no fuel. This is the "you
   always have a little" baseline so the player is never fully stuck. Matches
   your "earth (ground set machine at the start)" note exactly.
2. **Geothermal Vent** — placed on or adjacent to **Lava** (terrain already
   exists). Higher yield than the Rune Well but tethered to a hazard — you have
   to build near danger. `Magic_Lava` version yields more and corrupts nearby
   tiles (risk/reward).
3. **Ore Furnace / Mana Forge** — *consumes* a fuel item (Wood_Log early, refined
   bars later) and burns it into mana. This is the "spend materials for power"
   valve — bridges the crafting economy into the mana economy.
4. **Crystal Resonator** — consumes ore/crystal items for a big burst. The
   "premium fuel" option.

### Sky-flavor sources (late)

5. **Solar Collector / Aether Panel** — *your late-game solar-panel idea.* Only
   works on **sky levels**, drinks Sky Mana from open air. Passive, high yield,
   but immobile in the sky — you have to build your factory *up there* or
   transport the mana down (see §4, "cross-level mana" — a genuine late-game
   logistics puzzle).
6. **Wind Turbine** — placed in a `Wind_Current` tile (already exists as terrain
   that pushes the player). Turns the hazard into a resource.
7. **Storm Rod** — Sky Peaks only, harvests the lightning hazard. Highest yield,
   intermittent (bursts), needs buffering in a capacitor.

### The buffer (needed by both flavors)

8. **Mana Capacitor / Battery** — stores mana so bursty sources (Storm Rod,
   Crystal Resonator) can feed steady consumers. With the global-pool model this
   is just raising `power_cap`; as a *placeable* it becomes a real logistics
   piece later.

**Design knob:** every source trades one of {steady vs bursty, safe vs
hazardous, free vs fuel-hungry, here vs sky}. That spread is what makes choosing
*which* generator to build interesting.

---

## 2. What mana is FOR — five paths we can lean into

This is the real question you asked. Mana is fuel; here are the **directions**
the machines can point. We don't have to pick one — but the game will feel
sharpest if **one is the spine and the others are support.** My recommendation is
in §6.

### Path A — Automated Mining (the "dig itself" fantasy)

Mana powers machines that mine the world *for* you.

- **Mana Drill** — sits against a wall, consumes mana, mines the adjacent tile on
  a timer, drops the item into its output buffer. The core "factory" unit.
- **Bore / Tunneler** — drills in a line, eating mana faster, carving corridors.
- **Ore Sniffer** — highlights/auto-targets ore veins so drills prioritize them.

**Why it's good:** the game is *already* a mining game (`Mine_Wand`, mining
intent, tile drops). Automating mining is the most natural first automation and
directly scales the existing loop. This path reuses the most existing code.

### Path B — Alchemy / Orb Crafting (the "magic factory" fantasy)

Mana + raw materials → refined magical goods, in multi-stage chains. This is the
`power → orb → assembler` chain the architecture doc already sketched.

- **Mana Condenser** — mana → **Mana Orb** (raw magical intermediate).
- **Transmuter** — orbs + ore → refined/enchanted bars.
- **Assembler** — orbs + parts → finished goods (wands, keys, blueprint
  components, ammo).
- **Enchanter** — spends orbs to upgrade the player's gear (better wand range,
  faster mining, more HP).

**Why it's good:** this is the classic satisfying production tree, and it's the
sink that makes *all the other paths worth automating* (they feed it). Orbs
become the "currency" of the late game.

### Path C — Terraforming / World-Shaping (the "reshape Hel" fantasy)

Mana lets the player edit the world at scale — very on-theme for a Norse
underworld you're carving into.

- **Mana Pump** — moves Lava (you already have `Iron_Bucket` doing this by hand;
  automate it). Drain a lava lake to open a path, or *flood* an area as a weapon.
- **Wall Weaver / Constructor** — consumes Stone_Block + mana, auto-builds walls
  along a line (defense, sealing off enemies).
- **Purifier** — cleanses `corrupted` tile flags (Magic_Lava spread), spending
  mana to reclaim ground.
- **Grove Engine** — the `Tree_Grower` finally does something: mana → auto-grows
  trees → auto-harvests logs → feeds the Mana Forge. A self-sustaining wood loop.

**Why it's good:** turns hazards (lava, corruption) from pure obstacles into
*managed resources*, which deepens the survival theme.

### Path D — Defense / Wards (the "hold the dark back" fantasy)

Mana powers automated defense so the player can leave a factory running while
Garm and friends roam.

- **Mana Turret** — spends mana to auto-fire projectiles at enemies in range
  (reuses `Projectile_Store`).
- **Ward Pylon** — a mana-fueled aura that slows/damages enemies or blocks their
  builder-AI pathing.
- **Sentinel Beacon** — attracts enemies to a kill-zone so your factory elsewhere
  is safe.

**Why it's good:** the game is "player is fragile, world is hostile." Automated
defense is the answer to "who guards the base while I'm in the sky?" — it closes
a real gap the dual-axis loop creates (you can't be in two levels at once).

### Path E — Logistics & Cross-Level Transport (the "empire" fantasy, end game)

The glue that makes everything else *fully* automatable — the top of the tech
tree.

- **Conduits / Belts** — carry items across distance (the architecture doc's
  deferred "belts" — this is where they pay off).
- **Mana Conduits** — carry power across distance / between machine clusters.
- **Aether Elevator / Portal Link** — the big one: move items *and* mana
  **between levels** (sky ⇄ cave). Solves "my solar panels are in the sky but my
  factory is underground." This is the end-game capstone that ties the two axes
  into one automated empire.

**Why it's good:** this is what "everything automated at end game" actually
*means* mechanically. It's also the natural final tier — don't build it until A/B
prove the loop is fun.

---

## 3. The late/end-game vision: full automation

The promise is "everything can be automated." Concretely, a finished base should
be able to run this loop **with zero player clicks**:

```
Solar Collectors (sky)  ─┐
Geothermal Vents (lava) ─┼─► mana pool ──► Mana Drills ──► ore
Rune Wells (baseline)   ─┘                     │
                                               ▼
                        Mana Condenser ──► Mana Orbs
                                               │
                          ┌────────────────────┼───────────────┐
                          ▼                    ▼                ▼
                     Assembler            Enchanter         Turrets/Wards
                   (blueprint parts,    (auto-upgrade      (auto-defense
                    keys, ammo)          player gear)       while AFK)
                          │
                          ▼
                 Sky Altar auto-fed ──► structure completes ──► cave unlocks
```

The **fantasy of the end game** is: the player stops being a miner and becomes an
**architect**. They lay out generators, drills, conduits and defenses, then
*watch* the base mine, refine, defend, and even progress the tech tree on its
own. The player's remaining job is *designing better factories* and pushing into
the next level — not manual labor.

A stretch goal worth naming now (so we don't design against it): **auto-feeding
the Sky Altar.** If an assembler can produce the structure ingredients and a
conduit can deliver them, the *progression itself* becomes partly automatable —
the base can unlock the next cave while the player scouts ahead. Optional, but
it's the purest expression of "everything automated."

---

## 4. Cross-level mana — the one genuinely new design problem

Sky sources produce mana **in the sky**; most consumers live **underground**.
Three ways to bridge it, cheapest first:

1. **Player-carried mana** — fill a "mana flask" item in the sky, carry it down,
   pour it into a battery. Zero new systems, but not automatable → violates the
   end-game promise. Fine as a *stepping stone*.
2. **Shared global pool across levels** — cheat it: one mana pool the whole
   world draws from, regardless of level. Simplest to code (the pool already
   isn't spatial). Loses the "logistics puzzle" flavor but *is* fully automatic
   for free. **Recommended default.**
3. **Portal Link machines** — a placed pair (one per level) that transfers mana
   at a cost/loss. Real logistics, most satisfying, most code. End-game tier.

Recommendation: ship **#2 (shared pool)** so sky→cave "just works," and only
build **#3** if managing cross-level transport turns out to be a fun goal in
itself rather than a chore.

---

## 5. How this maps onto the existing progression

Slot the mana tech into the cycles the game already has so it doesn't feel
bolted on:

| Cycle | Player gets | New mana capability |
|-------|-------------|---------------------|
| Surface / Cave 1 | Rune Well, Mana Drill | *baseline power + auto-mining* — the loop begins |
| Cave 2 (needs Sky A) | Geothermal, Mana Condenser, Orbs | *first real factory chain* |
| Cave 3 (needs Sky B) | Turrets/Wards, Grove Engine | *automate defense + fuel* |
| Sky levels | Solar Collector, Wind Turbine | *Sky Mana unlocked* |
| Final (needs Sky C) | Conduits, Portal Link | *full cross-level empire* |

Each blueprint/structure gate can also gate a **mana tier**, so progression pulls
the mana economy forward instead of the two running on separate tracks.

---

## 6. Recommendation — what to actually build first

Per CLAUDE.md (simplicity first, don't overbuild): **do not build five paths.**
Build the smallest slice that proves the fantasy, and make it Path A + a sliver
of B, because they reuse the most existing code and are the most natural next
step for a mining game:

**Minimum viable mana loop (one vertical slice):**

1. **Rune Well** — starter generator, feeds the single global `power` pool.
   *(architecture doc build step 2)*
2. **Mana Drill** — consumes power, auto-mines an adjacent tile into its output
   buffer. *(the "aha" moment — the world mines itself)*
3. **Mana Condenser** — power → Mana Orb, so there's a first product to want.
4. **Adjacency handoff** — drill output → condenser input when placed touching,
   so a 3-machine line *works* and feels like a factory.

That slice = the architecture doc's build order 1–5, with **content** attached.
If *that* is fun, expand outward into B (full alchemy tree), then D (defense, to
cover the AFK gap), then E (logistics/cross-level) as the end-game capstone.
Paths C is flavor we add when we want world-shaping depth.

**Open questions for you (pick before we build):**

- One mana pool or two flavors (Earth/Sky) at the start? *(I lean: one now, split
  later.)*
- Is the spine **Path A (auto-mining)** or **Path B (alchemy factory)**? They
  combine well, but which is the headline?
- Should Sky Mana use the **shared-pool cheat** (§4.2) or a real **cross-level
  transport** puzzle (§4.3)?
- Is **auto-progression** (base auto-feeds the Sky Altar) a goal or a step too
  far?

---

## 7. Parallel Dimensions — craftable mining worlds (big pillar)

The idea: a **Dimension Creator** machine crafts **Dimension Blocks**; a block
slotted into a **Dimension Spawner** opens a portal to a fresh, *themed*,
mineable world. Want metal? Craft a **Metal Dimension** block. Want crystals? A
**Crystal Dimension**. Each dimension is an ore-biased world you set up automated
mining factories inside, then harvest at scale.

This is the answer to "everything needs 1000x" — you don't grind one map, you
**manufacture the map that's rich in what you need** and let machines strip it.

### 7.1 Why this fits the engine almost for free

The game *already* has the hard part: **levels are separate generated grids with
portals** (`Level_Store.worlds: [NUM_LEVELS]World_Grid`, `level_portals`,
`Cave_Entrance` transitions in `levels.odin`). A dimension is just:

> a generated level, whose **generation is parameterized by the block's recipe**
> (which ore, how dense, hazards), reached through a spawner portal instead of a
> fixed cave entrance.

So the machine chain is:

```
Dimension Creator  ── recipe + materials ─►  Dimension Block (item, carries a
                                             theme + seed)
        │
        ▼
Dimension Spawner  ── consumes/holds block ─►  portal ──►  themed mining world
```

`Dimension_Kind` is a **table** (theme → ore weights, hazard set, size), exactly
the table-driven pattern the codebase already uses for terrain/recipes. New
dimension type = new table row. No switch sprawl.

### 7.2 The two real constraints (must design around these)

Found by reading the code — these are hard limits, not preferences:

1. **Bulk storage is a NEW requirement.** `MAX_STACK :: 99`, `MAX_INVENTORY :: 24`
   → the player can carry **~2,400 items total**, and ground `item_counts` is a
   `u8` (caps at 255). "1000s of items" **cannot** live in inventory or on
   tiles. You need **Silo / Vault machines** — placed storage with a wide count
   (`u32`/`int`) that drills and conduits feed into. Bulk items live in silos and
   are consumed straight from them by the big crafts. This is a prerequisite for
   the whole pillar, so design it first.

2. **You cannot hold many live grids.** Each `World_Grid` is large (~20k cells ×
   several arrays) and `Level_Store` freezes one per level. Dozens of persistent
   dimension grids = memory blowout. **Resolved design (below):**
   `MAX_ACTIVE_DIMENSIONS :: 4` locked slots, everything else regenerates from
   seed.

### 7.2.1 Dimension Lock — the player picks what stays alive (DECIDED)

Hard cap: **4 active dimension slots.** The player controls *which* 4 by crafting
and placing a **Dimension Lock** inside a dimension:

- **Locked dimension** = one of the ≤4 persistent worlds. It keeps its mined
  state, holds a real (or snapshotted) grid, and **yields in the background**
  (§7.3). Costs one slot and ongoing mana.
- **Unlocked dimension** = ephemeral. Its block stores a seed; you can portal in
  to scout/hand-mine, but it **collapses (regenerates from seed) when you leave**
  — no persistence cost.
- **Removing a Lock** frees the slot and lets the player retire a played-out
  dimension for a fresher one. This is the "pick and choose what's active"
  control you want, and it *also* answers persist-vs-regenerate cleanly: locked =
  persist + yield, unlocked = regenerate.

Placing a Lock when all 4 slots are full fails gracefully ("no free dimension
anchors") — same bounded-alloc discipline as enemies/machines.

### 7.2.2 Dimension Tablet — the management view (DECIDED)

A **Dimension Tablet** is an inventory item (like the Blueprints — inspectable,
not consumed) that opens a **management window** listing every dimension the
player has: theme, richness/seed, locked-or-not, which slot, current yield rate,
linked silo, and mana draw. Read-only overview + the place to see at a glance
what your 4 locked slots are doing.

Fits the UI rules exactly: input toggles a `dimension_tablet_open` flag in
`UI_State`, `ui.odin` draws it read-only, no world mutation. (If we later allow
toggling a dimension's background-run on/off from the tablet, that goes through an
event, not a direct write.)

### 7.3 Two operating models (recommend a hybrid)

- **Model A — Explorable factory dimensions.** A dimension is a real grid you
  walk into, place drills/silos/conduits in, and physically build a factory.
  Richest gameplay, but bounded by the active-slot pool (§7.2.2) and needs the
  cross-level logistics to get goods *home* (§4 / Path E — Portal Link).

- **Model B — Abstract yield dimensions (idle).** An open dimension portal has a
  **yield rate**: while open (and powered by mana), it deposits its themed items
  into a linked silo at `X items/sec`, richer blocks = faster. **No grid is
  simulated** — it's a number going up, classic idle-game style. Cheap, scales to
  many dimensions, trivially "fully automated," but shallow.

**Recommended hybrid (locked by §7.2.1):** the player **sets up** a dimension by
hand (Model A: walk in, place the drills, wire the silo) and **places a Dimension
Lock** to anchor it; once locked it **runs in the background as a yield source**
(Model B) whether or not the player is standing in it. Best of both — the *design*
of the factory is hands-on and fun, the *operation* is automatic and
idle-scalable. This also dodges the "simulate a grid you're not standing in"
problem: a locked dimension collapses to a **rate**, and unlocked ones don't run
at all. The 4-slot cap keeps total background yield (and mana draw) bounded.

### 7.4 Feeding the bulk economy & the final craft

New bulk minerals justify the whole pillar. Introduce a tier of materials that
are **only** economical to get via dimensions — needed in the hundreds/thousands:

- Metal Dimension → **Iron/Silver/Gold** at volume (also refined bars via the
  alchemy chain, Path B).
- Crystal Dimension → **Aether Crystal / new gems** at volume.
- Corrupt Dimension → risky, drops rare reagents no safe dimension gives.
- Runic Dimension → the end-tier material.

The **final-boss craft** becomes a genuine industrial goal: e.g. the *Boss
Summoning Altar* recipe demands
`1000× Iron Bar + 800× Aether Crystal + 500× Runic Ore + 200× Void Shard`,
which realistically requires **~5 custom dimensions running in parallel** feeding
silos over real time. That's the "manufacture the world to beat the game"
end-state — and it's *fully automatable*, satisfying the core promise.

This also gives the mana economy (§1) real teeth: dimensions and their drills are
**huge mana sinks**, so running 5 at once forces a serious power base (Solar
Collectors + Geothermal + capacitors). The three systems — mana, machines,
dimensions — reinforce each other instead of being parallel tracks.

### 7.5 Where it sits in progression

Dimensions are a **mid/late unlock**, not a starter — they'd trivialize early
mining. Gate the **Dimension Creator** behind (say) the Cave 2 or first Sky
structure, so the player learns hand-mining + basic factories first, *then*
graduates to manufacturing worlds. The final-boss mega-craft is the capstone that
assumes several dimensions running.

### 7.6 Build order (after the §6 MVP proves out)

> **Status (2026-07-13):** step 2 shipped first (spawner slice, `dimensions.odin`):
> craftable themed spawners (Rune Altar tier — Metal costs iron bars, Gold costs
> gold bars; the recipe metal is the world's riches), portal in/out, ephemeral
> regen-from-seed. Themed spawner items stand in for step 3's Creator+Blocks for
> now. Silo (step 1) is next.

1. **Silo machine** first — wide-count bulk storage. Without it, nothing else
   about "1000x" works. → verify: a silo accumulates >255 of an item.
2. **Dimension theme table** + one hardcoded **Metal Dimension** you can enter via
   a manually-placed spawner. → verify: portal opens into an iron-rich grid.
3. **Dimension Creator + Block item** — craft the block, slot it into the spawner
   to choose the theme. → verify: a Crystal block opens a crystal world.
4. **Background yield** (Model B) for an established dimension feeding a silo. →
   verify: silo count climbs while player is on another level.
5. **Cross-level delivery** (Portal Link, Path E) so dimension output reaches the
   home base automatically. → verify: hands-off, base silos fill from a remote
   dimension.
6. **Final-boss industrial recipe** consuming from silos. → verify: boss can only
   be summoned after sustained multi-dimension production.

**Decided:** hybrid model (§7.3); **4** active slots controlled by **Dimension
Lock** (§7.2.1); locked = persist + background yield, unlocked = regenerate from
seed; **Dimension Tablet** as the management view (§7.2.2); **dimensions are
finite** (§7.2.3).

### 7.2.3 Finite dimensions — the rotation loop (DECIDED)

A dimension holds a finite **reserve** (total mineable ore, set by the block's
richness). Background yield draws the reserve down; when it hits zero the
dimension is **played out** — it stops yielding and **collapses**, freeing its
slot. This makes the 4 locked slots a **rotating strategic resource**, not
set-and-forget:

- The player watches the Tablet (§7.2.2), sees a dimension nearing depletion, and
  **retires its Lock** to make room for a fresh, richer block. This is an ongoing
  gameplay loop, not a one-time setup.
- **Richness is a design knob:** a cheap block = small reserve + low rate; an
  expensive block = huge reserve. The final-boss industrial craft (§7.4) implies
  burning through *many* blocks over a run, which keeps the Dimension Creator and
  the whole mana/mining economy relevant to the end.
- **Depletion detail:** since a locked dimension may collapse while the player is
  elsewhere, delivery to the home silo (Portal Link / §5 Path E) must keep up, or
  drain the final reserve into the linked silo *at collapse* so nothing is lost.
  Emit a `Dimension_Depleted` notification so the player isn't surprised.
- **Balance lever:** finite reserves are the natural throttle on "just leave 4
  dimensions running forever" — the player must keep *manufacturing* worlds, which
  is the intended treadmill for the bulk economy.

This supersedes any "infinite yield while powered" option.
