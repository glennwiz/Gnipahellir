package game

GRAVITY        :: f32(28.0)
MOVE_SPEED     :: f32(8.0)
JUMP_VEL       :: f32(-13.0)
MAX_FALL_SPEED :: f32(25.0)
FLY_SPEED      :: f32(14.0)  // debug fly mode

PLAYER_W :: f32(0.8)   // tile units
PLAYER_H :: f32(1.8)   // tile units

update_player :: proc(gs: ^Game_State) {
    p  := &gs.player
    dt := gs.delta_time

    if p.dead do return

    inp := &gs.input

    flying := false
    when GAME_DEBUG do flying = gs.debug.fly

    if flying {
        // ── Debug fly: directional movement, no gravity, no jump ──
        p.vel = {}
        if inp.move_left  { p.vel.x = -FLY_SPEED; p.facing = -1 }
        if inp.move_right { p.vel.x =  FLY_SPEED; p.facing =  1 }
        if inp.fly_up     { p.vel.y = -FLY_SPEED }
        if inp.fly_down   { p.vel.y =  FLY_SPEED }
    } else {
        // ── Horizontal intent ─────────────────────────────────────
        p.vel.x = 0
        if inp.move_left  { p.vel.x = -MOVE_SPEED; p.facing = -1 }
        if inp.move_right { p.vel.x =  MOVE_SPEED; p.facing =  1 }

        // ── Jump ──────────────────────────────────────────────────
        if inp.jump && p.grounded {
            p.vel.y    = JUMP_VEL
            p.grounded = false
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Jump)}})
        }
    }

    // ── AABB movement + collision (gravity applied inside) ───────
    prev_center := player_tile(p)

    move_body(&gs.world, &p.pos, &p.vel, {PLAYER_W, PLAYER_H}, dt,
        flying ? 0 : GRAVITY, MAX_FALL_SPEED, &p.grounded)

    entity_map_move(&gs.world, PLAYER_ID, prev_center, player_tile(p))

    // ── Fell through the clouds: back to the surface ─────────────
    if gs.level_index == LEVEL_SKY && p.pos.y > SKY_FALL_Y && !flying {
        level_transition(gs, &level_portals[LEVEL_SKY][0])
        return
    }

    // ── Item pickup (walk over drops) ─────────────────────────────
    player_pickup(gs)

    // ── Interact: portals, sky altar ──────────────────────────────
    if inp.interact do player_interact(gs)

    // ── Mana regen ────────────────────────────────────────────────
    p.mana = min(p.mana + p.mana_regen * dt, p.mana_max)

    // ── Mining ────────────────────────────────────────────────────
    if inp.mine {
        tx := int(gs.input.mouse_tile.x)
        ty := int(gs.input.mouse_tile.y)
        pcx := int(p.pos.x + PLAYER_W * 0.5)
        pcy := int(p.pos.y + PLAYER_H * 0.5)
        if in_bounds(tx, ty) &&
           abs(tx - pcx) <= PLAYER_REACH && abs(ty - pcy) <= PLAYER_REACH {
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

// Collect any world drops overlapped by the player's bounding box.
player_pickup :: proc(gs: ^Game_State) {
    p := &gs.player
    left  := int(p.pos.x)
    right := int(p.pos.x + PLAYER_W - 0.001)
    top   := int(p.pos.y)
    bot   := int(p.pos.y + PLAYER_H - 0.001)

    for ty in top ..= bot {
        for tx in left ..= right {
            if !in_bounds(tx, ty) do continue
            idx := grid_idx(tx, ty)
            it  := gs.world.items[idx]
            cnt := int(gs.world.item_counts[idx])
            if it == .None || cnt == 0 do continue
            if !inventory_insert(&p.inventory, it, cnt) do continue

            gs.world.items[idx]       = .None
            gs.world.item_counts[idx] = 0
            eq_push(&gs.events, Event{
                type    = .Item_Pickup,
                tile    = {i32(tx), i32(ty)},
                payload = {int_val = i32(it)},
            })
        }
    }
}

// Movement/collision resolution lives in physics.odin (move_body), shared
// with enemies.
