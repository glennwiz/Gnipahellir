package game

// ─── Shared AABB Body Physics ─────────────────────────────────────────────────
//
//  One collision resolver for every moving body (player, builders, later
//  Garm).  Axis-separated: X resolves first, then Y.  The leading edge is
//  swept over every tile column/row it crosses this frame, so a fast body
//  (dt is capped at 50 ms, where max fall speed crosses more than one tile)
//  cannot tunnel through a one-tile wall.
//
//  Two constants govern the tile math, and their ordering is load-bearing:
//
//  BODY_EPS — on contact the body snaps to the tile boundary backed off by
//  this much, so float equality never decides which tile the edge is in.
//
//  BODY_MARGIN — the collision box is shrunk by this much on ALL sides
//  before mapping to tile coordinates.  It must be strictly larger than
//  BODY_EPS (plus f32 noise): a body resting at back-off overlaps the
//  neighbouring row/column by BODY_EPS, and without the margin that
//  overlap makes a 1-tile body collide as if it were 2 tiles tall —
//  builders then freeze against every 1-high step (the exact bug this
//  margin fixes).  It must also stay well below one frame's minimum
//  gravity step (gravity * dt^2: ~0.0056 for builders at 60 fps), or
//  standing bodies stop re-detecting the floor and `grounded` flickers.

BODY_EPS    :: f32(0.001)
BODY_MARGIN :: f32(0.003)

// Auto step-up: a grounded body whose horizontal move is blocked will try to
// climb a step this tall (in tiles) rather than stop — walk up a single block
// without jumping.  Opt-in per body via move_body's `step_up` (player only).
STEP_HEIGHT :: f32(1.0)

// A door is solid rock to every body EXCEPT the player, who always walks
// through it in every direction (Glenn's design: no open/close, just a
// passageway).  A structure — machines/stations/spawners/altars
// (is_structure_tile) or a rune scroll chest (is_rune_scroll_chest) — is similar
// but only sideways: the player walks through its sides, yet still lands and
// stands on its top like solid ground.  Raw material tiles (Stone/Dirt/Grass/
// ore/Clay/...) are NOT included here on purpose — those stay solid to the
// player from every side, only built/placed fixtures are walk-through.
// `horizontal` distinguishes the two axes (true for the X sweep and the
// step-up probe, false for the Y sweep) so only sideways movement waives it.
// Everything else — anchoring, falling blocks, placement — reads plain
// is_solid, so a door or structure is always a stable anchor like rock.
@(private = "file")
blocks_body :: proc(w: ^World_Grid, x, y: int, is_player, horizontal: bool) -> bool {
    if is_player do return tile_blocks_player(get_tile(w, x, y), horizontal)
    return is_solid(w, x, y)
}

tile_blocks_player :: proc(t: Tile_Type, horizontal: bool) -> bool {
    if t == .Door do return false
    if horizontal && (is_structure_tile[t] || is_rune_scroll_chest(t)) do return false
    return .Solid in terrain_table[t].flags
}

// True if a body of `size` at `pos` would overlap any tile that blocks it.
// Used by the step-up probe: lift the body a tile and ask whether the raised
// position is clear (obstacle cleared AND headroom above). Only ever called
// while resolving horizontal movement, so structures waive like the X sweep.
@(private = "file")
body_blocked :: proc(w: ^World_Grid, pos, size: [2]f32, is_player: bool) -> bool {
    left  := int(pos.x + BODY_MARGIN)
    right := int(pos.x + size.x - BODY_MARGIN)
    top   := int(pos.y + BODY_MARGIN)
    bot   := int(pos.y + size.y - BODY_MARGIN)
    for y in top ..= bot {
        for x in left ..= right {
            if blocks_body(w, x, y, is_player, true) do return true
        }
    }
    return false
}

// Steering toward a point dx away on x, for every body that walks, swims or
// flies at one (card 191): the side to go, or 0 inside the slack.  A body that
// goes at a point with no slack, or one narrower than half its tick's step,
// overshoots it each tick and turns back the next, its facing flipping many
// times a second.  A facing set from it never turns on a correction smaller
// than the slack.
steer_dir :: proc(dx, slack: f32) -> int {
    if abs(dx) <= slack do return 0
    return 1 if dx > 0 else -1
}

// The same as a walk speed: full speed toward the point, the last tick's step
// cut to what is left of the way, so it settles at any dt and any slack.
steer_vel :: proc(dx, slack, speed, dt: f32) -> (vel: f32, dir: int) {
    dir = steer_dir(dx, slack)
    return f32(dir) * min(speed, abs(dx) / dt), dir
}

// The same for a body whose key moves it a whole stride a tick, with no
// speed between (the hero): a side only when the stride leaves it nearer the
// point than it is, so it never steps past and back, however fast it walks.
steer_key :: proc(dx, slack, stride: f32) -> int {
    return steer_dir(dx, max(slack, stride * 0.5))
}

// Integrates gravity (0 = none, e.g. debug fly mode) and moves the body,
// resolving against solid tiles.  `grounded` is written only when the body
// moves vertically: true on landing, false while airborne.  `is_player` lets
// the player phase through door/structure tiles (enemies leave it false —
// doors and structures wall them).
move_body :: proc(w: ^World_Grid, pos, vel: ^[2]f32, size: [2]f32,
                  dt, gravity, max_fall: f32, grounded: ^bool, is_player := false,
                  step_up := false, slip := f32(0)) {
    // Step-up is only for a grounded, gravity-bound body (never in fly mode).
    // `grounded^` still holds last frame's value here — the Y sweep is what
    // rewrites it, and that runs after X.
    can_step := step_up && grounded^ && gravity != 0

    if gravity != 0 {
        vel.y += gravity * dt
        if vel.y > max_fall do vel.y = max_fall
    }

    // ── X axis ────────────────────────────────────────────────────
    dx := vel.x * dt
    if dx != 0 {
        top   := int(pos.y + BODY_MARGIN)
        bot   := int(pos.y + size.y - BODY_MARGIN)
        new_x := pos.x + dx

        // Raising the body one step and finding the intended destination clear
        // means the obstacle is a single block with headroom above: climb it.
        try_step :: proc(w: ^World_Grid, pos: ^[2]f32, size: [2]f32,
                         dest_x: f32, is_player, can_step: bool) -> bool {
            if !can_step do return false
            step_y := pos.y - STEP_HEIGHT
            if body_blocked(w, {dest_x, step_y}, size, is_player) do return false
            pos.y = step_y
            return true
        }

        if dx > 0 {
            sweep_r: for c in int(pos.x + size.x - BODY_MARGIN) + 1 ..= int(new_x + size.x - BODY_MARGIN) {
                for r in top ..= bot {
                    if blocks_body(w, c, r, is_player, true) {
                        if !try_step(w, pos, size, pos.x + dx, is_player, can_step) {
                            new_x = f32(c) - size.x - BODY_EPS
                            vel.x = 0
                        }
                        break sweep_r
                    }
                }
            }
        } else {
            sweep_l: for c := int(pos.x + BODY_MARGIN) - 1; c >= int(new_x + BODY_MARGIN); c -= 1 {
                for r in top ..= bot {
                    if blocks_body(w, c, r, is_player, true) {
                        if !try_step(w, pos, size, pos.x + dx, is_player, can_step) {
                            new_x = f32(c + 1) + BODY_EPS
                            vel.x = 0
                        }
                        break sweep_l
                    }
                }
            }
        }
        pos.x = new_x
    }

    // ── Y axis ────────────────────────────────────────────────────
    dy := vel.y * dt
    if dy != 0 {
        left  := int(pos.x + BODY_MARGIN)
        right := int(pos.x + size.x - BODY_MARGIN)
        new_y := pos.y + dy

        if dy > 0 {
            grounded^ = false
            sweep_d: for r in int(pos.y + size.y - BODY_MARGIN) + 1 ..= int(new_y + size.y - BODY_MARGIN) {
                for c in left ..= right {
                    if blocks_body(w, c, r, is_player, false) {
                        if slip_off_lip(w, pos, size, r, slip, is_player) {
                            left  = int(pos.x + BODY_MARGIN)
                            right = int(pos.x + size.x - BODY_MARGIN)
                            continue sweep_d
                        }
                        new_y = f32(r) - size.y - BODY_EPS
                        vel.y = 0
                        grounded^ = true
                        break sweep_d
                    }
                }
            }
        } else {
            grounded^ = false
            sweep_u: for r := int(pos.y + BODY_MARGIN) - 1; r >= int(new_y + BODY_MARGIN); r -= 1 {
                for c in left ..= right {
                    if blocks_body(w, c, r, is_player, false) {
                        new_y = f32(r + 1) + BODY_EPS
                        vel.y = 0
                        break sweep_u
                    }
                }
            }
        }
        pos.y = new_y
    }

    // World border clamp.  int() truncates toward zero, so a slightly
    // negative coordinate maps to tile 0 and the solid out-of-bounds check
    // in the sweeps never fires — the clamp is the real border.
    pos.x = clamp(pos.x, BODY_EPS, f32(GRID_W) - size.x - BODY_EPS)
    pos.y = clamp(pos.y, BODY_EPS, f32(GRID_H) - size.y - BODY_EPS)
}

// A body falling onto row r with no more than slip of its width on a lip and
// the rest over an opening one tile wide moves off the lip into it (card 196):
// false when it lands as it would have.  At a wider opening a lip is a stair
// step or a ledge's edge, and the body stands on it.  A key moves the hero a whole stride, and steer_key
// stops it up to half a stride off a point, wider with Speed gear than the
// room a shaft one wide leaves; the hero's go slips that half stride.
@(private = "file")
slip_off_lip :: proc(w: ^World_Grid, pos: ^[2]f32, size: [2]f32, r: int, slip: f32, is_player: bool) -> bool {
    left  := int(pos.x + BODY_MARGIN)
    right := int(pos.x + size.x - BODY_MARGIN)
    lip_l := blocks_body(w, left, r, is_player, false)
    if lip_l == blocks_body(w, right, r, is_player, false) do return false
    if lip_l {
        if f32(right) - pos.x > slip || !blocks_body(w, right + 1, r, is_player, false) do return false
        pos.x = f32(right) + BODY_EPS
    } else {
        if pos.x + size.x - f32(right) > slip || !blocks_body(w, left - 1, r, is_player, false) do return false
        pos.x = f32(right) - size.x - BODY_EPS
    }
    return true
}

// True when the body overlaps any solid tile — wedged or entombed states
// (e.g. a builder walled in by another builder), which the movement sweeps
// by design never produce but world edits under the body can.
body_embedded :: proc(w: ^World_Grid, pos: [2]f32, size: [2]f32) -> bool {
    left  := int(pos.x + BODY_MARGIN)
    right := int(pos.x + size.x - BODY_MARGIN)
    top   := int(pos.y + BODY_MARGIN)
    bot   := int(pos.y + size.y - BODY_MARGIN)
    for y in top ..= bot {
        for x in left ..= right {
            if is_solid(w, x, y) do return true
        }
    }
    return false
}
