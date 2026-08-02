# upgrade_system.md — Wand & Gear Upgrade System (design plan)

> **Status:** design only, nothing built. Target: the mining wand as the first
> upgradable item. Written 2026-08-02. Read `context.md` first; this plan obeys
> the architecture law in `CLAUDE.md`.

## 1. The goal (Glenn's pitch)

A crafting-style GUI where you **drag a wand into a slot, drag a gemstone into
a second slot, click UPGRADE**, and the wand comes out improved:

- **+1 mine range** per upgrade, up to **+9**
- **+1 blast radius** per upgrade, up to **+9** (the ultra-wand's 3×3 dig, earned)
- a **special stone → auto-pickup** (mined drops home straight to the bag)
- room to grow: mana-cost reduction, cooldown, etc. later

Same machine should generalize to gear (sword +damage, armor +defense) later,
but **the wand is the target for v1** — build it narrow, prove the pattern.

---

## 2. The core problem: items have no per-instance data

This is THE decision the whole system turns on. Today:

```odin
Inventory_Slot :: struct { item: Item, count: int }   // game_state.odin
```

An item is a **bare enum value**. Every `.Mine_Wand_Gold` is byte-identical to
every other — they stack, they're interchangeable, there is nowhere to hang "+3
range" on a *specific* wand. The equipped weapon is likewise just
`p.equipment[.Weapon]: Item` — one enum, no payload.

There are two honest ways out:

### Option A — per-instance item data (rejected for v1)

Give items an identity: `Inventory_Slot :: { item, count, instance: u16 }` plus
a side-table of upgrade records indexed by instance id. This is the "proper"
RPG model (every wand is its own object with its own upgrades).

**Cost:** it breaks stacking, touches every inventory op (`inventory_insert`,
`_remove`, `_count`, save format, smelter feed, ground items, silo), and adds an
allocation/lifetime problem the fat-struct/fixed-array rules push back on. Weeks
of blast radius for a one-wand feature. **Not v1.**

### Option B — upgrades keyed by wand *type*, on the fat struct (RECOMMENDED)

Because wands are **non-stacking, one-per-tier tools** and the player realistically
carries **one of each tier**, treat the upgrade as a property of *"your Gold
Wand"* the category, not a specific copy. Store a small fixed table on
`Progression_State`:

```odin
Wand_Upgrade :: struct {
    range:       u8,    // +0 .. +UPGRADE_MAX
    radius:      u8,    // +0 .. +UPGRADE_MAX  (0 = single tile, N = (2N+1)² blast)
    auto_pickup: bool,  // special stone, one-shot unlock
}

// in Progression_State (game_state.odin), saved with the rest:
wand_upgrade: [Item]Wand_Upgrade,   // only the .Mine_Wand* rows ever used
```

- **Fits the enum-item model perfectly** — no per-instance identity needed.
- **Fixed size, no allocation** — `[Item]` is a static array; obeys the law.
- **Saved trivially** — it's plain data in `Progression_State`; bump
  `SAVE_VERSION`, add the `#assert` on `size_of(Save_Data)`.
- **Table-driven read** — mining looks up `gs.progression.wand_upgrade[wand]`.

**The one behavioral wrinkle to accept out loud:** upgrades attach to the *tier*,
so if you somehow held two Gold Wands they'd share the buff. For this game that's
a non-issue (wands don't stack meaningfully and you craft one per tier). Note it,
move on. If per-instance ever matters, Option A is the migration — this table
becomes the "instance 0" default.

> **Recommendation: Option B.** Everything below assumes it.

---

## 3. Upgrade axes & caps

```odin
UPGRADE_MAX :: 9   // +9 ceiling on range and radius
```

| Axis          | Effect                                              | Cap  | Read at |
|---------------|-----------------------------------------------------|------|---------|
| `range`       | `+1` tile of mining reach per level                 | +9   | `player_mine` (mining.odin) |
| `radius`      | blast dig: impact takes a `(2r+1)²` square          | +9   | `update_mining` (mining.odin) |
| `auto_pickup` | mined drops home to the bag instead of ground stack | bool | `handle_tile_mined` (events.odin) |

Effective range becomes:

```odin
wrange := wand_mine_range[wand] + i32(gs.progression.wand_upgrade[wand].range)
```

`radius` reuses the **exact machinery the ultra-wand cheat already has** — the
`blast` path in `update_mining` that loops a 3×3 and pushes `Tile_Mined` per
cell. Generalize its hardcoded `-1..=1` to `-r..=r`. That code is proven; we're
just wiring a data-driven `r` into it instead of a debug flag.

`auto_pickup` piggybacks on the **existing collect-mote/home-to-player** system
(`spawn_collect_mote`, `Particle.homing`) already used by the shaft-apron dirt
reward — when set, a `Tile_Mined` drop banks to the bag with a homing mote
instead of spawning a ground stack.

---

## 4. What feeds the upgrades (the gem economy)

Glenn: "drag a gemstone in." The game already has four gems with a natural power
ladder (from the Auto-Miner tiers): **Emerald < Jade < Diamond < Hel_Gem**, plus
sky mats (Cloud_Stone, Aether_Crystal, Runic_Sky_Ore).

Two ways to map gems → upgrades — **pick one, this is a Glenn decision:**

**Mapping 1 — one gem type per axis (simple, legible)** ← recommended
- **Emerald → +1 range** (common gem, the workhorse upgrade)
- **Diamond → +1 radius** (rarer, the powerful one)
- **Aether_Crystal → auto-pickup** (the "special stone," one-time)
- higher gems reserved for future axes (Hel_Gem → mana cost, etc.)

Each click consumes **1 gem**. The *type* of gem you drop decides which axis goes
up — no mode selector needed, the slot content is the choice. Clean, teaches
itself, matches "drag a gemstone in and click upgrade."

**Mapping 2 — escalating cost per level, any-gem-with-a-mode**
A UI toggle picks the axis; cost scales with current level (e.g. level→level+1
costs `level+1` gems, or steps Emerald→Jade→Diamond as you climb). More
grind-tunable, more UI. Heavier. Only reach for this if +9 feels too cheap in
playtest — **start with Mapping 1 and a flat 1-gem cost, tune later.**

> **Design north star check** (`context.md` §1: *cost mirrors reward*): range is
> cheap/common (Emerald), the big 3×3 dig is expensive/rare (Diamond),
> auto-pickup is a sky-material luxury. That reads right.

---

## 5. The GUI (the upgrade station)

### Where it lives — new station vs. existing

The drag-two-things-in-and-click pattern already exists twice (old anvil, current
smelter window). Cleanest fit is a **new station** so the wand-upgrade window is
its own thing, opened by interacting with a placed tile — same plumbing as the
Bench/Forge/Smelter.

Options for the station:
1. **New `Anvil` / `Runecarver` station tile** (recommended) — crafted early
   (a few Iron Bars at the Bench), unlocked around when you get your first wand.
   Add `.Anvil` to the `Station` enum (append-only), a tile + item + `draw_pixel_*`,
   a recipe row. Dedicated, discoverable, thematically "where you enchant gear."
2. **Fold into the Rune Altar** — thematically magical, but it's tier-3/late; wand
   upgrades want to start early. Rejected for gating reasons.
3. **Fold into the Dvergr Forge** — plausible (dwarven smithing), saves a tile.
   Acceptable fallback if we don't want a new station; the window would be a
   second tab/mode on the Forge. Slightly muddier UX.

> **Recommendation: new `Anvil` station.** Its own window, opened via a new
> `Anvil_Interact` event (mirror `Station_Interact`/`Smelter_Interact`).

### The window layout (`draw_upgrade` in ui.odin, read-only)

Reuse the Norse panel chrome + the smelter window's drag idiom:

```
┌─ THE ANVIL ───────────────────────────┐
│                                        │
│   ┌──────┐        ┌──────┐             │
│   │ WAND │   +    │ GEM  │             │   ← two drop slots
│   └──────┘        └──────┘             │
│                                        │
│   Gold Mine Wand                       │
│   Range   ██████░░░  +6 / +9           │   ← current upgrade bars
│   Radius  ██░░░░░░░  +2 / +9           │
│   Pickup  ● auto                       │
│                                        │
│   Emerald → +1 Range                   │   ← what the loaded gem will do
│                                        │
│        ┌─────────────────┐             │
│        │    UPGRADE       │  (pulses)  │   ← greys w/ reason when invalid
│        └─────────────────┘             │
└────────────────────────────────────────┘
```

**Drag model** (reuse `UI_State.drag_item`/`drag_slot`/`drag_tray` — already
built for the smelter): drag the wand from the bag onto the WAND slot, drag a gem
onto the GEM slot. Slots hold a reference (bag slot index), not a copy — nothing
leaves the bag until UPGRADE is clicked. UPGRADE button hit-test like
`craft_button_hovered`.

New `UI_State` fields (transient, not saved):
```odin
show_anvil:     bool,
anvil_tile:     [2]i32,   // which anvil we're at (mirrors smelter_tile)
anvil_wand:     Item,     // wand loaded into the slot (.None = empty)
anvil_gem:      Item,     // gem loaded into the slot (.None = empty)
```

UPGRADE greys with a reason (like the CRAFT button): "load a wand" / "load a
gem" / "already maxed" / "that gem does nothing here".

---

## 6. Data & control flow (obeys event-driven law)

1. **Input** (`input.odin`): clicking UPGRADE pushes `Event{type = .Wand_Upgrade}`
   with the loaded wand+gem in the payload. Dragging onto a slot toggles
   `ui.anvil_wand`/`anvil_gem` (UI state — the deliberate input exemption, same
   as inventory selection). Input never mutates `Progression_State`.
2. **Handler** (`events.odin` `handle_*`): `apply_wand_upgrade(gs, wand, gem)` —
   - validate: gem maps to an axis, axis not at cap, player still owns 1 gem;
   - `inventory_remove(gem, 1)`;
   - bump `gs.progression.wand_upgrade[wand].{range|radius}` or set `auto_pickup`;
   - `gs.save_dirty = true`; `notify` + `log_action`; play a sound.
3. **Read paths** (sim/render, read-only):
   - `player_mine` adds the range bonus (§3);
   - `update_mining` uses `radius` for the blast loop;
   - `handle_tile_mined` checks `auto_pickup` to bank vs. drop;
   - `draw_upgrade` reads the table to fill the bars.

`apply_wand_upgrade` lives in a new **`upgrade.odin`** (item/sim logic — never
calls `draw_*` or input). The `draw_upgrade` proc lives in `ui.odin`.

### Update order

No new `game_update` step needed — upgrading is event-driven (fires on click,
handled in step 6 `process_events`). Only the read sites change. Keeps the
deterministic order untouched.

---

## 7. Save version

`Progression_State` gains `wand_upgrade: [Item]Wand_Upgrade`. Per the law
(enums/saved structs): **bump `SAVE_VERSION` 16 → 17**, update the
`size_of(Save_Data)` `#assert` in the **same commit**, keep a `.v16.bak`. Old
saves reset (accepted convention here). The size probe test logs the real size.

---

## 8. File-by-file change list

| File | Change |
|------|--------|
| `types.odin` | `UPGRADE_MAX :: 9`; append `Wand_Upgrade` note near `Stat`; new `Event_Type.Wand_Upgrade`; append `Anvil` to nothing here (Station is in crafting.odin) |
| `game_state.odin` | `Wand_Upgrade` struct; `wand_upgrade: [Item]Wand_Upgrade` on `Progression_State`; `show_anvil`/`anvil_tile`/`anvil_wand`/`anvil_gem` on `UI_State` |
| `crafting.odin` | append `.Anvil` to `Station` enum; Anvil recipe row (Iron Bars @ Bench); unlock keyed to the wand |
| `items.odin` | `Anvil` item + `item_table` row + `place_tile` |
| `world.odin` | `Anvil` tile row in `terrain_table` (solid, non-mineable station like Bench) |
| `upgrade.odin` *(new)* | `wand_upgrade_axis(gem)->{axis,ok}`, `apply_wand_upgrade`, cap checks, the gem→axis table |
| `mining.odin` | range read adds `.range`; blast loop generalized to `radius` |
| `events.odin` | `Anvil_Interact` opens the window; `Wand_Upgrade` handler; `handle_tile_mined` honors `auto_pickup` |
| `input.odin` | UPGRADE click → event; slot drag → `ui.anvil_*`; open/close window |
| `ui.odin` | `draw_upgrade` window + hit-testers (`anvil_slot_at_cursor`, `upgrade_button_hovered`) |
| `render.odin` | `draw_pixel_anvil` tile art; wand icon may show upgrade pips |
| `save.odin` | `SAVE_VERSION` 16→17; size `#assert` |
| `tests.odin` | see §9 |

Roughly the shape of the recipe-unlock + smelter-feed work already shipped —
this is a known-sized slice, not a new subsystem.

---

## 9. Verification (goal-driven, per CLAUDE.md §4)

Headless tests in `tests.odin`:

1. `wand_upgrade_extends_range` — +N range makes `player_mine` fire at
   `base+N` tiles and refuse at `base+N+1`. (Mirror existing
   `wand_tiers_extend_reach`.)
2. `wand_upgrade_caps_at_max` — 10 range upgrades leaves `.range == 9`.
3. `wand_upgrade_consumes_gem` — one Emerald leaves the bag per +1; a failed/capped
   upgrade consumes nothing.
4. `wand_radius_blasts_area` — radius 1 mines a 3×3 on impact (reuse the ultra
   blast test's assertions).
5. `wand_auto_pickup_banks_drop` — with auto-pickup, `Tile_Mined` puts the drop in
   the bag, not a ground stack.
6. `save_roundtrips_wand_upgrade` — set upgrades, save, load, assert equal (and
   the size `#assert` compiles).

Loop: `odin run src` builds, `odin test src` green, then a hand playtest —
craft the Anvil, upgrade a wand to +9 range, watch the reach grow; load a Diamond,
confirm the 3×3 dig; Aether_Crystal → drops fly to the bag.

---

## 10. Open decisions for Glenn (pick before build)

1. **Data model — Option B (per-type table)?** Recommended. Option A (per-instance)
   only if you want two differently-upgraded wands of the same tier to coexist.
2. **Gem mapping — Mapping 1 (one gem per axis)?** Recommended.
   Emerald=range, Diamond=radius, Aether_Crystal=auto-pickup. Or Mapping 2
   (mode toggle + scaling cost) if flat cost feels too cheap.
3. **Station — new `Anvil` tile?** Recommended. Or fold into the Dvergr Forge to
   avoid a new tile.
4. **Cost curve — flat 1 gem/level for v1?** Recommended (tune after playtest).
   Escalating cost is a later dial.
5. **Scope — wand only for v1?** Recommended. Gear (sword/armor) upgrades reuse the
   same table shape (`[Item][Stat]u8` bonus) once the wand loop feels good.

---

## 11. Phased build order

1. **Data + read** — add `Wand_Upgrade` table, wire range/radius/auto-pickup read
   sites, tests 1–5, `GNIPA` debug hook to set upgrades directly. *Verify: tests
   green, cheat-set a +9 wand and feel it.* (No UI yet — proves the mechanic.)
2. **Save** — bump version, `#assert`, roundtrip test 6, `.v16.bak`.
3. **Station + window** — Anvil item/tile/recipe, `draw_upgrade`, drag slots,
   UPGRADE button, `Anvil_Interact`/`Wand_Upgrade` events. *Verify: playtest the
   full drag→click→+1 loop.*
4. **Polish** — anvil tile art, wand upgrade pips on the icon, sound, tutorial
   hint ("bring a wand and a gem to the Anvil").

Ship phase 1 first and playtest the *feel* before building the GUI — the mechanic
is the risk, the window is known work.
