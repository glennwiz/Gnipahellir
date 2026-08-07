package game

import "core:testing"
import "core:strings"
import "core:log"
import "core:os"

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
    // Production spawns the pickaxe on the grass to be picked up and equipped;
    // most tests want a ready-to-mine player, so put it in its dedicated slot.
    gs.player.equipment[.Tool] = .Pickaxe
    return gs
}

@(test)
starter_pickaxe_waits_on_the_shaft_ledge :: proc(t: ^testing.T) {
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)  // production init — not test_state's pickaxe handout

    // The player wakes empty-handed.
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Pickaxe), 0)

    // A pickaxe rests on a stone ledge ~7 tiles down the entrance shaft, so the
    // player drops in (a small fall) to reach it and the surface stays close.
    pick_x := GRID_W / 2
    pick_y := SURFACE_Y + 7
    idx := grid_idx(pick_x, pick_y)
    testing.expect_value(t, gs.world.items[idx], Item.Pickaxe)
    testing.expect_value(t, get_tile(&gs.world, pick_x, pick_y + 1), Tile_Type.Stone)

    // Landing on it collects it and clears the tile.
    gs.player.pos = {f32(pick_x), f32(pick_y + 1) - PLAYER_H}
    player_pickup(gs)
    testing.expect(t, inventory_count(&gs.player.inventory, .Pickaxe) >= 1, "pickaxe not collected")
    testing.expect_value(t, item_equip_slot[.Pickaxe], Equip_Slot.Tool)
    testing.expect_value(t, gs.player.equipment[.Tool], Item.None)
    testing.expect_value(t, gs.world.items[idx], Item.None)
}

@(test)
first_pickaxe_teaches_mining_once :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // First pickaxe pickup pops the one-shot mining hint.
    testing.expect(t, !gs.pickaxe_hint_shown, "hint starts unshown")
    eq_push(&gs.events, Event{type = .Item_Pickup, payload = {int_val = i32(Item.Pickaxe)}})
    process_events(gs)
    testing.expect(t, gs.pickaxe_hint_shown, "first pickaxe should arm the hint")
    testing.expect_value(t, gs.notify.count, 1)

    // A second pickup (dropped-and-repicked) must not re-notify.
    eq_push(&gs.events, Event{type = .Item_Pickup, payload = {int_val = i32(Item.Pickaxe)}})
    process_events(gs)
    testing.expect_value(t, gs.notify.count, 1)
}

@(test)
first_wood_log_teaches_crafting_once :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // First wood log pops the one-shot hand-crafting hint.
    testing.expect(t, !gs.craft_hint_shown, "hint starts unshown")
    eq_push(&gs.events, Event{type = .Item_Pickup, payload = {int_val = i32(Item.Wood_Log)}})
    process_events(gs)
    testing.expect(t, gs.craft_hint_shown, "first log should arm the crafting hint")
    testing.expect_value(t, gs.notify.count, 1)

    // Later logs don't re-notify.
    eq_push(&gs.events, Event{type = .Item_Pickup, payload = {int_val = i32(Item.Wood_Log)}})
    process_events(gs)
    testing.expect_value(t, gs.notify.count, 1)
}

@(test)
first_wand_teaches_equipping :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // First crafted wand pops the one-shot "equip it" hint.
    testing.expect(t, !gs.wand_hint_shown, "hint starts unshown")
    eq_push(&gs.events, Event{type = .Craft_Complete, payload = {int_val = i32(Item.Mine_Wand)}})
    process_events(gs)
    testing.expect(t, gs.wand_hint_shown, "first wand should arm the equip hint")
    testing.expect_value(t, gs.notify.count, 1)

    // A later wand (any tier) doesn't re-notify.
    eq_push(&gs.events, Event{type = .Craft_Complete, payload = {int_val = i32(Item.Mine_Wand_Silver)}})
    process_events(gs)
    testing.expect_value(t, gs.notify.count, 1)
}

@(test)
mining_the_shaft_apron_yields_rock_and_dirt :: proc(t: ^testing.T) {
    // Digging the loose stratum the cave mouth cuts through drops the rock on
    // the ground the normal way AND banks a clod of dirt straight into the bag
    // (with a collect mote).  The same dig anywhere else on the cap band gives
    // only the ground rock.  The reward zone is exactly the brown-scuffed apron.
    drop_near :: proc(gs: ^Game_State, x, y: int, it: Item) -> bool {
        for dy in -2 ..= 2 do for dx in -2 ..= 2 {
            if !in_bounds(x + dx, y + dy) do continue
            idx := grid_idx(x + dx, y + dy)
            if gs.world.items[idx] == it && gs.world.item_counts[idx] > 0 do return true
        }
        return false
    }

    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)             // production world — the real shaft
    gs.level_index = LEVEL_SURFACE
    inv := &gs.player.inventory

    ent_x := GRID_W / 2

    // A stone tile one step off the shaft is inside the apron: rock on the
    // ground, dirt in the bag, and a collect mote in flight.
    ax, ay := ent_x - 1, SURFACE_Y + 1
    testing.expect(t, in_shaft_apron(&gs.world, ax, ay), "tile beside the shaft is aproned")
    eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(ax), i32(ay)}})
    process_events(gs)
    testing.expect(t, drop_near(gs, ax, ay, .Stone_Block), "apron rock drops on the ground")
    testing.expect_value(t, inventory_count(inv, .Dirt), 1)
    testing.expect(t, !drop_near(gs, ax, ay, .Dirt), "apron dirt banks to the bag, not the ground")
    testing.expect(t, gs.particles.count > 0, "banked dirt spawns a collect mote")

    // A stone tile far along the same band is normal ground — a rock drops on
    // the tile, no dirt, and the bag gains nothing.
    fx, fy := 10, SURFACE_Y + 1
    testing.expect(t, !in_shaft_apron(&gs.world, fx, fy), "far tile is outside the apron")
    eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(fx), i32(fy)}})
    process_events(gs)
    testing.expect(t, drop_near(gs, fx, fy, .Stone_Block), "normal stone still drops a rock on the ground")
    testing.expect(t, !drop_near(gs, fx, fy, .Dirt), "normal stone must not drop dirt")
    testing.expect_value(t, inventory_count(inv, .Dirt), 1)  // unchanged by the far dig
}

@(test)
shaft_mouth_is_dressable :: proc(t: ^testing.T) {
    // draw_shaft_mouth dresses the descent shaft by reading terrain alone: a
    // Void column that opens to Air above and is walled by ground on both sides
    // through the surface cap.  Guard those assumptions so a gen change that
    // reshapes the mouth trips here instead of silently un-dressing it.
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)  // production world — the real shaft
    w := &gs.world

    ent_x := GRID_W / 2
    // The mouth opens to sky.
    testing.expect_value(t, get_tile(w, ent_x, SURFACE_Y - 1), Tile_Type.Air)
    // Void column walled by solid ground down the whole cap band.
    for y in SURFACE_Y ..< CAVE_TOP {
        testing.expect_value(t, get_tile(w, ent_x, y), Tile_Type.Void)
        testing.expect_value(t, get_tile(w, ent_x + 1, y), Tile_Type.Void)
        lw := get_tile(w, ent_x - 1, y)
        rw := get_tile(w, ent_x + 2, y)
        testing.expect(t, lw != .Void && lw != .Air, "left wall must be ground to dress")
        testing.expect(t, rw != .Void && rw != .Air, "right wall must be ground to dress")
    }
    // And no stray surface Void elsewhere on the cap rows — the pass must find
    // only the shaft, nothing spurious in the grass.
    for y in SURFACE_Y ..< CAVE_TOP {
        for x in 0 ..< GRID_W {
            if get_tile(w, x, y) == .Void {
                testing.expect(t, x == ent_x || x == ent_x + 1, "only the shaft is Void in the cap band")
            }
        }
    }
}

@(test)
rune_scroll_overlay_tracks_the_active_objective :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // No rune scroll found → nothing for the overlay to show.
    testing.expect_value(t, rune_scroll_active_tier(gs), -1)

    // Finding tier 0's rune scroll makes it the active objective.
    gs.progression.rune_scroll_found[0] = true
    testing.expect_value(t, rune_scroll_active_tier(gs), 0)
    testing.expect_value(t, rune_scroll_unlocks_name(0), level_names[LEVEL_CAVE2])

    // Raising its structure advances to the next found rune scroll, else none.
    gs.progression.sky_structure_complete[0] = true
    testing.expect_value(t, rune_scroll_active_tier(gs), -1)
    gs.progression.rune_scroll_found[1] = true
    testing.expect_value(t, rune_scroll_active_tier(gs), 1)
    testing.expect_value(t, rune_scroll_unlocks_name(1), level_names[LEVEL_CAVE3])
}

@(test)
placed_structures_can_be_reclaimed :: proc(t: ^testing.T) {
    // Anything you place can return through the deliberate reclaim hold.
    for tile in ([]Tile_Type{.Sky_Altar, .Crafting_Bench, .Tree_Grower, .Smelter}) {
        b := terrain_table[tile]
        testing.expect(t, .Mineable in b.flags, "placed structure must be mineable to reclaim")
        testing.expect(t, b.drop_item != .None, "placed structure must drop its item when mined")
    }
}

@(test)
ordinary_mining_never_breaks_equipment :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    target := [2]i32{31, i32(SURFACE_Y) - 1}
    set_tile(&gs.world, int(target.x), int(target.y), .Smelter)
    gs.input.mine = true
    gs.input.mouse_tile = target
    gs.input.mouse_world = {(f32(target.x) + 0.5)*CELL_SIZE, (f32(target.y) + 0.5)*CELL_SIZE}

    for _ in 0 ..< 12 {
        gs.player.mine_timer = 0
        player_mine(gs, 1.0/60.0)
        process_events(gs)
    }
    testing.expect_value(t, get_tile(&gs.world, int(target.x), int(target.y)), Tile_Type.Smelter)
}

@(test)
equipment_reclaim_requires_one_continuous_hold :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    target := [2]i32{31, i32(SURFACE_Y) - 1}
    set_tile(&gs.world, int(target.x), int(target.y), .Smelter)
    gs.input.mouse_tile = target
    gs.input.reclaim = true
    gs.delta_time = 0.1

    for _ in 0 ..< 4 do update_reclaim(gs)
    gs.input.reclaim = false
    update_reclaim(gs) // releasing cancels all accumulated progress
    testing.expect(t, !gs.reclaim.active)
    testing.expect_value(t, gs.reclaim.timer, f32(0))

    gs.input.reclaim = true
    for _ in 0 ..< 7 do update_reclaim(gs)
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, int(target.x), int(target.y)), Tile_Type.Smelter)

    update_reclaim(gs)
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, int(target.x), int(target.y)), Tile_Type.Air)
    testing.expect_value(t, gs.world.items[grid_idx(int(target.x), int(target.y))], Item.Smelter)
}

@(test)
loaded_auto_miner_refuses_reclaim_and_click_collects :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.level_index = LEVEL_DIMENSION
    gs.player.pos = {30, 50}
    target := [2]i32{31, 51}
    set_tile(&gs.world, int(target.x), int(target.y), .Auto_Miner)
    gs.dimension.miner.active = true
    gs.dimension.miner.base = target
    gs.dimension.miner.head = target
    gs.dimension.miner.haul[0] = {.Iron_Ore, 12}
    gs.input.mouse_tile = target
    gs.input.reclaim = true
    gs.delta_time = 0.1

    for _ in 0 ..< 12 do update_reclaim(gs)
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, int(target.x), int(target.y)), Tile_Type.Auto_Miner)
    testing.expect_value(t, miner_haul_total(&gs.dimension.miner), u32(12))
    testing.expect(t, gs.reclaim.blocked, "loaded miner should block before progress starts")

    // Normal use of the exact machine collects its haul instead of damaging it.
    structure_interact(gs, target)
    testing.expect_value(t, miner_haul_total(&gs.dimension.miner), u32(0))
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 12)
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
stone_wood_altar_pixel_skin_requires_complete_foundation :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	ax,ay:=70,30
	for dx in -2..=2 do set_tile(&gs.world,ax+dx,ay+2,.Stone)
	for dx in -1..=1 do set_tile(&gs.world,ax+dx,ay+1,.Wood)
	testing.expect(t,sky_altar_has_stone_wood_foundation(&gs.world,ax,ay),"complete five-stone/three-wood base should receive the connected skin")
	set_tile(&gs.world,ax+1,ay+1,.Air)
	testing.expect(t,!sky_altar_has_stone_wood_foundation(&gs.world,ax,ay),"an incomplete base must keep ordinary block art")
}

@(test)
each_tier_raises_a_distinct_altar :: proc(t: ^testing.T) {
    // Every progression tier has its own template, and the deeper ones call for
    // silver and gold — so each rune scroll reads differently.
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
door_crafts_places_anchors_and_mines :: proc(t: ^testing.T) {
    // Full life of a door: craft it at the bench from planks, place the 2-tall
    // pair, confirm it's solid rock that anchors a stack, then mine it back to
    // one Door item — both halves gone.
    gs := test_state()
    defer free(gs)
    w := &gs.world
    inv := &gs.player.inventory

    // A bench door from planks, buildable from the start.
    door_recipe := -1
    for r, i in recipe_table do if r.result == .Door { door_recipe = i; break }
    testing.expect(t, door_recipe >= 0, "a Door recipe exists")
    testing.expect_value(t, recipe_table[door_recipe].station, Station.Bench)

    gs.player.pos = {20, 40}
    for yy in 38 ..= 43 do for xx in 18 ..= 24 do set_tile(w, xx, yy, .Air)
    set_tile(w, 22, 42, .Stone)           // ground the door hangs on
    set_tile(w, 19, 41, .Crafting_Bench)  // bench in reach

    inventory_insert(inv, .Plank, 4)
    handle_craft_request(gs, Event{payload = {int_val = i32(door_recipe)}})
    testing.expect_value(t, inventory_count(inv, .Door), 1)
    testing.expect_value(t, inventory_count(inv, .Plank), 0)

    // Place the 1×2 door (foot at 22,41; it rises into 22,40).
    for &s, i in inv.slots do if s.item == .Door { inv.selected = i; break }
    testing.expect(t, placement_ok(gs, .Door, 22, 41), "door fits the doorway")
    eq_push(&gs.events, Event{type = .Place_Request, tile = {22, 41}})
    process_events(gs)
    testing.expect_value(t, get_tile(w, 22, 41), Tile_Type.Door)
    testing.expect_value(t, get_tile(w, 22, 40), Tile_Type.Door)
    testing.expect(t, is_solid(w, 22, 41) && is_solid(w, 22, 40), "a door is solid rock")

    // Stable anchor like rock: a placed stone resting on the door holds.
    set_tile(w, 22, 39, .Stone)
    w.tile_flags[grid_idx(22, 39)] += {.Placed}
    gravity_check_removed(gs, 22, 39)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(w, 22, 39), Tile_Type.Stone)

    // Mine one half: the whole door goes, exactly one Door drops back.
    eq_push(&gs.events, Event{type = .Tile_Mined, tile = {22, 41}})
    process_events(gs)
    testing.expect(t, get_tile(w, 22, 41) != .Door && get_tile(w, 22, 40) != .Door, "both halves removed")
    testing.expect_value(t, w.items[grid_idx(22, 41)], Item.Door)
}

@(test)
door_passes_player_blocks_enemies :: proc(t: ^testing.T) {
    // A door is always open to the player and always shut to everyone else:
    // move_body's is_player is the only difference.
    gs := test_state()
    defer free(gs)
    w := &gs.world

    for yy in 48 ..= 52 do for xx in 96 ..= 104 do set_tile(w, xx, yy, .Air)
    set_tile(w, 100, 50, .Door)   // a 2-tall door across the lane
    set_tile(w, 100, 49, .Door)

    grounded: bool

    // Player (is_player) walks straight through, ending past the door column.
    ppos := [2]f32{98, 49}
    pvel := [2]f32{50, 0}
    move_body(w, &ppos, &pvel, {PLAYER_W, PLAYER_H}, 0.1, 0, 0, &grounded, is_player = true)
    testing.expect(t, ppos.x > 100, "the player phases through a door")

    // An enemy (is_player defaults false) is stopped short of the door.
    epos := [2]f32{98, 49}
    evel := [2]f32{50, 0}
    move_body(w, &epos, &evel, {PLAYER_W, PLAYER_H}, 0.1, 0, 0, &grounded)
    testing.expect(t, epos.x < 100, "a door walls other entities out")
}

@(test)
player_passes_through_structures_enemies_blocked :: proc(t: ^testing.T) {
    // Same is_player exception extended to player-built structures: a bench
    // (or any is_structure_tile row) is solid rock to everyone but the player,
    // and only sideways for the player — its top still catches a landing.
    gs := test_state()
    defer free(gs)
    w := &gs.world

    for yy in 40 ..= 52 do for xx in 96 ..= 104 do set_tile(w, xx, yy, .Air)
    set_tile(w, 100, 50, .Crafting_Bench)
    testing.expect(t, is_solid(w, 100, 50), "a structure is solid rock")

    grounded: bool

    ppos := [2]f32{98, 50}
    pvel := [2]f32{50, 0}
    move_body(w, &ppos, &pvel, {PLAYER_W, PLAYER_H}, 0.1, 0, 0, &grounded, is_player = true)
    testing.expect(t, ppos.x > 100, "the player phases through a structure sideways")

    epos := [2]f32{98, 50}
    evel := [2]f32{50, 0}
    move_body(w, &epos, &evel, {PLAYER_W, PLAYER_H}, 0.1, 0, 0, &grounded)
    testing.expect(t, epos.x < 100, "a structure walls other entities out")

    // Jump/fall onto the bench from above: the player still lands and stands
    // on its top like solid ground, even though its sides are walk-through.
    dpos := [2]f32{100, 44}
    dvel := [2]f32{}
    dgrounded := false
    for _ in 0 ..< 120 {
        move_body(w, &dpos, &dvel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &dgrounded, is_player = true)
    }
    testing.expect(t, dgrounded, "the player lands on top of a structure")
    testing.expect(t, abs(dpos.y + PLAYER_H - 50) < 0.01, "feet rest exactly on the structure's top")
}

@(test)
player_passes_through_rune_scroll_chests_sideways_only :: proc(t: ^testing.T) {
    // Rune Scroll chests aren't in is_structure_tile (they gate their own
    // separate reclaim/mining rules via is_rune_scroll_chest), so the
    // walk-through exception is wired to them independently in physics.odin
    // — verify it actually took.
    gs := test_state()
    defer free(gs)
    w := &gs.world

    for yy in 40 ..= 52 do for xx in 96 ..= 104 do set_tile(w, xx, yy, .Air)
    set_tile(w, 100, 50, .Rune_Scroll_Chest_A)
    testing.expect(t, is_solid(w, 100, 50), "a rune scroll chest is solid rock")

    grounded: bool

    ppos := [2]f32{98, 50}
    pvel := [2]f32{50, 0}
    move_body(w, &ppos, &pvel, {PLAYER_W, PLAYER_H}, 0.1, 0, 0, &grounded, is_player = true)
    testing.expect(t, ppos.x > 100, "the player phases through a rune scroll chest sideways")

    epos := [2]f32{98, 50}
    evel := [2]f32{50, 0}
    move_body(w, &epos, &evel, {PLAYER_W, PLAYER_H}, 0.1, 0, 0, &grounded)
    testing.expect(t, epos.x < 100, "a rune scroll chest walls other entities out")

    dpos := [2]f32{100, 44}
    dvel := [2]f32{}
    dgrounded := false
    for _ in 0 ..< 120 {
        move_body(w, &dpos, &dvel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &dgrounded, is_player = true)
    }
    testing.expect(t, dgrounded, "the player lands on top of a rune scroll chest")
    testing.expect(t, abs(dpos.y + PLAYER_H - 50) < 0.01, "feet rest exactly on the chest's top")
}

@(test)
dirt_places_and_mines_back :: proc(t: ^testing.T) {
    // The dirt clod is a building block: place it as a Dirt tile, mine it back
    // into a clod.  A full round trip so the item↔tile pairing can't drift.
    gs := test_state()
    defer free(gs)

    testing.expect_value(t, item_table[.Dirt].place_tile, Tile_Type.Dirt)

    inv := &gs.player.inventory
    inventory_insert(inv, .Dirt, 1)
    for &s, i in inv.slots do if s.item == .Dirt { inv.selected = i; break }

    // Stand in open surface air with solid ground one tile below the target.
    gs.player.pos = {20, 40}
    tx, ty := 22, 40
    set_tile(&gs.world, tx, ty + 1, .Stone)
    testing.expect(t, placement_ok(gs, .Dirt, tx, ty), "dirt should place in open air beside ground")

    eq_push(&gs.events, Event{type = .Place_Request, tile = {i32(tx), i32(ty)}})
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, tx, ty), Tile_Type.Dirt)
    testing.expect_value(t, inventory_count(inv, .Dirt), 0)   // the clod was consumed

    eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(tx), i32(ty)}})
    process_events(gs)
    testing.expect_value(t, gs.world.items[grid_idx(tx, ty)], Item.Dirt)   // mines back to a clod
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
wheel_zoom_keeps_world_point_under_cursor :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Stay clear of every level edge so this measures cursor anchoring rather
    // than the intentional camera clamp taking priority.
    gs.player.pos = {90, 50}
    gs.zoom = 2
    gs.zoom_target = 2
    camera_snap_y(gs)
    cursor := [2]f32{1200, 400}

    before := game_camera(gs)
    anchor := [2]f32{
        (cursor.x - before.offset.x)/before.zoom + before.target.x,
        (cursor.y - before.offset.y)/before.zoom + before.target.y,
    }

    request_zoom(gs, 1, cursor)
    gs.delta_time = 1.0/60.0
    for _ in 0 ..< 120 do update_camera(gs)

    after := game_camera(gs)
    under_cursor := [2]f32{
        (cursor.x - after.offset.x)/after.zoom + after.target.x,
        (cursor.y - after.offset.y)/after.zoom + after.target.y,
    }
    testing.expect(t, abs(under_cursor.x - anchor.x) < 0.01, "wheel zoom preserves cursor world X")
    testing.expect(t, abs(under_cursor.y - anchor.y) < 0.01, "wheel zoom preserves cursor world Y")
    testing.expect(t, gs.cam_pan.x != 0 || gs.cam_pan.y != 0, "cursor zoom offsets the player-centered camera")

    // Starting to move gently recenters; it must shrink rather than snap away.
    pan_before := abs(gs.cam_pan.x) + abs(gs.cam_pan.y)
    gs.player.vel.x = 1
    update_camera(gs)
    pan_after := abs(gs.cam_pan.x) + abs(gs.cam_pan.y)
    testing.expect(t, pan_after > 0, "movement recenter is gradual")
    testing.expect(t, pan_after < pan_before, "movement pulls cursor pan back toward the player")
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
rune_scroll_chest_opens_container_then_claims :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {10, 40}
    set_tile(&gs.world, 11, 41, .Rune_Scroll_Chest_A)

    testing.expect(t, open_rune_scroll_chest(gs, {11, 41}), "chest should be recognized")
    testing.expect(t, gs.ui.show_barrel, "chest should open the shared container window")
    testing.expect(t, gs.ui.show_inventory, "bag should open beside the chest")
    testing.expect(t, !gs.progression.rune_scroll_found[0], "opening alone must not claim the rune scroll")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Rune_Scroll_A), 0)
    testing.expect_value(t, get_tile(&gs.world, 11, 41), Tile_Type.Rune_Scroll_Chest_A)
    chest_store := barrel_at(gs, gs.level_index, {11, 41})
    testing.expect(t, chest_store != nil, "opening should create ordinary 4x4 storage")
    testing.expect_value(t, chest_store.slots[RUNE_SCROLL_CHEST_SLOT].item, Item.Rune_Scroll_A)

    eq_push(&gs.events, Event{
        type    = .Barrel_Take,
        tile    = {11, 41},
        payload = {int_val = RUNE_SCROLL_CHEST_SLOT},
    })
    process_events(gs)

    testing.expect(t, gs.progression.rune_scroll_found[0], "rune scroll A should set tier 0")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Rune_Scroll_A), 1)
    testing.expect_value(t, get_tile(&gs.world, 11, 41), Tile_Type.Rune_Scroll_Chest_A)
    testing.expect(t, gs.ui.show_barrel, "permanent chest window should stay open")

    // The same chest is immediately reusable as ordinary storage.
    gs.player.inventory.slots[1] = {.Stone_Block, 3}
    eq_push(&gs.events, Event{
        type    = .Barrel_Store,
        tile    = {11, 41},
        payload = {int_val = 1},
    })
    process_events(gs)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 0)
    testing.expect_value(t, barrel_total(chest_store), 3)
}

@(test)
sealed_chest_refuses_pickup_until_the_scroll_is_out :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)

	gs.player.pos = {10, 40}
	set_tile(&gs.world, 11, 41, .Rune_Scroll_Chest_A)

	// Still sealed: the hold is refused outright, so the scroll can never be
	// swallowed by prising the coffer loose.
	testing.expect_value(t, structure_reclaim_block(gs, {11, 41}), Reclaim_Block.Sealed_Chest)
	gs.input.reclaim    = true
	gs.input.mouse_tile = {11, 41}
	for _ in 0 ..< 60 do update_reclaim(gs)
	process_events(gs)
	testing.expect(t, gs.reclaim.blocked, "a sealed chest must block the hold")
	testing.expect_value(t, get_tile(&gs.world, 11, 41), Tile_Type.Rune_Scroll_Chest_A)
	testing.expect_value(t, gs.world.items[grid_idx(11, 41)], Item.None)

	// Take the scroll the ordinary way, then the emptied chest comes loose.
	testing.expect(t, open_rune_scroll_chest(gs, {11, 41}), "chest should open")
	eq_push(&gs.events, Event{type = .Barrel_Take, tile = {11, 41},
		payload = {int_val = RUNE_SCROLL_CHEST_SLOT}})
	process_events(gs)
	testing.expect_value(t, inventory_count(&gs.player.inventory, .Rune_Scroll_A), 1)

	testing.expect_value(t, structure_reclaim_block(gs, {11, 41}), Reclaim_Block.None)
	gs.reclaim = {}
	for _ in 0 ..< 60 do update_reclaim(gs)
	process_events(gs)
	// Reclaims drop at the tile as a ground pile, same as any other structure.
	testing.expect_value(t, gs.world.items[grid_idx(11, 41)], Item.Rune_Coffer)
	testing.expect(t, get_tile(&gs.world, 11, 41) != .Rune_Scroll_Chest_A, "the chest should be gone from the world")
	testing.expect(t, barrel_at(gs, gs.level_index, {11, 41}) == nil, "its storage record should be freed")
}

@(test)
rune_coffer_re_places_as_ordinary_storage :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)

	gs.player.pos = {10, 40}
	inventory_insert(&gs.player.inventory, .Rune_Coffer, 1)
	for &s, i in gs.player.inventory.slots {
		if s.item == .Rune_Coffer { gs.player.inventory.selected = i; break }
	}
	// Placed adjacent to the player so the PICK_RANGE reclaim can reach it later.
	set_tile(&gs.world, 11, 42, .Stone)  // something to attach to
	eq_push(&gs.events, Event{type = .Place_Request, tile = {11, 41}})
	process_events(gs)

	testing.expect_value(t, get_tile(&gs.world, 11, 41), Tile_Type.Rune_Coffer)
	b := barrel_at(gs, gs.level_index, {11, 41})
	testing.expect(t, b != nil, "a placed coffer claims a storage record")

	// It stores like any barrel, and refuses the pick while loaded.
	gs.player.inventory.slots[0] = {.Stone_Block, 3}
	eq_push(&gs.events, Event{type = .Barrel_Store, tile = {11, 41}, payload = {int_val = 0}})
	process_events(gs)
	testing.expect_value(t, barrel_total(b), 3)
	testing.expect_value(t, structure_reclaim_block(gs, {11, 41}), Reclaim_Block.Loaded_Coffer)

	// Emptied, it comes straight back up as a coffer again.
	eq_push(&gs.events, Event{type = .Barrel_Take, tile = {11, 41}, payload = {int_val = 0}})
	process_events(gs)
	testing.expect_value(t, structure_reclaim_block(gs, {11, 41}), Reclaim_Block.None)
	gs.input.reclaim    = true
	gs.input.mouse_tile = {11, 41}
	for _ in 0 ..< 60 do update_reclaim(gs)
	process_events(gs)
	testing.expect_value(t, gs.world.items[grid_idx(11, 41)], Item.Rune_Coffer)
	testing.expect(t, barrel_at(gs, gs.level_index, {11, 41}) == nil, "reclaim frees the record")
}

@(test)
rune_scroll_stays_inside_open_chest_when_bag_is_full :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {10, 40}
    for i in 0 ..< MAX_INVENTORY {
        gs.player.inventory.slots[i] = {.Stone_Block, MAX_STACK}
    }
    set_tile(&gs.world, 11, 41, .Rune_Scroll_Chest_A)

    testing.expect(t, open_rune_scroll_chest(gs, {11, 41}), "chest should be recognized")
    testing.expect(t, gs.ui.show_barrel, "full bag must not prevent the chest window opening")
    eq_push(&gs.events, Event{
        type    = .Barrel_Take,
        tile    = {11, 41},
        payload = {int_val = RUNE_SCROLL_CHEST_SLOT},
    })
    process_events(gs)

    testing.expect_value(t, get_tile(&gs.world, 11, 41), Tile_Type.Rune_Scroll_Chest_A)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Rune_Scroll_A), 0)
    testing.expect(t, gs.ui.show_barrel, "open chest should remain visible after a refused take")
    chest_store := barrel_at(gs, gs.level_index, {11, 41})
    testing.expect(t, chest_store != nil, "full bag must not remove chest storage")
    testing.expect_value(t, chest_store.slots[RUNE_SCROLL_CHEST_SLOT].item, Item.Rune_Scroll_A)
}

@(test)
loose_rune_scrolls_are_sealed_for_save_compatibility :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := grid_idx(20, 80)
    set_tile(&gs.world, 20, 80, .Void)
    gs.world.items[idx]       = .Rune_Scroll_C
    gs.world.item_counts[idx] = 1

    seal_loose_rune_scrolls(&gs.world)

    testing.expect_value(t, get_tile(&gs.world, 20, 80), Tile_Type.Rune_Scroll_Chest_C)
    testing.expect_value(t, gs.world.items[idx], Item.None)
    testing.expect_value(t, gs.world.item_counts[idx], 0)
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
inventory_stack_splits_without_losing_items :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    inv := &gs.player.inventory

    inventory_insert(inv, .Stone_Block, 5)
    eq_push(&gs.events, Event{type = .Inventory_Split, payload = {int_val = 0}})
    process_events(gs)

    testing.expect_value(t, inv.slots[0].count, 2)
    testing.expect_value(t, inv.slots[1].item, Item.Stone_Block)
    testing.expect_value(t, inv.slots[1].count, 3)
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 5)
    testing.expect(t, gs.save_dirty, "splitting a stack should autosave")

    // A full bag refuses the split and preserves the complete stack.
    for &s in inv.slots do s = {item = .Stone_Block, count = MAX_STACK}
    inv.slots[0].count = 5
    gs.notify.count = 0
    testing.expect(t, !inventory_split_stack(gs, 0))
    testing.expect_value(t, inv.slots[0].count, 5)
    testing.expect_value(t, gs.notify.count, 1)
}

@(test)
inventory_drag_moves_merges_and_swaps :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    inv := &gs.player.inventory

    // Move a stack into an empty slot; selection follows it.
    inv.slots[1] = {item = .Stone_Block, count = 30}
    inv.selected = 1
    testing.expect(t, inventory_move_stack(gs, 1, 4))
    testing.expect_value(t, inv.slots[1].item, Item.None)
    testing.expect_value(t, inv.slots[4].count, 30)
    testing.expect_value(t, inv.selected, 4)

    // Merge into a matching stack, capped at 99 with the remainder preserved.
    inv.slots[2] = {item = .Stone_Block, count = 80}
    testing.expect(t, inventory_move_stack(gs, 4, 2))
    testing.expect_value(t, inv.slots[2].count, MAX_STACK)
    testing.expect_value(t, inv.slots[4].count, 11)
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 110)

    // Unlike stacks exchange slots without losing either one.
    inv.slots[3] = {item = .Wood_Log, count = 7}
    testing.expect(t, inventory_move_stack(gs, 3, 4))
    testing.expect_value(t, inv.slots[3].item, Item.Stone_Block)
    testing.expect_value(t, inv.slots[3].count, 11)
    testing.expect_value(t, inv.slots[4].item, Item.Wood_Log)
    testing.expect_value(t, inv.slots[4].count, 7)
}

@(test)
void_charm_recipe_uses_tier_two_riches :: proc(t: ^testing.T) {
    found := false
    for r in recipe_table {
        if r.result != .Void_Charm do continue
        found = true
        testing.expect_value(t, r.station, Station.Forge)
        testing.expect_value(t, r.ingredients[0], Ingredient{.Silver_Bar, 4})
        testing.expect_value(t, r.ingredients[1], Ingredient{.Gold_Bar, 2})
        testing.expect_value(t, r.ingredients[2], Ingredient{.Emerald, 1})
    }
    testing.expect(t, found, "Void Charm needs a Dvergr Forge recipe")
    testing.expect_value(t, item_equip_slot[.Void_Charm], Equip_Slot.Charm)
}

@(test)
void_slot_replaces_then_recovers_one_stack :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    inv := &gs.player.inventory

    inventory_insert(inv, .Void_Charm, 1)
    player_equip(gs, 0)
    testing.expect(t, void_charm_active(&gs.player))

    inventory_insert(inv, .Stone_Block, 12)
    testing.expect(t, void_slot_store(gs, 0))
    testing.expect_value(t, gs.player.void_slot, Inventory_Slot{.Stone_Block, 12})
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 0)

    // A second offered stack is retained; the old stone stack is truly gone.
    inventory_insert(inv, .Wood_Log, 7)
    testing.expect(t, void_slot_store(gs, 0))
    testing.expect_value(t, gs.player.void_slot, Inventory_Slot{.Wood_Log, 7})
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 0)
    testing.expect_value(t, gs.notify.count, 1)

    // Until replaced, the displayed stack is an undo buffer and can return.
    testing.expect(t, void_slot_take(gs, 5))
    testing.expect_value(t, inv.slots[5], Inventory_Slot{.Wood_Log, 7})
    testing.expect_value(t, gs.player.void_slot, Inventory_Slot{})
}

@(test)
void_slot_refuses_unsafe_or_unpowered_moves :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    inv := &gs.player.inventory

    inventory_insert(inv, .Stone_Block, 8)
    testing.expect(t, !void_slot_store(gs, 0), "the box stays locked without its charm")
    testing.expect_value(t, inventory_count(inv, .Stone_Block), 8)

    inventory_insert(inv, .Void_Charm, 1)
    player_equip(gs, 1)
    testing.expect(t, void_slot_store(gs, 0))
    inv.slots[3] = {.Wood_Log, 1}
    testing.expect(t, !void_slot_take(gs, 3), "recovery must not overwrite a bag stack")
    testing.expect_value(t, gs.player.void_slot, Inventory_Slot{.Stone_Block, 8})
    testing.expect_value(t, inv.slots[3], Inventory_Slot{.Wood_Log, 1})
}

@(test)
charm_belt_fills_open_slots_and_rejects_duplicates :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    p := &gs.player

    inventory_insert(&p.inventory, .Aether_Charm, 2)
    player_equip(gs, 0)
    testing.expect_value(t, p.equipment[.Charm], Item.Aether_Charm)
    testing.expect_value(t, p.equipment[.Charm_2], Item.None)
    testing.expect_value(t, inventory_count(&p.inventory, .Aether_Charm), 1)

    // A second copy is refused in place, so its speed bonus cannot stack.
    player_equip(gs, 0)
    testing.expect_value(t, inventory_count(&p.inventory, .Aether_Charm), 1)
    testing.expect_value(t, player_stat(p, .Speed), player_base_stats[.Speed] + 3)
    testing.expect_value(t, gs.notify.count, 1)

    inventory_insert(&p.inventory, .Void_Charm, 1)
    void_slot := -1
    for s, i in p.inventory.slots do if s.item == .Void_Charm { void_slot = i; break }
    player_equip(gs, void_slot)
    testing.expect_value(t, p.equipment[.Charm], Item.Aether_Charm)
    testing.expect_value(t, p.equipment[.Charm_2], Item.Void_Charm)
    testing.expect_value(t, p.equipment[.Charm_3], Item.None)
    testing.expect(t, void_charm_active(p), "Void Charm works from any belt socket")

    // Every socket unequips independently; removing CHM1 leaves CHM2 active.
    player_unequip(gs, .Charm)
    testing.expect_value(t, p.equipment[.Charm], Item.None)
    testing.expect_value(t, p.equipment[.Charm_2], Item.Void_Charm)
    testing.expect(t, void_charm_active(p))
}

@(test)
sword_requires_iron_bars :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    inv := &gs.player.inventory
    inventory_insert(inv, .Plank, 1)
    inventory_insert(inv, .Iron_Ore, 2)

    // Raw ore cannot be shaped into a sword; it must pass through the smelter.
    handle_craft_request(gs, Event{payload = {int_val = 6}})
    testing.expect_value(t, inventory_count(inv, .Sword), 0)
    testing.expect_value(t, inventory_count(inv, .Iron_Ore), 2)

    inventory_insert(inv, .Iron_Bar, 2)
    handle_craft_request(gs, Event{payload = {int_val = 6}})
    testing.expect_value(t, inventory_count(inv, .Sword), 1)
    testing.expect_value(t, inventory_count(inv, .Iron_Bar), 0)
    testing.expect_value(t, inventory_count(inv, .Plank), 0)
}

@(test)
iron_gear_requires_bars_not_ore :: proc(t: ^testing.T) {
    gear := [5]Item{.Iron_Helm, .Iron_Chestplate, .Iron_Gauntlets, .Iron_Greaves, .Iron_Boots}
    bar_cost := [5]int{3, 5, 2, 4, 2}

    for it, i in gear {
        found := false
        for r in recipe_table {
            if r.result != it do continue
            found = true
            testing.expect_value(t, r.ingredients[0].item, Item.Iron_Bar)
            testing.expect_value(t, r.ingredients[0].count, bar_cost[i])
            for ing in r.ingredients {
                testing.expect(t, ing.item != .Iron_Ore,
                    "iron gear recipes must use smelted bars, never raw ore")
            }
            break
        }
        testing.expect(t, found, "every iron gear piece needs a recipe")
    }
}

@(test)
ritual_consumes_and_unlocks :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inv := &gs.player.inventory
    gs.level_index = LEVEL_SKY  // ritual is gated to the sky level
    gs.progression.rune_scroll_found[0] = true

    // Missing materials: nothing happens
    handle_ritual_request(gs)
    process_events(gs)
    testing.expect(t, !gs.progression.sky_structure_complete[0], "no materials, no structure")

    inventory_insert(inv, .Cloud_Stone, 8)
    inventory_insert(inv, .Plank, 4)
    handle_ritual_request(gs)
    testing.expect(t, gs.ritual.active, "the offering swirl begins")
    testing.expect_value(t, inventory_count(inv, .Cloud_Stone), 8)  // not consumed until the flash

    // Drive the swirl to its finishing flash
    gs.delta_time = 0.1
    for gs.ritual.active do update_ritual(gs)
    process_events(gs)

    testing.expect(t, gs.progression.sky_structure_complete[0], "structure A complete")
    testing.expect(t, gs.progression.cave_unlocked[0], "cave 2 unlocked")
    testing.expect_value(t, inventory_count(inv, .Cloud_Stone), 0)
    testing.expect_value(t, inventory_count(inv, .Plank), 0)
    testing.expect(t, gs.ui.show_book, "a completed ritual leaves the instruction tome")
}

@(test)
ritual_swirls_then_leaves_a_tome :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inv := &gs.player.inventory
    gs.level_index = LEVEL_SKY
    gs.progression.rune_scroll_found[0] = true
    inventory_insert(inv, .Cloud_Stone, 8)
    inventory_insert(inv, .Plank, 4)

    handle_ritual_request(gs)
    testing.expect(t, gs.ritual.active, "offering starts the swirl")

    // A second E during the swirl is ignored — no double-start, no re-notify
    n := gs.notify.count
    handle_ritual_request(gs)
    testing.expect(t, gs.ritual.active, "still exactly one ritual")
    testing.expect_value(t, gs.notify.count, n)

    // Halfway through: nothing consumed, no structure yet
    gs.delta_time = RITUAL_DURATION * 0.5
    update_ritual(gs)
    testing.expect_value(t, inventory_count(inv, .Cloud_Stone), 8)
    testing.expect(t, !gs.progression.sky_structure_complete[0], "not done mid-swirl")

    // The finishing flash
    gs.delta_time = RITUAL_DURATION
    update_ritual(gs)
    process_events(gs)
    testing.expect(t, !gs.ritual.active, "swirl ends at the flash")
    testing.expect(t, gs.ui.show_book, "the tome opens")
    testing.expect_value(t, gs.ui.book_tier, 0)
    testing.expect(t, gs.progression.sky_structure_complete[0], "structure raised")
    testing.expect_value(t, inventory_count(inv, .Cloud_Stone), 0)
}

@(test)
debug_altar_kit_stamps_and_completes_rituals :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Raise tier B's structure with the capstone at (60, 40): every support
    // must be present and the ritual proc must accept it as a real altar.
    debug_stamp_altar_template(gs, 1, 60, 40)
    testing.expect_value(t, get_tile(&gs.world, 60, 40), Tile_Type.Sky_Altar)
    ok, _ := structure_template_satisfied(&gs.world, &structure_templates[1], 60, 40)
    testing.expect(t, ok, "stamped template should satisfy its own foundation check")

    // Free completion runs the real Structure_Complete path, in tier order.
    debug_complete_next_ritual(gs)
    process_events(gs)
    testing.expect(t, gs.progression.sky_structure_complete[0], "tier A completed first")
    testing.expect(t, gs.progression.cave_unlocked[0], "cave 2 unlocked")

    debug_complete_next_ritual(gs)
    process_events(gs)
    testing.expect(t, gs.progression.sky_structure_complete[1], "tier B completed next")
    testing.expect(t, gs.progression.cave_unlocked[1], "cave 3 unlocked")
}

@(test)
ritual_gated_to_sky_level :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Rune Scroll + full materials, but standing on the surface (C4): the
    // altar must refuse and explain itself.
    inv := &gs.player.inventory
    gs.progression.rune_scroll_found[0] = true
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
airborne_portal_entry_lands_without_phantom_fall :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    p := &gs.player

    // Settle onto the surface, then hop so the fall peak arms up on the
    // surface level — the state a player is in jumping into a portal.
    for _ in 0 ..< 300 {
        update_player(gs)
        process_events(gs)
        if p.grounded do break
    }
    testing.expect(t, p.grounded, "player should settle onto the surface")
    hp := p.hp

    p.pos.y -= 2
    update_player(gs)
    process_events(gs)
    testing.expect(t, !p.grounded, "player should be airborne entering the portal")

    // Take the sky gate mid-air, then land on the entrance cloud.
    gs.progression.sky_altar_pos = {40, 52}
    sky := sky_gate_portal(gs)
    level_transition(gs, &sky)
    testing.expect_value(t, gs.level_index, LEVEL_SKY)
    for _ in 0 ..< 300 {
        update_player(gs)
        process_events(gs)
        if p.grounded do break
    }
    testing.expect(t, p.grounded, "player should land on the sky entrance")
    testing.expect_value(t, p.hp, hp)
}

@(test)
sky_return_lands_at_the_altar :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Gate raised at {40, 52}: stepping back down must land on the altar,
    // not the table's left-edge fallback.
    gs.progression.sky_altar_pos = {40, 52}
    sky := sky_gate_portal(gs)
    level_transition(gs, &sky)
    testing.expect_value(t, gs.level_index, LEVEL_SKY)

    level_transition(gs, &level_portals[LEVEL_SKY][0])
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    testing.expect_value(t, gs.player.pos, [2]f32{40, 52 - PLAYER_H})

    // Falling through the clouds takes the same road home.
    level_transition(gs, &sky)
    gs.player.pos = {50, 90}  // below the cloud line
    update_player(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    testing.expect_value(t, gs.player.pos.x, f32(40))
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
    gs.player.inventory.selected = 0
    gs.player.pos = {f32(ax + 3), f32(ay)}  // beside the altar, within reach, not on it
    handle_place_request(gs, Event{tile = {i32(ax), i32(ay)}})

    testing.expect_value(t, get_tile(&gs.world, ax, ay), Tile_Type.Sky_Altar)
    testing.expect(t, gs.progression.sky_altar_pos == {i32(ax), i32(ay)}, "gate opened at the altar")
}

// Logs the real save size so bumping SAVE_DATA_EXPECTED_SIZE is a copy-paste,
// never a guess.  Grep the test log for "size_of(Save_Data)".
@(test)
save_data_size_probe :: proc(t: ^testing.T) {
    log.infof("size_of(Save_Data) = %d (expected %d)", size_of(Save_Data), SAVE_DATA_EXPECTED_SIZE)
    testing.expect_value(t, size_of(Save_Data), SAVE_DATA_EXPECTED_SIZE)
}

@(test)
gem_ladder_generation :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    count_tile :: proc(w: ^World_Grid, tt: Tile_Type) -> (n: int) {
        for i in 0 ..< GRID_W * GRID_H do if w.terrain[i] == tt do n += 1
        return
    }

    // Cave 1 (surface grid): a handful of emeralds in the deep rows, no more
    emeralds := count_tile(&gs.world, .Emerald_Ore)
    testing.expect(t, emeralds > 0, "cave 1 should hide emeralds")
    testing.expect(t, emeralds < 40, "emeralds should stay sparse")

    w2 := &gs.levels.worlds[LEVEL_CAVE2]
    gen_cave_level(w2, 1)
    testing.expect(t, count_tile(w2, .Jade_Ore) > 0, "cave 2 should hide jade")
    testing.expect_value(t, count_tile(w2, .Diamond_Ore), 0)  // diamonds are cave-3 only
    testing.expect_value(t, count_tile(w2, .Hel_Gem_Ore), 0)  // hel gems are cave-3 only

    w3 := &gs.levels.worlds[LEVEL_CAVE3]
    gen_cave_level(w3, 2)
    testing.expect(t, count_tile(w3, .Diamond_Ore) > 0, "cave 3 should hide diamonds")
    testing.expect(t, count_tile(w3, .Hel_Gem_Ore) > 0, "hel gems near the boss arena")
    testing.expect_value(t, count_tile(w3, .Jade_Ore), 0)  // jade is cave-2 only

    // Hel gems stay in the arena band
    for y in 0 ..< ARENA_Y0 - 10 {
        for x in 0 ..< GRID_W {
            testing.expect(t, get_tile(w3, x, y) != .Hel_Gem_Ore, "hel gem above the arena band")
        }
    }

    ws := &gs.levels.worlds[LEVEL_SKY]
    gen_sky_level(ws)
    testing.expect(t, count_tile(ws, .Aether_Ore) > 0, "sky should hold aether pockets")

    log.infof("gem gen: %d emerald (c1), %d jade (c2), %d diamond + %d hel gem (c3), %d aether (sky)",
        emeralds, count_tile(w2, .Jade_Ore), count_tile(w3, .Diamond_Ore),
        count_tile(w3, .Hel_Gem_Ore), count_tile(ws, .Aether_Ore))

    // Every gem tile drops its gem item (table wiring)
    testing.expect_value(t, terrain_table[.Emerald_Ore].drop_item, Item.Emerald)
    testing.expect_value(t, terrain_table[.Jade_Ore].drop_item, Item.Jade)
    testing.expect_value(t, terrain_table[.Diamond_Ore].drop_item, Item.Diamond)
    testing.expect_value(t, terrain_table[.Hel_Gem_Ore].drop_item, Item.Hel_Gem)
    testing.expect_value(t, terrain_table[.Aether_Ore].drop_item, Item.Aether_Crystal)
}

@(test)
plain_clouds_chance_drop_cloud_stone :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    count_tile :: proc(w: ^World_Grid, tt: Tile_Type) -> (n: int) {
        for i in 0 ..< GRID_W * GRID_H do if w.terrain[i] == tt do n += 1
        return
    }

    gen_sky_level(&gs.world)
    gs.level_index = LEVEL_SKY

    // The guaranteed vein supply survives the puffy gen: the win path's
    // 40 Cloud Stone (+6 Rune Altar) stays covered by ore alone.
    testing.expect_value(t, count_tile(&gs.world, .Cloud_Ore), 42)

    // Strip-mine every plain cloud: the per-tile hash makes the harvest
    // deterministic, and it must clear the remaining crafting demand
    // (spawners + the runic recipe) without flooding the economy.
    total, drops: int
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if get_tile(&gs.world, x, y) != .Cloud do continue
            total += 1
            eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(x), i32(y)}})
            process_events(gs)
            eq_clear(&gs.events)
            if gs.world.items[grid_idx(x, y)] == .Cloud_Stone do drops += 1
        }
    }
    testing.expect(t, drops >= 50, "plain clouds must yield a real Cloud Stone stream")
    testing.expect(t, drops < total/2, "the chance drop must stay a chance, not a flood")
    log.infof("cloud harvest: %d stone from %d plain cloud tiles (+42 guaranteed veins)", drops, total)
}

@(test)
cave_generation_has_ore_and_rune_scrolls :: proc(t: ^testing.T) {
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
    testing.expect_value(t, get_tile(w, 12, 101), Tile_Type.Rune_Scroll_Chest_B)
    testing.expect_value(t, w.items[grid_idx(12, 101)], Item.None)
    testing.expect_value(t, get_tile(w, 93, 26), Tile_Type.Cave_Entrance)
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
pickaxe_mines_only_while_equipped :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    target := [2]i32{31, i32(SURFACE_Y)}
    set_tile(&gs.world, int(target.x), int(target.y), .Stone)

    // A bagged pick is inert, like a bagged sword or wand.
    gs.player.equipment[.Tool] = .None
    inventory_insert(&gs.player.inventory, .Pickaxe, 1)
    for _ in 0 ..< PICK_HITS + 2 do mine_swing(gs, target)
    testing.expect_value(t, get_tile(&gs.world, int(target.x), int(target.y)), Tile_Type.Stone)

    // Equipping it into the dedicated pick slot enables ordinary mining.
    player_equip(gs, 0)
    testing.expect_value(t, gs.player.equipment[.Tool], Item.Pickaxe)
    for _ in 0 ..< PICK_HITS do mine_swing(gs, target)
    testing.expect(t, get_tile(&gs.world, int(target.x), int(target.y)) != .Stone,
        "the equipped pickaxe should mine")
}

@(test)
pickaxe_slot_is_independent_from_weapons :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inventory_insert(&gs.player.inventory, .Sword, 1)
    player_equip(gs, 0)
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Sword)
    testing.expect_value(t, gs.player.equipment[.Tool], Item.Pickaxe)

    inventory_insert(&gs.player.inventory, .Mine_Wand, 1)
    player_equip(gs, 0)
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Mine_Wand)
    testing.expect_value(t, gs.player.equipment[.Tool], Item.Pickaxe)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Sword), 1)
}

@(test)
wand_priority_keeps_pickaxe_fallback :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}

    inventory_insert(&gs.player.inventory, .Mine_Wand, 1)
    player_equip(gs, 0)

    // A valid adjacent target belongs to the wand even though PICK is filled.
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Stone)
    mine_swing(gs, {31, i32(SURFACE_Y - 1)})
    testing.expect(t, gs.mining.active, "a valid wand target should take priority")
    testing.expect_value(t, gs.player.chip_hits, u8(0))

    // Point beyond wand reach: no spell fires, but the same direction still
    // lets the independently equipped pick work the adjacent tile.
    gs.mining = {}
    gs.player.chip_tile = {-1, -1}
    for _ in 0 ..< PICK_HITS do mine_swing(gs, {35, i32(SURFACE_Y - 1)})
    testing.expect(t, !gs.mining.active)
    testing.expect(t, get_tile(&gs.world, 31, SURFACE_Y - 1) != .Stone,
        "the pickaxe should remain the close-range fallback")
}

@(test)
bare_hands_fell_trees_slower :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Put the starter pickaxe away: bare hands only.
    gs.player.equipment[.Tool] = .None

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)

    // Fists can't break stone — swing well past the tree cost, it holds.
    set_tile(&gs.world, 31, SURFACE_Y, .Stone)
    for _ in 0 ..< PICK_HITS * BARE_HAND_MULT + 2 { mine_swing(gs, {31, i32(SURFACE_Y)}) }
    testing.expect_value(t, get_tile(&gs.world, 31, SURFACE_Y), Tile_Type.Stone)

    // A tree comes down — but only after 3× the hits.
    set_tile(&gs.world, 31, SURFACE_Y, .Wood)
    gs.player.chip_hits = 0
    gs.player.chip_tile = {-1, -1}
    for _ in 0 ..< PICK_HITS * BARE_HAND_MULT - 1 { mine_swing(gs, {31, i32(SURFACE_Y)}) }
    testing.expect_value(t, get_tile(&gs.world, 31, SURFACE_Y), Tile_Type.Wood)  // not yet
    mine_swing(gs, {31, i32(SURFACE_Y)})
    testing.expect(t, get_tile(&gs.world, 31, SURFACE_Y) != .Wood, "the 9th hit fells it")
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
world_seed_varies_and_reproduces :: proc(t: ^testing.T) {
    w0 := new(World_Grid); defer free(w0)
    w1 := new(World_Grid); defer free(w1)
    w2 := new(World_Grid); defer free(w2)

    world_init(w0, 0)
    world_init(w1, 12345)
    world_init(w2, 12345)

    // A different seed reshapes the world.
    diff := 0
    for i in 0 ..< GRID_W * GRID_H do if w0.terrain[i] != w1.terrain[i] do diff += 1
    testing.expect(t, diff > 100, "a different seed must change the generated world")

    // The same seed reproduces it byte-for-byte.
    same := true
    for i in 0 ..< GRID_W * GRID_H do if w1.terrain[i] != w2.terrain[i] { same = false; break }
    testing.expect(t, same, "the same seed must reproduce the same world")
}

@(test)
flowers_forage_into_the_bag :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    fx := int(gs.player.pos.x)
    fy := int(gs.player.pos.y)
    set_tile(&gs.world, fx, fy, .Flower)

    // Walking through it plucks the flower + a handful of seeds, clears tile.
    player_pickup(gs)
    inv := &gs.player.inventory
    testing.expect_value(t, inventory_count(inv, .Flower), 1)
    seeds := inventory_count(inv, .Flower_Seed)
    testing.expect(t, seeds >= FLOWER_SEED_MIN && seeds <= FLOWER_SEED_MAX, "a flower yields 2–5 seeds")
    testing.expect_value(t, get_tile(&gs.world, fx, fy), Tile_Type.Air)
    testing.expect(t, gs.forage_hint_shown, "first forage teaches brewing")
}

@(test)
flower_bed_ripens_then_harvests :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    bx := int(gs.player.pos.x)
    by := int(gs.player.pos.y)
    set_tile(&gs.world, bx, by, .Flower_Bed)
    inv := &gs.player.inventory

    // Unripe: walking through yields nothing, the bed stays put.
    player_pickup(gs)
    testing.expect_value(t, inventory_count(inv, .Flower), 0)
    testing.expect_value(t, get_tile(&gs.world, bx, by), Tile_Type.Flower_Bed)

    // It grows over time (and caps at the ripe mark).
    gs.delta_time = 1.0
    update_sim(gs); eq_clear(&gs.events)
    update_sim(gs); eq_clear(&gs.events)
    testing.expect(t, gs.world.sim_data[grid_idx(bx, by)].growth_timer > 0, "the bed grows over time")

    // Ripe: walking through harvests all five blooms (+ seeds) and clears it.
    gs.world.sim_data[grid_idx(bx, by)].growth_timer = FLOWER_BED_GROW_TIME
    player_pickup(gs)
    testing.expect_value(t, inventory_count(inv, .Flower), FLOWER_BED_BLOOMS)
    testing.expect(t, inventory_count(inv, .Flower_Seed) >= FLOWER_BED_BLOOMS * FLOWER_SEED_MIN,
        "each bloom yields seeds")
    testing.expect_value(t, get_tile(&gs.world, bx, by), Tile_Type.Air)
    testing.expect_value(t, gs.world.sim_data[grid_idx(bx, by)].growth_timer, f32(0))  // cleared
}

@(test)
flower_bed_brews_from_dirt_plank_seeds :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    inv := &gs.player.inventory
    inventory_insert(inv, .Dirt, 1)
    inventory_insert(inv, .Plank, 1)
    inventory_insert(inv, .Flower_Seed, 5)

    idx := -1
    for r, i in recipe_table do if r.result == .Flower_Bed { idx = i; break }
    testing.expect(t, idx >= 0, "flower bed recipe must exist")
    handle_craft_request(gs, Event{payload = {int_val = i32(idx)}})

    testing.expect_value(t, inventory_count(inv, .Flower_Bed), 1)
    testing.expect_value(t, inventory_count(inv, .Flower_Seed), 0)  // 5 seeds consumed
    testing.expect_value(t, inventory_count(inv, .Dirt), 0)
    testing.expect_value(t, inventory_count(inv, .Plank), 0)
}

@(test)
recipes_unlock_when_their_material_is_found :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    gs.ui.active_station = .Bench

    visible :: proc(gs: ^Game_State, result: Item) -> bool {
        vis: [len(recipe_table)]int
        n := visible_recipes(gs, &vis)
        for row in 0 ..< n do if recipe_table[vis[row]].result == result do return true
        return false
    }

    // Hand recipes are known from the start; the smelter (needs iron) is hidden.
    testing.expect(t, gs.progression.recipe_unlocked[.Crafting_Bench], "bench known from start")
    testing.expect(t, !gs.progression.recipe_unlocked[.Smelter], "smelter hidden until iron")
    testing.expect(t, !visible(gs, .Smelter), "smelter not listed before iron")

    // Finding iron ore reveals the iron-tier recipes (with a notify).
    inventory_insert(&gs.player.inventory, .Iron_Ore, 1)
    update_recipe_unlocks(gs)
    testing.expect(t, gs.progression.recipe_unlocked[.Smelter], "iron reveals the smelter")
    testing.expect(t, gs.notify.count >= 1, "a new recipe pops a note")
    testing.expect(t, visible(gs, .Smelter), "smelter now listed")

    // Sticky: spending the iron doesn't re-hide the recipe.
    inventory_remove(&gs.player.inventory, .Iron_Ore, 1)
    update_recipe_unlocks(gs)
    testing.expect(t, gs.progression.recipe_unlocked[.Smelter], "unlock is sticky")

    // A deeper-tier recipe is still gated.
    testing.expect(t, !gs.progression.recipe_unlocked[.Dvergr_Forge], "forge waits on a smelted bar")

    // The Jade Ring is gated by Iron_Bar too, never by Jade itself — its
    // recipe card (and Jade cost) is what tells the player to go find one.
    testing.expect(t, !gs.progression.recipe_unlocked[.Jade_Ring], "jade ring waits on a smelted bar")
    inventory_insert(&gs.player.inventory, .Iron_Bar, 1)
    update_recipe_unlocks(gs)
    testing.expect(t, gs.progression.recipe_unlocked[.Jade_Ring], "iron bar reveals the jade ring")
    testing.expect(t, visible(gs, .Jade_Ring), "jade ring listed without ever holding jade")
}

@(test)
health_potion_brews_from_flowers :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    inv := &gs.player.inventory
    inventory_insert(inv, .Flower, 3)

    idx := -1
    for r, i in recipe_table do if r.result == .Potion_Health { idx = i; break }
    testing.expect(t, idx >= 0, "health potion recipe must exist")
    handle_craft_request(gs, Event{payload = {int_val = i32(idx)}})

    testing.expect_value(t, inventory_count(inv, .Potion_Health), 1)
    testing.expect_value(t, inventory_count(inv, .Flower), 0)  // three flowers consumed
}

@(test)
drinking_a_health_potion_heals :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    inv := &gs.player.inventory
    inventory_insert(inv, .Potion_Health, 2)
    pslot := -1
    for s, i in inv.slots do if s.item == .Potion_Health { pslot = i; break }

    // Hurt, then drink: heals by POTION_HEAL (capped), one potion spent.
    gs.player.hp = 3
    player_consume(gs, pslot)
    testing.expect_value(t, gs.player.hp, min(3 + POTION_HEAL, gs.player.hp_max))
    testing.expect_value(t, inventory_count(inv, .Potion_Health), 1)

    // At full health the potion is refused — nothing spent.
    gs.player.hp = gs.player.hp_max
    player_consume(gs, pslot)
    testing.expect_value(t, inventory_count(inv, .Potion_Health), 1)
}

@(test)
jade_ring_recipe_and_warp_home :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, 31, SURFACE_Y - 1, .Crafting_Bench)
    inv := &gs.player.inventory
    inventory_insert(inv, .Iron_Bar, 1)
    inventory_insert(inv, .Jade, 1)

    idx := -1
    for r, i in recipe_table do if r.result == .Jade_Ring { idx = i; break }
    testing.expect(t, idx >= 0, "jade ring recipe must exist")
    handle_craft_request(gs, Event{payload = {int_val = i32(idx)}})
    testing.expect_value(t, inventory_count(inv, .Jade_Ring), 1)

    // Warping without the ring worn does nothing.
    testing.expect(t, !player_warp_home(gs), "ring must be equipped to warp")

    rslot := -1
    for s, i in inv.slots do if s.item == .Jade_Ring { rslot = i; break }
    player_equip(gs, rslot)
    testing.expect(t, player_has_charm(&gs.player, .Jade_Ring), "ring should be worn")
    testing.expect_value(t, inventory_count(inv, .Jade_Ring), 0)  // worn, not in the bag

    // On the surface it's refused — no level change.
    testing.expect(t, !player_warp_home(gs), "already home")
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)

    // From a lower level it warps straight home, and the ring stays worn —
    // usable again as many times as needed.
    level_transition(gs, &level_portals[LEVEL_SURFACE][0])
    testing.expect_value(t, gs.level_index, LEVEL_CAVE2)
    testing.expect(t, player_warp_home(gs), "ring should warp home")
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    testing.expect_value(t, gs.player.pos, SURFACE_HOME_POS)
    testing.expect(t, player_has_charm(&gs.player, .Jade_Ring), "ring is not consumed")
}

@(test)
wand_mines_at_range_for_mana :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)
    inventory_insert(&gs.player.inventory, .Mine_Wand, 1)

    // A wand sitting in the bag no longer fires — it must be equipped.
    mine_swing(gs, {32, i32(SURFACE_Y)})
    testing.expect(t, !gs.mining.active, "an unequipped wand must not fire")

    // Equip it into the weapon slot; now it is the mining tool.
    wslot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Mine_Wand { wslot = i; break }
    player_equip(gs, wslot)
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Mine_Wand)

    // Adjacent tile: the wand fires up close too (no more free-pick fallback).
    mine_swing(gs, {31, i32(SURFACE_Y)})
    testing.expect(t, gs.mining.active, "wand fires on an adjacent tile")
    testing.expect_value(t, gs.player.mana, 100 - WAND_MANA_COST)
    gs.mining = {}
    gs.player.mana = 100

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

    // Beyond the basic wand's reach (4 > 3): nothing fires at range. The pick
    // remains equipped in its own slot, but finds only cleared air nearby.
    set_tile(&gs.world, 29, SURFACE_Y - 2, .Air)
    set_tile(&gs.world, 29, SURFACE_Y - 1, .Air)
    mana_before := gs.player.mana
    mine_swing(gs, {26, i32(SURFACE_Y)})
    testing.expect(t, !gs.mining.active, "out-of-range shot must not fire")
    testing.expect(t, gs.player.mana >= mana_before, "no mana spent on a refused shot")

    // Out of mana: the wand refuses and says so
    gs.player.mana = WAND_MANA_COST - 1
    mine_swing(gs, {28, i32(SURFACE_Y)})
    testing.expect(t, !gs.mining.active, "no mana, no shot")
    testing.expect_value(t, gs.notify.count, 1)
}

@(test)
wand_does_not_strike_structures :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}  // center tile (30, 53)

    // Equip a wand — the mining tool at every range.
    inventory_insert(&gs.player.inventory, .Mine_Wand, 1)
    for s, i in gs.player.inventory.slots do if s.item == .Mine_Wand { player_equip(gs, i); break }
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Mine_Wand)

    // A smelter two tiles out is a structure: the wand must not fire at it and
    // no mana is spent — you reclaim a machine with the pick, up close.
    set_tile(&gs.world, 32, SURFACE_Y, .Smelter)
    mana_before := gs.player.mana
    mine_swing(gs, {32, i32(SURFACE_Y)})
    testing.expect(t, !gs.mining.active, "a wand must not strike a structure")
    testing.expect_value(t, gs.player.mana, mana_before)
    testing.expect_value(t, get_tile(&gs.world, 32, SURFACE_Y), Tile_Type.Smelter)

    // Sanity: it still fires at ordinary mineable terrain at the same range.
    mine_swing(gs, {28, i32(SURFACE_Y)})
    testing.expect(t, gs.mining.active, "the wand still mines plain terrain")
}

@(test)
wand_target_highlight_matches_mining_rules :: proc(t: ^testing.T) {
	gs := test_state()
	defer free(gs)

	gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
	gs.player.equipment[.Weapon] = .Mine_Wand

	set_tile(&gs.world, 33, SURFACE_Y, .Stone)
	wand, cost, blast, ok := wand_target(gs, {33, SURFACE_Y})
	testing.expect_value(t, wand, Item.Mine_Wand)
	testing.expect_value(t, cost, WAND_MANA_COST)
	testing.expect(t, !blast)
	testing.expect(t, ok, "a mineable tile in wand range should highlight")

	set_tile(&gs.world, 33, SURFACE_Y, .Smelter)
	_, _, _, structure_ok := wand_target(gs, {33, SURFACE_Y})
	testing.expect(t, !structure_ok, "a protected structure must not highlight")

	set_tile(&gs.world, 34, SURFACE_Y, .Stone)
	_, _, _, distant_ok := wand_target(gs, {34, SURFACE_Y})
	testing.expect(t, !distant_ok, "a tile beyond wand range must not highlight")
}

@(test)
silver_wand_uses_less_mana :: proc(t: ^testing.T) {
	gs := test_state()
	defer free(gs)

	gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
	set_tile(&gs.world, 34, SURFACE_Y, .Stone)

	gs.player.equipment[.Weapon] = .Mine_Wand_Silver
	_, silver_cost, _, silver_ok := wand_target(gs, {34, SURFACE_Y})
	testing.expect(t, silver_ok)
	testing.expect_value(t, silver_cost, f32(3))
	testing.expect(t, silver_cost < WAND_MANA_COST,
		"the silver upgrade should sustain mining longer than the basic wand")
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

    equip_wand :: proc(gs: ^Game_State, wand: Item) {
        inventory_insert(&gs.player.inventory, wand, 1)
        for s, i in gs.player.inventory.slots do if s.item == wand {
            player_equip(gs, i)
            return
        }
    }

    equip_wand(gs, .Mine_Wand_Silver)
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Mine_Wand_Silver)
    testing.expect(t, fires_at(gs, 4), "silver wand reaches 4")
    testing.expect(t, !fires_at(gs, 5), "silver wand stops at 4")

    equip_wand(gs, .Mine_Wand_Gold)   // swapping wands: the gold now reaches farther
    testing.expect_value(t, gs.player.equipment[.Weapon], Item.Mine_Wand_Gold)
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
craft_selection_resolves_to_a_visible_recipe :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    gs.ui.active_station = .Bench

    // Nothing chosen yet → the first visible recipe is offered by default.
    gs.ui.craft_selected = -1
    sel := craft_selected_recipe(gs)
    testing.expect(t, sel >= 0, "a visible recipe is offered by default")

    // Choosing a specific visible recipe sticks.
    gs.ui.craft_selected = sel
    testing.expect_value(t, craft_selected_recipe(gs), sel)

    // An out-of-range / hidden selection falls back to something visible.
    gs.ui.craft_selected = 9999
    testing.expect(t, craft_selected_recipe(gs) >= 0, "invalid selection falls back to first visible")
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

    // First blow fells the builder — it rises as a draugr, so kill it twice to
    // reach true death and spill the trade-goods.
    for _ in 0 ..< 2 {
        eq_push(&gs.events, Event{
            type    = .Damage_Dealt,
            source  = PLAYER_ID,
            target  = enemy_entity_id(bi),
            payload = {int_val = 99},
        })
        process_events(gs)
        eq_clear(&gs.events)
    }

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
body_steps_up_one_block :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Clear a lane on the surface, then a one-tile-high raised ledge the body
    // must climb onto and keep walking along (long enough it can't walk off).
    for x in 30 ..= 47 do for y in SURFACE_Y - 4 ..< SURFACE_Y do set_tile(&gs.world, x, y, .Air)
    for x in 33 ..= 47 do set_tile(&gs.world, x, SURFACE_Y - 1, .Stone)

    pos      := [2]f32{30, f32(SURFACE_Y) - PLAYER_H}
    vel      := [2]f32{}
    grounded := true
    for _ in 0 ..< 90 {
        vel.x = MOVE_SPEED
        move_body(&gs.world, &pos, &vel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &grounded, step_up = true)
    }
    testing.expect(t, pos.x + PLAYER_W > 34.0, "body should step onto and past the 1-high block")
    testing.expect(t, grounded, "body stays grounded on top of the step")
    testing.expect(t, abs(pos.y + PLAYER_H - f32(SURFACE_Y - 1)) < 0.05, "feet rest on the step top")
}

@(test)
player_step_up_eases_the_sprite :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    for x in 30 ..= 40 do for y in SURFACE_Y - 4 ..< SURFACE_Y do set_tile(&gs.world, x, y, .Air)
    for x in 33 ..= 40 do set_tile(&gs.world, x, SURFACE_Y - 1, .Stone)

    gs.player.pos      = {30, f32(SURFACE_Y) - PLAYER_H}
    gs.player.grounded = true
    gs.input.move_right = true
    gs.delta_time       = 1.0/60.0

    for _ in 0 ..< 30 {
        update_player(gs)
        if gs.player_step_visual_y > 0 do break
    }

    testing.expect(t, gs.player_step_visual_y > 0.9,
        "the sprite should remain near its pre-step height on the collision frame")
    first_offset := gs.player_step_visual_y

    gs.input.move_right = false
    update_player(gs)
    testing.expect(t, gs.player_step_visual_y > 0 && gs.player_step_visual_y < first_offset,
        "the visual step offset should ease upward instead of popping")

    for _ in 0 ..< 30 do update_player(gs)
    testing.expect_value(t, gs.player_step_visual_y, f32(0))
}

@(test)
body_does_not_step_two_blocks :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A 2-high wall is too tall to auto-step: the body stops against it even
    // with step_up on.
    for x in 30 ..= 36 do for y in SURFACE_Y - 4 ..< SURFACE_Y do set_tile(&gs.world, x, y, .Air)
    set_tile(&gs.world, 33, SURFACE_Y - 1, .Stone)
    set_tile(&gs.world, 33, SURFACE_Y - 2, .Stone)

    pos      := [2]f32{30, f32(SURFACE_Y) - PLAYER_H}
    vel      := [2]f32{}
    grounded := true
    for _ in 0 ..< 90 {
        vel.x = MOVE_SPEED
        move_body(&gs.world, &pos, &vel, {PLAYER_W, PLAYER_H}, 1.0/60.0,
            GRAVITY, MAX_FALL_SPEED, &grounded, step_up = true)
    }
    testing.expect(t, pos.x + PLAYER_W <= 33.0, "a 2-high wall stops the body")
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

    // No rune scroll: the altar explains itself instead of doing nothing
    handle_ritual_request(gs)
    testing.expect_value(t, gs.notify.count, 1)
    testing.expect(t, strings.contains(notify_text(gs, 0), "rune scroll"), "should point at the missing rune scroll")

    // Rune Scroll but no materials: names the first missing ingredient + counts
    gs.progression.rune_scroll_found[0] = true
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

    // Fresh run: raise the sky gate first (Rune Scroll A doesn't exist yet)
    s := current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Sky Altar"), "fresh run points at raising the sky altar")

    // Gate up: hunt the deep rune scroll
    gs.progression.sky_altar_pos = {90, 90}
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Rune Scroll A"), "next step is finding Rune Scroll A")

    // Rune Scroll found: show the tier-0 ritual cost
    gs.progression.rune_scroll_found[0] = true
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Cloud Stone"), "ritual cost names the sky material")

    // Structure A raised: hunt Rune Scroll B
    gs.progression.sky_structure_complete[0] = true
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "Rune Scroll B"), "tier 1 points at Rune Scroll B")

    // All rituals done: face the boss
    gs.progression.rune_scroll_found        = {true, true, true}
    gs.progression.sky_structure_complete = {true, true, true}
    s = current_objective(gs, buf[:127])
    testing.expect(t, strings.contains(s, "GARM"), "endgame points at the boss")
}

@(test)
deep_rune_scroll_waits_for_the_altar :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := grid_idx(141, 94)
    testing.expect(t, !is_rune_scroll_chest(gs.world.terrain[idx]), "Rune Scroll A chest must not exist at world gen")

    spawn_deep_rune_scroll(gs)
    testing.expect_value(t, gs.world.terrain[idx], Tile_Type.Rune_Scroll_Chest_A)
    testing.expect_value(t, gs.world.items[idx], Item.None)

    // Idempotent: a second raise keeps the same single chest.
    spawn_deep_rune_scroll(gs)
    testing.expect_value(t, gs.world.terrain[idx], Tile_Type.Rune_Scroll_Chest_A)

    // Already found: never respawns
    set_tile(&gs.world, 141, 94, .Void)
    gs.progression.rune_scroll_found[0] = true
    spawn_deep_rune_scroll(gs)
    testing.expect(t, !is_rune_scroll_chest(gs.world.terrain[idx]), "found rune scroll chest must not respawn")
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

    // With movement working, all three level-0 builders finish their dens well
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
    builder_exec_action(e, idx, &e.nav, gs)
    testing.expect_value(t, get_tile(&gs.world, int(gap.x), int(gap.y)+1), Tile_Type.Void)
    testing.expect_value(t, e.nav.path.len, 0)

    // One pocket block: the bridge is placed and the pocket is spent
    e.nav.path = {tiles = {0 = gap}, len = 1, cursor = 0}
    e.builder.pocket = 1
    builder_exec_action(e, idx, &e.nav, gs)
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
    player_equip(gs, 0)
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

    // Two more swings fell the builder (6 hp, sword bites 2) — but a slain
    // builder rises as a draugr, not a corpse: same slot, new purpose.
    for _ in 0 ..< 2 {
        gs.player.attack_timer = 0
        update_player(gs)
        process_events(gs)
    }
    testing.expect(t, gs.enemies.active[idx], "a felled builder rises, not dies")
    testing.expect_value(t, e.kind, Enemy_Kind.Undead)
    testing.expect_value(t, e.hp, DRAUGR_HP)
    testing.expect_value(t, e.builder.goal, Builder_Goal.Hunt)
    testing.expect_value(t, gs.stats.total_kills, 0)   // the rise defers the kill

    // Put the draugr down for good (DRAUGR_HP = 4, sword bites 2 → two hits):
    // now the slot frees and the kill counts.
    for _ in 0 ..< 2 {
        gs.player.attack_timer = 0
        update_player(gs)
        process_events(gs)
    }
    testing.expect(t, !gs.enemies.active[idx], "a re-killed draugr stays down")
    testing.expect_value(t, gs.stats.total_kills, 1)
}

@(test)
draugr_rises_and_hunts :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    idx := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] { idx = i; break }
    }
    testing.expect(t, idx >= 0, "level 0 should have a builder")
    e := &gs.enemies.data[idx]

    // Fell the builder outright — it rises as a draugr in the same slot,
    // locked to the hunt, with no kill yet counted.
    e.hp = 0
    eq_push(&gs.events, Event{type = .Entity_Died, source = enemy_entity_id(idx)})
    process_events(gs)
    testing.expect(t, gs.enemies.active[idx], "a felled builder rises")
    testing.expect_value(t, e.kind, Enemy_Kind.Undead)
    testing.expect_value(t, e.builder.goal, Builder_Goal.Hunt)
    testing.expect_value(t, gs.stats.total_kills, 0)

    // Park the draugr on the player's tile and let the enemy update run: the
    // relentless thing claws the player.
    gs.delta_time = 1.0 / 60.0
    gs.player.pos = {30, f32(SURFACE_Y) - PLAYER_H}
    prev := builder_tile(e)
    e.pos = {30.5, f32(SURFACE_Y) - BUILDER_H}
    entity_map_move(&gs.world, enemy_entity_id(idx), prev, builder_tile(e))
    e.builder.attack_timer = 0

    // One claw costs a quarter of the player's max health — four land and you're dead.
    hp_before := gs.player.hp
    update_enemies(gs)
    process_events(gs)
    testing.expect_value(t, gs.player.hp, hp_before - (gs.player.hp_max + 3) / 4)
}

@(test)
draugr_respawns_at_its_den :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    spawn_builder(gs, 40)
    bi := -1
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] && gs.enemies.data[i].kind == .Builder do bi = i
    }
    testing.expect(t, bi >= 0, "builder should have spawned")
    e := &gs.enemies.data[bi]

    // Give it a home den at a standable cave floor away from its body, then
    // fell it — the draugr rises at the den, not where it died.
    hx, hy, ok := find_cave_floor(&gs.world, 90, 3)
    testing.expect(t, ok, "a cave floor for the den")
    e.builder.anchor    = {i32(hx), i32(hy)}
    e.builder.den_built = true

    eq_push(&gs.events, Event{type = .Entity_Died, source = enemy_entity_id(bi)})
    process_events(gs)

    testing.expect_value(t, e.kind, Enemy_Kind.Undead)
    testing.expect_value(t, builder_tile(e), [2]i32{i32(hx), i32(hy)})
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
    player_equip(gs, 0)
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
    eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = 0}})
    process_events(gs)
    testing.expect_value(t, p.equipment[.Weapon], Item.Sword)
    testing.expect_value(t, inventory_count(&p.inventory, .Sword), 0)

    // Swapping in a silver sword hands the old sword back to the bag.
    inventory_insert(&p.inventory, .Silver_Sword, 1)
    player_equip(gs, 0)
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
    player_equip(gs, 0)
    testing.expect_value(t, gs.player.equipment[.Chest], Item.Iron_Chestplate)
    testing.expect_value(t, player_stat(&gs.player, .Defense), i32(1))

    // An enemy bite for 2 lands for 1 through defense 1.
    hp := gs.player.hp
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = enemy_entity_id(0),
        target = PLAYER_ID, payload = {int_val = 2}})
    process_events(gs)
    testing.expect_value(t, gs.player.hp, hp - 1)

    // Armor never blunts below 1: a bite for 1 through defense 1 still chips.
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = enemy_entity_id(0),
        target = PLAYER_ID, payload = {int_val = 1}})
    process_events(gs)
    testing.expect_value(t, gs.player.hp, hp - 2)

    // The world (lava, falls — source INVALID_ENTITY) strikes past armor.
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = INVALID_ENTITY,
        target = PLAYER_ID, payload = {int_val = 2}})
    process_events(gs)
    testing.expect_value(t, gs.player.hp, hp - 4)
}

@(test)
player_damage_pops_a_floating_number :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A blow that lands spawns one damage number carrying the dealt amount.
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = enemy_entity_id(0),
        target = PLAYER_ID, payload = {int_val = 3}})
    process_events(gs)
    testing.expect_value(t, gs.floating_text.count, 1)
    active := -1
    for &ft, i in gs.floating_text.data do if ft.active { active = i; break }
    testing.expect(t, active >= 0, "a floating number should be active after a hit")
    testing.expect_value(t, gs.floating_text.data[active].value, 3)

    // It rises and fades: past its lifetime the slot frees.
    gs.delta_time = FLOAT_TEXT_LIFETIME + 0.01
    update_floating_text(gs)
    testing.expect_value(t, gs.floating_text.count, 0)
    testing.expect(t, !gs.floating_text.data[active].active, "expired number must free its slot")
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
    // (x=76 sits in the spawn/rune-chest band the surface pond always avoids)
    spawn_projectile(gs, {76, f32(SURFACE_Y) - 3}, {0, 20}, PLAYER_ID, 1)
    testing.expect_value(t, gs.projectiles.count, 1)
    for _ in 0 ..< 30 { update_projectiles(gs); eq_clear(&gs.events) }
    testing.expect_value(t, gs.projectiles.count, 0)
    testing.expect_value(t, get_tile(&gs.world, 76, SURFACE_Y), Tile_Type.Grass)

    // Player hit: enemy-owned fireball flying at the player
    // (clear the corridor first — surface gen may have tree trunks here)
    gs.player.pos = {76, f32(SURFACE_Y) - PLAYER_H}
    for x in 76 ..= 82 { set_tile(&gs.world, x, SURFACE_Y - 1, .Air) }
    spawn_projectile(gs, {80, f32(SURFACE_Y) - 1}, {-10, 0}, enemy_entity_id(0), 2)
    for _ in 0 ..< 60 { update_projectiles(gs); process_events(gs); eq_clear(&gs.events) }
    testing.expect_value(t, gs.player.hp, 8)
    testing.expect_value(t, gs.projectiles.count, 0)

    // Owner immunity: the player's own shot leaves the player unhurt
    spawn_projectile(gs, {f32(76) + PLAYER_W*0.5, f32(SURFACE_Y) - 1}, {10, 0}, PLAYER_ID, 2)
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
    gs.progression.rune_scroll_found[2] = true
    inventory_insert(&gs.player.inventory, .Cloud_Stone, 20)
    inventory_insert(&gs.player.inventory, .Gold_Bar, 10)
    gs.level_index = LEVEL_SKY  // ritual gating
    handle_ritual_request(gs)
    gs.level_index = LEVEL_CAVE3
    gs.delta_time = 0.1
    for gs.ritual.active do update_ritual(gs)  // swirl through to the finishing flash
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
    // lands 2 damage every 4 s, so the whole fight runs
    // ceil(GARM_HP / SWORD_DAMAGE) * 4 s ≈ 152 s.
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

    MAX_FRAMES :: 4 * 60 * 60   // 4-minute cap; hand-math says death at ~152 s

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
    // Hand-math floor: one sword hit per 240 frames, so death can come no
    // earlier than the hit that empties GARM_HP.
    testing.expectf(t, frame_done >= 240 * (GARM_HP / SWORD_DAMAGE),
        "fight ended impossibly early (frame %d)", frame_done)
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

@(test)
own_den_is_never_a_cage :: proc(t: ^testing.T) {
    // den_protected guards a built den's placed blocks from every other
    // builder — and from its owner too while the owner is outside (commutes
    // use the door).  But an owner standing INSIDE may always chew out:
    // a den it can't leave is a coffin (stuck-inside bounce loop, playtest
    // 2026-07-16).
    gs := test_state()
    defer free(gs)
    gs.enemies = {}
    spawn_builder(gs, 30)   // slot 0 — the owner
    spawn_builder(gs, 60)   // slot 1 — a neighbor
    e := &gs.enemies.data[0]
    e.builder.anchor    = {30, 88}
    e.builder.den_built = true
    e.builder.build     = .Shelter
    set_tile(&gs.world, 30, 85, .Wood)   // the den roof slab ({0,-3})

    e.pos = {30.1, 87}   // standing inside the den interior
    testing.expect(t, den_protected(gs, 30, 85), "den roof is protected from the world")
    testing.expect(t, den_protected(gs, 30, 85, 1), "and from other builders")
    testing.expect(t, !den_protected(gs, 30, 85, 0), "but never from an owner boxed inside")

    e.pos = {60, 87}     // owner off at work: the den is sacred again
    testing.expect(t, den_protected(gs, 30, 85, 0), "an owner outside uses the door like everyone")
}

@(test)
builder_pillar_escape_climbs_out :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Bury a builder in a stone pocket with an open cavern high above, and
    // trip the escape: it must mine the ceiling, hop, place blocks underfoot,
    // and surface in the cavern at least ESCAPE_MIN_RISE above the start.
    for &tile in gs.world.terrain do tile = .Stone
    for y in 87 ..= 89 do set_tile(&gs.world, 30, y, .Air)   // the pocket
    for y in 78 ..= 82 {                                     // the cavern
        for x in 26 ..= 34 do set_tile(&gs.world, x, y, .Air)
    }

    gs.enemies = {}
    gs.player.pos = {150, 20}   // far away: no hunt interference
    spawn_builder(gs, 30)
    testing.expect_value(t, gs.enemies.count, 1)
    e := &gs.enemies.data[0]
    start_y := builder_tile(e).y
    e.builder.escaping    = true
    e.builder.escape_from = start_y

    for _ in 0 ..< 60 * 60 {   // one simulated minute ≫ the escape cap
        update_enemies(gs)
        eq_clear(&gs.events)
        if !e.builder.escaping do break
    }
    rise := start_y - builder_tile(e).y
    log.infof("pillar escape: rose %d tiles", rise)
    testing.expect(t, !e.builder.escaping, "the escape must hand back to normal pathing")
    testing.expect(t, rise >= ESCAPE_MIN_RISE, "the builder must gain real height before replanning")
}

@(test)
builder_surface_soak_no_pingpong :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // The real generated surface world with its three cave-1 builders. Watch
    // for the livelock signature from the playtest logs: one tile alternately
    // carved and placed in RAPID succession (~8 s apart, 54 cycles at the map
    // edge).  Slow flips are commute churn (mine through a door tile on the
    // way out, rebuild it coming home) — wasteful but making progress.
    touched:   [GRID_W * GRID_H]u8    // 1 = last event mined, 2 = last placed
    last_flip: [GRID_W * GRID_H]int   // frame of the last reversal
    rapid_run: [GRID_W * GRID_H]u16   // consecutive reversals < RAPID frames apart
    RAPID :: 20 * 60                  // reversals under 20 s apart = looping

    worst := u16(0)
    worst_idx := 0
    SOAK_MINUTES :: 15
    for frame in 0 ..< SOAK_MINUTES * 3600 {
        update_enemies(gs)
        for k in 0 ..< gs.events.size {
            ev := gs.events.events[(gs.events.head + k) % MAX_EVENTS]
            #partial switch ev.type {
            case .Builder_Mined, .Builder_Placed:
                idx  := grid_idx(int(ev.tile.x), int(ev.tile.y))
                mark := u8(1) if ev.type == .Builder_Mined else u8(2)
                if touched[idx] != 0 && touched[idx] != mark {
                    rapid_run[idx] = rapid_run[idx] + 1 if frame - last_flip[idx] < RAPID else 0
                    last_flip[idx] = frame
                    if rapid_run[idx] > worst { worst = rapid_run[idx]; worst_idx = idx }
                }
                touched[idx] = mark
            }
        }
        eq_clear(&gs.events)
    }

    // The trip clock bounds a doomed objective to ~60 s of churn and the
    // avoid list stops retries, so one cursed spot can rack up ~20 rapid
    // reversals before it is abandoned — but never the unbounded 146+ the
    // livelock produced.
    log.infof("builder soak: worst rapid reversal run = %d at (%d,%d)",
        worst, worst_idx % GRID_W, worst_idx / GRID_W)
    testing.expect(t, worst < 32, "rapid carve/place cycling beyond one trip budget means a builder is looping again")
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

    // The deposit loop must have produced raidable loot (rune scrolls are tiles,
    // so every world item here was deposited by a builder).
    loot := 0
    for i in 0 ..< GRID_W * GRID_H {
        if gs.world.items[i] != .None {
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

    // Level 0 spawns three builders; each must be registered at its center tile.
    testing.expect_value(t, gs.enemies.count, 3)
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

    // A builder rises as a draugr on the first death; the second death is the
    // real one that frees the slot and counts the kill.
    for _ in 0 ..< 2 {
        eq_push(&gs.events, Event{type = .Entity_Died, source = enemy_entity_id(idx)})
        process_events(gs)
    }

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

    // Ritual rejected (rune scroll + materials present, on the sky level)
    gs.level_index = LEVEL_SKY
    gs.progression.rune_scroll_found[0] = true
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
smelter_casts_bars_from_ore :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A smelter on the surface with 4 iron ore laid beside it, stoked with wood.
    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    in_idx := grid_idx(sx - 1, sy)
    gs.world.items[in_idx]       = .Iron_Ore
    gs.world.item_counts[in_idx] = 4
    gs.world.sim_data[grid_idx(sx, sy)].fuel_count = u8(FUEL_PER_BAR * 2)  // enough for 2 bars

    // Two smelt cycles: the ore is auto-pulled into the buffer, 4 ore → 2 bars.
    frames := int((SMELT_TIME * 2) / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }

    testing.expect_value(t, gs.world.items[in_idx], Item.None)    // ore fully pulled in
    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    testing.expect_value(t, sd.store_item, Item.Iron_Bar)
    testing.expect_value(t, int(sd.store_count), 2)
    testing.expect_value(t, int(sd.in_count), 0)  // buffer emptied by the two casts
    testing.expect_value(t, int(sd.fuel_count), 0)  // both bars burned their wood

    // Nothing lands on the ground — the bars wait in the tray.
    ground := 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        idx := grid_idx(sx + dx, sy + dy)
        if gs.world.items[idx] == .Iron_Bar do ground += int(gs.world.item_counts[idx])
    }
    testing.expect_value(t, ground, 0)

    // The fire dies with the buffer empty: progress stays zero.
    update_sim(gs)
    testing.expect_value(t, sd.growth_timer, f32(0))
}

@(test)
smelter_stalls_without_ore :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A bare furnace with nothing loaded and no pile beside it: no progress.
    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)

    frames := int((SMELT_TIME * 2) / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }

    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    testing.expect_value(t, sd.growth_timer, f32(0))
    testing.expect_value(t, int(sd.store_count), 0)
    testing.expect_value(t, int(sd.in_count), 0)
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

    // Mining the furnace spills a loaded tray, the loaded ore AND the fuel — never lost.
    sd.store_item  = .Gold_Bar
    sd.store_count = 2
    sd.in_item     = .Iron_Ore
    sd.in_count    = 3
    sd.fuel_count  = 4
    handle_tile_mined(gs, Event{tile = {i32(sx), i32(sy)}})
    testing.expect_value(t, int(sd.store_count), 0)  // tray died with the tile
    testing.expect_value(t, int(sd.in_count), 0)     // and so did the input buffer
    testing.expect_value(t, int(sd.fuel_count), 0)   // and the fuel
    bars, ore, wood := 0, 0, 0
    for dy in -2 ..= 2 do for dx in -2 ..= 2 {
        idx := grid_idx(sx + dx, sy + dy)
        if gs.world.items[idx] == .Gold_Bar do bars += int(gs.world.item_counts[idx])
        if gs.world.items[idx] == .Iron_Ore do ore  += int(gs.world.item_counts[idx])
        if gs.world.items[idx] == .Wood_Log do wood += int(gs.world.item_counts[idx])
    }
    testing.expect_value(t, bars, 2)
    testing.expect_value(t, ore, 3)
    testing.expect_value(t, wood, 4)
}

@(test)
smelter_stalls_without_fuel :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Ore loaded but no wood: the fire stays cold, no bar is cast.
    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    sd.in_item  = .Iron_Ore
    sd.in_count = 4

    frames := int((SMELT_TIME * 2) / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }
    testing.expect_value(t, sd.growth_timer, f32(0))
    testing.expect_value(t, int(sd.store_count), 0)  // nothing cast
    testing.expect_value(t, int(sd.in_count), 4)     // ore untouched

    // Stoke it and it casts, burning FUEL_PER_BAR per bar.
    sd.fuel_count = u8(FUEL_PER_BAR)
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }
    testing.expect_value(t, int(sd.store_count), 1)  // exactly one bar — fuel ran out
    testing.expect_value(t, int(sd.in_count), 2)     // one bar's ore eaten
    testing.expect_value(t, int(sd.fuel_count), 0)
}

@(test)
smelter_input_pulls_back_out :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    gs.player.pos = {f32(sx - 2), f32(sy - 1)}  // within BENCH_RANGE
    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    sd.in_item  = .Iron_Ore
    sd.in_count = 5

    testing.expect(t, smelter_withdraw(gs, {i32(sx), i32(sy)}), "withdraw rejected")
    testing.expect_value(t, int(sd.in_count), 0)
    testing.expect_value(t, sd.in_item, Item.None)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 5)

    // An empty input buffer has nothing to pull.
    testing.expect(t, !smelter_withdraw(gs, {i32(sx), i32(sy)}), "empty withdraw should no-op")
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
smelter_feed_loads_the_input_buffer :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    gs.player.pos = {f32(sx - 2), f32(sy - 1)}  // within BENCH_RANGE
    sd := &gs.world.sim_data[grid_idx(sx, sy)]

    inventory_insert(&gs.player.inventory, .Iron_Ore, 5)
    slot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }

    testing.expect(t, smelter_feed(gs, {i32(sx), i32(sy)}, slot), "feed rejected")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)
    testing.expect_value(t, sd.in_item, Item.Iron_Ore)
    testing.expect_value(t, int(sd.in_count), 5)

    // A second feed of the same ore stacks into the buffer.
    inventory_insert(&gs.player.inventory, .Iron_Ore, 3)
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }
    testing.expect(t, smelter_feed(gs, {i32(sx), i32(sy)}, slot), "second feed rejected")
    testing.expect_value(t, int(sd.in_count), 8)

    // A different ore is refused while the buffer holds iron.
    inventory_insert(&gs.player.inventory, .Silver_Ore, 2)
    for s, i in gs.player.inventory.slots do if s.item == .Silver_Ore { slot = i; break }
    testing.expect(t, !smelter_feed(gs, {i32(sx), i32(sy)}, slot), "mismatched ore must be refused")
    testing.expect_value(t, int(sd.in_count), 8)

    // Wood is fuel: it loads the FUEL buffer, not the ore input.
    inventory_insert(&gs.player.inventory, .Wood_Log, 2)
    for s, i in gs.player.inventory.slots do if s.item == .Wood_Log { slot = i; break }
    testing.expect(t, smelter_feed(gs, {i32(sx), i32(sy)}, slot), "wood should stoke the fire")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Wood_Log), 0)
    testing.expect_value(t, int(sd.fuel_count), 2)  // wood went to fuel
    testing.expect_value(t, int(sd.in_count), 8)    // ore buffer untouched
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
    testing.expect_value(t, int(gs.world.sim_data[grid_idx(sx, sy)].in_count), 0)
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
    testing.expect_value(t, int(gs.world.sim_data[grid_idx(sx, sy)].in_count), 0)
}

// ─── Parallel dimensions (dimensions.odin) ────────────────────────────────────

// Stand the player next to a placed spawner on the surface, away from any
// static portal, and interact.
@(private = "file")
dimension_test_enter :: proc(gs: ^Game_State) -> (sx, sy: int) {
    sx, sy = 20, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Dimension_Spawner)
    gs.player.pos = {f32(sx - 2), f32(SURFACE_Y) - PLAYER_H}
    player_interact(gs)
    return
}

@(test)
dimension_spawner_opens_a_metal_world :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    dimension_test_enter(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect_value(t, gs.player.pos, DIM_SPAWN_POS)

    // The return gate stands in the spawn chamber.
    gate := DIM_GATE_TILES
    testing.expect_value(t, get_tile(&gs.world, int(gate[0].x), int(gate[0].y)), Tile_Type.Dimension_Gate)
    testing.expect_value(t, get_tile(&gs.world, int(gate[1].x), int(gate[1].y)), Tile_Type.Dimension_Gate)

    // A Metal dimension is rich in ore — the point of crafting one.
    iron := 0
    for tile in gs.world.terrain do if tile == .Iron_Ore do iron += 1
    testing.expect(t, iron > 500, "metal dimension must be iron-rich")
}

@(test)
dimension_gate_returns_the_player_home :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    home_pos := [2]f32{18, f32(SURFACE_Y) - PLAYER_H}
    sx, _ := dimension_test_enter(gs)
    _ = sx

    // Stand in the gate and interact: back on the surface where we left.
    gate := DIM_GATE_TILES
    gs.player.pos = {f32(gate[0].x), f32(gate[0].y) + 1 - PLAYER_H}
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    testing.expect_value(t, gs.player.pos, home_pos)
}

@(test)
dimension_is_ephemeral_and_seed_stable :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    dimension_test_enter(gs)

    // Find an ore vein and mine it away (direct write — the sim is not under test).
    vx, vy := -1, -1
    scan: for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if get_tile(&gs.world, x, y) == .Iron_Ore { vx, vy = x, y; break scan }
        }
    }
    testing.expect(t, vx >= 0, "no iron vein found")
    set_tile(&gs.world, vx, vy, .Void)

    // Leave and re-enter through the same spawner: the world regenerates from
    // the same seed, so the mined vein is whole again.
    gate := DIM_GATE_TILES
    gs.player.pos = {f32(gate[0].x), f32(gate[0].y) + 1 - PLAYER_H}
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect_value(t, get_tile(&gs.world, vx, vy), Tile_Type.Iron_Ore)
}

@(test)
gold_spawner_opens_a_gold_rich_world :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A gold spawner: the world beyond is rich in what the recipe cost.
    sx, sy := 20, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Dimension_Spawner_Gold)
    gs.player.pos = {f32(sx - 2), f32(SURFACE_Y) - PLAYER_H}
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect_value(t, gs.dimension.kind, Dimension_Kind.Gold)

    gold, iron := 0, 0
    for tile in gs.world.terrain {
        #partial switch tile {
        case .Gold_Ore: gold += 1
        case .Iron_Ore: iron += 1
        }
    }
    testing.expect(t, gold > 400, "gold dimension must be gold-rich")
    testing.expect(t, gold > iron, "gold must dominate iron in a gold dimension")
}

@(test)
runic_spawner_opens_the_runic_tier :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // The runic world holds the only non-debug Runic_Sky_Ore in the game.
    sx, sy := 20, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Dimension_Spawner_Runic)
    gs.player.pos = {f32(sx - 2), f32(SURFACE_Y) - PLAYER_H}
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect_value(t, gs.dimension.kind, Dimension_Kind.Runic)

    runic := 0
    for tile in gs.world.terrain do if tile == .Runic_Sky_Ore do runic += 1
    // A full runic gear set costs 33 ore; one world must fund it many times.
    testing.expect(t, runic > 100, "runic dimension must be rich in Runic Sky Ore")

    // The spawner itself is the endgame sink: 500 Gold Bars + 20 Cloud
    // Stone at the Rune Altar, and not a bar less.
    found := false
    for r in recipe_table {
        if r.result != .Dimension_Spawner_Runic do continue
        found = true
        testing.expect_value(t, r.station, Station.Rune_Altar)
        testing.expect_value(t, r.ingredients[0], Ingredient{.Gold_Bar, 500})
        testing.expect_value(t, r.ingredients[1], Ingredient{.Cloud_Stone, 20})
    }
    testing.expect(t, found, "the runic spawner needs a recipe")
}

@(test)
smashed_machines_drop_their_item :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    has_drop_near :: proc(gs: ^Game_State, x, y: int, it: Item) -> bool {
        for dy in -2 ..= 2 do for dx in -2 ..= 2 {
            idx := grid_idx(x + dx, y + dy)
            if gs.world.items[idx] == it && gs.world.item_counts[idx] > 0 do return true
        }
        return false
    }

    // A builder/Garm demolishing a station knocks it loose — the machine
    // item lands on the ground instead of vanishing.
    x, y := 40, SURFACE_Y - 1
    set_tile(&gs.world, x, y, .Rune_Altar)
    smash_tile(gs, x, y)
    testing.expect_value(t, get_tile(&gs.world, x, y), Tile_Type.Void)
    testing.expect(t, has_drop_near(gs, x, y, .Rune_Altar), "a smashed station must drop its item")

    // Plain terrain smashes stay silent — demolition mints no free blocks.
    x2 := 60
    set_tile(&gs.world, x2, y, .Stone)
    smash_tile(gs, x2, y)
    testing.expect(t, !has_drop_near(gs, x2, y, .Stone_Block), "smashed rock must not drop blocks")
}

@(test)
mining_any_same_kind_spawner_releases_the_anchor :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A miner anchors a Gold world whose original spawner tile is lost.
    gs.dimension.miner.active = true
    gs.dimension.kind = .Gold
    gs.dimension.seed = 12345

    // Mining a DIFFERENT spawner of the wrong kind changes nothing...
    x, y := 30, SURFACE_Y - 1
    set_tile(&gs.world, x, y, .Dimension_Spawner)
    eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(x), i32(y)}})
    process_events(gs)
    testing.expect(t, gs.dimension.miner.active, "a foreign-kind spawner must not touch the anchor")

    // ...but reclaiming ANY spawner of the anchored kind frees it.
    set_tile(&gs.world, x, y, .Dimension_Spawner_Gold)
    eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(x), i32(y)}})
    process_events(gs)
    testing.expect(t, !gs.dimension.miner.active, "a same-kind spawner reclaim must release the anchor")
}

// ─── Easter egg: Game of Life (life.odin) ─────────────────────────────────────

@(test)
conway_blinker_oscillates :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A clean void arena deep in the rock, far from the player's sanctuary.
    cx, cy := 100, 80
    for y in cy-4 ..= cy+4 {
        for x in cx-4 ..= cx+4 do set_tile(&gs.world, x, y, .Void)
    }
    // A horizontal blinker...
    set_tile(&gs.world, cx-1, cy, .Stone)
    set_tile(&gs.world, cx,   cy, .Stone)
    set_tile(&gs.world, cx+1, cy, .Stone)

    gs.debug.life = true
    gs.debug.life_timer = LIFE_TICK  // force a generation on this call
    update_life(gs)

    // ...stands vertical one generation later.  B3/S23, as Conway intended.
    testing.expect_value(t, get_tile(&gs.world, cx, cy-1), Tile_Type.Stone)
    testing.expect_value(t, get_tile(&gs.world, cx, cy),   Tile_Type.Stone)
    testing.expect_value(t, get_tile(&gs.world, cx, cy+1), Tile_Type.Stone)
    testing.expect_value(t, get_tile(&gs.world, cx-1, cy), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, cx+1, cy), Tile_Type.Void)
    testing.expect_value(t, gs.debug.life_gen, 1)

    // Off means off: no further evolution.
    gs.debug.life = false
    gs.debug.life_timer = LIFE_TICK
    update_life(gs)
    testing.expect_value(t, get_tile(&gs.world, cx, cy-1), Tile_Type.Stone)
    testing.expect_value(t, gs.debug.life_gen, 1)
}

// ─── Auto-Miner (miner.odin) ──────────────────────────────────────────────────

// Enter a dimension and stand a miner base in the spawn chamber.
@(private = "file")
miner_test_setup :: proc(gs: ^Game_State) -> (base: [2]i32) {
    dimension_test_enter(gs)
    base = {98, 26}  // chamber floor spot, solid stone below (row 27)
    set_tile(&gs.world, int(base.x), int(base.y), .Auto_Miner)
    miner_on_placed(gs, base)
    return
}

@(test)
miner_placement_gated_to_dimensions :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // A valid open spot on the surface — still refused: wrong world.
    sx := 30
    gs.player.pos = {f32(sx), f32(SURFACE_Y) - PLAYER_H}
    set_tile(&gs.world, sx + 2, SURFACE_Y - 1, .Air)  // clear any wild flower here
    testing.expect(t, !placement_ok(gs, .Auto_Miner, sx + 2, SURFACE_Y - 1),
        "miner must not place outside a dimension")
    testing.expect(t, placement_ok(gs, .Stone_Block, sx + 2, SURFACE_Y - 1),
        "the spot itself must be valid (or this test proves nothing)")

    // Inside a dimension the same call passes; a second miner is refused.
    dimension_test_enter(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect(t, placement_ok(gs, .Auto_Miner, 98, 26),
        "miner should place in the spawn chamber")
    miner_on_placed(gs, {98, 26})
    testing.expect(t, !placement_ok(gs, .Auto_Miner, 99, 26),
        "one miner per expedition")
}

@(test)
miner_snake_eats_ore_and_pays_stone_tax :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    miner_test_setup(gs)
    m := &gs.dimension.miner

    // Tick ~40 game-seconds: at 3 s/block the snake advances ~13 blocks.
    for _ in 0 ..< 40 * 60 {
        gs.elapsed_time += 1.0 / 60.0
        update_miner(gs)
    }

    testing.expect(t, m.head != m.base, "the head must leave the base")
    total := miner_haul_total(m)
    testing.expect(t, total > 5, "the snake should have eaten blocks")

    ore: u32 = 0
    for h in m.haul {
        if h.item == .Iron_Ore || h.item == .Silver_Ore || h.item == .Gold_Ore do ore += h.count
    }
    testing.expect(t, ore > 0, "at least one themed ore must be in the haul")

    body := 0
    for tile in gs.world.terrain do if tile == .Miner_Body do body += 1
    testing.expect(t, body > 5, "the trail must be visible in the world")
    testing.expect_value(t, get_tile(&gs.world, int(m.base.x), int(m.base.y)), Tile_Type.Auto_Miner)

    // Projected clear time at tier 0, for tuning (grep "miner clear").
    targets := 0
    for tile in gs.world.terrain do if miner_is_target(gs, tile) do targets += 1
    est := f32(targets) * miner_interval(m) / 3600.0
    log.infof("miner clear: %d ore left, tier 0 ≈ %.1f h (tier 4 ≈ %.1f h)",
        targets, est, est / miner_tier_mult[4])
}

@(test)
miner_boxed_in_gnaws_through_its_own_trail :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    base := miner_test_setup(gs)
    m := &gs.dimension.miner

    // Rebuild the world as one sealed T-pocket.  The snake eats right to the
    // dead-end ore; the branch ore above is then reachable ONLY back through
    // its own body trail — the boxed-in case that used to put it to sleep.
    //
    //        . I .           I ore   S stone   base at (98,26)
    //        . S .
    //   base S O .           O dead-end ore, everything else sealed
    for &tile in gs.world.terrain do tile = .Grass
    set_tile(&gs.world, int(base.x), int(base.y), .Auto_Miner)
    set_tile(&gs.world, int(base.x)+1, int(base.y),   .Stone)
    set_tile(&gs.world, int(base.x)+2, int(base.y),   .Iron_Ore)   // eaten first (dead end)
    set_tile(&gs.world, int(base.x)+1, int(base.y)-1, .Stone)
    set_tile(&gs.world, int(base.x)+1, int(base.y)-2, .Iron_Ore)   // only reachable through the trail

    // ~8 steps is plenty for both ores at 3 s each.
    for _ in 0 ..< 30 * 60 {
        gs.elapsed_time += 1.0 / 60.0
        update_miner(gs)
    }

    iron: u32 = 0
    for h in m.haul do if h.item == .Iron_Ore do iron += h.count
    testing.expect_value(t, iron, u32(2))
    testing.expect_value(t, get_tile(&gs.world, int(base.x)+1, int(base.y)-2), Tile_Type.Miner_Body)
    testing.expect(t, m.asleep, "with every ore eaten the miner sleeps for real")
}

@(test)
miner_gem_feed_raises_tier :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    base := miner_test_setup(gs)
    m := &gs.dimension.miner
    testing.expect_value(t, miner_interval(m), MINER_BASE_INTERVAL)

    // An emerald dropped beside the base is absorbed as tier 1...
    idx := grid_idx(int(base.x) - 1, int(base.y))
    gs.world.items[idx]       = .Emerald
    gs.world.item_counts[idx] = 1
    update_miner(gs)
    testing.expect_value(t, m.tier, u8(1))
    testing.expect_value(t, gs.world.item_counts[idx], u8(0))
    testing.expect_value(t, miner_interval(m), MINER_BASE_INTERVAL / 1.5)

    // ...and a diamond later jumps straight to tier 3.
    gs.world.items[idx]       = .Diamond
    gs.world.item_counts[idx] = 1
    update_miner(gs)
    testing.expect_value(t, m.tier, u8(3))
}

@(test)
miner_anchors_dimension_and_catches_up :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    miner_test_setup(gs)
    m := &gs.dimension.miner

    // Mine a vein by hand, then leave through the gate.
    vx, vy := -1, -1
    scan: for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if get_tile(&gs.world, x, y) == .Iron_Ore { vx, vy = x, y; break scan }
        }
    }
    set_tile(&gs.world, vx, vy, .Void)
    gate := DIM_GATE_TILES
    gs.player.pos = {f32(gate[0].x), f32(gate[0].y) + 1 - PLAYER_H}
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)

    // A DIFFERENT spawner refuses to open while the miner anchors this world.
    ox, oy := 40, SURFACE_Y - 1
    set_tile(&gs.world, ox, oy, .Dimension_Spawner)
    gs.player.pos = {f32(ox - 2), f32(SURFACE_Y) - PLAYER_H}
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_SURFACE)  // still home

    // 90 game-seconds pass; re-entering the ANCHORED world keeps the mined
    // vein (no regen) and queues the time as backlog, drained by update
    // frames (MINER_STEPS_PER_FRAME per frame — flagg G6).
    gs.elapsed_time += 90
    before := miner_haul_total(m)
    gs.player.pos = {f32(20 - 2), f32(SURFACE_Y) - PLAYER_H}  // original spawner
    player_interact(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect_value(t, get_tile(&gs.world, vx, vy), Tile_Type.Void)  // anchored: no regen
    for _ in 0 ..< 3 {
        update_miner(gs)
        eq_clear(&gs.events)
    }
    testing.expect(t, miner_haul_total(m) > before + 20, "catch-up must apply the time away")
}

@(test)
miner_catchup_is_amortized :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    miner_test_setup(gs)
    m := &gs.dimension.miner

    // An hour of owed work queues over a thousand steps, but one frame
    // drains at most MINER_STEPS_PER_FRAME BFS steps — re-entry never
    // stalls (flagg G6).
    gs.elapsed_time += 3600
    miner_catchup(gs)
    before := miner_haul_total(m)
    update_miner(gs)
    eq_clear(&gs.events)
    first := miner_haul_total(m) - before
    testing.expect(t, first > 0, "the backlog must start draining")
    testing.expect(t, int(first) <= MINER_STEPS_PER_FRAME, "one frame must not drain the whole backlog")

    // The fast-forward keeps rolling frame after frame.
    for _ in 0 ..< 5 {
        update_miner(gs)
        eq_clear(&gs.events)
    }
    testing.expect(t, miner_haul_total(m) > before + first, "backlog keeps draining across frames")
}

@(test)
miner_withdraw_and_reclaim :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    base := miner_test_setup(gs)
    m := &gs.dimension.miner

    // A wide haul pours into the bag as 99-stacks.
    m.haul[0] = {.Iron_Ore, 250}
    miner_withdraw(gs)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 250)
    testing.expect_value(t, miner_haul_total(m), u32(0))

    // Mining the base back releases the anchor: the next entry regenerates.
    handle_tile_mined(gs, Event{tile = base})
    testing.expect(t, !m.active, "reclaiming the base must deactivate the miner")
    gate := DIM_GATE_TILES
    gs.player.pos = {f32(gate[0].x), f32(gate[0].y) + 1 - PLAYER_H}
    player_interact(gs)
    player_interact(gs)  // back in through the same spawner
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    body := 0
    for tile in gs.world.terrain do if tile == .Miner_Body do body += 1
    testing.expect_value(t, body, 0)  // the world collapsed to seed — trail gone
}

// ─── Silo (silo.odin) ─────────────────────────────────────────────────────────

// Stand a registered silo in the surface air row, solid grass below.
@(private = "file")
silo_test_place :: proc(gs: ^Game_State) -> (tile: [2]i32) {
    tile = {i32(GRID_W/2 + 2), i32(SURFACE_Y - 1)}
    set_tile(&gs.world, int(tile.x), int(tile.y), .Silo)
    silo_on_placed(gs, tile)
    return
}

@(test)
silo_accumulates_past_the_u8_world :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    tile := silo_test_place(gs)
    feed := grid_idx(int(tile.x) - 1, int(tile.y))

    // Three 99-stacks Q-dropped beside it vanish into wide slots: 297 > 255,
    // past anything a u8 ground stack or tray could hold (§7.6 step 1).
    for _ in 0 ..< 3 {
        gs.world.items[feed]       = .Iron_Ore
        gs.world.item_counts[feed] = 99
        update_sim(gs)
        eq_clear(&gs.events)
        testing.expect_value(t, gs.world.items[feed], Item.None)  // vacuumed
    }
    s := silo_at(gs, gs.level_index, tile)
    testing.expect(t, s != nil, "silo record registered on placement")
    testing.expect_value(t, silo_total(s), u32(297))
}

@(test)
silo_withdraw_pours_99_stacks :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    tile := silo_test_place(gs)
    s := silo_at(gs, gs.level_index, tile)
    s.slots[0] = {.Iron_Bar, 300}

    silo_withdraw(gs, s)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Bar), 300)
    testing.expect_value(t, silo_total(s), u32(0))
}

@(test)
silo_too_heavy_to_break_until_empty :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)
    tile := silo_test_place(gs)
    s := silo_at(gs, gs.level_index, tile)
    s.slots[0] = {.Gold_Bar, 500}

    // Neither the pick nor an enemy smash moves a loaded silo.
    handle_tile_mined(gs, Event{tile = tile})
    testing.expect_value(t, get_tile(&gs.world, int(tile.x), int(tile.y)), Tile_Type.Silo)
    smash_tile(gs, int(tile.x), int(tile.y))
    testing.expect_value(t, get_tile(&gs.world, int(tile.x), int(tile.y)), Tile_Type.Silo)
    testing.expect_value(t, silo_total(s), u32(500))

    // Emptied, it lifts like any machine: tile drops its item, record frees.
    s.slots[0] = {}
    handle_tile_mined(gs, Event{tile = tile})
    testing.expect(t, get_tile(&gs.world, int(tile.x), int(tile.y)) != .Silo, "empty silo mines away")
    testing.expect_value(t, gs.world.items[grid_idx(int(tile.x), int(tile.y))], Item.Silo)
    testing.expect(t, silo_at(gs, gs.level_index, tile) == nil, "record freed for reuse")
}

@(test)
smelter_casts_into_adjacent_silo :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Smelter with a silo out-chute on its right; an ore pile on the far
    // side, out of the silo's vacuum reach.
    sx, sy := GRID_W/2, SURFACE_Y - 1
    set_tile(&gs.world, sx, sy, .Smelter)
    tile := [2]i32{i32(sx + 1), i32(sy)}
    set_tile(&gs.world, sx + 1, sy, .Silo)
    silo_on_placed(gs, tile)
    in_idx := grid_idx(sx - 1, sy)
    gs.world.items[in_idx]       = .Iron_Ore
    gs.world.item_counts[in_idx] = 4
    gs.world.sim_data[grid_idx(sx, sy)].fuel_count = u8(FUEL_PER_BAR * 2)  // wood for 2 bars

    // Two smelt cycles: 4 ore → 2 bars, straight past the tray.
    frames := int((SMELT_TIME * 2) / gs.delta_time) + 4
    for _ in 0 ..< frames {
        update_sim(gs)
        eq_clear(&gs.events)
    }

    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    testing.expect_value(t, int(sd.store_count), 0)  // the tray stays empty
    s := silo_at(gs, gs.level_index, tile)
    testing.expect(t, s != nil, "silo record registered")
    testing.expect_value(t, s.slots[0].item, Item.Iron_Bar)
    testing.expect_value(t, s.slots[0].count, u32(2))
}

@(test)
silo_placement_gates :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // On the surface a silo places fine — until the record book is full.
    x, y := GRID_W/2 + 2, SURFACE_Y - 1
    gs.player.pos = {f32(x - 2), f32(SURFACE_Y) - PLAYER_H}
    testing.expect(t, placement_ok(gs, .Silo, x, y), "surface placement should pass")
    for &s in gs.sim.silos do s.active = true
    testing.expect(t, !placement_ok(gs, .Silo, x, y), "full record book refuses")
    for &s in gs.sim.silos do s.active = false

    // Never in a dimension — the record would outlive the ephemeral world.
    dimension_test_enter(gs)
    testing.expect_value(t, gs.level_index, LEVEL_DIMENSION)
    testing.expect(t, !placement_ok(gs, .Silo, 98, 26), "no silos in ephemeral worlds")
}

// ─── Structural gravity (gravity.odin) ────────────────────────────────────────

@(private = "file")
gravity_count_active :: proc(gs: ^Game_State) -> int {
    n := 0
    for b in gs.gravity.blocks do if b.active do n += 1
    return n
}

// Carve an air pocket and stand a three-block trunk on a grass floor.  Returns
// the trunk column; ground is at gy, trunk at gy-1, gy-2, gy-3.
@(private = "file")
gravity_plant_tree :: proc(gs: ^Game_State, x, gy: int) {
    for yy in gy - 6 ..= gy do for xx in x - 2 ..= x + 2 do set_tile(&gs.world, xx, yy, .Air)
    set_tile(&gs.world, x, gy, .Grass)          // anchor
    set_tile(&gs.world, x, gy - 1, .Wood)       // trunk
    set_tile(&gs.world, x, gy - 2, .Wood)
    set_tile(&gs.world, x, gy - 3, .Wood)
}

@(test)
gravity_tree_falls_when_base_cut :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    x, gy := 100, 70
    gravity_plant_tree(gs, x, gy)

    // Cut the base trunk: the two blocks above lose their only path to ground.
    set_tile(&gs.world, x, gy - 1, .Void)
    gravity_check_removed(gs, x, gy - 1)

    // They leave the grid and enter the falling pool immediately.
    testing.expect_value(t, get_tile(&gs.world, x, gy - 2), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, x, gy - 3), Tile_Type.Void)
    testing.expect_value(t, gravity_count_active(gs), 2)
    // The original cell stays attached to each airborne block so render can
    // reuse the exact standing Wood atlas variant throughout the fall.
    for b in gs.gravity.blocks {
        if !b.active do continue
        testing.expect_value(t, b.x, b.source_x)
        testing.expect_value(t, b.y, f32(b.source_y))
    }

    // Let them settle: each lands as a collectible drop, none re-settle as solid.
    for _ in 0 ..< 400 do update_gravity(gs)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(&gs.world, x, gy - 1), Tile_Type.Void)
    testing.expect_value(t, get_tile(&gs.world, x, gy - 2), Tile_Type.Void)
    // Two trunk blocks fell → two Wood Logs piled on the grass, waiting to be grabbed.
    idx := grid_idx(x, gy - 1)
    testing.expect_value(t, gs.world.items[idx], Item.Wood_Log)
    testing.expect_value(t, int(gs.world.item_counts[idx]), 2)
}

@(test)
gravity_dirt_resettles_as_a_tile :: proc(t: ^testing.T) {
    // Placed dirt is sand-style: cut its anchor and the floating block falls,
    // then lands as a Dirt TILE again (not a crumbled drop like a felled tree).
    gs := test_state()
    defer free(gs)
    w := &gs.world
    x := 100

    for yy in 68 ..= 76 do for xx in x - 1 ..= x + 2 do set_tile(w, xx, yy, .Air)
    set_tile(w, x + 1, 75, .Stone)     // floor to land on
    set_tile(w, x, 70, .Stone)         // natural anchor (non-faller)
    set_tile(w, x + 1, 70, .Dirt)      // cantilevered off the anchor, air below

    // While the anchor stands, the dirt is supported — nothing falls.
    gravity_check_removed(gs, x + 1, 71)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(w, x + 1, 70), Tile_Type.Dirt)

    // Cut the anchor: the dirt loses its only path to ground and detaches.
    set_tile(w, x, 70, .Void)
    gravity_check_removed(gs, x, 70)
    testing.expect_value(t, get_tile(w, x + 1, 70), Tile_Type.Void)  // left the grid
    testing.expect_value(t, gravity_count_active(gs), 1)

    // It settles onto the floor as a Dirt tile — a solid block, not a drop.
    for _ in 0 ..< 400 do update_gravity(gs)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(w, x + 1, 74), Tile_Type.Dirt)          // rests on the floor
    testing.expect_value(t, gs.world.items[grid_idx(x + 1, 74)], Item.None)  // no crumbled clod
}

@(test)
gravity_placed_stone_falls_natural_stays :: proc(t: ^testing.T) {
    // Placed stone obeys gravity (sand-style, like dirt); the identical natural
    // cave stone never moves.  The .Placed cell bit is the only difference.
    gs := test_state()
    defer free(gs)
    w := &gs.world
    x := 100

    for yy in 68 ..= 76 do for xx in x - 1 ..= x + 2 do set_tile(w, xx, yy, .Air)
    set_tile(w, x + 1, 75, .Stone)                    // floor to land on
    set_tile(w, x, 70, .Stone)                        // natural anchor (not placed)
    set_tile(w, x + 1, 70, .Stone)                    // a stone block...
    w.tile_flags[grid_idx(x + 1, 70)] += {.Placed}    // ...the player placed

    // Same tile type, opposite gravity — decided per cell by .Placed.
    testing.expect(t, is_faller(w, x + 1, 70), "placed stone is a faller")
    testing.expect(t, !is_faller(w, x, 70), "natural stone is not")

    // Cut the anchor: the placed block detaches, falls, and re-settles as a
    // Stone tile — still .Placed, so it stays sand, and it left no crumb drop.
    set_tile(w, x, 70, .Void)
    gravity_check_removed(gs, x, 70)
    testing.expect_value(t, gravity_count_active(gs), 1)
    testing.expect_value(t, get_tile(w, x + 1, 70), Tile_Type.Void)  // lifted out

    for _ in 0 ..< 400 do update_gravity(gs)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(w, x + 1, 74), Tile_Type.Stone)
    testing.expect(t, .Placed in w.tile_flags[grid_idx(x + 1, 74)], "settled stone stays placed")
    testing.expect_value(t, gs.world.items[grid_idx(x + 1, 74)], Item.None)
}

@(test)
gravity_natural_terrain_never_falls :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    // Mining natural stone must never spawn a falling block — the whole point of
    // the structural-only scope is that caves don't collapse.
    x, y := 100, 90
    set_tile(&gs.world, x, y, .Stone)
    set_tile(&gs.world, x, y - 1, .Stone)
    set_tile(&gs.world, x, y, .Void)
    gravity_check_removed(gs, x, y)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(&gs.world, x, y - 1), Tile_Type.Stone)
}

@(test)
gravity_grounded_remainder_holds :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    x, gy := 100, 70
    gravity_plant_tree(gs, x, gy)

    // Cut the TOP block: the lower trunk is still rooted to the grass, so nothing
    // should fall.
    set_tile(&gs.world, x, gy - 3, .Void)
    gravity_check_removed(gs, x, gy - 3)
    testing.expect_value(t, gravity_count_active(gs), 0)
    testing.expect_value(t, get_tile(&gs.world, x, gy - 1), Tile_Type.Wood)
    testing.expect_value(t, get_tile(&gs.world, x, gy - 2), Tile_Type.Wood)
}

@(test)
barrel_stores_and_retrieves :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    tile := [2]i32{40, i32(SURFACE_Y)}
    barrel_on_placed(gs, tile)
    b := barrel_at(gs, gs.level_index, tile)
    testing.expect(t, b != nil, "barrel record should exist after placement")

    // Put a stack in the bag, find its slot, then stow the whole stack.
    inventory_insert(&gs.player.inventory, .Iron_Ore, 30)
    bag_slot := -1
    for s, i in gs.player.inventory.slots {
        if s.item == .Iron_Ore { bag_slot = i; break }
    }
    testing.expect(t, bag_slot >= 0, "iron ore should be in the bag")

    barrel_store(gs, b, bag_slot)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)
    testing.expect_value(t, barrel_total(b), 30)

    // Withdraw it back into the bag.
    barrel_take(gs, b, 0)
    testing.expect_value(t, barrel_total(b), 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 30)
}

@(test)
item_drop_lays_a_ground_pile :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    sx, sy := GRID_W/2, SURFACE_Y - 3   // open sky beside the player
    gs.player.pos = {f32(sx), f32(sy)}
    inventory_insert(&gs.player.inventory, .Iron_Ore, 10)
    slot := -1
    for s, i in gs.player.inventory.slots do if s.item == .Iron_Ore { slot = i; break }

    // Drop the whole stack onto an open cell in reach — it becomes a ground pile.
    tx, ty := sx + 1, sy
    handle_item_drop(gs, Event{tile = {i32(tx), i32(ty)}, payload = {int_val = i32(slot)}})
    idx := grid_idx(tx, ty)
    testing.expect_value(t, gs.world.items[idx], Item.Iron_Ore)
    testing.expect_value(t, int(gs.world.item_counts[idx]), 10)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)

    // Out of reach: refused, nothing leaves the bag.
    inventory_insert(&gs.player.inventory, .Gold_Ore, 3)
    for s, i in gs.player.inventory.slots do if s.item == .Gold_Ore { slot = i; break }
    handle_item_drop(gs, Event{tile = {i32(sx + 40), i32(sy)}, payload = {int_val = i32(slot)}})
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Gold_Ore), 3)

    // Onto solid rock: refused.
    set_tile(&gs.world, sx + 2, sy, .Stone)
    handle_item_drop(gs, Event{tile = {i32(sx + 2), i32(sy)}, payload = {int_val = i32(slot)}})
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Gold_Ore), 3)
}

@(test)
loaded_barrel_refuses_the_pick :: proc(t: ^testing.T) {
    gs := test_state()
    defer free(gs)

    tile := [2]i32{40, i32(SURFACE_Y)}
    set_tile(&gs.world, int(tile.x), int(tile.y), .Barrel)
    barrel_on_placed(gs, tile)
    b := barrel_at(gs, gs.level_index, tile)
    barrel_deposit(b, .Gold_Ore, 5)

    // Mining a loaded barrel is refused — the tile and its contents survive.
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = tile})
    process_events(gs)
    testing.expect_value(t, get_tile(&gs.world, int(tile.x), int(tile.y)), Tile_Type.Barrel)
    b = barrel_at(gs, gs.level_index, tile)
    testing.expect(t, b != nil, "record survives a refused mine")
    testing.expect_value(t, barrel_total(b), 5)

    // Emptied, it mines away and frees its record.
    b.slots = {}
    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = tile})
    process_events(gs)
    testing.expect(t, get_tile(&gs.world, int(tile.x), int(tile.y)) != Tile_Type.Barrel, "empty barrel mines away")
    testing.expect(t, barrel_at(gs, gs.level_index, tile) == nil, "record freed on reclaim")
}

@(test)
gravity_preserves_golem_masonry_ownership :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	w:=&gs.world
	gs.elapsed_time=10
	x:=104
	for yy in 68..=76 do for xx in x-1..=x+2 do set_tile(w,xx,yy,.Air)
	set_tile(w,x+1,75,.Stone)
	set_tile(w,x,70,.Stone)
	set_tile(w,x+1,70,.Stone)
	w.tile_flags[grid_idx(x+1,70)]+={.Placed,.Golem_Placed}
	golem_register_block_grace_until(gs,0,{i32(x+1),70},gs.elapsed_time+GOLEM_BLOCK_GRACE_TIME)

	set_tile(w,x,70,.Void)
	gravity_check_removed(gs,x,70)
	testing.expect_value(t,gravity_count_active(gs),1)
	for _ in 0..<400 do update_gravity(gs)
	settled:=[2]i32{i32(x+1),74}
	testing.expect(t,.Golem_Placed in w.tile_flags[grid_idx(int(settled.x),int(settled.y))],
		"settled navigation masonry must remain golem cleanup work")
	testing.expect(t,golem_block_grace_protected(gs,1,settled),"remaining cross-worker grace follows the falling block")
	testing.expect(t,!golem_block_grace_protected(gs,0,settled),"the owner may still reclaim the settled block")
}

// ─── Clay-golem automation ───────────────────────────────────────────────────

@(test)
surface_pond_has_water_clay_and_sand :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	clay, wet, sand := 0, 0, 0
	for x in 0 ..< GRID_W {
		tile := get_tile(&gs.world,x,SURFACE_Y)
		if tile==.Clay do clay += 1
		if tile==.Water do wet += 1
		if tile==.Sand do sand += 1
	}
	testing.expect(t,clay>0,"the pond should expose mineable clay banks")
	testing.expect(t,wet>0,"the pond should hold water")
	testing.expect(t,sand>0,"the pond should have a sand shore")
	testing.expect_value(t,terrain_table[.Clay].drop_item,Item.Clay)
	testing.expect_value(t,terrain_table[.Sand].drop_item,Item.Sand)
}

@(test)
command_wand_loads_deploys_and_recalls_golems :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	gs.player.equipment[.Weapon] = .Command_Wand
	gs.player.pos = {90, f32(SURFACE_Y)-PLAYER_H}
	inventory_insert(&gs.player.inventory,.Clay_Golem,2)
	slot := -1
	for s,i in gs.player.inventory.slots do if s.item==.Clay_Golem {slot=i;break}
	testing.expect(t,golem_load(gs,slot),"basic wand should bind its first golem")
	testing.expect(t,!golem_load(gs,slot),"basic wand capacity is exactly one")
	testing.expect_value(t,golem_loaded_count(gs),1)

	spawn := [2]i32{91,i32(SURFACE_Y-1)}
	testing.expect(t,golem_deploy(gs,spawn),"bound golem should deploy on open ground")
	testing.expect_value(t,golem_deployed_count(gs,LEVEL_SURFACE),1)
	testing.expect_value(t,gs.golems.data[0].mode,Golem_Mode.Gather)
	golem_toggle(gs,0)
	testing.expect_value(t,gs.golems.data[0].mode,Golem_Mode.Build)
	golem_recall(gs,0)
	testing.expect_value(t,gs.golems.data[0].status,Golem_Status.Carried)
}

@(test)
debug_cheat_places_a_ready_clay_golem :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 54..=58 do set_tile(&gs.world,90,y,.Air)
	set_tile(&gs.world,90,59,.Stone)
	testing.expect(t,debug_golem_deploy(gs,{90,58}),"the debug stamp should deploy directly on open ground")
	g:=&gs.golems.data[0]
	testing.expect_value(t,g.status,Golem_Status.Deployed)
	testing.expect_value(t,g.mode,Golem_Mode.Gather)
	testing.expect_value(t,g.level,gs.level_index)
	testing.expect_value(t,golem_tile(g),[2]i32{90,58})
}

@(test)
command_wand_zone_requires_a_deliberate_drag :: proc(t:^testing.T) {
	testing.expect(t,!golem_zone_drag_ready({100,100},{103,104}),"a normal click or small hand jitter must preserve the old zone")
	testing.expect(t,golem_zone_drag_ready({100,100},{106,100}),"a deliberate six-pixel drag should start zone painting")
}

@(test)
command_wand_golem_hitbox_matches_the_visible_worker :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,mode=.Gather,project_cell=-1}
	// This point is just outside the center tile but still over the padded
	// rendered worker, reproducing the fiddly click from the playtest.
	point:=[2]f32{19.95*CELL_SIZE,(g.pos.y+.3)*CELL_SIZE}
	testing.expect_value(t,golem_at_world_point(gs,point),0)
}

@(test)
hearth_upgrades_one_to_five_to_fifteen_slots :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	gs.player.equipment[.Weapon]=.Command_Wand
	inventory_insert(&gs.player.inventory,.Emerald,1)
	golem_hearth_use(gs)
	testing.expect_value(t,gs.player.equipment[.Weapon],Item.Command_Wand_Emerald)
	testing.expect_value(t,command_wand_capacity(gs.player.equipment[.Weapon]),5)
	testing.expect_value(t,inventory_count(&gs.player.inventory,.Emerald),0)

	inventory_insert(&gs.player.inventory,.Hel_Gem,1)
	golem_hearth_use(gs)
	testing.expect_value(t,gs.player.equipment[.Weapon],Item.Command_Wand_Hel)
	testing.expect_value(t,command_wand_capacity(gs.player.equipment[.Weapon]),15)
}

@(test)
gather_zone_climb_back_yields_to_a_reachable_marked_resource :: proc(t: ^testing.T) {
	// Regression: a golem legitimately working a Golem_Marked block far below
	// its (tiny) work-zone rectangle used to get yanked into a pointless
	// climb-back every time it finished a job there, forever re-picking the
	// same still-marked target and never making progress. golem_assign_gather
	// must not treat "below the zone" as "must have fallen" when a marked
	// resource explains exactly why the worker is there.
	gs:=test_state(); defer free(gs)
	for y in 60..=70 do for x in 18..=24 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=24 do set_tile(&gs.world,x,70,.Stone)
	marked:=[2]i32{21,68}
	set_tile(&gs.world,int(marked.x),int(marked.y),.Stone)
	testing.expect(t,golem_set_block_mark(gs,marked,true),"fixture needs a marked resource below the zone")
	gs.golems.work[gs.level_index]={active=true,min={18,60},max={24,61}}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={21.2,69-GOLEM_H},hp=GOLEM_HP,mode=.Gather,grounded=true,project_cell=-1}
	testing.expect(t,golem_tile(g).y>gs.golems.work[gs.level_index].max.y+2,"fixture needs the worker well below the zone")

	golem_assign_gather(gs,0)
	testing.expect_value(t,g.job,Golem_Job.Mine)
	testing.expect_value(t,g.target,marked)
	testing.expect(t,!g.recovering,"a legitimate marked-resource trip must not trigger the climb-back safety net")
}

@(test)
gather_zone_climb_back_still_fires_without_a_marked_resource :: proc(t: ^testing.T) {
	// The climb-back safety net itself must still work for its real case: a
	// worker with nothing below it to justify the depth (an actual fall).
	gs:=test_state(); defer free(gs)
	for y in 60..=70 do for x in 18..=24 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=24 do set_tile(&gs.world,x,70,.Stone)
	gs.golems.work[gs.level_index]={active=true,min={18,60},max={24,61}}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={21.2,69-GOLEM_H},hp=GOLEM_HP,mode=.Gather,grounded=true,project_cell=-1}

	golem_assign_gather(gs,0)
	testing.expect_value(t,g.job,Golem_Job.Seek)
	testing.expect(t,g.recovering,"an unexplained drop below the zone should still climb back")
}

@(test)
gather_zone_is_normalized_and_capped :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	golem_set_zone(gs,{80,80},{150,20})
	w := gs.golems.work[gs.level_index]
	testing.expect(t,w.active,"work order should activate")
	testing.expect(t,w.max.x-w.min.x+1<=GOLEM_ZONE_MAX_W,"zone width must be capped")
	testing.expect(t,w.max.y-w.min.y+1<=GOLEM_ZONE_MAX_H,"zone height must be capped")
	testing.expect(t,w.min.x<=w.max.x && w.min.y<=w.max.y,"reversed drag should normalize")
}

@(test)
gatherer_skips_an_unreachable_nearest_resource :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 55..=59 do for x in 16..=23 do set_tile(&gs.world,x,y,.Air)
	for x in 16..=23 do set_tile(&gs.world,x,60,.Stone)
	// A protected column divides the nearest block from the worker. Dig-aware
	// A* must not tunnel through it or walk around either world edge.
	for y in 0..<GRID_H {
		set_tile(&gs.world,21,y,.Stone)
		gs.world.tile_flags[grid_idx(21,y)] += {.Placed}
	}
	blocked,reachable:=[2]i32{22,59},[2]i32{17,59}
	set_tile(&gs.world,int(blocked.x),int(blocked.y),.Stone)
	set_tile(&gs.world,int(reachable.x),int(reachable.y),.Stone)
	gs.golems.work[gs.level_index]={active=true,min={17,59},max={22,59}}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}

	first,found:=golem_find_resource(gs,0,nil)
	testing.expect(t,found,"fixture needs a resource candidate")
	testing.expect_value(t,first,blocked)
	testing.expect(t,golem_assign_resource(gs,0),"the gatherer should try another resource after pathfinding rejects the nearest")
	testing.expect(t,g.has_target,"a successful alternative must remain reserved")
	testing.expect_value(t,g.target,reachable)
}

@(test)
gatherer_cleans_navigation_masonry_after_natural_resources :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 56..=59 do for x in 19..=25 do set_tile(&gs.world,x,y,.Air)
	for x in 19..=25 do set_tile(&gs.world,x,60,.Stone)
	player_block,nav_block,natural:=[2]i32{21,59},[2]i32{22,59},[2]i32{24,59}
	for cell in ([3][2]i32{player_block,nav_block,natural}) do set_tile(&gs.world,int(cell.x),int(cell.y),.Stone)
	gs.world.tile_flags[grid_idx(int(player_block.x),int(player_block.y))]+={.Placed}
	gs.world.tile_flags[grid_idx(int(nav_block.x),int(nav_block.y))]+={.Placed,.Golem_Placed}
	gs.golems.work[gs.level_index]={active=true,min={21,59},max={24,59}}
	gs.golems.data[0]={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}

	first,found:=golem_find_resource(gs,0,nil)
	testing.expect(t,found,"fixture needs natural work")
	testing.expect_value(t,first,natural)
	set_tile(&gs.world,int(natural.x),int(natural.y),.Air)
	cleanup,cleanup_found:=golem_find_resource(gs,0,nil)
	testing.expect(t,cleanup_found,"owned navigation masonry should become cleanup work")
	testing.expect_value(t,cleanup,nav_block)
	set_tile(&gs.world,int(nav_block.x),int(nav_block.y),.Air)
	player_cleanup,player_cleanup_found:=golem_find_resource(gs,0,nil)
	testing.expect(t,player_cleanup_found,"a marked Gather rectangle should finish ordinary player masonry")
	testing.expect_value(t,player_cleanup,player_block)
}

@(test)
fresh_golem_masonry_has_cross_worker_grace :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.elapsed_time=10
	for y in 56..=59 do for x in 19..=23 do set_tile(&gs.world,x,y,.Air)
	for x in 19..=23 do set_tile(&gs.world,x,60,.Stone)
	owned,spare:=[2]i32{21,59},[2]i32{22,59}
	for cell in ([2][2]i32{owned,spare}) {
		set_tile(&gs.world,int(cell.x),int(cell.y),.Grass)
		gs.world.tile_flags[grid_idx(int(cell.x),int(cell.y))]+={.Placed,.Golem_Placed}
		golem_register_block_grace_until(gs,0,cell,gs.elapsed_time+GOLEM_BLOCK_GRACE_TIME)
	}
	gs.golems.work[gs.level_index]={active=true,min=owned,max=spare}
	owner:=&gs.golems.data[0]
	other:=&gs.golems.data[1]
	owner^={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}
	other^={status=.Deployed,level=gs.level_index,pos={23.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}

	_,other_found:=golem_find_resource(gs,1,nil)
	testing.expect(t,!other_found,"another worker must not select freshly placed masonry")
	testing.expect(t,!golem_mine_tile(gs,other,owned,true,1),"a stale path must not bypass the grace period")
	testing.expect(t,golem_mine_tile(gs,owner,spare,true,0),"the placing worker may reclaim its own block immediately")

	gs.elapsed_time+=GOLEM_BLOCK_GRACE_TIME+.01
	target,found:=golem_find_resource(gs,1,nil)
	testing.expect(t,found,"masonry should become ordinary cleanup work after three seconds")
	testing.expect_value(t,target,owned)
	testing.expect(t,golem_mine_tile(gs,other,owned,true,1),"another worker may reclaim the block after grace expires")
}

@(test)
gather_zone_clears_grass_and_dirt :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 56..=59 do for x in 19..=23 do set_tile(&gs.world,x,y,.Air)
	for x in 19..=23 do set_tile(&gs.world,x,60,.Stone)
	grass,dirt:=[2]i32{21,59},[2]i32{22,59}
	set_tile(&gs.world,int(grass.x),int(grass.y),.Grass)
	set_tile(&gs.world,int(dirt.x),int(dirt.y),.Dirt)
	gs.golems.work[gs.level_index]={active=true,min=grass,max=dirt}
	gs.golems.data[0]={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}
	target,found:=golem_find_resource(gs,0,nil)
	testing.expect(t,found,"surface clearing should include ordinary soil")
	testing.expect(t,target==grass || target==dirt,"surface clearing should select grass or dirt")
	set_tile(&gs.world,int(target.x),int(target.y),.Air)
	other,other_found:=golem_find_resource(gs,0,nil)
	testing.expect(t,other_found,"both surface terrain types should be gatherable")
	testing.expect(t,other==grass || other==dirt,"the remaining soil should still be selected")
}

@(test)
painted_excavation_works_outside_zone_and_takes_priority :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 56..=59 do for x in 19..=27 do set_tile(&gs.world,x,y,.Air)
	for x in 19..=27 do set_tile(&gs.world,x,60,.Stone)
	zone_block,painted:=[2]i32{21,59},[2]i32{25,59}
	set_tile(&gs.world,int(zone_block.x),int(zone_block.y),.Stone)
	set_tile(&gs.world,int(painted.x),int(painted.y),.Stone)
	gs.golems.work[gs.level_index]={active=true,min=zone_block,max=zone_block}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}

	testing.expect(t,golem_set_block_mark(gs,painted,true),"Shift-paint should tag an ordinary mineable block")
	testing.expect(t,.Golem_Marked in gs.world.tile_flags[grid_idx(int(painted.x),int(painted.y))],"paint must persist on the world cell")
	target,found:=golem_find_resource(gs,0,nil)
	testing.expect(t,found,"painted excavation should create a gather job")
	testing.expect_value(t,target,painted)
	testing.expect(t,golem_mine_tile(gs,g,painted,false,0),"paint explicitly permits mining outside the rectangle")
	testing.expect(t,.Golem_Marked not_in gs.world.tile_flags[grid_idx(int(painted.x),int(painted.y))],"mining consumes the paint tag")
	testing.expect_value(t,gs.golem_marks.count,0)

	set_tile(&gs.world,int(painted.x),int(painted.y),.Stone)
	testing.expect(t,golem_set_block_mark(gs,painted,true),"the brush can repaint a block")
	testing.expect(t,golem_set_block_mark(gs,painted,false),"Shift-right should erase painted excavation")
	testing.expect(t,.Golem_Marked not_in gs.world.tile_flags[grid_idx(int(painted.x),int(painted.y))],"erasing leaves the block untouched")
}

@(test)
painted_excavation_carves_a_path_without_rectangle :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 55..=59 do for x in 18..=30 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=30 do set_tile(&gs.world,x,60,.Stone)
	for x in 24..=27 {
		set_tile(&gs.world,x,59,.Stone)
		testing.expect(t,golem_set_block_mark(gs,{i32(x),59},true),"tunnel brush should tag every stone")
	}
	gs.golems.data[0]={status=.Deployed,level=gs.level_index,pos={20.2,60-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,grounded=true,project_cell=-1}
	testing.expect(t,!gs.golems.work[gs.level_index].active,"painted excavation must not require a rectangle")

	for _ in 0..<2000 {
		update_golems(gs)
		if gs.golem_marks.count==0 do break
	}
	for x in 24..=27 do testing.expect(t,get_tile(&gs.world,x,59)!=.Stone,"the crew should carve the painted run")
	testing.expect_value(t,gs.golem_marks.count,0)
}

@(test)
paint_brush_rasterizes_fast_drag_without_gaps :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 50..=53 do for x in 20..=26 do set_tile(&gs.world,x,y,.Stone)
	golem_queue_paint_line(gs,{20,50},{26,53},true)
	process_events(gs)
	testing.expect_value(t,gs.golem_marks.count,7)
	for x in 20..=26 {
		marked_in_column:=false
		for y in 50..=53 do if .Golem_Marked in gs.world.tile_flags[grid_idx(x,y)] {
			marked_in_column=true
			break
		}
		testing.expect(t,marked_in_column,"a fast brush sweep must not skip crossed columns")
	}
}

@(test)
golem_packs_real_block_and_routes_it :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	g := &gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={90,f32(SURFACE_Y)-GOLEM_H},hp=GOLEM_HP,project_cell=-1}
	target := [2]i32{92,i32(SURFACE_Y-1)}
	set_tile(&gs.world,int(target.x),int(target.y),.Iron_Ore)
	gs.golems.work[gs.level_index]={active=true,min={89,i32(SURFACE_Y-3)},max={95,i32(SURFACE_Y)}}
	testing.expect(t,golem_mine_tile(gs,g,target),"golem should mine a natural resource in its zone")
	testing.expect_value(t,golem_pack_count(g),1)
	testing.expect_value(t,golem_pack_peek(g),Item.Iron_Ore)
	testing.expect(t,get_tile(&gs.world,int(target.x),int(target.y))!=.Iron_Ore,"block leaves the world grid")
	testing.expect(t,gs.particles.count>=5,"mining should stream the block toward the worker")
	testing.expect_value(t,gs.particles.data[0].pos,tile_center(target))
	testing.expect_value(t,gs.particles.data[0].target,golem_center(g))

	smelter := [2]i32{94,i32(SURFACE_Y-1)}
	set_tile(&gs.world,int(smelter.x),int(smelter.y),.Smelter)
	g.carry=golem_pack_pop(g)
	testing.expect(t,golem_deposit_at(gs,smelter,g.carry),"ore should route into a compatible furnace")
	testing.expect_value(t,gs.world.sim_data[grid_idx(int(smelter.x),int(smelter.y))].in_item,Item.Iron_Ore)
}

@(test)
gather_mode_walks_a_block_back_to_storage :: proc(t: ^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in SURFACE_Y-4..<SURFACE_Y do for x in 112..=126 do set_tile(&gs.world,x,y,.Air)
	for x in 112..=126 do set_tile(&gs.world,x,SURFACE_Y,.Grass)
	store:=[2]i32{114,i32(SURFACE_Y-1)}
	set_tile(&gs.world,int(store.x),int(store.y),.Barrel); barrel_on_placed(gs,store)
	target:=[2]i32{124,i32(SURFACE_Y-1)}
	set_tile(&gs.world,int(target.x),int(target.y),.Clay)
	gs.golems.work[gs.level_index]={active=true,min={118,i32(SURFACE_Y-3)},max={125,i32(SURFACE_Y-1)}}
	gs.golems.data[0]={status=.Deployed,level=gs.level_index,pos={118,f32(SURFACE_Y)-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,facing=1,project_cell=-1}
	for _ in 0..<5000 {
		update_golems(gs)
		if barrel_total(barrel_at(gs,gs.level_index,store))>0 do break
	}
	b:=barrel_at(gs,gs.level_index,store)
	testing.expect_value(t,barrel_total(b),1)
	testing.expect_value(t,b.slots[0].item,Item.Clay)
	testing.expect(t,get_tile(&gs.world,int(target.x),int(target.y))!=.Clay,"the carried block should leave the seam")
}

@(test)
gatherer_clears_access_floor_and_stockpiles_without_storage :: proc(t: ^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	// Reproduce the playtest stall: the selected stone is below the surface,
	// while A* approaches through a Grass floor one cell outside the zone.
	for y in 51..=56 do for x in 120..=140 do set_tile(&gs.world,x,y,.Air)
	for x in 120..=140 {
		set_tile(&gs.world,x,54,.Grass)
		set_tile(&gs.world,x,55,.Stone)
	}
	zone_min := [2]i32{129,53}
	zone_max := [2]i32{136,56}
	gs.golems.work[gs.level_index]={active=true,min=zone_min,max=zone_max}
	gs.golems.data[0]={status=.Deployed,level=gs.level_index,pos={124,f32(54)-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,facing=1,project_cell=-1}

	target := [2]i32{129,55}
	for _ in 0..<2000 {
		update_golems(gs)
	}
	testing.expect(t,get_tile(&gs.world,128,54)!=.Grass,"gatherer should clear the mineable access floor planned by A*")
	testing.expect(t,get_tile(&gs.world,int(target.x),int(target.y))!=.Stone,"gatherer should reach and mine the selected stone")

	found_pile := false
	for y in 49..=60 do for x in 116..=144 {
		idx := grid_idx(x,y)
		if !golem_in_work_zone(gs,{i32(x),i32(y)}) && gs.world.items[idx]!=.None && gs.world.item_counts[idx]>0 {
			found_pile=true
		}
	}
	testing.expect(t,found_pile,"without compatible storage the gathered blocks should form a pile outside the zone")
}

@(test)
loaded_gatherer_does_not_jump_loop_on_a_mining_route :: proc(t: ^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	// Two open chambers separated by an unbroken wall. The loaded worker has
	// an old dig-aware route toward storage on the far side, exactly like the
	// live save that repeatedly jumped at a solid waypoint.
	for y in 48..=60 do for x in 14..=36 do set_tile(&gs.world,x,y,.Air)
	for x in 14..=36 do set_tile(&gs.world,x,60,.Stone)
	for y in 0..=60 do for x in 24..=27 do set_tile(&gs.world,x,y,.Stone)
	chest := [2]i32{31,59}
	set_tile(&gs.world,int(chest.x),int(chest.y),.Barrel)
	barrel_on_placed(gs,chest)
	gs.golems.work[gs.level_index]={active=true,min={29,54},max={34,59}}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20,f32(60)-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Deliver,carry=.Grass_Turf,target=chest,has_target=true,facing=1,grounded=true,project_cell=-1}
	g.path={len=1,cursor=0}
	g.path.tiles[0]={24,59} // stale mining waypoint through the wall

	for _ in 0..<2000 {
		update_golems(gs)
		if barrel_total(barrel_at(gs,gs.level_index,chest))>0 &&
		   g.carry==.None && golem_pack_count(g)==0 {break}
	}
	testing.expect_value(t,g.carry,Item.None)
	testing.expect(t,!g.has_target || g.path.len==0 || !is_solid(&gs.world,int(g.path.tiles[g.path.cursor].x),int(g.path.tiles[g.path.cursor].y)),
		"a loaded worker must not keep jumping at a solid mining waypoint")
	b:=barrel_at(gs,gs.level_index,chest)
	testing.expect(t,b!=nil && barrel_total(b)>0,"the worker should use its pack to dig through and deliver the original cargo")
	testing.expect_value(t,golem_pack_count(g),0)
	testing.expect(t,barrel_total(b)>1,"natural blocks cleared from the route should unload with the original cargo")
}

@(test)
golem_bridge_places_free_quick_clay :: proc(t: ^testing.T) {
	// Bridging a gap no longer spends real pack material — it always
	// succeeds via a free, temporary Quick Clay foothold instead.
	gs:=test_state(); defer free(gs)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20,f32(60)-GOLEM_H},hp=GOLEM_HP,
		mode=.Gather,job=.Mine,grounded=true,project_cell=-1}
	for y in 56..=60 do for x in 18..=23 do set_tile(&gs.world,x,y,.Air)
	set_tile(&gs.world,20,60,.Stone)
	g.path={len=1,cursor=0}; g.path.tiles[0]={21,59}
	testing.expect(t,golem_exec_path_bridge(gs,g,0),"the gap waypoint should trigger a bridge action")
	testing.expect_value(t,get_tile(&gs.world,21,60),Tile_Type.Quick_Clay)
	testing.expect(t,is_solid(&gs.world,21,60),"the bridge tile is solid to stand on")
	testing.expect(t,.Placed not_in gs.world.tile_flags[grid_idx(21,60)],"Quick Clay is not tracked as real placed masonry")
	testing.expect_value(t,golem_pack_count(g),0) // never carried anything, never needed to
	found:=false
	for slot in gs.golem_quick_clay.blocks do if slot.active && slot.tile=={21,60} && slot.owner==0 do found=true
	testing.expect(t,found,"the foothold should be tracked for later despawn")
}

@(test)
golem_storage_transfers_show_both_directions :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 57..=61 do for x in 18..=23 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=23 do set_tile(&gs.world,x,61,.Stone)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,61-GOLEM_H},hp=GOLEM_HP,mode=.Build,grounded=true,project_cell=-1}
	source:=[2]i32{22,60}
	gs.world.items[grid_idx(int(source.x),int(source.y))]=.Plank
	gs.world.item_counts[grid_idx(int(source.x),int(source.y))]=1
	testing.expect(t,golem_fetch_carried(gs,g,source,.Plank),"the worker should collect the stored plank")
	testing.expect(t,gs.particles.count>=5,"collecting should stream cargo toward the worker")
	testing.expect_value(t,gs.particles.data[0].pos,tile_center(source))
	testing.expect_value(t,gs.particles.data[0].target,golem_center(g))
	gs.particles={}
	dest:=[2]i32{19,60}
	testing.expect(t,golem_store_carried(gs,g,dest),"the worker should store the carried plank")
	testing.expect(t,gs.particles.count>=5,"storing should stream cargo away from the worker")
	testing.expect_value(t,gs.particles.data[0].pos,golem_center(g))
	testing.expect_value(t,gs.particles.data[0].target,tile_center(dest))
}

@(test)
golem_unloads_its_entire_pack_before_leaving_storage :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 57..=61 do for x in 18..=23 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=23 do set_tile(&gs.world,x,61,.Stone)
	store:=[2]i32{22,60}
	set_tile(&gs.world,int(store.x),int(store.y),.Barrel)
	barrel_on_placed(gs,store)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,61-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Deliver,carry=.Stone_Block,target=store,has_target=true,grounded=true,project_cell=-1}
	for _ in 0..<GOLEM_PACK_CAP-1 do _=golem_pack_add(g,.Stone_Block)

	for _ in 0..<GOLEM_PACK_CAP do golem_update_one(gs,0)
	b:=barrel_at(gs,gs.level_index,store)
	testing.expect_value(t,barrel_total(b),GOLEM_PACK_CAP)
	testing.expect_value(t,g.carry,Item.None)
	testing.expect_value(t,golem_pack_count(g),0)
	testing.expect(t,!g.has_target,"the worker should leave only after every carried block is stored")
}

@(test)
golem_reroutes_remaining_pack_when_storage_fills :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 57..=61 do for x in 18..=24 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=24 do set_tile(&gs.world,x,61,.Stone)
	first,second:=[2]i32{22,60},[2]i32{23,60}
	set_tile(&gs.world,int(first.x),int(first.y),.Barrel); barrel_on_placed(gs,first)
	set_tile(&gs.world,int(second.x),int(second.y),.Barrel); barrel_on_placed(gs,second)
	b1:=barrel_at(gs,gs.level_index,first)
	for &slot in b1.slots do slot={item=.Dirt,count=MAX_STACK}
	b1.slots[0]={item=.Stone_Block,count=MAX_STACK-1}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,61-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Deliver,carry=.Stone_Block,target=first,has_target=true,grounded=true,project_cell=-1}
	_ = golem_pack_add(g,.Stone_Block)
	_ = golem_pack_add(g,.Stone_Block)

	for _ in 0..<3 do golem_update_one(gs,0)
	testing.expect_value(t,b1.slots[0].count,MAX_STACK)
	testing.expect_value(t,barrel_total(barrel_at(gs,gs.level_index,second)),2)
	testing.expect_value(t,g.carry,Item.None)
	testing.expect_value(t,golem_pack_count(g),0)
}

@(test)
golem_replans_a_saved_jump_blocked_by_placed_masonry :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 51..=55 do for x in 20..=28 do set_tile(&gs.world,x,y,.Air)
	for x in 20..=28 do set_tile(&gs.world,x,55,.Stone)
	set_tile(&gs.world,26,54,.Stone)
	set_tile(&gs.world,22,53,.Grass)
	gs.world.tile_flags[grid_idx(22,53)] += {.Placed}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={22.2,55-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Deliver,carry=.Stone_Block,target={26,53},has_target=true,grounded=true,project_cell=-1}
	for _ in 0..<GOLEM_PACK_CAP do _=golem_pack_add(g,.Stone_Block)
	g.path={len=1}; g.path.tiles[0]={23,53}
	testing.expect(t,golem_path_obstructed(gs,g),"fixture needs the saved jump arc blocked overhead")
	golem_update_one(gs,0)
	testing.expect(t,g.has_target,"the loaded worker should find the open route around its old masonry")
	testing.expect(t,!golem_path_obstructed(gs,g),"the replacement route must not repeat the blocked jump")
	testing.expect_value(t,get_tile(&gs.world,22,53),Tile_Type.Grass)
}

@(test)
golem_reclaims_its_own_navigation_masonry :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 51..=55 do for x in 20..=24 do set_tile(&gs.world,x,y,.Air)
	for x in 20..=24 do set_tile(&gs.world,x,55,.Stone)
	set_tile(&gs.world,22,53,.Stone)
	gs.world.tile_flags[grid_idx(22,53)] += {.Placed,.Golem_Placed}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={22.2,55-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Seek,target={24,52},has_target=true,grounded=true,project_cell=-1}
	g.path={len=1}; g.path.tiles[0]={23,53}
	testing.expect(t,golem_path_obstructed(gs,g),"fixture needs the worker's block in its takeoff arc")
	golem_update_one(gs,0)
	testing.expect(t,!is_solid(&gs.world,22,53),"the worker should pick its own obstructing block back up")
	testing.expect_value(t,golem_pack_count(g),1)
	testing.expect(t,.Golem_Placed not_in gs.world.tile_flags[grid_idx(22,53)],"reclaimed masonry must clear its ownership marker")
}

@(test)
golem_replans_an_upper_waypoint_after_falling :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 57..=70 do for x in 21..=27 do set_tile(&gs.world,x,y,.Air)
	for x in 21..=27 do set_tile(&gs.world,x,70,.Stone)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={24.2,70-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Mine,target={24,60},has_target=true,grounded=true,project_cell=-1}
	_ = golem_pack_add(g,.Stone_Block)
	g.path={len=1}; g.path.tiles[0]={24,62}
	testing.expect(t,golem_path_stale(g),"fixture needs a ledge waypoint abandoned by a fall")
	golem_update_one(gs,0)
	testing.expect(t,g.recovering,"the worker should replan from the landing and start a climb")
	testing.expect_value(t,g.path.len,0)
}

@(test)
golem_walks_to_the_standable_origin_used_by_pathfinding :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 54..=61 do for x in 35..=41 do set_tile(&gs.world,x,y,.Air)
	set_tile(&gs.world,37,58,.Stone)
	set_tile(&gs.world,38,60,.Stone)
	set_tile(&gs.world,39,60,.Stone)
	gs.golems.work[gs.level_index]={active=true,min={35,54},max={41,61}}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={37.85,58-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Mine,target={39,60},has_target=true,grounded=true,project_cell=-1}
	testing.expect(t,golem_set_target(gs,g,g.target),"the snapped route should be valid")
	testing.expect_value(t,g.path.len,1)
	testing.expect_value(t,g.path.tiles[0],[2]i32{38,59})
	for _ in 0..<200 {
		golem_update_one(gs,0)
		if get_tile(&gs.world,39,60)!=.Stone do break
	}
	testing.expect(t,get_tile(&gs.world,39,60)!=.Stone,"the perched worker should move to the assumed origin and mine")
}

@(test)
golem_stall_watchdog_enters_local_recovery :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 54..=62 do for x in 45..=49 do set_tile(&gs.world,x,y,.Air)
	for x in 45..=49 do set_tile(&gs.world,x,62,.Stone)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={47.2,62-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Mine,target={47,55},has_target=true,grounded=true,project_cell=-1,replan_timer=GOLEM_STUCK_TIME}
	_ = golem_pack_add(g,.Stone_Block)
	g.path={len=1}; g.path.tiles[0]={48,61}
	golem_update_one(gs,0)
	testing.expect(t,g.recovering,"a route with no waypoint progress must fall back to local recovery")
	testing.expect_value(t,g.path.len,0)
	testing.expect(t,g.replan_timer<GOLEM_STUCK_TIME,"the watchdog must reset after intervening")
}

@(test)
golem_unembeds_from_a_settled_falling_block :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	for y in 59..=65 do for x in 28..=34 do set_tile(&gs.world,x,y,.Air)
	set_tile(&gs.world,29,63,.Stone)
	set_tile(&gs.world,30,62,.Stone)
	gs.world.tile_flags[grid_idx(30,62)] += {.Placed}
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={30.2,62.2},hp=GOLEM_HP,mode=.Gather,
		job=.Deliver,carry=.Stone_Block,target={20,55},has_target=true,project_cell=-1}
	_ = golem_pack_add(g,.Dirt)
	testing.expect(t,!golem_body_clear(&gs.world,g.pos),"fixture needs the worker embedded in settled stone")
	testing.expect(t,golem_unembed(gs,g),"the worker should eject to nearby open ground")
	testing.expect(t,golem_body_clear(&gs.world,g.pos),"the ejected body must be clear of terrain")
	testing.expect(t,golem_tile(g)!=[2]i32{30,62},"the worker must leave the occupied cell")
	testing.expect(t,g.recovering,"an ejected worker should recover locally toward its upper objective")
	testing.expect_value(t,g.carry,Item.Stone_Block)
	testing.expect_value(t,golem_pack_count(g),1)
}

@(test)
falling_block_crumbles_instead_of_settling_inside_a_golem :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 59..=64 do for x in 38..=42 do set_tile(&gs.world,x,y,.Air)
	set_tile(&gs.world,40,64,.Stone)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={40.2,64-GOLEM_H},hp=GOLEM_HP,mode=.Gather,grounded=true,project_cell=-1}
	gs.gravity.blocks[0]={tile=.Stone,x=40,y=62.9,source_x=40,source_y=60,active=true}
	update_gravity(gs)
	testing.expect(t,!gs.gravity.blocks[0].active,"the falling block should resolve on contact")
	testing.expect(t,!is_solid(&gs.world,40,63),"a falling block must not settle inside the worker")
	testing.expect(t,golem_body_clear(&gs.world,g.pos),"the worker must remain outside solid terrain")
	drops:=0
	for i in 0..<GRID_W*GRID_H do if gs.world.items[i]==.Stone_Block do drops+=int(gs.world.item_counts[i])
	testing.expect(t,drops>0,"the blocked fall should preserve its material as a ground item")
}

@(test)
build_worker_without_a_project_unloads_then_waits :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 52..=81 do for x in 18..=24 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=24 do set_tile(&gs.world,x,81,.Stone)
	gs.golems.work[gs.level_index]={active=true,min={18,52},max={24,56}}
	store:=[2]i32{22,80}
	set_tile(&gs.world,int(store.x),int(store.y),.Barrel)
	barrel_on_placed(gs,store)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20.2,81-GOLEM_H},hp=GOLEM_HP,mode=.Build,
		job=.Idle,carry=.Stone_Block,grounded=true,project_cell=-1}
	_ = golem_pack_add(g,.Leaf)
	for _ in 0..<5 do golem_update_one(gs,0)
	testing.expect_value(t,g.carry,Item.None)
	testing.expect_value(t,golem_pack_count(g),0)
	testing.expect_value(t,g.mode,Golem_Mode.Build)
	testing.expect_value(t,g.job,Golem_Job.Idle)
	testing.expect(t,!g.has_target && !g.recovering,"an off-duty builder should wait for a monument plan")
	testing.expect_value(t,barrel_total(barrel_at(gs,gs.level_index,store)),2)
}

@(test)
golem_recovery_punches_through_a_den_shell_instead_of_aborting :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	_ = den_owner_fixture(gs)
	// The fixture's shelter wall includes (48,50). Put the worker directly
	// beneath it with an otherwise clear, supported rescue shaft.
	for y in 47..=52 do set_tile(&gs.world,48,y,.Air)
	set_tile(&gs.world,48,50,.Iron_Ore)
	gs.world.tile_flags[grid_idx(48,50)]={}
	set_tile(&gs.world,48,53,.Stone)
	testing.expect(t,den_protected(gs,48,50,-1),"fixture needs a protected mineral shell overhead")
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={48.2,53-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Seek,target={48,45},has_target=true,recover_from=52,grounded=true,project_cell=-1}
	testing.expect(t,!golem_mine_tile(gs,g,{48,50},true),"ordinary path clearing must still protect the den")
	g.recovering=true
	golem_update_recovery(gs,g,0)
	testing.expect(t,g.recovering,"a den shell above the shaft must not cancel self-rescue")
	testing.expect_value(t,get_tile(&gs.world,48,50),Tile_Type.Air)
	testing.expect_value(t,golem_pack_count(g),1)
}

@(test)
golem_quick_clay_pillars_out_of_a_deep_pocket :: proc(t: ^testing.T) {
	// Same deep-pocket fixture as before, but now the pillar itself is free:
	// the golem starts with an EMPTY pack (no pre-supplied material at all)
	// and must still climb out, using Quick Clay for every footing step.
	// Headroom it digs through along the way still banks real drops, so
	// total Stone is still conserved across terrain + pack/carry + ground.
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for &tile in gs.world.terrain do tile=.Stone
	for y in 95..=99 do set_tile(&gs.world,30,y,.Air)
	for y in 82..=86 do for x in 27..=33 do set_tile(&gs.world,x,y,.Air)
	stone_before:=0
	for tile in gs.world.terrain do if tile==.Stone do stone_before+=1
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={30.2,100-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Seek,target={30,84},has_target=true,facing=1,grounded=true,project_cell=-1,
		recovering=true,recover_from=99}
	gs.golems.work[gs.level_index]={active=true,min={27,82},max={33,86}}
	start_y:=golem_tile(g).y
	saw_quick_clay:=false
	for _ in 0..<5000 {
		update_golems(gs)
		bt:=golem_tile(g)
		if get_tile(&gs.world,int(bt.x),int(bt.y)+1)==.Quick_Clay do saw_quick_clay=true
		if !g.recovering do break
	}
	rise:=start_y-golem_tile(g).y
	testing.expect(t,!g.recovering,"vertical recovery should hand control back to the objective")
	testing.expect(t,rise>=12,"the golem should climb from the bottom pocket back toward its target with no material at all")
	testing.expect(t,saw_quick_clay,"the climb should use a free Quick Clay foothold at some point")
	stone_after:=0
	for tile in gs.world.terrain do if tile==.Stone do stone_after+=1
	stone_carried:=0
	for item in g.pack do if item==.Stone_Block do stone_carried+=1
	if g.carry==.Stone_Block do stone_carried+=1
	stone_dropped:=0
	for i in 0..<GRID_W*GRID_H do if gs.world.items[i]==.Stone_Block do stone_dropped+=int(gs.world.item_counts[i])
	testing.expect_value(t,stone_after+stone_carried+stone_dropped,stone_before)
}

@(test)
golem_recovery_closes_the_two_tile_seek_handoff :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	gs.delta_time=.05
	for y in 82..=87 do for x in 40..=42 do set_tile(&gs.world,x,y,.Air)
	set_tile(&gs.world,41,87,.Stone)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={41.2,87-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Seek,target={41,84},has_target=true,grounded=true,recovering=true,project_cell=-1}
	_ = golem_pack_add(g,.Stone_Block)
	start:=golem_tile(g)
	golem_update_recovery(gs,g,0)
	testing.expect(t,golem_tile(g).y<start.y,"Seek recovery must climb when still two tiles outside its one-tile reach")
	testing.expect(t,g.recovering,"the handoff happens only after the remaining reach gap is closed")
}

@(test)
quick_clay_footing_is_never_mineable_by_anyone :: proc(t:^testing.T) {
	// The old real-material foothold needed a 3-second ownership grace so a
	// neighboring worker wouldn't mine it out from under the first. Quick
	// Clay needs no such arbitration: it structurally can't be mined at all,
	// not even by its own placer, so two adjacent recovering workers each
	// building their own column can never disturb one another's footing.
	gs:=test_state(); defer free(gs)
	for y in 54..=60 do for x in 18..=23 do set_tile(&gs.world,x,y,.Air)
	for x in 18..=23 do set_tile(&gs.world,x,61,.Stone)
	left,right:=&gs.golems.data[0],&gs.golems.data[1]
	left^={status=.Deployed,level=gs.level_index,pos={20.2,61-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Seek,target={20,50},has_target=true,recovering=true,grounded=true,project_cell=-1}
	right^={status=.Deployed,level=gs.level_index,pos={21.2,61-GOLEM_H},hp=GOLEM_HP,mode=.Gather,
		job=.Seek,target={21,50},has_target=true,recovering=true,grounded=true,project_cell=-1}
	golem_update_recovery(gs,left,0)
	testing.expect_value(t,get_tile(&gs.world,20,60),Tile_Type.Quick_Clay)
	testing.expect(t,!golem_mine_tile(gs,left,{20,60},true,0),"not even its own placer can mine Quick Clay")
	golem_update_recovery(gs,right,1)
	testing.expect_value(t,get_tile(&gs.world,20,60),Tile_Type.Quick_Clay)
	testing.expect(t,is_solid(&gs.world,20,60),"the foothold remains solid to stand on")
}

@(test)
golem_quick_clay_dissolves_once_worker_moves_away :: proc(t:^testing.T) {
	gs:=test_state(); defer free(gs)
	g:=&gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20,60-GOLEM_H},hp=GOLEM_HP,mode=.Gather,grounded=true,project_cell=-1}
	golem_place_quick_clay(gs,g,0,{20,60})
	testing.expect_value(t,get_tile(&gs.world,20,60),Tile_Type.Quick_Clay)

	// Still close: a tick must not dissolve it early.
	golem_tick_quick_clay(gs)
	testing.expect_value(t,get_tile(&gs.world,20,60),Tile_Type.Quick_Clay)

	// Move the worker well away, then tick: it dissolves in a drip and frees its slot.
	g.pos = {40, 60-GOLEM_H}
	golem_tick_quick_clay(gs)
	testing.expect(t,get_tile(&gs.world,20,60)!=Tile_Type.Quick_Clay,"the foothold should dissolve once its worker moves away")
	testing.expect(t,gs.particles.count>=1,"dissolving should spawn a drip effect")
	found:=false
	for slot in gs.golem_quick_clay.blocks do if slot.active && slot.tile=={20,60} do found=true
	testing.expect(t,!found,"the pool slot should be freed")
}

@(test)
golem_sweep_clears_quick_clay_orphaned_by_a_load :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	g := &gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20,60-GOLEM_H},hp=GOLEM_HP,mode=.Gather,grounded=true,project_cell=-1}
	golem_place_quick_clay(gs,g,0,{20,60})
	testing.expect_value(t,get_tile(&gs.world,20,60),Tile_Type.Quick_Clay)

	// Golem_Quick_Clay_State is deliberately not part of Save_Data (it was
	// never "real") — a load wipes the pool exactly like this, leaving the
	// .Quick_Clay world tile (which IS saved) with no tracked owner.
	gs.golem_quick_clay = {}
	golem_sweep_orphan_quick_clay(gs)
	testing.expect(t,get_tile(&gs.world,20,60)!=Tile_Type.Quick_Clay,"an orphaned tile must not linger forever")
}

@(test)
golem_sweep_leaves_actively_tracked_quick_clay_alone :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	g := &gs.golems.data[0]
	g^={status=.Deployed,level=gs.level_index,pos={20,60-GOLEM_H},hp=GOLEM_HP,mode=.Gather,grounded=true,project_cell=-1}
	golem_place_quick_clay(gs,g,0,{20,60})

	golem_sweep_orphan_quick_clay(gs)
	testing.expect_value(t,get_tile(&gs.world,20,60),Tile_Type.Quick_Clay)
}

@(test)
golem_depot_feeds_and_collects_smelter_output :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	dt := [2]i32{90,i32(SURFACE_Y-1)}
	st := [2]i32{91,i32(SURFACE_Y-1)}
	set_tile(&gs.world,int(dt.x),int(dt.y),.Golem_Depot)
	golem_depot_on_built(gs,dt)
	d := golem_depot_at(gs,gs.level_index,dt)
	testing.expect(t,d!=nil,"built depot needs a saved record")
	golem_depot_add(d,.Iron_Ore,2); golem_depot_add(d,.Wood_Log,2)
	set_tile(&gs.world,int(st.x),int(st.y),.Smelter)
	tick_golem_depot(gs,int(dt.x),int(dt.y))
	tick_golem_depot(gs,int(dt.x),int(dt.y))
	sd := &gs.world.sim_data[grid_idx(int(st.x),int(st.y))]
	testing.expect_value(t,sd.in_item,Item.Iron_Ore)
	testing.expect_value(t,int(sd.fuel_count),2)

	gs.delta_time=SMELT_TIME
	tick_smelter(gs,int(st.x),int(st.y))
	has_bar := false
	for slot in d.slots do if slot.item==.Iron_Bar && slot.count>0 do has_bar=true
	testing.expect(t,has_bar,"adjacent depot should accept the cast bar")
}

@(test)
golem_monument_project_completes_into_infrastructure :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	gs.player.equipment[.Weapon]=.Command_Wand_Emerald
	anchor := [2]i32{100,i32(SURFACE_Y-1)}
	gs.player.pos={99,f32(SURFACE_Y)-PLAYER_H}
	testing.expect(t,golem_project_start(gs,.Golem_Depot,anchor),"emerald wand should mark a depot")
	p := &gs.golems.projects[gs.level_index]
	for c in golem_plan_table[.Golem_Depot].cells {
		T:=anchor+c.off
		set_tile(&gs.world,int(T.x),int(T.y),c.tile)
	}
	golem_project_finish_if_done(gs,p)
	testing.expect(t,p.complete,"matching every planned cell completes the monument")
	testing.expect(t,golem_depot_at(gs,gs.level_index,anchor)!=nil,"completed depot should create its storage record")
}

@(test)
build_mode_crew_fetches_and_places_a_hearth :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	gs.delta_time=.05
	gs.player.equipment[.Weapon]=.Command_Wand
	gs.player.pos={119,f32(SURFACE_Y)-PLAYER_H}
	anchor := [2]i32{120,i32(SURFACE_Y-1)}
	for y in SURFACE_Y-6..<SURFACE_Y do for x in 114..=126 do set_tile(&gs.world,x,y,.Air)
	for x in 114..=126 do set_tile(&gs.world,x,SURFACE_Y,.Grass)
	testing.expect(t,golem_project_start(gs,.Clay_Hearth,anchor),"hearth project should start")

	store := [2]i32{116,i32(SURFACE_Y-1)}
	set_tile(&gs.world,int(store.x),int(store.y),.Barrel)
	barrel_on_placed(gs,store)
	b:=barrel_at(gs,gs.level_index,store)
	barrel_deposit(b,.Stone_Block,4)
	barrel_deposit(b,.Clay,3)
	barrel_deposit(b,.Plank,4)
	barrel_deposit(b,.Iron_Bar,1)
	for i in 0..<3 {
		gs.golems.data[i]={status=.Deployed,level=gs.level_index,pos={117+f32(i)*0.7,f32(SURFACE_Y)-GOLEM_H},
			hp=GOLEM_HP,mode=.Build,facing=1,project_cell=-1}
	}
	for _ in 0..<8000 {
		update_golems(gs)
		update_gravity(gs)
		if gs.golems.projects[gs.level_index].complete do break
	}
	testing.expect(t,gs.golems.projects[gs.level_index].complete,"the crew should construct the Hearth from stored materials")
	testing.expect_value(t,get_tile(&gs.world,int(anchor.x),int(anchor.y)),Tile_Type.Clay_Hearth)
	testing.expect_value(t,barrel_total(b),0)
}

@(test)
broken_golem_is_recalled_and_repaired :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	gs.player.equipment[.Weapon]=.Command_Wand
	gs.player.pos={90,50}
	g:=&gs.golems.data[0]
	g^={status=.Broken,level=gs.level_index,pos={91,50},hp=0,carry=.Stone_Block,project_cell=-1}
	golem_recall(gs,0)
	testing.expect_value(t,g.status,Golem_Status.Carried)
	testing.expect_value(t,inventory_count(&gs.player.inventory,.Stone_Block),1)
	inventory_insert(&gs.player.inventory,.Clay,2)
	golem_hearth_use(gs)
	testing.expect_value(t,g.hp,GOLEM_HP)
	testing.expect_value(t,inventory_count(&gs.player.inventory,.Clay),0)
}

@(test)
world_anchor_preserves_a_deployed_dimension_crew :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	gs.level_index=LEVEL_DIMENSION
	gs.levels.generated[LEVEL_DIMENSION]=true
	gs.golems.data[0]={status=.Deployed,level=LEVEL_DIMENSION,hp=GOLEM_HP,project_cell=-1}
	testing.expect(t,!dimension_world_anchored(gs),"a loose crew does not anchor an ephemeral world")
	set_tile(&gs.world,20,20,.World_Anchor)
	testing.expect(t,dimension_world_anchored(gs),"the monument should anchor the active dimension")
}

// ─── Pixel Art Editor (pixel_art.odin) ─────────────────────────────────────────

@(test)
fresh_game_has_no_pixel_art_edits :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	// Every sprite must start has_data == false, or draw_pixel_grid_sprite
	// would replace the original procedural art on a clean checkout.
	for id in Pixel_Sprite_ID {
		testing.expect(t, !gs.pixel_art.sprites[id].has_data, "fresh state should have no saved pixel art")
	}
}

@(test)
pixel_sprite_dims_fit_the_fixed_grid :: proc(t: ^testing.T) {
	for id in Pixel_Sprite_ID {
		info := pixel_sprite_table[id]
		testing.expect(t, int(info.w) <= PIXEL_GRID_MAX_W, "sprite width exceeds PIXEL_GRID_MAX_W")
		testing.expect(t, int(info.h) <= PIXEL_GRID_MAX_H, "sprite height exceeds PIXEL_GRID_MAX_H")
	}
}

@(test)
pixel_art_save_and_load_round_trips :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	path :: "pixel_art_test_scratch.dat"
	defer os.remove(path)

	data := &gs.pixel_art.sprites[.Rune_Scroll_Chest]
	data.has_data = true
	data.grid[0][0] = 5
	data.grid[10][15] = 16

	testing.expect(t, save_pixel_art_to(gs, path), "save should succeed")

	loaded := new(Game_State); defer free(loaded)
	testing.expect(t, load_pixel_art_from(loaded, path), "load should succeed")
	ld := &loaded.pixel_art.sprites[.Rune_Scroll_Chest]
	testing.expect(t, ld.has_data, "loaded sprite should carry has_data through")
	testing.expect_value(t, ld.grid[0][0], u8(5))
	testing.expect_value(t, ld.grid[10][15], u8(16))
	testing.expect(t, !loaded.pixel_art.sprites[.Crafting_Bench].has_data, "untouched sprite stays unpainted")
}

@(test)
pixel_art_seed_previews_cover_the_sprite :: proc(t: ^testing.T) {
	// Regression guard for the hand-transcribed seed_*_grid / shell rect
	// tables (pixel_art.odin, render.odin): a coordinate-transform bug would
	// clip most of the art out of the declared w×h bounds silently.
	for id in Pixel_Sprite_ID {
		info := pixel_sprite_table[id]
		grid := seed_pixel_grid(id)
		painted := 0
		for row in 0 ..< int(info.h) {
			for col in 0 ..< int(info.w) {
				v := grid[row][col]
				if v == 0 do continue
				painted += 1
				testing.expect(t, int(v) <= PALETTE_SIZE, "seed painted a palette index out of range")
			}
		}
		area := int(info.w) * int(info.h)
		testing.expect(t, painted > area/3, "seeded preview should cover a meaningful fraction of the sprite")
	}
}

@(test)
pixel_art_load_rejects_missing_or_bad_file :: proc(t: ^testing.T) {
	gs := test_state(); defer free(gs)
	testing.expect(t, !load_pixel_art_from(gs, "pixel_art_test_does_not_exist.dat"), "missing file should fail load")

	path :: "pixel_art_test_garbage.dat"
	defer os.remove(path)
	garbage := []u8{1, 2, 3, 4}
	_ = os.write_entire_file(path, garbage)
	testing.expect(t, !load_pixel_art_from(gs, path), "wrong-size file should fail load")
	for id in Pixel_Sprite_ID {
		testing.expect(t, !gs.pixel_art.sprites[id].has_data, "a rejected load must not touch pixel_art")
	}
}


