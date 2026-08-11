package gnipa_studio

// The recipe editor tab: edit costs, stations, ingredients, unlock gates and
// smelt rules; append new recipes.  APPEND-ONLY by construction — no insert,
// delete or reorder controls exist, because recipe indices are load-bearing
// for the game's tests.  SAVE validates then rewrites gen_recipes.odin; the
// DAG tab and the inspector preview the working copy live (unsaved included).

import "core:fmt"
import game "../../src"
import rl "vendor:raylib"

MAX_RECIPES :: 128
MAX_SMELT   :: 16

PICKER_CLOSED     :: -100
PICKER_UNLOCK     :: -1
PICKER_APPEND     :: -2
PICKER_SMELT_ORE  :: -3
PICKER_SMELT_BAR  :: -4

Recipe_Work :: struct {
	recipes:      [MAX_RECIPES]game.Recipe,
	recipe_count: int,
	baseline:     int, // rows that existed at seed: their result item is locked
	unlock:       [game.Item]game.Item,
	smelt:        [MAX_SMELT]game.Smelt_Rule,
	smelt_count:  int,
	sel:          int,
	scroll:       int,
	dirty:        bool,
	gen:          int, // bumped on every change; DAG/xref rebuild when it moves
	status:       string,
	picker_slot:  int, // PICKER_CLOSED, PICKER_*, or ingredient slot 0..2
	pending_ore:  game.Item, // two-stage smelt append
}

rwork: Recipe_Work

recipe_work_init :: proc() {
	rwork = {}
	for r, i in game.recipe_table do rwork.recipes[i] = r
	rwork.recipe_count = len(game.recipe_table)
	rwork.baseline = rwork.recipe_count
	for gate, it in game.recipe_unlock do rwork.unlock[it] = gate
	for r, i in game.smelt_table do rwork.smelt[i] = r
	rwork.smelt_count = len(game.smelt_table)
	rwork.picker_slot = PICKER_CLOSED
}

recipe_touch :: proc() {
	rwork.dirty = true
	rwork.gen += 1
}

// Validation: every recipe needs >= 1 real ingredient, sane counts, and no
// ingredient cycle (a cycle would make the craft-depth layering meaningless
// and points at a content mistake anyway).
recipe_validate :: proc() -> (ok: bool, msg: string) {
	for r, i in rwork.recipes[:rwork.recipe_count] {
		if r.result == .None do return false, fmt.aprintf("row %d has no result item", i)
		if r.result_count < 1 || r.result_count > 99 do return false, fmt.aprintf("%s: result count %d out of 1..99", item_name(r.result), r.result_count)
		ings := 0
		for ing in r.ingredients {
			if ing.item == .None do continue
			ings += 1
			// Not stack-bound: the game counts across stacks (the 500-bar
			// Runic Dimension Spawner is legitimate).
			if ing.count < 1 || ing.count > 999 do return false, fmt.aprintf("%s: ingredient count %d out of 1..999", item_name(r.result), ing.count)
			if ing.item == r.result do return false, fmt.aprintf("%s: recipe consumes its own result", item_name(r.result))
		}
		if ings == 0 do return false, fmt.aprintf("%s: recipe has no ingredients (would craft from nothing)", item_name(r.result))
	}
	for r in rwork.smelt[:rwork.smelt_count] {
		if r.ore == .None || r.bar == .None do return false, fmt.aprintf("smelt rule with a missing item")
		if r.ore_per_bar < 1 || r.ore_per_bar > 99 do return false, fmt.aprintf("smelt %s: ore-per-bar out of 1..99", item_name(r.ore))
	}
	// Cycle check: run the same longest-path relaxation the DAG uses; if it is
	// still relaxing after n_items rounds, the ingredient graph has a cycle.
	layer: [game.Item]int
	for round in 0 ..< len(game.Item) + 1 {
		changed := false
		for r in rwork.recipes[:rwork.recipe_count] {
			for ing in r.ingredients {
				if ing.item == .None do continue
				if layer[r.result] < layer[ing.item] + 1 {
					layer[r.result] = layer[ing.item] + 1
					changed = true
				}
			}
		}
		if !changed do break
		if round == len(game.Item) do return false, fmt.aprintf("recipe cycle detected (some chain of recipes consumes itself)")
	}
	return true, ""
}

recipe_save :: proc() {
	if wizard_lock {
		rwork.status = "waiting for the rebuild after item creation"
		return
	}
	if vok, msg := recipe_validate(); !vok {
		rwork.status = fmt.aprintf("REFUSED - %s", msg)
		return
	}
	content := emit_recipes(&g_notes, rwork.recipes[:rwork.recipe_count], &rwork.unlock, rwork.smelt[:rwork.smelt_count], nil)
	if write_gen_file("gen_recipes.odin", content) {
		rwork.dirty = false
		rwork.status = "saved - the watcher rebuild lands you back here"
	} else {
		rwork.status = "WRITE FAILED - see console"
	}
}

// [-] value [+]; SHIFT steps by 10.
spinner :: proc(x, y: i32, val: ^int, minv, maxv: int, mouse: rl.Vector2, hint := "") -> bool {
	full_hint := hint != "" ? fmt.tprintf("%s (hold SHIFT to step by 10)", hint) : "hold SHIFT to step by 10"
	step := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) ? 10 : 1
	changed := false
	if button(x, y, "-", mouse, val^ > minv, hint = full_hint) {
		val^ = max(val^ - step, minv)
		changed = true
	}
	rl.DrawText(fmt.ctprintf("%d", val^), x + 26, y + 6, 14, {225, 228, 235, 255})
	if button(x + 52, y, "+", mouse, val^ < maxv, hint = full_hint) {
		val^ = min(val^ + step, maxv)
		changed = true
	}
	return changed
}

station_cycle := [4]game.Station{.None, .Bench, .Forge, .Rune_Altar}

// ─── The item picker modal ────────────────────────────────────────────────────

draw_item_picker :: proc(title: cstring, mouse: rl.Vector2, sw, sh: f32) -> (picked: game.Item, done: bool) {
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 170})
	cols :: 10
	cell :: 46
	rows := (len(game.Item) - 2) / cols + 1
	pw := i32(cols*cell + 24)
	ph := i32(rows*cell + 76)
	x0 := (i32(sw) - pw) / 2
	y0 := (i32(sh) - ph) / 2
	rl.DrawRectangle(x0, y0, pw, ph, {24, 26, 32, 255})
	rl.DrawRectangleLines(x0, y0, pw, ph, {245, 205, 90, 255})
	rl.DrawText(title, x0 + 12, y0 + 10, 16, {235, 235, 240, 255})
	rl.DrawText("right-click to cancel", x0 + pw - 150, y0 + 13, 12, {120, 125, 138, 255})

	hovered: game.Item = .None
	for it in game.Item {
		if it == .None do continue
		idx := int(it) - 1
		cx := x0 + 12 + i32(idx % cols)*cell
		cy := y0 + 38 + i32(idx / cols)*cell
		r := rl.Rectangle{f32(cx), f32(cy), cell, cell}
		hov := rl.CheckCollisionPointRec(mouse, r)
		if hov {
			hovered = it
			rl.DrawRectangleLinesEx(r, 1, {150, 155, 165, 255})
		}
		game.draw_item_icon(it, cx + 3, cy + 3, cell - 6)
	}
	if hovered != .None {
		rl.DrawText(fmt.ctprintf("%s", item_name(hovered)), x0 + 12, y0 + ph - 24, 14, {245, 205, 90, 255})
		draw_hint(mouse, game.item_table[hovered].desc)
		if rl.IsMouseButtonPressed(.LEFT) do return hovered, true
	}
	if rl.IsMouseButtonPressed(.RIGHT) || rl.IsKeyPressed(.ESCAPE) do return .None, true
	return .None, false
}

recipe_apply_pick :: proc(it: game.Item) {
	switch rwork.picker_slot {
	case PICKER_UNLOCK:
		rwork.unlock[rwork.recipes[rwork.sel].result] = it
		recipe_touch()
	case PICKER_APPEND:
		for r in rwork.recipes[:rwork.recipe_count] {
			if r.result == it {
				rwork.status = fmt.aprintf("REFUSED - %s already has a recipe (unlock gating keys on unique results)", item_name(it))
				return
			}
		}
		if rwork.recipe_count >= MAX_RECIPES {
			rwork.status = "REFUSED - recipe table is full"
			return
		}
		rwork.recipes[rwork.recipe_count] = {it, 1, .Bench, {}}
		rwork.sel = rwork.recipe_count
		rwork.recipe_count += 1
		recipe_touch()
		rwork.status = fmt.aprintf("appended %s - set its ingredients, then SAVE", item_name(it))
	case PICKER_SMELT_ORE:
		rwork.pending_ore = it
		rwork.picker_slot = PICKER_SMELT_BAR
		return // stay in picker flow
	case PICKER_SMELT_BAR:
		if rwork.smelt_count >= MAX_SMELT {
			rwork.status = "REFUSED - smelt table is full"
		} else {
			rwork.smelt[rwork.smelt_count] = {rwork.pending_ore, it, 1}
			rwork.smelt_count += 1
			recipe_touch()
		}
	case:
		if rwork.picker_slot >= 0 && rwork.picker_slot < 3 {
			r := &rwork.recipes[rwork.sel]
			ing := &r.ingredients[rwork.picker_slot]
			if ing.item == .None do ing.count = 1
			ing.item = it
			recipe_touch()
		}
	}
	rwork.picker_slot = PICKER_CLOSED
}

// ─── The tab ──────────────────────────────────────────────────────────────────

recipe_frame :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	// While the picker modal is up, everything beneath ignores the mouse.
	emouse := rwork.picker_slot != PICKER_CLOSED ? rl.Vector2{-9999, -9999} : mouse

	// Left: the append-only row list.
	lx := i32(16)
	ly := i32(TOP_BAR) + 14
	rl.DrawText("RECIPES  (append-only: indices are load-bearing for tests)", lx, ly, 13, {245, 205, 90, 255})
	ly += 22
	row_h :: 22
	visible := int((sh - f32(ly) - 40) / row_h)
	if rl.CheckCollisionPointRec(emouse, {f32(lx), f32(ly), 700, f32(visible*row_h)}) {
		rwork.scroll = clamp(rwork.scroll - int(rl.GetMouseWheelMove())*3, 0, max(0, rwork.recipe_count - visible))
	}
	for vi in 0 ..< min(visible, rwork.recipe_count - rwork.scroll) {
		i := rwork.scroll + vi
		r := rwork.recipes[i]
		y := ly + i32(vi)*row_h
		rect := rl.Rectangle{f32(lx), f32(y), 700, row_h}
		hov := rl.CheckCollisionPointRec(emouse, rect)
		if hov && rl.IsMouseButtonPressed(.LEFT) do rwork.sel = i
		if i == rwork.sel {
			rl.DrawRectangleRec(rect, {45, 48, 58, 255})
			rl.DrawRectangleLinesEx(rect, 1, {245, 205, 90, 255})
		} else if hov {
			rl.DrawRectangleRec(rect, {32, 35, 44, 255})
		}
		game.draw_item_icon(r.result, lx + 4, y + 2, row_h - 4)
		txt := fmt.tprintf("[%d] %s", i, item_name(r.result))
		if r.result_count > 1 do txt = fmt.tprintf("%s x%d", txt, r.result_count)
		txt = fmt.tprintf("%s  @ %s:", txt, station_label[station_ex(r.station)])
		first := true
		for ing in r.ingredients {
			if ing.item == .None do continue
			txt = fmt.tprintf("%s%s %dx %s", txt, first ? "" : "  +", ing.count, item_name(ing.item))
			first = false
		}
		col := rl.Color{225, 228, 235, 255}
		if i >= rwork.baseline do col = {140, 225, 160, 255} // appended this session
		rl.DrawText(fmt.ctprintf("%s", txt), lx + row_h + 6, y + 4, 12, col)
	}

	// Right: the edit panel for the selected row.
	ex := i32(760)
	ey := i32(TOP_BAR) + 14
	r := &rwork.recipes[rwork.sel]

	game.draw_item_icon(r.result, ex, ey, 40)
	rl.DrawText(fmt.ctprintf("%s", item_name(r.result)), ex + 50, ey + 2, 20, {235, 235, 240, 255})
	tag := rwork.sel >= rwork.baseline ? cstring("appended - result editable until saved") : cstring("existing row - result locked (indices)")
	rl.DrawText(tag, ex + 50, ey + 26, 11, {120, 125, 138, 255})
	ey += 52

	rl.DrawText("result count", ex, ey + 6, 12, {120, 125, 138, 255})
	if spinner(ex + 110, ey, &r.result_count, 1, 99, emouse, "How many of the result item one craft yields.") do recipe_touch()
	sb := fmt.ctprintf("station: %s", station_label[station_ex(r.station)])
	if button(ex + 210, ey, sb, emouse,
		hint = "Cycles the station this recipe is made at: None (hand-craftable anywhere), Bench, Forge, Rune Altar.") {
		for st, i in station_cycle {
			if st == r.station {
				r.station = station_cycle[(i + 1) % len(station_cycle)]
				break
			}
		}
		recipe_touch()
	}
	ey += 40

	rl.DrawText("INGREDIENTS", ex, ey, 13, {245, 205, 90, 255})
	ey += 20
	for slot in 0 ..< 3 {
		ing := &r.ingredients[slot]
		if ing.item != .None {
			game.draw_item_icon(ing.item, ex, ey, 26)
			rl.DrawText(fmt.ctprintf("%s", item_name(ing.item)), ex + 32, ey + 6, 13, {225, 228, 235, 255})
			if spinner(ex + 220, ey, &ing.count, 1, 999, emouse, "How many of this ingredient the recipe consumes.") do recipe_touch()
			if button(ex + 310, ey, "PICK", emouse, hint = "Choose a different ingredient for this slot.") do rwork.picker_slot = slot
			if button(ex + 370, ey, "CLEAR", emouse, hint = "Empty this ingredient slot.") {
				ing^ = {}
				recipe_touch()
			}
		} else {
			rl.DrawText("- empty -", ex + 32, ey + 6, 13, {90, 95, 110, 255})
			if button(ex + 310, ey, "PICK", emouse, hint = "Choose an ingredient for this slot.") do rwork.picker_slot = slot
		}
		ey += 34
	}
	ey += 8

	rl.DrawText("UNLOCK GATE", ex, ey, 13, {245, 205, 90, 255})
	ey += 20
	if gate := rwork.unlock[r.result]; gate != .None {
		game.draw_item_icon(gate, ex, ey, 26)
		rl.DrawText(fmt.ctprintf("hidden until the player holds %s", item_name(gate)), ex + 32, ey + 6, 13, {225, 228, 235, 255})
		if button(ex + 310, ey, "PICK", emouse, hint = "Choose which item, once held, reveals this recipe (recipe_unlock is keyed by the result item).") do rwork.picker_slot = PICKER_UNLOCK
		if button(ex + 370, ey, "CLEAR", emouse, hint = "Remove the gate - this recipe is visible from the start.") {
			rwork.unlock[r.result] = .None
			recipe_touch()
		}
	} else {
		rl.DrawText("known from the start", ex + 32, ey + 6, 13, {150, 155, 165, 255})
		if button(ex + 310, ey, "PICK", emouse,
			hint = "Choose a material that, once held, reveals this recipe in the crafting window (a sticky unlock - stays revealed after the material is spent).") {
			rwork.picker_slot = PICKER_UNLOCK
		}
	}
	ey += 44

	rl.DrawText("SMELT RULES  (ore -> bar at the smelter)", ex, ey, 13, {245, 205, 90, 255})
	ey += 20
	for i in 0 ..< rwork.smelt_count {
		sr := &rwork.smelt[i]
		game.draw_item_icon(sr.ore, ex, ey, 24)
		game.draw_item_icon(sr.bar, ex + 120, ey, 24)
		rl.DrawText(fmt.ctprintf("%s ->", item_name(sr.ore)), ex + 30, ey + 5, 12, {225, 228, 235, 255})
		rl.DrawText(fmt.ctprintf("%s", item_name(sr.bar)), ex + 150, ey + 5, 12, {225, 228, 235, 255})
		rl.DrawText("ore/bar", ex + 250, ey + 5, 11, {120, 125, 138, 255})
		if spinner(ex + 310, ey - 2, &sr.ore_per_bar, 1, 99, emouse, "How much ore the smelter eats per bar cast.") do recipe_touch()
		ey += 30
	}
	if button(ex, ey, "APPEND SMELT RULE", emouse, rwork.smelt_count < MAX_SMELT,
		hint = "Add a new ore -> bar rule: pick the ore, then the bar it casts into at the smelter.") {
		rwork.picker_slot = PICKER_SMELT_ORE
	}
	ey += 40

	if button(ex, ey, "APPEND RECIPE", emouse, rwork.recipe_count < MAX_RECIPES,
		hint = "Add a new recipe row for a chosen result item. Append-only - recipe indices are load-bearing for the game's tests, so nothing can be inserted, deleted, or reordered.") {
		rwork.picker_slot = PICKER_APPEND
	}

	// Save / revert / status.
	sx := i32(sw) - 260
	if button(sx, i32(TOP_BAR) + 12, rwork.dirty ? cstring("SAVE  (rewrites gen_recipes.odin)") : cstring("SAVED"), emouse, rwork.dirty,
		hint = "Validate every recipe (real ingredients, sane counts, no self-consumption, no cycle) and rewrite gen_recipes.odin. The watcher rebuilds and swaps the window.") {
		recipe_save()
	}
	if button(sx, i32(TOP_BAR) + 46, "REVERT ALL EDITS", emouse, rwork.dirty,
		hint = "Discard every unsaved recipe/unlock/smelt-rule edit and reload from the compiled tables.") {
		recipe_work_init()
		rwork.gen += 1
		rwork.status = "reverted to the compiled tables"
	}
	if rwork.status != "" {
		rl.DrawText(fmt.ctprintf("%s", rwork.status), lx, i32(sh) - 26, 13,
			rwork.dirty ? rl.Color{225, 228, 235, 255} : rl.Color{105, 185, 105, 255})
	}

	// The modal, over everything.
	if rwork.picker_slot != PICKER_CLOSED {
		title: cstring
		switch rwork.picker_slot {
		case PICKER_UNLOCK:    title = "PICK THE UNLOCK GATE"
		case PICKER_APPEND:    title = "PICK THE NEW RECIPE'S RESULT"
		case PICKER_SMELT_ORE: title = "SMELT RULE - PICK THE ORE"
		case PICKER_SMELT_BAR: title = "SMELT RULE - PICK THE BAR IT CASTS"
		case:                  title = "PICK THE INGREDIENT"
		}
		picked, done := draw_item_picker(title, mouse, sw, sh)
		if done {
			if picked == .None {
				rwork.picker_slot = PICKER_CLOSED
			} else {
				recipe_apply_pick(picked)
			}
		}
	}
}
