package gnipahellir

import rl "vendor:raylib/v55"

// Delayed mining action for Mine_Wand: sends small yellow projectiles that impact then mine.

WAND_MAX_PROJECTILES :: 16

Wand_Projectile :: struct {
    active    : bool,
    start_x   : f32,
    start_y   : f32,
    target_x  : f32,
    target_y  : f32,
    progress  : f32,   // 0..1 along path
    speed     : f32,   // progress per second
    size      : f32,
    start_delay : f32, // seconds before this projectile begins moving (stream effect)
}

Wand_Projectiles :: struct { data : [WAND_MAX_PROJECTILES]Wand_Projectile }

Mining_Action :: struct {
    active      : bool,
    target_tx   : int,
    target_ty   : int,
    drop_id     : Item_ID,
    travel_time : f32, // seconds to impact
    elapsed     : f32,
    target_enemy : bool, // true if targeting an enemy instead of terrain
}

wand_projectiles_spawn :: proc(wp: ^Wand_Projectiles, from_x, from_y, to_x, to_y: f32, count: int, travel_time: f32) {
    // Stagger spawning to create a visible stream rather than a burst.
    c := count
    if c > WAND_MAX_PROJECTILES { c = WAND_MAX_PROJECTILES }
    if c <= 0 do return
    spacing_progress := 1.0 / cast(f32)c
    for i in 0..<c {
        slot := -1
        for j in 0..<WAND_MAX_PROJECTILES { if !wp.data[j].active { slot = j; break } }
        if slot < 0 { break }
        p := &wp.data[slot]
        p.active = true
        p.start_x = from_x + cast(f32)rl.GetRandomValue(-3,3)
        p.start_y = from_y + cast(f32)rl.GetRandomValue(-3,3)
        p.target_x = to_x + cast(f32)rl.GetRandomValue(-2,2)
        p.target_y = to_y + cast(f32)rl.GetRandomValue(-2,2)
        p.progress = 0
        p.speed = 1.0 / travel_time * (0.85 + cast(f32)rl.GetRandomValue(0,30)/100.0)
        p.size = 2 + cast(f32)rl.GetRandomValue(0,3)
        base_delay := spacing_progress / p.speed * cast(f32)i
        jitter := (cast(f32)rl.GetRandomValue(0,15)/1000.0)
        p.start_delay = base_delay + jitter
    }
}

wand_projectiles_update :: proc(game: ^Game_State, dt: f32) {
    // Update mining action timing
    if game.mining.active {
        game.mining.elapsed += dt
        if game.mining.elapsed >= game.mining.travel_time {
            tx := game.mining.target_tx
            ty := game.mining.target_ty
            
            if game.mining.target_enemy {
                // Handle enemy damage
                if game.garm.active && enemy_at_position(&game.garm, tx, ty) {
                    died := enemy_take_damage(&game.garm, 3) // 3 damage per wand hit
                    if died {
                        // Clear enemy from entity grid
                        game.world.entities[tx][ty] = INVALID_ENTITY
                        
                        // Drop the Hell Key at Garm's location
                        if bounds_check(tx, ty) {
                            game.world.items[tx][ty] = .Hell_Key
                            game.world.item_counts[tx][ty] = 1
                        }
                        
                        // TODO: Could spawn death particles here
                    }
                }
            } else {
                // Handle terrain mining - defer world mutation to event processor
                drop := game.mining.drop_id
                _ = event_queue_push(&game.events, Event{ type = .Mining_Request, source_id = PLAYER_ID, target_id = PLAYER_ID, data = Mining_Event{ tx = tx, ty = ty, removed = .Air, drop = drop } })
            }
            
            game.mining.active = false
        }
    }

    // Update projectiles positions
    for i in 0..<WAND_MAX_PROJECTILES {
        if !game.wand_projectiles.data[i].active do continue
        p := &game.wand_projectiles.data[i]
        if p.start_delay > 0 {
            p.start_delay -= dt
            continue
        }
        p.progress += p.speed * dt
        if p.progress >= 1.0 {
            p.active = false
            continue
        }
    }
}

wand_projectiles_render :: proc(game: ^Game_State, cam_origin_x, cam_origin_y: f32) {
    for i in 0..<WAND_MAX_PROJECTILES {
        p := &game.wand_projectiles.data[i]
        if !p.active do continue
        if p.start_delay > 0 { // Not yet started: draw a faint seed at origin
            x := p.start_x
            y := p.start_y
            sx := cast(i32)(x - cam_origin_x)
            sy := cast(i32)(y - cam_origin_y)
            rl.DrawRectangle(sx, sy, cast(i32)p.size, cast(i32)p.size, rl.Color{200, 200, 60, 120})
            continue
        }
        x := p.start_x + (p.target_x - p.start_x)*p.progress
        y := p.start_y + (p.target_y - p.start_y)*p.progress
        sx := cast(i32)(x - cam_origin_x)
        sy := cast(i32)(y - cam_origin_y)
        col := rl.Color{255, 230, 80, cast(u8)(255 * (1.0 - p.progress*0.3))}
        rl.DrawRectangle(sx, sy, cast(i32)p.size, cast(i32)p.size, col)
    }
}
