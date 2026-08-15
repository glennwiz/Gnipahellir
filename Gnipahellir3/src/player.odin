package game

import "core:math"

GRAVITY        :: f32(28.0)
MOVE_SPEED     :: f32(8.0)
JUMP_VEL       :: f32(-13.0)
MAX_FALL_SPEED :: f32(25.0)
FLY_SPEED      :: f32(14.0)  // debug fly mode

// Water: it slows and it sinks, but it never drowns (no breath meter —
// Glenn's call).  The repeatable stroke is what keeps that true: without it,
// deep water would drown you by geometry.
WATER_DRAG   :: f32(0.5)   // horizontal speed multiplier while submerged
WATER_SINK   :: f32(0.35)  // gravity/terminal multiplier — you sink slowly
WATER_STROKE :: f32(0.55)  // swim-stroke height, as a fraction of JUMP_VEL

// Leaf fall: eat a GreenBerrie and you drift down like a leaf for a while.
LEAF_FALL_TIME :: f32(20.0)  // seconds of slow-fall per berry
LEAF_FALL_SINK :: f32(0.25)  // gravity/terminal multiplier while it lasts

PLAYER_W :: f32(0.8)   // tile units
PLAYER_H :: f32(1.8)   // tile units

// Collision climbs a one-tile ledge immediately so the body never overlaps
// solid terrain.  Rendering trails that move by this easing rate, turning the
// collision snap into a short visible climb without changing gameplay physics.
STEP_VISUAL_EASE :: f32(18.0)

// Melee.  Damage comes from the Attack stat (equipped weapon); the sword's
// bonus in item_stat_bonus is SWORD_DAMAGE, keeping the old pace:
// builder hp 6 -> three swings.
MELEE_REACH    :: i32(2)     // chebyshev tiles from player center
SWORD_DAMAGE   :: 2
SWORD_COOLDOWN :: f32(0.35)

// Ranged: the fire wand streams orbs at the cursor while the button is held.
// Per-shot damage sits between base and silver sword — range is what the
// wand buys, mana is what it costs (regen 5/s caps sustained fire at half
// uptime, so melee keeps the raw-DPS crown).
FIRE_ORB_SPEED    :: f32(16)     // tiles/s — snappier than Garm's 12
FIRE_ORB_COOLDOWN :: f32(0.4)
FIRE_ORB_MANA     :: f32(4)

// Damage per orb by wand tier — the mine wands' range-table idiom, ready for
// higher tiers.  is_fire_wand keys off it, so a new tier is one row here
// (plus the usual item tables); NOT item_stat_bonus, which would make the
// wand read as a melee weapon.
@(rodata)
fire_orb_damage := #partial [Item]int{
    .Fire_Wand = 3,
}

is_fire_wand :: proc(it: Item) -> bool {
    return fire_orb_damage[it] > 0
}

// The swing hits what is actually in reach: any active enemy within
// MELEE_REACH of the player qualifies, and the cursor only breaks ties
// between several — no pixel aiming required (2026-08-15 playtest: swings
// while standing on a builder must connect).  A direct pool scan, not the
// entity map: two bodies sharing a tile leave only one in the center-tile
// index, and the one underfoot must still be hittable.
melee_target :: proc(gs: ^Game_State) -> (best: int, found: bool) {
    pt := player_tile(&gs.player)
    mt := gs.input.mouse_tile
    best_d := max(i32)
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        et := builder_tile(&gs.enemies.data[i])
        if chebyshev(et, pt) > MELEE_REACH { continue }
        d := chebyshev(et, mt)
        if d < best_d { best_d = d; best = i; found = true }
    }
    return
}

// Fall damage: safe up to SAFE_FALL_TILES of drop (a full jump arc is ~3),
// then 1 hp per FALL_TILES_PER_HP beyond.  Water breaks any fall, and so does
// an active leaf-fall buff — a drifting leaf never lands hard.
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

    gs.player_step_visual_y *= max(f32(0), 1 - STEP_VISUAL_EASE*dt)
    if gs.player_step_visual_y < 0.001 do gs.player_step_visual_y = 0

    inp := &gs.input

    flying := gs.flight_t > 0   // the altar swirl's blessing (levels.odin)
    when GAME_DEBUG do flying = flying || gs.debug.fly

    submerged := !flying && player_in_water(gs)

    if flying {
        // ── Flight (debug fly / flight buff): directional movement, no gravity, no jump ──
        p.vel = {}
        if inp.move_left  { p.vel.x = -FLY_SPEED; p.facing = -1 }
        if inp.move_right { p.vel.x =  FLY_SPEED; p.facing =  1 }
        if inp.fly_up     { p.vel.y = -FLY_SPEED }
        if inp.fly_down   { p.vel.y =  FLY_SPEED }
    } else {
        // ── Horizontal intent (Speed stat: base + equipment) ──────
        speed := f32(player_stat(p, .Speed))
        if submerged do speed *= WATER_DRAG
        p.vel.x = 0
        if inp.move_left  { p.vel.x = -speed; p.facing = -1 }
        if inp.move_right { p.vel.x =  speed; p.facing =  1 }

        // ── Jump / swim stroke ────────────────────────────────────
        // In water the stroke replaces the jump even with footing — a push
        // off the pool floor is still a swim, not a leap.  It needs no
        // ground, so mashing jump always climbs.
        if inp.jump && submerged {
            p.vel.y    = JUMP_VEL * WATER_STROKE
            p.grounded = false
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Jump)}})
        } else if inp.jump && p.grounded {
            p.vel.y    = JUMP_VEL
            p.grounded = false
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Jump)}})
        }
    }

    // ── AABB movement + collision (gravity applied inside) ───────
    prev_center   := player_tile(p)
    prev_grounded := p.grounded
    prev_y        := p.pos.y

    if gs.leaf_fall_t > 0 do gs.leaf_fall_t -= dt
    if gs.flight_t > 0 do gs.flight_t -= dt

    gravity  := flying ? f32(0) : GRAVITY
    max_fall := MAX_FALL_SPEED
    if submerged {
        gravity  *= WATER_SINK   // you sink, slowly
        max_fall *= WATER_SINK
    } else if gs.leaf_fall_t > 0 {
        // Not stacked with water: both together would near-freeze the sink.
        gravity  *= LEAF_FALL_SINK
        max_fall *= LEAF_FALL_SINK
    }
    move_body(&gs.world, &p.pos, &p.vel, {PLAYER_W, PLAYER_H}, dt,
        gravity, max_fall, &p.grounded, is_player = true,
        step_up = true)

    // Keep the sprite at its pre-step height on the collision frame, then let
    // the render offset ease to zero. Adding the actual rise preserves visual
    // continuity even when climbing consecutive stair blocks quickly.
    step_rise := prev_y - p.pos.y
    if prev_grounded && step_rise > STEP_HEIGHT*0.5 {
        gs.player_step_visual_y += step_rise
    }

    entity_map_move(&gs.world, PLAYER_ID, prev_center, player_tile(p))

    // ── Fall damage: measure the drop from the airborne peak ─────
    // The peak arms only when the ground is actually left (grounded
    // true→false), so boot/load/teleport frames — which start airborne
    // with a stale peak — can never register a phantom fall (the
    // fall_peak_y > 0 guard covers the boot state, where it is zero).
    if flying || player_in_water(gs) || gs.leaf_fall_t > 0 {
        p.fall_peak_y = p.pos.y   // fly mode, water and leaf fall break any fall
        // (leaf fall resetting the peak also means a mid-fall berry saves you,
        // and a buff expiring mid-drift only counts the drop from where it died)
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

    // ── Consume from the hand: a click while holding a GreenBerrie/potion
    //    eats or drinks it — Equip_Request already routes consumables to
    //    player_consume, so the hand needs no new path of its own ─────
    if inp.attack && item_is_consumable(held_item(p)) {
        eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = i32(p.inventory.selected)}})
    }

    // ── Melee: click near an enemy swings the held weapon (a held wand is
    //    a mining tool, not a melee weapon).  The blade swings on EVERY
    //    click, hit or whiff — the cooldown is the swing itself, and the
    //    render's swing arc reads it — so attacking never looks like
    //    nothing happened. ─────
    p.attack_timer -= dt
    if inp.attack && p.attack_timer <= 0 && is_melee_weapon(held_item(p)) {
        p.attack_timer = SWORD_COOLDOWN
        if id, found := melee_target(gs); found {
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = PLAYER_ID,
                target  = enemy_entity_id(id),
                payload = {int_val = player_stat(p, .Attack)},
            })
            log_action(gs, "Player strikes enemy#%d", id)
        }
    }

    // ── Fire wand: hold the button and orbs stream at the cursor for mana.
    //    Rides attack_timer (it IS an attack — a sword swap respects the same
    //    cooldown); player_mine skips fire wands, so the same held button
    //    never also punches terrain. ─────
    if inp.mine && p.attack_timer <= 0 && is_fire_wand(held_item(p)) {
        if p.mana < FIRE_ORB_MANA {
            p.attack_timer = 0.6   // rate-limits the reminder while held
            notify(gs, "Not enough mana!")
        } else {
            pc := [2]f32{p.pos.x + PLAYER_W*0.5, p.pos.y + PLAYER_H*0.5}
            m  := gs.input.mouse_world / CELL_SIZE
            d  := m - pc
            dist := math.sqrt(d.x*d.x + d.y*d.y)
            if dist > 0.1 {   // a cursor on the body aims nowhere: no shot
                p.attack_timer = FIRE_ORB_COOLDOWN
                p.mana -= FIRE_ORB_MANA
                if d.x != 0 {p.facing = 1 if d.x > 0 else -1}
                spawn_projectile(gs, pc, d * (FIRE_ORB_SPEED / dist),
                    PLAYER_ID, fire_orb_damage[held_item(p)])
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

            // Forage: walking through a wild flower (1 bloom) or a RIPE flower
            // bed (5 blooms) harvests each bloom for a Flower plus a handful of
            // seeds, then clears the tile.  An unripe bed is left to keep growing.
            ft := get_tile(&gs.world, tx, ty)
            ripe_bed := ft == .Flower_Bed &&
                gs.world.sim_data[idx].growth_timer >= FLOWER_BED_GROW_TIME
            if ft == .Flower || ripe_bed {
                blooms := ft == .Flower_Bed ? FLOWER_BED_BLOOMS : 1
                got := 0
                for _ in 0 ..< blooms {
                    if !inventory_insert(&p.inventory, .Flower, 1) do break
                    got += 1
                    seeds := rand_range(gs, FLOWER_SEED_MIN, FLOWER_SEED_MAX)
                    if !inventory_insert(&p.inventory, .Flower_Seed, seeds) {
                        spawn_ground_item(&gs.world, {i32(tx), i32(ty)}, .Flower_Seed, seeds)
                    }
                }
                if got > 0 {
                    set_tile(&gs.world, tx, ty, .Air)
                    gs.world.sim_data[idx] = {}   // clear the bed's growth timer
                    spawn_collect_mote(gs, {i32(tx), i32(ty)}, .Flower)
                    spawn_collect_mote(gs, {i32(tx), i32(ty)}, .Flower_Seed)
                    gs.save_dirty = true
                    if !gs.forage_hint_shown {
                        gs.forage_hint_shown = true
                        notify(gs, "Foraged a flower + seeds - sow a Flower Bed, brew potions at the bench")
                    }
                }
            }

            it  := gs.world.items[idx]
            cnt := int(gs.world.item_counts[idx])
            if it == .None || cnt == 0 do continue
            // A partial fit banks what fits and deducts exactly that from the
            // pile — the remainder stays on the ground for a later pass.
            had := inventory_count(&p.inventory, it)
            all := inventory_insert(&p.inventory, it, cnt)
            banked := inventory_count(&p.inventory, it) - had
            if banked == 0 do continue

            if all {
                gs.world.items[idx]       = .None
                gs.world.item_counts[idx] = 0
            } else {
                gs.world.item_counts[idx] = u8(cnt - banked)
            }
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
