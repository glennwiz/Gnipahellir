# Gnipahellir 3 — Playtest Guide

Build & run: `odin run src` (debug) · `odin build src -define:GAME_DEBUG=false` (release)
Tests: `odin test src` — headless, ~20 tests, runs in well under a second.

## Controls

| Key | Action |
|---|---|
| A / D (or arrows) | Move |
| W / ↑ / Space | Jump |
| Left-click | Mine (5-tile reach, shared `PLAYER_REACH`) |
| Right-click | Place selected item (5-tile reach, needs solid neighbour) |
| TAB | Inventory (click slot or keys 1–8 to select) |
| C | Crafting window (rows green = affordable; click to craft) |
| E | Interact: portal travel / sky-altar ritual |
| F11 | Borderless fullscreen |
| Q | Drop item — **wired but unimplemented** |

No pause menu yet — close the window; it saves on quit and continues on
launch. Death clears the save (roguelike). Save/log files live in the
working directory (`gnipahellir_save.dat`, `gnipahellir_stats.dat`,
`action.log`).

## Debug tools (debug builds only)

| Key | Tool |
|---|---|
| F1 | Debug menu — click "Fly mode" to toggle (W/S or ↑/↓ vertical, no gravity, collision stays on) |
| F3 | Debug overlay: player pos/vel, builder scan rays, hover tile |

`action.log` records everything (flushed every 5 s + on quit) — after a
playtest, grep it for `strike`, `WARNING`, `Player` to reconstruct the
session. This is how the builder-freeze regression was diagnosed.

## The full loop (v1.0 progression)

1. **Cave 1**: hole in the grass at map center → shaft down. Blueprint A +
   the (locked) cave-2 portal are in the bottom-right chamber (~x 140–150).
2. **Blueprints**: walk over them — pickup *is* activation (fires
   `Blueprint_Found`; a popup shows the ritual cost). Never consumed.
3. **Sky**: gate on the surface far west (x≈6). Mine Cloud_Ore on the
   platforms. Falling below the clouds returns you to the surface.
4. **Ritual**: place a Sky_Altar, stand near, press E. Popups explain any
   missing prerequisite. Costs:
   - Tier A: 8 Cloud Stone + 4 Plank → unlocks Deep Cave (cave 2)
   - Tier B: 12 Cloud Stone + 6 Silver Ore → unlocks Gnipahellir (cave 3)
   - Tier C: 20 Cloud Stone + 10 Gold Ore → boss gate flag only (no boss
     until Phase 5 — dead end by design)
5. **Deep caves**: 3 builders each. They compete for ore, build dens, and
   hunt on sight (~12-tile LOS, 1 dmg/0.8 s bite). There is **no player
   attack yet** (Phase 5) — being cornered is death.

## Known stubs (deliberate, don't file as bugs)

- Smelter and Tree_Grower place but don't function (sim system stubbed)
- Iron_Bucket can't scoop lava; Q-drop does nothing; mining costs no mana
- Sky altar works on any level, not just sky (review item C4, design call)
