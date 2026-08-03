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
// through it (Glenn's design: no open/close, just permeable to the player and a
// wall to enemies).  move_body's `pass_doors` selects which side of that a body
// is on.  Everything else — anchoring, falling blocks, placement — reads plain
// is_solid, so a door is always a stable anchor like rock.
@(private = "file")
blocks_body :: proc(w: ^World_Grid, x, y: int, pass_doors: bool) -> bool {
    if pass_doors && is_door(w, x, y) do return false
    return is_solid(w, x, y)
}

// True if a body of `size` at `pos` would overlap any tile that blocks it.
// Used by the step-up probe: lift the body a tile and ask whether the raised
// position is clear (obstacle cleared AND headroom above).
@(private = "file")
body_blocked :: proc(w: ^World_Grid, pos, size: [2]f32, pass_doors: bool) -> bool {
    left  := int(pos.x + BODY_MARGIN)
    right := int(pos.x + size.x - BODY_MARGIN)
    top   := int(pos.y + BODY_MARGIN)
    bot   := int(pos.y + size.y - BODY_MARGIN)
    for y in top ..= bot {
        for x in left ..= right {
            if blocks_body(w, x, y, pass_doors) do return true
        }
    }
    return false
}

// Integrates gravity (0 = none, e.g. debug fly mode) and moves the body,
// resolving against solid tiles.  `grounded` is written only when the body
// moves vertically: true on landing, false while airborne.  `pass_doors` lets
// the player phase through door tiles (enemies leave it false — doors wall them).
move_body :: proc(w: ^World_Grid, pos, vel: ^[2]f32, size: [2]f32,
                  dt, gravity, max_fall: f32, grounded: ^bool, pass_doors := false,
                  step_up := false) {
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
                         dest_x: f32, pass_doors, can_step: bool) -> bool {
            if !can_step do return false
            step_y := pos.y - STEP_HEIGHT
            if body_blocked(w, {dest_x, step_y}, size, pass_doors) do return false
            pos.y = step_y
            return true
        }

        if dx > 0 {
            sweep_r: for c in int(pos.x + size.x - BODY_MARGIN) + 1 ..= int(new_x + size.x - BODY_MARGIN) {
                for r in top ..= bot {
                    if blocks_body(w, c, r, pass_doors) {
                        if !try_step(w, pos, size, pos.x + dx, pass_doors, can_step) {
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
                    if blocks_body(w, c, r, pass_doors) {
                        if !try_step(w, pos, size, pos.x + dx, pass_doors, can_step) {
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
                    if blocks_body(w, c, r, pass_doors) {
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
                    if blocks_body(w, c, r, pass_doors) {
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
