package game

import "core:testing"

// ─── A block in the caster's body does not eat the shot (card 122) ───────────
//
//  Run 7, life 3: placed Dirt sat at (107,53), inside the player's body.  The
//  orb is born at the body's center, so every shot spawned inside solid
//  terrain and burst on its first frame; a Vargr 1.5 tiles away took 16 orbs
//  and no damage.  The layout below is that one, shifted into the fire range.

// Player at (50.07,50.2) with Dirt in its center tile (50,51); the Vargr
// stands at (51.6,50) on Dirt and Stone, as it did in the run.
@(private = "file")
point_blank_fixture :: proc() -> (gs: ^Game_State, e: ^Enemy) {
    gs = new(Game_State)
    game_state_init(gs)
    gs.delta_time = 1.0 / 60.0
    gs.player.inventory.slots[TEST_HAND] = {item = .Fire_Wand, count = 1}
    gs.player.inventory.selected = TEST_HAND
    for y in 48 ..= 56 do for x in 44 ..= 68 {
        set_tile(&gs.world, x, y, .Stone if y == 52 else .Air)
    }
    gs.player.pos = {50.07, 50.2}
    set_tile(&gs.world, 50, 51, .Dirt)
    set_tile(&gs.world, 51, 51, .Dirt)
    set_tile(&gs.world, 52, 51, .Stone)

    id, ok := enemy_alloc(&gs.enemies)
    assert(ok)
    e = &gs.enemies.data[id]
    e.kind   = .Vargr
    e.hp     = 8
    e.hp_max = 8
    e.pos    = {51.6, 50}
    return
}

// Fires one orb at the tile and lets it fly; answers where it burst.
@(private = "file")
fire_at_tile :: proc(gs: ^Game_State, tx, ty: int) -> (burst: [2]i32) {
    burst = {-1, -1}
    gs.input.mouse_world = {(f32(tx) + 0.5) * CELL_SIZE, (f32(ty) + 0.5) * CELL_SIZE}
    gs.input.mine = true
    gs.player.attack_timer = 0
    update_player(gs)
    gs.input.mine = false
    for _ in 0 ..< 60 {
        update_projectiles(gs)
        for i in 0 ..< gs.events.size {
            ev := gs.events.events[(gs.events.head + i) % MAX_EVENTS]
            if ev.type == .Projectile_Impact do burst = ev.tile
        }
        process_events(gs)
        eq_clear(&gs.events)
    }
    return
}

@(test)
an_orb_born_inside_a_block_still_hits_at_point_blank :: proc(t: ^testing.T) {
    gs, e := point_blank_fixture()
    defer free(gs)

    _ = fire_at_tile(gs, 52, 50)   // the agent's aim in the run: (109,52)
    testing.expect(t, e.hp < 8, "the orb leaves the block it was born in and burns the Vargr")
    testing.expect_value(t, gs.projectiles.count, 0)
}

@(test)
only_the_birth_tile_lets_an_orb_through :: proc(t: ^testing.T) {
    gs, e := point_blank_fixture()
    defer free(gs)
    set_tile(&gs.world, 49, 51, .Stone)

    // Fired left, along row 51: out of the Dirt it was born in and straight
    // into Stone.  The next block stops it; it never reaches the far wall.
    burst := fire_at_tile(gs, 45, 51)
    testing.expect_value(t, burst, [2]i32{49, 51})
    testing.expect_value(t, gs.projectiles.count, 0)
    testing.expect_value(t, e.hp, 8)
    testing.expect_value(t, get_tile(&gs.world, 49, 51), Tile_Type.Stone)
}
