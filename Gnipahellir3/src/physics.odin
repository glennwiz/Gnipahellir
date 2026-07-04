package game

// ─── Shared AABB Body Physics ─────────────────────────────────────────────────
//
//  One collision resolver for every moving body (player, builders, later
//  Garm).  Axis-separated: X resolves first, then Y.  The leading edge is
//  swept over every tile column/row it crosses this frame, so a fast body
//  (dt is capped at 50 ms, where max fall speed crosses more than one tile)
//  cannot tunnel through a one-tile wall.
//
//  On contact the body snaps to the tile boundary backed off by BODY_EPS so
//  the next frame's leading-edge check re-detects the same wall.  Without
//  the back-off, `grounded` flickers while standing: the first post-snap
//  frame's fall distance is too small to re-cross the boundary.  The
//  back-off must stay well under one frame's minimum gravity step
//  (gravity * dt^2 at 60 fps) or the flicker returns.

BODY_EPS :: f32(0.001)

// Integrates gravity (0 = none, e.g. debug fly mode) and moves the body,
// resolving against solid tiles.  `grounded` is written only when the body
// moves vertically: true on landing, false while airborne.
move_body :: proc(w: ^World_Grid, pos, vel: ^[2]f32, size: [2]f32,
                  dt, gravity, max_fall: f32, grounded: ^bool) {
    if gravity != 0 {
        vel.y += gravity * dt
        if vel.y > max_fall do vel.y = max_fall
    }

    // ── X axis ────────────────────────────────────────────────────
    dx := vel.x * dt
    if dx != 0 {
        top   := int(pos.y)
        bot   := int(pos.y + size.y - BODY_EPS)
        new_x := pos.x + dx

        if dx > 0 {
            sweep_r: for c in int(pos.x + size.x - BODY_EPS) + 1 ..= int(new_x + size.x - BODY_EPS) {
                for r in top ..= bot {
                    if is_solid(w, c, r) {
                        new_x = f32(c) - size.x - BODY_EPS
                        vel.x = 0
                        break sweep_r
                    }
                }
            }
        } else {
            sweep_l: for c := int(pos.x + BODY_EPS) - 1; c >= int(new_x + BODY_EPS); c -= 1 {
                for r in top ..= bot {
                    if is_solid(w, c, r) {
                        new_x = f32(c + 1) + BODY_EPS
                        vel.x = 0
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
        left  := int(pos.x)
        right := int(pos.x + size.x - BODY_EPS)
        new_y := pos.y + dy

        if dy > 0 {
            grounded^ = false
            sweep_d: for r in int(pos.y + size.y - BODY_EPS) + 1 ..= int(new_y + size.y - BODY_EPS) {
                for c in left ..= right {
                    if is_solid(w, c, r) {
                        new_y = f32(r) - size.y - BODY_EPS
                        vel.y = 0
                        grounded^ = true
                        break sweep_d
                    }
                }
            }
        } else {
            grounded^ = false
            sweep_u: for r := int(pos.y + BODY_EPS) - 1; r >= int(new_y + BODY_EPS); r -= 1 {
                for c in left ..= right {
                    if is_solid(w, c, r) {
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
    left  := int(pos.x)
    right := int(pos.x + size.x - BODY_EPS)
    top   := int(pos.y)
    bot   := int(pos.y + size.y - BODY_EPS)
    for y in top ..= bot {
        for x in left ..= right {
            if is_solid(w, x, y) do return true
        }
    }
    return false
}
