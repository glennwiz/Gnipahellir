package game

import "core:fmt"

// ─── The grave stone ──────────────────────────────────────────────────────────
//
//  Glenn's permadeath (design review Q1): death is final, but the fallen may
//  send one thing on.  The death screen offers the bag; the next world raises a
//  rune stone by the shaft that names the hero, and a coffer holding the tithe.
//
//  A Grave_Record lives in two places, one at a time.  Between worlds it is
//  gs.stats.grave, in the stats file, because that is the one file death does
//  not burn.  grave_raise moves it into gs.grave, saved with the run it now
//  belongs to, and the tithe moves into an ordinary coffer record.

GRAVE_TEXT         :: 32   // bytes kept of a cause or place name
GRAVE_SHAFT_OFFSET :: 3    // tiles right of the shaft mouth the search for a spot begins
GRAVE_SEARCH       :: 24   // tiles searched to each side of that

Grave_Record :: struct {
    active:  bool,              // holds a fallen hero (stats) / the stone stands (run)
    tithe:   Item,              // .None: the hero sent nothing on
    hero:    int,               // which run this was, counted from the first
    seconds: f32,               // how long the saga lasted
    cause:   [GRAVE_TEXT]u8,    // "lava", NUL-terminated
    place:   [GRAVE_TEXT]u8,    // "Deep Cave", NUL-terminated
    tile:    [2]i32,            // where the stone stands (run only)
}

// Scrolls and keys are the run's own progress, so they cannot be carried out
// of it.  Everything else in the bag may go.
tithe_refused := #partial [Item]bool{
    .Rune_Scroll_A    = true,
    .Rune_Scroll_B    = true,
    .Rune_Scroll_C    = true,
    .Sky_Rune_Scroll  = true,
    .Scroll_Of_Waters = true,
    .Hell_Key         = true,
}

tithe_offerable :: proc(s: Inventory_Slot) -> bool {
    return s.item != .None && s.count > 0 && !tithe_refused[s.item]
}

any_tithe_offerable :: proc(inv: ^Inventory) -> bool {
    for s in inv.slots do if tithe_offerable(s) do return true
    return false
}

// The hero has just died: write them down at once, so the grave survives the
// process being killed on the death screen.
grave_record_death :: proc(gs: ^Game_State) {
    place := level_names[gs.level_index]
    if gs.level_index == LEVEL_DIMENSION do place = dimension_table[gs.dimension.kind].name
    cause := len(gs.death_by) > 0 ? gs.death_by : "something unseen"

    g := Grave_Record{active = true, hero = gs.stats.runs_played, seconds = gs.elapsed_time}
    fmt.bprintf(g.cause[:GRAVE_TEXT - 1], "%s", cause)
    fmt.bprintf(g.place[:GRAVE_TEXT - 1], "%s", place)
    gs.stats.grave = g
}

// The death screen's choice: one of the slot's items goes on.  Choosing again
// replaces it, and choosing the same slot takes it back.
grave_choose_tithe :: proc(gs: ^Game_State, slot: int) {
    if !gs.player.dead || !gs.stats.grave.active do return
    if slot < 0 || slot >= MAX_INVENTORY do return
    s := gs.player.inventory.slots[slot]
    if !tithe_offerable(s) do return
    if gs.ui.tithe_slot == slot {
        gs.ui.tithe_slot = -1
        gs.stats.grave.tithe = .None
    } else {
        gs.ui.tithe_slot = slot
        gs.stats.grave.tithe = s.item
    }
    log_action(gs, "Tithe chosen: %v", gs.stats.grave.tithe)
    _ = save_stats(gs)
}

// The two open cells beside each other, on solid ground, nearest the shaft.
@(private="file")
grave_spot :: proc(w: ^World_Grid) -> (x: int, ok: bool) {
    start := GRID_W/2 + GRAVE_SHAFT_OFFSET
    open :: proc(w: ^World_Grid, x: int) -> bool {
        if !in_bounds(x, SURFACE_Y - 1) || !in_bounds(x, SURFACE_Y) do return false
        idx := grid_idx(x, SURFACE_Y - 1)
        return w.terrain[idx] == .Air && w.items[idx] == .None &&
               .Solid in terrain_table[w.terrain[grid_idx(x, SURFACE_Y)]].flags
    }
    for d in 0 ..< GRAVE_SEARCH {
        for cand in ([2]int{start + d, start - d}) {
            if open(w, cand) && open(w, cand + 1) do return cand, true
        }
    }
    return 0, false
}

// A new world takes the last hero's grave, and the stats file lets go of it.
// The run is saved first: a crash between the two writes leaves the tithe in
// both files, never in neither.  With no room the grave waits for the next
// world.  Call with the player's level on the surface: a new run always is.
grave_raise :: proc(gs: ^Game_State) {
    if !gs.stats.grave.active do return
    x, ok := grave_spot(&gs.world)
    if !ok {
        log_action(gs, "No room for the grave stone")
        return
    }
    g := gs.stats.grave
    g.tile = {i32(x), SURFACE_Y - 1}
    set_tile(&gs.world, x, SURFACE_Y - 1, .Rune_Stone)
    if g.tithe != .None {
        coffer := [2]i32{i32(x + 1), SURFACE_Y - 1}
        set_tile(&gs.world, x + 1, SURFACE_Y - 1, .Rune_Coffer)
        barrel_on_placed(gs, coffer)
        if b := barrel_at(gs, LEVEL_SURFACE, coffer); b != nil do barrel_deposit(b, g.tithe, 1)
    }
    gs.grave = g
    gs.stats.grave = {}
    if len(gs.save_path) > 0 do _ = save_game_to(gs, gs.save_path)
    _ = save_stats(gs)
    log_action(gs, "Grave stone raised at (%d,%d), tithe %v", x, SURFACE_Y - 1, g.tithe)
}

grave_text :: proc(b: ^[GRAVE_TEXT]u8) -> string {
    return string(cstring(raw_data(b[:])))
}

@(private="file")
ordinal_suffix :: proc(n: int) -> string {
    if n % 100 >= 11 && n % 100 <= 13 do return "th"
    switch n % 10 {
    case 1: return "st"
    case 2: return "nd"
    case 3: return "rd"
    }
    return "th"
}

// "Here fell the 7th hero, to lava, in Deep Cave, after 1:40."
grave_inscription :: proc(g: ^Grave_Record, buf: []u8) -> string {
    secs := int(g.seconds)
    return fmt.bprintf(buf, "Here fell the %d%s hero, to %s, in %s, after %d:%02d.",
        g.hero, ordinal_suffix(g.hero), grave_text(&g.cause), grave_text(&g.place),
        secs / 60, secs % 60)
}

// E beside the stone reads it and opens the coffer that stands with it.
grave_interact :: proc(gs: ^Game_State, cx, cy: int) -> bool {
    if !gs.grave.active || gs.level_index != LEVEL_SURFACE do return false
    t := gs.grave.tile
    if abs(int(t.x) - cx) > BENCH_RANGE || abs(int(t.y) - cy) > BENCH_RANGE do return false
    buf: [128]u8
    notify(gs, "%s", grave_inscription(&gs.grave, buf[:]))
    coffer := [2]i32{t.x + 1, t.y}
    if get_tile(&gs.world, int(coffer.x), int(coffer.y)) == .Rune_Coffer {
        eq_push(&gs.events, Event{type = .Barrel_Interact, tile = coffer})
    }
    return true
}
