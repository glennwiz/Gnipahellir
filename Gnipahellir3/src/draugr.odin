package game

// ─── Draugr (risen builder) ─────────────────────────────────────────────────
//
//  A slain builder does not rest — it claws back up as a draugr (Enemy_Kind
//  .Undead) and hunts the player relentlessly.  It reuses the builder body and
//  the dig-aware A* wholesale (an undead miner still tunnels toward its prey),
//  but has no economy: no den, no ore, no line-of-sight give-up.  Kill it a
//  second time and it stays down, spilling the trade-goods the rise deferred.

DRAUGR_HP          :: 4          // frailer than a live builder (6) — already felled once
DRAUGR_SPEED       :: f32(10.0)  // super-fast: outruns the fleeing player (MOVE_SPEED 8.0)
DRAUGR_ATTACK_TIME :: f32(1.0)   // one heartbeat between claws — two land and you're dead

// Convert a felled builder into a draugr and RISE IT AT ITS HOME BASE: the
// corpse crawls back to the den it called home and claws its way up there.  A
// builder with no den yet (no anchor) rises where it fell.  Same slot, reborn
// to a single purpose.  Called from handle_entity_died instead of despawning.
rise_draugr :: proc(gs: ^Game_State, i: int) {
    e := &gs.enemies.data[i]
    b := &e.builder

    e.kind   = .Undead
    e.hp     = DRAUGR_HP
    e.hp_max = DRAUGR_HP
    e.vel    = {}

    // Respawn at the home den (anchor is a standable floor tile), moving the
    // entity-map marker with the body.
    if b.anchor != DEN_UNSET {
        old := builder_tile(e)
        ax, ay := snap_to_standable(&gs.world, int(b.anchor.x), int(b.anchor.y))
        e.pos = {f32(ax) + (1 - BUILDER_W)*0.5, f32(ay) - BUILDER_H + 1}
        entity_map_move(&gs.world, enemy_entity_id(i), old, builder_tile(e))
    }

    b.goal        = .Hunt
    b.carry       = .Air        // drops whatever it hauled; the pile stays where it fell
    b.attack_timer = 0
    b.los_timer   = 0
    b.stuck_timer = 0
    b.stuck_count = 0
    b.escaping    = false
    b.plan_target = {-99, -99}
    e.nav.path       = {}
    e.nav.mine_timer = 0

    log_action(gs, "Builder#%d is felled - rises as a draugr at its den", i)
    notify(gs, "The slain builder rises - a draugr!")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
}

// Relentless pursuit: the draugr always knows where the player is (undead
// sense) and paths there through rock if need be, biting on contact.  No LOS
// gate, no work to return to — it hunts until the player is dead or it is.
update_undead :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    e.nav.mine_timer -= dt
    b.replan_timer   -= dt
    b.attack_timer   -= dt

    // A stuck draugr pillars out just like a builder.
    if b.escaping {
        builder_escape_pillar(e, id, gs, dt)
        return
    }

    if gs.player.dead {
        e.vel.x = 0
        return
    }

    pt := player_tile(&gs.player)
    bt := builder_tile(e)

    // Player moved off the planned intercept — force a fresh path.
    if chebyshev(b.plan_target, pt) > 2 {
        b.plan_target = pt
        e.nav.path    = {}
    }

    if builder_travel(e, id, gs, dt, pt, 1) {
        e.facing = 1 if pt.x >= bt.x else -1
        if b.attack_timer <= 0 {
            b.attack_timer = DRAUGR_ATTACK_TIME
            // A claw costs a quarter of the player's max health, so four
            // clean strikes fell them from full (before armor blunts it).
            dmg := (gs.player.hp_max + 3) / 4
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = enemy_entity_id(id),
                target  = PLAYER_ID,
                payload = {int_val = i32(dmg)},
            })
            log_action(gs, "Draugr#%d claws the player for %d", id, dmg)
        }
    }
}
