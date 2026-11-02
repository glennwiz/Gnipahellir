package game

// ─── Doors ────────────────────────────────────────────────────────────────────
//
//  A door is two stacked .Door tiles.  It is solid rock to everything —
//  gravity anchors on it, falling blocks rest on it, enemies are walled by it
//  — with ONE exception: the player always walks straight
//  through it (move_body's `is_player`, physics.odin — the player also phases
//  through structures the same way, see is_structure_tile in world.odin).
//  Like any structure it breaks when its ground goes (undermine.odin).
//  No open/close state, no button.  Crafted at the bench (4 Plank), placed as
//  a 1×2 pair.

is_door :: proc(w: ^World_Grid, x, y: int) -> bool {
    return in_bounds(x, y) && w.terrain[grid_idx(x, y)] == .Door
}

// The vertical partner of a door tile (the other of its two stacked cells).
// ok=false for a lone door tile.
door_partner :: proc(w: ^World_Grid, x, y: int) -> (px, py: int, ok: bool) {
    // Doors can stack, so a door tile with doors both ways is not ambiguous:
    // counted up from the foot of the run they alternate foot, head, foot...
    below := 0
    for is_door(w, x, y + below + 1) do below += 1
    py = below % 2 == 0 ? y - 1 : y + 1
    return x, py, is_door(w, x, py)
}

// The two cells a door occupies if placed with its foot at (x,y): the clicked
// cell and the one above it (the door rises).
door_cells :: proc(x, y: int) -> [2][2]int {
    return {{x, y}, {x, y - 1}}
}
