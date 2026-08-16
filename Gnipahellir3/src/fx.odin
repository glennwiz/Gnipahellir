package game

import rl "vendor:raylib"

// ─── Tile Effects ─────────────────────────────────────────────────────────────
//
//  Reusable world-space overlay effects: spawn one on any tile and the render
//  pass animates it there for its duration.  Transient fixed pool (never
//  saved), aged in game_update step 9c, drawn read-only in the world camera
//  pass.  New effect = a Tile_Fx_Kind member + a draw arm in draw_tile_fx;
//  spawn_tile_fx hooks it onto whatever tile the caller points at, in
//  whatever color it passes.

MAX_TILE_FX :: 32

Tile_Fx_Kind :: enum u8 {
    Ghost_Maw,   // jaws of ghost-light opening over the duration — a bite windup telegraph
    Maw_Snap,    // the chomp: jaws slammed shut, flashing out (auto-chained from Ghost_Maw)
    Fire_Charge, // a gathering ember swelling toward launch — a ranged-attack windup
    Raid_Rumble, // soot-red fault lines gathering around industry that drew a raid
}

MAW_SNAP_TIME :: f32(0.15)

Tile_Fx :: struct {
    active:   bool,
    kind:     Tile_Fx_Kind,
    tile:     [2]i32,
    age:      f32,
    duration: f32,
    color:    rl.Color,
}

Tile_Fx_Store :: struct {
    data: [MAX_TILE_FX]Tile_Fx,
}

spawn_tile_fx :: proc(gs: ^Game_State, kind: Tile_Fx_Kind, tile: [2]i32, duration: f32, color: rl.Color) {
    for &f in gs.tile_fx.data {
        if f.active { continue }
        f = {active = true, kind = kind, tile = tile, duration = duration, color = color}
        return
    }
    // Pool full: the telegraph is lost, like a dropped particle.
}

clear_tile_fx_kind :: proc(gs: ^Game_State, kind: Tile_Fx_Kind) {
    for &f in gs.tile_fx.data do if f.active && f.kind == kind do f.active = false
}

// Step 9c — visual only, pushes no events.  An expiring Ghost_Maw chains
// into its own Maw_Snap so every windup ends in a visible chomp, hit or miss.
update_tile_fx :: proc(gs: ^Game_State) {
    for &f in gs.tile_fx.data {
        if !f.active { continue }
        f.age += gs.delta_time
        if f.age >= f.duration {
            if f.kind == .Ghost_Maw {
                f.kind     = .Maw_Snap
                f.age      = 0
                f.duration = MAW_SNAP_TIME
            } else {
                f.active = false
            }
        }
    }
}

// Read-only, called from the world camera pass (after enemies, under particles).
draw_tile_fx :: proc(gs: ^Game_State) {
    for &f in gs.tile_fx.data {
        if !f.active || f.duration <= 0 { continue }
        t  := clamp(f.age / f.duration, 0, 1)
        cx := (f32(f.tile.x) + 0.5) * CELL_SIZE
        cy := (f32(f.tile.y) + 0.5) * CELL_SIZE
        switch f.kind {
        case .Ghost_Maw:
            // Jaws part wider and glow brighter as the snap nears.
            draw_ghost_maw(cx, cy, 2 + 7*t, 0.5 + 0.5*t, f.color, false)
        case .Maw_Snap:
            // Slammed shut, flashing hot at the bite line, fading out.
            draw_ghost_maw(cx, cy, 0, 1 - t, f.color, t < 0.5)
        case .Fire_Charge:
            draw_fire_charge(cx, cy, t, f.color)
        case .Raid_Rumble:
            draw_raid_rumble(cx, cy, t, f.color)
        }
    }
}

// A warning bound to the machine that attracted the raid: hard-edged fault
// lines push outward, then close back in as the tunnellers approach. The
// square pulse is deliberately terrain-like rather than a generic glow.
@(private = "file")
draw_raid_rumble :: proc(cx, cy, t: f32, col: rl.Color) {
    pulse := f32(1) if int(t * 12) % 2 == 0 else f32(0.55)
    body  := rl.Color{col.r, col.g, col.b, u8(210 * pulse)}
    glow  := rl.Color{col.r, col.g, col.b, u8(45 * pulse)}
    hot   := rl.Color{255, 185, 90, u8(235 * pulse)}
    reach := 5 + 9 * (1 - t)

    rl.DrawRectangleRec({cx - reach - 3, cy - reach - 3, (reach + 3)*2, (reach + 3)*2}, glow)
    // Four stepped cracks aimed into the hot machine.
    rl.DrawRectangleRec({cx - reach, cy - 1, reach - 2, 2}, body)
    rl.DrawRectangleRec({cx + 2, cy - 1, reach - 2, 2}, body)
    rl.DrawRectangleRec({cx - 1, cy - reach, 2, reach - 2}, body)
    rl.DrawRectangleRec({cx - 1, cy + 2, 2, reach - 2}, body)
    rl.DrawRectangleRec({cx - 2, cy - 2, 4, 4}, hot)
}

// The maw itself: two fanged jaw bars over the point, gap (px from the bite
// line to each fang tip) and alpha driven by the caller.  Pixel-built (rects
// only) in the passed color, ghost-lit; the interlocking fang offset is what
// makes a shut maw read as a bite rather than two bars.
@(private = "file")
draw_ghost_maw :: proc(cx, cy, gap, a: f32, col: rl.Color, snap: bool) {
    w  := f32(2 * CELL_SIZE)   // the maw spans two tiles — boss-sized jaws
    x0 := cx - w*0.5
    body := rl.Color{col.r, col.g, col.b, u8(170 * a)}
    dark := rl.Color{col.r / 2, col.g / 2, col.b / 2, u8(200 * a)}
    glow := rl.Color{col.r, col.g, col.b, u8(38 * a)}

    // Ghost glow behind the whole maw.
    rl.DrawRectangleRec({x0 - 3, cy - gap - 12, w + 6, gap*2 + 24}, glow)

    // Upper jaw: brow line, jaw bar, four fangs pointing down.
    uy := cy - gap - 7
    rl.DrawRectangleRec({x0, uy - 2, w, 2}, dark)
    rl.DrawRectangleRec({x0, uy, w, 3}, body)
    for i in 0 ..< 4 {
        fang_x := x0 + 2 + f32(i)*5
        rl.DrawRectangleRec({fang_x, uy + 3, 3, 2}, body)
        rl.DrawRectangleRec({fang_x + 1, uy + 5, 1, 2}, body)
    }

    // Lower jaw mirrored, fangs offset half a step so a shut maw interlocks.
    ly := cy + gap + 4
    rl.DrawRectangleRec({x0, ly, w, 3}, body)
    rl.DrawRectangleRec({x0, ly + 3, w, 2}, dark)
    for i in 0 ..< 4 {
        fang_x := x0 + 4 + f32(i)*5
        rl.DrawRectangleRec({fang_x, ly - 2, 3, 2}, body)
        rl.DrawRectangleRec({fang_x + 1, ly - 4, 1, 2}, body)
    }

    // The snap flash: a hot line where the jaws meet.
    if snap {
        rl.DrawRectangleRec({x0, cy - 1, w, 2}, rl.Color{255, 240, 255, u8(230 * a)})
    }
}

// A gathering ember: a core that swells and brightens toward launch, ringed
// by four sparks falling inward — "he is about to breathe fire."
@(private = "file")
draw_fire_charge :: proc(cx, cy, t: f32, col: rl.Color) {
    a    := 0.35 + 0.65*t
    core := 2 + 6*t
    glow := rl.Color{col.r, col.g, col.b, u8(45 * a)}
    body := rl.Color{col.r, col.g, col.b, u8(220 * a)}
    hot  := rl.Color{255, 240, 200, u8(240 * a)}

    rl.DrawRectangleRec({cx - core - 4, cy - core - 4, (core + 4)*2, (core + 4)*2}, glow)
    rl.DrawRectangleRec({cx - core, cy - core, core*2, core*2}, body)
    rl.DrawRectangleRec({cx - core*0.5, cy - core*0.5, core, core}, hot)

    // Four sparks drawn falling inward as the charge completes.
    r := 12*(1 - t) + 4
    offs := [4][2]f32{{-r, 0}, {r, 0}, {0, -r}, {0, r}}
    for o in offs {
        rl.DrawRectangleRec({cx + o.x - 1, cy + o.y - 1, 2, 2}, body)
    }
}
