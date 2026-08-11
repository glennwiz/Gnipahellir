package gnipa_studio

// TILES tab (studio_tiles.md T2 + T3): the world palette on one screen.
// Browser = one color swatch per Tile_Type (tiles have no icons — the flat
// color IS the art); inspector joins all four gen_terrain tables into one
// card: behavior row, hover desc, structure badge, station glow.
//
// T3 (editing + SAVE): color and glow reuse the pixel editor's RGB sliders,
// flags are checkbox toggles, move_cost/dps/drop_pct are the recipe editor's
// spinner (temp'd through int — every value on disk today is a small whole
// number), drop item goes through the shared item-picker modal.  Name and
// desc stay non-editable this phase (no text-input widget yet) and round-trip
// through emit untouched.  SAVE validates then rewrites gen_terrain.odin
// through the same emit_terrain --extract uses.

import "core:fmt"
import game "../../src"
import rl "vendor:raylib"

Tile_Work :: struct {
	behavior:    [game.Tile_Type]game.Terrain_Behavior,
	desc:        [game.Tile_Type]string,
	is_struct:   [game.Tile_Type]bool,
	glow:        [game.Tile_Type]rl.Color,
	dirty:       bool,
	status:      string,
	picker_open: bool,
}

// What each Terrain_Flag actually does, verified against every read site in
// src/ (not aspirational — Walkable/Flammable/Animated are declared but no
// system currently checks them, and the hint says so honestly).
terrain_flag_hint := [game.Terrain_Flag]string{
	.Solid        = "Blocks movement and anchors gravity/fluid flow (is_solid, read by physics, mining, fluids, pathing). The load-bearing collision flag.",
	.Walkable     = "Documentation only today - no system currently reads this flag. Passability actually comes from NOT having .Solid.",
	.Swimmable    = "Grants swim physics while a body overlaps it: slower move/fall and a repeatable no-footing swim-stroke jump (update_player).",
	.Damaging     = "Deals damage_per_second to any body standing in the tile (update_player's hazard read). Needs damage_per_second > 0 to do anything.",
	.Flammable    = "Documentation only today - no system currently reads this flag; nothing spreads fire via it yet.",
	.Mineable     = "Can be mined: pickaxe/wand (mining.odin), builders (enemy.odin), and structural gravity's faller test all gate on this.",
	.Placeable    = "Marks a player-built structure - if an enemy/Garm smashes it, its item drops instead of vanishing silently (smash_tile).",
	.Animated     = "Documentation only today - no system currently reads this flag.",
	.Falls        = "Unconditional faller: drops when its support is cut, no matter who placed it (gravity.odin) - trees, placed wood/leaves, dirt.",
	.Falls_Placed = "Falls the same way, but ONLY on a player-placed cell (Tile_Flag.Placed) - natural terrain of this type never caves in on its own.",
	.Settles      = "A faller re-stacks as a solid TILE on landing (sand-style), instead of crumbling into item drops like a felled tree.",
}

twork: Tile_Work

tile_work_init :: proc() {
	twork = {}
	twork.behavior = game.terrain_table
	for d, t in game.terrain_desc do twork.desc[t] = d
	for sv, t in game.is_structure_tile do twork.is_struct[t] = sv
	for c, t in game.station_glow do twork.glow[t] = c
	twork.dirty = false
	twork.status = ""
	twork.picker_open = false
}

tile_touch :: proc() {
	twork.dirty = true
}

// Validation: a tile always needs a name (SAVE never introduces one, but a
// future append could), a .Damaging tile needs actual damage, and a glow row
// can't sit at zero alpha (that's indistinguishable from "not a station").
tile_validate :: proc() -> (ok: bool, msg: string) {
	for b, t in twork.behavior {
		if b.name == "" do return false, fmt.aprintf("%v: tile has no name", t)
		if .Damaging in b.flags && b.damage_per_second <= 0 do return false, fmt.aprintf("%s: .Damaging tile needs damage_per_second > 0", b.name)
	}
	for c, t in twork.glow {
		if c != {} && c.a == 0 do return false, fmt.aprintf("%v: station_glow row has alpha 0 (would emit as absent)", t)
	}
	return true, ""
}

tile_save :: proc() {
	if wizard_lock {
		twork.status = "waiting for the rebuild after item creation"
		return
	}
	if vok, msg := tile_validate(); !vok {
		twork.status = fmt.aprintf("REFUSED - %s", msg)
		return
	}
	content := emit_terrain(&g_notes, &twork.behavior, &twork.desc, &twork.is_struct, &twork.glow)
	if write_gen_file("gen_terrain.odin", content) {
		twork.dirty = false
		twork.status = "saved - the watcher rebuild lands you back here"
	} else {
		twork.status = "WRITE FAILED - see console"
	}
}

// Tile cells are wider than the item browser's: each carries its name under
// the swatch (Glenn's call — a bare palette didn't read), so 6 columns of
// 100 px instead of 8 of 52.
TILE_COLS  :: 6
TCELL_W    :: 100
TCELL_H    :: 64
TSWATCH    :: 40

// Ellipsis-truncate text to fit width at font size fs (temp-allocated).
fit_text :: proc(text: string, width, fs: i32) -> cstring {
	c := fmt.ctprintf("%s", text)
	if rl.MeasureText(c, fs) <= width do return c
	n := len(text)
	for n > 1 {
		n -= 1
		c = fmt.ctprintf("%s..", text[:n])
		if rl.MeasureText(c, fs) <= width do return c
	}
	return c
}

tiles_frame :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	// While the drop-item picker modal is up, everything beneath ignores the mouse.
	emouse := twork.picker_open ? rl.Vector2{-9999, -9999} : mouse

	// Browser grid: every tile, enum order, click to select. Swatches read
	// from the working copy so an in-progress color edit previews live.
	gy := i32(TOP_BAR) + 16
	hovered := false
	hovered_tile: game.Tile_Type
	for t in game.Tile_Type {
		idx := int(t)
		cx := i32(BROWSER_X + (idx % TILE_COLS) * TCELL_W)
		cy := gy + i32(idx / TILE_COLS) * TCELL_H
		cell := rl.Rectangle{f32(cx), f32(cy), TCELL_W, TCELL_H}
		hov := rl.CheckCollisionPointRec(emouse, cell)
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
		sx := cx + (TCELL_W - TSWATCH)/2
		draw_checker(sx, cy + 4, TSWATCH, TSWATCH)
		rl.DrawRectangle(sx, cy + 4, TSWATCH, TSWATCH, twork.behavior[t].color)
		// Name under the swatch; the hover footer carries the full text.
		name := fit_text(twork.behavior[t].name, TCELL_W - 8, 10)
		on := t == s.sel_tile || hov
		rl.DrawText(name, cx + (TCELL_W - rl.MeasureText(name, 10))/2, cy + TSWATCH + 8,
			10, on ? rl.Color{225, 228, 235, 255} : rl.Color{150, 155, 165, 255})
	}
	if hovered {
		rl.DrawText(fmt.ctprintf("%s  (.%v, ordinal %d)", twork.behavior[hovered_tile].name, hovered_tile, int(hovered_tile)),
			BROWSER_X, i32(sh) - 26, 14, {200, 203, 210, 255})
		hdesc := twork.desc[hovered_tile]
		if hdesc == "" do hdesc = game.tile_desc(hovered_tile)
		draw_hint(mouse, hdesc)
	}

	tile_inspector_frame(s, f32(BROWSER_X + TILE_COLS*TCELL_W + 28), sw, sh, emouse)

	// Save / revert / status, top-right like the other editable tabs.
	sx := i32(sw) - 260
	if button(sx, i32(TOP_BAR) + 12, twork.dirty ? cstring("SAVE  (rewrites gen_terrain.odin)") : cstring("SAVED"), emouse, twork.dirty,
		hint = "Validate every tile (nonempty name, .Damaging needs damage, no zero-alpha glow) and rewrite gen_terrain.odin. The watcher rebuilds and swaps the window.") {
		tile_save()
	}
	if button(sx, i32(TOP_BAR) + 46, "REVERT ALL EDITS", emouse, twork.dirty,
		hint = "Discard every unsaved terrain edit across all tiles and reload from the compiled tables.") {
		tile_work_init()
		twork.status = "reverted to the compiled tables"
	}
	if twork.status != "" {
		for l, i in wrap_text(twork.status, 250, 12) {
			rl.DrawText(fmt.ctprintf("%s", l), sx, i32(TOP_BAR) + 80 + i32(i)*16, 12,
				twork.dirty ? rl.Color{225, 228, 235, 255} : rl.Color{105, 185, 105, 255})
		}
	}

	// The modal, over everything.
	if twork.picker_open {
		picked, done := draw_item_picker("PICK THE DROP ITEM", mouse, sw, sh)
		if done {
			if picked != .None {
				twork.behavior[s.sel_tile].drop_item = picked
				tile_touch()
			}
			twork.picker_open = false
		}
	}
}

tile_inspector_frame :: proc(s: ^Studio, x0, sw, sh: f32, mouse: rl.Vector2) {
	t := s.sel_tile
	beh := &twork.behavior[t]
	x := i32(x0)
	y := i32(TOP_BAR) + 20

	// Name/desc stay non-editable this phase (no text-input widget yet).
	rl.DrawText(fmt.ctprintf("%s", beh.name), x, y, 26, {235, 235, 240, 255})
	rl.DrawText(fmt.ctprintf(".%v  (ordinal %d)", t, int(t)), x, y + 30, 12, {120, 125, 138, 255})
	y += 56

	// The terrain color at three scales on a checker, then RGB sliders below —
	// the pixel editor's palette-slot editor verbatim.
	px := x
	for size in ([3]i32{24, 48, 96}) {
		draw_checker(px, y, size + 12, 108)
		rl.DrawRectangle(px + 6, y + (108 - size)/2, size, size, beh.color)
		px += size + 24
	}
	rl.DrawText(fmt.ctprintf("color %d,%d,%d,%d", beh.color.r, beh.color.g, beh.color.b, beh.color.a), px, y + 4, 12, {150, 155, 165, 255})
	y += 118
	cchanged := false
	cchanged |= slider(x, y, "R", &beh.color.r, mouse, "Red channel of the tile's color - a tile has no icon, so this IS its whole art."); y += 22
	cchanged |= slider(x, y, "G", &beh.color.g, mouse, "Green channel of the tile's color."); y += 22
	cchanged |= slider(x, y, "B", &beh.color.b, mouse, "Blue channel of the tile's color."); y += 22
	if cchanged {
		if beh.color.a == 0 do beh.color.a = 255
		tile_touch()
	}
	y += 14

	// Flags as clickable toggles.
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
		box := rl.Rectangle{f32(cx), f32(y), f32(w), 20}
		if rl.CheckCollisionPointRec(mouse, box) {
			draw_hint(mouse, terrain_flag_hint[f])
			if rl.IsMouseButtonPressed(.LEFT) {
				if on {
					beh.flags -= {f}
				} else {
					beh.flags += {f}
				}
				tile_touch()
				on = !on
			}
		}
		rl.DrawRectangleLinesEx({f32(cx), f32(y), 14, 14}, 1, on ? rl.Color{245, 205, 90, 255} : rl.Color{80, 84, 96, 255})
		if on do rl.DrawRectangle(cx + 3, y + 3, 8, 8, {245, 205, 90, 255})
		rl.DrawText(label, cx + 20, y + 1, 13, on ? rl.Color{225, 228, 235, 255} : rl.Color{100, 104, 116, 255})
		cx += w
	}
	y += 30

	// Structure protection toggle (is_structure_tile).
	rl.DrawText("STRUCTURE", x, y + 4, 13, {245, 205, 90, 255})
	slabel := twork.is_struct[t] ? cstring("YES - wand-safe, reclaim with the pick") : cstring("NO - an ordinary mineable tile")
	if button(x + 110, y, slabel, mouse, true, twork.is_struct[t],
		hint = "Toggles is_structure_tile: a wand refuses to fire on this tile, and taking it apart needs a slow Shift-hold reclaim with the pick instead of a normal swing.") {
		twork.is_struct[t] = !twork.is_struct[t]
		tile_touch()
	}
	y += 36

	// move_cost / damage_per_second: small stepper arrows over a temp int —
	// every value on disk today is a small whole number.
	mc := int(beh.move_cost)
	rl.DrawText("move cost", x, y + 6, 12, {120, 125, 138, 255})
	if spinner(x + 110, y, &mc, 0, 8, mouse, "0 = solid (no movement through it), 1 = normal speed, 2 = slow (e.g. water). Read by player/enemy movement.") {
		beh.move_cost = f32(mc)
		tile_touch()
	}
	if beh.move_cost == 0 do rl.DrawText("(solid)", x + 260, y + 6, 12, {150, 155, 165, 255})
	y += 30

	dps := int(beh.damage_per_second)
	rl.DrawText("damage/s", x, y + 6, 12, {120, 125, 138, 255})
	if spinner(x + 110, y, &dps, 0, 20, mouse, "Damage per second dealt to any body standing in the tile - only takes effect with the .Damaging flag also set.") {
		beh.damage_per_second = f32(dps)
		tile_touch()
	}
	if !(.Damaging in beh.flags) && beh.damage_per_second > 0 {
		rl.DrawText("(no effect without .Damaging)", x + 260, y + 6, 12, {150, 155, 165, 255})
	}
	y += 36

	// Drop item as its real icon — click it to jump to the ITEMS tab; PICK
	// reassigns through the shared item-picker modal.
	rl.DrawText("DROPS", x, y, 13, {245, 205, 90, 255})
	y += 20
	if beh.drop_item != .None {
		cell := rl.Rectangle{f32(x), f32(y), 32, 32}
		hov := rl.CheckCollisionPointRec(mouse, cell)
		if hov && rl.IsMouseButtonPressed(.LEFT) {
			s.selected = beh.drop_item
			s.tab = .Items
		}
		draw_checker(x, y, 32, 32)
		game.draw_item_icon(beh.drop_item, x + 2, y + 2, 28)
		if hov do rl.DrawRectangleLinesEx(cell, 1, {245, 205, 90, 255})
		rl.DrawText(fmt.ctprintf("%s", item_name(beh.drop_item)), x + 40, y + 2, 13,
			hov ? rl.Color{245, 205, 90, 255} : rl.Color{140, 185, 225, 255})
		dp := int(beh.drop_pct)
		rl.DrawText("chance", x + 40, y + 20, 11, {120, 125, 138, 255})
		if spinner(x + 92, y + 14, &dp, 0, 100, mouse, "Percent chance the drop appears when mined; 0 means it always drops.") {
			beh.drop_pct = u8(dp)
			tile_touch()
		}
		rl.DrawText(beh.drop_pct == 0 ? "%  (0 = always)" : "%", x + 240, y + 20, 11, {120, 125, 138, 255})
		if button(x + 320, y + 2, "PICK", mouse, hint = "Choose a different item for this tile to drop when mined.") do twork.picker_open = true
		if button(x + 380, y + 2, "CLEAR", mouse, hint = "Mining this tile will yield nothing.") {
			beh.drop_item = .None
			beh.drop_pct = 0
			tile_touch()
		}
		y += 40
	} else {
		rl.DrawText("- nothing -", x, y, 13, {90, 95, 110, 255})
		if button(x + 120, y - 4, "PICK", mouse, hint = "Choose the item this tile drops when mined.") do twork.picker_open = true
		y += 28
	}
	y += 12

	// Station glow membership + color (the ambience-sparks contract).
	rl.DrawText("STATION GLOW", x, y, 13, {245, 205, 90, 255})
	y += 20
	gp := &twork.glow[t]
	if gp^ != {} {
		rl.DrawRectangle(x, y, 20, 20, gp^)
		gchanged := false
		gchanged |= slider(x + 30, y, "R", &gp.r, mouse, "Red channel of the station's ambience glow color."); y += 22
		gchanged |= slider(x + 30, y, "G", &gp.g, mouse, "Green channel of the station's ambience glow color."); y += 22
		gchanged |= slider(x + 30, y, "B", &gp.b, mouse, "Blue channel of the station's ambience glow color."); y += 22
		if gchanged {
			if gp.a == 0 do gp.a = 255
			tile_touch()
		}
		y += 6
		if button(x, y, "DISABLE GLOW", mouse,
			hint = "Remove the ambience glow - the tile still works exactly the same, it just won't visually announce itself as a station.") {
			gp^ = {}
			tile_touch()
		}
	} else {
		rl.DrawText("not a station", x + 30, y, 13, {150, 155, 165, 255})
		if button(x + 200, y - 4, "ENABLE GLOW", mouse,
			hint = "Turn this tile into a station: a dark base with a breathing glow in the given color, plus periodic rising sparks (station_glow, update_ambience).") {
			gp^ = {245, 205, 90, 255}
			tile_touch()
		}
	}
	y += 40

	// The hover line the player sees, wrapped; sparse terrain_desc rows fall
	// back to the drop item's desc (tile_desc), flagged when they do. Read-only.
	desc := twork.desc[t]
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
