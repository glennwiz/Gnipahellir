package game

import rl "vendor:raylib"
import "core:mem"
import "core:os"

// ─── Editable Pixel Art ────────────────────────────────────────────────────────
//
//  A grid+palette alternative to the hand-written rl.DrawRectangle sequences in
//  render.odin's draw_pixel_* procs, editable at runtime via the F1 debug menu's
//  Pixel Art Editor (ui.odin/input.odin) and saved to its own file. A sprite
//  with no saved edit (has_data == false) falls back to its original procedural
//  draw_pixel_* proc — nothing changes until it's actually painted and saved.
//  Debug/dev tool only; not part of the player's Save_Data.

// Shared swatches, seeded from the colors already duplicated between
// draw_pixel_rune_scroll_chest, draw_pixel_crafting_bench and the smelter's
// static shell (render.odin) plus item_art.odin's shared ICON_* colors —
// "our colour palette", not invented.
PALETTE_SIZE :: 25

game_palette := [PALETTE_SIZE]rl.Color{
	{24, 20, 24, 255},    // 1  outline
	{42, 43, 49, 255},    // 2  iron dark
	{65, 67, 75, 255},    // 3  iron
	{122, 126, 136, 255}, // 4  iron light
	{74, 39, 24, 255},    // 5  wood dark
	{126, 68, 36, 255},   // 6  wood
	{174, 102, 54, 255},  // 7  wood light
	{124, 76, 24, 255},   // 8  brass dark
	{94, 94, 102, 255},   // 9  stone dark
	{130, 130, 136, 255}, // 10 stone
	{168, 168, 176, 255}, // 11 stone light
	{205, 172, 78, 255},  // 12 gold trim
	{110, 75, 45, 255},   // 13 wood dark (warm)
	{185, 145, 95, 255},  // 14 wood light (warm)
	rl.WHITE,             // 15 white
	rl.BLACK,             // 16 black
	{54, 56, 64, 255},    // 17 chest iron
	{108, 112, 122, 255}, // 18 chest iron light
	{22, 20, 22, 255},    // 19 smelter outline
	{55, 50, 53, 255},    // 20 brick dark
	{91, 82, 82, 255},    // 21 brick
	{132, 120, 113, 255}, // 22 brick light
	{47, 49, 56, 255},    // 23 smelter iron
	{105, 110, 120, 255}, // 24 smelter iron light
	{16, 12, 14, 255},    // 25 firebox black
}

// Append-only, mirrors the enum-array convention used for UI_Window etc.
// Extend by adding one entry here + one row in pixel_sprite_table + one
// call-site swap in render.odin (see context.md's pixel-art editor notes).
Pixel_Sprite_ID :: enum u8 {
	Rune_Scroll_Chest,
	Crafting_Bench,
	Smelter,
}

// Smelter's real static shell is 26x27 (see smelter_shell_rects, render.odin);
// a little headroom above that for future sprites.
PIXEL_GRID_MAX_W :: 28
PIXEL_GRID_MAX_H :: 28

// Cell value: 0 = empty/transparent, N = game_palette[N-1].
Pixel_Grid :: [PIXEL_GRID_MAX_H][PIXEL_GRID_MAX_W]u8

// Real authored size + the (bx,by)-relative origin its original draw_pixel_*
// proc used, so draw_pixel_grid_sprite can reproduce the same placement.
Pixel_Sprite_Info :: struct {
	name:          string,
	w, h:          u8,
	ox_off, oy_off: i8,
}

pixel_sprite_table := [Pixel_Sprite_ID]Pixel_Sprite_Info{
	.Rune_Scroll_Chest = {"Rune Scroll Chest", 16, 11, -3, -1},
	.Crafting_Bench  = {"Crafting Bench", 20, 14, -5, -4},
	// Only the static furnace shell is grid-editable — the fire, smoke,
	// fuel/ore/output and progress bar stay procedural (draw_pixel_smelter_dynamic,
	// render.odin) since they're driven by live Sim_Tile_Data, not decoration.
	.Smelter         = {"Smelter (shell only)", 26, 27, -7, -14},
}

Pixel_Sprite_Data :: struct {
	has_data: bool,
	grid:     Pixel_Grid,
}

Pixel_Art_Store :: struct {
	sprites: [Pixel_Sprite_ID]Pixel_Sprite_Data,
}

// Render-only: reads gs.pixel_art + pixel_sprite_table, never mutates.
draw_pixel_grid_sprite :: proc(gs: ^Game_State, id: Pixel_Sprite_ID, bx, by: i32) {
	data := &gs.pixel_art.sprites[id]
	if !data.has_data do return
	info := pixel_sprite_table[id]
	ox := bx + i32(info.ox_off)
	oy := by + i32(info.oy_off)
	for row in 0 ..< int(info.h) {
		for col in 0 ..< int(info.w) {
			v := data.grid[row][col]
			if v == 0 do continue
			rl.DrawRectangle(ox + i32(col), oy + i32(row), 1, 1, game_palette[v - 1])
		}
	}
}

// ─── Shell rect tables (shared by a live procedural draw AND grid seeding) ────
//
//  A sprite's static shell can be described once as a list of rects (grid-
//  relative x/y/w/h + a 1-based game_palette index) and driven two ways:
//  draw_shell_rects paints it live (the render.odin fallback), seed_shell_rects
//  bakes the identical picture into a Pixel_Grid so the editor can preview —
//  and start an edit from — the real look instead of a blank canvas.

Shell_Rect :: struct {
	x, y, w, h: i32,
	pal:        u8,
}

draw_shell_rects :: proc(rects: []Shell_Rect, ox, oy: i32) {
	for r in rects {
		rl.DrawRectangle(ox + r.x, oy + r.y, r.w, r.h, game_palette[r.pal - 1])
	}
}

grid_fill_rect :: proc(grid: ^Pixel_Grid, gx, gy, gw, gh: i32, pal_idx: u8) {
	for row in gy ..< gy + gh {
		if row < 0 || row >= PIXEL_GRID_MAX_H do continue
		for col in gx ..< gx + gw {
			if col < 0 || col >= PIXEL_GRID_MAX_W do continue
			grid[row][col] = pal_idx
		}
	}
}

seed_shell_rects :: proc(rects: []Shell_Rect, grid: ^Pixel_Grid) {
	for r in rects {
		grid_fill_rect(grid, r.x, r.y, r.w, r.h, r.pal)
	}
}

// A read-only preview of a sprite's real original look, used by the editor
// when has_data == false so it never opens on a blank canvas. Never written
// into gs.pixel_art directly — a paint stroke copies it in as the base first
// (input.odin), so merely opening the editor changes nothing.
seed_pixel_grid :: proc(id: Pixel_Sprite_ID) -> Pixel_Grid {
	grid: Pixel_Grid
	switch id {
	case .Rune_Scroll_Chest: seed_rune_scroll_chest_grid(&grid)
	case .Crafting_Bench:  seed_crafting_bench_grid(&grid)
	case .Smelter:         seed_shell_rects(smelter_shell_rects, &grid)
	}
	return grid
}

// Mirrors draw_pixel_rune_scroll_chest (render.odin), skipping only the
// translucent ambient glow (not a flat pixel) and using a neutral gold
// placeholder for the tier-specific rune-lock accent (real chests are bronze/
// silver/gold; the grid is shared across all three once edited).
seed_rune_scroll_chest_grid :: proc(grid: ^Pixel_Grid) {
	outline, iron, iron_hi := u8(1), u8(17), u8(18)
	wood_d, wood, wood_hi  := u8(5), u8(6), u8(7)
	accent, white          := u8(12), u8(15)
	grid_fill_rect(grid, 2, 0, 12, 1, outline)
	grid_fill_rect(grid, 1, 1, 14, 3, outline)
	grid_fill_rect(grid, 0, 4, 16, 6, outline)
	grid_fill_rect(grid, 1, 10, 3, 1, outline)
	grid_fill_rect(grid, 12, 10, 3, 1, outline)
	grid_fill_rect(grid, 2, 1, 12, 1, wood_hi)
	grid_fill_rect(grid, 1, 2, 14, 2, wood)
	grid_fill_rect(grid, 1, 4, 14, 5, wood)
	grid_fill_rect(grid, 1, 6, 14, 1, wood_hi)
	grid_fill_rect(grid, 1, 8, 14, 1, wood_d)
	grid_fill_rect(grid, 3, 3, 10, 1, wood_d)
	grid_fill_rect(grid, 1, 4, 14, 2, iron)
	grid_fill_rect(grid, 1, 4, 14, 1, iron_hi)
	for sx in ([3]i32{2, 7, 12}) {
		grid_fill_rect(grid, sx, 1, 2, 8, iron)
		grid_fill_rect(grid, sx, 2, 1, 6, iron_hi)
	}
	grid_fill_rect(grid, 2, 5, 1, 1, iron_hi)
	grid_fill_rect(grid, 13, 5, 1, 1, iron_hi)
	grid_fill_rect(grid, 2, 8, 1, 1, iron_hi)
	grid_fill_rect(grid, 13, 8, 1, 1, iron_hi)
	grid_fill_rect(grid, 6, 4, 4, 4, outline)
	grid_fill_rect(grid, 7, 5, 2, 2, accent)
	grid_fill_rect(grid, 6, 6, 4, 1, accent)
	grid_fill_rect(grid, 8, 5, 1, 1, white)
}

// Mirrors draw_pixel_crafting_bench (render.odin), skipping the translucent
// halo and approximating the pulsing brass/hot rune-boss highlight with the
// static brass-dark/gold-trim swatches.
seed_crafting_bench_grid :: proc(grid: ^Pixel_Grid) {
	outline                := u8(1)
	iron_d, iron, iron_hi  := u8(2), u8(3), u8(4)
	wood_d, wood, wood_hi  := u8(5), u8(6), u8(7)
	brass_d, gold          := u8(8), u8(12)
	grid_fill_rect(grid, 0, 3, 20, 5, outline)
	grid_fill_rect(grid, 2, 7, 16, 4, outline)
	grid_fill_rect(grid, 2, 8, 5, 6, outline)
	grid_fill_rect(grid, 13, 8, 5, 6, outline)
	grid_fill_rect(grid, 5, 11, 10, 3, outline)
	grid_fill_rect(grid, 1, 4, 18, 3, wood)
	grid_fill_rect(grid, 2, 4, 16, 1, wood_hi)
	grid_fill_rect(grid, 1, 6, 18, 1, wood_d)
	grid_fill_rect(grid, 6, 4, 1, 2, wood_d)
	grid_fill_rect(grid, 14, 4, 1, 2, wood_d)
	grid_fill_rect(grid, 8, 5, 4, 1, wood_hi)
	grid_fill_rect(grid, 3, 7, 14, 3, wood_d)
	grid_fill_rect(grid, 4, 7, 12, 1, wood)
	grid_fill_rect(grid, 3, 9, 4, 4, wood)
	grid_fill_rect(grid, 14, 9, 3, 4, wood)
	grid_fill_rect(grid, 4, 9, 1, 3, wood_hi)
	grid_fill_rect(grid, 16, 9, 1, 3, wood_d)
	grid_fill_rect(grid, 6, 12, 8, 1, wood)
	grid_fill_rect(grid, 6, 13, 8, 1, wood_d)
	grid_fill_rect(grid, 0, 3, 3, 4, iron)
	grid_fill_rect(grid, 17, 3, 3, 4, iron)
	grid_fill_rect(grid, 1, 3, 2, 1, iron_hi)
	grid_fill_rect(grid, 17, 3, 2, 1, iron_hi)
	grid_fill_rect(grid, 2, 12, 5, 2, iron_d)
	grid_fill_rect(grid, 13, 12, 5, 2, iron_d)
	grid_fill_rect(grid, 3, 12, 3, 1, iron_hi)
	grid_fill_rect(grid, 14, 12, 3, 1, iron_hi)
	grid_fill_rect(grid, 1, 5, 1, 1, iron_hi)
	grid_fill_rect(grid, 18, 5, 1, 1, iron_hi)
	grid_fill_rect(grid, 4, 12, 1, 1, iron_hi)
	grid_fill_rect(grid, 15, 12, 1, 1, iron_hi)
	grid_fill_rect(grid, 0, 1, 6, 3, outline)
	grid_fill_rect(grid, 1, 1, 4, 2, iron)
	grid_fill_rect(grid, 1, 1, 3, 1, iron_hi)
	grid_fill_rect(grid, 0, 2, 2, 5, outline)
	grid_fill_rect(grid, 1, 3, 1, 3, iron)
	grid_fill_rect(grid, 0, 5, 4, 1, iron_d)
	grid_fill_rect(grid, 0, 4, 1, 3, iron_hi)
	grid_fill_rect(grid, 10, 0, 5, 4, outline)
	grid_fill_rect(grid, 11, 1, 3, 2, wood)
	grid_fill_rect(grid, 11, 1, 2, 1, wood_hi)
	grid_fill_rect(grid, 13, 1, 1, 2, wood_d)
	grid_fill_rect(grid, 10, 1, 1, 2, iron)
	grid_fill_rect(grid, 14, 2, 5, 2, outline)
	grid_fill_rect(grid, 14, 2, 4, 1, wood_hi)
	grid_fill_rect(grid, 15, 3, 4, 1, wood_d)
	grid_fill_rect(grid, 8, 6, 5, 5, outline)
	grid_fill_rect(grid, 9, 7, 3, 3, brass_d)
	grid_fill_rect(grid, 9, 8, 3, 1, gold)
	grid_fill_rect(grid, 10, 7, 1, 3, gold)
	grid_fill_rect(grid, 11, 7, 1, 1, gold)
}

// ─── Persistence ────────────────────────────────────────────────────────────
//
//  Same raw-binary-to-disk pattern as save.odin/Settings_Data, but a separate
//  file from the player's save: this is dev asset data, not run state. A
//  missing file, a length mismatch, or a version bump just leaves every
//  sprite has_data == false, so rendering falls back to the original
//  procedural draw_pixel_* procs — no player-facing failure mode.

PIXEL_ART_FILE    :: "pixel_art.dat"
PIXEL_ART_VERSION :: i32(1)

Pixel_Art_Save_Data :: struct {
	version: i32,
	store:   Pixel_Art_Store,
}

save_pixel_art :: proc(gs: ^Game_State) -> bool {
	return save_pixel_art_to(gs, PIXEL_ART_FILE)
}

load_pixel_art :: proc(gs: ^Game_State) -> bool {
	return load_pixel_art_from(gs, PIXEL_ART_FILE)
}

// Path-parameterized so tests can round-trip through a scratch file instead
// of Glenn's real pixel_art.dat.
save_pixel_art_to :: proc(gs: ^Game_State, path: string) -> bool {
	sd := new(Pixel_Art_Save_Data)
	defer free(sd)
	sd.version = PIXEL_ART_VERSION
	sd.store   = gs.pixel_art
	return os.write_entire_file(path, mem.ptr_to_bytes(sd)) == nil
}

load_pixel_art_from :: proc(gs: ^Game_State, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return false
	defer delete(data)
	if len(data) != size_of(Pixel_Art_Save_Data) do return false
	sd := new(Pixel_Art_Save_Data)
	defer free(sd)
	mem.copy(sd, raw_data(data), size_of(Pixel_Art_Save_Data))
	if sd.version != PIXEL_ART_VERSION do return false
	gs.pixel_art = sd.store
	return true
}
