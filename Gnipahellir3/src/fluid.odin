package game

// ─── Fluid Flow ───────────────────────────────────────────────────────────────
//
//  Water and lava are ordinary terrain tiles that MOVE.  Mass is conserved: a
//  fluid cell is one unit that steps into an open neighbour and leaves its own
//  cell open behind it — nothing is ever copied, so a body of fluid holds
//  exactly the tiles world-gen laid down.  Breach a basin and it drains; once
//  it has run out, it is gone.  You cannot farm the pond.
//
//  There is exactly ONE exception, and it has to be BUILT: a spring (see
//  `fluid_is_spring`).  Wall a three-wide pool and leave a gap under its middle
//  and that middle cell stops being a drop of water and becomes a source, which
//  is where new fluid enters the world.  Nothing else creates fluid.
//
//  One step, per cell, tries in order:
//    1. straight down            — the whole point: fluid spreads downward
//    2. down-left / down-right   — running down a slope.  The side cell must be
//                                  open too, so fluid can never squeeze through
//                                  the diagonal seam between two solid blocks.
//    3. one step toward the nearest hole it can see along its own row
//    4. sideways, but ONLY while buried under more of its own fluid — and the
//       push carries THROUGH the body, surfacing at the first open cell past
//       the end of its own run
//
//  A GAS runs the exact same rules with "down" mirrored to up (Fluid_Rule.rise)
//  and a finite lifetime: it climbs the shaft you dug, pools under whatever
//  ceiling you leave it, and fades if it escapes.  The dug terrain is the
//  plumbing.
//
//  Rules 3 and 4 are what stop a body of fluid churning forever.  Rule 3 only
//  ever moves a cell TOWARD somewhere it could genuinely fall — a puddle finds
//  the shaft you dug four tiles away and runs to it, but a pool with no drop in
//  reach never twitches.  Rule 4 is the pressure rule: it flattens a heap that
//  has nowhere to drain, and only a cell buried under more of its own fluid
//  pushes, so a settled surface has nothing to make it slither.  The push must
//  carry through the cell's own fluid: a heap fed from one column otherwise
//  freezes as a tower, its buried cell walled in by its neighbours and its
//  dry-topped edge cells never pushing at all.  Every move
//  either goes down, closes distance to a drop, or fills open space beneath a
//  load — so flow always terminates, and a body ends up flat and completely
//  still.
//
//  Scope: the loaded level only (`gs.world`).  Fluid in a level you are not
//  standing in is frozen exactly where you left it.  Positions live in the
//  terrain array, which is saved wholesale, so flow persists across saves with
//  no version bump — only the tick timers below are transient.

// One row per flowing tile type.  Period is the whole speed knob, and it is
// tuned for readability rather than realism: water advances a tile a second so
// you can watch a flood arrive and get out of its way, and lava creeps at a
// third of that.  Lava must stay slower than water.
//
// A GAS is the same sim mirrored (`rise`): "down" becomes up, and it pools
// under a ceiling instead of on a floor.  Gases also fade (`lifetime`), so an
// escaped cloud is an event you wait out, not permanent litter — the per-cell
// step count lives in `Fluid_State.age`, which is transient: a save/load
// resets every age and loaded vapour lives one extra lifetime.  Cosmetic.
Fluid_Rule :: struct {
	tile:     Tile_Type,
	period:   f32, // seconds between flow steps — one tile per period
	rise:     bool, // gas: flows up, pools under ceilings
	springs:  bool, // may the spring stencil fire for this fluid?
	lifetime: f32, // 0 = forever; >0 = seconds before a cell fades back to open
}

// Do not reorder existing rows: Fluid_State.timers/flip are indexed by rule
// position (transient, but tests index them too).
@(rodata)
fluid_rules := [?]Fluid_Rule {
	{tile = .Water, period = 1.0, springs = true},
	{tile = .Lava, period = 3.0, springs = true},
	{tile = .Magic_Lava, period = 3.0, springs = true},
	// Steam is fast (gas is light) and lives 20 s — long enough to cross a real
	// steam room, short enough that a leak visibly bleeds you dry.  `springs`
	// stays OFF for every gas: a steam spring would be free infinite power and
	// would delete the boiler from the game.
	{tile = .Steam, period = 0.25, rise = true, lifetime = 20.0},
	// The magic track's vapour — same shape as Steam (a rising, fading gas),
	// deliberately slower (mana_industry.md §4, a first guess to retune by
	// feel). springs stays OFF for the same reason it does for every gas: a
	// mist spring would be free infinite power with zero gems ever burned.
	// Lives MUCH longer than Steam (10 min, not 20 s) — Glenn's call: a piped
	// network should hold its charge, not evaporate mid-build.
	{tile = .Mana_Mist, period = 1.0, rise = true, lifetime = 600.0},
}

// How far along its row a blocked cell can spot somewhere to fall.  Bigger =
// a puddle drains to a more distant hole; the cost is this many lookups per
// blocked cell per step.
FLUID_SPREAD :: 8

// Is this tile one of the flowing kinds?  Keyed off the same table the flow
// runs from.
is_fluid_tile :: proc(t: Tile_Type) -> bool {
	for rule in fluid_rules do if rule.tile == t do return true
	return false
}

// The falling kinds only — what the bucket can carry.  A gas would just rise
// out of it.
is_liquid_tile :: proc(t: Tile_Type) -> bool {
	for rule in fluid_rules do if rule.tile == t do return !rule.rise
	return false
}

// Fluid only ever moves into genuinely empty space: it never eats terrain,
// plants or structures, and never displaces another fluid.  Out of bounds
// reads as stone, so a fluid can never leave the map.
fluid_open :: #force_inline proc(w: ^World_Grid, x, y: int) -> bool {
	t := get_tile(w, x, y)
	return t == .Air || t == .Void
}

// Looking along row y from (x,y) in direction d, how many cells away is the
// nearest column this fluid could keep flowing down (or up, for a gas — dy is
// the flow direction)?  Walls stop the search dead — a puddle cannot see
// through stone.  0 = nothing in reach.
fluid_drop_distance :: proc(w: ^World_Grid, x, y, d, dy: int) -> int {
	for i in 1 ..= FLUID_SPREAD {
		cx := x + d * i
		if !fluid_open(w, cx, y) do return 0
		if fluid_open(w, cx, y + dy) do return i
	}
	return 0
}

// Where does a buried cell's push surface?  Pressure transmits through the
// body: walk along the row THROUGH the cell's own fluid and come out at the
// first open cell, up to FLUID_SPREAD away.  A run that ends in anything else
// (a wall, another fluid) pushes nothing.
fluid_push_target :: proc(w: ^World_Grid, x, y, d: int, fluid: Tile_Type) -> (int, bool) {
	for i in 1 ..= FLUID_SPREAD {
		cx := x + d * i
		if fluid_open(w, cx, y) do return cx, true
		if get_tile(w, cx, y) != fluid do return 0, false
	}
	return 0, false
}

// Is (x,y) — already known to hold `fluid` — the mouth of a spring?  The shape
// is exact and has to be built on purpose:
//
//        x-2  x-1   x   x+1  x+2
//   y     S    W    W    W    S
//   y+1   S    S    V    S    S
//                   ^ new fluid wells up here
//
// Any solid walls it (stone, dirt, ore, a block you placed) — only the four S
// cells' solidity is checked, not what they are made of.  The two S cells
// UNDER the flanking fluid are what keep this from firing by accident: in a
// natural pond the flanks sit on more water, so a pond is never a spring and
// still drains when you dig it out.  Break any wall and the spring dies.
fluid_is_spring :: proc(w: ^World_Grid, x, y: int, fluid: Tile_Type) -> bool {
	if !fluid_open(w, x, y + 1) do return false          // nowhere to well up into
	if get_tile(w, x - 1, y) != fluid do return false    // the flanking pool
	if get_tile(w, x + 1, y) != fluid do return false
	if !is_solid(w, x - 2, y) || !is_solid(w, x + 2, y) do return false      // walled in
	return is_solid(w, x - 1, y + 1) && is_solid(w, x + 1, y + 1)            // flanks stand on rock
}

update_fluid :: proc(gs: ^Game_State) {
	profile_scope("update_fluid")
	for rule, i in fluid_rules {
		gs.fluid.timers[i] += gs.delta_time
		if gs.fluid.timers[i] < rule.period do continue
		gs.fluid.timers[i] = 0
		fluid_step(gs, rule, gs.fluid.flip[i])
		gs.fluid.flip[i] = !gs.fluid.flip[i]
	}
	update_mana_pipe_fill(gs)
}

MANA_PIPE_FILL_PERIOD :: f32(0.3) // seconds between each ring of pipe-fill spread

// A pipe network is its own sealed reservoir, independent of whatever open
// cavern the casing happens to sit in: Mana Mist touching a Piped cell
// spreads into every OPEN Piped cell connected to it, ring by ring, filling
// the whole run over a few seconds regardless of how the surrounding rock is
// shaped — a pipe holds gas even where "the terrain is the plumbing" alone
// wouldn't (an unsealed cavern would just let it rise away).  Two passes
// (mark then fill, both over fixed-size scratch arrays — no [dynamic]) so a
// cell filled this tick doesn't also spread within the same tick: exactly
// one ring of growth per period, deterministic regardless of scan order.
//
// Deliberately NOT mass-conserving — a real, narrow exception to fluid.odin's
// usual law, made safe by what Mana Mist actually is: it has zero economic
// value (nothing bottles or sells it, unlike water/lava through a bucket)
// and powered() is presence-based, not volume-based, so a fuller network
// grants no extra capability — purely the "the whole system is lit" payoff.
// An open (unpiped) end still leaks through the ordinary gas physics above,
// same as an unsealed steam duct.
update_mana_pipe_fill :: proc(gs: ^Game_State) {
	gs.fluid.pipe_fill_timer -= gs.delta_time
	if gs.fluid.pipe_fill_timer > 0 do return
	gs.fluid.pipe_fill_timer = MANA_PIPE_FILL_PERIOD

	w := &gs.world
	to_fill:  [GRID_W * GRID_H]bool
	tint_for: [GRID_W * GRID_H]u8

	for y in 0 ..< GRID_H {
		for x in 0 ..< GRID_W {
			idx := grid_idx(x, y)
			if w.terrain[idx] != .Mana_Mist do continue
			if .Piped not_in w.tile_flags[idx] do continue
			tint := gs.fluid.gem_tint[idx]
			for d in ([4][2]int{{0, -1}, {0, 1}, {1, 0}, {-1, 0}}) {
				nx, ny := x + d[0], y + d[1]
				if !in_bounds(nx, ny) do continue
				nidx := grid_idx(nx, ny)
				if .Piped not_in w.tile_flags[nidx] do continue
				if w.terrain[nidx] != .Air do continue // only spread into genuinely open pipe segments
				to_fill[nidx] = true
				tint_for[nidx] = tint
			}
		}
	}

	for idx in 0 ..< GRID_W * GRID_H {
		if !to_fill[idx] do continue
		set_tile(w, idx % GRID_W, idx / GRID_W, .Mana_Mist)
		gs.fluid.age[idx] = 0
		gs.fluid.gem_tint[idx] = tint_for[idx]
	}
}

// One flow step for every cell of one fluid.  Rows are walked so that a cell
// which moves in the flow direction lands in a row this step has already
// settled and cannot move twice — bottom-up for a falling liquid, TOP-DOWN for
// a rising gas; `moved` catches the sideways case, the only move that can land
// in a cell the scan has yet to reach.
fluid_step :: proc(gs: ^Game_State, rule: Fluid_Rule, flip: bool) {
	w := &gs.world
	fluid := rule.tile
	moved: [GRID_W * GRID_H]bool

	// The whole liquid/gas mirror is this one sign: "down" for a gas is up.
	dy := 1
	if rule.rise do dy = -1

	// A fading fluid's cells are aged in steps, not seconds, so the count fits
	// a u8.  0 = immortal (every liquid).
	life_steps := 0
	if rule.lifetime > 0 do life_steps = int(rule.lifetime / rule.period)

	// Which side is tried first flips every step, so a spreading pool has no
	// permanent lean to one direction.
	dir := 1
	if !flip do dir = -1

	for row in 0 ..< GRID_H {
		y := GRID_H - 1 - row
		if rule.rise do y = row
		for x in 0 ..< GRID_W {
			idx := grid_idx(x, y)
			if w.terrain[idx] != fluid do continue
			if moved[idx] do continue

			// A gas ages every step and finally fades back to open — a vented
			// cloud must never fill a ceiling forever.
			if life_steps > 0 {
				gs.fluid.age[idx] += 1
				if int(gs.fluid.age[idx]) >= life_steps {
					gs.fluid.age[idx] = 0
					set_tile(w, x, y, gravity_open_tile(gs, y))
					continue
				}
			}

			// A spring COPIES itself downward and stays put — the one place
			// fluid enters the world.  Checked before the fall rule, which
			// would otherwise just move this cell into the gap.  It refills
			// only while that gap is open, so a spring feeding a sealed pocket
			// quietly stops: one tile per step, never a runaway.  Gated per
			// fluid: no gas may ever spring.
			if rule.springs && fluid_is_spring(w, x, y, fluid) {
				// Row y+1 is already finished this step (rows run bottom-up),
				// so the newborn cell needs no `moved` guard.
				set_tile(w, x, y + 1, fluid)
				if !gs.spring_hint_shown {
					gs.spring_hint_shown = true
					notify(gs, "A spring wells up - walled this way, it will never run dry")
				}
				continue
			}

			if fluid_open(w, x, y + dy) {
				fluid_move(gs, x, y, x, y + dy, fluid, &moved)
				continue
			}
			if fluid_open(w, x + dir, y) && fluid_open(w, x + dir, y + dy) {
				fluid_move(gs, x, y, x + dir, y + dy, fluid, &moved)
				continue
			}
			if fluid_open(w, x - dir, y) && fluid_open(w, x - dir, y + dy) {
				fluid_move(gs, x, y, x - dir, y + dy, fluid, &moved)
				continue
			}
			// Run for the nearest hole in reach along this row.  Only ever a
			// step toward somewhere it could actually keep flowing, so it
			// closes distance monotonically and can never slosh back and forth.
			d, best := dir, fluid_drop_distance(w, x, y, dir, dy)
			if alt := fluid_drop_distance(w, x, y, -dir, dy); alt != 0 && (best == 0 || alt < best) {
				d, best = -dir, alt
			}
			if best != 0 {
				fluid_move(gs, x, y, x + d, y, fluid, &moved)
				continue
			}

			// Pressure: nowhere to drain, so only a cell with more of its own
			// fluid stacked against it (above for a liquid, below for a gas)
			// pushes sideways, flattening the heap.  The push carries through
			// the cell's own run and surfaces at its open end — the cell this
			// one is pressed against fills the gap it leaves, so the whole
			// body creeps as one.  A settled surface stays put.
			if get_tile(w, x, y - dy) != fluid do continue
			if tx, ok := fluid_push_target(w, x, y, dir, fluid); ok {
				fluid_move(gs, x, y, tx, y, fluid, &moved)
				continue
			}
			if tx, ok := fluid_push_target(w, x, y, -dir, fluid); ok {
				fluid_move(gs, x, y, tx, y, fluid, &moved)
			}
		}
	}
}

// The vacated cell opens exactly as a mined one does (air above the surface
// line and in the sky, void underground), so a drained channel reads the same
// as a dug one.  A cell's age travels with it — moving does not renew a gas.
fluid_move :: proc(
	gs: ^Game_State,
	fx, fy, tx, ty: int,
	fluid: Tile_Type,
	moved: ^[GRID_W * GRID_H]bool,
) {
	set_tile(&gs.world, tx, ty, fluid)
	set_tile(&gs.world, fx, fy, gravity_open_tile(gs, fy))
	gs.fluid.age[grid_idx(tx, ty)] = gs.fluid.age[grid_idx(fx, fy)]
	gs.fluid.age[grid_idx(fx, fy)] = 0
	// Mana Mist only (meaningless, but harmless, for every other fluid): a
	// drifting plume keeps the tint of whichever gem produced it.
	gs.fluid.gem_tint[grid_idx(tx, ty)] = gs.fluid.gem_tint[grid_idx(fx, fy)]
	gs.fluid.gem_tint[grid_idx(fx, fy)] = 0
	moved[grid_idx(tx, ty)] = true
}
