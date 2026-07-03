# Gnipahellir3 — Architecture Review (pre-playtest, pre-Phase 4)

Reviewed: all of `Gnipahellir3/src` (19 files, ~3,500 lines) against the rules in
`Gnipahellir3/CLAUDE.md`, `Gnipahellir3/plan.md` (design doc), and root `Plan.md`
(ship plan). Build and `odin test src` both green at time of review.

Overall verdict: **the architecture is in good shape.** Fat struct, fixed buffers,
event-driven flow, and table-driven behavior are all genuinely honored — no
`[dynamic]` collections, no gameplay allocations, no render-side mutation found.
The findings below are ranked by how much they'll hurt if not addressed before
Phase 4 (builder economy) and Phase 5 (Garm/combat) build on top of them.

---

## A. Fix before Phase 4/5 (these get more expensive every phase)

### A1. The one-entity-per-tile invariant is not actually enforced
CLAUDE.md calls `World_Grid.entity_map` "the authoritative record of entity
positions — check before every move." Reality:

- Only the player writes to `entity_map` (`player.odin:44-57`). Builders never
  register, never check it, and never clear it. Two builders can (and do) occupy
  the same tile.
- Enemy → `Entity_ID` mapping is an ad-hoc `Entity_ID(id + 1)` buried in
  `builder_hunt` (`enemy.odin:1109`). This convention exists in exactly one place
  and is documented nowhere.
- `handle_entity_died` (`events.odin:158`) increments `total_kills` for a dead
  enemy but never calls `enemy_free`, never clears its `entity_map` cell. Nothing
  can damage enemies yet, so it's latent — but Phase 5 combat lands directly on
  this path.

**Suggestion:** decide now whether `entity_map` is real or aspirational.
If real: add `enemy_entity_id :: proc(i: int) -> Entity_ID { return Entity_ID(i+1) }`
(+ inverse), make `enemy_physics` maintain map cells like the player does, and
wire `Entity_Died` → `enemy_free` + map clear. If aspirational until Phase 5:
delete the claim from CLAUDE.md so nobody builds on an invariant that doesn't hold.

### A2. Two independent physics/collision implementations
`player_move_x/y` (`player.odin:133-211`) and `enemy_physics` +
`enemy_collides_x/y` (`enemy.odin:482-543`) are separate AABB resolvers with
different snap strategies (epsilon offset vs tile-flush snap), different gravity
constants, and subtly different edge behavior. Garm in Phase 5 becomes body #3.

**Suggestion:** extract one `move_body(w, ^pos, ^vel, size, dt) -> grounded`
in world.odin (or a new physics.odin) and make both callers use it before a third
copy appears. The enemy version's tile-snap approach is the better-commented and
more robust of the two — start from it.

### A3. Event-queue ordering trap: systems after `process_events` lose events silently
`game_update` (`update.odin`) runs `process_events` at step 6 and `eq_clear` at
step 9. Any event pushed by steps 7–8 (`update_particles` — planned for Phase 7,
`update_audio`) is destroyed unprocessed at step 9. Right now nothing after
step 6 pushes, so `eq_clear` is pure redundancy — which is exactly why the trap
is invisible.

**Suggestion:** either delete `eq_clear` (process_events already drains the queue,
and mid-processing pushes are correctly handled by the pop loop), or move it to
directly after `process_events` with a comment stating "systems after this point
must not push events." One line now saves a "why doesn't my particle sound play"
hunt in Phase 7.

### A4. Dead player can still place, craft, and perform rituals
`update_player` early-outs when `p.dead` (`player.odin:15`), which gates mining
and interact. But `update_input` pushes `Place_Request` / `Craft_Request`
unconditionally (`input.odin:42-58`), and `handle_place_request`,
`handle_craft_request`, `handle_ritual_request` never check `gs.player.dead`.
A corpse can build.

**Suggestion:** one guard at the top of `update_input`'s click section (or in the
three handlers). Worth fixing before the playtest — death is the roguelike's core
loss condition.

### A5. Mining has no reach limit
Placement enforces `PLACE_REACH :: 5` (`placement.odin:29`), but the mining path
in `update_player` (`player.odin:75-88`) checks only that the mouse tile is
mineable. Since the whole 192×108 grid is on screen, the player can excavate the
entire map — including digging open the sealed portal/blueprint chambers — from
spawn, without moving. This trivializes the level-gating that Phase 3 just built.
(Mana cost is already on the known-gaps list; reach is not.)

**Suggestion:** apply the same chebyshev reach check as placement (shared
constant), and add it to the tests. Do this before the human playtest or the
pacing feedback will be measuring the wrong game.

---

## B. Rules vs. reality drift (cheap to fix, mostly documentation)

### B1. Module "import" rules are unenforceable as written
CLAUDE.md's dependency rules are phrased as import constraints ("render.odin never
imports input.odin"), but every file is `package game` — there are no imports to
forbid, and nothing mechanical stops a violation. The *discipline* is currently
holding (render is read-only, input mutates only UI/inventory selection), but the
rule as stated can't fail a build.

**Suggestion:** either restate the rules as call-discipline ("draw_* procs take
`^Game_State` but must not mutate; grep-audit per phase"), or split into real Odin
packages if you want the compiler to enforce it. The former is proportionate for
a game this size.

### B2. Planned file layout has drifted from reality
plan.md's module layout lists `entity.odin`, `interaction.odin`,
`progression.odin`, `sim.odin`, `projectile.odin`, `particles.odin`, `debug.odin`.
Actual: progression + interaction + level gen all live in `levels.odin` (379
lines, four concerns), entity pooling lives in `enemy.odin`, and the design doc
still describes sky levels as negative indices while `levels.odin:11-14` uses
`LEVEL_SKY :: 3`.

**Suggestion:** update plan.md's layout section to match reality (it's the
document CLAUDE.md tells every future change to read first). Consider splitting
`levels.odin` when Phase 5 adds the boss arena — gen code and progression logic
are already interleaved there.

### B3. The static tables are mutable globals — violating your own forbidden pattern
`terrain_table`, `item_table`, `recipe_table`, `build_templates`,
`structure_costs`, `level_portals`, `level_names`, `sound_file`,
`sound_base_volume`, `tile_draw_style`, `CROWN_OFFSETS`, and the UI colors in
`ui.odin:21-24` are all file-scope `:=` variables. "Module-level mutable global
state" is item #1 on the forbidden list. Worse, `portal_at_player` returns a
`^Portal` *into* the mutable global table and `level_transition` reads through it
— one accidental write and every save shares the corruption.

**Suggestion:** mark the tables `@(rodata)` (Odin supports this for globals; they
become read-only memory and writes crash loudly). Where `@(rodata)` fights you
(slices like `build_templates` referencing arrays), a comment exempting
intentionally-static tables is acceptable — but the portal table, which hands out
pointers, deserves the real treatment.

### B4. Dead code / dead fields
- `is_walkable` (`world.odin:70-74`) has zero callers, and its logic makes the
  `.Walkable` flag meaningless (`walkable OR not solid` ≡ not solid).
- `Enemy_Store.free_head` (`game_state.odin:87`) — the plan says "free-list
  managed"; `enemy_alloc` is a linear scan and `free_head` is never read.
- `Input_State.drop_item` is polled (`input.odin:26`) but unused (known gap — Q
  does nothing).
- Several `Event_Type`s are pure documentation (`Player_Moved`, `Enemy_Moved`,
  `Level_Exit`, `Item_Dropped`, `Projectile_*`, `Play_Music`, `Stop_Music`) —
  fine as forward declarations, but the empty cases in `process_events` imply
  handlers exist elsewhere ("handled by player system") when they don't exist at
  all.

**Suggestion:** delete `is_walkable` and `free_head` (bump `SAVE_VERSION` for the
latter — it changes `Save_Data` layout), and reword the misleading no-op case
comments to "not yet implemented."

### B5. Input writes `player.inventory.selected` directly
`input.odin:38,45` mutates player data, while the rules say input may only push
events and toggle `UI_State`. It's benign, but it's the kind of small exception
that erodes the rule. Either move `selected` into `UI_State` (it *is* UI state —
which slot is highlighted) or note the exemption in CLAUDE.md.

---

## C. Robustness / correctness details

### C1. Save format: any struct edit silently requires a version bump
`Save_Data` is a raw memcpy including compiler padding (`save.odin`). The
size + version checks catch most drift, but a semantic change that keeps the same
size (e.g. reordering two `f32` fields, changing what `carry` means) loads
garbage as valid. Every phase from here on touches saved structs.

**Suggestion:** add `#assert(size_of(Save_Data) == <known value>)` next to
`SAVE_VERSION` so any layout change forces a conscious decision at compile time,
and adopt the habit: touching any saved struct = bump version in the same commit.
plan.md promised "versioned binary with migration path" — there is no migration
path (old saves are discarded); fine for pre-1.0, just say so in the doc.

### C2. Mining a tile clobbers an existing drop on that cell
`handle_tile_mined` (`events.odin:184-188`) overwrites `items[idx]`/`item_counts`
unconditionally. Sequence: mine ore (drop appears) → place a block on that cell →
mine the block → the original drop is replaced, not stacked. Rare but a real item
loss; one `if` to stack-or-skip fixes it. Matters more in Phase 4 when ore is a
contested resource.

### C3. `cstring` casts assume null-terminated string backings
`ui.odin:128` does `cstring(raw_data(item_table[s.item].name))` — safe today only
because Odin string *literals* are null-terminated. The moment a name is built or
sliced, this reads out of bounds. The `fmt.bprintf`-into-zeroed-buffer pattern
used elsewhere is fine; the direct name cast is the fragile one.
**Suggestion:** route names through the same fixed buffer, or use
`rl.DrawText` wrappers that take length.

### C4. Ritual is not location-validated
`handle_ritual_request` (`levels.odin:157`) fires for the first
blueprint-found/unbuilt tier regardless of which altar or which level the player
stands on. With one sky tier in v1.0 this is invisible (Cloud_Stone still forces
sky visits), but the design doc says altars work "on a sky level," and you can
currently ritual on the surface. Cheap to gate on `gs.level_index == LEVEL_SKY`
now; confusing to retrofit when more tiers exist.

### C5. Level transition mid-frame swaps the world under later systems
`player_interact` → `level_transition` runs inside `update_player` (step 2), so
`update_enemies` (step 3) runs the *destination* level's enemies on the same
frame, and events pushed pre-transition (sounds, pickups) resolve against the new
world at step 6. Harmless today because handlers are tile-index-based, but it's
implicit cross-frame state the rules say shouldn't exist.
**Suggestion:** set a `pending_transition: ^Portal` (or level index) on
`Game_State`, and perform the swap at a fixed, explicit position in
`game_update` (e.g. step 6.5, after events drain). That also gives you one clean
place for the Phase 6 fade/loading hook.

---

## D. Minor / cosmetic (batch these opportunistically)

- `update.odin:36`: the `frame % 300` flush check runs in release builds too;
  the no-op is inside `flush_action_log`. Wrap the call in `when GAME_DEBUG` for
  clarity (the log itself already is).
- `debug_log.odin:42`: the action log writes to `enemy_action.log` but records
  *all* actions (crafting, rituals, level entry). Rename to `action.log`.
- `player.odin:60`: sky fall-through threshold `85` is a magic number two rows
  below the base platform at 80 — name it (`SKY_FALL_Y`) next to the sky-gen
  constants it depends on.
- `eq_push` drops silently when full; plan.md says "log in debug." Add the
  debug log line — a saturated queue is exactly the bug you'll want evidence for.
- `astar_dig` puts ~130 KB on the stack per call (`g_cost` + `closed` + `nodes`)
  and re-initializes the full 20,736-cell `g_cost` each replan. Fine at 3
  builders; if Phase 4's soak test shows replan spikes, move the scratch buffers
  into `Game_State` (they're single-threaded scratch, not state).
- `draw_world` issues ~20k immediate-mode rectangles per frame. Fine at this
  grid size on desktop; only revisit if the Phase 7 juice pass hurts frame time.

---

## E. What's genuinely good (keep doing this)

- **Event cascades resolve in-frame correctly**: `process_events` pops until
  empty, so `Item_Pickup → Blueprint_Found` and `Structure_Complete →
  Cave_Unlocked` chains settle the same frame with no ordering bugs.
- **Zero gameplay allocations** — verified: every buffer is fixed, `new` appears
  only at startup/save/tests, `log_action` formats into a fixed ring.
- **The builder AI is well-factored**: goal enum + small procs per goal, watchdog
  with strike escalation, den protection as a pure predicate. Porting Garm onto
  `astar_dig` (Phase 5) looks low-risk.
- **Headless test suite driving real procs** is the right shape — extend it with
  A4/A5 regressions (dead-player actions rejected; out-of-reach mining rejected)
  when you fix them.
- **Comments explain *why*** (snap-flush rationale, void-snapshot cascade note,
  final-waypoint acceptance radius) — exactly the constraint-documenting style
  the codebase rules ask for.

---

## Suggested order of attack

1. **Before the human playtest:** A5 (mining reach), A4 (dead-player actions) —
   both change what the playtest measures. ~1 hour including tests.
2. **Phase 4 kickoff, before new code:** A1 (entity_map decision), A3 (eq_clear),
   B3 (`@(rodata)`), B4 (dead code + save version bump) — all small, all get more
   expensive once builder economy code lands on top.
3. **Phase 5 kickoff:** A2 (unified physics) as the first task, before Garm.
4. **Whenever touching the files anyway:** B1/B2 doc reconciliation, C-items, D-items.
