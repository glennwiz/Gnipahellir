# Gnipahellir 3 — Plan

## Game Description

**Gnipahellir** ("Yawning Chasm" in Old Norse) is a fullscreen, grid-based 2D underground exploration and survival game. The player descends into a mythological Norse underworld, mining resources, building automation, facing increasingly dangerous entities, and navigating hazards like lava and magical corruption.

The game is inspired by two prototype iterations (Gnipahellir, Gnipahellir2) and improves upon them with a larger world, cleaner architecture, and a more intentional progression loop.

### Themes
- Norse mythology: Garm (hell hound guardian), Hel's depths, runic ore, magical corruption
- Digging deeper = higher risk, higher reward
- Automation (tree growers, smelters) enables scaling
- The player is fragile; the world is hostile

### Core Loop

The game has a **dual-axis progression**: the player alternates between descending into the underworld and ascending into the sky. Neither axis is completable alone.

```
Surface (Level 0)
    │
    ├── Descend to Cave 1
    │       └── Find Blueprint A
    │               └── Ascend to Sky -1
    │                       └── Build Sky Structure A  ──► Unlocks Cave 2
    │
    ├── Descend to Cave 2
    │       └── Find Blueprint B
    │               └── Ascend to Sky -2
    │                       └── Build Sky Structure B  ──► Unlocks Cave 3
    │
    ├── Descend to Cave 3
    │       └── Find Blueprint C
    │               └── Ascend to Sky -3 (Sky Peaks)
    │                       └── Build Final Sky Structure ──► Unlocks Final Boss
    │
    └── Final Boss (Cave 3 / Gnipahellir depths)
```

Each cycle:
1. Mine resources on the surface and current cave layer
2. Craft tools and automation (Tree Grower, Smelter, Crafting Bench)
3. Descend into the next cave — find the Blueprint for this cycle
4. Read the Blueprint to learn what the sky structure requires
5. Ascend to the matching sky level — gather sky-exclusive materials
6. Activate the Sky Altar with required resources → cave gate opens
7. Descend deeper, face new hazards and enemies
8. Repeat until the Final Sky Structure is built and the boss is reached

**Survive** — death is permanent (roguelike), persistent stats are preserved across runs.

---

## Grid & World

| Parameter        | Value                         |
|------------------|-------------------------------|
| Cell size        | 10 × 10 pixels                |
| Fullscreen res   | 1920 × 1080 (primary target)  |
| Grid dimensions  | 192 × 108 cells               |
| Total cells      | 20,736                        |
| Tile layers      | 2 (terrain + objects)         |
| Entity map       | 1 entity per cell, enforced   |

The grid is fixed-size and allocated at startup. No dynamic growth at runtime.

---

## Architecture Rules

These rules are mandatory. Every system added must comply.

### Fat Struct
All runtime state lives in `Game_State`. No module-level mutable globals. No hidden singletons.

### Data-First, Procedural
Systems are procs that accept `^Game_State` or a pointer to a contained sub-struct. No methods on game objects. No vtables.

### No Allocations During Gameplay
All buffers (particles, events, entities, projectiles) are fixed-size arrays initialized at startup. If a pool is full, the event or spawn is silently dropped (log in debug). Never grow at runtime.

### Deterministic Update Order
`game_update` calls update procs in explicit, numbered order. New systems must be inserted at the correct position. No implicit ordering via callbacks.

### Event-Driven Cross-System Communication
Systems do not call each other directly. They push events to `Event_Queue`. Events are consumed in a single `process_events` pass each frame. Queue is cleared at end of frame.

### Render is Read-Only
Draw procs read `Game_State` and call Raylib. They never mutate world state. UI may compute hover/layout hints but may not write to world or entity data. Exception: transient per-frame tooltip/hover state in `UI_State`.

### Module Responsibility Rules
All source files are one Odin package; these are call-discipline rules
(see CLAUDE.md for the authoritative wording):
- `draw_*` procs read `Game_State` and call raylib — never mutate game state
- `input.odin` pushes to `Event_Queue` and toggles `UI_State` — never writes `World_Grid` or entity data
- `world.odin`, `enemy.odin`, and sim code never call `draw_*` or input procs
- `types.odin` and `game_state.odin` are the shared foundation: types, constants, fat struct — no game logic

### Table-Driven Behavior
Terrain behavior, item properties, and entity stats are defined in static tables (indexed by enum). New terrain/item/enemy = new table entry. No scattered switch statements.

### Entity Map
`World_Grid.entity_map` is a per-tile position index (center tile,
last-writer-wins) maintained by player/enemy updates via `entity_map_move` /
`entity_map_clear`, and used for entity lookups such as combat targeting. It
is **not** a movement constraint — bodies are continuous AABBs and may
overlap. Entity_ID convention: player = 0, enemy slot i = i + 1
(`enemy_entity_id`). Despawn goes through `despawn_enemy`, which clears the
map cell and frees the pool slot.

### Pixel Art for Detailed Tiles
Cells are 10×10 pixels. Simple/background tiles (stone, grass, air, etc.) use a single `DrawRectangle` call. Tiles with visual detail (wood, leaves, flowers, and future decorative tiles) use a dedicated `draw_pixel_*` proc in `render.odin` that paints within the 10×10 cell pixel-by-pixel using `DrawRectangle` or `DrawPixel` calls.

- `Draw_Style` enum lives in `render.odin` (rendering concern, not game logic)
- `tile_draw_style` is a `[Tile_Type]Draw_Style` lookup table in `render.odin`
- Adding a detailed tile = one new `Draw_Style` entry + one new `draw_pixel_*` proc
- No changes to `types.odin`, `world.odin`, or terrain behavior table required

---

## Module / File Layout

```
src/
  main.odin        -- Window init, virtual-resolution transform, game loop
  types.odin       -- Build flags, constants, IDs, enums, events, nav types
  game_state.odin  -- All state structs + Game_State fat struct, init proc
  world.odin       -- Terrain table, grid + entity-map helpers, surface/cave-1 gen
  levels.odin      -- Level store, portals, transitions, ritual, cave 2-3 + sky gen
  physics.odin     -- Shared AABB body resolver (move_body), used by all bodies
  player.odin      -- Player update, intent, pickup, mining intent
  enemy.odin       -- Enemy pool, builder AI (A*, dens, hunting)
  input.odin       -- Input polling → intents/events, UI toggles
  events.odin      -- Event_Queue ops, process_events dispatcher
  update.odin      -- game_update: explicit update order
  crafting.odin    -- Recipe table, craft handler
  placement.odin   -- Place_Request validation + mutation
  items.odin       -- Item table, inventory ops
  audio.odin       -- Sound table, event-driven playback, depth ambience
  render.odin      -- draw_* procs (read-only), pixel-art tiles, debug overlay
  ui.odin          -- HUD, inventory/crafting windows, debug menu, hit tests
  save.odin        -- Versioned binary save/load, persistent stats
  debug_log.odin   -- Fixed-buffer action log (debug builds)
  tests.odin       -- Headless system tests (odin test src)
```

Planned but not yet split out: `sim.odin` (lava spread, tree growth),
`projectile.odin`, `particles.odin`; progression + interaction logic currently
lives in `levels.odin` and splits out when it grows (Phase 5).

---

## Game_State Fat Struct

```odin
Game_State :: struct {
    // World
    world:           World_Grid,
    level_index:     int,               // 0 = surface, >0 = caves, <0 = sky

    // Entities
    player:          Player,
    enemies:         Enemy_Store,       // fixed array, free-list

    // Systems
    projectiles:     Projectile_Store,
    particles:       Particle_Store,
    events:          Event_Queue,

    // Input / UI
    input:           Input_State,
    ui:              UI_State,

    // Simulation
    sim:             Sim_State,

    // Audio
    audio:           Audio_State,

    // Progression
    progression:     Progression_State,

    // Persistence
    stats:           Persistent_Stats,

    // Time
    elapsed_time:    f32,
    frame:           u64,
    delta_time:      f32,
}
```

---

## World_Grid Layout

```odin
GRID_W :: 192
GRID_H :: 108

World_Grid :: struct {
    terrain:     [GRID_W * GRID_H]Tile_Type,
    objects:     [GRID_W * GRID_H]Object_ID,     // doors, chests, benches
    items:       [GRID_W * GRID_H]Item_ID,
    item_counts: [GRID_W * GRID_H]u8,
    entity_map:  [GRID_W * GRID_H]Entity_ID,     // one entity per cell
    tile_flags:  [GRID_W * GRID_H]Tile_Flags,    // fire, poison, corrupted, etc.
    sim_data:    [GRID_W * GRID_H]Sim_Tile_Data, // growth timers, lava spread, etc.
}
```

Indexing: `terrain[y * GRID_W + x]`

---

## Entity Storage

```odin
MAX_ENEMIES   :: 64
PLAYER_ID     :: Entity_ID(0)
INVALID_ENTITY :: max(Entity_ID)

Enemy_Store :: struct {
    data:       [MAX_ENEMIES]Enemy,
    active:     [MAX_ENEMIES]bool,
    count:      int,
    free_head:  int,
}
```

Player is always `PLAYER_ID`. Enemies are allocated from `Enemy_Store`.

---

## Event System

```odin
MAX_EVENTS :: 512

Event_Type :: enum {
    // Movement
    Player_Moved,
    Enemy_Moved,

    // Combat
    Damage_Dealt,
    Entity_Died,

    // World
    Tile_Mined,
    Tile_Placed,
    Lava_Spread,
    Tree_Grew,

    // Items
    Item_Pickup,
    Item_Dropped,
    Craft_Request,
    Craft_Complete,

    // Projectiles
    Projectile_Fired,
    Projectile_Impact,

    // Audio
    Play_Sound,
    Play_Music,
    Stop_Music,

    // Transitions
    Level_Enter,
    Level_Exit,
    Level_Locked,
    Player_Died,

    // Progression
    Blueprint_Found,
    Structure_Complete,
    Cave_Unlocked,
    Boss_Defeated,
    Game_Won,
}

Event :: struct {
    type:    Event_Type,
    source:  Entity_ID,
    target:  Entity_ID,
    tile:    [2]i32,        // tile coords if relevant
    payload: Event_Payload, // union per type
}

Event_Queue :: struct {
    events: [MAX_EVENTS]Event,
    head:   int,
    tail:   int,
}
```

---

## Progression System

The progression system tracks which blueprints have been found and which sky structures are complete. It lives in `Game_State` and is saved/loaded with the rest of game state.

```odin
MAX_PROGRESSION_TIERS :: 3   // one per sky structure / cave gate pair

Progression_State :: struct {
    blueprint_found:        [MAX_PROGRESSION_TIERS]bool,
    sky_structure_complete: [MAX_PROGRESSION_TIERS]bool,
    cave_unlocked:          [MAX_PROGRESSION_TIERS]bool,   // index 0 = cave 2, etc.
    final_boss_defeated:    bool,
}
```

### Blueprint Items

Found as drops or placed objects in each cave level. When picked up, they set `blueprint_found[tier]` via a `Blueprint_Found` event. They can be inspected in the inventory to show:
- The target sky level
- Required materials and quantities for the Sky Altar activation

Blueprints are **not consumed** — they are a reference item kept in inventory.

### Sky Altar

A placeable workstation tile (`Sky_Altar`) available to the player from the start. Placed anywhere on a sky level. When interacted with:

1. The system checks `blueprint_found[tier]` for this sky level's tier
2. If blueprint not found: shows "You lack the knowledge to activate this"
3. If blueprint found: shows required materials from the tier's recipe
4. If player has all required materials: consumes them, marks `sky_structure_complete[tier]`, pushes `Structure_Complete` event
5. `process_events` handles `Structure_Complete` → sets `cave_unlocked[tier]`, pushes `Cave_Unlocked` notification

### Sky-Exclusive Materials

Each sky level produces materials not found underground, required by the sky structure recipes:

| Material       | Found At  | Use                        |
|----------------|-----------|----------------------------|
| Cloud_Stone    | Sky -1    | Sky Structure A ingredient |
| Aether_Crystal | Sky -2    | Sky Structure B ingredient |
| Runic_Sky_Ore  | Sky -3    | Final Sky Structure ingredient |

These are mineable terrain tiles unique to sky levels.

### Progression Events

```odin
Blueprint_Found,     // payload: tier index
Structure_Complete,  // payload: tier index → triggers cave unlock
Cave_Unlocked,       // payload: cave level index (for notification)
Level_Locked,        // payload: cave level index (player tried locked entrance)
Boss_Defeated,       // payload: entity ID
Game_Won,            // no payload
```

---

## Terrain Behavior Table

```odin
Terrain_Flags :: bit_set[enum {
    Solid, Walkable, Swimmable, Damaging,
    Flammable, Mineable, Placeable, Animated,
}]

Terrain_Behavior :: struct {
    name:       string,
    flags:      Terrain_Flags,
    color:      [4]u8,
    move_cost:  f32,         // 1.0 = normal, 2.0 = slow, 0 = solid
    damage_per_second: f32,
    drop_item:  Item_ID,
    on_enter:   proc(gs: ^Game_State, entity: Entity_ID, tile: [2]i32),
    on_stay:    proc(gs: ^Game_State, entity: Entity_ID, tile: [2]i32),
}

terrain_table := [Tile_Type]Terrain_Behavior { ... }
```

Adding a new terrain type = one entry in this table. No other files change.

---

## Terrain Types

| Name           | Solid | Mineable | Damage | Notes                          |
|----------------|-------|----------|--------|--------------------------------|
| Air            |       |          |        | Sky / above ground             |
| Void           |       |          |        | Underground empty space        |
| Grass          | X     | X        |        | Surface ground                 |
| Stone          | X     | X        |        | Common cave material           |
| Water          |       |          |        | Slows movement                 |
| Lava           |       |          | X      | 1 HP/0.5s, spreads             |
| Magic_Lava     |       |          | X      | Purple lava, faster spread     |
| Wood           | X     | X        |        | Tree trunk                     |
| Leaves         |       |          |        | Passable foliage               |
| Iron_Ore       | X     | X        |        | Drops iron ore item            |
| Silver_Ore     | X     | X        |        | Drops silver ore item          |
| Gold_Ore       | X     | X        |        | Drops gold ore item            |
| Gold_Rare_Ore  | X     | X        |        | Rare variant                   |
| Crafting_Bench | X     |          |        | Opens crafting UI on interact  |
| Tree_Grower    | X     |          |        | Auto-grows trees upward        |
| Smelter        | X     |          |        | Converts ores to refined bars  |
| Cave_Entrance  |       |          |        | Portal to next cave level      |
| Sky_Entrance   |       |          |        | Portal upward to sky levels    |
| Sky_Altar      | X     |          |        | Activate sky structure (workstation) |
| Cloud          |       |          |        | Sky platform, walkable         |
| Cloud_Ore      | X     | X        |        | Drops Cloud_Stone (sky -1)     |
| Aether_Ore     | X     | X        |        | Drops Aether_Crystal (sky -2)  |
| Runic_Sky_Ore  | X     | X        |        | Drops Runic_Sky_Ore item (sky -3) |
| Wind_Current   |       |          |        | Pushes player horizontally     |
| Void_Sky       |       |          | X      | Thin air — damages over time   |

---

## Item Types

| Name            | Placeable | Stackable | Notes                            |
|-----------------|-----------|-----------|----------------------------------|
| Sword           |           |           | Melee (future)                   |
| Potion_Health   |           | X         | Restores HP                      |
| Potion_Mana     |           | X         | Restores MP                      |
| Mine_Wand       |           |           | Primary mining tool (mana cost)  |
| Wood_Log        | X         | X         | Tree drop                        |
| Leaf            | X         | X         | Tree drop                        |
| Stone_Block     | X         | X         | Stone drop                       |
| Grass_Turf      | X         | X         | Grass surface drop               |
| Plank           | X         | X         | Crafted from Wood_Log            |
| Iron_Ore        |           | X         | Smelter input                    |
| Silver_Ore      |           | X         | Smelter input                    |
| Gold_Ore        |           | X         | Smelter input                    |
| Gold_Rare_Ore   |           | X         | Rare smelter input               |
| Crafting_Bench  | X         |           | Workstation                      |
| Tree_Grower     | X         |           | Automation                       |
| Smelter         | X         |           | Ore processing workstation       |
| Iron_Bucket     |           |           | Pick up and place lava           |
| Hell_Key        |           |           | Drops from Garm, unlocks depths  |
| Blueprint_A     |           |           | Found in Cave 1, inspectable     |
| Blueprint_B     |           |           | Found in Cave 2, inspectable     |
| Blueprint_C     |           |           | Found in Cave 3, inspectable     |
| Sky_Altar       | X         |           | Placeable workstation for sky structures |
| Cloud_Stone     |           | X         | Sky -1 ore drop, structure ingredient   |
| Aether_Crystal  |           | X         | Sky -2 ore drop, structure ingredient   |
| Runic_Sky_Ore   |           | X         | Sky -3 ore drop, structure ingredient   |

---

## Capacity Constants

| Buffer           | Capacity | Notes                          |
|------------------|----------|--------------------------------|
| Enemies          | 64       | Free-list managed              |
| Particles        | 256      | Increased from prototype       |
| Projectiles      | 32       | Wand stream + enemy fireballs  |
| Events per frame | 512      | Ring buffer, cleared per frame |
| Inventory slots  | 24       | Fixed per player               |
| Crafting recipes | 16       | Static table                   |
| Audio sounds     | 128      | Loaded at startup              |
| Levels           | 16       | 0=surface, 1-12=caves, -1to-3=sky |

---

## Update Order (game_update)

```
1. update_input          -- poll hardware → intents into Event_Queue
2. update_player         -- physics, movement, mana regen
3. update_enemies        -- AI state machines, movement, attacks
4. update_projectiles    -- travel, impact detection
5. update_sim            -- lava spread, tree growth, decay timers
6. process_events        -- consume Event_Queue, dispatch to handlers
   └── handle_progression_events (Blueprint_Found, Structure_Complete, Cave_Unlocked)
7. update_particles      -- lifetime, position, fade
8. update_audio          -- process sound events, stream music
9. clear_event_queue     -- end of frame cleanup
```

New systems are inserted at the correct position. Order is never implicit.

---

## Player

```odin
Player :: struct {
    // World position (tile units, continuous)
    pos:          [2]f32,
    vel:          [2]f32,

    // Stats
    hp:           int,
    hp_max:       int,
    mana:         f32,
    mana_max:     f32,
    mana_regen:   f32,     // per second

    // Inventory
    inventory:    Inventory,
    equipped:     Item_ID,
    bucket_lava:  bool,

    // State
    grounded:     bool,
    facing:       int,     // -1 left, 1 right
    dead:         bool,
    death_timer:  f32,

    // Animation
    anim_frame:   int,
    anim_timer:   f32,
    walk_anim_period: f32,

    // Cosmetic (randomized at init)
    clothing_color: [4]u8,
    hair_color:     [4]u8,
}
```

**Physics**: Gravity 18 tiles/s², terminal velocity 12 tiles/s, jump impulse -10 tiles/s, horizontal max speed 6 tiles/s.

---

## Enemies

| Name  | ID | HP | Behavior               | Drop      |
|-------|----|----|------------------------|-----------|
| Garm  | 1  | 30 | Chase + builder AI     | Hell_Key  |

More enemy types to be added per cave layer. Each gets a row in `enemy_behavior_table`.

---

## Level Structure

### Underworld (descend, index > 0)

| Level | Name            | Hazards               | Enemies       | Gives             | Gate              |
|-------|-----------------|-----------------------|---------------|-------------------|-------------------|
|  1    | Shallow Cave    | Lava pools            | None          | Blueprint A       | Open              |
|  2    | Deep Cave       | Lava + Magic Lava     | Garm          | Blueprint B       | Sky Structure A   |
|  3    | Gnipahellir     | All lava + corruption | Garm + TBD    | Blueprint C       | Sky Structure B   |
|  4    | Final Depths    | All hazards + boss    | Final Boss    | Victory           | Final Sky Struct  |

### Surface (index 0)

| Level | Name     | Hazards | Notes                                  |
|-------|----------|---------|----------------------------------------|
|  0    | Surface  | None    | Starting area. Portals to ±1 on edges. |

### Sky World (ascend, index < 0)

> **v1.0 implementation note:** the shipped build uses a flat index space —
> 0 = surface, 1–2 = deep caves, 3 = low sky (`LEVEL_*` constants in
> `levels.odin`). The negative-index multi-tier sky below is the post-launch
> design.

| Level | Name            | Hazards          | Materials           | Builds              | Unlocks    |
|-------|-----------------|------------------|---------------------|---------------------|------------|
| -1    | Low Sky         | Wind gusts       | Cloud Stone         | Sky Structure A     | Cave 2     |
| -2    | Cloud Layer     | Thin air (dmg)   | Aether Crystal      | Sky Structure B     | Cave 3     |
| -3    | Sky Peaks       | Lightning, wind  | Runic Sky Ore       | Final Sky Structure | Final Boss |

### Level Gating

Each cave level beyond 1 is **locked** until the matching sky structure is complete:

```
cave_unlocked[2] = sky_structure_complete[1]   // Sky -1 structure → Cave 2
cave_unlocked[3] = sky_structure_complete[2]   // Sky -2 structure → Cave 3
cave_unlocked[4] = sky_structure_complete[3]   // Sky -3 structure → Final Boss
```

A locked Cave Entrance shows a runic seal and emits a `Level_Locked` notification on interact.

---

## Win / Loss Conditions

- **Loss**: Player HP reaches 0. Death is permanent (roguelike). Stats (deaths, playtime, tiles mined) are saved to a separate persistent file and persist across runs.
- **Win**: Build all three Sky Structures (unlocking each cave gate in sequence), defeat the Final Boss in the deepest cave, and interact with the Victory Altar. Emits `Game_Won` event which triggers end screen and stat save.

---

## Rendering Pipeline

```
draw_frame(gs: ^Game_State):
  BeginDrawing()
    ClearBackground()
    BeginMode2D(camera)
      draw_terrain_layer(gs)     -- terrain tiles, culled to camera rect
      draw_object_layer(gs)      -- benches, smelters, growers
      draw_items_on_ground(gs)
      draw_projectiles(gs)
      draw_particles(gs)
      draw_enemies(gs)
      draw_player(gs)
    EndMode2D()
    draw_hud(gs)                 -- health, mana, equipped item
    draw_ui_windows(gs)          -- inventory, crafting, character
    draw_notifications(gs)       -- timed popup messages
    draw_debug_overlay(gs)       -- F3 only
  EndDrawing()
```

All draw procs are read-only. No `gs` mutations inside this call tree.

---

## UI Windows

| Window        | Key  | State in UI_State       |
|---------------|------|--------------------------|
| Inventory     | B    | inventory_open, position |
| Character     | C    | character_open, position |
| Build Menu    | R    | build_open, scroll       |
| Crafting      | auto | crafting_open (on bench) |
| Debug Overlay | F3   | debug_open               |
| Stats         | F10  | stats_open, scroll       |
| Settings      | menu | settings_open            |
| Save/Quit     | F5   | save_quit_open           |

---

## Improvements Over Gnipahellir2

| Area             | Prototype (Gnipahellir2)         | Gnipahellir3                              |
|------------------|----------------------------------|-------------------------------------------|
| Grid size        | 50×50 @ 16px                    | 192×108 @ 10px (fullscreen)               |
| Fullscreen       | 1280×1024 window                 | True fullscreen, resolution-adaptive      |
| Enemy variety    | Only Garm                        | Per-level enemy table (extensible)        |
| Event types      | ~12                              | ~20+, with payload union                  |
| Terrain table    | Scattered switch statements      | `terrain_table` — fully declarative       |
| Level count      | ~8 (partial)                     | 16 planned, generation per layer          |
| Win condition    | Undefined                        | Defined: Hell_Key + altar                 |
| Capacity buffers | Small (128 particles, 16 proj)   | Larger: 256 particles, 32 proj            |
| Save system      | Binary blob                      | Versioned binary with migration path      |
| Doc coverage     | RULES.md + Arkitecture.md        | plan.md + Arkitecture.md (this document)  |

---

## Build & Run

```sh
odin run src          # build and run
odin build src        # build only
```

Target: Windows primary, Odin + Raylib vendor package.

---

## Adding a New System: Checklist

1. Define data fields in `Game_State` with fixed-size arrays
2. Create `update_<system>` proc accepting `^Game_State`
3. Register in `game_update` at the correct explicit position
4. Add any `Event_Type` variants to the enum in `types.odin`
5. Push events from producers; handle in `process_events`
6. Implement `draw_<system>` proc — read-only, no state mutation
7. If UI is needed: add fields to `UI_State`, handle input in `input.odin`, draw in `ui.odin`
8. Add a section to `Arkitecture.md` if the system is cross-cutting

---

## Forbidden Patterns

- Render code calling gameplay updates
- Systems directly mutating another system's internals across module boundaries
- Dynamic collections that grow during play (`[dynamic]` in hot path)
- Module-level mutable global state (except `Game_State` pointer passed from main)
- UI code writing to `World_Grid` or entity data directly outside designated update steps
- `switch` sprawl for terrain/item/enemy behavior (use tables)
- TODOs in committed code — implement or file an issue
