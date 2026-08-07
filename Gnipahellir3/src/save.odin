package game

import rl "vendor:raylib"
import "core:mem"
import "core:os"

// ─── Save / Load ──────────────────────────────────────────────────────────────
//
//  Binary snapshot of the run, memcpy'd to disk (all state is POD, no pointers).
//  Rejected on size or version mismatch — a bad save just starts a fresh run.
//  Persistent stats live in their own file and survive across runs.

SAVE_FILE    :: "gnipahellir_save.dat"
STATS_FILE   :: "gnipahellir_stats.dat"
SAVE_DEBOUNCE :: f32(5)  // min seconds between autosaves (main loop debounce)
SAVE_VERSION :: i32(23)  // v23: saved golem packs and vertical recovery state

// Tripwire: the save is a raw memory snapshot, so ANY layout change to a
// saved struct (World_Grid, Player, Enemy, Level_Store, ...) changes this
// size and silently invalidates old saves.  When this assert fires: bump
// SAVE_VERSION and update the expected size in the same commit.
SAVE_DATA_EXPECTED_SIZE :: 3_171_464
#assert(size_of(Save_Data) == SAVE_DATA_EXPECTED_SIZE)

// One-version migration keeps the active playtest run intact. v22 had the
// same world/progression layout but each golem ended at project_cell.
Golem_v22 :: struct {
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
    project_cell: i16,
}

Golem_System_v22 :: struct {
    data:     [MAX_GOLEMS]Golem_v22,
    work:     [NUM_LEVELS]Golem_Work_Order,
    projects: [NUM_LEVELS]Golem_Project,
    depots:   [MAX_GOLEM_DEPOTS]Golem_Depot_State,
}

Save_Data_v22 :: struct {
    version:      i32,
    level_index:  int,
    world:        World_Grid,
    levels:       Level_Store,
    player:       Player,
    enemies:      Enemy_Store,
    golems:       Golem_System_v22,
    sim:          Sim_State,
    progression:  Progression_State,
    dimension:    Dimension_State,
    elapsed_time: f32,
    frame:        u64,
}
#assert(size_of(Save_Data_v22) == 3_171_224)

Save_Data :: struct {
    version:      i32,
    level_index:  int,
    world:        World_Grid,
    levels:       Level_Store,   // stashed non-active levels
    player:       Player,
    enemies:      Enemy_Store,   // builder goals/dens/carry ride along — Enemy is flat
    golems:       Golem_System,
    sim:          Sim_State,
    progression:  Progression_State,
    dimension:    Dimension_State,
    elapsed_time: f32,
    frame:        u64,
}

save_game :: proc(gs: ^Game_State) -> bool {
    sd := new(Save_Data)
    defer free(sd)

    sd.version      = SAVE_VERSION
    sd.level_index  = gs.level_index
    sd.world        = gs.world
    sd.levels       = gs.levels
    sd.player       = gs.player
    sd.enemies      = gs.enemies
    sd.golems       = gs.golems
    sd.sim          = gs.sim
    sd.progression  = gs.progression
    sd.dimension    = gs.dimension
    sd.elapsed_time = gs.elapsed_time
    sd.frame        = gs.frame

    return os.write_entire_file(SAVE_FILE, mem.ptr_to_bytes(sd)) == nil
}

load_game :: proc(gs: ^Game_State) -> bool {
    data, err := os.read_entire_file_from_path(SAVE_FILE, context.allocator)
    if err != nil do return false
    defer delete(data)
    if len(data) == size_of(Save_Data_v22) {
        old := new(Save_Data_v22)
        defer free(old)
        mem.copy(old, raw_data(data), size_of(Save_Data_v22))
        if old.version != 22 || old.player.dead do return false

        gs.level_index = old.level_index
        gs.world = old.world
        gs.levels = old.levels
        gs.player = old.player
        gs.enemies = old.enemies
        gs.golems.work = old.golems.work
        gs.golems.projects = old.golems.projects
        gs.golems.depots = old.golems.depots
        for &g, i in gs.golems.data {
            o := old.golems.data[i]
            g.status=o.status; g.level=o.level; g.pos=o.pos; g.vel=o.vel; g.hp=o.hp
            g.mode=o.mode; g.job=o.job; g.carry=o.carry; g.target=o.target
            g.has_target=o.has_target; g.path=o.path; g.mine_timer=o.mine_timer
            g.hazard_timer=o.hazard_timer; g.replan_timer=o.replan_timer
            g.facing=o.facing; g.grounded=o.grounded; g.project_cell=o.project_cell
        }
        gs.sim = old.sim
        gs.progression = old.progression
        gs.dimension = old.dimension
        gs.elapsed_time = old.elapsed_time
        gs.frame = old.frame
        seal_loose_rune_scrolls(&gs.world)
        for i in 0 ..< len(gs.levels.worlds) do if gs.levels.generated[i] do seal_loose_rune_scrolls(&gs.levels.worlds[i])
        log_action(gs, "run migrated from save v22")
        gs.save_dirty = true
        return true
    }
    if len(data) != size_of(Save_Data) do return false

    sd := new(Save_Data)
    defer free(sd)
    mem.copy(sd, raw_data(data), size_of(Save_Data))

    if sd.version != SAVE_VERSION do return false
    if sd.player.dead do return false  // dead runs don't resume

    gs.level_index  = sd.level_index
    gs.world        = sd.world
    gs.levels       = sd.levels
    gs.player       = sd.player
    gs.enemies      = sd.enemies
    gs.golems       = sd.golems
    gs.sim          = sd.sim
    gs.progression  = sd.progression
    gs.dimension    = sd.dimension
    gs.elapsed_time = sd.elapsed_time
    gs.frame        = sd.frame

    // v21 previously stored progression rune scrolls as loose world items.
    // Seal both the active grid and every already-generated stashed grid.
    seal_loose_rune_scrolls(&gs.world)
    for i in 0 ..< len(gs.levels.worlds) {
        if gs.levels.generated[i] do seal_loose_rune_scrolls(&gs.levels.worlds[i])
    }

    log_action(gs, "run continued from save")
    return true
}

// "New Game" from the menu: wipes any existing save and drops the player
// straight into a fresh run (mirrors main()'s no-save-found spawn).
start_new_game :: proc(gs: ^Game_State) {
    flush_action_log(gs)  // game_state_init doesn't preserve the log buffer
    os.remove(SAVE_FILE)
    seed := new_game_world_seed()   // random per run, or GNIPA_SEED override
    game_state_init(gs, seed)
    log_action(gs, "New game - world seed %d", seed)
    gs.player.pos            = SURFACE_HOME_POS
    gs.player.clothing_color = rl.BLUE
    gs.player.hair_color     = rl.ORANGE
    camera_snap_y(gs)
    gs.ui.show_menu          = false
    gs.ui.show_title         = false  // game_state_init re-arms the boot title screen
    gs.ui.show_charselect    = true   // pick a look before the fresh run begins
}

// Called once at shutdown: live runs persist; dead and won runs clear the
// save (roguelike semantics — the run is over either way).
save_on_quit :: proc(gs: ^Game_State) {
    if gs.player.dead || gs.game_won {
        os.remove(SAVE_FILE)
    } else {
        _ = save_game(gs)
    }
    _ = save_stats(&gs.stats)
    _ = save_settings(gs)
}

// ─── Settings (volumes + key bindings) ────────────────────────────────────────
//
//  Separate small file: settings survive across runs and deaths, like stats.
//  Saved when the settings screen closes / a binding changes, and on quit.

SETTINGS_FILE    :: "gnipahellir_settings.dat"
SETTINGS_VERSION :: i32(2)   // v2: retired the Crafting bind (TAB opens bag+craft)

Settings_Data :: struct {
    version:  i32,
    master:   f32,
    sfx:      f32,
    music:    f32,
    bindings: [Action]rl.KeyboardKey,
}

save_settings :: proc(gs: ^Game_State) -> bool {
    sd := Settings_Data{
        version  = SETTINGS_VERSION,
        master   = gs.audio.master_volume,
        sfx      = gs.audio.sfx_volume,
        music    = gs.audio.music_volume,
        bindings = gs.bindings,
    }
    return os.write_entire_file(SETTINGS_FILE, mem.ptr_to_bytes(&sd)) == nil
}

load_settings :: proc(gs: ^Game_State) -> bool {
    data, err := os.read_entire_file_from_path(SETTINGS_FILE, context.allocator)
    if err != nil do return false
    defer delete(data)
    if len(data) != size_of(Settings_Data) do return false

    sd: Settings_Data
    mem.copy(&sd, raw_data(data), size_of(Settings_Data))
    if sd.version != SETTINGS_VERSION do return false

    gs.audio.master_volume = clamp(sd.master, 0, 1)
    gs.audio.sfx_volume    = clamp(sd.sfx, 0, 1)
    gs.audio.music_volume  = clamp(sd.music, 0, 1)
    for a in Action {
        if sd.bindings[a] != .KEY_NULL do gs.bindings[a] = sd.bindings[a]
    }
    return true
}

// ─── Persistent Stats ─────────────────────────────────────────────────────────

save_stats :: proc(stats: ^Persistent_Stats) -> bool {
    return os.write_entire_file(STATS_FILE, mem.ptr_to_bytes(stats)) == nil
}

load_stats :: proc(stats: ^Persistent_Stats) -> bool {
    data, err := os.read_entire_file_from_path(STATS_FILE, context.allocator)
    if err != nil do return false
    defer delete(data)
    if len(data) != size_of(Persistent_Stats) do return false

    mem.copy(stats, raw_data(data), size_of(Persistent_Stats))
    return true
}
