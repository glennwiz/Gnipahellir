package game

// ─── Item Placement ───────────────────────────────────────────────────────────
//
//  Right-click places the selected inventory item as a tile.  Input pushes
//  Place_Request with the target tile; the handler validates and mutates.

PLAYER_REACH :: 5  // tiles, chebyshev from player center; shared by placing and mining

handle_place_request :: proc(gs: ^Game_State, e: Event) {
    if gs.player.dead do return
    inv  := &gs.player.inventory
    slot := &inv.slots[inv.selected]
    if slot.item == .None || slot.count <= 0 do return

    place_tile := item_table[slot.item].place_tile
    if place_tile == .Air do return  // not placeable

    x := int(e.tile.x)
    y := int(e.tile.y)
    if !in_bounds(x, y) do return

    // Target must be open (air above ground, void below)
    t := get_tile(&gs.world, x, y)
    if t != .Air && t != .Void do return

    // Within reach of the player
    pcx := int(gs.player.pos.x + PLAYER_W*0.5)
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    if abs(x - pcx) > PLAYER_REACH || abs(y - pcy) > PLAYER_REACH do return

    // Templated structures (the Sky Altar) stand only on a finished foundation.
    if tpl := structure_template_for(gs, slot.item); tpl != nil {
        if ok, want := structure_template_satisfied(&gs.world, tpl, x, y); !ok {
            notify(gs, "The %s needs its %s foundation — build the plan (press B)",
                tpl.name, terrain_table[want].name)
            return
        }
    }

    // Needs a solid neighbour to attach to
    if !is_solid(&gs.world, x-1, y) && !is_solid(&gs.world, x+1, y) &&
       !is_solid(&gs.world, x, y-1) && !is_solid(&gs.world, x, y+1) {
        return
    }

    // Never seal a solid tile around the player
    if .Solid in terrain_table[place_tile].flags && tile_overlaps_player(gs, x, y) do return

    slot.count -= 1
    if slot.count == 0 do slot.item = .None
    set_tile(&gs.world, x, y, place_tile)
    eq_push(&gs.events, Event{type = .Tile_Placed, source = PLAYER_ID, tile = e.tile})
}

tile_overlaps_player :: proc(gs: ^Game_State, x, y: int) -> bool {
    p := &gs.player
    return f32(x) < p.pos.x + PLAYER_W && f32(x+1) > p.pos.x &&
           f32(y) < p.pos.y + PLAYER_H && f32(y+1) > p.pos.y
}
