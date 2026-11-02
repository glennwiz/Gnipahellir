package game

import "core:strings"
import "core:testing"

// A bench (or `t`) at (UX,UY) on one support tile, in open cells over a floor
// three rows down.  The player stands far off, so nothing is vacuumed up.
UX :: 70
UY :: 70

@(private = "file")
ground_count :: proc(w: ^World_Grid, item: Item) -> (n: int) {
    for it, i in w.items do if it == item do n += int(w.item_counts[i])
    return
}

@(private = "file")
under_site :: proc(t_: Tile_Type = .Crafting_Bench) -> ^Game_State {
    gs := turret_test_state()
    gs.level_index = LEVEL_CAVE2  // no wave director, no surface line to mind
    gs.ui.show_title = false
    gs.player.pos = {10, 10}
    // All open: only what the test lays down exists.
    for i in 0 ..< GRID_W * GRID_H {
        gs.world.terrain[i], gs.world.items[i], gs.world.item_counts[i] = .Void, .None, 0
    }
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    for x in UX - 6 ..= UX + 6 do set_tile(&gs.world, x, UY + 4, .Stone)
    for x in 5 ..= 15 do set_tile(&gs.world, x, 12, .Stone)
    set_tile(&gs.world, UX, UY + 1, .Stone)
    set_tile(&gs.world, UX, UY, t_)
    return gs
}

@(private = "file")
under_frames :: proc(gs: ^Game_State, n := 40) {
    for _ in 0 ..< n {
        gs.delta_time = 1.0 / 60.0
        game_update(gs)
    }
}

@(private = "file")
expect_landed :: proc(t: ^testing.T, gs: ^Game_State, it: Item, n := 1, loc := #caller_location) {
    testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Void, loc)
    testing.expect_value(t, ground_count(&gs.world, it), n, loc)
    rests := false  // on the floor, or on the support's own drop
    for y in UY + 2 ..= UY + 3 do if gs.world.items[grid_idx(UX, y)] == it do rests = true
    testing.expect(t, rests, "it fell and landed", loc = loc)
}

@(test)
a_structure_on_ground_stands :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    set_tile(&gs.world, UX, UY - 1, .Smelter)
    set_tile(&gs.world, UX + 1, UY + 3, .Door)
    set_tile(&gs.world, UX + 1, UY + 2, .Door)
    under_frames(gs)
    testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Crafting_Bench)
    testing.expect_value(t, get_tile(&gs.world, UX, UY - 1), Tile_Type.Smelter)
    testing.expect_value(t, get_tile(&gs.world, UX + 1, UY + 2), Tile_Type.Door)
    testing.expect_value(t, get_tile(&gs.world, UX + 1, UY + 3), Tile_Type.Door)
}

@(test)
pick_under_a_structure_breaks_it :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {UX, UY + 1}})
    under_frames(gs)
    expect_landed(t, gs, .Crafting_Bench)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Crafting_Bench), 0)
}

// The world did it, not the player: the item falls, it is never banked.
@(test)
a_break_beside_the_player_still_falls :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    gs.player.pos = {UX + 2, UY - 1}
    gs.player.vel = {}
    smash_tile(gs, UX, UY + 1)
    update_undermined(gs)
    process_events(gs)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Crafting_Bench), 0)
    testing.expect_value(t, ground_count(&gs.world, .Crafting_Bench), 1)
}

@(test)
enemy_smash_under_a_structure_breaks_it :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    smash_tile(gs, UX, UY + 1)
    under_frames(gs)
    expect_landed(t, gs, .Crafting_Bench)
}

// Garm's own digger, the proc his update runs.
@(test)
garm_under_a_structure_breaks_it :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    id, ok := enemy_alloc(&gs.enemies)
    testing.expect(t, ok)
    gs.enemies.data[id] = Enemy{kind = .Garm, hp = 10, hp_max = 10}
    handle_tile_mined(gs, Event{type = .Tile_Mined, source = enemy_entity_id(id), tile = {UX, UY + 1}})
    enemy_free(&gs.enemies, id)
    under_frames(gs)
    expect_landed(t, gs, .Crafting_Bench)
}

// The support itself falls away: a wood block with its own ground mined.  The
// bench on it must not count as what holds it up.
@(test)
gravity_under_a_structure_breaks_it :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    set_tile(&gs.world, UX, UY + 1, .Wood)
    set_tile(&gs.world, UX, UY + 2, .Stone)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {UX, UY + 2}})
    under_frames(gs, 120)
    testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, UX, UY + 1), Tile_Type.Void)
    testing.expect_value(t, ground_count(&gs.world, .Crafting_Bench), 1)
}

// Clear ground and lay `cells`, one tile each.
@(private = "file")
under_build :: proc(gs: ^Game_State, cells: []struct{ x, y: int, t: Tile_Type }) {
    for x in UX - 6 ..= UX + 6 do set_tile(&gs.world, x, UY + 1, .Void)
    set_tile(&gs.world, UX, UY, .Void)
    for c in cells do set_tile(&gs.world, c.x, c.y, c.t)
}

// Review of card 97: a wood floor on one stilt, a post and a bench on the floor.
// The bench stands on the piece, so it must not hold the piece up.
@(test)
a_hut_does_not_hang_off_its_own_bench :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    under_build(gs, {{72, 70, .Wood}, {71, 70, .Crafting_Bench}, {70, 72, .Stone}})
    for x in 68 ..= 72 do set_tile(&gs.world, x, 71, .Wood)
    set_tile(&gs.world, 70, 73, .Stone)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {70, 72}})
    under_frames(gs, 300)
    for x in 68 ..= 72 do testing.expect_value(t, get_tile(&gs.world, x, 71), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, 71, 70), Tile_Type.Void)
    testing.expect_value(t, ground_count(&gs.world, .Crafting_Bench), 1)
}

@(test)
a_hut_does_not_hang_off_its_own_door :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    under_build(gs, {{70, 70, .Door}, {70, 69, .Door}, {71, 72, .Stone}, {71, 73, .Stone}})
    for x in 68 ..= 72 {
        set_tile(&gs.world, x, 68, .Wood)
        set_tile(&gs.world, x, 71, .Wood)
    }
    for y in 69 ..= 70 do set_tile(&gs.world, 68, y, .Wood)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {71, 72}})
    under_frames(gs, 300)
    testing.expect_value(t, get_tile(&gs.world, 70, 70), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, 70, 69), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, 70, 68), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, 70, 71), Tile_Type.Void)
    testing.expect_value(t, ground_count(&gs.world, .Door), 1)
}

// A beam hung on a grounded structure stays: that is what the anchor is for.
@(test)
a_grounded_structure_still_holds_a_hung_beam :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    set_tile(&gs.world, UX + 1, UY, .Wood)
    set_tile(&gs.world, UX + 2, UY, .Wood)
    set_tile(&gs.world, UX + 3, UY, .Wood)
    set_tile(&gs.world, UX + 3, UY + 1, .Stone)  // the beam's own prop
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {UX + 3, UY + 1}})
    under_frames(gs, 120)
    testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Crafting_Bench)
    testing.expect_value(t, get_tile(&gs.world, UX + 3, UY), Tile_Type.Wood)
}

// Same, one storey up: the bench stands on a stack, the stack on natural stone.
@(test)
a_stack_on_ground_still_holds_a_hung_beam :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    set_tile(&gs.world, UX, UY - 1, .Smelter)
    set_tile(&gs.world, UX + 1, UY - 1, .Wood)
    set_tile(&gs.world, UX + 2, UY - 1, .Wood)
    set_tile(&gs.world, UX + 2, UY, .Stone)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {UX + 2, UY}})
    under_frames(gs, 120)
    testing.expect_value(t, get_tile(&gs.world, UX + 2, UY - 1), Tile_Type.Wood)
}

// A hoard left floating stands, but it is no ground for anything else.
@(test)
a_floating_hoard_holds_no_beam_up :: proc(t: ^testing.T) {
    gs := under_site(.Barrel); defer free(gs)
    barrel_on_placed(gs, {UX, UY})
    barrel_at(gs, gs.level_index, {UX, UY}).slots[0] = {.Dirt, 5}
    set_tile(&gs.world, UX, UY + 1, .Void)
    set_tile(&gs.world, UX + 1, UY, .Wood)
    set_tile(&gs.world, UX + 2, UY, .Wood)
    set_tile(&gs.world, UX + 2, UY + 1, .Stone)
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {UX + 2, UY + 1}})
    under_frames(gs, 120)
    testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Barrel)
    testing.expect_value(t, get_tile(&gs.world, UX + 1, UY), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, UX + 2, UY), Tile_Type.Void)
}

@(test)
a_stack_comes_down_a_tile_at_a_time :: proc(t: ^testing.T) {
    gs := under_site(); defer free(gs)
    set_tile(&gs.world, UX, UY - 1, Tile_Type.Smelter)
    smash_tile(gs, UX, UY + 1)
    under_frames(gs)
    testing.expect_value(t, get_tile(&gs.world, UX, UY - 1), Tile_Type.Void)
    expect_landed(t, gs, .Crafting_Bench)
    testing.expect_value(t, ground_count(&gs.world, .Smelter), 1)
}

@(test)
every_placeable_structure_but_the_gates_breaks :: proc(t: ^testing.T) {
    for tile in Tile_Type {
        if .Placeable not_in terrain_table[tile].flags do continue
        drop := terrain_table[tile].drop_item
        gs := under_site(tile); defer free(gs)
        smash_tile(gs, UX, UY + 1)
        under_frames(gs)
        #partial switch tile {
        case .Sky_Altar, .Rune_Altar, .Dimension_Spawner, .Dimension_Spawner_Gold, .Dimension_Spawner_Runic:
            testing.expect_value(t, get_tile(&gs.world, UX, UY), tile)
            testing.expect_value(t, ground_count(&gs.world, drop), 0)
        case:
            testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Void)
            testing.expect_value(t, ground_count(&gs.world, drop), 1)
        }
    }
}

@(test)
gates_stay_up_with_no_ground :: proc(t: ^testing.T) {
    gates := [?]Tile_Type{.Sky_Altar, .Rune_Altar, .Dimension_Spawner, .Dimension_Spawner_Gold,
        .Dimension_Spawner_Runic, .Rune_Scroll_Chest_A, .Sky_Rune_Scroll_Chest, .Cave_Entrance}
    for gate in gates {
        gs := under_site(gate); defer free(gs)
        smash_tile(gs, UX, UY + 1)
        under_frames(gs)
        testing.expect_value(t, get_tile(&gs.world, UX, UY), gate)
    }
}

@(test)
a_door_comes_down_whole :: proc(t: ^testing.T) {
    gs := under_site(.Door); defer free(gs)
    set_tile(&gs.world, UX, UY - 1, .Door)
    smash_tile(gs, UX, UY + 1)
    under_frames(gs)
    testing.expect_value(t, get_tile(&gs.world, UX, UY - 1), Tile_Type.Void)
    expect_landed(t, gs, .Door)
}

@(test)
an_undermined_machine_spills_what_it_held :: proc(t: ^testing.T) {
    gs := under_site(.Smelter); defer free(gs)
    sd := &gs.world.sim_data[grid_idx(UX, UY)]
    sd.in_item, sd.in_count = .Iron_Ore, 3
    sd.fuel_count = 2
    sd.store_item, sd.store_count = .Iron_Bar, 1
    smash_tile(gs, UX, UY + 1)
    under_frames(gs)
    testing.expect_value(t, ground_count(&gs.world, .Smelter), 1)
    testing.expect_value(t, ground_count(&gs.world, .Iron_Ore), 3)
    testing.expect_value(t, ground_count(&gs.world, FUEL_ITEM), 2)
    testing.expect_value(t, ground_count(&gs.world, .Iron_Bar), 1)
}

@(test)
a_turret_comes_down_in_parts :: proc(t: ^testing.T) {
    gs := under_site(.Turret_Pillar); defer free(gs)
    set_tile(&gs.world, UX, UY - 1, .Flame_Turret)
    smash_tile(gs, UX, UY + 1)
    under_frames(gs)
    testing.expect_value(t, get_tile(&gs.world, UX, UY - 1), Tile_Type.Void)
    testing.expect_value(t, ground_count(&gs.world, .Turret_Pillar), 1)
    testing.expect_value(t, ground_count(&gs.world, .Flame_Head), 1)
}

// A hoard is too heavy to break, under a pick or here; empty, it falls.
@(test)
a_loaded_hoard_stands_until_it_is_empty :: proc(t: ^testing.T) {
    gs := under_site(.Barrel); defer free(gs)
    tile := [2]i32{UX, UY}
    barrel_on_placed(gs, tile)
    b := barrel_at(gs, gs.level_index, tile)
    b.slots[0] = {.Dirt, 5}
    smash_tile(gs, UX, UY + 1)
    gs.notify.count = 0
    under_frames(gs)
    testing.expect_value(t, get_tile(&gs.world, UX, UY), Tile_Type.Barrel)
    testing.expect_value(t, gs.notify.count, 0)  // no refusal every frame

    b.slots[0] = {}
    under_frames(gs)
    expect_landed(t, gs, .Barrel)
    testing.expect(t, barrel_at(gs, gs.level_index, tile) == nil, "the record goes with the tile")
}

@(test)
a_loaded_miner_stands_until_it_is_empty :: proc(t: ^testing.T) {
    gs := under_site(.Auto_Miner); defer free(gs)
    m := &gs.dimension.miner
    m.active = true
    m.base = {UX, UY}
    miner_haul_add(m, .Stone_Block, 4)
    testing.expect(t, holds_hoard(gs, UX, UY), "a full haul holds it")
    m.base = {UX + 1, UY}
    testing.expect(t, !holds_hoard(gs, UX, UY), "the haul is on the base, not on any miner")
    m.base = {UX, UY}
    m.haul = {}
    testing.expect(t, !holds_hoard(gs, UX, UY), "an empty one does not")
}

@(test)
nothing_goes_up_where_it_would_break :: proc(t: ^testing.T) {
    gs := under_site(.Air); defer free(gs)
    set_tile(&gs.world, UX, UY + 1, .Air)
    set_tile(&gs.world, UX + 1, UY, .Stone)  // a wall to hang on
    gs.player.pos = {UX - 3, UY - 1}
    for it in ([]Item{.Crafting_Bench, .Door, .Turret_Pillar}) {
        testing.expect(t, !placement_ok(gs, it, UX, UY), "a wall is not ground")
    }
    testing.expect(t, strings.contains(place_refusal(gs, .Crafting_Bench, UX, UY), "under it"), "the note says why")
    testing.expect(t, strings.contains(place_refusal(gs, .Door, UX, UY), "under them"), "the door note says why")

    set_tile(&gs.world, UX, UY + 1, .Stone)
    for it in ([]Item{.Crafting_Bench, .Door, .Turret_Pillar}) {
        testing.expect(t, placement_ok(gs, it, UX, UY), "on ground it stands")
    }
    set_tile(&gs.world, UX, UY + 1, .Air)
    testing.expect(t, placement_ok(gs, .Sky_Altar, UX, UY) == false, "the altar keeps its foundation rule")
}

// World gen must not hand out a structure that breaks on the first frame.
@(test)
fresh_levels_lose_nothing_to_the_rule :: proc(t: ^testing.T) {
    gs := turret_test_state(); defer free(gs)
    check :: proc(t: ^testing.T, gs: ^Game_State, loc := #caller_location) {
        for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
            testing.expect(t, !is_undermined(gs, x, y), "generated with no ground", loc = loc)
        }
    }
    check(t, gs)
    gs.level_index = LEVEL_CAVE2; gen_cave_level(&gs.world, 1, gs.world_seed); check(t, gs)
    gs.level_index = LEVEL_CAVE3; gen_cave_level(&gs.world, 2, gs.world_seed); check(t, gs)
    gs.level_index = LEVEL_SKY;   gen_sky_level(&gs.world, gs.world_seed);     check(t, gs)
}
