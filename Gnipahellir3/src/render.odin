package game

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

// ─── Draw Entry Point ─────────────────────────────────────────────────────────

draw_game :: proc(gs: ^Game_State, target: rl.RenderTexture2D) {
    profile_scope("draw_game")
    // The game renders at the fixed virtual resolution...
    rl.BeginTextureMode(target)
    rl.ClearBackground(rl.BLACK)

    // World renders through the zoom camera, scaled up into the supersampled
    // texture (fold SS into the camera so gameplay/input keep the 1:1 camera).
    world_cam := game_camera(gs)
    world_cam.offset = {world_cam.offset.x * SS_SCALE, world_cam.offset.y * SS_SCALE}
    world_cam.zoom  *= SS_SCALE
    rl.BeginMode2D(world_cam)
    draw_world(gs)
    draw_falling_blocks(gs)
    draw_mining_cracks(gs)
    draw_portals(gs)
    draw_placement_ghost(gs)
    draw_wand_target(gs)
    draw_reclaim_target(gs)
    draw_station_focus(gs)
    draw_player(&gs.player, gs.player_form, gs.player_step_visual_y)
    draw_enemies(&gs.enemies)
    draw_projectiles(&gs.projectiles)
    draw_particles(&gs.particles)
    draw_ritual(gs)
    draw_floating_text(&gs.floating_text)
    when GAME_DEBUG {
        if gs.ui.show_debug do draw_debug(gs)
    }
    rl.EndMode2D()

    // UI is screen-space (UI_W×UI_H logical); scale it up to the SS texture.
    rl.BeginMode2D(rl.Camera2D{zoom = SS_SCALE * UI_SCALE})
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

// Vertical camera deadzone (world px): the Y anchor only moves once the player
// leaves this band around it, so a jump arc (~3 tiles) stays inside and doesn't
// bob the view.  A little wider than a full jump so the whole arc is swallowed.
CAM_DEADZONE_Y :: f32(3.5 * CELL_SIZE)

// Zoom easing rate (1/s): higher = snappier. gs.zoom chases gs.zoom_target with
// frame-rate-independent exponential decay so a wheel notch glides in ~0.1-0.2 s
// instead of popping — which also feathers the clamp-release Y pan (see below).
ZOOM_EASE :: f32(18.0)

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
    // X follows the player exactly; Y tracks the deadzoned anchor (update_camera)
    // so jumping doesn't slide the view up and down.
    py := gs.cam_y
    return rl.Camera2D{
        target   = {clamp(px, half_w, f32(SCREEN_W) - half_w),
                    clamp(py, half_h, f32(SCREEN_H) - half_h)},
        offset   = {f32(SCREEN_W)*0.5, f32(SCREEN_H)*0.5},
        rotation = 0,
        zoom     = zoom,
    }
}

// The camera Y anchor: snap it straight to the player (level entry, spawn,
// teleport) so the view doesn't slide across the cut.
camera_snap_y :: proc(gs: ^Game_State) {
    gs.cam_y = (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    gs.player_step_visual_y = 0
}

// Advance the Y anchor with a vertical deadzone: it only moves when the player
// leaves the band, so a jump (arc inside the band) leaves the view still, while
// falling or climbing past the band drags it along.  Run each frame after the
// player moves.  At zoom 1.0 game_camera clamps Y to level-center anyway, so
// this is only felt when zoomed in.
update_camera :: proc(gs: ^Game_State) {
    // Ease the live zoom toward the wheel-set target. Because half_w/half_h (and
    // thus the edge clamp) are derived from zoom, gliding zoom also glides the
    // Y lurch you'd otherwise get when the clamp releases on the first notch.
    gs.zoom += (gs.zoom_target - gs.zoom) * (1 - math.exp(-ZOOM_EASE * gs.delta_time))

    py := (gs.player.pos.y + PLAYER_H*0.5) * CELL_SIZE
    if py < gs.cam_y - CAM_DEADZONE_Y do gs.cam_y = py + CAM_DEADZONE_Y
    if py > gs.cam_y + CAM_DEADZONE_Y do gs.cam_y = py - CAM_DEADZONE_Y
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
    Pixel_Gem,
    Pixel_Miner_Body,
    Pixel_Cloud,
    Pixel_Door,
    Pixel_Dirt,
    Pixel_Flower_Bed,
    Pixel_Blueprint_Chest,
}

@(rodata)
tile_draw_style := #partial [Tile_Type]Draw_Style{
    .Wood        = .Pixel_Wood,
    .Leaves      = .Pixel_Leaves,
    .Flower      = .Pixel_Flower,
    .Emerald_Ore = .Pixel_Gem,
    .Jade_Ore    = .Pixel_Gem,
    .Diamond_Ore = .Pixel_Gem,
    .Hel_Gem_Ore = .Pixel_Gem,
    .Miner_Body  = .Pixel_Miner_Body,
    .Cloud       = .Pixel_Cloud,
    .Door        = .Pixel_Door,
    .Dirt        = .Pixel_Dirt,
    .Flower_Bed  = .Pixel_Flower_Bed,
    .Sky_Blueprint_Chest = .Pixel_Blueprint_Chest,
    .Blueprint_Chest_A   = .Pixel_Blueprint_Chest,
    .Blueprint_Chest_B   = .Pixel_Blueprint_Chest,
    .Blueprint_Chest_C   = .Pixel_Blueprint_Chest,
    // all others default to .Solid (zero value)
}

// Stations read as magical in-world: a dark base, a breathing glow in the
// station's color, and the same pixel-art icon the bag shows.  Zero alpha
// (absent) = not a station.  update_ambience also reads this table to shed
// rising sparks off station tiles.
@(rodata)
station_glow := #partial [Tile_Type]rl.Color{
    .Crafting_Bench = {255, 200, 90, 255},   // hearth gold
    .Tree_Grower    = {110, 230, 110, 255},  // living green
    .Smelter        = {255, 120, 30, 255},   // furnace ember
    .Sky_Altar      = {130, 200, 255, 255},  // sky blue
    .Dvergr_Forge   = {255, 150, 60, 255},   // forge fire
    .Rune_Altar     = {190, 120, 255, 255},  // rune purple
    .Dimension_Spawner      = {80, 255, 220, 255},  // dimensional teal
    .Dimension_Spawner_Gold = {255, 225, 100, 255}, // gilded shimmer
    .Dimension_Spawner_Runic = {210, 140, 255, 255}, // runic violet
    .Auto_Miner             = {120, 255, 210, 255}, // the snake's beating heart
    .Silo                   = {200, 210, 225, 255}, // cold iron sheen
    .Barrel                 = {190, 140, 80,  255}, // warm oak
}

// ─── World / Terrain ──────────────────────────────────────────────────────────

// Outline drawn on every solid tile (not sky/void) — a test grid.  The camera
// works in virtual pixels (a tile is CELL_SIZE units), so GRID_LINE_PX is the
// on-screen line width in virtual px; we divide by the zoom so the line stays a
// constant width (and doesn't balloon or thrash) as you zoom.  Drawn as a quad
// via DrawRectangleLinesEx — a plain DrawRectangleLines is a 1px framebuffer
// hairline that flickers under the supersample.  Alpha + px are the knobs.
GRID_LINE    :: rl.Color{0, 0, 0, 80}
GRID_LINE_PX :: f32(2.5)
// Grid fades in with zoom: hidden at/below LO (dense = noise), full at/above HI.
GRID_FADE_LO :: f32(1.6)
GRID_FADE_HI :: f32(2.6)

// Ground-item blueprint pulse: radians/sec for the glow sine wave.
BLUEPRINT_PULSE_SPEED :: f32(4.0)

draw_world :: proc(gs: ^Game_State) {
    w := &gs.world
    grid_thick := GRID_LINE_PX / max(gs.zoom, ZOOM_MIN)
    grid_fade  := clamp((gs.zoom - GRID_FADE_LO) / (GRID_FADE_HI - GRID_FADE_LO), 0, 1)
    grid_col   := GRID_LINE
    grid_col.a  = u8(f32(GRID_LINE.a) * grid_fade)
    draw_grid  := grid_col.a > 0
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            idx := grid_idx(x, y)
            t   := w.terrain[idx]
            px  := i32(x * CELL_SIZE)
            py  := i32(y * CELL_SIZE)
            draw_tile(gs, t, x, y)

            if draw_grid && t != .Air && t != .Void {
                rl.DrawRectangleLinesEx({f32(px), f32(py), CELL_SIZE, CELL_SIZE}, grid_thick, grid_col)
            }

            // World item drop: small glinting square
            it := w.items[idx]
            if it != .None && w.item_counts[idx] > 0 {
                if is_blueprint(it) {
                    // Blueprints pulse in a brightened version of their own
                    // seal color (bronze/silver/gold/sky — see items.odin) so
                    // each tier's glow reads apart, with a dark halo behind it
                    // so the ring shows against the light-blue sky instead of
                    // blending into it.
                    pulse    := (math.sin(gs.elapsed_time * BLUEPRINT_PULSE_SPEED) + 1) * 0.5
                    grow     := i32(pulse * 5)
                    halo_ext := grow + 2
                    rl.DrawRectangle(px + 2 - halo_ext, py + 2 - halo_ext, 6 + halo_ext*2, 6 + halo_ext*2, rl.Color{0, 0, 0, 100})
                    base := item_table[it].color
                    glow_col := rl.Color{
                        u8(clamp(f32(base.r) * 1.3 + 40, 0, 255)),
                        u8(clamp(f32(base.g) * 1.3 + 40, 0, 255)),
                        u8(clamp(f32(base.b) * 1.3 + 40, 0, 255)),
                        u8(150 + pulse * 105),
                    }
                    rl.DrawRectangle(px + 2 - grow, py + 2 - grow, 6 + grow*2, 6 + grow*2, glow_col)
                }
                rl.DrawRectangle(px + 2, py + 2, 6, 6, item_table[it].color)
                rl.DrawRectangleLinesEx({f32(px) + 1, f32(py) + 1, 8, 8}, 1, rl.WHITE)
            }
        }
    }
    // The workbench, like the blueprint chest, is wider than its one-cell
    // collision footprint and needs a clean overlay pass after the grid.
    draw_crafting_benches(gs)
    // Blueprint chests deliberately spill beyond one 10px terrain cell.  Draw
    // them after the grid so neighboring backdrop cells cannot crop the coffer.
    draw_blueprint_chests(gs)
    // The surface descent shaft breaks the grass line as a raw Void slot —
    // dress its lip into a proper cave mouth (surface level only).
    if gs.level_index == LEVEL_SURFACE do draw_shaft_mouth(gs)
    // Cloud puffs go over everything tile-drawn so their round bulges merge
    // across cells instead of being clipped by neighboring Air rects.
    if gs.level_index == LEVEL_SKY do draw_cloud_layer(gs)
}

// ─── Surface descent shaft: the cave mouth ────────────────────────────────────
//
// The entrance shaft (world.odin §5) punches a raw 2-wide .Void column through
// the grass line down to the cave.  Left bare it reads as a flat black slot cut
// into the green — no depth, no edge.  This render-only pass gives it a mouth:
// earthen throat walls that darken into the dark, a cut-soil lip where the grass
// is sheared open, a lit grass rim, and an apron of scuffed earth that spreads
// onto the neighboring blocks and diminishes the further you are from the shaft
// on the X axis.  It keys off the terrain itself — Void bordered by ground in
// the surface-cap band — so it dresses any surface shaft, not a hardcoded
// column.  Reads state, never mutates.
draw_shaft_mouth :: proc(gs: ^Game_State) {
    w := &gs.world
    WALL_PX   :: i32(3)
    REACH     :: SHAFT_APRON_REACH              // brown scuff hugs the lip; blocks
                                               // past this read as normal grass.
                                               // Shared with mining's rock+dirt yield.
    APRON_A   :: f32(90)                        // apron alpha at the shaft edge
    grass_rim := rl.Color{78, 190, 78, 255}    // grass edge lit by open sky
    soil      := rl.Color{96, 66, 38, 0}        // scuffed topsoil (alpha per tile)
    span := f32(CAVE_TOP - SURFACE_Y)
    for y in SURFACE_Y ..< CAVE_TOP {
        for x in 0 ..< GRID_W {
            if w.terrain[grid_idx(x, y)] != .Void do continue
            px := i32(x * CELL_SIZE)
            py := i32(y * CELL_SIZE)
            // Throat wall darkens with depth: fresh topsoil at the rim sinking
            // toward near-black as it drops into the cave.
            d := clamp(f32(y - SURFACE_Y) / span, 0, 1)
            wall := rl.Color{u8(104 - 76*d), u8(72 - 52*d), u8(40 - 28*d), 255}
            top_mouth := y == SURFACE_Y && get_tile(w, x, y - 1) == .Air
            for dir in ([]int{-1, 1}) {
                nx := x + dir
                if nx < 0 || nx >= GRID_W do continue
                nt := w.terrain[grid_idx(nx, y)]
                if nt == .Void || nt == .Air do continue   // shaft, not a wall
                // Apron first (behind): scuffed earth onto the blocks, alpha
                // falling off tile-by-tile with X distance from the shaft.
                for k in 0 ..< REACH {
                    gx := x + dir*(k+1)
                    if gx < 0 || gx >= GRID_W do break
                    gt := w.terrain[grid_idx(gx, y)]
                    if gt == .Void || gt == .Air do break
                    s := soil
                    // Ease-out (squared) so the scuff hugs the lip and reads as
                    // gone well before REACH — a linear falloff stays half-lit at
                    // the midpoint and looks flat across the whole span.
                    t := 1 - f32(k)/f32(REACH)
                    s.a = u8(APRON_A * t * t)
                    rl.DrawRectangle(i32(gx*CELL_SIZE), py, CELL_SIZE, CELL_SIZE, s)
                }
                // Then the crisp mouth on top: throat wall on the void edge, a
                // cut-soil edge on the walling block, a grass rim at the lip.
                wall_x := dir < 0 ? px : px + CELL_SIZE - WALL_PX
                edge_x := dir < 0 ? px - WALL_PX : px + CELL_SIZE
                rl.DrawRectangle(wall_x, py, WALL_PX, CELL_SIZE, wall)
                rl.DrawRectangle(edge_x, py, WALL_PX, CELL_SIZE, wall)
                if top_mouth do rl.DrawRectangle(edge_x, py, WALL_PX, 2, grass_rim)

                // Detail so the throat reads as living earth, not a flat band:
                // grit embedded in the walls, and fine roots dangling from the
                // sheared lip into the shaft for the first couple of rows.
                hh := whash(u32(x)*2654435761 ~ u32(nx)*40503 ~ u32(y)*668265263)
                grit := rl.Color{u8(128 - 84*d), u8(104 - 68*d), u8(72 - 48*d), 255}
                rl.DrawRectangle(wall_x + i32(hh % u32(WALL_PX)),      py + i32((hh>>2) % u32(CELL_SIZE)), 1, 1, grit)
                rl.DrawRectangle(edge_x + i32((hh>>4) % u32(WALL_PX)), py + i32((hh>>6) % u32(CELL_SIZE)), 1, 1, grit)
                if y <= SURFACE_Y + 1 {
                    root   := rl.Color{96, 66, 36, 230}
                    root_x := dir < 0 ? px + 1 : px + CELL_SIZE - 2
                    rlen   := i32(3 + hh % 5)
                    for ry in i32(0) ..< rlen {
                        wob := i32((hh >> u32(ry)) & 1)
                        rl.DrawRectangle(root_x + (dir < 0 ? wob : -wob), py + ry, 1, 1, root)
                    }
                }
            }
        }
    }
}

// Clouds breathe and sway: each tile is a cluster of overlapping circles
// whose radius and center ride slow per-tile sine waves.  Contiguous cloud
// tiles merge into one billowy bank; single tiles read as small puffs.
draw_cloud_layer :: proc(gs: ^Game_State) {
    w := &gs.world
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if w.terrain[grid_idx(x, y)] != .Cloud do continue
            h := whash(u32(x) * 374761393) ~ whash(u32(y) * 668265263)
            breathe := math.sin(gs.elapsed_time*0.9 + f32(h % 628)*0.01)
            sway    := math.sin(gs.elapsed_time*0.5 + f32(h % 314)*0.02)
            cx := f32(x*CELL_SIZE) + CELL_SIZE*0.5 + sway*1.5
            cy := f32(y*CELL_SIZE) + CELL_SIZE*0.5
            r  := f32(CELL_SIZE) * (0.60 + 0.05*breathe)
            body := rl.Color{242, 246, 255, 240}
            rl.DrawCircleV({cx, cy + 1.5}, r, {205, 215, 240, 225})       // under-shade
            rl.DrawCircleV({cx - 1.5, cy - 1}, r*0.90, body)
            rl.DrawCircleV({cx + 2, cy - 0.5}, r*0.75, body)
            rl.DrawCircleV({cx - r*0.3, cy - r*0.4}, r*0.45, {255, 255, 255, 210})
        }
    }
}

// Blocks cut loose from their anchor, mid-slide toward the ground (gravity.odin).
// A falling Wood cell reuses the exact atlas variant selected at its original
// static coordinate; without this, the trunk visibly changed texture mid-fall.
// Read-only: the pool is advanced in update_gravity, never here.
draw_falling_blocks :: proc(gs: ^Game_State) {
    for b in gs.gravity.blocks {
        if !b.active do continue
        bx := b.x * CELL_SIZE
        by := i32(b.y * CELL_SIZE)
        #partial switch b.tile {
        case .Wood:
            if gs.assets.loaded {
                sp  := wood_variant(int(b.source_x), int(b.source_y))
                src := tile_atlas_rect(sp)
                dst := rl.Rectangle{f32(bx), f32(by), CELL_SIZE, CELL_SIZE}
                rl.DrawTexturePro(gs.assets.tile_atlas, src, dst, {0, 0}, 0, rl.WHITE)
            } else {
                draw_pixel_wood(bx, by)
            }
        case .Leaves: draw_pixel_leaves(bx, by)
        case:         rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, terrain_table[b.tile].color)
        }
    }
}

// The Sky-Altar offering: the ingredients orbit a swelling glow above the
// capstone while a counter-rotating ring of rainbow runes wheels around them.
// Read-only — the swirl motes and the finishing flash are particles.
draw_ritual :: proc(gs: ^Game_State) {
    if !gs.ritual.active do return
    r    := &gs.ritual
    t    := r.timer
    prog := clamp(t / RITUAL_DURATION, 0, 1)
    cx   := f32(r.altar.x) * CELL_SIZE + CELL_SIZE*0.5
    cy   := (f32(r.altar.y) - 1.5) * CELL_SIZE + CELL_SIZE*0.5

    // A glow that swells and pulses as the offering nears completion.
    glow := (0.6 + prog*1.4) * CELL_SIZE
    pulse := 0.6 + 0.4 * math.sin(t * 9)
    for k := 3; k >= 1; k -= 1 {
        a := u8(38 * f32(k) / 3 * pulse)
        rl.DrawCircleV({cx, cy}, glow * f32(k), rl.Color{255, 240, 185, a})
    }

    // Ingredient icons orbiting, spiralling inward toward the glow.
    orbit := (2.6 - prog*1.4) * CELL_SIZE
    ings  := structure_costs[r.tier]
    for ing, i in ings {
        ang := t*3.0 + f32(i) * (2*math.PI / f32(len(ings)))
        sz  := i32(f32(CELL_SIZE) * 1.4)
        ix  := i32(cx + math.cos(ang)*orbit) - sz/2
        iy  := i32(cy + math.sin(ang)*orbit) - sz/2
        draw_item_icon(ing.item, ix, iy, sz)
    }

    // A counter-rotating ring of runes, each cycling the rainbow.
    rune_r := (3.4 - prog*1.0) * CELL_SIZE
    RUNES  :: 6
    for i in 0 ..< RUNES {
        ang := -t*2.0 + f32(i) * (2*math.PI / RUNES)
        rx  := cx + math.cos(ang)*rune_r
        ry  := cy + math.sin(ang)*rune_r
        hue := f32(math.mod(f64(t*120 + f32(i)*60), 360))
        col := rl.ColorFromHSV(hue, 0.7, 1.0)
        col.a = u8(200 * (0.4 + 0.6*prog))
        draw_title_rune(title_runes[(i*2) % len(title_runes)], rx, ry,
            f32(CELL_SIZE)*1.3, ang + math.PI/2, col, 1.5, 4)
    }
}

draw_tile :: proc(gs: ^Game_State, t: Tile_Type, x, y: int) {
    px := i32(x * CELL_SIZE)
    py := i32(y * CELL_SIZE)
    // The shaft-cut stratum: cap-band stone that also drops dirt gets a
    // soil-veined face (the brown apron in draw_shaft_mouth layers over this).
    if t == .Stone && gs.level_index == LEVEL_SURFACE && in_shaft_apron(&gs.world, x, y) {
        draw_pixel_loam_stone(px, py, x, y)
        return
    }
    if gs.assets.loaded {
        if sp, ok := tile_sprite(gs, t, x, y); ok {
            dst := rl.Rectangle{f32(px), f32(py), CELL_SIZE, CELL_SIZE}
            rl.DrawTexturePro(gs.assets.tile_atlas, tile_atlas_rect(sp), dst, {0, 0}, 0, rl.WHITE)
            if t == .Stone do rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, STONE_TINT)
            return
        }
    }
    if t == .Crafting_Bench {
        // Backdrop only.  The full 20x14 bench is painted after the terrain loop
        // so adjacent cells cannot crop its vise, mallet, legs, or thick top.
        bg := terrain_table[blueprint_chest_backdrop(gs.level_index, y)].color
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, bg)
        return
    }
    if glow := station_glow[t]; glow.a != 0 {
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, rl.Color{24, 22, 30, 255})
        pulse := (math.sin(gs.elapsed_time*2.4 + f32(x*7 + y*13)) + 1) * 0.5
        g := glow
        g.a = u8(60 + pulse*90)
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, g)
        draw_item_icon(terrain_table[t].drop_item, px, py, CELL_SIZE)
        draw_machine_progress(gs, t, x, y)
        return
    }
    switch tile_draw_style[t] {
    case .Pixel_Wood:       draw_pixel_wood(px, py)
    case .Pixel_Leaves:     draw_pixel_leaves(px, py)
    case .Pixel_Flower:     draw_pixel_flower(px, py)
    case .Pixel_Gem:        draw_pixel_gem(px, py, t)
    case .Pixel_Miner_Body: draw_pixel_miner_body(gs, px, py, x, y)
    case .Pixel_Door:       draw_pixel_door(gs, px, py, x, y)
    case .Pixel_Dirt:       draw_pixel_dirt(px, py)
    case .Pixel_Flower_Bed: draw_pixel_flower_bed(gs, px, py, x, y)
    case .Pixel_Blueprint_Chest:
        bg := terrain_table[blueprint_chest_backdrop(gs.level_index, y)].color
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, bg)
    case .Pixel_Cloud:
        // Sky backdrop only — the puffs paint in draw_cloud_layer, a
        // second pass, so their bulges can spill over neighbor cells
        // without being clipped by later-drawn tiles.
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, terrain_table[.Air].color)
    case .Solid:
        rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, terrain_table[t].color)
    }
}

// ─── Pixel Art: Blueprint Chest ───────────────────────────────────────────────
//
// A compact 16×11 Norse coffer translated from sprites/blueprint_chests_concept:
// arched oak lid, three iron straps, corner rivets, and a tier-colored rune
// lock.  Its collision remains one cell; the broad silhouette is render-only.

draw_blueprint_chests :: proc(gs: ^Game_State) {
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            t := get_tile(&gs.world, x, y)
            if is_blueprint_chest(t) {
                draw_pixel_blueprint_chest(gs, i32(x*CELL_SIZE), i32(y*CELL_SIZE), t, x, y)
            }
        }
    }
}

draw_pixel_blueprint_chest :: proc(gs: ^Game_State, bx, by: i32, t: Tile_Type, x, y: int) {
    ox, oy := bx - 3, by - 1
    outline := rl.Color{24, 20, 24, 255}
    iron    := rl.Color{54, 56, 64, 255}
    iron_hi := rl.Color{108, 112, 122, 255}
    wood_d  := rl.Color{74, 39, 24, 255}
    wood    := rl.Color{126, 68, 36, 255}
    wood_hi := rl.Color{174, 102, 54, 255}
    accent  := terrain_table[t].color
    pulse   := (math.sin(gs.elapsed_time*3.6 + f32(x*3 + y*5)) + 1) * 0.5
    glow    := accent
    glow.a   = u8(55 + pulse*80)

    // A restrained colored aura makes the reward legible in black caves.
    rl.DrawRectangle(ox + 2, oy + 1, 12, 8, glow)

    // Black stepped silhouette: arched lid over a wider box and two feet.
    rl.DrawRectangle(ox + 2, oy,     12, 1, outline)
    rl.DrawRectangle(ox + 1, oy + 1, 14, 3, outline)
    rl.DrawRectangle(ox,     oy + 4, 16, 6, outline)
    rl.DrawRectangle(ox + 1, oy + 10, 3, 1, outline)
    rl.DrawRectangle(ox + 12, oy + 10, 3, 1, outline)

    // Warm oak panels and the curved lid highlight.
    rl.DrawRectangle(ox + 2, oy + 1, 12, 1, wood_hi)
    rl.DrawRectangle(ox + 1, oy + 2, 14, 2, wood)
    rl.DrawRectangle(ox + 1, oy + 4, 14, 5, wood)
    rl.DrawRectangle(ox + 1, oy + 6, 14, 1, wood_hi)
    rl.DrawRectangle(ox + 1, oy + 8, 14, 1, wood_d)
    rl.DrawRectangle(ox + 3, oy + 3, 10, 1, wood_d)

    // Heavy iron belt and three vertical straps, kept chunky at game scale.
    rl.DrawRectangle(ox + 1,  oy + 4, 14, 2, iron)
    rl.DrawRectangle(ox + 1,  oy + 4, 14, 1, iron_hi)
    for sx in ([3]i32{2, 7, 12}) {
        rl.DrawRectangle(ox + sx, oy + 1, 2, 8, iron)
        rl.DrawRectangle(ox + sx, oy + 2, 1, 6, iron_hi)
    }

    // Corner rivets and the bright rune-lock: the only tier-specific color.
    rl.DrawRectangle(ox + 2,  oy + 5, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 13, oy + 5, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 2,  oy + 8, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 13, oy + 8, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 6, oy + 4, 4, 4, outline)
    rl.DrawRectangle(ox + 7, oy + 5, 2, 2, accent)
    rl.DrawRectangle(ox + 6, oy + 6, 4, 1, accent)
    rl.DrawRectangle(ox + 8, oy + 5, 1, 1, rl.WHITE)
}

// ─── Pixel Art: Crafting Bench ────────────────────────────────────────────────
//
// A compact 20x14 Norse workbench translated from
// sprites/crafting_bench_concept.png: thick oak slab, braced legs, iron caps,
// vise, mallet, rivets, and one restrained rune boss.  Collision stays one cell;
// this is a read-only overlay, just like the blueprint chest.

draw_crafting_benches :: proc(gs: ^Game_State) {
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if get_tile(&gs.world, x, y) == .Crafting_Bench {
                draw_pixel_crafting_bench(gs, i32(x*CELL_SIZE), i32(y*CELL_SIZE), x, y)
            }
        }
    }
}

draw_pixel_crafting_bench :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
    ox, oy := bx - 5, by - 4
    outline := rl.Color{24, 20, 24, 255}
    iron_d  := rl.Color{42, 43, 49, 255}
    iron    := rl.Color{65, 67, 75, 255}
    iron_hi := rl.Color{122, 126, 136, 255}
    wood_d  := rl.Color{74, 39, 24, 255}
    wood    := rl.Color{126, 68, 36, 255}
    wood_hi := rl.Color{174, 102, 54, 255}
    brass_d := rl.Color{124, 76, 24, 255}
    pulse   := (math.sin(gs.elapsed_time*2.4 + f32(x*7 + y*13)) + 1) * 0.5
    brass   := rl.Color{u8(194 + pulse*40), u8(130 + pulse*42), u8(38 + pulse*22), 255}
    hot     := rl.Color{255, u8(198 + pulse*38), u8(72 + pulse*28), 255}

    // A small warm breath behind the station; the physical bench remains solid
    // and material-led rather than washed in the old full-tile magic glow.
    halo := station_glow[.Crafting_Bench]
    halo.a = u8(18 + pulse*24)
    rl.DrawRectangle(ox + 3, oy + 3, 14, 9, halo)

    // One joined silhouette: slab/apron, legs, feet, and low cross-brace.
    rl.DrawRectangle(ox,      oy + 3, 20, 5, outline)
    rl.DrawRectangle(ox + 2,  oy + 7, 16, 4, outline)
    rl.DrawRectangle(ox + 2,  oy + 8, 5, 6, outline)
    rl.DrawRectangle(ox + 13, oy + 8, 5, 6, outline)
    rl.DrawRectangle(ox + 5,  oy + 11, 10, 3, outline)

    // Thick oak top: bright worn edge, two panel seams, dark underside.
    rl.DrawRectangle(ox + 1, oy + 4, 18, 3, wood)
    rl.DrawRectangle(ox + 2, oy + 4, 16, 1, wood_hi)
    rl.DrawRectangle(ox + 1, oy + 6, 18, 1, wood_d)
    rl.DrawRectangle(ox + 6, oy + 4, 1, 2, wood_d)
    rl.DrawRectangle(ox + 14, oy + 4, 1, 2, wood_d)
    rl.DrawRectangle(ox + 8, oy + 5, 4, 1, wood_hi)

    // Front apron and stout braced legs.
    rl.DrawRectangle(ox + 3,  oy + 7, 14, 3, wood_d)
    rl.DrawRectangle(ox + 4,  oy + 7, 12, 1, wood)
    rl.DrawRectangle(ox + 3,  oy + 9, 4, 4, wood)
    rl.DrawRectangle(ox + 14, oy + 9, 3, 4, wood)
    rl.DrawRectangle(ox + 4,  oy + 9, 1, 3, wood_hi)
    rl.DrawRectangle(ox + 16, oy + 9, 1, 3, wood_d)
    rl.DrawRectangle(ox + 6,  oy + 12, 8, 1, wood)
    rl.DrawRectangle(ox + 6,  oy + 13, 8, 1, wood_d)

    // Iron corner caps and foot shoes, with chest-style rivet glints.
    rl.DrawRectangle(ox,      oy + 3, 3, 4, iron)
    rl.DrawRectangle(ox + 17, oy + 3, 3, 4, iron)
    rl.DrawRectangle(ox + 1,  oy + 3, 2, 1, iron_hi)
    rl.DrawRectangle(ox + 17, oy + 3, 2, 1, iron_hi)
    rl.DrawRectangle(ox + 2,  oy + 12, 5, 2, iron_d)
    rl.DrawRectangle(ox + 13, oy + 12, 5, 2, iron_d)
    rl.DrawRectangle(ox + 3,  oy + 12, 3, 1, iron_hi)
    rl.DrawRectangle(ox + 14, oy + 12, 3, 1, iron_hi)
    rl.DrawRectangle(ox + 1,  oy + 5, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 18, oy + 5, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 4,  oy + 12, 1, 1, iron_hi)
    rl.DrawRectangle(ox + 15, oy + 12, 1, 1, iron_hi)

    // Compact vise on the left: fixed jaw, sliding jaw, and screw handle.
    rl.DrawRectangle(ox,     oy + 1, 6, 3, outline)
    rl.DrawRectangle(ox + 1, oy + 1, 4, 2, iron)
    rl.DrawRectangle(ox + 1, oy + 1, 3, 1, iron_hi)
    rl.DrawRectangle(ox,     oy + 2, 2, 5, outline)
    rl.DrawRectangle(ox + 1, oy + 3, 1, 3, iron)
    rl.DrawRectangle(ox,     oy + 5, 4, 1, iron_d)
    rl.DrawRectangle(ox,     oy + 4, 1, 3, iron_hi)

    // Mallet resting on the slab: oak head, iron pin, tapered warm handle.
    rl.DrawRectangle(ox + 10, oy,     5, 4, outline)
    rl.DrawRectangle(ox + 11, oy + 1, 3, 2, wood)
    rl.DrawRectangle(ox + 11, oy + 1, 2, 1, wood_hi)
    rl.DrawRectangle(ox + 13, oy + 1, 1, 2, wood_d)
    rl.DrawRectangle(ox + 10, oy + 1, 1, 2, iron)
    rl.DrawRectangle(ox + 14, oy + 2, 5, 2, outline)
    rl.DrawRectangle(ox + 14, oy + 2, 4, 1, wood_hi)
    rl.DrawRectangle(ox + 15, oy + 3, 4, 1, wood_d)

    // Brass rune boss on the apron: the only magical focal point.
    rl.DrawRectangle(ox + 8, oy + 6, 5, 5, outline)
    rl.DrawRectangle(ox + 9, oy + 7, 3, 3, brass_d)
    rl.DrawRectangle(ox + 9, oy + 8, 3, 1, brass)
    rl.DrawRectangle(ox + 10, oy + 7, 1, 3, hot)
    rl.DrawRectangle(ox + 11, oy + 7, 1, 1, hot)
}

// Working machines show it (read-only: sim_data progress → overlay).  A
// smelting furnace burns hotter and fills an ember bar; a grower's sapling
// climbs out of the planter as the growth timer fills.
draw_machine_progress :: proc(gs: ^Game_State, t: Tile_Type, x, y: int) {
    px := i32(x * CELL_SIZE)
    py := i32(y * CELL_SIZE)
    #partial switch t {
    case .Smelter:
        p := gs.world.sim_data[grid_idx(x, y)].growth_timer / SMELT_TIME
        if p <= 0 do return
        flick := (math.sin(gs.elapsed_time*13 + f32(x)) + 1) * 0.5
        rl.DrawRectangle(px + 2, py + 3, 6, 4, rl.Color{255, 150, 40, u8(80 + p*100 + flick*60)})
        rl.DrawRectangle(px, py - 2, i32(f32(CELL_SIZE) * clamp(p, 0, 1)), 2, rl.Color{255, 200, 80, 230})
    case .Tree_Grower:
        p := gs.world.sim_data[grid_idx(x, y)].growth_timer / TREE_GROW_TIME
        if p <= 0 do return
        cp := clamp(p, 0, 1)
        // The sapling stem climbs the full trunk height (TREE_MAX_H tiles) as it
        // grows, so it reads as a stalk rising to full length before the grown
        // tree pops in — not a stub that jumps straight to a tree.  The column
        // above is guaranteed clear sky (tick_grower checks to TREE_MAX_H).
        full   := f32(TREE_MAX_H * CELL_SIZE)
        h      := i32(2 + cp*(full-2))
        stem_x := px + CELL_SIZE/2 - 1
        stalk  := rl.Color{70, 190, 60, 255}
        leaf   := rl.Color{110, 230, 110, 255}
        rl.DrawRectangle(stem_x, py - h, 2, h, stalk)
        // A pair of little leaves at the climbing tip.
        rl.DrawRectangle(stem_x - 2, py - h,     2, 2, leaf)
        rl.DrawRectangle(stem_x + 2, py - h + 1, 2, 2, leaf)
        // Side sprigs unfurl up the stem as it lengthens.
        if h > CELL_SIZE {
            rl.DrawRectangle(stem_x - 2, py - h/2, 2, 2, leaf)
            rl.DrawRectangle(stem_x + 2, py - h/3, 2, 2, leaf)
        }
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

// ─── Pixel Art: Dirt ──────────────────────────────────────────────────────────
//
//  Turned earth: warm brown fill scattered with darker pebbles and lighter
//  grit so a placed clod reads as soil, not a flat swatch.  Fixed pattern
//  (like leaves) — it tiles cleanly across a stacked dirt wall.

draw_pixel_dirt :: proc(bx, by: i32) {
    base  := rl.Color{120, 84, 50, 255}
    dark  := rl.Color{ 84, 58, 34, 255}
    light := rl.Color{150, 112, 74, 255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, base)
    // pebbles
    rl.DrawRectangle(bx+1, by+2, 2, 2, dark)
    rl.DrawRectangle(bx+6, by+1, 2, 2, dark)
    rl.DrawRectangle(bx+4, by+5, 2, 2, dark)
    rl.DrawRectangle(bx+7, by+6, 2, 2, dark)
    // grit
    rl.DrawRectangle(bx+3, by+0, 1, 1, light)
    rl.DrawRectangle(bx+8, by+3, 1, 1, light)
    rl.DrawRectangle(bx+0, by+6, 1, 1, light)
    rl.DrawRectangle(bx+2, by+7, 1, 1, light)
    rl.DrawRectangle(bx+5, by+8, 1, 1, light)
}

// ─── Pixel Art: Loam Stone ────────────────────────────────────────────────────
//
//  The loose earthen stratum the entrance shaft cuts through: cap-band stone
//  shot through with packed soil — it's why mining here also yields a dirt clod
//  (in_shaft_apron), so it should read as soil-veined rock, not plain stone.
//  Deterministic per cell via a position hash: varied down the band, never
//  shimmering.  Drawn UNDER the brown scuff apron (draw_shaft_mouth).

draw_pixel_loam_stone :: proc(bx, by: i32, x, y: int) {
    stone   := rl.Color{112, 110, 116, 255}
    stone_d := rl.Color{ 82,  80,  88,  255}
    stone_l := rl.Color{150, 148, 156, 255}
    soil    := rl.Color{120,  84,  50,  255}
    soil_d  := rl.Color{ 84,  58,  34,  255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, stone)

    h := whash(u32(x)*374761393) ~ whash(u32(y)*668265263)
    // A soil seam packed into a crack, its slant riding the hash.
    seam := i32(h % 4)
    rl.DrawRectangle(bx+seam,   by+2, 3, 2, soil)
    rl.DrawRectangle(bx+seam+2, by+4, 3, 2, soil_d)
    rl.DrawRectangle(bx+seam+3, by+6, 2, 2, soil)
    // Embedded pebbles and a lit chip, scattered off the hash.
    rl.DrawRectangle(bx + i32((h>>3)%7), by + i32((h>>6)%3) + 1, 2, 2, stone_d)
    rl.DrawRectangle(bx + i32((h>>9)%8), by + 7,                 2, 1, stone_l)
    rl.DrawRectangle(bx + i32((h>>12)%9), by + i32((h>>14)%4) + 5, 1, 1, soil_d)
}

// ─── Pixel Art: Flower Bed ────────────────────────────────────────────────────
//
//  A plank-framed soil bed whose five stalks grow over FLOWER_BED_GROW_TIME:
//  sprouts → stems → buds → swaying blooms.  Growth (sim_data.growth_timer)
//  drives the stalk height, and the ripe blooms spill up into the cell above
//  (a surface crop with open sky overhead), so it reads taller than one cell.

draw_pixel_flower_bed :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
    soil   := rl.Color{ 92, 62, 38, 255}
    soil_d := rl.Color{ 68, 46, 28, 255}
    frame  := rl.Color{140, 100, 55, 255}
    stem   := rl.Color{ 46, 140, 46, 255}
    stem_d := rl.Color{ 30, 100, 34, 255}
    bud    := rl.Color{120, 170, 70, 255}

    p := clamp(gs.world.sim_data[grid_idx(x, y)].growth_timer / FLOWER_BED_GROW_TIME, 0, 1)
    ripe := p >= 1.0

    soil_top := by + 6
    rl.DrawRectangle(bx, soil_top, CELL_SIZE, CELL_SIZE - 6, soil)   // tilled soil
    rl.DrawRectangle(bx, by + 8, CELL_SIZE, 2, soil_d)              // dark furrow
    rl.DrawRectangle(bx, soil_top, CELL_SIZE, 1, frame)            // plank lip
    rl.DrawRectangle(bx, soil_top, 1, CELL_SIZE - 6, frame)        // left rail
    rl.DrawRectangle(bx + CELL_SIZE - 1, soil_top, 1, CELL_SIZE - 6, frame)  // right rail

    petals := [5]rl.Color{
        {255, 220, 50, 255}, {255, 150, 60, 255}, {255, 90, 120, 255},
        {200, 120, 255, 255}, {255, 220, 50, 255},
    }
    for sx, i in ([5]i32{1, 3, 5, 7, 9}) {
        h    := i32(2 + p * 13)   // 2px sprout → 15px stalk (spills a cell up)
        sway := ripe ? i32(math.sin(gs.elapsed_time * 2 + f32(i)) * 1.2) : 0
        top  := soil_top - h
        hx   := bx + sx + sway
        rl.DrawRectangle(hx, top, 1, h, i % 2 == 0 ? stem : stem_d)
        if ripe {
            rl.DrawRectangle(hx - 1, top - 1, 3, 1, petals[i])          // side petals
            rl.DrawRectangle(hx,     top - 2, 1, 3, petals[i])          // top/bottom
            rl.DrawRectangle(hx,     top - 1, 1, 1, rl.Color{255, 240, 180, 255})  // core
        } else if p > 0.55 {
            rl.DrawRectangle(hx, top - 1, 1, 1, bud)                    // budding
        }
    }
}

// ─── Pixel Art: Door ──────────────────────────────────────────────────────────
//
//  A plank leaf fills the cell with dark jambs down both sides, a top-rail
//  highlight and a plank seam; the lower half (a door tile sits above it) wears
//  the iron knob.  Always drawn shut — the door has no open state; the player
//  simply phases through it (physics.odin).

draw_pixel_door :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
    wood  := rl.Color{150, 100, 55, 255}
    dark  := rl.Color{ 92,  60, 32, 255}
    light := rl.Color{182, 130, 78, 255}
    iron  := rl.Color{ 60,  60, 68, 255}

    bottom := is_door(&gs.world, x, y - 1)   // a door above → this is the lower half

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, wood)
    rl.DrawRectangle(bx, by, 1, CELL_SIZE, dark)
    rl.DrawRectangle(bx+CELL_SIZE-1, by, 1, CELL_SIZE, dark)
    rl.DrawRectangle(bx+1, by, CELL_SIZE-2, 1, light)
    rl.DrawRectangle(bx+3, by, 1, CELL_SIZE, dark)   // plank seam
    if bottom {
        rl.DrawRectangle(bx+CELL_SIZE-4, by+CELL_SIZE/2-1, 2, 2, iron)  // knob
    }
}

// ─── Pixel Art: Miner Body ────────────────────────────────────────────────────
//
//  The snake's trail: segmented steel bar with rivets, alternating joint
//  lines so a run of segments reads as linked metal.  The head segment
//  (gs.dimension.miner.head) pulses teal — the living end of the machine.

draw_pixel_miner_body :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
    dark  := rl.Color{ 52,  56,  66, 255}
    steel := rl.Color{118, 126, 140, 255}
    shine := rl.Color{176, 184, 198, 255}
    rivet := rl.Color{ 84,  90, 102, 255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, dark)
    rl.DrawRectangle(bx+1, by+2, 8, 6, steel)
    rl.DrawRectangle(bx+1, by+2, 8, 1, shine)
    // joint line alternates with the tile parity — segments read as links
    if (x + y) % 2 == 0 {
        rl.DrawRectangle(bx+4, by+1, 2, 8, rivet)
    } else {
        rl.DrawRectangle(bx+2, by+4, 6, 2, rivet)
    }
    rl.DrawRectangle(bx+2, by+3, 1, 1, shine)
    rl.DrawRectangle(bx+7, by+6, 1, 1, rivet)

    // The head glows — a breathing teal pulse on the working end.
    m := &gs.dimension.miner
    if m.active && m.head == {i32(x), i32(y)} {
        pulse := (math.sin(gs.elapsed_time * 5.0) + 1) * 0.5
        g := rl.Color{80, 255, 220, u8(90 + pulse * 130)}
        rl.DrawRectangle(bx+2, by+3, 6, 4, g)
    }
}

// ─── Pixel Art: Gem Ore ───────────────────────────────────────────────────────
//
//  A crystal cluster embedded in cave rock.  One proc serves every gem tile:
//  the gem's accent comes from terrain_table[t].color, so a new gem is still
//  just a table row (tile_draw_style entry + terrain color).
//  Stone base matches the STONE_TINT wash so the rock reads as cave wall.

draw_pixel_gem :: proc(bx, by: i32, t: Tile_Type) {
    stone := rl.Color{110, 110, 118, 255}
    shade := rl.Color{ 84,  84,  92, 255}
    gem   := terrain_table[t].color
    gdark := rl.Color{gem.r / 2, gem.g / 2, gem.b / 2, 255}

    rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, stone)
    // rock grain in the corners so it reads as wall, not a floating chip
    rl.DrawRectangle(bx+1, by+7, 2, 2, shade)
    rl.DrawRectangle(bx+7, by+1, 2, 2, shade)
    rl.DrawRectangle(bx+8, by+8, 1, 1, shade)
    // the embedded crystal cluster: a rough diamond with a dark facet
    rl.DrawRectangle(bx+4, by+2, 2, 6, gem)
    rl.DrawRectangle(bx+2, by+4, 6, 2, gem)
    rl.DrawRectangle(bx+3, by+3, 4, 4, gem)
    rl.DrawRectangle(bx+5, by+5, 2, 2, gdark)
    rl.DrawRectangle(bx+3, by+6, 1, 1, gdark)
    // sparkle
    rl.DrawRectangle(bx+4, by+3, 1, 1, rl.WHITE)
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

// A quiet targeting promise around the block an equipped wand will strike.
// The motes are derived from elapsed time rather than Particle_Store: render
// stays read-only, and hovering never consumes a slot from real effects.
draw_wand_target :: proc(gs: ^Game_State) {
    if gs.player.dead || gs.game_won || gs.ui.show_menu || gs.ui.show_title ||
       gs.ui.show_charselect || gs.ui.show_settings || gs.ui.show_book ||
       cursor_over_ui(gs) {
        return
    }

    T := gs.ui.hover_tile
    wand, cost, _, ok := wand_target(gs, T)
    if !ok || gs.player.mana < cost do return

    bx := f32(T.x * CELL_SIZE)
    by := f32(T.y * CELL_SIZE)
    col := item_table[wand].color
    pulse := 0.5 + 0.5 * math.sin(gs.elapsed_time * 5)

    outline := col
    outline.a = u8(35 + pulse*35)
    rl.DrawRectangleLinesEx({bx + 0.5, by + 0.5, CELL_SIZE - 1, CELL_SIZE - 1}, 0.5, outline)

    MOTE_COUNT :: 6
    edge := f32(CELL_SIZE - 1)
    for i in 0 ..< MOTE_COUNT {
        phase := math.mod(gs.elapsed_time*2.2 + f32(i)*4.0/MOTE_COUNT, 4)
        x, y := f32(0), f32(0)
        switch {
        case phase < 1: x = phase*edge
        case phase < 2: x = edge; y = (phase - 1)*edge
        case phase < 3: x = (3 - phase)*edge; y = edge
        case:           y = (4 - phase)*edge
        }

        twinkle := 0.65 + 0.35*math.sin(gs.elapsed_time*8 + f32(i)*1.7)
        mote := col
        mote.a = u8(145 + twinkle*90)
        rl.DrawCircleV({bx + 0.5 + x, by + 0.5 + y}, 0.55 + twinkle*0.35, mote)
    }
}

// Orange dismantle telegraph: the outline pulses while the bottom bar fills.
// Releasing Shift/click or leaving the target clears it before completion.
draw_reclaim_target :: proc(gs: ^Game_State) {
    if !gs.reclaim.active do return
    r := &gs.reclaim
    bx := f32(r.target.x * CELL_SIZE)
    by := f32(r.target.y * CELL_SIZE)
    progress := clamp(r.timer / RECLAIM_HOLD_TIME, 0, 1)
    pulse := 0.65 + 0.35*math.sin(gs.elapsed_time*12)
    edge := rl.Color{255, 125, 35, u8(180 + pulse*75)}

    rl.DrawRectangleRec({bx, by, CELL_SIZE, CELL_SIZE}, rl.Color{180, 45, 20, 30})
    rl.DrawRectangleLinesEx({bx + 0.5, by + 0.5, CELL_SIZE - 1, CELL_SIZE - 1}, 1, edge)
    rl.DrawRectangle(i32(bx), i32(by) + CELL_SIZE - 2, CELL_SIZE, 2, rl.Color{35, 15, 10, 220})
    rl.DrawRectangle(i32(bx), i32(by) + CELL_SIZE - 2, i32(progress*CELL_SIZE), 2, edge)
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

// Builder dvergr: a compact chest-style sprite translated from
// sprites/builder_concept.png. The broad art spills a couple of pixels beyond
// the 0.8x1-tile physics body, but collision and AI remain unchanged.
BUILDER_FRAME_W :: 12
BUILDER_FRAME_H :: 14

@(rodata)
builder_frames := [2][BUILDER_FRAME_H]string{
    { // planted stance
        "   OOOOOO   ",
        "  OIiiiiIO  ",
        "  OOOOOOOO  ",
        "  ObKKKKbO  ",
        "  ObEBBEbO  ",
        "  ObRRRRbO  ",
        "  OObBBbOO  ",
        " OOLLLLLLOO ",
        " OIOLLLLOIO ",
        "  OLLLLLLO  ",
        "  OILLLLIO  ",
        "  OII  IIO  ",
        "  OII  IIO  ",
        "  OOO  OOO  ",
    },
    { // broad mid-stride
        "   OOOOOO   ",
        "  OIiiiiIO  ",
        "  OOOOOOOO  ",
        "  ObKKKKbO  ",
        "  ObEBBEbO  ",
        "  ObRRRRbO  ",
        "  OObBBbOO  ",
        " OOLLLLLLOO ",
        " OIOLLLLOIO ",
        "  OLLLLLLO  ",
        "  OILLLLIO  ",
        " OII    IIO ",
        "OOO      IIO",
        "OOO      OOO",
    },
}

builder_pixel_color :: proc(ch: u8, hunting: bool) -> rl.Color {
    switch ch {
    case 'O': return rl.Color{24, 20, 24, 255}       // heavy chest outline
    case 'I': return rl.Color{65, 67, 75, 255}       // dark iron
    case 'i': return rl.Color{132, 136, 146, 255}    // iron edge glint
    case 'L': return rl.Color{112, 65, 38, 255}      // worn leather
    case 'l': return rl.Color{68, 38, 27, 255}       // leather seam
    case 'B': return rl.Color{150, 57, 27, 255}      // rust-red beard
    case 'b': return rl.Color{86, 33, 23, 255}       // beard shadow
    case 'R': return rl.Color{201, 78, 33, 255}      // beard firelight
    case 'K': return rl.Color{164, 101, 65, 255}     // cave-worn skin
    case 'E':
        return rl.Color{255, 82, 28, 255} if hunting else rl.Color{238, 174, 50, 255}
    }
    return {}
}

// Pixel-aligned local rectangle which mirrors with the character. Coordinates
// may spill outside the 12px frame for the pick head and carried block.
draw_builder_rect :: proc(ox, oy: f32, facing, x, y, w, h: int, col: rl.Color) {
    dx := x
    if facing < 0 do dx = BUILDER_FRAME_W - x - w
    rl.DrawRectangleRec({ox + f32(dx), oy + f32(y), f32(w), f32(h)}, col)
}

draw_builder_tool :: proc(ox, oy: f32, facing: int, raised: bool) {
    outline := rl.Color{24, 20, 24, 255}
    iron    := rl.Color{65, 67, 75, 255}
    iron_hi := rl.Color{132, 136, 146, 255}
    wood_d  := rl.Color{74, 39, 24, 255}
    wood    := rl.Color{145, 78, 40, 255}

    if raised {
        // Pick head above the leading shoulder; the stepped handle stays crisp.
        draw_builder_rect(ox, oy, facing, 8, -2, 5, 3, outline)
        draw_builder_rect(ox, oy, facing, 9, -1, 4, 1, iron_hi)
        draw_builder_rect(ox, oy, facing, 8,  0, 4, 1, iron)
        for p in ([][2]int{{10, 1}, {10, 2}, {9, 3}, {9, 4}, {8, 5}, {8, 6}}) {
            draw_builder_rect(ox, oy, facing, p.x, p.y, 2, 2, outline)
            draw_builder_rect(ox, oy, facing, p.x, p.y, 1, 1, wood)
        }
        draw_builder_rect(ox, oy, facing, 9, 4, 1, 2, wood_d)
    } else {
        // Tool carried low at the leading hand while walking or standing.
        draw_builder_rect(ox, oy, facing, 10, 5, 2, 8, outline)
        draw_builder_rect(ox, oy, facing, 10, 6, 1, 6, wood)
        draw_builder_rect(ox, oy, facing, 8,  4, 5, 3, outline)
        draw_builder_rect(ox, oy, facing, 9,  4, 4, 1, iron_hi)
        draw_builder_rect(ox, oy, facing, 8,  5, 4, 1, iron)
    }
}

draw_builder_carry :: proc(e: ^Enemy, ox, oy: f32) {
    outline := rl.Color{24, 20, 24, 255}
    base    := terrain_table[e.builder.carry].color
    dark    := shade_color(base, 0.55)
    light   := shade_color(base, 1.35)

    // A six-pixel mineral block locked against the leading shoulder.
    draw_builder_rect(ox, oy, e.facing, 7, -3, 7, 6, outline)
    draw_builder_rect(ox, oy, e.facing, 8, -2, 5, 4, base)
    draw_builder_rect(ox, oy, e.facing, 8, -2, 4, 1, light)
    draw_builder_rect(ox, oy, e.facing, 12, -1, 1, 3, dark)
    draw_builder_rect(ox, oy, e.facing, 9,  0, 2, 1, dark)
    // Bracer and fist holding the load up.
    draw_builder_rect(ox, oy, e.facing, 8, 2, 3, 3, outline)
    draw_builder_rect(ox, oy, e.facing, 9, 2, 2, 2, rl.Color{65, 67, 75, 255})
    draw_builder_rect(ox, oy, e.facing, 9, 2, 1, 1, rl.Color{132, 136, 146, 255})
}

draw_builder :: proc(e: ^Enemy) {
    moving  := abs(e.vel.x) > 0.2
    frame_i := 0
    if moving do frame_i = int(abs(e.pos.x)*4) % 2
    hunting := e.builder.goal == .Hunt
    raised  := hunting || e.builder.escaping || e.nav.mine_timer > 0

    px := e.pos.x * CELL_SIZE
    py := e.pos.y * CELL_SIZE
    pw := BUILDER_W * CELL_SIZE
    ph := BUILDER_H * CELL_SIZE
    ox := px + (pw - BUILDER_FRAME_W) * 0.5
    oy := py + ph - BUILDER_FRAME_H
    if moving && frame_i == 1 do oy -= 1

    frame := builder_frames[frame_i]
    for row in 0 ..< BUILDER_FRAME_H {
        for col in 0 ..< BUILDER_FRAME_W {
            ch := frame[row][col]
            if ch == ' ' do continue
            draw_col := col
            if e.facing < 0 do draw_col = BUILDER_FRAME_W - 1 - col
            rl.DrawRectangleRec(
                {ox + f32(draw_col), oy + f32(row), 1, 1},
                builder_pixel_color(ch, hunting),
            )
        }
    }

    if e.builder.carry != .Air {
        draw_builder_carry(e, ox, oy)
    } else {
        draw_builder_tool(ox, oy, e.facing, raised)
    }

    // The hunt face opens into a tiny black shout under ember-bright eyes.
    if hunting do draw_builder_rect(ox, oy, e.facing, 5, 5, 2, 1, rl.Color{24, 20, 24, 255})
}

// ─── Player (pixel-art forms) ───────────────────────────────────────────────

// Selectable player looks — chosen on the startup character-select screen.
// Cosmetic only; not saved (re-picked each launch). Wizard is the default
// (enum zero) so an un-set form matches the original mage.
Player_Form :: enum u8 {
    Wizard,
    Dwarf,
    Ranger,
    Viking,
    Knight,
    Golem,
    Plague,
}

PLAYER_FORM_COUNT :: len(Player_Form)

player_form_names := [Player_Form]cstring{
    .Wizard = "Wizard",
    .Dwarf  = "Dwarf",
    .Ranger = "Ranger",
    .Viking = "Viking",
    .Knight = "Knight",
    .Golem  = "Golem",
    .Plague = "Plague Dr.",
}

// 8×11 ascii sprites, two walk frames each. Legend: Y hair, C clothing (both
// player-tinted, left→right shaded), K face, B boots, M steel, F fur, W bone/
// horn/mask, '-' visor slit / goggle, S stone, G glowing core. Ported from G2;
// player-tinted colors come from the Player.
PLAYER_RENDER_SCALE :: 2  // sprite height in tiles — the one knob for player size
FRAME_WIDTH  :: 8
FRAME_HEIGHT :: 11

player_form_frames := [Player_Form][2][FRAME_HEIGHT][FRAME_WIDTH]rune{
    .Wizard = {
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
    },
    .Dwarf = {
        {
            {' ',' ',' ',' ',' ',' ',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ','M','M','M','M','M','M',' '},
            {' ',' ','Y','K','K','Y',' ',' '},
            {' ','Y','Y','Y','Y','Y','Y',' '},
            {' ','Y','Y','Y','Y','Y','Y',' '},
            {'C','C','Y','Y','Y','Y','C','C'},
            {'C','C','C','C','C','C','C','C'},
            {'C','C','C','C','C','C','C','C'},
            {' ','C','C','C','C','C','C',' '},
            {' ','B','B',' ',' ','B','B',' '},
        },
        {
            {' ',' ',' ',' ',' ',' ',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ','M','M','M','M','M','M',' '},
            {' ',' ','Y','K','K','Y',' ',' '},
            {' ','Y','Y','Y','Y','Y','Y',' '},
            {' ','Y','Y','Y','Y','Y','Y',' '},
            {'C','C','Y','Y','Y','Y','C','C'},
            {'C','C','C','C','C','C','C','C'},
            {'C','C','C','C','C','C','C','C'},
            {' ','C','C','C','C','C','C',' '},
            {' ',' ','B','B',' ',' ','B','B'},
        },
    },
    .Ranger = {
        {
            {' ',' ','C','C','C',' ',' ',' '},
            {' ','C','C','C','C','C',' ',' '},
            {' ','C','C','K','K','C',' ',' '},
            {' ',' ','C','K','K','C',' ',' '},
            {' ',' ','C','C','C','C',' ',' '},
            {' ','C','C','C','C','C','C',' '},
            {'C','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C','C'},
            {' ',' ','C','C','C','C','C',' '},
            {' ',' ','C','C','C',' ',' ',' '},
            {' ',' ','B','B',' ','B',' ',' '},
        },
        {
            {' ',' ','C','C','C',' ',' ',' '},
            {' ','C','C','C','C','C',' ',' '},
            {' ','C','C','K','K','C',' ',' '},
            {' ',' ','C','K','K','C',' ',' '},
            {' ',' ','C','C','C','C',' ',' '},
            {' ','C','C','C','C','C','C',' '},
            {'C','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C','C'},
            {' ',' ','C','C','C','C','C',' '},
            {' ',' ','C','C','C',' ',' ',' '},
            {' ','B',' ','B','B',' ',' ',' '},
        },
    },
    .Viking = {
        {
            {' ','W',' ',' ',' ',' ','W',' '},
            {' ','W','M','M','M','M','W',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','K','K','K','K',' ',' '},
            {' ','Y','K','K','K','K','Y',' '},
            {'F','F','F','F','F','F','F','F'},
            {' ','F','C','C','C','C','F',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ',' ','C','C','C','C',' ',' '},
            {' ','B','B',' ',' ','B','B',' '},
        },
        {
            {' ','W',' ',' ',' ',' ','W',' '},
            {' ','W','M','M','M','M','W',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','K','K','K','K',' ',' '},
            {' ','Y','K','K','K','K','Y',' '},
            {'F','F','F','F','F','F','F','F'},
            {' ','F','C','C','C','C','F',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ',' ','C','C','C','C',' ',' '},
            {' ',' ','B','B',' ',' ','B','B'},
        },
    },
    .Knight = {
        {
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','-','-','M',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {'M','M','M','M','M','M','M','M'},
            {' ','M','C','C','C','C','M',' '},
            {' ','M','C','C','C','C','M',' '},
            {' ','M','C','C','C','C','M',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','M',' ','M','M',' '},
        },
        {
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','-','-','M',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {'M','M','M','M','M','M','M','M'},
            {' ','M','C','C','C','C','M',' '},
            {' ','M','C','C','C','C','M',' '},
            {' ','M','C','C','C','C','M',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ',' ','M','M','M','M',' ',' '},
            {' ','M','M',' ',' ','M','M',' '},
        },
    },
    .Golem = {
        {
            {' ',' ','S','S','S','S',' ',' '},
            {' ','S','S','S','S','S','S',' '},
            {' ','S','K','S','S','K','S',' '},
            {' ','S','S','S','S','S','S',' '},
            {'S','S','S','S','S','S','S','S'},
            {'S','S','S','G','G','S','S','S'},
            {'S','S','S','G','G','S','S','S'},
            {' ','S','S','S','S','S','S',' '},
            {' ','S','S','S','S','S','S',' '},
            {' ','S','S',' ',' ','S','S',' '},
            {' ','S','S',' ',' ','S','S',' '},
        },
        {
            {' ',' ','S','S','S','S',' ',' '},
            {' ','S','S','S','S','S','S',' '},
            {' ','S','K','S','S','K','S',' '},
            {' ','S','S','S','S','S','S',' '},
            {'S','S','S','S','S','S','S','S'},
            {'S','S','S','G','G','S','S','S'},
            {'S','S','S','G','G','S','S','S'},
            {' ','S','S','S','S','S','S',' '},
            {' ','S','S','S','S','S','S',' '},
            {' ',' ','S','S',' ','S','S',' '},
            {' ',' ','S','S',' ','S','S',' '},
        },
    },
    .Plague = {
        {
            {' ',' ',' ',' ',' ',' ',' ',' '},
            {' ','K','K','K','K','K','K',' '},
            {' ',' ','K','K','K','K',' ',' '},
            {' ',' ','-','W','W','W',' ',' '},
            {' ',' ','W','W','W','W','W',' '},
            {' ',' ',' ','W','W','W','W',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ',' ','C','C','C','C',' ',' '},
            {' ',' ','B','B',' ','B',' ',' '},
        },
        {
            {' ',' ',' ',' ',' ',' ',' ',' '},
            {' ','K','K','K','K','K','K',' '},
            {' ',' ','K','K','K','K',' ',' '},
            {' ',' ','-','W','W','W',' ',' '},
            {' ',' ','W','W','W','W','W',' '},
            {' ',' ',' ','W','W','W','W',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ','C','C','C','C','C','C',' '},
            {' ',' ','C','C','C','C',' ',' '},
            {' ','B',' ','B','B',' ',' ',' '},
        },
    },
}

player_pixel_color :: proc(p: ^Player, ch: rune, shade: f32) -> rl.Color {
    switch ch {
    case 'Y': return p.hair_color
    case 'K': return rl.Color{40, 40, 50, 255}
    case 'C': return shade_color(p.clothing_color, shade)
    case 'B': return rl.Color{110, 70, 40, 255}
    case 'M': return shade_color(rl.Color{150, 155, 170, 255}, shade)  // steel
    case 'F': return shade_color(rl.Color{120, 95, 60, 255}, shade)    // fur
    case 'W': return rl.Color{230, 222, 195, 255}                      // bone / horn / mask
    case '-': return rl.Color{18, 18, 26, 255}                         // visor slit / goggle
    case 'S': return shade_color(rl.Color{112, 110, 120, 255}, shade)  // stone
    case 'G': return rl.Color{255, 176, 64, 255}                       // glowing core
    case:     return rl.BLANK
    }
}

shade_color :: proc(c: rl.Color, s: f32) -> rl.Color {
    return {
        u8(clamp(f32(c.r) * s, 0, 255)),
        u8(clamp(f32(c.g) * s, 0, 255)),
        u8(clamp(f32(c.b) * s, 0, 255)),
        255,
    }
}

draw_player :: proc(p: ^Player, form: Player_Form, step_visual_y: f32 = 0) {
    if p.dead { return }

    frame := player_form_frames[form][p.anim_frame]

    // Float world-pixel positions so the sprite glides sub-pixel under the
    // supersampled camera instead of snapping to whole tiles.
    px    := p.pos.x * CELL_SIZE
    py    := (p.pos.y + step_visual_y) * CELL_SIZE
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

    // Equipped mining tool in the leading hand. Only the pickaxe and wands
    // are drawn by this mining-tool pass.
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

// Draws a form's idle sprite (frame 0) at a UI position for the character-
// select cards. Same pixel loop as draw_player, minus animation/facing.
draw_form_sprite :: proc(form: Player_Form, x, y, ps: f32, hair, clothing: rl.Color) {
    tmp := Player{hair_color = hair, clothing_color = clothing}
    frame := player_form_frames[form][0]
    for row in 0 ..< FRAME_HEIGHT {
        for col in 0 ..< FRAME_WIDTH {
            ch := frame[row][col]
            if ch == ' ' { continue }
            shade := 0.85 + f32(col) / f32(FRAME_WIDTH - 1) * 0.25
            rl.DrawRectangleRec(
                {x + f32(col)*ps, y + f32(row)*ps, ps, ps},
                player_pixel_color(&tmp, ch, shade),
            )
        }
    }
}

// The equipped mining implement; bagged tools stay visually and mechanically inert.
held_tool :: proc(p: ^Player) -> Item {
    if wand := p.equipment[.Weapon]; is_wand(wand) do return wand
    if p.equipment[.Tool] == .Pickaxe do return .Pickaxe
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

// Gold outline on the station tile the player can interact with (read-only;
// the focus is computed in update_station_focus).
draw_station_focus :: proc(gs: ^Game_State) {
    if gs.player.dead || gs.ui.focus_station == .None do return
    rl.DrawRectangleLinesEx(
        {f32(gs.ui.focus_tile.x * CELL_SIZE), f32(gs.ui.focus_tile.y * CELL_SIZE), CELL_SIZE, CELL_SIZE},
        1, NORSE_GOLD_HOT)
}

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

// ─── Portal vortex (layered, procedural) ──────────────────────────────────────
//
//  A gate is drawn back-to-front: an additive bloom halo bleeding into the
//  scene, a dark event-horizon core for depth, spiral swirl arms of soft motes
//  drawn inward, a bright pulsing rim, expanding shimmer rings and rim glints.
//  Additive blend does the glow; DrawCircleGradient the soft dots.  Read-only.

portal_mix :: proc(a, b: rl.Color, t: f32) -> rl.Color {
    return {
        u8(f32(a.r) + (f32(b.r) - f32(a.r)) * t),
        u8(f32(a.g) + (f32(b.g) - f32(a.g)) * t),
        u8(f32(a.b) + (f32(b.b) - f32(a.b)) * t),
        u8(f32(a.a) + (f32(b.a) - f32(a.a)) * t),
    }
}

// Soft elliptical bloom faked from stacked low-alpha ellipses (additive): the
// center is covered by every layer and sums bright, the rim by only the outer.
portal_bloom :: proc(cx, cy, hw, hh: f32, col: rl.Color, pulse: f32) {
    LAYERS :: 5
    for k in 0 ..< LAYERS {
        rw := hw * (0.7 + f32(k) * 0.34)
        rh := hh * (0.7 + f32(k) * 0.34)
        a  := u8(f32(col.a) * 0.16 * (1 - f32(k) / LAYERS) * (0.7 + 0.3 * pulse))
        rl.DrawEllipse(i32(cx), i32(cy), rw, rh, rl.Color{col.r, col.g, col.b, a})
    }
}

// The bottomless maw: nested dark ellipses, darkest at the center.
portal_core :: proc(cx, cy, cw, ch: f32, col: rl.Color) {
    rl.DrawEllipse(i32(cx), i32(cy), cw, ch, col)
    rl.DrawEllipse(i32(cx), i32(cy), cw * 0.62, ch * 0.62, rl.Color{0, 0, 0, col.a})
}

// Logarithmic swirl arms of soft motes spiralling from the rim into the center,
// fading in at the rim and out at the throat — the "being drawn in" read.
portal_vortex :: proc(cx, cy, cw, ch: f32, frame: u64, arms: int, rim, throat: rl.Color, speed: f32) {
    POINTS :: 16
    TURNS  :: f32(1.4)
    rot    := f32(frame) * 0.01
    for m in 0 ..< arms {
        arm := f32(m) / f32(arms) * math.TAU
        for j in 0 ..< POINTS {
            s   := math.mod(f32(j) / POINTS + f32(frame) * speed, 1)  // 0 rim → 1 center, looping
            rr  := 1 - s
            ang := arm + s * TURNS * math.TAU + rot
            px  := cx + math.cos(ang) * cw * rr
            py  := cy + math.sin(ang) * ch * rr
            col := portal_mix(rim, throat, s)
            col.a = u8(f32(col.a) * math.sin(s * math.PI))           // fade in/out
            rl.DrawCircleGradient({px, py}, (0.7 + rr * 1.8) * 2.2, col, rl.Color{})
        }
    }
}

// Bright rim ring, thickened by two faint offset rings for an additive glow.
portal_rim :: proc(cx, cy, cw, ch: f32, col: rl.Color, pulse: f32) {
    rl.DrawEllipseLines(i32(cx), i32(cy), cw, ch, rl.Color{col.r, col.g, col.b, u8(130 + 100 * pulse)})
    rl.DrawEllipseLines(i32(cx), i32(cy), cw * 1.03, ch * 1.02, rl.Color{col.r, col.g, col.b, u8(50 + 40 * pulse)})
    rl.DrawEllipseLines(i32(cx), i32(cy), cw * 0.97, ch * 0.98, rl.Color{col.r, col.g, col.b, u8(50 + 40 * pulse)})
}

// A couple of ripple rings expanding out from the mouth and fading.
portal_ripples :: proc(cx, cy, hw, hh: f32, frame: u64, col: rl.Color) {
    RINGS :: 2
    for k in 0 ..< RINGS {
        ph := math.mod(f32(frame) * 0.006 + f32(k) / RINGS, 1)
        rw := hw * (0.5 + ph * 0.8)
        rh := hh * (0.5 + ph * 0.8)
        a  := u8(f32(col.a) * (1 - ph) * 0.5)
        rl.DrawEllipseLines(i32(cx), i32(cy), rw, rh, rl.Color{col.r, col.g, col.b, a})
    }
}

// Twinkling cross-glints drifting around the rim.
portal_glints :: proc(cx, cy, cw, ch: f32, frame: u64, col: rl.Color) {
    for i in 0 ..< 4 {
        base := f32(u32(i) * 2654435761 % 628) / 100
        dir  := i % 2 == 0 ? f32(1) : f32(-1)
        ang  := base + f32(frame) * 0.004 * dir
        tw   := 0.5 + 0.5 * math.sin(f32(frame) * 0.08 + f32(i) * 1.7)
        px   := cx + math.cos(ang) * cw
        py   := cy + math.sin(ang) * ch
        r    := 1.5 + 2.5 * tw
        c    := rl.Color{col.r, col.g, col.b, u8(200 * tw)}
        rl.DrawLineEx({px - r, py}, {px + r, py}, 1, c)
        rl.DrawLineEx({px, py - r}, {px, py + r}, 1, c)
        rl.DrawCircleGradient({px, py}, r, c, rl.Color{})
    }
}

// Tall, luminous sky gate: cool aurora vortex whorling into a deep-blue throat.
draw_sky_portal :: proc(cx, cy: f32, frame: u64) {
    pulse := 0.5 + 0.5 * math.sin(f32(frame) * 0.05)
    hw := 2.5 * f32(CELL_SIZE)   // halo reach
    hh := 5.0 * f32(CELL_SIZE)
    cw := 1.4 * f32(CELL_SIZE)   // mouth
    ch := 2.8 * f32(CELL_SIZE)
    glow := rl.Color{120, 200, 255, 255}

    rl.BeginBlendMode(.ADDITIVE)
    portal_bloom(cx, cy, hw, hh, glow, pulse)
    rl.EndBlendMode()

    portal_core(cx, cy, cw, ch, rl.Color{6, 12, 34, 235})

    rl.BeginBlendMode(.ADDITIVE)
    portal_vortex(cx, cy, cw, ch, frame, 3, rl.Color{190, 240, 255, 255}, rl.Color{90, 140, 255, 220}, 0.006)
    portal_ripples(cx, cy, hw, hh, frame, rl.Color{150, 210, 255, 200})
    portal_rim(cx, cy, cw, ch, glow, pulse)
    portal_glints(cx, cy, cw, ch, frame, rl.Color{220, 245, 255, 255})
    rl.EndBlendMode()
}

// Tall, ominous cave gate: an ember whirl in a black maw, green veins clawing
// the rim.  Dormant (locked) gates are dim and slow, sealed with a faint rune.
draw_cave_portal :: proc(cx, cy: f32, frame: u64, active: bool) {
    pulse := 0.5 + 0.5 * math.sin(f32(frame) * 0.06)
    hw := 2.5 * f32(CELL_SIZE)
    hh := 5.0 * f32(CELL_SIZE)
    cw := 1.5 * f32(CELL_SIZE)
    ch := 3.0 * f32(CELL_SIZE)
    life := active ? f32(1) : f32(0.35)
    red  := rl.Color{210, 45, 45, u8(255 * life)}

    if active {
        rl.BeginBlendMode(.ADDITIVE)
        portal_bloom(cx, cy, hw, hh, red, pulse)
        rl.EndBlendMode()
    }

    portal_core(cx, cy, cw, ch, rl.Color{10, 0, 8, 240})

    // Green veins clawing around the maw, brighter when the gate is alive.
    green := rl.Color{40, 200, 80, u8(active ? 170 : 70)}
    for i in 0 ..< 9 {
        ang := f32(i) / 9.0 * math.TAU + f32(frame) * 0.002
        x0  := cx + math.cos(ang) * cw * 1.1
        y0  := cy + math.sin(ang) * ch * 1.1
        x1  := cx + math.cos(ang + 0.35) * hw * 0.8
        y1  := cy + math.sin(ang + 0.35) * hh * 0.8
        x2  := cx + math.cos(ang) * hw
        y2  := cy + math.sin(ang) * hh
        rl.DrawLineEx({x0, y0}, {x1, y1}, 1.5, green)
        rl.DrawLineEx({x1, y1}, {x2, y2}, 1.5, green)
    }

    rl.BeginBlendMode(.ADDITIVE)
    if active {
        portal_vortex(cx, cy, cw, ch, frame, 3, rl.Color{255, 130, 60, 255}, rl.Color{150, 20, 60, 220}, 0.007)
        portal_ripples(cx, cy, hw, hh, frame, rl.Color{220, 60, 50, 180})
        portal_glints(cx, cy, cw, ch, frame, rl.Color{255, 170, 120, 255})
    }
    portal_rim(cx, cy, cw, ch, red, active ? pulse : pulse * 0.4)
    rl.EndBlendMode()

    // Sealing rune drawn across a dormant maw — the gate is barred.
    if !active {
        draw_title_rune(title_runes[3], cx, cy, f32(CELL_SIZE) * 2.6, 0, rl.Color{150, 40, 50, 130}, 2, 5)
    }
}
