package game

// ─── Item Placement ───────────────────────────────────────────────────────────
//
//  Right-click places the selected inventory item as a tile.  Input pushes
//  Place_Request with the target tile; the handler validates and mutates.

PLAYER_REACH :: 8  // tiles, chebyshev from player center; placement only (mining uses PICK_RANGE/wands)

// Would placing `item` at tile (x,y) succeed?  Pure — no notify, no mutation —
// so the placement handler and the cursor ghost preview agree exactly.
placement_ok :: proc(gs: ^Game_State, item: Item, x, y: int) -> bool {
    place_tile := item_table[item].place_tile
    if place_tile == .Air do return false          // not placeable
    if !in_bounds(x, y) do return false

    t := get_tile(&gs.world, x, y)                 // target must be open
    if t != .Air && t != .Void do return false

    // The Auto-Miner wakes only inside a spawned dimension, one per expedition.
    if place_tile == .Auto_Miner &&
       (gs.level_index != LEVEL_DIMENSION || gs.dimension.miner.active) {
        return false
    }

    // Silos stand on lasting ground only (a dimension collapses under them),
    // and the record book holds MAX_SILOS.
    if place_tile == .Silo &&
       (gs.level_index == LEVEL_DIMENSION || !silo_slot_free(gs)) {
        return false
    }

    pcx := int(gs.player.pos.x + PLAYER_W*0.5)     // within reach
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    if abs(x - pcx) > PLAYER_REACH || abs(y - pcy) > PLAYER_REACH do return false

    if tpl := structure_template_for(gs, item); tpl != nil {  // finished foundation
        if ok, _ := structure_template_satisfied(&gs.world, tpl, x, y); !ok do return false
    }

    // needs a solid neighbour to attach to
    if !is_solid(&gs.world, x-1, y) && !is_solid(&gs.world, x+1, y) &&
       !is_solid(&gs.world, x, y-1) && !is_solid(&gs.world, x, y+1) {
        return false
    }

    if .Solid in terrain_table[place_tile].flags && tile_overlaps_player(gs, x, y) do return false  // don't seal the player in
    return true
}

handle_place_request :: proc(gs: ^Game_State, e: Event) {
    if gs.player.dead do return
    inv  := &gs.player.inventory
    if inv.selected < 0 do return  // nothing selected
    slot := &inv.slots[inv.selected]
    if slot.item == .None || slot.count <= 0 do return

    place_tile := item_table[slot.item].place_tile
    x := int(e.tile.x)
    y := int(e.tile.y)

    if !placement_ok(gs, slot.item, x, y) {
        // Explain the common templated-structure miss (the red ghost shows the rest).
        if tpl := structure_template_for(gs, slot.item); tpl != nil {
            if ok, want := structure_template_satisfied(&gs.world, tpl, x, y); !ok {
                notify(gs, "The %s needs its %s foundation — build the plan (press B)",
                    tpl.name, terrain_table[want].name)
            }
        }
        // Explain the miner's two gates.
        if place_tile == .Auto_Miner {
            if gs.level_index != LEVEL_DIMENSION {
                notify(gs, "The Auto-Miner only wakes inside a spawned dimension")
            } else if gs.dimension.miner.active {
                notify(gs, "One miner per expedition — reclaim the working one first")
            }
        }
        // Explain the silo's two gates.
        if place_tile == .Silo {
            if gs.level_index == LEVEL_DIMENSION {
                notify(gs, "The silo needs lasting ground — this world will collapse")
            } else if !silo_slot_free(gs) {
                notify(gs, "Every silo is spoken for — reclaim one first")
            }
        }
        return
    }

    slot.count -= 1
    if slot.count == 0 do slot.item = .None
    set_tile(&gs.world, x, y, place_tile)
    gs.world.sim_data[grid_idx(x, y)] = {}  // a fresh machine starts cold, tray empty
    eq_push(&gs.events, Event{type = .Tile_Placed, source = PLAYER_ID, tile = e.tile})

    // A placed spawner is a door waiting to be opened.
    if place_tile == .Dimension_Spawner || place_tile == .Dimension_Spawner_Gold || place_tile == .Dimension_Spawner_Runic {
        notify(gs, "The spawner hums — press [%v] beside it to cross over", gs.bindings[.Interact])
    }

    // A placed Auto-Miner wakes the snake and anchors this dimension.
    if place_tile == .Auto_Miner {
        miner_on_placed(gs, e.tile)
    }

    // A placed Silo opens its record book entry.
    if place_tile == .Silo {
        silo_on_placed(gs, e.tile)
    }

    // Raising a Sky Altar on the surface opens the gate to the heavens above it.
    if place_tile == .Sky_Altar && gs.level_index == LEVEL_SURFACE {
        gs.progression.sky_altar_pos = {i32(x), i32(y)}
        audio_play(&gs.audio, .Fanfare)
        notify(gs, "The Sky Altar rises — a portal opens to the heavens!")
        spawn_deep_blueprint(gs)
    }
}

tile_overlaps_player :: proc(gs: ^Game_State, x, y: int) -> bool {
    p := &gs.player
    return f32(x) < p.pos.x + PLAYER_W && f32(x+1) > p.pos.x &&
           f32(y) < p.pos.y + PLAYER_H && f32(y+1) > p.pos.y
}
