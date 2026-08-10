package gnipa_studio

// TILES tab (studio_tiles.md T2): the world palette on one screen.
// Browser = one color swatch per Tile_Type (tiles have no icons — the flat
// color IS the art); inspector joins all four gen_terrain tables into one
// card: behavior row, hover desc, structure badge, station glow.
// Read-only — editing + SAVE is Phase T3.

import "core:fmt"
import game "../../src"
import rl "vendor:raylib"

tiles_frame :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	// Browser grid: every tile, enum order, click to select.
	gy := i32(TOP_BAR) + 16
	hovered := false
	hovered_tile: game.Tile_Type
	for t in game.Tile_Type {
		idx := int(t)
		cx := i32(BROWSER_X + (idx % BROWSER_COLS) * BCELL)
		cy := gy + i32(idx / BROWSER_COLS) * BCELL
		cell := rl.Rectangle{f32(cx), f32(cy), BCELL, BCELL}
		hov := rl.CheckCollisionPointRec(mouse, cell)
		if hov {
			hovered = true
			hovered_tile = t
		}
		if hov && rl.IsMouseButtonPressed(.LEFT) do s.sel_tile = t
		if t == s.sel_tile {
			rl.DrawRectangleRec(cell, {45, 48, 58, 255})
			rl.DrawRectangleLinesEx(cell, 2, {245, 205, 90, 255})
		} else if hov {
			rl.DrawRectangleLinesEx(cell, 1, {150, 155, 165, 255})
		}
		// Checker under the swatch so translucent fluids/gas read as such.
		draw_checker(cx + (BCELL-BICON)/2, cy + (BCELL-BICON)/2, BICON, BICON)
		rl.DrawRectangle(cx + (BCELL-BICON)/2, cy + (BCELL-BICON)/2, BICON, BICON, game.terrain_table[t].color)
	}
	if hovered {
		rl.DrawText(fmt.ctprintf("%s  (.%v, ordinal %d)", game.terrain_table[hovered_tile].name, hovered_tile, int(hovered_tile)),
			BROWSER_X, i32(sh) - 26, 14, {200, 203, 210, 255})
	}

	tile_inspector_frame(s, f32(BROWSER_X + BROWSER_COLS*BCELL + 28), sw, sh)
}

tile_inspector_frame :: proc(s: ^Studio, x0, sw, sh: f32) {
	t := s.sel_tile
	beh := game.terrain_table[t]
	x := i32(x0)
	y := i32(TOP_BAR) + 20

	rl.DrawText(fmt.ctprintf("%s", beh.name), x, y, 26, {235, 235, 240, 255})
	rl.DrawText(fmt.ctprintf(".%v  (ordinal %d)", t, int(t)), x, y + 30, 12, {120, 125, 138, 255})
	y += 56

	// The terrain color at three scales on a checker — the tile's whole art.
	px := x
	for size in ([3]i32{24, 48, 96}) {
		draw_checker(px, y, size + 12, 108)
		rl.DrawRectangle(px + 6, y + (108 - size)/2, size, size, beh.color)
		px += size + 24
	}
	rl.DrawText(fmt.ctprintf("color %d,%d,%d,%d", beh.color.r, beh.color.g, beh.color.b, beh.color.a), px, y + 4, 12, {150, 155, 165, 255})
	if game.is_structure_tile[t] {
		rl.DrawText("STRUCTURE", px, y + 28, 14, {245, 205, 90, 255})
		rl.DrawText("wand-safe; reclaim", px, y + 46, 11, {150, 155, 165, 255})
		rl.DrawText("with the pick", px, y + 60, 11, {150, 155, 165, 255})
	}
	if glow := game.station_glow[t]; glow != {} {
		rl.DrawRectangle(px, y + 80, 14, 14, glow)
		rl.DrawText(fmt.ctprintf("glow %d,%d,%d", glow.r, glow.g, glow.b), px + 20, y + 82, 12, {150, 155, 165, 255})
	}
	y += 124

	// Flags as a read-only checkbox row (T3 makes these toggles).
	rl.DrawText("FLAGS", x, y, 13, {245, 205, 90, 255})
	y += 20
	cx := x
	for f in game.Terrain_Flag {
		on := f in beh.flags
		label := fmt.ctprintf("%v", f)
		w := rl.MeasureText(label, 13) + 34
		if cx + w > i32(sw) - 24 {
			cx = x
			y += 22
		}
		rl.DrawRectangleLinesEx({f32(cx), f32(y), 14, 14}, 1, on ? rl.Color{245, 205, 90, 255} : rl.Color{80, 84, 96, 255})
		if on do rl.DrawRectangle(cx + 3, y + 3, 8, 8, {245, 205, 90, 255})
		rl.DrawText(label, cx + 20, y + 1, 13, on ? rl.Color{225, 228, 235, 255} : rl.Color{100, 104, 116, 255})
		cx += w
	}
	y += 30

	kv :: proc(x: i32, y: ^i32, label, value: string, vcol := rl.Color{225, 228, 235, 255}) {
		rl.DrawText(fmt.ctprintf("%s", label), x, y^, 12, {120, 125, 138, 255})
		rl.DrawText(fmt.ctprintf("%s", value), x + 110, y^, 12, vcol)
		y^ += 20
	}

	kv(x, &y, "move cost", fmt.tprintf("%s%s", f32_str(beh.move_cost), beh.move_cost == 0 ? "  (solid)" : ""))
	if beh.damage_per_second > 0 {
		kv(x, &y, "damage/s", f32_str(beh.damage_per_second), {235, 120, 110, 255})
	}
	y += 6

	// Drop item as its real icon — click it to jump to the ITEMS tab.
	if beh.drop_item == .None {
		kv(x, &y, "drops", "-  (nothing)", {150, 155, 165, 255})
	} else {
		rl.DrawText("drops", x, y + 8, 12, {120, 125, 138, 255})
		cell := rl.Rectangle{f32(x + 110), f32(y), 32, 32}
		hov := rl.CheckCollisionPointRec(rl.GetMousePosition(), cell)
		if hov && rl.IsMouseButtonPressed(.LEFT) {
			s.selected = beh.drop_item
			s.tab = .Items
		}
		draw_checker(x + 110, y, 32, 32)
		game.draw_item_icon(beh.drop_item, x + 112, y + 2, 28)
		if hov do rl.DrawRectangleLinesEx(cell, 1, {245, 205, 90, 255})
		pct := beh.drop_pct == 0 ? "always" : fmt.tprintf("%d%% chance", beh.drop_pct)
		rl.DrawText(fmt.ctprintf("%s  (%s)", item_name(beh.drop_item), pct), x + 150, y + 8, 13,
			hov ? rl.Color{245, 205, 90, 255} : rl.Color{140, 185, 225, 255})
		y += 40
	}
	y += 12

	// The hover line the player sees, wrapped; sparse terrain_desc rows fall
	// back to the drop item's desc (tile_desc), flagged when they do.
	desc := game.terrain_desc[t]
	from_drop := desc == ""
	if from_drop do desc = game.tile_desc(t)
	if desc != "" {
		for l in wrap_text(desc, i32(sw - x0) - 32, 13) {
			rl.DrawText(fmt.ctprintf("%s", l), x, y, 13, {200, 203, 210, 255})
			y += 19
		}
		if from_drop {
			rl.DrawText("(no terrain_desc row - drop item's desc)", x, y, 11, {120, 125, 138, 255})
			y += 17
		}
	}
}
