package gnipa_studio

// The DAG tab: the recipe graph view, ported from tools/recipe_viz and
// parameterized over a recipe slice so later phases can preview unsaved
// working copies.  Layered left→right by craft depth, station-colored edges,
// hover/click to focus a node.

import "core:fmt"
import game "../../src"
import rl "vendor:raylib"

DAG_COL_W  :: 300
DAG_NODE_W :: 210
DAG_NODE_H :: 40
DAG_V_STEP :: 54
DAG_ICON   :: 30

DAG_MAX_LAYERS    :: 16
DAG_MAX_PER_LAYER :: 64
DAG_MAX_EDGES     :: 512

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

station_ex :: proc(st: game.Station) -> Station_Ex {
	#partial switch st {
	case .Bench:      return .Bench
	case .Forge:      return .Forge
	case .Rune_Altar: return .Rune_Altar
	}
	return .Hand
}

Edge :: struct {
	from, to: game.Item,
	count:    int,
	station:  Station_Ex,
}

Graph :: struct {
	edges:      [DAG_MAX_EDGES]Edge,
	edge_count: int,
	used:       [game.Item]bool,
	layer:      [game.Item]int,
	row:        [game.Item]f32,
	pos:        [game.Item]rl.Vector2,
	layers:     [DAG_MAX_LAYERS][DAG_MAX_PER_LAYER]game.Item,
	layer_len:  [DAG_MAX_LAYERS]int,
	n_layers:   int,
}

add_edge :: proc(g: ^Graph, from, to: game.Item, count: int, st: Station_Ex) {
	if g.edge_count >= DAG_MAX_EDGES do return
	g.edges[g.edge_count] = {from, to, count, st}
	g.edge_count += 1
	g.used[from] = true
	g.used[to] = true
}

build_graph :: proc(g: ^Graph, recipes: []game.Recipe, smelts: []game.Smelt_Rule) {
	g^ = {}
	for r in recipes {
		for ing in r.ingredients {
			if ing.item == .None do continue
			add_edge(g, ing.item, r.result, ing.count, station_ex(r.station))
		}
	}
	for r in smelts {
		add_edge(g, r.ore, r.bar, r.ore_per_bar, .Smelter)
	}

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
		if g.layer_len[l] >= DAG_MAX_PER_LAYER do continue
		g.row[it] = f32(g.layer_len[l])
		g.layers[l][g.layer_len[l]] = it
		g.layer_len[l] += 1
	}
}

// Alternating barycenter sweeps keep edge crossings low.
layout_graph :: proc(g: ^Graph) {
	for pass in 0 ..< 8 {
		forward := pass % 2 == 0
		for i in 0 ..< g.n_layers {
			l := forward ? i : g.n_layers - 1 - i
			n := g.layer_len[l]
			keys: [DAG_MAX_PER_LAYER]f32
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
		y0 := -f32(n-1) * DAG_V_STEP * 0.5
		for k in 0 ..< n {
			it := g.layers[l][k]
			g.pos[it] = {f32(l) * DAG_COL_W, y0 + f32(k)*DAG_V_STEP}
		}
	}
}

node_rect :: proc(g: ^Graph, it: game.Item) -> rl.Rectangle {
	p := g.pos[it]
	return {p.x, p.y, DAG_NODE_W, DAG_NODE_H}
}

edge_points :: proc(g: ^Graph, e: Edge) -> (rl.Vector2, rl.Vector2) {
	a, b := g.pos[e.from], g.pos[e.to]
	return {a.x + DAG_NODE_W, a.y + DAG_NODE_H*0.5}, {b.x, b.y + DAG_NODE_H*0.5}
}

item_name :: proc(it: game.Item) -> string {
	return game.item_table[it].name
}

Dag_State :: struct {
	g:            Graph,
	cam:          rl.Camera2D,
	selected:     game.Item,
	press_pos:    rl.Vector2,
	bounds_min:   rl.Vector2,
	bounds_max:   rl.Vector2,
}

dag_init :: proc(d: ^Dag_State, sw, sh: f32) {
	build_graph(&d.g, game.recipe_table[:], game.smelt_table[:])
	layout_graph(&d.g)

	min_p, max_p := rl.Vector2{1e9, 1e9}, rl.Vector2{-1e9, -1e9}
	for it in game.Item {
		if !d.g.used[it] do continue
		p := d.g.pos[it]
		min_p.x = min(min_p.x, p.x);              min_p.y = min(min_p.y, p.y)
		max_p.x = max(max_p.x, p.x + DAG_NODE_W); max_p.y = max(max_p.y, p.y + DAG_NODE_H)
	}
	d.bounds_min, d.bounds_max = min_p, max_p
	d.cam = {
		target = (min_p + max_p) * 0.5,
		offset = {sw*0.5, sh*0.5 + 20},
		zoom   = clamp(min(
			(sw - 100) / (max_p.x - min_p.x),
			(sh - 160) / (max_p.y - min_p.y)), 0.15, 1.0),
	}
	d.selected = .None
}

// One frame of the DAG tab, below the top bar. Returns the focused item so
// the shell can jump the Items tab to it on double-interest later.
dag_frame :: proc(d: ^Dag_State, top: f32) -> game.Item {
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	d.cam.offset = {sw*0.5, (sh + top)*0.5}
	mouse := rl.GetMousePosition()
	over_view := mouse.y > top

	if wm := rl.GetMouseWheelMove(); wm != 0 && over_view {
		before := rl.GetScreenToWorld2D(mouse, d.cam)
		d.cam.zoom = clamp(d.cam.zoom * (wm > 0 ? 1.15 : 1.0/1.15), 0.10, 3.0)
		after := rl.GetScreenToWorld2D(mouse, d.cam)
		d.cam.target += before - after
	}
	if over_view && (rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.MIDDLE)) {
		d.cam.target -= rl.GetMouseDelta() / d.cam.zoom
	}
	if rl.IsMouseButtonPressed(.LEFT) do d.press_pos = mouse

	world := rl.GetScreenToWorld2D(mouse, d.cam)
	hovered: game.Item = .None
	if over_view {
		for it in game.Item {
			if d.g.used[it] && rl.CheckCollisionPointRec(world, node_rect(&d.g, it)) do hovered = it
		}
	}
	if over_view && rl.IsMouseButtonReleased(.LEFT) && rl.Vector2Distance(d.press_pos, mouse) < 4 {
		d.selected = hovered
	}
	if rl.IsKeyPressed(.ESCAPE) do d.selected = .None
	focus := hovered != .None ? hovered : d.selected

	related: [game.Item]bool
	if focus != .None {
		for e in d.g.edges[:d.g.edge_count] {
			if e.from == focus do related[e.to] = true
			if e.to == focus do related[e.from] = true
		}
	}

	rl.BeginMode2D(d.cam)

	for l in 0 ..< d.g.n_layers {
		rl.DrawText(fmt.ctprintf("depth %d", l),
			i32(f32(l)*DAG_COL_W + DAG_NODE_W/2 - 24), i32(d.bounds_min.y - 44), 14, {90, 95, 110, 255})
	}

	for e in d.g.edges[:d.g.edge_count] {
		p1, p2 := edge_points(&d.g, e)
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
		if !d.g.used[it] do continue
		r := node_rect(&d.g, it)
		dimmed := focus != .None && it != focus && !related[it]
		bg := rl.Color{45, 48, 58, dimmed ? 120 : 255}
		raw := producer_count(it) == 0
		border: rl.Color =
			it == focus ? {245, 205, 90, 255} :
			raw         ? {105, 185, 105, 255} :
			              station_color[first_producer_station(it)]
		if dimmed do border.a = 60
		rl.DrawRectangleRec(r, bg)
		rl.DrawRectangleLinesEx(r, it == focus ? 2 : 1, border)
		game.draw_item_icon(it, i32(r.x)+6, i32(r.y)+(DAG_NODE_H-DAG_ICON)/2, DAG_ICON, dimmed ? 90 : 255)
		name := fmt.ctprintf("%s", item_name(it))
		fs: i32 = rl.MeasureText(name, 12) > DAG_NODE_W - 48 ? 10 : 12
		tint := rl.Color{225, 228, 235, dimmed ? u8(90) : 255}
		rl.DrawText(name, i32(r.x)+42, i32(r.y)+(DAG_NODE_H-fs)/2, fs, tint)
	}

	rl.EndMode2D()

	// legend
	ly := i32(sh) - 20*i32(len(Station_Ex)) - 30
	rl.DrawText("edge = made at:", 16, ly - 18, 12, {150, 155, 165, 255})
	for st in Station_Ex {
		rl.DrawRectangle(16, ly, 22, 4, station_color[st])
		rl.DrawText(fmt.ctprintf("%s", station_label[st]), 46, ly - 4, 12, {200, 203, 210, 255})
		ly += 20
	}
	rl.DrawText("green border = raw material", 16, ly + 2, 12, {105, 185, 105, 255})

	if focus != .None do draw_dag_tooltip(d, focus, mouse, sw, sh)
	return focus
}

draw_dag_tooltip :: proc(d: ^Dag_State, it: game.Item, mouse: rl.Vector2, sw, sh: f32) {
	lines: [24]string
	n := 0
	push :: proc(lines: ^[24]string, n: ^int, s: string) {
		if n^ < len(lines) { lines[n^] = s; n^ += 1 }
	}

	push(&lines, &n, fmt.tprintf("%s%s", item_name(it), producer_count(it) == 0 ? "  (raw material)" : ""))
	for p in producers_of(it) {
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

	feeds: [game.Item]bool
	s := ""
	cnt := 0
	for e in d.g.edges[:d.g.edge_count] {
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
