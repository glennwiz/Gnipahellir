package game

import rl "vendor:raylib/v55"

// ─── Projectiles ──────────────────────────────────────────────────────────────
//
//  Straight-line shots (Garm's fireballs).  No gravity; a projectile dies on
//  a solid tile, an entity hit, lifetime expiry, or leaving the grid.  Damage
//  flows through Damage_Dealt like every other source; the owner is immune
//  to its own shot.  The store is not part of the save — projectiles in
//  flight at quit simply vanish.

PROJECTILE_LIFETIME :: f32(3.0)
PROJECTILE_RADIUS   :: f32(0.25)  // tile units; overlap test + draw size

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

        // Enemy hit via the entity map.
        id := gs.world.entity_map[grid_idx(x, y)]
        if id != INVALID_ENTITY && id != PLAYER_ID && id != p.owner {
            ei := entity_id_to_enemy_index(id)
            if ei >= 0 && ei < MAX_ENEMIES && gs.enemies.active[ei] {
                eq_push(&gs.events, Event{
                    type    = .Damage_Dealt,
                    source  = p.owner,
                    target  = id,
                    payload = {int_val = i32(p.damage)},
                })
                eq_push(&gs.events, Event{type = .Projectile_Impact, tile = {i32(x), i32(y)}})
                projectile_free(&gs.projectiles, i)
                continue
            }
        }
    }
}

// Read-only, called from render.
draw_projectiles :: proc(ps: ^Projectile_Store) {
    for i in 0 ..< MAX_PROJECTILES {
        p := &ps.data[i]
        if !p.active { continue }
        rl.DrawCircle(
            i32(p.pos.x * CELL_SIZE),
            i32(p.pos.y * CELL_SIZE),
            PROJECTILE_RADIUS * CELL_SIZE,
            rl.Color{255, 120, 20, 255},
        )
    }
}
