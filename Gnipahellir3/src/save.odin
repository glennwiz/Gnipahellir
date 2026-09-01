package game

import rl "vendor:raylib"
import "core:fmt"
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
SAVE_DATA_EXPECTED_SIZE :: 7_554_872   // EXPERIMENT: MAX_ENEMIES 1024 (3_171_512 at 64, 5_217_080 at 512)
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
#assert(size_of(Save_Data_v23) == 7_554_824)   // EXPERIMENT: 3_171_464 at MAX_ENEMIES 64

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
    return save_game_to(gs, SAVE_FILE)
}

// Split out so snapshots (and tests) can write the same format anywhere.
save_game_to :: proc(gs: ^Game_State, path: string) -> bool {
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

    return os.write_entire_file(path, mem.ptr_to_bytes(sd)) == nil
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
        migrate_hand_gear_to_bag(gs)
        clear_tile_fx_kind(gs, .Raid_Rumble)
        gs.raid = {}
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

    // The raid director is transient by design — reloading during a buildup
    // cancels it — and the pre-load session's rumble telegraph must not
    // outlive the director it announced.
    clear_tile_fx_kind(gs, .Raid_Rumble)
    gs.raid = {}

    // v21 previously stored progression rune scrolls as loose world items.
    // Seal both the active grid and every already-generated stashed grid.
    seal_loose_rune_scrolls(&gs.world)
    for i in 0 ..< len(gs.levels.worlds) {
        if gs.levels.generated[i] do seal_loose_rune_scrolls(&gs.levels.worlds[i])
    }

    // The bucket load used to ride on the player (bucket_fluid); it now lives
    // on the stack as a filled-bucket item.  Convert a carried load in place —
    // same byte layout, so no version bump.  (v23 saves predate the bucket
    // carrying anything, so only this path needs it.)
    if gs.player.bucket_fluid != .Air {
        if inventory_remove(&gs.player.inventory, .Iron_Bucket, 1) {
            inventory_insert(&gs.player.inventory, filled_bucket_for(gs.player.bucket_fluid))
        }
        gs.player.bucket_fluid = .Air
        gs.save_dirty = true
    }

    migrate_hand_gear_to_bag(gs)

    log_action(gs, "run continued from save")
    return true
}

// Hand gear moved from the Weapon/Tool equip slots to the bag + hotbar
// (2026-08-12): older saves may still carry gear in those slots. Return it to
// the bag — or set it on the nearest empty ground cell when the bag is full —
// so nothing is ever lost. Same byte layout, no version bump; the two slots
// simply stay .None from here on.
migrate_hand_gear_to_bag :: proc(gs: ^Game_State) {
    for slot in ([2]Equip_Slot{.Weapon, .Tool}) {
        it := gs.player.equipment[slot]
        if it == .None do continue
        if !inventory_insert(&gs.player.inventory, it, 1) {
            pt := player_tile(&gs.player)
            spot := -1
            scan: for dy in 0 ..= 4 {
                for dx in -2 ..= 2 {
                    x, y := int(pt.x) + dx, int(pt.y) + dy
                    if !in_bounds(x, y) do continue
                    if idx := grid_idx(x, y); gs.world.items[idx] == .None {
                        spot = idx
                        break scan
                    }
                }
            }
            if spot < 0 do continue  // nowhere to put it: stays in the slot, retried next load
            gs.world.items[spot] = it
        }
        gs.player.equipment[slot] = .None
        gs.save_dirty = true
    }
}

// ─── Snapshots (F3 menu) ──────────────────────────────────────────────────────
//
//  Ten numbered slot files in the same Save_Data format as the autosave.
//  Saving is just save_game_to; loading rebuilds the whole Game_State
//  boot-style first so transient state (buffs, golem calls, fluid ages)
//  never leaks across the jump.

SNAP_SLOTS :: 10

snapshot_path :: proc(buf: []u8, slot: int) -> string {
    return fmt.bprintf(buf, "gnipahellir_snap_%d.dat", slot)
}

snapshot_save :: proc(gs: ^Game_State, slot: int) -> bool {
    buf: [40]u8
    ok := save_game_to(gs, snapshot_path(buf[:], slot))
    if ok do log_action(gs, "snapshot %d saved", slot + 1)
    return ok
}

snapshot_load :: proc(gs: ^Game_State, slot: int) -> bool {
    buf: [40]u8
    ok := snapshot_restore_from(gs, snapshot_path(buf[:], slot))
    if ok do log_action(gs, "snapshot %d loaded", slot + 1)
    return ok
}

// Peek-validates the file BEFORE touching the live run — a stale or corrupt
// snapshot must never destroy the current state.  On success the Game_State
// is rebuilt the way main() boots (init, pixel art, load, orphan sweep,
// camera snap), so a mid-session load behaves exactly like quitting and
// relaunching into that save.
snapshot_restore_from :: proc(gs: ^Game_State, path: string) -> bool {
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil do return false
    ok := len(data) == size_of(Save_Data)
    if ok {
        sd := new(Save_Data)
        mem.copy(sd, raw_data(data), size_of(Save_Data))
        ok = sd.version == SAVE_VERSION && !sd.player.dead
        free(sd)
    }
    delete(data)
    if !ok do return false

    flush_action_log(gs)  // game_state_init doesn't preserve the log buffer
    game_state_init(gs, gs.world_seed)
    load_pixel_art(gs)    // init zeroed the sprite bank, same as boot
    if !load_game_from(gs, path) do return false  // unreachable: just validated
    golem_sweep_orphan_quick_clay(gs)
    camera_snap_y(gs)
    gs.ui.show_title = false  // init re-arms the boot title screen
    gs.save_dirty    = true   // the autosave catches up to the jump
    return true
}

// Refreshes the F3 menu's slot cache (existence + write time).  Called when
// the menu opens and after a save — never per frame, and never from draw.
snapshot_scan :: proc(gs: ^Game_State) {
    for slot in 0 ..< SNAP_SLOTS {
        buf: [40]u8
        path := snapshot_path(buf[:], slot)
        gs.ui.snap_exists[slot] = os.exists(path)
        gs.ui.snap_time[slot] = {}
        if gs.ui.snap_exists[slot] {
            if mt, terr := os.modification_time_by_path(path); terr == nil {
                gs.ui.snap_time[slot] = mt
            }
        }
    }
}

snapshot_menu_open :: proc(gs: ^Game_State) {
    snapshot_scan(gs)
    gs.ui.show_snapshots = true
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
