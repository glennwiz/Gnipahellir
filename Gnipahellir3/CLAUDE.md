# CLAUDE.md

Behavioral guidelines for this project. These rules are mandatory and apply to every code change.

Tradeoff: These guidelines bias toward caution over speed. For trivial tasks, use judgment.

---

## 1. Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

---

## 2. Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

---

## 3. Surgical Changes

Touch only what you must. Clean up only your own mess.

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

---

## 4. Goal-Driven Execution

Define success criteria. Loop until verified.

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

## 5. Project-Specific Rules (Gnipahellir3)

These extend the general rules above. All are mandatory.

### Language & Build

- Language: **Odin**
- Renderer: **Raylib** (vendor package only, no other dependencies)
- Build: `odin run src` — verify the project builds after every structural change
- Target: Windows primary

### Architecture

- **Fat struct**: all runtime state in `Game_State`. No module-level mutable globals.
- **Fixed-size arrays only**: no `[dynamic]` growth during gameplay. All buffers sized at startup.
- **Event-driven**: systems communicate via `Event_Queue`. No direct cross-system calls.
- **Render is read-only**: draw procs never mutate `Game_State`. No game logic in render.
- **Table-driven behavior**: terrain/item/enemy behavior in static tables. No `switch` sprawl.
- **Entity map**: `World_Grid.entity_map` is a per-tile position index — center
  tile, last-writer-wins — maintained by player/enemy updates via
  `entity_map_move`/`entity_map_clear` and used for entity lookups (combat
  targeting). It is NOT a movement constraint: bodies are continuous AABBs and
  may overlap. Entity_ID convention: player = 0, enemy slot i = i + 1
  (`enemy_entity_id`). Despawn goes through `despawn_enemy`, never bare
  `enemy_free`.
- **Deterministic update order**: new systems get an explicit line in `game_update`. No implicit ordering.

### Module Dependency Rules

- `render.odin` → may read `types.odin`, `world.odin`. Never imports `input.odin` or `update.odin`.
- `input.odin` → may push to `Event_Queue`, toggle `UI_State`. Never writes `World_Grid` directly.
- `world.odin`, `entity.odin` → never import `render.odin` or `input.odin`.
- `sim.odin` → never imports render or input.
- `types.odin`, `game_state.odin` → shared foundation; all modules may import them.

### Adding a New System: Checklist

1. Define data in `Game_State` with fixed sizes.
2. Create `update_<system>` proc taking `^Game_State`.
3. Register in `game_update` at the correct explicit position.
4. Add `Event_Type` entries to `types.odin` and emit as needed.
5. Implement `draw_<system>` — read-only, no state mutation.
6. If UI required: add fields to `UI_State`, handle input in `input.odin`, draw in `ui.odin`.

### Forbidden Patterns

- Render code calling gameplay updates.
- Systems directly mutating another system's internals across module boundaries.
- `[dynamic]` collections that grow during play.
- Module-level mutable global state.
- UI code writing to `World_Grid` or entity data outside designated update steps.
- `switch` sprawl for terrain/item/enemy behavior — use tables.
- TODOs in committed code — implement or file an issue.

### Key Constants (do not change without updating plan.md)

```
GRID_W          :: 192
GRID_H          :: 108
CELL_SIZE       :: 10
MAX_ENEMIES     :: 64
MAX_PARTICLES   :: 256
MAX_PROJECTILES :: 32
MAX_EVENTS      :: 512
```

### Game Context

See `plan.md` for full game description, progression system, level structure, terrain/item tables, and architectural data layout. Read it before adding any new system.
