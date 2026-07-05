package gnipahellir

import rl "vendor:raylib/v55"
import "core:math"

// Simple one-off particle system for mining sparkles

MAX_PARTICLES :: 128

Particle_Type :: enum u8 {
    Spark,
    Lava_Bubble,
    Magic_Sparkle,
    Death_Explosion,
}

Particle :: struct {
    active   : bool,
    x, y     : f32,   // world pixel position
    vx, vy   : f32,
    life     : f32,
    max_life : f32,
    ptype    : Particle_Type,
}

Particles :: struct {
    data : [MAX_PARTICLES]Particle,
}

particle_spawn_spark :: proc(ps: ^Particles, wx_px, wy_px: f32) {
    spawned := 0
    for i in 0..<MAX_PARTICLES {
        if spawned >= 6 { break }
        if !ps.data[i].active {
            speed := 25 + rl.GetRandomValue(0, 35) // pixels per second
            p := &ps.data[i]
            p.active = true
            p.x = wx_px + cast(f32)rl.GetRandomValue(-3, 3)
            p.y = wy_px + cast(f32)rl.GetRandomValue(-3, 3)
            rx := rl.GetRandomValue(-100, 100)
            ry := rl.GetRandomValue(-100, 100)
            if rx == 0 && ry == 0 { ry = 1 }
            // Normalize roughly (avoid sqrt for simplicity)
            mag := cast(f32)(abs(rx) + abs(ry))
            if mag <= 0.01 { mag = 1 }
            p.vx = cast(f32)rx / mag * cast(f32)speed * 0.6
            p.vy = cast(f32)ry / mag * cast(f32)speed * 0.6
            p.life = 0
            p.max_life = 0.25 + cast(f32)rl.GetRandomValue(0, 10)/100.0 // 0.25-0.35s
            p.ptype = .Spark
            spawned += 1
        }
    }
}

// Gentle rising lava bubble (single particle, slower, longer life, upward drift)
particle_spawn_lava_bubble :: proc(ps: ^Particles, wx_px, wy_px: f32) {
    for i in 0..<MAX_PARTICLES {
        if !ps.data[i].active {
            p := &ps.data[i]
            p.active = true
            p.x = wx_px + cast(f32)rl.GetRandomValue(-4,4)
            p.y = wy_px + cast(f32)rl.GetRandomValue(-2,2)
            p.vx = cast(f32)rl.GetRandomValue(-10,10)/20.0
            p.vy = - (15 + cast(f32)rl.GetRandomValue(0,10))
            p.life = 0
            p.max_life = 0.6 + cast(f32)rl.GetRandomValue(0,20)/100.0 // 0.6-0.8s
            p.ptype = .Lava_Bubble
            break
        }
    }
}

// Purple magical sparkle (brighter, faster, more chaotic movement)
particle_spawn_magic_sparkle :: proc(ps: ^Particles, wx_px, wy_px: f32) {
    for i in 0..<MAX_PARTICLES {
        if !ps.data[i].active {
            p := &ps.data[i]
            p.active = true
            p.x = wx_px + cast(f32)rl.GetRandomValue(-6,6)
            p.y = wy_px + cast(f32)rl.GetRandomValue(-6,6)
            p.vx = cast(f32)rl.GetRandomValue(-30,30)/20.0 // more chaotic
            p.vy = - (20 + cast(f32)rl.GetRandomValue(-15,15)) // can go up or down
            p.life = 0
            p.max_life = 0.8 + cast(f32)rl.GetRandomValue(0,40)/100.0 // 0.8-1.2s longer life
            p.ptype = .Magic_Sparkle
            break
        }
    }
}

// Death explosion with purple, gold, and white sparkles
particle_spawn_death_explosion :: proc(ps: ^Particles, wx_px, wy_px: f32) {
    spawned := 0
    for i in 0..<MAX_PARTICLES {
        if spawned >= 50 { break } // Much more particles for dramatic effect
        if !ps.data[i].active {
            speed := 60 + rl.GetRandomValue(0, 80) // Much faster than normal sparks
            p := &ps.data[i]
            p.active = true
            p.x = wx_px + cast(f32)rl.GetRandomValue(-16, 16) // Larger spawn area
            p.y = wy_px + cast(f32)rl.GetRandomValue(-16, 16)
            rx := rl.GetRandomValue(-100, 100)
            ry := rl.GetRandomValue(-100, 100)
            if rx == 0 && ry == 0 { ry = 1 }
            // Normalize roughly (avoid sqrt for simplicity)
            mag := cast(f32)(abs(rx) + abs(ry))
            if mag <= 0.01 { mag = 1 }
            p.vx = cast(f32)rx / mag * cast(f32)speed * 1.2 // Faster movement
            p.vy = cast(f32)ry / mag * cast(f32)speed * 1.2
            p.life = 0
            p.max_life = 1.0 + cast(f32)rl.GetRandomValue(0, 40)/100.0 // 1.0-1.4s longer life
            p.ptype = .Death_Explosion
            spawned += 1
        }
    }
}

particles_update :: proc(ps: ^Particles, dt: f32) {
    for i in 0..<MAX_PARTICLES {
        if !ps.data[i].active do continue
        p := &ps.data[i]
        p.life += dt
        if p.life >= p.max_life {
            p.active = false
            continue
        }
        // Integrate
        p.x += p.vx * dt
        p.y += p.vy * dt
        // Light upward drift / gravity negation
        p.vy -= 20 * dt
    }
}

particles_render :: proc(ps: ^Particles, cam_origin_x, cam_origin_y: f32) {
    for i in 0..<MAX_PARTICLES {
        if !ps.data[i].active do continue
        p := &ps.data[i]
        t := p.life / p.max_life
        if t < 0 { t = 0 } else if t > 1 { t = 1 }
        alpha := cast(u8)((1.0 - t) * 255)
    // Increased base size (was 2). Adjust here if you want bigger/smaller spark particles.
    size := 8
        sx := cast(i32)(p.x - cam_origin_x)
        sy := cast(i32)(p.y - cam_origin_y)
        // Color based on particle type
        col := rl.Color{255, 240, 100, alpha} // default yellow-white
        life_ratio := t
        
        switch p.ptype {
        case .Spark:
            col = rl.Color{255, 240, 100, alpha} // yellow-white
            size = 8
        case .Lava_Bubble:
            // fade from bright orange to darker as rises
            or := 255
            og := cast(int)(140 + 80*(1-life_ratio))
            ob := 40
            if og > 255 { og = 255 }
            col = rl.Color{cast(u8)or, cast(u8)og, cast(u8)ob, alpha}
            size = 6
        case .Magic_Sparkle:
            // bright purple that pulses and shifts
            pulse := math.sin(p.life * 15) * 0.5 + 0.5 // fast pulsing
            pr := cast(int)(255 * (0.8 + 0.2*pulse))
            pg := cast(int)(100 * (0.5 + 0.5*pulse))
            pb := cast(int)(255 * (0.9 + 0.1*pulse))
            col = rl.Color{cast(u8)pr, cast(u8)pg, cast(u8)pb, alpha}
            size = 4 // smaller but brighter
        case .Death_Explosion:
            // Cycle through purple, gold, and white
            cycle := cast(int)(p.life * 8) % 3 // cycle every 0.25 seconds
            switch cycle {
            case 0: // Purple
                col = rl.Color{180, 80, 255, alpha}
            case 1: // Gold
                col = rl.Color{255, 215, 0, alpha}
            case 2: // White
                col = rl.Color{255, 255, 255, alpha}
            }
            size = 16 // much bigger for dramatic effect
        }
        rl.DrawRectangle(sx, sy, cast(i32)size, cast(i32)size, col)
    }
}
