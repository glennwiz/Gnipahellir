package game

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
