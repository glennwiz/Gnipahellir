package game

import "core:fmt"
import "core:os"

// ─── Action Log ───────────────────────────────────────────────────────────────
//
//  Fixed ring buffer written to "enemy_action.log" on game exit.
//  Call log_action anywhere that has a *Game_State.
//  Call flush_action_log once before CloseWindow.

DEBUG_LOG_CAP :: 256 * 1024   // 256 KB — plenty for a full run

Debug_Log :: struct {
    buf:      [DEBUG_LOG_CAP]u8,
    pos:      int,
    overflow: bool,   // set when we start dropping entries
}

log_action :: proc(gs: ^Game_State, format: string, args: ..any) {
    dl := &gs.debug_log
    if dl.pos >= DEBUG_LOG_CAP - 256 {
        dl.overflow = true
        return
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

flush_action_log :: proc(gs: ^Game_State) {
    if gs.debug_log.pos == 0 { return }
    data := gs.debug_log.buf[:gs.debug_log.pos]
    _ = os.write_entire_file("enemy_action.log", data)
}
