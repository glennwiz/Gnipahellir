# Steam Industry — implementation spec

> **Status: BUILT 2026-08-08** — S1 gas sim `8ebaf11`, S2 Boiler `8290757`,
> S3 Engine/power `2d06506`, S4 swim `46c2754`. 238 tests green, no save bump.
> **Only the S5 hand playtest of the full loop is owed** (§12.3 below — it is
> the acceptance test, and "break the ceiling and watch the flywheel coast down"
> is the part to actually look at).
>
> Written 2026-08-08 by Opus from a design conversation with Glenn, then
> executed against it. **Kept, not archived** — §2 (the two-craft-track
> constraint) and §7.4 (`powered()` is the entire consumer API) are live law for
> every machine written from here on, and §11's pitfalls still apply. Read this
> before adding the magic track, a new gas, or any new powered machine.
>
> Read `context.md` first, as always.

---

## 1. Why

`fluid.odin` (2026-08-08) already does the hard part: water and lava are ordinary
terrain tiles that **move**, mass is conserved, and there is exactly one built
exception — the spring stencil — that is the only place fluid enters the world.

What the sim does not have is **consequence**. Water breaks your fall and does
nothing else. Lava burns. Nothing reacts with anything. The sim is a well-built
toy bolted to the side of the game.

Glenn's direction: *"fluids should be an important system, and we can also see a
future when we create gas."* Asked what "important" should mean, he chose
**industry** — fluids as the input to machines — with **steam as the first gas**.

### The idea that makes it worth building

**The terrain is the plumbing.** Steam is a gas tile that rises, pools under
whatever ceiling you leave it, and fades if it escapes. You do not craft pipes —
you *dig* them. A hole in your steam room is a real leak that costs you real
power. That turns "where you put your blocks" into an engineering problem, which
is precisely the automation arc `plan.md` points at.

It also gives three already-shipped things a job:

| Shipped | New job |
|---|---|
| The spring stencil (2026-08-08) | your renewable **water supply** |
| The Iron Bucket (2026-08-08) | how you move water/lava to where the boiler is |
| The Smelter | the first machine that runs on **power** |

### The loop, end to end

```
  spring  ──►  water  ──►  BOILER  ──►  vapour rises up the shaft you dug
  (built)                (+ fuel, or  ──►  pools under your ceiling
                          a hot cell)  ──►  ENGINE drinks it
                                         ──►  stamps power in a radius
                                         ──►  smelter runs 3× and burns no fuel
```

---

## 2. THE CONSTRAINT: two crafting tracks

Glenn, mid-review, and it shapes everything:

> *"We will have two craft tracks, magic and steam, both can achieve the same,
> so keep in mind that we might need to hook up magic machines with the same
> functionality just different looks but other effects but same production input
> and output."*

So **nothing here may be written as a bespoke Boiler proc or a bespoke Engine
proc.** Each machine is an **archetype driven by a rule table with one row per
track**, and the seam that matters is:

> ### `powered(gs, x, y) -> bool` is the entire consumer API.
> It reads one number. It knows nothing about steam, magic, vapours or engines.
> Every machine written from this day on gets **both tracks for free** by calling
> it. If you ever find yourself writing `if tile == .Steam_Engine` inside a
> consumer, you have broken the design.

**This session builds the steam track end to end and shapes the tables to hold
the magic track. No magic rows, no stubs, no dead content** (CLAUDE.md forbids
dead code). Landing the magic track later is then:

- 1 vapour row in `fluid_rules`
- 1 vapour row in `terrain_table` + `terrain_desc`
- 1 row in `boiler_rules`, 1 row in `engine_rules`
- 2 tile enums, 2 item enums, 2 recipes, 2 draw procs, 2 bag icons

**…and zero new logic.** That is the acceptance criterion for the abstraction.

Magic track shape, decided so the rule structs fit it (from the same
conversation): **same in, same out** — water in, power out, identical to steam —
differing only in what it burns (a gem/mana reagent instead of wood), what counts
as free heat (`Magic_Lava` instead of `Lava`), and what vapour it breathes out.

**Differing *effects* need no mechanism at all.** A vapour's effect on the player
is its `terrain_table` row: steam scalds through `damage_per_second`, which
`player_tile_hazard` (player.odin:186) already reads generically. Only an effect
no terrain flag can express (say, "drains mana") would cost anything — one new
`Terrain_Flag`, whenever that day comes. Do not build it speculatively.

---

## 3. Decisions locked

| # | Decision | Who | Why |
|---|---|---|---|
| 1 | **Gas dissipates over time** | Glenn | Otherwise a vented cave slowly fills its ceiling forever and gas becomes permanent litter. A steam cloud should be an event you wait out, not a mess you clean up. |
| 2 | **Springs must NOT apply to gas** | Opus | Load-bearing. A steam spring would be free infinite power and would delete the boiler from the game. `Fluid_Rule.springs = false` for every gas. |
| 3 | **No lava+water quench** | Glenn (twice) | Stays declined. The Boiler is the *only* vapour source, which keeps power an industrial good rather than something you trip over. (~15 lines of reaction table at the top of `fluid_step` whenever it's wanted.) |
| 4 | **Water slows you, no drowning** | Glenn | No breath meter this pass. Keeps the surface pond safe for early play. |
| 5 | **Water gets a swim stroke** | Opus | "No drowning" is only true if deep water isn't an inescapable pit. Without a repeatable stroke, water drowns you by geometry. |
| 6 | **Steam scalds (2 dps)** | Opus | Leaks must cost something or good plumbing isn't a skill. Costs no new code — one field in a terrain row. |
| 7 | **Powered smelter: 3× speed AND no fuel** | Opus | The reward mirrors the cost (a spring + boiler + engine is a real build). One constant to dial if it's too strong. |
| 8 | **No `SAVE_VERSION` bump** | Opus | See §9. Verify this holds before committing. |

---

## 4. Part 1 — generalize the fluid sim for gas (`src/fluid.odin`)

The sim hardcodes exactly one assumption: **down**. A gas is the same sim
mirrored. This is the smallest part of the change and the one that unlocks
everything else.

### 4.1 `Fluid_Rule` grows three fields

```odin
Fluid_Rule :: struct {
	tile:     Tile_Type,
	period:   f32,  // seconds between flow steps — one tile per period
	rise:     bool, // gas: "down" is -y
	springs:  bool, // may the spring stencil fire for this fluid?  (decision #2)
	lifetime: f32,  // 0 = forever; >0 = seconds before a cell fades to open
}

@(rodata)
fluid_rules := [?]Fluid_Rule {
	{.Water,      1.0, rise = false, springs = true,  lifetime = 0},
	{.Lava,       3.0, rise = false, springs = true,  lifetime = 0},
	{.Magic_Lava, 3.0, rise = false, springs = true,  lifetime = 0},
	{.Steam,      0.25, rise = true, springs = false, lifetime = 20.0},
}
```

Steam is fast (gas is light) and lives 20 s — long enough to cross a real steam
room, short enough that a leak visibly bleeds you dry.

> **Do not reorder existing rows.** `Fluid_State.timers`/`flip` are indexed by
> rule position. They're transient so it isn't a save hazard, but tests index
> them.

### 4.2 The `dy` substitution

`fluid_step` currently takes `(gs, fluid, flip)`. **Pass the whole `Fluid_Rule`
instead** — it needs `rise`, `springs` and `lifetime` now.

Inside, take `dy := rule.rise ? -1 : +1` and substitute mechanically:

| Today | Becomes | Note |
|---|---|---|
| `fluid_open(w, x, y+1)` (fall rule) | `y+dy` | |
| `fluid_open(w, x±dir, y+1)` (diagonal) | `y+dy` | side cell check unchanged — it's the seam guard |
| `get_tile(w, x, y-1) != fluid` (pressure) | `y-dy` | "buried under more of its own kind" |
| `fluid_drop_distance`'s `fluid_open(w, cx, y+1)` | `y+dy` | pass `dy` in |
| `fluid_is_spring`'s `y+1` cells | `y+dy` | mirrored stencil; gated off anyway |
| `for y := GRID_H-1; y >= 0; y -= 1` | **top-down when `rise`** | see below |

**The scan direction is not cosmetic.** Rows are walked so that a cell which
moves lands in a row the scan has *already finished*, and therefore cannot move
twice in one step. For a falling liquid that means bottom-up. For a rising gas it
means **top-down**. Flip the loop bounds off `rule.rise`. The `moved` bitmap
still catches the sideways case, which is the only move that can land in a cell
the scan has yet to reach.

### 4.3 Gate the spring

```odin
if rule.springs && fluid_is_spring(w, x, y, fluid, dy) {
    ...
}
```

That `rule.springs &&` is decision #2. **It is the most important line in the
change.** Write the test for it (§8, `steam_is_never_a_spring`) first.

### 4.4 Dissipation

Gas cells need an age, and there is nowhere per-cell to put one — fluid positions
live in the terrain array. Add a transient array to `Fluid_State`:

```odin
Fluid_State :: struct {
	timers: [len(fluid_rules)]f32,
	flip:   [len(fluid_rules)]bool,
	age:    [GRID_W * GRID_H]u8, // gas only: flow steps this cell has existed
}
```

- Counted in **steps, not seconds** — `u8` (20 KB), and `life_steps :=
  int(rule.lifetime / rule.period)` = 80 for steam, comfortably under 255.
- Each step, a gas cell increments its age; at `life_steps` it becomes
  `gravity_open_tile(gs, y)` (gravity.odin:65 — `.Air` above the surface line and
  in the sky, `.Void` underground) instead of moving.
- `fluid_move` **carries the age to the destination** cell and clears the source.
- A newly-boiled cell sets `age = 0`.

**Known limit to document in the file header:** `Fluid_State` is transient, so a
save/load resets every age and loaded vapour lives one extra lifetime. Purely
cosmetic; not worth a save bump.

### 4.5 What comes free

The diagonal seam guard, the drop-distance search, the buried-under-your-own-fluid
pressure rule, `fluid_move`'s use of `gravity_open_tile`, the alternating
left/right bias — all mirror with no further work. That is the whole reason this
part is cheap.

---

## 5. Part 2 — the `Steam` tile

**`src/types.odin`** — append to `Tile_Type` (ordinals are serialized; append
only, never reorder):

```odin
    // Steam industry (appended: terrain ordinals are serialized)
    Steam,
    Boiler,
    Steam_Engine,
```

and to `Item`:

```odin
    // Steam industry (appended: item ordinals are serialized)
    Boiler,
    Steam_Engine,
```

**`src/world.odin`** — `terrain_table` row (field order is
`name, flags, color, move_cost, damage_per_second, drop_item, drop_pct`):

```odin
	.Steam = {
		"Steam",
		{.Walkable, .Damaging},
		rl.Color{225, 228, 235, 110},
		1,
		2,        // scalds — decision #6; player_tile_hazard reads this generically
		.None,
		0,
	},
```

**This row is where a track's vapour effect lives.** The magic vapour differs by
editing nothing but its own row.

Plus `terrain_desc` (note: a concurrent session owns that table — match its
voice, don't restructure it):

```odin
	.Steam = "Scalding vapour. It rises, it leaks, and it fades - cap your chamber or lose your pressure.",
```

> Text is drawn with raylib's ASCII-only default font. **No em-dashes in string
> literals** — they render as `?`. Use `-`. (See context.md, 2026-08-02.)

Boiler and Engine also need `terrain_table` rows (`{.Solid, .Mineable}`, dropping
their own item) and both go into **`is_structure_tile`** (world.odin:541) — that
one table already gates wands away from machines, routes ordinary clicks to
interaction, and enables the deliberate Shift+hold pick reclaim.

**`src/assets.odin`** — `tile_sprite` (line 84): **do not route `.Steam` through
the atlas.** `.Water` is already deliberately excluded because its atlas cell is
unpainted (alpha ≈ 6/255) — that bug cost a session once. Falling through to the
flat terrain colour is correct here.

**`src/render.odin`** — draw steam semi-transparent with a slow per-cell hashed
drift so a body of vapour shimmers rather than sitting as a flat block. New
`Draw_Style` entries `Pixel_Steam`, `Pixel_Boiler`, `Pixel_Steam_Engine` in the
enum + `tile_draw_style` table + the draw switch (render.odin:548 area).

---

## 6. Part 3 — the Boiler archetype (`src/sim.odin`)

**One** `tick_boiler` registered in `tile_on_tick`, modelled on `tick_smelter`
(sim.odin:82), driven by a row looked up from its own tile.

```odin
// One row per craft track.  Same shape in, same shape out; a track varies only
// in what it burns, what counts as free heat, and what vapour it breathes out.
// Adding the magic track = adding a row here.  No logic changes.
Boiler_Rule :: struct {
    tile:      Tile_Type, // .Boiler        (magic: its own kettle tile)
    source:    Tile_Type, // .Water         — the fluid it drinks
    vapour:    Tile_Type, // .Steam         — the gas it emits upward
    heat_tile: Tile_Type, // .Lava          — adjacent cell that needs no fuel
    fuel_item: Item,      // .Wood_Log      (magic: a gem / mana reagent)
    period:    f32,       // seconds per puff
    burn_time: f32,       // seconds one fuel unit lasts
}

@(rodata)
boiler_rules := [?]Boiler_Rule{
    {.Boiler, .Water, .Steam, .Lava, .Wood_Log, 2.0, 8.0},
}

boiler_rule_for :: proc(t: Tile_Type) -> (Boiler_Rule, bool) {
    for r in boiler_rules do if r.tile == t do return r, true
    return {}, false
}
```

### Behaviour (identical for both tracks — that's the point)

1. **Fluid.** Consume one orthogonally adjacent `source` cell per puff, opening it
   via `gravity_open_tile`. With a spring feeding it, sustainable; without, finite.
   *This is what turns the spring into an industrial asset.*
2. **Heat.** Either `fuel_count` of `fuel_item`, **or** an adjacent `heat_tile`
   cell, which needs no fuel at all. One fuel unit burns for `burn_time` (8 s),
   tracked in the existing `spread_timer`.
   - Reuse the feeding pattern from `smelter_autopull` (sim.odin:142) so an
     adjacent pile stokes it hands-off. **Extract its fuel branch** into a shared
     `machine_autopull_fuel(gs, x, y, sd, item, cap)` and have both call it —
     do not copy-paste it.
3. **Output.** One `vapour` cell in the open tile above, every `period` (2 s),
   tracked in `growth_timer`, with `fluid.age[idx] = 0`. Blocked above → idle,
   consuming nothing. **Self-regulating in exactly the way the spring is**, and
   for the same reason: the mouth must be open.

### Recipe (`src/crafting.odin`)

```odin
    { .Boiler, 1, .Bench, {{.Iron_Bar, 4}, {.Stone_Block, 6}, {}} },
```
```odin
    .Boiler = .Iron_Bar,   // in recipe_unlock
```

Append to `recipe_table` — **several tests index recipes by position**; appending
keeps them stable. Give it an `Item_Info.desc` that teaches the build, the way
the Iron Bucket's card teaches the spring.

### Art

`Pixel_Boiler`: riveted iron kettle, chimney stub, sight-glass showing the water,
firebox glowing while `spread_timer > 0`. Follow `pixel_style.md`.

---

## 7. Part 4 — the Engine archetype and power

### 7.1 Power is live, not stored

```odin
// Transient — power is a live thing, not saved progress.  Same pattern as
// Fluid_State and golem_grace.  An engine re-establishes it within one tick of
// a load, so there is nothing worth persisting.
Power_State :: struct {
    charge: [GRID_W * GRID_H]f32, // seconds of powered time left, per cell
}
```

on `Game_State` as `power: Power_State`. 83 KB against a ~3 MB `World_Grid` —
irrelevant, and it keeps the save format untouched (§9).

### 7.2 The engine rule

```odin
Engine_Rule :: struct {
    tile:   Tile_Type, // .Steam_Engine  (magic: its own wheel tile)
    vapour: Tile_Type, // .Steam         — what it drinks
    period: f32,       // seconds per vapour cell consumed
    reach:  int,       // chebyshev radius it powers
    linger: f32,       // seconds a stamp survives without fresh vapour
}

@(rodata)
engine_rules := [?]Engine_Rule{
    {.Steam_Engine, .Steam, 1.0, 3, 3.0},
}
```

`tick_engine`: every `period`, consume one adjacent `vapour` cell (open it via
`gravity_open_tile`); on success stamp `charge = linger` on every cell within
`reach` (Chebyshev). No vapour → no stamp → the flywheel coasts down and stops.

### 7.3 The decay step

`update_power` decays every cell by `dt`, clamped at 0. New **numbered step 5b0**
in `game_update` (update.odin), immediately *before* `update_sim`:

```
5b0. power decay — ages engine stamps (writes Power_State only)
5b.  sim (smelters/growers/boilers/engines)
```

The `linger` is what makes consumers independent of grid scan order: a smelter
that ticks before its engine still reads last frame's stamp.

### 7.4 The one consumer API

```odin
// Is this cell inside a running engine's field?  Deliberately says NOTHING about
// which craft track powered it — that is the whole two-track contract.
powered :: proc(gs: ^Game_State, x, y: int) -> bool {
    return gs.power.charge[grid_idx(x, y)] > 0
}
```

### 7.5 Teaching the smelter to use it

Two edits inside `tick_smelter` (sim.odin:82), no restructuring:

- the `int(sd.fuel_count) < FUEL_PER_BAR` gate (line 94) is skipped when
  `powered(gs, x, y)`, and the `sd.fuel_count -= u8(FUEL_PER_BAR)` at line 119
  likewise;
- `SMELT_TIME` becomes `SMELT_TIME / POWERED_SPEEDUP` (3) while powered.

That's the reward: **your smelter stops eating wood and runs three times as
fast.** Cost mirrors reward — you paid a spring, a boiler and an engine for it.

### 7.6 Recipe and art

```odin
    { .Steam_Engine, 1, .Forge, {{.Iron_Bar, 10}, {.Silver_Bar, 2}, {}} },
```
```odin
    .Steam_Engine = .Silver_Bar,   // in recipe_unlock — a real mid-game gate
```

`Pixel_Steam_Engine`: brass flywheel that **spins while powered** — the only
read-only tell the player needs to know the machine is running — plus piston rod
and iron frame.

---

## 8. Part 5 — water slows you (`src/player.odin`)

`player_in_water(gs)` already exists (player.odin:169) and already breaks fall
damage (player.odin:93). In the non-flying branch of `update_player`:

```odin
WATER_DRAG   :: f32(0.5)   // horizontal speed multiplier while submerged
WATER_SINK   :: f32(0.35)  // gravity multiplier — you sink slowly
WATER_STROKE :: f32(0.55)  // swim-stroke height, as a fraction of JUMP_VEL
```

- `speed *= WATER_DRAG`
- pass `GRAVITY * WATER_SINK` and a reduced `MAX_FALL_SPEED` into `move_body`
- **`inp.jump` while submerged sets `vel.y = JUMP_VEL * WATER_STROKE` without
  requiring `p.grounded`** — the repeatable stroke that keeps deep water
  survivable (decision #5)

No breath meter, no drowning. Choke damp would plug into a breath system later;
it is not built.

---

## 9. Save compatibility — expect NO version bump

Verify this holds before committing; if it doesn't, bump `SAVE_VERSION` **and**
the size `#assert` in the same commit, per architecture law.

| Change | Save impact |
|---|---|
| `Tile_Type` / `Item` appends | **None.** Enum growth doesn't change `Save_Data` layout (same precedent as `Sand`, 2026-08-07). |
| `Fluid_State.age` | **None.** `Fluid_State` is transient. |
| `Power_State` | **None.** Transient by design (§7.1). |
| `Boiler`/`Engine` runtime data | **None.** Reuses `Sim_Tile_Data`'s existing `growth_timer` (puff/consume clock), `spread_timer` (burn clock) and `fuel_count`. **Do not add a field to `Sim_Tile_Data`** — it lives in `World_Grid.sim_data`, which is saved wholesale, so one field there *does* force a bump to v25. |
| New `Fluid_Rule` row | **None.** Fluid positions live in the terrain array, saved wholesale. |

`save_data_size_probe` should still log **3,171,512**. *(Corrected 2026-08-08:
this doc was written just before the Scroll of Waters commit bumped the save to
v24 / 3,171,512. The no-bump conclusion stands; the numbers moved.)*

---

## 10. Tests (`src/tests.odin`)

230 exist today (was 223 when this doc was drafted). Write these eight. **Write them against `boiler_rule_for` /
`engine_rules` / `powered()`, never against `.Boiler` or `.Steam_Engine`
literals** — then the magic track is covered by the same tests the day it lands.

| Test | Asserts |
|---|---|
| `steam_rises_and_pools_under_a_ceiling` | steam placed low ends up flush against the ceiling, flat, and settles (grid bit-identical over the last N steps) |
| `steam_dissipates_and_leaves_air` | a sealed steam cell is gone after `lifetime`, and the cell it leaves matches `gravity_open_tile` |
| `steam_is_never_a_spring` | build the exact `S W W W S` / `S S V S S` stencil **in steam**; assert the grid is unchanged after many steps. **Decision #2's guard rail.** |
| `a_boiler_turns_water_and_fuel_into_steam` | source water cell gone, vapour above, fuel spent, `age == 0` |
| `a_hot_cell_under_a_boiler_needs_no_fuel` | with `heat_tile` adjacent and zero `fuel_count`, it still puffs |
| `a_capped_boiler_idles` | ceiling blocked → no water consumed, no fuel consumed |
| `an_engine_powers_a_smelter` | same fixture ±engine: powered smelter casts ~3× the bars and consumes **zero** fuel; cut the vapour and it reverts within `linger` |
| `water_slows_the_player_and_lets_them_swim_out` | the same held-right input covers less ground submerged than dry; a body dropped in a 6-deep pool climbs out on repeated strokes |

**Regression watch:** the four existing fluid tests — especially
`a_settled_pond_never_churns` (whole grid bit-identical after 600 steps) and
`the_natural_pond_is_not_a_spring`. Their `for _ in 0 ..< N do update_fluid`
counts are calibrated to the current periods; adding a fourth rule doesn't change
them, but re-check if any period is retuned.

---

## 11. Pitfalls

1. **The scan direction.** Bottom-up for liquids, top-down for gases (§4.2). Get
   it wrong and a gas cell rises several tiles per step, which looks like a bug in
   the timing rather than in the loop.
2. **`rule.springs`.** Forgetting it makes steam farmable and silently deletes the
   entire boiler economy. Test it first.
3. **Do not add a field to `Sim_Tile_Data`** (§9). It's the one change here that
   forces a save bump.
4. **`.Water`'s atlas exclusion** (assets.odin:100) exists because that cell is
   unpainted. Steam needs the same treatment. Don't "fix" it by adding an atlas
   entry.
5. **Indentation is mixed per file.** `fluid.odin` and `world.odin` use tabs;
   `sim.odin`, `player.odin` and `crafting.odin` use 4 spaces. Match the file
   you're in (CLAUDE.md rule 3).
6. **Append recipes**, don't insert — several tests index `recipe_table` by
   position.
7. **No em-dashes in drawn strings** (ASCII-only font).
8. ~~The worktree is dirty with a concurrent session's work.~~ **Stale** — that
   work is committed as of 2026-08-08; build on clean master.
9. **Render stays read-only.** The flywheel's spin must be derived from
   `powered()` at draw time, not from a counter a draw proc increments.

---

## 12. Verification

1. `odin build src` green; `odin test src -all-packages` — 230 existing plus the
   eight new.
2. **Track-agnosticism check, before committing:** read `tick_smelter` and
   confirm it contains no vapour, engine or track reference — only `powered()`.
   If it doesn't, the magic track will cost logic later, and the whole point of
   §2 is lost.
3. **Play the loop.** This is the real acceptance test — *none* of the
   2026-08-08 fluid work has been eyeballed in-game yet:
   - F1 → give Iron/Silver Bars; craft a Boiler and a Steam Engine.
   - Build a water spring (`S W W W S` over `S S V S S`); let it fill a basin.
   - Boiler beside the water, wood pile next to it → steam puffs and rises.
   - Cap a chamber above, Engine in the pooled steam, Smelter within 3 tiles →
     flywheel spins, smelter runs fast on no wood.
   - **Then break the ceiling.** Steam vents, fades, the flywheel coasts down, the
     smelter falls back to wood. *That failure mode is the mechanic.* If it
     doesn't read clearly, tune `lifetime` and `linger` — they are the two knobs.
   - Swim the surface pond: sluggish, sinks slowly, strokes out.
4. Update `context.md` (header bullet, §4, §5 fluid follow-ups) and record the
   two-track constraint so the next session doesn't re-derive it.

---

## 12b. Known limits found reviewing the shipped code (2026-08-08)

None of these fail a test; all three are things a player will meet. Recorded so
the S5 playtest knows what to look at, not filed as bugs.

1. **A lava-heated boiler still hoards wood.** `tick_boiler` calls
   `machine_autopull_fuel` (sim.odin:266) *before* the free-heat check
   (sim.odin:280), so a kettle sitting on lava vacuums an adjacent wood pile it
   will never burn. Nothing is lost — mining it spills the hopper
   (events.odin:560) — but it will read as the boiler eating your fuel for
   nothing. One-line fix if it annoys: skip the autopull when a `heat_tile` is
   adjacent. Left alone because a boiler that *loses* its lava then has fuel
   ready, which is arguably the better behaviour.
2. **Power passes through walls.** `tick_engine` stamps a plain `reach` square
   with no line-of-sight test, so an engine powers a smelter on the far side of
   solid rock. Fine and legible as "a field", but it means you cannot wall a
   machine off from a running engine. Decide at playtest whether that should
   cost anything.
3. **Steam blocks water.** `fluid_open` counts only `.Air`/`.Void` as open, so a
   pooled steam cloud is a floor to falling water — a boiler under a basin can
   hold its own supply up. Consistent with fluids never displacing each other
   (water can't enter lava either), and it makes a capped steam chamber
   genuinely sealed, so it may well be a feature. Watch it in the loop.

---

## 13. Deliberately NOT built

- **The magic track itself.** Tables shaped for it; no rows, no stubs.
- **Lava + water → Stone (quench).** Declined twice.
- **Crafted pipes / pumps.** The dug terrain *is* the plumbing — that's the point.
- **Drowning / breath meter.** Glenn's call.
- **Firedamp, choke damp, smoke.** Each is one `Fluid_Rule` row; none is built.
- **Vapour pressure levels.** A cell is a cell; per-cell fill stays declined.
- **Fluid in unloaded levels.** Still frozen (existing fluid follow-up #3).
- **Sound.** Fluid has no audio at all; the boiler and engine both want it.
