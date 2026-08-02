package game

import rl "vendor:raylib"
import "core:fmt"

// ─── Floating Combat Text ─────────────────────────────────────────────────────
//
//  Damage numbers that pop off a struck body, drift upward and fade.  Purely
//  visual: a fixed store, no events pushed, spawned from update code (never
//  render).  World-space — drawn under the zoom camera in draw_game, so the
//  number stays pinned over the entity it belongs to.

FLOAT_TEXT_LIFETIME :: f32(0.9)   // seconds on screen
FLOAT_TEXT_RISE     :: f32(2.4)   // tiles/s the number drifts upward
FLOAT_TEXT_SIZE     :: i32(9)     // font height in world pixels

// Colour of a hit the player takes — a hot red, so damage is unmissable.
DAMAGE_COLOR :: rl.Color{255, 80, 60, 255}
// Colour of healing — a bright green, the visual opposite of damage.
HEAL_COLOR :: rl.Color{90, 220, 90, 255}

// Pop a number off a world position (tile coords).  Full store = silently
// dropped, like a lost particle.
spawn_damage_number :: proc(store: ^Floating_Text_Store, pos: [2]f32, value: int, color: rl.Color) {
    for i in 0 ..< MAX_FLOATING_TEXT {
        ft := &store.data[i]
        if ft.active { continue }
        ft^ = {pos = pos, value = value, color = color, lifetime = FLOAT_TEXT_LIFETIME, active = true}
        store.count += 1
        return
    }
}

// Step in game_update — visual only, pushes no events.
update_floating_text :: proc(gs: ^Game_State) {
    dt := gs.delta_time
    for i in 0 ..< MAX_FLOATING_TEXT {
        ft := &gs.floating_text.data[i]
        if !ft.active { continue }
        ft.age += dt
        if ft.age >= ft.lifetime {
            ft.active = false
            gs.floating_text.count = max(0, gs.floating_text.count - 1)
            continue
        }
        ft.pos.y -= FLOAT_TEXT_RISE * dt   // drift upward off the body
    }
}

// Read-only, called from render (inside the world camera pass).
draw_floating_text :: proc(store: ^Floating_Text_Store) {
    for i in 0 ..< MAX_FLOATING_TEXT {
        ft := &store.data[i]
        if !ft.active { continue }

        buf: [12]u8   // zero-initialised → keeps a NUL for the cstring
        fmt.bprintf(buf[:len(buf)-1], "%d", ft.value)
        c := cstring(raw_data(buf[:]))

        fade := clamp(1.0 - ft.age / max(ft.lifetime, 0.001), 0, 1)
        tw := rl.MeasureText(c, FLOAT_TEXT_SIZE)
        tx := i32(ft.pos.x * CELL_SIZE) - tw / 2
        ty := i32(ft.pos.y * CELL_SIZE) - FLOAT_TEXT_SIZE

        col := ft.color
        col.a = u8(f32(col.a) * fade)
        shadow := rl.Color{0, 0, 0, u8(180 * fade)}
        rl.DrawText(c, tx + 1, ty + 1, FLOAT_TEXT_SIZE, shadow)   // legibility drop-shadow
        rl.DrawText(c, tx, ty, FLOAT_TEXT_SIZE, col)
    }
}
