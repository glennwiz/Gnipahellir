package game

import "core:testing"

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
    return gs
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
    gs.player.inventory.selected = 0

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

    // Take the sky portal (always open)
    sky_portal := &level_portals[LEVEL_SURFACE][1]
    level_transition(gs, sky_portal)
    testing.expect_value(t, gs.level_index, LEVEL_SKY)
    testing.expect_value(t, get_tile(&gs.world, 95, 79), Tile_Type.Sky_Entrance)

    // Mine a cloud in the sky, then return
    set_tile(&gs.world, 90, 80, .Air)
    back := &level_portals[LEVEL_SKY][0]
    level_transition(gs, back)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    testing.expect_value(t, get_tile(&gs.world, 50, 50), Tile_Type.Gold_Ore)

    // And the sky remembers the mined cloud
    level_transition(gs, sky_portal)
    testing.expect_value(t, get_tile(&gs.world, 90, 80), Tile_Type.Air)
}

@(test)
sky_fall_returns_to_surface :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    level_transition(gs, &level_portals[LEVEL_SURFACE][1])
    testing.expect_value(t, gs.level_index, LEVEL_SKY)

    gs.player.pos = {50, 90}  // below the cloud line
    update_player(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
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
