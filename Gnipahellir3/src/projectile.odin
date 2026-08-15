package game

import rl "vendor:raylib"

// ─── Projectiles ──────────────────────────────────────────────────────────────
//
//  Straight-line shots (Garm's fireballs).  No gravity; a projectile dies on
//  a solid tile, an entity hit, lifetime expiry, or leaving the grid.  Damage
//  flows through Damage_Dealt like every other source; the owner is immune
//  to its own shot.  The store is not part of the save — projectiles in
//  flight at quit simply vanish.

PROJECTILE_LIFETIME :: f32(3.0)
PROJECTILE_RADIUS   :: f32(0.25)  // tile units; overlap test + draw size

// The void birth (Glenn's direction): every shot leaves its caster as a pure
// black orb — the body's inner void births it — and only ignites once clear
// of the body.  Hard age steps, no smooth fades: black silhouette, then a
// dark-red rim smolders in, then orange blooms, then the white-hot core —
// with a single void pixel kept at the very center, the remnant of its birth.
ORB_VOID_T   :: f32(0.10)  // pure void: black silhouette only
ORB_RIM_T    :: f32(0.20)  // dark-red rim around the black
ORB_IGNITE_T :: f32(0.28)  // orange bloom; full fire after

// Ignited orbs shed one trail ember per period — sparse on purpose, so the
// trail reads as falling embers, never a solid laser.
ORB_EMBER_PERIOD :: f32(0.09)

spawn_projectile :: proc(gs: ^Game_State, pos, vel: [2]f32, owner: Entity_ID, damage: int) {
    for i in 0 ..< MAX_PROJECTILES {
        p := &gs.projectiles.data[i]
        if p.active { continue }
        p^ = {pos = pos, vel = vel, owner = owner, active = true, damage = damage}
        gs.projectiles.count += 1
        eq_push(&gs.events, Event{
            type   = .Projectile_Fired,
            source = owner,
            tile   = {i32(pos.x), i32(pos.y)},
        })
        return
    }
    // Store full: the shot fizzles.  32 simultaneous projectiles is already
    // well past anything the boss fight produces.
}

projectile_free :: proc(ps: ^Projectile_Store, i: int) {
    ps.data[i].active = false
    ps.count = max(0, ps.count - 1)
}

// Step 4 in game_update — runs before process_events so its pushes drain
// the same frame.
update_projectiles :: proc(gs: ^Game_State) {
    dt := gs.delta_time
    for i in 0 ..< MAX_PROJECTILES {
        p := &gs.projectiles.data[i]
        if !p.active { continue }

        p.age += dt
        p.pos += p.vel * dt

        // Trail: only a lit orb burns — the black void phase sheds nothing.
        if p.age > ORB_IGNITE_T &&
           int(p.age / ORB_EMBER_PERIOD) != int((p.age - dt) / ORB_EMBER_PERIOD) {
            spawn_orb_ember(gs, p.pos)
        }

        x := int(p.pos.x)
        y := int(p.pos.y)

        if p.age > PROJECTILE_LIFETIME || !in_bounds(x, y) {
            projectile_free(&gs.projectiles, i)
            continue
        }

        if is_solid(&gs.world, x, y) {
            eq_push(&gs.events, Event{type = .Projectile_Impact, tile = {i32(x), i32(y)}})
            projectile_free(&gs.projectiles, i)
            continue
        }

        // Player hit: AABB test (the entity map only indexes center tiles,
        // too coarse for a 1.8-tall body).
        if p.owner != PLAYER_ID && !gs.player.dead {
            pl := &gs.player
            if p.pos.x + PROJECTILE_RADIUS > pl.pos.x &&
               p.pos.x - PROJECTILE_RADIUS < pl.pos.x + PLAYER_W &&
               p.pos.y + PROJECTILE_RADIUS > pl.pos.y &&
               p.pos.y - PROJECTILE_RADIUS < pl.pos.y + PLAYER_H {
                eq_push(&gs.events, Event{
                    type    = .Damage_Dealt,
                    source  = p.owner,
                    target  = PLAYER_ID,
                    payload = {int_val = i32(p.damage)},
                })
                eq_push(&gs.events, Event{type = .Projectile_Impact, tile = {i32(x), i32(y)}})
                projectile_free(&gs.projectiles, i)
                continue
            }
        }

        // Enemy hit: a direct pool scan against each body's real AABB.  The
        // entity map only indexes center tiles — an orb clipping Garm's flank
        // would fly straight through him (the same coarseness the melee
        // cursor-gating fix hit; ranged combat needs bodies, not centers).
        for ei in 0 ..< MAX_ENEMIES {
            if !gs.enemies.active[ei] { continue }
            id := enemy_entity_id(ei)
            if id == p.owner { continue }
            e := &gs.enemies.data[ei]
            size := enemy_body_size(e.kind)
            if p.pos.x + PROJECTILE_RADIUS > e.pos.x &&
               p.pos.x - PROJECTILE_RADIUS < e.pos.x + size.x &&
               p.pos.y + PROJECTILE_RADIUS > e.pos.y &&
               p.pos.y - PROJECTILE_RADIUS < e.pos.y + size.y {
                eq_push(&gs.events, Event{
                    type    = .Damage_Dealt,
                    source  = p.owner,
                    target  = id,
                    payload = {int_val = i32(p.damage)},
                })
                eq_push(&gs.events, Event{type = .Projectile_Impact, tile = {i32(x), i32(y)}})
                projectile_free(&gs.projectiles, i)
                break
            }
        }
    }
}

// Read-only, called from render.  Layered centered squares, staged by age —
// see the ORB_* constants for the birth sequence.
draw_projectiles :: proc(ps: ^Projectile_Store) {
    VOID :: rl.Color{16, 14, 22, 255}     // the wizard robe's own void-black
    RIM  :: rl.Color{150, 30, 20, 255}
    FIRE :: rl.Color{255, 120, 20, 255}
    CORE :: rl.Color{255, 240, 180, 255}
    for i in 0 ..< MAX_PROJECTILES {
        p := &ps.data[i]
        if !p.active { continue }
        px := i32(p.pos.x * CELL_SIZE)
        py := i32(p.pos.y * CELL_SIZE)
        switch {
        case p.age < ORB_VOID_T:
            rl.DrawRectangle(px - 2, py - 2, 5, 5, VOID)
        case p.age < ORB_RIM_T:
            rl.DrawRectangle(px - 3, py - 3, 7, 7, RIM)
            rl.DrawRectangle(px - 2, py - 2, 5, 5, VOID)
        case p.age < ORB_IGNITE_T:
            rl.DrawRectangle(px - 3, py - 3, 7, 7, RIM)
            rl.DrawRectangle(px - 2, py - 2, 5, 5, FIRE)
            rl.DrawRectangle(px - 1, py - 1, 3, 3, VOID)
        case:
            rl.DrawRectangle(px - 3, py - 3, 7, 7, RIM)
            rl.DrawRectangle(px - 2, py - 2, 5, 5, FIRE)
            // Two-state core flicker off the age clock — hard pixel steps,
            // no smooth pulse; the single void pixel at center stays.
            c := i32(2) if int(p.age * 24) % 2 == 0 else i32(1)
            rl.DrawRectangle(px - c, py - c, c*2 + 1, c*2 + 1, CORE)
            rl.DrawRectangle(px, py, 1, 1, VOID)
        }
    }
}
