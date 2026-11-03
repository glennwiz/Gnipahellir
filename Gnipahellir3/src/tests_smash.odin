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

// ─── A smashed monument gives back what it was built from (card 147) ──────────
//
//  Agent run 8: a Vargr tore a finished Clay Hearth down and its Iron Bar and
//  masonry were simply gone - the player may never reclaim a monument, so the
//  smash was the only way out for them.

// A golem-built cell of plan `plan` at (SMASH_X, SMASH_Y), as golem_place_reserved
// leaves it: marked in monument_cells, and masonry carries .Placed.
smash_test_monument_cell :: proc(gs: ^Game_State, plan: Golem_Plan, c: Golem_Build_Cell) {
    T := [2]i32{SMASH_X, SMASH_Y}
    gs.golems.projects[gs.level_index] = {active = true, plan = plan, level = gs.level_index, anchor = T - c.off}
    set_tile(&gs.world, SMASH_X, SMASH_Y, c.tile)
    gs.monument_cells[gs.level_index][grid_idx(SMASH_X, SMASH_Y)] = c.tile
    if !is_structure_tile[c.tile] do gs.world.tile_flags[grid_idx(SMASH_X, SMASH_Y)] += {.Placed}
}

// The anchor's Gold_Ore cell: built from a Gold_Bar, and what a natural or a
// player-laid Gold_Ore must never pay.
smash_test_gold_cell :: proc() -> (c: Golem_Build_Cell) {
    for cell in golem_plan_table[.World_Anchor].cells do if cell.tile == .Gold_Ore do return cell
    return
}

// A digger through a monument's masonry drops the item that cell was built
// from, and pockets nothing for it.
@(test)
a_dig_through_monument_masonry_drops_its_build_item :: proc(t: ^testing.T) {
    for plan in ([]Golem_Plan{.Clay_Hearth, .Golem_Depot, .World_Anchor}) {
        for c in golem_plan_table[plan].cells {
            if is_structure_tile[c.tile] do continue
            gs := turret_test_state()
            defer free(gs)
            e := smash_test_builder(gs)
            smash_test_monument_cell(gs, plan, c)
            item0 := turret_ground_count(gs, c.item)

            gs.delta_time = 1.0/60.0
            for _ in 0 ..< 600 {
                update_enemies(gs)
                if get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile do break
            }

            testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile, "%v %v was dug out", plan, c.off)
            testing.expectf(t, turret_ground_count(gs, c.item) - item0 == 1, "%v %v drops its %v", plan, c.off, c.item)
            testing.expectf(t, e.builder.pocket == 0, "%v %v pays no pocket block", plan, c.off)
        }
    }
}

// The wave hunter's demolition of a monument core drops the item it was built
// from - the Hearth's Iron Bar of run 8.
@(test)
a_raider_smashing_a_monument_core_drops_its_build_item :: proc(t: ^testing.T) {
    for plan in ([]Golem_Plan{.Clay_Hearth, .Golem_Depot, .World_Anchor}) {
        for c in golem_plan_table[plan].cells {
            if !is_structure_tile[c.tile] do continue
            gs := turret_test_state()
            defer free(gs)
            e := smash_test_builder(gs)
            e.kind = .Vargr
            T := [2]i32{SMASH_X, SMASH_Y}
            e.builder = {goal = .Wave_Hunt, target_tile = T, has_target = true, plan_target = T}
            smash_test_monument_cell(gs, plan, c)
            item0 := turret_ground_count(gs, c.item)

            update_raider(e, 0, gs, 0.1)

            testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile, "%v core was smashed", plan)
            testing.expectf(t, turret_ground_count(gs, c.item) - item0 == 1, "%v core drops its %v", plan, c.item)
        }
    }
}

// Only a cell a golem built pays its build item: natural ore left standing in
// the footprint, ore the player laid there (card 151), a mark on another tile,
// and another block laid where a marked cell was, dig as ever.
@(test)
a_dig_on_an_unbuilt_cell_keeps_its_old_drop :: proc(t: ^testing.T) {
    c := smash_test_gold_cell()
    for Case in ([]string{"natural", "player laid", "mark elsewhere", "other block"}) {
        gs := turret_test_state()
        defer free(gs)
        e := smash_test_builder(gs)
        smash_test_monument_cell(gs, .World_Anchor, c)
        idx := grid_idx(SMASH_X, SMASH_Y)
        tile := c.tile
        switch Case {
        case "natural":
            gs.monument_cells[gs.level_index][idx] = .Air
            gs.world.tile_flags[idx] -= {.Placed}
        case "player laid":
            gs.monument_cells[gs.level_index][idx] = .Air
        case "mark elsewhere":
            gs.monument_cells[gs.level_index][idx] = .Air
            gs.monument_cells[gs.level_index][grid_idx(SMASH_X + 1, SMASH_Y)] = c.tile
        case "other block":
            set_tile(&gs.world, SMASH_X, SMASH_Y, .Stone)
            tile = .Stone
        }

        gs.delta_time = 1.0/60.0
        for _ in 0 ..< 600 {
            update_enemies(gs)
            if get_tile(&gs.world, SMASH_X, SMASH_Y) != tile do break
        }

        testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != tile, "%s: the block was dug out", Case)
        testing.expectf(t, turret_ground_count(gs, .Gold_Bar) == 0, "%s: no Gold Bar is minted", Case)
        testing.expectf(t, e.builder.pocket == 1, "%s: the dig pockets its block", Case)
    }
}

// Card 151: the player's own Gold_Ore laid in an anchor's gold cell mines back
// as Gold_Ore, not as the Gold_Bar a golem would have built it from.
@(test)
a_pick_on_player_laid_ore_in_a_monument_pays_the_ore :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    smash_test_monument_cell(gs, .World_Anchor, smash_test_gold_cell())
    gs.monument_cells[gs.level_index][grid_idx(SMASH_X, SMASH_Y)] = .Air   // laid by hand
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {SMASH_X, SMASH_Y}})
    process_events(gs)
    testing.expect_value(t, turret_ground_count(gs, .Gold_Ore), 1)
    testing.expect_value(t, turret_ground_count(gs, .Gold_Bar), 0)
}

// Review probe (evidence 6616): a finished Hearth, then the next monument
// marked on the same level overwrites the project record.  The Hearth still
// pays its build items, its core to a raider and its wood to a pick.
@(test)
a_monument_pays_its_build_items_after_the_next_is_marked :: proc(t: ^testing.T) {
    T := [2]i32{SMASH_X, SMASH_Y}
    core, wood: Golem_Build_Cell
    for c in golem_plan_table[.Clay_Hearth].cells {
        if c.tile == .Clay_Hearth do core = c
        if c.tile == .Wood do wood = c
    }
    for c in ([]Golem_Build_Cell{core, wood}) {
        gs := turret_test_state()
        defer free(gs)
        e := smash_test_builder(gs)
        smash_test_monument_cell(gs, .Clay_Hearth, c)
        lvl := gs.level_index
        gs.golems.projects[lvl] = {active = true, plan = .Golem_Depot, level = lvl, anchor = T + {20, 0}}
        item0 := turret_ground_count(gs, c.item)
        if c.tile == .Clay_Hearth {
            e.kind = .Vargr
            e.builder = {goal = .Wave_Hunt, target_tile = T, has_target = true, plan_target = T}
            update_raider(e, 0, gs, 0.1)
        } else {
            eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = T})
            process_events(gs)
            testing.expect_value(t, turret_ground_count(gs, .Wood_Log), 0)
        }
        testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile, "%v was taken", c.tile)
        testing.expectf(t, turret_ground_count(gs, c.item) - item0 == 1, "%v pays its %v", c.tile, c.item)
    }
}

// The mark belongs to the cell: once taken, the cell pays its build item no
// more, and a block laid there later is the player's.
@(test)
a_taken_monument_cell_forgets_its_mark :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    c := smash_test_gold_cell()
    smash_test_monument_cell(gs, .World_Anchor, c)
    smash_tile(gs, SMASH_X, SMASH_Y)
    testing.expect_value(t, turret_ground_count(gs, .Gold_Bar), 1)
    set_tile(&gs.world, SMASH_X, SMASH_Y, .Gold_Ore)
    smash_tile(gs, SMASH_X, SMASH_Y)
    testing.expect_value(t, turret_ground_count(gs, .Gold_Bar), 1)
}

// A golem laying a monument cell marks it.
@(test)
a_golem_laying_a_monument_cell_marks_it :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    c := smash_test_gold_cell()
    ci := -1
    for cell, i in golem_plan_table[.World_Anchor].cells do if cell == c { ci = i; break }
    T := [2]i32{SMASH_X, SMASH_Y}
    gs.golems.projects[gs.level_index] = {active = true, plan = .World_Anchor, level = gs.level_index, anchor = T - c.off}
    g := &gs.golems.data[0]
    g^ = {status = .Deployed, level = gs.level_index, pos = {SMASH_X - 1, SMASH_Y}, carry = c.item, project_cell = i16(ci)}

    golem_place_reserved(gs, 0)

    testing.expect_value(t, get_tile(&gs.world, SMASH_X, SMASH_Y), c.tile)
    testing.expect_value(t, gs.monument_cells[gs.level_index][grid_idx(SMASH_X, SMASH_Y)], c.tile)
}

// A monument block that falls out of its cell leaves the mark behind it.
@(test)
a_falling_monument_block_leaves_its_mark :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    c: Golem_Build_Cell
    for cell in golem_plan_table[.Clay_Hearth].cells do if cell.tile == .Stone { c = cell; break }
    smash_test_monument_cell(gs, .Clay_Hearth, c)
    gravity_spawn(gs, SMASH_X, SMASH_Y, c.tile)
    testing.expect_value(t, gs.monument_cells[gs.level_index][grid_idx(SMASH_X, SMASH_Y)], Tile_Type.Air)
}

// A manufactured world made fresh keeps no marks from the one before it.
@(test)
a_fresh_dimension_forgets_its_monuments :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    gs.monument_cells[LEVEL_DIMENSION][grid_idx(10, 10)] = .Gold_Ore
    dimension_enter(gs, {SMASH_X, SMASH_Y}, .Metal)
    testing.expect_value(t, gs.monument_cells[LEVEL_DIMENSION][grid_idx(10, 10)], Tile_Type.Air)
}

// monument_build_item answers by tile, so no two plans may build one tile from
// different items.
@(test)
monument_tiles_have_one_build_item :: proc(t: ^testing.T) {
    for info in golem_plan_table do for c in info.cells {
        testing.expectf(t, monument_build_item(c.tile) == c.item, "%v %v is built from %v, the table says %v", info.name, c.off, c.item, monument_build_item(c.tile))
    }
}

// The den carve, the dig-free rescue and the mineral fetch each take a
// monument cell the same way: its build item lands, and the digger gets no
// pocket block or carried mineral on top of it.
@(test)
every_builder_dig_pays_a_monument_cell_once :: proc(t: ^testing.T) {
    Dig :: enum {Den_Carve, Dig_Free, Fetch}
    for dig in Dig {
        plan: Golem_Plan = .World_Anchor if dig == .Fetch else .Clay_Hearth
        want: Tile_Type  = .Gold_Ore if dig == .Fetch else .Stone
        c := Golem_Build_Cell{}
        for cell in golem_plan_table[plan].cells do if cell.tile == want { c = cell; break }
        gs := turret_test_state()
        defer free(gs)
        e := smash_test_builder(gs)
        smash_test_monument_cell(gs, plan, c)
        item0 := turret_ground_count(gs, c.item)

        switch dig {
        case .Den_Carve:
            builder_do_step(e, 0, gs, {SMASH_X, SMASH_Y}, .Void)
        case .Dig_Free:
            e.pos = {SMASH_X + (1 - BUILDER_W)*0.5, SMASH_Y + 1 - BUILDER_H}
            builder_dig_free(e, 0, gs)
        case .Fetch:
            e.builder = {goal = .Fetch_Mineral, carry = .Air, target_tile = {SMASH_X, SMASH_Y}, has_target = true}
            builder_fetch(e, 0, gs, 0.1)
        }

        testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile, "%v: the cell was taken", dig)
        testing.expectf(t, turret_ground_count(gs, c.item) - item0 == 1, "%v: drops its %v", dig, c.item)
        testing.expectf(t, e.builder.pocket == 0, "%v: no pocket block on top", dig)
        testing.expectf(t, e.builder.carry == .Air || dig != .Fetch, "%v: carries nothing home", dig)
    }
}

// The pick on a monument's masonry gets the same item back: a Plank-built Wood
// cell once paid a Wood Log, four planks for one.
@(test)
a_pick_on_monument_masonry_pays_its_build_item :: proc(t: ^testing.T) {
    for plan in ([]Golem_Plan{.Clay_Hearth, .Golem_Depot, .World_Anchor}) {
        for c in golem_plan_table[plan].cells {
            if is_structure_tile[c.tile] do continue
            gs := turret_test_state()
            defer free(gs)
            smash_test_builder(gs)   // the player stands far off: the drop lands
            smash_test_monument_cell(gs, plan, c)
            item0 := turret_ground_count(gs, c.item)
            old0  := turret_ground_count(gs, terrain_table[c.tile].drop_item)

            eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {SMASH_X, SMASH_Y}})
            process_events(gs)

            testing.expectf(t, get_tile(&gs.world, SMASH_X, SMASH_Y) != c.tile, "%v %v was mined", plan, c.off)
            testing.expectf(t, turret_ground_count(gs, c.item) - item0 == 1, "%v %v pays its %v", plan, c.off, c.item)
            if terrain_table[c.tile].drop_item != c.item {
                testing.expectf(t, turret_ground_count(gs, terrain_table[c.tile].drop_item) == old0, "%v %v pays no %v", plan, c.off, terrain_table[c.tile].drop_item)
            }
        }
    }
}

// Review probe (evidence 6739): a Gather golem on a monument cell inside its
// zone takes the cell through the same mark.  It packs the cell's build item,
// and ore the player lays there afterwards mines back as ore.
@(test)
a_gather_golem_on_a_monument_cell_packs_its_build_item :: proc(t: ^testing.T) {
    wood: Golem_Build_Cell
    for c in golem_plan_table[.Clay_Hearth].cells do if c.tile == .Wood { wood = c; break }
    for Case in ([]struct{plan: Golem_Plan, c: Golem_Build_Cell}{{.World_Anchor, smash_test_gold_cell()}, {.Clay_Hearth, wood}}) {
        gs := turret_test_state()
        defer free(gs)
        smash_test_builder(gs)
        gs.enemies = {}
        smash_test_monument_cell(gs, Case.plan, Case.c)
        T := [2]i32{SMASH_X, SMASH_Y}
        gs.golems.work[gs.level_index] = {active = true, min = T - 2, max = T + 2}
        g := &gs.golems.data[0]
        g^ = {status = .Deployed, level = gs.level_index, mode = .Gather, pos = {SMASH_X - 1, SMASH_Y}, project_cell = -1}

        testing.expectf(t, golem_mine_tile(gs, g, T, false, 0), "%v: the golem mines the cell", Case.c.tile)
        testing.expectf(t, golem_pack_has(g, Case.c.item), "%v: packs its %v", Case.c.tile, Case.c.item)
        testing.expectf(t, !golem_pack_has(g, terrain_table[Case.c.tile].drop_item), "%v: packs no %v", Case.c.tile, terrain_table[Case.c.tile].drop_item)
        testing.expect_value(t, gs.monument_cells[gs.level_index][grid_idx(SMASH_X, SMASH_Y)], Tile_Type.Air)

        if Case.c.tile == .Gold_Ore {
            set_tile(&gs.world, SMASH_X, SMASH_Y, .Gold_Ore)   // the player lays ore there
            eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = T})
            process_events(gs)
            testing.expect_value(t, turret_ground_count(gs, .Gold_Ore), 1)
            testing.expect_value(t, turret_ground_count(gs, .Gold_Bar), 0)
        }
    }
}

// A golem with a full pack leaves a monument cell, and its mark, alone.
@(test)
a_full_golem_leaves_a_monument_cell_marked :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    smash_test_builder(gs)
    c := smash_test_gold_cell()
    smash_test_monument_cell(gs, .World_Anchor, c)
    T := [2]i32{SMASH_X, SMASH_Y}
    gs.golems.work[gs.level_index] = {active = true, min = T - 2, max = T + 2}
    g := &gs.golems.data[0]
    g^ = {status = .Deployed, level = gs.level_index, mode = .Gather, pos = {SMASH_X - 1, SMASH_Y}, project_cell = -1}
    for &slot in g.pack do slot = .Dirt
    testing.expect(t, !golem_mine_tile(gs, g, T, false, 0), "a full golem does not mine")
    testing.expect_value(t, gs.monument_cells[gs.level_index][grid_idx(SMASH_X, SMASH_Y)], c.tile)
}
