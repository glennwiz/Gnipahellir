package game

// ─── Undermined Structures ────────────────────────────────────────────────────
//
//  Glenn, 2026-11-02: a structure with nothing solid under it breaks into its
//  item, which falls and lands.  Removals have many paths (pick, enemy, Garm,
//  gravity, fluid), so the rule reads the grid each frame rather than hooking
//  them, and the break goes through Tile_Mined, which spills a machine's
//  contents and takes a turret or a door apart.

// Not the tile's own doing: the mine handler logs this id as "the world".
WORLD_ID :: Entity_ID(max(u16))

// Altars and spawners are gates: dropping one could strand a run.  Scroll
// chests are not .Placeable, so they never come here.
@(rodata)
undermine_exempt := #partial [Tile_Type]bool{
    .Sky_Altar               = true,
    .Rune_Altar              = true,
    .Dimension_Spawner       = true,
    .Dimension_Spawner_Gold  = true,
    .Dimension_Spawner_Runic = true,
}

needs_ground :: proc(t: Tile_Type) -> bool {
    return (.Placeable in terrain_table[t].flags || t == .Door) && !undermine_exempt[t]
}

// Glenn, 2026-11-04: a loaded barrel or silo over a hole falls and breaks
// like a bench, its stores spilling as ground piles (spill_store).
@(rodata)
falls_loaded := #partial [Tile_Type]bool{
    .Barrel = true,
    .Silo   = true,
}

// Any other loaded hoard is too heavy to break, the same as under a pick.  It
// stands until it is emptied, and then it falls.
holds_hoard :: proc(gs: ^Game_State, x, y: int) -> bool {
    tile := [2]i32{i32(x), i32(y)}
    t := get_tile(&gs.world, x, y)
    if falls_loaded[t] do return false
    if t == .Auto_Miner {
        m := &gs.dimension.miner
        return m.active && m.base == tile && miner_haul_total(m) > 0
    }
    return wave_target_refused(gs, tile)
}

// Empties a falling store onto the ground, so the mine handler finds it empty
// and breaks it into its own item.
spill_store :: proc(gs: ^Game_State, T: [2]i32) {
    if b := barrel_at(gs, gs.level_index, T); b != nil {
        log_action(gs, "Barrel at (%d,%d) undermined: spills %d", T.x, T.y, barrel_total(b))
        for &s in b.slots {
            spawn_ground_item(&gs.world, T, s.item, s.count)
            s = {}
        }
    }
    if s := silo_at(gs, gs.level_index, T); s != nil {
        log_action(gs, "Silo at (%d,%d) undermined: spills %d", T.x, T.y, silo_total(s))
        for &slot in s.slots {
            spawn_ground_item(&gs.world, T, slot.item, int(slot.count))
            slot = {}
        }
    }
}

ground_gone :: proc(gs: ^Game_State, x, y: int) -> bool {
    return !is_solid(&gs.world, x, y + 1) && !holds_hoard(gs, x, y)
}

is_undermined :: proc(gs: ^Game_State, x, y: int) -> bool {
    return needs_ground(get_tile(&gs.world, x, y)) && ground_gone(gs, x, y)
}

// Pushes Tile_Mined, so it must precede process_events.  It stays a scan: a
// hoard can fall with no tile changing, when it is emptied.  So the cost is
// kept down per cell, deciding each tile type once and not each tile.
update_undermined :: proc(gs: ^Game_State) {
    profile_scope("update_undermined")
    needs: [Tile_Type]bool
    for t in Tile_Type do needs[t] = needs_ground(t)
    for t, i in gs.world.terrain {
        if !needs[t] do continue
        x, y := i % GRID_W, i / GRID_W
        if !ground_gone(gs, x, y) do continue
        if falls_loaded[t] do spill_store(gs, {i32(x), i32(y)})
        eq_push(&gs.events, Event{type = .Tile_Mined, source = WORLD_ID, tile = {i32(x), i32(y)}})
    }
}

// Would emptying (x,y) bring the player's work down?  A structure resting on
// it breaks (is_undermined), and a player-placed block it alone anchors falls
// (gravity).  Golems leave such a cell alone.  A block with an anchor of its
// own besides (x,y), or a stack beside it standing on one, is settled by a
// look at its neighbours; only a block without one costs a gravity search,
// with the cell emptied for the length of it.  in_search: the caller (one A*
// search, which asks of a cell many times) keeps the world still between
// calls, so answers carry over; anyone else starts fresh.
removal_undermines :: proc(gs: ^Game_State, x, y: int, in_search := false) -> bool {
    DIRS :: [4][2]int{{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
    w, m := &gs.world, &gs.held_memo
    if !in_search do held_memo_reset(m)
    i := grid_idx(x, y)
    if m.asked[i] != 0 && m.asked[i] >= m.floor do return m.answer[i]
    m.asked[i] = m.id
    m.answer[i] = true
    if needs_ground(get_tile(w, x, y - 1)) do return true
    blocks: for d in DIRS {
        nx, ny := x + d[0], y + d[1]
        if !in_bounds(nx, ny) do continue
        f := w.tile_flags[grid_idx(nx, ny)]
        if .Placed not_in f || .Golem_Placed in f || !is_faller(w, nx, ny) do continue
        for e in DIRS {
            if e == -d do continue
            ax, ay := nx + e[0], ny + e[1]
            for needs_ground(get_tile(w, ax, ay)) do ay += 1  // a stack holds what it stands on
            if is_anchor_cell(w, ax, ay) do continue blocks
        }
        was := w.terrain[i]
        w.terrain[i] = .Void
        held := gravity_piece_held(gs, nx, ny, {x, y})
        w.terrain[i] = was
        if !held do return true
    }
    m.answer[i] = false
    return false
}
