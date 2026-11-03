package game

import "core:math"

// ─── Structural Gravity ───────────────────────────────────────────────────────
//
//  Blocks must stay connected to the ground.  A "faller" tile (a tree trunk, a
//  leaf, a wood block you placed) is held up only while a 4-connected chain of
//  fallers links it to an ANCHOR — any solid tile that is not itself a faller
//  (natural stone, grass, ore, a machine) or the world's own edges.  Cut the
//  last link and the whole hanging piece detaches and slides down one column at
//  a time until it lands (gravity_check_removed → the falling-block pool →
//  update_gravity).
//
//  Scope is deliberately narrow: only tiles flagged `.Falls` fall, so natural
//  terrain never caves in and mining feels exactly as it did.  To make EVERY
//  mined tile obey gravity (full cave-in physics, anchored only to the map
//  edges), flip GRAVITY_ALL — the classification below is the single switch.

GRAVITY_ALL :: false          // false = structural only (trees + placed wood/leaves)
FALL_SPEED  :: f32(3)         // tiles/sec — a gentle settle.  Tune here.
                              // Must stay < 1/DT_CAP (20) so a block never skips a row.

// A faller obeys gravity; an anchor holds fallers up.  Both are decided here so
// the GRAVITY_ALL flip is one edit.  Cell-aware, because .Falls_Placed tiles
// (placed stone/grass) fall only where the .Placed bit is set — the same tile
// type is inert natural terrain everywhere else.
is_faller :: proc(w: ^World_Grid, x, y: int) -> bool {
    if !in_bounds(x, y) do return false
    idx := grid_idx(x, y)
    when GRAVITY_ALL {
        return .Mineable in terrain_table[w.terrain[idx]].flags
    } else {
        f := terrain_table[w.terrain[idx]].flags
        if .Falls in f do return true
        return .Falls_Placed in f && .Placed in w.tile_flags[idx]
    }
}

// Can cell (x,y) root a structure?  The map's edges/floor always can (bedrock);
// in-bounds it must be a non-faller solid.  Air, void and leaves hold nothing.
is_anchor_cell :: proc(w: ^World_Grid, x, y: int) -> bool {
    if !in_bounds(x, y) do return true
    t := w.terrain[grid_idx(x, y)]
    if .Solid not_in terrain_table[t].flags do return false
    return !is_faller(w, x, y)
}

// A falling block rests on any occupied cell — solid ground, a settled block,
// or the map floor (OOB reads as stone).  Open cells (air/void) it falls through.
gravity_blocked :: proc(w: ^World_Grid, x, y: int) -> bool {
    t := get_tile(w, x, y)
    return t != .Air && t != .Void
}

// Does a body stand in cell (x,y)?  A block landing there would wall the body
// in, so it crumbles to its item instead of settling as a tile.
gravity_body_occupies :: proc(gs:^Game_State, x,y:int) -> bool {
	for &g in gs.golems.data {
		if g.status==.Deployed && g.level==gs.level_index && golem_overlaps_cell(&g,x,y) do return true
	}
	if box_overlaps_cell(gs.player.pos, {PLAYER_W, PLAYER_H}, x, y) do return true
	for &e, i in gs.enemies.data {
		if gs.enemies.active[i] && box_overlaps_cell(e.pos, enemy_body_size(e.kind), x, y) do return true
	}
	return false
}

@(private = "file")
box_overlaps_cell :: proc(pos, size: [2]f32, x, y: int) -> bool {
	return pos.x < f32(x+1) && pos.x+size.x > f32(x) &&
	       pos.y < f32(y+1) && pos.y+size.y > f32(y)
}

// What an emptied cell becomes: open air above the surface line / in the sky,
// void underground — mirroring handle_tile_mined so tunnels stay tunnels.
gravity_open_tile :: proc(gs: ^Game_State, y: int) -> Tile_Type {
    if gs.level_index == LEVEL_SKY || (gs.level_index == LEVEL_SURFACE && y < SURFACE_Y) {
        return .Air
    }
    return .Void
}

gravity_free_slots :: proc(gs: ^Game_State) -> int {
    n := 0
    for b in gs.gravity.blocks do if !b.active do n += 1
    return n
}

// Lift tile (x,y) out of the grid and into the falling pool.
gravity_spawn :: proc(gs: ^Game_State, x, y: i32, t: Tile_Type) {
    for &b in gs.gravity.blocks {
        if b.active do continue
        idx := grid_idx(int(x), int(y))
        golem_placed := .Golem_Placed in gs.world.tile_flags[idx]
        owner, grace_expiry, has_grace := golem_block_grace_details(gs,{x,y})
        if !has_grace do owner = -1
        b = Falling_Block{
            tile = t,
            x = x,
            y = f32(y),
            source_x = x,
            source_y = y,
            golem_placed = golem_placed,
            golem_owner = i16(owner),
            grace_expires_at = grace_expiry,
            active = true,
        }
        set_tile(&gs.world, int(x), int(y), gravity_open_tile(gs, int(y)))
        golem_remove_block_mark(gs,{x,y})
        gs.world.tile_flags[idx] -= {.Placed,.Golem_Placed}  // the block left this cell
        gs.monument_cells[gs.level_index][idx] = .Air
        return
    }
}

// A tile at (rx,ry) just left the grid.  Any faller that leaned on it may have
// lost its last path to ground — check each neighbour's component and drop it if
// it no longer touches an anchor.  A loaded hoard stands with no ground but holds
// nothing up, so whatever leans on the stack above the hole is checked too.
// Called once per removal, not per frame.
//
// A detached piece can leave a stack behind, which is one more hole to check.
// Those go on a list, not the call stack: the Windows stack is small and each
// check holds a whole-grid array.  One entry per block lifted, so it can't fill.
gravity_check_removed :: proc(gs: ^Game_State, rx, ry: int) {
    holes: [MAX_FALLING + 1][2]i32
    holes[0] = {i32(rx), i32(ry)}
    n := 1
    dirs := [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
    visited: [GRID_W * GRID_H]bool
    for i := 0; i < n; i += 1 {
        x := int(holes[i].x)
        for y := int(holes[i].y); ; y -= 1 {
            for d in dirs {
                gravity_detach_if_floating(gs, x + d[0], y + d[1], &visited, holes[:], &n)
            }
            if !needs_ground(get_tile(&gs.world, x, y - 1)) do break
        }
    }
}

// Is this piece held up?  By an anchor it touches, or by a structure it touches
// whose stack rests on solid ground.  A stack resting on another piece is only
// as good as that piece, so the search carries on through it; a stack resting
// on a piece already searched adds nothing, so floating pieces cannot hold each
// other up.  A search too big to finish leaves the piece standing.
gravity_piece_held :: proc(w: ^World_Grid, sx, sy: int) -> bool {
    dirs := [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
    seen:  [GRID_W * GRID_H]bool
    cells: [MAX_FALLING][2]i32
    cells[0] = {i32(sx), i32(sy)}
    seen[grid_idx(sx, sy)] = true
    n := 1

    for i := 0; i < n; i += 1 {
        for d in dirs {
            x := int(cells[i].x) + d[0]
            y := int(cells[i].y) + d[1]
            for needs_ground(get_tile(w, x, y)) do y += 1
            if is_anchor_cell(w, x, y) do return true
            if !is_faller(w, x, y) || seen[grid_idx(x, y)] do continue
            if n == MAX_FALLING do return true
            seen[grid_idx(x, y)] = true
            cells[n] = {i32(x), i32(y)}; n += 1
        }
    }
    return false
}

gravity_detach_if_floating :: proc(gs: ^Game_State, sx, sy: int, visited: ^[GRID_W * GRID_H]bool, holes: [][2]i32, n_holes: ^int) {
    w := &gs.world
    if !in_bounds(sx, sy) do return
    if visited[grid_idx(sx, sy)] do return
    if !is_faller(w, sx, sy) do return

    dirs := [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}

    comp:  [MAX_FALLING][2]i32   // the connected faller component
    queue: [MAX_FALLING]int      // BFS frontier, as grid indices
    n, qh, qt := 0, 0, 0

    si := grid_idx(sx, sy)
    visited[si] = true
    queue[qt] = si; qt += 1
    comp[n] = {i32(sx), i32(sy)}; n += 1

    for qh < qt {
        idx := queue[qh]; qh += 1
        cx := idx % GRID_W
        cy := idx / GRID_W
        for d in dirs {
            nx := cx + d[0]
            ny := cy + d[1]
            if !in_bounds(nx, ny) do continue
            ni := grid_idx(nx, ny)
            if visited[ni] do continue
            if !is_faller(w, nx, ny) do continue
            visited[ni] = true
            if n >= MAX_FALLING do continue  // the search below finds it too big
            comp[n] = {i32(nx), i32(ny)}; n += 1
            queue[qt] = ni; qt += 1
        }
    }

    if gravity_piece_held(w, sx, sy) do return  // tied to the ground, or too big to tell
    if n > gravity_free_slots(gs) do return  // no room in the pool right now

    for i in 0 ..< n {
        cx, cy := int(comp[i].x), int(comp[i].y)
        gravity_spawn(gs, comp[i].x, comp[i].y, get_tile(w, cx, cy))
    }

    // A loaded hoard on this piece stays behind in the air.
    for i in 0 ..< n {
        cx, cy := int(comp[i].x), int(comp[i].y)
        if needs_ground(get_tile(w, cx, cy - 1)) {
            holes[n_holes^] = comp[i]
            n_holes^ += 1
        }
    }
}

// Slide every airborne block down; when it lands it becomes a collectible drop
// where it came to rest — a felled tree crumbles into a pile of logs and leaves
// for the player to gather, rather than re-settling as solid tiles.
update_gravity :: proc(gs: ^Game_State) {
    profile_scope("update_gravity")
    w  := &gs.world
    dt := gs.delta_time

    for &b in gs.gravity.blocks {
        if !b.active do continue
        // first blocked cell below → the block comes to rest one row above it
        r := int(math.floor(b.y)) + 1
        for r < GRID_H && !gravity_blocked(w, int(b.x), r) do r += 1
        rest := f32(r - 1)

        ny := b.y + FALL_SPEED * dt
        if ny >= rest {
            occupied:=gravity_body_occupies(gs,int(b.x),r-1)
            if .Settles in terrain_table[b.tile].flags && !occupied {
                // Sand-style: the block becomes a tile again where it lands.  r
                // is recomputed each frame off the live grid, and stacked fallers
                // keep their row separation as they drop, so a lower block always
                // settles before the one above reaches it — the tiles stack.  Re-
                // mark .Placed so the settled block is still a faller (stays sand).
                set_tile(w, int(b.x), r - 1, b.tile)
                settled := [2]i32{b.x,i32(r-1)}
                settled_idx := grid_idx(int(settled.x),int(settled.y))
                w.tile_flags[settled_idx] += {.Placed}
                if b.golem_placed {
                    w.tile_flags[settled_idx] += {.Golem_Placed}
                    if b.golem_owner >= 0 && b.grace_expires_at > gs.elapsed_time {
                        golem_register_block_grace_until(gs,int(b.golem_owner),settled,b.grace_expires_at)
                    }
                }
            } else if drop := terrain_table[b.tile].drop_item; drop != .None {
                spawn_ground_item(w, {b.x, i32(r - 1)}, drop, 1)   // crumbles to a pile
            }
            b.active = false
        } else {
            b.y = ny
        }
    }
}
