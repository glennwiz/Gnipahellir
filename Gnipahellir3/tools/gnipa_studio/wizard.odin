package gnipa_studio

// The new-item wizard: the one place that touches a hand-owned file.  CREATE
// inserts one enum line at the `<gen:item-append>` marker in src/types.odin
// (exactly-one-marker asserted, refuse-and-report on any anomaly) and rewrites
// the gen files with the pending item's rows appended — one Save, one rebuild,
// and the item is a first-class citizen everywhere (appending an Item is
// save-free since v24's MAX_ITEM_SLOTS ceiling).
//
// CREATE is a global save: it emits icons and recipes from the CURRENT working
// copies, unsaved edits included, so the multi-file write stays atomic in
// content.  Afterwards every save button locks until the watcher rebuild
// swaps the process — a stale emit could not know the new enum member.
//
// Behavior beyond data (a new tile to place, machine ticks, predicates) still
// needs code — the wizard says so instead of pretending.

import "core:fmt"
import "core:os"
import "core:strings"
import game "../../src"
import rl "vendor:raylib"

wizard_lock: bool // set after CREATE; cleared only by the process restart

Text_Field :: struct {
	buf: [240]u8,
	len: int,
}

tf_text :: proc(tf: ^Text_Field) -> string {
	return string(tf.buf[:tf.len])
}

tf_set :: proc(tf: ^Text_Field, s: string) {
	tf.len = min(len(s), len(tf.buf))
	copy(tf.buf[:tf.len], s)
}

Wizard_Work :: struct {
	ident:        Text_Field,
	disp:         Text_Field,
	desc:         Text_Field,
	color:        rl.Color,
	place:        game.Tile_Type,
	equip:        game.Equip_Slot,
	icon:         Icon_View,
	icon_src:     game.Item,
	has_recipe:   bool,
	station:      game.Station,
	result_count: int,
	ings:         [3]game.Ingredient,
	unlock:       game.Item,
	focus:        int, // -1 none; 0 ident, 1 display name, 2 desc
	picker:       int, // PICKER_CLOSED, -1 icon donor, -2 unlock, 0..2 ingredients
	status:       string,
}

wwork: Wizard_Work

wizard_work_init :: proc() {
	wwork = {}
	wwork.color = {200, 200, 210, 255}
	wwork.station = .Bench
	wwork.result_count = 1
	wwork.focus = -1
	wwork.picker = PICKER_CLOSED
}

wizard_typing :: proc() -> bool {
	return wwork.focus >= 0
}

// ─── Validation + the types.odin insert ───────────────────────────────────────

ident_valid :: proc(s: string) -> bool {
	if len(s) == 0 do return false
	if !(s[0] >= 'A' && s[0] <= 'Z') do return false // uppercase start dodges keywords
	for i in 0 ..< len(s) {
		c := s[i]
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
		if !ok do return false
	}
	return true
}

wizard_validate :: proc() -> (ok: bool, msg: string) {
	ident := tf_text(&wwork.ident)
	if !ident_valid(ident) do return false, "identifier must be Upper_Snake style: A-Z start, then letters/digits/_"
	for it in game.Item {
		if fmt.tprintf("%v", it) == ident do return false, fmt.aprintf("Item.%s already exists", ident)
	}
	if len(game.Item) + 1 > game.MAX_ITEM_SLOTS do return false, "item slots exhausted (MAX_ITEM_SLOTS) - raise the ceiling first"
	if wwork.disp.len == 0 do return false, "display name is required"
	if wwork.desc.len == 0 do return false, "description is required (the hover-description test enforces it)"
	if wwork.icon_src == .None do return false, "copy icon art from an item first (the icon test refuses invisible items)"
	if wwork.has_recipe {
		ings := 0
		for ing in wwork.ings do if ing.item != .None do ings += 1
		if ings == 0 do return false, "the recipe needs at least one ingredient (or turn the recipe off)"
	}
	return true, ""
}

types_append_item :: proc(ident: string) -> (ok: bool, msg: string) {
	path :: SRC_DIR + "types.odin"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil do return false, "cannot read types.odin"
	text := string(data)
	marker := "// <gen:item-append>"
	if n := strings.count(text, marker); n != 1 {
		return false, fmt.aprintf("expected exactly one %s marker in types.odin, found %d", marker, n)
	}
	idx := strings.index(text, marker)
	// Back up to the start of the marker's line so the insert lands above it.
	line_start := idx
	for line_start > 0 && text[line_start-1] != '\n' do line_start -= 1
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	strings.write_string(&b, text[:line_start])
	fmt.sbprintf(&b, "    %s, // (appended via gnipa_studio: item ordinals are serialized)\n", ident)
	strings.write_string(&b, text[line_start:])
	if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); werr != nil {
		return false, "FAILED to write types.odin"
	}
	return true, ""
}

wizard_create :: proc() {
	if wizard_lock {
		wwork.status = "waiting for the rebuild after the previous creation"
		return
	}
	if vok, msg := wizard_validate(); !vok {
		wwork.status = fmt.aprintf("REFUSED - %s", msg)
		return
	}
	ident := tf_text(&wwork.ident)
	p := Pending_Item{
		ident        = ident,
		info         = {tf_text(&wwork.disp), wwork.color, wwork.place, tf_text(&wwork.desc)},
		icon         = wwork.icon,
		equip        = wwork.equip,
		has_recipe   = wwork.has_recipe,
		result_count = wwork.result_count,
		station      = wwork.station,
		ings         = wwork.ings,
		unlock       = wwork.unlock,
	}
	if tok, msg := types_append_item(ident); !tok {
		wwork.status = fmt.aprintf("REFUSED - %s (nothing was written)", msg)
		return
	}
	pend := []Pending_Item{p}
	ok := write_gen_file("gen_items.odin", emit_items(&g_notes, pend))
	ok &&= write_gen_file("gen_item_icons.odin", emit_icons(&g_notes, &work.views, work.shapes[:], pend))
	ok &&= write_gen_file("gen_recipes.odin", emit_recipes(&g_notes, rwork.recipes[:rwork.recipe_count], &rwork.unlock, rwork.smelt[:rwork.smelt_count], pend))
	if !ok {
		wwork.status = "PARTIAL WRITE - the build will fail loudly; fix via git and re-run"
		return
	}
	work.dirty = false
	rwork.dirty = false
	wizard_lock = true
	wwork.status = fmt.aprintf("created %s - rebuild incoming; refine its icon in the PIXEL tab", ident)
}

// ─── The tab ──────────────────────────────────────────────────────────────────

text_field :: proc(x, y, w: i32, tf: ^Text_Field, id: int, mouse: rl.Vector2) {
	r := rl.Rectangle{f32(x), f32(y), f32(w), 26}
	if rl.IsMouseButtonPressed(.LEFT) {
		if rl.CheckCollisionPointRec(mouse, r) do wwork.focus = id
		else if wwork.focus == id do wwork.focus = -1
	}
	focused := wwork.focus == id
	rl.DrawRectangleRec(r, {26, 28, 36, 255})
	rl.DrawRectangleLinesEx(r, 1, focused ? {245, 205, 90, 255} : {90, 95, 110, 255})
	shown := tf_text(tf)
	// keep the tail visible when the text outgrows the box
	for rl.MeasureText(fmt.ctprintf("%s", shown), 13) > w - 16 && len(shown) > 1 do shown = shown[1:]
	rl.DrawText(fmt.ctprintf("%s%s", shown, focused ? "_" : ""), x + 8, y + 7, 13, {225, 228, 235, 255})
}

wizard_frame :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	emouse := wwork.picker != PICKER_CLOSED ? rl.Vector2{-9999, -9999} : mouse

	// keyboard into the focused field
	if wwork.focus >= 0 {
		tf := wwork.focus == 0 ? &wwork.ident : wwork.focus == 1 ? &wwork.disp : &wwork.desc
		for {
			c := rl.GetCharPressed()
			if c == 0 do break
			if c >= 32 && c < 127 && tf.len < len(tf.buf) {
				tf.buf[tf.len] = u8(c)
				tf.len += 1
			}
		}
		if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && tf.len > 0 do tf.len -= 1
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.ESCAPE) do wwork.focus = -1
	}

	x := i32(20)
	y := i32(TOP_BAR) + 14
	rl.DrawText("NEW ITEM WIZARD", x, y, 18, {235, 235, 240, 255})
	rl.DrawText(fmt.ctprintf("%d / %d item slots used - appending is save-free (v24 ceiling)", len(game.Item), game.MAX_ITEM_SLOTS),
		x + 220, y + 4, 12, {120, 125, 138, 255})
	y += 34

	rl.DrawText("enum identifier", x, y + 6, 12, {120, 125, 138, 255})
	text_field(x + 130, y, 240, &wwork.ident, 0, emouse)
	valid := ident_valid(tf_text(&wwork.ident))
	if wwork.ident.len > 0 {
		rl.DrawText(valid ? "ok" : "A-Z start, letters/digits/_", x + 380, y + 7, 12,
			valid ? rl.Color{105, 185, 105, 255} : rl.Color{225, 120, 100, 255})
	}
	y += 34
	rl.DrawText("display name", x, y + 6, 12, {120, 125, 138, 255})
	text_field(x + 130, y, 240, &wwork.disp, 1, emouse)
	if button(x + 380, y, "derive from ident", emouse, wwork.ident.len > 0) {
		mirrored, _ := strings.replace_all(tf_text(&wwork.ident), "_", " ", context.temp_allocator)
		tf_set(&wwork.disp, mirrored)
	}
	y += 34
	rl.DrawText("description", x, y + 6, 12, {120, 125, 138, 255})
	text_field(x + 130, y, 560, &wwork.desc, 2, emouse)
	y += 40

	rl.DrawText("flat color", x, y + 6, 12, {120, 125, 138, 255})
	rl.DrawRectangle(x + 130, y, 26, 70, wwork.color)
	cy := y
	slider(x + 170, cy, "R", &wwork.color.r, emouse); cy += 22
	slider(x + 170, cy, "G", &wwork.color.g, emouse); cy += 22
	slider(x + 170, cy, "B", &wwork.color.b, emouse)
	y += 80

	if button(x, y, fmt.ctprintf("places tile: %s", wwork.place == .Air ? "none (not placeable)" : game.terrain_table[wwork.place].name), emouse) {
		wwork.place = game.Tile_Type((int(wwork.place) + 1) % len(game.Tile_Type))
	}
	if button(x + 320, y, "<", emouse) {
		wwork.place = game.Tile_Type((int(wwork.place) + len(game.Tile_Type) - 1) % len(game.Tile_Type))
	}
	if button(x + 360, y, fmt.ctprintf("equip slot: %v", wwork.equip), emouse) {
		wwork.equip = game.Equip_Slot((int(wwork.equip) + 1) % len(game.Equip_Slot))
	}
	y += 38

	// Icon: borrowed art, refined later in the pixel tab.
	rl.DrawText("ICON", x, y, 13, {245, 205, 90, 255})
	y += 20
	if wwork.icon_src != .None {
		draw_checker(x, y, 60, 60)
		draw_view_icon(&wwork.icon, x + 6, y + 6, 48)
		rl.DrawText(fmt.ctprintf("copied from %s - refine in the PIXEL tab after create", item_name(wwork.icon_src)),
			x + 72, y + 20, 12, {150, 155, 165, 255})
	}
	if button(x + (wwork.icon_src != .None ? 500 : 0), y + 16, "COPY ART FROM ITEM", emouse) do wwork.picker = -1
	y += 76

	// Optional recipe.
	if button(x, y, wwork.has_recipe ? cstring("RECIPE: yes") : cstring("RECIPE: none"), emouse, true, wwork.has_recipe) {
		wwork.has_recipe = !wwork.has_recipe
	}
	y += 34
	if wwork.has_recipe {
		rl.DrawText("result count", x, y + 6, 12, {120, 125, 138, 255})
		spinner(x + 100, y, &wwork.result_count, 1, 99, emouse)
		if button(x + 200, y, fmt.ctprintf("station: %s", station_label[station_ex(wwork.station)]), emouse) {
			for st, i in station_cycle {
				if st == wwork.station {
					wwork.station = station_cycle[(i + 1) % len(station_cycle)]
					break
				}
			}
		}
		y += 34
		for slot in 0 ..< 3 {
			ing := &wwork.ings[slot]
			if ing.item != .None {
				game.draw_item_icon(ing.item, x, y, 24)
				rl.DrawText(fmt.ctprintf("%s", item_name(ing.item)), x + 30, y + 5, 12, {225, 228, 235, 255})
				spinner(x + 200, y, &ing.count, 1, 999, emouse)
				if button(x + 290, y, "PICK", emouse) do wwork.picker = slot
				if button(x + 350, y, "CLEAR", emouse) do ing^ = {}
			} else {
				rl.DrawText("- empty -", x + 30, y + 5, 12, {90, 95, 110, 255})
				if button(x + 290, y, "PICK", emouse) do wwork.picker = slot
			}
			y += 32
		}
		if gate := wwork.unlock; gate != .None {
			game.draw_item_icon(gate, x, y, 24)
			rl.DrawText(fmt.ctprintf("unlocked by holding %s", item_name(gate)), x + 30, y + 5, 12, {225, 228, 235, 255})
			if button(x + 290, y, "PICK", emouse) do wwork.picker = -2
			if button(x + 350, y, "CLEAR", emouse) do wwork.unlock = .None
		} else {
			rl.DrawText("unlock gate: known from the start", x + 30, y + 5, 12, {150, 155, 165, 255})
			if button(x + 290, y, "PICK", emouse) do wwork.picker = -2
		}
		y += 40
	}

	rl.DrawText("Behavior beyond data (a placeable's new tile, machine ticks, predicates like", x, y, 11, {120, 125, 138, 255})
	rl.DrawText("is_rune_scroll) still needs code - the wizard creates the data-complete item.", x, y + 14, 11, {120, 125, 138, 255})
	y += 40

	if button(x, y, wizard_lock ? cstring("CREATED - waiting for rebuild") : cstring("CREATE ITEM  (writes types.odin + gen files, saves everything)"), emouse, !wizard_lock) {
		wizard_create()
	}
	if wwork.status != "" {
		rl.DrawText(fmt.ctprintf("%s", wwork.status), x, i32(sh) - 26, 13,
			wizard_lock ? rl.Color{105, 185, 105, 255} : rl.Color{225, 228, 235, 255})
	}

	// The modal.
	if wwork.picker != PICKER_CLOSED {
		title: cstring = wwork.picker == -1 ? "COPY ICON ART FROM" : wwork.picker == -2 ? "PICK THE UNLOCK GATE" : "PICK THE INGREDIENT"
		picked, done := draw_item_picker(title, mouse, sw, sh)
		if done {
			if picked != .None {
				switch wwork.picker {
				case -1:
					wwork.icon = work.views[picked]
					wwork.icon_src = picked
				case -2:
					wwork.unlock = picked
				case:
					if wwork.picker >= 0 && wwork.picker < 3 {
						if wwork.ings[wwork.picker].item == .None do wwork.ings[wwork.picker].count = 1
						wwork.ings[wwork.picker].item = picked
					}
				}
			}
			wwork.picker = PICKER_CLOSED
		}
	}
}

// --test-wizard: headless end-to-end — create a real item, exercising the
// enum insert and every pending-row emitter.  Reverted afterwards via git.
test_wizard :: proc() -> bool {
	work_init()
	recipe_work_init()
	wizard_work_init()
	tf_set(&wwork.ident, "Studio_Test_Gem")
	tf_set(&wwork.disp, "Studio Test Gem")
	tf_set(&wwork.desc, "A wizard-made test gem. If you can read this, the studio works.")
	wwork.color = {120, 220, 200, 255}
	wwork.icon = work.views[game.Item.Emerald]
	wwork.icon_src = .Emerald
	wwork.has_recipe = true
	wwork.station = .Bench
	wwork.ings[0] = {.Stone_Block, 2}
	wwork.unlock = .Emerald
	wizard_create()
	fmt.printfln("test-wizard: %s", wwork.status)
	return wizard_lock
}
