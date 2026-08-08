package game

import "core:fmt"
import "core:os"

// ─── Camera Position Log ──────────────────────────────────────────────────────
//
//  One line per simulated frame, written to "cam_loc.log" on exit.
//
//  We are hunting unrequested horizontal camera motion, so the sample is the
//  real clamped `rl.Camera2D.target` that game_camera hands the renderer — the
//  value the eye actually sees — not the inputs that produced it. dx (change
//  since the previous frame) is the column a jerk shows up in: a smooth glide
//  ramps dx up and back down, a lurch is one fat row between thin ones.
//
//  Unlike action.log this is a true RING: a playtest runs for minutes and the
//  interesting frames are the last ones, so old lines are overwritten instead
//  of the log going quiet once full.
//
//  Diagnostic only — compiled out with GAME_DEBUG, like the action log.

CAM_LOG_CAP  :: 2 * 1024 * 1024  // ~20k frames (~5.5 min at 60 fps)
CAM_LOG_LINE :: 256              // reserved headroom for one formatted line

Cam_Log :: struct {
    buf:     [CAM_LOG_CAP]u8,
    pos:     int,     // write cursor
    end:     int,     // bytes used before the last wrap (0 = never wrapped yet)
    last:    [2]f32,  // previous frame's camera target, for the delta columns
    started: bool,    // false until the first sample, so its deltas read as zero
}

// Record where the camera ended up this frame.  Called at the tail of
// update_camera (camera.odin) so it can never drift out of sync with the state
// it reports; game_camera is a read-only query, so this stays a pure observer.
log_camera :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    cl  := &gs.cam_log
    tgt := game_camera(gs).target

    dx, dy: f32
    if cl.started {
        dx = tgt.x - cl.last.x
        dy = tgt.y - cl.last.y
    }
    cl.last    = tgt
    cl.started = true

    dt := gs.delta_time
    vx := f32(0)
    if dt > 0 do vx = dx / dt

    // Which camera rule was driving this frame — the first thing you want to
    // know when a row looks wrong.
    flag_buf: [4]u8
    n := 0
    if gs.zoom_t < 1         { flag_buf[n] = 'Z'; n += 1 }
    if gs.zoom_cursor_active { flag_buf[n] = 'A'; n += 1 }
    if gs.cam_recentering    { flag_buf[n] = 'R'; n += 1 }
    if gs.cam_dragging       { flag_buf[n] = 'D'; n += 1 }
    flags := n == 0 ? "-" : string(flag_buf[:n])

    if cl.pos + CAM_LOG_LINE > CAM_LOG_CAP {
        cl.end = cl.pos   // remember how far the previous lap reached
        cl.pos = 0
    }
    px   := (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE
    line := fmt.bprintf(
        cl.buf[cl.pos : cl.pos + CAM_LOG_LINE - 1],
        // Tab-separated: Odin's fmt pads float widths with digits rather than
        // spaces, so fixed columns aren't available — TSV also drops straight
        // into a spreadsheet when a jerk wants graphing.
        "%d\t%.4f\t%.2f\t%+.2f\t%+.1f\t%.2f\t%+.2f\t%.3f\t%+.2f\t%+.2f\t%.2f\t%s",
        gs.frame, dt, tgt.x, dx, vx, tgt.y, dy, gs.zoom,
        gs.cam_pan.x, gs.cam_pan.y, px, flags,
    )
    cl.pos += len(line)
    cl.buf[cl.pos] = '\n'
    cl.pos += 1
}

CAM_LOG_HEADER ::
`# cam_loc.log - camera target position, one tab-separated row per simulated frame.
# Ring buffer: the newest ~20k frames (~5.5 min) survive, oldest first.
# x/y     rl.Camera2D.target in world px, AFTER the level-edge clamp - what the renderer used
# dx/dy   change since the previous row; vx = dx/dt (world px per second)
# flags   Z zoom glide  A alt cursor zoom  R gliding back to the player  D alt drag pan  - idle
frame	dt	x	dx	vx	y	dy	zoom	pan_x	pan_y	player_x	flags
`

// Write the ring out oldest-first.  Two spans: whatever survives from the
// previous lap, then this lap.  The first line of the older span is a partial
// leftover the current lap wrote over, so it's trimmed to the first newline.
flush_cam_log :: proc(gs: ^Game_State) {
    when !GAME_DEBUG { return }
    cl := &gs.cam_log
    if cl.pos == 0 && cl.end == 0 do return

    fd, err := os.open("cam_loc.log", os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if err != nil do return
    defer os.close(fd)

    os.write_string(fd, CAM_LOG_HEADER)
    if cl.end > cl.pos {
        old := cl.buf[cl.pos:cl.end]
        for b, i in old {
            if b == '\n' {
                os.write(fd, old[i+1:])
                break
            }
        }
    }
    os.write(fd, cl.buf[:cl.pos])
}
