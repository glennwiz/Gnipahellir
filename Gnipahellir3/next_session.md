# Next Session Handover (updated 2026-07-12, fresh start)

## Where we are

Tree is clean, everything merged to `master` (PR #7). Done and verified:

- Crafting phases 1–3: station tiers, anvil drag GUI, runic gear + loot tables.
- Diegetic stations: walk near a bench/smelter/anvil → hover prompt
  (`update_station_focus` in `crafting.odin`), interact opens the GUI for
  THAT station (`ui.active_station` filters recipes). Crafting is gated by
  `player_near_station`; walking away dims the station title and blocks
  crafting (GUI stays open — it does not auto-close).
- UI renders on a 1280×720 virtual canvas at 1.5× (`UI_W/UI_H/UI_SCALE` in
  `main.odin`); game launches borderless fullscreen.
- Debug menu cheats for testing.

No branch in flight. Start new work from a fresh `feature/…` branch off master.

## Open ideas — pick with Glenn (nothing committed to)

- **Craft feedback**: particle burst (MAX_PARTICLES pool exists) / sound hook
  + result item flying to inventory instead of silently appearing.
- **Station visuals**: distinct sprites/colors per station tier so bench vs
  smelter vs anvil read differently in-world.
- **Close crafting GUI on walking away** — currently it stays open but dims;
  decide if auto-close feels better.
- Deferred from crafting plan: **chest loot**, **recipe list scrolling**
  (memory: project_crafting_system_plan).
- **Character creation screen** — death screen "carve a new hero" hardcodes
  colors (memory: project_character_creation_todo).

## Reminders

- Read `plan.md` + `CLAUDE.md` before touching systems.
- Build check: `odin run src` from repo root (`Gnipahellir3/`).
- Fixed arrays only, event-driven, render read-only, tables not switches.
