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
SAVE_VERSION :: i32(24)  // v24: recipe_unlocked sized to MAX_ITEM_SLOTS, not [Item]

// Tripwire: the save is a raw memory snapshot, so ANY layout change to a
// saved struct (World_Grid, Player, Enemy, Level_Store, ...) changes this
// size and silently invalidates old saves.  When this assert fires: bump
// SAVE_VERSION and update the expected size in the same commit.
// (save_data_size_probe logs the real number, plus len(Item).)
SAVE_DATA_EXPECTED_SIZE :: 3_171_512
#assert(size_of(Save_Data) == SAVE_DATA_EXPECTED_SIZE)

// One-version migration keeps the active playtest run intact.
//
// v23 was identical except that Progression_State keyed recipe_unlocked by
// [Item], so the array was exactly as long as the item enum happened to be —
// which is why appending Scroll_Of_Waters moved the whole save.  v24 sizes it
// to MAX_ITEM_SLOTS so that never happens again; the migration just copies the
// old flags into the front of the wider array.
//
// The v22 path was dropped here: it embedded the live Progression_State, so
// this very change broke it, and v22 is two versions stale.
//
// NOTE: this reuses the LIVE Player/World_Grid/etc. — correct only while those
// are unchanged since v23.  Player's `bucket_lava: bool` did become
// `bucket_fluid: Tile_Type` this session, but it is the same byte and the old
// bool was never written, so a v23 save reads back as an empty bucket.
RECIPE_SLOTS_V23 :: 84   // FROZEN len(Item) at v23 — never re-derive from len(Item)

Progression_State_v23 :: struct {
    rune_scroll_found:      [MAX_PROGRESSION_TIERS]bool,
    sky_structure_complete: [MAX_PROGRESSION_TIERS]bool,
    cave_unlocked:          [MAX_PROGRESSION_TIERS]bool,
    final_boss_defeated:    bool,
    sky_altar_pos:          [2]i32,
    recipe_unlocked:        [RECIPE_SLOTS_V23]bool,
}
#assert(size_of(Progression_State_v23) == 104)

Save_Data_v23 :: struct {
    version:      i32,
    level_index:  int,
    world:        World_Grid,
    levels:       Level_Store,
    player:       Player,
    enemies:      Enemy_Store,
    golems:       Golem_System,
    sim:          Sim_State,
    progression:  Progression_State_v23,
    dimension:    Dimension_State,
    elapsed_time: f32,
    frame:        u64,
}
#assert(size_of(Save_Data_v23) == 3_171_464)

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
    return load_game_from(gs, SAVE_FILE)
}

// Split out so tests can drive a synthetic save (a migration fixture) without
// ever touching the player's real SAVE_FILE.
load_game_from :: proc(gs: ^Game_State, path: string) -> bool {
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil do return false
    defer delete(data)
    if len(data) == size_of(Save_Data_v23) {
        old := new(Save_Data_v23)
        defer free(old)
        mem.copy(old, raw_data(data), size_of(Save_Data_v23))
        if old.version != 23 || old.player.dead do return false

        gs.level_index = old.level_index
        gs.world = old.world
        gs.levels = old.levels
        gs.player = old.player
        gs.enemies = old.enemies
        gs.golems = old.golems
        gs.sim = old.sim
        gs.dimension = old.dimension
        gs.elapsed_time = old.elapsed_time
        gs.frame = old.frame

        // Only progression changed shape: the same flags, now in a wider array.
        gs.progression.rune_scroll_found      = old.progression.rune_scroll_found
        gs.progression.sky_structure_complete = old.progression.sky_structure_complete
        gs.progression.cave_unlocked          = old.progression.cave_unlocked
        gs.progression.final_boss_defeated    = old.progression.final_boss_defeated
        gs.progression.sky_altar_pos          = old.progression.sky_altar_pos
        gs.progression.recipe_unlocked = {}
        for f, i in old.progression.recipe_unlocked do gs.progression.recipe_unlocked[i] = f

        seal_loose_rune_scrolls(&gs.world)
        for i in 0 ..< len(gs.levels.worlds) do if gs.levels.generated[i] do seal_loose_rune_scrolls(&gs.levels.worlds[i])
        log_action(gs, "run migrated from save v23")
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
