package game

import "core:testing"

// ─── A draugr with no road up pillars to its prey (card 121) ──────────────────
//
//  Run 7, life 2: the risen hero hunted a player on a ledge six tiles over its
//  head with an empty pocket.  A* plans no bridge it cannot pay for, so every
//  search came back empty, and a draugr's strikeout only dug it free of a wall
//  it was not in: it stood there 20 s, striking.

// An open hall in rock with a free-standing slab in the air, the player on the
// slab and a draugr on the floor below, its pocket empty.
@(private = "file")
slab_hall :: proc(gs: ^Game_State) -> (id: int) {
    gs.enemies = {}
    gs.wave    = {}
    gs.world.entity_map = {}
    for ty in CAVE_TOP ..< CAVE_BOT do for tx in CAVE_LEFT ..< CAVE_RIGHT do set_tile(&gs.world, tx, ty, .Stone)
    for ty in 62 ..= 80 do for tx in 40 ..= 100 do set_tile(&gs.world, tx, ty, .Void)
    for tx in 66 ..= 70 do set_tile(&gs.world, tx, 74, .Stone)
    gs.player.pos = {68.5 - PLAYER_W*0.5, 74 - PLAYER_H}
    gs.player.hp, gs.player.hp_max = 1000, 1000
    id, _ = enemy_alloc(&gs.enemies)
    e := &gs.enemies.data[id]
    e^ = Enemy{kind = .Undead, hp = DRAUGR_HP, hp_max = DRAUGR_HP, grounded = true}
    e.pos = {66 + (1 - BUILDER_W)*0.5, 81 - BUILDER_H}
    e.builder.goal = .Hunt
    e.builder.plan_target = {-99, -99}
    return
}

@(test)
a_draugr_under_a_ledge_climbs_to_the_player :: proc(t: ^testing.T) {
    gs := turret_test_state()
    defer free(gs)
    id := slab_hall(gs)
    gs.delta_time = 1.0 / 60.0
    hp := gs.player.hp
    for _ in 0 ..< 60 * 40 {
        update_enemies(gs)
        process_events(gs)
        eq_clear(&gs.events)
        if gs.player.hp < hp do break
    }
    e := &gs.enemies.data[id]
    testing.expectf(t, gs.player.hp < hp, "the draugr never clawed: it ends at (%.1f,%.1f) with the player on the slab",
        e.pos.x, e.pos.y)
}

// The pillar is for a hunt target overhead with no route: the same strikeout
// with the target at the draugr's own height raises none, since a pillar gains
// nothing, and nor does a route it walks but makes no progress on.
@(test)
a_draugr_pillars_only_toward_a_target_overhead :: proc(t: ^testing.T) {
    Row :: struct {dy: i32, reason: string, pillars: bool}
    for row in ([]Row{{-6, "no path", true}, {0, "no path", false}, {-6, "no progress", false}}) {
        gs := turret_test_state()
        defer free(gs)
        id := slab_hall(gs)
        e := &gs.enemies.data[id]
        e.builder.plan_target = builder_tile(e) + {10, row.dy}
        e.builder.stuck_count = MAX_STRIKES - 1
        builder_strike(e, id, gs, row.reason)
        testing.expectf(t, e.builder.escaping == row.pillars, "%v: escaping=%v", row, e.builder.escaping)
    }
}
