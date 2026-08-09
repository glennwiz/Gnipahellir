# mana_industry.md — gems are the fuel of the magic track (design agreed, NOT yet built)

**Status:** design agreed with Glenn 2026-08-09, the same day the Gem
Replicator shipped. Nothing implemented. This file is the full brief for the
**sink half of the gem economy** — a cold agent should be able to build it from
here without re-deriving anything.

**Companion docs:** `Steam_industry.md` (the two-track constraint and the rule
structs this fills in — read it first), `gem_industry.md` (the source half:
the Replicator, and the two-economy diagnosis), `context.md` (source of
truth), `CLAUDE.md` (architecture law).

**Obsoletes:** `draft1_machines.md` §1–§4's mana design (global mana pool,
capacitors, conduits, per-machine mana draw). Glenn chose the two-track model
over it explicitly — there is **no stored mana resource anywhere**. The vapour
is the mana. The Crystal Resonator idea ("eats gems for burst power") is
subsumed: the Magic Kettle *is* the resonator, load-bearing instead of bolted
on.

---

## 1. Why — the sink half was the bigger half

The Gem Replicator (built 2026-08-09) closed the *supply* hole: gems renew.
But the sinks were untouched — still a key ring of one-shot permanent
purchases. The day after the Replicator ships, surplus gems are dead weight
again: Diamond still has exactly one sink in the game, and a machine growing
diamonds every 10 minutes makes that *more* conspicuous, not less. A renewable
source needs ongoing demand on the other end or it is a faucet over a full cup.

**The answer: gems become the fuel of the magic track** — the second craft
track that S2/S3's architecture pre-shaped its tables for. This converts gems
from a key ring into a **flow economy, the same move that made wood work**.
Wood is healthy because every log faces a live choice: planks or fuel. With
this, every gem faces the same choice at higher stakes: **burn it** (power,
spent, renewable via the Replicator) **or keep it** (permanent upgrades —
miner tiers, golem slots, the existing sinks). The competing demand IS the
economy; Glenn's words about wood — "the competition is the point" — now apply
to gems.

**Perpetual-loop note, considered and accepted:** Replicator + kettle is a
self-feeding power loop (farm copies gems → gems burn → power). That is
precedent, not a bug — Tree Grower → logs → boiler fuel is the identical loop,
and lava-parked boilers already make free steam. The house style tolerates
infinite-but-slow; the burn/replicate ratio (§4) is the deliberate pressure
knob.

---

## 2. The decisions (Glenn's calls, 2026-08-09, in order)

1. **Mana = the magic track feeding the same `powered()` field.** One
   `Boiler_Rule` row (the Magic Kettle) + one `Engine_Rule` row (its engine)
   stamping the same `Power_State.charge`. Consumers stay ignorant — that is
   the whole two-track contract, and `tick_smelter` already has a test pinning
   it. A separate stored mana resource was offered and rejected.
2. **Sink choice: the gem-fired kettle only, for now.** Gem sockets on
   machines, vapour side-effects, and gem-tier gear were offered and NOT
   picked — parked in `ideas.md` (2026-08-09 entry), not designed here.
3. **All four gems burn, tiered burn times** (`miner_gem_tier` shape — cost
   mirrors reward). Not just Emerald: every gem gets a universal floor value.
4. **The Magic Kettle drinks Magic_Lava** as its source fluid, not Water. The
   deep magic-lava pools become a harvested resource. Magic-lava springs are
   buildable (the spring stencil allows all fluids — `springs = true` on
   Magic_Lava's rule row — and the Magic_Lava_Bucket shipped 2026-08-09), so
   the track is sitable anywhere after the same three-trip spring build water
   uses.
5. **The vapour ("Mana Mist") is harmless.** Steam scalds 2 dps; mana mist
   doesn't. Comfort is the luxury you pay gems for — you can live inside your
   own power plant. Zero-code differentiator (a `damage_per_second` of 0 in
   its terrain row).
6. **No free heat — the gem is the only ignition.** This resolves a real
   collision: `Steam_industry.md` penciled Magic_Lava as the magic kettle's
   free-heat tile, but with Magic_Lava as the *source* fluid, double-duty
   would mean one sited spring = infinite power with zero gems ever burned —
   the sink dies on the cheapest build. Ordinary-Lava free heat was also
   declined. **Track identity, stated as law:** steam is the thrifty track
   (cheap fuel, a free-heat shortcut, scalding vapour); magic is the luxury
   track (precious fuel, no shortcuts, kind mist).
7. **Burn ≈ ⅔ of the Replicator period**, so one farm *almost* feeds one
   kettle: a self-sufficient power block always wants one more farm or one
   better gem. That gap is where the pressure lives — tune it deliberately,
   never by accident.

---

## 3. The machines, against the shipped structs

All three rule structs exist and are `@(rodata)` tables (`sim.odin:51/75`,
`fluid.odin:59`). The magic track is table rows plus two small, named code
seams.

### The Magic Kettle — one `Boiler_Rule` row

```odin
// shipped shape: {tile, source, vapour, heat_tile, fuel_item, period, burn_time}
{.Magic_Kettle, .Magic_Lava, .Mana_Mist, /*heat*/ ???, /*fuel*/ ???, 2.0, ???},
```

Two seams keep this from being a pure row, both deliberate:

- **Seam 1 — no free heat.** `heat_tile` has no "none" value today, and the
  naive choices are traps: `.Air` or `.Void` would match `adjacent_tile_of`
  on nearly every placement and grant free heat always. Cleanest fix: make
  the heat check conditional — skip it when `heat_tile == .Air` (documented
  as "no free-heat tile for this track") or add a `has_free_heat: bool` to
  the struct with the steam row set true. Either way `tick_boiler` stays one
  proc; behaviour identical for both tracks except through table values.
- **Seam 2 — tiered fuel.** `fuel_item` is singular (wood). The magic kettle
  burns any of four gems with per-gem burn times, so its fuel becomes a small
  `#partial [Item]f32` burn-time table (`gem_burn_time`, sibling of
  `gem_replicate_time` — a nonzero row is also its is-fuel test) and
  `machine_autopull_fuel`/the burn clock consult it. The steam boiler's
  single-item path must be preserved untouched (wood's 8 s constant moves
  into the same table shape or stays a special case — implementer's call,
  but table-driven either way, no switch sprawl).

The kettle otherwise behaves exactly like the boiler, which is the point:
drinks one orthogonally adjacent Magic_Lava cell per puff (mass conserved via
`gravity_open_tile`), breathes a Mana_Mist cell above, idles consuming
NOTHING when capped, dry, or cold — so a rare gem committed to it is never
wasted while the vapour has nowhere to go. A 15-minute Diamond burn only
ticks while actual work happens (the boiler's `spread_timer` burn clock
already works this way).

### The engine — one `Engine_Rule` row

```odin
// shipped shape: {tile, vapour, period, reach, linger}
{.Mana_Wheel, .Mana_Mist, 1.0, 3, 3.0},
```

Same numbers as steam's engine to start — the tracks must reach capability
parity, and `powered()` consumers never learn which track fed them. Retune
only if playtest demands it.

### Mana Mist — one `Fluid_Rule` row + one terrain row

```odin
// shipped shape: {tile, period, rise, springs, lifetime}
{tile = .Mana_Mist, period = 1.0, rise = true, springs = false, lifetime = 20},
```

- `springs = false` is load-bearing exactly as it was for Steam: a springing
  gas is free infinite power. The `steam_is_never_a_spring` test's stencil
  approach generalises — pin it for Mana_Mist too.
- Terrain row: walkable, **`damage_per_second = 0`** (decision 5 — the whole
  luxury), its own wisp draw style in violet/white (Steam's atlas-less
  translucent drift is the reference; `station_glow`'s prismatic entry for
  the Replicator is the palette neighbour).
- Append `.Magic_Kettle`, `.Mana_Wheel`, `.Mana_Mist` to `Tile_Type` and the
  two machines to `Item` — append-only, ordinals are serialized. v24's
  `MAX_ITEM_SLOTS` ceiling (128, `len(Item)` currently 91) absorbs them; the
  probe test should still log **3,171,512**.

*(Names "Magic Kettle" / "Mana_Wheel" / "Mana Mist" are working names —
Glenn may rename at build time; nothing hangs on them.)*

---

## 4. Numbers (all knobs, all feel-tunable)

| Gem | Burns for | Replicator period | One farm feeds one kettle |
|---|---|---|---|
| Emerald | 120 s | 180 s | ~67% uptime |
| Jade | 240 s | 300 s | 80% |
| Diamond | 480 s | 600 s | 80% |
| Hel Gem | 900 s | 1200 s | 75% |

The ratio (decision 7) is the design: *almost* self-sufficient. All eight
numbers live in two `#partial [Item]f32` tables (`gem_burn_time` here,
`gem_replicate_time` shipped) — retuning is one number per row. Expect the
first playtest to move them.

---

## 5. Deliberately NOT designed here (decide at build time or later)

- **Recipes and unlock gates for the Kettle and Wheel.** Deliberately waiting
  for the Replicator's numbers to land in playtest first — the kettle's cost
  should sit relative to how hard gems actually are to farm. (Instinct, not
  decided: kettle at the Rune Altar like the Replicator; unlock on a gem or
  on Magic_Lava's first touch.)
- **Bespoke kettle/wheel pixel art** — they can launch on `station_glow` +
  icons like the boiler/engine did; the boiler's art pass is already owed.
- **Parked sinks** (offered 2026-08-09, not picked — live in `ideas.md`): gem
  sockets on every machine (the north star generalised — natural next step
  after this), vapour side-effects beyond harmlessness, gem-tier gear, gem
  conversion (judged mostly redundant post-Replicator: farming jade directly
  beats converting emeralds into it), gem dimensions (only earn their place
  if demand outgrows farms — and still blocked on enemy variety).
- **Sky Crystal / Aether_Ore's place in the gem family** — flagged, undecided.
  It replicates nowhere (the depth gate excludes sky) and burns nowhere (not
  in the fuel table). If the sky ever needs its own track, the two-track
  tables make it one row per struct — but that is a future conversation, not
  an omission here.

## 6. Build order

**Replicator playtest and retune first** (still owed — see `context.md`),
**then this as its own session.** Source before sink: the burn times in §4
only mean something once the replication periods have survived contact with
play. Verification at build time mirrors `Steam_industry.md` §S2/S3: build
green, tests green (kettle copies the boiler tests with magic literals, the
engine/`powered()` tests are track-agnostic already), probe unchanged, then
the in-game chain — magic-lava spring → kettle burning an emerald → capped
chamber → wheel → powered smelter, standing in the mist unhurt the whole time.
