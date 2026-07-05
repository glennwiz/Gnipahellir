package game

import rl "vendor:raylib/v55"
import "core:math"

// ─── Particles ────────────────────────────────────────────────────────────────
//
//  Purely visual: fixed store, no events pushed, spawned from update code
//  (never from render).  A negative age is a start delay — the particle
//  waits invisibly, which is what turns a wand burst into a stream.
//  Deterministic jitter comes from whash, not the raylib RNG.

spawn_particle :: proc(ps: ^Particle_Store, pos, vel: [2]f32, color: rl.Color, lifetime: f32, delay: f32 = 0) {
    for i in 0 ..< MAX_PARTICLES {
        p := &ps.data[i]
        if p.active { continue }
        p^ = {pos = pos, vel = vel, color = color, lifetime = lifetime, age = -delay, active = true}
        ps.count += 1
        return
    }
    // Store full: the spark is lost, nobody mourns it.
}

// Signed jitter in [-scale, +scale] from a deterministic hash.
@(private = "file")
jitter :: proc(seed: u32, scale: f32) -> f32 {
    return (f32(whash(seed) % 1024) / 512.0 - 1.0) * scale
}

// G2's wand stream: sparks fly from the player to the target tile, timed so
// the last ones arrive as the mining impact lands.
spawn_wand_stream :: proc(gs: ^Game_State, T: [2]i32) {
    from := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.35}
    to   := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}

    STREAM_COUNT :: 6
    for i in 0 ..< STREAM_COUNT {
        seed := u32(gs.frame)*31 + u32(i)*977
        t    := to + {jitter(seed, 0.3), jitter(seed + 1, 0.3)}
        d    := t - from
        vel  := d / WAND_TRAVEL_TIME
        delay := f32(i) * (WAND_TRAVEL_TIME / STREAM_COUNT) * 0.6
        spawn_particle(&gs.particles, from, vel,
            rl.Color{255, 230, 80, 255}, WAND_TRAVEL_TIME, delay)
    }
}

// Pick chips: a small fan of sparks off the struck tile.
spawn_chip_sparks :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}
    for i in 0 ..< 4 {
        seed := u32(gs.frame)*17 + u32(i)*563
        vel  := [2]f32{jitter(seed, 4), -2 + jitter(seed + 1, 2)}
        spawn_particle(&gs.particles, center, vel,
            rl.Color{255, 240, 180, 255}, 0.25)
    }
}

// Ultra-wand impact: a ring of hot sparks thrown out from the blast center.
spawn_blast_sparks :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}
    RING :: 16
    for i in 0 ..< RING {
        seed  := u32(gs.frame)*13 + u32(i)*401
        angle := f32(i) * (2 * 3.14159 / RING)
        speed := 6 + jitter(seed, 2)
        vel   := [2]f32{math.cos(angle) * speed, math.sin(angle) * speed}
        color := rl.Color{255, 160, 40, 255} if i % 2 == 0 else rl.Color{255, 230, 80, 255}
        spawn_particle(&gs.particles, center, vel, color, 0.35 + jitter(seed + 1, 0.1))
    }
}

// Step 8 in game_update — visual only, pushes no events.
update_particles :: proc(gs: ^Game_State) {
    dt := gs.delta_time
    for i in 0 ..< MAX_PARTICLES {
        p := &gs.particles.data[i]
        if !p.active { continue }
        p.age += dt
        if p.age >= p.lifetime {
            p.active = false
            gs.particles.count = max(0, gs.particles.count - 1)
            continue
        }
        if p.age >= 0 {
            p.pos += p.vel * dt
        }
    }
}

// Read-only, called from render.
draw_particles :: proc(ps: ^Particle_Store) {
    for i in 0 ..< MAX_PARTICLES {
        p := &ps.data[i]
        if !p.active || p.age < 0 { continue }
        fade := 1.0 - p.age / max(p.lifetime, 0.001)
        c := p.color
        c.a = u8(f32(c.a) * clamp(fade, 0, 1))
        rl.DrawRectangle(
            i32(p.pos.x * CELL_SIZE) - 1,
            i32(p.pos.y * CELL_SIZE) - 1,
            3, 3, c)
    }
}
