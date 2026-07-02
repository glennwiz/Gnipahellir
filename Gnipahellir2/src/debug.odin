package gnipahellir

import fmt "core:fmt"
import "core:os"

// Toggle debug logs for placement & dragging
DEBUG_LOG_PLACEMENT :: true

debugf :: proc(fmt_str: string, args: ..any) {
    if !DEBUG_LOG_PLACEMENT do return
    fmt.print("[PLACEMENT] ")
    // Odin variadics: forward with ..args
    fmt.printf(fmt_str, ..args)
    fmt.println()
}

// ---- Garm movement/action logging ----

// Append a preformatted message as a line to garm_move.log
garm_log :: proc(game: ^Game_State, msg: string) {
    filename := "garm_move.log"
    prefix := fmt.tprintf("%0.3fs ", cast(f64)game.elapsed_time)
    // Build a single line: prefix + msg + \n
    pb := transmute([]u8)prefix
    mb := transmute([]u8)msg
    line := make([]u8, len(pb)+len(mb)+1)
    n := copy(line[:], pb)
    n += copy(line[n:], mb)
    line[n] = '\n'

    existing, read_err := os.read_entire_file_from_path(filename, context.allocator)
    if read_err == nil {
        combined := make([]u8, len(existing)+len(line))
        _ = copy(combined[:], existing)
        _ = copy(combined[len(existing):], line)
        _ = os.write_entire_file(filename, combined)
        delete(combined)
    } else {
        _ = os.write_entire_file(filename, line)
    }
    delete(line)
}

// Append a preformatted message as a line to garm_action.log
garm_action_log :: proc(game: ^Game_State, msg: string) {
    filename := "garm_action.log"
    prefix := fmt.tprintf("%0.3fs ", cast(f64)game.elapsed_time)
    pb := transmute([]u8)prefix
    mb := transmute([]u8)msg
    line := make([]u8, len(pb)+len(mb)+1)
    n := copy(line[:], pb)
    n += copy(line[n:], mb)
    line[n] = '\n'

    existing, read_err2 := os.read_entire_file_from_path(filename, context.allocator)
    if read_err2 == nil {
        combined := make([]u8, len(existing)+len(line))
        _ = copy(combined[:], existing)
        _ = copy(combined[len(existing):], line)
        _ = os.write_entire_file(filename, combined)
        delete(combined)
    } else {
        _ = os.write_entire_file(filename, line)
    }
    delete(line)
}
