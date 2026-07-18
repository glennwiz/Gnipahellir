# Work Done — Holiday Session (July 5–18, 2026)

## Holiday Snapshot

Glenn took 11 days in Pula (south of Croatia) and brought his laptop. He worked extensively with Fable to ship major progression and automation systems. 80 tests green, save v12, and the game is now beatable — but the endgame still needs tuning.

---

## What Shipped

### Core Progression & Automation (July 14–18)

**Gem Ladder** (`gem_progression.md` step 1, save v12)
- Natural veins: Emerald (cave 1) / Jade (cave 2) / Diamond (cave 3) / Hel Gem (arena band) / Aether_Ore (high sky)
- Sparse distribution (~4/9/13+8/6 per world)
- `Pixel_Gem` tile art with dedicated icons
- First gem sink: Auto-Miner craft at Rune Altar (6 Iron Bar + 2 Gold Bar + 1 Emerald)
- Not yet playtested in-game (visuals + miner loop)

**Auto-Miner** (`miner.odin`, save v12) — *Glenn loves this*
- Placed ONLY in dimensions (Rune Altar craft)
- Snake head BFS-tunnels to nearest themed ore each tick (3 s base)
- Eats ore + stone, outputs wide-u32 haul on the base (silo-lite)
- Leaves a Miner_Body trail as it mines
- Gem speed tiers: drop gems = ×1.5/×2/×3/×5 mine rate
- Dimension anchor: placing locks the world (no regen, other spawners blocked)
- Catch-up on re-entry; "played out" sleep when ore exhausted
- Clear time: ~1.5–2 h tier 0, ~18 min tier 4
- Ready-to-ship: full cave loop playtest still pending

**Conway Easter Egg** (`life.odin`)
- Game of Life toy on F1 debug menu
- Isolated, non-game content, own commit — ignore for game planning

### Dimension Systems (July 13, save v11)

**Parallel Dimensions Spawner Slice** (draft1_machines.md §7.6 step 2)
- Themed spawners crafted at Rune Altar
- Metal Spawner (4 Iron Bars) → 14% iron world
- Gold Spawner (4 Gold Bars) → 12% gold world
- Both + 8 Cloud Stone + 20 Stone Block
- Ephemeral worlds regenerate from seed on re-entry
- Dimension_Gate returns to spawner
- Hardened for gem expansion: `Dimension_Theme` holds `veins: [MAX_THEME_VEINS]Dimension_Vein`
- Metal spawner placement playtested; Gold not yet seen in-game

### Machines & Automation (July 5–13)

**Smelter & Tree Grower** (sim.odin, save v11)
- Smelter: eats ore stacks beside it (2 ore → 1 bar; gold 1:1), casts bars out
- Table-driven `smelt_table` — easy to extend
- Tree Grower: raises tree above itself every 20 s when sky is clear
- Per-tile timers in `sim_data` (already saved — no format change)
- Visuals: smelter burns hotter + ember bar; grower sprout climbs + leaf drift

**Bar Economy** (save v11)
- Iron / Silver / Gold_Bar items with ingot pixel art
- Forge & Altar recipes now cost bars at half ore counts
- Dvergr Forge itself costs 3 Iron Bars — clean ladder
- Bench → Smelter → Forge → Rune Altar

**Q-Drop Item Toss**
- Drops selected stack two tiles ahead (outside pickup sweep)
- Primary way to feed the smelter

### UI & Polish (July 5–13)

**Smelter GUI + HUD Objective** (wider placing, placement reach 8)
- Interactive feedback for crafting
- Objective tracking in HUD

**Runic Viking Visual Polish Pass**
- Character model updates
- Animation refinement

**Procedural Pixel Art Icons** (item_icons table)
- All items render custom icons
- Clean visual presentation

**Pixel-Art Mage Port** (July 5 session)
- Animated feet, facing, shaded robe
- Pickaxe spawns on grass (pickup, not granted)
- Drawn in-hand with swing arc on hit and whiffs
- `Player.equipped` now vestigial (render derives tool from inventory)

**Interactive Blueprint Overlay**
- B key or click blueprint
- Ritual cost with live have/need display
- Build-template diagram
- FIND → GATHER → RAISE path visualization

**Data-Driven Structure Templates** (templates.odin)
- ASCII + legend format, easy to expand
- Sky Altar only stands on finished foundation
- One template per tier: A (stone+wood), B/C (rock+silver+gold)
- Silver / Gold ore now placeable blocks
- All placeable structures reclaimable by mining

**Build Ghost Preview** (placement_ok)
- Shared visual feedback during placement

**Autosave** (save_dirty flag)
- Every meaningful action
- Frame-end write in main.odin

**Polish Features** (June session recap)
- Flashy RGB portals (taller visuals)
- Mouse-wheel zoom + 3× supersampling (player at float, game_camera/SS_SCALE in render.odin)
- Player-built sky gate (no longer open at start — find blueprint, build altar, portal blooms)
- Deselect held item (hotkey/click/Esc, selected == -1)

### Earlier Systems (Foundation)

**Debug & Settings** (June–July)
- F1 debug menu with cheats (grant gold, gift wand, spawn enemy, etc.)
- Settings screen (volume, key binds)
- Pause / Main Menu (resume, new game, quit)
- Runic death screen with new-hero restart

**Audio** (event-driven)
- Sound table, layered by depth ambience
- Integrated event dispatcher

**Save System** (versioned binary)
- SAVE_VERSION 12 (landed with gem ladder)
- Persistent stats (runs_won on victory)
- Win screen on Garm defeat
- Failed-save rejects to fresh run

**Full Progression Loop** (Phase 5 COMPLETE)
- Surface → Cave 1 → Cave 2 → Cave 3 → Garm boss
- Blueprints unlock sky levels
- Sky altars unlock next cave via ritual
- Garm currently beatable (but trivial with Silver gear — see below)

---

## Current State

| Metric | Status |
|--------|--------|
| Tests | 80/80 green (`odin test src`) |
| Save Version | 12 |
| Game Phase | 5 COMPLETE (beatable) |
| Architecture | Fat struct + event-driven, no globals, fixed-size arrays |
| Build | `odin run src` ✓ |

### Known Issues (Audit from progression_review.md)

1. **Defense breaks the boss** — `max(dmg − def, 0)` means Silver gear (def 2) blanks all Garm damage. Fight is trivial at tier 2 of 4.
2. **Runic tier UNOBTAINABLE** — No generation source for Runic_Sky_Ore. Recipes exist; items don't.
3. **No bulk economy** — Miner over-produces by 50–100×. Nothing needs the volume.
4. **Rituals cost raw ore** — Bar economy moved Forge+ recipes; rituals B/C were left behind.
5. **Gem sinks thin** — Miner recipe + speed tiers only. Decoration otherwise.

---

## Locked Decisions (Glenn + Fable, July 14)

Read `progression_review.md` §5 for full audit and justification. All decisions locked; build order in §6.

### Decision 1: Min-1 Damage Rule (events.odin:57)

Change: `max(dmg − def, 0)` → `max(dmg − def, 1)` for *player-only* damage.

**Why:** Defense should mitigate, never immunize. Garm stays threatening.

### Decision 2: Garm Tuning (garm.odin constants)

```
GARM_HP:       30 → 75
GARM_BITE:      2 → 4
GARM_FIREBALL:  2 → 3
```

**Why:** Math after tuning:
- Gold set (atk 7, def 3, hp 17): 11 hits to kill (~3.9 s contact), takes 1/bite + 1/fireball + lava phases → *losable but possible*
- Runic set (atk 11, def 5, hp 21): 7 hits (~2.5 s contact), still 1 chip/bite → *intended, comfortable win*

### Decision 3: Runic Dimension Spawner (500 Gold Bars)

New tier in `templates.odin`:
```
Dimension_Spawner_Runic
  Recipe: 500 Gold Bars + 20 Cloud Stone @ Rune Altar
  Theme: Runic_Sky_Ore (10%) + Gold_Ore (3%) + ...
  Cost in ore: 1,000 gold ore
```

**Why:** Fixes unobtainable runic tier AND lands Glenn's "1000 gold" endgame design.
- One snake-stripped Gold dimension yields ~1,200 gold ore ≈ exactly one Runic spawner
- Auto-Miner (~20 min tier 4 gem-fed) is now load-bearing for the endgame
- 27 runic ore for full gear set comes from mining the runic world

**Watch:** `Ingredient.count` type — if u8, 500 overflows. Widen or split cost.

### Decision 4: Rituals B/C to Bars

```
Ritual B: 12 Cloud Stone + 6 Silver Bars  (was: 6 Silver Ore)
Ritual C: 20 Cloud Stone + 10 Gold Bars   (was: 10 Gold Ore)
```

**Why:** Consistency with bar economy. Cost roughly doubles in ore terms. Ritual C becomes real pre-boss checkpoint.

---

## Build Order (Next Session)

1. **Min-1 rule** (events.odin:57) → verify gold-set player still takes 1/bite in a soak test
2. **Garm constants** (garm.odin) → verify garm_fight_soak retuned, math checks out
3. **Rituals to bars** (structure_costs table) → verify tests updated, notify strings show bar names
4. **Runic Dimension** (tile + item + icon + glow row, recipe at Rune Altar)
   - Theme row: `{{.Runic_Sky_Ore, 10}, {.Gold_Ore, 3}, ...}`
   - Verify: spawner opens runic-rich world; full gear craftable from ore
   - **Watch:** `Ingredient.count` overflow check
   - **Watch:** crafting affordability must count across stacks (it does — `inventory_count` sums)
5. **Runic wand r12 note** in PLAYTEST; full-curve hand playtest

### After That: The Silo (draft1_machines.md §7.6 step 1)

Moving 500 bars = 6 bag stacks. The u8/99-stack constraint will finally bite. Glenn will feel it on schedule.

---

## Still Not Playtested In-Game

- Gem tile art display (Pixel_Gem look)
- Miner snake visuals (body trail, head pulse, base glow)
- Full miner loop by hand
- Gold Spawner in-world (Iron was playtested)

Quick fly-by covers all.

---

## Architecture Notes

- **Save Version 12** in flight; changes above may need a bump (check struct sizes with `save_data_size_probe` test)
- **Dimension_Theme** is now hardened for gem expansion — pure append-only table rows
- **Entity_Map** semantics locked (`center tile, last-writer-wins`, used for combat targeting, not movement constraint)
- **Fixed arrays only** — no `[dynamic]` growth during gameplay
- **Render is read-only** — all game logic in update procs

---

## Key Docs (Authoritative)

- `plan.md` — ship roadmap, phases 0–5 done
- `CLAUDE.md` — architecture law (call-discipline, entity-map, new-system checklist)
- `progression_review.md` — full audit of gate/gear/tool/economy math
- `next_session.md` — freshest truth before a session
- `PLAYTEST.md` — controls, debug tools (F1 fly)

---

## For Fable (Next Session Handover)

The holiday session landed the hardest features: automation (smelter/grower), dimensions (ephemeral worlds), gems (ladder + miner), and the full loop is playable. The code is clean, tests are green, and Glenn signed off on a locked endgame progression audit.

The next phase is pure table/constant tuning: min-1 damage rule, Garm rebalance, Runic spawner, ritual costs. All decisions are made; no design questions remain. Then the Silo (the hard part — managing 500 bars through 99-stacks).

The game is **ready for endgame tuning and final balancing**. After that, Phase 6 is about menus, death flow, and release polish.

---

**Signed:** Haiku 4.5

**To Fable:** You've set up a solid foundation. Glenn is happy with the automation and miner — keep momentum on the progression audit (it's locked), then move to the Silo. The game's very close to shipping.

Safe travels, and good luck with the next phase.

🔨⚒️

---

*Written 2026-07-18 after 11 days in Pula; compiled from commit history, action.log, and Fable's session notes.*
