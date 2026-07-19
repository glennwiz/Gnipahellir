package game

import rl "vendor:raylib/v55"

// ─── Sprite Atlas ─────────────────────────────────────────────────────────────
//
//  Tile art lives in a packed atlas (sprites/gnipahellir_tiles_atlas.png,
//  described by the sibling .json).  Uniform ATLAS_CELL cells, 8 per row.
//  Tile_Sprite's order MATCHES the atlas json exactly — the cell rect is
//  derived from the ordinal, so keep them in sync.  Tiles the atlas doesn't
//  cover fall back to the procedural draw_pixel_* / solid path in draw_tile.

TILE_ATLAS_FILE :: "sprites/gnipahellir_tiles_atlas.png"
ATLAS_CELL :: 80 // px per cell (atlas json "tile_size")
ATLAS_COLS :: 8

// Gray wash painted over stone tiles so the whole cave reads gray and the atlas
// texture only shines faintly through.  The alpha (4th component) is the knob:
// 0 = pure texture, 255 = flat gray.
STONE_TINT :: rl.Color{110, 110, 118, 120}

Tile_Sprite :: enum u8 {
	// row 0 + row 1 start: 10 stone variants
	Granite,
	Slate,
	Sandstone,
	Basalt,
	Marble,
	Mossy_Stone,
	Cracked_Stone,
	Cobblestone,
	Brickstone,
	Obsidian,
	// 5 wood
	Oak,
	Birch,
	Mahogany,
	Pine,
	Charred_Wood,
	// 3 ore
	Gold_Ore,
	Silver_Ore,
	Iron_Ore,
	// 4 liquids / special
	Lava,
	Magic_Lava,
	Water,
	Void,
}

Assets :: struct {
	loaded:     bool,
	tile_atlas: rl.Texture2D,
}

assets_init :: proc(a: ^Assets) {
	tex := rl.LoadTexture(TILE_ATLAS_FILE)
	if tex.id == 0 do return // missing atlas: stay on the procedural draw path
	rl.SetTextureFilter(tex, .POINT) // pixel art: no bilinear smear
	a.tile_atlas = tex
	a.loaded = true
}

assets_shutdown :: proc(a: ^Assets) {
	if !a.loaded do return
	rl.UnloadTexture(a.tile_atlas)
	a.loaded = false
}

// Source rect of a sprite cell, derived from its ordinal (row-major, 8 cols).
tile_atlas_rect :: proc(s: Tile_Sprite) -> rl.Rectangle {
	i := int(s)
	return {
		f32((i % ATLAS_COLS) * ATLAS_CELL),
		f32((i / ATLAS_COLS) * ATLAS_CELL),
		ATLAS_CELL,
		ATLAS_CELL,
	}
}

// Which atlas cell paints tile t at grid (x, y).  ok=false → not in the atlas,
// caller keeps its existing draw.  Stone picks a variant by depth/biome; wood
// picks one at random per tile (both per Glenn, 2026-07-05).
tile_sprite :: proc(gs: ^Game_State, t: Tile_Type, x, y: int) -> (Tile_Sprite, bool) {
	#partial switch t {
	case .Stone:
		return stone_variant(gs.level_index, y), true
	case .Wood:
		return wood_variant(x, y), true
	case .Iron_Ore:
		return .Iron_Ore, true
	case .Silver_Ore:
		return .Silver_Ore, true
	case .Gold_Ore:
		return .Gold_Ore, true
	case .Lava:
		return .Lava, true
	case .Magic_Lava:
		return .Magic_Lava, true
	case .Water:
		return .Water, true
	}
	return .Granite, false
}

// Deeper = darker/harder rock; each level is its own biome.  Bands are y in
// tiles (GRID_H 108, SURFACE_Y 54) — tune to taste.
stone_variant :: proc(level_index: int, y: int) -> Tile_Sprite {
	switch level_index {
	case LEVEL_SURFACE:
		// surface crust → cave 1
		if y < SURFACE_Y + 12 do return .Sandstone
		if y < 84 do return .Granite
		return .Cracked_Stone
	case LEVEL_CAVE2:
		if y < 36 do return .Slate
		if y < 72 do return .Cobblestone
		return .Basalt
	case LEVEL_CAVE3:
		// Gnipahellir — the hellish deep
		if y < 36 do return .Basalt
		if y < 72 do return .Brickstone
		return .Obsidian
	case LEVEL_SKY:
		if y < 40 do return .Marble
		return .Mossy_Stone
	}
	return .Granite
}

// One of the 5 wood cells, hashed off the tile so a wall of planks reads varied
// but stays stable frame to frame.
wood_variant :: proc(x, y: int) -> Tile_Sprite {
	h := whash(u32(x) * 374761393) ~ whash(u32(y) * 668265263)
	return Tile_Sprite(int(Tile_Sprite.Oak) + int(h % 5))
}
