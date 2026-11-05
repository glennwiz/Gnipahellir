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
        testing.expectf(t, row.gravity > 0 || row.update == update_fire_sprite || row.update == update_rain_wisp || row.update == update_rock_harpy || roamer_table[kind].swims, "%v floats", kind)
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
    testing.expect(t, enemy_behaviour[.Cave_Eel].update == update_roamer, "eel brain")
    testing.expect(t, enemy_behaviour[.Magma_Crawler].update == update_roamer, "crawler brain")
    testing.expect(t, enemy_behaviour[.Stone_Grub].update == update_roamer, "grub brain")

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
    testing.expect_value(t, roamer_table[.Cave_Eel].cap, 3)
    testing.expect_value(t, roamer_table[.Cave_Eel].damage, 2)
    testing.expect_value(t, roamer_table[.Cave_Eel].level, LEVEL_CAVE2)
    testing.expect_value(t, roamer_table[.Magma_Crawler].cap, 3)
    testing.expect_value(t, roamer_table[.Magma_Crawler].damage, 2)
    testing.expect_value(t, roamer_table[.Magma_Crawler].level, LEVEL_CAVE2)
    testing.expect_value(t, roamer_table[.Stone_Grub].cap, 3)
    testing.expect_value(t, roamer_table[.Stone_Grub].damage, 1)
    testing.expect_value(t, roamer_table[.Stone_Grub].level, LEVEL_CAVE2)
    testing.expect_value(t, enemy_behaviour[.Stone_Grub].hp, 12)
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
    gs.level_index = LEVEL_DIMENSION
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
    path := test_scratch_path("gnipahellir_roamer_scratch.dat")
    defer delete(path)
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

// ─── Cave Eel (card 66) ───────────────────────────────────────────────────────

EEL_X0 :: 40
EEL_X1 :: 69
EEL_Y0 :: 41

// An open-topped tank on the test ground, rows EEL_Y0..ROAM_Y.
eel_tank :: proc(gs: ^Game_State, px: f32) {
    roam_ground(gs, px)
    for y in EEL_Y0 ..= ROAM_Y {
        set_tile(&gs.world, EEL_X0 - 1, y, .Stone)
        set_tile(&gs.world, EEL_X1 + 1, y, .Stone)
        for x in EEL_X0 ..= EEL_X1 do set_tile(&gs.world, x, y, .Water)
    }
}

// Not a drop of water left on the level.
eel_dry :: proc(gs: ^Game_State) {
    for &c in gs.world.terrain do if c == .Water do c = .Air
}

eel_seed :: proc(gs: ^Game_State, x, y: int) -> ^Enemy {
    e := roam_seed(gs, .Cave_Eel, x)
    e.pos.y = f32(y) + 0.3
    e.grounded = false
    return e
}

eel_in_tank :: proc(gs: ^Game_State, e: ^Enemy) -> bool {
    T := builder_tile(e)
    return get_tile(&gs.world, int(T.x), int(T.y)) == .Water
}

@(test)
a_wandering_eel_never_leaves_the_water :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 170)
    e := eel_seed(gs, 50, 45)
    low, high := e.pos.x, e.pos.x
    for _ in 0 ..< 3000 {
        roam_step(gs, 1)
        testing.expect(t, eel_in_tank(gs, e), "the eel left the water")
        low, high = min(low, e.pos.x), max(high, e.pos.x)
    }
    testing.expect(t, high - low > 3, "the eel never swam")
    testing.expect_value(t, e.pos.y, f32(45.3))
}

// At the bank it turns back: a swim that meets no water is refused and says so.
@(test)
an_eel_turns_at_the_bank :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 170)
    e := eel_seed(gs, EEL_X1, 45)
    e.pos.x = f32(EEL_X1) + 1 - CAVE_EEL_W
    e.vel = {3, 3}   // last frame's swim must not carry on
    testing.expect(t, !roamer_swim(e, gs, 1, 0), "swam out of the tank")
    testing.expect_value(t, e.vel, [2]f32{})
    testing.expect(t, roamer_swim(e, gs, -1, 0), "open water behind it")
    testing.expect_value(t, e.vel, [2]f32{-CAVE_EEL_SPEED, 0})

    e.pos = {50, f32(EEL_Y0)}
    e.vel = {0, -3}
    testing.expect(t, !roamer_swim(e, gs, 0, -1), "swam up out of the surface")
    testing.expect_value(t, e.vel.y, f32(0))
    testing.expect(t, roamer_swim(e, gs, 0, 1), "deeper water below")
    testing.expect_value(t, e.vel.y, CAVE_EEL_SPEED)
}

@(test)
an_eel_leaves_a_player_on_the_bank_alone :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 50)
    gs.player.pos.y = f32(EEL_Y0) - PLAYER_H   // standing on the surface, dry
    eel_seed(gs, 50, EEL_Y0 + 1)
    testing.expect(t, !player_in_water(gs), "the player is dry")
    roam_step(gs, 240)
    testing.expect_value(t, gs.player.hp, gs.player.hp_max)
    testing.expect_value(t, gs.bite_slow_t, f32(0))
}

@(test)
an_eel_hunts_a_swimmer_bites_and_slows_him :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 45)
    gs.player.pos.y = 44
    testing.expect(t, player_in_water(gs), "the player swims")
    e := eel_seed(gs, 51, 48)
    for _ in 0 ..< 240 do if gs.player.hp == gs.player.hp_max do roam_step(gs, 1)
    pt := player_tile(&gs.player)
    testing.expect(t, chebyshev(builder_tile(e), pt) <= 1, "the eel came for him, across and up")
    testing.expect_value(t, gs.player.hp, gs.player.hp_max - roamer_table[.Cave_Eel].damage)
    testing.expect_value(t, gs.bite_slow_t, CAVE_EEL_BITE_SLOW)
    testing.expect_value(t, buff_remaining(gs, .Eel_Bite), CAVE_EEL_BITE_SLOW)

    // Same row: no climb, so it does not bob while it closes.
    e.pos = {52, f32(pt.y) + 0.3}
    e.builder.attack_timer = 0
    e.facing = 1
    roam_step(gs, 1)
    testing.expect_value(t, e.vel.y, f32(0))
    testing.expect(t, e.vel.x < 0, "it closes along the row")
    testing.expect_value(t, e.facing, -1)

    // Just past its sight it does not come.
    testing.expect_value(t, roamer_table[.Cave_Eel].sight, 8)
    e.pos = {f32(pt.x) + 9, f32(pt.y) + 0.3}
    e.builder.has_target = false
    e.builder.cooldown = 100
    roam_step(gs, 1)
    testing.expect_value(t, e.vel, [2]f32{})

    // Beyond sight the swimmer is safe.
    e.pos = {66, 49.3}
    hp := gs.player.hp
    gs.player.pos = {45, 41}
    gs.bite_slow_t = 0
    e.builder.has_target = false
    e.builder.cooldown = 100
    roam_step(gs, 1)
    testing.expect_value(t, e.vel, [2]f32{})
    testing.expect_value(t, gs.player.hp, hp)
    testing.expect_value(t, gs.bite_slow_t, f32(0))
}

@(test)
a_plain_bite_slows_nobody :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    roam_seed(gs, .Ember_Beetle, 101)
    roam_step(gs, 2)
    testing.expect_value(t, gs.player.hp, gs.player.hp_max - 1)
    testing.expect_value(t, gs.bite_slow_t, f32(0))
}

@(test)
the_slow_takes_the_longer_of_two_and_skips_the_dead :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    slow :: proc(gs: ^Game_State, secs: f32) {
        eq_push(&gs.events, Event{type = .Player_Slowed, target = PLAYER_ID, payload = {float_val = secs}})
        process_events(gs)
        eq_clear(&gs.events)
    }
    slow(gs, 3)
    testing.expect_value(t, gs.bite_slow_t, f32(3))
    slow(gs, 1)
    testing.expect_value(t, gs.bite_slow_t, f32(3))
    gs.bite_slow_t = 0
    gs.player.dead = true
    slow(gs, 3)
    testing.expect_value(t, gs.bite_slow_t, f32(0))
}

@(test)
the_slow_cuts_the_players_speed_and_runs_out :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    gs.delta_time = 0.1
    gs.input.move_right = true
    update_player(gs)
    full := gs.player.vel.x
    testing.expect(t, full > 0, "the player walks")

    gs.bite_slow_t = 0.25
    update_player(gs)
    testing.expect_value(t, gs.player.vel.x, full*BITE_SLOW)
    testing.expect(t, abs(gs.bite_slow_t - 0.15) < 0.001, "the clock runs")
    update_player(gs)
    update_player(gs)
    testing.expect(t, gs.bite_slow_t <= 0, "the clock ran out")
    update_player(gs)
    testing.expect_value(t, gs.player.vel.x, full)
}

@(test)
a_hurt_eel_flees_through_the_water :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 45)
    gs.player.pos.y = 44
    e := eel_seed(gs, 50, 46)
    e.hp -= 1
    e.facing = -1
    start := e.pos
    roam_step(gs, 30)
    testing.expect_value(t, e.facing, 1)
    testing.expect(t, e.pos.x > start.x + 1, "swims off along the row")
    testing.expect(t, e.pos.y > start.y + 1, "and down")
    testing.expect(t, eel_in_tank(gs, e), "it stays in the water")
    testing.expect_value(t, gs.player.hp, gs.player.hp_max)

    // From above the swimmer it dives the other way.
    e.pos = {50, 42.3}
    gs.player.pos.y = 46
    roam_step(gs, 1)
    testing.expect_value(t, e.vel.y, -CAVE_EEL_SPEED)

    // Level with him it goes down, away from the air.
    pt := player_tile(&gs.player)
    e.pos = {50, f32(pt.y) + 0.3}
    roam_step(gs, 1)
    testing.expect_value(t, builder_tile(e).y, pt.y)
    testing.expect_value(t, e.vel.y, CAVE_EEL_SPEED)
}

// A bank of open air holds it in as surely as stone: its nose stays wet.
@(test)
an_eel_keeps_its_body_in_the_water_at_an_air_bank :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 170)
    for y in EEL_Y0 ..= ROAM_Y do set_tile(&gs.world, EEL_X1 + 1, y, .Air)
    e := eel_seed(gs, EEL_X1 - 3, 45)
    e.builder.has_target = true
    e.builder.cooldown = 100
    turned := false
    for _ in 0 ..< 240 {
        roam_step(gs, 1)
        testing.expect(t, e.pos.x + CAVE_EEL_W <= f32(EEL_X1 + 1), "its nose left the water")
        turned ||= e.facing == -1
    }
    testing.expect(t, turned, "it turned at the bank")
}

// Each beat's roll picks its own start, so eels scatter through a pool.
@(test)
eels_scatter_through_the_pool :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_dry(gs)
    eel_tank(gs, 170)
    gs.level_index = LEVEL_CAVE2
    seen: map[[2]i32]bool
    defer delete(seen)
    for f in 0 ..< 20 {
        gs.enemies = {}
        gs.frame = u64(f)
        testing.expect(t, spawn_roamer(gs, .Cave_Eel), "no eel")
        seen[builder_tile(&gs.enemies.data[0])] = true
    }
    testing.expect(t, len(seen) >= 5, "the eels all start in one place")
}

@(test)
an_eel_with_no_water_falls_and_lies_there_until_it_comes_back :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_tank(gs, 45)
    e := eel_seed(gs, 50, 45)
    for y in EEL_Y0 ..= ROAM_Y do for x in EEL_X0 ..= EEL_X1 do set_tile(&gs.world, x, y, .Air)
    e.vel.x = CAVE_EEL_SPEED
    roam_step(gs, 1)
    testing.expect_value(t, e.vel.x, f32(0))
    roam_step(gs, 120)
    testing.expect(t, abs(e.pos.y + CAVE_EEL_H - f32(ROAM_Y + 1)) < 0.05, "it fell to the floor")
    x := e.pos.x
    roam_step(gs, 300)
    testing.expect_value(t, e.pos.x, x)

    // In a long drop it falls no faster than anyone else.
    e.pos.y = 45
    e.vel.y = BUILDER_MAX_FALL
    roam_step(gs, 1)
    testing.expect_value(t, e.vel.y, BUILDER_MAX_FALL)
    e.pos.y = f32(ROAM_Y + 1) - CAVE_EEL_H
    e.vel.y = 0
    roam_step(gs, 2)

    // Water back: the fall is forgotten, it swims again.
    e.pos.y = 45.3
    T := builder_tile(e)
    set_tile(&gs.world, int(T.x), int(T.y), .Water)
    e.vel.y = 5
    e.builder.has_target = false
    e.builder.cooldown = 100
    roam_step(gs, 1)
    testing.expect_value(t, e.vel.y, f32(0))
}

@(test)
eels_spawn_in_water_on_their_level_only :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_dry(gs)
    eel_tank(gs, 170)
    testing.expect(t, gs.level_index == LEVEL_SURFACE, "starts on the surface")
    gs.delta_time = ROAMER_SPAWN_EVERY
    for _ in 0 ..< 60 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Cave_Eel), 0)

    gs.enemies = {}
    gs.level_index = LEVEL_CAVE2
    for _ in 0 ..< 60 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Cave_Eel), roamer_table[.Cave_Eel].cap)
    testing.expect_value(t, wave_count_kind(gs, .Pond_Frog), 0)
    for &e, s in gs.enemies.data do if gs.enemies.active[s] && e.kind == .Cave_Eel {
        testing.expect(t, eel_in_tank(gs, &e), "spawned out of the water")
    }

    // No water, or only water beside the player: no eel.
    gs.enemies = {}
    gs.player.pos.x = 55
    for f in 0 ..< 40 {
        gs.frame = u64(f)
        testing.expect(t, !spawn_roamer(gs, .Cave_Eel), "spawned beside the player")
    }
    eel_dry(gs)
    for f in 0 ..< 40 {
        gs.frame = u64(f)
        testing.expect(t, !spawn_roamer(gs, .Cave_Eel), "spawned with no water")
    }
}

// Water beside the player does not stop one out of his sight being found.
@(test)
cave_home_passes_over_the_players_pool :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_dry(gs)
    eel_tank(gs, 55)
    set_tile(&gs.world, 150, 33, .Water)
    for h in 0 ..< 50 {
        x, _, ok := find_cave_home(gs, roamer_table[.Cave_Eel], whash(u32(h)))
        testing.expect(t, ok, "missed it")
        testing.expect_value(t, x, 150)
    }
}

// One cell of water, anywhere: the walk meets every cell.
@(test)
cave_home_finds_a_lone_cell :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    eel_dry(gs)
    set_tile(&gs.world, 77, 33, .Water)
    for h in 0 ..< 50 {
        x, y, ok := find_cave_home(gs, roamer_table[.Cave_Eel], whash(u32(h)))
        testing.expect(t, ok, "missed it")
        testing.expect_value(t, x, 77)
        testing.expect_value(t, y, 33)
    }
}

@(test)
an_eel_drops_its_skin :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 100)
    roam_seed(gs, .Cave_Eel, 60)
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = PLAYER_ID, target = enemy_entity_id(0), payload = {int_val = 99}})
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.world.items[grid_idx(60, ROAM_Y)], Item.Eel_Skin)
    testing.expect_value(t, enemy_kind_names[.Cave_Eel], "a cave eel")
}

// The tub brings its own walls and floor to open ground.
@(test)
a_cave_pool_is_lined_with_stone :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    roam_ground(gs, 170)
    dig_cave_pool(&gs.world, 60, 30)
    x0, x1 := 60 - CAVE_POOL_W/2, 60 + CAVE_POOL_W/2 - 1
    for y in 30 ..= 30 + CAVE_POOL_H {
        testing.expect_value(t, get_tile(&gs.world, x0 - 1, y), Tile_Type.Stone)
        testing.expect_value(t, get_tile(&gs.world, x1 + 1, y), Tile_Type.Stone)
    }
    for x in x0 ..= x1 {
        testing.expect_value(t, get_tile(&gs.world, x, 29), Tile_Type.Air)
        testing.expect_value(t, get_tile(&gs.world, x, 30), Tile_Type.Water)
        testing.expect_value(t, get_tile(&gs.world, x, 30 + CAVE_POOL_H), Tile_Type.Stone)
    }
}

// The Deep Cave's pool: on every seed, and its water stays put.
@(test)
the_deep_cave_pool_is_there_and_holds :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    count :: proc(w: ^World_Grid) -> (n: int) {
        for c in w.terrain do if c == .Water do n += 1
        return
    }
    for seed in u32(0) ..< 4 {
        gen_cave_level(&gs.world, 1, seed)
        testing.expect_value(t, count(&gs.world), CAVE_POOL_W*CAVE_POOL_H)
        gs.delta_time = 0.1
        for _ in 0 ..< 300 {
            gs.frame += 1
            update_fluid(gs)
        }
        testing.expect_value(t, count(&gs.world), CAVE_POOL_W*CAVE_POOL_H)
    }
    gen_cave_level(&gs.world, 2, 0)
    testing.expect_value(t, count(&gs.world), 0)
}

// ─── Magma Crawler (card 67) ──────────────────────────────────────────────────

// Open cave floor: the test ground with .Void for air.
crawl_cave :: proc(gs: ^Game_State, px: f32) {
    roam_ground(gs, px)
    gs.level_index = LEVEL_CAVE2
    for x in 1 ..< GRID_W - 1 do for y in 1 ..= ROAM_Y do set_tile(&gs.world, x, y, .Void)
}

@(test)
a_crawler_lights_the_floor_it_walks :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 170)
    gs.delta_time = 1.0/60
    e := roam_seed(gs, .Magma_Crawler, 60)
    e.builder.has_target = true
    e.builder.cooldown = 100
    start := int(e.pos.x)
    for _ in 0 ..< 180 do roam_step(gs, 1)
    lit := 0
    for x in 40 ..< 80 do if get_tile(&gs.world, x, ROAM_Y) == .Cinders do lit += 1
    testing.expect(t, lit >= 4, "a trail behind it")
    testing.expect_value(t, get_tile(&gs.world, start, ROAM_Y), Tile_Type.Cinders)
    testing.expect_value(t, get_tile(&gs.world, start, ROAM_Y - 1), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, start, ROAM_Y + 1), Tile_Type.Stone)
}

@(test)
only_open_floor_catches :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 170)
    e := roam_seed(gs, .Magma_Crawler, 60)
    e.builder.cooldown = 100
    e.grounded = false

    // Falling through the air: nothing under it to burn.
    e.pos.y = 30
    roam_step(gs, 1)
    testing.expect_value(t, get_tile(&gs.world, 60, 30), Tile_Type.Void)

    // Anything but open cave stays what it is.
    for tile in ([]Tile_Type{.Water, .Air, .Lava}) {
        set_tile(&gs.world, 60, ROAM_Y, tile)
        e.pos.y = f32(ROAM_Y + 1) - MAGMA_CRAWLER_H
        e.vel = {}
        roam_step(gs, 1)
        testing.expect_value(t, get_tile(&gs.world, 60, ROAM_Y), tile)
    }

    // Other roamers leave no trail.
    crawl_cave(gs, 170)
    roam_seed(gs, .Ember_Beetle, 60).builder.cooldown = 100
    roam_step(gs, 3)
    testing.expect_value(t, get_tile(&gs.world, 60, ROAM_Y), Tile_Type.Void)
}

@(test)
cinders_burn_out_on_their_clock_back_to_open_cave :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 170)
    i := grid_idx(60, ROAM_Y)
    set_tile(&gs.world, 60, ROAM_Y, .Cinders)
    gs.world.sim_data[i].growth_timer = 2   // stale clock on the cell
    e := roam_seed(gs, .Magma_Crawler, 60)
    e.builder.cooldown = 100

    // A fresh lighting starts the clock from nothing.
    set_tile(&gs.world, 60, ROAM_Y, .Void)
    roam_step(gs, 1)
    testing.expect_value(t, gs.world.sim_data[i].growth_timer, f32(0))
    gs.enemies = {}

    gs.delta_time = CINDERS_LIFE * 0.6
    update_sim(gs)
    testing.expect_value(t, get_tile(&gs.world, 60, ROAM_Y), Tile_Type.Cinders)
    update_sim(gs)
    testing.expect_value(t, get_tile(&gs.world, 60, ROAM_Y), Tile_Type.Void)
    testing.expect_value(t, gs.world.sim_data[i].growth_timer, f32(0))
}

@(test)
cinders_burn_the_player_and_name_themselves :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 100)
    set_tile(&gs.world, 100, ROAM_Y, .Cinders)
    testing.expect_value(t, hazard_cause[.Cinders], Damage_Cause.Cinders)
    testing.expect_value(t, damage_cause_names[.Cinders], "cinders")
    gs.delta_time = 1.1 / terrain_table[.Cinders].damage_per_second
    update_player(gs)
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.player.hp, gs.player.hp_max - 1)

    // They do not block a thing: nothing stands on them or runs into them.
    testing.expect(t, !is_solid(&gs.world, 100, ROAM_Y), "cinders are solid")
}

@(test)
crawlers_spawn_on_open_cave_floor_on_their_level_only :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 170)
    for y in ROAM_Y + 2 ..< GRID_H do for x in 0 ..< GRID_W do set_tile(&gs.world, x, y, .Stone)
    gs.delta_time = ROAMER_SPAWN_EVERY
    for _ in 0 ..< 60 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Magma_Crawler), roamer_table[.Magma_Crawler].cap)
    for &e, s in gs.enemies.data do if gs.enemies.active[s] && e.kind == .Magma_Crawler {
        testing.expect_value(t, builder_tile(&e).y, i32(ROAM_Y))
        testing.expect(t, abs(e.pos.y + MAGMA_CRAWLER_H - f32(ROAM_Y + 1)) < 0.01, "feet on the floor")
        testing.expect(t, abs(builder_tile(&e).x - 170) >= ROAMER_SPAWN_CLEAR, "spawned on the player")
    }

    gs.enemies = {}
    gs.level_index = LEVEL_SURFACE
    for _ in 0 ..< 40 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Magma_Crawler), 0)
}

@(test)
a_crawler_drops_coal :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 100)
    roam_seed(gs, .Magma_Crawler, 60)
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = PLAYER_ID, target = enemy_entity_id(0), payload = {int_val = 99}})
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.world.items[grid_idx(60, ROAM_Y)], Item.Coal)
    testing.expect_value(t, enemy_kind_names[.Magma_Crawler], "a magma crawler")
}

// ─── Stone Grub (card 68) ─────────────────────────────────────────────────────

GRUB_WALL :: 64   // the column it runs into

// A grub at x 62 walking right into a wall, whole column, of `tile`.
grub_wall :: proc(gs: ^Game_State, tile: Tile_Type) -> ^Enemy {
    crawl_cave(gs, 170)
    gs.world.tile_flags = {}
    for y in 1 ..= ROAM_Y do set_tile(&gs.world, GRUB_WALL, y, tile)
    e := roam_seed(gs, .Stone_Grub, 62)
    e.builder.has_target = true
    e.builder.cooldown = 1000
    gs.delta_time = 1.0/60
    return e
}

@(test)
a_grub_eats_the_wall_it_meets_one_bite_a_beat :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := grub_wall(gs, .Stone)
    frames := 0
    for get_tile(&gs.world, GRUB_WALL, ROAM_Y) == .Stone && frames < 600 {
        roam_step(gs, 1)
        frames += 1
    }
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y - 1), Tile_Type.Stone)
    testing.expect_value(t, gs.world.items[grid_idx(GRUB_WALL, ROAM_Y)], Item.None)
    testing.expect_value(t, e.facing, 1)

    // The next column is right behind it: it walks into the hole it made and
    // has to wait out the bite before it takes the next one.
    testing.expect(t, e.builder.attack_timer > STONE_GRUB_EAT_TIME - 0.1, "the bite set its clock")
    set_tile(&gs.world, GRUB_WALL + 1, ROAM_Y, .Stone)
    set_tile(&gs.world, GRUB_WALL + 1, ROAM_Y - 1, .Stone)
    start := e.pos.x
    roam_step(gs, 60)
    testing.expect(t, e.pos.x > start + 0.3, "it walks the hole it made")
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL + 1, ROAM_Y), Tile_Type.Stone)
    testing.expect_value(t, e.facing, 1)
    roam_step(gs, int(STONE_GRUB_EAT_TIME*60))
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL + 1, ROAM_Y), Tile_Type.Void)
}

@(test)
a_grub_spits_out_what_is_not_stone :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    grub_wall(gs, .Jade_Ore)
    roam_step(gs, 90)
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y), Tile_Type.Void)
    testing.expect_value(t, gs.world.items[grid_idx(GRUB_WALL, ROAM_Y)], terrain_table[.Jade_Ore].drop_item)
    testing.expect_value(t, gs.world.item_counts[grid_idx(GRUB_WALL, ROAM_Y)], u8(1))
}

// Each is a wall it walks up to and turns away from, whole.
@(test)
a_grub_leaves_what_it_may_not_eat :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    refused :: proc(t: ^testing.T, gs: ^Game_State, e: ^Enemy, tile: Tile_Type, why: string) {
        roam_step(gs, 90)
        testing.expectf(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y) == tile, "%s: eaten", why)
        testing.expectf(t, e.facing == -1, "%s: it should turn away", why)
    }

    // A player's block.
    e := grub_wall(gs, .Stone)
    gs.world.tile_flags[grid_idx(GRUB_WALL, ROAM_Y)] += {.Placed}
    refused(t, gs, e, .Stone, "placed")

    // A chest.
    e = grub_wall(gs, .Rune_Scroll_Chest_A)
    refused(t, gs, e, .Rune_Scroll_Chest_A, "chest")

    // A natural machine tile: a structure, whoever set it there.
    e = grub_wall(gs, .Smelter)
    refused(t, gs, e, .Smelter, "structure")

    // The wall of a pool.
    e = grub_wall(gs, .Stone)
    set_tile(&gs.world, GRUB_WALL + 1, ROAM_Y, .Water)
    refused(t, gs, e, .Stone, "pool wall")

    // Bedrock it cannot mine at all.
    e = grub_wall(gs, .Rune_Stone)
    refused(t, gs, e, .Rune_Stone, "unmineable")
}

@(test)
a_grub_respects_a_built_den :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := grub_wall(gs, .Iron_Ore)
    id, _ := enemy_alloc(&gs.enemies)
    b := &gs.enemies.data[id]
    b.kind, b.hp, b.hp_max = .Builder, 50, 50
    b.pos = {90, f32(ROAM_Y)}
    b.builder.build, b.builder.den_built = .Shelter, true
    // A shell slot under the wall tile: any anchor whose template reaches it.
    find: for dy in -12 ..= 12 do for dx in -12 ..= 12 {
        b.builder.anchor = {GRUB_WALL + i32(dx), ROAM_Y + i32(dy)}
        if den_structure_slot(&b.builder, {GRUB_WALL, ROAM_Y}) do break find
    }
    testing.expect(t, den_protected(gs, GRUB_WALL, ROAM_Y), "the setup is a den wall")
    roam_step(gs, 90)
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y), Tile_Type.Iron_Ore)
    testing.expect_value(t, e.facing, -1)
}

@(test)
only_a_grub_eats :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    grub_wall(gs, .Stone)
    gs.enemies = {}
    e := roam_seed(gs, .Magma_Crawler, 62)
    e.builder.has_target = true
    e.builder.cooldown = 1000
    roam_step(gs, 240)
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y), Tile_Type.Stone)
}

// While it runs from a beating or comes for the player it does not chew.
@(test)
a_hurt_grub_runs_and_does_not_chew :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := grub_wall(gs, .Stone)
    e.hp -= 1
    gs.player.pos.x = 56
    roam_step(gs, 120)
    testing.expect(t, e.pos.x > 62.5, "it ran up to the wall")
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y), Tile_Type.Stone)
}

@(test)
grubs_spawn_on_cave_floors_and_drop_stone :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 170)
    for y in ROAM_Y + 2 ..< GRID_H do for x in 0 ..< GRID_W do set_tile(&gs.world, x, y, .Stone)
    gs.delta_time = ROAMER_SPAWN_EVERY
    for _ in 0 ..< 60 {
        gs.frame += 1
        update_roamers(gs)
    }
    testing.expect_value(t, wave_count_kind(gs, .Stone_Grub), roamer_table[.Stone_Grub].cap)

    gs.enemies = {}
    gs.world.entity_map = {}
    roam_seed(gs, .Stone_Grub, 60)
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = PLAYER_ID, target = enemy_entity_id(0), payload = {int_val = 99}})
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.world.items[grid_idx(60, ROAM_Y)], Item.Stone_Block)
    testing.expect_value(t, enemy_kind_names[.Stone_Grub], "a stone grub")
}


// Nor while it hunts: an unhurt grub that sees the player up past a wall does
// not chew its way there.
@(test)
a_hunting_grub_does_not_chew :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := grub_wall(gs, .Stone)
    for y in 1 ..< ROAM_Y - 1 do set_tile(&gs.world, GRUB_WALL, y, .Void)
    // Hung high over the wall top, so the line of sight clears it even from
    // the grub's nose at the wall.
    gs.player.pos = {f32(GRUB_WALL) + 0.5 - PLAYER_W*0.5, f32(ROAM_Y - 5) + 0.5 - PLAYER_H*0.5}
    for _ in 0 ..< 300 {
        roam_step(gs, 1)
        _, dist, seen := roamer_sense(e, gs, roamer_table[.Stone_Grub].sight)
        testing.expectf(t, seen && dist > 1, "the setup: it must see the player out of reach (seen %v, dist %d)", seen, dist)
        if !seen do break
    }
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y), Tile_Type.Stone)
    testing.expect_value(t, get_tile(&gs.world, GRUB_WALL, ROAM_Y - 1), Tile_Type.Stone)
    testing.expect(t, e.pos.x > 62.5, "it came up to the wall")
}

// A tile smash_tile already drops (an unflagged door) lands once, not twice.
@(test)
a_grub_drops_a_knocked_loose_tile_once :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    grub_wall(gs, .Door)
    testing.expect(t, roamer_may_eat(gs, GRUB_WALL, ROAM_Y), "the setup: a door it may eat")
    roam_step(gs, 90)
    testing.expect(t, !is_solid(&gs.world, GRUB_WALL, ROAM_Y), "it ate the door")
    n := 0
    for i in 0 ..< len(gs.world.items) do if gs.world.items[i] == .Door do n += int(gs.world.item_counts[i])
    testing.expect_value(t, n, 1)
}

// The map's edge columns are never chewed, whatever they are made of.
@(test)
a_grub_never_chews_the_border :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    crawl_cave(gs, 100)
    gs.world.tile_flags = {}
    for x in ([]int{0, GRID_W - 1}) do for y in 1 ..= ROAM_Y do set_tile(&gs.world, x, y, .Stone)
    for side in ([]int{-1, 1}) {
        gs.enemies = {}
        e := roam_seed(gs, .Stone_Grub, 1 if side < 0 else GRID_W - 2)
        e.facing = side
        e.builder.has_target = true
        e.builder.cooldown = 1000
        e.pos.x = side < 0 ? f32(CAVE_LEFT) : f32(CAVE_RIGHT) - STONE_GRUB_W
        testing.expect(t, !roamer_eat(e, 0, gs), "chewed the border")
        roam_step(gs, 120)
    }
    testing.expect_value(t, get_tile(&gs.world, 0, ROAM_Y), Tile_Type.Stone)
    testing.expect_value(t, get_tile(&gs.world, GRID_W - 1, ROAM_Y), Tile_Type.Stone)
}
