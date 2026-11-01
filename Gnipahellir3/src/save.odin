package game

import rl "vendor:raylib"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"

// ─── Save / Load ──────────────────────────────────────────────────────────────
//
//  Binary snapshot of the run, memcpy'd to disk (all state is POD, no pointers).
//  Rejected on size or version mismatch — a bad save just starts a fresh run.
//  Persistent stats live in their own file and survive across runs.

SAVE_FILE    :: "gnipahellir_save.dat"
STATS_FILE   :: "gnipahellir_stats.dat"
SAVE_DEBOUNCE :: f32(5)  // min seconds between autosaves (main loop debounce)
SAVE_VERSION :: i32(28)  // v28: MAX_ENEMIES 256 (Glenn's Q5), down from 1024

// Tripwire: the save is a raw memory snapshot, so ANY layout change to a
// saved struct (World_Grid, Player, Enemy, Level_Store, ...) changes this
// size and silently invalidates old saves.  When this assert fires: bump
// SAVE_VERSION and update the expected size in the same commit.
// (save_data_size_probe logs the real number, plus len(Item).)
SAVE_DATA_EXPECTED_SIZE :: 4_048_864
#assert(size_of(Save_Data) == SAVE_DATA_EXPECTED_SIZE)

// Every older save was written at MAX_ENEMIES 1024, so those files are read
// through the frozen Save_Data_1024 below, then shrunk (save_data_shrink).  v24,
// v25 and v26 are v27 cut short before grave, risen and world_seed, and the rest
// stays zero: no stone, no kit, and seed 0, which is what an old run's reload
// always used.
SAVE_V24_SIZE :: 7_554_872
SAVE_V25_SIZE :: 7_554_968
SAVE_V26_SIZE :: 7_555_544
SAVE_V27_SIZE :: 7_555_552
#assert(offset_of(Save_Data_1024, grave) == SAVE_V24_SIZE)
#assert(offset_of(Save_Data_1024, risen) == SAVE_V25_SIZE)
#assert(offset_of(Save_Data_1024, world_seed) == SAVE_V26_SIZE)
#assert(size_of(Save_Data_1024) == SAVE_V27_SIZE)

ENEMIES_1024 :: 1024   // FROZEN: the cap every save before v28 was written at

Enemy_Store_1024 :: struct {
    data:   [ENEMIES_1024]Enemy,
    active: [ENEMIES_1024]bool,
    count:  int,
}

Level_Store_1024 :: struct {
    worlds:    [NUM_LEVELS]World_Grid,
    enemies:   [NUM_LEVELS]Enemy_Store_1024,
    generated: [NUM_LEVELS]bool,
}

Save_Data_1024 :: struct {
    version:      i32,
    level_index:  int,
    world:        World_Grid,
    levels:       Level_Store_1024,
    player:       Player,
    enemies:      Enemy_Store_1024,
    golems:       Golem_System,
    sim:          Sim_State,
    progression:  Progression_State,
    dimension:    Dimension_State,
    elapsed_time: f32,
    frame:        u64,
    grave:        Grave_Record,
    risen:        Risen_Hero,
    world_seed:   u32,
}

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
    levels:       Level_Store_1024,
    player:       Player,
    enemies:      Enemy_Store_1024,
    golems:       Golem_System,
    sim:          Sim_State,
    progression:  Progression_State_v23,
    dimension:    Dimension_State,
    elapsed_time: f32,
    frame:        u64,
}
#assert(size_of(Save_Data_v23) == 7_554_824)

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
    grave:        Grave_Record,  // see SAVE_V24_SIZE
    risen:        Risen_Hero,    // see SAVE_V25_SIZE
    world_seed:   u32,           // keep last: see SAVE_V26_SIZE
}

// Slots are kept where they fit: enemy_alloc fills from the bottom, so a 1024
// save rarely holds anything past 255.  Those above move down into free slots
// and their entity_map marks follow; with no free slot the body is gone, the
// one thing the smaller cap costs.  Returns where each old slot went, -1 if lost.
enemy_store_shrink :: proc(from: ^Enemy_Store_1024, to: ^Enemy_Store, w: ^World_Grid) -> (moved: [ENEMIES_1024]int) {
    to^ = {}
    for i in 0 ..< ENEMIES_1024 do moved[i] = -1
    for i in 0 ..< MAX_ENEMIES {
        if !from.active[i] do continue
        to.data[i]   = from.data[i]
        to.active[i] = true
        to.count    += 1
        moved[i]     = i
    }
    free_slot := 0
    for i in MAX_ENEMIES ..< ENEMIES_1024 {
        if !from.active[i] do continue
        for free_slot < MAX_ENEMIES && to.active[free_slot] do free_slot += 1
        if free_slot == MAX_ENEMIES do break
        to.data[free_slot]   = from.data[i]
        to.active[free_slot] = true
        to.count += 1
        moved[i]  = free_slot
    }
    for &id in w.entity_map {
        if id == PLAYER_ID || id == INVALID_ENTITY do continue
        i := entity_id_to_enemy_index(id)
        id = i < ENEMIES_1024 && moved[i] >= 0 ? enemy_entity_id(moved[i]) : INVALID_ENTITY
    }
    return
}

// Returns `moved` for the stashed surface, where a risen hero may be standing.
level_store_shrink :: proc(from: ^Level_Store_1024, to: ^Level_Store) -> (surface: [ENEMIES_1024]int) {
    to.worlds    = from.worlds
    to.generated = from.generated
    for i in 0 ..< NUM_LEVELS {
        moved := enemy_store_shrink(&from.enemies[i], &to.enemies[i], &to.worlds[i])
        if i == LEVEL_SURFACE do surface = moved
    }
    return
}

// A body lost to the cap must not take the kit with it: the kit stays in the
// record, unwalked, and the hero can rise again.
@(private="file")
risen_after_shrink :: proc(r: ^Risen_Hero, moved: ^[ENEMIES_1024]int) {
    if !r.walking do return
    r.slot = moved[r.slot]
    if r.slot < 0 do r.walking, r.slot = false, 0
}

// An older file's run, at the current cap.  Returns a new Save_Data.
save_data_shrink :: proc(old: ^Save_Data_1024) -> ^Save_Data {
    sd := new(Save_Data)
    sd.version      = SAVE_VERSION
    sd.level_index  = old.level_index
    sd.world        = old.world
    sd.player       = old.player
    sd.golems       = old.golems
    sd.sim          = old.sim
    sd.progression  = old.progression
    sd.dimension    = old.dimension
    sd.elapsed_time = old.elapsed_time
    sd.frame        = old.frame
    sd.grave        = old.grave
    sd.risen        = old.risen
    sd.world_seed   = old.world_seed
    surface := level_store_shrink(&old.levels, &sd.levels)
    moved := enemy_store_shrink(&old.enemies, &sd.enemies, &sd.world)
    risen_after_shrink(&sd.risen, old.level_index == LEVEL_SURFACE ? &moved : &surface)
    return sd
}

// The bytes as a Save_Data if they are a run that can resume, else nil.  Older
// files are shorter; the caller frees the result.
save_data_read :: proc(data: []u8) -> ^Save_Data {
    if len(data) == size_of(Save_Data) {
        sd := new(Save_Data)
        mem.copy(sd, raw_data(data), len(data))
        if sd.version == SAVE_VERSION && !sd.player.dead do return sd  // dead runs don't resume
        free(sd)
        return nil
    }
    version: i32
    switch len(data) {
    case SAVE_V27_SIZE: version = 27
    case SAVE_V26_SIZE: version = 26
    case SAVE_V25_SIZE: version = 25
    case SAVE_V24_SIZE: version = 24
    case:               return nil
    }
    old := new(Save_Data_1024)
    defer free(old)
    mem.copy(old, raw_data(data), len(data))
    if old.version != version || old.player.dead do return nil
    return save_data_shrink(old)
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
    sd.grave        = gs.grave
    sd.risen        = gs.risen
    sd.world_seed   = gs.world_seed

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
        _ = level_store_shrink(&old.levels, &gs.levels)
        gs.player = old.player
        _ = enemy_store_shrink(&old.enemies, &gs.enemies, &gs.world)
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

    sd := save_data_read(data)
    if sd == nil do return false
    defer free(sd)

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
    gs.grave        = sd.grave
    gs.risen        = sd.risen
    gs.world_seed   = sd.world_seed

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
    sd := save_data_read(data)
    ok := sd != nil
    free(sd)
    delete(data)
    if !ok do return false

    flush_action_log(gs)  // game_state_init doesn't preserve the log buffer
    game_state_init(gs, gs.world_seed)
    gs.stats.grave = {}   // a rewound hero did not die, so no grave, tithe or kit
    gs.stats.kit   = {}
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

// The run's autosave goes.  Death, a new game and a finished run all end up
// here, and a state main never armed has no file to lose: that is what keeps
// `odin test src` off a real save, the same way an unarmed action log is.
save_remove :: proc(gs: ^Game_State) {
    if len(gs.save_path) > 0 do os.remove(gs.save_path)
}

// "New Game" from the menu: wipes any existing save and drops the player
// straight into a fresh run (mirrors main()'s no-save-found spawn).
start_new_game :: proc(gs: ^Game_State) {
    start_new_game_with(gs, agent_new_game_seed(gs))   // random per run, GNIPA_SEED override, chained under an agent
}

// The title's way in: the typed seed if there is one, else a fresh world.
start_title_game :: proc(gs: ^Game_State) {
    if !gs.ui.title_fresh do return
    seed := agent_new_game_seed(gs)
    if gs.ui.title_seed_len > 0 {
        n, _ := strconv.parse_u64(string(gs.ui.title_seed[:gs.ui.title_seed_len]))
        seed = u32(n)   // wraps as GNIPA_SEED does, so the two agree
    }
    start_new_game_with(gs, seed)
}

start_new_game_with :: proc(gs: ^Game_State, seed: u32) {
    flush_action_log(gs)  // game_state_init doesn't preserve the log buffer
    save_remove(gs)
    game_state_init(gs, seed)
    load_pixel_art(gs)    // init zeroed the sprite bank, same as boot
    log_action(gs, "New game - world seed %d", seed)
    gs.stats.last_seed     = seed
    gs.stats.has_last_seed = true
    _ = save_stats(gs)
    gs.player.pos            = SURFACE_HOME_POS
    gs.player.clothing_color = rl.BLUE
    gs.player.hair_color     = rl.ORANGE
    camera_snap_y(gs)
    gs.ui.show_menu          = false
    gs.ui.show_title         = false  // game_state_init re-arms the boot title screen
    grave_raise(gs)
}

// Called once at shutdown: live runs persist; dead and won runs clear the
// save (roguelike semantics — the run is over either way).
save_on_quit :: proc(gs: ^Game_State) {
    if gs.player.dead || gs.game_won {
        save_remove(gs)
    } else {
        _ = save_game(gs)
    }
    _ = save_stats(gs)
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

//  STATS_VERSION is in the file since v2; v1 was the bare four counters, and
//  v2 and v3 are v4 cut short before the kit and the last seed.  A
//  file this build cannot read is moved aside, never overwritten.  The state
//  main never armed has no file, which keeps `odin test src` off real stats.

STATS_VERSION :: i32(4)
STATS_V2_SIZE :: int(offset_of(Persistent_Stats, kit))
STATS_V3_SIZE :: int(offset_of(Persistent_Stats, last_seed))

Persistent_Stats_v1 :: struct {
    runs_played:  int,
    runs_won:     int,
    deepest_cave: int,
    total_kills:  int,
}
#assert(size_of(Persistent_Stats_v1) == 32)
#assert(size_of(Persistent_Stats) != size_of(Persistent_Stats_v1))

save_stats :: proc(gs: ^Game_State) -> bool {
    if len(gs.stats_path) == 0 do return false
    return save_stats_to(&gs.stats, gs.stats_path)
}

save_stats_to :: proc(stats: ^Persistent_Stats, path: string) -> bool {
    stats.version = STATS_VERSION
    return os.write_entire_file(path, mem.ptr_to_bytes(stats)) == nil
}

load_stats :: proc(stats: ^Persistent_Stats, path: string) -> bool {
    data, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil do return false
    defer delete(data)

    switch len(data) {
    case size_of(Persistent_Stats_v1):
        old: Persistent_Stats_v1
        mem.copy(&old, raw_data(data), size_of(old))
        stats^ = {
            version      = STATS_VERSION,
            runs_played  = old.runs_played,
            runs_won     = old.runs_won,
            deepest_cave = old.deepest_cave,
            total_kills  = old.total_kills,
        }
        return true
    case STATS_V2_SIZE, STATS_V3_SIZE, size_of(Persistent_Stats):
        version := STATS_VERSION
        if len(data) == STATS_V2_SIZE do version = 2
        if len(data) == STATS_V3_SIZE do version = 3
        read: Persistent_Stats
        mem.copy(&read, raw_data(data), len(data))
        if read.version == version {
            read.version = STATS_VERSION
            stats^ = read
            return true
        }
    }
    _ = os.rename(path, fmt.tprintf("%s.unread", path))
    return false
}
