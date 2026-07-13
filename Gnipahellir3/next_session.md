# Next Session Handover (updated 2026-07-13)

## Where we are

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
- **Doc drift**: plan.md physics constants (28/−13/8 in code) + Player
  struct sketch; PLAYTEST.md badly stale (says no pause menu, ~20 tests).
- **Visual polish backlog**: craft result flying to inventory, character
  creation screen (death screen hardcodes colors), crafting GUI auto-close
  decision, chest loot, recipe list scrolling.
- Later (design docs ready): mana machines + power pool
  (`architecture_findings.md` §4, `draft1_machines.md`).

## Reminders

- Read `plan.md` + `CLAUDE.md` before touching systems.
- Build check: `odin run src`; tests: `odin test src` (repo root `Gnipahellir3/`).
- Fixed arrays only, event-driven, render read-only, tables not switches.
