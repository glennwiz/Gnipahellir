package game

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

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
	world_cam.zoom *= SS_SCALE
	rl.BeginMode2D(world_cam)
	draw_world(gs)
	draw_tile_ambience(gs)
	draw_falling_blocks(gs)
	draw_mining_cracks(gs)
	draw_portals(gs)
	draw_placement_ghost(gs)
	draw_wand_target(gs)
	draw_reclaim_target(gs)
	draw_golem_orders(gs)
	draw_player(&gs.player, gs.player_form, gs.player_step_visual_y)
	draw_enemies(&gs.enemies, gs.elapsed_time)
	draw_golems(gs)
	draw_projectiles(&gs.projectiles)
	draw_tile_fx(gs)
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
	src := rl.Rectangle{0, 0, f32(target.texture.width), -f32(target.texture.height)} // negative height: render textures are y-flipped
	dst := rl.Rectangle{offset.x, offset.y, f32(SCREEN_W) * scale, f32(SCREEN_H) * scale}

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
	Pixel_Gem,
	Pixel_Miner_Body,
	Pixel_Cloud,
	Pixel_Door,
	Pixel_Dirt,
	Pixel_Clay,
	Pixel_Flower_Bed,
	Pixel_Rune_Scroll_Chest,
	Pixel_Steam,
	Pixel_Mushroom,
	Pixel_Mossy_Stone,
	Pixel_Mana_Mist,
}

@(rodata)
tile_draw_style := #partial [Tile_Type]Draw_Style {
	.Wood                  = .Pixel_Wood,
	.Leaves                = .Pixel_Leaves,
	.Flower                = .Pixel_Flower,
	.Emerald_Ore           = .Pixel_Gem,
	.Jade_Ore              = .Pixel_Gem,
	.Diamond_Ore           = .Pixel_Gem,
	.Hel_Gem_Ore           = .Pixel_Gem,
	.Miner_Body            = .Pixel_Miner_Body,
	.Cloud                 = .Pixel_Cloud,
	.Door                  = .Pixel_Door,
	.Dirt                  = .Pixel_Dirt,
	.Clay                  = .Pixel_Clay,
	.Flower_Bed            = .Pixel_Flower_Bed,
	.Sky_Rune_Scroll_Chest = .Pixel_Rune_Scroll_Chest,
	.Rune_Scroll_Chest_A   = .Pixel_Rune_Scroll_Chest,
	.Rune_Scroll_Chest_B   = .Pixel_Rune_Scroll_Chest,
	.Rune_Scroll_Chest_C   = .Pixel_Rune_Scroll_Chest,
	.Rune_Coffer           = .Pixel_Rune_Scroll_Chest,
	.Steam                 = .Pixel_Steam,
	.Green_Cave_Mushroom   = .Pixel_Mushroom,
	.Mossy_Stone           = .Pixel_Mossy_Stone,
	.Mana_Mist             = .Pixel_Mana_Mist,
	// all others default to .Solid (zero value)
}

// ─── World / Terrain ──────────────────────────────────────────────────────────

// Outline drawn on every solid tile (not sky/void) — a test grid.  The camera
// works in virtual pixels (a tile is CELL_SIZE units), so GRID_LINE_PX is the
// on-screen line width in virtual px; we divide by the zoom so the line stays a
// constant width (and doesn't balloon or thrash) as you zoom.  Drawn as a quad
// via DrawRectangleLinesEx — a plain DrawRectangleLines is a 1px framebuffer
// hairline that flickers under the supersample.  Alpha + px are the knobs.
GRID_LINE :: rl.Color{0, 0, 0, 80}
GRID_LINE_PX :: f32(2.5)
// Grid fades in with zoom: hidden at/below LO (dense = noise), full at/above HI.
GRID_FADE_LO :: f32(1.6)
GRID_FADE_HI :: f32(2.6)

// Ground-item rune scroll pulse: radians/sec for the glow sine wave.
RUNE_SCROLL_PULSE_SPEED :: f32(4.0)

// ─── Tile Ambience ────────────────────────────────────────────────────────────
//
//  Always-on atmospheric motes — lava embers, cave dust — drawn as pure
//  functions of elapsed time and a per-tile hash: no pool, no update step, no
//  state, so ambience never competes with the combat particle store. Motion is
//  whole-pixel and brightness is stepped, matching the boot screen's ember
//  language. New ambience = a Tile_Ambience member, a tile_ambience table row,
//  and an arm in draw_tile_ambience.

Tile_Ambience :: enum u8 {
	None,
	Fire_Embers,  // sparks rising off an exposed (open-above) face
	Growth_Motes, // life-green flecks climbing a growing sapling
}

@(rodata)
tile_ambience := #partial [Tile_Type]Tile_Ambience {
	.Lava        = .Fire_Embers,
	.Magic_Lava  = .Fire_Embers,
	.Tree_Grower = .Growth_Motes,
}

// Bright/dark ember pair per emitter, mirroring enemy_blood's per-kind shades.
@(rodata)
ember_palette := #partial [Tile_Type][2]rl.Color {
	.Lava       = {{255, 170, 60, 255}, {255, 70, 20, 255}},
	.Magic_Lava = {{235, 100, 240, 255}, {150, 40, 170, 255}}, // hell-magic magenta
}

// Dust lives in open cells wherever there is cave overhead: below the surface
// line on level 0, everywhere in the deep levels and spawned dimensions —
// never in the sky.
DUST_COLOR :: rl.Color{185, 190, 205, 255}

draw_tile_ambience :: proc(gs: ^Game_State) {
	t := gs.elapsed_time
	deep := gs.level_index == LEVEL_CAVE2 || gs.level_index == LEVEL_CAVE3 ||
		gs.level_index == LEVEL_DIMENSION
	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			idx := grid_idx(x, y)
			tile := gs.world.terrain[idx]
			h := whash(u32(idx))

			// Cave dust: a sparse scatter of slow pale motes in open cells.
			if tile == .Air || tile == .Void {
				underground := deep || (gs.level_index == LEVEL_SURFACE && y >= SURFACE_Y)
				if underground && h % 14 == 0 {
					draw_dust_mote(x, y, h, t)
				}
				continue
			}

			switch tile_ambience[tile] {
			case .None:
			case .Fire_Embers:
				// Embers rise only off an exposed face — lava sealed in stone
				// (Hell's trap pockets) stays quiet until it's mined open.
				above: Tile_Type = .Air
				if y > 0 {above = gs.world.terrain[grid_idx(x, y - 1)]}
				if above == .Air || above == .Void {
					draw_fire_embers(x, y, h, t, ember_palette[tile])
				}
			case .Growth_Motes:
				// Motes ride each grower's own saved clock: silent while a
				// tree column is blocked (tick_grower zeroes the timer) and
				// silent once a flower bed ripens (the blooms themselves say
				// "harvest me") — motes always mean actively growing.
				gt := gs.world.sim_data[idx].growth_timer
				p: f32
				rise: f32
				pal: [2]rl.Color
				if tile == .Tree_Grower {
					p = gt / TREE_GROW_TIME
					rise = f32(TREE_MAX_H * CELL_SIZE - 4)
					pal = {{110, 230, 110, 255}, {70, 190, 60, 255}}
				} else { 	// .Flower_Bed
					p = gt < FLOWER_BED_GROW_TIME ? gt / FLOWER_BED_GROW_TIME : 0
					rise = f32(CELL_SIZE)
					pal = {{110, 230, 110, 255}, {255, 220, 50, 255}} 	// leaf + bloom gold
				}
				if p > 0 {
					draw_growth_motes(x, y, h, t, clamp(p, 0, 1), rise, pal)
				}
			}
		}
	}
}

// Two sparks per surface cell, each looping its own rise: whole-pixel climb,
// hash-desynced period and sway, brightness stepped down in thirds of the
// flight instead of a smooth fade.
draw_fire_embers :: proc(x, y: int, h: u32, t: f32, pal: [2]rl.Color) {
	for i in 0 ..< 2 {
		hh := whash(h + u32(i) * 97)
		period := 1.6 + f32(hh % 100) * 0.012 	// 1.6–2.8 s per rise
		phase := math.mod(t / period + f32(hh % 255) / 255.0, 1.0)
		rise := phase * (12 + f32(hh % 8))
		sway := math.sin(phase * 6.28318 * (2 + f32(hh % 3))) * 2
		px := math.floor(f32(x * CELL_SIZE) + 1 + f32(hh % 7) + sway)
		py := math.floor(f32(y * CELL_SIZE) + 1 - rise)
		col := pal[i & 1]
		col.a = phase < 0.4 ? 255 : phase < 0.75 ? 160 : 80
		size := phase < 0.35 ? f32(2) : f32(1)
		rl.DrawRectangleRec({px, py, size, size}, col)
	}
}

// Two life flecks spiraling up alongside whatever is growing, never higher
// than the growth has actually reached — the motes ARE the progress read at
// a distance. Palette pair per crop, stepped alpha.
draw_growth_motes :: proc(x, y: int, h: u32, t: f32, p: f32, full_rise: f32, pal: [2]rl.Color) {
	for i in 0 ..< 2 {
		hh := whash(h + u32(i) * 131)
		period := 2.2 + f32(hh % 90) * 0.01
		phase := math.mod(t / period + f32(hh % 255) / 255.0, 1.0)
		max_rise := 2 + p * full_rise 	// the growth tip's own climb
		sway := math.sin(phase * 6.28318 * 3 + f32(hh % 5)) * 2.5
		px := math.floor(f32(x * CELL_SIZE) + f32(CELL_SIZE / 2) + sway)
		py := math.floor(f32(y * CELL_SIZE) - phase * max_rise)
		col := pal[i]
		col.a = phase < 0.7 ? 200 : 90
		rl.DrawRectangleRec({px, py, 1, 1}, col)
	}
}

// One pixel drifting a slow figure inside its cell, shimmering between two
// alpha states — never a smooth pulse.
draw_dust_mote :: proc(x, y: int, h: u32, t: f32) {
	period := 6 + f32(h % 5)
	phase := math.mod(t / period + f32(h % 97) / 97.0, 1.0)
	px := math.floor(f32(x * CELL_SIZE) + 1 + f32(h % 8) + math.sin(phase * 6.28318) * 3)
	py := math.floor(f32(y * CELL_SIZE) + 1 + f32((h >> 4) % 8) + math.sin(phase * 12.56636 + f32(h % 7)) * 2)
	col := DUST_COLOR
	col.a = math.mod(t * 0.8 + f32(h % 13) * 0.3, 1.0) < 0.6 ? 70 : 35
	rl.DrawRectangleRec({px, py, 1, 1}, col)
}

draw_world :: proc(gs: ^Game_State) {
	w := &gs.world
	grid_thick := GRID_LINE_PX / max(gs.zoom, ZOOM_MIN)
	grid_fade := clamp((gs.zoom - GRID_FADE_LO) / (GRID_FADE_HI - GRID_FADE_LO), 0, 1)
	grid_col := GRID_LINE
	grid_col.a = u8(f32(GRID_LINE.a) * grid_fade)
	draw_grid := grid_col.a > 0
	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			idx := grid_idx(x, y)
			t := w.terrain[idx]
			px := i32(x * CELL_SIZE)
			py := i32(y * CELL_SIZE)
			draw_tile(gs, t, x, y)

			if draw_grid && t != .Air && t != .Void {
				rl.DrawRectangleLinesEx(
					{f32(px), f32(py), CELL_SIZE, CELL_SIZE},
					grid_thick,
					grid_col,
				)
			}

			// World item drop: the item's own pixel icon, no outline
			it := w.items[idx]
			if it != .None && w.item_counts[idx] > 0 {
				if is_rune_scroll(it) {
					// Rune Scrolls pulse in a brightened version of their own
					// seal color (bronze/silver/gold/sky — see items.odin) so
					// each tier's glow reads apart, with a dark halo behind it
					// so the ring shows against the light-blue sky instead of
					// blending into it.
					pulse := (math.sin(gs.elapsed_time * RUNE_SCROLL_PULSE_SPEED) + 1) * 0.5
					grow := i32(pulse * 5)
					halo_ext := grow + 2
					rl.DrawRectangle(
						px + 2 - halo_ext,
						py + 2 - halo_ext,
						6 + halo_ext * 2,
						6 + halo_ext * 2,
						rl.Color{0, 0, 0, 100},
					)
					base := item_table[it].color
					glow_col := rl.Color {
						u8(clamp(f32(base.r) * 1.3 + 40, 0, 255)),
						u8(clamp(f32(base.g) * 1.3 + 40, 0, 255)),
						u8(clamp(f32(base.b) * 1.3 + 40, 0, 255)),
						u8(150 + pulse * 105),
					}
					rl.DrawRectangle(
						px + 2 - grow,
						py + 2 - grow,
						6 + grow * 2,
						6 + grow * 2,
						glow_col,
					)
				}
				// Same 8x8 footprint as the old flat square; draw_item_icon
				// falls back to that flat color for items without art.
				draw_item_icon(it, px + 1, py + 1, 8)
			}
		}
	}
	// The workbench, like the rune scroll chest, is wider than its one-cell
	// collision footprint and needs a clean overlay pass after the grid.
	draw_crafting_benches(gs)
	draw_smelters(gs)
	// Rune Scroll chests deliberately spill beyond one 10px terrain cell.  Draw
	// them after the grid so neighboring backdrop cells cannot crop the coffer.
	draw_rune_scroll_chests(gs)
	draw_golem_monuments(gs)
	// The surface descent shaft breaks the grass line as a raw Void slot —
	// dress its lip into a proper cave mouth (surface level only).
	if gs.level_index == LEVEL_SURFACE do draw_shaft_mouth(gs)
	// Cloud puffs go over everything tile-drawn so their round bulges merge
	// across cells instead of being clipped by neighboring Air rects.
	if gs.level_index == LEVEL_SKY do draw_cloud_layer(gs)
	// The altar is a foreground station: on the sky level it must sit over the
	// neighboring cloud puffs rather than disappear into their broad bulges.
	draw_sky_altars(gs)
	if gs.level_index == LEVEL_SKY do draw_sky_apparition(gs)
	// Pipe casing over everything — it dresses whatever fluid/gas is already
	// there, so it must draw last to sit visibly on top.
	draw_mana_pipes(gs)
}

// ─── Clay-golem automation visuals ───────────────────────────────────────────

draw_golem_orders :: proc(gs: ^Game_State) {
	if equipped_command_wand(gs) == .None do return
	pulse := u8(100 + 45 * (math.sin(gs.elapsed_time * 5) + 1) * .5)
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		if .Golem_Marked not_in gs.world.tile_flags[grid_idx(x, y)] do continue
		px, py := i32(x * CELL_SIZE), i32(y * CELL_SIZE)
		col := rl.Color{70, 245, 180, pulse}
		rl.DrawRectangle(px + 1, py + 1, CELL_SIZE - 2, CELL_SIZE - 2, rl.Color{35, 180, 125, 45})
		rl.DrawRectangleLines(px, py, CELL_SIZE, CELL_SIZE, col)
		rl.DrawLine(px + 2, py + 2, px + CELL_SIZE - 3, py + CELL_SIZE - 3, col)
		rl.DrawLine(px + CELL_SIZE - 3, py + 2, px + 2, py + CELL_SIZE - 3, col)
	}
	w := gs.golems.work[gs.level_index]
	if w.active {
		x := f32(w.min.x * CELL_SIZE); y := f32(w.min.y * CELL_SIZE)
		ww := f32((w.max.x - w.min.x + 1) * CELL_SIZE)
		hh := f32((w.max.y - w.min.y + 1) * CELL_SIZE)
		zone_pulse := u8(105 + 55 * (math.sin(gs.elapsed_time * 4) + 1) * 0.5)
		rl.DrawRectangleLinesEx(
			{x, y, ww, hh},
			1.5 / max(gs.zoom, 1),
			rl.Color{90, 225, 145, zone_pulse},
		)
	}
	if gs.ui.golem_zone_drag {
		a, b := gs.ui.golem_zone_start, gs.input.mouse_tile
		lo := [2]i32{min(a.x, b.x), min(a.y, b.y)}
		hi := [2]i32{max(a.x, b.x), max(a.y, b.y)}
		hi.x = min(
			hi.x,
			lo.x + GOLEM_ZONE_MAX_W - 1,
		); hi.y = min(hi.y, lo.y + GOLEM_ZONE_MAX_H - 1)
		rl.DrawRectangleLinesEx(
			{
				f32(lo.x * CELL_SIZE),
				f32(lo.y * CELL_SIZE),
				f32((hi.x - lo.x + 1) * CELL_SIZE),
				f32((hi.y - lo.y + 1) * CELL_SIZE),
			},
			2 / max(gs.zoom, 1),
			rl.Color{140, 255, 180, 220},
		)
	}

	draw_plan := proc(gs: ^Game_State, plan: Golem_Plan, anchor: [2]i32, placed: bool) {
		if plan == .None do return
		info := &golem_plan_table[plan]
		for c in info.cells {
			T := anchor + c.off
			if !in_bounds(int(T.x), int(T.y)) do continue
			done := get_tile(&gs.world, int(T.x), int(T.y)) == c.tile
			if done && !placed do continue
			col := item_table[c.item].color
			col.a = 55 if !done else 110
			rl.DrawRectangle(T.x * CELL_SIZE, T.y * CELL_SIZE, CELL_SIZE, CELL_SIZE, col)
			rl.DrawRectangleLines(
				T.x * CELL_SIZE,
				T.y * CELL_SIZE,
				CELL_SIZE,
				CELL_SIZE,
				rl.Color{220, 190, 120, 170},
			)
		}
	}
	p := gs.golems.projects[gs.level_index]
	if p.active && !p.complete do draw_plan(gs, p.plan, p.anchor, true)
	if gs.ui.golem_plan != .None do draw_plan(gs, gs.ui.golem_plan, gs.input.mouse_tile, false)
}

// Per-mode command ring around each worker while the wand is held. Exhaustive
// so a future mode cannot silently miss its color.
@(rodata)
golem_mode_ring := [Golem_Mode]rl.Color {
	.Gather = {75, 235, 145, 160},
	.Build  = {235, 180, 75, 180},
	.Fight  = {235, 85, 75, 180},
}
@(rodata)
golem_mode_ring_hot := [Golem_Mode]rl.Color {
	.Gather = {135, 255, 185, 255},
	.Build  = {255, 215, 95, 255},
	.Fight  = {255, 120, 100, 255},
}

draw_golems :: proc(gs: ^Game_State) {
	hovered := -1
	if equipped_command_wand(gs) != .None do hovered = golem_at_world_point(gs, gs.input.mouse_world)
	for &g, i in gs.golems.data {
		if (g.status != .Deployed && g.status != .Broken) || g.level != gs.level_index do continue
		x := i32((g.pos.x - 0.05) * CELL_SIZE)
		y := i32((g.pos.y - 0.10) * CELL_SIZE)
		clay := rl.Color{178, 116, 78, 255}; dark := rl.Color{82, 48, 34, 255}
		glow := rl.Color{75, 235, 145, 255}
		if g.status == .Broken {
			rl.DrawRectangle(x + 1, y + 5, 6, 3, dark)
			rl.DrawRectangle(x + 2, y + 4, 2, 2, clay)
			rl.DrawLine(x + 3, y + 4, x + 5, y + 7, rl.Color{25, 18, 16, 255})
			continue
		}
		bob := i32(0)
		if abs(g.vel.x) > 0.1 do bob = i32((math.sin(gs.elapsed_time * 16 + f32(i)) * 0.5 + 0.5))
		// Oversized head, compact body and swinging pebble feet: deliberately
		// smaller and rounder than the cave builders.
		rl.DrawRectangle(x + 1, y + bob, 6, 4, dark)
		rl.DrawRectangle(x + 2, y + 1 + bob, 4, 3, clay)
		rl.DrawRectangle(x + 2, y + 4 + bob, 4, 3, dark)
		rl.DrawRectangle(x + 3, y + 4 + bob, 2, 2, clay)
		rl.DrawRectangle(x + 2, y + 2 + bob, 1, 1, glow)
		rl.DrawRectangle(x + 5, y + 2 + bob, 1, 1, glow)
		step := i32(1) if math.sin(gs.elapsed_time * 16 + f32(i)) > 0 else i32(0)
		rl.DrawRectangle(x + 1 + step, y + 7, 2, 1, dark)
		rl.DrawRectangle(x + 5 - step, y + 7, 2, 1, dark)
		shown := g.carry
		if shown == .None do shown = golem_pack_peek(&g)
		cargo_n := golem_pack_count(&g) + (1 if g.carry != .None else 0)
		if shown != .None {
			draw_item_icon(shown, x - 1, y - 7 + bob, 10)
			rl.DrawLine(x + 2, y, x + 1, y - 2, clay); rl.DrawLine(x + 5, y, x + 6, y - 2, clay)
			if cargo_n > 1 {
				buf: [8]u8; fmt.bprintf(buf[:7], "%d", cargo_n)
				rl.DrawText(cstring(raw_data(buf[:])), x + 7, y - 7 + bob, 5, rl.WHITE)
			}
		}
		if equipped_command_wand(gs) != .None {
			rl.DrawRectangleLines(x, y - 1, 8, 10, golem_mode_ring[g.mode])
			if hovered == i {
				rl.DrawRectangleLinesEx(
					{f32(x - 2), f32(y - 3), 12, 14},
					1.5,
					golem_mode_ring_hot[g.mode],
				)
			}
		}
	}
}

draw_golem_monuments :: proc(gs: ^Game_State) {
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		t := get_tile(&gs.world, x, y)
		if t != .Clay_Hearth && t != .Golem_Depot && t != .World_Anchor do continue
		px, py := i32(x * CELL_SIZE), i32(y * CELL_SIZE)
		pulse := (math.sin(gs.elapsed_time * 3 + f32(x)) + 1) * 0.5
		#partial switch t {
		case .Clay_Hearth:
			rl.DrawRectangle(px - 5, py - 8, 20, 15, rl.Color{82, 48, 34, 255})
			rl.DrawRectangle(px - 3, py - 6, 16, 11, rl.Color{170, 98, 58, 255})
			rl.DrawRectangle(px + 2, py - 4, 6, 7, rl.Color{40, 22, 18, 255})
			rl.DrawRectangle(px + 3, py - 3, 4, 4, rl.Color{255, 120, u8(35 + pulse * 55), 255})
		case .Golem_Depot:
			rl.DrawRectangle(px - 8, py - 10, 26, 18, rl.Color{48, 42, 38, 255})
			rl.DrawRectangle(px - 6, py - 8, 22, 14, rl.Color{92, 72, 52, 255})
			rl.DrawRectangleLines(px - 6, py - 8, 22, 14, rl.Color{80, 225, 145, 220})
			for k in 0 ..< 3 do rl.DrawRectangle(px - 3 + i32(k) * 6, py - 4, 4, 5, rl.Color{145, 98, 62, 255})
		case .World_Anchor:
			rl.DrawCircle(px + 5, py - 5, 9, rl.Color{40, 24, 55, 220})
			rl.DrawCircleLines(px + 5, py - 5, 8, rl.Color{180, 105, 235, u8(150 + pulse * 100)})
			rl.DrawLine(px + 5, py - 13, px + 5, py + 5, rl.Color{225, 190, 255, 255})
		case:
		}
	}
}

// ─── Surface descent shaft: the cave mouth ────────────────────────────────────
//
// The entrance shaft (world.odin §5) punches a raw 2-wide .Void column through
// the grass line down to the cave.  Left bare it reads as a flat black slot cut
// into the green — no depth, no edge.  This render-only pass gives it a mouth:
// earthen throat walls that darken into the dark, a cut-soil lip where the grass
// is sheared open, a lit grass rim, and an apron of scuffed earth that spreads
// onto the neighboring blocks and diminishes the further you are from the shaft
// on the X axis.  It keys off the terrain itself — a Void column running the
// whole surface-cap band, bordered by ground (is_shaft_column) — so it dresses
// any full-depth shaft, even a hand-dug one, not a hardcoded column; a shallow
// player dig stays undressed.  Reads state, never mutates.
draw_shaft_mouth :: proc(gs: ^Game_State) {
	w := &gs.world
	WALL_PX :: i32(3)
	REACH :: SHAFT_APRON_REACH // brown scuff hugs the lip; blocks
	// past this read as normal grass.
	// Shared with mining's rock+dirt yield.
	APRON_A :: f32(90) // apron alpha at the shaft edge
	grass_rim := rl.Color{78, 190, 78, 255} // grass edge lit by open sky
	soil := rl.Color{96, 66, 38, 0} // scuffed topsoil (alpha per tile)
	span := f32(CAVE_TOP - SURFACE_Y)
	for y in SURFACE_Y ..< CAVE_TOP {
		for x in 0 ..< GRID_W {
			if w.terrain[grid_idx(x, y)] != .Void do continue
			if !is_shaft_column(w, x) do continue // a shallow dig, not a shaft mouth
			px := i32(x * CELL_SIZE)
			py := i32(y * CELL_SIZE)
			// Throat wall darkens with depth: fresh topsoil at the rim sinking
			// toward near-black as it drops into the cave.
			d := clamp(f32(y - SURFACE_Y) / span, 0, 1)
			wall := rl.Color{u8(104 - 76 * d), u8(72 - 52 * d), u8(40 - 28 * d), 255}
			top_mouth := y == SURFACE_Y && get_tile(w, x, y - 1) == .Air
			for dir in ([]int{-1, 1}) {
				nx := x + dir
				if nx < 0 || nx >= GRID_W do continue
				nt := w.terrain[grid_idx(nx, y)]
				if nt == .Void || nt == .Air do continue // shaft, not a wall
				// Apron first (behind): scuffed earth onto the blocks, alpha
				// falling off tile-by-tile with X distance from the shaft.
				for k in 0 ..< REACH {
					gx := x + dir * (k + 1)
					if gx < 0 || gx >= GRID_W do break
					gt := w.terrain[grid_idx(gx, y)]
					if gt == .Void || gt == .Air do break
					s := soil
					// Ease-out (squared) so the scuff hugs the lip and reads as
					// gone well before REACH — a linear falloff stays half-lit at
					// the midpoint and looks flat across the whole span.
					t := 1 - f32(k) / f32(REACH)
					s.a = u8(APRON_A * t * t)
					rl.DrawRectangle(i32(gx * CELL_SIZE), py, CELL_SIZE, CELL_SIZE, s)
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
				hh := whash(u32(x) * 2654435761 ~ u32(nx) * 40503 ~ u32(y) * 668265263)
				grit := rl.Color{u8(128 - 84 * d), u8(104 - 68 * d), u8(72 - 48 * d), 255}
				rl.DrawRectangle(
					wall_x + i32(hh % u32(WALL_PX)),
					py + i32((hh >> 2) % u32(CELL_SIZE)),
					1,
					1,
					grit,
				)
				rl.DrawRectangle(
					edge_x + i32((hh >> 4) % u32(WALL_PX)),
					py + i32((hh >> 6) % u32(CELL_SIZE)),
					1,
					1,
					grit,
				)
				if y <= SURFACE_Y + 1 {
					root := rl.Color{96, 66, 36, 230}
					root_x := dir < 0 ? px + 1 : px + CELL_SIZE - 2
					rlen := i32(3 + hh % 5)
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
			breathe := math.sin(gs.elapsed_time * 0.9 + f32(h % 628) * 0.01)
			sway := math.sin(gs.elapsed_time * 0.5 + f32(h % 314) * 0.02)
			cx := f32(x * CELL_SIZE) + CELL_SIZE * 0.5 + sway * 1.5
			cy := f32(y * CELL_SIZE) + CELL_SIZE * 0.5
			r := f32(CELL_SIZE) * (0.60 + 0.05 * breathe)
			body := rl.Color{242, 246, 255, 240}
			rl.DrawCircleV({cx, cy + 1.5}, r, {205, 215, 240, 225}) // under-shade
			rl.DrawCircleV({cx - 1.5, cy - 1}, r * 0.90, body)
			rl.DrawCircleV({cx + 2, cy - 0.5}, r * 0.75, body)
			rl.DrawCircleV({cx - r * 0.3, cy - r * 0.4}, r * 0.45, {255, 255, 255, 210})
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
				sp := wood_variant(int(b.source_x), int(b.source_y))
				src := tile_atlas_rect(sp)
				dst := rl.Rectangle{f32(bx), f32(by), CELL_SIZE, CELL_SIZE}
				rl.DrawTexturePro(gs.assets.tile_atlas, src, dst, {0, 0}, 0, rl.WHITE)
			} else {
				draw_pixel_wood(bx, by)
			}
		case .Leaves:
			draw_pixel_leaves(bx, by)
		case:
			rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, terrain_table[b.tile].color)
		}
	}
}

// The Sky-Altar offering: the ingredients orbit a swelling glow above the
// capstone while a counter-rotating ring of rainbow runes wheels around them.
// Read-only — the swirl motes and the finishing flash are particles.
draw_ritual :: proc(gs: ^Game_State) {
	if !gs.ritual.active do return
	r := &gs.ritual
	t := r.timer
	prog := clamp(t / RITUAL_DURATION, 0, 1)
	cx := i32(r.altar.x * CELL_SIZE) + CELL_SIZE / 2
	cy := i32((r.altar.y - 2) * CELL_SIZE)
	tick := int(t * 12)

	// A stepped square bloom grows in whole pixels instead of a soft circle.
	grow := i32(prog * 8)
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRectangle(
		cx - 6 - grow,
		cy - 5 - grow,
		12 + grow * 2,
		10 + grow * 2,
		rl.Color{255, 210, 105, 22},
	)
	rl.DrawRectangle(
		cx - 4 - grow / 2,
		cy - 3 - grow / 2,
		8 + grow,
		6 + grow,
		rl.Color{255, 240, 185, 42},
	)
	rl.EndBlendMode()

	// Ingredient icons orbiting, spiralling inward toward the glow.
	orbit := (2.6 - prog * 1.4) * CELL_SIZE
	ings := structure_costs[r.tier]
	for ing, i in ings {
		ang := t * 3.0 + f32(i) * (2 * math.PI / f32(len(ings)))
		sz := i32(f32(CELL_SIZE) * 1.4)
		ix := cx + i32(math.cos(ang) * orbit) - sz / 2
		iy := cy + i32(math.sin(ang) * orbit) - sz / 2
		draw_item_icon(ing.item, ix, iy, sz)
	}

	// Six tiny rune tiles counter-rotate in snapped positions.
	rune_r := (3.4 - prog * 1.0) * CELL_SIZE
	RUNES :: 6
	for i in 0 ..< RUNES {
		ang := -t * 2.0 + f32(i) * (2 * math.PI / RUNES)
		rx := cx + i32(math.cos(ang) * rune_r) - 3
		ry := cy + i32(math.sin(ang) * rune_r) - 3
		cols := [3]rl.Color{{100, 220, 255, 220}, {255, 205, 90, 220}, {210, 120, 255, 220}}
		col := cols[(i + tick / 3) % len(cols)]
		rl.DrawRectangle(rx, ry, 6, 6, rl.Color{18, 22, 34, 210})
		draw_pixel_rune_mark(rx + 1, ry + 1, col, i + tick / 5)
	}
}

// The eternal minor swirl: once the first Sky ritual is done, its rune ring
// lives on over the altar forever — smaller, slower, dimmer.  Driven purely by
// elapsed_time and the saved progression flag, so it needs no state and
// survives save/load.  Silent while a full ritual owns the stage.
// Everything moves on float coordinates — a slow orbit quantized to whole
// world pixels reads as jerky steps.
draw_altar_eternal_swirl :: proc(gs: ^Game_State, altar_x, altar_y: int) {
	if gs.level_index != LEVEL_SKY do return
	if !gs.progression.sky_structure_complete[0] do return
	if gs.ritual.active do return
	t := gs.elapsed_time
	cx := f32(altar_x * CELL_SIZE) + CELL_SIZE / 2
	cy := f32((altar_y - 2) * CELL_SIZE)

	// A faint breathing bloom above the capstone.
	pulse := (math.sin(t * 1.6) + 1) * 2
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRectangleV(
		{cx - 5 - pulse, cy - 4 - pulse},
		{10 + pulse * 2, 8 + pulse * 2},
		rl.Color{120, 190, 255, 14},
	)
	rl.DrawRectangleV({cx - 3, cy - 2}, {6, 4}, rl.Color{185, 230, 255, 26})
	rl.EndBlendMode()

	rune_r := f32(2.0 * CELL_SIZE)

	// Blue motes drifting through the swirl, each breathing in and out of the
	// ring with a bright light core.
	MOTES :: 8
	for i in 0 ..< MOTES {
		phase := f32(i) * (2 * math.PI / MOTES)
		ang := t * (0.5 + f32(i % 3) * 0.12) + phase
		r := rune_r * (0.45 + 0.35 * math.sin(t * 0.9 + phase * 1.7))
		mx := cx + math.cos(ang) * r
		my := cy + math.sin(ang) * r
		a := 0.5 + 0.5 * math.sin(t * 2.0 + phase)
		rl.DrawRectangleV({mx - 1.5, my - 1.5}, {3, 3}, rl.Color{130, 200, 255, u8(60 + a * 90)})
		rl.DrawRectangleV({mx - 0.5, my - 0.5}, {1, 1}, rl.Color{225, 245, 255, u8(130 + a * 110)})
	}

	// Four rune tiles counter-rotate; glyph and color are fixed per rune —
	// the ring turns, the runes themselves don't shift.
	RUNES :: 4
	for i in 0 ..< RUNES {
		ang := -t * 0.8 + f32(i) * (2 * math.PI / RUNES)
		rx := cx + math.cos(ang) * rune_r - 2.5
		ry := cy + math.sin(ang) * rune_r - 2.5
		cols := [3]rl.Color{{100, 220, 255, 150}, {255, 205, 90, 150}, {210, 120, 255, 150}}
		col := cols[i % len(cols)]
		rl.DrawRectangleV({rx, ry}, {5, 5}, rl.Color{18, 22, 34, 140})
		draw_pixel_rune_mark_v({rx + 0.5, ry}, col, i)
	}
}

// ─── Sky apparition — a wordless tease at the top of the world ────────────────
//
//  gen_sky_level fills rows 0-27 with pure Air above the topmost cloud band
//  (row 28) — unclaimed space.  A chained, hound-shaped silhouette flickers
//  there, glimpsed only by someone who has climbed well above the known
//  platforms.  Never named as Garm anywhere in code; see garm.odin for what
//  the boss fight actually is.  What happens if the player "reaches" it is
//  deliberately unbuilt — a future hook, matching plan.md's "Garm + TBD".

SKY_APPARITION_GATE_ROW :: f32(20) // player pos.y must be below this for anything to show
SKY_APPARITION_CLEAR_ROW :: f32(6) // pos.y at/below this = fullest, longest read
SKY_APPARITION_PERIOD_FAR :: f32(17.0) // seconds between glimpses, right at the gate
SKY_APPARITION_PERIOD_NEAR :: f32(6.0) // seconds between glimpses, at clear altitude
SKY_APPARITION_WINDOW_FAR :: f32(0.5) // seconds visible, right at the gate (a flicker)
SKY_APPARITION_WINDOW_NEAR :: f32(3.0) // seconds visible, at clear altitude (lingers)
SKY_APPARITION_EDGE_FRAC :: f32(0.25) // fraction of the window spent fading in/out

// Deterministic glimpse state, pure function of level/altitude/elapsed_time
// (this codebase's sim has zero RNG). fade is this instant's flicker-window
// intensity (0 = invisible, 1 = fully in); clearness is the altitude ramp (0
// at the gate row, 1 at/above the clear row). Read-only — the single source
// of truth shared by the draw proc below and update_sky_apparition's
// (mutating) one-shot notify check in levels.odin, so their timing can never
// drift apart.
sky_apparition_glimpse :: proc(gs: ^Game_State) -> (fade, clearness: f32) {
	if gs.level_index != LEVEL_SKY do return
	clearness =
		1 -
		clamp(
			(gs.player.pos.y - SKY_APPARITION_CLEAR_ROW) /
			(SKY_APPARITION_GATE_ROW - SKY_APPARITION_CLEAR_ROW),
			0,
			1,
		)
	if clearness <= 0 do return

	period :=
		SKY_APPARITION_PERIOD_FAR +
		(SKY_APPARITION_PERIOD_NEAR - SKY_APPARITION_PERIOD_FAR) * clearness
	window :=
		SKY_APPARITION_WINDOW_FAR +
		(SKY_APPARITION_WINDOW_NEAR - SKY_APPARITION_WINDOW_FAR) * clearness
	phase := math.mod(gs.elapsed_time, period)
	if phase >= window do return

	s := phase / window
	fade = 1
	if s < SKY_APPARITION_EDGE_FRAC {
		fade = s / SKY_APPARITION_EDGE_FRAC
	} else if s > 1 - SKY_APPARITION_EDGE_FRAC {
		fade = (1 - s) / SKY_APPARITION_EDGE_FRAC
	}
	return
}

SKY_APPARITION_X :: f32(GRID_W) * 0.5 // tile column, grid-center
SKY_APPARITION_Y :: f32(4.5) // tile row, just under the grid's top edge
SKY_APPARITION_SWAY_X :: f32(2.5) // tiles, slow horizontal drift amplitude
SKY_APPARITION_SWAY_Y :: f32(1.0) // tiles, slow vertical drift amplitude
SKY_APPARITION_SWAY_SPEED :: f32(0.12) // rad/s — glacial: distant and bound, not alive/playful

SKY_APPARITION_BODY_COL :: rl.Color{10, 11, 16, 235} // near-black silhouette
SKY_APPARITION_GLOW_COL :: rl.Color{130, 170, 210, 40} // faint cold outline, additive
SKY_APPARITION_SCALE_FAR :: f32(0.6) // size multiplier at the gate
SKY_APPARITION_SCALE_NEAR :: f32(1.15) // size multiplier at clear altitude

// A wordless tease glimpsed above the clouds. Still and heavy, not orbiting:
// only a slow position sway (no rotation, no motes) plus the on/off flicker
// from sky_apparition_glimpse. Read-only — reads Game_State + calls raylib,
// never mutates.
draw_sky_apparition :: proc(gs: ^Game_State) {
	fade, clearness := sky_apparition_glimpse(gs)
	if fade <= 0 do return

	t := gs.elapsed_time
	sway_x := math.sin(t * SKY_APPARITION_SWAY_SPEED) * SKY_APPARITION_SWAY_X * CELL_SIZE
	sway_y :=
		math.sin(t * SKY_APPARITION_SWAY_SPEED * 0.7 + 1.3) * SKY_APPARITION_SWAY_Y * CELL_SIZE
	cx := SKY_APPARITION_X * CELL_SIZE + sway_x
	cy := SKY_APPARITION_Y * CELL_SIZE + sway_y

	scale :=
		(SKY_APPARITION_SCALE_FAR +
			(SKY_APPARITION_SCALE_NEAR - SKY_APPARITION_SCALE_FAR) * clearness) *
		CELL_SIZE
	dim := 0.5 + 0.5 * clearness // fainter far below the gate, solid near the top
	body_a := u8(f32(SKY_APPARITION_BODY_COL.a) * fade * dim)
	glow_a := u8(f32(SKY_APPARITION_GLOW_COL.a) * fade * dim)
	body := rl.Color {
		SKY_APPARITION_BODY_COL.r,
		SKY_APPARITION_BODY_COL.g,
		SKY_APPARITION_BODY_COL.b,
		body_a,
	}
	glow := rl.Color {
		SKY_APPARITION_GLOW_COL.r,
		SKY_APPARITION_GLOW_COL.g,
		SKY_APPARITION_GLOW_COL.b,
		glow_a,
	}

	// Couched, still torso + head — a low, heavy hound-like mass, not mid-stride.
	torso := rl.Rectangle{cx - scale * 2.2, cy - scale * 0.7, scale * 4.4, scale * 1.3}
	head := rl.Rectangle{cx - scale * 2.6, cy - scale * 1.1, scale * 1.5, scale * 1.1}

	rl.BeginBlendMode(.ADDITIVE)
	h := scale * 0.35
	rl.DrawRectangleV(
		{torso.x - h, torso.y - h},
		{torso.width + h * 2, torso.height + h * 2},
		glow,
	)
	rl.DrawRectangleV(
		{head.x - h * 0.6, head.y - h * 0.6},
		{head.width + h * 1.2, head.height + h * 1.2},
		glow,
	)
	rl.EndBlendMode()

	rl.DrawRectangleRec(torso, body)
	rl.DrawRectangleRec(head, body)

	ear_w, ear_h := scale * 0.35, scale * 0.5
	ex := head.x + scale * 0.25
	rl.DrawTriangle({ex, head.y}, {ex + ear_w, head.y}, {ex + ear_w * 0.5, head.y - ear_h}, body)
	ex2 := head.x + head.width - scale * 0.25 - ear_w
	rl.DrawTriangle(
		{ex2, head.y},
		{ex2 + ear_w, head.y},
		{ex2 + ear_w * 0.5, head.y - ear_h},
		body,
	)

	// Chain links trailing below the belly, fading into nothing — bound to
	// something never shown.
	LINKS :: 4
	lx := cx + scale * 0.6
	ly := torso.y + torso.height
	for i in 0 ..< LINKS {
		link_a := u8(f32(body_a) * (1 - f32(i) / LINKS))
		if link_a == 0 do continue
		y0 := ly + f32(i) * scale * 0.55
		y1 := y0 + scale * 0.55
		col := rl.Color{body.r, body.g, body.b, link_a}
		rl.DrawLineEx({lx, y0}, {lx, y1}, 1.5, col)
		rl.DrawRectangleV(
			{lx - scale * 0.18, y1 - scale * 0.12},
			{scale * 0.36, scale * 0.24},
			col,
		)
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
	if t == .Crafting_Bench || t == .Sky_Altar || t == .Smelter {
		// Backdrop only. These stations receive a larger pixel-art silhouette
		// after the terrain loop so neighboring cells cannot crop their art.
		bg := terrain_table[rune_scroll_chest_backdrop(gs.level_index, y)].color
		rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, bg)
		return
	}
	if glow := station_glow[t]; glow.a != 0 {
		rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, rl.Color{24, 22, 30, 255})
		pulse := (math.sin(gs.elapsed_time * 2.4 + f32(x * 7 + y * 13)) + 1) * 0.5
		g := glow
		g.a = u8(60 + pulse * 90)
		rl.DrawRectangle(px, py, CELL_SIZE, CELL_SIZE, g)
		draw_item_icon(terrain_table[t].drop_item, px, py, CELL_SIZE)
		draw_machine_progress(gs, t, x, y)
		return
	}
	switch tile_draw_style[t] {
	case .Pixel_Wood:
		draw_pixel_wood(px, py)
	case .Pixel_Leaves:
		draw_pixel_leaves(px, py)
	case .Pixel_Flower:
		draw_pixel_flower(px, py)
	case .Pixel_Gem:
		draw_pixel_gem(px, py, t)
	case .Pixel_Miner_Body:
		draw_pixel_miner_body(gs, px, py, x, y)
	case .Pixel_Door:
		draw_pixel_door(gs, px, py, x, y)
	case .Pixel_Dirt:
		draw_pixel_dirt(px, py)
	case .Pixel_Clay:
		draw_pixel_clay(px, py, x, y)
	case .Pixel_Flower_Bed:
		draw_pixel_flower_bed(gs, px, py, x, y)
	case .Pixel_Steam:
		draw_pixel_steam(gs, px, py, x, y)
	case .Pixel_Mana_Mist:
		draw_pixel_mana_mist(gs, px, py, x, y)
	case .Pixel_Mushroom:
		draw_pixel_mushroom(gs, px, py, x, y)
	case .Pixel_Mossy_Stone:
		draw_pixel_mossy_stone(gs, px, py, x, y)
	case .Pixel_Rune_Scroll_Chest:
		bg := terrain_table[rune_scroll_chest_backdrop(gs.level_index, y)].color
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

// ─── Pixel Art: Steam ─────────────────────────────────────────────────────────
//
//  Translucent vapour: the flat semi-transparent body plus a few paler wisps
//  that climb slowly, hashed per cell so a pooled cloud shimmers instead of
//  reading as one flat block.  Derived from elapsed_time only — read-only.

draw_pixel_steam :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, terrain_table[.Steam].color)
	wisp := rl.Color{245, 247, 252, 95}
	h := i32(x * 31 + y * 57)
	climb := i32(gs.elapsed_time * 3) // wisps rise a pixel every third of a second
	for i in i32(0) ..< 3 {
		wx := bx + (h * 7 + i * 13) %% CELL_SIZE
		wy := by + (h * 11 + i * 29 - climb) %% CELL_SIZE
		rl.DrawRectangle(wx, wy, 2, 1, wisp)
	}
}

// gem_tint_index (sim.odin) turned back into a real color — reads
// item_table[...].color directly so the tint always matches whatever that
// gem's color actually is.  0 (no gem recorded, e.g. a stale/edge-case cell)
// falls back to a neutral violet.
gem_tint_color :: proc(idx: u8) -> rl.Color {
	if idx == 0 || int(idx) > len(gem_tint_order) do return rl.Color{200, 170, 230, 255}
	return item_table[gem_tint_order[idx - 1]].color
}

// ─── Pixel Art: Mana Mist ───────────────────────────────────────────────────────
//
//  Steam's harmless twin: same translucent-body-plus-rising-wisps shape, but
//  tinted by whichever gem is currently fueling the Magic Kettle that
//  breathed it (gem_tint_color) instead of a fixed color — Emerald green,
//  Jade pale green, Diamond white/blue, Hel Gem red.

draw_pixel_mana_mist :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	tint := gem_tint_color(gs.fluid.gem_tint[grid_idx(x, y)])
	body := tint
	body.a = terrain_table[.Mana_Mist].color.a
	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, body)
	wisp := rl.Color{tint.r, tint.g, tint.b, 130}
	if wisp.r < 200 do wisp.r = 200 // keep the wisp reading bright against the dimmer body
	if wisp.g < 200 do wisp.g = 200
	if wisp.b < 200 do wisp.b = 200
	h := i32(x * 31 + y * 57)
	climb := i32(gs.elapsed_time * 3)
	for i in i32(0) ..< 3 {
		wx := bx + (h * 7 + i * 13) %% CELL_SIZE
		wy := by + (h * 11 + i * 29 - climb) %% CELL_SIZE
		rl.DrawRectangle(wx, wy, 2, 1, wisp)
	}
}

// ─── Pixel Art: Mana Pipe ────────────────────────────────────────────────────────
//
//  A Tile_Flag.Piped overlay (types.odin), not a Tile_Type — the underlying
//  cell stays whatever it naturally is (Air normally; Mana_Mist/Magic_Lava/
//  any other fluid when one is passing through) and fluid physics never
//  knows pipes exist.  Drawn as a separate pass over the grid (Piped cells
//  aren't keyed by their own Tile_Type, so they can't ride the main tile
//  switch), auto-tiled off the 4-neighbor Piped bitmask so a placed run of
//  pipes reads as a connected straight/corner/T/cross/stub network.  Lit
//  from within — Mana Mist's own gem tint, or the occupying fluid's flat
//  color otherwise — when a fluid/gas currently occupies the cell.

piped_at :: proc(w: ^World_Grid, x, y: int) -> bool {
	if !in_bounds(x, y) do return false
	return .Piped in w.tile_flags[grid_idx(x, y)]
}

draw_mana_pipes :: proc(gs: ^Game_State) {
	w := &gs.world
	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			if .Piped in w.tile_flags[grid_idx(x, y)] {
				draw_pixel_mana_pipe(gs, i32(x * CELL_SIZE), i32(y * CELL_SIZE), x, y)
			}
		}
	}
}

draw_pixel_mana_pipe :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	w := &gs.world
	n := piped_at(w, x, y - 1)
	s := piped_at(w, x, y + 1)
	e := piped_at(w, x + 1, y)
	we := piped_at(w, x - 1, y)

	casing := rl.Color{95, 85, 110, 255}
	dark := rl.Color{55, 48, 65, 255}
	band :: i32(4) // pipe thickness, centered in the 10px cell
	lo :: i32(3) // (CELL_SIZE - band) / 2

	rl.DrawRectangle(bx + lo, by + lo, band, band, casing) // the hub, always drawn
	if n do rl.DrawRectangle(bx + lo, by, band, lo + band, casing)
	if s do rl.DrawRectangle(bx + lo, by + lo, band, CELL_SIZE - lo, casing)
	if e do rl.DrawRectangle(bx + lo, by + lo, CELL_SIZE - lo, band, casing)
	if we do rl.DrawRectangle(bx, by + lo, lo + band, band, casing)
	rl.DrawRectangleLinesEx({f32(bx + lo), f32(by + lo), f32(band), f32(band)}, 1, dark)

	// Lit from within when a fluid/gas currently occupies this cell.
	t := get_tile(w, x, y)
	if is_fluid_tile(t) {
		glow :=
			t == .Mana_Mist ? gem_tint_color(gs.fluid.gem_tint[grid_idx(x, y)]) : terrain_table[t].color
		glow.a = 110
		rl.BeginBlendMode(.ADDITIVE)
		rl.DrawRectangle(bx + lo, by + lo, band, band, glow)
		rl.EndBlendMode()
	}
}

// ─── Pixel Art: Rune Scroll Chest ───────────────────────────────────────────────
//
// A compact 16×11 Norse coffer translated from sprites/blueprint_chests_concept.png:
// arched oak lid, three iron straps, corner rivets, and a tier-colored rune
// lock.  Its collision remains one cell; the broad silhouette is render-only.

draw_rune_scroll_chests :: proc(gs: ^Game_State) {
	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			t := get_tile(&gs.world, x, y)
			if is_rune_scroll_chest(t) || t == .Rune_Coffer {
				bx, by := i32(x * CELL_SIZE), i32(y * CELL_SIZE)
				if gs.pixel_art.sprites[.Rune_Scroll_Chest].has_data {
					draw_pixel_grid_sprite(gs, .Rune_Scroll_Chest, bx, by)
				} else {
					draw_pixel_rune_scroll_chest(gs, bx, by, t, x, y)
				}
			}
		}
	}
}

draw_pixel_rune_scroll_chest :: proc(gs: ^Game_State, bx, by: i32, t: Tile_Type, x, y: int) {
	ox, oy := bx - 3, by - 1
	outline := rl.Color{24, 20, 24, 255}
	iron := rl.Color{54, 56, 64, 255}
	iron_hi := rl.Color{108, 112, 122, 255}
	wood_d := rl.Color{74, 39, 24, 255}
	wood := rl.Color{126, 68, 36, 255}
	wood_hi := rl.Color{174, 102, 54, 255}
	accent := terrain_table[t].color
	pulse := (math.sin(gs.elapsed_time * 3.6 + f32(x * 3 + y * 5)) + 1) * 0.5
	glow := accent
	glow.a = u8(55 + pulse * 80)

	// A restrained colored aura makes the reward legible in black caves.
	rl.DrawRectangle(ox + 2, oy + 1, 12, 8, glow)

	// Black stepped silhouette: arched lid over a wider box and two feet.
	rl.DrawRectangle(ox + 2, oy, 12, 1, outline)
	rl.DrawRectangle(ox + 1, oy + 1, 14, 3, outline)
	rl.DrawRectangle(ox, oy + 4, 16, 6, outline)
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
	rl.DrawRectangle(ox + 1, oy + 4, 14, 2, iron)
	rl.DrawRectangle(ox + 1, oy + 4, 14, 1, iron_hi)
	for sx in ([3]i32{2, 7, 12}) {
		rl.DrawRectangle(ox + sx, oy + 1, 2, 8, iron)
		rl.DrawRectangle(ox + sx, oy + 2, 1, 6, iron_hi)
	}

	// Corner rivets and the bright rune-lock: the only tier-specific color.
	rl.DrawRectangle(ox + 2, oy + 5, 1, 1, iron_hi)
	rl.DrawRectangle(ox + 13, oy + 5, 1, 1, iron_hi)
	rl.DrawRectangle(ox + 2, oy + 8, 1, 1, iron_hi)
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
// this is a read-only overlay, just like the rune scroll chest.

draw_crafting_benches :: proc(gs: ^Game_State) {
	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			if get_tile(&gs.world, x, y) == .Crafting_Bench {
				bx, by := i32(x * CELL_SIZE), i32(y * CELL_SIZE)
				if gs.pixel_art.sprites[.Crafting_Bench].has_data {
					draw_pixel_grid_sprite(gs, .Crafting_Bench, bx, by)
				} else {
					draw_pixel_crafting_bench(gs, bx, by, x, y)
				}
			}
		}
	}
}

draw_pixel_crafting_bench :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	ox, oy := bx - 5, by - 4
	outline := rl.Color{24, 20, 24, 255}
	iron_d := rl.Color{42, 43, 49, 255}
	iron := rl.Color{65, 67, 75, 255}
	iron_hi := rl.Color{122, 126, 136, 255}
	wood_d := rl.Color{74, 39, 24, 255}
	wood := rl.Color{126, 68, 36, 255}
	wood_hi := rl.Color{174, 102, 54, 255}
	brass_d := rl.Color{124, 76, 24, 255}
	pulse := (math.sin(gs.elapsed_time * 2.4 + f32(x * 7 + y * 13)) + 1) * 0.5
	brass := rl.Color{u8(194 + pulse * 40), u8(130 + pulse * 42), u8(38 + pulse * 22), 255}
	hot := rl.Color{255, u8(198 + pulse * 38), u8(72 + pulse * 28), 255}

	// A small warm breath behind the station; the physical bench remains solid
	// and material-led rather than washed in the old full-tile magic glow.
	halo := station_glow[.Crafting_Bench]
	halo.a = u8(18 + pulse * 24)
	rl.DrawRectangle(ox + 3, oy + 3, 14, 9, halo)

	// One joined silhouette: slab/apron, legs, feet, and low cross-brace.
	rl.DrawRectangle(ox, oy + 3, 20, 5, outline)
	rl.DrawRectangle(ox + 2, oy + 7, 16, 4, outline)
	rl.DrawRectangle(ox + 2, oy + 8, 5, 6, outline)
	rl.DrawRectangle(ox + 13, oy + 8, 5, 6, outline)
	rl.DrawRectangle(ox + 5, oy + 11, 10, 3, outline)

	// Thick oak top: bright worn edge, two panel seams, dark underside.
	rl.DrawRectangle(ox + 1, oy + 4, 18, 3, wood)
	rl.DrawRectangle(ox + 2, oy + 4, 16, 1, wood_hi)
	rl.DrawRectangle(ox + 1, oy + 6, 18, 1, wood_d)
	rl.DrawRectangle(ox + 6, oy + 4, 1, 2, wood_d)
	rl.DrawRectangle(ox + 14, oy + 4, 1, 2, wood_d)
	rl.DrawRectangle(ox + 8, oy + 5, 4, 1, wood_hi)

	// Front apron and stout braced legs.
	rl.DrawRectangle(ox + 3, oy + 7, 14, 3, wood_d)
	rl.DrawRectangle(ox + 4, oy + 7, 12, 1, wood)
	rl.DrawRectangle(ox + 3, oy + 9, 4, 4, wood)
	rl.DrawRectangle(ox + 14, oy + 9, 3, 4, wood)
	rl.DrawRectangle(ox + 4, oy + 9, 1, 3, wood_hi)
	rl.DrawRectangle(ox + 16, oy + 9, 1, 3, wood_d)
	rl.DrawRectangle(ox + 6, oy + 12, 8, 1, wood)
	rl.DrawRectangle(ox + 6, oy + 13, 8, 1, wood_d)

	// Iron corner caps and foot shoes, with chest-style rivet glints.
	rl.DrawRectangle(ox, oy + 3, 3, 4, iron)
	rl.DrawRectangle(ox + 17, oy + 3, 3, 4, iron)
	rl.DrawRectangle(ox + 1, oy + 3, 2, 1, iron_hi)
	rl.DrawRectangle(ox + 17, oy + 3, 2, 1, iron_hi)
	rl.DrawRectangle(ox + 2, oy + 12, 5, 2, iron_d)
	rl.DrawRectangle(ox + 13, oy + 12, 5, 2, iron_d)
	rl.DrawRectangle(ox + 3, oy + 12, 3, 1, iron_hi)
	rl.DrawRectangle(ox + 14, oy + 12, 3, 1, iron_hi)
	rl.DrawRectangle(ox + 1, oy + 5, 1, 1, iron_hi)
	rl.DrawRectangle(ox + 18, oy + 5, 1, 1, iron_hi)
	rl.DrawRectangle(ox + 4, oy + 12, 1, 1, iron_hi)
	rl.DrawRectangle(ox + 15, oy + 12, 1, 1, iron_hi)

	// Compact vise on the left: fixed jaw, sliding jaw, and screw handle.
	rl.DrawRectangle(ox, oy + 1, 6, 3, outline)
	rl.DrawRectangle(ox + 1, oy + 1, 4, 2, iron)
	rl.DrawRectangle(ox + 1, oy + 1, 3, 1, iron_hi)
	rl.DrawRectangle(ox, oy + 2, 2, 5, outline)
	rl.DrawRectangle(ox + 1, oy + 3, 1, 3, iron)
	rl.DrawRectangle(ox, oy + 5, 4, 1, iron_d)
	rl.DrawRectangle(ox, oy + 4, 1, 3, iron_hi)

	// Mallet resting on the slab: oak head, iron pin, tapered warm handle.
	rl.DrawRectangle(ox + 10, oy, 5, 4, outline)
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

// ─── Pixel Art: Smelter ──────────────────────────────────────────────────────

draw_smelters :: proc(gs: ^Game_State) {
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		if get_tile(&gs.world, x, y) == .Smelter {
			bx, by := i32(x * CELL_SIZE), i32(y * CELL_SIZE)
			if gs.pixel_art.sprites[.Smelter].has_data {
				draw_pixel_grid_sprite(gs, .Smelter, bx, by)
			} else {
				draw_pixel_smelter_shell(bx, by)
			}
			draw_pixel_smelter_dynamic(gs, bx, by, x, y)
		}
	}
}

// Static furnace body — chimney, firebrick courses, firebox frame, fuel rack
// and casting tray frames, progress-bar frame, rivets. Grid-editable (see
// pixel_sprite_table[.Smelter]); this proc is only the procedural fallback
// when no edit has been saved. Coordinates and palette indices are listed in
// smelter_shell_rects, which seed_pixel_grid also reads for the editor preview.
draw_pixel_smelter_shell :: proc(bx, by: i32) {
	info := pixel_sprite_table[.Smelter]
	ox := bx + i32(info.ox_off)
	oy := by + i32(info.oy_off)
	draw_shell_rects(smelter_shell_rects, ox, oy)
}

@(rodata)
smelter_shell_rects := []Shell_Rect {
	{8, 0, 8, 10, 19},
	{7, 7, 10, 4, 19},
	{4, 9, 16, 3, 19},
	{2, 12, 20, 12, 19},
	{3, 24, 5, 2, 19},
	{16, 24, 5, 2, 19},
	{9, 1, 6, 9, 20},
	{8, 0, 8, 2, 23},
	{9, 0, 6, 1, 24},
	{10, 3, 4, 1, 19},
	{5, 10, 14, 3, 21},
	{3, 13, 18, 10, 20},
	{4, 14, 16, 8, 21},
	{5, 10, 12, 1, 22},
	{4, 17, 16, 2, 23},
	{5, 17, 14, 1, 24},
	{4, 22, 5, 1, 22},
	{15, 22, 5, 1, 22},
	{4, 14, 1, 3, 22},
	{19, 19, 1, 3, 20},
	{7, 12, 10, 3, 19},
	{6, 14, 12, 9, 19},
	{8, 13, 8, 2, 25},
	{7, 15, 10, 7, 25},
	{0, 16, 3, 8, 19},
	{1, 17, 2, 6, 23},
	{21, 18, 5, 2, 19},
	{21, 19, 5, 1, 24},
	{4, 25, 16, 2, 19},
	{4, 17, 1, 1, 24},
	{19, 17, 1, 1, 24},
	{2, 17, 1, 1, 24},
	{21, 17, 1, 1, 24},
}

// Everything driven by live Sim_Tile_Data: furnace breath, smoke, fire/cold
// coals, fuel pile, cast output, ore glints, progress fill. Always drawn on
// top of the shell (grid-edited or procedural) so this feedback never goes
// away, even once the shell has been customized.
draw_pixel_smelter_dynamic :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	cx, bottom := bx + CELL_SIZE / 2, by + CELL_SIZE
	sd := &gs.world.sim_data[grid_idx(x, y)]
	p := clamp(sd.growth_timer / SMELT_TIME, 0, 1)
	tick := int(gs.frame / 5) + x * 3 + y * 7
	working := p > 0
	ember := rl.Color{225, 75, 22, 255}
	flame := rl.Color{255, 145, 35, 255}
	hot := rl.Color{255, 220, 85, 255}

	// Restrained furnace breath, still rectangular and pixel-snapped.
	if working {
		rl.BeginBlendMode(.ADDITIVE)
		rl.DrawRectangle(cx - 8, bottom - 14, 16, 13, rl.Color{255, 75, 20, 25})
		rl.DrawRectangle(cx - 5, bottom - 11, 10, 9, rl.Color{255, 145, 35, 28})
		rl.EndBlendMode()
	}

	if working {
		for i in 0 ..< 3 {
			ii := i32(i)
			sx := cx - 3 + (ii * 4 + i32(tick)) % 7
			sy := bottom - 27 - ii * 4 - i32(tick % 3)
			smoke := rl.Color{75, 70, 76, u8(150 - i * 35)}
			rl.DrawRectangle(sx, sy, 2, 2, smoke)
		}
	}

	// Discrete flame frames over the shell's cold firebox opening.
	if working || sd.fuel_count > 0 {
		rl.DrawRectangle(cx - 4, bottom - 5, 8, 3, ember)
		rl.DrawRectangle(cx - 3, bottom - 7, 3, 4, flame)
		rl.DrawRectangle(cx + 1, bottom - 8 + i32(tick % 2), 3, 5 - i32(tick % 2), flame)
		rl.DrawRectangle(cx - 1, bottom - 6, 2, 4, hot)
		rl.DrawRectangle(cx + 2, bottom - 5, 1, 2, hot)
	} else {
		rl.DrawRectangle(cx - 4, bottom - 4, 3, 2, rl.Color{61, 34, 29, 255})
		rl.DrawRectangle(cx + 1, bottom - 4, 3, 2, rl.Color{61, 34, 29, 255})
	}

	// Fuel pile in the rack.
	if sd.fuel_count > 0 {
		rl.DrawRectangle(cx - 13, bottom - 6, 4, 2, rl.Color{112, 66, 36, 255})
		rl.DrawRectangle(cx - 12, bottom - 6, 3, 1, rl.Color{174, 108, 61, 255})
	}
	// Cast output resting in the tray.
	if sd.store_count > 0 {
		bar_col := item_table[sd.store_item].color
		rl.DrawRectangle(cx + 10, bottom - 8, 4, 3, rl.Color{22, 20, 22, 255})
		rl.DrawRectangle(cx + 10, bottom - 7, 3, 1, bar_col)
		rl.DrawRectangle(cx + 11, bottom - 6, 3, 1, rl.Color{225, 220, 205, 255})
	}

	// Ore glints in the throat; the integrated ember bar fills as the cast runs.
	if sd.in_count > 0 && sd.in_item != .None {
		ore_col := item_table[sd.in_item].color
		rl.DrawRectangle(cx - 2, bottom - 13, 2, 2, ore_col)
		rl.DrawRectangle(cx + 2, bottom - 12, 1, 1, ore_col)
	}
	if p > 0 do rl.DrawRectangle(cx - 7, bottom + 1, i32(14 * p), 1, hot)
}

// ─── Pixel Art: Sky Altar ────────────────────────────────────────────────────
//
// A one-cell capstone rendered as a broad 26x27 shrine: stepped cloud-stone,
// forked rune uprights, metal bindings and a hovering faceted aether crystal.
// Animation advances in whole-pixel beats so it shares the chest/bench cadence.

draw_sky_altars :: proc(gs: ^Game_State) {
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		if get_tile(&gs.world, x, y) == .Sky_Altar {
			if sky_altar_has_stone_wood_foundation(&gs.world, x, y) {
				draw_pixel_stone_wood_altar_base(gs, i32(x * CELL_SIZE), i32(y * CELL_SIZE), x, y)
			}
			draw_pixel_sky_altar(gs, i32(x * CELL_SIZE), i32(y * CELL_SIZE), x, y)
			draw_altar_eternal_swirl(gs, x, y)
		}
	}
}

sky_altar_has_stone_wood_foundation :: proc(w: ^World_Grid, x, y: int) -> bool {
	for dx in -2 ..= 2 do if get_tile(w, x + dx, y + 2) != .Stone do return false
	for dx in -1 ..= 1 do if get_tile(w, x + dx, y + 1) != .Wood do return false
	return true
}

// Tier-A's five Stone and three Wood cells become one continuous shrine facade
// once the capstone is present. Terrain and collision remain eight real blocks;
// this foreground skin only joins their seams, braces and central rune spine.
draw_pixel_stone_wood_altar_base :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	cx := bx + CELL_SIZE / 2
	wood_y := by + CELL_SIZE
	stone_y := by + CELL_SIZE * 2
	tick := int(gs.frame / 8) + x + y
	outline := rl.Color{22, 24, 32, 255}
	stone_d := rl.Color{67, 76, 98, 255}
	stone := rl.Color{112, 129, 158, 255}
	stone_hi := rl.Color{174, 193, 217, 255}
	wood_d := rl.Color{67, 38, 28, 255}
	wood := rl.Color{121, 70, 42, 255}
	wood_hi := rl.Color{174, 108, 61, 255}
	iron := rl.Color{57, 63, 76, 255}
	iron_hi := rl.Color{112, 124, 143, 255}
	rune := rl.Color{90, 215, 255, 255}
	if tick % 4 < 2 do rune = rl.Color{135, 240, 255, 255}

	// One broad foundation silhouette with small end feet.
	rl.DrawRectangle(cx - 26, stone_y - 1, 52, 11, outline)
	rl.DrawRectangle(
		cx - 24,
		stone_y + 9,
		7,
		2,
		outline,
	); rl.DrawRectangle(cx + 17, stone_y + 9, 7, 2, outline)
	rl.DrawRectangle(cx - 16, wood_y - 1, 32, 11, outline)

	// Five dressed stones retain individual joints but share a continuous cap.
	rl.DrawRectangle(cx - 25, stone_y, 50, 9, stone_d)
	rl.DrawRectangle(cx - 24, stone_y, 48, 2, stone_hi)
	for i in 0 ..< 5 {
		sx := cx - 25 + i32(i) * 10
		rl.DrawRectangle(sx + 1, stone_y + 2, 8, 6, stone)
		rl.DrawRectangle(sx + 1, stone_y + 2, 7, 1, stone_hi)
		if i < 4 do rl.DrawRectangle(sx + 9, stone_y + 1, 1, 8, outline)
		// Alternating one-pixel chips stop the course looking machine-perfect.
		if (i + tick) % 2 == 0 do rl.DrawRectangle(sx + 2, stone_y + 6, 2, 1, stone_d)
	}
	rl.DrawRectangle(
		cx - 23,
		stone_y + 9,
		6,
		1,
		stone,
	); rl.DrawRectangle(cx + 17, stone_y + 9, 6, 1, stone)

	// Three oak panels form a single bound beam. Stepped braces visually carry
	// the narrower altar down into the wide stone course.
	rl.DrawRectangle(cx - 15, wood_y, 30, 9, wood_d)
	rl.DrawRectangle(cx - 14, wood_y + 1, 28, 7, wood)
	rl.DrawRectangle(cx - 14, wood_y + 1, 28, 1, wood_hi)
	for seam in ([2]i32{cx - 5, cx + 5}) do rl.DrawRectangle(seam, wood_y + 1, 1, 7, outline)
	rl.DrawRectangle(cx - 14, wood_y + 7, 28, 1, wood_d)
	for step in 0 ..< 4 {
		s := i32(step)
		rl.DrawRectangle(cx - 17 - s * 2, wood_y + 6 + s, 4, 2, outline)
		rl.DrawRectangle(cx + 13 + s * 2, wood_y + 6 + s, 4, 2, outline)
		rl.DrawRectangle(cx - 16 - s * 2, wood_y + 6 + s, 3, 1, wood_hi)
		rl.DrawRectangle(cx + 13 + s * 2, wood_y + 6 + s, 3, 1, wood_hi)
	}

	// Iron collars and a luminous spine connect directly to the rune plate on
	// the capstone above, making all three material rows read as one machine.
	rl.DrawRectangle(cx - 16, wood_y, 3, 9, iron); rl.DrawRectangle(cx + 13, wood_y, 3, 9, iron)
	rl.DrawRectangle(
		cx - 15,
		wood_y + 1,
		1,
		6,
		iron_hi,
	); rl.DrawRectangle(cx + 13, wood_y + 1, 1, 6, iron_hi)
	rl.DrawRectangle(cx - 3, wood_y - 1, 6, 11, outline)
	rl.DrawRectangle(cx - 2, wood_y, 4, 9, iron)
	rl.DrawRectangle(cx - 1, wood_y, 2, 9, rune)
	rl.DrawRectangle(cx - 4, stone_y + 1, 8, 7, outline)
	rl.DrawRectangle(cx - 3, stone_y + 2, 6, 5, iron)
	draw_pixel_rune_mark(cx - 2, stone_y + 2, rune, tick / 3)

	// Small matching rune studs across the outer foundation echo the altar top.
	for rx in ([2]i32{cx - 19, cx + 16}) {
		rl.DrawRectangle(rx, stone_y + 3, 4, 4, stone_d)
		draw_pixel_rune_mark(rx, stone_y + 3, rune, tick / 5 + int(rx & 1))
	}
}

// Float-position twin of draw_pixel_rune_mark: same glyphs, sub-pixel world
// coordinates so a slow-moving mark glides instead of stepping.
draw_pixel_rune_mark_v :: proc(pos: [2]f32, col: rl.Color, variant: int) {
	r :: proc(pos: [2]f32, dx, dy, w, h: f32, col: rl.Color) {
		rl.DrawRectangleV({pos.x + dx, pos.y + dy}, {w, h}, col)
	}
	switch variant % 4 {
	case 0:
		// angular Ansuz-like spark
		r(pos, 1, 0, 1, 5, col); r(pos, 2, 1, 2, 1, col); r(pos, 2, 3, 2, 1, col)
	case 1:
		// diamond
		r(
			pos,
			1,
			0,
			2,
			1,
			col,
		); r(pos, 0, 1, 1, 2, col); r(pos, 3, 1, 1, 2, col); r(pos, 1, 3, 2, 1, col)
	case 2:
		// fork
		r(pos, 1, 1, 1, 4, col); r(pos, 0, 0, 1, 2, col); r(pos, 2, 0, 1, 2, col)
	case 3:
		// stepped lightning
		r(pos, 2, 0, 2, 1, col); r(pos, 1, 1, 2, 2, col); r(pos, 0, 3, 2, 1, col)
	case:
	}
}

draw_pixel_rune_mark :: proc(x, y: i32, col: rl.Color, variant: int) {
	switch variant % 4 {
	case 0:
		// angular Ansuz-like spark
		rl.DrawRectangle(
			x + 1,
			y,
			1,
			5,
			col,
		); rl.DrawRectangle(x + 2, y + 1, 2, 1, col); rl.DrawRectangle(x + 2, y + 3, 2, 1, col)
	case 1:
		// diamond
		rl.DrawRectangle(x + 1, y, 2, 1, col); rl.DrawRectangle(x, y + 1, 1, 2, col)
		rl.DrawRectangle(x + 3, y + 1, 1, 2, col); rl.DrawRectangle(x + 1, y + 3, 2, 1, col)
	case 2:
		// fork
		rl.DrawRectangle(
			x + 1,
			y + 1,
			1,
			4,
			col,
		); rl.DrawRectangle(x, y, 1, 2, col); rl.DrawRectangle(x + 2, y, 1, 2, col)
	case 3:
		// stepped lightning
		rl.DrawRectangle(
			x + 2,
			y,
			2,
			1,
			col,
		); rl.DrawRectangle(x + 1, y + 1, 2, 2, col); rl.DrawRectangle(x, y + 3, 2, 1, col)
	case:
	}
}

draw_pixel_sky_altar :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	cx, bottom := bx + CELL_SIZE / 2, by + CELL_SIZE
	tick := int(gs.frame / 7) + x * 3 + y * 5
	awake :=
		gs.level_index == LEVEL_SURFACE && gs.progression.sky_altar_pos == [2]i32{i32(x), i32(y)}
	outline := rl.Color{22, 24, 35, 255}
	stone_d := rl.Color{72, 82, 112, 255}
	stone := rl.Color{126, 145, 181, 255}
	stone_hi := rl.Color{194, 211, 234, 255}
	metal := rl.Color{64, 72, 92, 255}
	rune := rl.Color{82, 205, 255, 255}
	hot := rl.Color{225, 250, 255, 255}
	if awake && tick % 4 < 2 do rune = rl.Color{110, 235, 255, 255}

	// Rectangular, restrained aura behind the physical shrine.
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRectangle(cx - 9, bottom - 24, 18, 20, rl.Color{65, 175, 255, u8(awake ? 38 : 18)})
	rl.DrawRectangle(cx - 6, bottom - 22, 12, 17, rl.Color{120, 220, 255, u8(awake ? 42 : 20)})
	rl.EndBlendMode()

	// Joined black silhouette: three-step plinth, feet and forked uprights.
	rl.DrawRectangle(cx - 13, bottom - 4, 26, 4, outline)
	rl.DrawRectangle(cx - 10, bottom - 8, 20, 5, outline)
	rl.DrawRectangle(cx - 7, bottom - 12, 14, 5, outline)
	rl.DrawRectangle(
		cx - 11,
		bottom - 18,
		5,
		10,
		outline,
	); rl.DrawRectangle(cx + 6, bottom - 18, 5, 10, outline)
	rl.DrawRectangle(
		cx - 13,
		bottom - 22,
		5,
		6,
		outline,
	); rl.DrawRectangle(cx + 8, bottom - 22, 5, 6, outline)

	// Pale block courses; dark seams keep each chunky stone readable.
	rl.DrawRectangle(cx - 12, bottom - 3, 24, 2, stone_d)
	rl.DrawRectangle(cx - 9, bottom - 7, 18, 3, stone)
	rl.DrawRectangle(cx - 8, bottom - 7, 16, 1, stone_hi)
	rl.DrawRectangle(cx - 6, bottom - 11, 12, 3, stone_d)
	rl.DrawRectangle(cx - 5, bottom - 10, 10, 1, stone)
	rl.DrawRectangle(
		cx - 11,
		bottom - 2,
		7,
		1,
		stone,
	); rl.DrawRectangle(cx - 2, bottom - 2, 5, 1, stone)
	rl.DrawRectangle(cx + 5, bottom - 2, 7, 1, stone)

	// Forks point toward the portal; iron collars tie them to the plinth.
	rl.DrawRectangle(cx - 10, bottom - 17, 3, 9, stone)
	rl.DrawRectangle(cx - 9, bottom - 17, 2, 8, stone_hi)
	rl.DrawRectangle(
		cx - 12,
		bottom - 21,
		3,
		5,
		stone_d,
	); rl.DrawRectangle(cx - 11, bottom - 21, 2, 4, stone_hi)
	rl.DrawRectangle(cx + 7, bottom - 17, 3, 9, stone)
	rl.DrawRectangle(cx + 7, bottom - 17, 1, 8, stone_hi)
	rl.DrawRectangle(
		cx + 9,
		bottom - 21,
		3,
		5,
		stone_d,
	); rl.DrawRectangle(cx + 9, bottom - 21, 2, 4, stone_hi)
	rl.DrawRectangle(
		cx - 10,
		bottom - 10,
		3,
		2,
		metal,
	); rl.DrawRectangle(cx + 7, bottom - 10, 3, 2, metal)

	// Rune plates echo the chest lock: magic is concentrated, not a full wash.
	rl.DrawRectangle(cx - 5, bottom - 8, 10, 5, outline)
	rl.DrawRectangle(cx - 4, bottom - 7, 8, 3, metal)
	draw_pixel_rune_mark(cx - 2, bottom - 7, rune, tick / 3)
	rl.DrawRectangle(
		cx - 9,
		bottom - 15,
		1,
		2,
		rune,
	); rl.DrawRectangle(cx + 8, bottom - 15, 1, 2, rune)

	// Hovering five-row crystal. Its one-pixel bob and travelling white facet
	// provide the motion while preserving a hard sprite silhouette.
	bob := i32(1) if tick % 6 >= 3 else i32(0)
	cy := bottom - 27 - bob
	rl.DrawRectangle(cx - 1, cy, 2, 1, outline)
	rl.DrawRectangle(cx - 3, cy + 1, 6, 2, outline)
	rl.DrawRectangle(cx - 4, cy + 3, 8, 4, outline)
	rl.DrawRectangle(cx - 2, cy + 7, 4, 2, outline)
	rl.DrawRectangle(cx - 1, cy + 9, 2, 1, outline)
	rl.DrawRectangle(cx - 1, cy + 1, 2, 1, hot)
	rl.DrawRectangle(cx - 2, cy + 2, 4, 2, stone_hi)
	rl.DrawRectangle(cx - 3, cy + 4, 6, 2, rune)
	rl.DrawRectangle(cx - 1, cy + 3, 2, 5, hot)
	rl.DrawRectangle(cx + 2, cy + 4, 1, 3, stone_d)
	if tick % 4 == 0 do rl.DrawRectangle(cx - 5, cy + 2, 1, 1, hot)
	if tick % 4 == 2 do rl.DrawRectangle(cx + 5, cy + 6, 1, 1, hot)
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
		flick := (math.sin(gs.elapsed_time * 13 + f32(x)) + 1) * 0.5
		rl.DrawRectangle(
			px + 2,
			py + 3,
			6,
			4,
			rl.Color{255, 150, 40, u8(80 + p * 100 + flick * 60)},
		)
		rl.DrawRectangle(
			px,
			py - 2,
			i32(f32(CELL_SIZE) * clamp(p, 0, 1)),
			2,
			rl.Color{255, 200, 80, 230},
		)
	case .Boiler:
		sd := gs.world.sim_data[grid_idx(x, y)]
		// The firebox glows while fuel is burning; the bar is the next puff.
		if sd.spread_timer > 0 {
			flick := (math.sin(gs.elapsed_time * 11 + f32(x)) + 1) * 0.5
			rl.DrawRectangle(px + 2, py + 5, 6, 3, rl.Color{255, 150, 40, u8(110 + flick * 80)})
		}
		if r, ok := boiler_rule_for(t); ok && sd.growth_timer > 0 {
			p := clamp(sd.growth_timer / r.period, 0, 1)
			rl.DrawRectangle(px, py - 2, i32(f32(CELL_SIZE) * p), 2, rl.Color{200, 225, 240, 230})
		}
	case .Steam_Engine:
		// The spinning flywheel is the only tell the player needs: it turns
		// while the engine's own cell is powered and stands still the moment
		// the field dies.  Derived from powered() + elapsed_time — read-only.
		wx, wy := px + CELL_SIZE / 2, py + CELL_SIZE / 2
		brass := rl.Color{240, 212, 120, 255}
		rl.DrawRectangle(px + 2, py + 2, 6, 6, rl.Color{140, 110, 40, 255})
		phase := 0
		if powered(gs, x, y) do phase = int(gs.elapsed_time * 10) % 4
		switch phase {
		case 0:
			rl.DrawRectangle(wx - 3, wy - 1, 6, 2, brass)
		case 1:
			rl.DrawRectangle(wx - 2, wy - 2, 2, 2, brass)
			rl.DrawRectangle(wx, wy, 2, 2, brass)
		case 2:
			rl.DrawRectangle(wx - 1, wy - 3, 2, 6, brass)
		case 3:
			rl.DrawRectangle(wx, wy - 2, 2, 2, brass)
			rl.DrawRectangle(wx - 2, wy, 2, 2, brass)
		}
	case .Magic_Kettle:
		sd := gs.world.sim_data[grid_idx(x, y)]
		// The firebox glows in the loaded gem's own color while it burns —
		// the same "what am I feeding it" tell Boiler's orange flicker gives,
		// but gem-tinted so a glance says which gem is in the hopper.
		glow := gem_tint_color(gem_tint_index(sd.in_item))
		if sd.spread_timer > 0 {
			flick := (math.sin(gs.elapsed_time * 11 + f32(x)) + 1) * 0.5
			glow.a = u8(110 + flick * 80)
			rl.DrawRectangle(px + 2, py + 5, 6, 3, glow)
		}
		if r, ok := boiler_rule_for(t); ok && sd.growth_timer > 0 {
			p := clamp(sd.growth_timer / r.period, 0, 1)
			bar := gem_tint_color(gem_tint_index(sd.in_item))
			rl.DrawRectangle(px, py - 2, i32(f32(CELL_SIZE) * p), 2, bar)
		}
	case .Mana_Wheel:
		// Same tell as Steam_Engine's flywheel — turns while powered, stands
		// still the moment the field dies — in the track's own violet-brass.
		wx, wy := px + CELL_SIZE / 2, py + CELL_SIZE / 2
		brass := rl.Color{225, 190, 255, 255}
		rl.DrawRectangle(px + 2, py + 2, 6, 6, rl.Color{95, 70, 120, 255})
		phase := 0
		if powered(gs, x, y) do phase = int(gs.elapsed_time * 10) % 4
		switch phase {
		case 0:
			rl.DrawRectangle(wx - 3, wy - 1, 6, 2, brass)
		case 1:
			rl.DrawRectangle(wx - 2, wy - 2, 2, 2, brass)
			rl.DrawRectangle(wx, wy, 2, 2, brass)
		case 2:
			rl.DrawRectangle(wx - 1, wy - 3, 2, 6, brass)
		case 3:
			rl.DrawRectangle(wx, wy - 2, 2, 2, brass)
			rl.DrawRectangle(wx - 2, wy, 2, 2, brass)
		}
	case .Gem_Replicator:
		sd := gs.world.sim_data[grid_idx(x, y)]
		period, seeded := gem_replicate_time_for(sd.in_item)
		if !seeded || sd.growth_timer <= 0 do return
		// The growing copy climbs out of the plinth in the SEED's own color
		// (read from item_table), so the machine visibly reads as "growing an
		// emerald" — the sapling stalk's pacing, in crystal.
		p := clamp(sd.growth_timer / period, 0, 1)
		c := item_table[sd.in_item].color
		h := i32(2 + p * 6)
		gx := px + CELL_SIZE / 2 - 1
		rl.DrawRectangle(gx, py - h, 2, h, c)
		// Facets widen as the shard lengthens.
		if h > 4 {
			rl.DrawRectangle(gx - 1, py - h + 2, 1, h - 3, c)
			rl.DrawRectangle(gx + 2, py - h + 3, 1, h - 4, c)
		}
		// A glinting tip.
		rl.DrawRectangle(gx, py - h, 2, 1, rl.Color{255, 255, 255, 200})
	case .Tree_Grower:
		p := gs.world.sim_data[grid_idx(x, y)].growth_timer / TREE_GROW_TIME
		if p <= 0 do return
		cp := clamp(p, 0, 1)
		// The sapling stem climbs the full trunk height (TREE_MAX_H tiles) as it
		// grows, so it reads as a stalk rising to full length before the grown
		// tree pops in — not a stub that jumps straight to a tree.  The column
		// above is guaranteed clear sky (tick_grower checks to TREE_MAX_H).
		full := f32(TREE_MAX_H * CELL_SIZE)
		h := i32(2 + cp * (full - 2))
		stem_x := px + CELL_SIZE / 2 - 1
		stalk := rl.Color{70, 190, 60, 255}
		leaf := rl.Color{110, 230, 110, 255}
		rl.DrawRectangle(stem_x, py - h, 2, h, stalk)
		// A pair of little leaves at the climbing tip.
		rl.DrawRectangle(stem_x - 2, py - h, 2, 2, leaf)
		rl.DrawRectangle(stem_x + 2, py - h + 1, 2, 2, leaf)
		// Side sprigs unfurl up the stem as it lengthens.
		if h > CELL_SIZE {
			rl.DrawRectangle(stem_x - 2, py - h / 2, 2, 2, leaf)
			rl.DrawRectangle(stem_x + 2, py - h / 3, 2, 2, leaf)
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
	base := rl.Color{139, 90, 43, 255}
	dark := rl.Color{80, 50, 15, 255}
	light := rl.Color{180, 130, 70, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, base)
	rl.DrawRectangle(bx + 0, by, 1, CELL_SIZE, light)
	rl.DrawRectangle(bx + 1, by, 1, CELL_SIZE, dark)
	rl.DrawRectangle(bx + 5, by, 1, CELL_SIZE, light)
	rl.DrawRectangle(bx + 6, by, 1, CELL_SIZE, dark)
}

// ─── Pixel Art: Dirt ──────────────────────────────────────────────────────────
//
//  Turned earth: warm brown fill scattered with darker pebbles and lighter
//  grit so a placed clod reads as soil, not a flat swatch.  Fixed pattern
//  (like leaves) — it tiles cleanly across a stacked dirt wall.

draw_pixel_dirt :: proc(bx, by: i32) {
	base := rl.Color{120, 84, 50, 255}
	dark := rl.Color{84, 58, 34, 255}
	light := rl.Color{150, 112, 74, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, base)
	// pebbles
	rl.DrawRectangle(bx + 1, by + 2, 2, 2, dark)
	rl.DrawRectangle(bx + 6, by + 1, 2, 2, dark)
	rl.DrawRectangle(bx + 4, by + 5, 2, 2, dark)
	rl.DrawRectangle(bx + 7, by + 6, 2, 2, dark)
	// grit
	rl.DrawRectangle(bx + 3, by + 0, 1, 1, light)
	rl.DrawRectangle(bx + 8, by + 3, 1, 1, light)
	rl.DrawRectangle(bx + 0, by + 6, 1, 1, light)
	rl.DrawRectangle(bx + 2, by + 7, 1, 1, light)
	rl.DrawRectangle(bx + 5, by + 8, 1, 1, light)
}

// Damp terracotta seam: smooth clay bands with cool water-darkened pockets,
// visually distinct from the granular brown Dirt building block.
draw_pixel_clay :: proc(bx, by: i32, tx, ty: int) {
	base := rl.Color{166, 105, 72, 255}
	dark := rl.Color{105, 62, 48, 255}
	light := rl.Color{205, 145, 105, 255}
	wet := rl.Color{92, 112, 126, 220}
	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, base)
	h := whash(u32(tx) * 2654435761 ~ u32(ty) * 668265263)
	rl.DrawRectangle(bx, by + 2, 10, 1, light)
	rl.DrawRectangle(bx, by + 7, 10, 1, dark)
	rl.DrawRectangle(bx + i32(h % 6), by + 4, 4, 1, dark)
	rl.DrawRectangle(bx + i32((h >> 5) % 7), by + 8, 3, 1, light)
	rl.DrawRectangle(bx + i32((h >> 9) % 8), by + 1, 2, 1, wet)
}

// ─── Pixel Art: Loam Stone ────────────────────────────────────────────────────
//
//  The loose earthen stratum the entrance shaft cuts through: cap-band stone
//  shot through with packed soil — it's why mining here also yields a dirt clod
//  (in_shaft_apron), so it should read as soil-veined rock, not plain stone.
//  Deterministic per cell via a position hash: varied down the band, never
//  shimmering.  Drawn UNDER the brown scuff apron (draw_shaft_mouth).

draw_pixel_loam_stone :: proc(bx, by: i32, x, y: int) {
	stone := rl.Color{112, 110, 116, 255}
	stone_d := rl.Color{82, 80, 88, 255}
	stone_l := rl.Color{150, 148, 156, 255}
	soil := rl.Color{120, 84, 50, 255}
	soil_d := rl.Color{84, 58, 34, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, stone)

	h := whash(u32(x) * 374761393) ~ whash(u32(y) * 668265263)
	// A soil seam packed into a crack, its slant riding the hash.
	seam := i32(h % 4)
	rl.DrawRectangle(bx + seam, by + 2, 3, 2, soil)
	rl.DrawRectangle(bx + seam + 2, by + 4, 3, 2, soil_d)
	rl.DrawRectangle(bx + seam + 3, by + 6, 2, 2, soil)
	// Embedded pebbles and a lit chip, scattered off the hash.
	rl.DrawRectangle(bx + i32((h >> 3) % 7), by + i32((h >> 6) % 3) + 1, 2, 2, stone_d)
	rl.DrawRectangle(bx + i32((h >> 9) % 8), by + 7, 2, 1, stone_l)
	rl.DrawRectangle(bx + i32((h >> 12) % 9), by + i32((h >> 14) % 4) + 5, 1, 1, soil_d)
}

// ─── Pixel Art: Flower Bed ────────────────────────────────────────────────────
//
//  A plank-framed soil bed whose five stalks grow over FLOWER_BED_GROW_TIME:
//  sprouts → stems → buds → swaying blooms.  Growth (sim_data.growth_timer)
//  drives the stalk height, and the ripe blooms spill up into the cell above
//  (a surface crop with open sky overhead), so it reads taller than one cell.

draw_pixel_flower_bed :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	soil := rl.Color{92, 62, 38, 255}
	soil_d := rl.Color{68, 46, 28, 255}
	frame := rl.Color{140, 100, 55, 255}
	stem := rl.Color{46, 140, 46, 255}
	stem_d := rl.Color{30, 100, 34, 255}
	bud := rl.Color{120, 170, 70, 255}

	p := clamp(gs.world.sim_data[grid_idx(x, y)].growth_timer / FLOWER_BED_GROW_TIME, 0, 1)
	ripe := p >= 1.0

	soil_top := by + 6
	rl.DrawRectangle(bx, soil_top, CELL_SIZE, CELL_SIZE - 6, soil) // tilled soil
	rl.DrawRectangle(bx, by + 8, CELL_SIZE, 2, soil_d) // dark furrow
	rl.DrawRectangle(bx, soil_top, CELL_SIZE, 1, frame) // plank lip
	rl.DrawRectangle(bx, soil_top, 1, CELL_SIZE - 6, frame) // left rail
	rl.DrawRectangle(bx + CELL_SIZE - 1, soil_top, 1, CELL_SIZE - 6, frame) // right rail

	petals := [5]rl.Color {
		{255, 220, 50, 255},
		{255, 150, 60, 255},
		{255, 90, 120, 255},
		{200, 120, 255, 255},
		{255, 220, 50, 255},
	}
	for sx, i in ([5]i32{1, 3, 5, 7, 9}) {
		h := i32(2 + p * 13) // 2px sprout → 15px stalk (spills a cell up)
		sway := ripe ? i32(math.sin(gs.elapsed_time * 2 + f32(i)) * 1.2) : 0
		top := soil_top - h
		hx := bx + sx + sway
		rl.DrawRectangle(hx, top, 1, h, i % 2 == 0 ? stem : stem_d)
		if ripe {
			rl.DrawRectangle(hx - 1, top - 1, 3, 1, petals[i]) // side petals
			rl.DrawRectangle(hx, top - 2, 1, 3, petals[i]) // top/bottom
			rl.DrawRectangle(hx, top - 1, 1, 1, rl.Color{255, 240, 180, 255}) // core
		} else if p > 0.55 {
			rl.DrawRectangle(hx, top - 1, 1, 1, bud) // budding
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
	wood := rl.Color{150, 100, 55, 255}
	dark := rl.Color{92, 60, 32, 255}
	light := rl.Color{182, 130, 78, 255}
	iron := rl.Color{60, 60, 68, 255}

	bottom := is_door(&gs.world, x, y - 1) // a door above → this is the lower half

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, wood)
	rl.DrawRectangle(bx, by, 1, CELL_SIZE, dark)
	rl.DrawRectangle(bx + CELL_SIZE - 1, by, 1, CELL_SIZE, dark)
	rl.DrawRectangle(bx + 1, by, CELL_SIZE - 2, 1, light)
	rl.DrawRectangle(bx + 3, by, 1, CELL_SIZE, dark) // plank seam
	if bottom {
		rl.DrawRectangle(bx + CELL_SIZE - 4, by + CELL_SIZE / 2 - 1, 2, 2, iron) // knob
	}
}

// ─── Pixel Art: Miner Body ────────────────────────────────────────────────────
//
//  The snake's trail: segmented steel bar with rivets, alternating joint
//  lines so a run of segments reads as linked metal.  The head segment
//  (gs.dimension.miner.head) pulses teal — the living end of the machine.

draw_pixel_miner_body :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	dark := rl.Color{52, 56, 66, 255}
	steel := rl.Color{118, 126, 140, 255}
	shine := rl.Color{176, 184, 198, 255}
	rivet := rl.Color{84, 90, 102, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, dark)
	rl.DrawRectangle(bx + 1, by + 2, 8, 6, steel)
	rl.DrawRectangle(bx + 1, by + 2, 8, 1, shine)
	// joint line alternates with the tile parity — segments read as links
	if (x + y) % 2 == 0 {
		rl.DrawRectangle(bx + 4, by + 1, 2, 8, rivet)
	} else {
		rl.DrawRectangle(bx + 2, by + 4, 6, 2, rivet)
	}
	rl.DrawRectangle(bx + 2, by + 3, 1, 1, shine)
	rl.DrawRectangle(bx + 7, by + 6, 1, 1, rivet)

	// The head glows — a breathing teal pulse on the working end.
	m := &gs.dimension.miner
	if m.active && m.head == {i32(x), i32(y)} {
		pulse := (math.sin(gs.elapsed_time * 5.0) + 1) * 0.5
		g := rl.Color{80, 255, 220, u8(90 + pulse * 130)}
		rl.DrawRectangle(bx + 2, by + 3, 6, 4, g)
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
	shade := rl.Color{84, 84, 92, 255}
	gem := terrain_table[t].color
	gdark := rl.Color{gem.r / 2, gem.g / 2, gem.b / 2, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, stone)
	// rock grain in the corners so it reads as wall, not a floating chip
	rl.DrawRectangle(bx + 1, by + 7, 2, 2, shade)
	rl.DrawRectangle(bx + 7, by + 1, 2, 2, shade)
	rl.DrawRectangle(bx + 8, by + 8, 1, 1, shade)
	// the embedded crystal cluster: a rough diamond with a dark facet
	rl.DrawRectangle(bx + 4, by + 2, 2, 6, gem)
	rl.DrawRectangle(bx + 2, by + 4, 6, 2, gem)
	rl.DrawRectangle(bx + 3, by + 3, 4, 4, gem)
	rl.DrawRectangle(bx + 5, by + 5, 2, 2, gdark)
	rl.DrawRectangle(bx + 3, by + 6, 1, 1, gdark)
	// sparkle
	rl.DrawRectangle(bx + 4, by + 3, 1, 1, rl.WHITE)
}

// ─── Pixel Art: Leaves ────────────────────────────────────────────────────────
//
//  mid-green base, scattered 2×2 light highlights and dark shadow spots
//
//  light at: (2,1) (6,2) (1,5) (6,6) (3,7)
//  dark  at: (7,1) (0,3) (4,4) (5,8)

draw_pixel_leaves :: proc(bx, by: i32) {
	mid := rl.Color{30, 160, 30, 255}
	light := rl.Color{90, 210, 60, 255}
	dark := rl.Color{0, 100, 0, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, mid)

	rl.DrawRectangle(bx + 2, by + 1, 2, 2, light)
	rl.DrawRectangle(bx + 6, by + 2, 2, 2, light)
	rl.DrawRectangle(bx + 1, by + 5, 2, 2, light)
	rl.DrawRectangle(bx + 6, by + 6, 2, 2, light)
	rl.DrawRectangle(bx + 3, by + 7, 2, 2, light)

	rl.DrawRectangle(bx + 7, by + 1, 2, 2, dark)
	rl.DrawRectangle(bx + 0, by + 3, 2, 2, dark)
	rl.DrawRectangle(bx + 4, by + 4, 2, 2, dark)
	rl.DrawRectangle(bx + 5, by + 8, 2, 2, dark)
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
	air := terrain_table[.Air].color
	petal := rl.Color{255, 210, 20, 255}
	center := rl.Color{180, 70, 0, 255}
	stem := rl.Color{40, 130, 40, 255}

	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, air)

	// Top petal strip
	rl.DrawRectangle(bx + 2, by + 0, 6, 2, petal)
	// Left + right petals (rows 2-5)
	rl.DrawRectangle(bx + 0, by + 2, 2, 4, petal)
	rl.DrawRectangle(bx + 8, by + 2, 2, 4, petal)
	// Center body (covers x=2..7, y=2..5)
	rl.DrawRectangle(bx + 2, by + 2, 6, 4, petal)
	// Brown-orange center over petals
	rl.DrawRectangle(bx + 3, by + 2, 4, 4, center)
	// Bottom petal strip
	rl.DrawRectangle(bx + 2, by + 6, 6, 2, petal)
	// Stem
	rl.DrawRectangle(bx + 4, by + 8, 2, 2, stem)
}

// ─── Pixel Art: Green Cave Mushroom + Mossy Stone ─────────────────────────────
//
//  The mushroom sprouts out of the mossy block beneath it: stalk rooted at the
//  cell's bottom edge, neon-green cap wrapped in a breathing glow halo.  Pulse
//  derived from elapsed_time + a per-cell phase hash — read-only, no state.

draw_pixel_mushroom :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, terrain_table[.Void].color)

	neon := rl.Color{57, 235, 40, 255}
	lite := rl.Color{160, 255, 120, 255}
	dark := rl.Color{28, 130, 30, 255}
	stalk := rl.Color{225, 235, 200, 255}

	// Breathing halo behind the cap — the glow you spot from across the cave.
	pulse := (math.sin(gs.elapsed_time * 2.2 + f32(x * 7 + y * 13)) + 1) * 0.5
	halo := neon
	halo.a = u8(30 + pulse * 45)
	rl.DrawRectangle(bx + 1, by + 1, 8, 7, halo)
	halo.a = u8(50 + pulse * 60)
	rl.DrawRectangle(bx + 2, by + 2, 6, 5, halo)

	// Cap: lit crown, neon body, dark underside gills
	rl.DrawRectangle(bx + 3, by + 2, 4, 1, lite)
	rl.DrawRectangle(bx + 2, by + 3, 6, 2, neon)
	rl.DrawRectangle(bx + 2, by + 5, 6, 1, dark)
	// Spots
	rl.DrawRectangle(bx + 4, by + 3, 1, 1, rl.WHITE)
	rl.DrawRectangle(bx + 6, by + 4, 1, 1, rl.WHITE)
	// Stalk, rooted in the mossy block below
	rl.DrawRectangle(bx + 4, by + 6, 2, 4, stalk)
}

draw_pixel_mossy_stone :: proc(gs: ^Game_State, bx, by: i32, x, y: int) {
	moss := rl.Color{74, 150, 66, 255}
	deep := rl.Color{46, 104, 44, 255}
	rl.DrawRectangle(bx, by, CELL_SIZE, CELL_SIZE, terrain_table[.Stone].color)
	h := whash(u32(x) * 2654435761 ~ u32(y) * 668265263)
	// Moss lip across the top, creeping unevenly down the face
	rl.DrawRectangle(bx, by, CELL_SIZE, 2, moss)
	rl.DrawRectangle(bx + i32(h % 7), by + 2, 3, 1, moss)
	rl.DrawRectangle(bx + i32((h >> 5) % 8), by + 2, 2, 2, deep)
	rl.DrawRectangle(bx + i32((h >> 9) % 8), by + 5, 2, 1, moss)
	rl.DrawRectangle(bx + i32((h >> 13) % 7), by + 7, 2, 1, deep)

	// The regrow made visible: while the block's clock runs (tick_mossy_stone,
	// saved sim_data) a mini glowing sprout rises out of the moss into the
	// cell above — terrain paints top-down, so drawing up overdraws cleanly.
	// Blocked or bare cells hold the timer at 0, so this costs nothing there.
	p := clamp(gs.world.sim_data[grid_idx(x, y)].growth_timer / MUSHROOM_GROW_TIME, 0, 1)
	if p <= 0 do return

	neon := rl.Color{57, 235, 40, 255}
	lite := rl.Color{160, 255, 120, 255}
	stalk := rl.Color{225, 235, 200, 255}
	rise := i32(1 + p * 7) // sprout tip climbs 1 → 8 px above the moss
	top := by - rise
	capw := i32(2 + p * 4) // cap widens 2 → 6 px
	capx := bx + (CELL_SIZE - capw) / 2

	pulse := (math.sin(gs.elapsed_time * 2.6 + f32(x * 7 + y * 13)) + 1) * 0.5
	halo := neon
	halo.a = u8((20 + pulse * 30) * (0.4 + 0.6 * p))
	rl.DrawRectangle(capx - 1, top - 1, capw + 2, rise + 2, halo)

	if rise > 2 do rl.DrawRectangle(bx + 4, top + 2, 2, rise - 2, stalk)
	rl.DrawRectangle(capx, top, capw, 2, neon)
	if p > 0.5 do rl.DrawRectangle(capx + 1, top, capw - 2, 1, lite)
}

// Crack marks on the tile the pick is working: one diagonal per chip landed.
// Only drawn while the tile is still in pick range — stale chip state on a
// tile the player walked away from stays invisible.  Reach is measured from
// the BODY (in_pick_reach), which is what the pick itself uses: measuring from
// the center TILE hid the marks on every tile above the head or below the feet.
draw_mining_cracks :: proc(gs: ^Game_State) {
	p := &gs.player
	if p.chip_hits == 0 {return}
	if !in_pick_reach(p, p.chip_tile) {return}

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
	if gs.player.dead ||
	   gs.game_won ||
	   gs.ui.show_menu ||
	   gs.ui.show_title ||
	   gs.ui.show_charselect ||
	   gs.ui.show_settings ||
	   gs.ui.show_book ||
	   gs.ui.show_snapshots ||
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
	outline.a = u8(35 + pulse * 35)
	rl.DrawRectangleLinesEx({bx + 0.5, by + 0.5, CELL_SIZE - 1, CELL_SIZE - 1}, 0.5, outline)

	MOTE_COUNT :: 6
	edge := f32(CELL_SIZE - 1)
	for i in 0 ..< MOTE_COUNT {
		phase := math.mod(gs.elapsed_time * 2.2 + f32(i) * 4.0 / MOTE_COUNT, 4)
		x, y := f32(0), f32(0)
		switch {
		case phase < 1:
			x = phase * edge
		case phase < 2:
			x = edge; y = (phase - 1) * edge
		case phase < 3:
			x = (3 - phase) * edge; y = edge
		case:
			y = (4 - phase) * edge
		}

		twinkle := 0.65 + 0.35 * math.sin(gs.elapsed_time * 8 + f32(i) * 1.7)
		mote := col
		mote.a = u8(145 + twinkle * 90)
		rl.DrawCircleV({bx + 0.5 + x, by + 0.5 + y}, 0.55 + twinkle * 0.35, mote)
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
	pulse := 0.65 + 0.35 * math.sin(gs.elapsed_time * 12)
	edge := rl.Color{255, 125, 35, u8(180 + pulse * 75)}

	rl.DrawRectangleRec({bx, by, CELL_SIZE, CELL_SIZE}, rl.Color{180, 45, 20, 30})
	rl.DrawRectangleLinesEx({bx + 0.5, by + 0.5, CELL_SIZE - 1, CELL_SIZE - 1}, 1, edge)
	rl.DrawRectangle(i32(bx), i32(by) + CELL_SIZE - 2, CELL_SIZE, 2, rl.Color{35, 15, 10, 220})
	rl.DrawRectangle(i32(bx), i32(by) + CELL_SIZE - 2, i32(progress * CELL_SIZE), 2, edge)
}

// ─── Enemies ──────────────────────────────────────────────────────────────────

draw_enemies :: proc(es: ^Enemy_Store, t: f32) {
	for i in 0 ..< MAX_ENEMIES {
		if !es.active[i] {continue}
		draw_enemy(&es.data[i], t)
	}
}

draw_enemy :: proc(e: ^Enemy, t: f32) {
	switch e.kind {
	case .Builder:
		draw_builder(e)
	case .Garm:
		draw_garm(e, t)
	case .Undead:
		draw_draugr(e)
	case .Raider:
		draw_builder(e, true)
	case .Fire_Sprite:
		px := i32(e.pos.x * CELL_SIZE)
		py := i32(e.pos.y * CELL_SIZE)
		rl.DrawRectangle(px, py, i32(BUILDER_W * CELL_SIZE), i32(BUILDER_H * CELL_SIZE), rl.RED)
	}
}

// Sub-cell sprite detail: fine rectangles layered over a body drawn at any
// scale. Coordinates are in frame-pixel units with fractions allowed — a
// 0.25-unit rect is quarter-pixel detail — so one table serves every render
// size. Tables are authored right-facing; facing < 0 mirrors across frame_w.
Sprite_Detail :: struct {
	x, y, w, h: f32,
	color:      rl.Color,
}

// Placement math split from the draw loop so the facing mirror is testable
// without a window.
detail_rect :: proc(origin: [2]f32, ps: f32, frame_w: f32, facing: int, d: Sprite_Detail) -> rl.Rectangle {
	x := d.x
	if facing < 0 {x = frame_w - d.x - d.w}
	return {origin.x + x * ps, origin.y + d.y * ps, d.w * ps, d.h * ps}
}

draw_detail_overlay :: proc(origin: [2]f32, ps: f32, frame_w: f32, facing: int, details: []Sprite_Detail) {
	for d in details {
		rl.DrawRectangleRec(detail_rect(origin, ps, frame_w, facing, d), d.color)
	}
}

// Garm's face on a 16x18-unit virtual frame (1 unit = 0.1 tile). Table order
// is draw order: brow shadows first so the sockets sink into the skull, ember
// irises in the recess, white-hot cores last. The leading eye is larger and
// hotter than the trailing one so the head reads in profile.  The rows were
// rescaled onto the hound redesign's compact forward skull (same layers, same
// colors, same leading/trailing asymmetry — the approved treatment at hound
// proportions instead of the old full-frame face).
GARM_FRAME_W :: f32(16)

@(rodata)
garm_details := [8]Sprite_Detail{
	{12.60, 2.80, 2.20, 0.50, {10, 8, 14, 255}}, 	// leading brow
	{10.30, 2.95, 1.90, 0.50, {10, 8, 14, 255}}, 	// trailing brow
	{12.70, 3.30, 2.00, 1.70, {12, 9, 16, 255}}, 	// leading socket
	{10.40, 3.45, 1.70, 1.50, {12, 9, 16, 255}}, 	// trailing socket
	{13.00, 3.60, 1.40, 1.10, {255, 60, 20, 255}}, 	// leading ember
	{10.70, 3.75, 1.10, 0.95, {225, 48, 16, 255}}, 	// trailing ember, dimmer with depth
	{13.50, 3.90, 0.45, 0.45, {255, 230, 170, 255}}, 	// leading core
	{11.10, 4.05, 0.40, 0.40, {255, 205, 145, 255}}, 	// trailing core
}

// Garm's body: a void-black hound in profile on the same 16x18 frame as the
// face — stepped near-black/charcoal/void-purple planes so the mass stays
// dark but readable.  Tables by motion group: the contact shadow always
// grounds him; the legs come in three stances (planted, and two trot frames
// picked by ground covered); the living mass above them breathes.
@(rodata)
garm_shadow := [1]Sprite_Detail{
	{1.0, 17.2, 13.5, 0.8, {0, 0, 0, 90}}, 	// grounded contact shadow
}

// Standing still: four distinct legs with gaps between them — the far pair a
// shade darker and half a step behind the near pair, paws toed forward.
@(rodata)
garm_legs_planted := [8]Sprite_Detail{
	{1.6, 13.2, 1.6, 4.2, {12, 9, 16, 255}}, 	// far rear leg
	{9.4, 13.2, 1.6, 4.2, {12, 9, 16, 255}}, 	// far front leg
	{1.2, 17.0, 2.0, 0.8, {12, 9, 16, 255}}, 	// far rear paw
	{9.0, 17.0, 2.0, 0.8, {12, 9, 16, 255}}, 	// far front paw
	{3.6, 13.0, 1.8, 4.6, {20, 16, 26, 255}}, 	// near rear leg
	{11.6, 13.0, 1.8, 4.6, {20, 16, 26, 255}}, 	// near front leg
	{3.6, 17.4, 2.5, 0.6, {20, 16, 26, 255}}, 	// near rear paw, toes forward
	{11.6, 17.4, 2.5, 0.6, {20, 16, 26, 255}}, 	// near front paw
}

// Trot frame A: the diagonal pair (far-rear + near-front) swings forward
// lifted — shorter leg, raised paw — while the other diagonal drives back,
// planted at full length.
@(rodata)
garm_legs_a := [8]Sprite_Detail{
	{2.7, 13.2, 1.6, 3.6, {12, 9, 16, 255}}, 	// far rear leg, swinging, lifted
	{8.6, 13.2, 1.6, 4.2, {12, 9, 16, 255}}, 	// far front leg, driving back
	{2.5, 16.4, 2.0, 0.8, {12, 9, 16, 255}}, 	// far rear paw, mid-air
	{8.2, 17.0, 2.0, 0.8, {12, 9, 16, 255}}, 	// far front paw
	{2.7, 13.0, 1.8, 4.6, {20, 16, 26, 255}}, 	// near rear leg, planted under the haunch
	{12.7, 13.0, 1.8, 4.0, {20, 16, 26, 255}}, 	// near front leg, reaching, lifted
	{2.7, 17.4, 2.5, 0.6, {20, 16, 26, 255}}, 	// near rear paw
	{12.9, 16.6, 2.5, 0.6, {20, 16, 26, 255}}, 	// near front paw, mid-air
}

// Trot frame B: the opposite diagonal.
@(rodata)
garm_legs_b := [8]Sprite_Detail{
	{0.9, 13.2, 1.6, 4.2, {12, 9, 16, 255}}, 	// far rear leg, trailing, planted
	{10.2, 13.2, 1.6, 3.6, {12, 9, 16, 255}}, 	// far front leg, swinging, lifted
	{0.7, 17.0, 2.0, 0.8, {12, 9, 16, 255}}, 	// far rear paw
	{10.4, 16.4, 2.0, 0.8, {12, 9, 16, 255}}, 	// far front paw, mid-air
	{4.5, 13.0, 1.8, 4.0, {20, 16, 26, 255}}, 	// near rear leg, gathering, lifted
	{10.8, 13.0, 1.8, 4.6, {20, 16, 26, 255}}, 	// near front leg, driving
	{4.7, 16.6, 2.5, 0.6, {20, 16, 26, 255}}, 	// near rear paw, mid-air
	{10.8, 17.4, 2.5, 0.6, {20, 16, 26, 255}}, 	// near front paw
}

// One trot stride covers ~1.33 tiles of ground; the frame is a pure function
// of where he stands, so the gait needs no animation state and never drifts
// from his actual movement.
GARM_STRIDE :: f32(0.75) // stride cycles per tile walked

garm_gait_phase :: proc(pos_x: f32) -> f32 {
	return math.mod(abs(pos_x) * GARM_STRIDE, 1.0)
}

garm_legs_for :: proc(grounded: bool, vel_x: f32, pos_x: f32) -> []Sprite_Detail {
	if !grounded || abs(vel_x) <= 0.1 {return garm_legs_planted[:]}
	return garm_legs_a[:] if garm_gait_phase(pos_x) < 0.5 else garm_legs_b[:]
}

// The living mass: long low torso, haunch, hunched ember-cracked shoulders,
// angular skull and muzzle (sized to hold the approved eye rows), back-swept
// ears, ragged stepped tail.  Flame is selective — mane cracks, tail tip —
// small red -> orange -> white-hot steps on a dominant dark body.
@(rodata)
garm_body := [27]Sprite_Detail{
	// torso, rear to chest — low and heavy, legs mostly buried in the mass
	{0.5, 7.6, 12.0, 5.8, {25, 20, 30, 255}}, 	// long low torso
	{0.5, 8.6, 4.0, 4.6, {18, 14, 24, 255}}, 	// haunch mass
	{9.8, 7.6, 2.8, 5.2, {22, 17, 28, 255}}, 	// deep chest drop
	{1.0, 7.6, 9.5, 0.6, {32, 25, 41, 255}}, 	// spine light
	{1.6, 12.4, 10.0, 0.8, {10, 8, 14, 255}}, 	// belly shadow
	{5.0, 4.8, 4.4, 3.6, {25, 20, 30, 255}}, 	// hunched shoulder crest
	{5.3, 4.8, 3.6, 0.7, {36, 28, 46, 255}}, 	// crest top light
	{8.0, 4.6, 3.0, 3.6, {25, 20, 30, 255}}, 	// neck carrying the head forward
	{9.0, 6.6, 3.0, 0.7, {14, 11, 19, 255}}, 	// throat shadow
	// head — a compact forward skull holding the garm_details eye rows
	{9.8, 2.2, 5.4, 4.6, {25, 20, 30, 255}}, 	// skull
	{10.0, 2.2, 4.6, 0.6, {36, 28, 46, 255}}, 	// skull top light
	{13.8, 4.4, 2.2, 2.0, {18, 14, 24, 255}}, 	// muzzle, jutting past the jawline
	{13.8, 6.1, 2.0, 0.5, {10, 8, 14, 255}}, 	// jaw underside
	{15.6, 4.6, 0.4, 0.6, {8, 6, 11, 255}}, 	// nose tip
	{10.2, 0.8, 1.4, 1.8, {18, 14, 24, 255}}, 	// near ear
	{9.9, 1.6, 0.7, 1.0, {18, 14, 24, 255}}, 	// near ear, swept-back base
	{12.4, 1.0, 1.3, 1.5, {12, 9, 16, 255}}, 	// far ear
	// ragged tail, stepping up off the rear
	{0.0, 6.4, 1.6, 1.6, {18, 14, 24, 255}}, 	// tail root
	{0.0, 5.2, 1.0, 1.4, {25, 20, 30, 255}}, 	// tail mid step
	{0.2, 4.2, 0.7, 1.2, {12, 9, 16, 255}}, 	// ragged tip
	// selective flame — cracks along the shoulder crest, one on the spine,
	// the tail tip; small red -> orange -> white-hot steps
	{5.5, 5.0, 0.9, 0.5, {190, 55, 18, 255}}, 	// crest crack
	{6.7, 4.6, 1.1, 0.6, {255, 110, 25, 255}}, 	// mane heart
	{8.0, 5.1, 0.8, 0.45, {190, 55, 18, 255}}, 	// crest crack
	{7.0, 4.75, 0.35, 0.3, {255, 225, 160, 255}}, 	// white-hot fleck
	{3.2, 7.75, 1.0, 0.4, {170, 48, 16, 255}}, 	// spine crack
	{0.25, 3.95, 0.55, 0.55, {255, 110, 25, 255}}, 	// tail-tip flame
	{0.4, 4.05, 0.25, 0.25, {255, 225, 160, 255}}, 	// tail-tip core
}

// Garm: void-black pixel hound — distance-trotting legs, a breathing body
// carrying the layered ember eyes, a two-state mane flare, hp bar overhead.
draw_garm :: proc(e: ^Enemy, t: f32) {
	px := i32(e.pos.x * CELL_SIZE)
	py := i32(e.pos.y * CELL_SIZE)
	pw := i32(GARM_W * CELL_SIZE)

	ps := f32(CELL_SIZE) * 0.1
	origin := [2]f32{e.pos.x * CELL_SIZE, e.pos.y * CELL_SIZE}
	draw_detail_overlay(origin, ps, GARM_FRAME_W, e.facing, garm_shadow[:])
	walking := e.grounded && abs(e.vel.x) > 0.1
	draw_detail_overlay(origin, ps, GARM_FRAME_W, e.facing,
		garm_legs_for(e.grounded, e.vel.x, e.pos.x))

	// The living mass — torso, head, tail, mane and the face — sinks up to
	// 0.35 units on a slow breath while the legs move under it; each trot
	// footfall drops the mass another third of a unit so the stride has weight.
	breath := (math.sin(t * 1.3) + 1) * 0.5 * 0.35
	if walking && math.mod(garm_gait_phase(e.pos.x) * 2, 1.0) < 0.3 {
		breath += 0.35
	}
	borigin := [2]f32{origin.x, origin.y + breath * ps}
	draw_detail_overlay(borigin, ps, GARM_FRAME_W, e.facing, garm_body[:])
	draw_detail_overlay(borigin, ps, GARM_FRAME_W, e.facing, garm_details[:])

	// Mane flare: a hard two-state flicker over the hottest crack — stepped
	// like every other flame in the game, never a smooth pulse.
	if math.sin(t*9 + 1.7) > 0.35 {
		flare := Sprite_Detail{6.5, 4.45, 1.5, 0.85, {255, 150, 45, 200}}
		rl.DrawRectangleRec(detail_rect(borigin, ps, GARM_FRAME_W, e.facing, flare), flare.color)
	}

	// HP bar
	if e.hp < e.hp_max {
		w := i32(f32(pw) * f32(e.hp) / f32(e.hp_max))
		rl.DrawRectangle(px, py - 5, pw, 3, rl.Color{60, 0, 0, 255})
		rl.DrawRectangle(px, py - 5, w, 3, rl.Color{220, 40, 40, 255})
	}
}

// Draw a laser ray from the enemy center to each tile in the 3×3 grid around it.
// Solid tiles get a bright ray; air tiles get a dim one.
draw_enemy_scan :: proc(e: ^Enemy, w: ^World_Grid) {
	CS :: i32(CELL_SIZE)

	// Enemy center in pixels.
	ecx := i32((e.pos.x + BUILDER_W * 0.5) * CELL_SIZE)
	ecy := i32((e.pos.y + BUILDER_H * 0.5) * CELL_SIZE)

	// Tile the enemy center sits in.
	tx := int(e.pos.x + BUILDER_W * 0.5)
	ty := int(e.pos.y + BUILDER_H * 0.5)

	for dy in -3 ..= 2 {
		for dx in -3 ..= 2 {
			if dx == 0 && dy == 0 {continue}
			nx := tx + dx
			ny := ty + dy
			if !in_bounds(nx, ny) {continue}

			// Target: center of the scanned tile in pixels.
			tcx := i32(nx) * CS + CS / 2
			tcy := i32(ny) * CS + CS / 2

			col: rl.Color
			if is_solid(w, nx, ny) {
				col = rl.Color{255, 200, 50, 200} // bright yellow — solid
			} else {
				col = rl.Color{80, 180, 255, 60} // dim blue — air
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
builder_frames := [2][BUILDER_FRAME_H]string {
	{ 	// planted stance
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
	{ 	// broad mid-stride
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

builder_pixel_color :: proc(ch: u8, hunting: bool, raider := false) -> rl.Color {
	if raider {
		switch ch {
		case 'O': return rl.Color{18, 14, 17, 255}       // soot-black outline
		case 'I': return rl.Color{54, 48, 52, 255}       // blackened iron
		case 'i': return rl.Color{126, 92, 70, 255}      // fire-worn edge
		case 'L': return rl.Color{62, 36, 31, 255}       // charred leather
		case 'l': return rl.Color{39, 22, 23, 255}
		case 'B': return rl.Color{88, 34, 27, 255}       // soot-dark beard
		case 'b': return rl.Color{47, 22, 23, 255}
		case 'R': return rl.Color{205, 61, 24, 255}      // ember beard streak
		case 'K': return rl.Color{128, 74, 58, 255}
		case 'E': return rl.Color{255, 118, 35, 255}     // furnace eyes
		}
		return {}
	}
	switch ch {
	case 'O':
		return rl.Color{24, 20, 24, 255} // heavy chest outline
	case 'I':
		return rl.Color{65, 67, 75, 255} // dark iron
	case 'i':
		return rl.Color{132, 136, 146, 255} // iron edge glint
	case 'L':
		return rl.Color{112, 65, 38, 255} // worn leather
	case 'l':
		return rl.Color{68, 38, 27, 255} // leather seam
	case 'B':
		return rl.Color{150, 57, 27, 255} // rust-red beard
	case 'b':
		return rl.Color{86, 33, 23, 255} // beard shadow
	case 'R':
		return rl.Color{201, 78, 33, 255} // beard firelight
	case 'K':
		return rl.Color{164, 101, 65, 255} // cave-worn skin
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
	iron := rl.Color{65, 67, 75, 255}
	iron_hi := rl.Color{132, 136, 146, 255}
	wood_d := rl.Color{74, 39, 24, 255}
	wood := rl.Color{145, 78, 40, 255}

	if raised {
		// Pick head above the leading shoulder; the stepped handle stays crisp.
		draw_builder_rect(ox, oy, facing, 8, -2, 5, 3, outline)
		draw_builder_rect(ox, oy, facing, 9, -1, 4, 1, iron_hi)
		draw_builder_rect(ox, oy, facing, 8, 0, 4, 1, iron)
		for p in ([][2]int{{10, 1}, {10, 2}, {9, 3}, {9, 4}, {8, 5}, {8, 6}}) {
			draw_builder_rect(ox, oy, facing, p.x, p.y, 2, 2, outline)
			draw_builder_rect(ox, oy, facing, p.x, p.y, 1, 1, wood)
		}
		draw_builder_rect(ox, oy, facing, 9, 4, 1, 2, wood_d)
	} else {
		// Tool carried low at the leading hand while walking or standing.
		draw_builder_rect(ox, oy, facing, 10, 5, 2, 8, outline)
		draw_builder_rect(ox, oy, facing, 10, 6, 1, 6, wood)
		draw_builder_rect(ox, oy, facing, 8, 4, 5, 3, outline)
		draw_builder_rect(ox, oy, facing, 9, 4, 4, 1, iron_hi)
		draw_builder_rect(ox, oy, facing, 8, 5, 4, 1, iron)
	}
}

draw_builder_carry :: proc(e: ^Enemy, ox, oy: f32) {
	outline := rl.Color{24, 20, 24, 255}
	base := terrain_table[e.builder.carry].color
	dark := shade_color(base, 0.55)
	light := shade_color(base, 1.35)

	// A six-pixel mineral block locked against the leading shoulder.
	draw_builder_rect(ox, oy, e.facing, 7, -3, 7, 6, outline)
	draw_builder_rect(ox, oy, e.facing, 8, -2, 5, 4, base)
	draw_builder_rect(ox, oy, e.facing, 8, -2, 4, 1, light)
	draw_builder_rect(ox, oy, e.facing, 12, -1, 1, 3, dark)
	draw_builder_rect(ox, oy, e.facing, 9, 0, 2, 1, dark)
	// Bracer and fist holding the load up.
	draw_builder_rect(ox, oy, e.facing, 8, 2, 3, 3, outline)
	draw_builder_rect(ox, oy, e.facing, 9, 2, 2, 2, rl.Color{65, 67, 75, 255})
	draw_builder_rect(ox, oy, e.facing, 9, 2, 1, 1, rl.Color{132, 136, 146, 255})
}

draw_builder :: proc(e: ^Enemy, raider := false) {
	moving := abs(e.vel.x) > 0.2
	frame_i := 0
	if moving do frame_i = int(abs(e.pos.x) * 4) % 2
	hunting := e.builder.goal == .Hunt
	raised := hunting || e.builder.escaping || e.nav.mine_timer > 0

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
				builder_pixel_color(ch, hunting, raider),
			)
		}
	}

	if e.builder.carry != .Air {
		draw_builder_carry(e, ox, oy)
	} else {
		draw_builder_tool(ox, oy, e.facing, raised)
	}

	// The hunt face opens into a tiny black shout under ember-bright eyes.
	if hunting do draw_builder_rect(ox, oy, e.facing, 5, 5, 2, 1,
		rl.Color{12, 8, 11, 255} if raider else rl.Color{24, 20, 24, 255})

	// A wounded raider carries a soot-red health bar; ordinary builders keep
	// their quieter established silhouette.
	if raider && e.hp < e.hp_max {
		w := i32(pw * f32(e.hp) / f32(e.hp_max))
		rl.DrawRectangle(i32(px), i32(py) - 5, i32(pw), 3, rl.Color{45, 12, 12, 255})
		rl.DrawRectangle(i32(px), i32(py) - 5, w, 3, rl.Color{210, 58, 25, 255})
	}
}

// The draugr wears the dead builder's frame recolored to the grave: corpse-pale
// skin, rotted leather, bone-grey beard, and cold ghost-fire eyes. It always
// carries its pick raised — a relentless risen miner.
draugr_pixel_color :: proc(ch: u8) -> rl.Color {
	switch ch {
	case 'O':
		return rl.Color{16, 20, 18, 255} // near-black grave outline
	case 'I':
		return rl.Color{60, 66, 58, 255} // corroded iron
	case 'i':
		return rl.Color{116, 126, 112, 255} // dull iron glint
	case 'L':
		return rl.Color{66, 72, 52, 255} // mossy rotted leather
	case 'l':
		return rl.Color{40, 46, 34, 255} // leather seam
	case 'B':
		return rl.Color{150, 156, 138, 255} // bone-grey beard
	case 'b':
		return rl.Color{86, 92, 82, 255} // beard shadow
	case 'R':
		return rl.Color{120, 128, 110, 255} // pallid highlight
	case 'K':
		return rl.Color{150, 164, 142, 255} // corpse-pale skin
	case 'E':
		return rl.Color{120, 255, 220, 255} // cold ghost-fire eyes
	}
	return {}
}

draw_draugr :: proc(e: ^Enemy) {
	moving := abs(e.vel.x) > 0.2
	frame_i := 0
	if moving do frame_i = int(abs(e.pos.x) * 4) % 2

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
			rl.DrawRectangleRec({ox + f32(draw_col), oy + f32(row), 1, 1}, draugr_pixel_color(ch))
		}
	}

	// Pick always raised, mouth agape — a risen thing with one purpose.
	draw_builder_tool(ox, oy, e.facing, true)
	draw_builder_rect(ox, oy, e.facing, 5, 5, 2, 1, rl.Color{16, 20, 18, 255})

	// HP bar in grave-green.
	if e.hp < e.hp_max {
		w := i32(f32(pw) * f32(e.hp) / f32(e.hp_max))
		rl.DrawRectangle(i32(px), i32(py) - 5, i32(pw), 3, rl.Color{20, 40, 24, 255})
		rl.DrawRectangle(i32(px), i32(py) - 5, w, 3, rl.Color{120, 220, 150, 255})
	}
}

// ─── Player (pixel-art forms) ───────────────────────────────────────────────

// The sole player look.  Keep the enum-shaped API so the renderer, startup
// card, and Gnipa Studio player editor share one table-driven path.
Player_Form :: enum u8 {
	Wizard,
}

PLAYER_FORM_COUNT :: len(Player_Form)

player_form_names := [Player_Form]cstring {
	.Wizard = "Wizard",
}

PLAYER_RENDER_SCALE :: 2 // sprite height in tiles — the one knob for player size
FRAME_WIDTH :: 16
FRAME_HEIGHT :: 22

player_pixel_color :: proc(p: ^Player, ch: rune) -> rl.Color {
	switch ch {
	case 'x':
		return rl.Color{13, 11, 19, 255} // outline
	case 'v':
		return rl.Color{16, 14, 22, 255} // void / black cloth
	case 'h':
		return shade_color(p.clothing_color, 0.40) // clothing shadow
	case 'H':
		return shade_color(p.clothing_color, 0.72) // clothing mid
	case 'L':
		return shade_color(p.clothing_color, 1.08) // clothing rim light
	case 'y':
		return shade_color(p.hair_color, 0.55) // hair / beard shadow
	case 'Y':
		return p.hair_color // hair / beard
	case 'k':
		return rl.Color{158, 116, 86, 255} // skin shadow
	case 'K':
		return rl.Color{214, 170, 132, 255} // skin
	case 'm':
		return rl.Color{58, 62, 78, 255} // steel shadow
	case 'M':
		return rl.Color{132, 138, 158, 255} // steel
	case 'N':
		return rl.Color{200, 206, 224, 255} // steel highlight
	case 'f':
		return rl.Color{74, 56, 36, 255} // fur shadow
	case 'F':
		return rl.Color{122, 94, 58, 255} // fur
	case 'b':
		return rl.Color{66, 44, 28, 255} // leather shadow
	case 'B':
		return rl.Color{110, 70, 40, 255} // leather / boots
	case 'w':
		return rl.Color{168, 158, 132, 255} // bone shadow
	case 'W':
		return rl.Color{228, 220, 192, 255} // bone / horn / beak
	case 's':
		return rl.Color{70, 68, 80, 255} // stone shadow
	case 'S':
		return rl.Color{118, 116, 128, 255} // stone
	case 'g':
		return rl.Color{186, 98, 32, 255} // core ember ring
	case 'G':
		return rl.Color{255, 176, 64, 255} // glowing core
	case 'E':
		return rl.Color{255, 214, 92, 255} // eye glow
	case 'O':
		return rl.Color{205, 235, 255, 255} // orb core
	case 'Q':
		return rl.Color{96, 156, 255, 255} // orb halo
	case 'T':
		return rl.Color{200, 158, 72, 255} // gold trim
	case:
		return rl.BLANK
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
	if p.dead {return}

	frame := player_form_frames[form][p.anim_frame]

	// Float world-pixel positions so the sprite glides sub-pixel under the
	// supersampled camera instead of snapping to whole tiles.
	px := p.pos.x * CELL_SIZE
	py := (p.pos.y + step_visual_y) * CELL_SIZE
	pw_px := f32(PLAYER_W * CELL_SIZE)
	ph_px := f32(PLAYER_H * CELL_SIZE)

	// Best-fit the sprite to the collision box, then force it up to
	// PLAYER_RENDER_SCALE tiles high so the mage reads clearly.
	pixel_size := min(i32(pw_px) / FRAME_WIDTH, i32(ph_px) / FRAME_HEIGHT)
	forced_ps := i32((PLAYER_RENDER_SCALE * CELL_SIZE + FRAME_HEIGHT - 1) / FRAME_HEIGHT) // ceil
	if forced_ps > pixel_size {pixel_size = forced_ps}
	if pixel_size < 1 {pixel_size = 1}
	ps := f32(pixel_size)

	total_w := f32(FRAME_WIDTH) * ps
	total_h := f32(FRAME_HEIGHT) * ps
	origin_x := px + (pw_px - total_w) * 0.5 // centered on the box
	origin_y := py + (ph_px - total_h) // feet on the box floor

	bob := f32(0)
	if p.anim_frame == 1 {bob = -ps * 2} 	// little hop mid-stride

	// Soft pulsing halo behind the orb pixel ('O'), scanned from the frame so
	// it survives facing flips without a per-form table. Drawn first so the
	// sprite reads on top of the glow.
	for row in 0 ..< FRAME_HEIGHT {
		for col in 0 ..< FRAME_WIDTH {
			if frame[row][col] != 'O' {continue}
			draw_col := col
			if p.facing < 0 {draw_col = FRAME_WIDTH - 1 - col}
			cx := origin_x + (f32(draw_col) + 0.5) * ps
			cy := origin_y + (f32(row) + 0.5) * ps + bob
			pulse := 0.7 + 0.3 * math.sin(f32(rl.GetTime()) * 3.5)
			rl.DrawRectangleRec(
				{cx - 3.5 * ps, cy - 3.5 * ps, 7 * ps, 7 * ps},
				{120, 180, 255, u8(28 * pulse)},
			)
			rl.DrawRectangleRec(
				{cx - 2.5 * ps, cy - 2.5 * ps, 5 * ps, 5 * ps},
				{150, 200, 255, u8(55 * pulse)},
			)
		}
	}

	for row in 0 ..< FRAME_HEIGHT {
		for col in 0 ..< FRAME_WIDTH {
			ch := frame[row][col]
			if ch == ' ' {continue}
			draw_col := col
			if p.facing < 0 {draw_col = FRAME_WIDTH - 1 - col} 	// flip when facing left
			rl.DrawRectangleRec(
				{origin_x + f32(draw_col) * ps, origin_y + f32(row) * ps + bob, ps, ps},
				player_pixel_color(p, ch),
			)
		}
	}

	// Held item in the leading hand, drawn from its real icon art so what you
	// carry is what you see. The pickaxe swings on the chip cooldown; a melee
	// weapon swings on the attack cooldown.
	held := held_item(p)
	if held != .None {
		hand := rl.Vector2{origin_x + total_w - ps * 3, origin_y + ps * 16 + bob}
		if p.facing < 0 {hand.x = origin_x + ps * 3}
		deg := f32(10) // resting lean toward where the player looks
		if item_icons[held].grid == WAND_GRID {deg = -10} 	// wand art is already diagonal
		if held == .Pickaxe && p.mine_timer > 0 {
			// Swing arc driven by the chip cooldown: struck-down at the hit,
			// recovering back up as the timer runs out.
			sw := p.mine_timer / PICK_SWING_TIME // 1 at the strike → 0 recovered
			deg = -30 + 60 * sw
		} else if is_melee_weapon(held) && p.attack_timer > 0 {
			// Weighted slash on the attack cooldown: a fast follow-through
			// from over the shoulder, then a slow, heavy lift back to guard —
			// the asymmetry is what sells the blade's weight.
			sw := p.attack_timer / SWORD_COOLDOWN // 1 at the strike → 0 recovered
			if sw > 0.75 {
				cut := (1 - sw) / 0.25 // 0 raised behind → 1 swept through
				deg = -40 + 110 * cut
			} else {
				deg = 10 + 60 * (sw / 0.75) // +70 swept → +10 rested, slowly
			}
		}
		if p.facing < 0 {deg = -deg}
		draw_held_item(held, hand, ps * 0.75, deg, p.facing < 0)
	}
}

// Draws a form's idle sprite (frame 0) at a UI position for the character-
// select cards. Same pixel loop as draw_player, minus animation/facing.
draw_form_sprite :: proc(form: Player_Form, x, y, ps: f32, hair, clothing: rl.Color) {
	tmp := Player {
		hair_color     = hair,
		clothing_color = clothing,
	}
	frame := player_form_frames[form][0]
	for row in 0 ..< FRAME_HEIGHT {
		for col in 0 ..< FRAME_WIDTH {
			ch := frame[row][col]
			if ch == ' ' {continue}
			rl.DrawRectangleRec(
				{x + f32(col) * ps, y + f32(row) * ps, ps, ps},
				player_pixel_color(&tmp, ch),
			)
		}
	}
}

// A held item's icon art drawn in world space: one icon pixel per player
// pixel, mirrored when facing left, rotated `deg` degrees around the hand
// grip so the pickaxe can swing while mining.
draw_held_item :: proc(it: Item, hand: rl.Vector2, ps: f32, deg: f32, flip: bool) {
	icon := &item_icons[it]
	if icon.grid[0] == "" { 	// no art yet: a small flat-color stub in the hand
		rl.DrawRectangleRec({hand.x - ps, hand.y - ps * 2, ps * 2, ps * 3}, item_table[it].color)
		return
	}

	// Grid point the hand grips — most tool art roots its handle near the
	// bottom-center of the 12x12 icon grid; the diagonal wand art roots its
	// handle in the bottom-left corner instead.
	grip_x, grip_y := f32(5), f32(9.5)
	if icon.grid == WAND_GRID {grip_x, grip_y = 2, 9}

	// Pixels near the grip fade into the robe's black cloth, so the handle
	// reads as held by the body rather than pasted beside it.
	GRIP_FADE_R :: 3.5
	robe := rl.Color{16, 14, 22, 255} 	// player_pixel_color's 'v' black cloth

	for row, gy in icon.grid {
		for gx in 0 ..< len(row) {
			col, ok := icon_pixel(icon.pal, row[gx])
			if !ok do continue
			gdx := f32(gx) + 0.5 - grip_x
			gdy := f32(gy) + 0.5 - grip_y
			if d := math.sqrt(gdx * gdx + gdy * gdy); d < GRIP_FADE_R {
				t := 1 - d / GRIP_FADE_R 	// 1 at the grip → 0 at the fade edge
				col.r = u8(f32(col.r) + (f32(robe.r) - f32(col.r)) * t)
				col.g = u8(f32(col.g) + (f32(robe.g) - f32(col.g)) * t)
				col.b = u8(f32(col.b) + (f32(robe.b) - f32(col.b)) * t)
			}
			dx := f32(gx) - grip_x
			if flip {dx = -dx - 1} 	// mirror the offset across the grip
			rx := hand.x + dx * ps
			ry := hand.y + (f32(gy) - grip_y) * ps
			// Rect whose unrotated top-left is (rx,ry), spun around the grip.
			rl.DrawRectanglePro(
				rl.Rectangle{hand.x, hand.y, ps, ps},
				{hand.x - rx, hand.y - ry},
				deg,
				col,
			)
		}
	}
}

// ─── Debug Overlay ────────────────────────────────────────────────────────────

draw_debug :: proc(gs: ^Game_State) {
	buf: [128]u8
	text := fmt.bprintf(
		buf[:],
		"pos:%.1f,%.1f  vel:%.1f,%.1f  frame:%d",
		gs.player.pos.x,
		gs.player.pos.y,
		gs.player.vel.x,
		gs.player.vel.y,
		gs.frame,
	)
	rl.DrawText(cstring(raw_data(buf[:])), 4, 4, 10, rl.WHITE)

	hx := gs.ui.hover_tile.x * CELL_SIZE
	hy := gs.ui.hover_tile.y * CELL_SIZE
	rl.DrawRectangleLines(hx, hy, CELL_SIZE, CELL_SIZE, rl.YELLOW)

	draw_enemies_debug(gs)
}

CS :: CELL_SIZE // shorthand

draw_enemies_debug :: proc(gs: ^Game_State) {
	for i in 0 ..< MAX_ENEMIES {
		if !gs.enemies.active[i] {continue}
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
	inv := &gs.player.inventory
	if inv.selected < 0 do return // nothing selected
	slot := inv.slots[inv.selected]
	if slot.item == .None || slot.count <= 0 do return
	if item_table[slot.item].place_tile == .Air do return // not a placeable item
	if cursor_over_ui(gs) do return // cursor grabbed by a panel

	t := gs.ui.hover_tile
	px := f32(t.x * CELL_SIZE)
	py := f32(t.y * CELL_SIZE)
	ok := placement_ok(gs, slot.item, int(t.x), int(t.y))

	base := terrain_table[item_table[slot.item].place_tile].color
	fill := ok ? rl.Color{base.r, base.g, base.b, 140} : rl.Color{200, 60, 60, 110}
	outline := ok ? rl.Color{140, 255, 160, 230} : rl.Color{255, 90, 90, 230}
	rl.DrawRectangleRec({px, py, CELL_SIZE, CELL_SIZE}, fill)
	rl.DrawRectangleLinesEx({px, py, CELL_SIZE, CELL_SIZE}, 1, outline)
}

draw_portals :: proc(gs: ^Game_State) {
	for &p in level_portals[gs.level_index] {
		if !portal_valid(&p) do continue
		// Pixel center and ground line of the two-tile-wide gate. Anchoring to
		// the floor fixes the old ellipse extending several tiles underground.
		cx := i32((p.tiles[0].x + p.tiles[1].x + 1) * CELL_SIZE / 2)
		base_y := i32((p.tiles[0].y + 1) * CELL_SIZE)

		sky := p.dest_level == LEVEL_SKY || gs.level_index == LEVEL_SKY
		locked := p.gate_tier >= 0 && !gs.progression.cave_unlocked[p.gate_tier]

		if sky {
			draw_pixel_sky_gate(cx, base_y, gs.frame)
		} else {
			draw_pixel_cave_gate(cx, base_y, gs.frame, !locked)
		}
	}

	// The dynamic sky gate a surface altar raised — blooms above the altar.
	if gs.level_index == LEVEL_SURFACE && gs.progression.sky_altar_pos != {0, 0} {
		ap := gs.progression.sky_altar_pos
		// Entrance is a circular sky-well; the Low Sky return remains the
		// floor-anchored doorway drawn from level_portals above.
		draw_pixel_round_sky_portal(
			i32(ap.x * CELL_SIZE) + CELL_SIZE / 2,
			i32(ap.y * CELL_SIZE) - 39,
			gs.frame,
		)
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
		a := u8(f32(col.a) * 0.16 * (1 - f32(k) / LAYERS) * (0.7 + 0.3 * pulse))
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
portal_vortex :: proc(
	cx, cy, cw, ch: f32,
	frame: u64,
	arms: int,
	rim, throat: rl.Color,
	speed: f32,
) {
	POINTS :: 16
	TURNS :: f32(1.4)
	rot := f32(frame) * 0.01
	for m in 0 ..< arms {
		arm := f32(m) / f32(arms) * math.TAU
		for j in 0 ..< POINTS {
			s := math.mod(f32(j) / POINTS + f32(frame) * speed, 1) // 0 rim → 1 center, looping
			rr := 1 - s
			ang := arm + s * TURNS * math.TAU + rot
			px := cx + math.cos(ang) * cw * rr
			py := cy + math.sin(ang) * ch * rr
			col := portal_mix(rim, throat, s)
			col.a = u8(f32(col.a) * math.sin(s * math.PI)) // fade in/out
			rl.DrawCircleGradient({px, py}, (0.7 + rr * 1.8) * 2.2, col, rl.Color{})
		}
	}
}

// Bright rim ring, thickened by two faint offset rings for an additive glow.
portal_rim :: proc(cx, cy, cw, ch: f32, col: rl.Color, pulse: f32) {
	rl.DrawEllipseLines(
		i32(cx),
		i32(cy),
		cw,
		ch,
		rl.Color{col.r, col.g, col.b, u8(130 + 100 * pulse)},
	)
	rl.DrawEllipseLines(
		i32(cx),
		i32(cy),
		cw * 1.03,
		ch * 1.02,
		rl.Color{col.r, col.g, col.b, u8(50 + 40 * pulse)},
	)
	rl.DrawEllipseLines(
		i32(cx),
		i32(cy),
		cw * 0.97,
		ch * 0.98,
		rl.Color{col.r, col.g, col.b, u8(50 + 40 * pulse)},
	)
}

// A couple of ripple rings expanding out from the mouth and fading.
portal_ripples :: proc(cx, cy, hw, hh: f32, frame: u64, col: rl.Color) {
	RINGS :: 2
	for k in 0 ..< RINGS {
		ph := math.mod(f32(frame) * 0.006 + f32(k) / RINGS, 1)
		rw := hw * (0.5 + ph * 0.8)
		rh := hh * (0.5 + ph * 0.8)
		a := u8(f32(col.a) * (1 - ph) * 0.5)
		rl.DrawEllipseLines(i32(cx), i32(cy), rw, rh, rl.Color{col.r, col.g, col.b, a})
	}
}

// Twinkling cross-glints drifting around the rim.
portal_glints :: proc(cx, cy, cw, ch: f32, frame: u64, col: rl.Color) {
	for i in 0 ..< 4 {
		base := f32(u32(i) * 2654435761 % 628) / 100
		dir := i % 2 == 0 ? f32(1) : f32(-1)
		ang := base + f32(frame) * 0.004 * dir
		tw := 0.5 + 0.5 * math.sin(f32(frame) * 0.08 + f32(i) * 1.7)
		px := cx + math.cos(ang) * cw
		py := cy + math.sin(ang) * ch
		r := 1.5 + 2.5 * tw
		c := rl.Color{col.r, col.g, col.b, u8(200 * tw)}
		rl.DrawLineEx({px - r, py}, {px + r, py}, 1, c)
		rl.DrawLineEx({px, py - r}, {px, py + r}, 1, c)
		rl.DrawCircleGradient({px, py}, r, c, rl.Color{})
	}
}

// Tall, luminous sky gate: cool aurora vortex whorling into a deep-blue throat.
draw_sky_portal :: proc(cx, cy: f32, frame: u64) {
	pulse := 0.5 + 0.5 * math.sin(f32(frame) * 0.05)
	hw := 2.5 * f32(CELL_SIZE) // halo reach
	hh := 5.0 * f32(CELL_SIZE)
	cw := 1.4 * f32(CELL_SIZE) // mouth
	ch := 2.8 * f32(CELL_SIZE)
	glow := rl.Color{120, 200, 255, 255}

	rl.BeginBlendMode(.ADDITIVE)
	portal_bloom(cx, cy, hw, hh, glow, pulse)
	rl.EndBlendMode()

	portal_core(cx, cy, cw, ch, rl.Color{6, 12, 34, 235})

	rl.BeginBlendMode(.ADDITIVE)
	portal_vortex(
		cx,
		cy,
		cw,
		ch,
		frame,
		3,
		rl.Color{190, 240, 255, 255},
		rl.Color{90, 140, 255, 220},
		0.006,
	)
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
	red := rl.Color{210, 45, 45, u8(255 * life)}

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
		x0 := cx + math.cos(ang) * cw * 1.1
		y0 := cy + math.sin(ang) * ch * 1.1
		x1 := cx + math.cos(ang + 0.35) * hw * 0.8
		y1 := cy + math.sin(ang + 0.35) * hh * 0.8
		x2 := cx + math.cos(ang) * hw
		y2 := cy + math.sin(ang) * hh
		rl.DrawLineEx({x0, y0}, {x1, y1}, 1.5, green)
		rl.DrawLineEx({x1, y1}, {x2, y2}, 1.5, green)
	}

	rl.BeginBlendMode(.ADDITIVE)
	if active {
		portal_vortex(
			cx,
			cy,
			cw,
			ch,
			frame,
			3,
			rl.Color{255, 130, 60, 255},
			rl.Color{150, 20, 60, 220},
			0.007,
		)
		portal_ripples(cx, cy, hw, hh, frame, rl.Color{220, 60, 50, 180})
		portal_glints(cx, cy, cw, ch, frame, rl.Color{255, 170, 120, 255})
	}
	portal_rim(cx, cy, cw, ch, red, active ? pulse : pulse * 0.4)
	rl.EndBlendMode()

	// Sealing rune drawn across a dormant maw — the gate is barred.
	if !active {
		draw_title_rune(
			title_runes[3],
			cx,
			cy,
			f32(CELL_SIZE) * 2.6,
			0,
			rl.Color{150, 40, 50, 130},
			2,
			5,
		)
	}
}

// ─── Pixel gates ─────────────────────────────────────────────────────────────
//
// The live portal pass uses these hard-edged gates. The older smooth helpers
// above remain isolated for now, but no draw path calls them: no ellipses,
// gradients or sub-pixel spirals are involved in the in-world result.

draw_pixel_gate_mouth :: proc(cx, base: i32, frame: u64, sky, active: bool) {
	tick := i32(frame / 6)
	void := rl.Color{7, 9, 18, 245} if sky else rl.Color{12, 5, 9, 245}
	dark := rl.Color{16, 35, 62, 255} if sky else rl.Color{45, 8, 14, 255}
	mid := rl.Color{40, 126, 190, 235} if sky else rl.Color{128, 24, 30, 235}
	hot := rl.Color{155, 235, 255, 255} if sky else rl.Color{255, 105, 45, 255}
	if !active {dark = rl.Color{20, 16, 24, 255}; mid = rl.Color{48, 30, 38, 220}; hot = rl.Color{105, 48, 55, 180}}

	// Stepped top and straight throat make a readable sprite silhouette.
	rl.DrawRectangle(cx - 5, base - 42, 10, 2, void)
	rl.DrawRectangle(cx - 8, base - 40, 16, 3, void)
	rl.DrawRectangle(cx - 10, base - 37, 20, 37, void)
	rl.DrawRectangle(cx - 8, base - 38, 16, 2, dark)

	if active {
		// Six travelling bands, deliberately snapped to integer rows. Short dark
		// cuts and bright facets suggest depth without smooth rotation.
		for i in 0 ..< 7 {
			ii := i32(i)
			y := base - 35 + ii * 5
			shift := (tick + ii * 3) % 6
			col := mid if (ii + tick / 2) % 3 != 0 else dark
			rl.DrawRectangle(cx - 9 + shift / 2, y, 18 - shift, 2, col)
			if (ii + tick) % 2 == 0 do rl.DrawRectangle(cx - 7 + shift, y - 1, 4, 1, hot)
		}
		if sky {
			rl.DrawRectangle(cx - 1, base - 35, 2, 30, rl.Color{85, 185, 235, 150})
			rl.DrawRectangle(cx, base - 32 + (tick % 5), 1, 8, rl.Color{220, 250, 255, 220})
		} else {
			for i in 0 ..< 5 {
				ii := i32(i)
				x := cx - 8 + (ii * 7 + tick * 2) % 16
				y := base - 33 + (ii * 11 + tick * 3) % 28
				rl.DrawRectangle(x, y, 2, 2, hot)
			}
		}
	} else {
		// Iron crossbars and a square rune seal make the locked state unmistakable.
		for i in 0 ..< 3 do rl.DrawRectangle(cx - 9, base - 31 + i32(i) * 11, 18, 2, rl.Color{56, 49, 56, 255})
		rl.DrawRectangle(cx - 1, base - 37, 2, 34, rl.Color{75, 66, 72, 255})
		rl.DrawRectangle(cx - 4, base - 23, 8, 8, rl.Color{24, 18, 23, 255})
		rl.DrawRectangle(cx - 3, base - 22, 6, 6, rl.Color{92, 34, 42, 255})
		draw_pixel_rune_mark(cx - 2, base - 22, rl.Color{190, 58, 66, 220}, int(tick / 4))
	}
}

draw_pixel_gate_frame :: proc(cx, base: i32, frame: u64, sky, active, framed: bool) {
	tick := i32(frame / 7)
	outline := rl.Color{20, 22, 30, 255}
	stone_d := rl.Color{68, 78, 102, 255} if sky else rl.Color{48, 44, 48, 255}
	stone := rl.Color{120, 143, 174, 255} if sky else rl.Color{82, 73, 72, 255}
	stone_hi := rl.Color{190, 211, 232, 255} if sky else rl.Color{128, 112, 102, 255}
	rune := rl.Color{95, 220, 255, 255} if sky else rl.Color{55, 190, 92, u8(active ? 245 : 100)}
	glow := rl.Color{80, 195, 255, 28} if sky else rl.Color{235, 48, 28, u8(active ? 25 : 8)}

	// Square bloom and drifting square sparks are the only spill outside the
	// silhouette. Additive color remains restrained and never softens edges.
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRectangle(cx - 15, base - 44, 30, 42, glow)
	rl.DrawRectangle(cx - 12, base - 42, 24, 39, rl.Color{glow.r, glow.g, glow.b, u8(glow.a + 10)})
	if active {
		for i in 0 ..< 7 {
			ii := i32(i)
			x := cx - 20 + (ii * 13 + tick * 3) % 41
			y := base - 43 + (ii * 17 + tick * 2) % 39
			sz := i32(1 + (ii + tick) % 2)
			rl.DrawRectangle(x, y, sz, sz, rl.Color{rune.r, rune.g, rune.b, u8(90 + (i % 3) * 45)})
		}
	}
	rl.EndBlendMode()

	draw_pixel_gate_mouth(cx, base, frame, sky, active)

	if !framed {
		// A surface altar projects four floating rune brackets rather than a
		// second heavy stone monument above the physical shrine.
		for i in 0 ..< 4 {
			ii := i32(i)
			rx := cx - 16 + ii * 10
			ry := base - 35 + ((ii + tick / 4) % 3) * 8
			rl.DrawRectangle(rx, ry, 6, 6, outline)
			draw_pixel_rune_mark(rx + 1, ry + 1, rune, i + int(tick / 5))
		}
		return
	}

	// Joined black arch silhouette, built at the same 1–5px scale as chest
	// straps and bench braces.
	rl.DrawRectangle(
		cx - 16,
		base - 5,
		7,
		5,
		outline,
	); rl.DrawRectangle(cx + 9, base - 5, 7, 5, outline)
	rl.DrawRectangle(
		cx - 15,
		base - 36,
		6,
		33,
		outline,
	); rl.DrawRectangle(cx + 9, base - 36, 6, 33, outline)
	rl.DrawRectangle(
		cx - 13,
		base - 41,
		5,
		7,
		outline,
	); rl.DrawRectangle(cx + 8, base - 41, 5, 7, outline)
	rl.DrawRectangle(cx - 9, base - 45, 18, 7, outline)

	// Block courses and chipped highlights.
	rl.DrawRectangle(cx - 14, base - 34, 4, 29, stone)
	rl.DrawRectangle(cx - 13, base - 34, 1, 27, stone_hi)
	rl.DrawRectangle(cx + 10, base - 34, 4, 29, stone_d)
	rl.DrawRectangle(cx + 10, base - 33, 1, 26, stone_hi)
	rl.DrawRectangle(
		cx - 12,
		base - 40,
		4,
		6,
		stone_d,
	); rl.DrawRectangle(cx + 8, base - 40, 4, 6, stone)
	rl.DrawRectangle(cx - 8, base - 44, 16, 5, stone)
	rl.DrawRectangle(cx - 6, base - 43, 12, 1, stone_hi)
	rl.DrawRectangle(
		cx - 15,
		base - 4,
		6,
		3,
		stone_d,
	); rl.DrawRectangle(cx + 9, base - 4, 6, 3, stone_d)
	for i in 0 ..< 3 {
		y := base - 29 + i32(i) * 10
		rl.DrawRectangle(
			cx - 14,
			y,
			4,
			1,
			outline,
		); rl.DrawRectangle(cx + 10, y + 4, 4, 1, outline)
	}

	// Three inset rune stones animate by palette, not geometry.
	for i in 0 ..< 3 {
		rx := cx - 13 if i < 2 else cx + 10
		ry := base - 31 + i32(i) * 10
		if i == 2 do ry = base - 26
		rl.DrawRectangle(rx, ry, 3, 5, stone_d)
		draw_pixel_rune_mark(rx, ry, rune, i + int(tick / 6))
	}
	// Keystone with a bright single-pixel crown.
	rl.DrawRectangle(cx - 3, base - 44, 6, 5, stone_d)
	draw_pixel_rune_mark(cx - 2, base - 44, rune, int(tick / 5))
	if active && tick % 4 == 0 do rl.DrawRectangle(cx, base - 46, 1, 1, stone_hi)
}

draw_pixel_sky_gate :: proc(cx, base: i32, frame: u64, framed := true) {
	draw_pixel_gate_frame(cx, base, frame, true, true, framed)
}

draw_pixel_cave_gate :: proc(cx, base: i32, frame: u64, active: bool) {
	draw_pixel_gate_frame(cx, base, frame, false, active, true)
}

// The altar projects a round aperture rather than a door. Its circle is a
// deliberately stepped 36x36 sprite: dark sky-well, rotating block bands,
// four rune clasps and a broken cyan/stone rim.
draw_pixel_round_sky_portal :: proc(cx, cy: i32, frame: u64) {
	tick := i32(frame / 6)
	outline := rl.Color{18, 22, 35, 255}
	void := rl.Color{5, 10, 28, 245}
	deep := rl.Color{15, 48, 86, 245}
	blue := rl.Color{42, 145, 205, 240}
	rune := rl.Color{105, 225, 255, 255}
	hot := rl.Color{225, 250, 255, 255}
	stone := rl.Color{128, 153, 188, 255}
	stone_hi := rl.Color{196, 216, 236, 255}

	// Square additive breath and orbiting pixels keep the effect magical while
	// every visible edge remains aligned to the pixel grid.
	rl.BeginBlendMode(.ADDITIVE)
	rl.DrawRectangle(cx - 18, cy - 18, 36, 36, rl.Color{55, 175, 245, 24})
	rl.DrawRectangle(cx - 14, cy - 14, 28, 28, rl.Color{100, 220, 255, 32})
	for i in 0 ..< 8 {
		ii := i32(i)
		x := cx - 21 + (ii * 11 + tick * 3) % 43
		y := cy - 21 + (ii * 17 + tick * 2) % 43
		rl.DrawRectangle(
			x,
			y,
			1 + (ii + tick) % 2,
			1 + (ii + tick) % 2,
			rl.Color{120, 230, 255, u8(100 + (i % 3) * 45)},
		)
	}
	rl.EndBlendMode()

	// Stepped circular throat.
	rl.DrawRectangle(cx - 6, cy - 15, 12, 2, void)
	rl.DrawRectangle(cx - 11, cy - 13, 22, 3, void)
	rl.DrawRectangle(cx - 14, cy - 10, 28, 20, void)
	rl.DrawRectangle(cx - 11, cy + 10, 22, 3, void)
	rl.DrawRectangle(cx - 6, cy + 13, 12, 2, void)

	// Snapped bands circulate around a dark two-pixel eye. Alternating offsets
	// give clockwise motion without smooth rotation or blurred curves.
	for i in 0 ..< 6 {
		ii := i32(i)
		y := cy - 10 + ii * 4
		inset := abs(2 - ii)
		shift := (tick + ii * 2) % 5
		col := blue if (ii + tick / 2) % 3 != 0 else deep
		rl.DrawRectangle(cx - 11 + inset + shift / 2, y, 22 - inset * 2 - shift, 2, col)
		if (ii + tick) % 2 == 0 do rl.DrawRectangle(cx - 7 + shift, y - 1, 4, 1, hot)
	}
	rl.DrawRectangle(cx - 2, cy - 2, 4, 4, outline)
	rl.DrawRectangle(cx - 1, cy - 1, 2, 2, rl.Color{2, 5, 14, 255})

	// Broken octagonal rim: pale stone anchors, cyan energy joins.
	rl.DrawRectangle(
		cx - 7,
		cy - 18,
		14,
		3,
		outline,
	); rl.DrawRectangle(cx - 6, cy - 17, 12, 2, stone_hi)
	rl.DrawRectangle(
		cx - 13,
		cy - 16,
		7,
		4,
		outline,
	); rl.DrawRectangle(cx - 12, cy - 15, 6, 3, stone)
	rl.DrawRectangle(
		cx + 6,
		cy - 16,
		7,
		4,
		outline,
	); rl.DrawRectangle(cx + 6, cy - 15, 6, 3, stone)
	rl.DrawRectangle(
		cx - 17,
		cy - 12,
		4,
		7,
		outline,
	); rl.DrawRectangle(cx - 16, cy - 11, 3, 6, rune)
	rl.DrawRectangle(
		cx + 13,
		cy - 12,
		4,
		7,
		outline,
	); rl.DrawRectangle(cx + 13, cy - 11, 3, 6, rune)
	rl.DrawRectangle(
		cx - 18,
		cy - 5,
		3,
		10,
		outline,
	); rl.DrawRectangle(cx - 17, cy - 4, 2, 8, stone)
	rl.DrawRectangle(
		cx + 15,
		cy - 5,
		3,
		10,
		outline,
	); rl.DrawRectangle(cx + 15, cy - 4, 2, 8, stone)
	rl.DrawRectangle(cx - 17, cy + 5, 4, 7, outline); rl.DrawRectangle(cx - 16, cy + 5, 3, 6, rune)
	rl.DrawRectangle(cx + 13, cy + 5, 4, 7, outline); rl.DrawRectangle(cx + 13, cy + 5, 3, 6, rune)
	rl.DrawRectangle(
		cx - 13,
		cy + 12,
		7,
		4,
		outline,
	); rl.DrawRectangle(cx - 12, cy + 12, 6, 3, stone)
	rl.DrawRectangle(
		cx + 6,
		cy + 12,
		7,
		4,
		outline,
	); rl.DrawRectangle(cx + 6, cy + 12, 6, 3, stone)
	rl.DrawRectangle(
		cx - 7,
		cy + 15,
		14,
		3,
		outline,
	); rl.DrawRectangle(cx - 6, cy + 15, 12, 2, stone_hi)

	// Four cardinal rune clasps make the circle read as altar-bound machinery.
	for i in 0 ..< 4 {
		rx, ry := cx - 3, cy - 21
		switch i {
		case 1:
			rx = cx + 18; ry = cy - 3
		case 2:
			rx = cx - 3; ry = cy + 18
		case 3:
			rx = cx - 21; ry = cy - 3
		case:
		}
		rl.DrawRectangle(rx, ry, 6, 6, outline)
		draw_pixel_rune_mark(rx + 1, ry + 1, rune, i + int(tick / 5))
	}
	if tick % 4 == 0 do rl.DrawRectangle(cx + 8, cy - 16, 2, 1, hot)
	if tick % 4 == 2 do rl.DrawRectangle(cx - 11, cy + 15, 2, 1, hot)
}
