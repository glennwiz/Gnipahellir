package game

import "core:math"
import rl "vendor:raylib"

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

// The view's bottom edge may overshoot the world by two tiles of black void:
// the hotbar covers the lowest rows of the screen, so a player standing on
// the level floor needs the deepest layers lifted clear of it.  The clamp
// engages progressively — the final tiles of a descent slide the view into
// the pad, no snap.  Y-axis only; every Y clamp site passes it.
CAM_BOTTOM_PAD :: f32(2 * CELL_SIZE)

// A wheel notch glides to its new zoom over this many seconds, smoothstepped in
// 1/zoom (view half-width) space — see update_camera for why that matters: the
// edge clamp is linear in half-width, so easing there is what stops the camera
// lurching sideways when the clamp lets go on the first notch.
ZOOM_TIME :: f32(0.35)
// Once the player moves, an ALT-shifted view returns to the normal
// player-centered camera over this many seconds. A fixed duration with an
// ease-in-out (not exponential decay, whose first frames move fastest and whip
// the view back from a big offset) — the glide starts gently and settles.
CAM_RECENTER_TIME :: f32(0.6)

// smoothstep — zero slope at both ends, so a glide neither snaps off its start
// nor slams into its finish.  Used by the recenter glide, which always starts
// from a standstill.
cam_ease :: proc(t: f32) -> f32 {
    return t*t*(3 - 2*t)
}

// The zoom glide's curve: smoothstep generalised to start at a chosen speed.
//
// A wheel spin lands notches faster than a glide can finish, so most of them
// retarget one already in flight — and smoothstep restarts at ZERO slope. That
// dropped the camera's speed ~5x on every notch and re-ramped it, a ~20 Hz
// stutter in the framing and in the zoom scale alike. A fixed-duration ease
// cannot be retargeted without it.
//
// c is the initial slope, normalised (see cam_glide_c). It is the unique cubic
// with p(0)=0, p(1)=1, p'(0)=c, p'(1)=0 — so it still lands exactly on target
// with zero speed, and c=0 is smoothstep unchanged. Monotone for c in 0..3,
// which is what cam_glide_c clamps to.
cam_ease_from :: proc(t, c: f32) -> f32 {
    return ((c - 2)*t + (3 - 2*c))*t*t + c*t
}

// Normalised initial slope for cam_ease_from: the speed a glide already carries,
// expressed against the distance it now has to cover in ZOOM_TIME. Zero when
// there is nothing to cover, or when the motion is heading AWAY from the new
// target (a direction reversal genuinely has to stop and turn around).
cam_glide_c :: proc(vel, dist: f32) -> f32 {
    if dist == 0 do return 0
    return clamp(vel * ZOOM_TIME / dist, 0, 3)
}

// Where the camera comes to rest on one axis at a given zoom: the point it
// tracks, pulled back inside the level edges (plus any bottom pad on Y).
cam_rest_axis :: proc(p, span, zoom: f32, pad := f32(0)) -> f32 {
    half := span * 0.5 / max(zoom, ZOOM_MIN)
    return clamp(p, half, span + pad - half)
}

// The points the camera tracks, before the level-edge clamp: the player's exact
// float center on X, the deadzoned anchor on Y, each shifted by any ALT pan.
cam_track_x :: proc(gs: ^Game_State) -> f32 {
    return (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE + gs.cam_pan.x
}
cam_track_y :: proc(gs: ^Game_State) -> f32 {
    return gs.cam_y + gs.cam_pan.y
}

// One axis of the camera target, mid-notch included.
//
// Easing zoom alone is not enough to make the framing glide, because the edge
// clamp SATURATES: with the player at 934 px the clamp lets go at zoom 1.0278,
// so a 1.00→1.15 notch does all its horizontal travel in the first third of the
// glide — at which point smoothstep is at its fastest — and then stops dead.
// That truncation is the sideways jerk, in both axes.
//
// So ease the framing itself, from where the view is to where this notch will
// rest. The curve's zero end-slope then lands where the motion really ends, and
// an axis with no travel to do (player away from the edge) stays perfectly
// still. Both ends are relative to the live p, so walking mid-glide still
// tracks. from_off is captured by camera_begin_zoom_glide, NOT re-derived from
// the live zoom — see there.
cam_glide_axis :: proc(gs: ^Game_State, p, span, from_off, c: f32, pad := f32(0)) -> f32 {
    if gs.zoom_t >= 1 do return cam_rest_axis(p, span, gs.zoom, pad)
    from := p + from_off
    to   := cam_rest_axis(p, span, gs.zoom_target, pad)
    v    := from + (to - from) * cam_ease_from(gs.zoom_t, c)
    // Zooming OUT narrows the visible window, so a framing that was legal when
    // the notch started can fall outside it; hold it inside the level edges.
    // (Zooming in only widens the window, so this is a no-op there.)
    half := span * 0.5 / max(gs.zoom, ZOOM_MIN)
    return clamp(v, half, span + pad - half)
}

// Player-centered camera, plus the temporary offset made by an ALT cursor zoom.
// Clamped so we never show past the level edges. At zoom 1.0 the clamp pins it
// to level-center → the whole level, as before. A plain wheel notch changes zoom
// only, so the view stays on the player unless ALT deliberately pulls it away.
// Shared by render and input so both agree on the world↔screen mapping.
game_camera :: proc(gs: ^Game_State) -> rl.Camera2D {
    zoom := max(gs.zoom, ZOOM_MIN)
    px   := cam_track_x(gs)
    py   := cam_track_y(gs)
    return rl.Camera2D{
        target   = {cam_glide_axis(gs, px, f32(SCREEN_W), gs.cam_glide_from.x, gs.cam_ease_c.x),
                    cam_glide_axis(gs, py, f32(SCREEN_H), gs.cam_glide_from.y, gs.cam_ease_c.y, CAM_BOTTOM_PAD)},
        offset   = {f32(SCREEN_W)*0.5, f32(SCREEN_H)*0.5},
        rotation = 0,
        zoom     = zoom,
    }
}

// Begin (or restart) a wheel notch's glide. gs.zoom_target must already hold the
// new zoom; from_target is the camera target as it was under the OLD glide,
// sampled before that write.
//
// Two things make a mid-spin retarget continuous, and both were wrong before:
//
//   · POSITION. The framing origin is the offset of the LIVE camera target from
//     the tracked point, never re-derived from the live zoom. A notch would
//     otherwise restart the framing from where the live zoom says the camera
//     ought to REST — which is not where it is, because the edge clamp
//     saturates early in a notch and its resting point runs ahead of the eased
//     framing. Closing that gap threw the view up to 7 px sideways in one
//     frame, worse than the lurch this glide exists to remove.
//   · SPEED. Each quantity keeps the pace it already had, via cam_ease_from.
//     Restarting smoothstep at zero slope made every notch brake and re-launch.
camera_begin_zoom_glide :: proc(gs: ^Game_State, from_target: [2]f32) {
    px, py := cam_track_x(gs), cam_track_y(gs)
    gs.cam_glide_from = {from_target.x - px, from_target.y - py}
    gs.cam_ease_c = {
        cam_glide_c(gs.cam_glide_vel.x, cam_rest_axis(px, f32(SCREEN_W), gs.zoom_target) - from_target.x),
        cam_glide_c(gs.cam_glide_vel.y, cam_rest_axis(py, f32(SCREEN_H), gs.zoom_target, CAM_BOTTOM_PAD) - from_target.y),
    }
    // The zoom itself glides in 1/zoom space (see update_camera), so its carried
    // speed is measured there too.
    gs.zoom_ease_c = cam_glide_c(gs.zoom_inv_vel, 1/gs.zoom_target - 1/max(gs.zoom, ZOOM_MIN))
    gs.zoom_from   = gs.zoom
    gs.zoom_t      = 0
}

// The camera Y anchor: snap it straight to the player (level entry, spawn,
// teleport) so the view doesn't slide across the cut.
camera_snap_y :: proc(gs: ^Game_State) {
    gs.cam_y = (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    gs.cam_pan = {}
    // A cut, not a slide: any in-flight glide restarts centred and at a
    // standstill here, so no motion carries across the seam.
    gs.cam_glide_from = {}
    gs.cam_glide_vel  = {}
    gs.cam_ease_c     = {}
    gs.zoom_inv_vel   = 0
    gs.zoom_ease_c    = 0
    gs.zoom_cursor_active = false
    gs.cam_recentering = false
    gs.cam_dragging = false
    gs.cam_follow_kind = .None
    gs.player_step_visual_y = 0
}

// A followed body is watched through the SAME vertical deadzone the player gets
// (CAM_DEADZONE_Y): its jumps and hops arc inside the band, so the view holds
// perfectly still for them.  The anchor is then low-passed at this rate (1/s) on
// the way out of the band.  A bare deadzone goes from still to the body's full
// climb speed the instant the band is crossed — that jump in velocity is the
// jerk a pillaring worker made, once per hop.  Because the error is exactly zero
// at the crossing, the filter ramps the view into the motion from a standstill
// and settles about a sixth of a second behind a steady climb.
CAM_FOLLOW_Y_RATE :: f32(6)

// ─── Following a body ─────────────────────────────────────────────────────────
// ALT+click on a worker or a builder hands the camera to it. The follow is
// expressed as cam_pan — the same offset the ALT zoom and the ALT drag produce —
// rather than as a second tracked point, so every rule downstream comes along
// unchanged: the level-edge clamp, the zoom glide (which is why zooming keeps the
// body framed instead of snapping back to the hero), and the smoothstep home.

// World-pixel center of the followed body, or ok=false once it is gone — killed,
// despawned, recalled, or left behind on another level.
camera_follow_point :: proc(gs: ^Game_State) -> (pt: [2]f32, ok: bool) {
    switch gs.cam_follow_kind {
    case .None:
    case .Enemy:
        if gs.cam_follow_id < 0 || gs.cam_follow_id >= MAX_ENEMIES do return
        if !gs.enemies.active[gs.cam_follow_id] do return
        e    := &gs.enemies.data[gs.cam_follow_id]
        size := enemy_body_size(e.kind)
        return {(e.pos.x + size.x*0.5) * CELL_SIZE, (e.pos.y + size.y*0.5) * CELL_SIZE}, true
    case .Golem:
        if gs.cam_follow_id < 0 || gs.cam_follow_id >= MAX_GOLEMS do return
        g := &gs.golems.data[gs.cam_follow_id]
        if g.status != .Deployed || g.level != gs.level_index do return
        c := golem_center(g)
        return {c.x * CELL_SIZE, c.y * CELL_SIZE}, true
    }
    return
}

camera_follow_entity :: proc(gs: ^Game_State, kind: Cam_Follow, id: int) {
    gs.cam_follow_kind    = kind
    gs.cam_follow_id      = id
    gs.zoom_cursor_active = false
    gs.cam_recentering    = false
    // Start the Y anchor on the body, or the deadzone would begin off-centre and
    // the filter would drift up to it for no reason.
    if pt, ok := camera_follow_point(gs); ok do gs.cam_follow_y = pt.y
}

// Hand the camera back to the player. The view is left exactly where the follow
// had it and returns under the usual rule — gliding home the next time the player
// moves — so letting go never yanks the framing by itself.
camera_stop_follow :: proc(gs: ^Game_State) {
    gs.cam_follow_kind = .None
}

// Advance the Y anchor with a vertical deadzone: it only moves when the player
// leaves the band, so a jump (arc inside the band) leaves the view still, while
// falling or climbing past the band drags it along.  Run each frame after the
// player moves.  At zoom 1.0 game_camera clamps Y to level-center anyway, so
// this is only felt when zoomed in.
update_camera :: proc(gs: ^Game_State) {
    // Sampled before anything moves, so the pace this frame ends up carrying can
    // be handed to the next wheel notch (camera_begin_zoom_glide).
    was_target := game_camera(gs).target
    was_inv    := 1 / max(gs.zoom, ZOOM_MIN)

    py := (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    if py < gs.cam_y - CAM_DEADZONE_Y do gs.cam_y = py + CAM_DEADZONE_Y
    if py > gs.cam_y + CAM_DEADZONE_Y do gs.cam_y = py - CAM_DEADZONE_Y

    // Glide the live zoom to the wheel-set target: smoothstep over a fixed time
    // (not exponential decay, whose first frames are its fastest), interpolating
    // 1/zoom — the view half-width — rather than the zoom factor, so the scale
    // and the edge clamp advance in step. The framing itself is eased by
    // cam_glide_axis on the same curve; see there for why zoom easing alone
    // still leaves a sideways jerk.
    next_zoom := gs.zoom
    if gs.zoom_t < 1 {
        gs.zoom_t += gs.delta_time / ZOOM_TIME
        if gs.zoom_t >= 1 {
            gs.zoom_t = 1
            next_zoom = gs.zoom_target
        } else {
            k := cam_ease_from(gs.zoom_t, gs.zoom_ease_c)
            next_zoom = 1 / (1/gs.zoom_from + (1/gs.zoom_target - 1/gs.zoom_from)*k)
        }
    }

    // A followed body owns the pan while it lives, recomputed every frame so its
    // own walking, the player's, and any zoom in flight all keep it framed.
    following := gs.cam_follow_kind != .None
    if following {
        if pt, ok := camera_follow_point(gs); ok {
            // X rides the body exactly (a walk is already smooth). Y goes through
            // the deadzone — stated as a clamp, which is the same rule the player
            // anchor uses: it does not move at all while the body is inside the
            // band — and is then eased toward the band edge, so leaving the band
            // ramps the view in rather than snapping to the body's full speed.
            base_x := (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE
            want   := clamp(gs.cam_follow_y, pt.y - CAM_DEADZONE_Y, pt.y + CAM_DEADZONE_Y)
            gs.cam_follow_y += (want - gs.cam_follow_y) *
                               (1 - math.exp(-CAM_FOLLOW_Y_RATE * gs.delta_time))
            gs.cam_pan = {pt.x - base_x, gs.cam_follow_y - gs.cam_y}
            gs.zoom_cursor_active = false
            gs.cam_recentering    = false
            // Moving is the player's standing "take me home" order — the same
            // rule an ALT pan obeys — so walking releases the follow and the
            // branch below glides back from wherever the body had led the view.
            if abs(gs.player.vel.x) > 0.05 || abs(gs.player.vel.y) > 0.05 {
                camera_stop_follow(gs)
                following = false
            }
        } else {
            camera_stop_follow(gs)
            following = false
        }
    }

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
    } else if !following {
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
                gs.cam_pan = gs.cam_pan_from * (1 - cam_ease(gs.cam_recenter_t))
            }
        }
    }
    gs.zoom = next_zoom

    if gs.delta_time > 0 {
        gs.cam_glide_vel = (game_camera(gs).target - was_target) / gs.delta_time
        gs.zoom_inv_vel  = (1/max(gs.zoom, ZOOM_MIN) - was_inv) / gs.delta_time
    }
    log_camera(gs)  // diagnostic: one cam_loc.log row per frame (cam_log.odin)
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
        clamp(pan.y, half_h - gs.cam_y, f32(SCREEN_H) + CAM_BOTTOM_PAD - half_h - gs.cam_y),
    }
    gs.zoom_cursor_active = false
    gs.cam_recentering    = false
    gs.cam_follow_kind    = .None  // grabbing the view by hand takes it off a followed body
}

camera_begin_recenter :: proc(gs: ^Game_State) {
    if gs.cam_pan.x == 0 && gs.cam_pan.y == 0 do return
    gs.cam_pan_from    = gs.cam_pan
    gs.cam_recenter_t  = 0
    gs.cam_recentering = true
}
