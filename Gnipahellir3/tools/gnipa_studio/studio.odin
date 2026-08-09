package gnipa_studio

// The studio window: a tab bar over two views.
//   ITEMS — browsable icon grid + an inspector for the selected item.
//   DAG   — the recipe graph (dag.odin).
// Read-only in Phase B; the pixel editor (Phase C) hangs off the inspector.
//
// Session state (tab, selection) persists in session.dat beside the tool and
// is written on every change — the run.ps1 watcher kills this process without
// warning on rebuild, so write-on-change is the only reliable save point.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import game "../../src"
import rl "vendor:raylib"

STUDIO_W :: 1600
STUDIO_H :: 900
TOP_BAR  :: f32(52)

BROWSER_X    :: 16
BROWSER_COLS :: 8
BCELL        :: 52
BICON        :: 44

Tab :: enum i32 {
	Items,
	DAG,
}

// ─── Cross-references (who makes what, who uses what) ─────────────────────────

Producer :: struct {
	station:   Station_Ex,
	out_count: int,
	ings:      [3]game.Ingredient,
}

MAX_PRODUCERS :: 4
MAX_USERS     :: 24

xref_producers: [game.Item][MAX_PRODUCERS]Producer
xref_prod_len:  [game.Item]int
xref_users:     [game.Item][MAX_USERS]game.Item
xref_user_len:  [game.Item]int

xref_init :: proc() {
	add_prod :: proc(it: game.Item, p: Producer) {
		if xref_prod_len[it] < MAX_PRODUCERS {
			xref_producers[it][xref_prod_len[it]] = p
			xref_prod_len[it] += 1
		}
	}
	add_user :: proc(ing, result: game.Item) {
		for u in xref_users[ing][:xref_user_len[ing]] do if u == result do return
		if xref_user_len[ing] < MAX_USERS {
			xref_users[ing][xref_user_len[ing]] = result
			xref_user_len[ing] += 1
		}
	}
	for r in game.recipe_table {
		add_prod(r.result, {station_ex(r.station), r.result_count, r.ingredients})
		for ing in r.ingredients do if ing.item != .None do add_user(ing.item, r.result)
	}
	for r in game.smelt_table {
		add_prod(r.bar, {.Smelter, 1, {{r.ore, r.ore_per_bar}, {}, {}}})
		add_user(r.ore, r.bar)
	}
}

producer_count :: proc(it: game.Item) -> int {
	return xref_prod_len[it]
}

producers_of :: proc(it: game.Item) -> []Producer {
	return xref_producers[it][:xref_prod_len[it]]
}

first_producer_station :: proc(it: game.Item) -> Station_Ex {
	if xref_prod_len[it] == 0 do return .Hand
	return xref_producers[it][0].station
}

// How many items share this icon's shape grid (Phase C's shared-shape banner).
shape_shared_count :: proc(grid: game.Icon_Grid) -> int {
	n := 0
	for icon, it in game.item_icons {
		if it != .None && icon.grid == grid do n += 1
	}
	return n
}

// ─── Session ──────────────────────────────────────────────────────────────────

SESSION_VERSION :: i32(1)

Session :: struct #packed {
	version:  i32,
	tab:      Tab,
	selected: i32,
}

session_load :: proc(s: ^Studio) {
	data, err := os.read_entire_file_from_path(TOOL_DIR + "session.dat", context.allocator)
	if err != nil || len(data) != size_of(Session) do return
	ses := (^Session)(raw_data(data))^
	if ses.version != SESSION_VERSION do return
	if ses.selected >= 0 && int(ses.selected) < len(game.Item) do s.selected = game.Item(ses.selected)
	s.tab = ses.tab
}

session_save :: proc(s: ^Studio) {
	ses := Session{SESSION_VERSION, s.tab, i32(s.selected)}
	_ = os.write_entire_file(TOOL_DIR + "session.dat", mem.ptr_to_bytes(&ses))
}

// ─── The shell ────────────────────────────────────────────────────────────────

Studio :: struct {
	tab:      Tab,
	selected: game.Item,
	dag:      Dag_State,
}

studio_run :: proc(shot := false) {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(STUDIO_W, STUDIO_H, "Gnipa Studio")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL) // ESC clears selection; close via the window X

	xref_init()

	s: Studio
	s.selected = .Sword
	session_load(&s)
	dag_init(&s.dag, STUDIO_W, STUDIO_H)
	last_saved := Session{}
	frames := 0

	for !rl.WindowShouldClose() {
		sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		mouse := rl.GetMousePosition()

		if rl.IsKeyPressed(.ONE) do s.tab = .Items
		if rl.IsKeyPressed(.TWO) do s.tab = .DAG

		rl.BeginDrawing()
		rl.ClearBackground({24, 26, 32, 255})

		switch s.tab {
		case .Items:
			items_frame(&s, sw, sh, mouse)
		case .DAG:
			focus := dag_frame(&s.dag, TOP_BAR)
			if focus != .None do s.selected = focus
		}

		draw_top_bar(&s, sw, mouse)
		rl.EndDrawing()
		free_all(context.temp_allocator)

		now := Session{SESSION_VERSION, s.tab, i32(s.selected)}
		if now != last_saved {
			session_save(&s)
			last_saved = now
		}

		frames += 1
		if shot {
			if frames == 5 {
				rl.TakeScreenshot("studio_shot_items.png")
				s.tab = .DAG
			} else if frames == 10 {
				rl.TakeScreenshot("studio_shot_dag.png")
				break
			}
		}
	}
}

draw_top_bar :: proc(s: ^Studio, sw: f32, mouse: rl.Vector2) {
	rl.DrawRectangle(0, 0, i32(sw), i32(TOP_BAR), {18, 20, 26, 255})
	rl.DrawLine(0, i32(TOP_BAR), i32(sw), i32(TOP_BAR), {60, 64, 76, 255})

	labels := [Tab]cstring{.Items = "ITEMS [1]", .DAG = "RECIPE DAG [2]"}
	x := i32(16)
	for tab in Tab {
		w := rl.MeasureText(labels[tab], 16) + 28
		r := rl.Rectangle{f32(x), 10, f32(w), 32}
		active := s.tab == tab
		hov := rl.CheckCollisionPointRec(mouse, r)
		if hov && rl.IsMouseButtonPressed(.LEFT) do s.tab = tab
		rl.DrawRectangleRec(r, active ? {45, 48, 58, 255} : {26, 28, 36, 255})
		rl.DrawRectangleLinesEx(r, 1, active ? {245, 205, 90, 255} : (hov ? {150, 155, 165, 255} : {60, 64, 76, 255}))
		rl.DrawText(labels[tab], x + 14, 18, 16, active ? rl.Color{235, 235, 240, 255} : rl.Color{150, 155, 165, 255})
		x += w + 10
	}

	title :: "GNIPA STUDIO"
	rl.DrawText(title, i32(sw) - rl.MeasureText(title, 20) - 16, 16, 20, {235, 235, 240, 255})
}

// ─── ITEMS tab: browser + inspector ───────────────────────────────────────────

items_frame :: proc(s: ^Studio, sw, sh: f32, mouse: rl.Vector2) {
	// Browser grid: every item but .None, enum order, click to select.
	gy := i32(TOP_BAR) + 16
	hovered: game.Item = .None
	for it in game.Item {
		if it == .None do continue
		idx := int(it) - 1
		cx := i32(BROWSER_X + (idx % BROWSER_COLS) * BCELL)
		cy := gy + i32(idx / BROWSER_COLS) * BCELL
		cell := rl.Rectangle{f32(cx), f32(cy), BCELL, BCELL}
		hov := rl.CheckCollisionPointRec(mouse, cell)
		if hov do hovered = it
		if hov && rl.IsMouseButtonPressed(.LEFT) do s.selected = it
		if it == s.selected {
			rl.DrawRectangleRec(cell, {45, 48, 58, 255})
			rl.DrawRectangleLinesEx(cell, 2, {245, 205, 90, 255})
		} else if hov {
			rl.DrawRectangleLinesEx(cell, 1, {150, 155, 165, 255})
		}
		game.draw_item_icon(it, cx + (BCELL-BICON)/2, cy + (BCELL-BICON)/2, BICON)
	}
	if hovered != .None {
		rl.DrawText(fmt.ctprintf("%s", item_name(hovered)), BROWSER_X, i32(sh) - 26, 14, {200, 203, 210, 255})
	}

	inspector_frame(s, f32(BROWSER_X + BROWSER_COLS*BCELL + 28), sw, sh)
}

CHECKER_DARK  :: rl.Color{30, 32, 40, 255}
CHECKER_LIGHT :: rl.Color{38, 41, 51, 255}

draw_checker :: proc(x, y, w, h: i32) {
	rl.DrawRectangle(x, y, w, h, CHECKER_DARK)
	for cy := i32(0); cy < h; cy += 8 {
		for cx := i32(0); cx < w; cx += 8 {
			if ((cx/8) + (cy/8)) % 2 == 0 do continue
			rl.DrawRectangle(x + cx, y + cy, min(8, w-cx), min(8, h-cy), CHECKER_LIGHT)
		}
	}
}

// Word-wrap into temp-allocated lines that fit width at font size fs.
wrap_text :: proc(text: string, width, fs: i32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	line := ""
	for word in strings.split(text, " ", context.temp_allocator) {
		try := line == "" ? word : fmt.tprintf("%s %s", line, word)
		if rl.MeasureText(fmt.ctprintf("%s", try), fs) > width && line != "" {
			append(&lines, line)
			line = word
		} else {
			line = try
		}
	}
	if line != "" do append(&lines, line)
	return lines[:]
}

inspector_frame :: proc(s: ^Studio, x0, sw, sh: f32) {
	it := s.selected
	if it == .None do return
	info := game.item_table[it]
	icon := game.item_icons[it]
	x := i32(x0)
	y := i32(TOP_BAR) + 20

	rl.DrawText(fmt.ctprintf("%s", info.name), x, y, 26, {235, 235, 240, 255})
	rl.DrawText(fmt.ctprintf(".%v  (ordinal %d)", it, int(it)), x, y + 30, 12, {120, 125, 138, 255})
	y += 56

	// Icon previews on a checker, three scales.
	px := x
	for size in ([3]i32{24, 48, 96}) {
		draw_checker(px, y, size + 12, 108)
		game.draw_item_icon(it, px + 6, y + (108 - size)/2, size)
		px += size + 24
	}
	// Flat color swatch beside them.
	rl.DrawRectangle(px, y, 40, 108, info.color)
	rl.DrawText(fmt.ctprintf("color %d,%d,%d", info.color.r, info.color.g, info.color.b), px + 48, y + 4, 12, {150, 155, 165, 255})
	if name := shape_name_for(icon.grid); name != "" {
		rl.DrawText(fmt.ctprintf("shape %s", name), px + 48, y + 24, 12, {150, 155, 165, 255})
		rl.DrawText(fmt.ctprintf("shared by %d items", shape_shared_count(icon.grid)), px + 48, y + 42, 12, {150, 155, 165, 255})
	} else if icon.grid[0] != "" {
		rl.DrawText("unique shape", px + 48, y + 24, 12, {150, 155, 165, 255})
	}
	y += 124

	kv :: proc(x: i32, y: ^i32, label, value: string, vcol := rl.Color{225, 228, 235, 255}) {
		rl.DrawText(fmt.ctprintf("%s", label), x, y^, 12, {120, 125, 138, 255})
		rl.DrawText(fmt.ctprintf("%s", value), x + 110, y^, 12, vcol)
		y^ += 20
	}

	if info.place_tile == .Air {
		kv(x, &y, "places", "-  (not placeable)", {150, 155, 165, 255})
	} else {
		kv(x, &y, "places", fmt.tprintf(".%v", info.place_tile))
	}
	if slot := game.item_equip_slot[it]; slot != .None {
		kv(x, &y, "equip slot", fmt.tprintf("%v", slot))
	}
	if gate := game.recipe_unlock[it]; gate != .None {
		kv(x, &y, "unlock gate", fmt.tprintf("hold %s", item_name(gate)))
	}
	y += 6

	// Description, wrapped.
	if info.desc != "" {
		for l in wrap_text(info.desc, i32(sw - x0) - 32, 13) {
			rl.DrawText(fmt.ctprintf("%s", l), x, y, 13, {200, 203, 210, 255})
			y += 19
		}
	}
	y += 12

	// Made by.
	if producer_count(it) == 0 {
		rl.DrawText("RAW MATERIAL - found in the world", x, y, 13, {105, 185, 105, 255})
		y += 24
	} else {
		rl.DrawText("MADE BY", x, y, 13, {245, 205, 90, 255})
		y += 20
		for p in producers_of(it) {
			str := fmt.tprintf("%s:", station_label[p.station])
			first := true
			for ing in p.ings {
				if ing.item == .None do continue
				str = fmt.tprintf("%s%s %dx %s", str, first ? "" : "  +", ing.count, item_name(ing.item))
				first = false
			}
			if p.out_count > 1 do str = fmt.tprintf("%s  -> x%d", str, p.out_count)
			col := station_color[p.station]
			rl.DrawRectangle(x, y + 3, 8, 8, col)
			rl.DrawText(fmt.ctprintf("%s", str), x + 16, y, 13, {225, 228, 235, 255})
			y += 20
		}
	}
	y += 10

	// Used in — click a name to jump.
	if xref_user_len[it] > 0 {
		rl.DrawText("USED IN", x, y, 13, {245, 205, 90, 255})
		y += 20
		cx := x
		for u in xref_users[it][:xref_user_len[it]] {
			name := fmt.ctprintf("%s", item_name(u))
			w := rl.MeasureText(name, 13)
			if cx + w > i32(sw) - 24 {
				cx = x
				y += 20
			}
			r := rl.Rectangle{f32(cx) - 2, f32(y) - 2, f32(w) + 4, 17}
			hov := rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
			if hov && rl.IsMouseButtonPressed(.LEFT) do s.selected = u
			rl.DrawText(name, cx, y, 13, hov ? rl.Color{245, 205, 90, 255} : rl.Color{140, 185, 225, 255})
			cx += w + 14
		}
		y += 26
	}
}
