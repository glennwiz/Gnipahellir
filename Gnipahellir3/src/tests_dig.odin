package game

import "core:strings"
import "core:testing"

// ─── Placed blocks take dig time (card 59) ────────────────────────────────────
//
//  Glenn's rule: a digger works a player-placed block before it breaks, plans
//  pay for that, and nothing is refused, so a walled base holds longer and no
//  hunter is left hammering.

// A placed block, as handle_place_request leaves it.
dig_place :: proc(gs: ^Game_State, x, y: int, tile: Tile_Type) {
    set_tile(&gs.world, x, y, tile)
    gs.world.tile_flags[grid_idx(x, y)] += {.Placed}
}

// Frames of update_enemies until (x, y) stops being a solid tile.
dig_frames_until_open :: proc(gs: ^Game_State, x, y: int, limit := 1200) -> int {
    for f in 1 ..= limit {
        gs.player.hp = 1000
        update_enemies(gs)
        process_events(gs)
        eq_clear(&gs.events)
        if !is_solid(&gs.world, x, y) do return f
    }
    return -1
}

@(test)
dig_time_reads_the_table_for_placed_blocks_only :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    set_tile(&gs.world, 60, 60, .Stone)
    testing.expect_value(t, dig_time(gs, 60, 60), f32(0))
    dig_place(gs, 61, 60, .Stone)
    testing.expect_value(t, dig_time(gs, 61, 60), dig_time_table[.Stone])
    dig_place(gs, 62, 60, .Door)
    testing.expect_value(t, dig_time(gs, 62, 60), dig_time_table[.Door])
    dig_place(gs, 63, 60, .Dirt)
    testing.expect_value(t, dig_time(gs, 63, 60), DIG_TIME_PLACED)
    set_tile(&gs.world, 64, 60, .Air)
    gs.world.tile_flags[grid_idx(64, 60)] += {.Placed}
    testing.expect_value(t, dig_time(gs, 64, 60), f32(0))
}

@(test)
a_placed_block_holds_for_its_dig_time :: proc(t: ^testing.T) {
    Row :: struct {tile: Tile_Type, placed: bool, secs: f32}
    for row in ([]Row{{.Stone, false, 0}, {.Stone, true, 4}, {.Door, true, 6}, {.Dirt, true, 1.5}}) {
        gs := turret_test_state()
        defer free(gs)
        smash_test_builder(gs)
        set_tile(&gs.world, SMASH_X, SMASH_Y, row.tile)
        if row.placed do gs.world.tile_flags[grid_idx(SMASH_X, SMASH_Y)] += {.Placed}
        frames := dig_frames_until_open(gs, SMASH_X, SMASH_Y)
        testing.expectf(t, frames >= 1 && abs(frames - int(row.secs * 60)) <= 3,
            "%v placed=%v opened in %d frames, wants %v s", row.tile, row.placed, frames, row.secs)
    }
}

@(test)
a_dig_at_a_placed_block_is_in_the_log :: proc(t: ^testing.T) {
    when !GAME_DEBUG do return
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    dig_place(gs, SMASH_X, SMASH_Y, .Door)
    builder_dig_ready(e, 0, gs, {SMASH_X, SMASH_Y})
    logged := string(gs.debug_log.buf[:gs.debug_log.pos])
    testing.expect(t, strings.contains(logged, "digs at placed Door"), "a wall under siege reads in action.log")
}

@(test)
a_climb_carve_of_a_placed_block_takes_its_dig_time :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    // Our own headroom is a placed block, the landing up and to the right open.
    roof_x := int(builder_tile(e).x)
    dig_place(gs, roof_x, SMASH_Y - 1, .Stone)
    e.nav.path = {tiles = {0 = {SMASH_X, SMASH_Y - 1}}, len = 1, cursor = 0}
    frames := dig_frames_until_open(gs, roof_x, SMASH_Y - 1)
    testing.expectf(t, abs(frames - 240) <= 3, "the carve took %d frames", frames)
}

@(test)
a_pack_is_no_faster_on_one_block :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    dig_place(gs, SMASH_X, SMASH_Y, .Stone)
    for _ in 0 ..< 5 {
        id, _ := enemy_alloc(&gs.enemies)
        gs.enemies.data[id] = e^
    }
    frames := dig_frames_until_open(gs, SMASH_X, SMASH_Y)
    testing.expectf(t, abs(frames - 240) <= 3, "six diggers took %d frames", frames)
}

@(test)
a_digger_that_changes_block_starts_the_clock_over :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    dig_place(gs, SMASH_X, SMASH_Y, .Stone)
    dig_place(gs, SMASH_X, SMASH_Y - 1, .Stone)
    e.vel.x = BUILDER_SPEED
    testing.expect(t, !builder_dig_ready(e, 0, gs, {SMASH_X, SMASH_Y}), "the first ask starts the clock")
    testing.expect_value(t, e.vel.x, f32(0))
    testing.expect(t, !builder_dig_ready(e, 0, gs, {SMASH_X, SMASH_Y - 1}), "another block is not worn")
    testing.expect(t, builder_dig_ready(e, 0, gs, {SMASH_X, SMASH_Y - 1}), "the second ask breaks it")
    testing.expect(t, !builder_dig_ready(e, 0, gs, {SMASH_X, SMASH_Y - 1}), "the clock does not stay spent")
}

// The reviewer's case: a pack on one block, staggered, and the player repairs
// the breach the moment it opens.  In both slot orders, because the sweep has to
// catch a digger that ran before the one that broke the block.
@(test)
a_repair_under_a_staggered_pack_holds_its_full_time :: proc(t: ^testing.T) {
    for late_slot in 0 ..= 1 {
        gs := turret_test_state()
        defer free(gs)
        e := smash_test_builder(gs)
        dig_place(gs, SMASH_X, SMASH_Y, .Stone)
        id, _ := enemy_alloc(&gs.enemies)
        gs.enemies.data[id] = e^
        gs.enemies.data[late_slot].nav.mine_timer = 3

        testing.expect(t, dig_frames_until_open(gs, SMASH_X, SMASH_Y) > 0, "the block breaks")
        dig_place(gs, SMASH_X, SMASH_Y, .Stone)
        frames := dig_frames_until_open(gs, SMASH_X, SMASH_Y)
        testing.expectf(t, frames >= 240, "late slot %d: the repair held %d frames", late_slot, frames)
    }
}

@(test)
a_block_the_player_mines_stops_the_clock_on_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    dig_place(gs, SMASH_X, SMASH_Y, .Stone)
    for _ in 0 ..< 60 do update_enemies(gs)
    testing.expect(t, gs.enemy_status[0].dig_tile == {SMASH_X, SMASH_Y}, "the clock is running")

    handle_tile_mined(gs, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {SMASH_X, SMASH_Y}})
    e.nav.path = {}
    update_enemies(gs)
    testing.expect(t, gs.enemy_status[0].dig_tile == {}, "the clock goes with the block")
    testing.expect(t, e.nav.mine_timer <= 0, "and the digger stops waiting on it")
}

@(test)
a_digger_that_comes_back_starts_the_clock_over :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    dig_place(gs, SMASH_X, SMASH_Y, .Stone)
    route := e.nav.path
    update_enemies(gs)
    testing.expect(t, gs.enemy_status[0].dig_tile == {SMASH_X, SMASH_Y}, "the clock is running")

    // Called off with no route for longer than the clock and the lapse.
    e.nav.path = {}
    for _ in 0 ..< 600 do update_enemies(gs)
    testing.expect(t, is_solid(&gs.world, SMASH_X, SMASH_Y), "nobody dug meanwhile")

    e.nav.path = route
    frames := dig_frames_until_open(gs, SMASH_X, SMASH_Y)
    testing.expectf(t, abs(frames - 240) <= 3, "the return took %d frames", frames)
}

@(test)
garm_goes_through_a_placed_wall_at_his_own_pace :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    e.kind = .Garm
    dig_place(gs, SMASH_X, SMASH_Y, .Stone)
    testing.expect(t, builder_dig_ready(e, 0, gs, {SMASH_X, SMASH_Y}), "no wait for the boss")
}

// ─── Plans pay for it ─────────────────────────────────────────────────────────

@(private = "file")
dig_rock :: proc(gs: ^Game_State) {
    gs.enemies = {}
    for y in 52 ..= 68 do for x in 48 ..= 72 do set_tile(&gs.world, x, y, .Quick_Clay)
}

@(private = "file")
dig_open :: proc(gs: ^Game_State, x0, x1, y0, y1: int) {
    for y in y0 ..= y1 do for x in x0 ..= x1 do set_tile(&gs.world, x, y, .Void)
}

@(private = "file")
dig_route_has :: proc(p: ^Nav_Path, T: [2]i32) -> bool {
    for i in 0 ..< p.len do if p.tiles[i] == T do return true
    return false
}

// A room with a gate in each wall, a shaft behind each gate, and one corridor
// under them both, so the two ways round are the same but for the gates.
@(private = "file")
dig_gate_room :: proc(gs: ^Game_State) {
    dig_rock(gs)
    dig_open(gs, 58, 62, 60, 60)
    dig_open(gs, 56, 56, 60, 63)
    dig_open(gs, 64, 64, 60, 63)
    dig_open(gs, 56, 64, 63, 63)
}

@(test)
a_plan_tunnels_through_the_weaker_wall :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    for strong_left in ([]bool{true, false}) {
        dig_gate_room(gs)
        dig_place(gs, 57, 60, .Stone if strong_left else .Dirt)
        dig_place(gs, 63, 60, .Dirt if strong_left else .Stone)
        route: Nav_Path
        testing.expect(t, astar_dig(gs, {60, 60}, {60, 63}, 0, 0, &route))
        weak := [2]i32{63, 60} if strong_left else {57, 60}
        testing.expectf(t, dig_route_has(&route, weak), "strong_left=%v: %v", strong_left, route.tiles[:route.len])
    }
}

@(test)
a_plan_digs_down_through_the_weaker_floor :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    for strong_left in ([]bool{true, false}) {
        dig_rock(gs)
        dig_open(gs, 58, 62, 60, 60)
        dig_place(gs, 59, 61, .Stone if strong_left else .Dirt)
        dig_place(gs, 61, 61, .Dirt if strong_left else .Stone)
        // A second natural dig under each: A* stops at the first goal it pushes,
        // so the goal has to lie past the choice.
        set_tile(&gs.world, 59, 62, .Sand)
        set_tile(&gs.world, 61, 62, .Sand)
        route: Nav_Path
        testing.expect(t, astar_dig(gs, {60, 60}, {60, 63}, 1, 0, &route))
        weak := [2]i32{61, 61} if strong_left else {59, 61}
        testing.expectf(t, dig_route_has(&route, weak), "strong_left=%v: %v", strong_left, route.tiles[:route.len])
    }
}

@(test)
a_plan_climbs_through_the_weaker_block :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    for strong_left in ([]bool{true, false}) {
        dig_rock(gs)
        dig_open(gs, 60, 60, 58, 60)
        dig_open(gs, 59, 61, 58, 58)
        dig_open(gs, 58, 58, 59, 62)   // past each landing, a drop to a shared corridor
        dig_open(gs, 62, 62, 59, 62)
        dig_open(gs, 58, 62, 62, 62)
        dig_place(gs, 59, 59, .Stone if strong_left else .Dirt)
        dig_place(gs, 61, 59, .Dirt if strong_left else .Stone)
        route: Nav_Path
        testing.expect(t, astar_dig(gs, {60, 60}, {60, 62}, 0, 0, &route))
        weak := [2]i32{61, 59} if strong_left else {59, 59}
        testing.expectf(t, dig_route_has(&route, weak), "strong_left=%v: %v", strong_left, route.tiles[:route.len])
    }
}

// The goal sits nearer the left gate, so a flat price goes left and only the
// price of a placed block sends the plan the long way.
@(test)
garm_and_golems_plan_at_the_flat_price :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    dig_gate_room(gs)
    dig_place(gs, 57, 60, .Stone)
    gs.world.tile_flags[grid_idx(57, 60)] += {.Golem_Placed}
    set_tile(&gs.world, 63, 60, .Sand)
    left, right := [2]i32{57, 60}, [2]i32{63, 60}

    route: Nav_Path
    testing.expect(t, astar_dig(gs, {60, 60}, {57, 63}, 0, 0, &route))
    testing.expect(t, dig_route_has(&route, right), "a hunter pays and goes round")
    testing.expect(t, astar_dig(gs, {60, 60}, {57, 63}, 0, MAX_NAV_PATH, &route))
    testing.expect(t, dig_route_has(&route, left), "Garm pays the flat price")
    testing.expect(t, astar_dig(gs, {60, 60}, {57, 63}, 0, 0, &route, protect_placed = true))
    testing.expect(t, dig_route_has(&route, left), "a golem pays the flat price")
}

// ─── The base holds, in the real update ───────────────────────────────────────

@(private = "file")
dig_boxed_bench :: proc(gs: ^Game_State, X, Y: int, placed: bool) {
    for y in Y - 4 ..= Y + 1 do for x in X - 4 ..= X + 4 {
        if placed do dig_place(gs, x, y, .Stone)
        else do set_tile(&gs.world, x, y, .Stone)
    }
    for y in Y - 3 ..= Y do for x in X - 3 ..= X + 3 do set_tile(&gs.world, x, y, .Air)
    set_tile(&gs.world, X, Y, .Crafting_Bench)
}

// Frames until the wave takes the bench, and the longest any one wolf spent on
// one dig clock, which is the card's no-hammering check.
@(private = "file")
dig_siege :: proc(gs: ^Game_State, X, Y: int, placed: bool) -> (frames: int, longest: int, most_searches: int) {
    wave_clear_structures(gs)
    gs.player.pos = {8, 8}
    dig_boxed_bench(gs, X, Y, placed)
    gs.wave.structures_indexed = false
    wave_force(gs, .Ground, wave_table[.Ground].count)
    held: [MAX_ENEMIES]int
    last: [MAX_ENEMIES][2]i32
    for f in 1 ..= 300 * 60 {
        gs.player.hp = 1000
        update_enemies(gs)
        most_searches = max(most_searches, gs.nav_searches)
        for i in 0 ..< MAX_ENEMIES {
            T := gs.enemy_status[i].dig_tile
            held[i] = held[i] + 1 if T != {} && T == last[i] else 0
            last[i] = T
            longest = max(longest, held[i])
        }
        process_events(gs)
        eq_clear(&gs.events)
        if get_tile(&gs.world, X, Y) != .Crafting_Bench do return f, longest, most_searches
    }
    return -1, longest, most_searches
}

@(test)
a_walled_base_holds_longer_than_a_bare_one :: proc(t: ^testing.T) {
    X, Y := 90, SURFACE_Y - 2

    bare := turret_test_state()
    defer free(bare)
    bare_frames, _, _ := dig_siege(bare, X, Y, false)
    walled := turret_test_state()
    defer free(walled)
    walled_frames, longest, searches := dig_siege(walled, X, Y, true)

    testing.expect(t, bare_frames > 0, "the wave reaches a box of natural stone")
    testing.expect(t, walled_frames > 0, "a wall slows a wave, it does not stop one")
    testing.expectf(t, walled_frames >= bare_frames + int(dig_time_table[.Stone] * 60),
        "walled %d frames against bare %d", walled_frames, bare_frames)
    // A second's slack: a wolf whose route ran out waits its turn at the search
    // budget before it swings.
    testing.expectf(t, longest <= int(dig_time_table[.Stone] * 60) + 60, "a wolf held one clock %d frames", longest)
    testing.expect(t, searches <= MAX_NAV_SEARCHES_PER_FRAME, "the wall stays inside the search budget")
}

@(test)
a_large_wave_at_a_placed_wall_stays_inside_the_frame :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    wave_clear_structures(gs)
    gs.player.pos = {8, 8}
    dig_boxed_bench(gs, 90, SURFACE_Y - 2, true)
    gs.wave.structures_indexed = false
    wave_force(gs, .Ground, 60)
    most := 0
    for _ in 0 ..< 30 * 60 {
        gs.player.hp = 1000
        update_enemies(gs)
        most = max(most, gs.nav_searches)
        process_events(gs)
        eq_clear(&gs.events)
    }
    testing.expect_value(t, most, MAX_NAV_SEARCHES_PER_FRAME)
}
