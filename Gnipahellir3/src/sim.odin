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
SMELTER_IN_CAP :: MAX_STACK  // most ore the internal input buffer holds
TREE_GROW_TIME :: f32(20.0)  // seconds per tree
FLOWER_BED_GROW_TIME :: f32(120.0)  // seconds for a bed to bloom (~2 min)
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
    .Flower_Bed  = tick_flower_bed,
    .Silo        = tick_silo,
}

// A planted flower bed ripens over FLOWER_BED_GROW_TIME, then holds until it is
// harvested (walked through, player_pickup).  Progress lives in growth_timer,
// read by render for the growth stages.
tick_flower_bed :: proc(gs: ^Game_State, x, y: int) {
    sd := &gs.world.sim_data[grid_idx(x, y)]
    sd.growth_timer = min(sd.growth_timer + gs.delta_time, FLOWER_BED_GROW_TIME)
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

// The smelting rule for an ore item, if it is smeltable.
smelt_rule_for :: proc(it: Item) -> (Smelt_Rule, bool) {
    for r in smelt_table do if r.ore == it do return r, true
    return {}, false
}

// A smelter runs on an internal ore buffer (sim_data.in_*).  Ore reaches the
// buffer two ways: the player drags it onto the furnace window (smelter_feed),
// OR an ore pile lying on an adjacent cell is auto-pulled in — so a hopper of
// ore beside the fire keeps it fed hands-off (smelter + silo out-chute + ore
// pile still runs on its own).  While the buffer holds a bar's worth of one
// ore and the tray has room, the fire burns; each SMELT_TIME it eats ore and a
// bar lands in the tray (sim_data.store_*) — never on the ground.  No fuel:
// the furnace smelts ore alone.  Progress lives in growth_timer for the glow.
tick_smelter :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)
    sd  := &w.sim_data[idx]

    smelter_autopull(gs, x, y, sd)

    rule, ok := smelt_rule_for(sd.in_item)
    if !ok || int(sd.in_count) < rule.ore_per_bar {
        sd.growth_timer = 0  // nothing loaded, or not yet a full bar's worth
        return
    }

    // A silo next door is an out-chute: bars cast straight into its wide
    // slots, skipping the 99-cap tray.
    out_silo := silo_adjacent(gs, x, y)
    if out_silo != nil && !silo_has_room_for(out_silo, rule.bar) do out_silo = nil

    tray_ok := out_silo != nil ||
               sd.store_count == 0 ||
               (sd.store_item == rule.bar && int(sd.store_count) < MAX_STACK)
    if !tray_ok {
        sd.growth_timer = 0  // the tray is full — the cast has nowhere to land
        return
    }

    sd.growth_timer += gs.delta_time
    if sd.growth_timer < SMELT_TIME do return
    sd.growth_timer = 0

    sd.in_count -= u8(rule.ore_per_bar)
    if sd.in_count == 0 do sd.in_item = .None
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

// Draw ore piles lying on adjacent cells into the internal buffer, so a hopper
// of ore beside the fire feeds it automatically.  Only smeltable ore, only
// when the buffer is empty or already holds that ore with room.
smelter_autopull :: proc(gs: ^Game_State, x, y: int, sd: ^Sim_Tile_Data) {
    if int(sd.in_count) >= SMELTER_IN_CAP do return
    w := &gs.world
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            n  := grid_idx(nx, ny)
            it := w.items[n]
            if w.item_counts[n] == 0 do continue
            if _, ok := smelt_rule_for(it); !ok do continue
            if sd.in_item != .None && sd.in_item != it do continue
            have := sd.in_item == it ? int(sd.in_count) : 0
            take := min(int(w.item_counts[n]), SMELTER_IN_CAP - have)
            if take <= 0 do continue
            sd.in_item  = it
            sd.in_count = u8(have + take)
            w.item_counts[n] -= u8(take)
            if w.item_counts[n] == 0 do w.items[n] = .None
            return  // one pile per tick keeps it cheap
        }
    }
}

// Hand-feeding via the furnace window: the dragged bag stack loads the
// smelter's internal input buffer.  Only smeltable ore is taken, one ore kind
// at a time; a partial move (buffer near full) leaves the rest in the bag.
smelter_feed :: proc(gs: ^Game_State, tile: [2]i32, slot: int) -> bool {
    if gs.player.dead do return false
    if slot < 0 || slot >= MAX_INVENTORY do return false
    if !in_bounds(int(tile.x), int(tile.y)) do return false
    s := &gs.player.inventory.slots[slot]
    if s.item == .None || s.count <= 0 do return false

    if _, ok := smelt_rule_for(s.item); !ok {
        notify(gs, "The furnace takes only ore")
        return false
    }

    px := i32(gs.player.pos.x + PLAYER_W*0.5)
    py := i32(gs.player.pos.y + PLAYER_H*0.5)
    if max(abs(tile.x - px), abs(tile.y - py)) > BENCH_RANGE {
        notify(gs, "Too far from the furnace")
        return false
    }

    sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]
    if sd.in_item != .None && sd.in_item != s.item {
        notify(gs, "The furnace is busy with another ore")
        return false
    }
    have := sd.in_item == s.item ? int(sd.in_count) : 0
    take := min(s.count, SMELTER_IN_CAP - have)
    if take <= 0 {
        notify(gs, "The furnace is full")
        return false
    }
    sd.in_item  = s.item
    sd.in_count = u8(have + take)
    item := s.item
    s.count -= take
    if s.count == 0 do s.item = .None
    audio_play(&gs.audio, .Place)
    log_action(gs, "Player loads %v x%d into smelter at (%d,%d)", item, take, tile.x, tile.y)
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
