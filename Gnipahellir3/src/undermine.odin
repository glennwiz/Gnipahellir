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

// A loaded hoard is too heavy to break, the same as under a pick.  It stands
// until it is emptied, and then it falls.
holds_hoard :: proc(gs: ^Game_State, x, y: int) -> bool {
    tile := [2]i32{i32(x), i32(y)}
    if get_tile(&gs.world, x, y) == .Auto_Miner {
        m := &gs.dimension.miner
        return m.active && m.base == tile && miner_haul_total(m) > 0
    }
    return wave_target_refused(gs, tile)
}

is_undermined :: proc(gs: ^Game_State, x, y: int) -> bool {
    return needs_ground(get_tile(&gs.world, x, y)) && !is_solid(&gs.world, x, y + 1) &&
           !holds_hoard(gs, x, y)
}

// Pushes Tile_Mined, so it must precede process_events.
update_undermined :: proc(gs: ^Game_State) {
    for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
        if !is_undermined(gs, x, y) do continue
        eq_push(&gs.events, Event{type = .Tile_Mined, source = WORLD_ID, tile = {i32(x), i32(y)}})
    }
}
