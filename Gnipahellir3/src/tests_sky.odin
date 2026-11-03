package game

import "core:testing"

// ─── The sky's rainbow bridge ─────────────────────────────────────────────────

RB_SEEDS := [?]u32{0, 1, 2, 7, 1234, 99991, 0xDEADBEEF}

rb_left  :: RAINBOW_CENTER_X - RAINBOW_HALF_SPAN
rb_right :: RAINBOW_CENTER_X + RAINBOW_HALF_SPAN

@(private = "file")
sky_test_state :: proc() -> ^Game_State {
    gs := new(Game_State)
    game_state_init(gs)
    gs.delta_time = 1.0 / 60.0
    return gs
}

@(test)
rainbow_bridge_joins_two_islands_on_every_seed :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    for seed in RB_SEEDS {
        gen_sky_level(&gs.world, seed)
        w := &gs.world
        // Each foot lands on its own cloud, and open air parts the islands.
        testing.expect(t, is_solid(w, rb_left - 1, RAINBOW_FOOT_Y), "left island beside the foot")
        testing.expect(t, is_solid(w, rb_right + 1, RAINBOW_FOOT_Y), "right island beside the foot")
        testing.expect_value(t, get_tile(w, rb_left + 5, RAINBOW_FOOT_Y + 1), Tile_Type.Air)
        testing.expect_value(t, get_tile(w, rb_left - RAINBOW_ISLAND_W - 1, RAINBOW_FOOT_Y), Tile_Type.Air)
        testing.expect_value(t, get_tile(w, rb_right + RAINBOW_ISLAND_W, RAINBOW_FOOT_Y), Tile_Type.Air)
        // Puffy like any cloud: one deep at the rim, deeper inside.
        outer := rb_left - RAINBOW_ISLAND_W + 1
        testing.expect_value(t, get_tile(w, outer, RAINBOW_FOOT_Y), Tile_Type.Cloud)
        testing.expect_value(t, get_tile(w, outer, RAINBOW_FOOT_Y + 1), Tile_Type.Air)
        testing.expect_value(t, get_tile(w, outer + 1, RAINBOW_FOOT_Y + 1), Tile_Type.Cloud)
        testing.expect_value(t, get_tile(w, outer + 1, RAINBOW_FOOT_Y + 2), Tile_Type.Air)
        deep := false
        for x in outer ..< rb_left do deep = deep || get_tile(w, x, RAINBOW_FOOT_Y + 2) == .Cloud
        testing.expect(t, deep, "the middle bulges three deep")
        // One unbroken deck with clear headroom, no rise a walker cannot step.
        for x in rb_left ..= rb_right {
            y := rainbow_deck_y(x)
            testing.expect_value(t, get_tile(w, x, y), Tile_Type.Rainbow_Bridge)
            for up in 1 ..= RAINBOW_HEADROOM do testing.expect_value(t, get_tile(w, x, y - up), Tile_Type.Air)
            if x > rb_left do testing.expect(t, abs(y - rainbow_deck_y(x - 1)) <= 1, "a step too tall")
        }
        testing.expect_value(t, rainbow_deck_y(RAINBOW_CENTER_X), RAINBOW_APEX_Y)
        testing.expect_value(t, rainbow_deck_y(rb_left), RAINBOW_FOOT_Y)
        testing.expect_value(t, rainbow_deck_y(rb_right), RAINBOW_FOOT_Y)
        // The way home is untouched.
        testing.expect_value(t, get_tile(w, 95, 79), Tile_Type.Sky_Entrance)
        testing.expect_value(t, get_tile(w, 96, 79), Tile_Type.Sky_Entrance)
    }
}

@(test)
a_body_stands_on_the_rainbow_and_walks_across :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    gs.level_index = LEVEL_SKY
    for seed in RB_SEEDS {
        gen_sky_level(&gs.world, seed)
        p := &gs.player

        // Dropped on the apex, it comes to rest on the deck and stays.
        p.pos = {RAINBOW_CENTER_X + 0.1, RAINBOW_APEX_Y - PLAYER_H - 1}
        p.vel = {}
        for _ in 0 ..< 120 do update_player(gs)
        testing.expect(t, p.grounded, "stands on the rainbow")
        testing.expect(t, abs(p.pos.y + PLAYER_H - RAINBOW_APEX_Y) < 0.01, "at rest on the apex")

        // Island to island, over the top.  At walking speed the span is 18 s.
        p.pos = {rb_left - 3, RAINBOW_FOOT_Y - PLAYER_H}
        p.vel = {}
        highest := p.pos.y
        gs.input.move_right = true
        for _ in 0 ..< 60 * 25 {
            update_player(gs)
            highest = min(highest, p.pos.y)
            if p.pos.x > rb_right + 2 do break
        }
        gs.input.move_right = false
        testing.expect(t, p.pos.x > rb_right + 2, "the walk reaches the far island")
        testing.expect(t, highest + PLAYER_H <= RAINBOW_APEX_Y + 0.5, "the walk goes over the top")
        testing.expect(t, p.pos.y + PLAYER_H <= RAINBOW_FOOT_Y + 0.5, "and never falls off")
    }
}

@(test)
the_rainbow_cannot_be_broken_or_looted :: proc(t: ^testing.T) {
    r := terrain_table[.Rainbow_Bridge]
    testing.expect(t, .Solid in r.flags, "it bears weight")
    testing.expect(t, .Mineable not_in r.flags, "no pick marks it")
    testing.expect(t, .Falls not_in r.flags && .Falls_Placed not_in r.flags, "it hangs in the air")
    testing.expect_value(t, r.drop_item, Item.None)
    testing.expect(t, terrain_desc[.Rainbow_Bridge] != "", "the codex can name it")
    testing.expect(t, !is_structure_tile[.Rainbow_Bridge], "not a structure")
    testing.expect_value(t, tile_draw_style[.Rainbow_Bridge], Draw_Style.Pixel_Rainbow_Bridge)
    h: i32
    for s in RAINBOW_STRIPES do h += s.h
    testing.expect_value(t, h, i32(CELL_SIZE))
}

// ─── Floating islands ─────────────────────────────────────────────────────────

@(private = "file")
sky_count :: proc(w: ^World_Grid, tt: Tile_Type) -> (n: int) {
    for i in 0 ..< GRID_W * GRID_H do if w.terrain[i] == tt do n += 1
    return
}

// An island's middle column and cloud row, as gen_sky_islands placed it.
@(private = "file")
island_middle :: proc(w: ^World_Grid, i: int, seed: u32) -> (x, row: int) {
    spot := SKY_ISLAND_SPOTS[i]
    return spot.x + int(whash(seed + u32(i) * 3571) % SKY_ISLAND_NUDGE) + SKY_ISLAND_W / 2, spot.y
}

@(test)
every_sky_has_a_tree_a_pond_and_both_nests :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    first_island: [Sky_Island_Kind]int
    for seed in RB_SEEDS {
        gen_sky_level(&gs.world, seed)
        w := &gs.world
        trees, ponds, eggs, ores: int
        for i in 0 ..< len(SKY_ISLAND_SPOTS) {
            x, row := island_middle(w, i, seed)
            on_top := get_tile(w, x, row - 1)
            kind: Sky_Island_Kind
            switch {
            case on_top == .Wood:
                trees += 1
                kind = .Tree
                testing.expect_value(t, get_tile(w, x, row - SKY_TREE_HEIGHT), Tile_Type.Wood)
                testing.expect_value(t, get_tile(w, x, row - SKY_TREE_HEIGHT - 1), Tile_Type.Leaves)
                testing.expect(t, is_solid(w, x, row), "the tree stands on cloud")
            case get_tile(w, x, row) == .Water:
                ponds += 1
                kind = .Pond
                for d in 0 ..< SKY_POND_DEPTH {
                    testing.expect(t, is_solid(w, x - SKY_POND_REACH - 1, row + d), "left wall")
                    testing.expect(t, is_solid(w, x + SKY_POND_REACH + 1, row + d), "right wall")
                }
                for px in x - SKY_POND_REACH ..= x + SKY_POND_REACH {
                    testing.expect(t, is_solid(w, px, row + SKY_POND_DEPTH), "pond floor")
                }
            case on_top == .Nest:
                eggs += 1
                kind = .Egg_Nest
                idx := grid_idx(x, row - 1)
                testing.expect_value(t, w.items[idx], Item.Sky_Egg)
                testing.expect_value(t, int(w.item_counts[idx]), SKY_NEST_EGGS)
                testing.expect_value(t, get_tile(w, x - 1, row - 1), Tile_Type.Nest)
                testing.expect_value(t, get_tile(w, x + 1, row - 1), Tile_Type.Nest)
            case on_top == .Cloud_Ore:
                ores += 1
                kind = .Ore_Nest
                testing.expect_value(t, get_tile(w, x - 1, row - 1), Tile_Type.Nest)
                testing.expect_value(t, get_tile(w, x + 1, row - 1), Tile_Type.Nest)
            }
            if i == 0 do first_island[kind] += 1
        }
        testing.expect_value(t, trees, 1)
        testing.expect_value(t, ponds, 1)
        testing.expect_value(t, eggs, 1)
        testing.expect_value(t, ores, 1)
    }
    // The deal varies with the world: the first island is not always the same.
    varied := 0
    for n in first_island do if n > 0 do varied += 1
    testing.expect(t, varied > 1, "the hash deals the islands differently")
}

@(test)
islands_leave_the_portal_and_the_rainbow_alone :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    for seed in RB_SEEDS {
        gen_sky_level(&gs.world, seed)
        w := &gs.world
        testing.expect_value(t, sky_count(w, .Sky_Entrance), 2)
        testing.expect_value(t, get_tile(w, 95, 79), Tile_Type.Sky_Entrance)
        for x in 88 ..= 104 do testing.expect_value(t, get_tile(w, x, 80), Tile_Type.Cloud)
        for x in 89 ..= 103 do testing.expect_value(t, get_tile(w, x, 81), Tile_Type.Cloud)
        // Nothing of an island reaches the band over the base.
        for y in 63 ..< GRID_H {
            for x in 0 ..< GRID_W {
                tt := get_tile(w, x, y)
                testing.expect(t, tt != .Wood && tt != .Leaves && tt != .Water && tt != .Nest, "island stuff low down")
            }
        }
        // The rainbow keeps its deck and headroom with the islands in place.
        for x in rb_left ..= rb_right {
            y := rainbow_deck_y(x)
            testing.expect_value(t, get_tile(w, x, y), Tile_Type.Rainbow_Bridge)
            for up in 1 ..= RAINBOW_HEADROOM do testing.expect_value(t, get_tile(w, x, y - up), Tile_Type.Air)
        }
        // No island sits on a band: one clear row under its cloud, so it floats.
        for i in 0 ..< len(SKY_ISLAND_SPOTS) {
            x, row := island_middle(w, i, seed)
            testing.expect_value(t, get_tile(w, x, row + 3), Tile_Type.Air)
        }
    }
}

@(test)
the_ritual_still_runs_in_a_generated_sky :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    gs.progression.sky_altar_pos = {40, 52}
    portal := sky_gate_portal(gs)
    level_transition(gs, &portal)
    testing.expect_value(t, gs.level_index, LEVEL_SKY)
    p := &gs.player
    for _ in 0 ..< 60 do update_player(gs)
    testing.expect(t, p.grounded, "the gate sets you down on the base platform")
    testing.expect(t, p.pos.y + PLAYER_H <= 80.01, "and not through it")

    gs.progression.rune_scroll_found[0] = true
    inventory_insert(&p.inventory, .Cloud_Stone, 8)
    inventory_insert(&p.inventory, .Plank, 4)
    handle_ritual_request(gs)
    testing.expect(t, gs.ritual.active, "the offering begins on the platform")
    gs.delta_time = 0.1
    for gs.ritual.active do update_ritual(gs)
    process_events(gs)
    testing.expect(t, gs.progression.sky_structure_complete[0], "structure raised")
}

// Cell by cell: a leaking pond keeps its water count while it drains away.
@(test)
ponds_and_trees_hold_in_a_live_sky :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    gs.ui.show_title = false
    gs.level_index = LEVEL_SKY
    // The surface's builders would raise their dens here: the sky has none.
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    for seed in RB_SEEDS {
        gen_sky_level(&gs.world, seed)
        gs.player.pos = {95, 80 - PLAYER_H}
        gs.player.vel = {}
        testing.expect_value(t, sky_count(&gs.world, .Water), (2*SKY_POND_REACH + 1) * SKY_POND_DEPTH)
        testing.expect_value(t, sky_count(&gs.world, .Wood), SKY_TREE_HEIGHT)
        before := gs.world.terrain
        for _ in 0 ..< 600 do game_update(gs)
        for tt, i in before {
            if tt == .Water || tt == .Wood do testing.expect_value(t, gs.world.terrain[i], tt)
        }
    }
}

@(test)
a_nest_pays_out_and_its_egg_feeds :: proc(t: ^testing.T) {
    gs := sky_test_state()
    defer free(gs)
    gs.level_index = LEVEL_SKY
    gen_sky_level(&gs.world, 7)
    w := &gs.world
    nest, ore: [2]int
    for i in 0 ..< len(SKY_ISLAND_SPOTS) {
        x, row := island_middle(w, i, 7)
        if w.items[grid_idx(x, row - 1)] == .Sky_Egg do nest = {x, row}
        if get_tile(w, x, row - 1) == .Cloud_Ore do ore = {x, row}
    }

    // Stepping in lifts the eggs, as any ground pile.
    p := &gs.player
    p.pos = {f32(nest.x) + 0.1, f32(nest.y) - PLAYER_H}
    p.vel = {}
    for _ in 0 ..< 10 {
        update_player(gs)
        process_events(gs)
    }
    testing.expect(t, p.grounded, "a body stands on the island through the twigs")
    testing.expect_value(t, inventory_count(&p.inventory, .Sky_Egg), SKY_NEST_EGGS)
    testing.expect_value(t, w.items[grid_idx(nest.x, nest.y - 1)], Item.None)

    // Eaten from the bag: a little health, refused at full.
    slot := -1
    for s, i in p.inventory.slots do if s.item == .Sky_Egg do slot = i
    testing.expect(t, item_is_consumable(.Sky_Egg), "an egg is food")
    p.hp = p.hp_max
    player_consume(gs, slot)
    testing.expect_value(t, inventory_count(&p.inventory, .Sky_Egg), SKY_NEST_EGGS)
    p.hp = p.hp_max - 10
    player_consume(gs, slot)
    testing.expect_value(t, p.hp, p.hp_max - 8)  // written out: an egg is 2 hp
    testing.expect_value(t, inventory_count(&p.inventory, .Sky_Egg), SKY_NEST_EGGS - 1)
    p.hp = p.hp_max - 1
    player_consume(gs, slot)
    testing.expect_value(t, p.hp, p.hp_max)  // never past the cap

    // The ore in the other nest mines like any vein; a bare rim pays nothing.
    testing.expect_value(t, terrain_table[.Cloud_Ore].drop_item, Item.Cloud_Stone)
    testing.expect(t, .Mineable in terrain_table[.Nest].flags, "twigs can be cleared")
    testing.expect(t, .Solid not_in terrain_table[.Nest].flags, "twigs do not block a walker")
    testing.expect_value(t, terrain_table[.Nest].drop_item, Item.None)
    testing.expect(t, terrain_desc[.Nest] != "", "the codex can name it")
    testing.expect_value(t, tile_draw_style[.Nest], Draw_Style.Pixel_Nest)
    testing.expect(t, ore != {}, "the ore nest exists")
}
