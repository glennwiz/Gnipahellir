# Engineering Rules and Conventions

Strict guidelines to prevent coupling, preserve performance, and keep the codebase coherent. These rules are mandatory.

## Core patterns
- **Fat struct**: all runtime state must be reachable from `Game_State`. Prefer fixed-size arrays over dynamic containers.
- **Data-first, procedural**: operate on `^Game_State` or pointers to contained structs.
- **No runtime allocations during gameplay**: initialize memory at startup.
- **Deterministic update order**: new systems are added explicitly to `game_update`.
- **Event-driven cross-system communication**: no hidden backreferences.
- **Render is read-only**: immediate-mode UI may compute layout/hover hints but must not mutate world state.

## File/module boundaries
- Do not import render/UI modules from core systems. Core may not depend on UI.
- Input code may toggle UI state and enqueue gameplay intents; gameplay effects occur in update steps.
- World generation and hazard simulations live outside of render and input. Keep long-running sims in dedicated modules.
- Keep enums/types with many consumers in `world.odin` (or a dedicated types file) and evolve carefully.

## Function design
- Functions are verbs; pass explicit state (`^Game_State`, `^World_Grid`, etc.).
- No global mutable state outside `Game_State` and module-local temporaries.
- Avoid deep call chains across modules. Prefer event emission or local helpers.
- Keep update functions pure relative to their responsibilities; avoid rendering calls or I/O.

## Events
- Add a new `Event_Type` when a system’s output should be observed by another system.
- Producers push to `Event_Queue`; consumers read only during `process_events` or a dedicated events phase.
- Clear the queue once processed each frame.

## UI and input
- Input polling lives in `input.odin` (and future `ui_input.odin`).
- UI state is consolidated in `UI_State`. Any UI window must store its open/position/drag state there.
- Drag/drop and click decisions are computed during input/update, not during drawing.
- Tooltips/hover are transient per-frame and may be set during render.

## World rules
- One entity per tile enforcement via `world.entities`.
- Use `bounds_check`, `tile_is_solid`, `tile_is_walkable` for all movement/collision decisions.
- Prefer table-driven behavior for terrain and items. Avoid hard-coded switch expansion; centralize in tables.

## Performance and memory
- No heap growth in the hot path. Use fixed capacities and reuse buffers.
- Keep per-frame work O(visible tiles + active entities/effects). Avoid O(WORLD_WIDTH*WORLD_HEIGHT) scans unless amortized or necessary.
- Use simple math and branchless paths where reasonable, but prioritize clarity.

## Naming and style
- Descriptive names; avoid abbreviations. Functions as verbs, data as nouns.
- Early returns for error/edge cases.
- Do not leave TODOs; implement or file an issue.
- Match existing formatting; wrap long lines.

## Adding a new system: checklist
- Define data in `Game_State` with fixed sizes.
- Create `update_*` proc that takes `^Game_State` (or relevant sub-struct pointer).
- Register the update in `game_update` at the proper order.
- Add any `Event_Type` and emit as needed.
- Implement rendering in a separate draw proc; no state mutation there.
- If UI is required, add fields to `UI_State`, handle inputs in input/UI-input, and draw in a UI module.
- Provide a short section in `Arkitecture.md` if the system is cross-cutting.

## Coupling anti-patterns (forbidden)
- Rendering code calling gameplay updates.
- Systems directly mutating other systems’ internals across modules (except through `Game_State` pointers to their own data or via events).
- Adding dynamic collections that grow during play.
- Hidden singletons or module-level global mutable state.
- UI code modifying world tiles/items directly outside the designated interaction/update steps.

## Testing/integration expectations
- After structural changes, ensure the project still builds: `odin run src`.
- Favor small, incremental edits. Avoid mixing refactors with feature changes in the same commit.

## Example: terrain behavior table (directional)
- Introduce a `Terrain_Behavior` table with flags and optional callbacks like `on_enter`, `on_stay` to replace scattered `switch` checks. This keeps new terrain additions declarative and prevents logic spreading across modules.

By following these rules, we keep the data-first, fat-struct architecture predictable, fast, and easy to extend without introducing tight coupling.
