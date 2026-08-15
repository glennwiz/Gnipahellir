package game

import "core:math"
import rl "vendor:raylib"

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
GARM_HP :: 140

GARM_SPEED       :: f32(5.5)  // slower than the player (8) — fireballs punish kiting
// Damage sized against the armor ladder (chestplate Defense 1/2/3/5): gold
// blunts a bite to 3 and a fireball to 2 — felt, never floored to the min-1
// chip that let a gold set face-tank the whole fight, but survivable with
// potions and footwork (the first 8/6 cut killed a gold set in ~2 s of
// trading — no chance, 2026-08-15 retest).  Rough gold-tier math: ~13 s to
// cut 140 hp at silver-sword pace vs ~3.8/s taken toe-to-toe.
GARM_BITE_DAMAGE :: 6
GARM_BITE_TIME   :: f32(1.0)
GARM_BITE_REACH  :: i32(2)    // chebyshev tiles, same as the player's sword
// The bite telegraphs: ghost jaws open over the victim for this long before
// they snap — stepping out of reach during the windup is a real dodge.  One
// timer carries the whole cycle (no new saved state): bite_timer above
// GARM_BITE_TIME = winding up, at or below = plain cooldown.  Sized to
// Glenn's rhythm spec (2026-08-15): land TWO sword swings (0.35 s apart)
// and still clear the 2-tile reach (~0.25 s at player speed) before the
// snap — punished only if you get greedy for the third.
GARM_BITE_WINDUP :: f32(0.9)
GARM_MAW_COLOR   :: rl.Color{190, 80, 255, 255}

GARM_FIREBALL_DAMAGE :: 5
GARM_FIREBALL_SPEED  :: f32(12)
GARM_FIREBALL_TIME   :: f32(2.5)
GARM_FIREBALL_RANGE  :: f32(12)
// The fireball telegraphs too: he roots and gathers ember-light over his own
// body for this long before the launch (same one-timer domain trick as the
// bite: fire_timer above GARM_FIREBALL_TIME = charging).
GARM_FIREBALL_WINDUP :: f32(0.5)
GARM_FIRE_COLOR      :: rl.Color{255, 140, 40, 255}

// Phase thresholds and channel rates.  The threshold constants are the
// fresh-spawn values (tests pin them); the live check paces off e.hp_max so
// a Garm loaded from an older save phases against his own pool.
GARM_PHASE2_HP       :: GARM_HP * 2 / 3   // column starts
GARM_PHASE3_HP       :: GARM_HP / 3       // ring starts
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

// The lair site: off-center so the phase-2 column at ARENA_CX stays clear.
GARM_DEN_X :: ARENA_CX - 10

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
    e.kind          = .Garm
    e.hp            = GARM_HP
    e.hp_max        = GARM_HP
    e.builder.build = .Lair   // his den, raised before the hunt begins

    // Arena center floor; the room is carved to ARENA_Y1 with stone below.
    cx := f32(ARENA_CX)
    e.pos = {cx + (1 - GARM_W)*0.5, f32(ARENA_Y1) - GARM_H + 1}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "GARM awakens at (%.0f,%.0f)", e.pos.x, e.pos.y)
    notify(gs, "GARM has awoken in the depths")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Garm_Roar)}})
}

// Nothing may build over the way to Hell: the gate (and the Final Seal in
// Hell itself) is terrain no masonry — builder bridge, pillar, or den
// step — ever replaces.
is_sacred_tile :: proc(t: Tile_Type) -> bool {
    return t == .Hell_Gate || t == .Final_Seal
}

// The den column's floor INSIDE the arena: where the boss raises his lair,
// and where his death tears the gate open.  find_cave_floor's first-from-
// the-top column scan used to pick the arena ROOF at GARM_DEN_X (y=85) — a
// lair, and a gate, that nobody fighting on the arena floor ever saw.
garm_den_site :: proc(w: ^World_Grid) -> (T: [2]i32, ok: bool) {
    for y in ARENA_Y0 ..< GRID_H - 1 {
        if !is_solid(w, GARM_DEN_X, y) && is_solid(w, GARM_DEN_X, y+1) {
            return {i32(GARM_DEN_X), i32(y)}, true
        }
    }
    return {}, false
}

// His death tears the way open: a two-tile walk-in gate in the heart of his
// lair — the monument he raised (or began) was always guarding it.  Only a
// Garm felled before ever choosing his den site leaves the gate on the
// floor where he happened to die.  The Hell Key he drops is what turns it —
// player_interact refuses the step without it.
garm_open_hell_gate :: proc(gs: ^Game_State, en: ^Enemy) {
    // The live den site outranks the saved anchor: an older save may carry a
    // roof-sited anchor from before garm_den_site existed, and the gate must
    // stand where the fight happens — on the arena floor.
    T: [2]i32
    if site, ok := garm_den_site(&gs.world); ok {
        T = site
    } else if en.builder.anchor != DEN_UNSET {
        T = en.builder.anchor
    } else {
        T = builder_tile(en)
    }
    gx := clamp(int(T.x), 1, GRID_W - 3)
    gy := clamp(int(T.y), 1, GRID_H - 2)
    for gy < GRID_H - 2 && !is_solid(&gs.world, gx, gy + 1) && !is_solid(&gs.world, gx + 1, gy + 1) {
        gy += 1
    }
    set_tile(&gs.world, gx, gy, .Hell_Gate)
    set_tile(&gs.world, gx + 1, gy, .Hell_Gate)
    log_action(gs, "A gate to Hell tears open at (%d,%d)", gx, gy)
    notify(gs, "Garm's fall tears a gate to Hell open at his lair - the key turns it")
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
    // straight to the later one.  Fractions of HIS OWN hp_max, not GARM_HP:
    // a Garm loaded from an older save keeps that save's smaller pool, and
    // his phases must pace against it, not against the current constant.
    target := Garm_Phase.Chase
    if e.hp <= e.hp_max / 3 {
        target = .Ring
    } else if e.hp <= e.hp_max * 2 / 3 {
        target = .Column
    }
    if target > g.phase {
        msg := "GARM raises a pillar of stone!" if target == .Column else "GARM seals the arena!"
        garm_enter_phase(e, gs, target, msg)
    }

    // The ring finishing is what breaks the ground open: flood follows.
    if g.phase == .Ring && g.build_i >= GARM_RING_LEN {
        garm_enter_phase(e, gs, .Flood, "The ground splits - lava rises!")
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
    check: [8][2]int
    n := 0
    for row_y := int(e.pos.y); row_y <= int(e.pos.y + GARM_H - 0.1); row_y += 1 {
        check[n] = {ahead_x, row_y}
        n += 1
    }
    // ...plus headroom above both shoulders when climbing...
    if target.y < bt.y && n < len(check) - 1 {
        check[n] = {int(e.pos.x + 0.1), int(e.pos.y) - 1}
        n += 1
        check[n] = {int(e.pos.x + GARM_W - 0.1), int(e.pos.y) - 1}
        n += 1
    }
    // ...plus, when he stands over a lower waypoint, the ledge lip his wide
    // body toe-catches on: solid tiles in the row under his feet.  A 1-wide
    // builder centers over the drop and falls clean; Garm's 1.6-wide span
    // overhangs the neighboring ledge corner and hangs there forever.
    over_drop := target.y > bt.y && e.grounded &&
        int(target.x) >= int(e.pos.x) && int(target.x) <= int(e.pos.x + GARM_W - 0.1)
    if over_drop && n <= len(check) - 3 {
        feet_y := int(e.pos.y + GARM_H + 0.05)
        for lip_x := int(e.pos.x); lip_x <= int(e.pos.x + GARM_W - 0.1); lip_x += 1 {
            check[n] = {lip_x, feet_y}
            n += 1
        }
    }

    for i in 0 ..< n {
        cx := check[i].x
        cy := check[i].y
        if is_solid(&gs.world, cx, cy) && is_builder_mineable(&gs.world, cx, cy) &&
           !den_protected(gs, cx, cy) {
            smash_tile(gs, cx, cy)
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

// Arm the telegraphed bite: ghost jaws open over the victim's tile, and the
// snap check at the top of update_garm lands the damage when the windup
// share of the timer runs out.
@(private = "file")
garm_bite_windup :: proc(e: ^Enemy, gs: ^Game_State) {
    e.garm.bite_timer = GARM_BITE_TIME + GARM_BITE_WINDUP
    spawn_tile_fx(gs, .Ghost_Maw, player_tile(&gs.player), GARM_BITE_WINDUP, GARM_MAW_COLOR)
}

update_garm :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    g := &e.garm
    bite_was := g.bite_timer
    fire_was := g.fire_timer
    e.nav.mine_timer       -= dt
    e.builder.replan_timer -= dt
    g.fire_timer  -= dt
    g.bite_timer  -= dt
    g.build_timer -= dt

    // The snap: the windup that opened the ghost maw ends the instant the
    // timer crosses into the plain cooldown — blood if the victim is still
    // inside reach, an empty chomp otherwise (the fx chains its own
    // Maw_Snap either way, so a dodge is SEEN to be a dodge).
    if bite_was > GARM_BITE_TIME && g.bite_timer <= GARM_BITE_TIME &&
       !gs.player.dead &&
       chebyshev(builder_tile(e), player_tile(&gs.player)) <= GARM_BITE_REACH {
        eq_push(&gs.events, Event{
            type    = .Damage_Dealt,
            source  = enemy_entity_id(id),
            target  = PLAYER_ID,
            payload = {int_val = GARM_BITE_DAMAGE},
        })
        log_action(gs, "GARM bites the player" if e.builder.den_built else "GARM bites the intruder at his lair")
    }

    // Boss-magic masonry: the shared travel executor spends pocket blocks on
    // bridges/pillars, but Garm conjures stone — he never runs out.
    e.builder.pocket = POCKET_MAX

    garm_update_phase(e, gs)
    garm_build_tick(e, gs)

    // First blood ends the ceremony: a wounded Garm abandons the half-raised
    // lair and hunts — construction never again outranks the intruder, so
    // attacking him mid-build buys a head start, not a free kill.
    if !e.builder.den_built && e.hp < e.hp_max {
        e.builder.den_built = true
        log_action(gs, "GARM abandons his lair - the hunt begins")
        notify(gs, "GARM turns from his work - he hunts you now")
        eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Garm_Roar)}})
    }

    // The lair comes first: before the eternal hunt begins, Garm raises a
    // stone den with the same machinery the builders use — walking to the
    // site, carving, placing (the material is conjured, never fetched).
    // While he works, only a player inside biting reach gets punished; the
    // hunt and the fireballs wait for a finished lair.
    if !e.builder.den_built {
        b := &e.builder
        if b.anchor == DEN_UNSET {
            // A boss dens in his arena, on its FLOOR, not wherever he
            // happens to stand (nor on the arena roof — see garm_den_site).
            if T, found := garm_den_site(&gs.world); found {
                b.anchor = T
                b.step   = 0
                log_action(gs, "GARM raises his lair at (%d,%d)", T.x, T.y)
            }
        }
        if !gs.player.dead && g.bite_timer <= 0 &&
           chebyshev(builder_tile(e), player_tile(&gs.player)) <= GARM_BITE_REACH {
            garm_bite_windup(e, gs)
        }
        if garm_smash(e, gs) { return }   // wide-body carves serve den travel too
        b.cooldown -= dt
        if b.goal == .Cooldown {
            e.vel.x = 0
            if b.cooldown <= 0 { b.goal = b.resume }
            return
        }
        builder_build_den(e, id, gs, dt)
        return
    }

    if gs.player.dead {
        e.vel.x = 0
        return
    }

    pt := player_tile(&gs.player)
    bt := builder_tile(e)

    // Fireball: aimed at the player's center; dies on the first solid tile,
    // so cover works without an explicit line-of-sight test.  Telegraphed:
    // the Fire_Charge fx gathers over his body through the windup, and the
    // launch (the timer crossing) aims at wherever the player stands at
    // that instant — the charge is the window to break line of sight.
    gc := [2]f32{e.pos.x + GARM_W*0.5, e.pos.y + GARM_H*0.5}
    pc := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.5}
    d  := pc - gc
    dist := math.sqrt(d.x*d.x + d.y*d.y)
    if fire_was > GARM_FIREBALL_TIME && g.fire_timer <= GARM_FIREBALL_TIME && dist > 0.5 {
        spawn_projectile(gs, gc, d * (GARM_FIREBALL_SPEED / dist),
            enemy_entity_id(id), GARM_FIREBALL_DAMAGE)
    }
    // Only charged against a target beyond the jaws: in biting reach the
    // bite is his close weapon — the fireball punishes range and kiting.
    if dist <= GARM_FIREBALL_RANGE && dist > 0.5 && g.fire_timer <= 0 &&
       chebyshev(bt, pt) > GARM_BITE_REACH {
        g.fire_timer = GARM_FIREBALL_TIME + GARM_FIREBALL_WINDUP
        spawn_tile_fx(gs, .Fire_Charge, builder_tile(e), GARM_FIREBALL_WINDUP, GARM_FIRE_COLOR)
    }

    // Rooted while the fire gathers — an armed bite still snaps (the check
    // at the top), but he neither walks, smashes, nor opens new jaws.
    if g.fire_timer > GARM_FIREBALL_TIME {
        e.vel.x = 0
        return
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
            garm_bite_windup(e, gs)
        }
    }
}
