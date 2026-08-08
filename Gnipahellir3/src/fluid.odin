package game

// ─── Fluid Flow ───────────────────────────────────────────────────────────────
//
//  Water and lava are ordinary terrain tiles that MOVE.  Mass is conserved: a
//  fluid cell is one unit that steps into an open neighbour and leaves its own
//  cell open behind it — nothing is ever copied, so a body of fluid holds
//  exactly the tiles world-gen laid down.  Breach a basin and it drains; once
//  it has run out, it is gone.  (That also means no duplication exploit: you
//  cannot farm an infinite pond.)
//
//  One step, per cell, tries in order:
//    1. straight down            — the whole point: fluid spreads downward
//    2. down-left / down-right   — running down a slope.  The side cell must be
//                                  open too, so fluid can never squeeze through
//                                  the diagonal seam between two solid blocks.
//    3. one step toward the nearest hole it can see along its own row
//    4. sideways, but ONLY while buried under more of its own fluid
//
//  Rules 3 and 4 are what stop a body of fluid churning forever.  Rule 3 only
//  ever moves a cell TOWARD somewhere it could genuinely fall — a puddle finds
//  the shaft you dug four tiles away and runs to it, but a pool with no drop in
//  reach never twitches.  Rule 4 is the pressure rule: it flattens a heap that
//  has nowhere to drain, and only a cell buried under more of its own fluid
//  pushes, so a settled surface has nothing to make it slither.  Every move
//  either goes down, closes distance to a drop, or fills open space beneath a
//  load — so flow always terminates, and a body ends up flat and completely
//  still.
//
//  Scope: the loaded level only (`gs.world`).  Fluid in a level you are not
//  standing in is frozen exactly where you left it.  Positions live in the
//  terrain array, which is saved wholesale, so flow persists across saves with
//  no version bump — only the tick timers below are transient.

// One row per flowing tile type.  Period is the whole speed knob: water
// splashes, lava creeps at a pace you can walk away from.
Fluid_Rule :: struct {
	tile:   Tile_Type,
	period: f32, // seconds between flow steps
}

@(rodata)
fluid_rules := [?]Fluid_Rule {
	{.Water, 0.08},
	{.Lava, 0.35},
	{.Magic_Lava, 0.35},
}

// How far along its row a blocked cell can spot somewhere to fall.  Bigger =
// a puddle drains to a more distant hole; the cost is this many lookups per
// blocked cell per step.
FLUID_SPREAD :: 8

// Fluid only ever moves into genuinely empty space: it never eats terrain,
// plants or structures, and never displaces another fluid.  Out of bounds
// reads as stone, so a fluid can never leave the map.
fluid_open :: #force_inline proc(w: ^World_Grid, x, y: int) -> bool {
	t := get_tile(w, x, y)
	return t == .Air || t == .Void
}

// Looking along row y from (x,y) in direction d, how many cells away is the
// nearest column this fluid could fall down?  Walls stop the search dead — a
// puddle cannot see through stone.  0 = nothing in reach.
fluid_drop_distance :: proc(w: ^World_Grid, x, y, d: int) -> int {
	for i in 1 ..= FLUID_SPREAD {
		cx := x + d * i
		if !fluid_open(w, cx, y) do return 0
		if fluid_open(w, cx, y + 1) do return i
	}
	return 0
}

update_fluid :: proc(gs: ^Game_State) {
	profile_scope("update_fluid")
	for rule, i in fluid_rules {
		gs.fluid.timers[i] += gs.delta_time
		if gs.fluid.timers[i] < rule.period do continue
		gs.fluid.timers[i] = 0
		fluid_step(gs, rule.tile, gs.fluid.flip[i])
		gs.fluid.flip[i] = !gs.fluid.flip[i]
	}
}

// One flow step for every cell of one fluid.  Rows are walked bottom-up so a
// cell that falls lands in a row this step has already settled and cannot fall
// twice; `moved` catches the sideways case, the only move that can land in a
// cell the scan has yet to reach.
fluid_step :: proc(gs: ^Game_State, fluid: Tile_Type, flip: bool) {
	w := &gs.world
	moved: [GRID_W * GRID_H]bool

	// Which side is tried first flips every step, so a spreading pool has no
	// permanent lean to one direction.
	dir := 1
	if !flip do dir = -1

	for y := GRID_H - 1; y >= 0; y -= 1 {
		for x in 0 ..< GRID_W {
			idx := grid_idx(x, y)
			if w.terrain[idx] != fluid do continue
			if moved[idx] do continue

			if fluid_open(w, x, y + 1) {
				fluid_move(gs, x, y, x, y + 1, fluid, &moved)
				continue
			}
			if fluid_open(w, x + dir, y) && fluid_open(w, x + dir, y + 1) {
				fluid_move(gs, x, y, x + dir, y + 1, fluid, &moved)
				continue
			}
			if fluid_open(w, x - dir, y) && fluid_open(w, x - dir, y + 1) {
				fluid_move(gs, x, y, x - dir, y + 1, fluid, &moved)
				continue
			}
			// Run for the nearest hole in reach along this row.  Only ever a
			// step toward somewhere it could actually fall, so it closes
			// distance monotonically and can never slosh back and forth.
			d, best := dir, fluid_drop_distance(w, x, y, dir)
			if alt := fluid_drop_distance(w, x, y, -dir); alt != 0 && (best == 0 || alt < best) {
				d, best = -dir, alt
			}
			if best != 0 {
				fluid_move(gs, x, y, x + d, y, fluid, &moved)
				continue
			}

			// Pressure: nowhere to drain, so only a cell with more of its own
			// fluid stacked on top pushes sideways, flattening the heap.  A
			// settled pool's surface stays put.
			if get_tile(w, x, y - 1) != fluid do continue
			if fluid_open(w, x + dir, y) {
				fluid_move(gs, x, y, x + dir, y, fluid, &moved)
				continue
			}
			if fluid_open(w, x - dir, y) {
				fluid_move(gs, x, y, x - dir, y, fluid, &moved)
			}
		}
	}
}

// The vacated cell opens exactly as a mined one does (air above the surface
// line and in the sky, void underground), so a drained channel reads the same
// as a dug one.
fluid_move :: proc(
	gs: ^Game_State,
	fx, fy, tx, ty: int,
	fluid: Tile_Type,
	moved: ^[GRID_W * GRID_H]bool,
) {
	set_tile(&gs.world, tx, ty, fluid)
	set_tile(&gs.world, fx, fy, gravity_open_tile(gs, fy))
	moved[grid_idx(tx, ty)] = true
}
