package game

// Progression blueprints never lie loose in the world: every world placement
// is a permanent storage coffer.  The four tile variants make its initial
// blueprint self-describing before the first opening creates a barrel record.

BLUEPRINT_CHEST_SLOT :: 5 // second row/column in the shared barrel-window grid

is_blueprint_chest :: proc(t: Tile_Type) -> bool {
    return t == .Sky_Blueprint_Chest || t == .Blueprint_Chest_A ||
           t == .Blueprint_Chest_B || t == .Blueprint_Chest_C
}

blueprint_chest_item :: proc(t: Tile_Type) -> (Item, bool) {
    #partial switch t {
    case .Sky_Blueprint_Chest: return .Sky_Blueprint, true
    case .Blueprint_Chest_A:   return .Blueprint_A, true
    case .Blueprint_Chest_B:   return .Blueprint_B, true
    case .Blueprint_Chest_C:   return .Blueprint_C, true
    case:                      return .None, false
    }
}

blueprint_chest_tile :: proc(it: Item) -> (Tile_Type, bool) {
    #partial switch it {
    case .Sky_Blueprint: return .Sky_Blueprint_Chest, true
    case .Blueprint_A:   return .Blueprint_Chest_A, true
    case .Blueprint_B:   return .Blueprint_Chest_B, true
    case .Blueprint_C:   return .Blueprint_Chest_C, true
    case:                return .Air, false
    }
}

// Put one blueprint into a sealed coffer at an already-open cell.
place_blueprint_chest :: proc(w: ^World_Grid, x, y: int, it: Item) -> bool {
    if !in_bounds(x, y) do return false
    chest, ok := blueprint_chest_tile(it)
    if !ok do return false
    idx := grid_idx(x, y)
    // A one-cell chest can safely restore only ordinary open backdrop when it
    // is claimed; never overwrite water, flowers, portals, or other terrain.
    if w.terrain[idx] != .Air && w.terrain[idx] != .Void do return false
    if w.items[idx] != .None && w.item_counts[idx] > 0 do return false
    set_tile(w, x, y, chest)
    w.items[idx]       = .None
    w.item_counts[idx] = 0
    return true
}

// The open cell restored after a coffer is claimed matches the level backdrop.
blueprint_chest_backdrop :: proc(level_index, y: int) -> Tile_Type {
    if level_index == LEVEL_SKY || (level_index == LEVEL_SURFACE && y < SURFACE_Y) {
        return .Air
    }
    return .Void
}

// Open the coffer as an ordinary 4×4 storage container.  Its first opening
// claims one barrel record and seeds the contained blueprint into a normal
// slot; all sixteen slots can immediately store ordinary items.
// Returns true when tile was a blueprint chest, even when it was out of reach.
open_blueprint_chest :: proc(gs: ^Game_State, tile: [2]i32) -> bool {
    x, y := int(tile.x), int(tile.y)
    if !in_bounds(x, y) do return false
    chest := get_tile(&gs.world, x, y)
    it, ok := blueprint_chest_item(chest)
    if !ok do return false

    if chebyshev(tile, player_tile(&gs.player)) > BENCH_RANGE {
        notify(gs, "The blueprint chest is too far away")
        return true
    }

    if barrel_at(gs, gs.level_index, tile) == nil {
        storage: ^Barrel_State
        for &b in gs.sim.barrels {
            if !b.active {
                storage = &b
                break
            }
        }
        if storage == nil {
            notify(gs, "Too many storage containers - reclaim an empty barrel first")
            return true
        }
        storage^ = {
            active = true,
            level  = gs.level_index,
            tile   = tile,
        }
        storage.slots[BLUEPRINT_CHEST_SLOT] = {it, 1}
        gs.save_dirty = true
    }

    gs.ui.show_barrel    = true
    gs.ui.barrel_tile    = tile
    gs.ui.show_inventory = true
    log_action(gs, "Player opens %s container at (%d,%d)", terrain_table[chest].name, x, y)
    return true
}

// Withdraw the blueprint through the same drag path as any barrel stack, then
// emit the progression pickup event.  The chest and its storage record remain.
blueprint_chest_take :: proc(gs: ^Game_State, b: ^Barrel_State, slot: int) {
    if b == nil || slot < 0 || slot >= BARREL_SLOTS do return
    tile := b.tile
    x, y := int(tile.x), int(tile.y)
    if !in_bounds(x, y) do return
    s := &b.slots[slot]
    it := s.item
    if !is_blueprint(it) || s.count <= 0 do return
    if chebyshev(tile, player_tile(&gs.player)) > BENCH_RANGE {
        notify(gs, "The blueprint chest is too far away")
        return
    }

    before := inventory_count(&gs.player.inventory, it)
    barrel_take(gs, b, slot)
    if inventory_count(&gs.player.inventory, it) == before do return

    eq_push(&gs.events, Event{
        type    = .Item_Pickup,
        tile    = tile,
        payload = {int_val = i32(it)},
    })
    log_action(gs, "Player takes %s from permanent chest at (%d,%d)", item_table[it].name, x, y)
}

open_nearby_blueprint_chest :: proc(gs: ^Game_State, cx, cy: int) -> bool {
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            tile := [2]i32{i32(cx + dx), i32(cy + dy)}
            if open_blueprint_chest(gs, tile) do return true
        }
    }
    return false
}

// Current v21 saves may contain the former loose blueprint drops.  Tile enums
// are append-only, so these saves remain layout-compatible; seal those drops
// after loading rather than invalidating an active run.
seal_loose_blueprints :: proc(w: ^World_Grid) {
    for idx in 0 ..< GRID_W * GRID_H {
        it := w.items[idx]
        if !is_blueprint(it) || w.item_counts[idx] == 0 do continue
        x, y := idx % GRID_W, idx / GRID_W
        chest, ok := blueprint_chest_tile(it)
        if !ok do continue
        set_tile(w, x, y, chest)
        w.items[idx]       = .None
        w.item_counts[idx] = 0
    }
}
