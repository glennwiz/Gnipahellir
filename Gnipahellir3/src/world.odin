package game

import rl "vendor:raylib"

// ─── Terrain Behavior Table ───────────────────────────────────────────────────

Terrain_Behavior :: struct {
	name:              string,
	flags:             Terrain_Flags,
	color:             rl.Color,
	move_cost:         f32, // 0 = solid, 1 = normal, 2 = slow
	damage_per_second: f32,
	drop_item:         Item,
	drop_pct:          u8, // % chance the drop appears; 0 = guaranteed
}

// The hover line for a tile: its own desc when it has one, otherwise the desc
// of the item it mines into.  Read-only table lookup.
tile_desc :: proc(t: Tile_Type) -> string {
	if d := terrain_desc[t]; d != "" do return d
	return item_table[terrain_table[t].drop_item].desc
}

// ─── Grid Helpers ─────────────────────────────────────────────────────────────

grid_idx :: #force_inline proc(x, y: int) -> int {
	return y * GRID_W + x
}

in_bounds :: #force_inline proc(x, y: int) -> bool {
	return x >= 0 && x < GRID_W && y >= 0 && y < GRID_H
}

get_tile :: #force_inline proc(w: ^World_Grid, x, y: int) -> Tile_Type {
	if !in_bounds(x, y) do return .Stone
	return w.terrain[grid_idx(x, y)]
}

set_tile :: proc(w: ^World_Grid, x, y: int, t: Tile_Type) {
	if !in_bounds(x, y) do return
	w.terrain[grid_idx(x, y)] = t
}

is_solid :: #force_inline proc(w: ^World_Grid, x, y: int) -> bool {
	t := get_tile(w, x, y)
	return .Solid in terrain_table[t].flags
}

// ─── Entity Map ───────────────────────────────────────────────────────────────
//
//  entity_map is a per-tile position index (center tile, last-writer-wins),
//  maintained by the player and enemy updates and used for entity lookups.
//  It is NOT a movement constraint: bodies are continuous AABBs and may
//  transiently overlap, in which case the later writer owns the cell.

entity_map_move :: proc(w: ^World_Grid, id: Entity_ID, from, to: [2]i32) {
	if in_bounds(int(from.x), int(from.y)) {
		idx := grid_idx(int(from.x), int(from.y))
		if w.entity_map[idx] == id do w.entity_map[idx] = INVALID_ENTITY
	}
	if in_bounds(int(to.x), int(to.y)) {
		w.entity_map[grid_idx(int(to.x), int(to.y))] = id
	}
}

entity_map_clear :: proc(w: ^World_Grid, id: Entity_ID, at: [2]i32) {
	if !in_bounds(int(at.x), int(at.y)) do return
	idx := grid_idx(int(at.x), int(at.y))
	if w.entity_map[idx] == id do w.entity_map[idx] = INVALID_ENTITY
}

// ─── World Generation Helpers ─────────────────────────────────────────────────

// Deterministic hash — u32 wraps naturally, no overflow concerns
whash :: proc(n: u32) -> u32 {
	x := n * 2246822519 + 2654435761
	x = x * 2246822519 + 2654435761
	return x
}

// Crown offsets relative to the top of the trunk
@(rodata)
CROWN_OFFSETS := [][2]int {
	{0, -2},
	{-1, -1},
	{0, -1},
	{1, -1},
	{-2, 0},
	{-1, 0},
	{0, 0},
	{1, 0},
	{2, 0},
	{-1, 1},
	{0, 1},
	{1, 1},
}

place_tree :: proc(w: ^World_Grid, x, surface_y, height: int) {
	trunk_top := surface_y - height

	// Trunk: wood from trunk_top up to (but not including) surface_y
	for y in trunk_top ..< surface_y {
		set_tile(w, x, y, .Wood)
	}

	// Crown: leaves relative to trunk_top
	for off in CROWN_OFFSETS {
		lx := x + off[0]
		ly := trunk_top + off[1]
		if in_bounds(lx, ly) && get_tile(w, lx, ly) == .Air {
			set_tile(w, lx, ly, .Leaves)
		}
	}
}

// ─── World Constants ──────────────────────────────────────────────────────────

SURFACE_Y :: 54
CAVE_TOP :: SURFACE_Y + 6 // solid stone cap between surface and cave
SURFACE_HOME_POS :: [2]f32{f32(GRID_W/2) - 8, SURFACE_Y - PLAYER_H} // new-game spawn; also the Jade Ring's destination
SHAFT_APRON_REACH :: 4 // tiles of scuffed earth each side of the descent shaft;
// shared by render (the brown apron) and mining (the rock+dirt yield) so the
// loot lines up exactly with the dressed lip.

// True for a ground tile in the surface cap band that sits within
// SHAFT_APRON_REACH tiles of a descent-shaft Void column, with only solid
// ground between it and the shaft — the exact tiles draw_shaft_mouth scuffs
// brown.  Reads terrain only.
in_shaft_apron :: proc(w: ^World_Grid, x, y: int) -> bool {
	if y < SURFACE_Y || y >= CAVE_TOP do return false
	for dir in ([]int{-1, 1}) {
		for step in 1 ..= SHAFT_APRON_REACH {
			nx := x + dir * step
			if nx < 0 || nx >= GRID_W do break
			t := w.terrain[grid_idx(nx, y)]
			if t == .Void {
				if is_shaft_column(w, nx) do return true
				break // a shallow dig — no apron, and a gap besides
			}
			if t == .Air do break
		}
	}
	return false
}

// A Void column running the entire surface cap band — the entrance shaft
// punches clean through to the cave.  A shallow surface dig leaves solid rows
// below it and does not qualify, so ordinary digging never spawns a new apron;
// a hand-dug full-depth shaft earns the dressed mouth and the dirt yield.
is_shaft_column :: proc(w: ^World_Grid, x: int) -> bool {
	for y in SURFACE_Y ..< CAVE_TOP {
		if w.terrain[grid_idx(x, y)] != .Void do return false
	}
	return true
}
CAVE_BOT :: GRID_H - 2 // two-row stone floor at world bottom
CAVE_LEFT :: 1
CAVE_RIGHT :: GRID_W - 1

// ─── Cave Generation Helpers ──────────────────────────────────────────────────

carve_ellipse :: proc(w: ^World_Grid, cx, cy, rx, ry: int) {
	for dy in -ry ..= ry {
		for dx in -rx ..= rx {
			if dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry {
				set_tile(w, cx + dx, cy + dy, .Void)
			}
		}
	}
}

// Cellular automata cave generation for level 1.
// Writes Void cells into the already-stone cave region.
gen_cave_1 :: proc(w: ^World_Grid, seed: u32 = 0) {
	// Two working buffers; true = solid stone
	buf_a: [GRID_W * GRID_H]bool
	buf_b: [GRID_W * GRID_H]bool

	// ── 1. Random initial fill (~45% stone) ───────────────────────
	// Double-hash each axis independently then XOR for better 2D distribution
	for y in CAVE_TOP ..< CAVE_BOT {
		for x in CAVE_LEFT ..< CAVE_RIGHT {
			h := whash(u32(x) * 374761393 + seed) ~ whash(u32(y) * 668265263 + seed)
			buf_a[grid_idx(x, y)] = (h % 100) < 45
		}
	}
	// Solid border so the cave is always enclosed
	for y in CAVE_TOP ..< CAVE_BOT {
		buf_a[grid_idx(CAVE_LEFT, y)] = true
		buf_a[grid_idx(CAVE_RIGHT - 1, y)] = true
	}
	for x in CAVE_LEFT ..< CAVE_RIGHT {
		buf_a[grid_idx(x, CAVE_TOP)] = true
		buf_a[grid_idx(x, CAVE_BOT - 1)] = true
	}

	// ── 2. Cellular automata — 5 smoothing passes ─────────────────
	// Rule: stone cell survives if >=4 solid neighbours
	//       void  cell fills   if  >4 solid neighbours
	src := buf_a[:]
	dst := buf_b[:]
	for _ in 0 ..< 5 {
		for y in CAVE_TOP ..< CAVE_BOT {
			for x in CAVE_LEFT ..< CAVE_RIGHT {
				if x == CAVE_LEFT || x == CAVE_RIGHT - 1 || y == CAVE_TOP || y == CAVE_BOT - 1 {
					dst[grid_idx(x, y)] = true
					continue
				}
				solid := 0
				for dy in -1 ..= 1 {
					for dx in -1 ..= 1 {
						if dx == 0 && dy == 0 do continue
						if src[grid_idx(x + dx, y + dy)] do solid += 1
					}
				}
				if src[grid_idx(x, y)] {
					dst[grid_idx(x, y)] = solid >= 4
				} else {
					dst[grid_idx(x, y)] = solid > 4
				}
			}
		}
		src, dst = dst, src
	}

	// ── 3. Apply CA result to terrain ─────────────────────────────
	for y in CAVE_TOP ..< CAVE_BOT {
		for x in CAVE_LEFT ..< CAVE_RIGHT {
			if !src[grid_idx(x, y)] {
				set_tile(w, x, y, .Void)
			}
		}
	}

	// ── 4. Guarantee three open chambers so the cave isn't too tight
	mid_y := (CAVE_TOP + CAVE_BOT) / 2
	carve_ellipse(w, GRID_W / 4, CAVE_TOP + 15, 9, 6)
	carve_ellipse(w, GRID_W / 2, mid_y, 10, 7)
	carve_ellipse(w, 3 * GRID_W / 4, CAVE_BOT - 15, 9, 6)

	// ── 5. Entrance shaft: Void column from surface down into cave ─
	ent_x := GRID_W / 2
	for y in SURFACE_Y ..< CAVE_TOP {
		set_tile(w, ent_x, y, .Void)
		set_tile(w, ent_x + 1, y, .Void)
	}
	// Small landing chamber at the bottom of the shaft
	carve_ellipse(w, ent_x, CAVE_TOP + 4, 5, 3)

	// ── 6. Snapshot void cells BEFORE adding formations ───────────
	// Critical: stalactites/stalagmites must only detect ORIGINAL
	// ceilings/floors. Without this, each placed stone becomes a new
	// ceiling and cascades into long vertical lines all the way down.
	void_snap: [GRID_W * GRID_H]bool
	for y in CAVE_TOP ..< CAVE_BOT {
		for x in CAVE_LEFT ..< CAVE_RIGHT {
			void_snap[grid_idx(x, y)] = (get_tile(w, x, y) == .Void)
		}
	}

	// ── 7. Stalactites — fingers from original ceilings only ───────
	for x in CAVE_LEFT ..< CAVE_RIGHT {
		for y in CAVE_TOP + 1 ..< CAVE_BOT - 1 {
			// Original ceiling: this cell was void, cell above was stone
			if void_snap[grid_idx(x, y)] && !void_snap[grid_idx(x, y - 1)] {
				h := whash(u32(x) * 54321 + u32(y))
				if h % 4 == 0 { 	// 25% of ceiling positions
					tip := 1 + int((h >> 8) % 2) // 1–2 tiles
					for i in 0 ..< tip {
						ny := y + i
						if ny < CAVE_BOT - 1 && void_snap[grid_idx(x, ny)] {
							set_tile(w, x, ny, .Stone)
						}
					}
				}
			}
		}
	}

	// ── 8. Stalagmites — fingers from original floors only ─────────
	for x in CAVE_LEFT ..< CAVE_RIGHT {
		for y in CAVE_TOP + 1 ..< CAVE_BOT - 1 {
			// Original floor: this cell was void, cell below was stone
			if void_snap[grid_idx(x, y)] && !void_snap[grid_idx(x, y + 1)] {
				h := whash(u32(x) * 98765 + u32(y))
				if h % 5 == 0 { 	// 20% of floor positions
					tip := 1 + int((h >> 8) % 2) // 1–2 tiles
					for i in 0 ..< tip {
						ny := y - i
						if ny > CAVE_TOP && void_snap[grid_idx(x, ny)] {
							set_tile(w, x, ny, .Stone)
						}
					}
				}
			}
		}
	}

	// ── 9. Ore veins — depth-scaled scatter in stone walls ─────────
	for y in CAVE_TOP ..< CAVE_BOT {
		for x in CAVE_LEFT ..< CAVE_RIGHT {
			if get_tile(w, x, y) != .Stone do continue
			h := whash(u32(x) * 2654435761 + u32(y) * 1013904223)
			gh := whash(h) // fresh bits for the gem roll — per-mille, not per-cent
			depth := y - CAVE_TOP
			switch {
			// Gems first: sparse enough that they steal almost nothing from
			// the metals, and a metal roll must never mask one.
			case depth > 30 && gh % 1000 < 5:
				set_tile(w, x, y, .Emerald_Ore)
			case (h % 100) < 6:
				set_tile(w, x, y, .Iron_Ore)
			case depth > 20 && (h >> 8) % 100 < 3:
				set_tile(w, x, y, .Silver_Ore)
			case depth > 35 && (h >> 16) % 100 < 1:
				set_tile(w, x, y, .Gold_Ore)
			}
		}
	}

	// ── 10. Green cave mushrooms — sparse forage on cave floors ────
	// A mushroom grows where the cave opens onto solid ground; mined for the
	// GreenBerrie's cave-trip ingredient.
	for y in CAVE_TOP ..< CAVE_BOT - 1 {
		for x in CAVE_LEFT ..< CAVE_RIGHT {
			if get_tile(w, x, y) != .Void do continue
			if .Solid not_in terrain_table[get_tile(w, x, y + 1)].flags do continue
			mh := whash(u32(x) * 374761393 + u32(y) * 668265263)
			if mh % 100 < 2 {
				set_tile(w, x, y, .Green_Cave_Mushroom)
			}
		}
	}

}

// ─── World Init ───────────────────────────────────────────────────────────────

world_init :: proc(w: ^World_Grid, seed: u32 = 0) {
	// Zero entity map
	for i in 0 ..< GRID_W * GRID_H {
		w.terrain[i] = .Void
		w.entity_map[i] = INVALID_ENTITY
	}

	// Sky
	for y in 0 ..< SURFACE_Y {
		for x in 0 ..< GRID_W {
			set_tile(w, x, y, .Air)
		}
	}

	// Surface: grass + stone cap
	for x in 0 ..< GRID_W {
		set_tile(w, x, SURFACE_Y, .Grass)
		set_tile(w, x, SURFACE_Y + 1, .Stone)
		set_tile(w, x, SURFACE_Y + 2, .Stone)
		set_tile(w, x, SURFACE_Y + 3, .Stone)
	}

	// Fill underground with stone (cave gen will carve into this)
	for y in SURFACE_Y + 4 ..< GRID_H {
		for x in 0 ..< GRID_W {
			set_tile(w, x, y, .Stone)
		}
	}

	// Cave level 1
	gen_cave_1(w, seed)

	// Surface decoration: pond, trees, flowers
	CHUNK :: 12
	ent_x := GRID_W / 2

	// A single earthen pond, seeded per world: water at the center, exposed
	// clay banks around it (the mineable "water clay" starter material, now
	// deliberately placed instead of scattered randomly through cave walls),
	// sand at the shore.  Kept clear of the spawn shaft and the Sky Rune
	// Scroll chest (both sit within POND_EXCLUDE of ent_x) by restricting the
	// center to one of two safe bands to either side.
	POND_RADIUS  :: 5
	POND_EXCLUDE :: 36 // half-width of the spawn/rune-chest no-go band around ent_x
	ph := whash(909090 + seed)
	band_lo, band_hi := 16, ent_x - POND_EXCLUDE
	if ph % 2 == 1 {
		band_lo, band_hi = ent_x + POND_EXCLUDE, GRID_W - 16
	}
	pond_x := band_lo + POND_RADIUS + int((ph >> 8) % u32(max(band_hi-band_lo-2*POND_RADIUS, 1)))
	for dx in -POND_RADIUS ..= POND_RADIUS {
		x := pond_x + dx
		switch dist := abs(dx); {
		case dist <= 2:
			set_tile(w, x, SURFACE_Y, .Water)
			set_tile(w, x, SURFACE_Y + 1, .Water)
			set_tile(w, x, SURFACE_Y + 2, .Clay)
		case dist <= 4:
			set_tile(w, x, SURFACE_Y, .Clay)
		case:
			set_tile(w, x, SURFACE_Y, .Sand)
		}
	}

	// The Scroll of Waters rests on the pond's sand shore — the fluid system
	// explains itself where you first meet it.  Sits on the rim cell so it is
	// visible from the bank; the tree and flower loops below already skip
	// everything within POND_RADIUS+1, so nothing overwrites it.
	scroll_x := pond_x + POND_RADIUS
	if in_bounds(scroll_x, SURFACE_Y - 1) {
		scroll_idx := grid_idx(scroll_x, SURFACE_Y - 1)
		w.items[scroll_idx] = .Scroll_Of_Waters
		w.item_counts[scroll_idx] = 1
	}

	for chunk in 0 ..< GRID_W / CHUNK {
		h1 := whash(u32(chunk) * 31337 + seed)
		h2 := whash(u32(chunk) * 99991 + seed)

		if h1 % 10 < 7 {
			tx := chunk * CHUNK + int(h1 % u32(CHUNK))
			tree_height := 3 + int(h2 % 3)
			if abs(tx - ent_x) > 3 && abs(tx - pond_x) > POND_RADIUS + 1 && in_bounds(tx, SURFACE_Y) {
				place_tree(w, tx, SURFACE_Y, tree_height)
			}
		}
	}

	// A handful of wild flowers for the whole surface — the seed source for
	// flower farming, deliberately scarce (beds are how you scale up).
	flower_count := 5 + int(whash(424242 + seed) % 4)   // 5–8 across the level
	for i in 0 ..< flower_count {
		hf := whash(u32(i) * 2654435761 + 101 + seed)
		fx := int(hf % u32(GRID_W))
		fy := SURFACE_Y - 1
		if in_bounds(fx, fy) && get_tile(w, fx, fy) == .Air && abs(fx-pond_x) > POND_RADIUS+1 {
			set_tile(w, fx, fy, .Flower)
		}
	}

	// Starter pickaxe waits ~7 tiles down the entrance shaft — the player drops
	// in (a small fall, minor damage) to reach it, and the surface stays a
	// short mine/climb back up.  It rests on a stone ledge; the cave lies below,
	// so first blood is chipping through this floor with the pick you just got.
	pick_y := SURFACE_Y + 7                   // ledge row, ~7-tile drop from grass
	for x in ent_x ..= ent_x + 1 {            // clear the full 2-wide drop
		for y in SURFACE_Y ..= pick_y {
			set_tile(w, x, y, .Void)
		}
		set_tile(w, x, pick_y + 1, .Stone)    // floor to land on / rest the pick
	}
	pick_idx := grid_idx(ent_x, pick_y)
	w.items[pick_idx] = .Pickaxe
	w.item_counts[pick_idx] = 1

	// Portals to cave 2 and the sky, plus Rune Scroll A
	carve_level0_portals(w)
}