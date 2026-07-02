package game

import "core:mem"
import "core:os"

// ─── Save / Load ──────────────────────────────────────────────────────────────
//
//  Binary snapshot of the run, memcpy'd to disk (all state is POD, no pointers).
//  Rejected on size or version mismatch — a bad save just starts a fresh run.
//  Persistent stats live in their own file and survive across runs.

SAVE_FILE    :: "gnipahellir_save.dat"
STATS_FILE   :: "gnipahellir_stats.dat"
SAVE_VERSION :: i32(2)

Save_Data :: struct {
    version:      i32,
    level_index:  int,
    world:        World_Grid,
    levels:       Level_Store,   // stashed non-active levels
    player:       Player,
    enemies:      Enemy_Store,   // builder goals/dens/carry ride along — Enemy is flat
    sim:          Sim_State,
    progression:  Progression_State,
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
    sd.sim          = gs.sim
    sd.progression  = gs.progression
    sd.elapsed_time = gs.elapsed_time
    sd.frame        = gs.frame

    return os.write_entire_file(SAVE_FILE, mem.ptr_to_bytes(sd)) == nil
}

load_game :: proc(gs: ^Game_State) -> bool {
    data, err := os.read_entire_file_from_path(SAVE_FILE, context.allocator)
    if err != nil do return false
    defer delete(data)
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
    gs.sim          = sd.sim
    gs.progression  = sd.progression
    gs.elapsed_time = sd.elapsed_time
    gs.frame        = sd.frame

    log_action(gs, "run continued from save")
    return true
}

// Called once at shutdown: live runs persist, dead runs clear the save.
save_on_quit :: proc(gs: ^Game_State) {
    if gs.player.dead {
        os.remove(SAVE_FILE)
    } else {
        _ = save_game(gs)
    }
    _ = save_stats(&gs.stats)
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
