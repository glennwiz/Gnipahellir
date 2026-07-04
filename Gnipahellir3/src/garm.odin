package game

// ─── Garm — the final boss ────────────────────────────────────────────────────
//
//  Lives in the cave-3 arena (carved by gen_cave_level, depth tier 2) and
//  only awakens once sky structure C is complete (the boss gate): walls
//  cannot gate a mining game, so the SPAWN is the gate.  Spawn triggers on
//  entering cave 3 with the flag set, or on completing the ritual while
//  already inside.

GARM_W  :: f32(1.6)
GARM_H  :: f32(1.8)
GARM_HP :: 30

// Arena interior carved by gen_cave_level (depth_tier 2).
ARENA_X0 :: 150
ARENA_Y0 :: 86
ARENA_X1 :: 186
ARENA_Y1 :: 102

garm_present :: proc(gs: ^Game_State) -> bool {
    for i in 0 ..< MAX_ENEMIES {
        if gs.enemies.active[i] && gs.enemies.data[i].kind == .Garm { return true }
    }
    return false
}

spawn_garm :: proc(gs: ^Game_State) {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok { return }

    e := &gs.enemies.data[id]
    e.kind   = .Garm
    e.hp     = GARM_HP
    e.hp_max = GARM_HP

    // Arena center floor; the room is carved to ARENA_Y1 with stone below.
    cx := f32((ARENA_X0 + ARENA_X1) / 2)
    e.pos = {cx + (1 - GARM_W)*0.5, f32(ARENA_Y1) - GARM_H + 1}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "GARM awakens at (%.0f,%.0f)", e.pos.x, e.pos.y)
    notify(gs, "GARM has awoken in the depths")
}

// The boss gate: called on Level_Enter (cave 3) and on Cave_Unlocked (tier 2).
garm_maybe_awaken :: proc(gs: ^Game_State) {
    if gs.level_index != LEVEL_CAVE3 { return }
    if !gs.progression.cave_unlocked[2] { return }
    if gs.progression.final_boss_defeated { return }
    if garm_present(gs) { return }
    spawn_garm(gs)
}

// Boss AI lands with the phase machine (Phase 5 M4); for now Garm stands.
update_garm :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    e.vel.x = 0
}
