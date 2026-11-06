package game

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"
import "core:time"

// The frame's search budgets, counted in work rather than wall time: a clock on
// this box measures its load.  Work is the same in every build, so these tests
// bound the frame at -o:speed too.  Wall times are logged for a reader only.

NAV_TEST_FRAMES :: 300
// Measured: p99 96k (Vargr), 76k (mixed); worst frame seen 163k.  A full
// search is about 37.7k (113k = 3 enemy searches), so five are about 188k.
NAV_WORK_P99_BUDGET :: 110_000
#assert(NAV_FRAME_WORK < NAV_WORK_P99_BUDGET)  // the hero's plan fills a frame to NAV_FRAME_WORK (card 203)

@(private="file")
nav_state :: proc() -> ^Game_State {
    gs := new(Game_State)
    game_state_init(gs)
    gs.delta_time = 1.0 / 60.0
    gs.ui.show_title = false   // the title screen freezes the sim
    return gs
}

@(private="file")
nav_fill :: proc(gs: ^Game_State, mixed: bool) {
    gs.enemies = {}
    gs.player.hp = 1 << 30
    gs.player.hp_max = 1 << 30
    for i in 0 ..< MAX_ENEMIES {
        x := 8 + (i * 7) % (GRID_W - 16)
        y := 5 + (i * 3) % (SURFACE_Y - 8)
        kind: Enemy_Kind = .Fire_Sprite if mixed && i % 2 == 1 else .Vargr
        wave_seed_hunter(gs, kind, x, y)
    }
}

// Every worker on the crew, sent to a vein sealed in player masonry it may
// not dig: no route ever completes, so the crew asks for routes every frame.
@(private="file")
nav_crew :: proc(gs: ^Game_State) {
    for y in 70 ..= 78 do for x in 90 ..= 100 {
        set_tile(&gs.world, x, y, .Stone)
        if x == 90 || x == 100 || y == 70 || y == 78 do gs.world.tile_flags[grid_idx(x, y)] += {.Placed}
    }
    gs.golems.work[gs.level_index] = {active = true, min = {91, 71}, max = {99, 77}}
    for i in 0 ..< MAX_GOLEMS {
        gs.golems.data[i] = {status = .Deployed, level = gs.level_index, hp = GOLEM_HP, mode = .Gather,
            pos = {f32(20 + i * 10), f32(SURFACE_Y) - GOLEM_H}, project_cell = -1}
    }
    // Three of them walled into masonry cells: their searches fail at once,
    // every one, so some worker always wants the frame's searches.
    for i in 0 ..< 3 {
        x, y := 40 + i * 50, 64   // above the vein: lower, a worker climbs instead of searching
        for cy in y - 3 ..= y + 1 do for cx in x - 1 ..= x + 1 {
            set_tile(&gs.world, cx, cy, .Stone)
            gs.world.tile_flags[grid_idx(cx, cy)] += {.Placed}
        }
        for cy in y - 2 ..= y do set_tile(&gs.world, x, cy, .Air)
        gs.golems.data[i * 5].pos = {f32(x) + (1 - GOLEM_W) * 0.5, f32(y + 1) - GOLEM_H}
    }
}

@(private="file")
nav_frames :: proc(t: ^testing.T, gs: ^Game_State, name: string, loc := #caller_location) {
    work, ns: [NAV_TEST_FRAMES]i64
    capped := 0
    for f in 0 ..< NAV_TEST_FRAMES {
        start := time.tick_now()
        game_update(gs)
        ns[f] = i64(time.tick_since(start))
        work[f] = i64(gs.nav_work)
        testing.expect(t, gs.nav_searches <= MAX_NAV_SEARCHES_PER_FRAME, "the enemy budget holds", loc = loc)
        testing.expect(t, gs.golem_searches <= MAX_GOLEM_SEARCHES_PER_FRAME, "the golem budget holds", loc = loc)
        if gs.golem_searches == MAX_GOLEM_SEARCHES_PER_FRAME do capped += 1
    }
    slice.sort(work[:])
    slice.sort(ns[:])
    p99, top := work[NAV_TEST_FRAMES * 99 / 100], work[NAV_TEST_FRAMES - 1]
    log.infof("nav work %s: golems at their cap %d of %d frames", name, capped, NAV_TEST_FRAMES)
    log.infof("nav work %s: p50 %d, p99 %d, max %d; wall p50 %.2f ms, p99 %.2f ms", name,
        work[NAV_TEST_FRAMES / 2], p99, top, f64(ns[NAV_TEST_FRAMES / 2]) / 1e6, f64(ns[NAV_TEST_FRAMES * 99 / 100]) / 1e6)
    testing.expect(t, top > 0, "the swarm searched", loc = loc)
    testing.expect(t, p99 <= NAV_WORK_P99_BUDGET, "p99 frame stays in the work budget", loc = loc)
    testing.expect(t, capped >= NAV_TEST_FRAMES * 9 / 10, "the crew spends its searches", loc = loc)
}

@(test)
a_full_frame_at_the_cap_stays_in_budget :: proc(t: ^testing.T) {
    for mixed in ([2]bool{false, true}) {
        gs := nav_state()
        defer free(gs)
        nav_fill(gs, mixed)
        nav_crew(gs)
        nav_frames(t, gs, "mixed" if mixed else "vargr")
    }
}

@(test)
the_open_set_pops_lowest_f_then_oldest :: proc(t: ^testing.T) {
    open: [MAX_ASTAR_NODES]A_Open
    size, work: int
    seed := u32(1)
    for i in 0 ..< MAX_ASTAR_NODES {
        seed = seed * 1664525 + 1013904223
        astar_open_push(open[:], &size, {f = f32(seed >> 24), node = i16(i)}, &work)
    }
    pushed := work
    testing.expect(t, pushed >= MAX_ASTAR_NODES, "a push counts its sift")
    prev := astar_open_pop(open[:], &size, &work)
    for size > 0 {
        next := astar_open_pop(open[:], &size, &work)
        testing.expect(t, prev.f < next.f || (prev.f == next.f && prev.node < next.node), "lowest f, then oldest")
        prev = next
    }
    testing.expect(t, work - pushed >= 8 * MAX_ASTAR_NODES, "a pop counts its sift")
    // log2(4096) = 12 levels: a linear scan would be thousands per pop.
    testing.expect(t, work <= 2 * 12 * MAX_ASTAR_NODES, "heap work stays logarithmic")
}

@(test)
an_open_tie_goes_to_the_older_node_whatever_the_push_order :: proc(t: ^testing.T) {
    open: [4]A_Open
    size, work: int
    astar_open_push(open[:], &size, {f = 5, node = 2}, &work)
    astar_open_push(open[:], &size, {f = 5, node = 1}, &work)
    testing.expect_value(t, astar_open_pop(open[:], &size, &work).node, i16(1))
}

@(test)
a_search_counts_each_node_it_expands :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    // A corridor one tile high: no jumps, one open node at a time, no sifts.
    for x in 20 ..= 40 {
        set_tile(&gs.world, x, 50, .Stone)
        set_tile(&gs.world, x, 51, .Air)
        set_tile(&gs.world, x, 52, .Stone)
    }
    set_tile(&gs.world, 20, 51, .Stone)   // and a dead end: one way to go
    path: Nav_Path
    gs.nav_work = 0
    testing.expect(t, astar_dig(gs, {21, 51}, {29, 51}, 0, 0, &path, allow_mining = false), "the corridor has a route")
    testing.expect_value(t, gs.nav_work, 8)
}

@(test)
a_search_heads_for_its_goal :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    // The same corridor, open both ways: the heuristic must spend nothing on
    // the wrong direction, or the search floods out behind the start.
    for x in 20 ..= 80 {
        set_tile(&gs.world, x, 50, .Stone)
        set_tile(&gs.world, x, 51, .Air)
        set_tile(&gs.world, x, 52, .Stone)
    }
    path: Nav_Path
    gs.nav_work = 0
    testing.expect(t, astar_dig(gs, {50, 51}, {70, 51}, 0, 0, &path, allow_mining = false), "the corridor has a route")
    testing.expect(t, gs.nav_work <= 45, "the search goes one way")
    log.infof("corridor work %d", gs.nav_work)
}

@(test)
a_search_weighs_the_cost_of_its_route :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    for y in 44 ..= 57 do for x in 20 ..= 40 do set_tile(&gs.world, x, y, .Air)
    for x in 20 ..= 40 do set_tile(&gs.world, x, 58, .Stone)
    // The goal is straight below a short slab.  Digging closes on it at every
    // step; stepping off the edge moves away first and costs a sixth as much.
    for y in 51 ..= 52 do for x in 28 ..= 32 do set_tile(&gs.world, x, y, .Stone)
    path: Nav_Path
    testing.expect(t, astar_dig(gs, {30, 50}, {30, 57}, 0, 0, &path), "there is a route")
    for i in 0 ..< path.len {
        T := path.tiles[i]
        testing.expect(t, !is_solid(&gs.world, int(T.x), int(T.y)), "the route goes round, not through")
    }
}

// A pocket: open room 12..=26 on floor 60, a protected wall at x=21 no route
// crosses.  The worker stands at x=20 with empty hands.
@(private="file")
nav_pocket :: proc(gs: ^Game_State) -> ^Golem {
    for y in 55 ..= 59 do for x in 12 ..= 26 do set_tile(&gs.world, x, y, .Air)
    for x in 12 ..= 26 do set_tile(&gs.world, x, 60, .Stone)
    for y in 0 ..< GRID_H {
        set_tile(&gs.world, 21, y, .Stone)
        gs.world.tile_flags[grid_idx(21, y)] += {.Placed}
    }
    g := &gs.golems.data[0]
    g^ = {status = .Deployed, level = gs.level_index, pos = {20.2, 60 - GOLEM_H}, hp = GOLEM_HP,
        mode = .Gather, grounded = true, project_cell = -1}
    return g
}

@(test)
an_interrupted_assignment_resumes_at_its_next_choice :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    // More unreachable choices, all nearer, than one frame may search.
    for x in 22 ..= 25 do set_tile(&gs.world, x, 59, .Stone)
    set_tile(&gs.world, 13, 59, .Stone)
    gs.golems.work[gs.level_index] = {active = true, min = {13, 59}, max = {25, 59}}

    update_golems(gs)
    testing.expect(t, !g.has_target, "one frame cannot get past the unreachable choices")
    testing.expect_value(t, gs.golem_searches, MAX_GOLEM_SEARCHES_PER_FRAME)
    for _ in 0 ..< 4 do if !g.has_target do update_golems(gs)
    testing.expect(t, g.has_target, "the worker reaches the far choice")
    testing.expect_value(t, g.target, [2]i32{13, 59})
    testing.expect_value(t, gs.golem_skips[0].n, 0)
}

@(test)
a_spent_frame_does_not_ship_a_part_load :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    set_tile(&gs.world, 15, 59, .Stone)
    gs.golems.work[gs.level_index] = {active = true, min = {15, 59}, max = {15, 59}}
    _ = golem_pack_add(g, .Stone_Block)
    _ = golem_pack_add(g, .Stone_Block)
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    golem_update_one(gs, 0)
    testing.expect_value(t, g.carry, Item.None)
    testing.expect_value(t, golem_pack_count(g), 2)
    testing.expect(t, g.job != .Deliver, "still gathering")
    update_golems(gs)
    testing.expect_value(t, g.target, [2]i32{15, 59})
    testing.expect_value(t, g.job, Golem_Job.Mine)
}

// A worker at a barrel with a full load, a resource in the zone to tempt it.
@(private="file")
nav_unloader :: proc(gs: ^Game_State, id: int) -> (^Golem, ^Barrel_State) {
    g := nav_pocket(gs)
    u := &gs.golems.data[id]
    if id != 0 do u^ = g^
    store := [2]i32{19, 59}
    set_tile(&gs.world, int(store.x), int(store.y), .Barrel)
    barrel_on_placed(gs, store)
    u.job = .Deliver
    u.carry = .Stone_Block
    u.target = store
    u.has_target = true
    for _ in 0 ..< GOLEM_PACK_CAP - 1 do _ = golem_pack_add(u, .Stone_Block)
    return u, barrel_at(gs, gs.level_index, store)
}

@(test)
a_spent_frame_holds_an_unload_at_the_door :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g, b := nav_unloader(gs, 0)
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    g.vel.x = 1
    golem_update_one(gs, 0)
    testing.expect_value(t, g.vel.x, f32(0))
    testing.expect_value(t, barrel_total(b), 0)
    testing.expect_value(t, g.job, Golem_Job.Deliver)
    testing.expect_value(t, g.carry, Item.Stone_Block)
    testing.expect(t, g.has_target, "still bound for the barrel")
}

@(test)
a_crew_short_of_searches_still_unloads_in_full :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    u, b := nav_unloader(gs, 1)
    for x in 13 ..= 15 do set_tile(&gs.world, x, 59, .Stone)
    gs.golems.work[gs.level_index] = {active = true, min = {13, 59}, max = {15, 59}}
    // Slots 14 and 0 run first and spend the frame on searches of their own.
    gs.golems.data[14] = {status = .Deployed, level = gs.level_index, pos = {20.2, 60 - GOLEM_H}, hp = GOLEM_HP,
        mode = .Gather, grounded = true, project_cell = -1}
    gs.frame = 14
    for _ in 0 ..< GOLEM_PACK_CAP + 4 {
        update_golems(gs)
        gs.frame += 1
        testing.expect(t, u.job != .Mine || golem_pack_count(u) == 0, "no worker leaves storage loaded")
        if u.carry == .None && golem_pack_count(u) == 0 do break
    }
    testing.expect_value(t, barrel_total(b), GOLEM_PACK_CAP)
}

@(test)
a_full_list_of_choices_on_a_spent_frame_still_delivers :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    set_tile(&gs.world, 19, 59, .Barrel)
    barrel_on_placed(gs, {19, 59})
    _ = golem_pack_add(g, .Stone_Block)
    skips := &gs.golem_skips[0]
    skips.n = len(skips.tiles)
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    golem_update_one(gs, 0)
    testing.expect_value(t, skips.n, len(skips.tiles))   // the round ends on a frame that can act on it
    update_golems(gs)
    testing.expect_value(t, skips.n, 0)
    testing.expect_value(t, barrel_total(barrel_at(gs, gs.level_index, {19, 59})), 1)   // the load went home
}

@(test)
a_called_worker_stands_still_on_a_spent_frame :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    gs.golem_calls[0] = .Come
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    g.vel.x = 3
    golem_update_one(gs, 0)
    testing.expect_value(t, g.vel.x, f32(0))
}

@(test)
an_idle_worker_stands_still_on_a_spent_frame :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    g.vel.x = 3
    golem_update_one(gs, 0)
    testing.expect_value(t, g.vel.x, f32(0))
}

@(test)
a_finished_round_of_choices_starts_over :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    nav_pocket(gs)
    for x in 22 ..= 23 do set_tile(&gs.world, x, 59, .Stone)
    gs.golems.work[gs.level_index] = {active = true, min = {22, 59}, max = {23, 59}}
    update_golems(gs)
    testing.expect_value(t, gs.golem_skips[0].n, 2)
    update_golems(gs)
    testing.expect_value(t, gs.golem_skips[0].n, 0)
}

@(test)
a_spent_frame_leaves_the_cargo_in_hand :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    set_tile(&gs.world, 15, 59, .Barrel)
    barrel_on_placed(gs, {15, 59})
    g.carry = .Stone_Block
    testing.expect(t, !golem_start_delivery(gs, g), "no search this frame")
    testing.expect_value(t, g.carry, Item.Stone_Block)
    testing.expect_value(t, gs.golem_searches, MAX_GOLEM_SEARCHES_PER_FRAME)
}

@(test)
a_last_search_on_a_failed_deposit_leaves_the_cargo_in_hand :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    set_tile(&gs.world, 24, 59, .Barrel)
    barrel_on_placed(gs, {24, 59})
    g.carry = .Stone_Block
    for golem_pack_add(g, .Stone_Block) {}
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME - 1
    testing.expect(t, !golem_start_delivery(gs, g), "the deposit is behind the wall")
    testing.expect_value(t, gs.golem_searches, MAX_GOLEM_SEARCHES_PER_FRAME)
    testing.expect_value(t, g.carry, Item.Stone_Block)
}

@(test)
the_first_search_of_a_frame_goes_round_the_crew :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    a, b := &gs.golems.data[1], &gs.golems.data[14]
    a^, b^ = g^, g^
    for x in 13 ..= 15 do set_tile(&gs.world, x, 59, .Stone)
    gs.golems.work[gs.level_index] = {active = true, min = {13, 59}, max = {15, 59}}
    gs.frame = 14   // slot 14, then 0, then 1
    update_golems(gs)
    testing.expect(t, b.has_target, "this frame's first worker searched")
    testing.expect(t, g.has_target, "and the next")
    testing.expect(t, !a.has_target, "the frame's searches are gone")
    gs.frame += 1
    update_golems(gs)
    testing.expect(t, a.has_target, "the last worker gets the next frame")
}

// A worker with a target, about to replan, on a frame with no searches left.
@(private="file")
nav_spent_worker :: proc(gs: ^Game_State) -> ^Golem {
    g := nav_pocket(gs)
    g.job = .Mine
    g.target = {13, 59}
    g.has_target = true
    gs.golem_searches = MAX_GOLEM_SEARCHES_PER_FRAME
    return g
}

@(private="file")
nav_expect_waits :: proc(t: ^testing.T, gs: ^Game_State, g: ^Golem, loc := #caller_location) {
    golem_update_one(gs, 0)
    testing.expect_value(t, gs.golem_searches, MAX_GOLEM_SEARCHES_PER_FRAME, loc = loc)
    testing.expect(t, g.has_target, "the target survives a spent frame", loc = loc)
}

@(test)
a_spent_frame_defers_a_finished_route :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_spent_worker(gs)
    nav_expect_waits(t, gs, g)
}

@(test)
a_spent_frame_defers_the_stall_watchdog :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_spent_worker(gs)
    g.replan_timer = GOLEM_STUCK_TIME
    nav_expect_waits(t, gs, g)
    testing.expect(t, g.replan_timer >= GOLEM_STUCK_TIME, "still due next frame")
}

@(test)
a_spent_frame_defers_a_stale_route :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_spent_worker(gs)
    g.path = {len = 1}
    g.path.tiles[0] = {14, 59}
    nav_expect_waits(t, gs, g)
}

@(test)
a_spent_frame_defers_an_obstructed_route :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_spent_worker(gs)
    // Protected masonry on the next waypoint: the worker cannot clear it.
    set_tile(&gs.world, 19, 59, .Stone)
    gs.world.tile_flags[grid_idx(19, 59)] += {.Placed}
    g.path = {len = 1}
    g.path.tiles[0] = {19, 59}
    nav_expect_waits(t, gs, g)
}

@(test)
a_spent_frame_defers_a_build_cell :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_spent_worker(gs)
    g.has_target = false
    g.mode = .Build
    cell := golem_plan_table[.Clay_Hearth].cells[0]
    gs.golems.projects[g.level] = {active = true, plan = .Clay_Hearth, anchor = {15, 58}}
    g.project_cell = 0
    g.carry = cell.item
    golem_update_one(gs, 0)
    testing.expect_value(t, gs.golem_searches, MAX_GOLEM_SEARCHES_PER_FRAME)
}

@(test)
a_spent_frame_does_not_call_a_worker_lost :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    g := nav_spent_worker(gs)
    g.has_target = false
    gs.golem_calls[0] = .Come
    golem_update_one(gs, 0)
    testing.expect_value(t, gs.golem_calls[0], Golem_Call.Come)
    testing.expect_value(t, gs.golem_searches, MAX_GOLEM_SEARCHES_PER_FRAME)
}

@(test)
only_a_failed_fetch_or_delivery_drops_its_target :: proc(t: ^testing.T) {
    // Card 145: a transfer target with no route goes on the worker's dropped
    // list.  A mine or a walk with no route is the gather skip list's business.
    // Card 152: a Build errand (fetch or place) first sets a full pack down
    // and tries again with room to dig; a Place with no route waits instead
    // of taking a slot (golem_give_up_place).
    gs := nav_state()
    defer free(gs)
    // Roster slot 3, so the list is the worker's own and not slot 0's.
    g := &gs.golems.data[3]
    g^ = nav_pocket(gs)^
    gs.golems.data[0] = {}
    beyond := [2]i32{26, 59}   // past even a Place's reach
    for job in Golem_Job {
        gs.golem_transfer[3] = {}
        g.job = job
        g.pack = {}
        for golem_pack_add(g, .Stone_Block) {}   // a full pack cannot dig
        testing.expect(t, !golem_set_target(gs, g, beyond, false), "the far side is sealed")
        build := job == .Fetch_Build || job == .Place
        testing.expect_value(t, golem_pack_count(g) == 0, build)
        if build {
            testing.expect(t, !golem_resource_skipped(beyond, golem_transfer_skips(gs, 3)), "not yet: it may dig now")
            testing.expect(t, !golem_set_target(gs, g, beyond, false), "the placed wall is sealed with room too")
        }
        testing.expect_value(t, len(golem_transfer_skips(gs, 0)), 0)
        dropped := golem_resource_skipped(beyond, golem_transfer_skips(gs, 3))
        testing.expect_value(t, dropped, job == .Fetch_Build || job == .Deliver)
    }
}

@(test)
a_stockpile_with_no_route_is_not_picked_twice :: proc(t: ^testing.T) {
    // With no store on the level the deposit search hands back a stockpile
    // cell.  When that cell has no route, the stockpile retry in the same call
    // must skip it and try the next, not search the same one again.
    gs := nav_state()
    defer free(gs)
    g := nav_pocket(gs)
    g.pos.x = 25.2   // east of the wall; every pile cell is west of it
    for golem_pack_add(g, .Stone_Block) {}
    g.carry = .Stone_Block
    // Its stockpile ring ends at x=17, beyond a transfer's reach of the wall.
    gs.golems.work[gs.level_index] = {active = true, min = {11, 59}, max = {13, 59}}
    near, ok := golem_find_stockpile(gs, golem_tile(g), .Stone_Block, nil)
    testing.expect(t, ok && near.x <= 17, "the nearest pile is past the wall")
    testing.expect(t, !golem_start_delivery(gs, g), "no pile has a route")
    skips := golem_transfer_skips(gs, 0)
    testing.expect_value(t, len(skips), 2)
    if len(skips) == 2 {
        testing.expect_value(t, skips[0], near)
        testing.expect(t, skips[1] != near, "the retry searched another pile")
    }

    // The next block: the deposit search, which falls back to the stockpile
    // with no store about, skips both dropped piles as well.
    g.carry = .Stone_Block
    gs.golem_searches = 0
    testing.expect(t, !golem_start_delivery(gs, g), "still no route")
    skips = golem_transfer_skips(gs, 0)
    testing.expect_value(t, len(skips), 4)
    for a, i in skips do for b in skips[i+1:] do testing.expect(t, a != b, "each search tried a new pile")
}

// Seed 781's surface, the hero at (89,79) with a pick and 30 blocks, nothing
// hunting it: the long go to (165,100) runs the window's search, the whole
// level's and the one that hurts (card 195's test).
HERO_LONG_FROM :: [2]i32{89, 79}
HERO_LONG_TO   :: [2]i32{165, 100}

@(private="file")
hero_long_world :: proc() -> (gs: ^Game_State, link: ^Agent_Link) {
    gs = new(Game_State)
    link = new(Agent_Link)
    game_state_init(gs, 781)
    gs.ui.show_title = false
    link.connected, link.realtime = true, true
    link.goals.reflexes_off = {.On_Its_Own}
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    gs.roamer_timer = -1e9
    gs.player.inventory = {}
    _ = inventory_insert(&gs.player.inventory, .Pickaxe, 1)
    _ = inventory_insert(&gs.player.inventory, .Stone_Block, 30)
    gs.player.pos = {f32(HERO_LONG_FROM.x) + 0.1, f32(HERO_LONG_FROM.y) + 1 - PLAYER_H}
    return
}

@(private="file")
hero_long_frame :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if agent_drive(link, gs) {
        game_update(gs)
        agent_after_tick(link, gs)
    }
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
}

@(private="file")
hero_long_go :: proc(t: ^testing.T, link: ^Agent_Link, gs: ^Game_State) {
    for _ in 0 ..< 10 do hero_long_frame(link, gs)
    testing.expect_value(t, hero_feet(&gs.player), HERO_LONG_FROM)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, HERO_LONG_TO.x, HERO_LONG_TO.y))
}

// The hero's searches count in the frame's work, and a long go's plan is
// spread over frames (card 202): in one frame it was several frames' budget.
@(test)
a_hero_replan_is_counted_and_spread_over_frames :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    top, total, run, longest := 0, 0, 0, 0
    for f := 0; f < 60 * 120 && agent_goals_busy(&link.goals); f += 1 {
        hero_long_frame(link, gs)
        top = max(top, gs.nav_work)
        total += gs.nav_work
        run = run + 1 if gs.nav_work > 0 else 0
        longest = max(longest, run)
    }
    log.infof("hero nav work: max frame %d, total %d, longest run of searching frames %d", top, total, longest)
    testing.expect(t, total > 0, "the hero's searches are counted")
    testing.expect(t, top <= NAV_WORK_P99_BUDGET, "no frame of the go's searches passes the frame's budget")
    testing.expect(t, longest <= 30, "the hero waits half a second at most for a plan")
    g := &link.goals.slots[0]
    testing.expectf(t, link.goals.n == 1 && g.status == .Done, "the go arrives: %v %s", g.status, string(g.reason.buf[:g.reason.len]))
}

// A plan run a slice of work at a time is the plan run whole: the same path,
// the same work, and no slice much past what it was given.
@(test)
a_hero_plan_in_slices_is_the_plan_run_whole :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    whole, sliced: Hero_Path
    gs.nav_work = 0
    reached := hero_plan(gs, HERO_LONG_FROM, HERO_LONG_TO, &whole)
    work := gs.nav_work
    testing.expect(t, !gs.hero.nav.planning, "a whole plan leaves none in hand")
    SLICE :: 5000
    gs.nav_work = 0
    hero_plan_begin(gs, HERO_LONG_FROM, HERO_LONG_TO, true, true)
    slices, top := 0, 0
    for {
        before := gs.nav_work
        done, r := hero_plan_step(gs, &sliced, SLICE)
        slices += 1
        top = max(top, gs.nav_work - before)
        if done {
            testing.expect_value(t, r, reached)
            break
        }
        testing.expect(t, gs.hero.nav.planning, "a plan not done is still in hand")
        if slices > 1000 do break
    }
    log.infof("hero plan: work %d, reached %v, in %d slices, the largest %d", work, reached, slices, top)
    testing.expect(t, reached, "the long go is planned to its end")
    testing.expect(t, !gs.hero.nav.planning, "a plan done leaves none in hand")
    testing.expect_value(t, gs.nav_work, work)
    testing.expect(t, slices > work / SLICE, "it ran in slices")
    testing.expect(t, top <= SLICE + 500, "a slice stops near its work: one node's pushes past it at most")
    testing.expect_value(t, sliced.n, whole.n)
    for i in 0 ..< min(whole.n, sliced.n) do testing.expectf(t, sliced.steps[i] == whole.steps[i], "step %d: %v, whole %v", i, sliced.steps[i], whole.steps[i])
}

// A corridor two tiles high, closed at x 19 and x 61, nothing to dig, jump
// or bridge: one way along it.
@(private="file")
hero_corridor :: proc(gs: ^Game_State) {
    for x in 18 ..= 62 {
        for y in 46 ..= 52 do set_tile(&gs.world, x, y, .Stone)
        if x > 19 && x < 61 do for y in 48 ..= 49 do set_tile(&gs.world, x, y, .Air)
    }
    gs.player.inventory = {}
}

// From 30 to 40 along it: each node expanded is one work, each push its
// sifts.  31 to 39 each push the next, a sift over 29, which waits behind;
// 30 pushes 29 and 31, one sift; 40 ends it: 1 + 1 + 9 * 2 + 1.
@(test)
a_hero_search_counts_its_nodes_and_sifts :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    hero_corridor(gs)
    path: Hero_Path
    gs.nav_work = 0
    reached, _ := hero_plan_once(gs, {30, 49}, {40, 49}, &path, false, false, false)
    testing.expect(t, reached, "along the corridor")
    testing.expect_value(t, path.n, 10)
    testing.expect_value(t, gs.nav_work, 21)
}

// A goal past the window that the corridor never reaches: the first search
// goes over the whole level and shuts it, so no second search without a hurt
// runs, and with no blocks none without them: the plan is two searches.
@(test)
a_hero_plan_the_level_shuts_runs_no_search_again :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    hero_corridor(gs)
    from, to := [2]i32{30, 49}, [2]i32{120, 49}
    path: Hero_Path
    gs.nav_work = 0
    reached, whole := hero_plan_once(gs, from, to, &path, false, false, false)
    testing.expect(t, !reached && whole, "the corridor is the whole level's way")
    one := gs.nav_work
    gs.nav_work = 0
    testing.expect(t, !hero_plan(gs, from, to, &path, dig = false, blocks = false), "no way")
    testing.expect_value(t, gs.nav_work, 2 * one)
    testing.expect(t, path.n > 0 && path.steps[path.n - 1].to == {60, 49}, "the end of the corridor, nearest the goal")
}

// A replan for a go that has its path, when no headway stops it, runs on
// each frame until it is done; the old path is not walked meanwhile.
@(test)
a_hero_replan_runs_on_until_done :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    g := &link.goals.slots[0]
    n := &gs.hero.nav
    for f := 0; f < 120 && (gs.hero.path.goal != g.id || n.planning || gs.hero.path.at < 2); f += 1 do hero_long_frame(link, gs)
    testing.expect(t, gs.hero.path.goal == g.id && !n.planning, "walking its first plan")
    // No headway this frame (the best already beaten), and long enough for a replan.
    g.stuck_t, g.replanned, g.best, g.steps_best = HERO_GO_REPLAN_S, false, 0, 0
    old := gs.hero.path   // the walk's path as the replan begins: untouched until the new one is taken up
    for f := 0; f < 10 && !g.replanned; f += 1 do hero_long_frame(link, gs)
    testing.expect(t, g.replanned && n.planning, "the replan takes more than a frame")
    testing.expect(t, gs.hero.path == old, "the replan's first frame leaves the old path as it was")
    frames := 1
    for ; frames < 60 && n.planning; frames += 1 {
        hero_long_frame(link, gs)
        testing.expectf(t, gs.hero.path == old, "frame %d of the replan: the old path neither walked nor written", frames)
    }
    testing.expectf(t, !n.planning && frames <= 5, "the replan is done in %d frames", frames)
    // Its go takes the new path up at its next tick (card 204: until then it
    // is the plan's own, in gs.hero.nav.out).
    hero_long_frame(link, gs)
    testing.expect(t, gs.hero.path.goal == g.id && gs.hero.path.at == 0 && gs.hero.path.steps[0].from == n.from, "the new path, from the replan's feet")
}

// A plan in hand is for one walk: another goal, or the same goal sent to
// another tile (a work goal's next stand), starts its own.
@(test)
a_hero_plan_in_hand_is_for_one_walk :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    hero_long_frame(link, gs)
    n := &gs.hero.nav
    g := &link.goals.slots[0]
    testing.expect(t, n.planning && n.plan_goal == g.id, "the go's plan runs on")
    other := Agent_Goal{id = g.id + 100, status = .Running, kind = g.kind, to = HERO_LONG_TO, best = max(i32)}
    hero_go_tick(gs, &other)
    testing.expect(t, n.planning && n.plan_goal == other.id, "another goal plans afresh")
    other.to = {120, 60}
    hero_go_tick(gs, &other)
    testing.expect(t, n.plan_to == other.to && n.to == other.to, "a new tile plans afresh")
}

// The corridor three tiles high with a pit a tile deep at 33 and at 36:
// from 30 the hero walks, drops in, climbs out or jumps over, so nodes wait
// in the open set and a pop sifts.  Measured with every pop, push and node
// counted: 11 nodes, 35 work.
@(test)
a_hero_search_counts_its_pops :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    hero_corridor(gs)
    for x in 20 ..= 60 do set_tile(&gs.world, x, 47, .Air)
    for x in ([2]int{33, 36}) do set_tile(&gs.world, x, 50, .Air)
    path: Hero_Path
    gs.nav_work = 0
    reached, _ := hero_plan_once(gs, {30, 49}, {40, 49}, &path, false, false, false)
    testing.expect(t, reached, "along the corridor")
    log.infof("three-high corridor: %d nodes, %d work", gs.hero.nav.expanded, gs.nav_work)
    testing.expect_value(t, gs.nav_work, 35)
}

// A plan from a tile off the level has no search to run: it comes back done
// at once, with no path and no plan left in hand, so no go waits on it.
@(test)
a_hero_plan_from_off_the_level_is_done_at_once :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    path: Hero_Path
    path.n = 5
    hero_plan_begin(gs, {-5, 49}, {40, 49}, true, true)
    done, reached := hero_plan_step(gs, &path, HERO_NAV_FRAME_WORK)
    testing.expect(t, done && !reached, "done, and nowhere reached")
    testing.expect_value(t, path.n, 0)
    testing.expect(t, !gs.hero.nav.planning, "no plan left in hand")
}

// A plan in hand begun where the hero no longer stands (card 203: knocked
// while it waited) is dropped, and the go plans again from the hero's feet.
@(test)
a_hero_knocked_mid_plan_plans_again_from_its_feet :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    hero_long_frame(link, gs)
    n := &gs.hero.nav
    g := &link.goals.slots[0]
    testing.expect(t, n.planning && n.from == HERO_LONG_FROM, "the go's plan runs on from where it began")
    // Knocked a few tiles west, onto ground.
    to := [2]i32{-1, -1}
    find: for dx in i32(3) ..= 12 do for y in i32(60) ..< 100 do if hero_stand(&gs.world, {HERO_LONG_FROM.x - dx, y}) {
        to = {HERO_LONG_FROM.x - dx, y}
        break find
    }
    testing.expect(t, to.x >= 0, "ground to land on")
    gs.player.pos = {f32(to.x) + 0.1, f32(to.y) + 1 - PLAYER_H}
    gs.player.vel = {}
    for f := 0; f < 30 && (gs.hero.path.goal != g.id || n.planning); f += 1 do hero_long_frame(link, gs)
    testing.expect(t, gs.hero.path.goal == g.id && !n.planning, "the go has a plan")
    testing.expect_value(t, n.from, to)
    testing.expect(t, gs.hero.path.n > 0 && gs.hero.path.steps[0].from == to, "its path starts at the feet it was knocked to")
}

// Each search starts its own best (card 203): one that reached its goal
// leaves nothing for the next, whose chain back then stays its own.
@(test)
a_hero_search_starts_its_own_best :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    hero_corridor(gs)
    path: Hero_Path
    reached, _ := hero_plan_once(gs, {30, 49}, {40, 49}, &path, false, false, false)
    testing.expect(t, reached, "along the corridor")
    n := &gs.hero.nav
    from, to := [2]i32{50, 49}, [2]i32{58, 30}   // over the corridor's roof: never reached
    hero_search_start(gs, from, to, false, false, false, false, HERO_NAV_BUDGET)
    testing.expect_value(t, n.best, n.s)
    testing.expect_value(t, n.best_h, f32(8) + 0.5 * f32(19))
    ended, r, _ := hero_search_run(gs, &path, max(int))
    testing.expect(t, ended && !r, "the search ends short of its goal")
    testing.expect(t, path.n == 8 && path.steps[0].from == from && path.steps[7].to == {58, 49}, "from its own start to the tile under the goal")
}

// The hero plans on what the golems and enemies leave of the frame (card
// 203): with a full swarm and crew searching while a go plans and plans
// again, the frames stay in the frame's budget but for the 1% the swarm fills
// by itself.
@(test)
a_hero_plan_and_the_swarm_share_the_frame :: proc(t: ^testing.T) {
    gs := nav_state()
    defer free(gs)
    link := new(Agent_Link)
    defer free(link)
    link.connected, link.realtime = true, true
    link.goals.reflexes_off = ~{}  // the go, not a fight with the swarm
    nav_fill(gs, false)
    nav_crew(gs)
    // From the ground at the west end into the sky over the middle, with a
    // pick and blocks: no way reaches it, so each plan runs all its searches
    // through, about 310k of work.
    from := [2]i32{-1, -1}
    for y in i32(1) ..< GRID_H - 1 do if hero_stand(&gs.world, {12, y}) {
        from = {12, y}
        break
    }
    testing.expect(t, from.y > 0, "ground to stand on")
    gs.player.inventory = {}
    _ = inventory_insert(&gs.player.inventory, .Pickaxe, 1)
    _ = inventory_insert(&gs.player.inventory, .Stone_Block, 30)
    gs.player.pos = {f32(from.x) + 0.1, f32(from.y) + 1 - PLAYER_H}
    n := &gs.hero.nav
    work: [NAV_TEST_FRAMES]i64
    planned, over := 0, 0
    for f in 0 ..< NAV_TEST_FRAMES {
        if !agent_goals_busy(&link.goals) do agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,2]}}]}}`, GRID_W / 2))
        // The stuck watchdog's replan due at each tick: a plan always in hand.
        for &g in link.goals.slots[:link.goals.n] do if g.status == .Running do g.stuck_t, g.replanned = HERO_GO_REPLAN_S, false
        was := n.planning
        if agent_drive(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
        work[f] = i64(gs.nav_work)
        if gs.nav_work > NAV_WORK_P99_BUDGET do over += 1
        if was || n.planning do planned += 1
    }
    slice.sort(work[:])
    log.infof("hero and swarm: p50 %d, p99 %d, max %d; %d frames over the budget; the hero planned in %d",
        work[NAV_TEST_FRAMES / 2], work[NAV_TEST_FRAMES * 99 / 100], work[NAV_TEST_FRAMES - 1], over, planned)
    testing.expect(t, planned >= NAV_TEST_FRAMES / 3, "the hero plans all through")
    testing.expect(t, work[NAV_TEST_FRAMES * 99 / 100] <= NAV_WORK_P99_BUDGET, "p99 frame stays in the work budget")
    testing.expect(t, over <= NAV_TEST_FRAMES / 100, "the hero's plan takes no frame over the budget")
}

// update_hero_plan's slice (card 203): what the golems and enemies left of
// NAV_FRAME_WORK, HERO_NAV_FRAME_WORK at most and HERO_NAV_FRAME_MIN at least,
// past by one node's pushes at most; a fresh plan waits afresh.
@(test)
a_hero_plan_slice_is_what_the_frame_left :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    g := hero_long_running(link)
    n := &gs.hero.nav
    begin :: proc(gs: ^Game_State, g: ^Agent_Goal) {
        hero_plan_begin(gs, HERO_LONG_FROM, HERO_LONG_TO, true, true)
        gs.hero.nav.plan_goal, gs.hero.nav.plan_to = g.id, g.to   // the go's own, paused
    }
    // Waited HERO_NAV_STARVE_FRAMES on a full frame, it takes its most
    // whatever the frame used, so no swarm stands the hero still past about
    // half a second plus the plan's own frames (card 203).
    over := NAV_FRAME_WORK + 30_000
    begin(gs, g)
    for _ in 0 ..< HERO_NAV_STARVE_FRAMES {
        gs.frame += 1
        gs.nav_work = over
        update_hero_plan(gs)
        testing.expect(t, n.planning && gs.nav_work - over <= HERO_NAV_FRAME_MIN + 500, "a full frame leaves the plan its least")
    }
    gs.frame += 1
    gs.nav_work = over
    update_hero_plan(gs)
    testing.expectf(t, gs.nav_work - over >= HERO_NAV_FRAME_WORK, "starved, the plan took %d", gs.nav_work - over)
    Case :: struct { used, want: int }
    for c in ([3]Case{{0, HERO_NAV_FRAME_WORK}, {NAV_FRAME_WORK - 20_000, 20_000}, {NAV_FRAME_WORK + 30_000, HERO_NAV_FRAME_MIN}}) {
        gs.frame += 1
        begin(gs, g)
        gs.nav_work = c.used
        update_hero_plan(gs)
        spent := gs.nav_work - c.used
        testing.expectf(t, gs.hero.nav.planning && spent >= c.want && spent <= c.want + 500, "%d used: the plan took %d, not about %d", c.used, spent, c.want)
    }
}

// A plan run through for one go is not another's (card 203): a go that
// begins its own while another's waits to be taken up waits for its own.
@(test)
a_hero_plan_run_through_is_for_its_own_go :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    hero_long_frame(link, gs)
    n := &gs.hero.nav
    g := &link.goals.slots[0]
    for f := 0; f < 10 && !n.ready; f += 1 {
        gs.frame += 1
        gs.nav_work = 0
        update_hero_plan(gs)
    }
    testing.expect(t, n.ready && n.plan_goal == g.id, "the go's plan waits to be taken up")
    other := Agent_Goal{id = g.id + 100, status = .Running, kind = g.kind, to = HERO_LONG_TO, best = max(i32)}
    hero_go_tick(gs, &other)
    testing.expect(t, n.planning && !n.ready && n.plan_goal == other.id, "the other go's plan runs")
    testing.expect(t, gs.hero.path.goal != other.id, "and is not walked before it is done")
}

// A go's tick runs a fresh plan's first slice only, before the golems and
// enemies search (card 203): the rest waits for what they leave.
@(test)
a_hero_go_tick_plans_a_slice_before_the_swarm :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    hero_long_frame(link, gs)
    g := link.goals.slots[0]
    g.id += 100   // a fresh go to the same tile: its own plan
    gs.nav_work = 0
    hero_go_tick(gs, &g)
    testing.expect(t, gs.hero.nav.planning && gs.hero.nav.plan_goal == g.id, "the long plan runs on")
    testing.expectf(t, gs.nav_work > 0 && gs.nav_work <= HERO_NAV_TICK_WORK + 500, "the tick spent %d", gs.nav_work)
}

// A replan in hand when the hero is knocked along its old path (card 203):
// the old path is not walked on; the replan begins again from the feet.
@(test)
a_hero_knocked_mid_replan_plans_again_from_its_feet :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    g := &link.goals.slots[0]
    n := &gs.hero.nav
    path := &gs.hero.path
    for f := 0; f < 120 && (path.goal != g.id || n.planning || path.at < 2); f += 1 do hero_long_frame(link, gs)
    testing.expect(t, path.goal == g.id && !n.planning && path.at < path.n, "walking its first plan")
    g.stuck_t, g.replanned, g.best, g.steps_best = HERO_GO_REPLAN_S, false, 0, 0
    for f := 0; f < 10 && !g.replanned; f += 1 do hero_long_frame(link, gs)
    testing.expect(t, g.replanned && n.planning, "the replan takes more than a frame")
    // On along the old path to its next step's end, still on it.
    to := path.steps[path.at].to
    gs.player.pos, gs.player.vel = {f32(to.x) + 0.1, f32(to.y) + 1 - PLAYER_H}, {}
    hero_long_frame(link, gs)
    testing.expect_value(t, n.from, to)
    testing.expect(t, n.planning || n.ready, "the replan runs again from there")
}

// A swarm that fills every frame still lets a long go set off within a
// second (card 203: at the least alone it stood about 124 frames), and so
// does a go another behaviour pauses a frame in every 31, just past the
// starve frames: a paused go that is still running keeps its plan and its
// wait.  The frame is played by hand: the go's tick, then a swarm's frame of
// work, then the plan.
@(test)
a_hero_go_starved_by_the_swarm_sets_off_within_a_second :: proc(t: ^testing.T) {
    for pause in ([2]int{0, HERO_NAV_STARVE_FRAMES + 1}) {
        gs, link := hero_long_world()
        defer free(gs)
        defer free(link)
        hero_long_go(t, link, gs)
        g := hero_long_running(link)
        path := &gs.hero.path
        frames := 0
        for frames < 200 && path.goal != g.id {
            frames += 1
            gs.frame += 1
            gs.nav_work = 0
            gs.agent.cmd = {}
            if pause == 0 || frames % pause != 0 do hero_go_tick(gs, g)
            if path.goal == g.id do break
            gs.nav_work += NAV_FRAME_WORK + 10_000
            update_hero_plan(gs)
        }
        log.infof("starved go, paused every %d: the path taken up at frame %d", pause, frames)
        testing.expectf(t, path.goal == g.id && path.n > 0 && gs.agent.cmd != {}, "the go walks its first step (paused every %d)", pause)
        testing.expectf(t, frames <= 60, "it stood %d frames (paused every %d)", frames, pause)
    }
}

// The long go queued and running, its walk not yet begun: the tick a
// frame by hand gives it is its first.
@(private="file")
hero_long_running :: proc(link: ^Agent_Link) -> ^Agent_Goal {
    g := &link.goals.slots[0]
    g.status, g.to, g.best = .Running, HERO_LONG_TO, max(i32)
    return g
}

// A plan run through, then the hero knocked straight down a shaft before
// its go takes the path up (card 203): the go plans again from the feet it
// landed on, not from the old.
@(test)
a_hero_knocked_down_with_its_plan_done_plans_again_from_its_feet :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    n := &gs.hero.nav
    g := &link.goals.slots[0]
    for f := 0; f < 30 && !n.ready; f += 1 do hero_long_frame(link, gs)
    testing.expect(t, n.ready && n.plan_goal == g.id && n.from == HERO_LONG_FROM && gs.hero.path.goal != g.id, "the plan waits to be taken up")
    // A shaft under the feet, the hero at its foot.
    to := HERO_LONG_FROM + {0, 3}
    for y in HERO_LONG_FROM.y + 1 ..= to.y do set_tile(&gs.world, int(to.x), int(y), .Air)
    set_tile(&gs.world, int(to.x), int(to.y + 1), .Stone)
    testing.expect(t, hero_stand(&gs.world, to), "the shaft has a floor")
    gs.player.pos, gs.player.vel = {f32(to.x) + 0.1, f32(to.y) + 1 - PLAYER_H}, {}
    hero_long_frame(link, gs)
    testing.expect_value(t, n.from, to)
    testing.expect(t, gs.hero.path.goal != g.id || gs.hero.path.steps[0].from == to, "no path from the old feet taken up")
}

// A plan whose go is gone, done, cancelled or with the link dropped, is
// dropped at the next frame, not run on into the hero's path (card 203).
@(test)
a_hero_plan_with_no_go_left_is_dropped :: proc(t: ^testing.T) {
    for drop in ([2]bool{false, true}) {
        gs, link := hero_long_world()
        defer free(gs)
        defer free(link)
        hero_long_go(t, link, gs)
        hero_long_frame(link, gs)
        n := &gs.hero.nav
        testing.expect(t, n.planning, "the go's plan runs on")
        if drop {
            link.connected, link.goals = false, {}   // as agent_drop_client leaves it
            game_update(gs)
        } else {
            agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
            hero_long_frame(link, gs)
        }
        testing.expectf(t, !n.planning && !n.ready, "dropped (link dropped %v)", drop)
        testing.expectf(t, gs.nav_work < HERO_NAV_FRAME_MIN, "no work spent on it: %d", gs.nav_work)
    }
}

// A walk the brain runs itself, as a retreat, is no goal of the queue: its
// ticks alone own its plan, which runs on to its path (card 203).
@(test)
a_hero_walk_of_its_own_keeps_its_plan_while_it_ticks :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    r := Agent_Goal{id = 1000, kind = link.goals.slots[0].kind, to = HERO_LONG_TO, best = max(i32)}   // in no slot of the queue, running no status: the brain's own
    path := &gs.hero.path
    frames := 0
    for frames < 30 {
        frames += 1
        gs.frame += 1
        gs.nav_work = 0
        hero_go_tick(gs, &r)
        if path.goal == r.id do break
        update_hero_plan(gs)
    }
    testing.expectf(t, path.goal == r.id && path.n > 0 && gs.agent.cmd != {}, "the walk sets off: %d frames", frames)
    testing.expectf(t, frames <= 5, "in %d frames", frames)
}

// Another goal running does not own a plan for a go that has ended (card 203).
@(test)
a_hero_plan_of_an_ended_go_is_not_another_goals :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    hero_long_frame(link, gs)
    n := &gs.hero.nav
    testing.expect(t, n.planning && n.plan_goal == link.goals.slots[0].id, "the go's plan runs on")
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"stay"}]}`)
    testing.expect_value(t, link.goals.n, 2)
    link.goals.slots[0].status = .Done
    link.goals.slots[1].status = .Running
    gs.frame += 1
    update_hero_plan(gs)
    testing.expect(t, !n.planning, "dropped")
}

// The swarm's world with the hero on the ground at its west end, a pick and
// blocks in the bag, and, with plan, a plan into the sky always in hand,
// owned as its go's tick owns it.  The hero's frame work is the frame's less
// the same frame's work without the plan: the swarm never reads the hero's
// plan, so it runs the same either way.
@(private="file")
nav_swarm_frames :: proc(plan: bool) -> (work: [NAV_TEST_FRAMES]int) {
    gs := nav_state()
    defer free(gs)
    nav_fill(gs, false)
    nav_crew(gs)
    from := [2]i32{-1, -1}
    for y in i32(1) ..< GRID_H - 1 do if hero_stand(&gs.world, {12, y}) {
        from = {12, y}
        break
    }
    gs.player.inventory = {}
    _ = inventory_insert(&gs.player.inventory, .Pickaxe, 1)
    _ = inventory_insert(&gs.player.inventory, .Stone_Block, 30)
    n := &gs.hero.nav
    for f in 0 ..< NAV_TEST_FRAMES {
        if plan {
            if !n.planning do hero_plan_begin(gs, from, {GRID_W / 2, 2}, true, true)
            n.owned = gs.frame + 1   // this frame's tick, as hero_go_tick marks it
        }
        game_update(gs)
        work[f] = gs.nav_work
    }
    return
}

// The hero's plan runs after the golems' and enemies' searches (card 203): on
// a frame they take past NAV_FRAME_WORK the plan gets its least, and on every
// frame no more than they left.
@(test)
a_hero_plan_runs_on_what_the_swarm_left :: proc(t: ^testing.T) {
    swarm := nav_swarm_frames(false)
    both := nav_swarm_frames(true)
    full, busy := 0, 0
    for f in 0 ..< NAV_TEST_FRAMES {
        hero := both[f] - swarm[f]
        left := max(NAV_FRAME_WORK - swarm[f], HERO_NAV_FRAME_MIN)
        testing.expectf(t, hero >= 0, "frame %d: the swarm ran the same", f)
        testing.expectf(t, hero <= min(left, HERO_NAV_FRAME_WORK) + 500, "frame %d: the swarm took %d, the hero %d", f, swarm[f], hero)
        if swarm[f] >= NAV_FRAME_WORK do full += 1
        if swarm[f] >= NAV_FRAME_WORK - HERO_NAV_FRAME_WORK do busy += 1
    }
    log.infof("hero after the swarm: %d frames the swarm filled, %d it took past half", full, busy)
    testing.expect(t, full > 0 && busy >= 10, "the swarm fills frames")
}

// A stuck replan that outlasts its tick slice holds the hero (card 203): no
// step of the old path is walked while it runs, and the path taken up starts
// where the replan began.
@(test)
a_hero_stuck_replan_holds_the_hero_until_taken_up :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    g := &link.goals.slots[0]
    n := &gs.hero.nav
    path := &gs.hero.path
    for f := 0; f < 120 && (path.goal != g.id || n.planning || path.at < 2); f += 1 do hero_long_frame(link, gs)
    testing.expect(t, path.goal == g.id && !n.planning && path.at < path.n, "walking its first plan")
    g.stuck_t, g.replanned, g.best, g.steps_best = HERO_GO_REPLAN_S, false, 0, 0
    feet := hero_feet(&gs.player)
    frames, walked := 0, 0
    for frames < 120 {
        frames += 1
        gs.frame += 1
        gs.nav_work = 0
        gs.agent.cmd = {}
        hero_go_tick(gs, g)
        if frames > 1 && !n.planning && !n.ready do break   // taken up
        if gs.agent.cmd != {} do walked += 1
        gs.nav_work += NAV_FRAME_WORK + 10_000
        update_hero_plan(gs)
    }
    testing.expect(t, g.replanned && frames > 2, "the replan outlasts its tick slice")
    testing.expect_value(t, walked, 0)
    testing.expect_value(t, n.from, feet)
    testing.expect(t, path.goal == g.id && path.n > 0 && path.at == 0 && path.steps[0].from == feet, "the path taken up starts at the replan's feet")
    testing.expect(t, gs.agent.cmd != {}, "and is walked")
}

// A go's plan runs in a buffer of its own (card 204): a paused go's plan,
// running on after the swarm, never writes the path another walk (a retreat)
// is on, and its go takes up the plan's own path.
@(test)
a_hero_plan_writes_no_path_but_its_own :: proc(t: ^testing.T) {
    gs, link := hero_long_world()
    defer free(gs)
    defer free(link)
    hero_long_go(t, link, gs)
    g := hero_long_running(link)
    n := &gs.hero.nav
    path := &gs.hero.path
    gs.frame += 1
    hero_go_tick(gs, g)
    testing.expect(t, n.planning && n.plan_goal == g.id, "the go's plan runs on")
    // Another walk on the path, its steps its own.
    other := Hero_Path{n = 2, goal = 1000}
    other.steps[0] = {from = HERO_LONG_FROM, to = HERO_LONG_FROM + {1, 0}, move = .Walk}
    other.steps[1] = {from = HERO_LONG_FROM + {1, 0}, to = HERO_LONG_FROM + {2, 0}, move = .Walk}
    path^ = other
    for f := 0; f < 60 && !n.ready; f += 1 {
        gs.frame += 1
        gs.nav_work = 0
        update_hero_plan(gs)   // the go paused, still running: its plan runs on
        testing.expectf(t, path^ == other, "frame %d: the other walk's path is as it was", f)
    }
    testing.expect(t, n.ready, "the plan ran through")
    gs.frame += 1
    hero_go_tick(gs, g)
    testing.expect(t, path.goal == g.id && path.at == 0 && path.n > 0 && path.steps[0].from == HERO_LONG_FROM, "the go takes up its own plan's path")
    testing.expect(t, path.n != other.n || path.steps[0] != other.steps[0], "not the other walk's")
}
