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
