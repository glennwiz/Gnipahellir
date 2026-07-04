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

@(test)
mining_respects_reach :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)
    gs.input.mine = true

    // Within reach: grass 2 tiles away gets mined (opens to void)
    gs.input.mouse_tile = {32, i32(SURFACE_Y)}
    update_player(gs)
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y), Tile_Type.Void)

    // Out of reach: grass 20 tiles away is untouched
    gs.input.mouse_tile = {50, i32(SURFACE_Y)}
    update_player(gs)
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, 50, SURFACE_Y), Tile_Type.Grass)
}

@(test)
mining_leaves_drops_leaf_and_opens_to_air :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)
    set_tile(&gs.world, 32, SURFACE_Y - 3, .Leaves)

    gs.input.mine = true
    gs.input.mouse_tile = {32, i32(SURFACE_Y - 3)}
    update_player(gs)
    process_events(gs)

    // Above the surface line the hole opens to air (not void), leaf drops
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y - 3), Tile_Type.Air)
    testing.expect_value(t, gs.world.items[grid_idx(32, SURFACE_Y - 3)], Item.Leaf)
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

    SOAK_MINUTES :: 30
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
    inv.selected = 0
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
