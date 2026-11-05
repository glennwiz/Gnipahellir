package game

import "core:fmt"
import "core:os"
import "core:time"

// ─── Action Log ───────────────────────────────────────────────────────────────
//
//  A STREAMING record of the run.  log_action fills a fixed buffer; every flush
//  APPENDS the filled part to `path` and empties the buffer, so the FILE grows
//  for as long as the run lasts while memory stays at DEBUG_LOG_CAP.  Nothing
//  is ever dropped: the old code went silent once the buffer filled, which is
//  how 63 s of a playtest vanished from the record.
//
//  `path` is EMPTY until a real run arms it (action_log_begin_run, from main).
//  Tests build Game_States by the hundred and every one of them logs; an
//  unarmed log opens no file at all, so `odin test src` can never overwrite
//  Glenn's action.log.  A test that wants the disk path sets `path` itself.
//
//  Call log_action anywhere that has a ^Game_State; flush_action_log runs every
//  300 frames (update.odin) and once before CloseWindow.

DEBUG_LOG_CAP   :: 256 * 1024   // buffer size — the file on disk grows past it
DEBUG_LOG_LINE  :: 512          // headroom reserved for one formatted line
ACTION_LOG_PATH :: "action.log"

Debug_Log :: struct {
    buf:  [DEBUG_LOG_CAP]u8,
    pos:  int,
    path: string,   // "" = buffer only, never written to disk (the test default)
    held: bool,     // armed, but no run has started: flushes wait and the file is untouched
}

log_action :: proc(gs: ^Game_State, format: string, args: ..any) {
    when !GAME_DEBUG { return }
    dl := &gs.debug_log
    // Near-full: stream what we have out and carry on with an empty buffer.
    // With no path armed there is nowhere to stream to, so the buffer simply
    // starts over — a headless test wraps instead of wedging.
    if dl.pos >= DEBUG_LOG_CAP - DEBUG_LOG_LINE {
        flush_action_log(gs)
    }
    prefix_buf: [32]u8
    prefix := fmt.bprintf(prefix_buf[:], "[f%07d] ", gs.frame)
    copy(dl.buf[dl.pos:], prefix)
    dl.pos += len(prefix)

    body := fmt.bprintf(dl.buf[dl.pos:], format, ..args)
    dl.pos += len(body)
    dl.buf[dl.pos] = '\n'
    dl.pos += 1
}

// Append the buffered lines to the run's log file and empty the buffer.  The
// buffer is cleared either way: an unarmed (or unopenable) log must still stay
// bounded, and a run that cannot write to disk is not a reason to stop playing.
flush_action_log :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    dl := &gs.debug_log
    if dl.held || dl.pos == 0 do return
    if dl.path != "" {
        if fd, err := os.open(dl.path, os.O_WRONLY | os.O_CREATE | os.O_APPEND); err == nil {
            os.write(fd, dl.buf[:dl.pos])
            os.close(fd)
        }
    }
    dl.pos = 0
}

// The kinds whose builder.goal is theirs: the builder and raider brains, a
// wave's fire sprite, the risen hero.  Every other kind leaves it at its zero
// value, which would read as Build_Den (playtest 135: Rain_Wisp goal=Build_Den),
// so its pos line says goal=- instead.
@(rodata)
log_has_goal := #partial [Enemy_Kind]bool{
    .Builder = true, .Raider = true, .Vargr = true, .Fire_Sprite = true, .Undead = true,
}

// Where every live body IS, written on update.odin's 5 s flush beat.  Bespoke
// lines only fire when something HAPPENS, so a flyer that drifts to the map
// edge and then does nothing leaves no trace at all — which is precisely how
// two fire sprites went missing from a playtest for 63 s.  Worst case is
// 1 + MAX_ENEMIES lines per beat, which is nothing now that the log streams.
log_breadcrumbs :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    p := &gs.player
    log_action(gs, "pos Player (%.1f,%.1f) hp=%d mana=%.0f lvl=%d",
        p.pos.x, p.pos.y, p.hp, p.mana, gs.level_index)
    for &e, i in gs.enemies.data {
        if !gs.enemies.active[i] do continue
        if !log_has_goal[e.kind] {
            log_action(gs, "pos Enemy#%d %v (%.1f,%.1f) hp=%d goal=-", i, e.kind, e.pos.x, e.pos.y, e.hp)
            continue
        }
        log_action(gs, "pos Enemy#%d %v (%.1f,%.1f) hp=%d goal=%v target=(%d,%d)",
            i, e.kind, e.pos.x, e.pos.y, e.hp,
            e.builder.goal, e.builder.target_tile.x, e.builder.target_tile.y)
    }
    if gs.birds.seeded do for &f, i in gs.birds.flocks {  // sky scenery, its own store
        log_action(gs, "pos Flock#%d (%.1f,%.1f) heading=%+.0f scattered=%v", i, f.center.x, f.center.y, f.heading, f.scatter_t > 0)
    }
}

// Name an entity for a log line: "Player", "Enemy#3(Fire_Sprite)", or "the
// world" for the sourceless hurts (lava, a fall).  Formats into the CALLER's
// buffer, so attributing a line still allocates nothing.  One place, because
// "who did that" is the question every damage and demolition line has to
// answer and the answer must read the same everywhere.
entity_name :: proc(gs: ^Game_State, id: Entity_ID, buf: []u8) -> string {
    if id == PLAYER_ID do return "Player"
    i := entity_id_to_enemy_index(id)
    if i >= 0 && i < MAX_ENEMIES && gs.enemies.active[i] {
        return fmt.bprintf(buf, "Enemy#%d(%v)", i, gs.enemies.data[i].kind)
    }
    return "the world"
}

// Open the run's record: arm the path, write the header, and hold it all in the
// buffer.  Called once from main before the loop.  The file waits for
// action_log_release: a run owns the log it writes, and a boot that leaves by the
// title, or hands the game to an agent's sandbox, has not started one.  Loading a
// save mid-session does NOT come through here: it logs its own line into the
// same file, because the record must keep the run that led up to the load.
action_log_begin_run :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    gs.debug_log.path = ACTION_LOG_PATH
    gs.debug_log.held = true

    now := time.now()
    d_buf: [time.MIN_YYYY_DATE_LEN]u8
    t_buf: [time.MIN_HMS_LEN]u8
    log_action(gs, "=== run start %s %s - save v%d ===",
        time.to_string_yyyy_mm_dd(now, d_buf[:]), time.to_string_hms(now, t_buf[:]),
        SAVE_VERSION)
}

// A run has started: the last run's log goes, and the held lines can reach disk.
action_log_release :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    dl := &gs.debug_log
    if !dl.held do return
    dl.held = false
    if fd, err := os.open(dl.path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC); err == nil {
        os.close(fd)
    }
}
