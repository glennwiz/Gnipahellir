package game

import "core:math"

// ─── Garm — the final boss ────────────────────────────────────────────────────
//
//  Lives in the cave-3 arena (carved by gen_cave_level, depth tier 2) and
//  only awakens once sky structure C is complete (the boss gate): walls
//  cannot gate a mining game, so the SPAWN is the gate.  Spawn triggers on
//  entering cave 3 with the flag set, or on completing the ritual while
//  already inside.
//
//  The fight: Garm always hunts (builder_travel — the same battle-hardened
//  pathing the builders use), bites in close, and lobs fireballs at range.
//  Losing hp drives him through G2's project phases, recast as boss
//  mechanics: he channels them at range while fighting, one tile per tick —
//  raising a center column, sealing the arena perimeter, then flooding the
//  floor with lava.  Everything he builds is mineable stone: the player's
//  answer to every phase is the pickaxe.

GARM_W  :: f32(1.6)
GARM_H  :: f32(1.8)
GARM_HP :: 75

GARM_SPEED       :: f32(5.5)  // slower than the player (8) — fireballs punish kiting
GARM_BITE_DAMAGE :: 4
GARM_BITE_TIME   :: f32(1.0)
GARM_BITE_REACH  :: i32(2)    // chebyshev tiles, same as the player's sword

GARM_FIREBALL_DAMAGE :: 3
GARM_FIREBALL_SPEED  :: f32(12)
GARM_FIREBALL_TIME   :: f32(2.5)
GARM_FIREBALL_RANGE  :: f32(12)

// Phase thresholds and channel rates.
GARM_PHASE2_HP       :: 50         // column starts (2/3 of GARM_HP)
GARM_PHASE3_HP       :: 25         // ring starts (1/3 of GARM_HP)
GARM_COLUMN_INTERVAL :: f32(0.4)
GARM_RING_INTERVAL   :: f32(0.15)
GARM_FLOOD_INTERVAL  :: f32(0.3)
GARM_LAVA_DEPTH      :: 4          // flood stops this many rows above the floor

// Arena interior carved by gen_cave_level (depth_tier 2).
ARENA_X0 :: 150
ARENA_Y0 :: 86
ARENA_X1 :: 186
ARENA_Y1 :: 102

ARENA_CX :: (ARENA_X0 + ARENA_X1) / 2

// Column: floor up to 2 below the ceiling (the gap keeps a jump route open).
GARM_COLUMN_LEN :: ARENA_Y1 - ARENA_Y0 - 1
// Ring: left wall + right wall + top row (the floor is already solid).
GARM_RING_SIDE :: ARENA_Y1 - ARENA_Y0 + 1
GARM_RING_TOP  :: ARENA_X1 - ARENA_X0 - 1
GARM_RING_LEN  :: 2*GARM_RING_SIDE + GARM_RING_TOP
// Flood: interior columns, GARM_LAVA_DEPTH rows from the floor up.
GARM_FLOOD_ROW :: ARENA_X1 - ARENA_X0 - 1
GARM_FLOOD_LEN :: GARM_LAVA_DEPTH * GARM_FLOOD_ROW

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
    cx := f32(ARENA_CX)
    e.pos = {cx + (1 - GARM_W)*0.5, f32(ARENA_Y1) - GARM_H + 1}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "GARM awakens at (%.0f,%.0f)", e.pos.x, e.pos.y)
    notify(gs, "GARM has awoken in the depths")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Garm_Roar)}})
}

// The boss gate: called on Level_Enter (cave 3) and on Cave_Unlocked (tier 2).
garm_maybe_awaken :: proc(gs: ^Game_State) {
    if gs.level_index != LEVEL_CAVE3 { return }
    if !gs.progression.cave_unlocked[2] { return }
    if gs.progression.final_boss_defeated { return }
    if garm_present(gs) { return }
    spawn_garm(gs)
}

// ─── Phase machine ────────────────────────────────────────────────────────────

@(private = "file")
garm_enter_phase :: proc(e: ^Enemy, gs: ^Game_State, phase: Garm_Phase, msg: string) {
    e.garm.phase       = phase
    e.garm.build_i     = 0
    e.garm.build_timer = 0
    log_action(gs, "GARM phase -> %v (hp %d)", phase, e.hp)
    notify(gs, "%s", msg)
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Garm_Roar)}})
}

@(private = "file")
garm_update_phase :: proc(e: ^Enemy, gs: ^Game_State) {
    g := &e.garm

    // Hp thresholds only ever escalate; a skipped phase (burst damage) jumps
    // straight to the later one.
    target := Garm_Phase.Chase
    if e.hp <= GARM_PHASE3_HP {
        target = .Ring
    } else if e.hp <= GARM_PHASE2_HP {
        target = .Column
    }
    if target > g.phase {
        msg := "GARM raises a pillar of stone!" if target == .Column else "GARM seals the arena!"
        garm_enter_phase(e, gs, target, msg)
    }

    // The ring finishing is what breaks the ground open: flood follows.
    if g.phase == .Ring && g.build_i >= GARM_RING_LEN {
        garm_enter_phase(e, gs, .Flood, "The ground splits — lava rises!")
    }
}

// ─── Boss-magic construction ──────────────────────────────────────────────────
//
//  One tile per interval, conjured at range while Garm keeps fighting (he
//  channels; he does not commute to worksites like a builder).  Solid tiles
//  are never placed into a body — a blocked slot retries next tick, so a
//  player standing on the slot delays the structure but never dies to it.

@(private = "file")
garm_structure_tile :: proc(g: ^Garm_State) -> (T: [2]i32, tile: Tile_Type, ok: bool) {
    i := g.build_i
    #partial switch g.phase {
    case .Column:
        if i >= GARM_COLUMN_LEN { return }
        return {ARENA_CX, i32(ARENA_Y1 - i)}, .Stone, true
    case .Ring:
        if i >= GARM_RING_LEN { return }
        switch {
        case i < GARM_RING_SIDE:
            return {ARENA_X0, i32(ARENA_Y1 - i)}, .Stone, true
        case i < 2*GARM_RING_SIDE:
            return {ARENA_X1, i32(ARENA_Y1 - (i - GARM_RING_SIDE))}, .Stone, true
        case:
            return {i32(ARENA_X0 + 1 + (i - 2*GARM_RING_SIDE)), ARENA_Y0}, .Stone, true
        }
    case .Flood:
        if i >= GARM_FLOOD_LEN { return }
        row := i / GARM_FLOOD_ROW
        col := i % GARM_FLOOD_ROW
        return {i32(ARENA_X0 + 1 + col), i32(ARENA_Y1 - row)}, .Lava, true
    }
    return
}

@(private = "file")
garm_interval :: proc(phase: Garm_Phase) -> f32 {
    #partial switch phase {
    case .Column: return GARM_COLUMN_INTERVAL
    case .Ring:   return GARM_RING_INTERVAL
    }
    return GARM_FLOOD_INTERVAL
}

@(private = "file")
garm_build_tick :: proc(e: ^Enemy, gs: ^Game_State) {
    g := &e.garm
    if g.phase == .Chase { return }
    if g.build_timer > 0 { return }

    for {
        T, tile, ok := garm_structure_tile(g)
        if !ok { return }   // structure complete

        x := int(T.x)
        y := int(T.y)

        // Already satisfied (solid rock in a stone slot, lava over lava, or a
        // stone slot flooded solid earlier): skip without spending the tick.
        if tile == .Stone && is_solid(&gs.world, x, y) { g.build_i += 1; continue }
        if tile == .Lava {
            t := get_tile(&gs.world, x, y)
            if t == .Lava || is_solid(&gs.world, x, y) { g.build_i += 1; continue }
        }

        // Never conjure solid stone into a body — retry the slot next tick.
        if tile == .Stone {
            pl := &gs.player
            player_on_slot := !pl.dead &&
                f32(x) < pl.pos.x + PLAYER_W && f32(x+1) > pl.pos.x &&
                f32(y) < pl.pos.y + PLAYER_H && f32(y+1) > pl.pos.y
            if player_on_slot || builder_overlaps_tile(e, x, y) {
                g.build_timer = garm_interval(g.phase)
                return
            }
        }

        set_tile(&gs.world, x, y, tile)
        eq_push(&gs.events, Event{type = .Builder_Placed, tile = T})
        g.build_i    += 1
        g.build_timer = garm_interval(g.phase)
        return
    }
}

// ─── Smash ────────────────────────────────────────────────────────────────────
//
//  The A* plans 1-tile clearances but Garm is 1.6 wide and 1.8 tall: carve
//  the mineable tiles his body presses against in the direction of travel
//  (extra headroom, tunnel width).  Rate-limited like all mining.

@(private = "file")
garm_smash :: proc(e: ^Enemy, gs: ^Game_State) -> bool {
    if e.nav.path.cursor >= e.nav.path.len { return false }
    if e.nav.mine_timer > 0 { return false }

    target := e.nav.path.tiles[e.nav.path.cursor]
    bt     := builder_tile(e)

    // Column just ahead of the body, every row the body spans...
    ahead_x := int(e.pos.x - 0.3) if e.facing < 0 else int(e.pos.x + GARM_W + 0.3)
    check: [4][2]int
    n := 0
    for row_y := int(e.pos.y); row_y <= int(e.pos.y + GARM_H - 0.1); row_y += 1 {
        check[n] = {ahead_x, row_y}
        n += 1
    }
    // ...plus headroom above both shoulders when climbing.
    if target.y < bt.y && n < len(check) - 1 {
        check[n] = {int(e.pos.x + 0.1), int(e.pos.y) - 1}
        n += 1
        check[n] = {int(e.pos.x + GARM_W - 0.1), int(e.pos.y) - 1}
        n += 1
    }

    for i in 0 ..< n {
        cx := check[i].x
        cy := check[i].y
        if is_solid(&gs.world, cx, cy) && is_builder_mineable(&gs.world, cx, cy) &&
           !den_protected(gs, cx, cy) {
            set_tile(&gs.world, cx, cy, .Void)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = {i32(cx), i32(cy)}})
            log_action(gs, "GARM smashes (%d,%d)", cx, cy)
            e.nav.mine_timer = MINE_TIME
            e.vel.x = 0
            return true
        }
    }
    return false
}

// ─── Update ───────────────────────────────────────────────────────────────────

update_garm :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    g := &e.garm
    e.nav.mine_timer       -= dt
    e.builder.replan_timer -= dt
    g.fire_timer  -= dt
    g.bite_timer  -= dt
    g.build_timer -= dt

    garm_update_phase(e, gs)
    garm_build_tick(e, gs)

    if gs.player.dead {
        e.vel.x = 0
        return
    }

    pt := player_tile(&gs.player)
    bt := builder_tile(e)

    // Fireball: aimed at the player's center; dies on the first solid tile,
    // so cover works without an explicit line-of-sight test.
    gc := [2]f32{e.pos.x + GARM_W*0.5, e.pos.y + GARM_H*0.5}
    pc := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.5}
    d  := pc - gc
    dist := math.sqrt(d.x*d.x + d.y*d.y)
    if dist <= GARM_FIREBALL_RANGE && dist > 0.5 && g.fire_timer <= 0 {
        g.fire_timer = GARM_FIREBALL_TIME
        spawn_projectile(gs, gc, d * (GARM_FIREBALL_SPEED / dist),
            enemy_entity_id(id), GARM_FIREBALL_DAMAGE)
    }

    // Body too big for the planned corridor?  Smash through.
    if garm_smash(e, gs) { return }

    // The eternal hunt: he always knows where you are.
    if chebyshev(e.builder.plan_target, pt) > 2 {
        e.builder.plan_target = pt
        e.nav.path = {}
    }
    if builder_travel(e, id, gs, dt, pt, GARM_BITE_REACH) {
        e.facing = 1 if pt.x >= bt.x else -1
        if g.bite_timer <= 0 {
            g.bite_timer = GARM_BITE_TIME
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = enemy_entity_id(id),
                target  = PLAYER_ID,
                payload = {int_val = GARM_BITE_DAMAGE},
            })
            log_action(gs, "GARM bites the player")
        }
    }
}
