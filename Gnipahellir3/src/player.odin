package game

GRAVITY        :: f32(28.0)
MOVE_SPEED     :: f32(8.0)
JUMP_VEL       :: f32(-13.0)
MAX_FALL_SPEED :: f32(25.0)
FLY_SPEED      :: f32(14.0)  // debug fly mode

PLAYER_W :: f32(0.8)   // tile units
PLAYER_H :: f32(1.8)   // tile units

// Melee.  Damage comes from the Attack stat (equipped weapon); the sword's
// bonus in item_stat_bonus is SWORD_DAMAGE, keeping the old pace:
// builder hp 6 -> three swings.
MELEE_REACH    :: i32(2)     // chebyshev tiles from player center
SWORD_DAMAGE   :: 2
SWORD_COOLDOWN :: f32(0.35)

// Fall damage: safe up to SAFE_FALL_TILES of drop (a full jump arc is ~3),
// then 1 hp per FALL_TILES_PER_HP beyond.  Water breaks any fall.
SAFE_FALL_TILES   :: f32(5)
FALL_TILES_PER_HP :: f32(2)

update_player :: proc(gs: ^Game_State) {
    p  := &gs.player
    dt := gs.delta_time

    if p.dead {
        p.death_timer += dt   // paces the death screen fade + input delay
        return
    }
    if gs.game_won do return   // the win screen is up — the run is over

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
        // ── Horizontal intent (Speed stat: base + equipment) ──────
        speed := f32(player_stat(p, .Speed))
        p.vel.x = 0
        if inp.move_left  { p.vel.x = -speed; p.facing = -1 }
        if inp.move_right { p.vel.x =  speed; p.facing =  1 }

        // ── Jump ──────────────────────────────────────────────────
        if inp.jump && p.grounded {
            p.vel.y    = JUMP_VEL
            p.grounded = false
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Jump)}})
        }
    }

    // ── AABB movement + collision (gravity applied inside) ───────
    prev_center   := player_tile(p)
    prev_grounded := p.grounded

    move_body(&gs.world, &p.pos, &p.vel, {PLAYER_W, PLAYER_H}, dt,
        flying ? 0 : GRAVITY, MAX_FALL_SPEED, &p.grounded)

    entity_map_move(&gs.world, PLAYER_ID, prev_center, player_tile(p))

    // ── Fall damage: measure the drop from the airborne peak ─────
    // The peak arms only when the ground is actually left (grounded
    // true→false), so boot/load/teleport frames — which start airborne
    // with a stale peak — can never register a phantom fall (the
    // fall_peak_y > 0 guard covers the boot state, where it is zero).
    if flying || player_in_water(gs) {
        p.fall_peak_y = p.pos.y   // fly mode and water break any fall
    } else if prev_grounded && !p.grounded {
        p.fall_peak_y = p.pos.y   // left the ground: arm the fall
    } else if !p.grounded {
        p.fall_peak_y = min(p.fall_peak_y, p.pos.y)
    } else {
        if !prev_grounded && p.fall_peak_y > 0 {   // landed this frame
            fall := p.pos.y - p.fall_peak_y
            if fall > SAFE_FALL_TILES {
                dmg := int((fall - SAFE_FALL_TILES) / FALL_TILES_PER_HP) + 1
                eq_push(&gs.events, Event{
                    type    = .Damage_Dealt,
                    source  = INVALID_ENTITY,   // the world itself — armor won't help
                    target  = PLAYER_ID,
                    payload = {int_val = i32(dmg)},
                })
                log_action(gs, "Player falls %.1f tiles (%d damage)", fall, dmg)
            }
        }
        p.fall_peak_y = p.pos.y
    }

    // ── Fell through the clouds: back to the surface ─────────────
    if gs.level_index == LEVEL_SKY && p.pos.y > SKY_FALL_Y && !flying {
        level_transition(gs, &level_portals[LEVEL_SKY][0])
        return
    }

    // ── Tile hazards: lava burns at the table's damage_per_second ─
    player_tile_hazard(gs, dt)

    // ── Item pickup (walk over drops) ─────────────────────────────
    player_pickup(gs)

    // ── Interact: portals, sky altar ──────────────────────────────
    if inp.interact do player_interact(gs)

    // ── Mana regen ────────────────────────────────────────────────
    p.mana = min(p.mana + p.mana_regen * dt, p.mana_max)

    // ── Melee: click near an enemy swings the equipped weapon ─────
    p.attack_timer -= dt
    if inp.attack && p.attack_timer <= 0 && p.equipment[.Weapon] != .None {
        if id, found := enemy_near_tile(gs, gs.input.mouse_tile); found {
            if chebyshev(builder_tile(&gs.enemies.data[id]), player_tile(p)) <= MELEE_REACH {
                p.attack_timer = SWORD_COOLDOWN
                eq_push(&gs.events, Event{
                    type    = .Damage_Dealt,
                    source  = PLAYER_ID,
                    target  = enemy_entity_id(id),
                    payload = {int_val = player_stat(p, .Attack)},
                })
                log_action(gs, "Player strikes enemy#%d", id)
            }
        }
    }

    // ── Mining: pick chips adjacent tiles, wands shoot further ───
    player_mine(gs, dt)

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

// True while the body overlaps any swimmable tile — used to break falls.
player_in_water :: proc(gs: ^Game_State) -> bool {
    p := &gs.player
    left  := int(p.pos.x)
    right := int(p.pos.x + PLAYER_W - 0.001)
    top   := int(p.pos.y)
    bot   := int(p.pos.y + PLAYER_H - 0.001)
    for ty in top ..= bot {
        for tx in left ..= right {
            if .Swimmable in terrain_table[get_tile(&gs.world, tx, ty)].flags do return true
        }
    }
    return false
}

// Damaging tiles (lava, void sky) hurt while the body overlaps them: the
// strongest overlapped tile's damage_per_second accumulates into hazard_timer,
// which buys 1 hp of damage per unit — dps 2 means 1 damage every 0.5 s.
player_tile_hazard :: proc(gs: ^Game_State, dt: f32) {
    p := &gs.player
    left  := int(p.pos.x)
    right := int(p.pos.x + PLAYER_W - 0.001)
    top   := int(p.pos.y)
    bot   := int(p.pos.y + PLAYER_H - 0.001)

    dps := f32(0)
    for ty in top ..= bot {
        for tx in left ..= right {
            b := terrain_table[get_tile(&gs.world, tx, ty)]
            if .Damaging in b.flags { dps = max(dps, b.damage_per_second) }
        }
    }
    if dps <= 0 {
        p.hazard_timer = 0
        return
    }
    p.hazard_timer += dps * dt
    if p.hazard_timer >= 1 {
        p.hazard_timer -= 1
        eq_push(&gs.events, Event{
            type    = .Damage_Dealt,
            source  = INVALID_ENTITY,   // the world itself
            target  = PLAYER_ID,
            payload = {int_val = 1},
        })
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
