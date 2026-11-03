package game

import "core:testing"


// ─── A builder in its own floor slot (card 101) ───────────────────────────────

// What a real den puts in a slot: its template tile, or a mineral in the shell.
den_slot_tile :: proc(e: ^Enemy, T: [2]i32) -> Tile_Type {
    for t in build_templates[e.builder.build].tiles {
        if e.builder.anchor + t.off == T do return t.tile
    }
    return .Iron_Ore
}

// A finished den, every slot full but the floor slot at rel (-2,1), with the
// builder standing in that one, carrying a block home.  `spare` opens a second
// slot, one the search reaches later.
pinned_den :: proc(gs: ^Game_State, spare: bool) -> (e: ^Enemy, A: [2]i32) {
    gs.enemies = {}
    gs.world.entity_map = {}
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    A = {100, 80}
    for dy in -10 ..= 4 do for dx in -10 ..= 10 do set_tile(&gs.world, int(A.x) + dx, int(A.y) + dy, .Void)
    for dx in -10 ..= 10 do set_tile(&gs.world, int(A.x) + dx, int(A.y) + 2, .Stone)

    id, _ := enemy_alloc(&gs.enemies)
    e = &gs.enemies.data[id]
    e.kind, e.hp, e.hp_max = .Builder, 50, 50
    e.builder.build, e.builder.anchor, e.builder.den_built = .Shelter, A, true
    e.pos = {1, 1}   // clear of the den while its slots are filled
    for {
        T, ok, _ := den_next_build_tile(e, gs)
        if !ok do break
        set_tile(&gs.world, int(T.x), int(T.y), den_slot_tile(e, T))
    }
    slot := A + {-2, 1}
    set_tile(&gs.world, int(slot.x), int(slot.y), .Void)
    if spare do set_tile(&gs.world, int(A.x) + 2, int(A.y) + 1, .Void)

    e.pos = {f32(slot.x) + (1 - BUILDER_W)*0.5, f32(slot.y)}
    e.grounded = true
    e.builder.goal  = .Encase_Den
    e.builder.carry = .Iron_Ore
    return
}

@(test)
a_builder_in_its_own_slot_fills_another :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, true)
    gs.delta_time = 1.0/60.0
    for _ in 0 ..< 5 * 60 {
        update_enemies(gs)
        if e.builder.carry == .Air do break
    }

    testing.expect_value(t, get_tile(&gs.world, int(A.x) + 2, int(A.y) + 1), Tile_Type.Iron_Ore)
    testing.expect_value(t, e.builder.stuck_count, 0)
}

// Run the den's builder, handing it a block whenever it spends one, until no
// slot is open: the trip for a fresh block is not what is under test.
den_finishes :: proc(gs: ^Game_State, e: ^Enemy) -> bool {
    gs.delta_time = 1.0/60.0
    for _ in 0 ..< 60 * 60 {
        if e.builder.carry == .Air || e.builder.goal != .Encase_Den {
            e.builder.carry, e.builder.goal = .Iron_Ore, .Encase_Den
        }
        update_enemies(gs)
        if _, found, under := den_next_build_tile(e, gs); !found && !under do return true
    }
    return false
}

// The slot under the body is the only one left: the block is kept, the builder
// gets clear, and the den ends up closed.  Banking would leave it open.
@(test)
a_builder_in_the_last_slot_finishes_the_den :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    slot := A + {-2, 1}
    testing.expect(t, den_finishes(gs, e), "every slot ends up filled")
    testing.expect(t, is_solid(&gs.world, int(slot.x), int(slot.y)), "the last slot is filled")
    drop := terrain_table[Tile_Type.Iron_Ore].drop_item
    testing.expect_value(t, turret_ground_count(gs, drop), 0)
}

// Not one frame of banking while a slot is open, wherever the builder stands.
@(test)
a_builder_keeps_its_block_while_the_last_slot_is_under_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, _ := pinned_den(gs, false)
    _, found, under := den_next_build_tile(e, gs)
    testing.expect(t, !found && under, "the only slot is the one under the body")
    gs.delta_time = 1.0/60.0
    update_enemies(gs)
    testing.expect_value(t, e.builder.carry, Tile_Type.Iron_Ore)
    testing.expect_value(t, e.builder.goal, Builder_Goal.Encase_Den)
}

// The review's shape: the slot at rel (2,1), on the doorway side, and the body
// resting in the pit under it, which overlaps the slot by a sliver.
@(test)
a_builder_arriving_under_the_last_slot_finishes_the_den :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    set_tile(&gs.world, int(A.x) - 2, int(A.y) + 1, .Stone)
    slot := A + {2, 1}
    set_tile(&gs.world, int(slot.x), int(slot.y), .Void)
    set_tile(&gs.world, int(slot.x), int(slot.y) + 1, .Void)
    set_tile(&gs.world, int(slot.x), int(slot.y) + 2, .Stone)
    e.pos = {f32(slot.x) + (1 - BUILDER_W)*0.5, f32(slot.y) + 0.999}   // a body at y.999 spans two rows
    e.builder.pocket = 2   // two rows up to the doorway take a block to stand on
    _, found, under := den_next_build_tile(e, gs)
    testing.expect(t, !found && under, "the only slot is the one overlapped")
    testing.expect(t, den_finishes(gs, e), "every slot ends up filled")
    testing.expect(t, is_solid(&gs.world, int(slot.x), int(slot.y)), "the last slot is filled")
}

// With the shell truly done the block still goes to the stockpile.
@(test)
a_builder_with_no_slot_left_banks_its_block :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    set_tile(&gs.world, int(A.x) - 2, int(A.y) + 1, .Stone)
    e.pos = {f32(A.x), f32(A.y)}
    drop := terrain_table[Tile_Type.Iron_Ore].drop_item
    gs.delta_time = 1.0/60.0
    for _ in 0 ..< 60 do update_enemies(gs)
    testing.expect_value(t, turret_ground_count(gs, drop), 1)
    testing.expect_value(t, e.builder.carry, Tile_Type.Air)
}

// Standing clear of every slot, the choice is the same as ever.
@(test)
a_builder_clear_of_its_den_still_takes_the_first_slot :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    e.pos = {f32(A.x), f32(A.y)}
    T, ok, _ := den_next_build_tile(e, gs)
    testing.expect(t, ok, "the open slot is found")
    testing.expect_value(t, T, A + {-2, 1})
}

// Both floor slots of a den of real material, with and without a pit, with and
// without blocks in the pocket: the block is kept and the den ends up closed.
@(test)
a_builder_finishes_a_real_den_from_either_floor_slot :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    for dx in ([]i32{-2, 2}) do for pit in ([]bool{false, true}) do for pocket in ([]u8{0, 2}) {
        e, A := pinned_den(gs, false)
        set_tile(&gs.world, int(A.x) - 2, int(A.y) + 1, den_slot_tile(e, A + {-2, 1}))
        slot := A + {dx, 1}
        set_tile(&gs.world, int(slot.x), int(slot.y), .Void)
        e.pos = {f32(slot.x) + (1 - BUILDER_W)*0.5, f32(slot.y)}
        if pit {
            set_tile(&gs.world, int(slot.x), int(slot.y) + 1, .Void)
            set_tile(&gs.world, int(slot.x), int(slot.y) + 2, .Stone)
            e.pos.y += 0.999
        }
        e.builder.pocket = pocket
        testing.expectf(t, den_finishes(gs, e), "slot %d pit %v pocket %d: den closed", dx, pit, pocket)
        testing.expect(t, is_solid(&gs.world, int(slot.x), int(slot.y)), "the slot is filled")
    }
}

// A roof nothing can eat: each refused pillar is a strike, the arming stops at
// the strikeout, and the block lands at the builder's feet.
@(test)
a_builder_under_a_roof_it_cannot_eat_drops_its_block :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    set_tile(&gs.world, int(A.x) - 2, int(A.y), .Rune_Stone)
    set_tile(&gs.world, int(A.x) - 1, int(A.y) + 1, .Rune_Stone)
    set_tile(&gs.world, int(A.x) - 3, int(A.y) + 1, .Rune_Stone)
    drop := terrain_table[Tile_Type.Iron_Ore].drop_item
    gs.delta_time = 1.0/60.0
    starts := 0
    for _ in 0 ..< 60 * 60 {
        was := e.builder.escaping
        update_enemies(gs)
        if e.builder.escaping && !was do starts += 1
        if e.builder.carry == .Air do break
    }
    testing.expect_value(t, e.builder.carry, Tile_Type.Air)
    testing.expect_value(t, turret_ground_count(gs, drop), 1)
    testing.expect(t, starts < MAX_STRIKES, "the pillar is not re-armed past the strikeout")
}

// The door still rules: an unstruck builder in a slot leaves the wall alone.
@(test)
an_unstruck_builder_in_its_slot_may_not_eat_its_wall :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    roof := A + {-2, 0}
    testing.expect(t, !builder_may_eat_roof(gs, e, 0, int(roof.x), int(roof.y)), "no strike, no cut")
    e.builder.stuck_count = 1
    testing.expect(t, builder_may_eat_roof(gs, e, 0, int(roof.x), int(roof.y)), "a strike opens it")
    e.pos = {f32(A.x) - 8, f32(A.y)}
    e.builder.goal = .Fetch_Mineral   // a struck haul home is let in (card 111)
    testing.expect(t, !builder_may_eat_roof(gs, e, 0, int(roof.x), int(roof.y)), "from outside it holds")
}

// Seed 424242: a neighbour took each block from under the pillar, so each rose
// one tile, never struck, and the next began at once, 21 times in an hour.
@(test)
a_last_slot_pillar_that_gained_nothing_is_not_repeated :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, _ := pinned_den(gs, false)
    gs.delta_time = 1.0/60.0
    e.builder.stuck_count = 1
    e.builder.escape_from = builder_tile(e).y - 1
    update_enemies(gs)
    testing.expect(t, !e.builder.escaping, "the last pillar rose one: no second")
    e.builder.escape_from = builder_tile(e).y + ESCAPE_MIN_RISE
    update_enemies(gs)
    testing.expect(t, e.builder.escaping, "one that rose goes on")
}

// A pillar that ran out its clock without rising failed: that is a strike.
@(test)
a_pillar_that_rose_nothing_is_a_strike :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, _ := pinned_den(gs, false)
    builder_start_escape(e)
    e.builder.escape_timer = ESCAPE_MAX_TIME
    gs.delta_time = 1.0/60.0
    update_enemies(gs)
    testing.expect(t, !e.builder.escaping, "the clock ends it")
    testing.expect_value(t, e.builder.stuck_count, 1)
}

// Cutting its own wall is the way out: the escape ends there and the walk takes
// over, with the strikes forgiven.
@(test)
the_cut_through_its_own_wall_ends_the_escape :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    roof := A + {-2, 0}
    e.builder.stuck_count = 1
    builder_start_escape(e)
    gs.delta_time = 1.0/60.0
    for _ in 0 ..< 60 {
        update_enemies(gs)
        if !is_solid(&gs.world, int(roof.x), int(roof.y)) do break
    }
    testing.expect(t, !is_solid(&gs.world, int(roof.x), int(roof.y)), "the wall is cut")
    testing.expect(t, !e.builder.escaping, "the escape ends at the cut")
    testing.expect_value(t, e.builder.stuck_count, 0)
}

// Every way out of an escape drops a pillar's aim (card 119 review): here the
// cut through its own wall, and the fall that raises a draugr.
@(test)
the_ways_out_of_an_escape_drop_the_pillar_aim :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, _ := pinned_den(gs, false)
    e.builder.stuck_count = 1
    builder_start_escape(e)
    gs.enemy_status[0].pillar_aim = {100, 50}
    gs.delta_time = 1.0/60.0
    for _ in 0 ..< 60 {
        update_enemies(gs)
        if !e.builder.escaping do break
    }
    testing.expect(t, !e.builder.escaping, "the escape ends at the cut")
    testing.expect(t, gs.enemy_status[0].pillar_aim == {}, "the cut drops the aim")

    builder_start_escape(e)
    gs.enemy_status[0].pillar_aim = {100, 50}
    rise_draugr(gs, 0)
    testing.expect(t, gs.enemy_status[0].pillar_aim == {}, "the draugr drops the aim")
}

// The block went to another slot and the walk to the vein has no way out of the
// den slot under the body: the fetch strikes out, the builder cuts free, and
// the slot it stood in ends up filled.  No block is handed in.
@(test)
a_builder_that_spent_its_block_still_leaves_its_slot :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    for second in ([][2]i32{{2, 1}, {-4, 1}, {-2, -3}, {4, -4}}) do for pit in ([]bool{false, true}) {
        e, A := pinned_den(gs, false)
        slot := A + {-2, 1}
        if pit {
            set_tile(&gs.world, int(slot.x), int(slot.y) + 1, .Void)
            set_tile(&gs.world, int(slot.x), int(slot.y) + 2, .Stone)
            e.pos.y += 0.999
        }
        set_tile(&gs.world, int(A.x + second.x), int(A.y + second.y), .Void)
        set_tile(&gs.world, int(A.x) - 9, int(A.y) + 1, .Iron_Ore)
        set_tile(&gs.world, int(A.x) - 9, int(A.y), .Iron_Ore)
        gs.delta_time = 1.0/60.0
        for _ in 0 ..< 300 * 60 {
            update_enemies(gs)
            eq_clear(&gs.events)
            if is_solid(&gs.world, int(slot.x), int(slot.y)) do break
        }
        testing.expectf(t, is_solid(&gs.world, int(slot.x), int(slot.y)), "second slot %v pit %v: the slot is filled", second, pit)
    }
}

// A struck builder eats its own wall, never a neighbour's.
@(test)
a_struck_builder_in_its_slot_leaves_a_neighbours_wall :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    top  := A + {0, -3 - DEN_SHELL_LAYERS}
    roof := top - {0, 1}
    e.pos = {f32(top.x) + (1 - BUILDER_W)*0.5, f32(top.y)}
    e.builder.stuck_count = 1

    n, _ := enemy_alloc(&gs.enemies)
    o := &gs.enemies.data[n]
    o.kind, o.hp, o.hp_max = .Builder, 50, 50
    o.pos = {1, 1}
    o.builder.build, o.builder.den_built = .Shelter, true
    for tt in build_templates[Build_Kind.Shelter].tiles do if tt.tile == .Wood {
        o.builder.anchor = roof - tt.off
        break
    }
    set_tile(&gs.world, int(roof.x), int(roof.y), .Wood)
    testing.expect(t, den_protected(gs, int(roof.x), int(roof.y), 0), "the wall is the neighbour's")
    testing.expect(t, !builder_may_eat_roof(gs, e, 0, int(roof.x), int(roof.y)), "it holds")
}

// Outside its slots a fetch that strikes out only gives up, as ever.
@(test)
a_fetch_strikeout_clear_of_the_slots_starts_no_pillar :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    e.pos = {f32(A.x) - 9, f32(A.y)}
    e.builder.goal = .Fetch_Mineral
    e.builder.stuck_count = MAX_STRIKES - 1
    builder_strike(e, 0, gs, "test")
    testing.expect(t, !e.builder.escaping, "no pillar out here")
}

// A builder sent back to work mid-build has an anchor and no den yet: a fetch
// strikeout in a slot of that unfinished den is an ordinary give-up.
@(test)
a_fetch_strikeout_in_an_unbuilt_den_starts_no_pillar :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, _ := pinned_den(gs, false)
    e.builder.den_built = false
    e.builder.goal = .Fetch_Mineral
    e.builder.stuck_count = MAX_STRIKES - 1
    builder_strike(e, 0, gs, "test")
    testing.expect(t, !e.builder.escaping, "no pillar out of a den not yet built")
}

// A body wholly in the pit is not in the slot above it; a sliver in the slot is.
@(test)
a_body_only_counts_in_a_slot_it_overlaps :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e, A := pinned_den(gs, false)
    slot := A + {-2, 1}
    e.pos.y = f32(slot.y) + 1
    testing.expect(t, !builder_in_own_slot(e), "wholly below the slot")
    e.pos.y = f32(slot.y) + 0.999
    testing.expect(t, builder_in_own_slot(e), "a sliver in the slot")
}
