# Gnipahellir 3 — Playtest Guide

Build & run: `odin run src` (debug) · `odin build src -define:GAME_DEBUG=false` (release)
Tests: `odin test src` — headless, ~20 tests, runs in well under a second.

## Controls

| Key | Action |
|---|---|
| A / D (or arrows) | Move |
| W / ↑ / Space | Jump |
| Left-click | Mine: **Pickaxe** chips adjacent tiles (3 hits, free); a crafted **Mine Wand** shoots a spark stream at range 2/4/8 (5 mana per shot) |
| Left-click on enemy | Sword swing (needs a Sword in inventory; 2-tile reach, 2 dmg, 0.35 s cooldown) |
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
   - Tier C: 20 Cloud Stone + 10 Gold Ore → wakes Garm in cave 3
5. **Deep caves**: 3 builders each. They compete for ore, build dens (raid
   them for the floor stockpile — the owner shrieks and defends), and hunt
   on sight (~12-tile LOS, 1 dmg/0.8 s bite). Craft a **Sword** at a bench
   (2 Iron Ore + 1 Plank) — builders die in 3 hits and retaliate when struck.
6. **The miner's ladder**: you start with a Pickaxe (adjacent only, 3 chips
   per tile). At a bench: Mine Wand (2 Plank + 4 Iron, range 2) → Silver
   Wand (wand + 6 Silver, range 4) → Gold Wand (silver + 6 Gold, range 8).
   Each tier consumes the previous wand; wand shots cost 5 mana (pool 100,
   regen 5/s — burst ~20 shots, then throttled).
7. **Garm** (boss gate = ritual C): awakens in the cave-3 arena. Chases,
   bites (2 dmg), throws fireballs (2 dmg, dodge or break line of sight).
   At 20 hp he raises a center column, at 10 he seals the arena, and when
   the ring closes lava floods the floor — everything he builds is mineable.
   Kill him, grab the **Hell Key** where he fell: win screen. Won runs clear
   the save like deaths do.

## Known stubs (deliberate, don't file as bugs)

- Smelter and Tree_Grower place but don't function (sim system stubbed;
  smelting deferred at Phase 4 kickoff — ores are used raw)
- Iron_Bucket can't scoop lava; Q-drop does nothing
