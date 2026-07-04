package game

import rl "vendor:raylib/v55"
import "core:fmt"
import "core:math"

// ─── Rendering Constants ──────────────────────────────────────────────────────

PLAYER_RENDER_SCALE :: 2  // render player at this many tiles high for visibility

// ─── Draw Entry Point ─────────────────────────────────────────────────────────

draw_game :: proc(gs: ^Game_State, target: rl.RenderTexture2D) {
    // The game renders at the fixed virtual resolution...
    rl.BeginTextureMode(target)
    rl.ClearBackground(rl.BLACK)

    draw_world(&gs.world)
    draw_portal_seals(gs)
    draw_player(&gs.player)
    draw_enemies(&gs.enemies)
    draw_ui(gs)

    when GAME_DEBUG {
        if gs.ui.show_debug do draw_debug(gs)
    }

    rl.EndTextureMode()

    // ...then scales letterboxed onto the real window.
    scale, offset := screen_transform()
    src := rl.Rectangle{0, 0, f32(SCREEN_W), -f32(SCREEN_H)}  // negative height: render textures are y-flipped
    dst := rl.Rectangle{offset.x, offset.y, f32(SCREEN_W)*scale, f32(SCREEN_H)*scale}

    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)
    rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)
    rl.EndDrawing()
}

// ─── Tile Draw Style ──────────────────────────────────────────────────────────
//
// Static/background tiles use a solid DrawRectangle (fast, simple).
// Tiles with visual detail get a dedicated draw_pixel_* proc that paints
// within the 10×10 pixel cell.  Adding a new detailed tile = new Draw_Style
// entry + new draw_pixel_* proc.  No other file changes needed.

Draw_Style :: enum u8 {
    Solid,
    Pixel_Wood,
    Pixel_Leaves,
    Pixel_Flower,
}

@(rodata)
tile_draw_style := #partial [Tile_Type]Draw_Style{
    .Wood   = .Pixel_Wood,
    .Leaves = .Pixel_Leaves,
    .Flower = .Pixel_Flower,
    // all others default to .Solid (zero value)
}

// ─── World / Terrain ──────────────────────────────────────────────────────────

draw_world :: proc(w: ^World_Grid) {
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            idx := grid_idx(x, y)
            t   := w.terrain[idx]
            px  := i32(x * CELL_SIZE)
            py  := i32(y * CELL_SIZE)
            draw_tile(t, px, py)

            // World item drop: small glinting square
            it := w.items[idx]
            if it != .None && w.item_counts[idx] > 0 {
                rl.DrawRectangle(px + 2, py + 2, 6, 6, item_table[it].color)
                rl.DrawRectangleLines(px + 1, py + 1, 8, 8, rl.WHITE)
            }
        }
    }
}

draw_tile :: proc(t: Tile_Type, px, py: i32) {
    switch tile_draw_style[t] {
    case .Pixel_Wood:   draw_pixel_wood(px, py)
    case .Pixel_Leaves: draw_pixel_leaves(px, py)
    case .Pixel_Flower: draw_pixel_flower(px, py)
    case .Solid:
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, terrain_table[t].color)
    }
}

// ─── Pixel Art: Wood (trunk) ──────────────────────────────────────────────────
//
//  base fill + two pairs of (light highlight, dark grain) vertical lines
//  giving the impression of rounded wood grain
//
//  x: 0 1 2 3 4 5 6 7 8 9
//     L D . . . L D . . .   (L=light, D=dark, .=base brown)

draw_pixel_wood :: proc(bx, by: i32) {
    base  := rl.Color{139, 90,  43, 255}
    dark  := rl.Color{ 80, 50,  15, 255}
    light := rl.Color{180, 130, 70, 255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, base)
    rl.DrawRectangle(bx+0, by, 1, CELL_SIZE, light)
    rl.DrawRectangle(bx+1, by, 1, CELL_SIZE, dark)
    rl.DrawRectangle(bx+5, by, 1, CELL_SIZE, light)
    rl.DrawRectangle(bx+6, by, 1, CELL_SIZE, dark)
}

// ─── Pixel Art: Leaves ────────────────────────────────────────────────────────
//
//  mid-green base, scattered 2×2 light highlights and dark shadow spots
//
//  light at: (2,1) (6,2) (1,5) (6,6) (3,7)
//  dark  at: (7,1) (0,3) (4,4) (5,8)

draw_pixel_leaves :: proc(bx, by: i32) {
    mid   := rl.Color{ 30, 160,  30, 255}
    light := rl.Color{ 90, 210,  60, 255}
    dark  := rl.Color{  0, 100,   0, 255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, mid)

    rl.DrawRectangle(bx+2, by+1, 2, 2, light)
    rl.DrawRectangle(bx+6, by+2, 2, 2, light)
    rl.DrawRectangle(bx+1, by+5, 2, 2, light)
    rl.DrawRectangle(bx+6, by+6, 2, 2, light)
    rl.DrawRectangle(bx+3, by+7, 2, 2, light)

    rl.DrawRectangle(bx+7, by+1, 2, 2, dark)
    rl.DrawRectangle(bx+0, by+3, 2, 2, dark)
    rl.DrawRectangle(bx+4, by+4, 2, 2, dark)
    rl.DrawRectangle(bx+5, by+8, 2, 2, dark)
}

// ─── Pixel Art: Flower ────────────────────────────────────────────────────────
//
//  air background, yellow petal ring, brown-orange center, green stem
//
//  y=0-1: ....PPPP.... <- top petal strip  (x=2..7)
//  y=2-5: PPPPCCCCPPPP <- full width, center rect (x=3..6)
//  y=6-7: ....PPPP.... <- bottom petal strip
//  y=8-9: ....SS......  <- stem (x=4..5)

draw_pixel_flower :: proc(bx, by: i32) {
    air    := terrain_table[.Air].color
    petal  := rl.Color{255, 210,  20, 255}
    center := rl.Color{180,  70,   0, 255}
    stem   := rl.Color{ 40, 130,  40, 255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, air)

    // Top petal strip
    rl.DrawRectangle(bx+2, by+0, 6, 2, petal)
    // Left + right petals (rows 2-5)
    rl.DrawRectangle(bx+0, by+2, 2, 4, petal)
    rl.DrawRectangle(bx+8, by+2, 2, 4, petal)
    // Center body (covers x=2..7, y=2..5)
    rl.DrawRectangle(bx+2, by+2, 6, 4, petal)
    // Brown-orange center over petals
    rl.DrawRectangle(bx+3, by+2, 4, 4, center)
    // Bottom petal strip
    rl.DrawRectangle(bx+2, by+6, 6, 2, petal)
    // Stem
    rl.DrawRectangle(bx+4, by+8, 2, 2, stem)
}

// ─── Enemies ──────────────────────────────────────────────────────────────────

draw_enemies :: proc(es: ^Enemy_Store) {
    for i in 0 ..< MAX_ENEMIES {
        if !es.active[i] { continue }
        draw_enemy(&es.data[i])
    }
}

draw_enemy :: proc(e: ^Enemy) {
    switch e.kind {
    case .Builder:
        draw_builder(e)
    case .Garm, .Undead, .Fire_Sprite:
        px := i32(e.pos.x * CELL_SIZE)
        py := i32(e.pos.y * CELL_SIZE)
        rl.DrawRectangle(px, py, i32(BUILDER_W * CELL_SIZE), i32(BUILDER_H * CELL_SIZE), rl.RED)
    }
}

// Draw a laser ray from the enemy center to each tile in the 3×3 grid around it.
// Solid tiles get a bright ray; air tiles get a dim one.
draw_enemy_scan :: proc(e: ^Enemy, w: ^World_Grid) {
    CS :: i32(CELL_SIZE)

    // Enemy center in pixels.
    ecx := i32((e.pos.x + BUILDER_W*0.5) * CELL_SIZE)
    ecy := i32((e.pos.y + BUILDER_H*0.5) * CELL_SIZE)

    // Tile the enemy center sits in.
    tx := int(e.pos.x + BUILDER_W*0.5)
    ty := int(e.pos.y + BUILDER_H*0.5)

    for dy in -3 ..= 2 {
        for dx in -3 ..= 2 {
            if dx == 0 && dy == 0 { continue }
            nx := tx + dx
            ny := ty + dy
            if !in_bounds(nx, ny) { continue }

            // Target: center of the scanned tile in pixels.
            tcx := i32(nx)*CS + CS/2
            tcy := i32(ny)*CS + CS/2

            col: rl.Color
            if is_solid(w, nx, ny) {
                col = rl.Color{255, 200, 50, 200}   // bright yellow — solid
            } else {
                col = rl.Color{80, 180, 255, 60}    // dim blue — air
            }
            rl.DrawLine(ecx, ecy, tcx, tcy, col)
        }
    }
}

// Builder: grey body, darker head, small shovel indicator when carrying
draw_builder :: proc(e: ^Enemy) {
    px := i32(e.pos.x * CELL_SIZE)
    py := i32(e.pos.y * CELL_SIZE)
    pw := i32(BUILDER_W * CELL_SIZE)
    ph := i32(BUILDER_H * CELL_SIZE)

    head_h := i32(CELL_SIZE / 2)
    body_h := ph - head_h

    body_color := rl.Color{120, 100, 80, 255}
    head_color := rl.Color{ 80,  60, 40, 255}

    rl.DrawRectangle(px, py + head_h, pw, body_h, body_color)
    rl.DrawRectangle(px, py,          pw, head_h, head_color)
}

// ─── Player (pixel-art) ─────────────────────────────────────────────────────

// Small 8×11 ascii pixel player
FRAME_WIDTH  :: 8
FRAME_HEIGHT :: 11

Player_Frame :: [FRAME_HEIGHT][FRAME_WIDTH]rune

player_frames : [2][FRAME_HEIGHT][FRAME_WIDTH]rune = {
    { // frame 0
        {' ',' ',' ',' ',' ',' ',' ',' '},
        {' ',' ','Y','Y',' ',' ',' ',' '},
        {' ',' ',' ','Y','Y',' ',' ',' '},
        {' ',' ','Y','Y','Y',' ',' ',' '},
        {' ','Y','K','K','K','Y',' ',' '},
        {' ','K','K','K','K','K',' ',' '},
        {'C','K','K','K','K','C','C',' '},
        {'C','C','C','C','C','C','C','C'},
        {'C','C','C','C','C','C','C','C'},
        {' ','C','C','C','C','C',' ',' '},
        {' ',' ',' ','B','B','B',' ',' '},
    },
    { // frame 1
        {' ',' ','Y',' ',' ',' ',' ',' '},
        {' ',' ',' ','Y',' ',' ',' ',' '},
        {' ',' ',' ','Y','Y',' ',' ',' '},
        {' ',' ','Y','Y','Y',' ',' ',' '},
        {' ','Y','Y','K','Y','Y',' ',' '},
        {' ','K','K','K','K','K',' ',' '},
        {'C','K','K','K','K','C','C',' '},
        {'C','C','C','C','C','C','C','C'},
        {'C','C','C','C','C','C','C','C'},
        {' ','C','C','C','C','C',' ',' '},
        {' ',' ','B','B','B',' ',' ',' '},
    },
}

player_animation_frame :: proc(p: ^Player) -> int {
    return p.anim_frame
}

player_pixel_color :: proc(p: ^Player, ch: rune, shade: f32) -> rl.Color {
    clamp := proc(v_in: f32) -> u8 {
        v := v_in
        if v < 0 { v = 0 } else if v > 255 { v = 255 }
        return cast(u8)v
    }
    switch ch {
    case 'Y': return rl.Color{p.hair_color.r, p.hair_color.g, p.hair_color.b, 255}
    case 'K': return rl.Color{40,40,50,255}
    case 'C': {
        r := cast(f32)p.clothing_color.r * shade
        g := cast(f32)p.clothing_color.g * shade
        b := cast(f32)p.clothing_color.b * shade
        return rl.Color{clamp(r), clamp(g), clamp(b), 255}
    }
    case 'B': return rl.Color{110,70,40,255}
    case: return rl.BLANK
    }
}

cell_pixel_size :: proc() -> int {
    size := CELL_SIZE/8
    if size < 1 { size = 1 }
    return size
}

// Draw player using per-character pixels, scaled to CELL_SIZE and anchored to tile
draw_player :: proc(p: ^Player) {
    // Don't draw dead player
    if p.dead { return }

    frame_index := player_animation_frame(p)
    frame := player_frames[frame_index]

    // Position in pixels (virtual render texture space)
    px := i32(p.pos[0] * CELL_SIZE)
    py := i32(p.pos[1] * CELL_SIZE)

    // Scale the 8×11 pixel sprite to best-fit the player's collision box
    pw_px := i32(cast(f32)(PLAYER_W * CELL_SIZE))
    ph_px := i32(cast(f32)(PLAYER_H * CELL_SIZE))
    ps_w := pw_px / FRAME_WIDTH
    ps_h := ph_px / FRAME_HEIGHT
    pixel_size := ps_w
    if ps_h < pixel_size { pixel_size = ps_h }
    if pixel_size < 1 { pixel_size = 1 }

    // Scale player sprite to be visible at the desired height in tiles.
    // Adjust PLAYER_RENDER_SCALE if player appears too small or too large.
    forced_ps := i32((PLAYER_RENDER_SCALE * CELL_SIZE + FRAME_HEIGHT - 1) / FRAME_HEIGHT) // ceil
    if forced_ps > pixel_size { pixel_size = forced_ps }

    total_w := FRAME_WIDTH * pixel_size
    total_h := FRAME_HEIGHT * pixel_size
    // Center horizontally inside the player's collision box and align bottom to player's feet
    origin_x := px + (pw_px - total_w)/2
    origin_y := py + (ph_px - total_h) // anchor feet

    // Small bob while animating
    bob_offset := 0
    if p.anim_frame == 1 { bob_offset = -1 }

    // Draw pixels with left-right shading
    if p.facing >= 0 {
        for row in 0..<FRAME_HEIGHT {
            for col in 0..<FRAME_WIDTH {
                ch := frame[row][col]
                if ch == ' ' do continue
                shade := 0.85 + cast(f32)col / cast(f32)(FRAME_WIDTH-1) * 0.25
                colr := player_pixel_color(p, ch, shade)
                rl.DrawRectangle(origin_x + i32(col) * i32(pixel_size), origin_y + i32(row) * i32(pixel_size) + i32(bob_offset), i32(pixel_size), i32(pixel_size), colr)
            }
        }
    } else {
        for row in 0..<FRAME_HEIGHT {
            for col in 0..<FRAME_WIDTH {
                ch := frame[row][col]
                if ch == ' ' do continue
                flipped_col := FRAME_WIDTH - 1 - col
                shade := 0.85 + cast(f32)flipped_col / cast(f32)(FRAME_WIDTH-1) * 0.25
                colr := player_pixel_color(p, ch, shade)
                rl.DrawRectangle(origin_x + i32(flipped_col) * i32(pixel_size), origin_y + i32(row) * i32(pixel_size) + i32(bob_offset), i32(pixel_size), i32(pixel_size), colr)
            }
        }
    }

    // Draw equipped item (Mine_Wand) as a small angled overlay near the player's side
    if p.equipped != .None {
        // Anchor near side facing direction
        base_y := origin_y + i32(pixel_size*6)
        base_x := origin_x + i32(total_w - pixel_size*2)
        if p.facing < 0 { base_x = origin_x + i32(pixel_size) }
        // Simple 3×5 wand pixel art when Mine_Wand
        if p.equipped == .Mine_Wand {
            // 3x5 minimal wand: handle + tip
            // Draw handle
            rl.DrawRectangle(base_x, base_y, i32(pixel_size), i32(pixel_size*3), rl.Color{120,40,180,255})
            // Draw tip (spark)
            rl.DrawRectangle(base_x + i32(pixel_size), base_y - i32(pixel_size), i32(pixel_size), i32(pixel_size), rl.Color{255,220,120,255})
        }
    }
}

// ─── Debug Overlay ────────────────────────────────────────────────────────────

draw_debug :: proc(gs: ^Game_State) {
    buf: [128]u8
    text := fmt.bprintf(buf[:], "pos:%.1f,%.1f  vel:%.1f,%.1f  frame:%d",
        gs.player.pos.x, gs.player.pos.y,
        gs.player.vel.x, gs.player.vel.y,
        gs.frame)
    rl.DrawText(cstring(raw_data(buf[:])), 4, 4, 10, rl.WHITE)

    hx := gs.ui.hover_tile.x * CELL_SIZE
    hy := gs.ui.hover_tile.y * CELL_SIZE
    rl.DrawRectangleLines(hx, hy, CELL_SIZE, CELL_SIZE, rl.YELLOW)

    draw_enemies_debug(gs)
}

CS :: CELL_SIZE  // shorthand

draw_enemies_debug :: proc(gs: ^Game_State) {
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        e := &gs.enemies.data[i]
        draw_enemy_scan(e, &gs.world)
        label_buf: [16]u8
        label := fmt.bprintf(label_buf[:], "#%d", i)
        lx := i32(e.pos.x * CS)
        ly := i32(e.pos.y * CS) - 12
        rl.DrawText(cstring(raw_data(label_buf[:])), lx, ly, 9, rl.WHITE)
    }
}
