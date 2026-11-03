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

// ─── A dig is a mine, and pays once (card 103) ────────────────────────────────

// Turn the fixture's raider into Garm, his body pressed against the waypoint.
smash_test_garm :: proc(gs: ^Game_State) -> ^Enemy {
    e := smash_test_builder(gs)
    e.kind, e.hp, e.hp_max = .Garm, GARM_HP, GARM_HP
    e.pos = {SMASH_X - 1.8, SMASH_Y + 1 - GARM_H}
    e.facing = 1
    e.builder.den_built = true
    return e
}

smash_test_miner :: proc(gs: ^Game_State, level: int, base: [2]i32) {
    gs.level_index = level
    gs.dimension.kind = .Metal
    gs.dimension.miner = {active = true, base = base, head = base}
}

@(test)
a_dug_auto_miner_releases_the_anchor :: proc(t: ^testing.T) {
    for garm in ([]bool{false, true}) {
        gs := turret_test_state()
        defer free(gs)
        if garm do smash_test_garm(gs)
        else do smash_test_builder(gs)
        smash_test_miner(gs, LEVEL_DIMENSION, {SMASH_X, SMASH_Y})
        set_tile(&gs.world, SMASH_X, SMASH_Y, .Auto_Miner)

        gs.delta_time = 1.0/60.0
        update_enemies(gs)

        testing.expect(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != .Auto_Miner, "the miner was dug out")
        testing.expect(t, !gs.dimension.miner.active, "the anchor goes with its base")
        testing.expect_value(t, turret_ground_count(gs, .Auto_Miner), 1)
    }
}

// A miner that is not the base anchors nothing: digging it holds the anchor.
@(test)
a_dug_spare_auto_miner_keeps_the_anchor :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    smash_test_miner(gs, LEVEL_DIMENSION, {SMASH_X + 9, SMASH_Y})
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Auto_Miner)
    gs.delta_time = 1.0/60.0
    update_enemies(gs)
    testing.expect(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != .Auto_Miner, "the miner was dug out")
    testing.expect(t, gs.dimension.miner.active, "the anchor holds")
}

// The release valve: losing a spawner of the anchored kind may not lock every
// gate, and an enemy's dig loses it as surely as the player's pick.
@(test)
a_dug_spawner_opens_the_release_valve :: proc(t: ^testing.T) {
    Case :: struct {level: int, tile: Tile_Type, active: bool}
    for c in ([]Case{
        {LEVEL_SURFACE,   .Dimension_Spawner,      false},
        {LEVEL_SURFACE,   .Dimension_Spawner_Gold, true},   // another kind's
        {LEVEL_DIMENSION, .Dimension_Spawner,      true},   // not out in the world
    }) {
        gs := turret_test_state()
        defer free(gs)
        smash_test_builder(gs)
        smash_test_miner(gs, c.level, {5, 5})
        set_tile(&gs.world, SMASH_X, SMASH_Y, c.tile)
        gs.delta_time = 1.0/60.0
        update_enemies(gs)
        testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile, "%v was dug out", c.tile)
        testing.expectf(t, gs.dimension.miner.active == c.active, "%v on level %d", c.tile, c.level)
    }
}

// A block goes to the ground or into the pocket, never both.  Each of the three
// digs a builder makes, on a machine that drops itself and on stone that does not.
@(test)
a_dig_pays_the_pocket_only_for_what_it_did_not_drop :: proc(t: ^testing.T) {
    Dig :: enum {Waypoint, Climb, Pillar}
    for dig in Dig do for tile in ([]Tile_Type{.Smelter, .Stone}) {
        gs := turret_test_state()
        defer free(gs)
        e := smash_test_builder(gs)
        at := [2]int{SMASH_X, SMASH_Y}
        switch dig {
        case .Waypoint:
        case .Climb:
            at = {SMASH_X - 1, SMASH_Y - 1}
            e.nav.path.tiles[0] = {SMASH_X, SMASH_Y - 1}
        case .Pillar:
            at = {SMASH_X - 1, SMASH_Y - 1}
            e.builder.escaping = true
            e.builder.escape_from = SMASH_Y
        }
        set_tile(&gs.world, at.x, at.y, tile)
        drop0 := turret_ground_count(gs, terrain_table[tile].drop_item)

        gs.delta_time = 1.0/60.0
        update_enemies(gs)

        testing.expectf(t, get_tile(&gs.world, at.x, at.y) != tile, "%v: %v was dug out", dig, tile)
        dropped := turret_ground_count(gs, terrain_table[tile].drop_item) - drop0
        testing.expectf(t, int(e.builder.pocket) + dropped == 1,
            "%v: %v paid pocket %d and ground %d", dig, tile, e.builder.pocket, dropped)
    }
}

@(test)
a_dug_door_pays_no_pocket_block :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_builder(gs)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Door)
    set_tile(&gs.world, SMASH_X, SMASH_Y - 1, .Door)
    gs.delta_time = 1.0/60.0
    update_enemies(gs)
    testing.expect_value(t, turret_ground_count(gs, .Door), 1)
    testing.expect_value(t, e.builder.pocket, 0)
}

// Garm's dig is the same demolition, from update_garm.
@(test)
garm_digs_a_loaded_machine_like_any_digger :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    e := smash_test_garm(gs)
    MY :: SMASH_Y - 1   // the top row of his body: he swings top down
    set_tile(&gs.world, SMASH_X, MY, .Smelter)
    set_tile(&gs.world, SMASH_X, MY - 1, .Wood)   // rests on the smelter alone
    sd := &gs.world.sim_data[grid_idx(SMASH_X, MY)]
    sd.store_item, sd.store_count = .Iron_Bar, 2

    gs.delta_time = 1.0/60.0
    update_enemies(gs)

    testing.expect(t, get_tile(&gs.world, SMASH_X, MY) != .Smelter, "he dug it out")
    testing.expect_value(t, turret_ground_count(gs, .Iron_Bar), 2)
    testing.expect_value(t, turret_ground_count(gs, .Smelter), 1)
    testing.expect(t, get_tile(&gs.world, SMASH_X, MY - 1) != .Wood, "the wood let go")
    testing.expect(t, e.nav.mine_timer > 0, "the dig costs him the swing")
}

@(test)
a_dug_block_lets_go_of_what_leaned_on_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Stone)
    set_tile(&gs.world, SMASH_X, SMASH_Y - 1, .Wood)   // rests on the stone alone
    gs.delta_time = 1.0/60.0
    update_enemies(gs)
    testing.expect(t, !is_solid(&gs.world, SMASH_X, SMASH_Y), "the stone was dug out")
    testing.expect(t, get_tile(&gs.world, SMASH_X, SMASH_Y - 1) != .Wood, "the wood let go")
}

// The tile's records go with it: nothing marks an empty cell as built.
@(test)
a_dug_block_takes_its_marks_with_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    idx := grid_idx(SMASH_X, SMASH_Y)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Stone)
    gs.world.tile_flags[idx] += {.Placed, .Golem_Placed}
    testing.expect(t, golem_set_block_mark(gs, {SMASH_X, SMASH_Y}, true), "the block takes a mark")
    testing.expect_value(t, gs.golem_marks.count, 1)

    gs.delta_time = 1.0/60.0
    dig_frames_until_open(gs, SMASH_X, SMASH_Y)

    testing.expect(t, !is_solid(&gs.world, SMASH_X, SMASH_Y), "the stone was dug out")
    testing.expect(t, .Placed not_in gs.world.tile_flags[idx], "the Placed flag goes")
    testing.expect(t, .Golem_Placed not_in gs.world.tile_flags[idx], "the Golem_Placed flag goes")
    testing.expect(t, .Golem_Marked not_in gs.world.tile_flags[idx], "the mark goes")
    testing.expect_value(t, gs.golem_marks.count, 0)
}

// A dig opens what a mine opens: sky stays sky, and a cave stays void.
@(test)
a_dig_opens_air_above_the_surface_line :: proc(t: ^testing.T) {
    {
        gs := turret_test_state()
        defer free(gs)
        smash_test_builder(gs)
        gs.level_index = LEVEL_SKY
        set_tile(&gs.world, SMASH_X, SMASH_Y, .Stone)
        gs.delta_time = 1.0/60.0
        update_enemies(gs)
        testing.expect_value(t, get_tile(&gs.world, SMASH_X, SMASH_Y), Tile_Type.Air)
    }
    {
        gs := turret_test_state()
        defer free(gs)
        set_tile(&gs.world, 62, SURFACE_Y - 2, .Stone)
        set_tile(&gs.world, 64, SURFACE_Y + 2, .Stone)
        smash_tile(gs, 62, SURFACE_Y - 2)
        smash_tile(gs, 64, SURFACE_Y + 2)
        testing.expect_value(t, get_tile(&gs.world, 62, SURFACE_Y - 2), Tile_Type.Air)
        testing.expect_value(t, get_tile(&gs.world, 64, SURFACE_Y + 2), Tile_Type.Void)
    }
}
