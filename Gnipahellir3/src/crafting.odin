package game

// ─── Crafting ─────────────────────────────────────────────────────────────────
//
//  Static recipe table.  Hand recipes (.None) work anywhere; station recipes
//  need their station's tile within BENCH_RANGE of the player.  Stations form
//  a ladder — Bench (iron) → Dvergr Forge (silver/gold) → Rune Altar (sky
//  magic) — but higher stations do not include lower ones.  Crafting flows
//  through events: input pushes Craft_Request (payload = recipe index),
//  handle_craft_request validates, consumes and inserts.

BENCH_RANGE :: 3  // tiles, chebyshev

// Not itself saved (only lives in transient UI_State), but keep it
// append-only anyway: it indexes station_tile/station_title below and
// world.odin's terrain_table keys off individual Tile_Type values that
// mirror this list — reordering would desync those lookups even without
// touching the save format.
Station :: enum u8 {
    None,        // craftable by hand, anywhere
    Bench,
    Forge,
    Rune_Altar,
}

@(rodata)
station_tile := [Station]Tile_Type{
    .None       = .Air,
    .Bench      = .Crafting_Bench,
    .Forge      = .Dvergr_Forge,
    .Rune_Altar = .Rune_Altar,
}


// Window title and interact-prompt name, per station.
@(rodata)
station_title := [Station]cstring{
    .None       = "CRAFTING",
    .Bench      = "CRAFTING BENCH",
    .Forge      = "DVERGR FORGE",
    .Rune_Altar = "RUNE ALTAR",
}

Ingredient :: struct {
    item:  Item,
    count: int,
}

Recipe :: struct {
    result:       Item,
    result_count: int,
    station:      Station,
    ingredients:  [3]Ingredient,   // .None entries are unused
}

// Reveal recipes whose gating material the player now holds (sticky), popping a
// one-shot "New recipe" note.  Step in game_update; reads inventory, pushes no
// events.  Pre-marked (.None) recipes never notify — see game_state_init.
// recipe_unlocked is sized to MAX_ITEM_SLOTS rather than [Item] so that
// appending an item never changes the save layout — these two keep the call
// sites reading in terms of items rather than raw indices.
recipe_revealed :: #force_inline proc(p: ^Progression_State, it: Item) -> bool {
    return p.recipe_unlocked[int(it)]
}

reveal_recipe :: #force_inline proc(p: ^Progression_State, it: Item) {
    p.recipe_unlocked[int(it)] = true
}

update_recipe_unlocks :: proc(gs: ^Game_State) {
    first: Item = .None
    more  := 0
    for r in recipe_table {
        if recipe_revealed(&gs.progression, r.result) do continue
        req := recipe_unlock[r.result]
        if req != .None && inventory_count(&gs.player.inventory, req) == 0 do continue
        reveal_recipe(&gs.progression, r.result)
        if first == .None { first = r.result } else { more += 1 }
    }
    if first != .None {
        if more > 0 {
            notify(gs, "New recipe: %s  (+%d more)", item_table[first].name, more)
        } else {
            notify(gs, "New recipe: %s", item_table[first].name)
        }
    }
}

// One scan of the tiles around the player: which stations are in range.
// .None is always "in range" — hand recipes work anywhere.
stations_in_range :: proc(gs: ^Game_State) -> [Station]bool {
    near: [Station]bool
    near[.None] = true
    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            t := get_tile(&gs.world, cx+dx, cy+dy)
            for st in Station {
                if st != .None && station_tile[st] == t do near[st] = true
            }
        }
    }
    return near
}

player_near_station :: proc(gs: ^Game_State, st: Station) -> bool {
    if st == .None do return true
    return stations_in_range(gs)[st]
}

// The station on a tile, or .None.
station_at_tile :: proc(w: ^World_Grid, tx, ty: i32) -> Station {
    t := get_tile(w, int(tx), int(ty))
    for st in Station {
        if st != .None && station_tile[st] == t do return st
    }
    return .None
}

// Nearest interactable station within BENCH_RANGE of the player — scanned
// ring by ring (chebyshev) so the closest tile wins.  .None when nothing near.
nearest_station :: proc(gs: ^Game_State) -> (st: Station, tile: [2]i32) {
    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)
    for r in 0 ..= BENCH_RANGE {
        for dy in -r ..= r {
            for dx in -r ..= r {
                if max(abs(dx), abs(dy)) != r do continue  // shell of this ring only
                if s := station_at_tile(&gs.world, i32(cx+dx), i32(cy+dy)); s != .None {
                    return s, {i32(cx + dx), i32(cy + dy)}
                }
            }
        }
    }
    return .None, {}
}

// Per-frame station focus: the station the player could interact with right
// now, read by the hover prompt and click handler.
update_station_focus :: proc(gs: ^Game_State) {
    if gs.player.dead {
        gs.ui.focus_station = .None
        return
    }
    gs.ui.focus_station, _ = nearest_station(gs)
}

// Recipes shown in the crafting window: hand recipes plus those of the
// station the window was opened at (ui.active_station; .None = hand only).
// Fills idx_buf with recipe-table indices, returns the count.  Draw and
// cursor hit-test both use this so rows always line up.
visible_recipes :: proc(gs: ^Game_State, idx_buf: ^[len(recipe_table)]int) -> int {
    n := 0
    for r, i in recipe_table {
        if r.station != .None && r.station != gs.ui.active_station do continue
        if !recipe_revealed(&gs.progression, r.result) do continue   // hidden until discovered
        idx_buf[n] = i
        n += 1
    }
    return n
}

recipe_craftable :: proc(gs: ^Game_State, r: ^Recipe) -> bool {
    if !player_near_station(gs, r.station) do return false
    for ing in r.ingredients {
        if ing.item == .None do continue
        if inventory_count(&gs.player.inventory, ing.item) < ing.count do return false
    }
    return true
}

handle_craft_request :: proc(gs: ^Game_State, e: Event) {
    if gs.player.dead do return
    idx := int(e.payload.int_val)
    if idx < 0 || idx >= len(recipe_table) do return
    r := &recipe_table[idx]
    if !recipe_craftable(gs, r) do return

    for ing in r.ingredients {
        if ing.item == .None do continue
        inventory_remove(&gs.player.inventory, ing.item, ing.count)
    }
    // A full bag drops the overflow at the player's feet — nothing is
    // silently lost.  inventory_insert banks whatever fits, so spill only
    // the remainder (count before/after, the barrel_take idiom).
    before := inventory_count(&gs.player.inventory, r.result)
    inventory_insert(&gs.player.inventory, r.result, r.result_count)
    moved := inventory_count(&gs.player.inventory, r.result) - before
    if moved < r.result_count {
        spawn_ground_item(&gs.world, player_tile(&gs.player), r.result, r.result_count - moved)
        notify(gs, "The bag is full - it falls at your feet")
    }
    eq_push(&gs.events, Event{type = .Craft_Complete, payload = {int_val = i32(r.result)}})
    log_action(gs, "Player crafts %v x%d", r.result, r.result_count)
}
