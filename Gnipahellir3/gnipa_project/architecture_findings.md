# Architecture Findings — Gnipahellir3

Review date: 2026-07-05. Scope: full read of `src/*.odin` (~7.7k LOC), focused on
whether the current architecture can carry a **machine dependency chain** —
e.g. `power/mana generator → orb creator → assembler`, machines consuming the
output of other machines.

**Verdict up front:** You are in a *good* place. Do **not** remake or refactor
the core. The architecture was, in fact, already designed with this exact
expansion in mind — there are reserved-but-unused hooks (`objects` layer,
`sim_data`, `Sim_State`, the commented `update_sim` slot) waiting for it. The
work is additive, not corrective. The one real design decision left open is
*how machines move items and power between each other* — that choice is yours
to make and this document recommends a path.

---

## 1. How the codebase is built (the patterns that matter here)

The conventions in `CLAUDE.md` are followed faithfully in the code. The ones
relevant to a machine system:

- **Fat struct** — all runtime state lives in one `Game_State` (`game_state.odin:296`).
  New systems add a fixed-size member. No globals.
- **Table-driven behavior** — `terrain_table` (`world.odin:17`), `item_table`
  (`items.odin:16`), `recipe_table` (`crafting.odin:25`), `wand_mine_range`,
  `structure_templates`. Behavior is data, not `switch` sprawl. This is *exactly*
  the right shape for machine recipes.
- **Event-driven, single drain** — systems push to `Event_Queue`; `process_events`
  (`events.odin:31`) drains it once per frame, then `eq_clear` wipes it. Handlers
  may push mid-drain and those get processed; anything pushed *after* the drain
  step is destroyed. Ordering is load-bearing.
- **Deterministic update order** — `game_update` (`update.odin:3`) is an explicit
  numbered list. New systems get an explicit line.
- **Render is read-only** — `draw_*` never mutates state.
- **Save is a raw memory snapshot** — `Save_Data` is memcpy'd to disk
  (`save.odin:23`). Any layout change to a saved struct bumps `SAVE_VERSION` and
  the size assert (`save.odin:20`).

None of these fight a production system. Three of them (tables, fixed stores,
explicit tick order) actively help.

---

## 2. What "machines" are *today* — and the gap

Current machines — `Crafting_Bench`, `Smelter`, `Tree_Grower` — are **not
machines**. They are `Tile_Type` values with terrain flags (`world.odin:31-33`)
and a matching `Item` that places them (`items.odin:34-36`). Concretely:

- **Crafting_Bench** is the only one that "does" anything, and only passively:
  `player_near_bench` (`crafting.odin:39`) checks chebyshev range so bench-gated
  recipes unlock. The bench has no state and never ticks.
- **Smelter** and **Tree_Grower** are **inert placed blocks.** You can craft them
  (`recipe_table`), place them, and mine them back — but there is **no code that
  makes them convert anything.** plan.md line 405 says the Smelter "converts ores
  to refined bars"; that behavior does not exist. Grep confirms: outside the
  recipe/item/terrain tables and one test, `Smelter` and `Tree_Grower` appear
  nowhere.
- **There is no tick.** `update_sim` is commented out (`update.odin:24`).
  `Sim_State` (`lava_tick_timer`, `tree_tick_timer`) is declared, saved, and
  never read. `Sim_Tile_Data` (`growth_timer`, `spread_timer`) per cell is
  declared, saved, and never read. `Lava_Spread` / `Tree_Grew` events have empty
  handlers marked "Phase 4+".

**So the gap is precise:** there is no per-machine instance state and no
simulation step to advance it. That is the entire thing you need to build. The
crafting model you have (`recipe_table` + event-driven `handle_craft_request`)
is *player-pull* crafting — the player stands near a bench and spends inventory.
A machine chain is *autonomous push/pull* — machines run on their own each tick.
These are different mechanisms; the second one is missing, not broken.

---

## 3. The reserved scaffolding (this is the good news)

The original author left the machine layer stubbed in on purpose. You are not
starting from scratch:

| Hook | Location | Status | Use for machines |
|------|----------|--------|------------------|
| `objects: [GRID_W*GRID_H]Object_ID` | `game_state.odin:14` | **declared, 100% unused** | per-tile index into a machine store |
| `Object_ID :: distinct u8` | `types.odin:30` | declared, unused | machine handle type |
| `sim_data: [...]Sim_Tile_Data` | `game_state.odin:19` | declared, saved, unread | per-tile timers (or superseded by a store) |
| `Sim_State` | `game_state.odin:256` | declared, saved, unread | global sim timers/power pool |
| `update_sim(gs)` slot | `update.odin:24` | commented placeholder | the machine tick, step 5b |
| `Lava_Spread`, `Tree_Grew` events | `types.odin:139-140` | empty handlers | precedent for sim-emitted events |

Because `World_Grid` (with its unused `objects` array) already rides inside
`Save_Data`, wiring machines through the `objects` layer costs **nothing extra in
save format** beyond a version bump — the bytes are already being written.

---

## 4. Recommended design for the power → orb → assembler chain

This is the one place a decision is genuinely open. Two sub-problems: **how power
is distributed** and **how items move between machines.** Both have a
simple-first answer that fits the existing architecture and defers the hard
logistics work until you know you want it.

### 4a. Machine instance state — use a store + the `objects` layer

Mirror the enemy pattern (`Enemy_Store` + `entity_map`). Add:

```odin
Machine_Kind :: enum u8 { None, Mana_Generator, Orb_Creator, Assembler }

Machine :: struct {
    kind:     Machine_Kind,
    tile:     [2]i32,
    in_buf:   [2]Inventory_Slot,  // small fixed input buffers
    out_buf:  Inventory_Slot,     // single output buffer
    progress: f32,                // seconds into current job
    active:   bool,
}

MAX_MACHINES :: 128
Machine_Store :: struct {
    data:  [MAX_MACHINES]Machine,
    count: int,
}
```

`objects[grid_idx(x,y)]` holds `Object_ID` = machine index + 1 (0 = none),
exactly like the `enemy slot i → entity_id i+1` convention. Placement allocates a
machine and writes the index; mining frees it. Add `machines: Machine_Store` to
`Game_State` and `Save_Data`.

Keep the machines as `Tile_Type`s too (for rendering/terrain flags as they are
now) — the `objects` layer just attaches instance state on top. No conflict.

### 4b. Machine recipes — a new table (don't overload `recipe_table`)

`recipe_table` is player/bench crafting; keep it. Add a parallel, table-driven
machine table so behavior stays data:

```odin
Machine_Recipe :: struct {
    kind:        Machine_Kind,
    inputs:      [2]Ingredient,
    output:      Item,           // e.g. .Mana_Orb
    output_count:int,
    job_time:    f32,            // seconds per unit
    power_cost:  f32,            // drawn per second while running (0 for generators)
    power_gen:   f32,            // produced per second (generators only)
}
```

`Mana_Generator` has `power_gen > 0` and no inputs (or consumes a fuel item).
`Orb_Creator` consumes power + a raw input, outputs `Mana_Orb`. `Assembler`
consumes power + orbs + parts, outputs the final good. New machines = new table
rows. This honors "no switch sprawl."

### 4c. Power distribution — start with a **global pool**, not wiring

Two models:

- **Global pool (recommended first).** One `power: f32` (plus `power_cap`) in
  `Sim_State`. Each tick: generators add to the pool, consumers draw from it; if
  the pool can't cover all consumers this tick, they stall (or run proportionally
  slower). **No wiring, no connectivity graph, no flood-fill.** This is the
  Satisfactory-early / Terraria-wiring-lite feel and is ~40 lines.
- **Local network (defer).** Power flows only through adjacent machines/conduits;
  requires a connectivity pass (flood-fill or union-find) whenever a machine or
  wire is placed/mined. Much more code and a whole new "conduit" tile type. Only
  build this if "managing power grids" is a design *goal*, not a side effect.

**Recommendation:** ship the global pool. It delivers the dependency fantasy
("the generator must be running or the assembler stops") immediately. You can add
locality later without throwing the pool away (the pool becomes per-network).

### 4d. Item handoff between machines — start with **adjacency pull**

How does the orb creator's output reach the assembler? Three models, increasing
cost:

1. **Player-carried (simplest).** Machines have buffers; the player pulls output
   into inventory and loads it into the next machine by hand. Reuses your
   existing interact/inventory flow. Least automation.
2. **Adjacency pull (recommended).** On tick, a machine with a free input buffer
   pulls a matching item from an orthogonally-adjacent machine's output buffer.
   Chains work if you place them touching. ~15 lines in the tick, no new tiles,
   no pathing. This is enough to *feel* like a factory.
3. **Belts/conduits (defer).** Full logistics tiles that carry items across
   distance. Big feature: new tile types, item-in-transit entities, render work.
   Don't build this until adjacency proves the loop is fun.

### 4e. The tick — reclaim the `update_sim` slot

Add `update_machines(gs)` at step 5b in `game_update` (the commented
`update_sim` line), **before `process_events`** so anything it emits (sound,
"output full" notify, completion particles) drains the same frame.

```
update_machines:
  for each active machine, in index order (deterministic):
    if generator:  sim.power = min(cap, sim.power + power_gen*dt)
  for each active machine, in index order:
    (adjacency pull into input buffers)
    if inputs satisfied and sim.power >= power_cost*dt:
      sim.power -= power_cost*dt
      progress  += dt
      if progress >= job_time: consume inputs, add to out_buf, reset
```

**Critical:** machines own their own buffers, so intra-machine transfers happen
**directly in this step, not through events.** Only emit events for cross-system
effects (audio/particles/notify). Routing per-tick item production through the
512-slot `Event_Queue` would saturate it (see §5).

---

## 5. Risks & watch-outs (all manageable)

1. **Event queue saturation.** `MAX_EVENTS = 512`, dropped-on-full
   (`events.odin:6`). 128 machines each emitting a couple events per frame is
   fine; 128 machines emitting per *item* per tick is not. Rule: **machine state
   changes are direct writes; events are only for audio/UI/particles.** The
   debug drop-counter (`update.odin:43`) will warn you if you get this wrong.
2. **Save versioning.** Adding `Machine_Store` to `Game_State`/`Save_Data` bumps
   `SAVE_VERSION` and the `SAVE_DATA_EXPECTED_SIZE` assert (`save.odin:20`). The
   assert is a tripwire by design — it will fail to compile until you update it,
   which is the intended safety. One-line change, same commit. `MAX_MACHINES` is
   pure fixed cost in the save (128 × sizeof(Machine)); keep it sane.
3. **Fixed-array cap.** `MAX_MACHINES` is a hard ceiling — pick it deliberately
   and have placement fail gracefully (notify "too many machines") when full,
   the way enemy alloc is bounded.
4. **Determinism.** Iterate the machine store by index in a fixed order in the
   tick, so adjacency pulls resolve the same way every frame. Two machines
   pulling from one output in the same tick = last/first-writer-wins; make it
   explicit.
5. **Render.** You'll want progress bars / buffer glyphs on machines. That's a
   new read-only `draw_machines(gs)` in the object layer pass
   (plan.md line 594 already reserves "benches, smelters, growers"). No state
   mutation — fits the rule.
6. **Placement coupling.** `placement.odin` currently only sets a tile. Machine
   placement additionally allocs a `Machine` and writes the `objects` index;
   mining must free it in `handle_tile_mined` (`events.odin:240`). Keep the
   tile-and-object writes together so they never desync.
7. **Odin dead scaffolding.** `sim_data` and `Sim_State`'s current fields may be
   redundant once machines carry their own timers. Decide whether machine timers
   live in `Machine` (recommended) or `sim_data`; don't maintain both. If
   `sim_data` goes unused permanently, note it rather than leaving two timer
   homes.

---

## 6. Should you refactor anything first? — No, but two small tidy-ups help

You do **not** need a remake. Before building the machine layer, two optional
low-risk cleanups make it cleaner:

- **Nothing is required.** The `objects`/`sim_data`/`update_sim` hooks are
  usable as-is.
- *(Optional)* Decide the timer home now (§5.7) so you don't add `Machine.progress`
  and keep writing `sim_data` — pick one.
- *(Optional)* When you add `update_machines`, either implement or delete the
  long-dormant `Lava_Spread`/`Tree_Grew` empty handlers so the sim step has one
  clear owner instead of three half-stubs. (CLAUDE.md forbids committed TODOs;
  these empty "Phase 4+" cases are effectively that.)

---

## 7. Concrete build order (each step verifiable)

1. `Machine_Kind`, `Machine`, `Machine_Store`; add `machines` to `Game_State`.
   → verify: `odin run src` builds.
2. `machine_recipe_table` with just `Mana_Generator` (power only, no I/O).
   → verify: place it, `update_machines` grows `sim.power` (F3/debug readout).
3. Placement/mining alloc+free the machine via the `objects` layer.
   → verify: place then mine leaves no orphan machine (count returns to 0).
4. `Orb_Creator`: consumes power, outputs `Mana_Orb` into `out_buf`.
   → verify: orb count rises only while power > 0.
5. Adjacency pull; `Assembler` consuming orbs from a neighboring orb creator.
   → verify: a generator+creator+assembler line placed touching produces the
     final good; break the generator and the line stalls.
6. `draw_machines` progress/buffer overlay; bump `SAVE_VERSION` + size assert;
   add to `Save_Data`. → verify: save/reload preserves a running line.

Each step is a small verified commit — the workflow this project already uses.

---

## Bottom line

The architecture is a good fit and was pre-wired for this. Build the machine
system as a **new store + new table + the reclaimed `update_sim` tick**, start
with a **global power pool** and **adjacency item handoff**, keep per-tick logic
out of the event queue, and bump the save version. No refactor of existing
systems is warranted before you begin.
