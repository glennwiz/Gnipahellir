package game

// ─── Doors ────────────────────────────────────────────────────────────────────
//
//  A door is two stacked .Door tiles.  It is solid rock to everything —
//  gravity anchors on it, falling blocks rest on it, enemies are walled by it,
//  it never falls — with ONE exception: the player always walks straight
//  through it (move_body's `pass_doors`, physics.odin).  No open/close state,
//  no button.  Crafted at the bench (4 Plank), placed as a 1×2 pair.

is_door :: proc(w: ^World_Grid, x, y: int) -> bool {
    return in_bounds(x, y) && w.terrain[grid_idx(x, y)] == .Door
}

// The vertical partner of a door tile (the other of its two stacked cells).
// Prefers below, then above.  ok=false for a lone door tile.
door_partner :: proc(w: ^World_Grid, x, y: int) -> (px, py: int, ok: bool) {
    if is_door(w, x, y + 1) do return x, y + 1, true
    if is_door(w, x, y - 1) do return x, y - 1, true
    return 0, 0, false
}

// The two cells a door occupies if placed with its foot at (x,y): the clicked
// cell and the one above it (the door rises).
door_cells :: proc(x, y: int) -> [2][2]int {
    return {{x, y}, {x, y - 1}}
}
