# Enemy Spawn Waves + Rainbow Laser Defense + Fire Wand Testing Recipe

## Context

Glenn wants to start testing enemy pressure on the base. Three pieces:

1. **Fire Wand testing recipe** — the wand already exists (combat-proven, "I love the feel of it"). For wave testing it must be cheap and immediate: **1 Wood_Log + 1 Stone_Block at the bench, revealed from the start** (currently Plank 2 + Iron Ore 2 + Emerald 1, revealed by first Emerald). Marked as a testing recipe — will be reverted/retuned after wave testing.
2. **Rainbow Laser** — the game's first defense structure: bench-crafted (1 Wood_Log + 1 Stone_Block), placeable, automatically beams the nearest enemy in range. Rainbow-colored beam.
3. **Wave system** — 3 wave kinds: **AIR / GROUND / UNDERGROUND**, with typed enemies and a data table so future waves are edits, not code. Testing trigger: **each Fire Wand craft spawns the next wave in a fixed cycle Air → Ground → Underground → repeat** (trigger will change later — keep it a one-line hook). Wave enemies **hunt ALL structures** (the 28 `is_structure_tile` machines/stations — NOT player-placed plain blocks), smash them one by one, then hunt the player/golems. F4 debug menu gets force-spawn buttons per wave kind + a clear button.

Decisions Glenn confirmed: cycle trigger (not all-at-once/random); machines & stations only as targets; wand revealed from start.

All paths below under `Gnipahellir3\`. House rules apply: each commit standalone green (`odin build src` + `odin test src`, 309 currently green), save probe `#assert` 3_171_512 at `save.odin:24-25` must not fire, gen-file edits verified with `gnipa_studio --emit-check`.

**Board protocol (before any edit):** this work is **board task #164** (already drafted and Ready). Check in on http://127.0.0.1:7666 as `claude-opus-waves-<4 hex>` (status post, NO `files` — the task carries the claims), then `GET /tasks`, read #164's current `rev`, and `claim` it with that rev. `renew` before long quiet stretches. On completion post your write-up as a board message, then `submit` with `result_seq` = that post's seq. Do NOT commit this plan file. Commit only the task's listed files, via `git commit -- <paths>` (the index is shared state — never bare `git commit`, never stash/reset).

---

## Commit 1 — Fire Wand testing recipe, revealed from start

Files: `src\gen_recipes.odin`, `tools\gnipa_studio\notes.txt`, `src\tests.odin`

- `gen_recipes.odin:112` → `{ .Fire_Wand, 1, .Bench, {{.Wood_Log, 1}, {.Stone_Block, 1}, {}} },` (exact emitter format, tab-indented). Update the comment block above it (:109-111) to say TESTING recipe.
- Delete unlock row `.Fire_Wand = .Emerald` at `gen_recipes.odin:192` + its comment line :191 → recipe pre-revealed at init (`game_state.odin:801-803`).
- `notes.txt`: rewrite the `recipe	Fire_Wand` comment lines, delete the `unlock	Fire_Wand` line (:185) — required or `--emit-check` reports drift.
- Test `the_fire_wand_testing_recipe_is_open_from_the_start`: `recipe_unlock[.Fire_Wand] == .None` + recipe row is exactly Wood_Log 1 + Stone_Block 1 at `.Bench`.

Verify: build, tests, `gnipa_studio --emit-check`.

## Commit 2 — Rainbow Laser structure

Files: `src\types.odin`, `src\gen_items.odin`, `src\gen_item_icons.odin`, `src\gen_recipes.odin`, `src\gen_terrain.odin`, `src\sim.odin`, `src\render.odin`, `tools\gnipa_studio\notes.txt`, `src\tests.odin`

- **Enums**: `Rainbow_Laser` Item at the `// <gen:item-append>` marker (`types.odin:325`, len(Item) 98→99/128, save-free); `Rainbow_Laser` Tile_Type appended at end of enum (~:184, append-only is save-free).
- **Gen rows** (hand-edit in emitter byte format): `gen_items.odin` item row with `place_tile = .Rainbow_Laser` + non-empty description; `gen_item_icons.odin` `{SMELTER_GRID, <rainbow palette>}` (Boiler/Kettle precedent — zero new art); `gen_recipes.odin` `{ .Rainbow_Laser, 1, .Bench, {{.Wood_Log, 1}, {.Stone_Block, 1}, {}} },` with **no unlock row** (known from start); `gen_terrain.odin` terrain_table row `{.Solid, .Mineable, .Placeable}` + drop_item = the item, `is_structure_tile[.Rainbow_Laser] = true` (wave-targetable + reclaimable — intended), `station_glow` row (free in-world icon render via `render.odin:951-959`). notes.txt comment lines to match.
- **Tick** (`sim.odin`): constants `LASER_RANGE :: f32(8)`, `LASER_DAMAGE :: 2`, `LASER_COOLDOWN :: f32(0.5)` (first-guess, playtest-tuned). Pure helper `laser_target(gs, x, y) -> (ei, ok)` — nearest active enemy AABB-center within range (idiom: `projectile.odin:106-115`). `tick_rainbow_laser(gs, x, y)` — cooldown in `sim_data.growth_timer` (safe scratch: `raid_machine_hot` only reads Smelter/Boiler/Kettle); on fire push `.Damage_Dealt {source = PLAYER_ID, target = enemy_entity_id(ei), payload.int_val = LASER_DAMAGE}` (`events.odin:76-101` does hp/sound/number/blood free). Register in `tile_on_tick` (`sim.odin:139-152`); update_sim runs before process_events so the event lands same frame.
- **Beam render** (`render.odin`): `draw_lasers` in the world pass after enemies — scan grid for `.Rainbow_Laser` tiles, re-run `laser_target` (pure/read-only), draw tile-center→enemy-center as 3-4 parallel 1px strips, colors hard-stepped through a rainbow band indexed by `int(gs.elapsed_time * 8) % N` (house style: pixel steps, no alpha fades). Beam continuous while target in range; damage stays on the 0.5 s tick.
- Tests: `the_rainbow_laser_zaps_the_nearest_enemy_in_range` (damage inside range past one cooldown; none at 12 tiles; verify fails without tick registration), `the_rainbow_laser_is_a_bench_craft_and_a_structure` (recipe + place_tile + is_structure_tile + unlock .None). Existing gates: `item_icons_are_well_formed`, `every_tile_and_item_has_a_hover_description`.

Verify: build, tests, emit-check, `odin run src` eyeball of icon + beam.

## Commit 3 — Wave enemy kinds + shared structure-hunting brain

Files: `src\game_state.odin`, `src\enemy.odin`, `src\loot.odin`, `src\particles.odin`, `src\render.odin`, `src\tests.odin`

- **Enums** (both saved-u8, append-only, save-free): `Enemy_Kind` += `Vargr` (GROUND runner, Norse outlaw-wolf); `Builder_Goal` (`game_state.odin:54-60`) += `Wave_Hunt` (marks a wave-spawned enemy that hunts ALL structures). **AIR = repurpose `.Fire_Sprite`** — dead stub, no spawn proc ever existed so no save can contain one (empty case `enemy.odin:1967`, placeholder `render.odin:2310`). UNDERGROUND = existing `.Raider` with `goal = .Wave_Hunt`.
- **Mandatory table rows** (full `[Enemy_Kind]` arrays — compile fails without): `enemy_drop_table` (`loot.odin:21`) `.Vargr` row; `enemy_blood` (`particles.odin:95`) `.Vargr` row. Extend `#partial` helpers `enemy_speed`/`enemy_body_size` (`enemy.odin:272-287`) — both new kinds keep `{BUILDER_W, BUILDER_H}` body so builder_tile/entity-map math is untouched. Constants near `enemy.odin:62`: `FIRE_SPRITE_HP :: 4`, `FIRE_SPRITE_SPEED :: 5.0`, `VARGR_HP :: 8`, `WAVE_ATTACK_TIME :: f32(0.9)`, `WAVE_DAMAGE :: 2` (first-guess).
- **Shared targeting helpers** (enemy.odin, beside the raid section):
  - `wave_target_refused(gs, T) -> bool` — mirrors `handle_tile_mined`'s refusal branches (`events.odin:492-521`: loaded Silo/Barrel/Coffer/scroll-chest). **Livelock fix: refused containers are excluded before targeting**, not discovered by failing at them.
  - `find_wave_structure_target(gs, from) -> (T, ok)` — full-grid scan (`raid_heat_target` idiom, `enemy.odin:851`) for nearest `is_structure_tile` tile, skipping refused ones.
- **Generalize `update_raider`** (`enemy.odin:1860-1940`), no duplication: target-validity predicate at :1905 becomes goal-dependent (`.Wave_Hunt` → `is_structure_tile && !wave_target_refused`; else current `is_raid_machine`); after smash, when `!has_target && goal == .Wave_Hunt`, re-target via `find_wave_structure_target` before falling through to the player/golem hunt at :1927. Industry raiders keep exact current behavior.
- **Vargr** = `update_raider` wholesale: `update_enemies` gains a `case .Vargr:` identical to `.Raider` (move_body + update_raider).
- **Fire_Sprite flying** — first flying enemy. `update_enemies` case: `move_body(..., 0 /*gravity*/, 0 /*max_fall*/, &e.grounded)` + new `update_fire_sprite` — zero-gravity through the shared mover keeps collision + entity-map bookkeeping (:1969). Brain: same `Wave_Hunt` targeting via the shared helpers; steering not pathfinding (`e.vel = normalize(target_center - body_center) * FIRE_SPRITE_SPEED`; wall-ahead → rise, builder wall-ahead idiom `enemy.odin:761-762`); adjacent (chebyshev ≤ 1) on attack_timer → smash via `handle_tile_mined` `source = enemy_entity_id(id)` (the proven raider path :1917); no structures left → steer at player/golem, strike on contact (`Damage_Dealt`, reuse strike pattern).
- **Spawn procs**: `find_surface_floor(w, hint_x)` (mirror of `find_cave_floor` scanning above CAVE_TOP); `spawn_wave_flyer` (sky above surface, alternating near map edges); `spawn_wave_walker` (Vargr on surface floor near each edge); `spawn_wave_tunneller` (spawn_raider + `goal = .Wave_Hunt`, bracket columns like `spawn_tunneller_raid` :894). All set `goal = .Wave_Hunt`, `has_target = false` (first update self-targets).
- **Render** (`render.odin:2300`): Fire_Sprite placeholder → small deterministic hard-stepped flame off `t` (ember palette); Vargr → builder-shaped body in grey-wolf tint (surgical: palette variant of the existing builder draw, the raider-recolor precedent).
- Tests: `wave_hunters_smash_structures_not_plain_blocks`, `a_loaded_silo_never_traps_a_wave_hunter` (verify fails with `wave_target_refused` stubbed false), `air_wave_flyers_hold_altitude_and_close_on_their_prey`.

Verify: build + tests.

## Commit 4 — Wave director, craft trigger, F4 menu

Files: `src\game_state.odin`, new `src\wave.odin`, `src\update.odin`, `src\events.odin`, `src\ui.odin`, `src\input.odin`, `src\tests.odin`

- **State** (beside `Raid_State`, `game_state.odin:128`; transient like `gs.raid` — zero save impact, spawned enemies persist via Enemy_Store):
  ```odin
  Wave_Kind  :: enum u8 { Air, Ground, Underground }
  Wave_State :: struct { pending: bool, cycle: int }
  ```
  `wave: Wave_State` in Game_State next to `raid`.
- **Table + director** (`wave.odin`):
  ```odin
  Wave_Spec :: struct { enemy: Enemy_Kind, count: int, spawn: proc(gs: ^Game_State, n: int) -> int }
  @(rodata) wave_table := [Wave_Kind]Wave_Spec{
      .Air = {.Fire_Sprite, 4, spawn_air_wave}, .Ground = {.Vargr, 3, spawn_ground_wave},
      .Underground = {.Raider, 2, spawn_underground_wave},
  }
  ```
  `wave_force(gs, kind) -> int` — single entry point (spawn + notify + log), shared by director and F4 so the trigger stays decoupled. `update_waves(gs)` — consume `pending` on LEVEL_SURFACE: `wave_force(Wave_Kind(cycle % 3))`, advance cycle (pending holds while off-surface). Waves deliberately stack per craft (testing intent).
- **Update order**: insert step **5b1a `update_waves(gs)`** in `update.odin` right after `update_raids` (:56) — after update_sim, before `process_events`/`eq_clear` (:90) so pushed notify/sound events survive.
- **Trigger** (`events.odin:173-184`, `.Craft_Complete` case): `if crafted == .Fire_Wand do gs.wave.pending = true` — one line; swapping the trigger later = moving this line.
- **F4 menu**: `RAID_MENU_ROWS` 3→7 (`ui.odin:1423`), four new rows in `draw_raid_menu` ("Spawn AIR wave >", GROUND, UNDERGROUND, "Clear wave enemies >"); dispatch arms in `input.odin:863-869`; debug procs beside `enemy.odin:985-1034`: `debug_wave_spawn(gs, kind)` = wave_force; `debug_wave_clear` = despawn every `.Fire_Sprite`/`.Vargr` + every `.Raider` with `goal == .Wave_Hunt` (industry raiders survive), `gs.wave = {}`.
- Tests: `crafting_fire_wands_cycles_air_ground_underground_waves` (Craft_Complete → pending → three update_waves runs assert kind/count per table + wrap), `the_f4_wave_menu_forces_and_clears_waves` (precedent `tests.odin:3458`; seed a plain Builder + industry Raider, assert clear leaves them).

Verify: build, full suite, manual smoke — craft Fire Wand at bench → AIR wave dives at a placed Rainbow Laser → F4 clear.

---

## Verification (end-to-end)

1. Per commit: `odin build src` + `odin test src` green standalone (throwaway worktree outside the repo, per house precedent); gen commits also `gnipa_studio --emit-check`.
2. Save probe: `#assert` at `save.odin:24-25` must not fire (all changes are enum appends + transient state — if it fires, stop and redesign, never bump blindly).
3. Manual playtest script for Glenn: fresh world → grab 1 log + 1 stone → bench → both cards visible → place Rainbow Laser → craft Fire Wand → AIR wave (4 sprites fly in, attack structures, laser + wand kill them) → craft again → GROUND (3 Vargr walk in) → again → UNDERGROUND (2 tunnellers) → F4 menu force/clear each.
4. Update `context.md` + board task `submit` at session end.

## Risks / notes

- **Emit-check byte-fidelity**: hand gen-edits must match emitter format incl. notes.txt comments; if it fights, do the edit through the studio.
- **Flyer steering is naive** (rise-over-wall): fine on open surface, note for the real-trigger pass.
- **Laser targets any enemy** incl. neutral cave Builders if placed underground — playtest note, likely fine for a turret.
- **Numbers are first-guess** (laser 8/2/0.5s, wave counts 4/3/2, HP 4/8, damage 2) — Glenn tunes in playtest.
