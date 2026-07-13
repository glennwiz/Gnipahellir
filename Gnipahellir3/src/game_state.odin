package game

import rl "vendor:raylib/v55"
import "core:time"

// ─── World Grid ───────────────────────────────────────────────────────────────

Sim_Tile_Data :: struct {
    growth_timer: f32,
    spread_timer: f32,
    store_item:   Item, // smelter output tray — cast bars wait here, not on the ground
    store_count:  u8,
    fuel_charge:  u8,   // bars the last-eaten log can still fire (BARS_PER_LOG per log)
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
    pocket:       u8,           // spare blocks from tiles it mined; spent on bridges
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

// Boss phases escalate with lost hp; order matters (a phase never regresses).
Garm_Phase :: enum u8 {
    Chase,   // full hp: hunt + fireballs only
    Column,  // <= GARM_PHASE2_HP: raises the center column
    Ring,    // <= GARM_PHASE3_HP: seals the arena perimeter
    Flood,   // ring complete: lava rises from the arena floor
}

Garm_State :: struct {
    build_i:     int,        // progress index into the current phase's structure
    build_timer: f32,        // seconds until the next boss-magic tile
    fire_timer:  f32,        // fireball cooldown
    bite_timer:  f32,        // melee cooldown
    phase:       Garm_Phase,
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
    garm:     Garm_State,
}

Enemy_Store :: struct {
    data:   [MAX_ENEMIES]Enemy,
    active: [MAX_ENEMIES]bool,   // enemy_alloc scans this linearly
    count:  int,
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
    attack_timer:     f32,   // sword swing cooldown
    hazard_timer:     f32,   // accumulated tile damage (lava); 1 hp per unit
    fall_peak_y:      f32,   // highest airborne y; fall damage measures from it on landing
    mine_timer:       f32,   // pick swing / wand shot cooldown
    chip_tile:        [2]i32,// tile the pick is currently chipping
    chip_hits:        u8,    // chips landed on it (PICK_HITS breaks it)
    inventory:        Inventory,
    equipment:        [Equip_Slot]Item,   // equipped gear; [.None] unused
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

// ─── Wand Mining (delayed impact) ─────────────────────────────────────────────

// One shot in flight at a time (a new shot overwrites it, like G2).  Not part
// of the save — a shot in flight at quit simply vanishes, like projectiles.
Mining_Action :: struct {
    active:  bool,
    blast:   bool,  // ultra-wand cheat: impact mines a 3×3 with a bang
    target:  [2]i32,
    travel:  f32,   // seconds to impact
    elapsed: f32,
}

// ─── Projectiles ──────────────────────────────────────────────────────────────

Projectile :: struct {
    pos:    [2]f32,
    vel:    [2]f32,
    owner:  Entity_ID,
    active: bool,
    damage: int,
    age:    f32,   // seconds alive; dies at PROJECTILE_LIFETIME
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
    attack:       bool,   // discrete press — sword swing
    interact:     bool,
    drop_item:    bool,
    fly_up:       bool,   // debug fly mode only (W/S held)
    fly_down:     bool,
    mouse_tile:   [2]i32,
    mouse_world:  [2]f32,   // world-pixel space (camera-inverse) — mining/placement
    mouse_screen: [2]f32,   // virtual-screen space — UI hit-testing
}

// ─── UI ───────────────────────────────────────────────────────────────────────

UI_State :: struct {
    show_inventory:  bool,
    show_crafting:   bool,
    show_blueprint:  bool,
    show_smelter:    bool,   // furnace window; smelter_tile says which furnace
    show_debug:      bool,
    show_menu:       bool,   // Resume / New Game / Save and Quit overlay
    show_title:      bool,   // boot title screen; any key dismisses it into the menu
    show_settings:   bool,   // volume sliders + key rebinding screen
    settings_capture: int,   // action index awaiting a new key, -1 = none
    settings_drag:    int,   // volume slider being dragged (0..2), -1 = none
    craft_offer:     [3]Item, // anvil offering slots — references, items stay in the bag
    drag_item:       Item,    // bag stack being dragged onto the anvil/smelter (.None = no drag)
    drag_slot:       int,     // bag slot the drag started from (smelter feed takes from it)
    drag_tray:       bool,    // the drag holds the smelter tray, not a bag stack
    win_pos:         [UI_Window][2]i32, // top-left of each floating window (draggable)
    win_drag:        int,     // window being dragged by its header, -1 = none
    win_drag_off:    [2]i32,  // cursor offset inside the window at grab
    smelter_tile:    [2]i32,  // furnace the smelter window is looking at
    active_station:  Station, // station the crafting window was opened at (.None = hand crafting)
    focus_station:   Station, // nearest interactable station in range this frame (.None = none)
    focus_tile:      [2]i32,  // its tile — anchor for the highlight and prompt
    hover_tile:      [2]i32,
    tooltip_text:    [64]u8,
}

// ─── Notifications (timed on-screen popups) ───────────────────────────────────

MAX_NOTIFICATIONS :: 4
NOTIFY_TEXT_LEN   :: 64

Notification :: struct {
    text: [NOTIFY_TEXT_LEN]u8,
    len:  int,
    age:  f32,
}

Notification_State :: struct {
    items: [MAX_NOTIFICATIONS]Notification,
    count: int,
}

// ─── Debug Menu (F1, debug builds only) ───────────────────────────────────────

Debug_State :: struct {
    menu_open:  bool,
    fly:        bool,
    ultra_wand: bool,   // cheat: 13-tile mining wand, free, explosive impact
    place_tile: Tile_Type,  // armed stamp: next world click sets this tile (.Air = off)
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
    sky_altar_pos:          [2]i32,  // surface tile of the built sky-gate altar; {0,0} = closed
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
    ambience_timer: f32,   // countdown to the next ambient-mote probe pass
    mining:      Mining_Action,
    events:      Event_Queue,

    input:       Input_State,
    bindings:    [Action]rl.KeyboardKey,   // rebindable keys (settings screen)
    ui:          UI_State,
    notify:      Notification_State,

    sim:         Sim_State,
    audio:       Audio_State,
    assets:      Assets,
    progression: Progression_State,
    dimension:   Dimension_State,
    stats:       Persistent_Stats,

    elapsed_time: f32,
    frame:        u64,
    delta_time:   f32,
    loot_rng:     u64,    // xorshift state for drop rolls; not saved, reseeded per run
    game_won:     bool,   // run complete — not saved; a won run ends like a death
    zoom:         f32,    // view zoom (1.0 = whole level); not saved
    save_dirty:   bool,   // a player action changed saved state; autosave at frame end
    quit_requested: bool, // "Save and Quit" clicked; main loop exits, save happens on shutdown



    debug_log:   Debug_Log,
    debug:       Debug_State,
}

// ─── Init ─────────────────────────────────────────────────────────────────────

@(rodata)
default_bindings := [Action]rl.KeyboardKey{
    .Move_Left  = .A,
    .Move_Right = .D,
    .Jump       = .W,
    .Interact   = .E,
    .Drop_Item  = .Q,
    .Inventory  = .TAB,
    .Crafting   = .C,
    .Blueprint  = .B,
}

game_state_init :: proc(gs: ^Game_State) {
    // Preserved across a reset (audio/assets are live GPU/OS handles set up
    // once in main(); stats and key bindings persist across runs). debug_log
    // is NOT preserved here: it's a 256KB buffer, too large to stack-copy,
    // and losing its unflushed tail on a New Game is harmless (diagnostic only).
    audio    := gs.audio
    assets   := gs.assets
    stats    := gs.stats
    bindings := gs.bindings

    gs^ = {}  // zero all fields

    gs.audio  = audio
    gs.assets = assets
    gs.stats  = stats
    // First boot arrives zeroed (KEY_NULL) — take the defaults then.
    gs.bindings = bindings[.Move_Left] == .KEY_NULL ? default_bindings : bindings
    gs.ui.settings_capture = -1
    gs.ui.settings_drag    = -1
    gs.ui.win_drag         = -1
    gs.ui.win_pos          = default_window_pos

    gs.player.hp          = 10
    gs.player.hp_max      = 10
    gs.player.mana        = 100
    gs.player.mana_max    = 100
    gs.player.mana_regen  = 5
    gs.player.facing      = 1
    gs.player.walk_anim_period = 0.15
    gs.zoom               = 1.0
    gs.loot_rng           = u64(time.now()._nsec)  // fresh drop rolls each run
    gs.ui.show_title      = true   // boot into the title screen; a key press opens the menu
    // No starting tools — the pickaxe waits on the grass (see world_init).

    world_init(&gs.world)
    spawn_level_1_enemies(gs)
    gs.levels.generated[LEVEL_SURFACE] = true  // lives in gs.world
}
