package gnipa_studio

// The pixel editor tab: paint the selected item's 12x12 icon, edit its
// palette slots, and SAVE — which validates exactly what the game's
// item_icons_are_well_formed test checks, then rewrites gen_item_icons.odin
// from the working views.  The run.ps1 watcher rebuilds and swaps the window,
// which lands back here via session restore with the saved state compiled in.
//
// A stroke on a SHARED shape (a grid ANCHORED to a named registry shape —
// its gen-file row references the constant, not merely equal cells) applies
// to every anchored sharer by default — the shape constant survives the emit.
// Switch to THIS ITEM ONLY and the first stroke detaches this item to a
// unique inline grid, permanently: an inline row never re-attaches, even if
// painted back to equality.  Palette edits are always per-item (editing an
// icon that used PAL_IRON detaches its palette to an inline literal the same
// way).

import "core:fmt"
import game "../../src"
import rl "vendor:raylib"

PIX_CELL   :: 36
PIX_GRID_X :: 16

Work :: struct {
	views:        [game.Item]Icon_View,
	anchored:     Icon_Anchors,
	shapes:       [len(shape_registry)]Shape_View,
	dirty:        bool,
	paint:        u8,
	apply_shared: bool,
	status:       string,
}

work: Work

work_init :: proc() {
	views_from_game(&work.views)
	work.anchored = anchors_from_gen_file()
	shapes_from_registry(work.shapes[:])
	work.dirty = false
	work.paint = 'B'
	work.apply_shared = true
	work.status = ""
}

shape_index_of :: proc(cells: Icon_Cells) -> int {
	for sh, i in work.shapes do if sh.cells == cells do return i
	return -1
}

work_shared_count :: proc(cells: Icon_Cells) -> int {
	n := 0
	for it in game.Item {
		if it != .None && work.anchored[it] && !work.views[it].empty && work.views[it].cells == cells do n += 1
	}
	return n
}

apply_paint :: proc(it: game.Item, x, y: int, ch: u8) {
	v := &work.views[it]
	if v.cells[y][x] == ch do return
	if work.apply_shared && work.anchored[it] {
		if si := shape_index_of(v.cells); si >= 0 {
			old := work.shapes[si].cells
			work.shapes[si].cells[y][x] = ch
			for jt in game.Item {
				w := &work.views[jt]
				if !w.empty && work.anchored[jt] && w.cells == old do w.cells[y][x] = ch
			}
			work.dirty = true
			return
		}
	}
	v.cells[y][x] = ch
	work.anchored[it] = false // a per-item stroke detaches for good
	work.dirty = true
}

pal_slot :: proc(pal: ^game.Icon_Palette, ch: u8) -> ^rl.Color {
	switch ch {
	case 'B': return &pal.base
	case 'D': return &pal.dark
	case 'L': return &pal.light
	case 'A': return &pal.accent
	case 'a': return &pal.accent2
	}
	return nil
}

// Mirrors item_icons_are_well_formed: 12x12 by construction here, every
// non-'.' rune must resolve, and every icon must draw at least one pixel.
validate_views :: proc() -> (ok: bool, msg: string) {
	for it in game.Item {
		if it == .None do continue
		v := &work.views[it]
		if v.empty do continue
		opaque := 0
		for row in v.cells {
			for ch in row {
				if _, pok := game.icon_pixel(v.pal, ch); pok {
					opaque += 1
				} else if ch != '.' {
					return false, fmt.aprintf("%s: rune '%c' maps to nothing (palette slot unset?)", item_name(it), rune(ch))
				}
			}
		}
		if opaque == 0 do return false, fmt.aprintf("%s: icon draws nothing", item_name(it))
	}
	return true, ""
}

work_save :: proc() {
	if wizard_lock {
		work.status = "waiting for the rebuild after item creation"
		return
	}
	if vok, msg := validate_views(); !vok {
		work.status = fmt.aprintf("REFUSED - %s", msg)
		return
	}
	content := emit_icons(&g_notes, &work.views, &work.anchored, work.shapes[:], nil)
	if write_gen_file("gen_item_icons.odin", content) {
		work.dirty = false
		work.status = "saved - the watcher rebuild lands you back here"
	} else {
		work.status = "WRITE FAILED - see console"
	}
}

// --test-save: headless write-path smoke test — paint one Dirt pixel and one
// Wizard pixel, save both files.
test_save :: proc() -> bool {
	work_init()
	work.views[game.Item.Dirt].cells[0][0] = 'B'
	work.dirty = true
	work_save()
	fmt.printfln("test-save icons:  %s", work.status)

	player_work_init()
	pwork.frames[game.Player_Form.Wizard][0][0][0] = 'x'
	pwork.dirty = true
	player_save()
	fmt.printfln("test-save player: %s", pwork.status)

	recipe_work_init()
	rwork.recipes[0].result_count += 1
	rwork.dirty = true
	recipe_save()
	fmt.printfln("test-save recipes: %s", rwork.status)
	return !work.dirty && !pwork.dirty && !rwork.dirty
}

draw_view_icon :: proc(v: ^Icon_View, x, y, size: i32) {
	cell := f32(size) / game.ICON_GRID
	for row, gy in v.cells {
		for ch, gx in row {
			col, ok := game.icon_pixel(v.pal, ch)
			if !ok do continue
			rl.DrawRectangleRec({f32(x) + f32(gx)*cell, f32(y) + f32(gy)*cell, cell, cell}, col)
		}
	}
}

button :: proc(x, y: i32, label: cstring, mouse: rl.Vector2, enabled := true, active := false) -> bool {
	w := rl.MeasureText(label, 14) + 20
	r := rl.Rectangle{f32(x), f32(y), f32(w), 26}
	hov := enabled && rl.CheckCollisionPointRec(mouse, r)
	rl.DrawRectangleRec(r, active ? {45, 48, 58, 255} : {26, 28, 36, 255})
	rl.DrawRectangleLinesEx(r, 1,
		!enabled ? {60, 64, 76, 255} :
		active   ? {245, 205, 90, 255} :
		hov      ? {150, 155, 165, 255} : {90, 95, 110, 255})
	rl.DrawText(label, x + 10, y + 6, 14, enabled ? rl.Color{225, 228, 235, 255} : rl.Color{100, 104, 116, 255})
	return hov && rl.IsMouseButtonPressed(.LEFT)
}

slider :: proc(x, y: i32, label: cstring, val: ^u8, mouse: rl.Vector2) -> bool {
	rl.DrawText(label, x, y + 1, 12, {150, 155, 165, 255})
	bar := rl.Rectangle{f32(x + 22), f32(y), 256, 14}
	changed := false
	if rl.IsMouseButtonDown(.LEFT) &&
	   rl.CheckCollisionPointRec(mouse, {bar.x - 4, bar.y - 6, bar.width + 8, bar.height + 12}) {
		nv := u8(clamp(int(mouse.x - bar.x), 0, 255))
		if nv != val^ {
			val^ = nv
			changed = true
		}
	}
	rl.DrawRectangleRec(bar, {26, 28, 36, 255})
	rl.DrawRectangle(i32(bar.x), y, i32(val^), 14, {150, 155, 165, 255})
	rl.DrawRectangleLinesEx(bar, 1, {90, 95, 110, 255})
	rl.DrawText(fmt.ctprintf("%d", val^), i32(bar.x) + 262, y + 1, 12, {200, 203, 210, 255})
	return changed
}

pixel_frame :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	it := s.selected
	if it == .None || work.views[it].empty {
		rl.DrawText("Select an item on the ITEMS tab first.", PIX_GRID_X, i32(TOP_BAR) + 24, 16, {150, 155, 165, 255})
		return
	}
	v := &work.views[it]

	// Header: item + shared-shape banner + apply-mode toggle.
	by := i32(TOP_BAR) + 12
	rl.DrawText(fmt.ctprintf("%s", item_name(it)), PIX_GRID_X, by, 20, {235, 235, 240, 255})
	bx := PIX_GRID_X + rl.MeasureText(fmt.ctprintf("%s", item_name(it)), 20) + 24
	if si := shape_index_of(v.cells); si >= 0 && work.anchored[it] {
		rl.DrawText(fmt.ctprintf("shape %s - shared by %d items", work.shapes[si].name, work_shared_count(v.cells)),
			bx, by + 4, 13, {140, 185, 225, 255})
		bx += rl.MeasureText(fmt.ctprintf("shape %s - shared by %d items", work.shapes[si].name, work_shared_count(v.cells)), 13) + 20
		if button(bx, by - 2, "ALL SHARERS", mouse, true, work.apply_shared) do work.apply_shared = true
		bx += rl.MeasureText("ALL SHARERS", 14) + 30
		if button(bx, by - 2, "THIS ITEM ONLY", mouse, true, !work.apply_shared) do work.apply_shared = false
	} else {
		rl.DrawText("unique shape", bx, by + 4, 13, {150, 155, 165, 255})
	}

	gy := by + 36
	gsize := i32(game.ICON_GRID * PIX_CELL)

	// The canvas.
	draw_checker(PIX_GRID_X, gy, gsize, gsize)
	for y in 0 ..< int(game.ICON_GRID) {
		for x in 0 ..< int(game.ICON_GRID) {
			ch := v.cells[y][x]
			cx := PIX_GRID_X + i32(x)*PIX_CELL
			cy := gy + i32(y)*PIX_CELL
			if col, ok := game.icon_pixel(v.pal, ch); ok {
				rl.DrawRectangle(cx, cy, PIX_CELL, PIX_CELL, col)
			} else if ch != '.' {
				// unresolvable rune: flag it loudly
				rl.DrawRectangle(cx, cy, PIX_CELL, PIX_CELL, {120, 30, 30, 255})
				rl.DrawText(fmt.ctprintf("%c", rune(ch)), cx + 12, cy + 8, 18, {255, 120, 120, 255})
			}
		}
	}
	for i in 0 ..= int(game.ICON_GRID) {
		o := i32(i) * PIX_CELL
		rl.DrawLine(PIX_GRID_X + o, gy, PIX_GRID_X + o, gy + gsize, {60, 64, 76, 120})
		rl.DrawLine(PIX_GRID_X, gy + o, PIX_GRID_X + gsize, gy + o, {60, 64, 76, 120})
	}

	// Paint.
	mx := int((mouse.x - f32(PIX_GRID_X)) / PIX_CELL)
	my := int((mouse.y - f32(gy)) / PIX_CELL)
	if mx >= 0 && mx < int(game.ICON_GRID) && my >= 0 && my < int(game.ICON_GRID) &&
	   mouse.x >= f32(PIX_GRID_X) && mouse.y >= f32(gy) {
		rl.DrawRectangleLinesEx(
			{f32(PIX_GRID_X + i32(mx)*PIX_CELL), f32(gy + i32(my)*PIX_CELL), PIX_CELL, PIX_CELL},
			2, {245, 205, 90, 255})
		if rl.IsMouseButtonDown(.LEFT) do apply_paint(it, mx, my, work.paint)
		if rl.IsMouseButtonDown(.RIGHT) do apply_paint(it, mx, my, '.')
	}

	// Live previews.
	px := PIX_GRID_X + gsize + 28
	py := gy + 18
	rl.DrawText("PREVIEW", px, gy - 2, 12, {120, 125, 138, 255})
	for size in ([4]i32{12, 24, 48, 96}) {
		draw_checker(px, py, size + 12, size + 12)
		draw_view_icon(v, px + 6, py + 6, size)
		py += size + 20
	}

	// Rune bar.
	ry := gy + gsize + 16
	rl.DrawText("paint:", PIX_GRID_X, ry + 7, 13, {150, 155, 165, 255})
	rx := i32(PIX_GRID_X + 52)
	runes := "BDLAa WhHgSst ."
	for i in 0 ..< len(runes) {
		ch := runes[i]
		if ch == ' ' {
			rx += 12
			continue
		}
		r := rl.Rectangle{f32(rx), f32(ry), 28, 28}
		hov := rl.CheckCollisionPointRec(mouse, r)
		if hov && rl.IsMouseButtonPressed(.LEFT) do work.paint = ch
		if ch == '.' {
			draw_checker(rx, ry, 28, 28)
		} else if col, ok := game.icon_pixel(v.pal, ch); ok {
			rl.DrawRectangleRec(r, col)
		} else {
			rl.DrawRectangleRec(r, {26, 28, 36, 255})
			rl.DrawLine(rx + 4, ry + 4, rx + 24, ry + 24, {120, 30, 30, 255})
		}
		rl.DrawRectangleLinesEx(r, work.paint == ch ? 2 : 1,
			work.paint == ch ? {245, 205, 90, 255} : (hov ? rl.Color{150, 155, 165, 255} : rl.Color{90, 95, 110, 255}))
		// rune label, readable on any swatch
		rl.DrawText(fmt.ctprintf("%c", rune(ch)), rx + 2, ry + 30, 12, {150, 155, 165, 255})
		rx += 34
	}

	// Palette-slot editor for the selected rune.
	sy := ry + 62
	if slot := pal_slot(&v.pal, work.paint); slot != nil {
		rl.DrawText(fmt.ctprintf("palette slot '%c' - edits THIS item's palette (a shared PAL_ detaches to inline)", rune(work.paint)),
			PIX_GRID_X, sy, 13, {200, 203, 210, 255})
		sy += 22
		changed := false
		changed |= slider(PIX_GRID_X, sy, "R", &slot.r, mouse); sy += 22
		changed |= slider(PIX_GRID_X, sy, "G", &slot.g, mouse); sy += 22
		changed |= slider(PIX_GRID_X, sy, "B", &slot.b, mouse); sy += 22
		if changed {
			if slot.a == 0 do slot.a = 255
			work.dirty = true
		}
		if button(PIX_GRID_X, sy + 4, "UNSET SLOT (transparent)", mouse, slot^ != {}) {
			slot^ = {}
			work.dirty = true
		}
	} else if work.paint != '.' {
		rl.DrawText(fmt.ctprintf("'%c' is a shared color - fixed in item_art.odin for every icon", rune(work.paint)),
			PIX_GRID_X, sy, 13, {150, 155, 165, 255})
	}

	// Save / revert / status.
	sx := i32(sw) - 260
	if button(sx, i32(TOP_BAR) + 12, work.dirty ? cstring("SAVE  (rewrites gen_item_icons.odin)") : cstring("SAVED"), mouse, work.dirty) {
		work_save()
	}
	if button(sx, i32(TOP_BAR) + 46, "REVERT ALL EDITS", mouse, work.dirty) {
		work_init()
		work.status = "reverted to the compiled tables"
	}
	if work.status != "" {
		rl.DrawText(fmt.ctprintf("%s", work.status), PIX_GRID_X, i32(sh) - 26, 13,
			work.dirty ? rl.Color{225, 228, 235, 255} : rl.Color{105, 185, 105, 255})
	}
}
