# Next Session Handover (written 2026-07-12, out of tokens)

## Where we are

Crafting system phases 1–3 are DONE (station tiers, anvil drag GUI, runic
gear + loot tables). BUT: manual playtesting says it feels bad / placeholder.
The crafting GUI currently opens via a keyboard toggle (`show_crafting` in
`input.odin:97`), completely detached from the world.

There are uncommitted changes on `master` (input.odin, levels.odin, ui.odin,
~38 lines) — review with `git diff`, commit or finish them FIRST before new
work. Do not start on a dirty tree.

## Priority 1: Click stations to open crafting GUI

This is the main fix for the placeholder feel. Interacting with the actual
crafting bench / smelter / anvil in the world should open the GUI — not a
global hotkey.

Implementation sketch (follow CLAUDE.md architecture rules):
1. In `input.odin`: on left-click (or an "interact" key like E when adjacent),
   convert mouse world pos → grid tile, check the tile's terrain/station type.
2. Use the terrain table (table-driven, no switch sprawl) to mark which tiles
   are interactable stations and which GUI tier they open.
3. Push an event (e.g. `Station_Interacted { tier }`) through `Event_Queue`
   rather than input writing sim state — input may only toggle `UI_State`,
   so setting `show_crafting` + station tier in `UI_State` directly is the
   sanctioned path (input.odin is allowed to toggle UI_State).
4. GUI should know WHICH station opened it: smelter shows smelting recipes,
   bench shows bench recipes, anvil shows the drag-forge UI. Store
   `active_station: Station_Tier` (or similar) in `UI_State`.
5. Range check: require player within ~1–2 tiles of the station, otherwise
   ignore the click.
6. Keep (or remove?) the old hotkey — ask Glenn. Probably remove to force the
   diegetic flow, or keep as re-open shortcut only when near a station.

Verify: `odin run src`, walk to bench/smelter/anvil, click each → correct
GUI variant opens; click from across the map → nothing happens; ESC closes.

## Priority 2: Proximity/hover feedback on stations — CONFIRMED, we're doing this

Glenn approved this one explicitly. Build it together with Priority 1 (they
share the tile-lookup and range-check code):
- When the player is within interact range of a station (or mouse hovers
  it), highlight the tile and show a small prompt like "[E] Smelt" /
  station name. Sells interactability instantly.
- Draw side goes in `ui.odin` or a `draw_*` proc — read-only, reads the
  same "nearest interactable station" info the click handler uses. Compute
  that once per frame in an update step (store in `UI_State`), don't
  recompute in render.
- Prompt text per station comes from the same terrain/station table as
  Priority 1 — one table, both features.

Verify: walk near bench/smelter/anvil → highlight + prompt appears,
disappears when out of range; prompt matches station type.

## Priority 3+: More de-placeholder polish (discuss/pick with Glenn)

Ideas raised or implied — pick the cheap high-impact ones:
- **Close GUI on walking away** from the station (distance check in the
  crafting update step).
- **Craft feedback**: sound hook / particle burst (MAX_PARTICLES pool exists)
  + result item flying to inventory instead of silently appearing.
- **Station visuals**: distinct sprites/colors per station tier so bench vs
  smelter vs anvil read differently in-world.
- Known deferred items from crafting plan: **chest loot** and **recipe list
  scrolling** (see memory: project_crafting_system_plan).
- Also still open: **character creation screen** (death screen "carve a new
  hero" hardcodes colors — memory: project_character_creation_todo).

## Reminders

- Read `plan.md` + `CLAUDE.md` before touching systems.
- Build check: `odin run src` from repo root (`Gnipahellir3/`).
- Fixed arrays only, event-driven, render read-only, tables not switches.
