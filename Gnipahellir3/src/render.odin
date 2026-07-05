package game

import rl "vendor:raylib/v55"
import "core:fmt"
import "core:math"

// ─── Draw Entry Point ─────────────────────────────────────────────────────────

draw_game :: proc(gs: ^Game_State, target: rl.RenderTexture2D) {
    // The game renders at the fixed virtual resolution...
    rl.BeginTextureMode(target)
    rl.ClearBackground(rl.BLACK)

    // World renders through the zoom camera, scaled up into the supersampled
    // texture (fold SS into the camera so gameplay/input keep the 1:1 camera).
    world_cam := game_camera(gs)
    world_cam.offset = {world_cam.offset.x * SS_SCALE, world_cam.offset.y * SS_SCALE}
    world_cam.zoom  *= SS_SCALE
    rl.BeginMode2D(world_cam)
    draw_world(&gs.world)
    draw_mining_cracks(gs)
    draw_portals(gs)
    draw_placement_ghost(gs)
    draw_player(&gs.player)
    draw_enemies(&gs.enemies)
    draw_projectiles(&gs.projectiles)
    draw_particles(&gs.particles)
    when GAME_DEBUG {
        if gs.ui.show_debug do draw_debug(gs)
    }
    rl.EndMode2D()

    // UI is screen-space (1920×1080 logical); scale it up to the SS texture.
    rl.BeginMode2D(rl.Camera2D{zoom = SS_SCALE})
    draw_ui(gs)
    rl.EndMode2D()

    rl.EndTextureMode()

    // ...then scales letterboxed onto the real window.
    scale, offset := screen_transform()
    src := rl.Rectangle{0, 0, f32(target.texture.width), -f32(target.texture.height)}  // negative height: render textures are y-flipped
    dst := rl.Rectangle{offset.x, offset.y, f32(SCREEN_W)*scale, f32(SCREEN_H)*scale}

    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)
    rl.DrawTexturePro(target.texture, src, dst, {0, 0}, 0, rl.WHITE)
    rl.EndDrawing()
}

// ─── Zoom Camera ──────────────────────────────────────────────────────────────

ZOOM_STEP :: f32(0.15)   // per mouse-wheel notch
ZOOM_MIN  :: f32(1.0)    // 1.0 = whole level (the level is exactly SCREEN_W×SCREEN_H)
ZOOM_MAX  :: f32(4.0)

// Player-centered camera, clamped so we never show past the level edges.  At
// zoom 1.0 the clamp pins it to level-center → the whole level, as before.
// Shared by render and input so both agree on the world↔screen mapping.
game_camera :: proc(gs: ^Game_State) -> rl.Camera2D {
    zoom   := max(gs.zoom, ZOOM_MIN)
    half_w := f32(SCREEN_W) * 0.5 / zoom
    half_h := f32(SCREEN_H) * 0.5 / zoom
    // Exact float player center — the supersampled texture + float sprite draw
    // let both glide sub-pixel, so no integer snapping is needed here.
    px := (gs.player.pos.x + PLAYER_W*0.5) * CELL_SIZE
    py := (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    return rl.Camera2D{
        target   = {clamp(px, half_w, f32(SCREEN_W) - half_w),
                    clamp(py, half_h, f32(SCREEN_H) - half_h)},
        offset   = {f32(SCREEN_W)*0.5, f32(SCREEN_H)*0.5},
        rotation = 0,
        zoom     = zoom,
    }
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

// Crack marks on the tile the pick is working: one diagonal per chip landed.
// Only drawn while the tile is still in pick range — stale chip state on a
// tile the player walked away from stays invisible.
draw_mining_cracks :: proc(gs: ^Game_State) {
    p := &gs.player
    if p.chip_hits == 0 { return }
    if chebyshev(p.chip_tile, player_tile(p)) > PICK_RANGE { return }

    px := p.chip_tile.x * CELL_SIZE
    py := p.chip_tile.y * CELL_SIZE
    dark := rl.Color{20, 15, 10, 220}
    rl.DrawLine(px + 2, py + 3, px + 7, py + 8, dark)
    if p.chip_hits >= 2 {
        rl.DrawLine(px + 8, py + 2, px + 3, py + 9, dark)
    }
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
    case .Garm:
        draw_garm(e)
    case .Undead, .Fire_Sprite:
        px := i32(e.pos.x * CELL_SIZE)
        py := i32(e.pos.y * CELL_SIZE)
        rl.DrawRectangle(px, py, i32(BUILDER_W * CELL_SIZE), i32(BUILDER_H * CELL_SIZE), rl.RED)
    }
}

// Garm: hulking black hound, ember eyes, hp bar overhead.
draw_garm :: proc(e: ^Enemy) {
    px := i32(e.pos.x * CELL_SIZE)
    py := i32(e.pos.y * CELL_SIZE)
    pw := i32(GARM_W * CELL_SIZE)
    ph := i32(GARM_H * CELL_SIZE)

    rl.DrawRectangle(px, py, pw, ph, rl.Color{25, 20, 30, 255})
    // Ember eyes on the facing side
    eye_y := py + ph/5
    eye_x := px + pw - pw/4 if e.facing >= 0 else px + pw/4 - 2
    rl.DrawRectangle(eye_x,     eye_y, 3, 3, rl.Color{255, 60, 20, 255})
    rl.DrawRectangle(eye_x - 5, eye_y, 3, 3, rl.Color{255, 60, 20, 255})

    // HP bar
    if e.hp < e.hp_max {
        w := i32(f32(pw) * f32(e.hp) / f32(e.hp_max))
        rl.DrawRectangle(px, py - 5, pw, 3, rl.Color{60, 0, 0, 255})
        rl.DrawRectangle(px, py - 5, w,  3, rl.Color{220, 40, 40, 255})
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

// ─── Player (pixel-art mage) ────────────────────────────────────────────────

// 8×11 ascii sprite, two walk frames. Legend: Y hair, K face, C clothing
// (left→right shaded), B boots. Ported from G2; colors come from the Player.
PLAYER_RENDER_SCALE :: 2  // sprite height in tiles — the one knob for player size
FRAME_WIDTH  :: 8
FRAME_HEIGHT :: 11

player_frames := [2][FRAME_HEIGHT][FRAME_WIDTH]rune{
    { // frame 0 — feet together
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
    { // frame 1 — mid-stride
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

player_pixel_color :: proc(p: ^Player, ch: rune, shade: f32) -> rl.Color {
    switch ch {
    case 'Y': return p.hair_color
    case 'K': return rl.Color{40, 40, 50, 255}
    case 'C': return rl.Color{
        u8(clamp(f32(p.clothing_color.r) * shade, 0, 255)),
        u8(clamp(f32(p.clothing_color.g) * shade, 0, 255)),
        u8(clamp(f32(p.clothing_color.b) * shade, 0, 255)),
        255,
    }
    case 'B': return rl.Color{110, 70, 40, 255}
    case:     return rl.BLANK
    }
}

draw_player :: proc(p: ^Player) {
    if p.dead { return }

    frame := player_frames[p.anim_frame]

    // Float world-pixel positions so the sprite glides sub-pixel under the
    // supersampled camera instead of snapping to whole tiles.
    px    := p.pos.x * CELL_SIZE
    py    := p.pos.y * CELL_SIZE
    pw_px := f32(PLAYER_W * CELL_SIZE)
    ph_px := f32(PLAYER_H * CELL_SIZE)

    // Best-fit the sprite to the collision box, then force it up to
    // PLAYER_RENDER_SCALE tiles high so the mage reads clearly.
    pixel_size := min(i32(pw_px) / FRAME_WIDTH, i32(ph_px) / FRAME_HEIGHT)
    forced_ps := i32((PLAYER_RENDER_SCALE * CELL_SIZE + FRAME_HEIGHT - 1) / FRAME_HEIGHT) // ceil
    if forced_ps > pixel_size { pixel_size = forced_ps }
    if pixel_size < 1 { pixel_size = 1 }
    ps := f32(pixel_size)

    total_w := f32(FRAME_WIDTH) * ps
    total_h := f32(FRAME_HEIGHT) * ps
    origin_x := px + (pw_px - total_w) * 0.5  // centered on the box
    origin_y := py + (ph_px - total_h)        // feet on the box floor

    bob := f32(0)
    if p.anim_frame == 1 { bob = -ps }  // little hop mid-stride

    for row in 0 ..< FRAME_HEIGHT {
        for col in 0 ..< FRAME_WIDTH {
            ch := frame[row][col]
            if ch == ' ' { continue }
            draw_col := col
            if p.facing < 0 { draw_col = FRAME_WIDTH - 1 - col }  // flip when facing left
            shade := 0.85 + f32(draw_col) / f32(FRAME_WIDTH - 1) * 0.25
            rl.DrawRectangleRec(
                {origin_x + f32(draw_col)*ps, origin_y + f32(row)*ps + bob, ps, ps},
                player_pixel_color(p, ch, shade),
            )
        }
    }

    // Tool in hand, on the leading side. Derived from what the mage actually
    // carries (mining reads its tool from the bag; the `equipped` field is
    // vestigial). Best wand wins, else the pickaxe once it's been picked up.
    held := held_tool(p)
    if held != .None {
        hand_x := origin_x + total_w - ps * 2
        if p.facing < 0 { hand_x = origin_x + ps }
        hand_y := origin_y + ps * 6
        if held == .Pickaxe {
            // Swing arc driven by the chip cooldown: struck-down at the hit,
            // recovering back up as the timer runs out.
            deg := f32(0)
            if p.mine_timer > 0 {
                sw := p.mine_timer / PICK_SWING_TIME  // 1 at the strike → 0 recovered
                deg = -30 + 60 * sw
                if p.facing < 0 { deg = -deg }
            }
            draw_pickaxe(hand_x, hand_y, ps, deg)
        } else {  // a wand tier — shaft with a tier-colored tip
            rl.DrawRectangleRec({hand_x, hand_y, ps, ps * 3}, rl.Color{90, 60, 40, 255})
            rl.DrawRectangleRec({hand_x + ps, hand_y - ps, ps, ps}, item_table[held].color)
        }
    }
}

// The implement the mage visibly holds: best wand carried, else pickaxe.
held_tool :: proc(p: ^Player) -> Item {
    switch {
    case inventory_count(&p.inventory, .Mine_Wand_Gold)   > 0: return .Mine_Wand_Gold
    case inventory_count(&p.inventory, .Mine_Wand_Silver) > 0: return .Mine_Wand_Silver
    case inventory_count(&p.inventory, .Mine_Wand)        > 0: return .Mine_Wand
    case inventory_count(&p.inventory, .Pickaxe)          > 0: return .Pickaxe
    }
    return .None
}

// Small pickaxe: wooden shaft, iron head crossbar with two drooping tips.
// Rotated `deg` degrees around the hand grip so it can swing while mining.
draw_pickaxe :: proc(x, y, s: f32, deg: f32) {
    wood  := rl.Color{140, 90, 50, 255}
    iron  := rl.Color{185, 190, 200, 255}
    pivot := rl.Vector2{x + s * 0.5, y + s * 2}  // hand grip

    // Draw a rect whose unrotated top-left is (rx,ry), spun around `pivot`.
    rot :: proc(rx, ry, w, h: f32, pivot: rl.Vector2, deg: f32, col: rl.Color) {
        rl.DrawRectanglePro(rl.Rectangle{pivot.x, pivot.y, w, h}, {pivot.x - rx, pivot.y - ry}, deg, col)
    }
    rot(x,     y - s, s,     s * 4, pivot, deg, wood)  // shaft
    rot(x - s, y - s, s * 3, s,     pivot, deg, iron)  // head crossbar
    rot(x - s, y,     s,     s,     pivot, deg, iron)  // left tip
    rot(x + s, y,     s,     s,     pivot, deg, iron)  // right tip
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

// ─── Portals ────────────────────────────────────────────────────────────────
//
//  Portals are drawn from the level_portals table, not the underlying tile, so
//  we know each one's destination and lock state.  Sky-bound gates glow bright
//  and pull in pale motes; cave gates are ominous black-red maws veined with
//  green that spew red motes inward once unlocked.

// Translucent preview of the selected placeable tile under the cursor — green
// where it would place, red where it wouldn't.  Mirrors placement_ok exactly.
draw_placement_ghost :: proc(gs: ^Game_State) {
    if gs.player.dead do return
    inv  := &gs.player.inventory
    if inv.selected < 0 do return  // nothing selected
    slot := inv.slots[inv.selected]
    if slot.item == .None || slot.count <= 0 do return
    if item_table[slot.item].place_tile == .Air do return  // not a placeable item
    if cursor_over_ui(gs) do return                         // cursor grabbed by a panel

    t  := gs.ui.hover_tile
    px := f32(t.x * CELL_SIZE)
    py := f32(t.y * CELL_SIZE)
    ok := placement_ok(gs, slot.item, int(t.x), int(t.y))

    base    := terrain_table[item_table[slot.item].place_tile].color
    fill    := ok ? rl.Color{base.r, base.g, base.b, 140} : rl.Color{200, 60, 60, 110}
    outline := ok ? rl.Color{140, 255, 160, 230}          : rl.Color{255, 90, 90, 230}
    rl.DrawRectangleRec({px, py, CELL_SIZE, CELL_SIZE}, fill)
    rl.DrawRectangleLinesEx({px, py, CELL_SIZE, CELL_SIZE}, 1, outline)
}

draw_portals :: proc(gs: ^Game_State) {
    for &p in level_portals[gs.level_index] {
        if !portal_valid(&p) do continue
        // Pixel center of the two-tile-wide gate.
        cx := (f32(p.tiles[0].x) + f32(p.tiles[1].x) + 1) * 0.5 * CELL_SIZE
        cy := (f32(p.tiles[0].y) + 0.5) * CELL_SIZE

        sky    := p.dest_level == LEVEL_SKY || gs.level_index == LEVEL_SKY
        locked := p.gate_tier >= 0 && !gs.progression.cave_unlocked[p.gate_tier]

        if sky {
            draw_sky_portal(cx, cy, gs.frame)
        } else {
            draw_cave_portal(cx, cy, gs.frame, !locked)
        }
    }

    // The dynamic sky gate a surface altar raised — blooms above the altar.
    if gs.level_index == LEVEL_SURFACE && gs.progression.sky_altar_pos != {0, 0} {
        ap := gs.progression.sky_altar_pos
        draw_sky_portal((f32(ap.x) + 0.5) * CELL_SIZE, (f32(ap.y) - 2.5) * CELL_SIZE, gs.frame)
    }
}

// Motes streaming inward on a slow elliptical spiral — the "entering the
// portal" effect.  `seed` offsets phase/angle so stacked colour streams differ.
draw_portal_inflow :: proc(cx, cy, rw, rh: f32, count: int, frame: u64, seed: f32, col: rl.Color, speed: f32) {
    for i in 0 ..< count {
        ph := f32(frame)*speed + f32(i)/f32(count) + seed
        ph -= math.floor(ph)                            // 0..1, looping
        ang := f32(i)*2.39996 + ph*2.5 + seed*6.2831853 // golden spread, spiralling in
        rr  := 1 - ph                                   // rim (ph=0) → center (ph=1)
        px  := cx + math.cos(ang)*rw*rr
        py  := cy + math.sin(ang)*rh*rr
        sz  := 1.5 + rr*2.5
        a   := u8(f32(col.a) * (0.25 + 0.75*ph))
        rl.DrawRectangleRec({px - sz*0.5, py - sz*0.5, sz, sz}, rl.Color{col.r, col.g, col.b, a})
    }
}

// Tall, bright sky gate: glowing oval, pale core, red/green/blue motes drawn in.
draw_sky_portal :: proc(cx, cy: f32, frame: u64) {
    pulse := 0.5 + 0.5*math.sin(f32(frame)*0.05)
    hw := 2.5 * f32(CELL_SIZE)   // 5 tiles wide
    hh := 5.0 * f32(CELL_SIZE)   // 10 tiles tall — a tall doorway
    cw := 1.2 * f32(CELL_SIZE)
    ch := 2.6 * f32(CELL_SIZE)

    rl.DrawEllipse(i32(cx), i32(cy), cw, ch, rl.Color{90, 150, 230, 150})
    rl.DrawEllipseLines(i32(cx), i32(cy), cw, ch, rl.Color{220, 240, 255, u8(160 + 60*pulse)})
    rl.DrawEllipseLines(i32(cx), i32(cy), hw*0.7, hh*0.7, rl.Color{150, 210, 255, u8(45 + 55*pulse)})
    rl.DrawEllipseLines(i32(cx), i32(cy), hw, hh, rl.Color{120, 200, 255, u8(70 + 70*pulse)})

    N :: 22
    draw_portal_inflow(cx, cy, hw, hh, N, frame, 0.00, rl.Color{255, 70, 70, 255},  0.010) // red
    draw_portal_inflow(cx, cy, hw, hh, N, frame, 0.33, rl.Color{70, 255, 110, 255}, 0.011) // green
    draw_portal_inflow(cx, cy, hw, hh, N, frame, 0.66, rl.Color{90, 130, 255, 255}, 0.012) // blue
}

// Tall, ominous cave gate: black maw, red ring, green veins, RGB motes when active.
draw_cave_portal :: proc(cx, cy: f32, frame: u64, active: bool) {
    pulse := 0.5 + 0.5*math.sin(f32(frame)*0.06)
    hw := 2.5 * f32(CELL_SIZE)
    hh := 5.0 * f32(CELL_SIZE)
    cw := 1.4 * f32(CELL_SIZE)
    ch := 3.0 * f32(CELL_SIZE)

    rl.DrawEllipse(i32(cx), i32(cy), cw, ch, rl.Color{12, 0, 12, 230})
    ring_a := u8(active ? (150 + 90*pulse) : 70)
    rl.DrawEllipseLines(i32(cx), i32(cy), cw, ch, rl.Color{200, 25, 25, ring_a})
    rl.DrawEllipseLines(i32(cx), i32(cy), hw, hh, rl.Color{140, 15, 40, u8(active ? 120 : 50)})

    // Green veins clawing around the maw.
    green := rl.Color{40, 200, 80, u8(active ? 160 : 80)}
    for i in 0 ..< 9 {
        ang := f32(i)/9.0 * 6.2831853 + f32(frame)*0.002
        x0  := cx + math.cos(ang)*cw*1.1
        y0  := cy + math.sin(ang)*ch*1.1
        x1  := cx + math.cos(ang + 0.35)*hw*0.8
        y1  := cy + math.sin(ang + 0.35)*hh*0.8
        x2  := cx + math.cos(ang)*hw
        y2  := cy + math.sin(ang)*hh
        rl.DrawLineEx({x0, y0}, {x1, y1}, 1.5, green)
        rl.DrawLineEx({x1, y1}, {x2, y2}, 1.5, green)
    }

    if active {
        N :: 20
        draw_portal_inflow(cx, cy, hw, hh, N, frame, 0.00, rl.Color{240, 40, 30, 255},  0.012) // red
        draw_portal_inflow(cx, cy, hw, hh, N, frame, 0.33, rl.Color{60, 220, 90, 255},  0.010) // green
        draw_portal_inflow(cx, cy, hw, hh, N, frame, 0.66, rl.Color{80, 110, 240, 255}, 0.013) // blue
    }
}
