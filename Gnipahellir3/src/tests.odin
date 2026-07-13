package game

import "core:testing"
import "core:strings"
import "core:log"

// ─── Phase 3 system tests ─────────────────────────────────────────────────────
//
//  Run with: odin test src
//  Everything here drives the real game procs on a heap Game_State; audio is
//  uninitialized (audio_play no-ops) and no raylib window is required.

@(private = "file")
test_state :: proc() -> ^Game_State {
    gs := new(Game_State)
    game_state_init(gs)
    gs.delta_time = 1.0 / 60.0
    // Production spawns the pickaxe on the grass to be picked up; tests want a
    // ready-to-mine player, so hand it over directly (slot 0).
    inventory_insert(&gs.player.inventory, .Pickaxe, 1)
    return gs
}

@(test)
starter_pickaxe_waits_on_the_grass :: proc(t: ^testing.T) {
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)  // production init — not test_state's pickaxe handout

    // The player wakes empty-handed.
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Pickaxe), 0)

    // A pickaxe rests on the grass east of spawn.
    idx := grid_idx(GRID_W/2 - 4, SURFACE_Y - 1)
    testing.expect_value(t, gs.world.items[idx], Item.Pickaxe)

    // Walking onto it collects it and clears the tile.
    gs.player.pos = {f32(GRID_W/2 - 4), f32(SURFACE_Y) - PLAYER_H}
    player_pickup(gs)
    testing.expect(t, inventory_count(&gs.player.inventory, .Pickaxe) >= 1, "pickaxe not collected")
    testing.expect_value(t, gs.world.items[idx], Item.None)
}

@(test)
blueprint_overlay_tracks_the_active_objective :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // No blueprint found → nothing for the overlay to show.
    testing.expect_value(t, blueprint_active_tier(gs), -1)

    // Finding tier 0's blueprint makes it the active objective.
    gs.progression.blueprint_found[0] = true
    testing.expect_value(t, blueprint_active_tier(gs), 0)
    testing.expect_value(t, blueprint_unlocks_name(0), level_names[LEVEL_CAVE2])

    // Raising its structure advances to the next found blueprint, else none.
    gs.progression.sky_structure_complete[0] = true
    testing.expect_value(t, blueprint_active_tier(gs), -1)
    gs.progression.blueprint_found[1] = true
    testing.expect_value(t, blueprint_active_tier(gs), 1)
    testing.expect_value(t, blueprint_unlocks_name(1), level_names[LEVEL_CAVE3])
}

@(test)
placed_structures_can_be_reclaimed :: proc(t: ^testing.T) {
    // Anything you place, you can chip back up — it drops its own item.
    for tile in ([]Tile_Type{.Sky_Altar, .Crafting_Bench, .Tree_Grower, .Smelter}) {
        b := terrain_table[tile]
        testing.expect(t, .Mineable in b.flags, "placed structure must be mineable to reclaim")
        testing.expect(t, b.drop_item != .None, "placed structure must drop its item when mined")
    }
}

@(test)
sky_altar_requires_its_template :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    tpl := &structure_templates[0]  // tier A: stone + wood

    ax, ay := 70, 30  // clear sky, well above any tree

    // Bare ground → the altar has no foundation.
    ok, _ := structure_template_satisfied(&gs.world, tpl, ax, ay)
    testing.expect(t, !ok, "template should be unsatisfied on bare ground")

    // Lay 5 stone, then 3 wood centered on top.
    for dx in -2 ..= 2 { set_tile(&gs.world, ax + dx, ay + 2, .Stone) }
    for dx in -1 ..= 1 { set_tile(&gs.world, ax + dx, ay + 1, .Wood) }
    ok2, _ := structure_template_satisfied(&gs.world, tpl, ax, ay)
    testing.expect(t, ok2, "template should be satisfied once built")

    // A gap in the stone row breaks it, and reports the missing tile.
    set_tile(&gs.world, ax + 2, ay + 2, .Air)
    ok3, want := structure_template_satisfied(&gs.world, tpl, ax, ay)
    testing.expect(t, !ok3, "template should fail with a gap")
    testing.expect_value(t, want, Tile_Type.Stone)
}

@(test)
each_tier_raises_a_distinct_altar :: proc(t: ^testing.T) {
    // Every progression tier has its own template, and the deeper ones call for
    // silver and gold — so each blueprint reads differently.
    a := &structure_templates[0]
    b := &structure_templates[1]
    testing.expect(t, a.name != b.name, "tier A and B templates should differ")
    testing.expect(t, !structure_template_uses(a, .Gold_Ore), "tier A should not need gold")
    testing.expect(t, structure_template_uses(b, .Silver_Ore), "tier B should need silver")
    testing.expect(t, structure_template_uses(b, .Gold_Ore),   "tier B should need gold")

    // Silver and gold ore are placeable blocks (that's what the altars are built from).
    testing.expect_value(t, item_table[.Silver_Ore].place_tile, Tile_Type.Silver_Ore)
    testing.expect_value(t, item_table[.Gold_Ore].place_tile,   Tile_Type.Gold_Ore)
}

@(test)
camera_clamps_to_level_bounds :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // At zoom 1.0 the camera is pinned to level center — whole level visible,
    // identical to the pre-zoom view, wherever the player stands.
    gs.zoom = 1.0
    gs.player.pos = {5, 5}
    cam := game_camera(gs)
    testing.expect_value(t, cam.target.x, f32(SCREEN_W)*0.5)
    testing.expect_value(t, cam.target.y, f32(SCREEN_H)*0.5)

    // Zoomed 2x in the top-left corner: follows the player but clamps at the
    // edge (half-view = SCREEN/4 from the corner).
    gs.zoom = 2.0
    gs.player.pos = {0, 0}
    cam2 := game_camera(gs)
    testing.expect_value(t, cam2.target.x, f32(SCREEN_W)*0.25)
    testing.expect_value(t, cam2.target.y, f32(SCREEN_H)*0.25)
}

@(test)
player_actions_mark_autosave :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    testing.expect(t, !gs.save_dirty, "starts clean")

    // A pickup is a meaningful action → marks the run for autosave.
    eq_push(&gs.events, Event{type = .Item_Pickup, payload = {int_val = i32(Item.Stone_Block)}})
    process_events(gs)
    testing.expect(t, gs.save_dirty, "pickup marks dirty")

    // Movement must NOT trigger a save.
    gs.save_dirty = false
    eq_push(&gs.events, Event{type = .Player_Moved})
    process_events(gs)
    testing.expect(t, !gs.save_dirty, "movement does not mark dirty")
}

@(test)
pickup_collects_world_drops :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {10, 40}
    idx := grid_idx(10, 41)  // inside the player's 1.8-tile-tall AABB
    gs.world.items[idx]       = .Stone_Block
    gs.world.item_counts[idx] = 3

    player_pickup(gs)

    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 3)
    testing.expect_value(t, gs.world.items[idx], Item.None)
}

@(test)
blueprint_pickup_sets_progression :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {10, 40}
    idx := grid_idx(10, 41)
    gs.world.items[idx]       = .Blueprint_A
    gs.world.item_counts[idx] = 1

    player_pickup(gs)
    process_events(gs)

    testing.expect(t, gs.progression.blueprint_found[0], "blueprint A should set tier 0")
}

@(test)
placement_validates_and_places :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 32, SURFACE_Y - 1, .Air)  // clear any gen decoration
    inventory_insert(&gs.player.inventory, .Stone_Block, 5)
    gs.player.inventory.selected = 1   // slot 0 holds the starting Pickaxe

    // Valid: air tile on top of grass, within reach
    handle_place_request(gs, Event{tile = {32, i32(SURFACE_Y) - 1}})
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y - 1), Tile_Type.Stone)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 4)

    // Invalid: floating in mid-air (no solid neighbour)
    set_tile(&gs.world, 40, 20, .Air)
    handle_place_request(gs, Event{tile = {40, 20}})
    testing.expect_value(t, get_tile(&gs.world, 40, 20), Tile_Type.Air)

    // Invalid: out of reach
    handle_place_request(gs, Event{tile = {60, i32(SURFACE_Y) - 1}})
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 4)
}

@(test)
crafting_hand_and_bench :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    inv := &gs.player.inventory
    inventory_insert(inv, .Wood_Log, 2)

    // Recipe 0: 1 Wood_Log -> 4 Plank (hand)
    handle_craft_request(gs, Event{payload = {int_val = 0}})
    testing.expect_value(t, inventory_count(inv, .Plank), 4)
    testing.expect_value(t, inventory_count(inv, .Wood_Log), 1)

    // Recipe 2 (Smelter) needs a bench: must fail without one
    inventory_insert(inv, .Stone_Block, 8)
    inventory_insert(inv, .Iron_Ore, 2)
    handle_craft_request(gs, Event{payload = {int_val = 2}})
    testing.expect_value(t, inventory_count(inv, .Smelter), 0)

    // Place a bench next to the player and retry
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    handle_craft_request(gs, Event{payload = {int_val = 2}})
    testing.expect_value(t, inventory_count(inv, .Smelter), 1)
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 0)
}

@(test)
ritual_consumes_and_unlocks :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inv := &gs.player.inventory
    gs.level_index = LEVEL_SKY  // ritual is gated to the sky level
    gs.progression.blueprint_found[0] = true

    // Missing materials: nothing happens
    handle_ritual_request(gs)
    process_events(gs)
    testing.expect(t, !gs.progression.sky_structure_complete[0], "no materials, no structure")

    inventory_insert(inv, .Cloud_Stone, 8)
    inventory_insert(inv, .Plank, 4)
    handle_ritual_request(gs)
    process_events(gs)

    testing.expect(t, gs.progression.sky_structure_complete[0], "structure A complete")
    testing.expect(t, gs.progression.cave_unlocked[0], "cave 2 unlocked")
    testing.expect_value(t, inventory_count(inv, .Cloud_Stone), 0)
    testing.expect_value(t, inventory_count(inv, .Plank), 0)
}

@(test)
ritual_gated_to_sky_level :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Blueprint + full materials, but standing on the surface (C4): the
    // altar must refuse and explain itself.
    inv := &gs.player.inventory
    gs.progression.blueprint_found[0] = true
    inventory_insert(inv, .Cloud_Stone, 8)
    inventory_insert(inv, .Plank, 4)

    handle_ritual_request(gs)
    process_events(gs)

    testing.expect(t, !gs.progression.sky_structure_complete[0], "ritual must not fire off the sky level")
    testing.expect_value(t, inventory_count(inv, .Cloud_Stone), 8)
    testing.expect_value(t, gs.notify.count, 1)
    msg := string(gs.notify.items[0].text[:gs.notify.items[0].len])
    testing.expect(t, strings.contains(msg, "sky"), "rejection should point at the sky")
}

@(test)
locked_portal_blocks_then_opens :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Stand in the cave-2 portal (surface level, gate tier 0)
    gs.player.pos = {143.1, 93.6}  // center tile (143, 94)
    portal := portal_at_player(gs)
    testing.expect(t, portal != nil, "player should be standing in the cave-2 portal")

    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)  // still locked

    gs.progression.cave_unlocked[0] = true
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_CAVE2)
    testing.expect(t, gs.levels.generated[LEVEL_CAVE2], "cave 2 generated on entry")

    // Builders spawned in the fresh cave
    testing.expect(t, gs.enemies.count > 0, "cave 2 should have builders")
}

@(test)
transition_preserves_level_state :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Scar the surface so we can recognize it later
    set_tile(&gs.world, 50, 50, .Gold_Ore)

    // Take the dynamic sky gate (raised by a surface altar)
    gs.progression.sky_altar_pos = {40, 52}
    sky_portal := sky_gate_portal(gs)
    level_transition(gs, &sky_portal)
    testing.expect_value(t, gs.level_index, LEVEL_SKY)
    testing.expect_value(t, get_tile(&gs.world, 95, 79), Tile_Type.Sky_Entrance)

    // Mine a cloud in the sky, then return
    set_tile(&gs.world, 90, 80, .Air)
    back := &level_portals[LEVEL_SKY][0]
    level_transition(gs, back)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    testing.expect_value(t, get_tile(&gs.world, 50, 50), Tile_Type.Gold_Ore)

    // And the sky remembers the mined cloud
    level_transition(gs, &sky_portal)
    testing.expect_value(t, get_tile(&gs.world, 90, 80), Tile_Type.Air)
}

@(test)
sky_fall_returns_to_surface :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.progression.sky_altar_pos = {40, 52}
    sky := sky_gate_portal(gs)
    level_transition(gs, &sky)
    testing.expect_value(t, gs.level_index, LEVEL_SKY)

    gs.player.pos = {50, 90}  // below the cloud line
    update_player(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
}

@(test)
building_surface_altar_opens_the_sky_gate :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    gs.level_index = LEVEL_SURFACE

    testing.expect(t, gs.progression.sky_altar_pos == {0, 0}, "sky gate starts closed")

    // Lay the tier-A foundation (5 stone, 3 wood) in clear air, then cap it.
    ax, ay := 70, 30
    for dx in -2 ..= 2 { set_tile(&gs.world, ax + dx, ay + 2, .Stone) }
    for dx in -1 ..= 1 { set_tile(&gs.world, ax + dx, ay + 1, .Wood) }
    inventory_insert(&gs.player.inventory, .Sky_Altar, 1)
    gs.player.inventory.selected = 1  // slot 0 is the test pickaxe; Sky_Altar landed in slot 1
    gs.player.pos = {f32(ax + 3), f32(ay)}  // beside the altar, within reach, not on it
    handle_place_request(gs, Event{tile = {i32(ax), i32(ay)}})

    testing.expect_value(t, get_tile(&gs.world, ax, ay), Tile_Type.Sky_Altar)
    testing.expect(t, gs.progression.sky_altar_pos == {i32(ax), i32(ay)}, "gate opened at the altar")
}

@(test)
cave_generation_has_ore_and_blueprints :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    w := &gs.levels.worlds[LEVEL_CAVE2]
    gen_cave_level(w, 1)

    iron, silver, voids := 0, 0, 0
    for i in 0 ..< GRID_W * GRID_H {
        #partial switch w.terrain[i] {
        case .Iron_Ore:   iron += 1
        case .Silver_Ore: silver += 1
        case .Void:       voids += 1
        }
    }
    testing.expect(t, iron > 50, "cave 2 should have iron")
    testing.expect(t, silver > 20, "cave 2 should have silver")
    testing.expect(t, voids > 2000, "cave 2 should be substantially open")
    testing.expect_value(t, w.items[grid_idx(12, 101)], Item.Blueprint_B)
    testing.expect_value(t, get_tile(w, 6, 14), Tile_Type.Cave_Entrance)
}

// One pick swing / wand attempt pointing at the tile; the pick only reads
// the rough direction, the wand reads the exact tile.
@(private = "file")
mine_swing :: proc(gs: ^Game_State, tile: [2]i32) {
    gs.input.mine        = true
    gs.input.mouse_tile  = tile
    gs.input.mouse_world = {(f32(tile.x) + 0.5) * CELL_SIZE, (f32(tile.y) + 0.5) * CELL_SIZE}
    gs.player.mine_timer = 0
    update_player(gs)
    process_events(gs)
    eq_clear(&gs.events)
}

@(test)
pick_chips_by_rough_direction :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)

    // Down-forward: pointing at the diagonal grass — two chips crack it,
    // the third breaks it (opens to void)
    T := [2]i32{31, i32(SURFACE_Y)}
    mine_swing(gs, T)
    mine_swing(gs, T)
    testing.expect_value(t, get_tile(&gs.world, 31, SURFACE_Y), Tile_Type.Grass)
    testing.expect_value(t, gs.player.chip_hits, u8(2))
    mine_swing(gs, T)
    testing.expect_value(t, get_tile(&gs.world, 31, SURFACE_Y), Tile_Type.Void)

    // Pointing far with no wand: the pick only works adjacent tiles — with
    // open air beside the body, distant grass is untouched
    set_tile(&gs.world, 31, SURFACE_Y - 2, .Air)
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Air)
    far := [2]i32{33, i32(SURFACE_Y)}
    for _ in 0 ..< 5 { mine_swing(gs, far) }
    testing.expect_value(t, get_tile(&gs.world, 33, SURFACE_Y), Tile_Type.Grass)

    // Straight up: mines the tile above the head
    set_tile(&gs.world, 30, SURFACE_Y - 3, .Stone)
    up := [2]i32{30, i32(SURFACE_Y - 3)}
    for _ in 0 ..< PICK_HITS { mine_swing(gs, up) }
    testing.expect_value(t, get_tile(&gs.world, 30, SURFACE_Y - 3), Tile_Type.Air)

    // Switching direction resets the chip count
    mine_swing(gs, {30, i32(SURFACE_Y)})
    mine_swing(gs, {29, i32(SURFACE_Y)})
    testing.expect_value(t, gs.player.chip_hits, u8(1))
}

@(test)
mining_leaves_drops_leaf_and_opens_to_air :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)
    set_tile(&gs.world, 31, SURFACE_Y - 2, .Leaves)  // adjacent, above the surface line

    T := [2]i32{31, i32(SURFACE_Y - 2)}
    for _ in 0 ..< PICK_HITS { mine_swing(gs, T) }

    // Above the surface line the hole opens to air (not void), leaf drops
    testing.expect_value(t, get_tile(&gs.world, 31, SURFACE_Y - 2), Tile_Type.Air)
    testing.expect_value(t, gs.world.items[grid_idx(31, SURFACE_Y - 2)], Item.Leaf)
}

@(test)
wand_mines_at_range_for_mana :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)
    inventory_insert(&gs.player.inventory, .Mine_Wand, 1)

    // Two tiles out: the wand fires, drinks mana, and the tile breaks on impact
    mine_swing(gs, {32, i32(SURFACE_Y)})
    testing.expect(t, gs.mining.active, "wand shot should be in flight")
    testing.expect_value(t, gs.player.mana, 100 - WAND_MANA_COST)
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y), Tile_Type.Grass)  // not yet

    for _ in 0 ..< 15 {
        update_mining(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y), Tile_Type.Void)
    testing.expect(t, !gs.mining.active, "the shot is spent")

    // Beyond the basic wand's reach (3 > 2): nothing fires (the swing falls
    // back to the pick, which finds only the cleared air beside the body)
    set_tile(&gs.world, 29, SURFACE_Y - 2, .Air)
    set_tile(&gs.world, 29, SURFACE_Y - 1, .Air)
    mana_before := gs.player.mana
    mine_swing(gs, {27, i32(SURFACE_Y)})
    testing.expect(t, !gs.mining.active, "out-of-range shot must not fire")
    testing.expect(t, gs.player.mana >= mana_before, "no mana spent on a refused shot")

    // Out of mana: the wand refuses and says so
    gs.player.mana = WAND_MANA_COST - 1
    mine_swing(gs, {28, i32(SURFACE_Y)})
    testing.expect(t, !gs.mining.active, "no mana, no shot")
    testing.expect_value(t, gs.notify.count, 1)
}

@(test)
wand_tiers_extend_reach :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)

    fires_at :: proc(gs: ^Game_State, dx: i32) -> bool {
        gs.mining = {}
        gs.player.mana = 100
        mine_swing(gs, {30 + dx, i32(SURFACE_Y)})
        return gs.mining.active
    }

    inventory_insert(&gs.player.inventory, .Mine_Wand_Silver, 1)
    testing.expect(t, fires_at(gs, 4), "silver wand reaches 4")
    testing.expect(t, !fires_at(gs, 5), "silver wand stops at 4")

    inventory_insert(&gs.player.inventory, .Mine_Wand_Gold, 1)  // best wand wins
    testing.expect(t, fires_at(gs, 8), "gold wand reaches 8")
    testing.expect(t, !fires_at(gs, 9), "gold wand stops at 8")
}

@(test)
ultra_wand_cheat_blasts_a_3x3 :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)
    gs.debug.ultra_wand = true

    // 13 tiles out, nothing in the bag, a solid 3×3 around the target
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 { set_tile(&gs.world, 43 + dx, SURFACE_Y + 1 + dy, .Stone) }
    }
    mine_swing(gs, {43, i32(SURFACE_Y + 1)})
    testing.expect(t, gs.mining.active, "ultra wand fires at 13 tiles with no wand carried")
    testing.expect(t, gs.mining.blast, "ultra wand shots are explosive")
    testing.expect_value(t, gs.player.mana, 100)   // the cheat is free

    for _ in 0 ..< 15 {
        update_mining(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            testing.expectf(t, !is_solid(&gs.world, 43 + dx, SURFACE_Y + 1 + dy),
                "blast should clear (%d,%d)", 43 + dx, SURFACE_Y + 1 + dy)
        }
    }

    // Beyond even the cheat's reach: nothing fires
    set_tile(&gs.world, 31, SURFACE_Y - 2, .Air)
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Air)
    set_tile(&gs.world, 45, SURFACE_Y + 1, .Stone)
    mine_swing(gs, {45, i32(SURFACE_Y + 1)})   // chebyshev 15
    testing.expect(t, !gs.mining.active, "15 tiles is out of ultra range")

    // Cheat off: back to honest tools (no wand carried, so no shot at all)
    gs.debug.ultra_wand = false
    set_tile(&gs.world, 42, SURFACE_Y + 1, .Stone)
    mine_swing(gs, {42, i32(SURFACE_Y + 1)})   // chebyshev 12
    testing.expect(t, !gs.mining.active, "no cheat, no wand, no shot")
}

@(test)
wand_crafting_ladder :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    inv := &gs.player.inventory
    inventory_insert(inv, .Plank, 2)
    inventory_insert(inv, .Iron_Ore, 4)
    inventory_insert(inv, .Silver_Bar, 3)
    inventory_insert(inv, .Gold_Bar, 3)

    craft :: proc(gs: ^Game_State, result: Item) {
        for r, i in recipe_table {
            if r.result == result {
                handle_craft_request(gs, Event{payload = {int_val = i32(i)}})
                return
            }
        }
    }

    // Each tier consumes the wand before it — never two wands at once.
    craft(gs, .Mine_Wand)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand), 1)

    // Silver tier is forge work: refused at a bare bench
    craft(gs, .Mine_Wand_Silver)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand_Silver), 0)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand), 1)

    set_tile(&gs.world, 29, SURFACE_Y - 1, .Dvergr_Forge)
    craft(gs, .Mine_Wand_Silver)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand_Silver), 1)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand), 0)

    craft(gs, .Mine_Wand_Gold)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand_Gold), 1)
    testing.expect_value(t, inventory_count(inv, .Mine_Wand_Silver), 0)
    testing.expect_value(t, inventory_count(inv, .Silver_Bar), 0)
    testing.expect_value(t, inventory_count(inv, .Gold_Bar), 0)
}

@(test)
station_ladder :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    inv := &gs.player.inventory

    craft :: proc(gs: ^Game_State, result: Item) {
        for r, i in recipe_table {
            if r.result == result {
                handle_craft_request(gs, Event{payload = {int_val = i32(i)}})
                return
            }
        }
    }

    // In the wilderness only hand recipes are visible
    vis: [len(recipe_table)]int
    n := visible_recipes(gs, &vis)
    for row in 0 ..< n {
        testing.expect_value(t, recipe_table[vis[row]].station, Station.None)
    }

    // The forge is smithed at a bench, from smelted iron
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    inventory_insert(inv, .Stone_Block, 10)
    inventory_insert(inv, .Iron_Bar, 3)
    craft(gs, .Dvergr_Forge)
    testing.expect_value(t, inventory_count(inv, .Dvergr_Forge), 1)

    // The altar is forge work: refused until a forge is placed
    inventory_insert(inv, .Gold_Bar, 3)
    inventory_insert(inv, .Cloud_Stone, 6)
    inventory_insert(inv, .Aether_Crystal, 3)
    craft(gs, .Rune_Altar)
    testing.expect_value(t, inventory_count(inv, .Rune_Altar), 0)

    set_tile(&gs.world, 29, SURFACE_Y - 1, .Dvergr_Forge)
    craft(gs, .Rune_Altar)
    testing.expect_value(t, inventory_count(inv, .Rune_Altar), 1)

    // The charm is altar work: bench + forge are not enough
    craft(gs, .Aether_Charm)
    testing.expect_value(t, inventory_count(inv, .Aether_Charm), 0)

    set_tile(&gs.world, 32, SURFACE_Y - 1, .Rune_Altar)
    craft(gs, .Aether_Charm)
    testing.expect_value(t, inventory_count(inv, .Aether_Charm), 1)
}

@(test)
anvil_offer_matching :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    buf: [len(recipe_table)]int

    // Empty anvil matches nothing
    testing.expect_value(t, offer_matches(gs, &buf), 0)

    // A wood log by hand: the plank recipe, counts not required to match
    gs.ui.craft_offer = {.Wood_Log, .None, .None}
    n := offer_matches(gs, &buf)
    testing.expect_value(t, n, 1)
    testing.expect_value(t, recipe_table[buf[0]].result, Item.Plank)

    // Iron + plank with the hand window: nothing — all its shapes are bench work
    gs.ui.craft_offer = {.Iron_Ore, .Plank, .None}
    testing.expect_value(t, offer_matches(gs, &buf), 0)

    // With the window opened at a bench the same offer is ambiguous:
    // sword, wand and five armor pieces
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    gs.ui.active_station = .Bench
    testing.expect_value(t, offer_matches(gs, &buf), 7)

    // An extra material breaks the set — no partial matches
    gs.ui.craft_offer = {.Iron_Ore, .Plank, .Wood_Log}
    testing.expect_value(t, offer_matches(gs, &buf), 0)
}

@(test)
runic_gear_ladder :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    inv := &gs.player.inventory
    inventory_insert(inv, .Gold_Sword, 1)
    inventory_insert(inv, .Runic_Sky_Ore, 6)

    craft :: proc(gs: ^Game_State, result: Item) {
        for r, i in recipe_table {
            if r.result == result {
                handle_craft_request(gs, Event{payload = {int_val = i32(i)}})
                return
            }
        }
    }

    // Runic work needs the altar, and consumes the gold piece beneath it
    craft(gs, .Runic_Sword)
    testing.expect_value(t, inventory_count(inv, .Runic_Sword), 0)

    set_tile(&gs.world, 31, SURFACE_Y - 1, .Rune_Altar)
    craft(gs, .Runic_Sword)
    testing.expect_value(t, inventory_count(inv, .Runic_Sword), 1)
    testing.expect_value(t, inventory_count(inv, .Gold_Sword), 0)
    testing.expect_value(t, inventory_count(inv, .Runic_Sky_Ore), 0)

    // And it wears like the rest of the ladder
    sword_slot := -1
    for s, i in inv.slots {
        if s.item == .Runic_Sword && s.count > 0 do sword_slot = i
    }
    testing.expect(t, sword_slot >= 0, "runic sword should be in the bag")
    eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = i32(sword_slot)}})
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Runic_Sword)
    testing.expect_value(t, player_stat(&gs.player, .Attack), i32(8))
}

@(test)
enemy_drop_tables :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A slain builder's guaranteed stone lands on or beside his death tile
    spawn_builder(gs, 40)
    bi := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] && gs.enemies.data[i].kind == .Builder do bi = i
    }
    testing.expect(t, bi >= 0, "builder should have spawned")
    T := builder_tile(&gs.enemies.data[bi])

    eq_push(&gs.events, Event{
        type    = .Damage_Dealt,
        source  = PLAYER_ID,
        target  = enemy_entity_id(bi),
        payload = {int_val = 99},
    })
    process_events(gs)
    eq_clear(&gs.events)

    testing.expect(t, !gs.enemies.active[bi], "builder should be dead")
    stone := 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        x, y := int(T.x) + dx, int(T.y) + dy
        if !in_bounds(x, y) do continue
        idx := grid_idx(x, y)
        if gs.world.items[idx] == .Stone_Block do stone += int(gs.world.item_counts[idx])
    }
    testing.expect(t, stone >= 1 && stone <= 2, "builder death drops 1-2 stone")
}

@(test)
ground_item_spillover :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    w := &gs.world

    // The death tile is taken by a different item: the drop spills to a
    // neighbor instead of clobbering it.
    T := [2]i32{60, i32(SURFACE_Y) - 3}
    idx := grid_idx(int(T.x), int(T.y))
    w.items[idx]       = .Leaf
    w.item_counts[idx] = 5
    spawn_ground_item(w, T, .Iron_Ore, 2)
    testing.expect_value(t, w.items[idx], Item.Leaf)
    found := 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        i2 := grid_idx(int(T.x) + dx, int(T.y) + dy)
        if w.items[i2] == .Iron_Ore do found += int(w.item_counts[i2])
    }
    testing.expect_value(t, found, 2)

    // Every nearby cell taken: the origin is claimed outright so a
    // guaranteed drop (the Hell Key) is never lost.
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        i2 := grid_idx(int(T.x) + dx, int(T.y) + dy)
        w.items[i2]       = .Leaf
        w.item_counts[i2] = 1
    }
    spawn_ground_item(w, T, .Hell_Key, 1)
    testing.expect_value(t, w.items[idx], Item.Hell_Key)
}

@(test)
body_lands_and_grounded_is_stable :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Clear surface decoration above the landing column
    for y in SURFACE_Y - 8 ..< SURFACE_Y do set_tile(&gs.world, 30, y, .Air)

    pos      := [2]f32{30, f32(SURFACE_Y) - 6}
    vel      := [2]f32{}
    grounded := false
    for _ in 0 ..< 120 {
        move_body(&gs.world, &pos, &vel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &grounded)
    }
    testing.expect(t, grounded, "body should land on the surface")
    testing.expect(t, abs(pos.y + PLAYER_H - f32(SURFACE_Y)) < 0.01, "feet at the grass boundary")

    // Regression: grounded must hold EVERY frame while standing (the old
    // enemy resolver flickered grounded on alternating frames)
    for _ in 0 ..< 10 {
        move_body(&gs.world, &pos, &vel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &grounded)
        testing.expect(t, grounded, "grounded must not flicker while standing")
    }
}

@(test)
body_blocked_by_wall :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Two-tile wall right of the body
    set_tile(&gs.world, 33, SURFACE_Y - 1, .Stone)
    set_tile(&gs.world, 33, SURFACE_Y - 2, .Stone)

    pos      := [2]f32{30, f32(SURFACE_Y) - PLAYER_H}
    vel      := [2]f32{}
    grounded := true
    for _ in 0 ..< 60 {
        vel.x = MOVE_SPEED
        move_body(&gs.world, &pos, &vel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &grounded)
    }
    testing.expect(t, pos.x + PLAYER_W <= 33.0, "body must stop at the wall")
    testing.expect(t, pos.x + PLAYER_W > 32.9, "body must stand right against the wall")
}

@(test)
fast_fall_does_not_tunnel :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Worst case: terminal velocity at the 50 ms dt cap crosses > 1 tile.
    // The grass row at SURFACE_Y is one tile thick with stone below removed.
    for y in SURFACE_Y - 8 ..< SURFACE_Y do set_tile(&gs.world, 30, y, .Air)

    pos      := [2]f32{30, f32(SURFACE_Y) - PLAYER_H - 0.5}
    vel      := [2]f32{0, MAX_FALL_SPEED}
    grounded := false
    for _ in 0 ..< 10 {
        move_body(&gs.world, &pos, &vel, {PLAYER_W, PLAYER_H}, 0.05,
            GRAVITY, MAX_FALL_SPEED, &grounded)
    }
    testing.expect(t, grounded, "body must land, not tunnel through the surface")
    testing.expect(t, abs(pos.y + PLAYER_H - f32(SURFACE_Y)) < 0.01, "feet on the grass row")
}

@(test)
notifications_explain_ritual_state :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    notify_text :: proc(gs: ^Game_State, i: int) -> string {
        return string(gs.notify.items[i].text[:gs.notify.items[i].len])
    }

    gs.level_index = LEVEL_SKY  // ritual is gated to the sky level

    // No blueprint: the altar explains itself instead of doing nothing
    handle_ritual_request(gs)
    testing.expect_value(t, gs.notify.count, 1)
    testing.expect(t, strings.contains(notify_text(gs, 0), "blueprint"), "should point at the missing blueprint")

    // Blueprint but no materials: names the first missing ingredient + counts
    gs.progression.blueprint_found[0] = true
    inventory_insert(&gs.player.inventory, .Cloud_Stone, 3)
    handle_ritual_request(gs)
    testing.expect_value(t, gs.notify.count, 2)
    testing.expect(t, strings.contains(notify_text(gs, 1), "Cloud Stone"), "should name the missing material")
    testing.expect(t, strings.contains(notify_text(gs, 1), "you have 3"), "should show the held count")

    // Notifications expire after NOTIFY_DURATION
    gs.delta_time = NOTIFY_DURATION + 0.1
    update_notifications(gs)
    testing.expect_value(t, gs.notify.count, 0)
}

@(test)
objective_line_walks_the_loop :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    buf: [128]u8

    // Fresh run: raise the sky gate first (Blueprint A doesn't exist yet)
    s := current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Sky Altar"), "fresh run points at raising the sky altar")

    // Gate up: hunt the deep blueprint
    gs.progression.sky_altar_pos = {90, 90}
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Blueprint A"), "next step is finding Blueprint A")

    // Blueprint found: show the tier-0 ritual cost
    gs.progression.blueprint_found[0] = true
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Cloud Stone"), "ritual cost names the sky material")

    // Structure A raised: hunt Blueprint B
    gs.progression.sky_structure_complete[0] = true
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Blueprint B"), "tier 1 points at Blueprint B")

    // All rituals done: face the boss
    gs.progression.blueprint_found        = {true, true, true}
    gs.progression.sky_structure_complete = {true, true, true}
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "GARM"), "endgame points at the boss")
}

@(test)
deep_blueprint_waits_for_the_altar :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := grid_idx(141, 94)
    testing.expect(t, gs.world.items[idx] == .None, "Blueprint A must not exist at world gen")

    spawn_deep_blueprint(gs)
    testing.expect(t, gs.world.items[idx] == .Blueprint_A, "altar raise reveals Blueprint A in the chamber")
    testing.expect_value(t, gs.world.item_counts[idx], 1)

    // Idempotent: a second raise doesn't stack another copy
    spawn_deep_blueprint(gs)
    testing.expect_value(t, gs.world.item_counts[idx], 1)

    // Already found: never respawns
    gs.world.items[idx]       = .None
    gs.world.item_counts[idx] = 0
    gs.progression.blueprint_found[0] = true
    spawn_deep_blueprint(gs)
    testing.expect(t, gs.world.items[idx] == .None, "found blueprint must not respawn")
}

@(test)
builders_do_not_freeze :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // 60 simulated seconds of builder AI on the real level-0 world.
    // Regression for the physics-margin bug where builders pinned against
    // 1-high steps forever: a builder may legitimately idle a few seconds
    // (cooldowns between jobs), but 10 s at the exact same position while
    // active means the freeze is back.
    last_pos:   [MAX_ENEMIES][2]f32
    still_secs: [MAX_ENEMIES]int

    for frame in 0 ..< 3600 {
        update_enemies(gs)
        process_events(gs)
        eq_clear(&gs.events)

        if frame % 60 != 0 do continue
        for i in 0 ..< MAX_ENEMIES {
            if !gs.enemies.active[i] do continue
            e := &gs.enemies.data[i]
            if e.pos == last_pos[i] {
                still_secs[i] += 1
                testing.expect(t, still_secs[i] < 10, "builder frozen in place for 10s")
            } else {
                still_secs[i] = 0
                last_pos[i]   = e.pos
            }
        }
    }

    // With movement working, both level-0 builders finish their dens well
    // within the minute (deterministic world gen + fixed dt).
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] do continue
        testing.expect(t, gs.enemies.data[i].builder.den_built, "builder should complete its den within 60s")
    }
}

@(test)
bridging_spends_pocket_blocks :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A builder whose current waypoint hangs over a gap
    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    testing.expect(t, idx >= 0, "level 0 should have a builder")
    e := &gs.enemies.data[idx]

    gap := builder_tile(e) + {3, 0}
    set_tile(&gs.world, int(gap.x), int(gap.y),   .Void)
    set_tile(&gs.world, int(gap.x), int(gap.y)+1, .Void)
    e.nav.path = {tiles = {0 = gap}, len = 1, cursor = 0}
    e.nav.mine_timer = 0

    // Empty pocket: no block appears, path is dropped for a replan
    e.builder.pocket = 0
    builder_exec_action(e, &e.nav, gs)
    testing.expect_value(t, get_tile(&gs.world, int(gap.x), int(gap.y)+1), Tile_Type.Void)
    testing.expect_value(t, e.nav.path.len, 0)

    // One pocket block: the bridge is placed and the pocket is spent
    e.nav.path = {tiles = {0 = gap}, len = 1, cursor = 0}
    e.builder.pocket = 1
    builder_exec_action(e, &e.nav, gs)
    testing.expect_value(t, get_tile(&gs.world, int(gap.x), int(gap.y)+1), Tile_Type.Stone)
    testing.expect_value(t, e.builder.pocket, u8(0))
}

// Builder with a finished shelter den at (50, 50) — shared setup for the
// stockpile and raid tests.
@(private = "file")
den_owner_fixture :: proc(gs: ^Game_State) -> (idx: int) {
    idx = -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    b := &gs.enemies.data[idx].builder
    b.build     = .Shelter
    b.anchor    = {50, 50}
    b.den_built = true
    b.goal      = .Fetch_Mineral
    return
}

@(test)
den_stockpile_deposits_loot :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := den_owner_fixture(gs)
    e := &gs.enemies.data[idx]
    e.builder.carry = .Iron_Ore

    builder_deposit_loot(e, idx, gs)
    floor := grid_idx(50, 50)
    testing.expect_value(t, gs.world.items[floor], Item.Iron_Ore)
    testing.expect_value(t, gs.world.item_counts[floor], u8(1))
    testing.expect_value(t, e.builder.carry, Tile_Type.Air)

    // Second haul stacks onto the same pile
    e.builder.carry = .Iron_Ore
    builder_deposit_loot(e, idx, gs)
    testing.expect_value(t, gs.world.item_counts[floor], u8(2))
}

@(test)
den_break_in_triggers_hunt :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Mining a den wall tile (template offset {-2, 0}) enrages the owner
    idx := den_owner_fixture(gs)
    handle_tile_mined(gs, Event{tile = {48, 50}})
    testing.expect_value(t, gs.enemies.data[idx].builder.goal, Builder_Goal.Hunt)
    testing.expect_value(t, gs.notify.count, 1)

    // Mining unrelated rock far away does not
    gs2 := test_state()
    defer free(gs2)
    idx2 := den_owner_fixture(gs2)
    handle_tile_mined(gs2, Event{tile = {100, 90}})
    testing.expect(t, gs2.enemies.data[idx2].builder.goal != .Hunt, "distant mining must not alert the den owner")
}

@(test)
den_trespass_triggers_hunt :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := den_owner_fixture(gs)
    e := &gs.enemies.data[idx]
    e.pos = {48, 48}  // owner at home — beyond HUNT_LOSE_DIST it gives up

    // Player center inside the den interior (center tile = anchor)
    gs.player.pos = {50.5 - PLAYER_W*0.5, 50.5 - PLAYER_H*0.5}
    update_builder(e, idx, gs, 1.0/60.0)
    testing.expect_value(t, e.builder.goal, Builder_Goal.Hunt)
}

@(test)
sword_melee_kills_builders :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    testing.expect(t, idx >= 0, "level 0 should have a builder")
    e := &gs.enemies.data[idx]

    // Park the builder beside the player, refresh its entity-map marker
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    prev := builder_tile(e)
    e.pos = {31.5, f32(SURFACE_Y) - BUILDER_H}
    entity_map_move(&gs.world, enemy_entity_id(idx), prev, builder_tile(e))

    gs.input.attack     = true
    gs.input.mouse_tile = builder_tile(e)

    // No sword: the click hits nothing
    update_player(gs)
    process_events(gs)
    testing.expect_value(t, e.hp, 6)

    // First swing wounds and enrages (sword must be equipped, not just bagged)
    inventory_insert(&gs.player.inventory, .Sword, 1)
    player_equip(gs, 1)   // test_state put the pickaxe in slot 0
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Sword)
    gs.player.attack_timer = 0
    update_player(gs)
    process_events(gs)
    testing.expect_value(t, e.hp, 4)
    testing.expect_value(t, e.builder.goal, Builder_Goal.Hunt)

    // Cooldown gates the second swing
    update_player(gs)
    process_events(gs)
    testing.expect_value(t, e.hp, 4)

    // Two more swings kill: slot freed, kill counted
    for _ in 0 ..< 2 {
        gs.player.attack_timer = 0
        update_player(gs)
        process_events(gs)
    }
    testing.expect(t, !gs.enemies.active[idx], "three sword hits kill a builder")
    testing.expect_value(t, gs.stats.total_kills, 1)
}

@(test)
sword_respects_reach :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    e := &gs.enemies.data[idx]

    // Cursor on a builder far out of melee reach: no hit
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    prev := builder_tile(e)
    e.pos = {40, f32(SURFACE_Y) - BUILDER_H}
    entity_map_move(&gs.world, enemy_entity_id(idx), prev, builder_tile(e))

    inventory_insert(&gs.player.inventory, .Sword, 1)
    player_equip(gs, 1)   // test_state put the pickaxe in slot 0
    gs.input.attack     = true
    gs.input.mouse_tile = builder_tile(e)
    update_player(gs)
    process_events(gs)
    testing.expect_value(t, e.hp, 6)
}

@(test)
equip_swaps_through_events_and_never_destroys_gear :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    p := &gs.player

    // Equip via the event route — the same path input.odin pushes.
    inventory_insert(&p.inventory, .Sword, 1)
    eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = 1}})
    process_events(gs)
    testing.expect_value(t, p.equipment[.Weapon], Item.Sword)
    testing.expect_value(t, inventory_count(&p.inventory, .Sword), 0)

    // Swapping in a silver sword hands the old sword back to the bag.
    inventory_insert(&p.inventory, .Silver_Sword, 1)
    player_equip(gs, 1)
    testing.expect_value(t, p.equipment[.Weapon], Item.Silver_Sword)
    testing.expect_value(t, inventory_count(&p.inventory, .Sword), 1)

    // Bag stuffed full, source slot still stacked: the displaced weapon has
    // nowhere to go, so the swap is refused — nothing is destroyed.
    for &s in p.inventory.slots { s.item = .Stone_Block; s.count = MAX_STACK }
    p.inventory.slots[1] = {.Gold_Sword, 2}
    player_equip(gs, 1)
    testing.expect_value(t, p.equipment[.Weapon], Item.Silver_Sword)
    testing.expect_value(t, p.inventory.slots[1].count, 2)

    // Unequip into a full bag is likewise refused.
    player_unequip(gs, .Weapon)
    testing.expect_value(t, p.equipment[.Weapon], Item.Silver_Sword)
}

@(test)
armor_blunts_enemy_blows_but_not_the_world :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inventory_insert(&gs.player.inventory, .Iron_Chestplate, 1)
    player_equip(gs, 1)   // test_state put the pickaxe in slot 0
    testing.expect_value(t, gs.player.equipment[.Chest], Item.Iron_Chestplate)
    testing.expect_value(t, player_stat(&gs.player, .Defense), i32(1))

    // An enemy bite for 2 lands for 1 through defense 1.
    hp := gs.player.hp
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = enemy_entity_id(0),
        target = PLAYER_ID, payload = {int_val = 2}})
    process_events(gs)
    testing.expect_value(t, gs.player.hp, hp - 1)

    // The world (lava, falls — source INVALID_ENTITY) strikes past armor.
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = INVALID_ENTITY,
        target = PLAYER_ID, payload = {int_val = 2}})
    process_events(gs)
    testing.expect_value(t, gs.player.hp, hp - 3)
}

@(test)
fall_damage_measures_the_drop_from_the_peak :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    p := &gs.player

    // Settle onto the ground first so the fall arms on a real ledge-off.
    for _ in 0 ..< 300 {
        update_player(gs)
        process_events(gs)
        if p.grounded do break
    }
    testing.expect(t, p.grounded, "player should settle onto the surface")
    hp := p.hp

    // A short 3-tile hoist is under SAFE_FALL_TILES: lands clean.
    p.pos.y -= 3
    for _ in 0 ..< 300 {
        update_player(gs)
        process_events(gs)
        if p.grounded do break
    }
    testing.expect_value(t, p.hp, hp)

    // A 10-tile drop: 5 tiles past safe -> int(5/2)+1 = 3 damage.
    p.pos.y -= 10
    for _ in 0 ..< 300 {
        update_player(gs)
        process_events(gs)
        if p.grounded do break
    }
    testing.expect_value(t, p.hp, hp - 3)
}

@(test)
projectiles_fly_hit_and_expire :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Wall hit: fired at the ground, dies on the solid tile, world intact
    spawn_projectile(gs, {30, f32(SURFACE_Y) - 3}, {0, 20}, PLAYER_ID, 1)
    testing.expect_value(t, gs.projectiles.count, 1)
    for _ in 0 ..< 30 { update_projectiles(gs); eq_clear(&gs.events) }
    testing.expect_value(t, gs.projectiles.count, 0)
    testing.expect_value(t, get_tile(&gs.world, 30, SURFACE_Y), Tile_Type.Grass)

    // Player hit: enemy-owned fireball flying at the player
    // (clear the corridor first — surface gen may have tree trunks here)
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    for x in 30 ..= 36 { set_tile(&gs.world, x, SURFACE_Y - 1, .Air) }
    spawn_projectile(gs, {34, f32(SURFACE_Y) - 1}, {-10, 0}, enemy_entity_id(0), 2)
    for _ in 0 ..< 60 { update_projectiles(gs); process_events(gs); eq_clear(&gs.events) }
    testing.expect_value(t, gs.player.hp, 8)
    testing.expect_value(t, gs.projectiles.count, 0)

    // Owner immunity: the player's own shot leaves the player unhurt
    spawn_projectile(gs, {f32(30) + PLAYER_W*0.5, f32(SURFACE_Y) - 1}, {10, 0}, PLAYER_ID, 2)
    for _ in 0 ..< 60 { update_projectiles(gs); process_events(gs); eq_clear(&gs.events) }
    testing.expect_value(t, gs.player.hp, 8)

    // Enemy hit: shot parked on a builder's center tile
    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    e  := &gs.enemies.data[idx]
    bt := builder_tile(e)
    spawn_projectile(gs, {f32(bt.x) + 0.5, f32(bt.y) + 0.5}, {0, 0}, PLAYER_ID, 2)
    update_projectiles(gs)
    process_events(gs)
    eq_clear(&gs.events)
    testing.expect_value(t, e.hp, 4)
}

@(test)
den_defense_persists_without_los :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Owner at home, raider lurking on the den grounds behind a wall
    idx := den_owner_fixture(gs)
    e := &gs.enemies.data[idx]
    e.pos = {48, 48}
    gs.player.pos = {54.5 - PLAYER_W*0.5, 50.5 - PLAYER_H*0.5}  // 3 east of anchor
    set_tile(&gs.world, 52, 50, .Stone)  // sight line blocked

    builder_alert(gs, idx)

    // Way past LOS_MEMORY: the owner must still be hunting
    for _ in 0 ..< int((LOS_MEMORY + 3.0) * 60) {
        update_builder(e, idx, gs, 1.0/60.0)
    }
    testing.expect_value(t, e.builder.goal, Builder_Goal.Hunt)

    // Raider actually flees the grounds: hunt ends
    gs.player.pos = {100, 20}
    for _ in 0 ..< int((LOS_MEMORY + 3.0) * 60) {
        update_builder(e, idx, gs, 1.0/60.0)
        if e.builder.goal != .Hunt { break }
    }
    testing.expect(t, e.builder.goal != .Hunt, "hunt must end once the raider leaves the den grounds")
}

// ─── Phase 5: boss arena + Garm gate ─────────────────────────────────────────

@(test)
cave3_has_boss_arena :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    w := &gs.levels.worlds[LEVEL_CAVE3]
    gen_cave_level(w, 2)

    // Arena interior fully carved, floor solid beneath
    for y in ARENA_Y0 ..= ARENA_Y1 {
        for x in ARENA_X0 ..= ARENA_X1 {
            testing.expect(t, !is_solid(w, x, y), "arena interior must be open")
        }
    }
    for x in ARENA_X0 ..= ARENA_X1 {
        testing.expect(t, is_solid(w, x, ARENA_Y1 + 1), "arena floor must be solid")
    }
}

@(test)
garm_spawns_only_behind_boss_gate :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Caves open but structure C unbuilt: entering cave 3 spawns no boss
    gs.progression.cave_unlocked[0] = true
    gs.progression.cave_unlocked[1] = true
    level_transition(gs, &level_portals[LEVEL_SURFACE][0])
    level_transition(gs, &level_portals[LEVEL_CAVE2][1])
    process_events(gs)
    testing.expect_value(t, gs.level_index, LEVEL_CAVE3)
    testing.expect(t, !garm_present(gs), "no Garm before the boss gate")

    // Structure C completes while inside cave 3: Garm awakens
    gs.progression.blueprint_found[2] = true
    inventory_insert(&gs.player.inventory, .Cloud_Stone, 20)
    inventory_insert(&gs.player.inventory, .Gold_Ore, 10)
    gs.level_index = LEVEL_SKY  // ritual gating
    handle_ritual_request(gs)
    gs.level_index = LEVEL_CAVE3
    process_events(gs)
    testing.expect(t, garm_present(gs), "Garm awakens when the boss gate opens")

    // He stands on the arena floor and takes sword damage like anything else
    gi := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] && gs.enemies.data[i].kind == .Garm { gi = i; break }
    }
    g := &gs.enemies.data[gi]
    for _ in 0 ..< 60 { update_enemies(gs); process_events(gs); eq_clear(&gs.events) }
    testing.expect(t, g.grounded, "Garm should land on the arena floor")

    eq_push(&gs.events, Event{
        type    = .Damage_Dealt,
        source  = PLAYER_ID,
        target  = enemy_entity_id(gi),
        payload = {int_val = SWORD_DAMAGE},
    })
    process_events(gs)
    testing.expect_value(t, g.hp, GARM_HP - SWORD_DAMAGE)
}

@(test)
lava_damages_player :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Standing with the feet in a lava tile: dps 2 = 1 hp every 0.5 s.
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 30, SURFACE_Y - 1, .Lava)

    step :: proc(gs: ^Game_State) {
        update_player(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }

    for _ in 0 ..< 32 { step(gs) }
    testing.expect_value(t, gs.player.hp, 9)
    for _ in 0 ..< 30 { step(gs) }
    testing.expect_value(t, gs.player.hp, 8)

    // Out of the lava: the burn stops and the accumulator resets.
    set_tile(&gs.world, 30, SURFACE_Y - 1, .Air)
    for _ in 0 ..< 120 { step(gs) }
    testing.expect_value(t, gs.player.hp, 8)
}

// Cave-3 world with only Garm in it; returns his slot index.
@(private = "file")
garm_fixture :: proc(gs: ^Game_State) -> (gi: int) {
    gen_cave_level(&gs.world, 2)
    gs.enemies     = {}
    gs.level_index = LEVEL_CAVE3
    spawn_garm(gs)
    gi = -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] && gs.enemies.data[i].kind == .Garm { gi = i; break }
    }
    return
}

@(test)
garm_phases_follow_hp :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gi := garm_fixture(gs)
    testing.expect(t, gi >= 0, "Garm should spawn in the fixture")
    g := &gs.enemies.data[gi]

    // Dead player keeps him stationary — the channel must run regardless.
    gs.player.dead = true
    // Step him off the column slot (he spawns on it; solid stone is never
    // conjured into a body, so the column would politely wait forever).
    g.pos.x = f32(ARENA_X0 + 3)

    step :: proc(gs: ^Game_State) {
        update_enemies(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }

    // Full hp: chase phase, no construction.
    for _ in 0 ..< 300 { step(gs) }
    testing.expect_value(t, g.garm.phase, Garm_Phase.Chase)
    testing.expect(t, !is_solid(&gs.world, ARENA_CX, ARENA_Y1 - 5), "no column before phase 2")

    // Phase 2: the center column rises, floor to 2 below the ceiling.
    g.hp = GARM_PHASE2_HP
    for _ in 0 ..< 600 { step(gs) }
    testing.expect_value(t, g.garm.phase, Garm_Phase.Column)
    for i in 0 ..< GARM_COLUMN_LEN {
        testing.expectf(t, is_solid(&gs.world, ARENA_CX, ARENA_Y1 - i),
            "column cell %d should be built", i)
    }
    testing.expect(t, !is_solid(&gs.world, ARENA_CX, ARENA_Y0 + 1), "the column leaves a gap at the top")

    // Phase 3: the perimeter seals; its completion breaks into the flood.
    g.hp = GARM_PHASE3_HP
    for _ in 0 ..< 800 { step(gs) }
    testing.expect_value(t, g.garm.phase, Garm_Phase.Flood)
    for i in 0 ..= ARENA_Y1 - ARENA_Y0 {
        testing.expectf(t, is_solid(&gs.world, ARENA_X0, ARENA_Y1 - i), "left ring cell %d", i)
        testing.expectf(t, is_solid(&gs.world, ARENA_X1, ARENA_Y1 - i), "right ring cell %d", i)
    }
    for x in ARENA_X0 + 1 ..< ARENA_X1 {
        testing.expectf(t, is_solid(&gs.world, x, ARENA_Y0), "ring roof cell x=%d", x)
    }

    // Flood: lava fills the arena floor up to GARM_LAVA_DEPTH rows.
    for _ in 0 ..< int(GARM_FLOOD_INTERVAL * f32(GARM_FLOOD_LEN) * 60) + 300 { step(gs) }
    for x in ARENA_X0 + 1 ..< ARENA_X1 {
        lava_or_stone := get_tile(&gs.world, x, ARENA_Y1) == .Lava || is_solid(&gs.world, x, ARENA_Y1)
        testing.expectf(t, lava_or_stone, "arena floor row should be flooded at x=%d", x)
    }
}

@(test)
garm_fight_soak :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gi := garm_fixture(gs)
    testing.expect(t, gi >= 0, "Garm should spawn in the fixture")
    g := &gs.enemies.data[gi]

    // Deterministic bot: hop to a fresh arena spot every 6 s; the sword
    // lands 2 damage every 4 s, so the whole fight runs ~60 s.
    place_bot :: proc(gs: ^Game_State, cycle: int) {
        h  := whash(u32(cycle) * 2654435761 + 17)
        x  := ARENA_X0 + 2 + int(h % u32(ARENA_X1 - ARENA_X0 - 3))
        sx, sy := snap_to_standable(&gs.world, x, ARENA_Y1 - 1)
        gs.player.pos = {f32(sx) + (1 - PLAYER_W)*0.5, f32(sy) - PLAYER_H + 1}
    }
    place_bot(gs, 0)

    player_hits, fireballs: int
    closed_in:  bool
    last_pos:   [2]f32
    still_secs: int

    MAX_FRAMES :: 4 * 60 * 60   // 4-minute cap; the fight should end well before

    frame_done := 0
    for frame in 0 ..< MAX_FRAMES {
        frame_done = frame
        if !gs.enemies.active[gi] { break }   // Garm slain — fight over

        if frame % 360 == 0 && frame > 0 { place_bot(gs, frame / 360) }
        gs.player.hp = 1000   // the bot outlives everything; hits are counted below

        if frame % 240 == 0 && frame > 0 {
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = PLAYER_ID,
                target  = enemy_entity_id(gi),
                payload = {int_val = SWORD_DAMAGE},
            })
        }

        update_enemies(gs)
        update_projectiles(gs)

        n  := gs.events.size
        qi := gs.events.head
        for _ in 0 ..< n {
            ev := gs.events.events[qi]
            if ev.type == .Damage_Dealt && ev.target == PLAYER_ID { player_hits += 1 }
            if ev.type == .Projectile_Fired { fireballs += 1 }
            qi = (qi + 1) % MAX_EVENTS
        }
        process_events(gs)
        eq_clear(&gs.events)

        if gs.enemies.active[gi] {
            if chebyshev(builder_tile(g), player_tile(&gs.player)) <= GARM_BITE_REACH {
                closed_in = true
            }
            // Freeze watchdog: standing still is only legitimate in biting
            // range (or during a mine cooldown, far shorter than 10 s).
            if frame % 60 == 0 {
                far := chebyshev(builder_tile(g), player_tile(&gs.player)) > 4
                if g.pos == last_pos && far {
                    still_secs += 1
                    testing.expect(t, still_secs < 10, "Garm frozen in place for 10 s")
                } else {
                    still_secs = 0
                    last_pos   = g.pos
                }
            }
        }
    }

    testing.expect(t, !gs.enemies.active[gi], "the fight must end in Garm's death")
    testing.expect(t, closed_in, "Garm should reach biting range at least once")
    testing.expect(t, player_hits >= 1, "Garm should land at least one hit")
    testing.expectf(t, fireballs >= 5, "Garm should throw fireballs (got %d)", fireballs)
    testing.expect(t, get_tile(&gs.world, ARENA_X0 + 5, ARENA_Y1) == .Lava ||
        is_solid(&gs.world, ARENA_X0 + 5, ARENA_Y1), "the flood should have reached the floor")

    log.infof("garm soak: fight lasted %.1f s, %d fireballs, %d hits on the player",
        f32(frame_done) / 60.0, fireballs, player_hits)
}

@(test)
garm_death_drops_key_and_wins_the_game :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gi := garm_fixture(gs)
    g := &gs.enemies.data[gi]
    key_tile := builder_tile(g)

    // The killing blow: Hell Key drops where he stood, boss flag set,
    // and the gate never respawns him.
    eq_push(&gs.events, Event{
        type    = .Damage_Dealt,
        source  = PLAYER_ID,
        target  = enemy_entity_id(gi),
        payload = {int_val = GARM_HP},
    })
    process_events(gs)
    eq_clear(&gs.events)

    testing.expect(t, !gs.enemies.active[gi], "Garm should be dead")
    idx := grid_idx(int(key_tile.x), int(key_tile.y))
    testing.expect_value(t, gs.world.items[idx], Item.Hell_Key)
    testing.expect(t, gs.progression.final_boss_defeated, "boss flag should be set")

    gs.progression.cave_unlocked[2] = true
    garm_maybe_awaken(gs)
    testing.expect(t, !garm_present(gs), "a defeated Garm must not respawn")

    // Claiming the key wins the run and banks the stats.
    won_before := gs.stats.runs_won
    gs.player.pos = {f32(key_tile.x), f32(key_tile.y + 1) - PLAYER_H}
    player_pickup(gs)
    process_events(gs)
    eq_clear(&gs.events)

    testing.expect(t, gs.game_won, "picking up the Hell Key wins the game")
    testing.expect_value(t, gs.stats.runs_won, won_before + 1)

    // The win freezes the run exactly like death does.
    pos_before := gs.player.pos
    gs.input.move_right = true
    update_player(gs)
    testing.expect(t, gs.player.pos == pos_before, "no more moves after the win")
}

// ─── Phase 4 AI soak ──────────────────────────────────────────────────────────

@(test)
builder_soak_cave2_economy :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Fresh cave-2 world with 3 builders; player parked in the spawn chamber.
    gen_cave_level(&gs.world, 1)
    gs.enemies     = {}
    gs.level_index = LEVEL_CAVE2
    spawn_builder(gs, 40)
    spawn_builder(gs, GRID_W - 40)
    spawn_builder(gs, GRID_W / 2)
    testing.expect_value(t, gs.enemies.count, 3)
    gs.player.pos = {6, 10}

    SOAK_MINUTES :: 60
    WINDOW       :: 3600   // one simulated minute of frames

    prev_carry:  [MAX_ENEMIES]Tile_Type
    last_pickup: [MAX_ENEMIES]int
    for i in 0 ..< MAX_ENEMIES { last_pickup[i] = -1 }
    trip_total, trip_count: int

    mined_in_window  := 0
    dens_done_window := -1

    for frame in 0 ..< SOAK_MINUTES * WINDOW {
        update_enemies(gs)

        // Count builder mining before the queue is drained.
        n := gs.events.size
        qi := gs.events.head
        for _ in 0 ..< n {
            if gs.events.events[qi].type == .Builder_Mined { mined_in_window += 1 }
            qi = (qi + 1) % MAX_EVENTS
        }
        process_events(gs)
        eq_clear(&gs.events)

        // Fetch round trips: carry going empty -> loaded is a harvest pickup.
        for bi in 0 ..< MAX_ENEMIES {
            if !gs.enemies.active[bi] { continue }
            c := gs.enemies.data[bi].builder.carry
            if prev_carry[bi] == .Air && c != .Air {
                if last_pickup[bi] >= 0 {
                    trip_total += frame - last_pickup[bi]
                    trip_count += 1
                }
                last_pickup[bi] = frame
            }
            prev_carry[bi] = c
        }

        if (frame + 1) % WINDOW == 0 {
            window := (frame + 1) / WINDOW
            all_built := true
            for bi in 0 ..< MAX_ENEMIES {
                if gs.enemies.active[bi] && !gs.enemies.data[bi].builder.den_built {
                    all_built = false
                }
            }
            if dens_done_window < 0 && all_built { dens_done_window = window }
            // Once every den stands the economy must never stall: a silent
            // minute across 3 builders means the 3-strike watchdog is looping.
            if dens_done_window >= 0 && window > dens_done_window {
                testing.expectf(t, mined_in_window > 0, "no builder mined anything in minute %d", window)
            }
            mined_in_window = 0
        }
    }

    testing.expectf(t, dens_done_window >= 0 && dens_done_window <= 10,
        "all dens should stand within 10 minutes (done at %d)", dens_done_window)

    // The deposit loop must have produced raidable loot (builder deposits are
    // the only world items in this cave besides the generated blueprint).
    loot := 0
    for i in 0 ..< GRID_W * GRID_H {
        if gs.world.items[i] != .None && gs.world.items[i] != .Blueprint_B {
            loot += int(gs.world.item_counts[i])
        }
    }
    testing.expect(t, loot > 0, "den floors should hold stockpiled loot")

    testing.expect(t, trip_count > 0, "builders should complete fetch round trips")
    if trip_count > 0 {
        log.infof("soak: %d fetch round trips, avg %.1f s; %d loot items banked",
            trip_count, f32(trip_total) / f32(trip_count) / 60.0, loot)
    }
}

@(test)
hunt_escape_soak :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    testing.expect(t, idx >= 0, "level 0 should have a builder")
    e := &gs.enemies.data[idx]

    step :: proc(gs: ^Game_State) {
        update_enemies(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }

    for cycle in 0 ..< 10 {
        gs.player.hp   = gs.player.hp_max
        gs.player.dead = false

        // Park the player 10 tiles out (inside hunt range, outside bite
        // range) and enrage the builder.
        gs.player.pos = {e.pos.x + 10, e.pos.y}
        builder_alert(gs, idx)
        testing.expect_value(t, e.builder.goal, Builder_Goal.Hunt)

        // Chase for 2 simulated seconds.
        for _ in 0 ..< 120 { step(gs) }

        // Escape: teleport high above the cave, far beyond HUNT_LOSE_DIST.
        gs.player.pos = {e.pos.x, 5}
        escaped := false
        for _ in 0 ..< int((LOS_MEMORY + 2.0) * 60) {
            step(gs)
            if e.builder.goal != .Hunt { escaped = true; break }
        }
        testing.expectf(t, escaped, "cycle %d: builder never gave up the hunt", cycle)
        testing.expect_value(t, e.builder.stuck_count, 0)

        // Let it settle back into work before the next cycle.
        for _ in 0 ..< 300 { step(gs) }
        testing.expect(t, e.builder.goal != .Hunt, "builder should be back at work between cycles")
    }
}

@(test)
entity_map_tracks_enemies :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Level 0 spawns 2 builders; each must be registered at its center tile
    registered := 0
    for i in 0 ..< GRID_W * GRID_H {
        id := gs.world.entity_map[i]
        if id != PLAYER_ID && id != INVALID_ENTITY do registered += 1
    }
    testing.expect_value(t, registered, gs.enemies.count)

    // Markers follow the enemy across an update tick
    update_enemies(gs)
    registered = 0
    for i in 0 ..< GRID_W * GRID_H {
        id := gs.world.entity_map[i]
        if id != PLAYER_ID && id != INVALID_ENTITY do registered += 1
    }
    testing.expect_value(t, registered, gs.enemies.count)
}

@(test)
enemy_death_despawns_and_clears_map :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Find an active builder
    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    testing.expect(t, idx >= 0, "level 0 should have a builder")
    before := gs.enemies.count
    tile   := builder_tile(&gs.enemies.data[idx])

    eq_push(&gs.events, Event{type = .Entity_Died, source = enemy_entity_id(idx)})
    process_events(gs)

    testing.expect(t, !gs.enemies.active[idx], "enemy slot freed on death")
    testing.expect_value(t, gs.enemies.count, before - 1)
    testing.expect(t, gs.world.entity_map[grid_idx(int(tile.x), int(tile.y))] != enemy_entity_id(idx),
        "entity map cell cleared on despawn")
    testing.expect_value(t, gs.stats.total_kills, 1)
}

@(test)
dead_player_cannot_act :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos  = {30, f32(SURFACE_Y) - PLAYER_H}
    gs.player.dead = true
    inv := &gs.player.inventory

    // Place rejected (target itself is valid)
    set_tile(&gs.world, 32, SURFACE_Y - 1, .Air)
    inventory_insert(inv, .Stone_Block, 5)
    inv.selected = 1   // slot 0 holds the starting Pickaxe
    handle_place_request(gs, Event{tile = {32, i32(SURFACE_Y) - 1}})
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y - 1), Tile_Type.Air)
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 5)

    // Craft rejected (hand recipe, ingredients present)
    inventory_insert(inv, .Wood_Log, 1)
    handle_craft_request(gs, Event{payload = {int_val = 0}})
    testing.expect_value(t, inventory_count(inv, .Plank), 0)

    // Ritual rejected (blueprint + materials present, on the sky level)
    gs.level_index = LEVEL_SKY
    gs.progression.blueprint_found[0] = true
    inventory_insert(inv, .Cloud_Stone, 8)
    inventory_insert(inv, .Plank, 4)
    handle_ritual_request(gs)
    process_events(gs)
    testing.expect(t, !gs.progression.sky_structure_complete[0], "dead player cannot perform the ritual")
}

@(test)
item_icons_are_well_formed :: proc(t: ^testing.T) {
    // Every item has 12 rows of 12 chars, every char resolves to a palette
    // color or transparent, and no icon but .None is fully invisible.
    for icon, it in item_icons {
        if it == .None do continue
        opaque := 0
        for row, gy in icon.grid {
            if len(row) != ICON_GRID {
                log.errorf("%v row %d is %d chars, want %d", it, gy, len(row), ICON_GRID)
                testing.fail(t)
                continue
            }
            for gx in 0 ..< len(row) {
                ch := row[gx]
                if _, ok := icon_pixel(icon.pal, ch); ok {
                    opaque += 1
                } else if ch != '.' {
                    log.errorf("%v has char %c mapping to nothing (palette slot unset?)", it, ch)
                    testing.fail(t)
                }
            }
        }
        testing.expect(t, opaque > 0, "icon draws nothing")
    }
}

@(test)
ambience_breathes_motes_into_the_air :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // ~10 s of ticks on the surface: the probe pass must find open air and
    // shed drifting motes into the particle pool.
    for _ in 0 ..< 600 {
        gs.frame += 1
        update_ambience(gs)
        update_particles(gs)
    }
    testing.expect(t, gs.particles.count > 0, "no ambient motes spawned")
}

// ─── Machine sim (smelter, tree grower) ──────────────────────────────────────

@(test)
smelter_casts_bars_from_ground_ore :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A smelter on the surface with 4 iron ore and 1 wood laid beside it.
    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    in_idx := grid_idx(sx - 1, sy)
    gs.world.items[in_idx]       = .Iron_Ore
    gs.world.item_counts[in_idx] = 4
    fuel_idx := grid_idx(sx + 1, sy)
    gs.world.items[fuel_idx]       = .Wood_Log
    gs.world.item_counts[fuel_idx] = 1

    // Two smelt cycles: 4 ore → 2 bars; one log covers both (BARS_PER_LOG=3).
    frames := int((SMELT_TIME * 2) / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }

    testing.expect_value(t, gs.world.items[in_idx], Item.None)    // ore fully eaten
    testing.expect_value(t, gs.world.items[fuel_idx], Item.None)  // the log went in the fire
    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    testing.expect_value(t, sd.store_item, Item.Iron_Bar)
    testing.expect_value(t, int(sd.store_count), 2)
    testing.expect_value(t, int(sd.fuel_charge), BARS_PER_LOG - 2)  // embers left for one more

    // The leftover embers fire a third bar with no wood beside the fire.
    gs.world.items[in_idx]       = .Iron_Ore
    gs.world.item_counts[in_idx] = 2
    frames = int(SMELT_TIME / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }
    testing.expect_value(t, int(sd.store_count), 3)
    testing.expect_value(t, int(sd.fuel_charge), 0)

    // Nothing lands on the ground — the bars wait in the tray.
    ground := 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        idx := grid_idx(sx + dx, sy + dy)
        if gs.world.items[idx] == .Iron_Bar do ground += int(gs.world.item_counts[idx])
    }
    testing.expect_value(t, ground, 0)

    // The fire dies without ore: progress stays zero.
    update_sim(gs)
    testing.expect_value(t, sd.growth_timer, f32(0))
}

@(test)
smelter_stalls_without_wood :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Ore beside the fire but nothing to burn: no progress, no bars.
    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    in_idx := grid_idx(sx - 1, sy)
    gs.world.items[in_idx]       = .Iron_Ore
    gs.world.item_counts[in_idx] = 4

    frames := int((SMELT_TIME * 2) / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }

    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    testing.expect_value(t, sd.growth_timer, f32(0))
    testing.expect_value(t, int(sd.store_count), 0)
    testing.expect_value(t, int(gs.world.item_counts[in_idx]), 4)  // ore untouched
}

@(test)
smelter_tray_collects_to_bag_and_spills_on_mine :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    gs.player.pos = {f32(sx - 2), f32(sy - 1)}  // within BENCH_RANGE

    // Three bars wait in the tray: collecting moves them all into the bag.
    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    sd.store_item  = .Iron_Bar
    sd.store_count = 3
    testing.expect(t, smelter_collect(gs, {i32(sx), i32(sy)}), "collect rejected")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Bar), 3)
    testing.expect_value(t, int(sd.store_count), 0)
    testing.expect_value(t, sd.store_item, Item.None)

    // Mining the furnace spills a loaded tray to the ground — never lost.
    sd.store_item  = .Gold_Bar
    sd.store_count = 2
    handle_tile_mined(gs, Event{tile = {i32(sx), i32(sy)}})
    testing.expect_value(t, int(sd.store_count), 0)  // tray died with the tile
    spilled := 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        idx := grid_idx(sx + dx, sy + dy)
        if gs.world.items[idx] == .Gold_Bar do spilled += int(gs.world.item_counts[idx])
    }
    testing.expect_value(t, spilled, 2)
}

@(test)
tree_grower_raises_trees_over_time :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gx, gy := GRID_W/2 + 5, SURFACE_Y - 1
    set_tile(&gs.world, gx, gy, .Tree_Grower)
    for h in 1 ..= TREE_MAX_H do set_tile(&gs.world, gx, gy - h, .Air)

    frames := int(TREE_GROW_TIME / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }
    testing.expect_value(t, get_tile(&gs.world, gx, gy - 1), Tile_Type.Wood)

    // A standing trunk pauses the grower until it is harvested.
    update_sim(gs)
    testing.expect_value(t, gs.world.sim_data[grid_idx(gx, gy)].growth_timer, f32(0))
}

@(test)
q_drop_lands_ahead_of_the_pickup_sweep :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inventory_insert(&gs.player.inventory, .Iron_Ore, 5)
    slot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }
    gs.player.facing = 1

    handle_item_dropped(gs, Event{payload = {int_val = i32(slot)}})
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)

    // The stack lies ahead of the player — the pickup sweep must not reclaim it.
    player_pickup(gs)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)

    tx := int(gs.player.pos.x + PLAYER_W*0.5) + 2
    ty := int(gs.player.pos.y + PLAYER_H - 0.001)
    found := 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        if !in_bounds(tx + dx, ty + dy) do continue
        idx := grid_idx(tx + dx, ty + dy)
        if gs.world.items[idx] == .Iron_Ore do found += int(gs.world.item_counts[idx])
    }
    testing.expect_value(t, found, 5)
}

// Ore lying beside a smelter, counted over its 8 neighbor cells.
count_ore_beside :: proc(gs: ^Game_State, sx, sy: int, item: Item) -> int {
    n := 0
    for dy in -1 ..= 1 do for dx in -1 ..= 1 {
        if dx == 0 && dy == 0 do continue
        idx := grid_idx(sx + dx, sy + dy)
        if gs.world.items[idx] == item do n += int(gs.world.item_counts[idx])
    }
    return n
}

@(test)
smelter_feed_lays_bag_ore_beside_furnace :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    gs.player.pos = {f32(sx - 2), f32(sy - 1)}  // within BENCH_RANGE

    inventory_insert(&gs.player.inventory, .Iron_Ore, 5)
    slot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }

    ok := smelter_feed(gs, {i32(sx), i32(sy)}, slot)
    testing.expect(t, ok, "feed rejected")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)
    testing.expect_value(t, count_ore_beside(gs, sx, sy, .Iron_Ore), 5)

    // A second feed stacks onto the same cell rather than scattering.
    inventory_insert(&gs.player.inventory, .Iron_Ore, 3)
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }
    testing.expect(t, smelter_feed(gs, {i32(sx), i32(sy)}, slot), "second feed rejected")
    testing.expect_value(t, count_ore_beside(gs, sx, sy, .Iron_Ore), 8)

    // Wood is fuel — the furnace takes it the same way.
    inventory_insert(&gs.player.inventory, .Wood_Log, 2)
    for s, i in gs.player.inventory.slots do if s.item == .Wood_Log { slot = i; break }
    testing.expect(t, smelter_feed(gs, {i32(sx), i32(sy)}, slot), "wood feed rejected")
    testing.expect_value(t, count_ore_beside(gs, sx, sy, .Wood_Log), 2)
}

@(test)
smelter_feed_rejects_non_ore :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    gs.player.pos = {f32(sx - 2), f32(sy - 1)}

    inventory_insert(&gs.player.inventory, .Plank, 3)
    slot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Plank { slot = i; break }

    testing.expect(t, !smelter_feed(gs, {i32(sx), i32(sy)}, slot), "plank must not feed the fire")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Plank), 3)
    testing.expect_value(t, count_ore_beside(gs, sx, sy, .Plank), 0)
}

@(test)
smelter_feed_requires_reach :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    gs.player.pos = {f32(sx - 20), f32(sy - 1)}  // far outside BENCH_RANGE

    inventory_insert(&gs.player.inventory, .Iron_Ore, 4)
    slot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }

    testing.expect(t, !smelter_feed(gs, {i32(sx), i32(sy)}, slot), "feed must fail out of reach")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 4)
    testing.expect_value(t, count_ore_beside(gs, sx, sy, .Iron_Ore), 0)
}
