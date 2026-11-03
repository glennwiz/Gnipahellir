package game

import "core:testing"

// ─── Sky roamers (cards 69, 70) ───────────────────────────────────────────────

sky_ground :: proc(gs: ^Game_State, px: f32) {
    roam_ground(gs, px)
    gs.level_index = LEVEL_SKY
    gs.projectiles = {}
    gs.soak_t = 0
}

wisp_seed :: proc(gs: ^Game_State, x, y: int) -> ^Enemy {
    e := roam_seed(gs, .Rain_Wisp, x)
    e.pos.y = f32(y)
    e.grounded = false
    return e
}

sky_step :: proc(gs: ^Game_State, frames: int) {
    for _ in 0 ..< frames {
        gs.frame += 1
        update_enemies(gs)
        update_projectiles(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }
}

first_drip :: proc(gs: ^Game_State) -> ^Projectile {
    for &p in gs.projectiles.data do if p.active && p.drip do return &p
    return nil
}

@(test)
a_rain_wisp_is_a_sky_row :: proc(t: ^testing.T) {
    row := enemy_behaviour[.Rain_Wisp]
    testing.expect(t, row.update == update_rain_wisp, "wisp brain")
    testing.expect_value(t, row.gravity, f32(0))
    testing.expect_value(t, row.hp, RAIN_WISP_HP)
    testing.expect_value(t, row.speed, RAIN_WISP_SPEED)
    testing.expect_value(t, row.body, [2]f32{RAIN_WISP_W, RAIN_WISP_H})
    spec := roamer_table[.Rain_Wisp]
    testing.expect_value(t, spec.level, LEVEL_SKY)
    testing.expect_value(t, spec.cap, 3)
    testing.expect_value(t, spec.sight, i32(10))
    testing.expect(t, !spec.friendly, "hostile")
    testing.expect_value(t, enemy_kind_names[.Rain_Wisp], "a rain wisp")
    testing.expect_value(t, enemy_drop_table[.Rain_Wisp][0].item, Item.Cloud_Stone)
}

@(test)
wisps_top_up_in_open_sky_and_only_there :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    gs.delta_time = ROAMER_SPAWN_EVERY
    for _ in 0 ..< 200 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Rain_Wisp), roamer_table[.Rain_Wisp].cap)
    rows_differ := false
    first_y := f32(-1)
    for &e, s in gs.enemies.data do if gs.enemies.active[s] {
        T := builder_tile(&e)
        testing.expect(t, abs(T.x - player_tile(&gs.player).x) >= ROAMER_SPAWN_CLEAR, "spawned on the player")
        testing.expect(t, int(T.y) >= ROAMER_AIR_TOP && int(T.y) <= ROAMER_AIR_BOTTOM, "in the sky band")
        testing.expect(t, e.hp == RAIN_WISP_HP && e.hp_max == RAIN_WISP_HP, "whole")
        if first_y >= 0 && e.pos.y != first_y do rows_differ = true
        first_y = e.pos.y
    }
    testing.expect(t, rows_differ, "not all on one row")

    // Solid rows refuse it, and the surface never gets one.
    sky_ground(gs, 100)
    for x in 1 ..< GRID_W - 1 do for y in ROAMER_AIR_TOP - 1 ..= ROAMER_AIR_BOTTOM + 1 do set_tile(&gs.world, x, y, .Cloud)
    for f in 0 ..< 200 {
        gs.frame = u64(f)
        testing.expect(t, !spawn_roamer(gs, .Rain_Wisp), "spawned in cloud")
    }
    sky_ground(gs, 100)
    gs.level_index = LEVEL_SURFACE
    gs.delta_time = ROAMER_SPAWN_EVERY
    for _ in 0 ..< 60 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Rain_Wisp), 0)
}

@(test)
a_wisp_drifts_without_falling_and_keeps_to_the_band :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 170)
    gs.player.dead = true
    e := wisp_seed(gs, 60, 30)
    moved := false
    for _ in 0 ..< 1200 {
        sky_step(gs, 1)
        if e.pos != {f32(60) + (1 - RAIN_WISP_W)*0.5, 30} do moved = true
        testing.expect(t, abs(e.pos.y - 30) < 40, "it stays in the air")
    }
    testing.expect(t, moved, "it drifts")
    testing.expect_value(t, first_drip(gs) == nil, true)

    // A whim outside the band or the map is held inside.
    e.pos = {60, f32(ROAMER_AIR_TOP) - 1}
    roamer_fly(e, gs, {60 + RAIN_WISP_W*0.5, -50})
    testing.expect(t, e.vel.y > 0, "no flight above the band")
    e.pos = {60, f32(ROAMER_AIR_BOTTOM) + 1}
    roamer_fly(e, gs, {60 + RAIN_WISP_W*0.5, 500})
    testing.expect(t, e.vel.y < 0, "no flight into the void")
    e.pos = {f32(CAVE_RIGHT) - 0.5, 30}
    roamer_fly(e, gs, {500, 30 + RAIN_WISP_H*0.5})
    testing.expect(t, e.vel.x < 0, "no flight off the map's right")
    e.pos = {f32(CAVE_LEFT) - 0.5, 30}
    roamer_fly(e, gs, {-500, 30 + RAIN_WISP_H*0.5})
    testing.expect(t, e.vel.x > 0, "no flight off the map's left")
}

// A whim holds its time, then picks a new spot near the wisp, within its roam.
@(test)
a_wisps_whim_waits_and_reaches :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 170)
    gs.player.dead = true
    e := wisp_seed(gs, 60, 30)
    update_rain_wisp(e, 0, gs, gs.delta_time)
    testing.expect_value(t, e.builder.cooldown, ROAMER_WHIM_TIME)
    held := e.builder.target_tile
    gs.frame += 1
    update_rain_wisp(e, 0, gs, 0.25)
    testing.expect_value(t, e.builder.cooldown, ROAMER_WHIM_TIME - 0.25)
    testing.expect_value(t, e.builder.target_tile, held)

    left, right := 0, 0
    home := builder_tile(e)
    for _ in 0 ..< 80 {
        e.builder.cooldown = 0
        gs.frame += 37
        update_rain_wisp(e, 0, gs, gs.delta_time)
        d := e.builder.target_tile - home
        testing.expect(t, abs(d.x) <= RAIN_WISP_ROAM && abs(d.y) <= 2, "a whim stays near")
        if d.x < 0 do left += 1
        if d.x > 0 do right += 1
    }
    testing.expect(t, left > 0 && right > 0, "it drifts both ways")
}

@(test)
roamer_fly_steers_rises_and_stops :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 170)
    e := wisp_seed(gs, 60, 30)
    c := e.pos + [2]f32{RAIN_WISP_W, RAIN_WISP_H}*0.5
    roamer_fly(e, gs, c + {10, 0})
    testing.expect(t, abs(e.vel.x - RAIN_WISP_SPEED) < 0.001, "at its row's speed")
    testing.expect_value(t, e.facing, 1)
    roamer_fly(e, gs, c + {-10, 0})
    testing.expect_value(t, e.facing, -1)
    e.vel = {1, 1}
    roamer_fly(e, gs, c)
    testing.expect_value(t, e.vel, [2]f32{})

    // Straight up keeps its facing.
    e.facing = 1
    roamer_fly(e, gs, c + {0, -5})
    testing.expect_value(t, e.facing, 1)

    // A wall dead ahead means rise, and it gets over.
    for y in 25 ..= 40 do set_tile(&gs.world, 62, y, .Stone)
    e.pos.x = 61.0
    roamer_fly(e, gs, {70, e.pos.y + RAIN_WISP_H*0.5})
    testing.expect_value(t, e.vel.y, -RAIN_WISP_SPEED)
    gs.player.dead = true
    e.builder.cooldown = 1000
    for _ in 0 ..< 400 {
        roamer_fly(e, gs, {70, 31})
        sky_step_body(gs)
    }
    testing.expect(t, e.pos.x > 63, "over the wall")
}

// Moves bodies only, so a brain does not overwrite the steering under test.
sky_step_body :: proc(gs: ^Game_State) {
    for &e, i in gs.enemies.data do if gs.enemies.active[i] {
        row := enemy_behaviour[e.kind]
        move_body(&gs.world, &e.pos, &e.vel, row.body, gs.delta_time, row.gravity, BUILDER_MAX_FALL, &e.grounded)
    }
}

@(test)
a_wisp_holds_over_the_head_and_drips_on_its_clock :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    px := gs.player.pos.x + PLAYER_W*0.5
    e := wisp_seed(gs, 105, ROAM_Y - 7)

    // Out of reach sideways: it closes in without dripping.
    x0 := e.pos.x
    update_rain_wisp(e, 0, gs, gs.delta_time)
    testing.expect(t, e.vel.x < 0, "it comes over")
    testing.expect_value(t, e.pos.x, x0)
    testing.expect_value(t, first_drip(gs) == nil, true)

    roam_step(gs, 200)
    testing.expect(t, abs(e.pos.x + RAIN_WISP_W*0.5 - px) < 0.5, "over the player")
    testing.expect(t, abs(e.pos.y + RAIN_WISP_H*0.5 - (gs.player.pos.y - RAIN_WISP_HOVER)) < 0.5, "at its hover")

    // In reach: one drop, straight down, under the body, on its clock.
    gs.projectiles = {}
    e.builder.attack_timer = 0
    update_rain_wisp(e, 0, gs, gs.delta_time)
    d := first_drip(gs)
    testing.expect(t, d != nil, "it drips")
    testing.expect_value(t, gs.projectiles.count, 1)
    testing.expect_value(t, d.vel, [2]f32{0, RAIN_WISP_DRIP_SPEED})
    testing.expect_value(t, d.pos.y, e.pos.y + RAIN_WISP_H + PROJECTILE_RADIUS)
    testing.expect_value(t, d.pos.x, e.pos.x + RAIN_WISP_W*0.5)
    testing.expect_value(t, d.owner, enemy_entity_id(0))
    testing.expect_value(t, d.damage, 0)
    testing.expect_value(t, e.builder.attack_timer, RAIN_WISP_DRIP_TIME)
    testing.expect_value(t, gs.events.size, 0)   // a silent drop: no fireball whoosh

    update_rain_wisp(e, 0, gs, gs.delta_time)
    testing.expect_value(t, gs.projectiles.count, 1)
    e.builder.attack_timer = 0.001
    update_rain_wisp(e, 0, gs, 0.01)
    testing.expect_value(t, gs.projectiles.count, 2)

    // Reach is the bound, and under the player it does not drip up.
    gs.projectiles = {}
    e.builder.attack_timer = 0
    e.pos.x = px + RAIN_WISP_REACH + 0.2 - RAIN_WISP_W*0.5
    update_rain_wisp(e, 0, gs, gs.delta_time)
    testing.expect_value(t, gs.projectiles.count, 0)
    e.pos.x = px + RAIN_WISP_REACH - 0.2 - RAIN_WISP_W*0.5
    update_rain_wisp(e, 0, gs, gs.delta_time)
    testing.expect_value(t, gs.projectiles.count, 1)
    gs.projectiles = {}
    e.builder.attack_timer = 0
    e.pos = {px - RAIN_WISP_W*0.5, gs.player.pos.y + 0.5}
    update_rain_wisp(e, 0, gs, gs.delta_time)
    testing.expect_value(t, gs.projectiles.count, 0)
}

@(test)
a_wisp_past_sight_or_behind_a_roof_leaves_the_player_be :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    e := wisp_seed(gs, 100, ROAM_Y - int(roamer_table[.Rain_Wisp].sight) - 4)
    e.builder.cooldown = 100
    e.builder.target_tile = builder_tile(e)
    sky_step(gs, 60)
    testing.expect_value(t, first_drip(gs) == nil, true)

    sky_ground(gs, 100)
    e = wisp_seed(gs, 100, ROAM_Y - 7)
    for x in 90 ..= 110 do set_tile(&gs.world, x, ROAM_Y - 4, .Stone)
    e.builder.cooldown = 100
    e.builder.target_tile = builder_tile(e)
    sky_step(gs, 60)
    testing.expect_value(t, first_drip(gs) == nil, true)

    sky_ground(gs, 100)
    e = wisp_seed(gs, 100, ROAM_Y - 7)
    gs.player.dead = true
    e.builder.cooldown = 100
    e.builder.target_tile = builder_tile(e)
    sky_step(gs, 60)
    testing.expect_value(t, first_drip(gs) == nil, true)
}

@(test)
a_hurt_wisp_flees_up_and_away_and_a_dead_player_scares_nothing :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    e := wisp_seed(gs, 104, ROAM_Y - 6)
    e.hp -= 1
    x0, y0 := e.pos.x, e.pos.y
    roam_step(gs, 40)
    testing.expect(t, e.pos.x > x0 + 0.5, "away")
    testing.expect(t, e.pos.y < y0 - 0.2, "and up")
    testing.expect_value(t, first_drip(gs) == nil, true)

    e.pos = {96, f32(ROAM_Y - 6)}
    x0 = e.pos.x
    roam_step(gs, 40)
    testing.expect(t, e.pos.x < x0 - 0.5, "away the other way")

    // Past the hunt it calms down and drifts.
    e.pos = {100 + HUNT_LOSE_DIST + 3, 30}
    e.builder.cooldown = 100
    e.builder.target_tile = builder_tile(e)
    x0 = e.pos.x
    roam_step(gs, 40)
    testing.expect(t, abs(e.pos.x - x0) < 0.6, "out of range it stops running")

    e.pos = {104, f32(ROAM_Y - 6)}
    gs.player.dead = true
    e.builder.target_tile = builder_tile(e)
    x0 = e.pos.x
    roam_step(gs, 40)
    testing.expect(t, abs(e.pos.x - x0) < 0.6, "a dead player scares nothing")
}

@(test)
a_drip_soaks_without_hurting_then_dries :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    hp := gs.player.hp
    spawn_projectile(gs, gs.player.pos + {PLAYER_W*0.5, -1}, {0, RAIN_WISP_DRIP_SPEED}, enemy_entity_id(0), 0, drip = true)
    testing.expect_value(t, gs.events.size, 0)
    for _ in 0 ..< 30 {
        update_projectiles(gs)
        if gs.projectiles.count == 0 do break
    }
    testing.expect_value(t, gs.projectiles.count, 0)
    testing.expect_value(t, gs.events.size, 2)
    a := gs.events.events[gs.events.head]
    b := gs.events.events[(gs.events.head + 1) % MAX_EVENTS]
    testing.expect_value(t, a.type, Event_Type.Player_Soaked)
    testing.expect_value(t, b.type, Event_Type.Projectile_Impact)
    testing.expect_value(t, b.payload.int_val, i32(1))
    gs.particles = {}
    process_events(gs)
    testing.expect_value(t, gs.soak_t, RAIN_SOAK_TIME)
    testing.expect_value(t, gs.player.hp, hp)
    testing.expect_value(t, buff_remaining(gs, .Soaked), RAIN_SOAK_TIME)
    drops := 0
    for i in 0 ..< MAX_PARTICLES do if gs.particles.data[i].lifetime > 0 && gs.particles.data[i].color.b > gs.particles.data[i].color.r do drops += 1
    testing.expect(t, drops > 0, "it splashes water, not fire")
}

@(test)
a_fire_orb_is_no_drip :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    hp := gs.player.hp
    spawn_projectile(gs, gs.player.pos + {PLAYER_W*0.5, -1}, {0, 9}, enemy_entity_id(0), 1)
    testing.expect_value(t, gs.events.size, 1)
    testing.expect_value(t, gs.events.events[gs.events.head].type, Event_Type.Projectile_Fired)
    for _ in 0 ..< 30 do update_projectiles(gs)
    last := gs.events.events[(gs.events.head + gs.events.size - 1) % MAX_EVENTS]
    testing.expect_value(t, last.type, Event_Type.Projectile_Impact)
    testing.expect_value(t, last.payload.int_val, i32(0))
    process_events(gs)
    testing.expect_value(t, gs.soak_t, f32(0))
    testing.expect(t, gs.player.hp < hp, "an orb burns")
}

@(test)
a_roof_stops_a_drip_and_other_enemies_let_it_pass :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    top := gs.player.pos + {PLAYER_W*0.5, -6}
    set_tile(&gs.world, int(top.x), int(top.y) + 3, .Stone)
    spawn_projectile(gs, top, {0, RAIN_WISP_DRIP_SPEED}, enemy_entity_id(0), 0, drip = true)
    for _ in 0 ..< 60 do update_projectiles(gs)
    testing.expect_value(t, gs.projectiles.count, 0)
    testing.expect_value(t, gs.events.size, 1)
    ev := gs.events.events[gs.events.head]
    testing.expect_value(t, ev.type, Event_Type.Projectile_Impact)
    testing.expect_value(t, ev.payload.int_val, i32(1))
    process_events(gs)
    testing.expect_value(t, gs.soak_t, f32(0))

    // The owner is slot 0; a frog in the way is untouched and the drop lands.
    sky_ground(gs, 100)
    wisp_seed(gs, 60, 30)
    frog := roam_seed(gs, .Pond_Frog, int(gs.player.pos.x))
    frog.pos = gs.player.pos + {0, -3}
    spawn_projectile(gs, gs.player.pos + {PLAYER_W*0.5, -6}, {0, RAIN_WISP_DRIP_SPEED}, enemy_entity_id(0), 0, drip = true)
    for _ in 0 ..< 60 do update_projectiles(gs)
    process_events(gs)
    testing.expect_value(t, frog.hp, POND_FROG_HP)
    testing.expect_value(t, gs.soak_t, RAIN_SOAK_TIME)
}

@(test)
a_lit_drip_sheds_no_embers :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    gs.particles = {}
    spawn_projectile(gs, {60, 5}, {0, 1}, enemy_entity_id(0), 0, drip = true)
    for _ in 0 ..< 60 do update_projectiles(gs)
    for i in 0 ..< MAX_PARTICLES do testing.expect_value(t, gs.particles.data[i].lifetime, f32(0))
}

@(test)
soaked_drags_the_stride_and_wears_off :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 100)
    gs.input.move_right = true
    update_player(gs)
    dry := gs.player.vel.x
    testing.expect(t, dry > 0, "walks")

    gs.soak_t = 1
    update_player(gs)
    testing.expect(t, abs(gs.player.vel.x - dry*RAIN_SOAK_DRAG) < 0.001, "soaked, it drags")
    testing.expect(t, gs.soak_t < 1, "it dries")

    gs.flight_t = 5
    update_player(gs)
    testing.expect(t, abs(gs.player.vel.x - FLY_SPEED*RAIN_SOAK_DRAG) < 0.001, "soaked flight drags too")
    gs.soak_t = 0
    update_player(gs)
    testing.expect_value(t, gs.player.vel.x, FLY_SPEED)
    gs.flight_t = 0

    // Not stacked with water.
    pt := player_tile(&gs.player)
    set_tile(&gs.world, int(pt.x), int(pt.y), .Water)
    set_tile(&gs.world, int(pt.x), int(pt.y) - 1, .Water)
    update_player(gs)
    wet := gs.player.vel.x
    testing.expect(t, player_in_water(gs), "in the pool")
    gs.soak_t = 1
    update_player(gs)
    testing.expect_value(t, gs.player.vel.x, wet)
}

@(test)
a_flyers_drop_lands_on_the_floor_below :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    sky_ground(gs, 170)
    testing.expect_value(t, flyer_drop_tile(&gs.world, {60, 30}), [2]i32{60, ROAM_Y})
    testing.expect_value(t, flyer_drop_tile(&gs.world, {60, ROAM_Y}), [2]i32{60, ROAM_Y})

    // No floor under it: it stays where it died.
    for y in ROAM_Y ..< GRID_H do set_tile(&gs.world, 60, y, .Air)
    testing.expect_value(t, flyer_drop_tile(&gs.world, {60, 30}), [2]i32{60, 30})

    sky_ground(gs, 170)
    paid := 0
    for i in 0 ..< 40 {
        gs.enemies = {}
        gs.world.items[grid_idx(60, ROAM_Y)] = .None
        gs.world.item_counts[grid_idx(60, ROAM_Y)] = 0
        wisp_seed(gs, 60, 30)
        gs.frame = u64(i)
        eq_push(&gs.events, Event{type = .Damage_Dealt, source = PLAYER_ID, target = enemy_entity_id(0), payload = {int_val = 99}})
        process_events(gs)
        eq_clear(&gs.events)
        testing.expect_value(t, gs.enemies.count, 0)
        testing.expect_value(t, gs.world.items[grid_idx(60, 30)], Item.None)
        if gs.world.items[grid_idx(60, ROAM_Y)] == .Cloud_Stone do paid += 1
    }
    testing.expect(t, paid > 0 && paid < 40, "half the wisps pay")

    // A walker's drop stays at its feet, whatever is under the tile.
    gs.enemies = {}
    roll_enemy_drops(gs, .Ember_Beetle, {80, 30})
    testing.expect_value(t, gs.world.items[grid_idx(80, 30)], Item.Coal)
}

// Through game_update on the real sky: wisps arrive, stay capped and alive.
@(test)
wisps_ride_out_a_real_sky_soak :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    gen_sky_level(&gs.world, 12345)
    gs.level_index = LEVEL_SKY
    gs.enemies = {}
    gs.player.pos = {95, 79 - PLAYER_H}
    gs.delta_time = 0.05
    gs.ui.show_title = false
    for _ in 0 ..< int(ROAMER_SPAWN_EVERY * 5 * 20) {
        game_update(gs)
        gs.player.hp = gs.player.hp_max
        gs.player.dead = false
        gs.player.pos = {95, 79 - PLAYER_H}
        for &e, s in gs.enemies.data do if gs.enemies.active[s] && e.kind == .Rain_Wisp {
            T := builder_tile(&e)
            testing.expect(t, int(T.y) >= ROAMER_AIR_TOP - 1 && int(T.y) <= ROAMER_AIR_BOTTOM + 1, "in the band")
            testing.expect(t, int(T.x) >= CAVE_LEFT && int(T.x) < CAVE_RIGHT, "on the map")
        }
    }
    n := wave_count_kind(gs, .Rain_Wisp)
    testing.expect(t, n > 0 && n <= roamer_table[.Rain_Wisp].cap, "they arrive, capped")
}
