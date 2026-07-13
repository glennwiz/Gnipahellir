# Next Session Handover (updated 2026-07-13, late night)

## Newest: gem ladder + Auto-Miner (2026-07-13 late session, save v12, 79/79 tests)

Two features on branch `feature/dimension-spawners` (needs push):

- **Gem ladder shipped** (`gem_progression.md` step 1): Emerald/Jade/Diamond/
  Hel Gem veins + revived Aether_Ore in the sky, ≈4/9/13+8/6 per world,
  `Pixel_Gem` tile art, icons, debug handout. Gems roll before metals.
- **Auto-Miner shipped** (`miner.odin`, save v12): Rune Altar craft (6 Iron
  Bar + 2 Gold Bar + 1 Emerald — first gem sink), places ONLY in dimensions,
  one per expedition. Snake head BFS-tunnels to nearest themed ore each tick
  (3 s base), eats ore + stone tax into a wide-u32 haul on the base
  (silo-lite), leaves a Miner_Body trail. E = withdraw 99-stacks; Q-drop gems
  = permanent speed tiers (×1.5/×2/×3/×5). Placing ANCHORS the dimension (no
  regen, other spawners blocked = first Dimension Lock); leaving + returning
  applies catch-up; ore exhausted = "played out" sleep; mining the base
  releases the anchor. Clear time: ~1.5–2 h tier 0, ~18 min tier 4
  (`miner clear` log line in tests).
- **NOT yet playtested in-game**: gem tile art, miner snake visuals (body
  trail, head pulse, base glow), the whole miner loop by hand. Do this first.
- New permanent `save_data_size_probe` test logs size_of(Save_Data) — bumping
  the save is now copy-paste.

## Previous session (2026-07-13 session: dimensions pillar begins)

On master: the **Parallel Dimensions spawner slice** shipped
(`draft1_machines.md` §7.6 step 2 — Glenn chose it before the Silo).
`src/dimensions.odin`, 72/72 tests green, save bumped to **v11**
(old saves reject to a fresh run):

- **Themed spawners** crafted at the Rune Altar; the recipe's metal is the
  world's riches (Glenn's design call): Metal Spawner = 4 Iron Bars → iron
  14%; Gold Spawner = 4 Gold Bars → gold 12%. Both + 8 Cloud Stone +
  20 Stone Block.
- **Ephemeral worlds**: `LEVEL_DIMENSION :: 4` in Level_Store; regenerates
  from seed (whash of spawner tile) every entry; Dimension_Gate returns you
  to the spawner. Interact scan mirrors the Sky Altar pattern.
- **Hardened for gem expansion**: `Dimension_Theme` now holds a
  `veins: [MAX_THEME_VEINS]Dimension_Vein` list ({tile, pct}) — gen loops it,
  no per-ore fields or switch arms. A new themed world is pure table data.
- Placement/mining, debug menu handout, station glow, crystal icons, plan.md
  synced. **Metal spawner placement playtested; Gold not yet seen in-game.**

## Next session: gem expansion plan (emeralds, diamonds, jade, sky crystals, hell gems)

Architecture verdict: ready. Per new gem, everything is an append-only table
row (Tile_Type + Item enums are save-safe appends; item_icons is a full array
so the compiler forces the icon entry; ORE_GRID/CRYSTAL_GRID + palette = one
line). Decisions to make with Glenn before building:

1. **Gem ladder step 1 SHIPPED (2026-07-13 evening, 73/73 tests)**: natural
   veins live — Emerald (cave 1), Jade (cave 2), Diamond (cave 3), Hel Gem
   (arena band), Aether_Ore revived in the high sky. Sparse (≈4/9/13+8/6 per
   world), `Pixel_Gem` tile art, icons, debug handout. **Not yet playtested
   in-game** (Pixel_Gem look + icon check). No gem sinks yet — next per
   `gem_progression.md`: gem dimensions (needs Dimension Blocks first) and
   sinks (resonator/gear/boss craft). Hazards design unchanged.
2. **Spawner-per-theme stops scaling** past ~4 themes (each needs tile + item
   + recipe + icon + glow row). At that point implement §7.6 step 3:
   **Dimension Creator + Dimension Block** items — ONE spawner tile, block
   consumable carries kind+seed. Recommended before adding a 3rd theme.
3. **What gems are FOR** — recipes that want them (runic+ tier gear? machine
   parts? boss summon?). Without sinks they're decoration.
4. **Silo still first** for any bulk economy (§7.6 step 1): item_counts is u8
   (255 cap), inventory ~2,400 total. Unchanged prerequisite.

## Previous session (machines-alive, merged)

Branch `feature/machines-alive` (off master, not yet merged/pushed): the
"shine" pass began with the biggest gap from `score.md` (8.5/10 review) —
the inert automation pillar. Done and test-verified on the branch:

- **Machines live**: `update_sim` (new `sim.odin`) reclaims step 5b.
  Smelter eats ore stacks lying beside it (2 ore → 1 bar, rare gold 1:1,
  table-driven `smelt_table`) and casts bar items out; Tree Grower raises
  a tree above itself every 20 s when the sky is clear. Per-tile timers in
  `sim_data` (already saved — no save format change).
- **Q-drop implemented** (was a dead binding): drops the selected stack two
  tiles ahead, outside the pickup sweep. This is how you feed the smelter.
- **Bar economy**: Iron/Silver/Gold_Bar items (+ ingot pixel art). Forge- and
  Altar-tier recipes now cost bars at half the old ore counts; the Dvergr
  Forge itself costs 3 Iron Bars — ladder reads bench → smelter → forge.
- **Visuals**: smelter burns hotter with progress + ember bar, grower sprout
  climbs as growth fills, ember/smoke burst on each cast bar, leaf drift on
  each grown tree, placement hint notifications.
- 61/61 headless tests green (3 new: smelter, grower, Q-drop). `MAX_RECIPES`
  leftover removed; `src.bin` gitignored; plan.md updated (bars, update
  order, sim.odin).

**Needs a manual playtest before merging** — the sim logic is test-covered
but the look (glow, sprout, bursts) hasn't been seen in-game.

## Next up on the shine list (from score.md, pick with Glenn)

- **Remaining dead ends**: Iron_Bucket can't scoop lava; potions exist but
  are unobtainable/unusable.
- **Enemy variety**: Undead/Fire_Sprite are empty enum branches; caves 2–3
  need distinct threats.
- ~~**Doc drift**~~ — FIXED 2026-07-13: plan.md physics + Player struct
  synced to code; PLAYTEST.md test count (72) and placement reach (8) fixed.
- **Visual polish backlog**: craft result flying to inventory, character
  creation screen (death screen hardcodes colors), crafting GUI auto-close
  decision, chest loot, recipe list scrolling.
- Later (design docs ready): mana machines + power pool
  (`architecture_findings.md` §4, `draft1_machines.md`).
- **Builder reach upgrade** (Glenn, 2026-07-13 playtest): base placement
  reach is now 8 (`PLAYER_REACH`, placement.odin). Idea: a craftable
  upgrade that extends it further and lets you paint tiles by holding the
  mouse — mirror the wand pattern (`best_wand` extends PICK_RANGE).

## Reminders

- Read `plan.md` + `CLAUDE.md` before touching systems.
- Build check: `odin run src`; tests: `odin test src` (repo root `Gnipahellir3/`).
- Fixed arrays only, event-driven, render read-only, tables not switches.
