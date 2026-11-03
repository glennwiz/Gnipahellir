package game

import "core:math"
import "core:testing"

// A fresh sky with the player far from every lane, so nothing scatters yet.
@(private = "file")
sky_state :: proc() -> ^Game_State {
    gs := turret_test_state()
    gs.level_index = LEVEL_SKY
    gen_sky_level(&gs.world, gs.world_seed)
    gs.ui.show_title = false
    gs.player.pos = {96, 200}
    gs.delta_time = 1.0 / 60.0
    return gs
}

@(private = "file")
tick :: proc(gs: ^Game_State, n := 1) {
    for _ in 0 ..< n do update_birds(gs)
}

@(private = "file")
spread :: proc(f: ^Bird_Flock) -> (far: f32) {
    for b in f.birds {
        d := b.pos - f.birds[0].pos
        far = max(far, math.sqrt(d.x * d.x + d.y * d.y))
    }
    return
}

@(test)
birds_fly_only_in_the_sky :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    testing.expect(t, gs.birds.seeded, "the sky seeds its flocks")
    gs.level_index = LEVEL_SURFACE
    tick(gs)
    testing.expect(t, !gs.birds.seeded, "leaving drops them")
    testing.expect_value(t, gs.birds.flocks[0].center.y, 0)
}

@(test)
birds_are_stepped_by_game_update :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    gs.player.pos = {96, 78}
    game_update(gs)
    testing.expect(t, gs.birds.seeded, "game_update runs the birds")
}

@(test)
flocks_hold_their_lanes_clear_of_every_cloud :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    for seed in u32(0) ..< 40 {
        gs.world_seed = seed
        gen_sky_level(&gs.world, seed)
        gs.birds = {}
        tick(gs)
        seen: [MAX_BIRD_FLOCKS]f32
        for fi in 0 ..< MAX_BIRD_FLOCKS {
            f := &gs.birds.flocks[fi]
            seen[fi] = f.center.y
            for other in 0 ..< fi do testing.expect(t, seen[other] != f.center.y, "one flock a lane")
            testing.expect(t, abs(f.heading) == 1, "a flock has a heading")
            testing.expect(t, f.center.x > -1 && f.center.x < GRID_W + 1, "starts in the level")
            for b in f.birds {
                if !in_bounds(int(b.pos.x), int(b.pos.y)) do continue // just past the side edge
                x := int(b.pos.x)
                tile := get_tile(&gs.world, x, int(b.pos.y))
                if tile == .Rainbow_Bridge do continue // crossed on purpose
                on_a_foot := abs(x - RAINBOW_CENTER_X) >= RAINBOW_HALF_SPAN
                if on_a_foot && int(b.pos.y) >= RAINBOW_FOOT_Y do continue // and its islands
                testing.expect_value(t, tile, Tile_Type.Air)
            }
        }
    }
}

@(test)
a_new_flock_starts_in_formation :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    for fi in 0 ..< MAX_BIRD_FLOCKS {
        f := &gs.birds.flocks[fi]
        for j in 0 ..< BIRDS_PER_FLOCK {
            d := bird_slot(f, j, gs.elapsed_time) - f.birds[j].pos
            testing.expect(t, abs(d.x) < 0.2 && abs(d.y) < 0.2, "each bird at its slot")
            testing.expect(t, abs(f.birds[j].pos.y - f.center.y) < 3, "in its flock's lane")
        }
    }
}

// The radius runs from the middle of the body, not the corner pos names.
@(test)
scatter_range_is_measured_from_the_players_centre :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    spot := [2]f32{90, 46}
    half := [2]f32{PLAYER_W, PLAYER_H} * 0.5

    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = spot}
    gs.player.pos = spot + {BIRD_SCATTER_RADIUS - 0.1, 0} - half
    tick(gs)
    testing.expect(t, f.scatter_t > 0, "centre inside the radius, corner outside")

    f.scatter_t = 0
    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = spot}
    gs.player.pos = spot + {BIRD_SCATTER_RADIUS + 0.1, 0} - half
    tick(gs)
    testing.expect_value(t, f.scatter_t, 0)
}

@(test)
worlds_vary_where_flocks_fly :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    east, west, phases, places := 0, 0, 0, 0
    for seed in u32(0) ..< 40 {
        gs.world_seed = seed
        gs.birds = {}
        birds_seed(gs)
        a, b := gs.birds.flocks[0], gs.birds.flocks[1]
        if a.heading > 0 do east += 1
        if a.heading < 0 do west += 1
        if a.phase != b.phase do phases += 1
        if a.center.x != b.center.x do places += 1
    }
    testing.expect(t, east > 0 && west > 0, "flocks fly both ways")
    testing.expect(t, phases > 30, "flocks beat out of step")
    testing.expect(t, places > 30, "flocks start apart")
}

@(test)
a_flock_bobs_as_it_flies :: proc(t: ^testing.T) {
    f := Bird_Flock{center = {90, 46}, heading = 1}
    a := bird_slot(&f, 0, 0).y
    testing.expect(t, bird_slot(&f, 0, 1).y != a, "with time")
    f.phase = 1
    testing.expect(t, bird_slot(&f, 0, 0).y != a, "out of step with other flocks")
    f.phase = 0
    for j in 0 ..< BIRDS_PER_FLOCK do for tt in 0 ..< 60 {
        y := bird_slot(&f, j, f32(tt) * 0.2).y
        testing.expect(t, y > 43 && y < 49, "inside the lane")
    }
}

@(test)
a_flock_cruises_in_a_tight_v :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    f.center.x, f.heading = 90, 1
    wing := bird_slot(f, 1, 0)
    testing.expect(t, wing.x < f.center.x, "wings trail an eastbound leader")
    f.heading = -1
    testing.expect(t, bird_slot(f, 1, 0).x > f.center.x, "and a westbound one")
    f.phase = 0
    a, b := bird_slot(f, 1, 0), bird_slot(f, 2, 0)
    testing.expect(t, abs(a.y - b.y) > 1 && abs(a.x - b.x) < 0.001, "one rank, either side")
    testing.expect(t, bird_slot(f, 3, 0).x > a.x, "the next rank sits further back")

    f.center.x, f.heading = 90, 1
    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = bird_slot(f, j, gs.elapsed_time)}
    before := f.center.x
    tick(gs, 60)
    testing.expect(t, abs(f.center.x - before - BIRD_CRUISE_SPEED) < 0.1, "a second of cruise")
    testing.expect(t, spread(f) < 8, "the V holds")
    testing.expect_value(t, f.scatter_t, 0)
    for j in 0 ..< BIRDS_PER_FLOCK {
        d := bird_slot(f, j, gs.elapsed_time) - f.birds[j].pos
        testing.expect(t, abs(d.x) < 2 && abs(d.y) < 2, "each bird keeps its slot")
    }
}

@(test)
the_player_coming_close_scatters_a_flock_and_no_other :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f, other := &gs.birds.flocks[0], &gs.birds.flocks[1]
    gs.player.pos = f.birds[3].pos + {BIRD_SCATTER_RADIUS - 2, 0} - {PLAYER_W, PLAYER_H} * 0.5
    other.center = {f.center.x + 100, 100}
    for j in 0 ..< BIRDS_PER_FLOCK do other.birds[j] = {pos = other.center}
    tick(gs)
    testing.expect(t, f.scatter_t > 0, "close by, it scatters")
    testing.expect_value(t, other.scatter_t, 0)
    burst := f.birds[0].vel
    gs.frame += 1
    tick(gs)
    v := f.birds[0].vel
    testing.expect(t, v.x * v.x + v.y * v.y < burst.x * burst.x + burst.y * burst.y, "one burst, not one a frame")
    player := gs.player.pos + {PLAYER_W, PLAYER_H} * 0.5
    was: [BIRDS_PER_FLOCK]f32
    for j in 0 ..< BIRDS_PER_FLOCK {
        d := f.birds[j].pos - player
        was[j] = math.sqrt(d.x * d.x + d.y * d.y)
    }
    tick(gs, 30)
    for j in 0 ..< BIRDS_PER_FLOCK {
        d := f.birds[j].pos - player
        testing.expect(t, math.sqrt(d.x * d.x + d.y * d.y) > was[j] + 1, "every bird gets clear")
    }
}

@(test)
a_flock_outside_the_radius_keeps_cruising :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    gs.player.pos = {f.birds[0].pos.x, f.birds[0].pos.y + BIRD_SCATTER_RADIUS * 3}
    tick(gs)
    testing.expect_value(t, f.scatter_t, 0)
}

@(test)
every_bird_flies_away_from_the_player_and_the_flock_turns :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    f.center, f.heading = {90, 46}, -1
    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = f.center + {f32(j) * 0.1, 0}}
    from := [2]f32{85, 46}
    bird_flock_scatter(gs, f, from)
    testing.expect_value(t, f.heading, 1)
    testing.expect_value(t, f.scatter_t, BIRD_SCATTER_TIME)
    apart := false
    for j in 0 ..< BIRDS_PER_FLOCK {
        b := f.birds[j]
        testing.expect(t, b.vel.x > 0, "away from the player")
        speed := math.sqrt(b.vel.x * b.vel.x + b.vel.y * b.vel.y)
        want := BIRD_SCATTER_SPEED + f32(j % 3) * BIRD_SCATTER_SPEED_STEP
        testing.expect(t, abs(speed - want) < 0.01, "at its burst speed")
        if b.vel.y / b.vel.x != f.birds[0].vel.y / f.birds[0].vel.x do apart = true
    }
    testing.expect(t, apart, "each on its own line")

    // Another scatter, another fan.
    first := f.birds[1].vel
    gs.frame += 1
    bird_flock_scatter(gs, f, from)
    testing.expect(t, f.birds[1].vel != first, "scatters differ")

    f.heading = 1
    bird_flock_scatter(gs, f, {95, 46})
    testing.expect_value(t, f.heading, -1)
}

@(test)
a_scattered_flock_flees_then_re_forms :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    f.center, f.heading = {90, 46}, 1
    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = bird_slot(f, j, gs.elapsed_time)}
    bird_flock_scatter(gs, f, {88, 46})
    start := f.center.x
    burst := f.birds[0].vel
    tick(gs)
    testing.expect(t, abs(f.center.x - start - BIRD_FLEE_SPEED / 60) < 0.001, "the point flees fast")
    v := f.birds[0].vel
    testing.expect(t, v.x * v.x + v.y * v.y < burst.x * burst.x + burst.y * burst.y, "the burst tires")

    tick(gs, 60 * 3)
    testing.expect_value(t, f.scatter_t, 0)
    tick(gs, 60 * 3)
    testing.expect(t, spread(f) < 8, "back in formation")
    for j in 0 ..< BIRDS_PER_FLOCK {
        d := bird_slot(f, j, gs.elapsed_time) - f.birds[j].pos
        testing.expect(t, abs(d.x) < 2 && abs(d.y) < 2, "each bird found its slot")
    }
}

@(test)
a_flock_past_the_edge_comes_round_the_other_side_with_its_birds :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    f.heading = 1
    f.center.x = f32(GRID_W) + BIRD_WRAP_MARGIN + 0.01
    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = bird_slot(f, j, gs.elapsed_time)}
    tick(gs)
    testing.expect(t, f.center.x < 0, "east edge to west")
    testing.expect(t, f.birds[0].pos.x < 0, "the birds came too")

    f.heading = -1
    f.center.x = -BIRD_WRAP_MARGIN - 0.01
    for j in 0 ..< BIRDS_PER_FLOCK do f.birds[j] = {pos = bird_slot(f, j, gs.elapsed_time)}
    tick(gs)
    testing.expect(t, f.center.x > GRID_W, "west edge to east")
    testing.expect(t, f.birds[0].pos.x > GRID_W, "the birds came too")
}

@(test)
scattered_birds_beat_their_wings_harder :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    f := &gs.birds.flocks[0]
    f.phase = 0
    testing.expect_value(t, bird_wing_lift(f, 0, 0.1), math.sin(f32(0.1) * BIRD_FLAP_SPEED) * BIRD_WING_LIFT)
    f.scatter_t = 1
    testing.expect_value(t, bird_wing_lift(f, 0, 0.1), math.sin(f32(0.1) * BIRD_FLAP_SPEED_SPOOKED) * BIRD_WING_LIFT)
    testing.expect(t, bird_wing_lift(f, 0, 0.1) != bird_wing_lift(f, 1, 0.1), "birds flap out of step")
}

// Harmless, no drops, no wave load: a player flown through every flock for
// half a minute changes nothing but the birds.
@(test)
birds_touch_nothing_but_themselves :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    tick(gs)
    gs.flight_t = 0
    hp, enemies, threat := gs.player.hp, gs.enemies.count, gs.wave.pressure
    rng, world := gs.loot_rng, new_clone(gs.world)
    defer free(world)
    for frame in 0 ..< 1800 {
        f := &gs.birds.flocks[frame % MAX_BIRD_FLOCKS]
        gs.player.pos = f.birds[0].pos
        gs.frame += 1
        gs.elapsed_time += gs.delta_time
        update_birds(gs)
        testing.expect_value(t, gs.events.size, 0)
    }
    testing.expect_value(t, gs.player.hp, hp)
    testing.expect_value(t, gs.enemies.count, enemies)
    testing.expect_value(t, gs.wave.pressure, threat)
    testing.expect_value(t, gs.loot_rng, rng)
    testing.expect(t, gs.world == world^, "no drops, no tiles")
}

// Same world, same flocks; birds never reach the save.
@(test)
a_world_seed_lays_out_the_same_flocks :: proc(t: ^testing.T) {
    gs := sky_state()
    defer free(gs)
    gs.world_seed = 5
    tick(gs)
    first := gs.birds
    gs.birds = {}
    tick(gs)
    testing.expect(t, first == gs.birds, "deterministic")
    gs.world_seed = 6
    gs.birds = {}
    tick(gs)
    testing.expect(t, first != gs.birds, "another world, other flocks")
}
