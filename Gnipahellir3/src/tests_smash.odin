package game

import "core:testing"

// ─── Enemy demolition conserves (card 102) ────────────────────────────────────
//
//  smash_tile is the dig of a builder and of Garm.  What the player would get
//  back from a pick, the ground gets from a dig.

SMASH_X :: 62
SMASH_Y :: 60

// A raider beside (SMASH_X, SMASH_Y), its next waypoint on that tile: the dig
// path builders and raiders share, reached through update_enemies.
smash_test_builder :: proc(gs: ^Game_State) -> ^Enemy {
    gs.enemies = {}
    gs.world.entity_map = {}
    for dy in -3 ..= 2 do for dx in -3 ..= 1 do set_tile(&gs.world, SMASH_X + dx, SMASH_Y + dy, .Void)
    for dx in -3 ..= 1 do set_tile(&gs.world, SMASH_X + dx, SMASH_Y + 1, .Stone)
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}

    id, _ := enemy_alloc(&gs.enemies)
    e := &gs.enemies.data[id]
    e.kind, e.hp, e.hp_max = .Raider, 50, 50
    e.pos = {SMASH_X - 1 + (1 - BUILDER_W)*0.5, SMASH_Y + 1 - BUILDER_H}
    e.grounded = true
    e.builder.goal = .Hunt
    e.builder.plan_target = player_tile(&gs.player)   // the player is far: this is en route
    e.builder.replan_timer = 100
    e.nav.path = {tiles = {0 = {SMASH_X, SMASH_Y}}, len = 1, cursor = 0}
    return e
}

@(test)
a_dig_through_a_loaded_machine_spills_it :: proc(t: ^testing.T) {
    for machine in ([]Tile_Type{.Smelter, .Gem_Replicator, .Boiler, .Magic_Kettle}) {
        gs := turret_test_state()
        defer free(gs)
        smash_test_builder(gs)
        set_tile(&gs.world, SMASH_X, SMASH_Y, machine)
        sd := &gs.world.sim_data[grid_idx(SMASH_X, SMASH_Y)]
        sd.store_item, sd.store_count = .Iron_Bar, 2
        sd.in_item,    sd.in_count    = .Iron_Ore, 3
        fuel := FUEL_ITEM
        if rule, ok := boiler_rule_for(machine); ok do fuel = rule.fuel_item
        if fuel != .None do sd.fuel_count = 4   // a kettle burns its input slot: no fuel_count
        bar0, ore0, fuel0 := turret_ground_count(gs, .Iron_Bar), turret_ground_count(gs, .Iron_Ore), turret_ground_count(gs, fuel)
        drop  := terrain_table[machine].drop_item
        drop0 := turret_ground_count(gs, drop)

        gs.delta_time = 1.0/60.0
        update_enemies(gs)

        testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != machine, "%v was dug out", machine)
        testing.expectf(t, turret_ground_count(gs, .Iron_Bar) - bar0 == 2, "%v spills its tray", machine)
        testing.expectf(t, turret_ground_count(gs, .Iron_Ore) - ore0 == 3, "%v spills its input", machine)
        if fuel != .None do testing.expectf(t, turret_ground_count(gs, fuel) - fuel0 == 4, "%v spills its fuel", machine)
        testing.expectf(t, turret_ground_count(gs, drop) - drop0 == 1, "%v drops itself", machine)
        testing.expect_value(t, sd^, Sim_Tile_Data{})
    }
}

// A plain tile keeps no contents to spill: a dig leaves nothing behind.
@(test)
a_dig_through_stone_spills_nothing :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Stone)
    sd := &gs.world.sim_data[grid_idx(SMASH_X, SMASH_Y)]
    sd.store_item, sd.store_count = .Iron_Bar, 2   // scratch a non-machine must not pay out
    gs.delta_time = 1.0/60.0
    update_enemies(gs)
    testing.expect(t, !is_solid(&gs.world, SMASH_X, SMASH_Y), "the stone was dug out")
    testing.expect_value(t, turret_ground_count(gs, .Iron_Bar), 0)
}

@(test)
a_dig_through_a_door_takes_both_halves :: proc(t: ^testing.T) {
    for half in 0 ..< 2 {   // the waypoint on the foot, then on the head
        gs := turret_test_state()
        defer free(gs)
        smash_test_builder(gs)
        other := half == 0 ? SMASH_Y - 1 : SMASH_Y + 1
        if half == 1 do set_tile(&gs.world, SMASH_X, SMASH_Y + 2, .Stone)
        set_tile(&gs.world, SMASH_X, SMASH_Y, .Door)
        set_tile(&gs.world, SMASH_X, other, .Door)
        gs.world.tile_flags[grid_idx(SMASH_X, other)] += {.Placed}
        door0 := turret_ground_count(gs, .Door)

        gs.delta_time = 1.0/60.0
        update_enemies(gs)

        testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y), "the dug half is gone")
        testing.expect(t, !is_door(&gs.world, SMASH_X, other), "no half door stays standing")
        testing.expect(t, .Placed not_in gs.world.tile_flags[grid_idx(SMASH_X, other)], "the far half's mark goes too")
        testing.expect_value(t, turret_ground_count(gs, .Door) - door0, 1)
    }
}

// A den slot on a door is the same demolition, and pays no pocket block: the
// door went to the ground as an item.
@(test)
a_den_carve_takes_a_whole_door :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    e.pos = {SMASH_X - 4, SMASH_Y - BUILDER_H + 1}
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Door)
    set_tile(&gs.world, SMASH_X, SMASH_Y - 1, .Door)
    door0, pocket0 := turret_ground_count(gs, .Door), e.builder.pocket

    builder_do_step(e, 0, gs, {SMASH_X, SMASH_Y}, .Void)

    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y), "the slot is carved")
    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y - 1), "no half door stays standing")
    testing.expect_value(t, turret_ground_count(gs, .Door) - door0, 1)
    testing.expect_value(t, e.builder.pocket, pocket0)
}

// Stacked doors pair from the foot of the run.  Digging one takes its own
// partner and leaves the other door whole, so two doors pay exactly two.
@(test)
a_dig_through_stacked_doors_takes_one_whole_door :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    for dy in 0 ..< 4 do set_tile(&gs.world, SMASH_X, SMASH_Y - dy, .Door)
    for y, want in ([]int{SMASH_Y, SMASH_Y - 1, SMASH_Y - 2, SMASH_Y - 3}) {
        _, py, ok := door_partner(&gs.world, SMASH_X, y)
        testing.expect(t, ok, "a stacked door has a partner")
        testing.expect_value(t, py, want % 2 == 0 ? y - 1 : y + 1)
    }

    gs.delta_time = 1.0/60.0
    update_enemies(gs)   // the waypoint is the lower door's foot
    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y), "the dug foot is gone")
    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y - 1), "its head goes with it")
    testing.expect(t, is_door(&gs.world, SMASH_X, SMASH_Y - 2), "the upper door keeps its foot")
    testing.expect(t, is_door(&gs.world, SMASH_X, SMASH_Y - 3), "the upper door keeps its head")
    testing.expect_value(t, turret_ground_count(gs, .Door), 1)

    smash_tile(gs, SMASH_X, SMASH_Y - 3)   // the upper door, by its head
    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y - 2), "no half door stays standing")
    testing.expect_value(t, turret_ground_count(gs, .Door), 2)
}

// The door's far half goes the way a mined tile goes: what leaned on it falls,
// and a golem's mark on it is struck from the list.
@(test)
a_dug_doors_far_half_lets_go_of_what_leaned_on_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Door)
    set_tile(&gs.world, SMASH_X, SMASH_Y - 1, .Door)
    set_tile(&gs.world, SMASH_X, SMASH_Y - 2, .Wood)   // rests on the door's head alone
    head := [2]i32{SMASH_X, SMASH_Y - 1}
    testing.expect(t, golem_set_block_mark(gs, head, true), "the head takes a mark")
    testing.expect_value(t, gs.golem_marks.count, 1)

    gs.delta_time = 1.0/60.0
    update_enemies(gs)

    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y - 1), "the head is gone")
    testing.expect(t, get_tile(&gs.world, SMASH_X, SMASH_Y - 2) != .Wood, "the wood let go")
    testing.expect(t, .Golem_Marked not_in gs.world.tile_flags[grid_idx(SMASH_X, SMASH_Y - 1)], "the mark goes")
    testing.expect_value(t, gs.golem_marks.count, 0)
}

// A lone half, which older saves can hold, has no partner: the dig takes that
// tile and not the block above it.
@(test)
a_dig_through_a_lone_half_door_stops_at_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Door)
    set_tile(&gs.world, SMASH_X, SMASH_Y - 1, .Stone)
    _, _, ok := door_partner(&gs.world, SMASH_X, SMASH_Y)
    testing.expect(t, !ok, "a lone half has no partner")

    gs.delta_time = 1.0/60.0
    update_enemies(gs)

    testing.expect(t, !is_door(&gs.world, SMASH_X, SMASH_Y), "the half is dug")
    testing.expect_value(t, get_tile(&gs.world, SMASH_X, SMASH_Y - 1), Tile_Type.Stone)
}

// Above the surface line the far half opens to air, as a mined tile does, not
// to the void of a cave.
@(test)
a_dug_door_on_the_surface_opens_its_far_half_to_air :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    foot := SURFACE_Y - 2
    set_tile(&gs.world, 62, foot, .Door)
    set_tile(&gs.world, 62, foot - 1, .Door)

    smash_tile(gs, 62, foot)

    testing.expect_value(t, get_tile(&gs.world, 62, foot - 1), Tile_Type.Air)
}
