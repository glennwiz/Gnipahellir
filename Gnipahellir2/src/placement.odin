package gnipahellir

// Unified item placement rules used by highlight, drag-drop, and build mode.

// Returns true if the given item can be placed at tile (tx,ty) in the current world.
can_place_item_at :: proc(game: ^Game_State, id: Item_ID, tx, ty: int) -> bool {
    if !bounds_check(tx, ty) { return false }
    if game.world.entities[tx][ty] != INVALID_ENTITY { return false }
    if !item_is_placeable(id) { return false }

    // Global dependency: Tree_Grower requires at least one Crafting_Bench in the world
    if id == .Tree_Grower && !world_has_terrain(&game.world, .Crafting_Bench) {
        return false
    }

    t_here := game.world.terrain[tx][ty]

    // Helper: require adjacent stone when placing a Smelter into open space
    requires_adjacent_stone := proc(g: ^Game_State, x, y: int) -> bool {
        for dx in -1..=1 { for dy in -1..=1 {
            if dx == 0 && dy == 0 do continue
            nx := x + dx; ny := y + dy
            if bounds_check(nx, ny) && g.world.terrain[nx][ny] == .Stone { return true }
        }}
        return false
    }

    #partial switch t_here {
    case .Air: {
        if id == .Smelter {
            // Smelter in air allowed only with adjacent stone foundation
            return requires_adjacent_stone(game, tx, ty)
        }
        return true
    }
    case .Void: {
        // Underground open space: allow Smelter with adjacent stone only
        if id == .Smelter { return requires_adjacent_stone(game, tx, ty) }
        return true // other placeables can occupy void similar to air
    }
    case .Grass: {
        return id == .Crafting_Bench || id == .Tree_Grower
    }
    case .Stone: {
        // Only Smelter can replace Stone
        return id == .Smelter
    }
    case: {
        // Block all other terrains (Water, Lava, Wood, Leaves, ores, Smelter etc.)
        return false
    }
    }
}

// Applies terrain change for placing an item at (tx,ty). Returns true if placed.
// Does NOT handle inventory consumption; callers should adjust stacks.
place_item_terrain_at :: proc(game: ^Game_State, id: Item_ID, tx, ty: int) -> bool {
    if !can_place_item_at(game, id, tx, ty) { return false }
    terr := item_place_terrain(id)
    if terr == .Air { return false }
    game.world.terrain[tx][ty] = terr
    return true
}


