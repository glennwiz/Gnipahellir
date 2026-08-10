# studio_tiles.md — the TILES tab: terrain goes studio-owned (T1 SHIPPED, T2/T3 owed)

**Status:** spec agreed with Glenn 2026-08-09 (the day Studio Phases A–C
shipped). **T1 (the extraction, §2) SHIPPED 2026-08-10, commit 7e505c8** —
gen_terrain.odin exists, emit-check covers five files, notes.txt carries the
tile/tiledesc/struct/glow harvest. T2/T3 (§3/§4) remain the full brief for
the tab itself. **One stale detail:** this spec predates studio Phases D/E,
which took keys [5] (RECIPES) and [6] (WIZARD) — the TILES tab lands on
key **[7]**, not [5].

**Companion docs:** the studio bullet in `context.md` (Phases A–C: what the
tool is, the codegen model, the ownership law), `tools/gnipa_studio/main.odin`
header (modes), `pixel_style.md` (art direction if tile colors get a pass).

---

## 1. Why tiles are next

Items, icons, recipes and player art are studio-owned; **terrain is the other
half of the game's content** and it is entirely pure-literal — audited
2026-08-09, `terrain_table`'s full body (`world.odin:18-533`) references no
named constant anywhere: every row is name / flags / color / move_cost /
damage_per_second / drop_item / drop_pct literals (struct at `world.odin:7`).
The world's whole palette — every terrain color the player ever sees — becomes
paintable in one place, beside the icon palettes it must harmonise with.

**Ownership law check (all four pass "pure-literal only"):**

| Table | Where | Shape |
|---|---|---|
| `terrain_table` | `world.odin:17` | `[Tile_Type]Terrain_Behavior`, full array |
| `terrain_desc` | `world.odin:535` | `#partial [Tile_Type]string` |
| `is_structure_tile` | `world.odin:580` | `#partial [Tile_Type]bool` |
| `station_glow` | `render.odin:111` | `#partial [Tile_Type]rl.Color` |

These four move together deliberately: they are one tile's identity split
across three files today (behavior + hover text + equipment-protection +
ambience glow), and the inspector should show them as one card.

**What stays hand-owned, named so nobody re-litigates:** `terrain_desc_for`
(`world.odin:571` — logic), the `Terrain_Behavior`/`Terrain_Flags` types, all
of `fluid_rules`/`boiler_rules`/`engine_rules`/`gem_replicate_time`/
`miner_gem_tier` (tuning knobs with load-bearing ordering and cross-table
relationships — Glenn's call to hold these, 2026-08-09), `build_templates` and
the golem `*_CELLS` (the documented slice-initializer exception), and every
bespoke `draw_pixel_*` proc (procedural code, not data).

---

## 2. Phase T1 — extraction into `src/gen_terrain.odin`

Mirror Phase A exactly: **the emitter performs the extraction**, so emit is
byte-stable from day one and `--emit-check` is green from the first commit.

### `tools/gnipa_studio/emit.odin` — new `emit_terrain`

One proc, four sections, modelled on `emit_items`/`emit_recipes`:

1. `terrain_table` — full `[Tile_Type]` iteration (enum order = emit order,
   deterministic). Flags emit as a literal set (`{.Solid, .Mineable}`); emit
   in `Terrain_Flags`' declared bit order so the text is stable. `move_cost`
   and `damage_per_second` are f32 — today every value is a small whole
   number; print with a minimal-float helper (`%g`-style, no trailing zeros)
   and let `--emit-check` pin it.
2. `terrain_desc` — `#partial`, skip empty strings, `escape_odin_string`.
3. `is_structure_tile` — `#partial`, skip false.
4. `station_glow` — `#partial`, skip `{}`, reuse `color_str`.

Each section prints its explanatory header the way `emit_recipes` prints the
append-only warning — the hand-file comments above each table today become
emitter-printed headers (the `is_structure_tile` doc comment at
`world.odin:576-579` and the `station_glow` one at `render.odin:108-110` are
the two that matter: they state the wand/reclaim protection rule and the
ambience-sparks contract).

### `tools/gnipa_studio/notes.txt` — harvest the row comments

New table prefixes: `tile`, `tiledesc`, `struct`, `glow` (key = tile enum
name). Harvest before deleting the hand rows — the ones that exist today:

- `tile/Stone` — the `.Falls_Placed` explanation (natural stone never moves,
  placed stone falls) sitting inside the row at `world.odin:32-35`. Sweep the
  whole table body for others like it.
- `tiledesc/Cave_Entrance` — the "Gateways: the label should say where the
  step leads" comment (`world.odin:543`).
- `struct/Sky_Rune_Scroll_Chest` — the coffer block comment
  (`world.odin:596-598`).
- `glow/*` — every trailing `// hearth gold`-style swatch name
  (`render.odin:112-126`) becomes a leading note line; they are the palette's
  vocabulary and must survive.

### `tools/gnipa_studio/main.odin`

`emit_all` grows `[4]Gen_Out` → `[5]Gen_Out` with
`{"gen_terrain.odin", emit_terrain(notes)}`. The `--extract` / `--emit-check`
loops are generic — no other change.

### `src/` deletions (same commit)

Delete the four tables from `world.odin`/`render.odin`; everything else in
those files stays. Same package, so **no call site anywhere changes** — this
is symbol-neutral file movement, exactly like Phase A.

### Verify T1

`gnipa_studio --extract` writes `gen_terrain.odin` → game builds green → full
test suite green **untouched** (these tables are not saved; probe stays
3,171,512) → `--emit-check` green on all five files → `run.ps1` watcher
rebuild still fires (it already tolerates multi-file saves via the 400 ms
debounce).

---

## 3. Phase T2 — the TILES tab (browser + inspector, read-only)

`Tab` enum (`studio.odin:28`) gains `.Tiles`, key **5**, `session.dat` gains
the selected tile (append the field; the session file is a tolerant scratch —
a stale one just loses the selection).

- **Browser:** the ITEMS grid pattern (`BROWSER_COLS`/`BCELL`), one cell per
  `Tile_Type`, drawn as its `terrain_table` color swatch on the checker (tiles
  have no icons — the flat color IS the art), name + ordinal underneath.
  This grid is the world palette on one screen, which is the tab's whole
  pitch.
- **Inspector** (one tile = one card, all four tables joined): name · flags
  as a checkbox row · move_cost · dps · drop item **as its real icon** with
  drop_pct, click = jump to the ITEMS tab (the existing USED-IN jump-link
  pattern) · the `terrain_desc` text wrapped · structure badge when
  `is_structure_tile` · glow swatch when `station_glow` has a row.
- `--shot` renders the new tab like the others.

---

## 4. Phase T3 — editing + SAVE

- **Color and glow:** reuse the pixel editor's RGB sliders verbatim — select
  the terrain color or the glow swatch, drag, live preview on the browser
  cell.
- **Flags:** checkbox toggles. **move_cost / dps / drop_pct:** small stepper
  arrows (no text entry needed — the values are tiny).
- **Drop item:** picker over the ITEMS browser grid (reuse it as a modal or a
  filtered strip).
- **Structure / glow membership:** the badge and swatch toggle rows in/out of
  the two `#partial` tables.
- **Name and desc text stay non-editable this phase** — the studio has no
  text-input widget yet; they round-trip through emit untouched. Building a
  text field is its own small task; do not smuggle it in here.
- **SAVE** validates before writing (the `item_icons_are_well_formed`
  discipline): every tile has a nonempty name; a `.Damaging` tile has dps > 0;
  a `station_glow` row has alpha ≠ 0. Then re-emit `gen_terrain.odin` through
  the same proc `--extract` uses.
- `--test-save` grows a third leg: nudge one channel of Dirt's terrain color,
  save, game builds, revert via git — **and per the studio workflow rule,
  never run the revert leg over uncommitted studio content** (commit
  `content:` first; `--emit-check` green + nonempty diff = Glenn's work, not
  drift).

---

## 5. Explicitly NOT in scope

- **The template/blueprint editor** (`structure_templates`, `templates.odin`)
  — the agreed *second* extraction: the pixel editor's interaction painting
  tiles instead of runes, capstone rule (exactly one `A`) validated on SAVE.
  Own session, own brief.
- **`enemy_drop_table` / `dimension_table`** — inspector-grade candidates,
  parked until there's an ENEMY or DIMENSION view worth hanging them on.
- **A KNOBS tab for the sim rule tables** — declined for now (hand-edit +
  watcher is the same loop; re-emitting files whose invariants live in
  comments adds risk).
- **Terrain draw styles** (`Pixel_Gem`, fluid wisps, the bespoke station
  art) — rendering code, not data. The tab shows the flat color only.
- Phases D (recipe editor) and E (new-item wizard) stay queued as planned;
  T1–T3 slot around them at Glenn's pleasure.
