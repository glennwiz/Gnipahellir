package game

import rl "vendor:raylib"
import "core:math"

// ─── Zoom Camera ──────────────────────────────────────────────────────────────
// Camera state lives on Game_State (gs.cam_y/cam_pan/zoom/...); this file owns
// every read AND write of it. game_camera is the read-only query render/input
// share; update_camera/camera_snap_y are the only procs allowed to mutate it —
// kept out of render.odin so that file stays provably read-only.

ZOOM_STEP :: f32(0.15)   // per mouse-wheel notch
ZOOM_MIN  :: f32(1.0)    // 1.0 = whole level (the level is exactly SCREEN_W×SCREEN_H)
ZOOM_MAX  :: f32(4.0)

// Vertical camera deadzone (world px): the Y anchor only moves once the player
// leaves this band around it, so a jump arc (~3 tiles) stays inside and doesn't
// bob the view.  A little wider than a full jump so the whole arc is swallowed.
CAM_DEADZONE_Y :: f32(3.5 * CELL_SIZE)

// Zoom easing rate (1/s): higher = snappier. gs.zoom chases gs.zoom_target with
// frame-rate-independent exponential decay so a wheel notch glides in ~0.1-0.2 s
// instead of popping — which also feathers the clamp-release Y pan (see below).
ZOOM_EASE :: f32(18.0)
// Once the player moves, an ALT-shifted view returns to the normal
// player-centered camera over this many seconds. A fixed duration with an
// ease-in-out (not exponential decay, whose first frames move fastest and whip
// the view back from a big offset) — the glide starts gently and settles.
CAM_RECENTER_TIME :: f32(0.6)

// Player-centered camera, plus the temporary offset made by an ALT cursor zoom.
// Clamped so we never show past the level edges. At zoom 1.0 the clamp pins it
// to level-center → the whole level, as before. A plain wheel notch changes zoom
// only, so the view stays on the player unless ALT deliberately pulls it away.
// Shared by render and input so both agree on the world↔screen mapping.
game_camera :: proc(gs: ^Game_State) -> rl.Camera2D {
    zoom   := max(gs.zoom, ZOOM_MIN)
    half_w := f32(SCREEN_W) * 0.5 / zoom
    half_h := f32(SCREEN_H) * 0.5 / zoom
    // Exact float player center — the supersampled texture + float sprite draw
    // let both glide sub-pixel, so no integer snapping is needed here.
    px := (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE + gs.cam_pan.x
    // X follows the player exactly; Y tracks the deadzoned anchor (update_camera)
    // so jumping doesn't slide the view up and down.
    py := gs.cam_y + gs.cam_pan.y
    return rl.Camera2D{
        target   = {clamp(px, half_w, f32(SCREEN_W) - half_w),
                    clamp(py, half_h, f32(SCREEN_H) - half_h)},
        offset   = {f32(SCREEN_W)*0.5, f32(SCREEN_H)*0.5},
        rotation = 0,
        zoom     = zoom,
    }
}

// The camera Y anchor: snap it straight to the player (level entry, spawn,
// teleport) so the view doesn't slide across the cut.
camera_snap_y :: proc(gs: ^Game_State) {
    gs.cam_y = (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    gs.cam_pan = {}
    gs.zoom_cursor_active = false
    gs.cam_recentering = false
    gs.cam_dragging = false
    gs.player_step_visual_y = 0
}

// Advance the Y anchor with a vertical deadzone: it only moves when the player
// leaves the band, so a jump (arc inside the band) leaves the view still, while
// falling or climbing past the band drags it along.  Run each frame after the
// player moves.  At zoom 1.0 game_camera clamps Y to level-center anyway, so
// this is only felt when zoomed in.
update_camera :: proc(gs: ^Game_State) {
    py := (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    if py < gs.cam_y - CAM_DEADZONE_Y do gs.cam_y = py + CAM_DEADZONE_Y
    if py > gs.cam_y + CAM_DEADZONE_Y do gs.cam_y = py - CAM_DEADZONE_Y

    // Ease the live zoom toward the wheel-set target. Because half_w/half_h (and
    // thus the edge clamp) are derived from zoom, gliding zoom also glides the
    // Y lurch you'd otherwise get when the clamp releases on the first notch.
    next_zoom := gs.zoom + (gs.zoom_target - gs.zoom) * (1 - math.exp(-ZOOM_EASE * gs.delta_time))
    if abs(gs.zoom_target - next_zoom) < 0.0001 do next_zoom = gs.zoom_target

    if gs.zoom_cursor_active {
        // ALT zoom: target = anchor_world - cursor displacement / zoom.
        // Recomputing this every eased frame keeps the same world pixel under
        // the pointer rather than merely aiming the final notch there.
        base_x := (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE
        gs.cam_pan = {
            gs.zoom_anchor_world.x -
                (gs.zoom_anchor_screen.x - f32(SCREEN_W)*0.5)/next_zoom - base_x,
            gs.zoom_anchor_world.y -
                (gs.zoom_anchor_screen.y - f32(SCREEN_H)*0.5)/next_zoom - gs.cam_y,
        }
        if next_zoom == gs.zoom_target do gs.zoom_cursor_active = false
        gs.cam_recentering = false
    } else {
        // Looking around should not permanently detach the view from the hero.
        // Movement is the player's implicit "take me home" camera command.
        if !gs.cam_recentering &&
           (abs(gs.player.vel.x) > 0.05 || abs(gs.player.vel.y) > 0.05) {
            camera_begin_recenter(gs)
        }
        if gs.cam_recentering {
            gs.cam_recenter_t += gs.delta_time / CAM_RECENTER_TIME
            if gs.cam_recenter_t >= 1 {
                gs.cam_pan         = {}
                gs.cam_recentering = false
            } else {
                // smoothstep: zero slope at both ends, so the glide neither
                // snaps off the inspected spot nor slams into the player.
                t := gs.cam_recenter_t
                gs.cam_pan = gs.cam_pan_from * (1 - t*t*(3 - 2*t))
            }
        }
    }
    gs.zoom = next_zoom
}

// Start the smooth glide from the current ALT offset back to the player. Also
// the plain-wheel "back to the hero" path (input.odin), so neither route snaps.
// Runs to completion once started — stopping mid-glide would stall the view
// halfway off the hero.
// ALT+drag grabs the world: the view moves with the pointer, so the spot you
// grabbed stays under it. Feeds the same cam_pan as ALT wheel zoom, so it glides
// home by the same rule once the player moves. Clamped to what game_camera can
// actually show, or dragging past a level edge would bank invisible offset you'd
// have to unwind (and at zoom 1.0, where the whole level already fits, panning
// is correctly a no-op).
camera_pan_drag :: proc(gs: ^Game_State, screen_delta: [2]f32) {
    zoom   := max(gs.zoom, ZOOM_MIN)
    half_w := f32(SCREEN_W) * 0.5 / zoom
    half_h := f32(SCREEN_H) * 0.5 / zoom
    px     := (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE
    pan    := gs.cam_pan - screen_delta/zoom
    gs.cam_pan = {
        clamp(pan.x, half_w - px,       f32(SCREEN_W) - half_w - px),
        clamp(pan.y, half_h - gs.cam_y, f32(SCREEN_H) - half_h - gs.cam_y),
    }
    gs.zoom_cursor_active = false
    gs.cam_recentering    = false
}

camera_begin_recenter :: proc(gs: ^Game_State) {
    if gs.cam_pan.x == 0 && gs.cam_pan.y == 0 do return
    gs.cam_pan_from    = gs.cam_pan
    gs.cam_recenter_t  = 0
    gs.cam_recentering = true
}
