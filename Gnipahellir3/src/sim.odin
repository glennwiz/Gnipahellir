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
SMELT_FUEL     :: Item.Wood_Log  // what the fire burns, laid beside it like ore
BARS_PER_LOG   :: 3          // one log's embers fire this many casts
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
    .Silo        = tick_silo,
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

// A smelter feeds on ore stacks lying beside it (drag them onto its window,
// or Q-drop them there) and burns wood laid the same way: while a neighbor
// holds enough smeltable ore, another holds wood, and the tray has room, the
// fire runs; when the timer fills, ore and a log are consumed and the bar
// lands in the tray (sim_data.store_*) — never on the ground.  Progress
// lives in sim_data.growth_timer — render reads it for the fire glow.
tick_smelter :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)
    sd  := &w.sim_data[idx]

    in_idx   := -1
    fuel_idx := -1
    rule: Smelt_Rule
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            n := grid_idx(nx, ny)
            if fuel_idx < 0 && w.items[n] == SMELT_FUEL && w.item_counts[n] > 0 {
                fuel_idx = n
            }
            if in_idx < 0 {
                for r in smelt_table {
                    if w.items[n] == r.ore && int(w.item_counts[n]) >= r.ore_per_bar {
                        in_idx = n
                        rule   = r
                        break
                    }
                }
            }
        }
    }

    // A silo next door is an out-chute: bars cast straight into its wide
    // slots, skipping the 99-cap tray — smelter + silo + ore pile runs
    // hands-off.
    out_silo := silo_adjacent(gs, x, y)
    if out_silo != nil && !silo_has_room_for(out_silo, rule.bar) do out_silo = nil

    tray_ok := out_silo != nil ||
               sd.store_count == 0 ||
               (sd.store_item == rule.bar && int(sd.store_count) < MAX_STACK)
    has_fuel := sd.fuel_charge > 0 || fuel_idx >= 0
    if in_idx < 0 || !has_fuel || !tray_ok {
        sd.growth_timer = 0  // the fire dies without ore, wood, or tray room
        return
    }

    sd.growth_timer += gs.delta_time
    if sd.growth_timer < SMELT_TIME do return
    sd.growth_timer = 0

    w.item_counts[in_idx] -= u8(rule.ore_per_bar)
    if w.item_counts[in_idx] == 0 do w.items[in_idx] = .None
    if sd.fuel_charge == 0 {
        // the embers are spent — eat a log, good for BARS_PER_LOG casts
        w.item_counts[fuel_idx] -= 1
        if w.item_counts[fuel_idx] == 0 do w.items[fuel_idx] = .None
        sd.fuel_charge = BARS_PER_LOG
    }
    sd.fuel_charge -= 1
    if out_silo != nil {
        silo_add(out_silo, rule.bar, 1)
    } else {
        sd.store_item  = rule.bar
        sd.store_count += 1
    }
    spawn_smelt_burst(gs, {i32(x), i32(y)})
    eq_push(&gs.events, Event{
        type    = .Play_Sound,
        tile    = {i32(x), i32(y)},
        payload = {int_val = i32(Sound_ID.Place)},
    })
    log_action(gs, "Smelter at (%d,%d) casts %v into its tray", x, y, rule.bar)
}

// Hand-feeding via the furnace window: the dragged bag stack lands on a cell
// beside the smelter — the same ground stacks tick_smelter eats.  Only
// smeltable ore and wood fuel are taken; a partial move leaves the rest in
// the bag.
smelter_feed :: proc(gs: ^Game_State, tile: [2]i32, slot: int) -> bool {
    if gs.player.dead do return false
    if slot < 0 || slot >= MAX_INVENTORY do return false
    s := &gs.player.inventory.slots[slot]
    if s.item == .None || s.count <= 0 do return false

    smeltable := s.item == SMELT_FUEL
    for r in smelt_table do if r.ore == s.item { smeltable = true; break }
    if !smeltable {
        notify(gs, "The furnace takes only ore and wood")
        return false
    }

    px := i32(gs.player.pos.x + PLAYER_W*0.5)
    py := i32(gs.player.pos.y + PLAYER_H*0.5)
    if max(abs(tile.x - px), abs(tile.y - py)) > BENCH_RANGE {
        notify(gs, "Too far from the furnace")
        return false
    }

    // A matching stack with room wins over an empty open cell.
    w    := &gs.world
    best := -1
    find: for pass in 0 ..< 2 {
        for dy in i32(-1) ..= 1 {
            for dx in i32(-1) ..= 1 {
                if dx == 0 && dy == 0 do continue
                x, y := int(tile.x + dx), int(tile.y + dy)
                if !in_bounds(x, y) do continue
                idx := grid_idx(x, y)
                if .Solid in terrain_table[w.terrain[idx]].flags do continue
                if pass == 0 {
                    if w.items[idx] == s.item && w.item_counts[idx] > 0 &&
                       int(w.item_counts[idx]) < MAX_STACK {
                        best = idx
                        break find
                    }
                } else if w.items[idx] == .None || w.item_counts[idx] == 0 {
                    best = idx
                    break find
                }
            }
        }
    }
    if best < 0 {
        notify(gs, "No room beside the furnace")
        return false
    }

    have := w.items[best] == s.item ? int(w.item_counts[best]) : 0
    take := min(s.count, MAX_STACK - have)
    w.items[best]       = s.item
    w.item_counts[best] = u8(have + take)
    item := s.item
    s.count -= take
    if s.count == 0 do s.item = .None
    audio_play(&gs.audio, .Place)
    log_action(gs, "Player feeds %v x%d to smelter at (%d,%d)", item, take, tile.x, tile.y)
    return true
}

// Emptying the tray into the bag (click it, or drag it onto the inventory).
// Whatever the bag can't hold stays in the tray.
smelter_collect :: proc(gs: ^Game_State, tile: [2]i32) -> bool {
    if gs.player.dead do return false
    if !in_bounds(int(tile.x), int(tile.y)) do return false
    sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]
    if sd.store_count == 0 do return false

    px := i32(gs.player.pos.x + PLAYER_W*0.5)
    py := i32(gs.player.pos.y + PLAYER_H*0.5)
    if max(abs(tile.x - px), abs(tile.y - py)) > BENCH_RANGE {
        notify(gs, "Too far from the furnace")
        return false
    }

    inv    := &gs.player.inventory
    before := inventory_count(inv, sd.store_item)
    fit    := inventory_insert(inv, sd.store_item, int(sd.store_count))
    taken  := inventory_count(inv, sd.store_item) - before
    sd.store_count -= u8(taken)
    item := sd.store_item
    if sd.store_count == 0 do sd.store_item = .None
    if !fit do notify(gs, "The bag is full")
    if taken > 0 {
        audio_play(&gs.audio, .Pickup)
        log_action(gs, "Player takes %v x%d from smelter at (%d,%d)", item, taken, tile.x, tile.y)
    }
    return taken > 0
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
