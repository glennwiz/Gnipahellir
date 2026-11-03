package game

import "core:os"
import "core:testing"

// ─── Roamers and the enemy behaviour table (card 64) ──────────────────────────

ROAM_Y :: 50   // standing row of the test ground

// Flat open ground, x 20..170, with the player parked at px.
roam_ground :: proc(gs: ^Game_State, px: f32) {
    gs.enemies = {}
    gs.world.entity_map = {}
    gs.level_index = LEVEL_SURFACE
    for x in 1 ..< GRID_W - 1 {
        for y in 1 ..= ROAM_Y do set_tile(&gs.world, x, y, .Air)
        set_tile(&gs.world, x, ROAM_Y + 1, .Stone)
    }
    gs.player.pos = {px, f32(ROAM_Y + 1) - PLAYER_H}
}

roam_seed :: proc(gs: ^Game_State, kind: Enemy_Kind, x: int) -> ^Enemy {
    id, _ := enemy_alloc(&gs.enemies)
    row := enemy_behaviour[kind]
    e := &gs.enemies.data[id]
    e^ = Enemy{kind = kind, hp = row.hp, hp_max = row.hp, facing = 1, grounded = true,
        pos = {f32(x) + (1 - row.body.x)*0.5, f32(ROAM_Y + 1) - row.body.y}}
    return e
}

roam_step :: proc(gs: ^Game_State, frames: int) {
    for _ in 0 ..< frames {
        gs.frame += 1
        update_enemies(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }
}

@(test)
every_kind_has_a_whole_behaviour_row :: proc(t: ^testing.T) {
    for row, kind in enemy_behaviour {
        testing.expectf(t, row.update != nil, "%v has no update", kind)
        testing.expectf(t, row.body.x > 0 && row.body.y > 0, "%v has no body", kind)
        testing.expectf(t, row.speed > 0 && row.hp > 0, "%v has no speed or hp", kind)
        testing.expectf(t, row.gravity > 0 || kind == .Fire_Sprite || kind == .Rain_Wisp, "%v floats", kind)
    }
    testing.expect_value(t, enemy_body_size(.Garm), [2]f32{GARM_W, GARM_H})
    testing.expect_value(t, enemy_body_size(.Vargr), [2]f32{BUILDER_W, BUILDER_H})
    testing.expect_value(t, enemy_speed(.Garm), GARM_SPEED)
    testing.expect_value(t, enemy_speed(.Undead), DRAUGR_SPEED)
    testing.expect_value(t, enemy_speed(.Raider), RAIDER_SPEED)
    testing.expect_value(t, enemy_speed(.Vargr), RAIDER_SPEED)
    testing.expect_value(t, enemy_speed(.Fire_Sprite), FIRE_SPRITE_SPEED)
    testing.expect_value(t, enemy_speed(.Builder), BUILDER_SPEED)
    testing.expect_value(t, enemy_behaviour[.Builder].hp, BUILDER_HP)
    testing.expect_value(t, enemy_behaviour[.Garm].hp, GARM_HP)
    testing.expect_value(t, enemy_behaviour[.Undead].hp, DRAUGR_HP)
    testing.expect_value(t, enemy_behaviour[.Raider].hp, RAIDER_HP)
    testing.expect_value(t, enemy_behaviour[.Vargr].hp, VARGR_HP)
    testing.expect_value(t, enemy_behaviour[.Fire_Sprite].hp, FIRE_SPRITE_HP)

    testing.expect(t, enemy_behaviour[.Builder].update == update_builder, "builder brain")
    testing.expect(t, enemy_behaviour[.Garm].update == update_garm, "boss brain")
    testing.expect(t, enemy_behaviour[.Undead].update == update_undead, "draugr brain")
    testing.expect(t, enemy_behaviour[.Raider].update == update_raider, "raider brain")
    testing.expect(t, enemy_behaviour[.Vargr].update == update_raider, "the wolf is the raider brain")
    testing.expect(t, enemy_behaviour[.Fire_Sprite].update == update_fire_sprite, "sprite brain")
    testing.expect(t, enemy_behaviour[.Pond_Frog].update == update_roamer, "frog brain")
    testing.expect(t, enemy_behaviour[.Ember_Beetle].update == update_roamer, "beetle brain")
    testing.expect(t, enemy_behaviour[.Mole].update == update_roamer, "mole brain")

    // The first guesses, pinned so a retune is a choice.
    testing.expect_value(t, roamer_table[.Pond_Frog].cap, 4)
    testing.expect_value(t, roamer_table[.Ember_Beetle].cap, 3)
    testing.expect_value(t, roamer_table[.Ember_Beetle].damage, 1)
    testing.expect_value(t, roamer_table[.Mole].cap, 2)
    testing.expect_value(t, roamer_table[.Mole].dig_every, MOLE_DIG_EVERY)
    testing.expect(t, roamer_table[.Mole].friendly, "a mole is friendly")
    testing.expect_value(t, roamer_table[.Mole].damage, 0)
    testing.expect_value(t, roamer_table[.Mole].sight, i32(5))
    testing.expect_value(t, enemy_body_size(.Mole), [2]f32{MOLE_W, MOLE_H})
    testing.expect_value(t, enemy_speed(.Mole), MOLE_SPEED)
    testing.expect_value(t, enemy_behaviour[.Mole].hp, MOLE_HP)
    testing.expect_value(t, int(MOLE_HP), 3)
    testing.expect_value(t, MOLE_W, f32(0.9))
    testing.expect_value(t, MOLE_H, f32(0.6))
    testing.expect_value(t, MOLE_SPEED, f32(2.0))
    testing.expect_value(t, MOLE_DIG_EVERY, f32(90))
}

@(test)
the_table_moves_each_body_by_its_own_row :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    frog := roam_seed(gs, .Pond_Frog, 60)
    frog.pos.y = 30
    frog.grounded = false
    sprite := roam_seed(gs, .Fire_Sprite, 40)
    sprite.pos.y = 30
    sprite.builder.goal = .Wave_Hunt
    roam_step(gs, 1)
    testing.expect(t, frog.vel.y > 0, "gravity comes from the row")
    testing.expect_value(t, sprite.pos.y <= 30, true)

    // A landed roamer rests on its own feet, not a builder's.
    roam_step(gs, 200)
    testing.expect(t, abs(frog.pos.y + POND_FROG_H - f32(ROAM_Y + 1)) < 0.05, "body comes from the row")
}

// With nothing to do a sprite hangs dead still: no gravity reaches it.
@(test)
a_sprite_with_no_prey_hangs_still :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    wave_clear_structures(gs)
    roam_ground(gs, 170)
    gs.player.dead = true
    e := roam_seed(gs, .Fire_Sprite, 60)
    e.pos.y = 30
    e.builder.goal = .Wave_Hunt
    roam_step(gs, 30)
    testing.expect_value(t, e.pos.y, f32(30))
}

@(test)
a_row_spawns_with_its_hp :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    spawn_builder(gs, 60)
    testing.expect_value(t, gs.enemies.data[0].hp_max, BUILDER_HP)
    testing.expect_value(t, gs.enemies.data[0].hp, BUILDER_HP)
    rise_draugr(gs, 0)
    testing.expect_value(t, gs.enemies.data[0].hp, DRAUGR_HP)
    testing.expect_value(t, gs.enemies.data[0].hp_max, DRAUGR_HP)

    gs.enemies = {}
    testing.expect(t, spawn_wave_walker(gs, 0), "a wolf lands")
    testing.expect_value(t, gs.enemies.data[0].hp, VARGR_HP)
    testing.expect_value(t, gs.enemies.data[0].hp_max, VARGR_HP)

    gs.enemies = {}
    testing.expect(t, spawn_flyer_at(gs, 60, 20), "a sprite lands")
    testing.expect_value(t, gs.enemies.data[0].hp, FIRE_SPRITE_HP)
    testing.expect_value(t, gs.enemies.data[0].hp_max, FIRE_SPRITE_HP)

    gs.enemies = {}
    testing.expect(t, spawn_raider(gs, player_tile(&gs.player), GRID_W/2), "a raider lands")
    testing.expect_value(t, gs.enemies.data[0].hp, RAIDER_HP)
    testing.expect_value(t, gs.enemies.data[0].hp_max, RAIDER_HP)

    gs.enemies = {}
    spawn_garm(gs)
    testing.expect_value(t, gs.enemies.data[0].hp, GARM_HP)
    testing.expect_value(t, gs.enemies.data[0].hp_max, GARM_HP)
}

@(test)
a_gutted_out_body_leaves_the_entity_map :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    e := roam_seed(gs, .Fire_Sprite, 60)
    e.pos.y = 30
    e.builder.goal = .Wave_Hunt
    prev := builder_tile(e)
    e.builder.anchor = prev
    e.builder.stuck_count = FIRE_SPRITE_GIVE_UP - 1
    e.builder.stuck_timer = FIRE_SPRITE_STALL
    gs.world.entity_map[grid_idx(int(prev.x), int(prev.y))] = enemy_entity_id(0)
    roam_step(gs, 1)
    testing.expect(t, !gs.enemies.active[0], "it gutted out")
    testing.expect_value(t, gs.enemies.count, 0)
    for id in gs.world.entity_map do testing.expect(t, id != enemy_entity_id(0), "no ghost in the map")
}

@(test)
roamers_never_touch_a_wave :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    for kind in Enemy_Kind do if roamer_table[kind].cap > 0 {
        e := roam_seed(gs, kind, 60)
        testing.expectf(t, !is_wave_enemy(e), "%v counts as a wave", kind)
        e.builder.goal = .Wave_Hunt
        testing.expectf(t, !is_wave_enemy(e), "%v counts as a wave by goal", kind)
    }

    // Alive roamers do not stand in for survivors: an armed wave's buildup runs.
    gs.wave.threat = 10
    gs.wave.threat_timer = 100
    update_waves(gs)
    eq_clear(&gs.events)
    testing.expect(t, gs.wave.pressure > 0, "roamers held the pressure back")

    n := gs.enemies.count
    debug_wave_clear(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.enemies.count, n)
}

@(test)
roamers_top_up_to_their_caps_and_stop :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    gs.delta_time = ROAMER_SPAWN_EVERY
    for i in 0 ..< 200 {
        gs.frame += 1
        update_roamers(gs)
        for &e, s in gs.enemies.data do if gs.enemies.active[s] {
            testing.expect(t, abs(builder_tile(&e).x - player_tile(&gs.player).x) + 1 > ROAMER_SPAWN_CLEAR - 1, "spawned on the player")
            testing.expect(t, e.hp > 0 && e.hp == e.hp_max, "a roamer starts whole")
            testing.expect(t, is_solid(&gs.world, int(builder_tile(&e).x), ROAM_Y + 1), "on the ground")
            testing.expect(t, abs(e.pos.y + enemy_body_size(e.kind).y - f32(ROAM_Y + 1)) < 0.01, "feet on the floor")
        }
    }
    testing.expect_value(t, wave_count_kind(gs, .Pond_Frog), roamer_table[.Pond_Frog].cap)
    testing.expect_value(t, wave_count_kind(gs, .Ember_Beetle), roamer_table[.Ember_Beetle].cap)
    testing.expect_value(t, wave_count_kind(gs, .Mole), roamer_table[.Mole].cap)

    for &e, s in gs.enemies.data do if gs.enemies.active[s] {
        T := builder_tile(&e)
        testing.expect(t, e.facing != 0, "a roamer faces somewhere")
        testing.expect_value(t, gs.world.entity_map[grid_idx(int(T.x), int(T.y))], enemy_entity_id(s))
    }
}

@(test)
one_top_up_a_beat_and_only_on_the_beat :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    gs.delta_time = ROAMER_SPAWN_EVERY * 0.9
    update_roamers(gs)
    testing.expect_value(t, gs.enemies.count, 0)
    gs.frame = 7
    update_roamers(gs)
    testing.expect(t, gs.enemies.count <= 2, "one per row")
    testing.expect_value(t, gs.roamer_timer, f32(0))
}

@(test)
roamers_spawn_only_on_their_own_level :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    gs.level_index = LEVEL_SURFACE + 1
    gs.delta_time = ROAMER_SPAWN_EVERY
    for _ in 0 ..< 40 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, gs.enemies.count, 0)
}

@(test)
no_roamer_spawns_in_water_or_lava_or_near_the_player :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    for x in 1 ..< GRID_W - 1 do set_tile(&gs.world, x, ROAM_Y, .Water)
    for f in 0 ..< 200 {
        gs.frame = u64(f) * 3
        testing.expect(t, !spawn_roamer(gs, .Pond_Frog), "spawned in water")
    }
    roam_ground(gs, 100)
    spawned := 0
    for f in 0 ..< 400 {
        gs.frame = u64(f)
        if spawn_roamer(gs, .Pond_Frog) do spawned += 1
    }
    testing.expect(t, spawned > 0, "open ground takes a frog")
    near := 0
    for &e, s in gs.enemies.data do if gs.enemies.active[s] && abs(builder_tile(&e).x - 100) < ROAMER_SPAWN_CLEAR do near += 1
    testing.expect_value(t, near, 0)
}

@(test)
a_full_store_refuses_a_roamer :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    for i in 0 ..< MAX_ENEMIES do gs.enemies.active[i] = true
    gs.enemies.count = MAX_ENEMIES
    for f in 0 ..< 50 {
        gs.frame = u64(f)
        testing.expect(t, !spawn_roamer(gs, .Pond_Frog), "no slot")
    }
}

@(test)
a_frog_runs_from_the_player_and_a_turret_lets_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    frog := roam_seed(gs, .Pond_Frog, 104)
    start := frog.pos.x
    roam_step(gs, 30)
    testing.expect(t, frog.pos.x > start + 1, "the frog bolts away")
    testing.expect_value(t, frog.facing, 1)

    // From the other side it runs the other way.
    frog.pos.x = 96
    start = frog.pos.x
    roam_step(gs, 30)
    testing.expect(t, frog.pos.x < start - 1, "the frog bolts the other way")
    testing.expect_value(t, gs.player.hp, gs.player.hp_max)

    _, found := turret_target(gs, 100, ROAM_Y, 100)
    testing.expect(t, !found, "turrets leave a friendly alone")
    roam_seed(gs, .Ember_Beetle, 102)
    ei, hit := turret_target(gs, 100, ROAM_Y, 100)
    testing.expect(t, hit, "a hostile roamer is a target")
    testing.expect_value(t, ei, 1)
}

@(test)
a_frog_past_its_sight_or_behind_a_wall_keeps_calm :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    frog := roam_seed(gs, .Pond_Frog, 100 + int(roamer_table[.Pond_Frog].sight) + 2)
    frog.builder.cooldown = 10   // not walking, by whim
    start := frog.pos.x
    roam_step(gs, 30)
    testing.expect_value(t, frog.pos.x, start)

    frog.pos.x = 104
    start = frog.pos.x
    for y in ROAM_Y - 8 ..= ROAM_Y do set_tile(&gs.world, 102, y, .Stone)
    roam_step(gs, 30)
    testing.expect_value(t, frog.pos.x, start)

    // A dead player scares nothing.
    for y in ROAM_Y - 8 ..= ROAM_Y do set_tile(&gs.world, 102, y, .Air)
    gs.player.dead = true
    frog.hp = 1
    roam_step(gs, 30)
    testing.expect_value(t, frog.pos.x, start)
}

@(test)
a_beetle_bites_then_runs_when_hurt :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    beetle := roam_seed(gs, .Ember_Beetle, 105)
    start := beetle.pos.x
    roam_step(gs, 20)
    testing.expect(t, beetle.pos.x < start, "it comes for the player it sees")
    testing.expect_value(t, beetle.facing, -1)
    hp := gs.player.hp
    roam_step(gs, 120)
    testing.expect(t, gs.player.hp < hp, "it bites")
    testing.expect(t, gs.player.hp <= hp - 2, "it bites again")
    testing.expect(t, gs.player.hp >= hp - 4, "it bites on the attack clock")

    // Hurt, it flees, even past its sight and with a wall between.
    gs.player.hp = gs.player.hp_max
    beetle.hp -= 1
    start = beetle.pos.x
    roam_step(gs, 40)
    testing.expect(t, beetle.pos.x > start + 1, "hurt, it runs")
    testing.expect_value(t, beetle.facing, 1)
    testing.expect_value(t, gs.player.hp, gs.player.hp_max)

    beetle.pos.x = 100 + f32(roamer_table[.Ember_Beetle].sight) + 3
    for y in ROAM_Y - 8 ..= ROAM_Y do set_tile(&gs.world, 103, y, .Stone)
    start = beetle.pos.x
    roam_step(gs, 40)
    testing.expect(t, beetle.pos.x > start + 1, "it knows who hit it")

    // Far enough off, it calms down.
    beetle.pos.x = 100 + HUNT_LOSE_DIST + 3
    beetle.builder.cooldown = 10
    beetle.builder.has_target = false
    start = beetle.pos.x
    roam_step(gs, 40)
    testing.expect(t, abs(beetle.pos.x - start) < 0.1, "out of range it stops running")
}

// One bite: the row's damage, from beside the player and no further, standing.
@(test)
a_bite_is_the_rows_and_from_arms_length :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    pt := player_tile(&gs.player)
    beetle := roam_seed(gs, .Ember_Beetle, int(pt.x) + 2)
    update_roamer(beetle, 0, gs, gs.delta_time)
    testing.expect_value(t, gs.events.size, 0)
    testing.expect(t, beetle.vel.x < 0, "two tiles off it closes in")

    beetle.pos.x = f32(pt.x) + 1
    beetle.facing = 1
    update_roamer(beetle, 0, gs, gs.delta_time)
    testing.expect_value(t, beetle.facing, -1)
    testing.expect_value(t, gs.events.size, 1)
    ev := gs.events.events[gs.events.head]
    testing.expect_value(t, ev.type, Event_Type.Damage_Dealt)
    testing.expect_value(t, int(ev.payload.int_val), roamer_table[.Ember_Beetle].damage)
    testing.expect_value(t, beetle.vel.x, f32(0))
    eq_clear(&gs.events)
}

@(test)
a_whim_waits_its_time :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    frog := roam_seed(gs, .Pond_Frog, 60)
    frog.builder.cooldown = 1
    update_roamer(frog, 0, gs, 0.25)
    testing.expect_value(t, frog.builder.cooldown, f32(0.75))
}

// Refused means stopped: a panicking frog does not coast into the lava, and a
// body in the air gets no second hop.
@(test)
roamer_walk_stops_dead_and_hops_only_from_the_ground :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    frog := roam_seed(gs, .Pond_Frog, 60)
    set_tile(&gs.world, 61, ROAM_Y, .Lava)
    frog.vel.x = 3
    testing.expect(t, !roamer_walk(frog, gs, 1), "lava refused")
    testing.expect_value(t, frog.vel.x, f32(0))

    set_tile(&gs.world, 61, ROAM_Y, .Stone)
    frog.grounded = false
    testing.expect(t, roamer_walk(frog, gs, 1), "a step is walkable")
    testing.expect_value(t, frog.vel.y, f32(0))
    frog.grounded = true
    testing.expect(t, roamer_walk(frog, gs, 1), "a step is walkable")
    testing.expect_value(t, frog.vel.y, ROAMER_HOP)
}

@(test)
roamers_pay_their_drops :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    roam_seed(gs, .Pond_Frog, 60)
    roam_seed(gs, .Ember_Beetle, 140)
    before := gs.stats.total_kills
    for id in 0 ..< 2 {
        eq_push(&gs.events, Event{type = .Damage_Dealt, source = PLAYER_ID, target = enemy_entity_id(id), payload = {int_val = 99}})
    }
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.enemies.count, 0)
    testing.expect_value(t, gs.stats.total_kills, before + 2)
    testing.expect_value(t, gs.world.items[grid_idx(60, ROAM_Y)], Item.Slime)
    testing.expect_value(t, gs.world.items[grid_idx(140, ROAM_Y)], Item.Coal)
}

@(test)
a_wanderer_walks_hops_and_turns :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)

    // It hops a one-tile step.
    frog := roam_seed(gs, .Pond_Frog, 60)
    set_tile(&gs.world, 62, ROAM_Y, .Stone)
    frog.builder.cooldown, frog.builder.has_target = 10, true
    roam_step(gs, 120)
    testing.expect(t, frog.pos.x > 62, "over the step")

    // A wall too tall to hop turns it round; lava too; so does the map's edge.
    roam_ground(gs, 170)
    frog = roam_seed(gs, .Pond_Frog, 60)
    for y in ROAM_Y - 1 ..= ROAM_Y do set_tile(&gs.world, 62, y, .Stone)
    frog.builder.cooldown, frog.builder.has_target = 100, true
    roam_step(gs, 60)
    testing.expect(t, frog.pos.x < 60, "it turned at the wall")

    for hazard in ([]Tile_Type{.Lava, .Magic_Lava}) {
        roam_ground(gs, 170)
        frog = roam_seed(gs, .Pond_Frog, 60)
        set_tile(&gs.world, 62, ROAM_Y + 1, hazard)
        set_tile(&gs.world, 62, ROAM_Y + 2, .Stone)
        frog.builder.cooldown, frog.builder.has_target = 100, true
        roam_step(gs, 60)
        testing.expect(t, frog.pos.x < 60, "it turned at the lava")
        roam_ground(gs, 170)
        frog = roam_seed(gs, .Pond_Frog, 60)
        set_tile(&gs.world, 62, ROAM_Y, hazard)
        frog.builder.cooldown, frog.builder.has_target = 100, true
        roam_step(gs, 60)
        testing.expect(t, frog.pos.x < 60, "it turned at the pool")
    }

    // A wanderer will not walk into a shaft, but a short drop is ground, and a
    // frog running for its life takes any drop.
    roam_ground(gs, 170)
    frog = roam_seed(gs, .Pond_Frog, 60)
    for y in ROAM_Y + 1 ..= ROAM_Y + 8 do set_tile(&gs.world, 62, y, .Air)
    frog.builder.cooldown, frog.builder.has_target = 100, true
    roam_step(gs, 60)
    testing.expect(t, frog.pos.y < f32(ROAM_Y + 1) && frog.pos.x < 60, "it turned at the shaft")

    roam_ground(gs, 170)
    frog = roam_seed(gs, .Pond_Frog, 60)
    for dx in 2 ..= 3 do for y in ROAM_Y + 1 ..= ROAM_Y + ROAMER_MAX_DROP - 1 do set_tile(&gs.world, 60 + dx, y, .Air)
    for dx in 2 ..= 3 do set_tile(&gs.world, 60 + dx, ROAM_Y + ROAMER_MAX_DROP, .Stone)
    frog.builder.cooldown, frog.builder.has_target = 100, true
    roam_step(gs, 60)
    testing.expect(t, frog.pos.y > f32(ROAM_Y + 1), "a short drop is walkable")

    roam_ground(gs, 57)
    frog = roam_seed(gs, .Pond_Frog, 60)
    for x in 62 ..= 66 do for y in ROAM_Y + 1 ..= ROAM_Y + 7 do set_tile(&gs.world, x, y, .Air)
    for x in 62 ..= 66 do set_tile(&gs.world, x, ROAM_Y + 8, .Stone)
    roam_step(gs, 120)
    testing.expect(t, frog.pos.y > f32(ROAM_Y + 2), "panic takes the drop")

    roam_ground(gs, 170)
    frog = roam_seed(gs, .Pond_Frog, 3)
    frog.facing = -1
    frog.builder.cooldown, frog.builder.has_target = 100, true
    roam_step(gs, 60)
    testing.expect(t, frog.pos.x >= f32(CAVE_LEFT) - 0.01, "never past the edge")
    frog2 := roam_seed(gs, .Pond_Frog, CAVE_RIGHT - 3)
    frog2.builder.cooldown, frog2.builder.has_target = 100, true
    roam_step(gs, 60)
    testing.expect(t, frog2.pos.x + POND_FROG_W <= f32(CAVE_RIGHT) + 0.01, "never past the far edge")
}

@(test)
a_whim_can_start_stop_or_turn :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    walked, rested, left, right := 0, 0, 0, 0
    frog := roam_seed(gs, .Pond_Frog, 60)
    for _ in 0 ..< 80 {
        frog.pos = {60, f32(ROAM_Y + 1) - POND_FROG_H}
        frog.builder.cooldown = 0
        gs.frame += 37
        update_roamer(frog, 0, gs, gs.delta_time)
        if frog.builder.has_target { walked += 1 } else { rested += 1 }
        if frog.facing > 0 { right += 1 } else { left += 1 }
        testing.expect_value(t, frog.builder.cooldown, ROAMER_WHIM_TIME)
        testing.expect_value(t, frog.vel.x, frog.builder.has_target ? f32(frog.facing)*POND_FROG_SPEED : 0)
    }
    testing.expect(t, walked > 0 && rested > 0 && left > 0 && right > 0, "a wanderer does all of it")
}

@(test)
every_kind_can_be_named_and_bleed :: proc(t: ^testing.T) {
    for kind in Enemy_Kind {
        testing.expectf(t, len(enemy_kind_names[kind]) > 0, "%v has no name", kind)
        testing.expectf(t, enemy_blood[kind].a > 0, "%v has no blood", kind)
    }
    testing.expect_value(t, enemy_kind_names[.Pond_Frog], "a pond frog")
    testing.expect_value(t, enemy_kind_names[.Ember_Beetle], "an ember beetle")
    testing.expect_value(t, enemy_kind_names[.Mole], "a mole")
}

// Through game_update, so the step itself is what is on trial.
@(test)
roamers_ride_out_a_real_surface_soak :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    gs.player.pos = {f32(GRID_W/2), f32(SURFACE_Y) - PLAYER_H}
    gs.delta_time = 0.05
    gs.ui.show_title = false
    earth :: proc(gs: ^Game_State) -> (n: int) {
        for tile in gs.world.terrain do if roamer_earth[tile] do n += 1
        return
    }
    ground := earth(gs)
    for _ in 0 ..< int((ROAMER_SPAWN_EVERY * 3 + MOLE_DIG_EVERY * 2) * 20) {
        game_update(gs)
        gs.player.hp = gs.player.hp_max
        gs.player.dead = false
    }
    testing.expect(t, wave_count_kind(gs, .Pond_Frog) > 0, "frogs arrive on real ground")
    testing.expect(t, wave_count_kind(gs, .Pond_Frog) <= roamer_table[.Pond_Frog].cap, "capped")
    testing.expect(t, wave_count_kind(gs, .Ember_Beetle) > 0, "beetles arrive on real ground")
    testing.expect(t, wave_count_kind(gs, .Ember_Beetle) <= roamer_table[.Ember_Beetle].cap, "capped")
    testing.expect(t, wave_count_kind(gs, .Mole) > 0, "moles arrive on real ground")
    testing.expect(t, wave_count_kind(gs, .Mole) <= roamer_table[.Mole].cap, "capped")
    testing.expect(t, earth(gs) < ground, "moles dig real ground")
    testing.expect(t, ground - earth(gs) <= roamer_table[.Mole].cap * 3, "at the mole's pace")
}

// A live roamer of every row comes back from a save as it went in.  A new row
// is covered by being in the table.
@(test)
a_live_roamer_survives_a_save_round_trip :: proc(t: ^testing.T) {
    path :: "gnipahellir_roamer_scratch.dat"
    defer os.remove(path)
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    x := 30
    for kind in Enemy_Kind do if roamer_table[kind].cap > 0 {
        e := roam_seed(gs, kind, x)
        e.hp = enemy_behaviour[kind].hp - 1
        e.facing = -1
        e.builder.cooldown = 1.5
        e.builder.has_target = true
        e.builder.stuck_timer = 42
        x += 8
    }
    want := gs.enemies
    testing.expect(t, save_game_to(gs, path), "saved")
    gs.enemies = {}
    testing.expect(t, load_game_from(gs, path), "loaded")
    testing.expect_value(t, gs.enemies.count, want.count)
    for i in 0 ..< want.count {
        testing.expect(t, gs.enemies.active[i], "the slot came back")
        testing.expect_value(t, gs.enemies.data[i].kind, want.data[i].kind)
        testing.expect_value(t, gs.enemies.data[i].hp, want.data[i].hp)
        testing.expect_value(t, gs.enemies.data[i].hp_max, want.data[i].hp_max)
        testing.expect_value(t, gs.enemies.data[i].pos, want.data[i].pos)
        testing.expect_value(t, gs.enemies.data[i].facing, -1)
        testing.expect_value(t, gs.enemies.data[i].builder.cooldown, f32(1.5))
        testing.expect_value(t, gs.enemies.data[i].builder.has_target, true)
        testing.expect_value(t, gs.enemies.data[i].builder.stuck_timer, f32(42))
    }
}

// Earth floor under open air, with a mole on it and its dig clock run down.
mole_on_earth :: proc(gs: ^Game_State, px: f32) -> ^Enemy {
    roam_ground(gs, px)
    for x in 50 ..= 70 {
        set_tile(&gs.world, x, ROAM_Y + 1, .Grass)
        set_tile(&gs.world, x, ROAM_Y + 2, .Stone)
    }
    e := roam_seed(gs, .Mole, 60)
    e.builder.cooldown = 100   // standing still, by whim
    e.builder.stuck_timer = MOLE_DIG_EVERY
    return e
}

@(test)
a_mole_digs_one_hole_and_climbs_out :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    {
        mole := mole_on_earth(gs, 170)
        update_roamer(mole, 0, gs, gs.delta_time)
        testing.expect_value(t, is_solid(&gs.world, 60, ROAM_Y + 1), false)
        testing.expect_value(t, gs.world.items[grid_idx(60, ROAM_Y + 1)], Item.Grass_Turf)
        testing.expect_value(t, mole.builder.stuck_timer, f32(0))
    }

    // It drops in, and its next hole does not go deeper.
    mole := &gs.enemies.data[0]
    roam_step(gs, 30)
    testing.expect(t, abs(mole.pos.y + MOLE_H - f32(ROAM_Y + 2)) < 0.05, "in the hole")
    mole.builder.stuck_timer = MOLE_DIG_EVERY
    roam_step(gs, 2)
    testing.expect_value(t, get_tile(&gs.world, 60, ROAM_Y + 2), Tile_Type.Stone)

    // Nor when the floor of the pit is earth: its sides are not open air.
    set_tile(&gs.world, 60, ROAM_Y + 2, .Grass)
    roam_step(gs, 2)
    testing.expect_value(t, get_tile(&gs.world, 60, ROAM_Y + 2), Tile_Type.Grass)

    // Wandering, it hops back out.
    mole.builder.cooldown, mole.builder.has_target = 100, true
    roam_step(gs, 120)
    testing.expect(t, mole.pos.y + MOLE_H < f32(ROAM_Y + 1) + 0.05, "it climbed out")
}

@(test)
a_mole_digs_on_its_clock_and_only_in_calm :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    mole := mole_on_earth(gs, 170)
    mole.builder.stuck_timer = 0
    update_roamer(mole, 0, gs, MOLE_DIG_EVERY * 0.5)
    testing.expect_value(t, mole.builder.stuck_timer, MOLE_DIG_EVERY * 0.5)
    testing.expect(t, is_solid(&gs.world, 60, ROAM_Y + 1), "not yet")
    update_roamer(mole, 0, gs, MOLE_DIG_EVERY * 0.5)
    testing.expect(t, !is_solid(&gs.world, 60, ROAM_Y + 1), "on the clock")

    // In the air it waits, with the clock held ripe.
    mole = mole_on_earth(gs, 170)
    mole.grounded = false
    update_roamer(mole, 0, gs, gs.delta_time)
    testing.expect(t, is_solid(&gs.world, 60, ROAM_Y + 1), "not in the air")
    testing.expect(t, mole.builder.stuck_timer >= MOLE_DIG_EVERY, "the clock stays ripe")

    // Fleeing the player it sees, or hurt, it does not dig and its clock stops.
    mole = mole_on_earth(gs, 63)
    update_roamer(mole, 0, gs, gs.delta_time)
    testing.expect(t, is_solid(&gs.world, 60, ROAM_Y + 1), "a mole in sight runs")
    testing.expect_value(t, mole.builder.stuck_timer, MOLE_DIG_EVERY)
    testing.expect(t, mole.vel.x < 0 || mole.vel.x > 0, "it runs")

    // Other roamers never dig.
    roam_ground(gs, 170)
    for x in 50 ..= 70 do set_tile(&gs.world, x, ROAM_Y + 1, .Grass)
    frog := roam_seed(gs, .Pond_Frog, 60)
    frog.builder.cooldown = 100
    update_roamer(frog, 0, gs, MOLE_DIG_EVERY * 2)
    testing.expect(t, is_solid(&gs.world, 60, ROAM_Y + 1), "a frog has no spade")
    testing.expect_value(t, frog.builder.stuck_timer, f32(0))
}

@(test)
a_mole_leaves_what_is_not_its_to_dig :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    FX, FY :: 60, ROAM_Y + 1

    check :: proc(t: ^testing.T, gs: ^Game_State, mole: ^Enemy, why: string, loc := #caller_location) {
        before := get_tile(&gs.world, FX, FY)
        testing.expect(t, !roamer_dig(mole, 0, gs), why, loc = loc)
        testing.expect_value(t, get_tile(&gs.world, FX, FY), before, loc = loc)
    }

    mole := mole_on_earth(gs, 170)
    testing.expect(t, roamer_may_dig(gs, FX, FY), "the open case digs")

    set_tile(&gs.world, FX, FY, .Stone)
    check(t, gs, mole, "stone is no earth")

    mole = mole_on_earth(gs, 170)
    gs.world.tile_flags[grid_idx(FX, FY)] += {.Placed}
    check(t, gs, mole, "a placed block is the player's")
    gs.world.tile_flags[grid_idx(FX, FY)] -= {.Placed}

    for dx in -1 ..= 1 {
        for above in ([]Tile_Type{.Water, .Wood, .Flower_Bed}) {
            mole = mole_on_earth(gs, 170)
            set_tile(&gs.world, FX + dx, FY - 1, above)
            check(t, gs, mole, "something stands on it or beside it")
        }
    }

    for dx in ([]int{-1, 1}) {
        mole = mole_on_earth(gs, 170)
        set_tile(&gs.world, FX + dx, FY, .Air)
        check(t, gs, mole, "beside a hole: no trench")
    }

    mole = mole_on_earth(gs, 170)
    set_tile(&gs.world, FX, FY + 1, .Void)
    check(t, gs, mole, "over a hollow: no cave roof opened")

    // A build leaning on the lip keeps its anchor: placed planks out over air,
    // natural wood, or placed earth, beside it or under it.
    for dx in ([]int{-1, 1}) {
        mole = mole_on_earth(gs, 170)
        for k in 1 ..= 4 {
            bx := FX + dx*k
            set_tile(&gs.world, bx, FY, .Wood)
            gs.world.tile_flags[grid_idx(bx, FY)] += {.Placed}
            if k > 1 do for y in FY + 1 ..= FY + 3 do set_tile(&gs.world, bx, y, .Air)
        }
        check(t, gs, mole, "a plank bridge leans on the lip")
        testing.expect_value(t, get_tile(&gs.world, FX + dx*4, FY), Tile_Type.Wood)
        for k in 1 ..= 4 do gs.world.tile_flags[grid_idx(FX + dx*k, FY)] -= {.Placed}
        check(t, gs, mole, "a tree's root leans on it too")
    }
    mole = mole_on_earth(gs, 170)
    set_tile(&gs.world, FX, FY + 1, .Wood)
    check(t, gs, mole, "wood under it")
    mole = mole_on_earth(gs, 170)
    set_tile(&gs.world, FX, FY + 1, .Dirt)
    check(t, gs, mole, "dirt under it would fall in")

    // A pond holding beside the floor stays held.
    for dx in ([]int{-1, 1}) {
        mole = mole_on_earth(gs, 170)
        set_tile(&gs.world, FX + dx, FY, .Water)
        check(t, gs, mole, "beside water")
    }
}

// Earth is no den wall and no hoard: the table alone keeps a mole off both.
@(test)
a_moles_earth_is_never_a_den_or_a_structure :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    testing.expect(t, !roamer_earth[.Dirt], "no Dirt: all of it in play was placed")
    for dig, tile in roamer_earth do if dig {
        set_tile(&gs.world, 60, ROAM_Y + 1, tile)
        testing.expectf(t, !den_material(gs, 60, ROAM_Y + 1), "%v is den material", tile)
        testing.expectf(t, !is_structure_tile[tile], "%v is a structure", tile)
        testing.expectf(t, !is_rune_scroll_chest(tile), "%v is a chest", tile)
    }
}

@(test)
a_mole_turns_up_ore_and_pays_when_hunted :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)

    // Over many holes the rows pay at about their odds, and always into the hole.
    iron, silver := 0, 0
    HOLES :: 600
    for _ in 0 ..< HOLES {
        mole := mole_on_earth(gs, 170)
        gs.world.items = {}
        gs.world.item_counts = {}
        testing.expect(t, roamer_dig(mole, 0, gs), "dug")
        for it, i in gs.world.items {
            n := int(gs.world.item_counts[i])
            if it == .Iron_Ore {
                iron += n
            } else if it == .Silver_Ore {
                silver += n
            } else {
                testing.expectf(t, it == .None || it == .Grass_Turf, "turned up %v", it)
            }
        }
    }
    testing.expect(t, iron > HOLES/5 && iron < HOLES*2/5, "iron near its row")
    testing.expect(t, silver > HOLES/20 && silver < HOLES*3/20, "silver near its row")

    // Hunted down, it pays its dirt, and iron on the row's odds.
    got_iron, kills := 0, 200
    for _ in 0 ..< kills {
        roam_ground(gs, 170)
        gs.world.items = {}
        gs.world.item_counts = {}
        roam_seed(gs, .Mole, 60)
        eq_push(&gs.events, Event{type = .Damage_Dealt, source = PLAYER_ID, target = enemy_entity_id(0), payload = {int_val = 99}})
        process_events(gs)
        eq_clear(&gs.events)
        testing.expect_value(t, gs.enemies.count, 0)
        dirt := 0
        for it, i in gs.world.items {
            if it == .Dirt do dirt += int(gs.world.item_counts[i])
            if it == .Iron_Ore do got_iron += 1
        }
        testing.expect(t, dirt >= 1 && dirt <= 2, "its dirt")
    }
    testing.expect(t, got_iron > kills/3 && got_iron < kills*2/3, "iron near its row")
}

// The hole is the mole's: in the player's reach its turf still lands on the
// ground, and the player's bag gets nothing.
@(test)
a_moles_hole_is_not_the_players_mine :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    mole := mole_on_earth(gs, 62)
    before := inventory_count(&gs.player.inventory, .Grass_Turf)
    testing.expect(t, roamer_dig(mole, 0, gs), "dug")
    testing.expect_value(t, gs.world.items[grid_idx(60, ROAM_Y + 1)], Item.Grass_Turf)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Grass_Turf), before)
}

@(test)
a_mole_is_friendly_to_turrets_and_runs :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    mole := roam_seed(gs, .Mole, 103)
    start := mole.pos.x
    roam_step(gs, 30)
    testing.expect(t, mole.pos.x > start + 0.5, "it bolts")
    testing.expect_value(t, gs.player.hp, gs.player.hp_max)
    _, found := turret_target(gs, 100, ROAM_Y, 100)
    testing.expect(t, !found, "turrets leave a mole alone")
}
