package game

// ─── Sim: placed machines that run on their own ───────────────────────────────
//
//  Step 5b in game_update.  Table-driven: tile_on_tick maps a Tile_Type to a
//  tick proc; update_sim scans the active grid and advances each ticking
//  tile's timer in sim_data (saved with the world, so progress survives a
//  reload).  Only the active level ticks — machines elsewhere sleep until
//  the player returns.  Runs before process_events so anything a machine
//  emits (sound, Tree_Grew) drains the same frame.

SMELT_TIME       :: f32(3.0)   // seconds per bar
SMELTER_IN_CAP   :: MAX_STACK  // most ore the internal input buffer holds
SMELTER_FUEL_CAP :: MAX_STACK  // most wood the fuel buffer holds
FUEL_PER_BAR     :: 2          // wood logs burned to cast one bar
FUEL_ITEM        :: Item.Wood_Log  // what stokes the fire
TREE_GROW_TIME :: f32(40.0)  // seconds per tree
FLOWER_BED_GROW_TIME :: f32(120.0)  // seconds for a bed to bloom (~2 min)
MUSHROOM_GROW_TIME :: f32(120.0)  // seconds for mossy stone to regrow its mushroom (~2 min)
TREE_MAX_H     :: 5          // tallest grown trunk; clearance is checked to here

// The Gem Replicator only works as deep as gems actually form: caves 2/3 roll
// gems at depth > 60 below CAVE_LVL_TOP (levels.odin), so this is that exact
// row.  Checked at placement — the condition is static per cell, so a refusal
// with a reason beats a machine that silently never ticks.
REPLICATOR_DEPTH_Y :: CAVE_LVL_TOP + 60

// What a smelter eats and what it casts.  New smeltable = new row.
Smelt_Rule :: struct {
    ore, bar:    Item,
    ore_per_bar: int,
}

// ─── The Boiler archetype ─────────────────────────────────────────────────────
//
//  There will be TWO craft tracks — steam and magic — with the same inputs and
//  outputs, differing only in what they burn, what counts as free heat, and
//  what vapour they breathe.  So nothing here is a bespoke Boiler proc: one
//  tick_boiler runs every kettle from a rule row looked up by its own tile.
//  Adding the magic track = adding a row.  No logic changes.

BOILER_FUEL_CAP :: MAX_STACK  // most fuel a kettle's hopper holds

Boiler_Rule :: struct {
    tile:      Tile_Type, // the kettle itself
    source:    Tile_Type, // the fluid it drinks (orthogonally adjacent)
    vapour:    Tile_Type, // the gas it breathes into the open tile above
    heat_tile: Tile_Type, // adjacent cell that makes fuel unnecessary
    fuel_item: Item,      // what stokes it otherwise
    period:    f32,       // seconds per puff
    burn_time: f32,       // seconds one fuel unit lasts
}

@(rodata)
boiler_rules := [?]Boiler_Rule{
    {.Boiler, .Water, .Steam, .Lava, .Wood_Log, 2.0, 8.0},
    // The magic track: no free heat (heat_tile == .Air is the sentinel tick_boiler
    // checks for — see Seam 1 there), and fuel_item == .None means "consult
    // gem_burn_time instead" (Seam 2) rather than a fixed single item. burn_time
    // is unused for this row; the real duration is gem_burn_time[sd.in_item].
    {.Magic_Kettle, .Magic_Lava, .Mana_Mist, .Air, .None, 2.0, 0},
}

boiler_rule_for :: proc(t: Tile_Type) -> (Boiler_Rule, bool) {
    for r in boiler_rules do if r.tile == t do return r, true
    return {}, false
}

// ─── The Engine archetype and power ───────────────────────────────────────────

POWERED_SPEEDUP :: f32(3)  // a powered machine runs this many times faster

Engine_Rule :: struct {
    tile:   Tile_Type, // the engine itself
    vapour: Tile_Type, // what it drinks
    period: f32,       // seconds per vapour cell consumed
    reach:  int,       // chebyshev radius it powers
    linger: f32,       // seconds a stamp survives without fresh vapour
}

@(rodata)
engine_rules := [?]Engine_Rule{
    {.Steam_Engine, .Steam, 1.0, 3, 3.0},
    // Same numbers as steam's engine — capability parity between tracks is
    // the point; powered() consumers never learn which track fed them.
    {.Mana_Wheel, .Mana_Mist, 1.0, 3, 3.0},
}

engine_rule_for :: proc(t: Tile_Type) -> (Engine_Rule, bool) {
    for r in engine_rules do if r.tile == t do return r, true
    return {}, false
}

// Is this cell inside a running engine's field?  THE consumer API: it reads
// one number and deliberately says NOTHING about which craft track powered it
// — that is the whole two-track contract.  A machine that checks a specific
// engine tile instead of calling this has broken the design.
powered :: proc(gs: ^Game_State, x, y: int) -> bool {
    return gs.power.charge[grid_idx(x, y)] > 0
}

// Step 5b0: engine stamps age out unless re-stamped.  The linger is what makes
// consumers independent of grid scan order — a machine ticking before its
// engine still reads last frame's charge.
update_power :: proc(gs: ^Game_State) {
    for &c in gs.power.charge {
        if c > 0 do c = max(0, c - gs.delta_time)
    }
}

// One tick of any engine, driven by its rule row.  Every period it drinks one
// adjacent vapour cell; on success it stamps `linger` seconds of charge on
// every cell within `reach`.  No vapour -> no stamp -> the flywheel coasts
// down and everything it fed falls back to its own fuel.
tick_engine :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)
    sd  := &w.sim_data[idx]
    rule, ok := engine_rule_for(w.terrain[idx])
    if !ok do return

    sd.growth_timer += gs.delta_time
    if sd.growth_timer < rule.period do return
    sd.growth_timer = 0

    vx, vy, found := adjacent_tile_of(w, x, y, rule.vapour)
    if !found do return  // starved — the field decays on its own

    set_tile(w, vx, vy, gravity_open_tile(gs, vy))
    gs.fluid.age[grid_idx(vx, vy)] = 0
    for sy in y - rule.reach ..= y + rule.reach {
        for sx in x - rule.reach ..= x + rule.reach {
            if !in_bounds(sx, sy) do continue
            gs.power.charge[grid_idx(sx, sy)] = rule.linger
        }
    }
}

@(rodata)
tile_on_tick := #partial [Tile_Type]proc(gs: ^Game_State, x, y: int){
    .Smelter     = tick_smelter,
    .Tree_Grower = tick_grower,
    .Flower_Bed  = tick_flower_bed,
    .Silo        = tick_silo,
    .Golem_Depot = tick_golem_depot,
    .Boiler      = tick_boiler,
    .Steam_Engine = tick_engine,
    .Gem_Replicator = tick_gem_replicator,
    .Mossy_Stone = tick_mossy_stone,
    .Magic_Kettle = tick_boiler,
    .Mana_Wheel   = tick_engine,
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

// Wood stokes the furnace: FUEL_PER_BAR logs burn per bar cast.
smelter_is_fuel :: proc(it: Item) -> bool {
    return it == FUEL_ITEM
}

// A smelter runs on two internal buffers: ore (sim_data.in_*) and wood fuel
// (sim_data.fuel_count).  Both reach the furnace two ways: the player drags
// them onto the window (smelter_feed routes by item — ore to input, wood to
// fuel), OR a pile lying on an adjacent cell is auto-pulled in — so a hopper
// of ore on one side and wood on another keeps it fed hands-off (smelter +
// silo out-chute still runs on its own).  While the buffer holds a bar's worth
// of one ore, FUEL_PER_BAR wood waits, and the tray has room, the fire burns;
// each SMELT_TIME it eats ore + wood and a bar lands in the tray
// (sim_data.store_*) — never on the ground.  Progress lives in growth_timer.
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
    // A powered furnace burns no wood and casts POWERED_SPEEDUP times as fast
    // — the reward for a real spring + boiler + engine build.  Deliberately
    // track-agnostic: this proc knows nothing about steam or engines.
    is_powered := powered(gs, x, y)
    if !is_powered && int(sd.fuel_count) < FUEL_PER_BAR {
        sd.growth_timer = 0  // the fire is cold — feed it wood
        return
    }

    // A silo next door is an out-chute: bars cast straight into its wide
    // slots, skipping the 99-cap tray.
    out_silo := silo_adjacent(gs, x, y)
    if out_silo != nil && !silo_has_room_for(out_silo, rule.bar) do out_silo = nil
    out_depot := golem_depot_adjacent(gs, x, y)
    if out_depot != nil && !golem_depot_has_room(out_depot, rule.bar) do out_depot = nil

    tray_ok := out_silo != nil || out_depot != nil ||
               sd.store_count == 0 ||
               (sd.store_item == rule.bar && int(sd.store_count) < MAX_STACK)
    if !tray_ok {
        sd.growth_timer = 0  // the tray is full — the cast has nowhere to land
        return
    }

    smelt_time := is_powered ? SMELT_TIME / POWERED_SPEEDUP : SMELT_TIME
    sd.growth_timer += gs.delta_time
    if sd.growth_timer < smelt_time do return
    sd.growth_timer = 0

    sd.in_count -= u8(rule.ore_per_bar)
    if !is_powered do sd.fuel_count -= u8(FUEL_PER_BAR)
    if sd.in_count == 0 do sd.in_item = .None
    if out_silo != nil {
        silo_add(out_silo, rule.bar, 1)
    } else if out_depot != nil {
        _ = golem_depot_add(out_depot, rule.bar, 1)
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

// Is one of the four orthogonal neighbours this tile?  Used for the boiler's
// drink (source) and its free heat (heat_tile).
adjacent_tile_of :: proc(w: ^World_Grid, x, y: int, t: Tile_Type) -> (int, int, bool) {
    dirs := [4][2]int{{0, 1}, {0, -1}, {-1, 0}, {1, 0}}
    for d in dirs {
        if get_tile(w, x + d[0], y + d[1]) == t do return x + d[0], y + d[1], true
    }
    return 0, 0, false
}

// One tick of any kettle, driven entirely by its Boiler_Rule row.  Per puff it
// drinks one orthogonally adjacent source cell and breathes one vapour cell
// into the open tile above (age 0 — freshly boiled).  Heat is either loaded
// fuel (one unit burns for burn_time, clocked in spread_timer) or a free
// adjacent heat_tile cell.  Blocked above, dry, or cold -> it idles and
// consumes NOTHING — self-regulating exactly the way the spring is, and for
// the same reason: the mouth must be open.
tick_boiler :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)
    sd  := &w.sim_data[idx]
    rule, ok := boiler_rule_for(w.terrain[idx])
    if !ok do return

    // Seam 2: fuel_item == .None means tiered gem fuel (gem_burn_time),
    // tracked in sd.in_item/in_count like the smelter's variable-item ore
    // slot, instead of the fixed-item fuel_count every other boiler row
    // uses. Captured once up front so the vapour this tick breathes (if any)
    // is tinted by whatever gem was observably loaded this frame, even if
    // that gem's last unit burns out later in this same tick.
    tiered     := rule.fuel_item == .None
    tint_gem   := sd.in_item
    if tiered {
        _ = machine_autopull_tiered_fuel(gs, x, y, sd, BOILER_FUEL_CAP)
    } else {
        _ = machine_autopull_fuel(gs, x, y, sd, rule.fuel_item, BOILER_FUEL_CAP)
    }

    if !fluid_open(w, x, y - 1) {
        sd.growth_timer = 0  // capped — nowhere for the puff to go
        return
    }
    sx, sy, found := adjacent_tile_of(w, x, y, rule.source)
    if !found {
        sd.growth_timer = 0  // dry — nothing to boil, so nothing burns
        return
    }

    // Heat: a heat_tile cell against the kettle boils for free; otherwise the
    // burn clock eats loaded fuel, one unit per burn_time. Seam 1: heat_tile
    // == .Air is the "no free-heat tile configured" sentinel — checked
    // before the match, since .Air would otherwise falsely match nearly
    // every open-adjacent kettle and grant free heat always.
    free_heat := false
    if rule.heat_tile != .Air {
        _, _, free_heat = adjacent_tile_of(w, x, y, rule.heat_tile)
    }
    if !free_heat {
        if sd.spread_timer <= 0 {
            if tiered {
                if sd.in_item == .None || sd.in_count == 0 {
                    sd.growth_timer = 0  // the fire is cold — feed it
                    return
                }
                burn_time, _ := gem_burn_time_for(sd.in_item)
                sd.in_count -= 1
                if sd.in_count == 0 do sd.in_item = .None
                sd.spread_timer = burn_time
            } else {
                if sd.fuel_count == 0 {
                    sd.growth_timer = 0  // the fire is cold — feed it
                    return
                }
                sd.fuel_count -= 1
                sd.spread_timer = rule.burn_time
            }
        }
        sd.spread_timer -= gs.delta_time
    }

    sd.growth_timer += gs.delta_time
    if sd.growth_timer < rule.period do return
    sd.growth_timer = 0

    set_tile(w, sx, sy, gravity_open_tile(gs, sy))
    set_tile(w, x, y - 1, rule.vapour)
    gs.fluid.age[grid_idx(x, y - 1)] = 0
    if tiered do gs.fluid.gem_tint[grid_idx(x, y - 1)] = gem_tint_index(tint_gem)
    spawn_smelt_burst(gs, {i32(x), i32(y)})
    eq_push(&gs.events, Event{
        type    = .Play_Sound,
        tile    = {i32(x), i32(y)},
        payload = {int_val = i32(Sound_ID.Place)},
    })
    log_action(gs, "Boiler at (%d,%d) breathes %v", x, y, rule.vapour)
}

// Draw one adjacent pile of `item` into the fuel buffer — the hopper pattern
// shared by every fuel-burning machine (smelter, boilers).  Returns true if it
// pulled: one pile per tick keeps it cheap.
machine_autopull_fuel :: proc(gs: ^Game_State, x, y: int, sd: ^Sim_Tile_Data, item: Item, cap: int) -> bool {
    if int(sd.fuel_count) >= cap do return false
    w := &gs.world
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            n := grid_idx(nx, ny)
            if w.item_counts[n] == 0 || w.items[n] != item do continue
            take := min(int(w.item_counts[n]), cap - int(sd.fuel_count))
            if take <= 0 do continue
            sd.fuel_count += u8(take)
            w.item_counts[n] -= u8(take)
            if w.item_counts[n] == 0 do w.items[n] = .None
            return true
        }
    }
    return false
}

// Draw one adjacent pile of ANY tiered-fuel item (gem_burn_time's nonzero
// rows) into sd.in_item/in_count — the Magic Kettle's fuel slot, styled like
// the smelter's variable-item ore slot rather than the boiler's fixed-item
// fuel_count.  Refuses mixing exactly like the smelter's ore buffer: once a
// gem is loaded, only more of that same gem tops it up until it runs dry.
// Returns true if it pulled: one pile per tick keeps it cheap.
machine_autopull_tiered_fuel :: proc(gs: ^Game_State, x, y: int, sd: ^Sim_Tile_Data, cap: int) -> bool {
    if sd.in_item != .None && int(sd.in_count) >= cap do return false
    w := &gs.world
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            n := grid_idx(nx, ny)
            it := w.items[n]
            if w.item_counts[n] == 0 do continue
            if _, ok := gem_burn_time_for(it); !ok do continue
            if sd.in_item != .None && sd.in_item != it do continue
            have := sd.in_item == it ? int(sd.in_count) : 0
            take := min(int(w.item_counts[n]), cap - have)
            if take <= 0 do continue
            sd.in_item  = it
            sd.in_count = u8(have + take)
            w.item_counts[n] -= u8(take)
            if w.item_counts[n] == 0 do w.items[n] = .None
            return true
        }
    }
    return false
}

// Draw ore and wood piles lying on adjacent cells into the internal buffers,
// so a hopper of ore on one side and wood on another feeds the fire
// automatically.  Ore goes to the input buffer (one kind at a time), wood to
// the fuel buffer; either only when there is room.  One pile per tick.
smelter_autopull :: proc(gs: ^Game_State, x, y: int, sd: ^Sim_Tile_Data) {
    if machine_autopull_fuel(gs, x, y, sd, FUEL_ITEM, SMELTER_FUEL_CAP) do return
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
// smelter — ore into the input buffer (one kind at a time), wood into the fuel
// buffer.  A partial move (buffer near full) leaves the rest in the bag.
smelter_feed :: proc(gs: ^Game_State, tile: [2]i32, slot: int) -> bool {
    if gs.player.dead do return false
    if slot < 0 || slot >= MAX_INVENTORY do return false
    if !in_bounds(int(tile.x), int(tile.y)) do return false
    s := &gs.player.inventory.slots[slot]
    if s.item == .None || s.count <= 0 do return false

    is_fuel     := smelter_is_fuel(s.item)
    _, is_ore   := smelt_rule_for(s.item)
    if !is_ore && !is_fuel {
        notify(gs, "The furnace takes ore to smelt and wood to burn")
        return false
    }

    px := i32(gs.player.pos.x + PLAYER_W*0.5)
    py := i32(gs.player.pos.y + PLAYER_H*0.5)
    if max(abs(tile.x - px), abs(tile.y - py)) > BENCH_RANGE {
        notify(gs, "Too far from the furnace")
        return false
    }

    sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]

    if is_fuel {
        take := min(s.count, SMELTER_FUEL_CAP - int(sd.fuel_count))
        if take <= 0 {
            notify(gs, "The furnace is stocked with fuel")
            return false
        }
        sd.fuel_count += u8(take)
        s.count -= take
        if s.count == 0 do s.item = .None
        audio_play(&gs.audio, .Place)
        log_action(gs, "Player stokes smelter at (%d,%d) with %d wood", tile.x, tile.y, take)
        return true
    }

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

// Pull the loaded ore back out of the furnace into the bag (drag the INPUT
// slot onto the inventory).  Whatever the bag can't hold stays loaded.
smelter_withdraw :: proc(gs: ^Game_State, tile: [2]i32) -> bool {
    if gs.player.dead do return false
    if !in_bounds(int(tile.x), int(tile.y)) do return false
    sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]
    if sd.in_count == 0 do return false

    px := i32(gs.player.pos.x + PLAYER_W*0.5)
    py := i32(gs.player.pos.y + PLAYER_H*0.5)
    if max(abs(tile.x - px), abs(tile.y - py)) > BENCH_RANGE {
        notify(gs, "Too far from the furnace")
        return false
    }

    inv    := &gs.player.inventory
    before := inventory_count(inv, sd.in_item)
    inventory_insert(inv, sd.in_item, int(sd.in_count))
    taken  := inventory_count(inv, sd.in_item) - before
    item   := sd.in_item
    sd.in_count -= u8(taken)
    if sd.in_count == 0 do sd.in_item = .None
    if taken == 0 do notify(gs, "The bag is full")
    if taken > 0 {
        audio_play(&gs.audio, .Pickup)
        log_action(gs, "Player pulls %v x%d back out of smelter at (%d,%d)", item, taken, tile.x, tile.y)
    }
    return taken > 0
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

// A mossy stone block slowly regrows the mushroom it feeds — Tree Grower
// mechanics exactly: the timer (saved in sim_data, so progress survives a
// reload) only runs while the cell above is open, resets when blocked, and
// the sprout is free.  The timer doubles as the VISIBLE growth clock:
// draw_pixel_mossy_stone reads it to raise a mini glowing sprout into the
// cell above, so the whole 2 minutes reads on screen.  This is also what
// makes mushroom farming possible later: any mossy stone that ends up
// somewhere open grows.
tick_mossy_stone :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)

    above := get_tile(w, x, y - 1)
    if above != .Void && above != .Air {
        w.sim_data[idx].growth_timer = 0
        return
    }

    w.sim_data[idx].growth_timer += gs.delta_time
    if w.sim_data[idx].growth_timer < MUSHROOM_GROW_TIME do return
    w.sim_data[idx].growth_timer = 0
    set_tile(w, x, y - 1, .Green_Cave_Mushroom)
    eq_push(&gs.events, Event{type = .Mushroom_Grew, tile = {i32(x), i32(y - 1)}})
}

// ─── The Gem Replicator ───────────────────────────────────────────────────────
//
//  Feed it one gem: the SEED STAYS FOREVER and copies of it slowly grow —
//  Tree Grower parity, never consume-and-double.  This is the gem economy's
//  renewal path: one gem found in nature seeds a farm, so the gem ladder can
//  no longer dead-end and future gem sinks stop being one-shot traps.

// Seconds to grow one copy of each seed — the north star ("the gem you feed a
// machine is the speed you get back") as a table, same shape as
// miner_gem_tier.  A nonzero row is also the "is this a gem" test.  Rarer gem
// = longer wait: the cost mirrors the reward.
@(rodata)
gem_replicate_time := #partial [Item]f32{
    .Emerald = 180,
    .Jade    = 300,
    .Diamond = 600,
    .Hel_Gem = 1200,
}

gem_replicate_time_for :: proc(it: Item) -> (f32, bool) {
    t := gem_replicate_time[it]
    return t, t > 0
}

// Seconds one gem burns in the Magic Kettle — sibling of gem_replicate_time,
// same shape, same "nonzero row is the is-fuel test."  Burn ≈ 2/3 of that
// gem's own replicate period (mana_industry.md §4, decision 7): one farm
// almost feeds one kettle, so a self-sufficient power block always wants
// one more farm or one better gem — the pressure knob, tuned deliberately.
@(rodata)
gem_burn_time := #partial [Item]f32{
    .Emerald = 120,
    .Jade    = 240,
    .Diamond = 480,
    .Hel_Gem = 900,
}

gem_burn_time_for :: proc(it: Item) -> (f32, bool) {
    t := gem_burn_time[it]
    return t, t > 0
}

// A small per-cell index (not the Item itself, to keep Fluid_State.gem_tint
// one byte) recording which gem tinted a Mana Mist cell — 0 means "no gem"
// (render falls back to a neutral color). gem_tint_color (render.odin) turns
// this back into a real color by reading item_table[...].color directly, so
// the tint always matches whatever that gem's color actually is.
gem_tint_order := [4]Item{.Emerald, .Jade, .Diamond, .Hel_Gem}

gem_tint_index :: proc(it: Item) -> u8 {
    for g, i in gem_tint_order do if g == it do return u8(i + 1)
    return 0
}

// Draw ONE gem from an adjacent pile into the empty seed slot — drop a gem
// beside the machine and it takes it, the same drag-to-drop primitive the
// smelter hopper uses (so golems can seed it too).  Seed capacity is 1: a
// whole stack must never vanish into it.
replicator_autopull :: proc(gs: ^Game_State, x, y: int, sd: ^Sim_Tile_Data) {
    if sd.in_count > 0 do return
    w := &gs.world
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            n  := grid_idx(nx, ny)
            it := w.items[n]
            if w.item_counts[n] == 0 do continue
            if _, ok := gem_replicate_time_for(it); !ok do continue
            sd.in_item  = it
            sd.in_count = 1
            w.item_counts[n] -= 1
            if w.item_counts[n] == 0 do w.items[n] = .None
            return  // one pile per tick keeps it cheap
        }
    }
}

// One tick of the gem farm.  While seeded and the output has room, the timer
// climbs toward the seed's own period; on fill one COPY lands silo -> depot
// -> tray in that priority (the smelter's out-chute, verbatim) and the seed
// stays at 1, forever.
tick_gem_replicator :: proc(gs: ^Game_State, x, y: int) {
    w   := &gs.world
    idx := grid_idx(x, y)
    sd  := &w.sim_data[idx]

    replicator_autopull(gs, x, y, sd)

    period, seeded := gem_replicate_time_for(sd.in_item)
    if !seeded || sd.in_count == 0 {
        sd.growth_timer = 0  // no seed — nothing to copy
        return
    }

    out_silo := silo_adjacent(gs, x, y)
    if out_silo != nil && !silo_has_room_for(out_silo, sd.in_item) do out_silo = nil
    out_depot := golem_depot_adjacent(gs, x, y)
    if out_depot != nil && !golem_depot_has_room(out_depot, sd.in_item) do out_depot = nil

    tray_ok := out_silo != nil || out_depot != nil ||
               sd.store_count == 0 ||
               (sd.store_item == sd.in_item && int(sd.store_count) < MAX_STACK)
    if !tray_ok {
        sd.growth_timer = 0  // the tray is full — the copy has nowhere to land
        return
    }

    sd.growth_timer += gs.delta_time
    if sd.growth_timer < period do return
    sd.growth_timer = 0

    // Deposit the copy, never the seed: in_count stays at 1.
    if out_silo != nil {
        silo_add(out_silo, sd.in_item, 1)
    } else if out_depot != nil {
        _ = golem_depot_add(out_depot, sd.in_item, 1)
    } else {
        sd.store_item  = sd.in_item
        sd.store_count += 1
    }
    spawn_smelt_burst(gs, {i32(x), i32(y)})
    eq_push(&gs.events, Event{
        type    = .Play_Sound,
        tile    = {i32(x), i32(y)},
        payload = {int_val = i32(Sound_ID.Place)},
    })
    log_action(gs, "Gem Replicator at (%d,%d) grows a %v", x, y, sd.in_item)
}

// Emptying the replicator's tray into the bag (press E beside it, or let a
// silo next door take the output directly).  Whatever the bag cannot hold
// stays in the tray.
replicator_collect :: proc(gs: ^Game_State, tile: [2]i32) -> bool {
    if gs.player.dead do return false
    if !in_bounds(int(tile.x), int(tile.y)) do return false
    sd := &gs.world.sim_data[grid_idx(int(tile.x), int(tile.y))]
    if sd.store_count == 0 do return false

    px := i32(gs.player.pos.x + PLAYER_W*0.5)
    py := i32(gs.player.pos.y + PLAYER_H*0.5)
    if max(abs(tile.x - px), abs(tile.y - py)) > BENCH_RANGE {
        notify(gs, "Too far from the replicator")
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
        log_action(gs, "Player takes %v x%d from the gem replicator at (%d,%d)", item, taken, tile.x, tile.y)
    }
    return taken > 0
}
