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
        b = Falling_Block{tile = t, x = x, y = f32(y), active = true}
        set_tile(&gs.world, int(x), int(y), gravity_open_tile(gs, int(y)))
        gs.world.tile_flags[grid_idx(int(x), int(y))] -= {.Placed}  // the block left this cell
        return
    }
}

// A tile at (rx,ry) just left the grid.  Any faller that leaned on it may have
// lost its last path to ground — check each neighbour's component and drop it if
// it no longer touches an anchor.  Called once per removal, not per frame.
gravity_check_removed :: proc(gs: ^Game_State, rx, ry: int) {
    visited: [GRID_W * GRID_H]bool
    dirs := [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
    for d in dirs {
        gravity_detach_if_floating(gs, rx + d[0], ry + d[1], &visited)
    }
}

gravity_detach_if_floating :: proc(gs: ^Game_State, sx, sy: int, visited: ^[GRID_W * GRID_H]bool) {
    w := &gs.world
    if !in_bounds(sx, sy) do return
    if visited[grid_idx(sx, sy)] do return
    if !is_faller(w, sx, sy) do return

    dirs := [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}

    comp:  [MAX_FALLING][2]i32   // the connected faller component
    queue: [MAX_FALLING]int      // BFS frontier, as grid indices
    n, qh, qt := 0, 0, 0
    supported := false
    overflow  := false

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
            if is_anchor_cell(w, nx, ny) do supported = true
            if !in_bounds(nx, ny) do continue
            ni := grid_idx(nx, ny)
            if visited[ni] do continue
            if !is_faller(w, nx, ny) do continue
            visited[ni] = true
            if n >= MAX_FALLING { overflow = true; continue }
            comp[n] = {i32(nx), i32(ny)}; n += 1
            queue[qt] = ni; qt += 1
        }
    }

    if supported do return               // still tied to the ground — nothing falls
    if overflow  do return               // too big to lift cleanly — leave it standing
    if n > gravity_free_slots(gs) do return  // no room in the pool right now

    for i in 0 ..< n {
        cx, cy := int(comp[i].x), int(comp[i].y)
        gravity_spawn(gs, comp[i].x, comp[i].y, get_tile(w, cx, cy))
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
            if .Settles in terrain_table[b.tile].flags {
                // Sand-style: the block becomes a tile again where it lands.  r
                // is recomputed each frame off the live grid, and stacked fallers
                // keep their row separation as they drop, so a lower block always
                // settles before the one above reaches it — the tiles stack.  Re-
                // mark .Placed so the settled block is still a faller (stays sand).
                set_tile(w, int(b.x), r - 1, b.tile)
                w.tile_flags[grid_idx(int(b.x), r - 1)] += {.Placed}
            } else if drop := terrain_table[b.tile].drop_item; drop != .None {
                spawn_ground_item(w, {b.x, i32(r - 1)}, drop, 1)   // crumbles to a pile
            }
            b.active = false
        } else {
            b.y = ny
        }
    }
}
