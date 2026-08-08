package game

import "core:fmt"
import "core:os"
import "core:time"

// ─── Mouse / Mining Aim Log ───────────────────────────────────────────────────
//
//  One line per mining attempt, written to "mouse_pos.log" on exit.
//
//  The question it answers: for the cursor where it actually was, WHICH tile did
//  the game work?  Every stage of the chain is a column — raw virtual-screen px,
//  the camera-inverted world px, the tile that lands in, the player's position,
//  the cursor's offset from the player in tiles (what the pick's direction cone
//  reads), and the tile finally struck.  `off_x`/`off_y` is the money column:
//  the tile struck minus the tile hovered.  Zero means the cursor got what it
//  pointed at; anything else is the aim rule diverging from the pointer.
//
//  Sampled on mining attempts only — not per frame — so a mouse sweep across the
//  screen can't flood the buffer and evict the swings.
//
//  A true RING like cam_loc.log: the newest rows survive.
//  Diagnostic only — compiled out with GAME_DEBUG, like the action log.

MOUSE_LOG_CAP  :: 256 * 1024  // ~1400 rows (~7 min of continuous mining)
MOUSE_LOG_LINE :: 320         // reserved headroom for one formatted line

Mouse_Log :: struct {
    buf:     [MOUSE_LOG_CAP]u8,
    pos:     int,        // write cursor
    end:     int,        // bytes used before the last wrap (0 = never wrapped yet)
    start:   time.Time,  // wall clock of the first row — the header's date, and row t=0
    started: bool,
}

// Record one mining attempt.  `kind` names the path taken, `target` is the tile
// that path chose (always a real tile, even on a whiff — that's the one it would
// have struck), `note` says what came of it.
log_mouse :: proc(gs: ^Game_State, kind: string, target: [2]i32, note: string) {
    when !GAME_DEBUG { return }
    ml  := &gs.mouse_log
    inp := &gs.input
    p   := &gs.player

    if !ml.started {
        ml.start   = time.now()
        ml.started = true
    }
    t := time.duration_seconds(time.since(ml.start))

    // The cursor's offset from the player's center in tiles — the distance
    // pick_target measures every candidate against.
    dx := inp.mouse_world.x / CELL_SIZE - (p.pos.x + PLAYER_W*0.5)
    dy := inp.mouse_world.y / CELL_SIZE - (p.pos.y + PLAYER_H*0.5)

    hover_name  := "out"
    if in_bounds(int(inp.mouse_tile.x), int(inp.mouse_tile.y)) {
        hover_name = terrain_table[get_tile(&gs.world, int(inp.mouse_tile.x), int(inp.mouse_tile.y))].name
    }
    target_name := "out"
    if in_bounds(int(target.x), int(target.y)) {
        target_name = terrain_table[get_tile(&gs.world, int(target.x), int(target.y))].name
    }

    if ml.pos + MOUSE_LOG_LINE > MOUSE_LOG_CAP {
        ml.end = ml.pos   // remember how far the previous lap reached
        ml.pos = 0
    }
    line := fmt.bprintf(
        ml.buf[ml.pos : ml.pos + MOUSE_LOG_LINE - 1],
        // Tab-separated, like cam_loc.log: drops straight into a spreadsheet.
        "%.2f\t%d\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%d\t%s\t%.2f\t%.2f\t%+.2f\t%+.2f\t%d\t%d\t%s\t%+d\t%+d\t%.2f\t%s",
        t, gs.frame, kind,
        inp.mouse_screen.x, inp.mouse_screen.y,
        inp.mouse_world.x, inp.mouse_world.y,
        inp.mouse_tile.x, inp.mouse_tile.y, hover_name,
        p.pos.x, p.pos.y, dx, dy,
        target.x, target.y, target_name,
        target.x - inp.mouse_tile.x, target.y - inp.mouse_tile.y,
        gs.zoom, note,
    )
    ml.pos += len(line)
    ml.buf[ml.pos] = '\n'
    ml.pos += 1
}

MOUSE_LOG_HEADER ::
`# mouse_pos.log - cursor position vs. the tile actually mined, one row per mining attempt.
# Ring buffer: the newest ~1400 attempts survive, oldest first.
# kind    PICK equipped pickaxe  HAND bare-handed tree  WAND shot fired  IMPACT wand shot landing
#         WHIFF nothing mineable that way  NOMANA wand refused
# t       seconds since the first row (the recorded date is above)
# scr_x/y virtual UI-canvas px (1280x720) straight off the letterbox transform
# wld_x/y world px after the camera inverse; m_x/m_y is that divided by CELL_SIZE
# p_x/p_y player position in tiles (top-left of the body); d_x/d_y cursor minus player CENTER, in tiles
# t_x/t_y the tile the aim rule chose; off_x/off_y = that tile minus the hovered tile (0,0 = cursor got what it pointed at)
# WHIFF's note is the tile type that refused the swing ("Void", "Air"); nothing else is mined in its place
`

// Write the ring out oldest-first.  Two spans: whatever survives from the
// previous lap, then this lap.  The first line of the older span is a partial
// leftover the current lap wrote over, so it's trimmed to the first newline.
flush_mouse_log :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    ml := &gs.mouse_log
    if ml.pos == 0 && ml.end == 0 do return

    fd, err := os.open("mouse_pos.log", os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if err != nil do return
    defer os.close(fd)

    os.write_string(fd, MOUSE_LOG_HEADER)

    // The date the run was recorded (UTC — core:time has no local zone without
    // tzdata), so a log file is placeable in time on its own.
    y, mo, d := time.date(ml.start)
    hh, mm, ss := time.clock_from_time(ml.start)
    date_buf: [64]u8
    os.write_string(fd, fmt.bprintf(
        date_buf[:], "# recorded %d-%02d-%02d %02d:%02d:%02d UTC\n",
        y, int(mo), d, hh, mm, ss,
    ))
    os.write_string(fd,
        "t\tframe\tkind\tscr_x\tscr_y\twld_x\twld_y\tm_x\tm_y\tm_tile\tp_x\tp_y\td_x\td_y\tt_x\tt_y\tt_tile\toff_x\toff_y\tzoom\tnote\n")

    if ml.end > ml.pos {
        old := ml.buf[ml.pos:ml.end]
        for b, i in old {
            if b == '\n' {
                os.write(fd, old[i+1:])
                break
            }
        }
    }
    os.write(fd, ml.buf[:ml.pos])
}
