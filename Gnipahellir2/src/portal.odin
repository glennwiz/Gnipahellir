package gnipahellir

import rl "vendor:raylib"

Portal_Effect :: struct {
    active   : bool,
    x, y     : f32, // world pixel center
    time     : f32,
    max_time : f32,
}

spawn_portal :: proc(pe: ^Portal_Effect, tile_x, tile_y: int) {
    pe.active = true
    pe.time = 0
    pe.max_time = 1.0 // 1 second effect
    pe.x = cast(f32)(tile_x*TILE_SIZE + TILE_SIZE/2)
    pe.y = cast(f32)(tile_y*TILE_SIZE + TILE_SIZE/2)
}

portals_update :: proc(arr: ^[2]Portal_Effect, dt: f32) {
    for i in 0..<len(arr^) {
        p := &arr^[i]
        if !p.active do continue
        p.time += dt
        if p.time >= p.max_time { p.active = false }
    }
}

portals_render :: proc(arr: ^[2]Portal_Effect, cam_origin_x, cam_origin_y: f32) {
    for i in 0..<len(arr^) {
        p := &arr^[i]
        if !p.active do continue
        t := p.time / p.max_time
        if t < 0 { t = 0 } else if t > 1 { t = 1 }
        r := cast(f32)TILE_SIZE * (0.2 + 0.8*t) // expanding radius
        cx := cast(i32)(p.x - cam_origin_x)
        cy := cast(i32)(p.y - cam_origin_y)
        // Black core
        rl.DrawCircle(cx, cy, r*0.35, rl.BLACK)
        // Colored rims
        rl.DrawCircleLines(cx, cy, r*0.55, rl.PINK)
        rl.DrawCircleLines(cx, cy, r*0.75, rl.PURPLE)
        rl.DrawCircleLines(cx, cy, r*0.95, rl.YELLOW)
    }
}
