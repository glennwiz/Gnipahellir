package recipe_viz

// ─── Recipe DAG viewer ────────────────────────────────────────────────────────
//
//  Standalone dev tool: draws the full crafting graph — every recipe_table row
//  plus the smelter's ore→bar casts — as a layered DAG, left to right by craft
//  depth.  It imports the game package directly, so it always renders the exact
//  tables the game compiles with; there is no exported data file to drift.
//
//  Run it through run.ps1 (same folder): the script rebuilds and relaunches
//  this window whenever any src/*.odin changes, so the graph live-updates as
//  recipes are edited.
//
//  Controls: wheel = zoom (at cursor) · drag = pan · hover/click a node =
//  highlight its edges + tooltip (recipe, unlock gate, what it feeds into).
//  `--shot` renders one frame to recipe_dag.png and exits (build sanity check).

import "core:fmt"
import "core:os"
import game "../../src"
import rl "vendor:raylib"

SCREEN_W :: 1600
SCREEN_H :: 900

COL_W  :: 300 // horizontal gap between craft-depth layers
NODE_W :: 210
NODE_H :: 40
V_STEP :: 54
ICON   :: 30

MAX_LAYERS    :: 16
MAX_PER_LAYER :: 64
MAX_EDGES     :: 512
MAX_PRODUCERS :: 4

// The game's Station ladder plus the machines that transform items outside
// the crafting window.
Station_Ex :: enum {
	Hand,
	Bench,
	Forge,
	Rune_Altar,
	Smelter,
}

@(rodata)
station_color := [Station_Ex]rl.Color{
	.Hand       = {165, 165, 175, 255},
	.Bench      = {190, 145, 92, 255},
	.Forge      = {235, 140, 60, 255},
	.Rune_Altar = {90, 205, 225, 255},
	.Smelter    = {225, 95, 75, 255},
}

@(rodata)
station_label := [Station_Ex]string{
	.Hand       = "hand",
	.Bench      = "Bench",
	.Forge      = "Forge",
	.Rune_Altar = "Rune Altar",
	.Smelter    = "Smelter",
}

Edge :: struct {
	from, to: game.Item,
	count:    int, // how many of `from` one craft consumes
	station:  Station_Ex,
}

// One way of making an item — a recipe row or a smelt rule — for the tooltip.
Producer :: struct {
	station:   Station_Ex,
	out_count: int,
	ings:      [3]game.Ingredient,
}

Graph :: struct {
	edges:      [MAX_EDGES]Edge,
	edge_count: int,
	used:       [game.Item]bool,
	layer:      [game.Item]int,
	row:        [game.Item]f32, // order key within the layer
	pos:        [game.Item]rl.Vector2,
	prod:       [game.Item][MAX_PRODUCERS]Producer,
	prod_count: [game.Item]int,
	layers:     [MAX_LAYERS][MAX_PER_LAYER]game.Item,
	layer_len:  [MAX_LAYERS]int,
	n_layers:   int,
}

add_edge :: proc(g: ^Graph, from, to: game.Item, count: int, st: Station_Ex) {
	if g.edge_count >= MAX_EDGES do return
	g.edges[g.edge_count] = {from, to, count, st}
	g.edge_count += 1
	g.used[from] = true
	g.used[to] = true
}

add_producer :: proc(g: ^Graph, it: game.Item, p: Producer) {
	if g.prod_count[it] >= MAX_PRODUCERS do return
	g.prod[it][g.prod_count[it]] = p
	g.prod_count[it] += 1
}

station_ex :: proc(st: game.Station) -> Station_Ex {
	#partial switch st {
	case .Bench:      return .Bench
	case .Forge:      return .Forge
	case .Rune_Altar: return .Rune_Altar
	}
	return .Hand
}

build_graph :: proc(g: ^Graph) {
	for r in game.recipe_table {
		st := station_ex(r.station)
		add_producer(g, r.result, {st, r.result_count, r.ingredients})
		for ing in r.ingredients {
			if ing.item == .None do continue
			add_edge(g, ing.item, r.result, ing.count, st)
		}
	}
	for r in game.smelt_table {
		add_producer(g, r.bar, {.Smelter, 1, {{r.ore, r.ore_per_bar}, {}, {}}})
		add_edge(g, r.ore, r.bar, r.ore_per_bar, .Smelter)
	}

	// Craft depth by longest path: raw materials sit at 0, each product one
	// column right of its deepest ingredient.
	for {
		changed := false
		for e in g.edges[:g.edge_count] {
			if g.layer[e.to] < g.layer[e.from] + 1 {
				g.layer[e.to] = g.layer[e.from] + 1
				changed = true
			}
		}
		if !changed do break
	}

	for it in game.Item {
		if !g.used[it] do continue
		l := g.layer[it]
		if l + 1 > g.n_layers do g.n_layers = l + 1
		if g.layer_len[l] >= MAX_PER_LAYER do continue
		g.row[it] = f32(g.layer_len[l])
		g.layers[l][g.layer_len[l]] = it
		g.layer_len[l] += 1
	}
}

// A few alternating barycenter sweeps: order each column by the average row of
// its neighbours in the previous/next column, so edge crossings stay low.
layout_graph :: proc(g: ^Graph) {
	for pass in 0 ..< 8 {
		forward := pass % 2 == 0
		for i in 0 ..< g.n_layers {
			l := forward ? i : g.n_layers - 1 - i
			n := g.layer_len[l]
			keys: [MAX_PER_LAYER]f32
			for k in 0 ..< n {
				it := g.layers[l][k]
				sum, cnt := f32(0), 0
				for e in g.edges[:g.edge_count] {
					other: game.Item = .None
					if forward && e.to == it && g.layer[e.from] < l do other = e.from
					if !forward && e.from == it && g.layer[e.to] > l do other = e.to
					if other == .None do continue
					sum += g.row[other]
					cnt += 1
				}
				keys[k] = cnt > 0 ? sum / f32(cnt) : g.row[it]
			}
			// insertion sort the column by key
			for a in 1 ..< n {
				it, key := g.layers[l][a], keys[a]
				b := a
				for b > 0 && keys[b-1] > key {
					g.layers[l][b] = g.layers[l][b-1]
					keys[b] = keys[b-1]
					b -= 1
				}
				g.layers[l][b] = it
				keys[b] = key
			}
			for k in 0 ..< n do g.row[g.layers[l][k]] = f32(k)
		}
	}

	for l in 0 ..< g.n_layers {
		n := g.layer_len[l]
		y0 := -f32(n-1) * V_STEP * 0.5
		for k in 0 ..< n {
			it := g.layers[l][k]
			g.pos[it] = {f32(l) * COL_W, y0 + f32(k)*V_STEP}
		}
	}
}

node_rect :: proc(g: ^Graph, it: game.Item) -> rl.Rectangle {
	p := g.pos[it]
	return {p.x, p.y, NODE_W, NODE_H}
}

edge_points :: proc(g: ^Graph, e: Edge) -> (rl.Vector2, rl.Vector2) {
	a, b := g.pos[e.from], g.pos[e.to]
	return {a.x + NODE_W, a.y + NODE_H*0.5}, {b.x, b.y + NODE_H*0.5}
}

item_name :: proc(it: game.Item) -> string {
	return game.item_table[it].name
}

main :: proc() {
	shot := len(os.args) > 1 && os.args[1] == "--shot"

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(SCREEN_W, SCREEN_H, "Gnipahellir — Crafting DAG")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	g: Graph
	build_graph(&g)
	layout_graph(&g)

	// Fit the whole graph on screen to start with.
	min_p, max_p := rl.Vector2{1e9, 1e9}, rl.Vector2{-1e9, -1e9}
	for it in game.Item {
		if !g.used[it] do continue
		p := g.pos[it]
		min_p.x = min(min_p.x, p.x);          min_p.y = min(min_p.y, p.y)
		max_p.x = max(max_p.x, p.x + NODE_W); max_p.y = max(max_p.y, p.y + NODE_H)
	}
	cam := rl.Camera2D{
		target = (min_p + max_p) * 0.5,
		offset = {SCREEN_W*0.5, SCREEN_H*0.5 + 14},
		zoom   = clamp(min(
			(SCREEN_W - 100) / (max_p.x - min_p.x),
			(SCREEN_H - 140) / (max_p.y - min_p.y)), 0.15, 1.0),
	}

	selected: game.Item = .None
	press_pos: rl.Vector2
	frames := 0

	for !rl.WindowShouldClose() {
		sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		cam.offset = {sw*0.5, sh*0.5 + 14}
		mouse := rl.GetMousePosition()

		// wheel zoom, anchored on the cursor
		if wm := rl.GetMouseWheelMove(); wm != 0 {
			before := rl.GetScreenToWorld2D(mouse, cam)
			cam.zoom = clamp(cam.zoom * (wm > 0 ? 1.15 : 1.0/1.15), 0.10, 3.0)
			after := rl.GetScreenToWorld2D(mouse, cam)
			cam.target += before - after
		}
		// any-button drag pans; a motionless left click selects/clears
		if rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE) {
			cam.target -= rl.GetMouseDelta() / cam.zoom
		}
		if rl.IsMouseButtonPressed(.LEFT) do press_pos = mouse

		world := rl.GetScreenToWorld2D(mouse, cam)
		hovered: game.Item = .None
		for it in game.Item {
			if g.used[it] && rl.CheckCollisionPointRec(world, node_rect(&g, it)) do hovered = it
		}
		if rl.IsMouseButtonReleased(.LEFT) && rl.Vector2Distance(press_pos, mouse) < 4 {
			selected = hovered // click on empty ground clears
		}
		if rl.IsKeyPressed(.ESCAPE) do selected = .None
		focus := hovered != .None ? hovered : selected

		related: [game.Item]bool
		if focus != .None {
			for e in g.edges[:g.edge_count] {
				if e.from == focus do related[e.to] = true
				if e.to == focus do related[e.from] = true
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground({24, 26, 32, 255})
		rl.BeginMode2D(cam)

		for l in 0 ..< g.n_layers {
			rl.DrawText(fmt.ctprintf("depth %d", l),
				i32(f32(l)*COL_W + NODE_W/2 - 24), i32(min_p.y - 44), 14, {90, 95, 110, 255})
		}

		for e in g.edges[:g.edge_count] {
			p1, p2 := edge_points(&g, e)
			active := focus == .None || e.from == focus || e.to == focus
			col := station_color[e.station]
			col.a = active ? (focus != .None ? 255 : 165) : 26
			rl.DrawLineBezier(p1, p2, active && focus != .None ? 2.5 : 1.5, col)
			if active && focus != .None && e.count > 1 {
				mid := (p1 + p2) * 0.5
				rl.DrawText(fmt.ctprintf("x%d", e.count), i32(mid.x)-8, i32(mid.y)-14, 12, col)
			}
		}

		for it in game.Item {
			if !g.used[it] do continue
			r := node_rect(&g, it)
			dimmed := focus != .None && it != focus && !related[it]
			bg := rl.Color{45, 48, 58, dimmed ? 120 : 255}
			raw := g.prod_count[it] == 0
			border: rl.Color =
				it == focus ? {245, 205, 90, 255} :
				raw         ? {105, 185, 105, 255} :
				              station_color[g.prod[it][0].station]
			if dimmed do border.a = 60
			rl.DrawRectangleRec(r, bg)
			rl.DrawRectangleLinesEx(r, it == focus ? 2 : 1, border)
			game.draw_item_icon(it, i32(r.x)+6, i32(r.y)+(NODE_H-ICON)/2, ICON, dimmed ? 90 : 255)
			name := fmt.ctprintf("%s", item_name(it))
			fs: i32 = rl.MeasureText(name, 12) > NODE_W - 48 ? 10 : 12
			tint := rl.Color{225, 228, 235, dimmed ? u8(90) : 255}
			rl.DrawText(name, i32(r.x)+42, i32(r.y)+(NODE_H-fs)/2, fs, tint)
		}

		rl.EndMode2D()

		// header + legend
		rl.DrawText("GNIPAHELLIR - CRAFTING DAG", 16, 12, 20, {235, 235, 240, 255})
		used_n := 0
		for it in game.Item do if g.used[it] do used_n += 1
		rl.DrawText(fmt.ctprintf("%d recipes + %d smelt rules - %d items - wheel zoom, drag pan, click a node",
			len(game.recipe_table), len(game.smelt_table), used_n),
			16, 36, 12, {150, 155, 165, 255})
		ly := i32(sh) - 20*i32(len(Station_Ex)) - 30
		rl.DrawText("edge = made at:", 16, ly - 18, 12, {150, 155, 165, 255})
		for st in Station_Ex {
			rl.DrawRectangle(16, ly, 22, 4, station_color[st])
			rl.DrawText(fmt.ctprintf("%s", station_label[st]), 46, ly - 4, 12, {200, 203, 210, 255})
			ly += 20
		}
		rl.DrawText("green border = raw material", 16, ly + 2, 12, {105, 185, 105, 255})

		if focus != .None do draw_tooltip(&g, focus, mouse, sw, sh)

		rl.EndDrawing()
		free_all(context.temp_allocator)

		frames += 1
		if shot && frames == 5 {
			rl.TakeScreenshot("recipe_dag.png")
			break
		}
	}
}

draw_tooltip :: proc(g: ^Graph, it: game.Item, mouse: rl.Vector2, sw, sh: f32) {
	lines: [24]string
	n := 0
	push :: proc(lines: ^[24]string, n: ^int, s: string) {
		if n^ < len(lines) { lines[n^] = s; n^ += 1 }
	}

	push(&lines, &n, fmt.tprintf("%s%s", item_name(it), g.prod_count[it] == 0 ? "  (raw material)" : ""))
	for p in g.prod[it][:g.prod_count[it]] {
		s := fmt.tprintf("%s:", station_label[p.station])
		first := true
		for ing in p.ings {
			if ing.item == .None do continue
			s = fmt.tprintf("%s%s %dx %s", s, first ? "" : "  +", ing.count, item_name(ing.item))
			first = false
		}
		if p.out_count > 1 do s = fmt.tprintf("%s  -> x%d", s, p.out_count)
		push(&lines, &n, s)
	}
	if gate := game.recipe_unlock[it]; gate != .None {
		push(&lines, &n, fmt.tprintf("unlocked by holding: %s", item_name(gate)))
	}

	// what it feeds into, deduped, wrapped a few names per line
	feeds: [game.Item]bool
	s := ""
	cnt := 0
	for e in g.edges[:g.edge_count] {
		if e.from != it || feeds[e.to] do continue
		feeds[e.to] = true
		s = fmt.tprintf("%s%s%s", s, cnt % 4 == 0 && cnt > 0 ? "" : (cnt == 0 ? "used in: " : ", "), item_name(e.to))
		cnt += 1
		if cnt % 4 == 0 {
			push(&lines, &n, s)
			s = "    "
		}
	}
	if cnt % 4 != 0 do push(&lines, &n, s)

	w: i32 = 0
	for l in lines[:n] do w = max(w, rl.MeasureText(fmt.ctprintf("%s", l), 12))
	h := i32(n)*18 + 12
	x := i32(clamp(mouse.x + 18, 0, sw - f32(w) - 24))
	y := i32(clamp(mouse.y + 18, 0, sh - f32(h) - 8))
	rl.DrawRectangle(x, y, w + 20, h, {18, 20, 26, 235})
	rl.DrawRectangleLines(x, y, w + 20, h, {245, 205, 90, 200})
	for l, i in lines[:n] {
		tint := rl.Color{225, 228, 235, 255}
		if i == 0 do tint = {245, 205, 90, 255}
		rl.DrawText(fmt.ctprintf("%s", l), x + 10, y + 8 + i32(i)*18, 12, tint)
	}
}
