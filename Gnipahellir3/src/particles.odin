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

// Craft success: a slow ring of sparks blooms off the crafter — gold and
// rune-light woven with the crafted item's own color, drifting upward.
spawn_craft_burst :: proc(gs: ^Game_State, it: Item) {
    p := &gs.player
    center := [2]f32{p.pos.x + PLAYER_W/2, p.pos.y + PLAYER_H/2}
    RING :: 18
    for i in 0 ..< RING {
        seed  := u32(gs.frame)*17 + u32(i)*611
        angle := f32(i) * (2 * math.PI / RING)
        speed := 3 + jitter(seed, 1.5)
        vel   := [2]f32{math.cos(angle) * speed, math.sin(angle) * speed - 2}
        color := item_table[it].color
        switch i % 3 {
        case 1: color = rl.Color{255, 220, 80, 255}   // gold
        case 2: color = rl.Color{225, 185, 255, 255}  // rune-light
        }
        spawn_particle(&gs.particles, center, vel, color,
            0.6 + jitter(seed + 1, 0.2), f32(i % 5) * 0.03)
    }
}

// Smelter output: a spray of embers and a curl of smoke off the furnace mouth.
spawn_smelt_burst :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.3}
    for i in 0 ..< 8 {
        seed := u32(gs.frame)*23 + u32(i)*733
        vel  := [2]f32{jitter(seed, 2.5), -2.5 + jitter(seed + 1, 1)}
        color := rl.Color{255, 160, 40, 255} if i % 2 == 0 else rl.Color{120, 110, 100, 200}
        spawn_particle(&gs.particles, center, vel, color, 0.5 + jitter(seed + 3, 0.15))
    }
}

// A grown tree shakes loose a drift of leaves around the new crown.
spawn_grow_burst :: proc(gs: ^Game_State, T: [2]i32) {
    for i in 0 ..< 10 {
        seed := u32(gs.frame)*19 + u32(i)*457
        pos  := [2]f32{f32(T.x) + 0.5 + jitter(seed, 1.5), f32(T.y) - 3 + jitter(seed + 1, 1.5)}
        vel  := [2]f32{jitter(seed + 3, 0.8), 0.6 + jitter(seed + 5, 0.4)}
        color := rl.Color{112, 208, 88, 220} if i % 2 == 0 else rl.Color{58, 158, 48, 220}
        spawn_particle(&gs.particles, pos, vel, color, 0.9 + jitter(seed + 7, 0.3))
    }
}

// ─── Ambience ─────────────────────────────────────────────────────────────────
//
//  Stray motes of magic drifting up through each level's air, and station
//  tiles shedding the occasional rising spark in their glow color.  Random
//  tile sampling keeps it cheap: a few probes per tick over the whole grid.

AMBIENCE_INTERVAL :: 0.12
AMBIENCE_PROBES   :: 4
AMBIENCE_CHANCE   :: 30 // % of air probes that become a mote

// Mote colors per level: surface gold, cave2 cold blue, cave3 hell embers,
// sky aurora, dimension pale shimmer.
@(rodata)
level_mote_colors := [NUM_LEVELS][2]rl.Color{
    LEVEL_SURFACE   = {{255, 226, 130, 200}, {200, 240, 160, 170}},
    LEVEL_CAVE2     = {{140, 170, 230, 170}, {120, 220, 210, 150}},
    LEVEL_CAVE3     = {{255, 140, 60, 200}, {230, 70, 40, 180}},
    LEVEL_SKY       = {{170, 240, 255, 200}, {230, 190, 255, 190}},
    LEVEL_DIMENSION = {{200, 200, 225, 180}, {255, 215, 140, 160}},
}

update_ambience :: proc(gs: ^Game_State) {
    gs.ambience_timer -= gs.delta_time
    if gs.ambience_timer > 0 do return
    gs.ambience_timer = AMBIENCE_INTERVAL

    for i in 0 ..< AMBIENCE_PROBES {
        seed := u32(gs.frame)*31 + u32(i)*977
        x := int(whash(seed) % GRID_W)
        y := int(whash(seed ~ 0x9E3779B9) % GRID_H)
        t := get_tile(&gs.world, x, y)
        pos := [2]f32{f32(x) + 0.5 + jitter(seed + 3, 0.4), f32(y) + 0.5}

        if glow := station_glow[t]; glow.a != 0 {
            // A station breathes out a spark that rises and dies quickly.
            spawn_particle(&gs.particles, {pos.x, f32(y) + 0.2},
                {jitter(seed + 5, 0.5), -1.6 + jitter(seed + 7, 0.4)},
                glow, 0.9)
        } else if t == .Air && whash(seed + 11) % 100 < AMBIENCE_CHANCE {
            color := level_mote_colors[gs.level_index][int(whash(seed + 13) % 2)]
            spawn_particle(&gs.particles, pos,
                {jitter(seed + 17, 0.3), -0.35 + jitter(seed + 19, 0.15)},
                color, 3 + jitter(seed + 23, 1.5))
        }
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
