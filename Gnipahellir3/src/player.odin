package game

GRAVITY        :: f32(28.0)
MOVE_SPEED     :: f32(8.0)
JUMP_VEL       :: f32(-13.0)
MAX_FALL_SPEED :: f32(25.0)

PLAYER_W :: f32(0.8)   // tile units
PLAYER_H :: f32(1.8)   // tile units

update_player :: proc(gs: ^Game_State) {
    p  := &gs.player
    dt := gs.delta_time

    if p.dead do return

    inp := &gs.input

    // ── Horizontal intent ─────────────────────────────────────────
    p.vel.x = 0
    if inp.move_left  { p.vel.x = -MOVE_SPEED; p.facing = -1 }
    if inp.move_right { p.vel.x =  MOVE_SPEED; p.facing =  1 }

    // ── Jump ──────────────────────────────────────────────────────
    if inp.jump && p.grounded {
        p.vel.y    = JUMP_VEL
        p.grounded = false
    }

    // ── Gravity ───────────────────────────────────────────────────
    p.vel.y += GRAVITY * dt
    if p.vel.y > MAX_FALL_SPEED do p.vel.y = MAX_FALL_SPEED

    // ── AABB movement + collision ─────────────────────────────────
    prev_center := [2]int{
        int(p.pos.x + PLAYER_W * 0.5),
        int(p.pos.y + PLAYER_H * 0.5),
    }

    player_move_x(gs, dt)
    player_move_y(gs, dt)

    // Update entity_map (gameplay one-entity-per-tile tracking)
    new_center := [2]int{
        int(p.pos.x + PLAYER_W * 0.5),
        int(p.pos.y + PLAYER_H * 0.5),
    }
    if in_bounds(prev_center.x, prev_center.y) {
        idx := grid_idx(prev_center.x, prev_center.y)
        if gs.world.entity_map[idx] == PLAYER_ID {
            gs.world.entity_map[idx] = INVALID_ENTITY
        }
    }
    if in_bounds(new_center.x, new_center.y) {
        gs.world.entity_map[grid_idx(new_center.x, new_center.y)] = PLAYER_ID
    }

    // ── Mana regen ────────────────────────────────────────────────
    p.mana = min(p.mana + p.mana_regen * dt, p.mana_max)

    // ── Mining ────────────────────────────────────────────────────
    if inp.mine {
        tx := int(gs.input.mouse_tile.x)
        ty := int(gs.input.mouse_tile.y)
        if in_bounds(tx, ty) {
            t := get_tile(&gs.world, tx, ty)
            if .Mineable in terrain_table[t].flags {
                eq_push(&gs.events, Event{
                    type   = .Tile_Mined,
                    source = PLAYER_ID,
                    tile   = {i32(tx), i32(ty)},
                })
            }
        }
    }

    // ── Walk animation ───────────────────────────────────────────
    if p.vel.x != 0 && p.grounded {
        p.anim_timer += dt
        if p.anim_timer >= p.walk_anim_period {
            p.anim_timer  = 0
            p.anim_frame  = (p.anim_frame + 1) % 2
        }
    } else {
        p.anim_frame = 0
        p.anim_timer = 0
    }
}

// Move horizontally, resolve against solid tiles.
// Checks the full height of the player's bounding box on the leading edge.
player_move_x :: proc(gs: ^Game_State, dt: f32) {
    p := &gs.player
    w := &gs.world
    dx := p.vel.x * dt

    if dx == 0 do return

    new_x := p.pos.x + dx

    if dx > 0 {
        // Check right edge: column at floor(new_x + PLAYER_W)
        right_tile_x := int(new_x + PLAYER_W)
        top_tile_y   := int(p.pos.y)
        bot_tile_y   := int(p.pos.y + PLAYER_H - 0.001)
        for ty := top_tile_y; ty <= bot_tile_y; ty += 1 {
            if is_solid(w, right_tile_x, ty) {
                new_x    = f32(right_tile_x) - PLAYER_W - 0.001
                p.vel.x  = 0
                break
            }
        }
    } else {
        // Check left edge: column at floor(new_x)
        left_tile_x := int(new_x)
        top_tile_y  := int(p.pos.y)
        bot_tile_y  := int(p.pos.y + PLAYER_H - 0.001)
        for ty := top_tile_y; ty <= bot_tile_y; ty += 1 {
            if is_solid(w, left_tile_x, ty) {
                new_x   = f32(left_tile_x + 1) + 0.001
                p.vel.x = 0
                break
            }
        }
    }

    p.pos.x = clamp(new_x, 0, f32(GRID_W) - PLAYER_W - 0.001)
}

// Move vertically, resolve against solid tiles.
// Checks the full width of the player's bounding box on the leading edge.
player_move_y :: proc(gs: ^Game_State, dt: f32) {
    p := &gs.player
    w := &gs.world
    dy := p.vel.y * dt

    if dy == 0 do return

    new_y := p.pos.y + dy

    if dy > 0 {
        // Check bottom edge: row at floor(new_y + PLAYER_H)
        bot_tile_y  := int(new_y + PLAYER_H)
        left_tile_x := int(p.pos.x)
        right_tile_x := int(p.pos.x + PLAYER_W - 0.001)
        p.grounded = false
        for tx := left_tile_x; tx <= right_tile_x; tx += 1 {
            if is_solid(w, tx, bot_tile_y) {
                new_y      = f32(bot_tile_y) - PLAYER_H - 0.001
                p.vel.y    = 0
                p.grounded = true
                break
            }
        }
    } else {
        // Check top edge: row at floor(new_y)
        top_tile_y   := int(new_y)
        left_tile_x  := int(p.pos.x)
        right_tile_x := int(p.pos.x + PLAYER_W - 0.001)
        for tx := left_tile_x; tx <= right_tile_x; tx += 1 {
            if is_solid(w, tx, top_tile_y) {
                new_y   = f32(top_tile_y + 1) + 0.001
                p.vel.y = 0
                break
            }
        }
    }

    p.pos.y = clamp(new_y, 0, f32(GRID_H) - PLAYER_H - 0.001)
}
