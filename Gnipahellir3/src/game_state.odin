package game

import rl "vendor:raylib"
import "core:time"
import "core:os"
import "core:strconv"

// ─── World Grid ───────────────────────────────────────────────────────────────

Sim_Tile_Data :: struct {
    growth_timer: f32,
    spread_timer: f32,
    store_item:   Item, // smelter output tray — cast bars wait here, not on the ground
    store_count:  u8,
    in_item:      Item, // smelter input buffer — ore loaded into the furnace, waiting to smelt
    in_count:     u8,
    fuel_count:   u8,   // smelter fuel buffer — wood logs stoking the fire (FUEL_PER_BAR per bar)
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

// Saved as u8 (Enemy.kind, memcpy'd into Save_Data) — append-only, same rule
// as the enums in types.odin: never reorder or remove a value, only add.
Enemy_Kind :: enum u8 {
    Garm,
    Undead,
    Fire_Sprite,
    Builder,
    Raider, // industry-drawn tunneller; appended for save compatibility
    // The GROUND wave: an outlaw-wolf that runs the surface and takes the
    // base apart structure by structure. Appended for save compatibility.
    Vargr,
}

Enemy_Nav :: struct {
    path:       Nav_Path,
    mine_timer: f32,   // cooldown after a mine/place action
}

Build_Kind :: enum u8 {
    Cairn,
    Pillar,
    Shelter,
    Lair,     // Garm's stone den (builders always pick Shelter)
}

Builder_Goal :: enum u8 {
    Build_Den,      // zero value: builders boot into den construction
    Fetch_Mineral,  // travel to an ore vein and mine one block
    Encase_Den,     // carry the block home and place it on the den shell
    Hunt,           // chase and bite the player
    Cooldown,
    // Wave-spawned: hunt EVERY structure (is_structure_tile), smash them one
    // at a time, and only turn on the player once nothing built is standing.
    // Appended: saved as u8 inside Builder_State.
    Wave_Hunt,
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
    last_place:   [2]i32,       // last bridge-placed tile (place-loop detection)
    place_reps:   u8,           // times last_place was placed in a row
    escaping:     bool,         // pillar escape: tunnel straight up out of a stuck spot
    escape_timer: f32,
    escape_from:  i32,          // tile y where the escape began (min-rise check)
}

// Boss phases escalate with lost hp; order matters (a phase never regresses).
// Also saved as u8 (Garm_State.phase) — append-only for the same reason.
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

// Surface industry slowly draws a tunneller raid. Transient on purpose: the
// enemy store is saved once the raid exists, while an unfinished warning is
// harmless to cancel on save/load just like the tile effect that announces it.
Raid_State :: struct {
    pressure:       f32,
    warning_timer:  f32,
    cooldown:       f32,
    quiet_timer:    f32,
    target:         [2]i32,
    warning_active: bool,
}

// Which wave the director sends. Ordinal IS the cycle position (wave.odin).
Wave_Kind :: enum u8 {
    Air,
    Ground,
    Underground,
}

// The wave director. Transient exactly like Raid_State: the enemies a wave
// spawns persist in the saved Enemy_Store, while an unconsumed trigger is
// harmless to drop on a reload. Zero save impact.
Wave_State :: struct {
    pending:        bool,      // a scripted trigger fired; the next surface frame arms it
    pending_kind:   Wave_Kind, // which wave the script asked for
    cycle:          int,       // how many waves have been sent
    threat:         f32,       // cached base score, rescanned on a slow beat
    threat_timer:   f32,
    pressure:       f32,       // threat-seconds accumulated toward the next wave
    warning_timer:  f32,
    warning_active: bool,
    warning_kind:   Wave_Kind, // decided when the warning arms, not at spawn
    cooldown:       f32,
    // Structure index for the hunters: rebuilt on the WAVE_THREAT_RESCAN beat
    // (lazily on first use), so picking a target walks a few dozen entries
    // instead of the 20k-tile grid — which every hunter without a target used
    // to do EVERY FRAME, ~10M reads a frame at 512 enemies once the base was
    // gone.  Entries are verified live at pick time, so a structure smashed
    // since the beat costs one skipped step; one placed since it waits ≤ 2 s.
    structures:         [MAX_WAVE_STRUCTURES][2]i32,
    structures_n:       int,
    structures_indexed: bool,
}

MAX_WAVE_STRUCTURES :: 256   // stations and machines only, never placed blocks

// Garm's combat cage — the stone box he conjures around the player at low hp
// and then floods.  Transient on purpose, and that IS the mechanism: a zero
// anchor means "snapshot the player's tile next tick", so a reload, an escape
// and a stalled cage all recover through the same single path.  No build
// progress lives here either; the slot generator scans the world, so walls
// always precede lava even on a save loaded mid-flood.
Cage_State :: struct {
    anchor:         [2]i32,  // {0,0} = no cage; next tick snapshots the player
    stall:          f32,     // seconds since a slot last landed
    announced_fill: bool,    // the fill notify fires once per anchor
}

// ─── Friendly Clay Golems ───────────────────────────────────────────────────

GOLEM_PROJECT_CELLS :: 128
MAX_GOLEM_DEPOTS     :: 8
GOLEM_DEPOT_SLOTS    :: 12
GOLEM_PACK_CAP       :: 8
GOLEM_BLOCK_GRACE_CAP :: MAX_GOLEMS * 8
GOLEM_QUICK_CLAY_CAP  :: MAX_GOLEMS * 4

Golem :: struct {
    status:       Golem_Status,
    level:        int,
    pos:          [2]f32,
    vel:          [2]f32,
    hp:           u8,
    mode:         Golem_Mode,
    job:          Golem_Job,
    carry:        Item,
    target:       [2]i32,
    has_target:   bool,
    path:         Nav_Path,
    mine_timer:   f32,
    hazard_timer: f32,
    replan_timer: f32,
    facing:       i8,
    grounded:     bool,
    project_cell: i16, // -1 when no build cell is reserved
    pack:          [GOLEM_PACK_CAP]Item, // mined cargo and real bridge/pillar material
    recovering:    bool,
    recover_from:  i32,
}

Golem_Work_Order :: struct {
    active: bool,
    min:    [2]i32,
    max:    [2]i32,
}

Golem_Project :: struct {
    active:   bool,
    complete: bool,
    plan:     Golem_Plan,
    level:    int,
    anchor:   [2]i32,
    reserved: [GOLEM_PROJECT_CELLS]u8, // 0 = free, otherwise golem slot + 1
}

Golem_Depot_State :: struct {
    active: bool,
    level:  int,
    tile:   [2]i32,
    slots:  [GOLEM_DEPOT_SLOTS]Silo_Slot,
}

Golem_System :: struct {
    data:     [MAX_GOLEMS]Golem,
    work:     [NUM_LEVELS]Golem_Work_Order,
    projects: [NUM_LEVELS]Golem_Project,
    depots:   [MAX_GOLEM_DEPOTS]Golem_Depot_State,
}

// Short-lived ownership for freshly placed navigation masonry. This stays
// outside Golem_System because it is transient coordination state, not save
// data; loading a run simply resumes without an obsolete three-second lock.
Golem_Block_Grace :: struct {
    tile:       [2]i32,
    level:      int,
    owner:      i16,
    expires_at: f32,
}

Golem_Grace_State :: struct {
    blocks: [GOLEM_BLOCK_GRACE_CAP]Golem_Block_Grace,
}

// Free, instant, self-dissolving footing a worker conjures for its own
// vertical movement (bridging a gap, pillaring up during recovery) — no
// material spent, unlike navigation masonry. Transient coordination state,
// not save data, for the same reason as Golem_Grace_State: a fresh load
// simply has none lingering, which is correct since it was never "real."
Golem_Quick_Clay :: struct {
    active: bool,
    tile:   [2]i32,
    level:  int,
    owner:  i16,
}

Golem_Quick_Clay_State :: struct {
    blocks: [GOLEM_QUICK_CLAY_CAP]Golem_Quick_Clay,
}

// Transient acceleration index over saved Tile_Flag.Golem_Marked cells. It is
// rebuilt lazily after loading or changing level, so Save_Data stays compatible.
Golem_Mark_Index :: struct {
    valid: bool,
    level: int,
    count: int,
    min:   [2]i32,
    max:   [2]i32,
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
    bucket_fluid:     Tile_Type, // RETIRED: the load now lives on the stack as a
                                 // filled-bucket item.  Kept (always .Air) so the
                                 // Save_Data layout is unchanged; load_game_from
                                 // converts a carried load into the filled item.
    grounded:         bool,
    facing:           int,
    dead:             bool,
    death_timer:      f32,
    anim_frame:       int,
    anim_timer:       f32,
    walk_anim_period: f32,
    clothing_color:   rl.Color,
    hair_color:       rl.Color,
    void_slot:        Inventory_Slot, // saved last-chance stack held by the Void Charm
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
    // Collect motes home toward `target`, accelerating in and dying on arrival
    // — the "flew into your inventory" read.  Off = straight ballistic drift.
    homing:   bool,
    target:   [2]f32,
}

Particle_Store :: struct {
    data:  [MAX_PARTICLES]Particle,
    count: int,
}

// ─── Floating Combat Text ─────────────────────────────────────────────────────
//
//  Short-lived damage numbers that rise off a struck body and fade — a purely
//  visual read that a hit landed (drawn in world-space, floating_text.odin).
//  Transient like particles: spawned from update code, never saved.

MAX_FLOATING_TEXT :: 32

Floating_Text :: struct {
    pos:      [2]f32,   // world tile coords; drifts upward as it ages
    value:    int,
    color:    rl.Color,
    age:      f32,
    lifetime: f32,
    active:   bool,
}

Floating_Text_Store :: struct {
    data:  [MAX_FLOATING_TEXT]Floating_Text,
    count: int,
}

// ─── Falling Blocks (structural gravity) ──────────────────────────────────────
//
//  A tile cut loose from its anchor (gravity.odin) leaves the terrain grid and
//  rides this pool down until it lands.  Transient: not part of Save_Data, so a
//  save caught mid-fall drops the airborne blocks (a rare, cosmetic loss).

Falling_Block :: struct {
    tile:             Tile_Type,
    x:                i32,   // column (never changes — blocks fall straight down)
    y:                f32,   // tile-space top; fractional while sliding
    source_x:         i32,   // original grid cell; preserves the static texture variant
    source_y:         i32,   // while live Y moves through fractional rows
    golem_placed:     bool,  // ownership follows settling navigation masonry
    golem_owner:      i16,   // -1 once its placement grace has already expired
    grace_expires_at: f32,
    active:           bool,
}

Gravity_State :: struct {
    blocks: [MAX_FALLING]Falling_Block,
}

// ─── Fluid Flow ───────────────────────────────────────────────────────────────
//
//  Water/lava positions live in the terrain grid itself (fluid.odin moves them
//  a cell at a time), so all this holds is the per-fluid tick clock and the
//  alternating sideways bias.  Transient: not part of Save_Data — flow resumes
//  from wherever the saved terrain left it.

// Power is a LIVE thing, not saved progress: every cell an engine reaches
// carries a few seconds of charge, re-stamped while the engine drinks vapour.
// Transient by design (same pattern as Fluid_State) — a running engine
// re-establishes the field within one tick of a load, so there is nothing
// worth persisting.
Power_State :: struct {
    charge: [GRID_W * GRID_H]f32, // seconds of powered time left, per cell
}

Fluid_State :: struct {
    timers: [len(fluid_rules)]f32,
    flip:   [len(fluid_rules)]bool,
    // Gas only: flow steps each cell has existed, for dissipation.  Transient
    // like the clocks — a save/load resets it, so loaded vapour lives one
    // extra lifetime.  Cosmetic; not worth a save bump.  u16 (not u8): Mana
    // Mist's 600s lifetime at a 1.0s period is 600 steps, past u8's 255 cap —
    // widened for both gases since the field is shared; Steam's 80 steps
    // fit either way.
    age:    [GRID_W * GRID_H]u16,
    // Mana Mist only: which gem's own item_table color tints this cell
    // (gem_tint_index, sim.odin) — carried on move exactly like age is, so a
    // drifting plume keeps its color.  Transient/cosmetic for the same
    // reason age is: a reload just loses one cloud's tint, not worth a save
    // bump.  Meaningless (and unread) for every other fluid.
    gem_tint: [GRID_W * GRID_H]u8,
    // Mana Mist only: clock for update_mana_pipe_fill's spread-through-pipes
    // pass (fluid.odin) — separate from the per-rule `timers` above since
    // it isn't keyed to a fluid_rules row.  Transient.
    pipe_fill_timer: f32,
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
    reclaim:      bool,   // Shift + held mine button — deliberate structure removal
    interact:     bool,
    fly_up:       bool,   // flight steering: debug fly mode and the altar-swirl buff
    fly_down:     bool,
    mouse_tile:   [2]i32,
    mouse_world:  [2]f32,   // world-pixel space (camera-inverse) — mining/placement
    mouse_screen: [2]f32,   // virtual-screen space — UI hit-testing
    place_last:   [2]i32,   // last tile a hold-to-place fired on — dedupes the sweep
    golem_paint_last:   [2]i32,
    golem_paint_button: i8, // 0 none, 1 mark, 2 erase; dedupes held wand paint
}

// ─── UI ───────────────────────────────────────────────────────────────────────

UI_State :: struct {
    show_inventory:  bool,
    show_crafting:   bool,
    show_rune_scroll:  bool,
    show_smelter:    bool,   // furnace window; smelter_tile says which furnace
    show_barrel:     bool,   // barrel window; barrel_tile says which barrel
    show_debug:      bool,
    show_menu:       bool,   // Resume / New Game / Save and Quit overlay
    show_title:      bool,   // boot title screen; any key dismisses it into the character-select
    show_charselect: bool,   // startup form picker; dismissed by choosing a look
    show_settings:   bool,   // volume sliders + key rebinding screen
    show_snapshots:  bool,   // F3 snapshot save/load menu (full-screen modal)
    snap_exists:     [SNAP_SLOTS]bool,      // slot cache, refreshed by snapshot_scan
    snap_time:       [SNAP_SLOTS]time.Time, // slot file write time, for the row label
    show_book:       bool,   // full-screen tome overlay (ritual passage, or a read scroll)
    book_page:       Book_Page, // which text the tome is showing
    book_tier:       int,    // .Seal only: which structure tier's passage the tome describes
    book_open_frame: u64,    // gs.frame the tome opened — drives the flash-in (frame counts even while paused)
    settings_capture: int,   // action index awaiting a new key, -1 = none
    settings_drag:    int,   // volume slider being dragged (0..2), -1 = none
    craft_selected:  int,     // recipe-table index selected in the crafting window's card grid
    drag_item:       Item,    // bag stack being dragged onto the smelter (.None = no drag)
    drag_slot:       int,     // bag slot the drag started from (smelter feed takes from it)
    drag_tray:       bool,    // the drag holds the smelter tray, not a bag stack
    drag_input:      bool,    // the drag holds the smelter's loaded ore (pulling it back out)
    drag_barrel:     int,     // barrel slot the drag started from (-1 = drag is from the bag/tray, not a barrel)
    drag_void:       bool,    // drag source is Player.void_slot, not the bag
    win_pos:         [UI_Window][2]i32, // top-left of each floating window (draggable)
    win_moved:       [UI_Window]bool,   // player has hand-dragged this window; auto-layout leaves it alone
    win_drag:        int,     // window being dragged by its header, -1 = none
    win_drag_off:    [2]i32,  // cursor offset inside the window at grab
    hotbar_click_slot:  int,  // hotbar cell of the last click — double-click-to-consume pairing
    hotbar_click_frame: u64,  // gs.frame of that click (0 = none/spent)
    smelter_tile:    [2]i32,  // furnace the smelter window is looking at
    barrel_tile:     [2]i32,  // barrel the barrel window is looking at
    active_station:  Station, // station the crafting window was opened at (.None = hand crafting)
    focus_station:   Station, // nearest interactable station in range this frame (.None = none)
    hover_tile:      [2]i32,
    // Cursor description line: shown once, the first time you point at a kind
    // of thing you have never pointed at before, then it holds and fades and
    // that kind stays quiet from then on (update_hover_desc).  The seen sets
    // are deliberately not saved — they are UI state, and a reloaded run
    // simply re-teaches.
    hover_desc_tile:  Tile_Type, // subject when it is terrain (.Air = a drop, below)
    hover_desc_item:  Item,      // subject when it is a loose item on the ground
    hover_desc_timer: f32,       // seconds of description left; 0 = name only
    hover_seen_tile:  [Tile_Type]bool, // kinds whose description has been shown
    hover_seen_item:  [Item]bool,
    tooltip_text:    [64]u8,
    golem_plan:       Golem_Plan, // selected command-wand construction ghost
    show_golem_roster: bool,      // wand click (no drag): the per-golem command window
	golem_zone_press: bool,       // empty-world press waiting to become a deliberate drag
    golem_zone_drag:  bool,
    golem_zone_start: [2]i32,
	golem_zone_press_screen: [2]f32,

    show_pixel_editor:   bool,           // F1 debug tool: paint editable structure sprites (pixel_art.odin)
    pixel_editor_target:  Pixel_Sprite_ID, // sprite currently open in the editor
    pixel_editor_color:  u8,             // selected palette index (game_palette), 1-based; 0 = eraser
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
	place_golem: bool,    // armed stamp: next world click deploys a Clay Golem
    altar_menu: bool,   // F2: altar/ritual debug menu
    raid_menu:  bool,   // F4: industry-raid debug menu
    place_tier: int,    // armed altar stamp: next click raises this tier's sky structure (0 = off, else tier+1)
    life:       bool,   // easter egg: Conway's Game of Life eats the world (life.odin)
    life_timer: f32,
    life_gen:   int,
    item_palette: bool, // F1 admin tool: every item's pixel art, click to bag
}

// ─── Sim ──────────────────────────────────────────────────────────────────────

Sim_State :: struct {
    lava_tick_timer: f32,
    tree_tick_timer: f32,
    silos:           [MAX_SILOS]Silo_State,  // wide-count bulk stores (silo.odin)
    barrels:         [MAX_BARRELS]Barrel_State, // hand-organized 4×4 chests (barrel.odin)
}

// ─── Audio ────────────────────────────────────────────────────────────────────

Audio_State :: struct {
    initialized:     bool,
    master_volume:   f32,
    sfx_volume:      f32,
    music_volume:    f32,
    sounds:          [Sound_ID]rl.Sound,
    loaded:          [Sound_ID]bool,

    // Cave ambience is synthesized at runtime (a deep drone + random water
    // drips) and streamed — no clip, so it never loops or seams.  All DSP
    // state lives here; the generator is fill_ambience in audio.odin.
    ambience:        rl.AudioStream,
    ambience_loaded: bool,
    ambience_gain:   f32,               // smoothed output gain (depth × music × master)
    amb_buf:         [AMBIENCE_BUF]i16, // one stream refill of mono 16-bit samples
    amb_rng:         u64,               // xorshift state for noise + drip scheduling
    amb_brown:       f32,               // brown-noise integrator (rumble source)
    amb_lp1, amb_lp2: f32,              // two-pole lowpass state → deep rumble
    amb_air:         f32,               // one-pole lowpass state → faint wind hiss
    amb_lfo:         f32,               // slow swell phase (the cave "breathing")
    amb_depth:       f32,               // smoothed 0..1 depth (drives drip rate + rumble)
    drip_timer:      f32,               // seconds until the next drip
    drip_env:        f32,               // current drip amplitude envelope
    drip_phase:      f32,               // drip sine phase
    drip_freq:       f32,               // drip pitch (Hz)
}

// ─── Progression ──────────────────────────────────────────────────────────────

Progression_State :: struct {
    rune_scroll_found:        [MAX_PROGRESSION_TIERS]bool,
    sky_structure_complete: [MAX_PROGRESSION_TIERS]bool,
    cave_unlocked:          [MAX_PROGRESSION_TIERS]bool,
    final_boss_defeated:    bool,
    sky_altar_pos:          [2]i32,  // surface tile of the built sky-gate altar; {0,0} = closed
    // Sticky: a recipe (keyed by result item) revealed once its gating material
    // was held (crafting.odin).  Indexed through recipe_revealed/reveal_recipe
    // rather than by [Item] directly — see MAX_ITEM_SLOTS for why it is sized to
    // a ceiling instead of to the enum.
    recipe_unlocked:        [MAX_ITEM_SLOTS]bool,
}

// ─── Sky Altar ritual (the offering animation) ────────────────────────────────
//
//  A completed offering doesn't finish instantly: for RITUAL_DURATION the
//  materials swirl over the altar amid runes and rainbow light, then a flash
//  raises the structure and leaves an instruction tome.  Transient — not saved
//  (a mid-ritual save just drops the animation; the offering isn't consumed
//  until the finishing flash, so nothing is lost).
Ritual_State :: struct {
    active: bool,
    timer:  f32,     // 0 → RITUAL_DURATION
    tier:   int,     // structure tier being raised
    altar:  [2]i32,  // the Sky_Altar tile the offering plays over
}

// Deliberate removal of player equipment. Transient: cancelling, travelling or
// reloading simply drops the hold progress; no structure changes until complete.
Reclaim_State :: struct {
    active:  bool,
    blocked: bool,
    target:  [2]i32,
    timer:   f32,
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
    raid:        Raid_State, // transient industry-pressure director (enemy.odin)
    wave:        Wave_State, // transient wave director (wave.odin)
    nav_searches: int,       // astar_dig calls spent this frame by enemies; reset
                             // in update_enemies, capped by MAX_NAV_SEARCHES_PER_FRAME
    cage:        Cage_State, // transient Garm combat-cage anchor (garm.odin)
    golems:      Golem_System,
    golem_grace: Golem_Grace_State,
    golem_marks: Golem_Mark_Index,
    golem_quick_clay: Golem_Quick_Clay_State,
    golem_need:   [8]Item, // items the active Build project can't source (golem_project_reserve); transient, not saved — drives the crew's NEEDS feedback
    golem_need_n: int,
    golem_calls:  [MAX_GOLEMS]Golem_Call, // roster CALL/PICK UP orders; transient, not saved — a reload drops the call and the golem resumes its mode

    projectiles: Projectile_Store,
    particles:   Particle_Store,
    floating_text: Floating_Text_Store,   // damage numbers (floating_text.odin)
    tile_fx:     Tile_Fx_Store,   // reusable tile-overlay telegraphs (fx.odin); transient, not saved
    gravity:     Gravity_State,   // structural blocks in mid-fall (gravity.odin)
    leaf_fall_t: f32,             // GreenBerrie slow-fall buff seconds left (player.odin); transient, not saved
    flight_t:    f32,             // altar-swirl flight buff seconds left (levels.odin grants, player.odin ticks); transient, not saved
    fluid:       Fluid_State,     // water/lava flow clocks (fluid.odin); transient, not saved
    power:       Power_State,     // live engine charge field (sim.odin); transient, not saved
    ritual:      Ritual_State,    // the Sky Altar offering animation (levels.odin); transient, not saved
    reclaim:     Reclaim_State,   // Shift+hold pickaxe dismantle; transient, not saved
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
    pixel_art:   Pixel_Art_Store,  // editable structure sprites (pixel_art.odin); loaded/saved separately from Save_Data
    progression: Progression_State,
    dimension:   Dimension_State,
    stats:       Persistent_Stats,

    elapsed_time: f32,
    frame:        u64,
    delta_time:   f32,
    world_seed:   u32,    // seed mixed into level generation; set per run, not saved
    loot_rng:     u64,    // xorshift state for drop rolls; not saved, reseeded per run
    game_won:     bool,   // run complete — not saved; a won run ends like a death
    zoom:         f32,    // view zoom, eased toward zoom_target each frame (1.0 = whole level); not saved
    zoom_target:  f32,    // wheel-set zoom the view eases toward; smoothing removes the per-notch pop/lurch; not saved
    zoom_from:    f32,    // zoom the current glide started from; not saved
    zoom_t:       f32,    // 0..1 progress of that glide (1 = settled); not saved
    cam_glide_from: [2]f32, // camera target minus tracked point when that glide began, so a mid-glide notch retargets from where the view IS; not saved
    cam_glide_vel: [2]f32,  // camera target speed (px/s) last frame, handed to the next notch so a wheel spin keeps its pace; not saved
    cam_ease_c:    [2]f32,  // normalised initial slope of the framing curve, per axis (0 = plain smoothstep); not saved
    zoom_inv_vel:  f32,     // d(1/zoom)/dt last frame — the zoom's carried pace, measured in the space it glides in; not saved
    zoom_ease_c:   f32,     // same normalised initial slope for the zoom curve; not saved
    cam_y:        f32,    // camera Y anchor (world px); a deadzone keeps jumps from bobbing the view — not saved
    cam_pan:      [2]f32, // world-pixel offset created by ALT cursor zoom; glides home once the player moves; not saved
    cam_pan_from: [2]f32, // pan captured when that glide started, for the smoothstep; not saved
    cam_recenter_t: f32,  // 0..1 progress of the glide back to the player; not saved
    cam_recentering: bool, // true while that glide is running; not saved
    cam_dragging:  bool,   // true while ALT+mouse is panning the view; not saved
    cam_drag_last: [2]f32, // previous virtual-screen cursor pos of that drag; not saved
    cam_follow_kind: Cam_Follow, // store the ALT-clicked body being followed lives in (.None = the player); not saved
    cam_follow_id:   int,        // its slot in that store; not saved
    cam_follow_y:    f32,        // deadzoned + eased Y anchor for that body, so its jumps don't bob the view; not saved
    zoom_anchor_world:  [2]f32, // world point kept beneath zoom_anchor_screen while easing; not saved
    zoom_anchor_screen: [2]f32, // virtual-screen cursor captured by an ALT wheel zoom; not saved
    zoom_cursor_active: bool,   // true while the live zoom is easing around that cursor anchor; not saved
    player_step_visual_y: f32, // downward render offset that eases out after an instant collision step; not saved
    player_form:  Player_Form,  // chosen sprite look (startup character-select); cosmetic, not saved
    save_dirty:   bool,   // a player action changed saved state; autosave at frame end
    save_cooldown: f32,   // debounce: seconds until the next autosave may fire; not saved
    quit_requested: bool, // "Save and Quit" clicked; main loop exits, save happens on shutdown
    pickaxe_hint_shown: bool, // one-shot: the "you can mine now" popup on first pickaxe (not saved)
    craft_hint_shown:   bool, // one-shot: the "open bag to craft" popup on first wood log (not saved)
    forage_hint_shown:  bool, // one-shot: the "brew potions" popup on first foraged flower (not saved)
    wand_hint_shown:    bool, // one-shot: the "equip the wand" popup on first crafted wand (not saved)
    spring_hint_shown:  bool, // one-shot: the "it will not run dry" popup on the first spring (not saved)
    sky_apparition_glimpsed: bool, // one-shot: "something moves..." popup on first clear glimpse of the sky apparition (not saved)



    debug_log:   Debug_Log,
    cam_log:     Cam_Log,
    mouse_log:   Mouse_Log,
    debug:       Debug_State,
}

// ─── Init ─────────────────────────────────────────────────────────────────────

@(rodata)
default_bindings := [Action]rl.KeyboardKey{
    .Move_Left  = .A,
    .Move_Right = .D,
    .Jump       = .W,
    .Interact   = .E,
    .Inventory  = .TAB,
    .Rune_Scroll  = .B,
    .Golem_Crew = .R,
}

// Seed 0 reproduces the original fixed world — used for the boot title screen
// and headless tests, so both stay deterministic.  A real New Game passes a
// random (or overridden) seed via new_game_world_seed.
DEFAULT_WORLD_SEED :: u32(0)

// The world seed for a fresh run: the GNIPA_SEED env var if it holds a number
// (reproducible / shareable), otherwise wall-clock time (a new world each game).
new_game_world_seed :: proc() -> u32 {
    if s := os.get_env("GNIPA_SEED", context.temp_allocator); s != "" {
        if n, ok := strconv.parse_u64(s); ok do return u32(n)
    }
    return u32(time.now()._nsec)
}

game_state_init :: proc(gs: ^Game_State, world_seed: u32 = DEFAULT_WORLD_SEED) {
    // Preserved across a reset (audio/assets are live GPU/OS handles set up
    // once in main(); stats and key bindings persist across runs). debug_log,
    // cam_log and mouse_log are NOT preserved here: they're multi-hundred-KB
    // buffers, too large to stack-copy, and losing an unflushed tail on a New
    // Game is harmless (all three are diagnostic only).  Its target PATH is
    // the exception: it is what arms the log for disk at all, and a New Game
    // must keep writing the run's record, not fall silent.
    audio    := gs.audio
    assets   := gs.assets
    stats    := gs.stats
    bindings := gs.bindings
    log_path := gs.debug_log.path

    gs^ = {}  // zero all fields

    gs.audio  = audio
    gs.assets = assets
    gs.stats  = stats
    gs.debug_log.path = log_path
    // First boot arrives zeroed (KEY_NULL) — take the defaults then.
    gs.bindings = bindings[.Move_Left] == .KEY_NULL ? default_bindings : bindings
    gs.ui.settings_capture = -1
    gs.ui.settings_drag    = -1
    gs.ui.win_drag         = -1
    gs.ui.drag_barrel      = -1
    gs.ui.win_pos          = default_window_pos

    gs.player.hp          = 10
    gs.player.hp_max      = 10
    gs.player.mana        = 100
    gs.player.mana_max    = 100
    gs.player.mana_regen  = 5
    gs.player.facing      = 1
    gs.player.walk_anim_period = 0.15
    gs.zoom               = 1.0
    gs.zoom_target        = 1.0
    gs.zoom_from          = 1.0
    gs.zoom_t             = 1.0   // settled: no glide in flight
    gs.loot_rng           = u64(time.now()._nsec)  // fresh drop rolls each run
    gs.world_seed         = world_seed
    gs.ui.show_title      = true   // boot into the title screen; a key press opens the menu
    // No starting tools — the pickaxe waits on the grass (see world_init).

    // Recipes with no gating material (Plank, Bench) are known from the start;
    // pre-mark them so update_recipe_unlocks doesn't announce them as "new".
    for r in recipe_table {
        if recipe_unlock[r.result] == .None do reveal_recipe(&gs.progression, r.result)
    }

    world_init(&gs.world, world_seed)
    spawn_level_1_enemies(gs)
    gs.levels.generated[LEVEL_SURFACE] = true  // lives in gs.world
}
