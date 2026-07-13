package game

// ─── Sim: placed machines that run on their own ───────────────────────────────
//
//  Step 5b in game_update.  Table-driven: tile_on_tick maps a Tile_Type to a
//  tick proc; update_sim scans the active grid and advances each ticking
//  tile's timer in sim_data (saved with the world, so progress survives a
//  reload).  Only the active level ticks — machines elsewhere sleep until
//  the player returns.  Runs before process_events so anything a machine
//  emits (sound, Tree_Grew) drains the same frame.

SMELT_TIME     :: f32(3.0)   // seconds per bar
TREE_GROW_TIME :: f32(20.0)  // seconds per tree
TREE_MAX_H     :: 5          // tallest grown trunk; clearance is checked to here

// What a smelter eats and what it casts.  New smeltable = new row.
Smelt_Rule :: struct {
    ore, bar:    Item,
    ore_per_bar: int,
}

@(rodata)
smelt_table := [?]Smelt_Rule{
    { .Iron_Ore,      .Iron_Bar,   2 },
    { .Silver_Ore,    .Silver_Bar, 2 },
    { .Gold_Ore,      .Gold_Bar,   2 },
    { .Gold_Rare_Ore, .Gold_Bar,   1 },  // rare ore is rich: one is enough
}

@(rodata)
tile_on_tick := #partial [Tile_Type]proc(gs: ^Game_State, x, y: int){
    .Smelter     = tick_smelter,
    .Tree_Grower = tick_grower,
}

update_sim :: proc(gs: ^Game_State) {
    for y in 0 ..< GRID_H {
        for x in 0 ..< GRID_W {
            if tick := tile_on_tick[gs.world.terrain[grid_idx(x, y)]]; tick != nil {
                tick(gs, x, y)
            }
        }
    }
}

// A smelter feeds on ore stacks lying beside it (Q-drop them there): while a
// neighbor cell holds enough of a smeltable ore, the fire runs; when the
// timer fills, the ore is consumed and a bar lands by the furnace.  Progress
// lives in sim_data.growth_timer — render reads it for the fire glow.
tick_smelter :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)

    in_idx := -1
    rule: Smelt_Rule
    scan: for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            n := grid_idx(nx, ny)
            for r in smelt_table {
                if w.items[n] == r.ore && int(w.item_counts[n]) >= r.ore_per_bar {
                    in_idx = n
                    rule   = r
                    break scan
                }
            }
        }
    }

    if in_idx < 0 {
        w.sim_data[idx].growth_timer = 0  // the fire dies without ore
        return
    }

    w.sim_data[idx].growth_timer += gs.delta_time
    if w.sim_data[idx].growth_timer < SMELT_TIME do return
    w.sim_data[idx].growth_timer = 0

    w.item_counts[in_idx] -= u8(rule.ore_per_bar)
    if w.item_counts[in_idx] == 0 do w.items[in_idx] = .None
    spawn_ground_item(w, {i32(x), i32(y)}, rule.bar, 1)
    spawn_smelt_burst(gs, {i32(x), i32(y)})
    eq_push(&gs.events, Event{
        type    = .Play_Sound,
        tile    = {i32(x), i32(y)},
        payload = {int_val = i32(Sound_ID.Place)},
    })
    log_action(gs, "Smelter at (%d,%d) casts %v", x, y, rule.bar)
}

// A grower nurses a sapling: while the column above is open sky, growth runs;
// when the timer fills a tree stands on top (trees need sky — .Air only, so
// growers are surface machines).  A standing trunk pauses the grower until
// it is harvested.  Progress is read by render for the sprout shimmer.
tick_grower :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)

    for h in 1 ..= TREE_MAX_H {
        if get_tile(w, x, y - h) != .Air {
            w.sim_data[idx].growth_timer = 0
            return
        }
    }

    w.sim_data[idx].growth_timer += gs.delta_time
    if w.sim_data[idx].growth_timer < TREE_GROW_TIME do return
    w.sim_data[idx].growth_timer = 0

    height := 3 + int(whash(u32(idx)*31 + u32(gs.frame)) % 3)
    place_tree(w, x, y, height)
    eq_push(&gs.events, Event{type = .Tree_Grew, tile = {i32(x), i32(y)}})
}
