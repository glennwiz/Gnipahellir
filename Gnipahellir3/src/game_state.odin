package game

import rl "vendor:raylib"

// ─── World Grid ───────────────────────────────────────────────────────────────

Sim_Tile_Data :: struct {
    growth_timer: f32,
    spread_timer: f32,
}

World_Grid :: struct {
    terrain:     [GRID_W * GRID_H]Tile_Type,
    objects:     [GRID_W * GRID_H]Object_ID,
    items:       [GRID_W * GRID_H]Item,
    item_counts: [GRID_W * GRID_H]u8,
    entity_map:  [GRID_W * GRID_H]Entity_ID,
    tile_flags:  [GRID_W * GRID_H]Tile_Flags,
    sim_data:    [GRID_W * GRID_H]Sim_Tile_Data,
}

// ─── Entity Storage ───────────────────────────────────────────────────────────

Enemy_Kind :: enum u8 {
    Garm,
    Undead,
    Fire_Sprite,
    Builder,
}

Enemy_Nav :: struct {
    path:       Nav_Path,
    mine_timer: f32,   // cooldown after a mine/place action
}

Build_Kind :: enum u8 {
    Cairn,
    Pillar,
    Shelter,
}

Builder_Goal :: enum u8 {
    Build_Den,      // zero value: builders boot into den construction
    Fetch_Mineral,  // travel to an ore vein and mine one block
    Encase_Den,     // carry the block home and place it on the den shell
    Hunt,           // chase and bite the player
    Cooldown,
}

Builder_State :: struct {
    goal:         Builder_Goal,
    resume:       Builder_Goal, // goal to return to when Cooldown ends
    build:        Build_Kind,   // den template
    anchor:       [2]i32,       // den anchor; {0,0} = no den site yet
    step:         int,          // next den template tile index
    den_built:    bool,
    carry:        Tile_Type,    // mineral being hauled (.Air = empty hands)
    target_tile:  [2]i32,       // current ore target
    has_target:   bool,
    avoid:        [4][2]i32,    // recently given-up targets, skipped in searches
    avoid_n:      int,
    plan_target:  [2]i32,       // player tile the hunt path was planned for
    los_timer:    f32,          // seconds since the player was last visible
    attack_timer: f32,
    cooldown:     f32,
    replan_timer: f32,
    stuck_timer:  f32,          // seconds without path progress (watchdog)
    stuck_count:  int,
}

Enemy :: struct {
    pos:      [2]f32,
    vel:      [2]f32,
    hp:       int,
    hp_max:   int,
    kind:     Enemy_Kind,
    facing:   int,
    grounded: bool,
    nav:      Enemy_Nav,
    builder:  Builder_State,
}

Enemy_Store :: struct {
    data:      [MAX_ENEMIES]Enemy,
    active:    [MAX_ENEMIES]bool,
    count:     int,
    free_head: int,
}

// ─── Inventory ────────────────────────────────────────────────────────────────

Inventory_Slot :: struct {
    item:  Item,
    count: int,
}

Inventory :: struct {
    slots:    [MAX_INVENTORY]Inventory_Slot,
    selected: int,
}

// ─── Player ───────────────────────────────────────────────────────────────────

Player :: struct {
    pos:              [2]f32,
    vel:              [2]f32,
    hp:               int,
    hp_max:           int,
    mana:             f32,
    mana_max:         f32,
    mana_regen:       f32,
    inventory:        Inventory,
    equipped:         Item,
    bucket_lava:      bool,
    grounded:         bool,
    facing:           int,
    dead:             bool,
    death_timer:      f32,
    anim_frame:       int,
    anim_timer:       f32,
    walk_anim_period: f32,
    clothing_color:   rl.Color,
    hair_color:       rl.Color,
}

// ─── Projectiles ──────────────────────────────────────────────────────────────

Projectile :: struct {
    pos:    [2]f32,
    vel:    [2]f32,
    owner:  Entity_ID,
    active: bool,
    damage: int,
}

Projectile_Store :: struct {
    data:  [MAX_PROJECTILES]Projectile,
    count: int,
}

// ─── Particles ────────────────────────────────────────────────────────────────

Particle :: struct {
    pos:      [2]f32,
    vel:      [2]f32,
    color:    rl.Color,
    lifetime: f32,
    age:      f32,
    active:   bool,
}

Particle_Store :: struct {
    data:  [MAX_PARTICLES]Particle,
    count: int,
}

// ─── Event Queue ──────────────────────────────────────────────────────────────

Event_Queue :: struct {
    events:  [MAX_EVENTS]Event,
    head:    int,
    tail:    int,
    size:    int,
    dropped: int,   // pushes rejected because the queue was full (debug telemetry)
}

// ─── Input ────────────────────────────────────────────────────────────────────

Input_State :: struct {
    move_left:    bool,
    move_right:   bool,
    jump:         bool,
    mine:         bool,
    interact:     bool,
    drop_item:    bool,
    fly_up:       bool,   // debug fly mode only (W/S held)
    fly_down:     bool,
    mouse_tile:   [2]i32,
    mouse_world:  [2]f32,
}

// ─── UI ───────────────────────────────────────────────────────────────────────

UI_State :: struct {
    show_inventory:  bool,
    show_crafting:   bool,
    show_debug:      bool,
    hover_tile:      [2]i32,
    tooltip_text:    [64]u8,
}

// ─── Debug Menu (F1, debug builds only) ───────────────────────────────────────

Debug_State :: struct {
    menu_open: bool,
    fly:       bool,
}

// ─── Sim ──────────────────────────────────────────────────────────────────────

Sim_State :: struct {
    lava_tick_timer: f32,
    tree_tick_timer: f32,
}

// ─── Audio ────────────────────────────────────────────────────────────────────

Audio_State :: struct {
    initialized:     bool,
    master_volume:   f32,
    sfx_volume:      f32,
    music_volume:    f32,
    sounds:          [Sound_ID]rl.Sound,
    loaded:          [Sound_ID]bool,
    ambience:        rl.Music,
    ambience_loaded: bool,
    ambience_gain:   f32,
}

// ─── Progression ──────────────────────────────────────────────────────────────

Progression_State :: struct {
    blueprint_found:        [MAX_PROGRESSION_TIERS]bool,
    sky_structure_complete: [MAX_PROGRESSION_TIERS]bool,
    cave_unlocked:          [MAX_PROGRESSION_TIERS]bool,
    final_boss_defeated:    bool,
}

// ─── Persistent Stats ─────────────────────────────────────────────────────────

Persistent_Stats :: struct {
    runs_played:  int,
    runs_won:     int,
    deepest_cave: int,
    total_kills:  int,
}

// ─── Game State (fat struct) ──────────────────────────────────────────────────

Game_State :: struct {
    world:       World_Grid,
    level_index: int,
    levels:      Level_Store,

    player:      Player,
    enemies:     Enemy_Store,

    projectiles: Projectile_Store,
    particles:   Particle_Store,
    events:      Event_Queue,

    input:       Input_State,
    ui:          UI_State,

    sim:         Sim_State,
    audio:       Audio_State,
    progression: Progression_State,
    stats:       Persistent_Stats,

    elapsed_time: f32,
    frame:        u64,
    delta_time:   f32,

    debug_log:   Debug_Log,
    debug:       Debug_State,
}

// ─── Init ─────────────────────────────────────────────────────────────────────

game_state_init :: proc(gs: ^Game_State) {
    gs^ = {}  // zero all fields

    gs.player.hp          = 10
    gs.player.hp_max      = 10
    gs.player.mana        = 100
    gs.player.mana_max    = 100
    gs.player.mana_regen  = 5
    gs.player.facing      = 1
    gs.player.walk_anim_period = 0.15
    gs.player.equipped    = .Mine_Wand

    gs.enemies.free_head = 0

    world_init(&gs.world)
    spawn_level_1_enemies(gs)
    gs.levels.generated[LEVEL_SURFACE] = true  // lives in gs.world
}
