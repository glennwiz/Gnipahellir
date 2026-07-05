package gnipahellir

import rl "vendor:raylib/v55"
import "core:strings"
import "core:math"
import "core:fmt"
import "core:os"
// Simple tooltip popup when hovering items/terrain

render_tooltip :: proc(game: ^Game_State) {
    // Suppress tooltip in the world grid: only show when at least one UI window/menu is open
    if !(game.ui.bag_open || game.ui.character_open || game.ui.build_menu_open || game.ui.crafting_open) do return
    id := game.ui.hover_item
    terr := game.ui.hover_terrain
    if id == .None && terr == .Air do return
    txt : cstring
    if id != .None { txt = item_name(id) }
    else { txt = terrain_name(terr) }
    mx := game.ui.tooltip_x
    my := game.ui.tooltip_y
    pad := 4
    fs := 14
    w := int(rl.MeasureText(txt, cast(i32)fs)) + pad*2
    h := fs + pad*2
    // Adjust to keep on screen
    sw := int(rl.GetScreenWidth()); sh := int(rl.GetScreenHeight())
    if mx + w > sw { mx = sw - w - 4 }
    if my + h > sh { my = sh - h - 4 }
    rl.DrawRectangle(cast(i32)mx, cast(i32)my, cast(i32)w, cast(i32)h, rl.Color{20,20,25,230})
    draw_tile_outline_rectangle(cast(i32)mx, cast(i32)my, cast(i32)w, cast(i32)h, rl.GOLD)
    rl.DrawText(txt, cast(i32)(mx+pad), cast(i32)(my+pad-1), cast(i32)fs, rl.WHITE)
}

// Helper to test if a screen point is inside any open UI window (for drag-drop)
point_in_any_window :: proc(game: ^Game_State, x, y: int) -> bool {
    // Inventory
    if game.ui.bag_open {
        if x >= game.ui.inv_x && x < game.ui.inv_x+INVENTORY_W && y >= game.ui.inv_y && y < game.ui.inv_y+INVENTORY_H do return true
    }
    if game.ui.character_open {
        if x >= game.ui.char_x && x < game.ui.char_x+CHARACTER_W && y >= game.ui.char_y && y < game.ui.char_y+CHARACTER_H do return true
    }
    if game.ui.build_menu_open {
        if x >= game.ui.build_x && x < game.ui.build_x+BUILD_MENU_W && y >= game.ui.build_y && y < game.ui.build_y+BUILD_MENU_H do return true
    }
    if game.ui.crafting_open {
        if x >= game.ui.craft_x && x < game.ui.craft_x+CRAFT_MENU_W && y >= game.ui.craft_y && y < game.ui.craft_y+CRAFT_MENU_H do return true
    }
    if game.ui.sound_debug_open {
        // Sound debug window covers most of the screen
        screen_w := cast(int)rl.GetScreenWidth()
        screen_h := cast(int)rl.GetScreenHeight()
        if x >= 50 && x < screen_w-50 && y >= 50 && y < screen_h-50 do return true
    }
    return false
}

// Simple terrain color map
terrain_color :: proc(t: Terrain_Type) -> rl.Color {
    switch t {
    case .Air: return rl.Color{40,60,110,255} // sky
    case .Void: return rl.Color{10,10,20,255} // underground open space (darker)
    case .Grass: return rl.Color{34,139,34,255}
    case .Stone: return rl.GRAY
    case .Water: return rl.BLUE
    case .Lava:  return rl.Color{255,100,20,255} // hotter orange
    case .Magic_Lava: return rl.Color{200,50,255,255} // purple/magenta
    case .Wood:  return rl.BROWN
    case .Leaves: return rl.Color{34,180,34,255}
    case .Crafting_Bench: return rl.Color{139,69,19,255}
    case .Tree_Grower: return rl.Color{160,82,45,255}
    case .Iron: return rl.Color{150,150,170,255}
    case .Silver: return rl.Color{190,190,220,255}
    case .Gold: return rl.Color{220,180,40,255}
    case .Gold_Rare: return rl.Color{255,240,120,255}
    case .Smelter: return rl.Color{100,100,110,255}
    case .Cave_Entrance: return rl.Color{15,15,30,255} // Dark, ominous entrance to Gnipahellir
    }
    return rl.BLACK
}

// Pixel-aligned tile outline (workaround for DrawRectangleLines misalignment on some platforms)
draw_tile_outline :: proc(screen_x, screen_y: int, color: rl.Color) {
    left   := cast(i32)screen_x
    top    := cast(i32)screen_y
    right  := cast(i32)(screen_x + TILE_SIZE)
    bottom := cast(i32)(screen_y + TILE_SIZE)
    // Order: top, left, right, bottom (avoid overdrawing corners too much)
    rl.DrawLine(left, top, right, top, color)
    rl.DrawLine(left, top, left, bottom, color)
    rl.DrawLine(right, top, right, bottom, color)
    rl.DrawLine(left, bottom, right, bottom, color)
}

draw_tile_outline_rectangle :: proc(screen_x, screen_y, l, h:i32,color: rl.Color) {
    left   := cast(i32)screen_x
    top    := cast(i32)screen_y
    right  := cast(i32)(screen_x + l)
    bottom := cast(i32)(screen_y + h)
    // Order: top, left, right, bottom (avoid overdrawing corners too much)
    rl.DrawLine(left, top, right, top, color)
    rl.DrawLine(left, top, left, bottom, color)
    rl.DrawLine(right, top, right, bottom, color)
    rl.DrawLine(left, bottom, right, bottom, color)
}

update_camera :: proc(game: ^Game_State, dt: f32) {
    // Smooth follow only while player is moving; when player stops, camera stays where it last was.
    desired_x := game.player.visual_x*TILE_SIZE
    desired_y := game.player.visual_y*TILE_SIZE
    speed_sq := game.player.vel_x*game.player.vel_x + game.player.vel_y*game.player.vel_y
    if speed_sq < 0.0001 { // player effectively stopped -> freeze camera (no snapping)
        return
    }
    damping : f32 = 7.0
    alpha := 1 - math.exp(-damping*dt)
    dx := desired_x - game.camera.target_x
    dy := desired_y - game.camera.target_y
    // Dead zone keeps micro jitter absent while moving
    dead : f32 = 0.25
    if math.abs(dx) < dead { dx = 0 }
    if math.abs(dy) < dead { dy = 0 }
    game.camera.target_x += dx*alpha
    game.camera.target_y += dy*alpha
}

render_game :: proc(game: ^Game_State) {
    // Reset tooltip each frame
    game.ui.hover_item = .None
    game.ui.hover_terrain = .Air
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    // Clamp camera target so view never goes outside world pixel bounds
    world_px_w := cast(f32)(WORLD_WIDTH * TILE_SIZE)
    world_px_h := cast(f32)(WORLD_HEIGHT * TILE_SIZE)
    half_w := cast(f32)screen_w / 2
    half_h := cast(f32)screen_h / 2
    // If screen larger than world, center inside and avoid negative ranges
    if world_px_w <= cast(f32)screen_w {
        game.camera.target_x = world_px_w / 2
    } else {
        min_tx := half_w
        max_tx := world_px_w - half_w
        if game.camera.target_x < min_tx { game.camera.target_x = min_tx }
        if game.camera.target_x > max_tx { game.camera.target_x = max_tx }
    }
    if world_px_h <= cast(f32)screen_h {
        game.camera.target_y = world_px_h / 2
    } else {
        min_ty := half_h
        max_ty := world_px_h - half_h
        if game.camera.target_y < min_ty { game.camera.target_y = min_ty }
        if game.camera.target_y > max_ty { game.camera.target_y = max_ty }
    }
    cam_origin_x := game.camera.target_x - cast(f32)screen_w/2
    cam_origin_y := game.camera.target_y - cast(f32)screen_h/2

    // Compute visible tile bounds
    first_tile_x := cast(int)(cam_origin_x) / TILE_SIZE - 1
    first_tile_y := cast(int)(cam_origin_y) / TILE_SIZE - 1
    tiles_x := cast(int)(screen_w / TILE_SIZE + 3)
    tiles_y := cast(int)(screen_h / TILE_SIZE + 3)

    cam_origin_x_i := cast(int)cam_origin_x
    cam_origin_y_i := cast(int)cam_origin_y
    for tx in first_tile_x ..< first_tile_x + tiles_x {
        if tx < 0 || tx >= WORLD_WIDTH do continue
        for ty in first_tile_y ..< first_tile_y + tiles_y {
            if ty < 0 || ty >= WORLD_HEIGHT do continue
            ttype := game.world.terrain[tx][ty]
            col := terrain_color(ttype)
            world_px_x := tx*TILE_SIZE
            world_px_y := ty*TILE_SIZE
            screen_x := world_px_x - cam_origin_x_i
            screen_y := world_px_y - cam_origin_y_i
            base_col := rl.Color{cast(u8)(col.r/2), cast(u8)(col.g/2), cast(u8)(col.b/2), 255}
            if ttype == .Lava {
                // Pulsate brightness using time-based sine (use elapsed_time)
                pulse := (math.sin(game.elapsed_time*5 + cast(f32)(tx+ty)) * 0.5 + 0.5) // 0..1
                // Blend more vivid orange
                br := cast(f32)base_col.r * (1.1 + 0.4*pulse)
                bg := cast(f32)base_col.g * (1.0 + 0.3*pulse)
                bb := cast(f32)base_col.b * (0.9 + 0.2*pulse)
                if br > 255 { br = 255 }; if bg > 255 { bg = 255 }; if bb > 255 { bb = 255 }
                base_col = rl.Color{cast(u8)br, cast(u8)bg, cast(u8)bb, 255}
            }
            if ttype == .Magic_Lava {
                // Purple magical pulsation (faster)
                pulse := (math.sin(game.elapsed_time*8 + cast(f32)(tx+ty)) * 0.5 + 0.5) // 0..1
                // Blend more vivid purple/magenta
                br := cast(f32)base_col.r * (1.0 + 0.6*pulse)
                bg := cast(f32)base_col.g * (1.0 + 0.2*pulse)
                bb := cast(f32)base_col.b * (1.2 + 0.5*pulse)
                if br > 255 { br = 255 }; if bg > 255 { bg = 255 }; if bb > 255 { bb = 255 }
                base_col = rl.Color{cast(u8)br, cast(u8)bg, cast(u8)bb, 255}
            }
            if ttype == .Cave_Entrance {
                // Ominous dark pulsation suggesting the depths of Gnipahellir
                pulse := (math.sin(game.elapsed_time*3 + cast(f32)(tx+ty)) * 0.5 + 0.5) // 0..1, slower rhythm
                // Subtle dark purple/blue glow from the depths
                br := cast(f32)base_col.r * (0.8 + 0.4*pulse)
                bg := cast(f32)base_col.g * (0.8 + 0.4*pulse)
                bb := cast(f32)base_col.b * (1.0 + 0.6*pulse) // More blue in the darkness
                if br > 255 { br = 255 }; if bg > 255 { bg = 255 }; if bb > 255 { bb = 255 }
                base_col = rl.Color{cast(u8)br, cast(u8)bg, cast(u8)bb, 255}
            }
            rl.DrawRectangle(cast(i32)screen_x, cast(i32)screen_y, TILE_SIZE, TILE_SIZE, base_col)
            if ttype != .Air && ttype != .Void {
                draw_tile_outline(screen_x, screen_y, rl.BLACK)
            }
            if ttype == .Lava {
                // Inner glow ellipse
                glow_rad := TILE_SIZE/2 - 2
                center_x := screen_x + TILE_SIZE/2
                center_y := screen_y + TILE_SIZE/2
                for r := glow_rad; r > 0; r -= 2 {
                    a := cast(u8)(40 + (glow_rad - r)*6)
                    if a > 180 { a = 180 }
                    pct := cast(f32)r / cast(f32)glow_rad
                    // gradient toward yellow center
                    rr := cast(f32)255 * (1 - pct*0.2)
                    gg := cast(f32)120 * (1 - pct*0.4)
                    bb := cast(f32)30 * (1 - pct*0.8)
                    rl.DrawCircle(cast(i32)center_x, cast(i32)center_y, cast(f32)r, rl.Color{cast(u8)rr, cast(u8)gg, cast(u8)bb, a})
                }
                // Bubble pop: small bright squares rising (visual only; separate from particle system)
                if (rl.GetRandomValue(0, 100) < 3) {
                    bx := screen_x + cast(int)rl.GetRandomValue(3, TILE_SIZE-5)
                    by := screen_y + cast(int)rl.GetRandomValue(4, TILE_SIZE-6)
                    rl.DrawRectangle(cast(i32)bx, cast(i32)by, 3, 3, rl.Color{255,240,160,230})
                    rl.DrawRectangle(cast(i32)(bx+1), cast(i32)(by-2), 1, 2, rl.Color{255,200,80,180})
                }
            }
            if ttype == .Magic_Lava {
                // Purple magical glow ellipse (brighter and more intense)
                glow_rad := TILE_SIZE/2 - 1
                center_x := screen_x + TILE_SIZE/2
                center_y := screen_y + TILE_SIZE/2
                for r := glow_rad; r > 0; r -= 2 {
                    a := cast(u8)(60 + (glow_rad - r)*8)
                    if a > 200 { a = 200 }
                    pct := cast(f32)r / cast(f32)glow_rad
                    // gradient toward bright purple center
                    rr := cast(f32)255 * (1 - pct*0.1)
                    gg := cast(f32)80 * (1 - pct*0.6)
                    bb := cast(f32)255 * (1 - pct*0.1)
                    rl.DrawCircle(cast(i32)center_x, cast(i32)center_y, cast(f32)r, rl.Color{cast(u8)rr, cast(u8)gg, cast(u8)bb, a})
                }
                // Purple sparkles: small bright purple squares (more frequent than lava bubbles)
                if (rl.GetRandomValue(0, 100) < 5) {
                    bx := screen_x + cast(int)rl.GetRandomValue(2, TILE_SIZE-4)
                    by := screen_y + cast(int)rl.GetRandomValue(2, TILE_SIZE-4)
                    rl.DrawRectangle(cast(i32)bx, cast(i32)by, 2, 2, rl.Color{255,180,255,255})
                }
            }
            if ttype == .Cave_Entrance {
                // Ominous dark glow from the depths of Gnipahellir
                glow_rad := TILE_SIZE/2 + 2  // Slightly larger glow than magical lava
                center_x := screen_x + TILE_SIZE/2
                center_y := screen_y + TILE_SIZE/2
                for r := glow_rad; r > 0; r -= 3 {
                    a := cast(u8)(30 + (glow_rad - r)*4)  // More subtle than magical effects
                    if a > 120 { a = 120 }
                    pct := cast(f32)r / cast(f32)glow_rad
                    // gradient toward dark blue-purple abyss
                    rr := cast(f32)20 * (1 - pct*0.8)   // Very dark red
                    gg := cast(f32)20 * (1 - pct*0.8)   // Very dark green  
                    bb := cast(f32)60 * (1 - pct*0.3)   // More blue for mystical depth
                    rl.DrawCircle(cast(i32)center_x, cast(i32)center_y, cast(f32)r, rl.Color{cast(u8)rr, cast(u8)gg, cast(u8)bb, a})
                }
                // Occasional mysterious wisps: small dark motes that suggest movement in the depths
                if (rl.GetRandomValue(0, 100) < 3) {  // Less frequent than lava effects
                    bx := screen_x + cast(int)rl.GetRandomValue(3, TILE_SIZE-5)
                    by := screen_y + cast(int)rl.GetRandomValue(3, TILE_SIZE-5)
                    rl.DrawRectangle(cast(i32)bx, cast(i32)by, 1, 1, rl.Color{40,40,80,180})
                }
            }

            // Detail overlay for special terrain
            if ttype == .Crafting_Bench {
                cell := TILE_SIZE/4
                // tabletop lighter
                rl.DrawRectangle(cast(i32)screen_x, cast(i32)screen_y, TILE_SIZE, cast(i32)(cell*2), rl.Color{170,110,60,255})
                // legs
                rl.DrawRectangle(cast(i32)screen_x, cast(i32)(screen_y+cell*2), cast(i32)cell, cast(i32)(cell*2), rl.BROWN)
                rl.DrawRectangle(cast(i32)(screen_x+TILE_SIZE-cell), cast(i32)(screen_y+cell*2), cast(i32)cell, cast(i32)(cell*2), rl.BROWN)
                // tools (hammer head gray, handle brown)
                rl.DrawRectangle(cast(i32)(screen_x+cell), cast(i32)(screen_y+cell/2), cast(i32)(cell*2), cast(i32)(cell/2), rl.LIGHTGRAY)
                rl.DrawRectangle(cast(i32)(screen_x+cell*2), cast(i32)(screen_y+cell/2), cast(i32)(cell/2), cast(i32)(cell*2), rl.BROWN)
            } else if ttype == .Tree_Grower {
                cell := TILE_SIZE/4
                // base plate
                rl.DrawRectangle(cast(i32)screen_x, cast(i32)(screen_y+cell*2), TILE_SIZE, cast(i32)(cell*2), rl.Color{100,60,30,255})
                // central chute
                rl.DrawRectangle(cast(i32)(screen_x+cell*1), cast(i32)screen_y, cast(i32)(cell*2), cast(i32)(cell*2), rl.Color{140,90,50,255})
                // arrow indicator up
                rl.DrawTriangle(rl.Vector2{cast(f32)(screen_x+TILE_SIZE/2), cast(f32)screen_y}, rl.Vector2{cast(f32)(screen_x+cell), cast(f32)(screen_y+cell*2)}, rl.Vector2{cast(f32)(screen_x+TILE_SIZE-cell), cast(f32)(screen_y+cell*2)}, rl.GREEN)
            } else if ttype == .Smelter {
                // Draw a furnace body with slot - reuse tile size
                body_col := rl.Color{90,90,100,255}
                rl.DrawRectangle(cast(i32)screen_x+2, cast(i32)screen_y+2, TILE_SIZE-4, TILE_SIZE-4, body_col)
                // Lava adjacency check for activation (within 1 tile)
                active := false
                for dx in -1..=1 { for dy in -1..=1 { if dx == 0 && dy == 0 do continue; nx := tx+dx; ny := ty+dy; if bounds_check(nx,ny) && (game.world.terrain[nx][ny] == .Lava || game.world.terrain[nx][ny] == .Magic_Lava) { active = true } } }
                slot_col := rl.Color{40,40,50,255}
                if active {
                    pulse := (math.sin(game.elapsed_time*6 + cast(f32)(tx*3+ty)) * 0.5 + 0.5)
                    // fiery gradient
                    or := cast(u8)(180 + 50*pulse)
                    og := cast(u8)(70 + 80*pulse)
                    ob := cast(u8)(20 + 30*pulse)
                    slot_col = rl.Color{or, og, ob, 255}
                    // small top smoke puff
                    if rl.GetRandomValue(0,100) < 5 {
                        rl.DrawRectangle(cast(i32)screen_x+TILE_SIZE/2-2, cast(i32)screen_y-4, 4, 4, rl.Color{120,120,130,200})
                    }
                }
                rl.DrawRectangle(cast(i32)screen_x+4, cast(i32)screen_y+TILE_SIZE/2-3, TILE_SIZE-8, 6, slot_col)
            } else if ttype == .Iron || ttype == .Silver || ttype == .Gold || ttype == .Gold_Rare {
                // Draw small cluster pattern (5x5 logical) centered in tile using pixel chunks
                px := 2
                if TILE_SIZE/8 > 2 { px = TILE_SIZE/8 }
                pattern_w := 5; pattern_h := 5
                start_x := screen_x + (TILE_SIZE - pattern_w*px)/2
                start_y := screen_y + (TILE_SIZE - pattern_h*px)/2
                // Define per-ore colors - MUCH more distinct
                base_col := rl.Color{60,60,70,255}     // Iron: Dark metallic gray
                mid_col  := rl.Color{120,120,130,255}  // Iron: Medium gray
                hi_col   := rl.Color{180,180,190,255}  // Iron: Light gray
                if ttype == .Silver { base_col = rl.Color{200,220,240,255}; mid_col = rl.Color{220,240,255,255}; hi_col = rl.Color{255,255,255,255} }  // Silver: Bright white/blue
                else if ttype == .Gold { base_col = rl.Color{160,120,0,255}; mid_col = rl.Color{255,200,0,255}; hi_col = rl.Color{255,255,100,255} }    // Gold: Bright yellow
                else if ttype == .Gold_Rare { base_col = rl.Color{200,0,200,255}; mid_col = rl.Color{255,100,255,255}; hi_col = rl.Color{255,200,255,255} } // Rare Gold: Bright magenta
                // pattern characters: 'b' base, 'm' mid, 'h' highlight, ' ' empty
                // Each mineral gets a UNIQUE pattern for easy identification
                pattern : [5][5]u8
                if ttype == .Iron {
                    // Iron: Square chunky pattern
                    pattern = [5][5]u8{{'b','b','m','b','b'},{'b','m','h','m','b'},{'m','h','h','h','m'},{'b','m','h','m','b'},{'b','b','m','b','b'}}
                } else if ttype == .Silver {
                    // Silver: Cross/star pattern
                    pattern = [5][5]u8{{' ',' ','h',' ',' '},{' ','m','h','m',' '},{'h','h','h','h','h'},{' ','m','h','m',' '},{' ',' ','h',' ',' '}}
                } else if ttype == .Gold {
                    // Gold: Diamond pattern
                    pattern = [5][5]u8{{' ',' ','h',' ',' '},{' ','h','m','h',' '},{'h','m','b','m','h'},{' ','h','m','h',' '},{' ',' ','h',' ',' '}}
                } else { // Gold_Rare: Sparkly scattered pattern
                    pattern = [5][5]u8{{'h',' ','m',' ','h'},{' ','m','h','m',' '},{'m','h','h','h','m'},{' ','m','h','m',' '},{'h',' ','m',' ','h'}}
                }
                for r in 0..<pattern_h {
                    for c in 0..<pattern_w {
                        ch := pattern[r][c]
                        if ch == ' ' do continue
                        colr := mid_col
                        if ch == 'b' { colr = base_col } else if ch == 'h' { colr = hi_col }
                        rl.DrawRectangle(cast(i32)(start_x + c*px), cast(i32)(start_y + r*px), cast(i32)px, cast(i32)px, colr)
                    }
                }
            }
            item := game.world.items[tx][ty]
            if item != .None {
                if item == .Mine_Wand || item == .Hell_Key {
                    // Use same pixel art as inventory but scaled to fit tile
                    // draw_item_icon assumes top-left, pattern width ~5, height ~7
                    scale := 2 // 5*2=10, 7*2=14 fits inside 16x16 with 3px vertical centering
                    icon_w := 5*scale
                    icon_h := 7*scale
                    ix := screen_x + (TILE_SIZE - icon_w)/2
                    iy := screen_y + (TILE_SIZE - icon_h)/2
                    draw_item_icon(item, ix, iy, scale)
                } else {
                    item_col := rl.GOLD
                    #partial switch item {
                    case .Sword: item_col = rl.LIGHTGRAY
                    case .Wood_Log: item_col = rl.BROWN
                    case .Leaf: item_col = rl.Color{34,180,34,255}
                    case .Crafting_Bench: item_col = rl.Color{139,69,19,255}
                    case .Tree_Grower: item_col = rl.Color{160,82,45,255}
                    case .Stone_Block: item_col = rl.GRAY
                    case .Grass_Turf: item_col = rl.Color{34,139,34,255}
                    case .Iron_Ore: item_col = rl.Color{120,120,130,255}      // Match iron terrain
                    case .Silver_Ore: item_col = rl.Color{220,240,255,255}    // Match silver terrain  
                    case .Gold_Ore: item_col = rl.Color{255,200,0,255}        // Match gold terrain
                    case .Gold_Rare_Ore: item_col = rl.Color{255,100,255,255} // Match rare gold terrain
                    case .Smelter: item_col = rl.Color{100,100,110,255}
                    case .Hell_Key: item_col = rl.Color{255,0,0,255} // Bright red for Hell Key
                    }
                    rl.DrawRectangle(cast(i32)(screen_x+TILE_SIZE/4), cast(i32)(screen_y+TILE_SIZE/4), cast(i32)(TILE_SIZE/2), cast(i32)(TILE_SIZE/2), item_col)
                }
                cnt := game.world.item_counts[tx][ty]
                if cnt > 1 {
                    txt := rl.TextFormat("%d", cast(i32)cnt)
                    rl.DrawText(txt, cast(i32)(screen_x+TILE_SIZE/2 - 6), cast(i32)(screen_y+TILE_SIZE/2 - 4), 10, rl.WHITE)
                }
            }
        }
    }

    // While dragging a placeable item from inventory, show a highlight over the target tile under cursor
    if game.ui.dragging && game.ui.drag_from_inv {
        di := game.ui.drag_index
        if di >= 0 && di < INV_MAX_SLOTS {
            stack := game.inventory.slots[di]
            if stack.id != .None && item_is_placeable(stack.id) {
                mouse := rl.GetMousePosition()
                world_px_x := mouse.x + cam_origin_x
                world_px_y := mouse.y + cam_origin_y
                tx := cast(int)(world_px_x) / TILE_SIZE
                ty := cast(int)(world_px_y) / TILE_SIZE
                if bounds_check(tx, ty) {
                    can_place := false
                    if !point_in_any_window(game, cast(int)mouse.x, cast(int)mouse.y) {
                        can_place = can_place_item_at(game, stack.id, tx, ty)
                    }
                    screen_x := tx*TILE_SIZE - cast(int)cam_origin_x
                    screen_y := ty*TILE_SIZE - cast(int)cam_origin_y
                    col := rl.Color{80,200,120,120}
                    if !can_place { col = rl.Color{200,60,60,120} }
                    draw_tile_outline_rectangle(cast(i32)screen_x, cast(i32)screen_y, TILE_SIZE, TILE_SIZE, rl.BLACK)
                    rl.DrawRectangle(cast(i32)screen_x, cast(i32)screen_y, TILE_SIZE, TILE_SIZE, col)
                }
            }
        }
    }

    draw_player_pixels(game, cam_origin_x, cam_origin_y)
    
    // Draw enemy (Garm)
    draw_enemy_pixels(&game.garm, cam_origin_x, cam_origin_y)

    // Garm debug rays overlay: lines from Garm to last-checked tiles
    {
        // Start at Garm's approximate center in world pixels
        start_x_f := game.garm.visual_x*TILE_SIZE - cam_origin_x
        start_y_f := game.garm.visual_y*TILE_SIZE - cam_origin_y
        for i in 0 ..< len(game.garm.debug_rays) {
            r := &game.garm.debug_rays[i]
            if r.life <= 0 do continue
            end_x_f := cast(f32)(r.x*TILE_SIZE + TILE_SIZE/2) - cam_origin_x
            end_y_f := cast(f32)(r.y*TILE_SIZE + TILE_SIZE/2) - cam_origin_y
            col := r.color
            // Fade alpha based on remaining life
            a := 80 + r.life*10
            if a > 255 { a = 255 }
            col.a = cast(u8)a
            rl.DrawLine(cast(i32)start_x_f, cast(i32)start_y_f, cast(i32)end_x_f, cast(i32)end_y_f, col)
            // Highlight the target tile
            tile_px_x := r.x*TILE_SIZE - cast(int)cam_origin_x
            tile_px_y := r.y*TILE_SIZE - cast(int)cam_origin_y
            draw_tile_outline_rectangle(cast(i32)tile_px_x, cast(i32)tile_px_y, TILE_SIZE, TILE_SIZE, col)
            // Decay
            r.life -= 1
        }
    }

    // Mining laser preview when holding Mine_Wand: draw line to mouse within range 5
    if game.player.main_hand == .Mine_Wand {
        mouse := rl.GetMousePosition()
        // Convert wand tip to screen coords (fallback to center if not available)
        tip_x, tip_y, ok_tip := player_wand_tip_world(&game.player)
        if !ok_tip {
            tip_x = game.player.visual_x*TILE_SIZE 
            tip_y = game.player.visual_y*TILE_SIZE 
        }
    pcx := tip_x - cam_origin_x
    pcy := tip_y - cam_origin_y + 3 // shifted down 3px per request
        // Determine mouse tile and range limit
        cam_origin_x2 := game.camera.target_x - cast(f32)WINDOW_WIDTH/2
        cam_origin_y2 := game.camera.target_y - cast(f32)WINDOW_HEIGHT/2
        world_px_x := mouse.x + cam_origin_x2
        world_px_y := mouse.y + cam_origin_y2
        mtx := cast(int)(world_px_x)/TILE_SIZE
        mty := cast(int)(world_px_y)/TILE_SIZE
        px := game.player.tile_x
        py := game.player.tile_y
        if bounds_check(mtx,mty) {
            dx := mtx - px
            dy := mty - py
            if dx*dx + dy*dy <= 25 { // within 5 tiles
                rl.DrawLine(cast(i32)pcx, cast(i32)pcy, cast(i32)mouse.x, cast(i32)mouse.y, rl.YELLOW)
                // highlight target tile
                screen_x_f := cast(f32)(mtx*TILE_SIZE) - cam_origin_x
                screen_y_f := cast(f32)(mty*TILE_SIZE) - cam_origin_y
                screen_x := cast(int)(screen_x_f + 0.5)
                screen_y := cast(int)(screen_y_f + 0.5)
                draw_tile_outline_rectangle(cast(i32)screen_x, cast(i32)screen_y, TILE_SIZE, TILE_SIZE, rl.YELLOW)
            }
        }
    }

    // Portal effects (appear behind player but above terrain)
    portals_render(&game.portals, cam_origin_x, cam_origin_y)
    // Render transient particles (sparks etc.) above tiles & portals but below UI
    particles_render(&game.particles, cam_origin_x, cam_origin_y)
    // Wand projectile particles (traveling sparks)
    wand_projectiles_render(game, cam_origin_x, cam_origin_y)
    // Enemy fireball projectiles
    fireballs_render(&game.fireballs, cam_origin_x, cam_origin_y)

    // World hover detection (only if mouse not over any UI window)
    mouse := rl.GetMousePosition()
    if !point_in_any_window(game, cast(int)mouse.x, cast(int)mouse.y) {
        cam_origin_x2 := game.camera.target_x - cast(f32)WINDOW_WIDTH/2
        cam_origin_y2 := game.camera.target_y - cast(f32)WINDOW_HEIGHT/2
        world_px_x := mouse.x + cam_origin_x2
        world_px_y := mouse.y + cam_origin_y2
        tx := cast(int)(world_px_x) / TILE_SIZE
        ty := cast(int)(world_px_y) / TILE_SIZE
        if bounds_check(tx, ty) {
            itm := game.world.items[tx][ty]
            if itm != .None {
                game.ui.hover_item = itm
                game.ui.tooltip_x = cast(int)mouse.x + 18
                game.ui.tooltip_y = cast(int)mouse.y + 18
            } else {
                terr := game.world.terrain[tx][ty]
                if terr != .Air {
                    game.ui.hover_terrain = terr
                    game.ui.tooltip_x = cast(int)mouse.x + 18
                    game.ui.tooltip_y = cast(int)mouse.y + 18
                }
            }
            // Debug ghost preview overlay
            if game.ui.debug_place_active {
                gx := tx*TILE_SIZE - cast(int)cam_origin_x2
                gy := ty*TILE_SIZE - cast(int)cam_origin_y2
                col := terrain_color(game.ui.debug_place_terrain)
                rl.DrawRectangle(cast(i32)gx, cast(i32)gy, TILE_SIZE, TILE_SIZE, rl.Color{col.r, col.g, col.b, 140})
                draw_tile_outline_rectangle(cast(i32)gx, cast(i32)gy, TILE_SIZE, TILE_SIZE, rl.Color{255,255,255,180})
            }
        }
    }

    // Pickup logic moved to interaction system

    // Render character first so inventory drag cancellation doesn't prematurely end equip drops
    if game.ui.character_open { render_character(game) }
    if game.ui.bag_open { render_inventory(game) }
    if game.ui.build_menu_open { render_build_menu(game) }
        render_popup_buttons(game)
    if game.ui.crafting_open { render_crafting_menu(game) }
    if game.ui.debug_open { render_debug_menu(game) }
    if game.ui.sound_debug_open { render_sound_debug_window(game) }
    
    // Health and Mana orbs (always visible)
    render_health_mana_orbs(game)
    
    // Final overlay tooltip
    render_tooltip(game)

    // Popup message overlay
    if game.ui.popup_active {
        // decrement timer (render phase reads dt indirectly; safe to keep simple without dt here)
        // We'll reduce lifetime in update_interactions to avoid side-effects here.
        txt := game.ui.popup_text
        fs := 18
        w := int(rl.MeasureText(txt, cast(i32)fs)) + 20
        h := fs + 16
        x := (int(rl.GetScreenWidth()) - w)/2
        y := 40
        rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)w, cast(i32)h, rl.Color{25,25,35,230})
        draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)w, cast(i32)h, rl.GOLD)
        rl.DrawText(txt, cast(i32)(x+10), cast(i32)(y+8), cast(i32)fs, rl.WHITE)
    }
    
    // Game over screen (rendered on top of everything after 4 seconds)
    if game.player_dead && game.death_timer >= 4.0 {
        render_game_over_screen(game)
    }
    
    // Stats screen (F11 to toggle)
    if game.ui.stats_open {
        render_stats_screen(game)
    }
    
    // Menu system rendering (on top of everything)
    if game.ui.main_menu_active {
        render_main_menu(game)
    }
    
    if game.ui.save_quit_dialog_active {
        render_save_quit_dialog(game)
    }
    
    if game.ui.settings_menu_active {
        render_settings_menu(game)
    }
    
    // Debug ghost placement moved to interaction system

    // World drop/placement moved to interaction system
}

// Very small 8x11 ascii pixel player (from user provided frames reduced)
FRAME_WIDTH  :: 8
FRAME_HEIGHT :: 11

// Enemy (Garm) frame dimensions - bigger than player
ENEMY_FRAME_WIDTH  :: 12
ENEMY_FRAME_HEIGHT :: 14

Player_Frame :: [FRAME_HEIGHT][FRAME_WIDTH]rune
Enemy_Frame :: [ENEMY_FRAME_HEIGHT][ENEMY_FRAME_WIDTH]rune

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

// Garm the hell hound frames - larger and more menacing than player
// R = Red/dark red body, F = Fire/bright red accents, E = Eyes (glowing), B = Black details
enemy_frames : [2][ENEMY_FRAME_HEIGHT][ENEMY_FRAME_WIDTH]rune = {
    { // frame 0 - standing/idle
        {' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' '},
        {' ',' ',' ','E',' ',' ',' ',' ','E',' ',' ',' '},
        {' ',' ','B','F','B',' ',' ','B','F','B',' ',' '},
        {' ',' ',' ','R','R','R','R','R','R',' ',' ',' '},
        {' ',' ','R','R','R','R','R','R','R','R',' ',' '},
        {' ','R','R','R','F','R','R','F','R','R','R',' '},
        {'R','R','R','R','R','R','R','R','R','R','R','R'},
        {'R','R','R','R','R','R','R','R','R','R','R','R'},
        {'R','R','R','R','R','R','R','R','R','R','R','R'},
        {' ','R','R','R','R','R','R','R','R','R','R',' '},
        {' ',' ','R','R',' ',' ',' ',' ','R','R',' ',' '},
        {' ',' ','B','B',' ',' ',' ',' ','B','B',' ',' '},
        {' ','B','B','B','B',' ',' ','B','B','B','B',' '},
        {' ','B','B','B','B',' ',' ','B','B','B','B',' '},
    },
    { // frame 1 - walking
        {' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' '},
        {' ',' ',' ','E',' ',' ',' ',' ','E',' ',' ',' '},
        {' ',' ','B','F','B',' ',' ','B','F','B',' ',' '},
        {' ',' ',' ','R','R','R','R','R','R',' ',' ',' '},
        {' ',' ','R','R','R','R','R','R','R','R',' ',' '},
        {' ','R','R','R','F','R','R','F','R','R','R',' '},
        {'R','R','R','R','R','R','R','R','R','R','R','R'},
        {'R','R','R','R','R','R','R','R','R','R','R','R'},
        {'R','R','R','R','R','R','R','R','R','R','R','R'},
        {' ','R','R','R','R','R','R','R','R','R','R',' '},
        {' ','R','R',' ',' ',' ',' ',' ',' ','R','R',' '},
        {' ','B','B',' ',' ',' ',' ',' ',' ','B','B',' '},
        {'B','B','B','B',' ',' ',' ',' ','B','B','B','B'},
        {'B','B','B','B',' ',' ',' ',' ','B','B','B','B'},
    },
}

// Extract minimal animation state from player.move_timer to select frame
player_animation_frame :: proc(p: ^Player) -> int {
    return p.walk_anim_frame
}

// Extract enemy animation frame
enemy_animation_frame :: proc(e: ^Enemy) -> int {
    return e.walk_anim_frame
}

player_pixel_color :: proc(p: ^Player, ch: rune, shade: f32) -> rl.Color {
    // shade multiplies brightness (0..1.2 range typical)
    clamp := proc(v_in: f32) -> u8 {
        v := v_in
        if v < 0 { v = 0 } else if v > 255 { v = 255 }
        return cast(u8)v
    }
    switch ch {
    case 'Y': return rl.Color{p.hair_r, p.hair_g, p.hair_b, 255}
    case 'K': return rl.Color{40,40,50,255}
    case 'C': {
        r := cast(f32)p.clothing_r * shade
        g := cast(f32)p.clothing_g * shade
        b := cast(f32)p.clothing_b * shade
        return rl.Color{clamp(r), clamp(g), clamp(b), 255}
    }
    case 'B': return rl.Color{110,70,40,255}
    case: return rl.BLANK
    }
}

// Enemy (Garm) pixel colors - hell hound theme
enemy_pixel_color :: proc(ch: rune, shade: f32) -> rl.Color {
    clamp := proc(v_in: f32) -> u8 {
        v := v_in
        if v < 0 { v = 0 } else if v > 255 { v = 255 }
        return cast(u8)v
    }
    switch ch {
    case 'R': { // Dark red body
        r := 120.0 * shade
        g := 20.0 * shade
        b := 20.0 * shade
        return rl.Color{clamp(r), clamp(g), clamp(b), 255}
    }
    case 'F': { // Bright fire red accents
        r := 255.0 * shade
        g := 60.0 * shade
        b := 0.0 * shade
        return rl.Color{clamp(r), clamp(g), clamp(b), 255}
    }
    case 'E': { // Glowing yellow eyes
        r := 255.0 * shade
        g := 255.0 * shade
        b := 100.0 * shade
        return rl.Color{clamp(r), clamp(g), clamp(b), 255}
    }
    case 'B': { // Black details
        r := 20.0 * shade
        g := 20.0 * shade
        b := 20.0 * shade
        return rl.Color{clamp(r), clamp(g), clamp(b), 255}
    }
    case: return rl.BLANK
    }
}

cell_pixel_size :: proc() -> int {
    size := TILE_SIZE/8
    if size < 1 { size = 1 }
    return size
}

// Draw player using per-character pixels, scaled to TILE_SIZE vertically anchored
// We map player.tile_x/y to world tile center and draw pixels inside that tile region.
draw_player_pixels :: proc(game: ^Game_State, cam_x, cam_y: f32) {
    // Don't draw player if they're dead
    if game.player_dead {
        return
    }
    
    p := &game.player
    frame_index := player_animation_frame(p)
    frame := player_frames[frame_index]

    // Position
    base_x_f := p.visual_x*TILE_SIZE
    base_y_f := p.visual_y*TILE_SIZE

    pixel_size := cell_pixel_size()

    // Compute frame width in pixels for centering
    total_w := FRAME_WIDTH * pixel_size
    total_h := FRAME_HEIGHT * pixel_size
    origin_x_f := base_x_f - cast(f32)total_w/2 - cam_x
    origin_y_f := base_y_f - cast(f32)total_h + cast(f32)pixel_size - cam_y // anchor feet
    origin_x := cast(int)(origin_x_f + 0.5)
    origin_y := cast(int)(origin_y_f + 0.5)

    // Simple vertical bob based on walk animation timer for a hint of motion
    bob_offset := 0
    if p.walk_anim_frame == 1 { bob_offset = -1 }
    // Lighting: left->right gradient slight
    if p.facing_right {
        for row in 0..<FRAME_HEIGHT {
            for col in 0..<FRAME_WIDTH {
                ch := frame[row][col]
                if ch == ' ' do continue
                shade := 0.85 + cast(f32)col / cast(f32)(FRAME_WIDTH-1) * 0.25
                colr := player_pixel_color(p, ch, shade)
                rl.DrawRectangle(cast(i32)(origin_x + col*pixel_size), cast(i32)(origin_y + row*pixel_size + bob_offset), cast(i32)pixel_size, cast(i32)pixel_size, colr)
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
                rl.DrawRectangle(cast(i32)(origin_x + flipped_col*pixel_size), cast(i32)(origin_y + row*pixel_size + bob_offset), cast(i32)pixel_size, cast(i32)pixel_size, colr)
            }
        }
    }

    // Draw equipped main hand item (simple angled pixel art overlay)
    if p.main_hand != .None {
        // Anchor near side facing mouse mid body
        base_y := origin_y + pixel_size*6
        base_x : int
        if p.facing_right { base_x = origin_x + total_w - pixel_size*2 } else { base_x = origin_x + pixel_size }
    #partial switch p.main_hand {
        case .Sword: {
            // Diagonal blade toward facing direction
            steps := 6
            dir := 1
            if !p.facing_right { dir = -1 }
            for i in 0..<steps {
                x := base_x + i*pixel_size*dir
                y := base_y - i*pixel_size
                rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)pixel_size, cast(i32)pixel_size, rl.LIGHTGRAY)
            }
            // Cross-guard (horizontal) & hilt (brown)
            guard_y := base_y + pixel_size
            if p.facing_right {
                rl.DrawRectangle(cast(i32)(base_x - pixel_size), cast(i32)guard_y, cast(i32)(pixel_size*3), cast(i32)pixel_size, rl.DARKGRAY)
                rl.DrawRectangle(cast(i32)(base_x), cast(i32)(base_y + pixel_size*2), cast(i32)pixel_size, cast(i32)(pixel_size*2), rl.BROWN)
            } else {
                rl.DrawRectangle(cast(i32)(base_x - pixel_size), cast(i32)guard_y, cast(i32)(pixel_size*3), cast(i32)pixel_size, rl.DARKGRAY)
                rl.DrawRectangle(cast(i32)(base_x), cast(i32)(base_y + pixel_size*2), cast(i32)pixel_size, cast(i32)(pixel_size*2), rl.BROWN)
            }
        }
        case .Mine_Wand: {
            // Wand shaft angled toward facing side
            steps := 5
            dir := 1
            if !p.facing_right { dir = -1 }
            for i in 0..<steps {
                x := base_x + i*pixel_size*dir
                y := base_y - i*pixel_size
                rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)pixel_size, cast(i32)pixel_size, rl.BROWN)
            }
            head_x := base_x + (steps-1)*pixel_size*dir
            head_y := base_y - (steps-1)*pixel_size
            // Head centered perpendicular to shaft
            rl.DrawRectangle(cast(i32)(head_x - pixel_size/2), cast(i32)(head_y - pixel_size/2), cast(i32)(pixel_size*2), cast(i32)(pixel_size*2), rl.PURPLE)
        }
        case .Iron_Bucket: {
            // Draw bucket held in hand
            bucket_w := pixel_size * 3
            bucket_h := pixel_size * 4
            bucket_x := base_x - pixel_size
            bucket_y := base_y - pixel_size
            
            // Bucket outline
            rl.DrawRectangle(cast(i32)bucket_x, cast(i32)bucket_y, cast(i32)bucket_w, cast(i32)bucket_h, rl.Color{120,120,130,255})
            rl.DrawRectangleLines(cast(i32)bucket_x, cast(i32)bucket_y, cast(i32)bucket_w, cast(i32)bucket_h, rl.Color{80,80,90,255})
            
            // Handle
            handle_x := bucket_x + bucket_w
            handle_y := bucket_y + pixel_size
            rl.DrawRectangle(cast(i32)handle_x, cast(i32)handle_y, cast(i32)pixel_size, cast(i32)(pixel_size*2), rl.Color{100,100,110,255})
            
            // Show lava inside if bucket has lava
            if game.bucket_has_lava {
                lava_margin := pixel_size / 2
                lava_x := bucket_x + lava_margin
                lava_y := bucket_y + pixel_size + lava_margin
                lava_w := bucket_w - lava_margin*2
                lava_h := pixel_size * 2
                rl.DrawRectangle(cast(i32)lava_x, cast(i32)lava_y, cast(i32)lava_w, cast(i32)lava_h, rl.Color{220,50,20,255})
            }
        }
        case: {
            // Generic small square for other equipables
            rl.DrawRectangle(cast(i32)base_x, cast(i32)base_y, cast(i32)(pixel_size*2), cast(i32)(pixel_size*2), rl.GOLD)
        }
        }
    }
}

// Draw enemy using pixel art similar to player but larger
draw_enemy_pixels :: proc(enemy: ^Enemy, cam_x, cam_y: f32) {
    if !enemy.active do return
    
    frame_index := enemy_animation_frame(enemy)
    frame := enemy_frames[frame_index]
    
    // Position
    base_x_f := enemy.visual_x * TILE_SIZE
    base_y_f := enemy.visual_y * TILE_SIZE
    
    pixel_size := cell_pixel_size()
    
    // Compute frame width in pixels for centering
    total_w := ENEMY_FRAME_WIDTH * pixel_size
    total_h := ENEMY_FRAME_HEIGHT * pixel_size
    origin_x_f := base_x_f - cast(f32)total_w/2 - cam_x
    origin_y_f := base_y_f - cast(f32)total_h + cast(f32)pixel_size - cam_y // anchor feet
    origin_x := cast(int)(origin_x_f + 0.5)
    origin_y := cast(int)(origin_y_f + 0.5)
    
    // Simple vertical bob for walking animation
    bob_offset := 0
    if enemy.walk_anim_frame == 1 { bob_offset = -1 }
    
    // Add damage flash effect
    damage_flash := enemy.damage_timer > 0
    
    // Draw with directional lighting and optional damage flash
    if enemy.facing_right {
        for row in 0..<ENEMY_FRAME_HEIGHT {
            for col in 0..<ENEMY_FRAME_WIDTH {
                ch := frame[row][col]
                if ch == ' ' do continue
                shade := 0.85 + cast(f32)col / cast(f32)(ENEMY_FRAME_WIDTH-1) * 0.25
                colr := enemy_pixel_color(ch, shade)
                
                // Apply damage flash (make whiter)
                if damage_flash {
                    colr.r = cast(u8)(cast(f32)colr.r * 0.5 + 255.0 * 0.5)
                    colr.g = cast(u8)(cast(f32)colr.g * 0.5 + 255.0 * 0.5)
                    colr.b = cast(u8)(cast(f32)colr.b * 0.5 + 255.0 * 0.5)
                }
                
                rl.DrawRectangle(
                    cast(i32)(origin_x + col*pixel_size), 
                    cast(i32)(origin_y + row*pixel_size + bob_offset), 
                    cast(i32)pixel_size, 
                    cast(i32)pixel_size, 
                    colr
                )
            }
        }
    } else {
        // Flipped horizontally when facing left
        for row in 0..<ENEMY_FRAME_HEIGHT {
            for col in 0..<ENEMY_FRAME_WIDTH {
                ch := frame[row][col]
                if ch == ' ' do continue
                flipped_col := ENEMY_FRAME_WIDTH - 1 - col
                shade := 0.85 + cast(f32)flipped_col / cast(f32)(ENEMY_FRAME_WIDTH-1) * 0.25
                colr := enemy_pixel_color(ch, shade)
                
                // Apply damage flash
                if damage_flash {
                    colr.r = cast(u8)(cast(f32)colr.r * 0.5 + 255.0 * 0.5)
                    colr.g = cast(u8)(cast(f32)colr.g * 0.5 + 255.0 * 0.5)
                    colr.b = cast(u8)(cast(f32)colr.b * 0.5 + 255.0 * 0.5)
                }
                
                rl.DrawRectangle(
                    cast(i32)(origin_x + flipped_col*pixel_size), 
                    cast(i32)(origin_y + row*pixel_size + bob_offset), 
                    cast(i32)pixel_size, 
                    cast(i32)pixel_size, 
                    colr
                )
            }
        }
    }
}

// ---------------- Inventory UI ------------------

render_inventory :: proc(game: ^Game_State) {
    // Simple centered panel
        panel_w := INVENTORY_W
        panel_h := INVENTORY_H
        x := game.ui.inv_x
        y := game.ui.inv_y
    bg := rl.Color{25,25,35,220}
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, bg)
    draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.GOLD)

    // Title
        rl.DrawText("Bag", cast(i32)(x+12), cast(i32)(y+8), 18, rl.GOLD)
        // Drag handling (title bar 0..30px)
        mouse := rl.GetMousePosition()
        left_pressed := rl.IsMouseButtonPressed(rl.MouseButton(0))
        left_released := rl.IsMouseButtonReleased(rl.MouseButton(0))
        if mouse.x >= cast(f32)x && mouse.x < cast(f32)(x+panel_w) && mouse.y >= cast(f32)y && mouse.y < cast(f32)(y+30) {
            if left_pressed { game.ui.window_dragging = true; game.ui.window_drag_target = 1; game.ui.window_drag_off_x = cast(int)mouse.x - x; game.ui.window_drag_off_y = cast(int)mouse.y - y }
        }
        if game.ui.window_dragging && game.ui.window_drag_target == 1 {
            if rl.IsMouseButtonDown(rl.MouseButton(0)) {
                game.ui.inv_x = cast(int)mouse.x - game.ui.window_drag_off_x
                game.ui.inv_y = cast(int)mouse.y - game.ui.window_drag_off_y
            } else if left_released {
                game.ui.window_dragging = false
                game.ui.window_drag_target = 0
            }
            x = game.ui.inv_x; y = game.ui.inv_y
        }

    // Grid config
    cols := 6
    slot_size := 40
    pad := 8
    start_x := x + 12
    start_y := y + 40

    mouse = rl.GetMousePosition()
    mx := cast(int)mouse.x
    my := cast(int)mouse.y
    _ = rl.IsMouseButtonDown(rl.MouseButton(0)) // currently unused continuous check
    left_pressed = rl.IsMouseButtonPressed(rl.MouseButton(0))
    left_released = rl.IsMouseButtonReleased(rl.MouseButton(0))

    for i in 0..<INV_MAX_SLOTS {
        col := i % cols
        row := i / cols
        sx := start_x + col*(slot_size+pad)
        sy := start_y + row*(slot_size+pad)
        // slot background
        rl.DrawRectangle(cast(i32)sx, cast(i32)sy, cast(i32)slot_size, cast(i32)slot_size, rl.Color{45,45,60,255})
        draw_tile_outline_rectangle(cast(i32)sx, cast(i32)sy, cast(i32)slot_size, cast(i32)slot_size, rl.Color{90,90,120,255})
        hovered := mx >= sx && mx < sx+slot_size && my >= sy && my < sy+slot_size
        if hovered {
            draw_tile_outline_rectangle(cast(i32)sx, cast(i32)sy, cast(i32)slot_size, cast(i32)slot_size, rl.GOLD)
            if left_pressed && !game.ui.dragging && game.inventory.slots[i].id != .None {
                // Play UI click sound
                _ = event_queue_push(&game.events, Event{
                    type = .Play_Sound,
                    source_id = PLAYER_ID,
                    target_id = PLAYER_ID,
                    data = Sound_Event{ sound_id = .UI_CLICK, volume = -1 }
                })
                
                // Double-click detection (within 0.3s on same slot) to auto-equip
                DOUBLE_CLICK_WINDOW :: 0.3
                now := game.elapsed_time
                if game.ui.last_click_slot == i && (now - game.ui.last_click_time) <= DOUBLE_CLICK_WINDOW {
                    if equip_inventory_slot_to_main_hand(game, i) {
                        debugf("Auto-equip double-click slot=%d", i)
                    }
                    game.ui.last_click_slot = -1
                    game.ui.last_click_time = -1000
                } else {
                    game.ui.last_click_slot = i
                    game.ui.last_click_time = now
                    // Start drag if not equipping
                    game.ui.dragging = true
                    game.ui.drag_from_inv = true
                    game.ui.drag_index = i
                    stack := game.inventory.slots[i]
                    debugf("Inv drag start slot=%d item=%s count=%d", i, item_name(stack.id), stack.count)
                }
            }
            if left_released && game.ui.dragging && game.ui.drag_from_inv && game.ui.drag_index != i {
                // Drop into slot (swap)
                src := game.ui.drag_index
                a := game.inventory.slots[src]
                b := game.inventory.slots[i]
                tmp := game.inventory.slots[src]
                game.inventory.slots[src] = game.inventory.slots[i]
                game.inventory.slots[i] = tmp
                game.ui.dragging = false
                debugf("Inv swap src=%d(%s x%d) dst=%d(%s x%d)", src, item_name(a.id), a.count, i, item_name(b.id), b.count)
            }
            
            // Right-click to use consumables
            if rl.IsMouseButtonPressed(rl.MouseButton(1)) && hovered && !game.ui.dragging {
                // Play UI click sound for right-click
                _ = event_queue_push(&game.events, Event{
                    type = .Play_Sound,
                    source_id = PLAYER_ID,
                    target_id = PLAYER_ID,
                    data = Sound_Event{ sound_id = .UI_CLICK, volume = -1 }
                })
                stack := &game.inventory.slots[i]
                if stack.id == .Potion_Health && stack.count > 0 {
                    if game.player.health < game.player.max_health {
                        game.player.health = min(game.player.health + 3, game.player.max_health)
                        stack.count -= 1
                        if stack.count == 0 { stack.id = .None }
                        game.ui.popup_active = true
                        game.ui.popup_text = "Health restored!"
                        game.ui.popup_time = 1.0
                    }
                } else if stack.id == .Potion_Mana && stack.count > 0 {
                    if game.player.mana < game.player.max_mana {
                        game.player.mana = min(game.player.mana + 2, game.player.max_mana)
                        stack.count -= 1
                        if stack.count == 0 { stack.id = .None }
                        game.ui.popup_active = true
                        game.ui.popup_text = "Mana restored!"
                        game.ui.popup_time = 1.0
                    }
                }
            }
            // Tooltip
            stack := game.inventory.slots[i]
            if stack.id != .None {
                game.ui.hover_item = stack.id
                game.ui.tooltip_x = mx + 16
                game.ui.tooltip_y = my + 16
            }
        }
        stack := game.inventory.slots[i]
        if stack.id != .None {
            // Render icon placeholder as colored square & abbreviation
            // Icon drawing centered
            draw_item_icon(stack.id, sx + (slot_size-20)/2, sy + 8, 2)
            if stack.count > 1 {
                // Count bottom-right
                txt := rl.TextFormat("%d", cast(i32)stack.count)
                measure := rl.MeasureText(txt, 10)
                rl.DrawText(txt, cast(i32)(sx + slot_size - 4 - cast(int)measure), cast(i32)(sy+slot_size-14), 10, rl.WHITE)
            }
        }
    }

    // Drag icon render (follows cursor) - do not auto-cancel so character window can accept drop
    if game.ui.dragging && game.ui.drag_from_inv {
        di := game.ui.drag_index
        if di >= 0 && di < INV_MAX_SLOTS {
            stack := game.inventory.slots[di]
            if stack.id != .None {
                draw_item_icon(stack.id, mx-10, my-10, 2)
            }
        }
        if left_released {
            // Only cancel here if releasing INSIDE a UI window (world drop handled later outside windows)
            if point_in_any_window(game, mx, my) {
                // If it's over character window, that code will already have consumed drop; if just empty UI space, cancel.
                game.ui.dragging = false
            }
        }
    }

    rl.DrawText("B to close", cast(i32)(x+panel_w-110), cast(i32)(y+panel_h-22), 10, rl.GRAY)
}

render_character :: proc(game: ^Game_State) {
    panel_w := CHARACTER_W
    panel_h := CHARACTER_H
    x := game.ui.char_x
    y := game.ui.char_y
    left_pressed := rl.IsMouseButtonPressed(rl.MouseButton(0))
    left_released := rl.IsMouseButtonReleased(rl.MouseButton(0))
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{30,25,40,220})
    draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{120,90,150,255})
    rl.DrawText("Character", cast(i32)(x+10), cast(i32)(y+8), 18, rl.PINK)

    slot_x := x + 70
    slot_y := y + 60
    mouse := rl.GetMousePosition()
    if mouse.x >= cast(f32)x && mouse.x < cast(f32)(x+panel_w) && mouse.y >= cast(f32)y && mouse.y < cast(f32)(y+30) {
        if left_pressed { game.ui.window_dragging = true; game.ui.window_drag_target = 2; game.ui.window_drag_off_x = cast(int)mouse.x - x; game.ui.window_drag_off_y = cast(int)mouse.y - y }
    }
    if game.ui.window_dragging && game.ui.window_drag_target == 2 {
        if rl.IsMouseButtonDown(rl.MouseButton(0)) {
            game.ui.char_x = cast(int)mouse.x - game.ui.window_drag_off_x
            game.ui.char_y = cast(int)mouse.y - game.ui.window_drag_off_y
            x = game.ui.char_x; y = game.ui.char_y
        } else if left_released { game.ui.window_dragging = false; game.ui.window_drag_target = 0 }
    }
    rl.DrawText("Main Hand", cast(i32)(x+10), cast(i32)(y+40), 12, rl.GRAY)
    rl.DrawRectangle(cast(i32)slot_x, cast(i32)slot_y, 48, 48, rl.Color{50,50,70,255})
    draw_tile_outline_rectangle(cast(i32)slot_x, cast(i32)slot_y, 48, 48, rl.Color{100,100,140,255})

    mouse = rl.GetMousePosition()
    mx := cast(int)mouse.x
    my := cast(int)mouse.y
    hovered := mx >= slot_x && mx < slot_x+48 && my >= slot_y && my < slot_y+48

    if hovered { draw_tile_outline_rectangle(cast(i32)slot_x, cast(i32)slot_y, 48, 48, rl.GOLD) }

    if hovered && left_released && game.ui.dragging {
        // Drop from inventory into main hand if equipable
        if game.ui.drag_from_inv {
            src := game.ui.drag_index
            if src >= 0 && src < INV_MAX_SLOTS {
                _ = equip_inventory_slot_to_main_hand(game, src)
            }
        }
        game.ui.dragging = false
    } else if hovered && left_pressed && !game.ui.dragging && game.player.main_hand != .None {
        // Play UI click sound for character slot interaction
        _ = event_queue_push(&game.events, Event{
            type = .Play_Sound,
            source_id = PLAYER_ID,
            target_id = PLAYER_ID,
            data = Sound_Event{ sound_id = .UI_CLICK, volume = -1 }
        })
        // Pick up equipped back into drag and clear
        game.ui.dragging = true
        game.ui.drag_from_inv = false
        game.ui.drag_index = -1
        // Put into a temp slot outside, we track type via player.main_hand and on drop will handle
    }

    // Draw main hand icon
    if game.player.main_hand != .None {
        draw_item_icon(game.player.main_hand, slot_x+8, slot_y+8, 4)
        if hovered {
            game.ui.hover_item = game.player.main_hand
            game.ui.tooltip_x = mx + 16
            game.ui.tooltip_y = my + 16
        }
    }

    rl.DrawText("C to close", cast(i32)(x+panel_w-110), cast(i32)(y+panel_h-22), 10, rl.GRAY)

    // If dragging equipment (from main hand) follow mouse
    if game.ui.dragging && !game.ui.drag_from_inv && game.player.main_hand != .None {
        draw_item_icon(game.player.main_hand, mx-12, my-12, 3)
        if left_released {
            // Drop into inventory
            id := game.player.main_hand
            // find existing stack
            placed := false
            for i in 0..<INV_MAX_SLOTS {
                if game.inventory.slots[i].id == id { game.inventory.slots[i].count += 1; placed = true; break }
            }
            if !placed {
                for i in 0..<INV_MAX_SLOTS {
                    if game.inventory.slots[i].id == .None { game.inventory.slots[i] = Item_Stack{ id = id, count = 1 }; placed = true; break }
                }
            }
            game.player.main_hand = .None
            game.ui.dragging = false
        }
    }
}

// ---------------- Build Menu ------------------
render_build_menu :: proc(game: ^Game_State) {
    panel_w := BUILD_MENU_W
    panel_h := BUILD_MENU_H
    x := game.ui.build_x
    y := game.ui.build_y
    left_pressed := rl.IsMouseButtonPressed(rl.MouseButton(0))
    left_released := rl.IsMouseButtonReleased(rl.MouseButton(0))
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{25,35,25,220})
    draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{70,120,70,255})
    rl.DrawText("Build", cast(i32)(x+10), cast(i32)(y+8), 18, rl.GREEN)

    // Collect placeable inventory entries
    mouse := rl.GetMousePosition()
    if mouse.x >= cast(f32)x && mouse.x < cast(f32)(x+panel_w) && mouse.y >= cast(f32)y && mouse.y < cast(f32)(y+30) {
        if left_pressed { game.ui.window_dragging = true; game.ui.window_drag_target = 3; game.ui.window_drag_off_x = cast(int)mouse.x - x; game.ui.window_drag_off_y = cast(int)mouse.y - y }
    }
    if game.ui.window_dragging && game.ui.window_drag_target == 3 {
        if rl.IsMouseButtonDown(rl.MouseButton(0)) {
            game.ui.build_x = cast(int)mouse.x - game.ui.window_drag_off_x
            game.ui.build_y = cast(int)mouse.y - game.ui.window_drag_off_y
            x = game.ui.build_x; y = game.ui.build_y
        } else if left_released { game.ui.window_dragging = false; game.ui.window_drag_target = 0 }
    }
    mx := cast(int)mouse.x
    my := cast(int)mouse.y

    start_y := y + 40
    slot_h := 36
    spacing := 4
    // Build a temporary list of placeable stacks (indices)
    placeables : [INV_MAX_SLOTS]int
    count := 0
    for i in 0..<INV_MAX_SLOTS {
        st := game.inventory.slots[i]
        if st.id == .None || !item_is_placeable(st.id) do continue
        placeables[count] = i
        count += 1
    }
    // Clamp scroll
    max_visible_px := panel_h - 80 // leave room bottom for help text
    per_entry := slot_h + spacing
    max_start_index := count - (max_visible_px / per_entry)
    if max_start_index < 0 { max_start_index = 0 }
    if game.ui.build_scroll > max_start_index { game.ui.build_scroll = max_start_index }
    start_index := game.ui.build_scroll
    drawn := 0
    for list_i in start_index ..< count {
        inv_i := placeables[list_i]
        stack := game.inventory.slots[inv_i]
        sy := start_y + drawn * per_entry
        if sy + slot_h > start_y + max_visible_px do break
        rl.DrawRectangle(cast(i32)(x+10), cast(i32)sy, cast(i32)(panel_w-20), cast(i32)slot_h, rl.Color{40,55,40,255})
        hovered := mx >= x+10 && mx < x+10+panel_w-20 && my >= sy && my < sy+slot_h
        if hovered { draw_tile_outline_rectangle(cast(i32)(x+10), cast(i32)sy, cast(i32)(panel_w-20), cast(i32)slot_h, rl.GREEN) }
        draw_item_icon(stack.id, x+16, sy+8, 3)
        txt := rl.TextFormat("%d", cast(i32)stack.count)
        rl.DrawText(txt, cast(i32)(x+54), cast(i32)(sy+12), 12, rl.LIME)
        if stack.id == game.ui.build_selected {
            rl.DrawText("[SEL]", cast(i32)(x+panel_w-70), cast(i32)(sy+12), 12, rl.YELLOW)
        }
        // Show dependency lock for Tree_Grower if no Crafting_Bench placed yet; block selection
        locked := stack.id == .Tree_Grower && !world_has_terrain(&game.world, .Crafting_Bench)
        if locked {
            rl.DrawRectangle(cast(i32)(x+10), cast(i32)sy, cast(i32)(panel_w-20), cast(i32)slot_h, rl.Color{0,0,0,140})
            rl.DrawText("Requires Bench", cast(i32)(x+24), cast(i32)(sy+12), 12, rl.RED)
        } else if hovered && left_pressed {
            // Play UI click sound for build menu selection
            _ = event_queue_push(&game.events, Event{
                type = .Play_Sound,
                source_id = PLAYER_ID,
                target_id = PLAYER_ID,
                data = Sound_Event{ sound_id = .UI_CLICK, volume = -1 }
            })
            
            prev := game.ui.build_selected
            game.ui.build_selected = stack.id
            if prev != stack.id { debugf("Build select %s", item_name(stack.id)) }
        }
        drawn += 1
    }
    // Scroll bar (simple)
    if count > 0 {
        bar_x := x + panel_w - 14
        bar_y := start_y
        bar_h := max_visible_px
        draw_tile_outline_rectangle(cast(i32)bar_x, cast(i32)bar_y, 8, cast(i32)bar_h, rl.DARKGREEN)
        if max_start_index > 0 {
            ratio := cast(f32)game.ui.build_scroll / cast(f32)max_start_index
            if ratio < 0 { ratio = 0 } else if ratio > 1 { ratio = 1 }
            knob_h := 20
            knob_y := bar_y + cast(int)(ratio * cast(f32)(bar_h - knob_h))
            rl.DrawRectangle(cast(i32)bar_x+1, cast(i32)knob_y, 6, cast(i32)knob_h, rl.GREEN)
        } else {
            rl.DrawRectangle(cast(i32)bar_x+1, cast(i32)bar_y+2, 6, cast(i32)(bar_h-4), rl.GREEN)
        }
    }
    rl.DrawText("R to close", cast(i32)(x+panel_w-110), cast(i32)(y+panel_h-22), 10, rl.GRAY)
    rl.DrawText("Scroll: wheel", cast(i32)(x+10), cast(i32)(y+panel_h-22), 10, rl.GRAY)
}

// ---------------- Item Icon Drawing ------------------

draw_item_icon :: proc(id: Item_ID, x, y: int, scale: int) {
    #partial switch id {
    case .Mine_Wand: {
        pattern : [7][5]u8 = {
            {' ',' ','M',' ',' '},
            {' ',' ','M',' ',' '},
            {' ',' ','M',' ',' '},
            {' ',' ','M',' ',' '},
            {' ',' ','W',' ',' '},
            {' ',' ','W',' ',' '},
            {' ','W','W','W',' '},
        }
        for row in 0..<7 {
            for col in 0..<5 {
                ch := pattern[row][col]
                if ch == ' ' do continue
                colr := rl.GOLD
                if ch == 'W' { colr = rl.BROWN } else if ch == 'M' { colr = rl.PURPLE }
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, colr)
            }
        }
        return
    }
    case .Sword: {
        pattern : [7][3]u8 = {
            {' ','S',' '},
            {' ','S',' '},
            {' ','S',' '},
            {'S','S','S'},
            {' ','S',' '},
            {' ','S',' '},
            {' ','S',' '},
        }
        for row in 0..<7 {
            for col in 0..<3 {
                ch := pattern[row][col]
                if ch == ' ' do continue
                colr := rl.LIGHTGRAY
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, colr)
            }
        }
        return
    }
    case .Potion_Health, .Potion_Mana: {
        body := rl.RED
        if id == .Potion_Mana { body = rl.BLUE }
        for row in 0..<7 {
            for col in 0..<5 {
                if row == 0 { if col != 2 do continue }
                else if row == 1 { if col < 1 || col > 3 do continue }
                else if row < 6 { if col == 0 || col == 4 do continue }
                c := body
                if row < 3 { c = rl.Color{c.r, c.g, c.b, 180} }
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, c)
            }
        }
        return
    }
    case .Wood_Log: {
        // Simple 5x5 brown block with darker bark stripes
        for row in 0..<5 {
            for col in 0..<5 {
                colr := rl.BROWN
                if col == 1 || col == 3 { colr = rl.Color{colr.r, colr.g, colr.b, 220} }
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, colr)
            }
        }
        return
    }
    case .Leaf: {
        // Simple leafy puff with lighter interior
        for row in 0..<5 {
            for col in 0..<5 {
                if (row == 0 || row == 4) && (col == 0 || col == 4) do continue
                colr := rl.Color{34,180,34,255}
                if row == 0 || row == 4 || col == 0 || col == 4 { colr = rl.Color{34,150,34,255} }
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, colr)
            }
        }
        return
    }
    case .Crafting_Bench: {
        // Bench top (5x3) + shadow + legs + small tool sprites (hammer + saw)
        for row in 0..<3 {
            for col in 0..<5 {
                top := rl.Color{160,82,45,255}
                if row == 0 { top = rl.Color{180,100,55,255} }
                if col == 2 && row == 1 { top = rl.Color{190,140,90,255} }
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, top)
            }
        }
        // Shadow band
        for col in 0..<5 {
            rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + 3*scale), cast(i32)scale, cast(i32)scale, rl.Color{120,60,30,255})
        }
        // Legs
        rl.DrawRectangle(cast(i32)(x + 0*scale), cast(i32)(y + 4*scale), cast(i32)scale, cast(i32)scale, rl.BROWN)
        rl.DrawRectangle(cast(i32)(x + 4*scale), cast(i32)(y + 4*scale), cast(i32)scale, cast(i32)scale, rl.BROWN)
        // Hammer head (gray) on left of top
        rl.DrawRectangle(cast(i32)(x + 1*scale), cast(i32)(y + 1*scale), cast(i32)scale, cast(i32)scale, rl.LIGHTGRAY)
        rl.DrawRectangle(cast(i32)(x + 1*scale), cast(i32)(y + 2*scale), cast(i32)scale, cast(i32)scale, rl.BROWN)
        // Saw blade (lightgray) and handle (brown)
        rl.DrawRectangle(cast(i32)(x + 3*scale), cast(i32)(y + 1*scale), cast(i32)scale, cast(i32)scale, rl.LIGHTGRAY)
        rl.DrawRectangle(cast(i32)(x + 3*scale), cast(i32)(y + 2*scale), cast(i32)scale, cast(i32)scale, rl.BROWN)
        return
    }
    case .Tree_Grower: {
        // device: base + upward arrow
        for row in 0..<5 {
            for col in 0..<5 {
                colr := rl.Color{160,82,45,255}
                if row == 4 { colr = rl.Color{120,60,30,255} }
                rl.DrawRectangle(cast(i32)(x + col*scale), cast(i32)(y + row*scale), cast(i32)scale, cast(i32)scale, colr)
            }
        }
        // arrow (green) on top row 0-2-4 pattern
        mid := x + 2*scale
        rl.DrawRectangle(cast(i32)mid, cast(i32)(y-1*scale), cast(i32)scale, cast(i32)scale, rl.GREEN)
        rl.DrawRectangle(cast(i32)(mid-scale), cast(i32)(y), cast(i32)(scale*3), cast(i32)scale, rl.GREEN)
        return
    }
    case .Stone_Block: {
        for row in 0..<5 { for col in 0..<5 {
            shade := u8(120 + row*4 + col*3)
            rl.DrawRectangle(cast(i32)(x+col*scale), cast(i32)(y+row*scale), cast(i32)scale, cast(i32)scale, rl.Color{shade,shade,shade,255})
        }}
        return
    }
    case .Grass_Turf: {
        for row in 0..<5 { for col in 0..<5 {
            colr := rl.Color{34,139,34,255}
            if row == 4 { colr = rl.Color{90,60,30,255} } // dirt base
            rl.DrawRectangle(cast(i32)(x+col*scale), cast(i32)(y+row*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Plank: {
        // Simple narrow tan plank with dark edges
        for row in 0..<5 { for col in 0..<5 {
            colr := rl.Color{194,155,100,255}
            if col == 0 || col == 4 { colr = rl.Color{160,120,70,255} }
            if row == 2 { colr = rl.Color{205,165,110,255} }
            rl.DrawRectangle(cast(i32)(x+col*scale), cast(i32)(y+row*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Iron_Ore: {
        // Iron: Dark metallic gray with chunky square pattern
        pattern : [5][5]u8 = {
            {'d','d','m','d','d'},
            {'d','m','h','m','d'},
            {'m','h','h','h','m'},
            {'d','m','h','m','d'},
            {'d','d','m','d','d'},
        }
        for r in 0..<5 { for c in 0..<5 {
            ch := pattern[r][c]; if ch == ' ' do continue
            colr := rl.Color{120,120,130,255}  // Medium gray
            if ch == 'd' { colr = rl.Color{60,60,70,255} }     // Dark gray
            else if ch == 'h' { colr = rl.Color{180,180,190,255} } // Light gray
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Silver_Ore: {
        // Silver: Bright white/blue with cross/star pattern
        pattern : [5][5]u8 = {
            {' ',' ','h',' ',' '},
            {' ','s','h','s',' '},
            {'h','h','h','h','h'},
            {' ','s','h','s',' '},
            {' ',' ','h',' ',' '},
        }
        for r in 0..<5 { for c in 0..<5 {
            ch := pattern[r][c]; if ch == ' ' do continue
            colr := rl.Color{220,240,255,255}   // Bright silver-blue
            if ch == 's' { colr = rl.Color{200,220,240,255} }  // Medium silver
            else if ch == 'h' { colr = rl.Color{255,255,255,255} } // Pure white
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Gold_Ore: {
        // Gold: Bright yellow with diamond pattern
        pattern : [5][5]u8 = {
            {' ',' ','h',' ',' '},
            {' ','h','g','h',' '},
            {'h','g','d','g','h'},
            {' ','h','g','h',' '},
            {' ',' ','h',' ',' '},
        }
        for r in 0..<5 { for c in 0..<5 {
            ch := pattern[r][c]; if ch == ' ' do continue
            colr := rl.Color{255,200,0,255}     // Bright gold
            if ch == 'd' { colr = rl.Color{160,120,0,255} }    // Dark gold
            else if ch == 'h' { colr = rl.Color{255,255,100,255} } // Bright yellow
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Gold_Rare_Ore: {
        // Rare Gold: Bright magenta with sparkly scattered pattern
        pattern : [5][5]u8 = {
            {'h',' ','g',' ','h'},
            {' ','g','s','g',' '},
            {'g','s','s','s','g'},
            {' ','g','s','g',' '},
            {'h',' ','g',' ','h'},
        }
        for r in 0..<5 { for c in 0..<5 {
            ch := pattern[r][c]; if ch == ' ' do continue
            colr := rl.Color{255,100,255,255}   // Bright magenta
            if ch == 'g' { colr = rl.Color{200,0,200,255} }    // Dark magenta 
            else if ch == 'h' { colr = rl.Color{255,200,255,255} } // Light magenta
            else if ch == 's' { colr = rl.Color{255,255,255,255} } // White sparkles
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Smelter: {
        // 5x5 furnace: dark casing with orange slit and chimney
        for r in 0..<5 { for c in 0..<5 {
            colr := rl.Color{90,90,100,255}
            if r == 0 { colr = rl.Color{70,70,80,255} }
            if r == 2 && c >=1 && c <=3 { colr = rl.Color{220,110,20,255} }
            if r == 1 && c == 2 { colr = rl.Color{150,80,15,255} }
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        // chimney extension (one pixel row above if scale allows)
        if scale >= 2 {
            rl.DrawRectangle(cast(i32)(x+2*scale), cast(i32)(y-1*scale), cast(i32)scale, cast(i32)scale, rl.Color{60,60,70,255})
        }
        return
    }
    case .Iron_Bucket: {
        // 5x6 bucket: metal walls with opening at top
        pattern : [6][5]u8 = {
            {' ','T','T','T',' '}, // handle/top rim
            {'B','B','B','B','B'}, // rim
            {'B','L','L','L','B'}, // walls with lava content
            {'B','L','L','L','B'},
            {'B','L','L','L','B'},
            {' ','B','B','B',' '}, // bottom
        }
        for r in 0..<6 { for c in 0..<5 {
            ch := pattern[r][c]; if ch == ' ' do continue
            colr := rl.Color{120,120,130,255} // base metal
            if ch == 'T' { colr = rl.Color{100,100,110,255} } // darker handle
            else if ch == 'L' { colr = rl.Color{0,0,0,0} } // transparent for now
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case .Hell_Key: {
        // Hell Key: Demonic key with glowing red and black design
        pattern : [7][5]u8 = {
            {' ',' ','R',' ',' '},
            {' ','R','R','R',' '},
            {'R','R','R','R','R'},
            {'B','B','B',' ',' '},
            {'R','R','B',' ',' '},
            {'B','B','B',' ',' '},
            {'R','R','B',' ',' '},
        }
        for r in 0..<7 { for c in 0..<5 {
            ch := pattern[r][c]; if ch == ' ' do continue
            colr := rl.Color{255,0,0,255}      // Bright red
            if ch == 'B' { colr = rl.Color{20,20,20,255} }  // Black details
            rl.DrawRectangle(cast(i32)(x+c*scale), cast(i32)(y+r*scale), cast(i32)scale, cast(i32)scale, colr)
        }}
        return
    }
    case: {}
    }
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)(scale*4), cast(i32)(scale*4), rl.GRAY)
}

    // ---------------- Crafting UI ------------------
    render_popup_buttons :: proc(game: ^Game_State) {
        base_x := 8
        base_y := 8
        size := 32
        pad := 6
        mouse := rl.GetMousePosition()
    for i in 0..<4 {
            bx := base_x + i*(size+pad)
            by := base_y
            rl.DrawRectangle(cast(i32)bx, cast(i32)by, cast(i32)size, cast(i32)size, rl.Color{45,45,60,200})
            draw_tile_outline_rectangle(cast(i32)bx, cast(i32)by, cast(i32)size, cast(i32)size, rl.Color{90,90,130,255})
            hovered := mouse.x >= cast(f32)bx && mouse.x < cast(f32)(bx+size) && mouse.y >= cast(f32)by && mouse.y < cast(f32)(by+size)
            switch i {
            case 0: // Inventory
                rl.DrawRectangle(cast(i32)(bx+8), cast(i32)(by+10), 16, 12, rl.BROWN)
                draw_tile_outline_rectangle(cast(i32)(bx+8), cast(i32)(by+10), 16, 12, rl.Color{110,70,40,255})
                rl.DrawRectangle(cast(i32)(bx+14), cast(i32)(by+14), 4, 4, rl.GOLD)
            case 1: // Character
                rl.DrawCircle(cast(i32)(bx+16), cast(i32)(by+12), 6, rl.LIGHTGRAY)
                rl.DrawRectangle(cast(i32)(bx+10), cast(i32)(by+18), 12, 10, rl.LIGHTGRAY)
            case 2: // Build hammer
                rl.DrawLine(cast(i32)(bx+10), cast(i32)(by+22), cast(i32)(bx+22), cast(i32)(by+10), rl.LIGHTGRAY)
                rl.DrawRectangle(cast(i32)(bx+18), cast(i32)(by+6), 8, 8, rl.BROWN)
            case 3: // Crafting gear ring
                rl.DrawCircleLines(cast(i32)(bx+16), cast(i32)(by+16), 10, rl.SKYBLUE)
                gear_x := [4]int{0,10,0,-10}
                gear_y := [4]int{-10,0,10,0}
                for a in 0..<4 {
                    rl.DrawCircle(cast(i32)(bx+16+gear_x[a]/2), cast(i32)(by+16+gear_y[a]/2), 3, rl.SKYBLUE)
                }
            }
            active := false
            if i == 0 { active = game.ui.bag_open }
            else if i == 1 { active = game.ui.character_open }
            else if i == 2 { active = game.ui.build_menu_open }
            else if i == 3 { active = game.ui.crafting_open }
            if active {
                draw_tile_outline_rectangle(cast(i32)bx, cast(i32)by, cast(i32)size, cast(i32)size, rl.GOLD)
            } else if hovered {
                draw_tile_outline_rectangle(cast(i32)bx, cast(i32)by, cast(i32)size, cast(i32)size, rl.Color{130,130,180,255})
            }
            if hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
                switch i {
                case 0: game.ui.bag_open = !game.ui.bag_open
                case 1: game.ui.character_open = !game.ui.character_open
                case 2: game.ui.build_menu_open = !game.ui.build_menu_open
                case 3: game.ui.crafting_open = !game.ui.crafting_open
                }
            }
        }
    }

    render_crafting_menu :: proc(game: ^Game_State) {
    panel_w := CRAFT_MENU_W + 260 // wider to separate resource grid
    panel_h := CRAFT_MENU_H + 120 // taller for spacing
        x := game.ui.craft_x
        y := game.ui.craft_y
        left_pressed := rl.IsMouseButtonPressed(rl.MouseButton(0))
        left_released := rl.IsMouseButtonReleased(rl.MouseButton(0))
        rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{30,40,55,230})
        draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{100,140,190,255})
        rl.DrawText("Crafting", cast(i32)(x+10), cast(i32)(y+6), 20, rl.SKYBLUE)
        // Drag bar
        mouse := rl.GetMousePosition(); mx := cast(int)mouse.x; my := cast(int)mouse.y
        if mx >= x && mx < x+panel_w && my >= y && my < y+28 {
            if left_pressed { game.ui.window_dragging = true; game.ui.window_drag_target = 4; game.ui.window_drag_off_x = mx - x; game.ui.window_drag_off_y = my - y }
        }
        if game.ui.window_dragging && game.ui.window_drag_target == 4 {
            if rl.IsMouseButtonDown(rl.MouseButton(0)) {
                game.ui.craft_x = mx - game.ui.window_drag_off_x
                game.ui.craft_y = my - game.ui.window_drag_off_y
                x = game.ui.craft_x; y = game.ui.craft_y
            } else if left_released { game.ui.window_dragging = false; game.ui.window_drag_target = 0 }
        }
        // Dropdown for recipes
        drop_x := x + 12
        drop_y := y + 36
        drop_w := 200
        drop_h := 28
        rl.DrawRectangle(cast(i32)drop_x, cast(i32)drop_y, cast(i32)drop_w, cast(i32)drop_h, rl.Color{50,60,80,255})
        draw_tile_outline_rectangle(cast(i32)drop_x, cast(i32)drop_y, cast(i32)drop_w, cast(i32)drop_h, rl.SKYBLUE)
        sel := game.ui.crafting_selected_index
        if sel >= 0 && sel < len(craft_recipes) {
            rl.DrawText(item_name(craft_recipes[sel].product), cast(i32)(drop_x+8), cast(i32)(drop_y+6), 16, rl.WHITE)
        } else {
            rl.DrawText("Select Recipe", cast(i32)(drop_x+8), cast(i32)(drop_y+6), 16, rl.GRAY)
        }
        // Dropdown toggle arrow area
        arrow_w := 24
        rl.DrawRectangle(cast(i32)(drop_x+drop_w-arrow_w), cast(i32)drop_y, cast(i32)arrow_w, cast(i32)drop_h, rl.Color{70,80,100,255})
        rl.DrawTriangle(rl.Vector2{cast(f32)(drop_x+drop_w-arrow_w/2-6), cast(f32)(drop_y+10)}, rl.Vector2{cast(f32)(drop_x+drop_w-arrow_w/2+6), cast(f32)(drop_y+10)}, rl.Vector2{cast(f32)(drop_x+drop_w-arrow_w/2), cast(f32)(drop_y+drop_h-8)}, rl.SKYBLUE)
        over_drop := mx >= drop_x && mx < drop_x+drop_w && my >= drop_y && my < drop_y+drop_h
        if over_drop && left_pressed { game.ui.crafting_dropdown_open = !game.ui.crafting_dropdown_open }
        list_max_h := 6*drop_h
        extra_offset_y := 0
        if game.ui.crafting_dropdown_open {
            list_h := min(list_max_h, (len(craft_recipes))*drop_h)
            // Draw list first
            rl.DrawRectangle(cast(i32)drop_x, cast(i32)(drop_y+drop_h), cast(i32)drop_w, cast(i32)list_h, rl.Color{40,50,70,255})
            draw_tile_outline_rectangle(cast(i32)drop_x, cast(i32)(drop_y+drop_h), cast(i32)drop_w, cast(i32)list_h, rl.SKYBLUE)
            for i in 0..<len(craft_recipes) {
                iy := drop_y + drop_h + i*drop_h
                if iy + drop_h > drop_y + drop_h + list_h do break
                hovered := mx >= drop_x && mx < drop_x+drop_w && my >= iy && my < iy+drop_h
                if hovered { rl.DrawRectangle(cast(i32)drop_x, cast(i32)iy, cast(i32)drop_w, cast(i32)drop_h, rl.Color{70,90,120,255}) }
                draw_item_icon(craft_recipes[i].product, drop_x+4, iy+4, 2)
                locked := craft_recipes[i].product != .Crafting_Bench && !world_has_terrain(&game.world, .Crafting_Bench)
                name_col := rl.WHITE
                if locked { name_col = rl.Color{150,150,150,255} }
                rl.DrawText(item_name(craft_recipes[i].product), cast(i32)(drop_x+40), cast(i32)(iy+6), 16, name_col)
                if hovered && left_pressed {
                    if !locked {
                        game.ui.crafting_selected_index = i
                        game.ui.crafting_dropdown_open = false
                    }
                }
            }
            extra_offset_y = list_h + 8
        }
        // Resource inventory grid (right side)
    grid_x := drop_x + drop_w + 40 // push to right of detail column
    grid_y := y + 36
        cols := 10
        slot_sz := 22
        for i in 0..<INV_MAX_SLOTS {
            sx := grid_x + (i%cols)*slot_sz
            sy := grid_y + (i/cols)*slot_sz
            rl.DrawRectangle(cast(i32)sx, cast(i32)sy, cast(i32)(slot_sz-2), cast(i32)(slot_sz-2), rl.Color{55,65,85,255})
            draw_tile_outline_rectangle(cast(i32)sx, cast(i32)sy, cast(i32)(slot_sz-2), cast(i32)(slot_sz-2), rl.Color{80,90,110,255})
            stack := game.inventory.slots[i]
            if stack.id != .None {
                draw_item_icon(stack.id, sx+4, sy+2, 2)
                if stack.count > 1 {
                    txt := rl.TextFormat("%d", cast(i32)stack.count)
                    rl.DrawText(txt, cast(i32)(sx+6), cast(i32)(sy+slot_sz-14), 10, rl.WHITE)
                }
            }
        }
        // Selected recipe detail / combiner (left panel area under dropdown)
        detail_x := drop_x
    detail_y := drop_y + drop_h + 12 + extra_offset_y
        detail_w := drop_w
        detail_h := panel_h - (detail_y - y) - 20
        rl.DrawRectangle(cast(i32)detail_x, cast(i32)detail_y, cast(i32)detail_w, cast(i32)detail_h, rl.Color{45,55,75,255})
        draw_tile_outline_rectangle(cast(i32)detail_x, cast(i32)detail_y, cast(i32)detail_w, cast(i32)detail_h, rl.Color{80,120,170,255})
    if sel >= 0 && sel < len(craft_recipes) {
            r := &craft_recipes[sel]
            draw_item_icon(r.product, detail_x+detail_w-40, detail_y+8, 3)
            rl.DrawText(item_name(r.product), cast(i32)(detail_x+12), cast(i32)(detail_y+8), 16, rl.WHITE)
            // Ingredients list
            ing_y := detail_y + 40
            can := can_craft(&game.inventory, r)
            unlocked := true
            if r.product != .Crafting_Bench { unlocked = world_has_terrain(&game.world, .Crafting_Bench) }
            if !unlocked { can = false }
            for ing in r.ingredients {
                have := 0
                for si in 0..<INV_MAX_SLOTS { s := game.inventory.slots[si]; if s.id == ing.id { have += cast(int)s.count } }
                need := cast(int)ing.count
                col := rl.RED; if have >= need { col = rl.LIGHTGRAY }
                rl.DrawText(rl.TextFormat("%s %d/%d", item_name(ing.id), cast(i32)have, cast(i32)need), cast(i32)(detail_x+12), cast(i32)ing_y, 14, col)
                ing_y += 20
            }
            // Craft button
            btn_w := detail_w - 24
            btn_h := 30
            btn_x := detail_x + 12
            btn_y := detail_y + detail_h - btn_h - 12
            col := rl.Color{70,100,140,255}
            if can { col = rl.Color{60,140,90,255} }
            rl.DrawRectangle(cast(i32)btn_x, cast(i32)btn_y, cast(i32)btn_w, cast(i32)btn_h, col)
            draw_tile_outline_rectangle(cast(i32)btn_x, cast(i32)btn_y, cast(i32)btn_w, cast(i32)btn_h, rl.BLACK)
            rl.DrawText("Craft", cast(i32)(btn_x+btn_w/2-24), cast(i32)(btn_y+8), 16, rl.WHITE)
            over_btn := mx >= btn_x && mx < btn_x+btn_w && my >= btn_y && my < btn_y+btn_h
            if over_btn && left_pressed && can && unlocked { craft_attempt(game, r.product) }
            if !unlocked {
                rl.DrawText("Requires Bench placed", cast(i32)(btn_x+4), cast(i32)(btn_y-20), 12, rl.RED)
            }
        }
        rl.DrawText("ESC/Q closes", cast(i32)(x+panel_w-140), cast(i32)(y+panel_h-24), 10, rl.GRAY)
    }

    

// ---------------- Debug Menu (Development Only) ------------------
render_debug_menu :: proc(game: ^Game_State) {
    panel_w := WINDOW_WIDTH
    panel_h := WINDOW_HEIGHT / 2
    x := 0
    y := WINDOW_HEIGHT / 2
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{20,20,30,220})
    draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{180,90,200,255})
    rl.DrawText("DEBUG (F3)", cast(i32)(x+10), cast(i32)(y+8), 18, rl.PURPLE)
    
    // Current level info
    level_info := ""
    if game.level_offset == 0 {
        level_info = "Surface (0)"
    } else if game.level_offset > 0 {
        level_info = fmt.aprintf("Cave Level %d", game.level_offset)
    } else {
        level_info = fmt.aprintf("Sky Level %d", -game.level_offset)
    }
    rl.DrawText(cstring(raw_data(level_info)), cast(i32)(x+150), cast(i32)(y+8), 14, rl.YELLOW)
    mouse := rl.GetMousePosition()
    mx := cast(int)mouse.x; my := cast(int)mouse.y
    // Layout variables
    line_h := 18
    section_pad := 10

    // Complete list of all useful terrains (manually maintained but complete)  
    terrains := []Terrain_Type{
        .Air, .Grass, .Stone, .Water, .Lava, .Magic_Lava, 
        .Wood, .Leaves, .Crafting_Bench, .Tree_Grower, 
        .Iron, .Silver, .Gold, .Gold_Rare, .Smelter
    }
    terrain_section_height := 14 /*title*/ + 20 /*gap*/ + 60 /*terrain rows*/ + 10 /*bottom pad*/
    terrain_section_top := y + panel_h - terrain_section_height

    // Level switching section (top)
    level_y := y + 34
    rl.DrawText("Level Switching:", cast(i32)(x+10), cast(i32)level_y, 14, rl.SKYBLUE)
    level_y += 18
    rl.DrawText("0: Surface  1-8: Cave Levels", cast(i32)(x+10), cast(i32)level_y, 12, rl.LIGHTGRAY)
    level_y += 14
    rl.DrawText("F1-F2,F4: Sky Levels  -/+: Navigate", cast(i32)(x+10), cast(i32)level_y, 12, rl.LIGHTGRAY)
    level_y += 14
    rl.DrawText("(Debug menu must be open)", cast(i32)(x+10), cast(i32)level_y, 12, rl.LIGHTGRAY)
    level_y += 18

    // Cheats section
    cheats_title_y := level_y + 8
    rl.DrawText("Cheats", cast(i32)(x+10), cast(i32)cheats_title_y, 14, rl.PINK)
    cheat_line_y := cheats_title_y + 20
    // Fly toggle
    state_txt : cstring = "OFF"
    if game.player.can_fly { state_txt = "ON" }
    fly_label := rl.TextFormat("Fly: %s", state_txt)
    fly_col := rl.LIGHTGRAY
    fly_hovered := mx >= x+10 && mx < x+panel_w-10 && my >= cheat_line_y && my < cheat_line_y+line_h
    if fly_hovered { fly_col = rl.WHITE }
    rl.DrawText(fly_label, cast(i32)(x+10), cast(i32)cheat_line_y, 14, fly_col)
    if fly_hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
        game.player.can_fly = !game.player.can_fly
    }
    cheat_line_y += line_h
    
    // Health controls
    health_label := rl.TextFormat("Health: %d/%d", game.player.health, game.player.max_health)
    health_hovered := mx >= x+10 && mx < x+panel_w-10 && my >= cheat_line_y && my < cheat_line_y+line_h
    health_col := rl.LIGHTGRAY; if health_hovered { health_col = rl.WHITE }
    rl.DrawText(health_label, cast(i32)(x+10), cast(i32)cheat_line_y, 14, health_col)
    if health_hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
        // Left click decreases, right click increases
        if rl.IsMouseButtonPressed(rl.MouseButton(1)) { // right click
            if game.player.health < game.player.max_health { game.player.health += 1 }
        } else { // left click
            if game.player.health > 0 { game.player.health -= 1 }
        }
    }
    cheat_line_y += line_h
    
    // Mana controls  
    mana_label := rl.TextFormat("Mana: %d/%d", game.player.mana, game.player.max_mana)
    mana_hovered := mx >= x+10 && mx < x+panel_w-10 && my >= cheat_line_y && my < cheat_line_y+line_h
    mana_col := rl.LIGHTGRAY; if mana_hovered { mana_col = rl.WHITE }
    rl.DrawText(mana_label, cast(i32)(x+10), cast(i32)cheat_line_y, 14, mana_col)
    if mana_hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
        // Left click decreases, right click increases
        if rl.IsMouseButtonPressed(rl.MouseButton(1)) { // right click
            if game.player.mana < game.player.max_mana { game.player.mana += 1 }
        } else { // left click
            if game.player.mana > 0 { game.player.mana -= 1 }
        }
    }

    // Items section (middle) — clipped to above terrain section - DYNAMIC!
    items_title_y := cheat_line_y + line_h + section_pad
    rl.DrawText("Items (Dynamic)", cast(i32)(x+10), cast(i32)items_title_y, 14, rl.GOLD)
    items_start_y := items_title_y + 18
    
    // Complete list of all items (manually maintained but complete)
    items := []Item_ID{
        .Sword, .Potion_Health, .Potion_Mana, .Mine_Wand, 
        .Wood_Log, .Leaf, .Crafting_Bench, .Tree_Grower, 
        .Stone_Block, .Grass_Turf, .Plank, 
        .Iron_Ore, .Silver_Ore, .Gold_Ore, .Gold_Rare_Ore, 
        .Smelter, .Iron_Bucket, .Hell_Key
    }
    
    // Multi-column layout for items (more columns due to wider screen)
    items_area_x := x + 10
    items_area_y := items_start_y
    available_height := terrain_section_top - items_area_y - 20 // keep padding above terrain section
    max_rows := available_height / line_h
    if max_rows < 1 { max_rows = 1 }
    
    columns := 6  // More columns since we have full screen width
    col_width := (panel_w - 40) / columns  // 40 = 20 margin + 20 spacing
    rows_per_col := (len(items) + columns - 1) / columns  // ceiling division
    
    for idx in 0..<len(items) {
        col_idx := idx / rows_per_col
        row_idx := idx % rows_per_col
        
        // Skip if this would go beyond available space
        if row_idx >= max_rows { continue }
        
        item_x := items_area_x + col_idx * col_width
        item_y := items_area_y + row_idx * line_h
        
        txt := item_name(items[idx])
        col := rl.LIGHTGRAY
        hovered := mx >= item_x && mx < item_x + col_width - 10 && my >= item_y && my < item_y + line_h
        if hovered { col = rl.WHITE }
        rl.DrawText(txt, cast(i32)item_x, cast(i32)item_y, 14, col)
        if hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
            add_item_to_inventory(&game.inventory, items[idx], 1)
        }
    }

    // Terrain spawning section (set tile under mouse to chosen type) at bottom - DYNAMIC!
    terr_y := terrain_section_top
    rl.DrawText("Set Tile (click world) Dynamic", cast(i32)(x+10), cast(i32)terr_y, 14, rl.SKYBLUE)
    terr_y += 20
    
    // Multi-column layout for terrains too
    terrain_columns := 5
    terrain_col_width := (panel_w - 40) / terrain_columns
    terrain_rows_per_col := (len(terrains) + terrain_columns - 1) / terrain_columns
    
    for i in 0..<len(terrains) {
        col_idx := i / terrain_rows_per_col
        row_idx := i % terrain_rows_per_col
        
        terrain_x := x + 10 + col_idx * terrain_col_width
        terrain_y := terr_y + row_idx * line_h
        
        if terrain_y > y+panel_h-30 { break }
        
        name := terrain_name(terrains[i])
        hovered := mx >= terrain_x && mx < terrain_x + terrain_col_width - 10 && my >= terrain_y && my < terrain_y + line_h
        col := rl.LIGHTGRAY; if hovered { col = rl.WHITE }
        rl.DrawText(name, cast(i32)terrain_x, cast(i32)terrain_y, 14, col)
        if hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
            game.ui.debug_place_active = true
            game.ui.debug_place_terrain = terrains[i]
        }
    }
    rl.DrawText("L-Click world to place", cast(i32)(x+10), cast(i32)(y+panel_h-18), 12, rl.GRAY)
}

// ---------------- Health and Mana Orbs (Diablo Style) ------------------

render_health_orb :: proc(x, y, radius: int, current, max_value: i32) {
    // Calculate fill percentage
    fill_ratio := cast(f32)current / cast(f32)max_value
    if fill_ratio < 0 { fill_ratio = 0 }
    if fill_ratio > 1 { fill_ratio = 1 }
    
    // Outer orb border (dark red)
    rl.DrawCircle(cast(i32)x, cast(i32)y, cast(f32)radius, rl.Color{80, 20, 20, 255})
    
    // Main orb background (black)
    rl.DrawCircle(cast(i32)x, cast(i32)y, cast(f32)(radius-3), rl.Color{20, 10, 10, 255})
    
    // Health fill from bottom up
    fill_height := cast(int)(cast(f32)(radius*2-6) * fill_ratio)
    if fill_height > 0 {
        // Create a gradient effect with multiple red circles
        for i in 0..<fill_height {
            alpha := cast(f32)i / cast(f32)fill_height
            intensity := 0.6 + 0.4 * alpha
            
            red := cast(u8)(200 * intensity)
            green := cast(u8)(20 * intensity)
            blue := cast(u8)(20 * intensity)
            
            circle_y := y + (radius-3) - i
            circle_radius := cast(f32)(radius-3) * (1.0 - cast(f32)i / cast(f32)(radius*2-6))
            
            if circle_radius > 0 {
                rl.DrawCircle(cast(i32)x, cast(i32)circle_y, circle_radius, rl.Color{red, green, blue, 200})
            }
        }
    }
    
    // Highlight effect on top
    rl.DrawCircle(cast(i32)x, cast(i32)(y-radius/3), cast(f32)(radius/3), rl.Color{255, 100, 100, 80})
    
    // Text overlay showing current/max
    text := rl.TextFormat("%d/%d", current, max_value)
    text_width := rl.MeasureText(text, 12)
    rl.DrawText(text, cast(i32)(x - cast(int)text_width/2), cast(i32)(y-6), 12, rl.WHITE)
}

render_mana_orb :: proc(x, y, radius: int, current, max_value: i32) {
    // Calculate fill percentage
    fill_ratio := cast(f32)current / cast(f32)max_value
    if fill_ratio < 0 { fill_ratio = 0 }
    if fill_ratio > 1 { fill_ratio = 1 }
    
    // Outer orb border (dark purple)
    rl.DrawCircle(cast(i32)x, cast(i32)y, cast(f32)radius, rl.Color{40, 20, 80, 255})
    
    // Main orb background (black)
    rl.DrawCircle(cast(i32)x, cast(i32)y, cast(f32)(radius-3), rl.Color{10, 10, 20, 255})
    
    // Mana fill from bottom up
    fill_height := cast(int)(cast(f32)(radius*2-6) * fill_ratio)
    if fill_height > 0 {
        // Create a gradient effect with multiple purple circles
        for i in 0..<fill_height {
            alpha := cast(f32)i / cast(f32)fill_height
            intensity := 0.6 + 0.4 * alpha
            
            red := cast(u8)(100 * intensity)
            green := cast(u8)(50 * intensity)
            blue := cast(u8)(200 * intensity)
            
            circle_y := y + (radius-3) - i
            circle_radius := cast(f32)(radius-3) * (1.0 - cast(f32)i / cast(f32)(radius*2-6))
            
            if circle_radius > 0 {
                rl.DrawCircle(cast(i32)x, cast(i32)circle_y, circle_radius, rl.Color{red, green, blue, 200})
            }
        }
    }
    
    // Highlight effect on top
    rl.DrawCircle(cast(i32)x, cast(i32)(y-radius/3), cast(f32)(radius/3), rl.Color{150, 100, 255, 80})
    
    // Text overlay showing current/max
    text := rl.TextFormat("%d/%d", current, max_value)
    text_width := rl.MeasureText(text, 12)
    rl.DrawText(text, cast(i32)(x - cast(int)text_width/2), cast(i32)(y-6), 12, rl.WHITE)
}

render_health_mana_orbs :: proc(game: ^Game_State) {
    screen_w := cast(int)rl.GetScreenWidth()
    screen_h := cast(int)rl.GetScreenHeight()
    
    orb_radius := 30
    margin := 20
    
    // Health orb on bottom left
    health_x := margin + orb_radius
    health_y := screen_h - margin - orb_radius
    render_health_orb(health_x, health_y, orb_radius, game.player.health, game.player.max_health)
    
    // Mana orb on bottom right
    mana_x := screen_w - margin - orb_radius
    mana_y := screen_h - margin - orb_radius
    render_mana_orb(mana_x, mana_y, orb_radius, game.player.mana, game.player.max_mana)
}

// ---------------- Sound Debug Window (F12) ------------------
render_sound_debug_window :: proc(game: ^Game_State) {
    screen_w := cast(int)rl.GetScreenWidth()
    screen_h := cast(int)rl.GetScreenHeight()
    
    // Large centered window
    panel_w := screen_w - 100  // Leave 50px margin on each side
    panel_h := screen_h - 100  // Leave 50px margin top/bottom
    x := 50
    y := 50
    
    // Background
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{15,15,25,240})
    draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{255,140,0,255})
    
    // Title
    rl.DrawText("SOUND DEBUG (F12)", cast(i32)(x+20), cast(i32)(y+15), 24, rl.ORANGE)
    rl.DrawText("Left-click: decrease volume | Right-click: increase volume | Click sound names to test", cast(i32)(x+20), cast(i32)(y+45), 14, rl.LIGHTGRAY)
    
    mouse := rl.GetMousePosition()
    mx := cast(int)mouse.x; my := cast(int)mouse.y
    
    content_y := y + 75
    line_h := 20
    
    // Volume controls section
    rl.DrawText("Volume Controls", cast(i32)(x+20), cast(i32)content_y, 18, rl.YELLOW)
    content_y += 25
    
    master_label := rl.TextFormat("Master Volume: %.0f%%", game.audio.master_volume * 100)
    master_hovered := mx >= x+20 && mx < x+300 && my >= content_y && my < content_y+line_h
    master_col := rl.LIGHTGRAY; if master_hovered { master_col = rl.WHITE }
    rl.DrawText(master_label, cast(i32)(x+20), cast(i32)content_y, 16, master_col)
    if master_hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
        // Play UI click sound for volume adjustment
        _ = event_queue_push(&game.events, Event{
            type = .Play_Sound,
            source_id = PLAYER_ID,
            target_id = PLAYER_ID,
            data = Sound_Event{ sound_id = .UI_CLICK, volume = -1 }
        })
        
        new_vol := game.audio.master_volume + (rl.IsMouseButtonPressed(rl.MouseButton(1)) ? 0.1 : -0.1)
        set_master_volume(&game.audio, clamp(new_vol, 0.0, 1.0))
    }
    content_y += line_h + 5
    
    sfx_label := rl.TextFormat("SFX Volume: %.0f%%", game.audio.sfx_volume * 100)
    sfx_hovered := mx >= x+20 && mx < x+300 && my >= content_y && my < content_y+line_h
    sfx_col := rl.LIGHTGRAY; if sfx_hovered { sfx_col = rl.WHITE }
    rl.DrawText(sfx_label, cast(i32)(x+20), cast(i32)content_y, 16, sfx_col)
    if sfx_hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
        // Play UI click sound for volume adjustment
        _ = event_queue_push(&game.events, Event{
            type = .Play_Sound,
            source_id = PLAYER_ID,
            target_id = PLAYER_ID,
            data = Sound_Event{ sound_id = .UI_CLICK, volume = -1 }
        })
        
        new_vol := game.audio.sfx_volume + (rl.IsMouseButtonPressed(rl.MouseButton(1)) ? 0.1 : -0.1)
        set_sfx_volume(&game.audio, clamp(new_vol, 0.0, 1.0))
    }
    content_y += line_h + 20
    
    // Audio system status
    rl.DrawText("Audio System Status", cast(i32)(x+20), cast(i32)content_y, 18, rl.YELLOW)
    content_y += 25
    
    status_text := game.audio.initialized ? "INITIALIZED" : "NOT INITIALIZED"
    status_col := game.audio.initialized ? rl.GREEN : rl.RED
    status_label := rl.TextFormat("Audio Device: %s", status_text)
    rl.DrawText(status_label, cast(i32)(x+20), cast(i32)content_y, 14, status_col)
    content_y += 18
    
    loaded_label := rl.TextFormat("Static Sounds: %d / %d | Dynamic Sounds: %d", game.audio.sound_count, MAX_LOADED_SOUNDS, game.audio.dynamic_sound_count)
    rl.DrawText(loaded_label, cast(i32)(x+20), cast(i32)content_y, 14, rl.LIGHTGRAY)
    content_y += 18
    
    scroll_label := rl.TextFormat("Scroll: %d | Use mouse wheel to scroll", game.ui.sound_debug_scroll)
    rl.DrawText(scroll_label, cast(i32)(x+20), cast(i32)content_y, 12, rl.GRAY)
    content_y += 25
    
    // Sound test grid with much more space
    rl.DrawText("Sound Test Grid - Click to Play", cast(i32)(x+20), cast(i32)content_y, 18, rl.YELLOW)
    content_y += 30
    
    // Handle scroll input
    if game.ui.sound_debug_open {
        scroll_wheel := rl.GetMouseWheelMove()
        if scroll_wheel != 0 {
            game.ui.sound_debug_scroll -= cast(int)(scroll_wheel * 3) // 3 lines per wheel step
        }
        // Clamp scroll
        max_scroll := max(0, game.audio.dynamic_sound_count - 20) // Show about 20 sounds at once
        game.ui.sound_debug_scroll = clamp(game.ui.sound_debug_scroll, 0, max_scroll)
    }
    
    // Get category color
    get_category_color :: proc(category: string) -> rl.Color {
        if strings.contains(category, "Wand") do return rl.Color{255,100,100,255}
        if strings.contains(category, "UI") do return rl.Color{100,255,100,255}
        if strings.contains(category, "Combat") do return rl.Color{255,150,100,255}
        if strings.contains(category, "Environment") do return rl.Color{200,200,100,255}
        if strings.contains(category, "Magic") do return rl.Color{255,100,255,255}
        if strings.contains(category, "Heal") do return rl.Color{100,255,200,255}
        if strings.contains(category, "Buff") do return rl.Color{150,255,150,255}
        if strings.contains(category, "Debuff") do return rl.Color{255,150,150,255}
        if strings.contains(category, "Poison") do return rl.Color{180,100,180,255}
        if strings.contains(category, "Movement") do return rl.Color{255,255,100,255}
        if strings.contains(category, "Battle") do return rl.Color{255,200,100,255}
        return rl.Color{150,150,150,255}
    }
    
    // Render scrollable sound list using pre-computed categories
    visible_area_height := panel_h - (content_y - y) - 50
    line_height := 18
    scroll_offset := game.ui.sound_debug_scroll * line_height
    
    current_y := content_y - scroll_offset
    
    // Render all categories from the pre-computed array
    for cat_idx in 0..<game.audio.category_count {
        category := &game.audio.categories[cat_idx]
        
        // Category header
        if current_y >= content_y - line_height && current_y < content_y + visible_area_height {
            category_color := get_category_color(category.name)
            rl.DrawText(cstring(raw_data(category.name)), cast(i32)(x+20), cast(i32)current_y, 16, category_color)
        }
        current_y += 22
        
        // Category sounds
        for i in 0..<category.sound_count {
            if current_y >= content_y + visible_area_height do break
            
            sound_idx := category.sound_indices[i]
            
            if current_y >= content_y - line_height {
                sound := &game.audio.dynamic_sounds[sound_idx]
                
                sound_col := sound.loaded ? rl.LIGHTGRAY : rl.Color{80,80,80,255}
                
                sound_hovered := mx >= x+40 && mx < x + panel_w - 40 && 
                                my >= current_y && my < current_y + line_height
                if sound_hovered && sound.loaded { sound_col = rl.WHITE }
                
                // Add status indicator and volume info
                status_indicator := sound.loaded ? "[✓]" : "[✗]"
                volume_info := rl.TextFormat("%.0f%%", sound.volume * 100)
                full_text := rl.TextFormat("%s %s (%s)", status_indicator, sound.name, volume_info)
                rl.DrawText(full_text, cast(i32)(x+40), cast(i32)current_y, 14, sound_col)
                
                if sound_hovered && sound.loaded && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
                    play_dynamic_sound(&game.audio, sound_idx)
                }
            }
            
            current_y += line_height
        }
        
        current_y += 10  // Extra space after category
        
        if current_y >= content_y + visible_area_height do break
    }
    
    // Footer
    footer_y := y + panel_h - 30
    rl.DrawText("Press F12 to close", cast(i32)(x + panel_w - 150), cast(i32)footer_y, 12, rl.GRAY)
}

// Render game over screen
render_game_over_screen :: proc(game: ^Game_State) {
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    
    // Semi-transparent dark overlay
    rl.DrawRectangle(0, 0, screen_w, screen_h, rl.Color{0, 0, 0, 180})
    
    // Game Over text
    title := "GAME OVER"
    title_size := rl.MeasureText(cstring(raw_data(title)), 48)
    title_x := (screen_w - title_size) / 2
    title_y := screen_h / 2 - 100
    
    // Animated title color (cycling through purple, gold, white)
    time := game.elapsed_time
    cycle := cast(int)(time * 2) % 3
    title_color : rl.Color
    switch cycle {
    case 0: // Purple
        title_color = rl.Color{180, 80, 255, 255}
    case 1: // Gold
        title_color = rl.Color{255, 215, 0, 255}
    case 2: // White
        title_color = rl.Color{255, 255, 255, 255}
    }
    
    rl.DrawText(cstring(raw_data(title)), cast(i32)title_x, cast(i32)title_y, 48, title_color)
    
    // Restart button
    button_text := "Click to Restart"
    button_size := rl.MeasureText(cstring(raw_data(button_text)), 24)
    button_x := (screen_w - button_size) / 2
    button_y := screen_h / 2 + 50
    button_w := button_size + 40
    button_h := 40
    
    mouse := rl.GetMousePosition()
    button_hovered := mouse.x >= cast(f32)button_x - 20 && 
                     mouse.x < cast(f32)(button_x + button_w - 20) &&
                     mouse.y >= cast(f32)button_y - 10 && 
                     mouse.y < cast(f32)button_y + cast(f32)button_h - 10
    
    button_color := button_hovered ? rl.Color{100, 100, 255, 255} : rl.Color{80, 80, 200, 255}
    rl.DrawRectangle(cast(i32)(button_x - 20), cast(i32)(button_y - 10), cast(i32)button_w, cast(i32)button_h, button_color)
    rl.DrawText(cstring(raw_data(button_text)), cast(i32)button_x, cast(i32)button_y, 24, rl.WHITE)
    
    // Handle restart click
    if button_hovered && rl.IsMouseButtonPressed(rl.MouseButton(0)) {
        restart_game(game)
    }
}

// Render comprehensive statistics screen
render_stats_screen :: proc(game: ^Game_State) {
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    
    // Semi-transparent dark overlay
    rl.DrawRectangle(0, 0, screen_w, screen_h, rl.Color{0, 0, 0, 180})
    
    // Stats panel
    panel_w := 600
    panel_h := 500
    x := cast(f32)((cast(int)screen_w - panel_w) / 2)
    y := cast(f32)((cast(int)screen_h - panel_h) / 2)
    
    // Panel background
    rl.DrawRectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{25, 25, 35, 230})
    draw_tile_outline_rectangle(cast(i32)x, cast(i32)y, cast(i32)panel_w, cast(i32)panel_h, rl.GOLD)
    
    // Title
    title := "GAME STATISTICS"
    title_size := rl.MeasureText(cstring(raw_data(title)), 24)
    title_x := x + cast(f32)((panel_w - cast(int)title_size) / 2)
    rl.DrawText(cstring(raw_data(title)), cast(i32)title_x, cast(i32)y + 20, 24, rl.GOLD)
    
    // Content area with scrolling
    content_x := x + 30
    content_y := y + 60
    content_h := cast(f32)(panel_h - 80) // Leave space for title and footer
    line_height := 25
    
    // Helper function to draw a stat line
    draw_stat_line :: proc(label: string, value: string, x, y: f32, color: rl.Color = rl.WHITE) {
        rl.DrawText(cstring(raw_data(label)), cast(i32)x, cast(i32)y, 16, color)
        rl.DrawText(cstring(raw_data(value)), cast(i32)(x + 200), cast(i32)y, 16, color)
    }
    
    // Helper function to draw a section header
    draw_section_header :: proc(header: string, x, y: f32, color: rl.Color) {
        rl.DrawText(cstring(raw_data(header)), cast(i32)x, cast(i32)y, 18, color)
    }
    
    // Calculate total content height to determine max scroll
    total_lines := 0
    total_lines += 1 // "RUN STATISTICS" header
    total_lines += 4 // 4 run stat lines
    total_lines += 1 // "CURRENT RUN" header  
    total_lines += 4 // 4 current run lines
    total_lines += 1 // "RESOURCE STATISTICS" header
    total_lines += 4 // 4 resource stat lines
    total_lines += 1 // "ITEM COLLECTION" header
    total_lines += 6 // 6 item collection lines
    total_lines += 1 // "COMBAT STATISTICS" header
    total_lines += 2 // 2 combat stat lines
    
    // Add spacing between sections
    total_lines += 4 // Extra spacing
    
    max_scroll := max(0, total_lines - cast(int)(content_h / cast(f32)line_height))
    if game.ui.stats_scroll > max_scroll {
        game.ui.stats_scroll = max_scroll
    }
    
    // Set up scissor test to clip content to panel
    rl.BeginScissorMode(cast(i32)x, cast(i32)content_y, cast(i32)panel_w, cast(i32)content_h)
    
    current_y := cast(int)content_y - (game.ui.stats_scroll * line_height)
    line_index := 0
    
    // Run Statistics
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + cast(f32)content_h) {
        draw_section_header("RUN STATISTICS", content_x, cast(f32)current_y, rl.YELLOW)
    }
    current_y += line_height + 5
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + cast(f32)content_h) {
        draw_stat_line("Total Runs:", fmt.tprintf("%d", game.stats.total_runs), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + cast(f32)content_h) {
        draw_stat_line("Total Deaths:", fmt.tprintf("%d", game.stats.total_deaths), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + cast(f32)content_h) {
        draw_stat_line("Best Depth:", fmt.tprintf("%d", game.stats.best_depth_reached), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Total Time:", fmt.tprintf("%.1f hours", game.stats.total_time_played / 3600.0), content_x, cast(f32)current_y)
    }
    current_y += line_height + 10
    line_index += 1
    
    // Current Run
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_section_header("CURRENT RUN", content_x, cast(f32)current_y, rl.GREEN)
    }
    current_y += line_height + 5
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Run Time:", fmt.tprintf("%.1f minutes", game.stats.current_run_time / 60.0), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Blocks Destroyed:", fmt.tprintf("%d", game.stats.current_run_blocks_destroyed), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Items Picked Up:", fmt.tprintf("%d", game.stats.current_run_items_picked_up), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Mana Spent:", fmt.tprintf("%d", game.stats.current_run_mana_spent), content_x, cast(f32)current_y)
    }
    current_y += line_height + 10
    line_index += 1
    
    // Resource Statistics
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_section_header("RESOURCE STATISTICS", content_x, cast(f32)current_y, rl.ORANGE)
    }
    current_y += line_height + 5
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Total Blocks Destroyed:", fmt.tprintf("%d", game.stats.total_blocks_destroyed), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Total Items Picked Up:", fmt.tprintf("%d", game.stats.total_items_picked_up), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Total Mining Actions:", fmt.tprintf("%d", game.stats.total_mining_actions), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Total Mana Spent:", fmt.tprintf("%d", game.stats.total_mana_spent), content_x, cast(f32)current_y)
    }
    current_y += line_height + 10
    line_index += 1
    
    // Item Collection
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_section_header("ITEM COLLECTION", content_x, cast(f32)current_y, rl.BLUE)
    }
    current_y += line_height + 5
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Wood Logs:", fmt.tprintf("%d", game.stats.wood_logs_collected), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Stone Blocks:", fmt.tprintf("%d", game.stats.stone_blocks_collected), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Iron Ore:", fmt.tprintf("%d", game.stats.iron_ore_collected), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Silver Ore:", fmt.tprintf("%d", game.stats.silver_ore_collected), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Gold Ore:", fmt.tprintf("%d", game.stats.gold_ore_collected), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Rare Gold Ore:", fmt.tprintf("%d", game.stats.gold_rare_ore_collected), content_x, cast(f32)current_y)
    }
    current_y += line_height + 10
    line_index += 1
    
    // Combat Statistics
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_section_header("COMBAT STATISTICS", content_x, cast(f32)current_y, rl.RED)
    }
    current_y += line_height + 5
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Lava Damage Taken:", fmt.tprintf("%d", game.stats.total_lava_damage_taken), content_x, cast(f32)current_y)
    }
    current_y += line_height
    line_index += 1
    
    if line_index >= game.ui.stats_scroll && current_y < cast(int)(content_y + content_h) {
        draw_stat_line("Deaths by Lava:", fmt.tprintf("%d", game.stats.total_deaths_by_lava), content_x, cast(f32)current_y)
    }
    current_y += line_height + 10
    line_index += 1
    
    rl.EndScissorMode()
    
    // Footer (always visible)
    footer_y := cast(int)(y + cast(f32)panel_h - 30)
    rl.DrawText("Press F10 to close", cast(i32)(x + cast(f32)panel_w - 150), cast(i32)footer_y, 12, rl.GRAY)
    
    // Persistence indicator
    persistence_text := "Stats persist between sessions"
    rl.DrawText(cstring(raw_data(persistence_text)), cast(i32)content_x, cast(i32)footer_y, 12, rl.GREEN)
    
    // Scroll instructions
    scroll_text := "Use mouse wheel or arrow keys to scroll"
    rl.DrawText(cstring(raw_data(scroll_text)), cast(i32)content_x, cast(i32)(footer_y - 15), 10, rl.GRAY)
}

// Render save status indicator
render_save_status :: proc(game: ^Game_State) {
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    
    // Check if save file exists
    save_exists := false
    if data, ok := os.read_entire_file_from_path("gnipahellir_save.dat", context.allocator); ok == nil {
        save_exists = true
        delete(data)
    }
    
    // Draw save status in top-right corner
    status_text := save_exists ? "SAVE" : "NO SAVE"
    status_color := save_exists ? rl.GREEN : rl.RED
    text_size := rl.MeasureText(cstring(raw_data(status_text)), 16)
    
    x := cast(f32)(screen_w - text_size - 10)
    y := cast(f32)10
    
    rl.DrawText(cstring(raw_data(status_text)), cast(i32)x, cast(i32)y, 16, status_color)
    
    // Draw save controls hint
    controls_text := "F5: Save | F9: New Game"
    controls_size := rl.MeasureText(cstring(raw_data(controls_text)), 12)
    controls_x := cast(f32)(screen_w - controls_size - 10)
    controls_y := y + 20
    
    rl.DrawText(cstring(raw_data(controls_text)), cast(i32)controls_x, cast(i32)controls_y, 12, rl.GRAY)
}

// Render main menu
render_main_menu :: proc(game: ^Game_State) {
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    
    // Dark overlay
    rl.DrawRectangle(0, 0, screen_w, screen_h, rl.Color{0, 0, 0, 200})
    
    // Title
    title := "GNIPAHELLIR"
    title_size := rl.MeasureText(cstring(raw_data(title)), 48)
    title_x := cast(i32)((cast(int)screen_w - cast(int)title_size) / 2)
    title_y := cast(i32)(screen_h / 4)
    rl.DrawText(cstring(raw_data(title)), title_x, title_y, 48, rl.GOLD)
    
    // Subtitle
    subtitle := "A Roguelike Mining Adventure"
    subtitle_size := rl.MeasureText(cstring(raw_data(subtitle)), 20)
    subtitle_x := cast(i32)((cast(int)screen_w - cast(int)subtitle_size) / 2)
    subtitle_y := title_y + 60
    rl.DrawText(cstring(raw_data(subtitle)), subtitle_x, subtitle_y, 20, rl.GRAY)
    
    // Check if save file exists
    save_exists := false
    if data, ok := os.read_entire_file_from_path("gnipahellir_save.dat", context.allocator); ok == nil {
        save_exists = true
        delete(data)
    }
    
    // Menu options
    menu_x := cast(i32)(screen_w / 2 - 100)
    menu_y := cast(i32)(screen_h / 2)
    menu_spacing := 40
    
    menu_options := []string{"New Game", "Load Game", "Settings", "Quit"}
    
    for i in 0..<len(menu_options) {
        option := menu_options[i]
        y := menu_y + cast(i32)(i * menu_spacing)
        
        // Dim "Load Game" option if no save file exists
        color := game.ui.menu_selection == i ? rl.GOLD : rl.WHITE
        if i == 1 && !save_exists { // Load Game option
            color = game.ui.menu_selection == i ? rl.Color{200, 150, 50, 255} : rl.GRAY
        }
        
        // Selection indicator
        if game.ui.menu_selection == i {
            rl.DrawText("> ", menu_x - 20, y, 20, rl.GOLD)
        }
        
        rl.DrawText(cstring(raw_data(option)), menu_x, y, 20, color)
        
        // Add status indicator for Load Game option
        if i == 1 {
            status_text := save_exists ? "(Available)" : "(No Save Found)"
            status_color := save_exists ? rl.GREEN : rl.RED
            rl.DrawText(cstring(raw_data(status_text)), menu_x + 120, y, 16, status_color)
        }
    }
    
    // Instructions
    instructions := "Use UP/DOWN arrows to navigate, ENTER to select"
    inst_size := rl.MeasureText(cstring(raw_data(instructions)), 16)
    inst_x := cast(i32)((cast(int)screen_w - cast(int)inst_size) / 2)
    inst_y := cast(i32)(screen_h - 50)
    rl.DrawText(cstring(raw_data(instructions)), inst_x, inst_y, 16, rl.GRAY)
}

// Render save/quit dialog
render_save_quit_dialog :: proc(game: ^Game_State) {
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    
    // Dark overlay
    rl.DrawRectangle(0, 0, screen_w, screen_h, rl.Color{0, 0, 0, 180})
    
    // Dialog box
    dialog_w := 400
    dialog_h := 200
    dialog_x := cast(i32)((cast(int)screen_w - dialog_w) / 2)
    dialog_y := cast(i32)((cast(int)screen_h - dialog_h) / 2)
    
    rl.DrawRectangle(dialog_x, dialog_y, cast(i32)dialog_w, cast(i32)dialog_h, rl.Color{25, 25, 35, 230})
    draw_tile_outline_rectangle(dialog_x, dialog_y, cast(i32)dialog_w, cast(i32)dialog_h, rl.GOLD)
    
    // Title
    title := "Save and Quit?"
    title_size := rl.MeasureText(cstring(raw_data(title)), 24)
    title_x := cast(i32)((cast(int)screen_w - cast(int)title_size) / 2)
    title_y := dialog_y + 30
    rl.DrawText(cstring(raw_data(title)), title_x, title_y, 24, rl.WHITE)
    
    // Message
    message := "Do you want to save your progress and quit?"
    msg_size := rl.MeasureText(cstring(raw_data(message)), 16)
    msg_x := cast(i32)((cast(int)screen_w - cast(int)msg_size) / 2)
    msg_y := title_y + 50
    rl.DrawText(cstring(raw_data(message)), msg_x, msg_y, 16, rl.GRAY)
    
    // Buttons
    button_y := dialog_y + 120
    button_spacing := 120
    
    // Save and Quit button
    save_text := "Save & Quit"
    save_color := game.ui.menu_selection == 0 ? rl.GOLD : rl.WHITE
    save_x := cast(i32)(cast(int)screen_w / 2 - button_spacing - 50)
    rl.DrawText(cstring(raw_data(save_text)), save_x, button_y, 18, save_color)
    
    // Cancel button
    cancel_text := "Cancel"
    cancel_color := game.ui.menu_selection == 1 ? rl.GOLD : rl.WHITE
    cancel_x := cast(i32)(cast(int)screen_w / 2 + 50)
    rl.DrawText(cstring(raw_data(cancel_text)), cancel_x, button_y, 18, cancel_color)
    
    // Instructions
    inst_text := "Use LEFT/RIGHT arrows, ENTER to confirm, ESC to cancel"
    inst_size := rl.MeasureText(cstring(raw_data(inst_text)), 14)
    inst_x := cast(i32)((cast(int)screen_w - cast(int)inst_size) / 2)
    inst_y := dialog_y + cast(i32)dialog_h - 30
    rl.DrawText(cstring(raw_data(inst_text)), inst_x, inst_y, 14, rl.GRAY)
}

// Render settings menu
render_settings_menu :: proc(game: ^Game_State) {
    screen_w := rl.GetScreenWidth()
    screen_h := rl.GetScreenHeight()
    
    // Dark overlay
    rl.DrawRectangle(0, 0, screen_w, screen_h, rl.Color{0, 0, 0, 200})
    
    // Settings panel
    panel_w := 500
    panel_h := 300
    panel_x := cast(i32)((cast(int)screen_w - panel_w) / 2)
    panel_y := cast(i32)((cast(int)screen_h - panel_h) / 2)
    
    rl.DrawRectangle(panel_x, panel_y, cast(i32)panel_w, cast(i32)panel_h, rl.Color{25, 25, 35, 230})
    draw_tile_outline_rectangle(panel_x, panel_y, cast(i32)panel_w, cast(i32)panel_h, rl.GOLD)
    
    // Title
    title := "SETTINGS"
    title_size := rl.MeasureText(cstring(raw_data(title)), 28)
    title_x := cast(i32)((cast(int)screen_w - cast(int)title_size) / 2)
    title_y := panel_y + 30
    rl.DrawText(cstring(raw_data(title)), title_x, title_y, 28, rl.GOLD)
    
    // Menu options
    menu_x := cast(i32)(screen_w / 2 - 100)
    menu_y := title_y + 80
    menu_spacing := 50
    
    menu_options := []string{"Back to Main Menu", "Reset Statistics"}
    
    for i in 0..<len(menu_options) {
        option := menu_options[i]
        y := menu_y + cast(i32)(i * menu_spacing)
        color := game.ui.menu_selection == i ? rl.GOLD : rl.WHITE
        
        // Selection indicator
        if game.ui.menu_selection == i {
            rl.DrawText("> ", menu_x - 20, y, 20, rl.GOLD)
        }
        
        rl.DrawText(cstring(raw_data(option)), menu_x, y, 20, color)
    }
    
    // Instructions
    instructions := "Use UP/DOWN arrows to navigate, ENTER to select, ESC to go back"
    inst_size := rl.MeasureText(cstring(raw_data(instructions)), 16)
    inst_x := cast(i32)((cast(int)screen_w - cast(int)inst_size) / 2)
    inst_y := panel_y + cast(i32)panel_h - 40
    rl.DrawText(cstring(raw_data(instructions)), inst_x, inst_y, 16, rl.GRAY)
}
