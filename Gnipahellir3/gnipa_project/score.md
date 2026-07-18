# Gnipahellir 3 — Vertical Slice Review

Review date: 2026-07-13. Scope: plan.md, architecture_findings.md, and a
multi-pass read of all of `src/*.odin` (~10k LOC) — foundation, gameplay
systems, AI/boss, persistence, forbidden-pattern sweep, tests, and build.

## Score: 8.5 / 10

The game is a genuine, complete vertical slice: you can play from spawn to
victory through every core system — pickaxe → cave 1 → Blueprint A → sky
ritual → gated cave 2/3 → the wand/sword/armor crafting ladder across three
station tiers → a four-phase Garm boss fight → Hell Key → win screen, with
roguelike death, versioned saves, audio, and a full UI around it. The build
compiles clean and all 58 headless tests pass in under a second, including
two soak tests (a 60-second simulated boss fight and a builder-economy run).

## What's holding the score up

- **Architecture discipline is real, not aspirational.** Swept for every
  forbidden pattern: no TODOs, no `[dynamic]`, render and UI never mutate
  state (grep-verified), all module-level tables are `@(rodata)` except
  `build_templates`, which carries a comment explaining exactly why it
  can't be. `game_update` is an explicit numbered order with comments
  stating *why* each position matters (e.g. mining must precede
  `process_events`).
- **Everything is table-driven as promised** — terrain, items, 37 recipes,
  stats/equipment, loot, structure templates, key bindings. Adding content
  is a table row, exactly as plan.md claims.
- **The hard code is battle-hardened.** The dig-aware A* and builder AI in
  `enemy.odin` is the most complex system, and it's full of documented
  livelock fixes, watchdogs with strike escalation, and a dig-free rescue
  of last resort. `physics.odin` documents the load-bearing ordering of
  `BODY_EPS`/`BODY_MARGIN`. This reads like code that survived playtesting,
  and `action.log` + PLAYTEST.md confirm it did.
- **Honest self-knowledge.** PLAYTEST.md's "Known stubs" section and
  `architecture_findings.md` match what the code actually contains — the
  docs don't oversell.

## Why not higher

- **One of the four stated pillars is inert.** plan.md lists "Automation
  (tree growers, smelters) enables scaling" as a core theme, but
  `update_sim` is a commented-out stub (`update.odin:34`): Smelter and
  Tree_Grower are craftable, placeable tiles that do nothing,
  `Sim_State`/`sim_data` are saved but never read, and
  `Lava_Spread`/`Tree_Grew` handlers are empty. For a vertical slice,
  shipping craftable machines that don't function is the biggest dent — a
  player will find this in minutes. (`architecture_findings.md` already
  has the right build plan for this.)
- **Small dead ends visible to the player:** Q-drop is bound but
  `Item_Dropped` has an empty handler, Iron_Bucket can't scoop lava, and
  Potion_Health/Mana exist in the item table with no way to obtain or use
  them.
- **Enemy variety is thin per plan:** `Undead`/`Fire_Sprite` are enum
  entries with empty update branches and empty drop rows; caves 2 and 3
  differ mainly in generation parameters, not threats.

## Drift worth fixing (cheap, doc-only)

- **PLAYTEST.md is stale in places:** it says "No pause menu yet — close
  the window," but ESC opens a full pause menu with Resume / Settings /
  New Game / Save-and-Quit; it also says "~20 tests" (it's 58) and doesn't
  mention the Runic tier or rebindable keys.
- **plan.md physics constants are stale:** it documents gravity 18 /
  jump −10 / speed 6, but the code uses 28 / −13 / 8
  (`player.odin:3-6`). Same for the update-order list (no mining /
  station-focus steps) and the Player struct sketch. The v1.0 flat-index
  note handles the level-structure drift well; the rest of the doc could
  use the same treatment.
- `MAX_RECIPES :: 16` in `types.odin:19` is unused (the recipe table is
  `[?]Recipe` with 37 entries) — a leftover constant that now lies.

## Bottom line

As a *slice* this is an 8.5 — complete loop, verified quality, exemplary
discipline for a codebase this size. What separates it from 9–10 is depth
in the promised pillars: wire up `update_sim` so smelters/growers actually
run (the findings doc's step-by-step plan is ready to execute), and close
out the three small dead-end items either by implementing or removing them.
