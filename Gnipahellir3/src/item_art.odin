package game

import rl "vendor:raylib"

// ─── Item Pixel Art ───────────────────────────────────────────────────────────
//
//  Every item icon is a 12x12 character grid drawn as chunky pixels — same
//  flat, no-gradient style as the tile atlas.  Table-driven: one Item_Icon per
//  Item in item_icons; tiered gear reuses a shape grid with a tier palette
//  (iron/silver/gold/runic), so a new tier is one palette line, not new art.
//
//  Grid characters resolve through the icon's palette first, then the shared
//  colors in icon_pixel:
//      B D L A a   base / dark / light / accent / accent2 (per-icon palette)
//      W h H g S s t   white, wood dark/light, gold trim, stone base/dark/light
//      .               transparent
//
//  draw_item_icon is render-side only: reads tables, never touches Game_State.

ICON_GRID :: 12

Icon_Grid :: [ICON_GRID]string

Icon_Palette :: struct {
	base, dark, light, accent, accent2: rl.Color,
}

// Shared colors (grid chars without a palette slot).
ICON_WOOD_DARK   :: rl.Color{110, 75, 45, 255}
ICON_WOOD_LIGHT  :: rl.Color{185, 145, 95, 255}
ICON_GOLD_TRIM   :: rl.Color{205, 172, 78, 255}
ICON_STONE       :: rl.Color{130, 130, 136, 255}
ICON_STONE_DARK  :: rl.Color{94, 94, 102, 255}
ICON_STONE_LIGHT :: rl.Color{168, 168, 176, 255}


// ─── Per-item icon table (grid + palette) ─────────────────────────────────────

Item_Icon :: struct {
	grid: Icon_Grid,
	pal:  Icon_Palette,
}

// ─── Drawing ─────────────────────────────────────────────────────────────────

// Resolve one grid character: the icon palette's slots first, shared colors
// second.  ok=false → transparent, draw nothing.
icon_pixel :: proc(pal: Icon_Palette, ch: u8) -> (col: rl.Color, ok: bool) {
	switch ch {
	case 'B': col = pal.base
	case 'D': col = pal.dark
	case 'L': col = pal.light
	case 'A': col = pal.accent
	case 'a': col = pal.accent2
	case 'W': col = rl.WHITE
	case 'h': col = ICON_WOOD_DARK
	case 'H': col = ICON_WOOD_LIGHT
	case 'g': col = ICON_GOLD_TRIM
	case 'S': col = ICON_STONE
	case 's': col = ICON_STONE_DARK
	case 't': col = ICON_STONE_LIGHT
	case:     return {}, false // '.' and anything unmapped
	}
	return col, col.a != 0
}

// Item icon for UI: the item's pixel grid scaled to a size x size box.
// alpha dims the whole icon (crafting results that aren't craftable yet).
// Items without art fall back to the old flat item_table color.
draw_item_icon :: proc(it: Item, x, y, size: i32, alpha: u8 = 255) {
	icon := &item_icons[it]
	if icon.grid[0] == "" {
		col := item_table[it].color
		col.a = min(col.a, alpha)
		rl.DrawRectangle(x, y, size, size, col)
		return
	}
	cell := f32(size) / ICON_GRID
	for row, gy in icon.grid {
		for gx in 0 ..< len(row) {
			col, ok := icon_pixel(icon.pal, row[gx])
			if !ok do continue
			col.a = alpha
			rl.DrawRectangleRec(
				{f32(x) + f32(gx) * cell, f32(y) + f32(gy) * cell, cell, cell},
				col,
			)
		}
	}
}
