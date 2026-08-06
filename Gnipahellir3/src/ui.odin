package game

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

// ─── UI Layout (virtual-resolution pixels) ────────────────────────────────────
//
//  Constants shared by draw procs here and hit-testing in input.odin.

INV_COLS :: 8
INV_ROWS :: 3
SLOT_PX :: 44

// The inventory is a near-centered popup (nudged left so the crafting list
// fits beside it on the UI canvas): header, then a paperdoll column of
// equip slots on the left and the bag grid to its right.
INV_PANEL_W :: 24 + 100 + 16 + INV_COLS * SLOT_PX + 24
INV_PANEL_H :: 600
INV_PANEL_X :: (UI_W - INV_PANEL_W) / 2 - 40 // default position (draggable)
INV_PANEL_Y :: (UI_H - INV_PANEL_H) / 2

// Crafting: a two-column "forge" panel right of the inventory popup — a grid of
// recipe cards on the left, a detail + CRAFT panel on the right.
CRAFT_X :: INV_PANEL_X + INV_PANEL_W + 8 // default panel corner (draggable)
CRAFT_Y :: 130
CRAFT_COLS     :: 4                       // recipe cards per row
CRAFT_CARD     :: SLOT_PX                 // card = one item slot (44)
CRAFT_CARD_GAP :: 8
CRAFT_GRID_W   :: CRAFT_COLS * (CRAFT_CARD + CRAFT_CARD_GAP)   // 208
CRAFT_DETAIL_W :: 210                     // right-hand detail column
CRAFT_PAD      :: 12
CRAFT_PANEL_W  :: CRAFT_PAD + CRAFT_GRID_W + 14 + CRAFT_DETAIL_W + CRAFT_PAD  // 466
CRAFT_PANEL_H  :: 400
CRAFT_BTN_W    :: CRAFT_DETAIL_W - 16
CRAFT_BTN_H    :: 34

// Equipment boxes — weapon, dedicated pick, armor head→feet, then a 3-slot charm belt.
EQUIP_STEP :: 50

@(rodata)
equip_slot_order := [10]Equip_Slot{
	.Weapon, .Tool, .Head, .Chest, .Hands, .Legs, .Feet, .Charm, .Charm_2, .Charm_3,
}

@(rodata)
equip_slot_labels := [10]cstring{
	"WPN", "PICK", "HEAD", "CHEST", "HANDS", "LEGS", "FEET", "CHM1", "CHM2", "CHM3",
}

// Blueprint overlay — centered panel.
BP_W :: 540
BP_H :: 360
BP_X :: (UI_W - BP_W) / 2 // default position (draggable)
BP_Y :: (UI_H - BP_H) / 2

// Smelter window — the furnace fire, the ground cells beside it, the tray.
SMELT_W :: 250
SMELT_H :: 360
SMELT_X :: 140 // default position (draggable)
SMELT_Y :: 180

// Barrel window — a 4×4 grid of bag-style slots.
BARREL_PAD :: 20
BARREL_GRID_Y :: 56  // content top, below the title band
BARREL_W :: BARREL_PAD * 2 + BARREL_COLS * SLOT_PX          // 40 + 176 = 216
BARREL_H :: BARREL_GRID_Y + BARREL_ROWS * SLOT_PX + 28      // header + grid + footer
BARREL_X :: 420 // default position (draggable)
BARREL_Y :: 200

// Selected-block chip — a bottom-center HUD slot showing what right-click will
// place (icon + count).  Clicking it opens the bag.
SEL_CHIP   :: 52
SEL_CHIP_X :: (UI_W - SEL_CHIP) / 2
SEL_CHIP_Y :: UI_H - 70

GOLEM_CMD_X :: i32(18)
GOLEM_CMD_Y :: i32(UI_H - 112)
GOLEM_CMD_W :: i32(390)
GOLEM_CMD_H :: i32(66)
GOLEM_PLAN_W :: i32(104)

// ─── Floating Windows (draggable) ─────────────────────────────────────────────
//
//  Each floating window's top-left lives in UI_State.win_pos (defaults below);
//  grabbing the top WINDOW_HEADER_H band drags it.  Full-screen modals (menu,
//  settings, title, death) are not windows and stay fixed.

UI_Window :: enum u8 {
	Inventory,
	Crafting,
	Smelter,
	Barrel,
	Blueprint,
}

WINDOW_HEADER_H :: 40

@(rodata)
default_window_pos := [UI_Window][2]i32 {
	.Inventory = {INV_PANEL_X, INV_PANEL_Y},
	.Crafting  = {CRAFT_X, CRAFT_Y},
	.Smelter   = {SMELT_X, SMELT_Y},
	.Barrel    = {BARREL_X, BARREL_Y},
	.Blueprint = {BP_X, BP_Y},
}

// draw_ui stacks windows in enum order; drag hit-testing walks this top-down.
@(rodata)
window_top_down := [5]UI_Window{.Blueprint, .Barrel, .Smelter, .Crafting, .Inventory}

// Outer bounds of a floating window at its current position, and whether it
// is open.  Crafting's height tracks its recipe list.
window_rect :: proc(gs: ^Game_State, w: UI_Window) -> (x, y, ww, wh: i32, open: bool) {
	p := gs.ui.win_pos[w]
	switch w {
	case .Inventory:
		return p.x, p.y, INV_PANEL_W, INV_PANEL_H, gs.ui.show_inventory
	case .Crafting:
		return p.x, p.y, CRAFT_PANEL_W, CRAFT_PANEL_H, gs.ui.show_crafting
	case .Smelter:
		return p.x, p.y, SMELT_W, SMELT_H, gs.ui.show_smelter
	case .Barrel:
		return p.x, p.y, BARREL_W, BARREL_H, gs.ui.show_barrel
	case .Blueprint:
		return p.x, p.y, BP_W, BP_H, gs.ui.show_blueprint
	}
	return
}

// Snap the bag+forge to a centered pair so the crafting panel doesn't spill off
// the right edge.  Called when crafting opens beside the inventory (hotkey or
// station).  A window the player has hand-dragged (win_moved) keeps its spot.
place_craft_pair :: proc(gs: ^Game_State) {
	total := i32(INV_PANEL_W + 8 + CRAFT_PANEL_W)
	left  := (i32(UI_W) - total) / 2
	if !gs.ui.win_moved[.Inventory] do gs.ui.win_pos[.Inventory] = {left, INV_PANEL_Y}
	if !gs.ui.win_moved[.Crafting]  do gs.ui.win_pos[.Crafting]  = {left + INV_PANEL_W + 8, CRAFT_Y}
}

// Center the bag on its own (TAB with nothing else open), unless hand-placed.
place_bag_centered :: proc(gs: ^Game_State) {
	if gs.ui.win_moved[.Inventory] do return
	gs.ui.win_pos[.Inventory] = {(UI_W - INV_PANEL_W) / 2, INV_PANEL_Y}
}

// True when the cursor is inside an open window's bounds.
cursor_in_window :: proc(gs: ^Game_State, w: UI_Window) -> bool {
	x, y, ww, wh, open := window_rect(gs, w)
	if !open do return false
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	return mx >= x && mx < x + ww && my >= y && my < y + wh
}

// The topmost open window whose bounds contain the cursor, honoring the same
// stacking order window-header drags use — where two windows' rects overlap
// (e.g. a chest drawn over the bag), the one drawn on top claims the point.
window_at_cursor :: proc(gs: ^Game_State) -> (w: UI_Window, ok: bool) {
	for win in window_top_down {
		if cursor_in_window(gs, win) do return win, true
	}
	return {}, false
}

// Runtime content origins, derived from the window position.
inv_bag_origin :: proc(gs: ^Game_State) -> (x, y: i32) {
	p := gs.ui.win_pos[.Inventory]
	return p.x + 140, p.y + 70
}

equip_origin :: proc(gs: ^Game_State) -> (x, y: i32) {
	p := gs.ui.win_pos[.Inventory]
	return p.x + 24, p.y + 70
}

// Content origin of the crafting window (win_pos is the panel corner; the
// title band above the content is 28px).
craft_origin :: proc(gs: ^Game_State) -> (x, y: i32) {
	p := gs.ui.win_pos[.Crafting]
	return p.x + CRAFT_PAD, p.y + 28
}

// Top-left of recipe card `slot` (0-based, laid out row-major in the grid).
craft_card_rect :: proc(gs: ^Game_State, slot: int) -> (x, y: i32) {
	cx, cy := craft_origin(gs)
	col := i32(slot % CRAFT_COLS)
	row := i32(slot / CRAFT_COLS)
	return cx + col * (CRAFT_CARD + CRAFT_CARD_GAP), cy + 6 + row * (CRAFT_CARD + CRAFT_CARD_GAP)
}

// Recipe-table index of the card under the cursor, or -1.
craft_card_at_cursor :: proc(gs: ^Game_State) -> int {
	if !gs.ui.show_crafting do return -1
	vis: [len(recipe_table)]int
	n := visible_recipes(gs, &vis)
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	for slot in 0 ..< n {
		x, y := craft_card_rect(gs, slot)
		if mx >= x && mx < x + CRAFT_CARD && my >= y && my < y + CRAFT_CARD do return vis[slot]
	}
	return -1
}

// The CRAFT button rect in the detail column (aligned with the detail content
// origin used in draw_crafting: cx + CRAFT_GRID_W + 16).
craft_button_rect :: proc(gs: ^Game_State) -> (x, y: i32) {
	cx, cy := craft_origin(gs)
	detx := cx + CRAFT_GRID_W + 16
	return detx + 8, cy + CRAFT_PANEL_H - 28 - CRAFT_BTN_H - 20
}

// True when the cursor is over the CRAFT button.
craft_button_hovered :: proc(gs: ^Game_State) -> bool {
	if !gs.ui.show_crafting do return false
	bx, by := craft_button_rect(gs)
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	return mx >= bx && mx < bx + CRAFT_BTN_W && my >= by && my < by + CRAFT_BTN_H
}

// The recipe shown in the detail panel: the selected one if it is still
// visible at this station, else the first visible recipe (-1 = none).
craft_selected_recipe :: proc(gs: ^Game_State) -> int {
	vis: [len(recipe_table)]int
	n := visible_recipes(gs, &vis)
	if n == 0 do return -1
	for slot in 0 ..< n do if vis[slot] == gs.ui.craft_selected do return gs.ui.craft_selected
	return vis[0]
}

// The smelter tray slot (cast bars wait here) — shared by draw and hit-test.
smelter_tray_rect :: proc(gs: ^Game_State) -> (x, y: i32) {
	p := gs.ui.win_pos[.Smelter]
	return p.x + 24, p.y + 272
}

// The smelter INPUT slot (loaded ore) — shared by draw and the pull-out grab.
smelter_input_rect :: proc(gs: ^Game_State) -> (x, y: i32) {
	p := gs.ui.win_pos[.Smelter]
	return p.x + 24, p.y + 68
}

// The smelter FUEL slot (wood stoking the fire) — shared by draw and hit-test.
smelter_fuel_rect :: proc(gs: ^Game_State) -> (x, y: i32) {
	p := gs.ui.win_pos[.Smelter]
	return p.x + 24, p.y + 186
}

// Top-left of barrel slot `i` (0-based, row-major in the 4×4 grid).
barrel_slot_rect :: proc(gs: ^Game_State, i: int) -> (x, y: i32) {
	p := gs.ui.win_pos[.Barrel]
	col := i32(i % BARREL_COLS)
	row := i32(i / BARREL_COLS)
	return p.x + BARREL_PAD + col * SLOT_PX, p.y + BARREL_GRID_Y + row * SLOT_PX
}

// Barrel slot index under the cursor, or -1.
barrel_slot_at_cursor :: proc(gs: ^Game_State) -> int {
	if !gs.ui.show_barrel do return -1
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	for i in 0 ..< BARREL_SLOTS {
		x, y := barrel_slot_rect(gs, i)
		if mx >= x && mx < x + SLOT_PX && my >= y && my < y + SLOT_PX do return i
	}
	return -1
}

panel_bg :: rl.Color{15, 15, 25, 230}
panel_border :: rl.Color{90, 90, 120, 255}
slot_bg :: rl.Color{35, 35, 50, 255}
text_dim :: rl.Color{140, 140, 150, 255}

// Norse palette — shared by the title, pause menu, settings and death screens.
NORSE_GOLD :: rl.Color{200, 150, 70, 255}
NORSE_GOLD_HOT :: rl.Color{255, 220, 140, 255}
NORSE_PANEL :: rl.Color{24, 20, 16, 235}
NORSE_ROW :: rl.Color{30, 26, 20, 225}
NORSE_ROW_HOT :: rl.Color{62, 46, 26, 235}
NORSE_BORDER :: rl.Color{115, 88, 52, 255}

// ─── Title Screen (boot only; any key → menu) ─────────────────────────────────
//
//  Fully procedural: a slowly rotating ring of Elder Futhark runes spelling
//  GNIPAHELLIR, drifting embers, and the glowing title.  Animates on wall
//  clock (rl.GetTime) because the sim — and gs.elapsed_time — is frozen
//  while the title is up.

// Rune strokes in a unit box (y down), up to 4 segments of {x1,y1,x2,y2}.
Rune_Glyph :: struct {
	n:   int,
	seg: [4][4]f32,
}

@(rodata)
title_runes := [11]Rune_Glyph { 	// G N I P A H E L L I R
	{2, {{0.0, 0, 1.0, 1}, {1.0, 0, 0.0, 1}, {}, {}}}, // Gebo
	{2, {{0.5, 0, 0.5, 1}, {0.2, 0.62, 0.8, 0.38}, {}, {}}}, // Nauthiz
	{1, {{0.5, 0, 0.5, 1}, {}, {}, {}}}, // Isa
	{4, {{0.3, 0, 0.3, 1}, {0.3, 0, 0.7, 0.3}, {0.3, 1, 0.7, 0.7}, {0.7, 0.3, 0.7, 0.7}}}, // Perthro
	{3, {{0.3, 0, 0.3, 1}, {0.3, 0.08, 0.8, 0.35}, {0.3, 0.42, 0.8, 0.69}, {}}}, // Ansuz
	{3, {{0.25, 0, 0.25, 1}, {0.75, 0, 0.75, 1}, {0.25, 0.35, 0.75, 0.6}, {}}}, // Hagalaz
	{4, {{0.2, 0, 0.2, 1}, {0.8, 0, 0.8, 1}, {0.2, 0, 0.5, 0.45}, {0.5, 0.45, 0.8, 0}}}, // Ehwaz
	{2, {{0.4, 0, 0.4, 1}, {0.4, 0, 0.8, 0.4}, {}, {}}}, // Laguz
	{2, {{0.4, 0, 0.4, 1}, {0.4, 0, 0.8, 0.4}, {}, {}}}, // Laguz
	{1, {{0.5, 0, 0.5, 1}, {}, {}, {}}}, // Isa
	{4, {{0.3, 0, 0.3, 1}, {0.3, 0, 0.7, 0.22}, {0.7, 0.22, 0.3, 0.5}, {0.3, 0.5, 0.75, 1}}}, // Raidho
}

// One glyph, rotated about its own center, glow pass under the core stroke.
draw_title_rune :: proc(
	g: Rune_Glyph,
	cx, cy, size, rot: f32,
	col: rl.Color,
	core: f32 = 3,
	glow_w: f32 = 8,
) {
	cr := math.cos(rot)
	sr := math.sin(rot)
	for k in 0 ..< g.n {
		p1 := [2]f32{g.seg[k][0] - 0.5, g.seg[k][1] - 0.5} * size
		p2 := [2]f32{g.seg[k][2] - 0.5, g.seg[k][3] - 0.5} * size
		a := rl.Vector2{cx + p1.x * cr - p1.y * sr, cy + p1.x * sr + p1.y * cr}
		b := rl.Vector2{cx + p2.x * cr - p2.y * sr, cy + p2.x * sr + p2.y * cr}
		glow := col
		glow.a = col.a / 4
		rl.DrawLineEx(a, b, glow_w, glow)
		rl.DrawLineEx(a, b, core, col)
	}
}

// GNIPAHELLIR as a quiet horizontal rune band, centered on cx — dressing
// for panel headers.
draw_rune_strip :: proc(cx, cy, size: f32, col: rl.Color) {
	step := size * 1.8
	x := cx - step * f32(len(title_runes) - 1) / 2
	for g in title_runes {
		draw_title_rune(g, x, cy, size, 0, col, 2, 4)
		x += step
	}
}

draw_title :: proc(gs: ^Game_State) {
	t := f32(rl.GetTime())
	cx := f32(UI_W) / 2
	cy := f32(UI_H) / 2 - 40

	// Night backdrop, warming toward a fire-lit horizon.
	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{8, 8, 14, 255})
	rl.DrawRectangleGradientV(
		0,
		UI_H * 2 / 3,
		UI_W,
		UI_H / 3,
		rl.Color{8, 8, 14, 255},
		rl.Color{42, 20, 10, 255},
	)
	// The cave mouth smolders below the horizon.
	rl.DrawCircleGradient(
		{cx, f32(UI_H + 100)},
		420,
		rl.Color{255, 120, 30, 70},
		rl.Color{0, 0, 0, 0},
	)

	// Embers: stateless — each i hashes to a column/speed, y wraps on time.
	for i in 0 ..< 70 {
		h := whash(u32(i) * 7919 + 13)
		speed := 18 + f32(h % 70)
		x := f32(h % UI_W) + math.sin(t * 1.3 + f32(i)) * 16
		y := f32(UI_H) - math.mod(t * speed + f32(h % UI_H), f32(UI_H + 60))
		rl.DrawRectangle(
			i32(x),
			i32(y),
			3,
			3,
			rl.Color{255, u8(110 + h % 90), 40, u8(70 + h % 130)},
		)
	}

	// The rune ring: GNIPAHELLIR in Elder Futhark, wheeling slowly, each
	// glyph breathing on its own phase.  Faint rings frame the band.
	ring_col := rl.Color{200, 150, 70, 45}
	radius := f32(310)
	rl.DrawRing({cx, cy}, radius - 54, radius - 50, 0, 360, 96, ring_col)
	rl.DrawRing({cx, cy}, radius + 50, radius + 54, 0, 360, 96, ring_col)
	for g, i in title_runes {
		ang := t * 0.12 + f32(i) * (2 * math.PI / f32(len(title_runes)))
		rx := cx + math.cos(ang) * radius
		ry := cy + math.sin(ang) * radius
		breath := 0.55 + 0.45 * math.sin(t * 1.7 + f32(i) * 2.4)
		col := rl.Color{255, 200, 110, u8(120 + 135 * breath)}
		draw_title_rune(g, rx, ry, 40, ang + math.PI / 2, col)
	}

	center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
		tw := rl.MeasureText(text, size)
		rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
	}

	// Title, haloed in ember-light.
	ty := i32(cy) - 70
	pulse := 0.6 + 0.4 * math.sin(t * 1.5)
	center_text("GNIPAHELLIR", ty + 4, 110, rl.Color{120, 40, 10, u8(140 * pulse)})
	center_text("GNIPAHELLIR", ty - 4, 110, rl.Color{120, 40, 10, u8(140 * pulse)})
	center_text("GNIPAHELLIR", ty, 110, rl.Color{240, 205, 130, 255})
	center_text("- III -", ty + 120, 30, rl.Color{200, 150, 70, 255})
	center_text("The hound howls before the cliff-cave", ty + 170, 20, text_dim)

	prompt := u8(120 + 135 * (0.5 + 0.5 * math.sin(t * 2.5)))
	center_text("PRESS ANY KEY", UI_H - 130, 26, rl.Color{255, 240, 180, prompt})
}

// ─── Character Select (startup form picker) ───────────────────────────────────

CSEL_CARD_W  :: 160
CSEL_CARD_H  :: 240
CSEL_GAP     :: 16
CSEL_TOTAL_W :: PLAYER_FORM_COUNT * CSEL_CARD_W + (PLAYER_FORM_COUNT - 1) * CSEL_GAP
CSEL_X0      :: (UI_W - CSEL_TOTAL_W) / 2
CSEL_Y0      :: 230

// Index of the card under the cursor, or -1.
charselect_card_at_cursor :: proc(gs: ^Game_State) -> int {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if my < CSEL_Y0 || my >= CSEL_Y0 + CSEL_CARD_H do return -1
	for i in 0 ..< PLAYER_FORM_COUNT {
		x := i32(CSEL_X0 + i * (CSEL_CARD_W + CSEL_GAP))
		if mx >= x && mx < x + CSEL_CARD_W do return i
	}
	return -1
}

draw_charselect :: proc(gs: ^Game_State) {
	t := f32(rl.GetTime())
	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{12, 10, 14, 255})

	center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
		tw := rl.MeasureText(text, size)
		rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
	}
	center_text("CHOOSE YOUR FORM", 110, 48, rl.Color{240, 205, 130, 255})
	center_text("click a form - or press its number - to begin", 168, 20, text_dim)

	pulse := 0.6 + 0.4 * math.sin(t * 1.5)
	hover := charselect_card_at_cursor(gs)
	for i in 0 ..< PLAYER_FORM_COUNT {
		form := Player_Form(i)
		x := i32(CSEL_X0 + i * (CSEL_CARD_W + CSEL_GAP))
		y := i32(CSEL_Y0)
		hovered := i == hover

		rl.DrawRectangle(x, y, CSEL_CARD_W, CSEL_CARD_H, hovered ? NORSE_ROW_HOT : NORSE_ROW)
		rl.DrawRectangleLinesEx(
			{f32(x), f32(y), CSEL_CARD_W, CSEL_CARD_H},
			hovered ? 3 : 2,
			hovered ? NORSE_GOLD_HOT : NORSE_BORDER,
		)

		// Sprite preview, centered in the card's upper area (uses the new-game
		// default tints so it matches the in-world look).
		ps := f32(13)
		sw := f32(FRAME_WIDTH) * ps
		sx := f32(x) + (CSEL_CARD_W - sw) / 2
		sy := f32(y) + 36
		if hovered do sy -= 4 * f32(pulse)  // a little lift on hover
		draw_form_sprite(form, sx, sy, ps, rl.ORANGE, rl.BLUE)

		// Name plate.
		name := player_form_names[form]
		tw := rl.MeasureText(name, 18)
		rl.DrawText(
			name,
			x + (CSEL_CARD_W - tw) / 2,
			y + CSEL_CARD_H - 44,
			18,
			hovered ? NORSE_GOLD_HOT : rl.Color{225, 215, 195, 255},
		)

		// Number hint under the name.
		num_buf: [4]u8
		num := fmt.bprintf(num_buf[:], "%d", i + 1)
		nt := rl.MeasureText(cstring(raw_data(num_buf[:])), 16)
		rl.DrawText(cstring(raw_data(num_buf[:])), x + (CSEL_CARD_W - nt) / 2, y + CSEL_CARD_H - 22, 16, text_dim)
		_ = num
	}
}

// ─── Pause / Main Menu (ESC, or shown first at startup) ───────────────────────

MENU_ROWS :: 4 // row 0: Resume; 1: Settings; 2: New Game; 3: Save and Quit
MENU_W :: 360
MENU_ROW_H :: 56
MENU_X :: (UI_W - MENU_W) / 2
MENU_Y :: (UI_H - MENU_ROWS * MENU_ROW_H) / 2

@(rodata)
menu_labels := [MENU_ROWS]cstring{"Resume", "Settings", "New Game", "Save and Quit"}

// Menu row under the cursor, or -1.
menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < MENU_X || mx >= MENU_X + MENU_W do return -1
	r := int((my - MENU_Y) / MENU_ROW_H)
	if my < MENU_Y || r >= MENU_ROWS do return -1
	return r
}

draw_menu :: proc(gs: ^Game_State) {
	t := f32(rl.GetTime())

	// Dim the world, deepen the top and bottom edges.
	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{8, 6, 10, 215})
	rl.DrawRectangleGradientV(0, 0, UI_W, 220, rl.Color{0, 0, 0, 180}, rl.Color{0, 0, 0, 0})
	rl.DrawRectangleGradientV(
		0,
		UI_H - 220,
		UI_W,
		220,
		rl.Color{0, 0, 0, 0},
		rl.Color{0, 0, 0, 180},
	)

	cx := f32(UI_W) / 2
	cy := f32(UI_H) / 2

	// The rune wheel turns slowly behind the menu, framed by faint rings.
	radius := f32(350)
	ring_col := rl.Color{NORSE_GOLD.r, NORSE_GOLD.g, NORSE_GOLD.b, 35}
	rl.DrawRing({cx, cy}, radius - 46, radius - 42, 0, 360, 96, ring_col)
	rl.DrawRing({cx, cy}, radius + 42, radius + 46, 0, 360, 96, ring_col)
	for g, i in title_runes {
		ang := t * 0.1 + f32(i) * (2 * math.PI / f32(len(title_runes)))
		rx := cx + math.cos(ang) * radius
		ry := cy + math.sin(ang) * radius
		breath := 0.5 + 0.5 * math.sin(t * 1.4 + f32(i) * 2.1)
		col := rl.Color{NORSE_GOLD.r, NORSE_GOLD.g, NORSE_GOLD.b, u8(60 + 90 * breath)}
		draw_title_rune(g, rx, ry, 30, ang + math.PI / 2, col)
	}

	center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
		tw := rl.MeasureText(text, size)
		rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
	}

	// Ember-haloed title above the buttons.
	pulse := 0.6 + 0.4 * math.sin(t * 1.5)
	center_text("GNIPAHELLIR", MENU_Y - 136, 64, rl.Color{120, 40, 10, u8(140 * pulse)})
	center_text("GNIPAHELLIR", MENU_Y - 140, 64, rl.Color{240, 205, 130, 255})

	hover := menu_row_at_cursor(gs)
	for i in 0 ..< MENU_ROWS {
		y := i32(MENU_Y + i * MENU_ROW_H)
		hovered := i == hover
		rl.DrawRectangle(MENU_X, y, MENU_W, MENU_ROW_H - 6, hovered ? NORSE_ROW_HOT : NORSE_ROW)
		rl.DrawRectangleLinesEx(
			{MENU_X, f32(y), MENU_W, MENU_ROW_H - 6},
			2,
			hovered ? NORSE_GOLD_HOT : NORSE_BORDER,
		)
		tw := rl.MeasureText(menu_labels[i], 22)
		rl.DrawText(
			menu_labels[i],
			MENU_X + (MENU_W - tw) / 2,
			y + 13,
			22,
			hovered ? NORSE_GOLD_HOT : rl.Color{225, 215, 195, 255},
		)

		// Gebo marks flank the chosen row.
		if hovered {
			ry := f32(y) + (MENU_ROW_H - 6) / 2
			draw_title_rune(title_runes[0], f32(MENU_X) - 34, ry, 18, 0, NORSE_GOLD_HOT)
			draw_title_rune(title_runes[0], f32(MENU_X + MENU_W) + 34, ry, 18, 0, NORSE_GOLD_HOT)
		}
	}

	center_text(
		"The hound stirs beneath the cliff",
		MENU_Y + MENU_ROWS * MENU_ROW_H + 40,
		18,
		rl.Color{150, 130, 110, 255},
	)
}

// ─── Settings Screen (volumes + key binds) ────────────────────────────────────

SET_W :: 640
SET_ROW_H :: 44
SET_X :: (UI_W - SET_W) / 2
SET_Y :: (UI_H - 684) / 2 // 684 = the panel's content height (SET_H)
SET_VOL_Y :: SET_Y + 100 // first volume slider row
SET_BIND_Y :: SET_VOL_Y + 3 * SET_ROW_H + 60 // first key-bind row
SET_H :: SET_BIND_Y + len(Action) * SET_ROW_H + 40 - SET_Y
SET_SLIDER_X :: SET_X + 280
SET_SLIDER_W :: 300

@(rodata)
action_labels := [Action]cstring {
	.Move_Left  = "Move Left",
	.Move_Right = "Move Right",
	.Jump       = "Jump",
	.Interact   = "Interact",
	.Inventory  = "Inventory",
	.Blueprint  = "Blueprint",
	.Golem_Crew = "Golem crew",
}

@(rodata)
volume_labels := [3]cstring{"Master", "Effects", "Music"}

// Volume slider row under the cursor, or -1.
settings_slider_at_cursor :: proc(gs: ^Game_State) -> int {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < SET_SLIDER_X - 10 || mx >= SET_SLIDER_X + SET_SLIDER_W + 10 do return -1
	for i in 0 ..< 3 {
		y := i32(SET_VOL_Y + i * SET_ROW_H)
		if my >= y && my < y + SET_ROW_H - 12 do return i
	}
	return -1
}

// Key-bind row under the cursor, or -1.
settings_bind_at_cursor :: proc(gs: ^Game_State) -> int {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < SET_X + 20 || mx >= SET_X + SET_W - 20 do return -1
	r := int((my - SET_BIND_Y) / SET_ROW_H)
	if my < SET_BIND_Y || r >= len(Action) do return -1
	return r
}

draw_settings :: proc(gs: ^Game_State) {
	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{8, 6, 10, 215})
	rl.DrawRectangle(SET_X, SET_Y, SET_W, SET_H, NORSE_PANEL)
	rl.DrawRectangleLinesEx({SET_X, SET_Y, SET_W, SET_H}, 2, NORSE_BORDER)
	rl.DrawText("SETTINGS", SET_X + 24, SET_Y + 20, 30, NORSE_GOLD_HOT)
	rl.DrawText("[ESC] back", SET_X + SET_W - 110, SET_Y + 28, 14, NORSE_GOLD)
	// Gold rule under the header.
	rl.DrawRectangle(SET_X + 24, SET_Y + 58, SET_W - 48, 2, NORSE_BORDER)

	// Volume sliders
	rl.DrawText("VOLUME", SET_X + 24, SET_VOL_Y - 30, 14, NORSE_GOLD)
	volumes := [3]f32{gs.audio.master_volume, gs.audio.sfx_volume, gs.audio.music_volume}
	for i in 0 ..< 3 {
		y := i32(SET_VOL_Y + i * SET_ROW_H)
		rl.DrawText(volume_labels[i], SET_X + 24, y + 6, 20, rl.Color{225, 215, 195, 255})

		bar_h := i32(SET_ROW_H - 22)
		rl.DrawRectangle(SET_SLIDER_X, y + 4, SET_SLIDER_W, bar_h, NORSE_ROW)
		fill := i32(f32(SET_SLIDER_W) * volumes[i])
		rl.DrawRectangle(SET_SLIDER_X, y + 4, fill, bar_h, NORSE_GOLD)
		hover := settings_slider_at_cursor(gs) == i || gs.ui.settings_drag == i
		rl.DrawRectangleLines(
			SET_SLIDER_X,
			y + 4,
			SET_SLIDER_W,
			bar_h,
			hover ? NORSE_GOLD_HOT : NORSE_BORDER,
		)

		pct_buf: [8]u8
		fmt.bprintf(pct_buf[:7], "%d%%", int(volumes[i] * 100 + 0.5))
		rl.DrawText(
			cstring(raw_data(pct_buf[:])),
			SET_SLIDER_X + SET_SLIDER_W + 14,
			y + 6,
			20,
			NORSE_GOLD,
		)
	}

	// Key binds
	rl.DrawText("KEY BINDS", SET_X + 24, SET_BIND_Y - 30, 14, NORSE_GOLD)
	hover_bind := settings_bind_at_cursor(gs)
	for a, i in Action {
		y := i32(SET_BIND_Y + i * SET_ROW_H)
		if i == hover_bind {
			rl.DrawRectangle(SET_X + 20, y, SET_W - 40, SET_ROW_H - 8, NORSE_ROW_HOT)
		}
		rl.DrawText(action_labels[a], SET_X + 36, y + 8, 20, rl.Color{225, 215, 195, 255})

		// Key chip on the right — or the capture prompt while rebinding.
		if gs.ui.settings_capture == i {
			rl.DrawText("PRESS A KEY...", SET_X + SET_W - 220, y + 8, 20, NORSE_GOLD_HOT)
		} else {
			key_buf: [24]u8
			fmt.bprintf(key_buf[:23], "%v", gs.bindings[a])
			key_str := cstring(raw_data(key_buf[:]))
			kw := rl.MeasureText(key_str, 20)
			kx := i32(SET_X + SET_W - 60) - kw
			rl.DrawRectangle(kx - 10, y + 2, kw + 20, SET_ROW_H - 12, NORSE_ROW)
			rl.DrawRectangleLines(kx - 10, y + 2, kw + 20, SET_ROW_H - 12, NORSE_BORDER)
			rl.DrawText(key_str, kx, y + 8, 20, NORSE_GOLD_HOT)
		}
	}
}

// ─── Debug Menu (F1, debug builds only) ───────────────────────────────────────

DBG_MENU_X :: 24
DBG_MENU_Y :: 80
DBG_MENU_W :: 200
DBG_MENU_ROW_H :: 24
DBG_MENU_ROWS :: 14 // 0:fly; 1:wand; 2:portals; 3:structures; 4:resources; 5:full hp; 6:max mana; 7/8:stamp spawners; 9:miner; 10:wand; 11:golem; 12:life; 13:pixel art editor

// Menu row under the cursor, or -1.
debug_menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < DBG_MENU_X || mx >= DBG_MENU_X + DBG_MENU_W do return -1
	r := int((my - DBG_MENU_Y) / DBG_MENU_ROW_H)
	if my < DBG_MENU_Y || r >= DBG_MENU_ROWS do return -1
	return r
}

draw_debug_menu :: proc(gs: ^Game_State) {
	h := i32(DBG_MENU_ROWS * DBG_MENU_ROW_H)
	rl.DrawRectangle(DBG_MENU_X - 6, DBG_MENU_Y - 26, DBG_MENU_W + 12, h + 34, panel_bg)
	rl.DrawRectangleLines(DBG_MENU_X - 6, DBG_MENU_Y - 26, DBG_MENU_W + 12, h + 34, panel_border)
	rl.DrawText("DEBUG (F1)", DBG_MENU_X, DBG_MENU_Y - 20, 10, rl.YELLOW)

	fly_col := gs.debug.fly ? rl.GREEN : text_dim
	rl.DrawText(
		gs.debug.fly ? cstring("Fly mode: ON") : cstring("Fly mode: OFF"),
		DBG_MENU_X,
		DBG_MENU_Y + 7,
		10,
		fly_col,
	)

	uw_col := gs.debug.ultra_wand ? rl.GREEN : text_dim
	rl.DrawText(
		gs.debug.ultra_wand ? cstring("Ultra wand: ON") : cstring("Ultra wand: OFF"),
		DBG_MENU_X,
		DBG_MENU_Y + DBG_MENU_ROW_H + 7,
		10,
		uw_col,
	)

	// Action rows (click to invoke)
	rl.DrawText(
		"Activate portals >",
		DBG_MENU_X,
		DBG_MENU_Y + 2 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)
	rl.DrawText(
		"Add all structures >",
		DBG_MENU_X,
		DBG_MENU_Y + 3 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)
	rl.DrawText(
		"Add resource stack >",
		DBG_MENU_X,
		DBG_MENU_Y + 4 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)
	rl.DrawText("Full HP >", DBG_MENU_X, DBG_MENU_Y + 5 * DBG_MENU_ROW_H + 7, 10, rl.YELLOW)
	rl.DrawText("Max mana >", DBG_MENU_X, DBG_MENU_Y + 6 * DBG_MENU_ROW_H + 7, 10, rl.YELLOW)

	// Snake-miner test kit: stamp a spawner with the next click, get a miner.
	ms_col := gs.debug.place_tile == .Dimension_Spawner ? rl.GREEN : rl.YELLOW
	gs_col := gs.debug.place_tile == .Dimension_Spawner_Gold ? rl.GREEN : rl.YELLOW
	rl.DrawText(
		"Stamp Metal spawner >",
		DBG_MENU_X,
		DBG_MENU_Y + 7 * DBG_MENU_ROW_H + 7,
		10,
		ms_col,
	)
	rl.DrawText(
		"Stamp Gold spawner >",
		DBG_MENU_X,
		DBG_MENU_Y + 8 * DBG_MENU_ROW_H + 7,
		10,
		gs_col,
	)
	rl.DrawText(
		"Give Auto-Miner >",
		DBG_MENU_X,
		DBG_MENU_Y + 9 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)
	rl.DrawText(
		"Give Command Wand >",
		DBG_MENU_X,
		DBG_MENU_Y + 10 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)
	rl.DrawText(
		"Place Clay Golem >",
		DBG_MENU_X,
		DBG_MENU_Y + 11 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)

	life_col := gs.debug.life ? rl.GREEN : text_dim
	rl.DrawText(
		gs.debug.life ? cstring("Game of Life: ON ?!") : cstring("Game of Life: OFF"),
		DBG_MENU_X,
		DBG_MENU_Y + 12 * DBG_MENU_ROW_H + 7,
		10,
		life_col,
	)

	pe_col := gs.ui.show_pixel_editor ? rl.GREEN : rl.YELLOW
	rl.DrawText(
		"Pixel Art Editor >",
		DBG_MENU_X,
		DBG_MENU_Y + 13 * DBG_MENU_ROW_H + 7,
		10,
		pe_col,
	)

	if r := debug_menu_row_at_cursor(gs); r >= 0 {
		rl.DrawRectangleLines(
			DBG_MENU_X - 2,
			DBG_MENU_Y + i32(r) * DBG_MENU_ROW_H + 1,
			DBG_MENU_W + 4,
			DBG_MENU_ROW_H - 2,
			rl.YELLOW,
		)
	}
}

// ─── Altar Debug Menu (F2, debug builds only) ─────────────────────────────────

ALT_MENU_X :: DBG_MENU_X + DBG_MENU_W + 36
ALT_MENU_Y :: DBG_MENU_Y
ALT_MENU_W :: 200
ALT_MENU_ROWS :: 7 // 0/1: stamp sky/rune altar; 2-4: raise tier structure; 5: blueprints; 6: complete ritual

// Menu row under the cursor, or -1.
altar_menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < ALT_MENU_X || mx >= ALT_MENU_X + ALT_MENU_W do return -1
	r := int((my - ALT_MENU_Y) / DBG_MENU_ROW_H)
	if my < ALT_MENU_Y || r >= ALT_MENU_ROWS do return -1
	return r
}

draw_altar_menu :: proc(gs: ^Game_State) {
	h := i32(ALT_MENU_ROWS * DBG_MENU_ROW_H)
	rl.DrawRectangle(ALT_MENU_X - 6, ALT_MENU_Y - 26, ALT_MENU_W + 12, h + 34, panel_bg)
	rl.DrawRectangleLines(ALT_MENU_X - 6, ALT_MENU_Y - 26, ALT_MENU_W + 12, h + 34, panel_border)
	rl.DrawText("ALTARS (F2)", ALT_MENU_X, ALT_MENU_Y - 20, 10, rl.YELLOW)

	sa_col := gs.debug.place_tile == .Sky_Altar ? rl.GREEN : rl.YELLOW
	ra_col := gs.debug.place_tile == .Rune_Altar ? rl.GREEN : rl.YELLOW
	rl.DrawText("Stamp Sky Altar (gate) >", ALT_MENU_X, ALT_MENU_Y + 7, 10, sa_col)
	rl.DrawText("Stamp Rune Altar >", ALT_MENU_X, ALT_MENU_Y + DBG_MENU_ROW_H + 7, 10, ra_col)

	tier_rows := [3]cstring {
		"Raise Stone Altar >",
		"Raise Silver-Gold Altar >",
		"Raise Golden Altar >",
	}
	for label, i in tier_rows {
		col := gs.debug.place_tier == i + 1 ? rl.GREEN : rl.YELLOW
		rl.DrawText(label, ALT_MENU_X, ALT_MENU_Y + i32(2 + i) * DBG_MENU_ROW_H + 7, 10, col)
	}

	rl.DrawText(
		"Find all blueprints >",
		ALT_MENU_X,
		ALT_MENU_Y + 5 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)
	rl.DrawText(
		"Complete next ritual >",
		ALT_MENU_X,
		ALT_MENU_Y + 6 * DBG_MENU_ROW_H + 7,
		10,
		rl.YELLOW,
	)

	if r := altar_menu_row_at_cursor(gs); r >= 0 {
		rl.DrawRectangleLines(
			ALT_MENU_X - 2,
			ALT_MENU_Y + i32(r) * DBG_MENU_ROW_H + 1,
			ALT_MENU_W + 4,
			DBG_MENU_ROW_H - 2,
			rl.YELLOW,
		)
	}
}

// ─── Pixel Art Editor (F1 debug menu, debug builds only) ──────────────────────
//
//  Paints editable structure sprites (pixel_art.odin) using the shared
//  game_palette. A fixed centered modal, not a draggable UI_Window — this is
//  a debug/dev tool, not a player-facing panel.

PXED_CELL       :: i32(16) // on-screen px per grid cell
PXED_PAD        :: i32(16)
PXED_HEADER_H   :: i32(40)
PXED_FOOTER_H   :: i32(60)
PXED_CANVAS_W   :: i32(PIXEL_GRID_MAX_W) * PXED_CELL
PXED_CANVAS_H   :: i32(PIXEL_GRID_MAX_H) * PXED_CELL
// Palette swatches, laid out in a compact grid. Slot 0 is the eraser — same
// size, same click handling as every color, "just another swatch to pick".
PXED_SWATCH     :: i32(16)
PXED_SWATCH_GAP :: i32(3)
PXED_PAL_COLS   :: i32(2)
PXED_PAL_COL_W  :: PXED_PAL_COLS * (PXED_SWATCH + PXED_SWATCH_GAP)
PXED_W          :: PXED_PAD * 2 + PXED_CANVAS_W + 16 + PXED_PAL_COL_W
PXED_H          :: PXED_PAD * 2 + PXED_HEADER_H + PXED_CANVAS_H + PXED_FOOTER_H
PXED_X          :: (UI_W - PXED_W) / 2
PXED_Y          :: (UI_H - PXED_H) / 2
PXED_BTN_W      :: i32(100)
PXED_BTN_H      :: i32(28)
PXED_BTN_GAP    :: i32(12)

pxed_button_labels := [4]cstring{"< PREV", "NEXT >", "SAVE", "CLEAR"}

// Top-left of the canvas (where grid cell (0,0) is drawn).
pixel_editor_canvas_origin :: proc() -> (x, y: i32) {
	return PXED_X + PXED_PAD, PXED_Y + PXED_PAD + PXED_HEADER_H
}

pixel_cell_rect :: proc(col, row: int) -> (x, y: i32) {
	ox, oy := pixel_editor_canvas_origin()
	return ox + i32(col) * PXED_CELL, oy + i32(row) * PXED_CELL
}

// Grid cell under the cursor, bounded by the current sprite's real w×h.
pixel_cell_at_cursor :: proc(gs: ^Game_State) -> (col, row: int, ok: bool) {
	if !gs.ui.show_pixel_editor do return 0, 0, false
	info := pixel_sprite_table[gs.ui.pixel_editor_target]
	ox, oy := pixel_editor_canvas_origin()
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < ox || my < oy do return 0, 0, false
	c := int((mx - ox) / PXED_CELL)
	r := int((my - oy) / PXED_CELL)
	if c < 0 || c >= int(info.w) || r < 0 || r >= int(info.h) do return 0, 0, false
	return c, r, true
}

// Slot 0 = eraser (pixel_editor_color 0), slots 1..PALETTE_SIZE = game_palette[i-1].
palette_swatch_rect :: proc(i: int) -> (x, y: i32) {
	ox := PXED_X + PXED_PAD + PXED_CANVAS_W + 16
	oy := PXED_Y + PXED_PAD + PXED_HEADER_H
	col := i32(i) % PXED_PAL_COLS
	row := i32(i) / PXED_PAL_COLS
	return ox + col * (PXED_SWATCH + PXED_SWATCH_GAP), oy + row * (PXED_SWATCH + PXED_SWATCH_GAP)
}

// Palette slot under the cursor (0 = eraser, 1..PALETTE_SIZE = a color), or -1.
// The value returned IS the pixel_editor_color to select — no special-casing.
palette_swatch_at_cursor :: proc(gs: ^Game_State) -> int {
	if !gs.ui.show_pixel_editor do return -1
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	for i in 0 ..= PALETTE_SIZE {
		x, y := palette_swatch_rect(i)
		if mx >= x && mx < x + PXED_SWATCH && my >= y && my < y + PXED_SWATCH do return i
	}
	return -1
}

pixel_editor_button_rect :: proc(i: int) -> (x, y, w, h: i32) {
	by := PXED_Y + PXED_H - PXED_FOOTER_H + 16
	bx := PXED_X + PXED_PAD + i32(i) * (PXED_BTN_W + PXED_BTN_GAP)
	return bx, by, PXED_BTN_W, PXED_BTN_H
}

// Footer button index under the cursor (0 Prev, 1 Next, 2 Save, 3 Clear), or -1.
pixel_editor_button_at_cursor :: proc(gs: ^Game_State) -> int {
	if !gs.ui.show_pixel_editor do return -1
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	for i in 0 ..< 4 {
		x, y, w, h := pixel_editor_button_rect(i)
		if mx >= x && mx < x + w && my >= y && my < y + h do return i
	}
	return -1
}

draw_pixel_editor :: proc(gs: ^Game_State) {
	rl.DrawRectangle(PXED_X, PXED_Y, PXED_W, PXED_H, panel_bg)
	rl.DrawRectangleLines(PXED_X, PXED_Y, PXED_W, PXED_H, panel_border)

	info := pixel_sprite_table[gs.ui.pixel_editor_target]
	header: [80]u8
	n := len(fmt.bprintf(header[:], "PIXEL ART EDITOR - %s (%dx%d)", info.name, info.w, info.h))
	rl.DrawText(cstring(raw_data(header[:n])), PXED_X + PXED_PAD, PXED_Y + 12, 16, rl.YELLOW)
	rl.DrawText("[ESC] close", PXED_X + PXED_W - 96, PXED_Y + 14, 12, NORSE_GOLD)

	// Canvas: an empty cell shows a faint checkerboard so "transparent" reads.
	// A sprite with no saved edit previews its real original look (seeded,
	// read-only) instead of opening blank — see seed_pixel_grid.
	data := &gs.pixel_art.sprites[gs.ui.pixel_editor_target]
	preview := data.has_data ? data.grid : seed_pixel_grid(gs.ui.pixel_editor_target)
	for row in 0 ..< int(info.h) {
		for col in 0 ..< int(info.w) {
			x, y := pixel_cell_rect(col, row)
			v := preview[row][col]
			if v == 0 {
				checker := (row + col) % 2 == 0 ? rl.Color{40, 40, 48, 255} : rl.Color{52, 52, 62, 255}
				rl.DrawRectangle(x, y, PXED_CELL, PXED_CELL, checker)
			} else {
				rl.DrawRectangle(x, y, PXED_CELL, PXED_CELL, game_palette[v - 1])
			}
			rl.DrawRectangleLines(x, y, PXED_CELL, PXED_CELL, rl.Color{0, 0, 0, 60})
		}
	}
	if c, r, ok := pixel_cell_at_cursor(gs); ok {
		x, y := pixel_cell_rect(c, r)
		rl.DrawRectangleLines(x, y, PXED_CELL, PXED_CELL, rl.YELLOW)
	}

	// Palette grid: slot 0 is the eraser (a checkerboard swatch, deletes a
	// cell just like picking a color paints one), slots 1..PALETTE_SIZE are
	// game_palette colors.
	for i in 0 ..= PALETTE_SIZE {
		x, y := palette_swatch_rect(i)
		if i == 0 {
			rl.DrawRectangle(x, y, PXED_SWATCH, PXED_SWATCH, rl.Color{40, 40, 48, 255})
			rl.DrawRectangle(x, y, PXED_SWATCH / 2, PXED_SWATCH / 2, rl.Color{52, 52, 62, 255})
			rl.DrawRectangle(x + PXED_SWATCH / 2, y + PXED_SWATCH / 2, PXED_SWATCH / 2, PXED_SWATCH / 2, rl.Color{52, 52, 62, 255})
		} else {
			rl.DrawRectangle(x, y, PXED_SWATCH, PXED_SWATCH, game_palette[i - 1])
		}
		selected := i == int(gs.ui.pixel_editor_color)
		border := selected ? rl.YELLOW : panel_border
		thick := selected ? f32(2) : f32(1)
		rl.DrawRectangleLinesEx({f32(x), f32(y), f32(PXED_SWATCH), f32(PXED_SWATCH)}, thick, border)
	}

	// Footer buttons.
	for label, i in pxed_button_labels {
		x, y, w, h := pixel_editor_button_rect(i)
		hover := pixel_editor_button_at_cursor(gs) == i
		rl.DrawRectangle(x, y, w, h, hover ? rl.Color{70, 70, 90, 255} : slot_bg)
		rl.DrawRectangleLines(x, y, w, h, panel_border)
		tw := rl.MeasureText(label, 12)
		rl.DrawText(label, x + (w - tw) / 2, y + 8, 12, rl.WHITE)
	}
}

// True when the cursor is over an open UI panel (blocks mining/placing).
cursor_over_ui :: proc(gs: ^Game_State) -> bool {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	when GAME_DEBUG {
		if gs.debug.menu_open &&
		   mx >= DBG_MENU_X - 6 &&
		   mx < DBG_MENU_X + DBG_MENU_W + 6 &&
		   my >= DBG_MENU_Y - 26 &&
		   my < DBG_MENU_Y + DBG_MENU_ROWS * DBG_MENU_ROW_H + 8 {
			return true
		}
		if gs.debug.altar_menu &&
		   mx >= ALT_MENU_X - 6 &&
		   mx < ALT_MENU_X + ALT_MENU_W + 6 &&
		   my >= ALT_MENU_Y - 26 &&
		   my < ALT_MENU_Y + ALT_MENU_ROWS * DBG_MENU_ROW_H + 8 {
			return true
		}
		if gs.ui.show_pixel_editor &&
		   mx >= PXED_X && mx < PXED_X + PXED_W &&
		   my >= PXED_Y && my < PXED_Y + PXED_H {
			return true
		}
	}
	for w in UI_Window {
		if cursor_in_window(gs, w) do return true
	}
	if sel_chip_hovered(gs) do return true  // the bottom-center placement chip
	if equipped_command_wand(gs) != .None && mx >= GOLEM_CMD_X && mx < GOLEM_CMD_X+GOLEM_CMD_W &&
	   my >= GOLEM_CMD_Y && my < GOLEM_CMD_Y+GOLEM_CMD_H {
		return true
	}
	if gs.ui.show_menu || gs.ui.show_title || gs.ui.show_charselect || gs.ui.show_settings {
		return true // full-screen modals — everything behind them is blocked
	}
	return false
}

golem_plan_button_at_cursor :: proc(gs: ^Game_State) -> Golem_Plan {
	if equipped_command_wand(gs) == .None do return .None
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if my < GOLEM_CMD_Y+30 || my >= GOLEM_CMD_Y+58 do return .None
	for plan, i in ([3]Golem_Plan{.Clay_Hearth, .Golem_Depot, .World_Anchor}) {
		x := GOLEM_CMD_X + 8 + i32(i)*GOLEM_PLAN_W
		if mx >= x && mx < x+GOLEM_PLAN_W-4 && golem_plan_unlocked(gs,plan) do return plan
	}
	return .None
}

// True when the cursor is over the selected-block chip (bottom-center HUD).
sel_chip_hovered :: proc(gs: ^Game_State) -> bool {
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	return mx >= SEL_CHIP_X && mx < SEL_CHIP_X + SEL_CHIP &&
	       my >= SEL_CHIP_Y && my < SEL_CHIP_Y + SEL_CHIP
}

// Equip box under the cursor, or .None (the boxes stack vertically).
equip_slot_at_cursor :: proc(gs: ^Game_State) -> Equip_Slot {
	ex, ey := equip_origin(gs)
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < ex || mx >= ex + SLOT_PX do return .None
	for s, i in equip_slot_order {
		y := ey + i32(i * EQUIP_STEP)
		if my >= y && my < y + SLOT_PX do return s
	}
	return .None
}

WARP_BTN_W :: 64
WARP_BTN_H :: 18

// The "Return to Surface" button beside the charm slot currently holding a
// Jade Ring — live only while it's worn (charm_slot_order / player_has_charm).
warp_button_rect :: proc(gs: ^Game_State) -> (x, y: i32, ok: bool) {
	for s, i in equip_slot_order {
		if gs.player.equipment[s] != .Jade_Ring do continue
		ex, ey := equip_origin(gs)
		x = ex + SLOT_PX + 6
		y = ey + i32(i * EQUIP_STEP) + (SLOT_PX - WARP_BTN_H) / 2
		return x, y, true
	}
	return 0, 0, false
}

warp_button_hovered :: proc(gs: ^Game_State) -> bool {
	if !gs.ui.show_inventory do return false
	x, y, ok := warp_button_rect(gs)
	if !ok do return false
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	return mx >= x && mx < x + WARP_BTN_W && my >= y && my < y + WARP_BTN_H
}

// Inventory slot under the cursor, or -1.
slot_at_cursor :: proc(gs: ^Game_State) -> int {
	bx, by := inv_bag_origin(gs)
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	if mx < bx || my < by do return -1
	c := int((mx - bx) / SLOT_PX)
	r := int((my - by) / SLOT_PX)
	if c < 0 || c >= INV_COLS || r < 0 || r >= INV_ROWS do return -1
	return r * INV_COLS + c
}

// The Void Charm opens one recoverable trash box below the bag grid.
void_slot_rect :: proc(gs: ^Game_State) -> (x, y: i32) {
	bx, by := inv_bag_origin(gs)
	return bx, by + INV_ROWS*SLOT_PX + 34
}

void_slot_hovered :: proc(gs: ^Game_State) -> bool {
	if !gs.ui.show_inventory || !void_charm_active(&gs.player) do return false
	x, y := void_slot_rect(gs)
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	return mx >= x && mx < x + SLOT_PX && my >= y && my < y + SLOT_PX
}

// ─── Drawing ──────────────────────────────────────────────────────────────────

// "[E] CRAFTING BENCH" while a station is in reach — hidden once the window
// is open.  Reads the focus computed by update_station_focus.
draw_station_prompt :: proc(gs: ^Game_State) {
	if gs.ui.focus_station == .None || gs.ui.show_crafting do return
	buf: [48]u8
	fmt.bprintf(buf[:47], "[%v] %v", gs.bindings[.Interact], station_title[gs.ui.focus_station])
	text := cstring(raw_data(buf[:]))
	w := rl.MeasureText(text, 20)
	rl.DrawText(text, (UI_W - w) / 2, UI_H - 130, 20, NORSE_GOLD_HOT)
}

draw_ui :: proc(gs: ^Game_State) {
	draw_hud(gs)
	draw_golem_command_strip(gs)
	draw_hover_label(gs)
	draw_objective(gs)
	draw_station_prompt(gs)
	if gs.ui.show_inventory do draw_inventory(gs)
	if gs.ui.show_crafting do draw_crafting(gs)
	if gs.ui.show_smelter do draw_smelter(gs)
	if gs.ui.show_barrel do draw_barrel(gs)
	if gs.ui.show_inventory || gs.ui.show_crafting do draw_tile_tooltip(gs)
	if gs.ui.drag_item != .None {
		mx := i32(gs.input.mouse_screen.x)
		my := i32(gs.input.mouse_screen.y)
		draw_item_icon(gs.ui.drag_item, mx - 12, my - 12, 24)
		rl.DrawRectangleLines(mx - 12, my - 12, 24, 24, NORSE_GOLD_HOT)
	}
	if gs.ui.show_blueprint do draw_blueprint(gs)
	if gs.ui.show_book do draw_book(gs)
	if gs.game_won do draw_win_screen(gs)
	if gs.player.dead do draw_death_screen(gs)
	when GAME_DEBUG {
		if gs.debug.menu_open do draw_debug_menu(gs)
		if gs.debug.altar_menu do draw_altar_menu(gs)
		if gs.ui.show_pixel_editor do draw_pixel_editor(gs)
	}
	if gs.ui.show_menu do draw_menu(gs) // modal overlays — always drawn last, on top
	if gs.ui.show_charselect do draw_charselect(gs)
	if gs.ui.show_settings do draw_settings(gs)
	if gs.ui.show_title do draw_title(gs) // title covers everything, menu included
	// Notifications are the final UI layer.  Blueprint pickup messages and other
	// important feedback must stay readable over inventory/storage windows,
	// tooltips, dragged icons, books, menus, and every full-screen modal.
	draw_notifications(gs)
}

draw_golem_command_strip :: proc(gs: ^Game_State) {
	wand := equipped_command_wand(gs)
	if wand == .None do return
	cap := command_wand_capacity(wand)
	loaded := golem_loaded_count(gs)
	deployed := golem_deployed_count(gs, gs.level_index)

	rl.DrawRectangle(GOLEM_CMD_X, GOLEM_CMD_Y, GOLEM_CMD_W, GOLEM_CMD_H, NORSE_PANEL)
	rl.DrawRectangleLinesEx({f32(GOLEM_CMD_X), f32(GOLEM_CMD_Y), f32(GOLEM_CMD_W), f32(GOLEM_CMD_H)}, 2, NORSE_GOLD)
	buf: [96]u8
	fmt.bprintf(buf[:95], "CLAY CREW  %d/%d bound  %d here   [%v] all Gather/Build",
		loaded, cap, deployed, gs.bindings[.Golem_Crew])
	rl.DrawText(cstring(raw_data(buf[:])), GOLEM_CMD_X+8, GOLEM_CMD_Y+8, 11, NORSE_GOLD_HOT)

	for plan, i in ([3]Golem_Plan{.Clay_Hearth, .Golem_Depot, .World_Anchor}) {
		x := GOLEM_CMD_X + 8 + i32(i)*GOLEM_PLAN_W
		y := GOLEM_CMD_Y + 30
		unlocked := golem_plan_unlocked(gs, plan)
		selected := gs.ui.golem_plan == plan
		col := NORSE_GOLD_HOT if selected else (NORSE_BORDER if unlocked else rl.Color{65,60,58,180})
		rl.DrawRectangle(x, y, GOLEM_PLAN_W-4, 28, NORSE_ROW)
		rl.DrawRectangleLinesEx({f32(x),f32(y),f32(GOLEM_PLAN_W-4),28}, selected ? 2 : 1, col)
		name := cstring(raw_data(golem_plan_table[plan].name))
		rl.DrawText(name, x+5, y+8, 10, unlocked ? rl.WHITE : text_dim)
	}
	mode := cstring("PLAN: click an anchor") if gs.ui.golem_plan != .None else cstring("GATHER: drag zone | SHIFT+L/R paint/erase")
	build_waiting:=false
	p:=gs.golems.projects[gs.level_index]
	for g in gs.golems.data do if g.status==.Deployed && g.level==gs.level_index && g.mode==.Build &&
		(!p.active || p.complete) {build_waiting=true; break}
	if gs.ui.golem_plan==.None && build_waiting {
		mode=cstring("BUILD: select monument, then click its anchor")
	} else if deployed > 0 && gs.ui.golem_plan == .None && !gs.golems.work[gs.level_index].active {
		mode = cstring("WAITING: drag zone or SHIFT+L paint blocks")
	}
	rl.DrawText(mode, GOLEM_CMD_X+322, GOLEM_CMD_Y+37, 9, text_dim)
}

// ─── Ritual Instruction Tome ──────────────────────────────────────────────────
//
//  Left by a completed Sky-Altar offering: an illuminated book that opens on a
//  white flash and tells the player where the freshly-unsealed portal waits.
//  Screen-space modal; the sim is frozen while it's up (E/ESC/click closes).

draw_book :: proc(gs: ^Game_State) {
	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{10, 8, 6, 205})

	bw := i32(760)
	bh := i32(460)
	bx := (UI_W - bw) / 2
	by := (UI_H - bh) / 2

	// Leather cover + gold frame
	rl.DrawRectangle(bx - 14, by - 14, bw + 28, bh + 28, rl.Color{46, 30, 18, 255})
	rl.DrawRectangleLinesEx({f32(bx - 14), f32(by - 14), f32(bw + 28), f32(bh + 28)}, 3, NORSE_GOLD)

	// Two parchment pages with a shaded spine down the middle
	rl.DrawRectangle(bx, by, bw, bh, rl.Color{234, 220, 188, 255})
	rl.DrawRectangle(bx + bw / 2 - 10, by, 20, bh, rl.Color{200, 184, 150, 255})
	rl.DrawLine(bx + bw / 2, by, bx + bw / 2, by + bh, rl.Color{150, 130, 100, 255})

	ink := rl.Color{60, 44, 28, 255}
	faint := rl.Color{120, 100, 74, 255}

	// Header rune band + title
	draw_rune_strip(f32(bx + bw / 2), f32(by + 34), 12, NORSE_GOLD)
	title := book_title(gs.ui.book_tier)
	tw := rl.MeasureText(title, 40)
	rl.DrawText(title, bx + (bw - tw) / 2, by + 60, 40, ink)
	rl.DrawLine(bx + 60, by + 112, bx + bw - 60, by + 112, faint)

	// Body — the passage to the next portal
	l1, l2, l3 := book_lines(gs.ui.book_tier)
	ty := by + 156
	for line in ([3]cstring{l1, l2, l3}) {
		if line != "" {
			lw := rl.MeasureText(line, 20)
			rl.DrawText(line, bx + (bw - lw) / 2, ty, 20, ink)
		}
		ty += 40
	}

	hint: cstring = "[E] close the tome"
	hw := rl.MeasureText(hint, 16)
	rl.DrawText(hint, bx + (bw - hw) / 2, by + bh - 40, 16, faint)

	// Flash-in: a white wash over the first frames, fading to the page. gs.frame
	// advances even while the sim is frozen, so the flash always plays.
	frames := gs.frame - gs.ui.book_open_frame
	if frames < 16 {
		flash := 1.0 - f32(frames) / 16.0
		rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{255, 250, 236, u8(255 * flash)})
	}
}

book_title :: proc(tier: int) -> cstring {
	switch tier {
	case 0: return "The First Seal"
	case 1: return "The Second Seal"
	case 2: return "The Final Seal"
	}
	return "The Rune-Book of Passage"
}

// Three centered lines of instruction pointing at the portal the ritual opened.
book_lines :: proc(tier: int) -> (cstring, cstring, cstring) {
	switch tier {
	case 0:
		return "The sky-gift is bound. The first seal upon the deep is broken.",
			"Return to the surface and descend once more - deep in the",
			"caves a barred portal now yields, opening the Deep Cave."
	case 1:
		return "The way sinks further. In the Deep Cave, seek its far depths -",
			"the sealed portal to Gnipahellir now opens to your hand.",
			""
	case 2:
		return "The last seal shatters. Gnipahellir's floor trembles below.",
			"Descend to the yawning chasm and face GARM.",
			""
	}
	return "A passage has opened below. Descend, and seek the next portal.", "", ""
}

// ─── Death Screen ─────────────────────────────────────────────────────────────
//
//  Roguelike death: the run is over and the save burns with it.  Blood-dark
//  fade paced by player.death_timer, the rune ring wheeling in red, and after
//  a beat the prompt to carve a new hero (ENTER/click → New_Game_Request).

DEATH_INPUT_DELAY :: f32(1.2) // seconds before restart input is accepted

draw_death_screen :: proc(gs: ^Game_State) {
	t := f32(rl.GetTime())
	fade := clamp(gs.player.death_timer, 0, 1)

	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{25, 0, 0, u8(215 * fade)})

	center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
		tw := rl.MeasureText(text, size)
		rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
	}

	cx := f32(UI_W) / 2
	cy := f32(UI_H) / 2 - 40

	// The rune ring again — but wheeling backwards, in blood.
	radius := f32(270)
	for g, i in title_runes {
		ang := -t * 0.08 + f32(i) * (2 * math.PI / f32(len(title_runes)))
		rx := cx + math.cos(ang) * radius
		ry := cy + math.sin(ang) * radius
		breath := 0.55 + 0.45 * math.sin(t * 1.1 + f32(i) * 2.4)
		col := rl.Color{220, 60, 40, u8((90 + 120 * breath) * fade)}
		draw_title_rune(g, rx, ry, 36, ang + math.PI / 2, col)
	}

	ty := i32(cy) - 60
	center_text("YOU HAVE FALLEN", ty, 80, rl.Color{230, 60, 40, u8(255 * fade)})
	center_text(
		"The Norns have cut your thread",
		ty + 100,
		24,
		rl.Color{200, 160, 140, u8(255 * fade)},
	)

	mins := int(gs.elapsed_time) / 60
	secs := int(gs.elapsed_time) % 60
	buf: [96]u8
	fmt.bprintf(
		buf[:95],
		"Your saga lasted %d:%02d      Kills %d      Runs %d",
		mins,
		secs,
		gs.stats.total_kills,
		gs.stats.runs_played,
	)
	center_text(cstring(raw_data(buf[:])), ty + 150, 20, rl.Color{255, 255, 255, u8(255 * fade)})

	center_text(
		"Death is final - the save burns on the pyre.",
		ty + 200,
		18,
		rl.Color{160, 130, 120, u8(255 * fade)},
	)

	if gs.player.death_timer > DEATH_INPUT_DELAY {
		pulse := u8(120 + 135 * (0.5 + 0.5 * math.sin(t * 2.5)))
		center_text(
			"PRESS [ENTER] - CARVE A NEW HERO",
			UI_H - 150,
			26,
			rl.Color{255, 220, 140, pulse},
		)
	}
}

// The game is beaten: dark overlay, title, run stats.  Quitting ends the
// run (save cleared on exit); menus and restart flow land in Phase 6.
draw_win_screen :: proc(gs: ^Game_State) {
	rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{0, 0, 0, 200})

	center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
		tw := rl.MeasureText(text, size)
		rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
	}

	center_text("GARM IS SLAIN", 380, 60, rl.Color{255, 200, 80, 255})
	center_text("Gnipahellir is conquered", 450, 30, rl.Color{255, 240, 180, 255})

	mins := int(gs.elapsed_time) / 60
	secs := int(gs.elapsed_time) % 60

	buf: [96]u8
	fmt.bprintf(
		buf[:95],
		"Run time %d:%02d      Kills %d      Runs won %d",
		mins,
		secs,
		gs.stats.total_kills,
		gs.stats.runs_won,
	)
	center_text(cstring(raw_data(buf[:])), 520, 20, rl.WHITE)

	center_text("The hound guards the gate no more.", 580, 20, rl.Color{160, 160, 170, 255})
}

// The current objective — one dim line, top-center, always on so a new
// player knows the next step of the loop (text from current_objective).
draw_objective :: proc(gs: ^Game_State) {
	if gs.player.dead || gs.game_won || gs.ui.show_title do return
	buf: [128]u8
	s := current_objective(gs, buf[:127])
	if len(s) == 0 do return
	text := cstring(raw_data(buf[:]))
	tw := rl.MeasureText(text, 18)
	x := (i32(UI_W) - tw) / 2
	rl.DrawText(text, x + 1, 41, 18, rl.Color{0, 0, 0, 160})
	rl.DrawText(text, x, 40, 18, rl.Color{210, 185, 140, 220})
}

// A single Elder-Futhark-style glyph, stroked from a vertical stave plus
// branches within an (x,y,w,h) box.  The default bitmap font can't render real
// rune codepoints, so we draw them as line segments — which also matches the
// game's carved-stone pixel look.  `id` picks one of six shapes.
draw_rune :: proc(id: int, x, y, w, h: f32, col: rl.Color, thick: f32) {
	sx := x + w * 0.32                       // stave sits left of centre
	L :: proc(ax, ay, bx, by: f32, col: rl.Color, thick: f32) {
		rl.DrawLineEx({ax, ay}, {bx, by}, thick, col)
	}
	rx := x + w                              // right edge of the branch reach
	switch id % 6 {
	case 0: // Fehu ᚠ — two arms angling up-right
		L(sx, y, sx, y + h, col, thick)
		L(sx, y + h*0.14, rx, y + h*0.02, col, thick)
		L(sx, y + h*0.42, rx, y + h*0.30, col, thick)
	case 1: // Ansuz ᚨ — two arms angling down-right
		L(sx, y, sx, y + h, col, thick)
		L(sx, y + h*0.06, rx, y + h*0.30, col, thick)
		L(sx, y + h*0.34, rx, y + h*0.58, col, thick)
	case 2: // Thurisaz ᚦ — a thorn triangle on the stave
		L(sx, y, sx, y + h, col, thick)
		L(sx, y + h*0.28, rx, y + h*0.50, col, thick)
		L(rx, y + h*0.50, sx, y + h*0.72, col, thick)
	case 3: // Tiwaz ᛏ — an arrowhead pointing up
		L(sx, y, sx, y + h, col, thick)
		L(sx, y, sx - w*0.28, y + h*0.26, col, thick)
		L(sx, y, sx + w*0.28, y + h*0.26, col, thick)
	case 4: // Raido ᚱ — loop at top, leg kicking out
		L(sx, y, sx, y + h, col, thick)
		L(sx, y, rx, y + h*0.18, col, thick)
		L(rx, y + h*0.18, sx, y + h*0.40, col, thick)
		L(sx, y + h*0.40, rx, y + h, col, thick)
	case 5: // Eihwaz ᛇ — notches kicking off top-right and bottom-left
		L(sx, y, sx, y + h, col, thick)
		L(sx, y, rx, y + h*0.16, col, thick)
		L(sx, y + h, x, y + h*0.84, col, thick)
	}
}

// Timed popups, stacked top-center as inscribed rune-plates that fade out over
// the last NOTIFY_FADE s.  Each message wears a dark bordered plaque flanked by
// a pair of runes that breathe with a slow gold pulse — a guiding voice, not
// bland text.
draw_notifications :: proc(gs: ^Game_State) {
	NOTIFY_FONT :: 20
	RUNE_H      :: f32(16)
	RUNE_W      :: f32(11)
	PAD_X       :: i32(16)   // plate edge → rune
	GAP         :: i32(14)   // rune cluster → text
	PLATE_H     :: i32(32)

	pulse := (math.sin(f32(gs.elapsed_time) * 3) + 1) * 0.5   // shared breath

	for i in 0 ..< gs.notify.count {
		n := &gs.notify.items[i]

		alpha := f32(1)
		if remain := NOTIFY_DURATION - n.age; remain < NOTIFY_FADE {
			alpha = remain / NOTIFY_FADE
		}

		text := cstring(raw_data(n.text[:])) // buffer is zeroed on push
		tw := rl.MeasureText(text, NOTIFY_FONT)

		// Two runes flank each side; a paired cluster reads as an inscription.
		rune_span := i32(RUNE_W)*2 + 4
		plate_w := tw + 2*(PAD_X + rune_span + GAP)
		x0 := (i32(UI_W) - plate_w) / 2
		y0 := i32(56 + i32(i)*42)

		// Plaque + gold border (Ex avoids the supersample hairline flicker).
		bg := NORSE_PANEL;  bg.a = u8(f32(bg.a) * alpha)
		rl.DrawRectangle(x0, y0, plate_w, PLATE_H, bg)
		bord := NORSE_BORDER
		bord.a = u8((110 + pulse*145) * alpha)
		rl.DrawRectangleLinesEx({f32(x0), f32(y0), f32(plate_w), f32(PLATE_H)}, 2, bord)

		// Carved corner ticks catch the light.
		gold := NORSE_GOLD_HOT;  gold.a = u8(255 * alpha)
		TICK :: i32(6)
		rl.DrawRectangle(x0, y0, TICK, 2, gold)
		rl.DrawRectangle(x0, y0, 2, TICK, gold)
		rl.DrawRectangle(x0+plate_w-TICK, y0+PLATE_H-2, TICK, 2, gold)
		rl.DrawRectangle(x0+plate_w-2, y0+PLATE_H-TICK, 2, TICK, gold)

		// Flanking runes — their glow rides the shared pulse.
		rcol := NORSE_GOLD
		rcol.a = u8((150 + pulse*105) * alpha)
		ry := f32(y0) + (f32(PLATE_H) - RUNE_H) / 2
		base := int(n.len)
		lx := f32(x0 + PAD_X)
		draw_rune(base,   lx,            ry, RUNE_W, RUNE_H, rcol, 2)
		draw_rune(base+3, lx + RUNE_W+4, ry, RUNE_W, RUNE_H, rcol, 2)
		rx := f32(x0 + plate_w - PAD_X - rune_span)
		draw_rune(base+1, rx,            ry, RUNE_W, RUNE_H, rcol, 2)
		draw_rune(base+4, rx + RUNE_W+4, ry, RUNE_W, RUNE_H, rcol, 2)

		// The message itself, centred, with its legibility shadow.
		tx := (i32(UI_W) - tw) / 2
		ty := y0 + (PLATE_H - NOTIFY_FONT) / 2
		rl.DrawText(text, tx + 1, ty + 1, NOTIFY_FONT, rl.Color{0, 0, 0, u8(200 * alpha)})
		rl.DrawText(text, tx, ty, NOTIFY_FONT, rl.Color{255, 240, 180, u8(255 * alpha)})
	}
}

// A small plate beside the cursor naming the tile it points at — the
// genre-standard "what am I pointing at" readout. Empty sky/void and any
// pointer over a panel or full-screen modal are skipped.
draw_hover_label :: proc(gs: ^Game_State) {
	if gs.ui.show_book || gs.player.dead || cursor_over_ui(gs) do return
	t := get_tile(&gs.world, int(gs.ui.hover_tile.x), int(gs.ui.hover_tile.y))
	if t == .Air || t == .Void do return

	FONT :: 10
	PAD  :: i32(6)
	text := cstring(raw_data(terrain_table[t].name))
	tw := rl.MeasureText(text, FONT)
	equipment := is_structure_tile[t]
	blueprint_chest := is_blueprint_chest(t)
	hint := cstring("click/E use  |  SHIFT+HOLD reclaim")
	if blueprint_chest do hint = cstring("click/E open")
	hint_w := i32(0)
	if equipment || blueprint_chest do hint_w = rl.MeasureText(hint, FONT)
	pw := max(tw, hint_w) + PAD*2
	ph := i32(FONT) + PAD*2
	if equipment || blueprint_chest do ph += i32(FONT) + 3
	x := clamp(i32(gs.input.mouse_screen.x) + 14, 0, i32(UI_W) - pw)
	y := clamp(i32(gs.input.mouse_screen.y) + 18, 0, i32(UI_H) - ph)

	rl.DrawRectangle(x, y, pw, ph, NORSE_PANEL)
	rl.DrawRectangleLines(x, y, pw, ph, NORSE_BORDER)
	rl.DrawText(text, x + PAD, y + PAD, FONT, rl.Color{255, 240, 180, 255})
	if equipment || blueprint_chest {
		rl.DrawText(hint, x + PAD, y + PAD + i32(FONT) + 3, FONT, rl.Color{225, 150, 70, 255})
	}
}

draw_hud :: proc(gs: ^Game_State) {
	p := &gs.player

	// HP bar
	rl.DrawRectangle(24, 16, 200, 14, rl.Color{60, 20, 20, 255})
	hp_w := i32(200 * f32(p.hp) / f32(max(p.hp_max, 1)))
	rl.DrawRectangle(24, 16, hp_w, 14, rl.Color{200, 40, 40, 255})
	rl.DrawRectangleLines(24, 16, 200, 14, panel_border)

	// Mana bar
	rl.DrawRectangle(24, 34, 200, 10, rl.Color{20, 20, 60, 255})
	mana_w := i32(200 * p.mana / max(p.mana_max, 1))
	rl.DrawRectangle(24, 34, mana_w, 10, rl.Color{60, 90, 220, 255})
	rl.DrawRectangleLines(24, 34, 200, 10, panel_border)

	// Level name (the selected item now reads off the bottom-center chip).
	name_buf: [64]u8
	fmt.bprintf(name_buf[:63], "%s", level_names[gs.level_index])
	rl.DrawText(cstring(raw_data(name_buf[:])), 24, 50, 10, rl.WHITE)

	// Stat line (base + equipment)
	stat_buf: [48]u8
	fmt.bprintf(
		stat_buf[:47],
		"ATK %d  DEF %d  SPD %d",
		player_stat(p, .Attack),
		player_stat(p, .Defense),
		player_stat(p, .Speed),
	)
	rl.DrawText(cstring(raw_data(stat_buf[:])), 24, 64, 10, text_dim)

	// Equipped gear, always visible: one mini box per slot + item name.
	for s, i in equip_slot_order {
		y := i32(82 + i * 24)
		rl.DrawRectangle(24, y, 20, 20, slot_bg)
		rl.DrawRectangleLines(24, y, 20, 20, panel_border)
		rl.DrawText(equip_slot_labels[i], 50, y + 5, 10, text_dim)
		if it := p.equipment[s]; it != .None {
			draw_item_icon(it, 27, y + 3, 14)
			rl.DrawText(cstring(raw_data(item_table[it].name)), 82, y + 5, 10, rl.WHITE)
		}
	}

	// Control hint, bottom-left: one key opens the bag + crafting together, so
	// a new hand always knows where crafting lives.
	hint_buf: [48]u8
	fmt.bprintf(hint_buf[:47], "[%v] Bag / Craft", gs.bindings[.Inventory])
	rl.DrawText(cstring(raw_data(hint_buf[:])), 24, i32(UI_H) - 22, 11, rl.Color{200, 150, 70, 150})

	draw_sel_chip(gs)
}

// The bottom-center placement chip: shows the selected item's icon + count, a
// name label tinted by whether it can be placed, and an empty prompt when
// nothing is selected.  Clicking it (handled in input.odin) opens the bag.
draw_sel_chip :: proc(gs: ^Game_State) {
	inv := &gs.player.inventory
	hov := sel_chip_hovered(gs)
	x := i32(SEL_CHIP_X)
	y := i32(SEL_CHIP_Y)

	has_sel := inv.selected >= 0 &&
		inv.slots[inv.selected].item != .None &&
		inv.slots[inv.selected].count > 0

	item: Item = .None
	count := 0
	if has_sel {
		item  = inv.slots[inv.selected].item
		count = inv.slots[inv.selected].count
	}
	placeable := has_sel && item_table[item].place_tile != .Air

	rl.DrawRectangle(x, y, SEL_CHIP, SEL_CHIP, NORSE_ROW)
	bcol := NORSE_BORDER
	switch {
	case hov:       bcol = NORSE_GOLD_HOT
	case placeable: bcol = NORSE_GOLD
	}
	rl.DrawRectangleLinesEx({f32(x), f32(y), SEL_CHIP, SEL_CHIP}, (hov || placeable) ? 2 : 1, bcol)

	if has_sel {
		draw_item_icon(item, x + 12, y + 8, 32, placeable ? 255 : 120)
		if count > 1 {
			cbuf: [8]u8
			fmt.bprintf(cbuf[:7], "%d", count)
			rl.DrawText(cstring(raw_data(cbuf[:])), x + 6, y + SEL_CHIP - 14, 11, rl.WHITE)
		}
		name := cstring(raw_data(item_table[item].name))
		nw := rl.MeasureText(name, 11)
		rl.DrawText(name, x + (SEL_CHIP - nw)/2, y - 16, 11, placeable ? NORSE_GOLD_HOT : text_dim)
	} else {
		hint := cstring("no block")
		hw := rl.MeasureText(hint, 10)
		rl.DrawText(hint, x + (SEL_CHIP - hw)/2, y - 15, 10, text_dim)
	}
}

draw_inventory :: proc(gs: ^Game_State) {
	inv := &gs.player.inventory
	px := gs.ui.win_pos[.Inventory].x
	py := gs.ui.win_pos[.Inventory].y
	ex, ey := equip_origin(gs)
	bx, by := inv_bag_origin(gs)

	// Norse panel: header (drag to move), equipment row, bag grid, footer.
	rl.DrawRectangle(px, py, INV_PANEL_W, INV_PANEL_H, NORSE_PANEL)
	rl.DrawRectangleLinesEx({f32(px), f32(py), INV_PANEL_W, INV_PANEL_H}, 2, NORSE_BORDER)
	rl.DrawText("INVENTORY", px + 24, py + 16, 26, NORSE_GOLD_HOT)
	draw_rune_strip(f32(px) + 295, f32(py) + 30, 11, rl.Color{200, 150, 70, 110})
	rl.DrawText("[TAB] close", px + INV_PANEL_W - 106, py + 24, 12, NORSE_GOLD)
	rl.DrawRectangle(px + 24, py + 52, INV_PANEL_W - 48, 2, NORSE_BORDER)

	// Equipment paperdoll: right-click a bag item to equip, a box to doff.
	rl.DrawText("GEAR", ex, ey - 16, 12, NORSE_GOLD)
	for s, i in equip_slot_order {
		x := ex
		y := ey + i32(i * EQUIP_STEP)
		hovered := equip_slot_at_cursor(gs) == s
		rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, NORSE_ROW)
		rl.DrawRectangleLinesEx(
			{f32(x), f32(y), SLOT_PX, SLOT_PX},
			hovered ? 2 : 1,
			hovered ? NORSE_GOLD_HOT : NORSE_BORDER,
		)
		it := gs.player.equipment[s]
		if it == .Jade_Ring {
			// Worn, not spent: this button is the ring's only effect.
			bx, by, _ := warp_button_rect(gs)
			whov := warp_button_hovered(gs)
			rl.DrawRectangle(bx, by, WARP_BTN_W, WARP_BTN_H, whov ? rl.Color{70, 52, 26, 255} : NORSE_ROW)
			rl.DrawRectangleLinesEx({f32(bx), f32(by), WARP_BTN_W, WARP_BTN_H}, 1, whov ? NORSE_GOLD_HOT : NORSE_GOLD)
			label := cstring("HOME")
			lw := rl.MeasureText(label, 10)
			rl.DrawText(label, bx + (WARP_BTN_W - lw) / 2, by + 4, 10, whov ? NORSE_GOLD_HOT : NORSE_GOLD)
		} else {
			rl.DrawText(equip_slot_labels[i], x + SLOT_PX + 6, y + 17, 10, text_dim)
		}
		if it != .None {
			draw_item_icon(it, x + 10, y + 10, 24)
		}
	}

	// Bag grid
	for i in 0 ..< MAX_INVENTORY {
		c := i32(i % INV_COLS)
		r := i32(i / INV_COLS)
		x := bx + c * SLOT_PX
		y := by + r * SLOT_PX
		rl.DrawRectangle(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, NORSE_ROW)
		rl.DrawRectangleLines(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, rl.Color{70, 56, 38, 255})

		s := inv.slots[i]
		if s.item != .None && s.count > 0 {
			draw_item_icon(s.item, x + 10, y + 8, 24)
			cnt_buf: [8]u8
			fmt.bprintf(cnt_buf[:7], "%d", s.count)
			rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
		}
		if i == inv.selected {
			rl.DrawRectangleLinesEx(
				{f32(x) + 1, f32(y) + 1, SLOT_PX - 2, SLOT_PX - 2},
				2,
				NORSE_GOLD_HOT,
			)
		}
	}

	// Void Charm buffer: the displayed stack is still recoverable. Dropping a
	// new bag stack here replaces and permanently deletes the one shown.
	if void_charm_active(&gs.player) {
		vx, vy := void_slot_rect(gs)
		hovered := void_slot_hovered(gs)
		pulse := u8(95 + 35*(0.5 + 0.5*math.sin(gs.elapsed_time*3)))
		rl.DrawRectangle(vx + 2, vy + 2, SLOT_PX - 4, SLOT_PX - 4, rl.Color{18, 8, 28, 255})
		rl.DrawRectangleLinesEx(
			{f32(vx) + 1, f32(vy) + 1, SLOT_PX - 2, SLOT_PX - 2},
			hovered ? 2 : 1,
			hovered ? rl.Color{190, 105, 245, 255} : rl.Color{105, 55, 150, pulse},
		)
		rl.DrawText("VOID", vx + SLOT_PX + 10, vy + 5, 12, rl.Color{188, 120, 235, 255})
		rl.DrawText("replace = erase", vx + SLOT_PX + 10, vy + 23, 10, text_dim)

		s := gs.player.void_slot
		if s.item != .None && s.count > 0 {
			draw_item_icon(s.item, vx + 10, vy + 8, 24)
			cnt_buf: [8]u8
			fmt.bprintf(cnt_buf[:7], "%d", s.count)
			rl.DrawText(cstring(raw_data(cnt_buf[:])), vx + 6, vy + SLOT_PX - 14, 10, rl.WHITE)
		}
	}

	// Footer: name of whatever is under the cursor (bag item or worn gear).
	footer_y := py + INV_PANEL_H - 28
	hint := cstring("[SHIFT+CLICK] split  |  drag to stack")
	hint_w := rl.MeasureText(hint, 10)
	rl.DrawText(hint, px + INV_PANEL_W - 24 - hint_w, footer_y, 10, text_dim)
	if hov := slot_at_cursor(gs); hov >= 0 {
		s := inv.slots[hov]
		if s.item != .None && s.count > 0 {
			rl.DrawText(
				cstring(raw_data(item_table[s.item].name)),
				bx,
				footer_y,
				12,
				NORSE_GOLD_HOT,
			)
		}
	} else if es := equip_slot_at_cursor(gs); es != .None {
		if it := gs.player.equipment[es]; it != .None {
			rl.DrawText(cstring(raw_data(item_table[it].name)), bx, footer_y, 12, NORSE_GOLD_HOT)
		}
	} else if void_slot_hovered(gs) {
		if it := gs.player.void_slot.item; it != .None {
			rl.DrawText(cstring(raw_data(item_table[it].name)), bx, footer_y, 12, rl.Color{188, 120, 235, 255})
		}
	}
}

CRAFT_DESC_LINE_H :: i32(14)

// Greedy word-wrap for the crafting detail panel's item description: draws
// each line left-aligned at x, CRAFT_DESC_LINE_H apart, and returns the y
// just below the last line so callers can stack more text beneath it.
// Fixed-buffer, no allocation — descriptions are short hand-authored strings.
draw_wrapped_text :: proc(text: string, x, y, max_w: i32, font_size: i32, color: rl.Color) -> i32 {
	cy := y
	buf: [128]u8
	blen := 0
	word_start := 0
	for i := 0; i <= len(text); i += 1 {
		if i < len(text) && text[i] != ' ' do continue
		word := text[word_start:i]
		word_start = i + 1
		if len(word) == 0 do continue

		sep := blen > 0 ? 1 : 0
		trial: [128]u8
		copy(trial[:], buf[:blen])
		tn := blen
		if sep == 1 { trial[tn] = ' '; tn += 1 }
		copy(trial[tn:], word)
		tn += len(word)
		trial[tn] = 0
		fits := rl.MeasureText(cstring(raw_data(trial[:])), font_size) <= max_w

		if fits || blen == 0 {
			copy(buf[:], trial[:tn])
			blen = tn
			buf[blen] = 0
		} else {
			buf[blen] = 0
			rl.DrawText(cstring(raw_data(buf[:])), x, cy, font_size, color)
			cy += CRAFT_DESC_LINE_H
			copy(buf[:], word)
			blen = len(word)
			buf[blen] = 0
		}
	}
	if blen > 0 {
		buf[blen] = 0
		rl.DrawText(cstring(raw_data(buf[:])), x, cy, font_size, color)
		cy += CRAFT_DESC_LINE_H
	}
	return cy
}

// A "forge" panel: a grid of recipe cards on the left, and a detail column on
// the right (big result icon, ingredient have/need rows, a glowing CRAFT
// button).  Reads craft_selected_recipe for the shown recipe.
draw_crafting :: proc(gs: ^Game_State) {
	vis: [len(recipe_table)]int
	n := visible_recipes(gs, &vis)
	in_reach := player_near_station(gs, gs.ui.active_station)
	pulse := f32((math.sin(f32(gs.elapsed_time) * 3) + 1) * 0.5)

	wx, wy, ww, wh, _ := window_rect(gs, .Crafting)
	cx, cy := craft_origin(gs)

	// Panel + carved frame.
	rl.DrawRectangle(wx, wy, ww, wh, NORSE_PANEL)
	rl.DrawRectangleLinesEx({f32(wx), f32(wy), f32(ww), f32(wh)}, 2, NORSE_BORDER)
	TICK :: i32(7)
	rl.DrawRectangle(wx, wy, TICK, 2, NORSE_GOLD_HOT)
	rl.DrawRectangle(wx, wy, 2, TICK, NORSE_GOLD_HOT)
	rl.DrawRectangle(wx+ww-TICK, wy+wh-2, TICK, 2, NORSE_GOLD_HOT)
	rl.DrawRectangle(wx+ww-2, wy+wh-TICK, 2, TICK, NORSE_GOLD_HOT)

	// Title band.
	rl.DrawText(station_title[gs.ui.active_station], wx + CRAFT_PAD, wy + 8, 20,
		in_reach ? NORSE_GOLD_HOT : text_dim)
	draw_rune_strip(f32(wx + ww) - 64, f32(wy) + 15, 7, rl.Color{200, 150, 70, 120})
	if !in_reach do rl.DrawText("(too far)", wx + ww - 150, wy + 14, 12, text_dim)
	rl.DrawRectangle(wx + CRAFT_PAD, wy + 30, ww - 2*CRAFT_PAD, 1, NORSE_BORDER)

	// ── Left: recipe card grid ──
	hov_card := craft_card_at_cursor(gs)
	sel      := craft_selected_recipe(gs)
	for slot in 0 ..< n {
		ri := vis[slot]
		r  := &recipe_table[ri]
		x, y := craft_card_rect(gs, slot)
		ok       := recipe_craftable(gs, r)
		selected := ri == sel
		hovered  := ri == hov_card

		rl.DrawRectangle(x, y, CRAFT_CARD, CRAFT_CARD, selected ? NORSE_ROW_HOT : NORSE_ROW)
		bcol := NORSE_BORDER
		switch {
		case selected: bcol = NORSE_GOLD_HOT
		case hovered:  bcol = NORSE_GOLD
		case ok:       bcol = rl.Color{96, 150, 96, 255}   // craftable now → faint green
		}
		rl.DrawRectangleLinesEx({f32(x), f32(y), CRAFT_CARD, CRAFT_CARD}, (selected || hovered) ? 2 : 1, bcol)
		draw_item_icon(r.result, x + 10, y + 8, 24, ok ? 255 : 110)
		if r.result_count > 1 {
			cnt: [8]u8
			fmt.bprintf(cnt[:7], "x%d", r.result_count)
			rl.DrawText(cstring(raw_data(cnt[:])), x + 5, y + CRAFT_CARD - 13, 10, rl.WHITE)
		}
	}
	if n == 0 {
		rl.DrawText("No recipes yet - gather materials", cx, cy + 24, 10, text_dim)
	}

	// ── Divider ──
	dx := cx + CRAFT_GRID_W + 6
	rl.DrawRectangle(dx, cy + 4, 1, wh - 44, NORSE_BORDER)

	// ── Right: detail column ──
	detx := dx + 10
	if sel < 0 do return
	r  := &recipe_table[sel]
	ok := recipe_craftable(gs, r)

	// Big result icon, framed.
	ix := detx + (CRAFT_DETAIL_W - 60) / 2
	rl.DrawRectangle(ix, cy + 8, 60, 60, slot_bg)
	rl.DrawRectangleLinesEx({f32(ix), f32(cy + 8), 60, 60}, 2, ok ? NORSE_GOLD : NORSE_BORDER)
	draw_item_icon(r.result, ix + 6, cy + 14, 48)

	// Name (centered), and result count.
	name := cstring(raw_data(item_table[r.result].name))
	nw := rl.MeasureText(name, 18)
	rl.DrawText(name, detx + (CRAFT_DETAIL_W - nw)/2, cy + 74, 18, NORSE_GOLD_HOT)
	if r.result_count > 1 {
		cbuf: [12]u8
		fmt.bprintf(cbuf[:11], "makes %d", r.result_count)
		cw := rl.MeasureText(cstring(raw_data(cbuf[:])), 10)
		rl.DrawText(cstring(raw_data(cbuf[:])), detx + (CRAFT_DETAIL_W - cw)/2, cy + 94, 10, text_dim)
	}
	rl.DrawRectangle(detx, cy + 110, CRAFT_DETAIL_W - 4, 1, NORSE_BORDER)
	rl.DrawText("MATERIALS", detx, cy + 116, 10, NORSE_GOLD)

	// Ingredient rows: icon + name + have/need (green if satisfied, red if not).
	iy := cy + 132
	for ing in r.ingredients {
		if ing.item == .None do continue
		have := inventory_count(&gs.player.inventory, ing.item)
		enough := have >= ing.count
		rl.DrawRectangle(detx, iy, 22, 22, slot_bg)
		rl.DrawRectangleLines(detx, iy, 22, 22, NORSE_BORDER)
		draw_item_icon(ing.item, detx + 3, iy + 2, 16)
		rl.DrawText(cstring(raw_data(item_table[ing.item].name)), detx + 30, iy + 2, 11, rl.Color{225, 215, 195, 255})
		hbuf: [16]u8
		fmt.bprintf(hbuf[:15], "%d/%d", have, ing.count)
		hs := cstring(raw_data(hbuf[:]))
		hw := rl.MeasureText(hs, 12)
		rl.DrawText(hs, detx + CRAFT_DETAIL_W - hw - 8, iy + 4, 12,
			enough ? rl.Color{110, 210, 110, 255} : rl.Color{225, 90, 80, 255})
		iy += 28
	}

	// Description + any passive stat bonuses, filling the gap above CRAFT —
	// this is the player's cue for what the item actually does (a charm's
	// effect, a potion's use, an armor piece's bonus).
	desc_y := iy + 4
	rl.DrawRectangle(detx, desc_y, CRAFT_DETAIL_W - 4, 1, NORSE_BORDER)
	desc_y += 8
	if desc := item_table[r.result].desc; desc != "" {
		desc_y = draw_wrapped_text(desc, detx, desc_y, CRAFT_DETAIL_W - 8, 11, rl.Color{205, 195, 175, 255})
	}
	for stat in Stat {
		bonus := item_stat_bonus[r.result][stat]
		if bonus == 0 do continue
		line: [24]u8
		fmt.bprintf(line[:23], "+%d %s", bonus, stat_label[stat])
		rl.DrawText(cstring(raw_data(line[:])), detx, desc_y, 11, rl.Color{110, 210, 110, 255})
		desc_y += CRAFT_DESC_LINE_H
	}

	// CRAFT button — glows when craftable, dim otherwise.
	bx, by := craft_button_rect(gs)
	hovered := craft_button_hovered(gs)
	bg := NORSE_ROW
	if ok do bg = rl.Color{u8(70 + pulse*40), u8(52 + pulse*28), 26, 255}
	rl.DrawRectangle(bx, by, CRAFT_BTN_W, CRAFT_BTN_H, bg)
	bord := ok ? (hovered ? NORSE_GOLD_HOT : NORSE_GOLD) : NORSE_BORDER
	rl.DrawRectangleLinesEx({f32(bx), f32(by), CRAFT_BTN_W, CRAFT_BTN_H}, ok ? 2 : 1, bord)
	label := cstring("CRAFT")
	lw := rl.MeasureText(label, 18)
	lcol := ok ? NORSE_GOLD_HOT : text_dim
	rl.DrawText(label, bx + (CRAFT_BTN_W - lw)/2, by + 8, 18, lcol)

	// A one-line reason under the button when you can't forge it.
	if !ok {
		msg := cstring("need more materials")
		if !in_reach do msg = "stand by the station"
		mw := rl.MeasureText(msg, 10)
		rl.DrawText(msg, bx + (CRAFT_BTN_W - mw)/2, by + CRAFT_BTN_H + 5, 10, text_dim)
	}
}

// ─── Smelter Window ───────────────────────────────────────────────────────────
//
//  A self-contained furnace: an INPUT slot holding the ore loaded into the
//  fire, the fire itself glowing with progress, and the TRAY of cast bars.
//  Drag ore from the bag onto this window to load it; an ore pile beside the
//  furnace is auto-pulled into the same buffer.

draw_smelter :: proc(gs: ^Game_State) {
	px := gs.ui.win_pos[.Smelter].x
	py := gs.ui.win_pos[.Smelter].y
	tile := gs.ui.smelter_tile
	w := &gs.world

	pcx := i32(gs.player.pos.x + PLAYER_W * 0.5)
	pcy := i32(gs.player.pos.y + PLAYER_H * 0.5)
	in_reach := max(abs(tile.x - pcx), abs(tile.y - pcy)) <= BENCH_RANGE

	rl.DrawRectangle(px, py, SMELT_W, SMELT_H, NORSE_PANEL)
	rl.DrawRectangleLinesEx({f32(px), f32(py), SMELT_W, SMELT_H}, 2, NORSE_BORDER)
	rl.DrawText("SMELTER", px + 24, py + 12, 20, in_reach ? NORSE_GOLD_HOT : text_dim)
	rl.DrawText("[ESC] close", px + SMELT_W - 96, py + 16, 12, NORSE_GOLD)
	rl.DrawRectangle(px + 24, py + 38, SMELT_W - 48, 2, NORSE_BORDER)

	sd := &w.sim_data[grid_idx(int(tile.x), int(tile.y))]
	heat := clamp(sd.growth_timer / SMELT_TIME, 0, 1)
	burning := heat > 0

	// INPUT: ore loaded into the fire (drag from the bag to add; a pile beside
	// the furnace is auto-pulled in here too; drag this slot out to pull it back).
	rl.DrawText("INPUT", px + 24, py + 52, 10, NORSE_GOLD)
	ix, iy := smelter_input_rect(gs)
	rl.DrawRectangle(ix, iy, SLOT_PX, SLOT_PX, slot_bg)
	rl.DrawRectangleLinesEx(
		{f32(ix), f32(iy), SLOT_PX, SLOT_PX},
		sd.in_count > 0 ? 2 : 1,
		sd.in_count > 0 ? NORSE_GOLD_HOT : NORSE_BORDER,
	)
	if sd.in_count > 0 {
		draw_item_icon(sd.in_item, ix + 10, iy + 8, 24)
		cnt_buf: [8]u8
		fmt.bprintf(cnt_buf[:7], "%d", sd.in_count)
		rl.DrawText(cstring(raw_data(cnt_buf[:])), ix + 6, iy + SLOT_PX - 14, 10, rl.WHITE)
		rl.DrawText("drag out to unload", ix + SLOT_PX + 10, iy + 17, 10, text_dim)
	}

	// FUEL: wood stoking the fire (drag wood from the bag; a wood pile beside
	// the furnace is auto-pulled here too).  FUEL_PER_BAR burns per bar.
	fux, fuy := smelter_fuel_rect(gs)
	has_fuel := sd.fuel_count >= FUEL_PER_BAR
	rl.DrawText("FUEL", px + 24, fuy - 14, 10, NORSE_GOLD)
	rl.DrawRectangle(fux, fuy, SLOT_PX, SLOT_PX, slot_bg)
	rl.DrawRectangleLinesEx(
		{f32(fux), f32(fuy), SLOT_PX, SLOT_PX},
		sd.fuel_count > 0 ? 2 : 1,
		has_fuel ? rl.Color{255, 150, 40, 255} : (sd.fuel_count > 0 ? NORSE_GOLD_HOT : NORSE_BORDER),
	)
	if sd.fuel_count > 0 {
		draw_item_icon(FUEL_ITEM, fux + 10, fuy + 8, 24)
		cnt_buf: [8]u8
		fmt.bprintf(cnt_buf[:7], "%d", sd.fuel_count)
		rl.DrawText(cstring(raw_data(cnt_buf[:])), fux + 6, fuy + SLOT_PX - 14, 10, rl.WHITE)
	} else {
		rl.DrawText("out of wood", fux + SLOT_PX + 10, fuy + 17, 10, text_dim)
	}

	// The fire, glowing with smelting progress, to the right of the input.
	fcx := f32(px + SMELT_W - 58)
	fcy := f32(iy + SLOT_PX / 2)
	if burning {
		glow := rl.Color{255, u8(120 + 100 * heat), 50, u8(60 + 180 * heat)}
		rl.DrawCircleGradient({fcx, fcy}, 16 + 8 * heat, glow, rl.Color{})
	} else {
		rl.DrawCircleGradient({fcx, fcy}, 10, rl.Color{120, 60, 30, 90}, rl.Color{})
	}

	// Smelting progress toward the next bar
	bar_y := iy + SLOT_PX + 18
	rl.DrawRectangle(px + 24, bar_y, SMELT_W - 48, 10, NORSE_ROW)
	rl.DrawRectangle(px + 24, bar_y, i32(f32(SMELT_W - 48) * heat), 10, NORSE_GOLD)
	rl.DrawRectangleLines(px + 24, bar_y, SMELT_W - 48, 10, NORSE_BORDER)

	rule, has_ore := smelt_rule_for(sd.in_item)
	status := cstring("cold - drag ore into the furnace")
	switch {
	case burning:
		status = "the fire eats ore and wood"
	case has_ore && int(sd.in_count) < rule.ore_per_bar:
		status = "not enough ore for a bar"
	case has_ore && !has_fuel:
		status = "no fuel - drag wood into the furnace"
	case has_ore:
		status = "the tray blocks the cast - take the bars"
	}
	rl.DrawText(status, px + 24, bar_y + 18, 10, burning ? NORSE_GOLD_HOT : text_dim)

	// The tray: cast bars wait here — click it, or drag it onto the bag.
	tx, ty := smelter_tray_rect(gs)
	rl.DrawText("TRAY", tx, ty - 14, 10, NORSE_GOLD)
	rl.DrawRectangle(tx, ty, SLOT_PX, SLOT_PX, slot_bg)
	rl.DrawRectangleLinesEx(
		{f32(tx), f32(ty), SLOT_PX, SLOT_PX},
		sd.store_count > 0 ? 2 : 1,
		sd.store_count > 0 ? rl.GREEN : NORSE_BORDER,
	)
	if sd.store_count > 0 {
		draw_item_icon(sd.store_item, tx + 10, ty + 8, 24)
		cnt_buf: [8]u8
		fmt.bprintf(cnt_buf[:7], "%d", sd.store_count)
		rl.DrawText(cstring(raw_data(cnt_buf[:])), tx + 6, ty + SLOT_PX - 14, 10, rl.WHITE)
		rl.DrawText("click or drag to the bag", tx + SLOT_PX + 10, ty + 17, 10, text_dim)
	}

	rl.DrawText(
		"drag ore and wood from the bag onto this window",
		px + 24,
		py + SMELT_H - 22,
		10,
		text_dim,
	)
	if !in_reach {
		rl.DrawText("(too far)", px + SMELT_W - 70, py + SMELT_H - 22, 10, text_dim)
	}
}

// Shared normal-storage window: barrels and blueprint chests both expose the
// same 4×4 inventory.  A fresh chest simply starts with its blueprint in slot 5.
draw_barrel :: proc(gs: ^Game_State) {
	px := gs.ui.win_pos[.Barrel].x
	py := gs.ui.win_pos[.Barrel].y
	tile := gs.ui.barrel_tile
	container_t := get_tile(&gs.world, int(tile.x), int(tile.y))
	is_chest := is_blueprint_chest(container_t)

	pcx := i32(gs.player.pos.x + PLAYER_W * 0.5)
	pcy := i32(gs.player.pos.y + PLAYER_H * 0.5)
	in_reach := max(abs(tile.x - pcx), abs(tile.y - pcy)) <= BENCH_RANGE

	rl.DrawRectangle(px, py, BARREL_W, BARREL_H, NORSE_PANEL)
	rl.DrawRectangleLinesEx({f32(px), f32(py), BARREL_W, BARREL_H}, 2, NORSE_BORDER)
	title := cstring("BARREL")
	if is_chest do title = cstring("CHEST")
	rl.DrawText(title, px + BARREL_PAD, py + 12, 20, in_reach ? NORSE_GOLD_HOT : text_dim)
	rl.DrawText("[ESC] close", px + BARREL_W - 96, py + 16, 12, NORSE_GOLD)
	rl.DrawRectangle(px + BARREL_PAD, py + 38, BARREL_W - BARREL_PAD * 2, 2, NORSE_BORDER)

	b := barrel_at(gs, gs.level_index, tile)
	for i in 0 ..< BARREL_SLOTS {
		x, y := barrel_slot_rect(gs, i)
		rl.DrawRectangle(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, slot_bg)
		rl.DrawRectangleLines(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, NORSE_BORDER)
		if b == nil do continue
		s := b.slots[i]
		if s.item == .None || s.count <= 0 do continue
		draw_item_icon(s.item, x + 10, y + 8, 24)
		cnt_buf: [8]u8
		fmt.bprintf(cnt_buf[:7], "%d", s.count)
		rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
	}

	footer := cstring("drag stacks in from the bag, or a slot out to it")
	rl.DrawText(footer, px + BARREL_PAD, py + BARREL_H - 20, 10, text_dim)
}

// The interactive blueprint overlay (B, or click a blueprint in the bag):
// what to gather, the build template for the altar, and the path to the cave.
draw_blueprint :: proc(gs: ^Game_State) {
	x := gs.ui.win_pos[.Blueprint].x
	y := gs.ui.win_pos[.Blueprint].y
	rl.DrawRectangle(x, y, BP_W, BP_H, panel_bg)
	rl.DrawRectangleLines(x, y, BP_W, BP_H, panel_border)

	accent := rl.Color{130, 180, 255, 255}
	good := rl.Color{120, 220, 120, 255}
	warm := rl.Color{250, 220, 110, 255}

	rl.DrawText("[B] close", x + BP_W - 92, y + 14, 12, text_dim)

	// Opening objective: with the Sky Blueprint in hand and no gate raised yet,
	// show how to build the surface Sky Altar that opens the way above.
	if inventory_count(&gs.player.inventory, .Sky_Blueprint) > 0 &&
	   gs.progression.sky_altar_pos == {0, 0} {
		rl.DrawText("BLUEPRINT: The Sky Gate", x + 20, y + 18, 24, accent)
		rl.DrawText(
			"Raise a Sky Altar on the surface to open the way above.",
			x + 20,
			y + 54,
			16,
			rl.Color{225, 225, 240, 255},
		)
		tpl := &structure_templates[0] // tier A: the stone-and-wood altar
		rl.DrawText("BUILD THE ALTAR", x + 320, y + 90, 14, text_dim)
		draw_template_diagram(tpl, x + 415, y + 120)
		ly := y + 96
		draw_legend(x + 30, ly, terrain_table[.Stone].color, "Stone Block")
		draw_legend(x + 30, ly + 22, terrain_table[.Wood].color, "Wood (Plank/Log)")
		draw_legend(x + 30, ly + 44, item_table[.Sky_Altar].color, "Sky Altar (cap)")
		rl.DrawText(
			"Build it on the grass - the portal blooms above the altar.",
			x + 20,
			y + BP_H - 32,
			14,
			text_dim,
		)
		return
	}

	tier := blueprint_active_tier(gs)
	if tier < 0 {
		rl.DrawText("BLUEPRINT", x + 20, y + 18, 24, accent)
		rl.DrawText("You carry no blueprint yet.", x + 20, y + 64, 18, text_dim)
		rl.DrawText(
			"Delve the caves - each blueprint waits in a sealed chest.",
			x + 20,
			y + 92,
			16,
			text_dim,
		)
		return
	}

	// Title + objective
	rl.DrawText("BLUEPRINT: The Sky Ritual", x + 20, y + 18, 24, accent)
	obj_buf: [96]u8
	fmt.bprintf(
		obj_buf[:95],
		"Raise the sky structure to unlock %s.",
		blueprint_unlocks_name(tier),
	)
	rl.DrawText(cstring(raw_data(obj_buf[:])), x + 20, y + 52, 16, rl.Color{225, 225, 240, 255})

	// LEFT — ritual material checklist: icon, name, have/need, check when met
	rl.DrawText("THE ALTAR HUNGERS FOR", x + 20, y + 84, 14, text_dim)
	all_met := true
	for ing, i in structure_costs[tier] {
		ry := y + 104 + i32(i) * 30
		have := inventory_count(&gs.player.inventory, ing.item)
		met := have >= ing.count
		if !met do all_met = false
		draw_item_icon(ing.item, x + 30, ry, 20)
		rl.DrawRectangleLines(x + 30, ry, 20, 20, panel_border)
		rl.DrawText(cstring(raw_data(item_table[ing.item].name)), x + 60, ry + 3, 15, rl.WHITE)
		cnt_buf: [32]u8
		fmt.bprintf(cnt_buf[:31], "%d / %d", have, ing.count)
		rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 210, ry + 3, 15, met ? good : warm)
		if met do draw_check(x + 268, ry + 2, good)
	}

	// RIGHT — the active tier's altar build template, from templates.odin
	tpl := &structure_templates[tier]
	rl.DrawText("BUILD THE ALTAR", x + 320, y + 84, 14, text_dim)
	name_buf: [32]u8
	fmt.bprintf(name_buf[:31], "%s", tpl.name)
	rl.DrawText(cstring(raw_data(name_buf[:])), x + 320, y + 100, 14, accent)
	draw_template_diagram(tpl, x + 415, y + 118)
	ly := y + 190
	if structure_template_uses(
		tpl,
		.Stone,
	) {draw_legend(x + 330, ly, terrain_table[.Stone].color, "Stone Block"); ly += 19}
	if structure_template_uses(
		tpl,
		.Wood,
	) {draw_legend(x + 330, ly, terrain_table[.Wood].color, "Wood"); ly += 19}
	if structure_template_uses(
		tpl,
		.Silver_Ore,
	) {draw_legend(x + 330, ly, terrain_table[.Silver_Ore].color, "Silver Ore"); ly += 19}
	if structure_template_uses(
		tpl,
		.Gold_Ore,
	) {draw_legend(x + 330, ly, terrain_table[.Gold_Ore].color, "Gold Ore"); ly += 19}
	draw_legend(x + 330, ly, item_table[.Sky_Altar].color, "Sky Altar (cap)")

	// Three-step path (left): find -> gather -> raise the altar
	steps_done := [3]bool{true, all_met, gs.progression.sky_structure_complete[tier]}
	labels := [3]cstring{"FIND", "GATHER", "RAISE"}
	current := 3
	for d, i in steps_done {if !d {current = i; break}}
	for i in 0 ..< 3 {
		nx := x + 30 + i32(i) * 90
		ny := y + 196
		col := text_dim
		if steps_done[i] {col = good} else if i == current {col = warm}
		rl.DrawRectangle(nx, ny, 34, 34, slot_bg)
		rl.DrawRectangleLines(nx, ny, 34, 34, col)
		num_buf: [4]u8
		fmt.bprintf(num_buf[:3], "%d", i + 1)
		rl.DrawText(cstring(raw_data(num_buf[:])), nx + 12, ny + 8, 20, col)
		rl.DrawText(labels[i], nx - 2, ny + 40, 12, col)
		if i < 2 do rl.DrawText(">", nx + 42, ny + 4, 24, text_dim)
	}

	rl.DrawText(
		"Build the altar in the Low Sky, gather the offering, then press E.",
		x + 20,
		y + BP_H - 32,
		14,
		text_dim,
	)
}

// A small checkmark drawn from two strokes (default font has no glyph for it).
draw_check :: proc(x, y: i32, col: rl.Color) {
	rl.DrawLineEx({f32(x), f32(y + 8)}, {f32(x + 5), f32(y + 14)}, 3, col)
	rl.DrawLineEx({f32(x + 5), f32(y + 14)}, {f32(x + 14), f32(y)}, 3, col)
}

// A labelled colour swatch for the template legend.
draw_legend :: proc(x, y: i32, col: rl.Color, label: cstring) {
	rl.DrawRectangle(x, y, 14, 14, col)
	rl.DrawRectangleLines(x, y, 14, 14, panel_border)
	rl.DrawText(label, x + 20, y + 1, 13, text_dim)
}

// Draw a build template as stacked colour blocks, centered horizontally on cx.
draw_template_diagram :: proc(tpl: ^Structure_Template, cx, top: i32) {
	CELL :: 16
	for line, r in tpl.rows {
		rw := i32(len(line)) * CELL
		rx := cx - rw / 2
		for glyph, c in line {
			tile, kind := structure_template_cell(glyph)
			if kind == .Empty do continue
			col := kind == .Capstone ? item_table[tpl.capstone].color : terrain_table[tile].color
			bx := rx + i32(c) * CELL
			by := top + i32(r) * CELL
			rl.DrawRectangle(bx + 1, by + 1, CELL - 2, CELL - 2, col)
			rl.DrawRectangleLines(bx + 1, by + 1, CELL - 2, CELL - 2, panel_border)
		}
	}
}

draw_tile_tooltip :: proc(gs: ^Game_State) {
	if cursor_over_ui(gs) do return
	ht := gs.ui.hover_tile
	if !in_bounds(int(ht.x), int(ht.y)) do return

	t := get_tile(&gs.world, int(ht.x), int(ht.y))
	idx := grid_idx(int(ht.x), int(ht.y))

	tip_buf: [64]u8
	it := gs.world.items[idx]
	if it != .None && gs.world.item_counts[idx] > 0 {
		fmt.bprintf(tip_buf[:63], "%s (drop: %s)", terrain_table[t].name, item_table[it].name)
	} else {
		fmt.bprintf(tip_buf[:63], "%s", terrain_table[t].name)
	}
	mx := i32(gs.input.mouse_screen.x)
	my := i32(gs.input.mouse_screen.y)
	rl.DrawText(cstring(raw_data(tip_buf[:])), mx + 12, my - 4, 10, rl.WHITE)
}
