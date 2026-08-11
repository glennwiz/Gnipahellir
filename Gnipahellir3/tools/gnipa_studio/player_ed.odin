package gnipa_studio

// The player sprite editor tab: paint the 16x22 walk frames of the seven
// player forms.  Same write-back contract as the icon editor — SAVE validates
// (legend runes only) and rewrites src/gen_player_art.odin from the working
// copy; the watcher rebuild swaps the window with the art compiled in.
//
// Clothing (h/H/L) and hair (y/Y) runes are player-tinted at runtime, so the
// editor previews through game.player_pixel_color with a cycleable tint set —
// exactly the char-select path (draw_form_sprite's tmp-Player trick).

import "core:fmt"
import game "../../src"
import rl "vendor:raylib"

PL_CELL   :: 24
PL_GRID_X :: 16

// Every rune player_pixel_color resolves; anything else (but ' ') refuses SAVE.
PLAYER_LEGEND :: "xvhHLyYkKmMNfFbBwWsSgGEOQT"

// What each legend rune is, for the swatch hover label.
player_rune_label :: proc(ch: rune) -> string {
	switch ch {
	case 'x': return "outline"
	case 'v': return "void / black cloth"
	case 'h': return "clothing shadow (tinted)"
	case 'H': return "clothing mid (tinted)"
	case 'L': return "clothing rim light (tinted)"
	case 'y': return "hair shadow (tinted)"
	case 'Y': return "hair (tinted)"
	case 'k': return "skin shadow"
	case 'K': return "skin"
	case 'm': return "steel shadow"
	case 'M': return "steel"
	case 'N': return "steel highlight"
	case 'f': return "fur shadow"
	case 'F': return "fur"
	case 'b': return "leather shadow"
	case 'B': return "leather / boots"
	case 'w': return "bone shadow"
	case 'W': return "bone / horn / beak"
	case 's': return "stone shadow"
	case 'S': return "stone"
	case 'g': return "core ember ring"
	case 'G': return "glowing core"
	case 'E': return "eye glow"
	case 'O': return "orb core"
	case 'Q': return "orb halo"
	case 'T': return "gold trim"
	}
	return "?"
}

Tint :: struct {
	name:     string,
	hair:     rl.Color,
	clothing: rl.Color,
}

preview_tints := [4]Tint{
	{"violet robe / gold hair", {200, 160, 60, 255}, {96, 70, 160, 255}},
	{"blue / brown", {110, 74, 42, 255}, {58, 96, 170, 255}},
	{"green / black", {40, 36, 40, 255}, {66, 130, 74, 255}},
	{"red / blond", {214, 190, 120, 255}, {160, 58, 58, 255}},
}

Player_Work :: struct {
	frames: Player_Frames,
	form:   game.Player_Form,
	frame:  int, // 0 idle, 1 stride
	paint:  rune,
	tint:   int,
	dirty:  bool,
	status: string,
}

pwork: Player_Work

player_work_init :: proc() {
	pwork.frames = game.player_form_frames
	pwork.form = .Wizard
	pwork.frame = 0
	pwork.paint = 'H'
	pwork.dirty = false
	pwork.status = ""
}

player_tint_player :: proc() -> game.Player {
	t := preview_tints[pwork.tint]
	return game.Player{hair_color = t.hair, clothing_color = t.clothing}
}

player_validate :: proc() -> (ok: bool, msg: string) {
	for form_frames, form in pwork.frames {
		for frame, fi in form_frames {
			for row in frame {
				for ch in row {
					if ch == ' ' do continue
					known := false
					for l in PLAYER_LEGEND do if l == ch { known = true; break }
					if !known {
						return false, fmt.aprintf("%v frame %d: rune '%c' is not in the legend", form, fi, ch)
					}
				}
			}
		}
	}
	return true, ""
}

player_save :: proc() {
	if wizard_lock {
		pwork.status = "waiting for the rebuild after item creation"
		return
	}
	if vok, msg := player_validate(); !vok {
		pwork.status = fmt.aprintf("REFUSED - %s", msg)
		return
	}
	content := emit_player(&g_notes, &pwork.frames)
	if write_gen_file("gen_player_art.odin", content) {
		pwork.dirty = false
		pwork.status = "saved - the watcher rebuild lands you back here"
	} else {
		pwork.status = "WRITE FAILED - see console"
	}
}

draw_work_form :: proc(frame: ^[game.FRAME_HEIGHT][game.FRAME_WIDTH]rune, x, y, ps: f32) {
	tmp := player_tint_player()
	for row in 0 ..< int(game.FRAME_HEIGHT) {
		for col in 0 ..< int(game.FRAME_WIDTH) {
			ch := frame[row][col]
			if ch == ' ' do continue
			rl.DrawRectangleRec(
				{x + f32(col)*ps, y + f32(row)*ps, ps, ps},
				game.player_pixel_color(&tmp, ch))
		}
	}
}

player_frame_ui :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	tmp := player_tint_player()

	// Form + frame selectors.
	by := i32(TOP_BAR) + 10
	bx := i32(PL_GRID_X)
	for form in game.Player_Form {
		if button(bx, by, game.player_form_names[form], mouse, true, pwork.form == form,
			hint = "Switch the canvas to this character form's sprite.") {
			pwork.form = form
		}
		bx += rl.MeasureText(game.player_form_names[form], 14) + 30
	}
	bx += 20
	if button(bx, by, "FRAME 0 idle", mouse, true, pwork.frame == 0, hint = "The standing/idle walk frame.") {
		pwork.frame = 0
	}
	bx += rl.MeasureText("FRAME 0 idle", 14) + 30
	if button(bx, by, "FRAME 1 stride", mouse, true, pwork.frame == 1,
		hint = "The mid-stride walk frame - alternates with FRAME 0 while the player moves.") {
		pwork.frame = 1
	}

	frame := &pwork.frames[pwork.form][pwork.frame]
	gy := by + 38
	gw := i32(game.FRAME_WIDTH * PL_CELL)
	gh := i32(game.FRAME_HEIGHT * PL_CELL)

	// The canvas.
	draw_checker(PL_GRID_X, gy, gw, gh)
	for row in 0 ..< int(game.FRAME_HEIGHT) {
		for col in 0 ..< int(game.FRAME_WIDTH) {
			ch := frame[row][col]
			if ch == ' ' do continue
			rl.DrawRectangle(
				i32(PL_GRID_X) + i32(col)*PL_CELL, gy + i32(row)*PL_CELL,
				PL_CELL, PL_CELL, game.player_pixel_color(&tmp, ch))
		}
	}
	for i in 0 ..= int(game.FRAME_WIDTH) {
		o := i32(i) * PL_CELL
		rl.DrawLine(i32(PL_GRID_X) + o, gy, i32(PL_GRID_X) + o, gy + gh, {60, 64, 76, 120})
	}
	for i in 0 ..= int(game.FRAME_HEIGHT) {
		o := i32(i) * PL_CELL
		rl.DrawLine(i32(PL_GRID_X), gy + o, i32(PL_GRID_X) + gw, gy + o, {60, 64, 76, 120})
	}

	// Paint / erase.
	mx := int((mouse.x - f32(PL_GRID_X)) / PL_CELL)
	my := int((mouse.y - f32(gy)) / PL_CELL)
	if mx >= 0 && mx < int(game.FRAME_WIDTH) && my >= 0 && my < int(game.FRAME_HEIGHT) &&
	   mouse.x >= f32(PL_GRID_X) && mouse.y >= f32(gy) {
		rl.DrawRectangleLinesEx(
			{f32(i32(PL_GRID_X) + i32(mx)*PL_CELL), f32(gy + i32(my)*PL_CELL), PL_CELL, PL_CELL},
			2, {245, 205, 90, 255})
		if rl.IsMouseButtonDown(.LEFT) && frame[my][mx] != pwork.paint {
			frame[my][mx] = pwork.paint
			pwork.dirty = true
		}
		if rl.IsMouseButtonDown(.RIGHT) && frame[my][mx] != ' ' {
			frame[my][mx] = ' '
			pwork.dirty = true
		}
	}

	// Legend rune bar, two columns beside the canvas.
	lx := i32(PL_GRID_X) + gw + 24
	rl.DrawText("paint:", lx, gy - 16, 12, {120, 125, 138, 255})
	hover_label := ""
	legend := string(PLAYER_LEGEND)
	for i in 0 ..< len(legend) {
		ch := rune(legend[i])
		cx := lx + i32(i % 2) * 56
		cy := gy + i32(i / 2) * 36
		r := rl.Rectangle{f32(cx), f32(cy), 28, 28}
		hov := rl.CheckCollisionPointRec(mouse, r)
		if hov {
			hover_label = player_rune_label(ch)
			if rl.IsMouseButtonPressed(.LEFT) do pwork.paint = ch
		}
		rl.DrawRectangleRec(r, game.player_pixel_color(&tmp, ch))
		rl.DrawRectangleLinesEx(r, pwork.paint == ch ? 2 : 1,
			pwork.paint == ch ? {245, 205, 90, 255} : (hov ? rl.Color{150, 155, 165, 255} : rl.Color{90, 95, 110, 255}))
		rl.DrawText(fmt.ctprintf("%c", ch), cx + 32, cy + 8, 12, {150, 155, 165, 255})
	}
	// Eraser.
	{
		i := len(PLAYER_LEGEND)
		cx := lx + i32(i % 2) * 56
		cy := gy + i32(i / 2) * 36
		r := rl.Rectangle{f32(cx), f32(cy), 28, 28}
		hov := rl.CheckCollisionPointRec(mouse, r)
		if hov {
			hover_label = "eraser (space)"
			if rl.IsMouseButtonPressed(.LEFT) do pwork.paint = ' '
		}
		draw_checker(cx, cy, 28, 28)
		rl.DrawRectangleLinesEx(r, pwork.paint == ' ' ? 2 : 1,
			pwork.paint == ' ' ? {245, 205, 90, 255} : (hov ? rl.Color{150, 155, 165, 255} : rl.Color{90, 95, 110, 255}))
	}
	if hover_label != "" {
		rl.DrawText(fmt.ctprintf("%s", hover_label), lx, gy + 14*36 + 8, 13, {200, 203, 210, 255})
	}

	// Previews: both frames, two scales, current tint.
	px := lx + 150
	pv := gy + 24
	rl.DrawText(fmt.ctprintf("PREVIEW - %s", preview_tints[pwork.tint].name), px, pv - 16, 12, {120, 125, 138, 255})
	pf0 := &pwork.frames[pwork.form][0]
	pf1 := &pwork.frames[pwork.form][1]
	draw_checker(px, pv, 16*3 + 12, 22*3 + 12)
	draw_work_form(pf0, f32(px + 6), f32(pv + 6), 3)
	draw_checker(px + 76, pv, 16*3 + 12, 22*3 + 12)
	draw_work_form(pf1, f32(px + 82), f32(pv + 6), 3)
	py := pv + 22*3 + 24
	draw_checker(px, py, 16*6 + 12, 22*6 + 12)
	draw_work_form(pwork.frame == 0 ? pf0 : pf1, f32(px + 6), f32(py + 6), 6)
	if button(px, py + 22*6 + 24, "CYCLE TINT", mouse,
		hint = "Preview only - cycles the hair/clothing tint the h/H/L/y/Y runes resolve to. Does not change any saved data.") {
		pwork.tint = (pwork.tint + 1) % len(preview_tints)
	}

	// Save / revert / status.
	sx := i32(sw) - 260
	if button(sx, i32(TOP_BAR) + 12, pwork.dirty ? cstring("SAVE  (rewrites gen_player_art.odin)") : cstring("SAVED"), mouse, pwork.dirty,
		hint = "Validate every frame (legend runes only) and rewrite gen_player_art.odin. The watcher rebuilds and swaps the window.") {
		player_save()
	}
	if button(sx, i32(TOP_BAR) + 46, "REVERT ALL EDITS", mouse, pwork.dirty,
		hint = "Discard every unsaved sprite edit across all forms/frames and reload from the compiled table.") {
		player_work_init()
		pwork.status = "reverted to the compiled table"
	}
	if pwork.status != "" {
		rl.DrawText(fmt.ctprintf("%s", pwork.status), PL_GRID_X, i32(sh) - 26, 13,
			pwork.dirty ? rl.Color{225, 228, 235, 255} : rl.Color{105, 185, 105, 255})
	}
}
