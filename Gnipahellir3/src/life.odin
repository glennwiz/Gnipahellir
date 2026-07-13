package game

// ─── Easter egg: Conway's Game of Life on the world grid ─────────────────────
//
//  F1 debug menu → "Game of Life": every SOLID tile becomes a live cell and
//  the whole scene starts evolving under B3/S23.  Survivors keep their tile
//  identity (ore veins crawl, dens boil); births rise as fresh Stone; deaths
//  open to void (or air above the surface line).  A 5×5 sanctuary around the
//  player stays frozen so you can stand and watch the world seethe.
//
//  Debug-only chaos: toggled from the F1 menu (debug builds), never saved,
//  and it will happily eat portals, stations and blueprints.  That's the fun.

LIFE_TICK :: f32(0.25)  // seconds per generation

update_life :: proc(gs: ^Game_State) {
    if !gs.debug.life do return

    gs.debug.life_timer += gs.delta_time
    if gs.debug.life_timer < LIFE_TICK do return
    gs.debug.life_timer = 0
    gs.debug.life_gen += 1

    w := &gs.world
    alive: [GRID_W * GRID_H]bool
    for i in 0 ..< GRID_W * GRID_H {
        alive[i] = .Solid in terrain_table[w.terrain[i]].flags
    }

    // The player's sanctuary: a frozen 5×5 so the watcher isn't entombed.
    px := int(gs.player.pos.x + PLAYER_W*0.5)
    py := int(gs.player.pos.y + PLAYER_H*0.5)

    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if abs(x - px) <= 2 && abs(y - py) <= 2 do continue

            n := 0
            for dy in -1 ..= 1 {
                for dx in -1 ..= 1 {
                    if dx == 0 && dy == 0 do continue
                    nx, ny := x + dx, y + dy
                    if !in_bounds(nx, ny) do continue  // beyond the edge is dead
                    if alive[grid_idx(nx, ny)] do n += 1
                }
            }

            idx := grid_idx(x, y)
            if alive[idx] {
                if n < 2 || n > 3 {
                    // death: open to air above the surface line, void below
                    fill: Tile_Type = .Void
                    if gs.level_index == LEVEL_SKY ||
                       (gs.level_index == LEVEL_SURFACE && y < SURFACE_Y) {
                        fill = .Air
                    }
                    w.terrain[idx] = fill
                }
                // survival: the tile keeps its identity — veins crawl on
            } else if n == 3 {
                w.terrain[idx] = .Stone  // birth
            }
        }
    }
}
