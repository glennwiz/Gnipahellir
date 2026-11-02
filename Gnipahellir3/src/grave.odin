package game

import "core:fmt"

// ─── The grave stone ──────────────────────────────────────────────────────────
//
//  Glenn's permadeath (design review Q1): death is final, but the fallen may
//  send one thing on.  The death screen offers the bag; the next world raises a
//  rune stone where the hero fell that names them, and a coffer holding the tithe.
//  The next world is a new one, so that is the same level and coordinates, on
//  the nearest open cell.  A cave or the sky does not exist until it is entered:
//  until then the grave is `pending` in gs.grave, and it stands on the way in.
//
//  A Grave_Record lives in two places, one at a time.  Between worlds it is
//  gs.stats.grave, in the stats file, because that is the one file death does
//  not burn.  grave_raise moves it into gs.grave, saved with the run it now
//  belongs to, and the tithe moves into an ordinary coffer record.

GRAVE_TEXT         :: 32   // bytes kept of a cause or place name
GRAVE_SHAFT_OFFSET :: 3    // tiles right of the shaft mouth: where a grave with no tile looks first
GRAVE_SPAWN_CLEAR  :: 4    // tiles a surface grave keeps from where a new player appears

Grave_Record :: struct {
    active:  bool,              // holds a fallen hero (stats) / the stone stands (run)
    tithe:   Item,              // .None: the hero sent nothing on
    pending: bool,              // the run holds it, its level is not generated yet
    hero:    int,               // which run this was, counted from the first
    seconds: f32,               // how long the saga lasted
    cause:   [GRAVE_TEXT]u8,    // "lava", NUL-terminated
    place:   [GRAVE_TEXT]u8,    // "Deep Cave", NUL-terminated
    tile:    [2]i32,            // where the hero fell, then where the stone stands
    level:   i32,               // and on which level.  {0,0}, level 0: by the shaft
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
    // A Dimension does not come back with the next world, so a hero lost there
    // gets the stone by the shaft.  The inscription still says where they fell.
    if gs.level_index != LEVEL_DIMENSION {
        g.level = i32(gs.level_index)
        g.tile  = player_tile(&gs.player)
    }
    gs.stats.grave = g
    kit_collect(gs)
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

// What a grave must not crowd: the way on, and the run's own progress.
@(private="file", rodata)
grave_keep_clear := #partial [Tile_Type]bool{
    .Cave_Entrance         = true,
    .Sky_Altar             = true,
    .Rune_Altar            = true,
    .Sky_Rune_Scroll_Chest = true,
    .Rune_Scroll_Chest_A   = true,
    .Rune_Scroll_Chest_B   = true,
    .Rune_Scroll_Chest_C   = true,
}

// Void is the open air of a cave.
@(private="file")
grave_tile_open :: proc(tile: Tile_Type) -> bool {
    return tile == .Air || tile == .Void
}

// Open air, a head of it, ground under it, no pile, nothing to crowd.
@(private="file")
grave_cell_open :: proc(w: ^World_Grid, level, x, y: int) -> bool {
    if !in_bounds(x, y - 1) || !in_bounds(x, y + 1) do return false
    idx := grid_idx(x, y)
    if !grave_tile_open(w.terrain[idx]) || w.items[idx] != .None do return false
    if !grave_tile_open(w.terrain[grid_idx(x, y - 1)]) do return false
    if .Solid not_in terrain_table[w.terrain[grid_idx(x, y + 1)]].flags do return false
    for dy in -1 ..= 1 do for dx in -1 ..= 1 {
        if !in_bounds(x + dx, y + dy) do continue
        near := grid_idx(x + dx, y + dy)
        if grave_keep_clear[w.terrain[near]] || tithe_refused[w.items[near]] do return false
    }
    if level == LEVEL_SURFACE {
        home := SURFACE_HOME_POS + {PLAYER_W*0.5, PLAYER_H*0.5}
        spawn := [2]i32{i32(home.x), i32(home.y)}
        if chebyshev({i32(x), i32(y)}, spawn) <= GRAVE_SPAWN_CLEAR do return false
    }
    for p in level_portals[level] {
        for t in p.tiles {
            if abs(int(t.x) - x) <= 1 && abs(int(t.y) - y) <= 1 do return false
        }
    }
    return true
}

// The nearest three open cells in a row: stone, coffer, and where the hero rises.
@(private="file")
grave_spot :: proc(w: ^World_Grid, level: int, from: [2]i32) -> (tile: [2]i32, ok: bool) {
    for r in 0 ..< GRID_W {
        for dy in -r ..= r do for dx in -r ..= r {
            if max(abs(dx), abs(dy)) != r do continue  // this ring only
            x, y := int(from.x) + dx, int(from.y) + dy
            if grave_cell_open(w, level, x, y) && grave_cell_open(w, level, x + 1, y) &&
               grave_cell_open(w, level, x + 2, y) {
                return {i32(x), i32(y)}, true
            }
        }
    }
    return {}, false
}

// Stands the stone and coffer in the live world, the level the player is on.
@(private="file")
grave_stand :: proc(gs: ^Game_State, g: ^Grave_Record) -> bool {
    from := g.tile
    if from == {} do from = {GRID_W/2 + GRAVE_SHAFT_OFFSET, SURFACE_Y - 1}
    tile, ok := grave_spot(&gs.world, gs.level_index, from)
    if !ok do return false
    g.tile = tile
    set_tile(&gs.world, int(tile.x), int(tile.y), .Rune_Stone)
    if g.tithe != .None {
        coffer := tile + {1, 0}
        if barrel_slot_free(gs) {
            set_tile(&gs.world, int(coffer.x), int(coffer.y), .Rune_Coffer)
            barrel_on_placed(gs, coffer)
            if b := barrel_at(gs, gs.level_index, coffer); b != nil do barrel_deposit(b, g.tithe, 1)
        } else {
            spawn_ground_item(&gs.world, coffer, g.tithe, 1)
        }
    }
    return true
}

// A new world takes the last hero's grave, and the stats file lets go of it.
// The run is saved first: a crash between the two writes leaves the tithe in
// both files, never in neither.  With no room the grave waits for the next
// world.  Call with the player's level on the surface: a new run always is.
grave_raise :: proc(gs: ^Game_State) {
    if !gs.stats.grave.active do return
    g := gs.stats.grave
    if int(g.level) == gs.level_index {
        if !grave_stand(gs, &g) {
            log_action(gs, "No room for the grave stone")
            return
        }
    } else {
        g.pending = true
    }
    gs.grave = g
    gs.stats.grave = {}
    kit_take_up(gs, g.tithe)
    if RISEN_HERO_WALKS do risen_hero_rise(gs)
    if len(gs.save_path) > 0 do _ = save_game_to(gs, gs.save_path)
    _ = save_stats(gs)
    log_action(gs, "Grave stone for level %d at (%d,%d), tithe %v, pending %v", g.level, g.tile.x, g.tile.y, g.tithe, g.pending)
}

// The level a grave was waiting for exists now.
grave_on_level_enter :: proc(gs: ^Game_State, level: int) {
    if !gs.grave.pending || int(gs.grave.level) != level do return
    if !grave_stand(gs, &gs.grave) {
        log_action(gs, "No room for the grave stone")
        return
    }
    gs.grave.pending = false
    if RISEN_HERO_WALKS do risen_hero_rise(gs)
    gs.save_dirty = true
    log_action(gs, "Grave stone raised at (%d,%d) on level %d", gs.grave.tile.x, gs.grave.tile.y, level)
}

// ─── The risen hero (design review I2, Glenn 2026-11-02) ──────────────────────
//
//  The last hero guards their grave as a draugr with everything they carried
//  but the tithe, and scrolls and keys burn with the run.  Kill them to get it
//  back.  The kit travels with the grave: gs.stats.kit between worlds, then
//  gs.risen, saved with the run, until the body falls and it lands on the ground.
//  They rise beside the coffer when the stone stands, and hold that post until
//  the player comes within RISEN_GUARD_RANGE of the stone.  Their body stays on
//  the grave's level while the player is away.

RISEN_HERO_WALKS  :: true
RISEN_HERO_HP     :: 12
RISEN_GUARD_RANGE :: 12   // tiles from the stone: a modest first guess, Glenn's to feel
RISEN_FIRST_CLAW  :: f32(2)  // seconds after rising before the first claw: a modest guess too
RISEN_KIT         :: MAX_INVENTORY + len(Equip_Slot)

Risen_Hero :: struct {
    has_kit: bool,
    walking: bool,                         // kit is on the body in enemy slot `slot`
    slot:    int,                          // in gs.levels.enemies[gs.grave.level] when away
    kit:     [RISEN_KIT]Inventory_Slot,
}

@(private="file")
kit_collect :: proc(gs: ^Game_State) {
    n := 0
    gs.stats.kit = {}
    for s in gs.player.inventory.slots {
        if tithe_offerable(s) {
            gs.stats.kit[n] = s
            n += 1
        }
    }
    for it in gs.player.equipment {
        s := Inventory_Slot{item = it, count = 1}
        if tithe_offerable(s) {
            gs.stats.kit[n] = s
            n += 1
        }
    }
}

// The kit passes from stats to run, leaving the tithe behind in its coffer.
@(private="file")
kit_take_up :: proc(gs: ^Game_State, tithe: Item) {
    gs.risen = {kit = gs.stats.kit}
    gs.stats.kit = {}
    if tithe != .None {
        for &s in gs.risen.kit {
            if s.item != tithe do continue
            s.count -= 1
            if s.count == 0 do s = {}
            break
        }
    }
    for s in gs.risen.kit do if s.count > 0 do gs.risen.has_kit = true
}

// The last hero claws up beside their stone.  With no stone here, or no free
// enemy slot, they stay in the ground and the attempt changes nothing.
risen_hero_rise :: proc(gs: ^Game_State) -> bool {
    if !gs.risen.has_kit || gs.risen.walking || !gs.grave.active do return false
    if int(gs.grave.level) != gs.level_index do return false
    i, ok := enemy_alloc(&gs.enemies)
    if !ok do return false
    post := risen_hero_post(gs)
    e := &gs.enemies.data[i]
    e.kind   = .Undead
    e.hp     = RISEN_HERO_HP
    e.hp_max = RISEN_HERO_HP
    e.pos    = {f32(post.x) + (1 - BUILDER_W)*0.5, f32(post.y) - BUILDER_H + 1}
    e.builder.goal = .Hunt
    e.builder.attack_timer = RISEN_FIRST_CLAW
    entity_map_move(&gs.world, enemy_entity_id(i), builder_tile(e), builder_tile(e))
    gs.risen.walking = true
    gs.risen.slot    = i
    notify(gs, "The %d%s hero walks again", gs.grave.hero, ordinal_suffix(gs.grave.hero))
    log_action(gs, "Risen hero walks, enemy slot %d", i)
    return true
}

// The cell past the coffer.
risen_hero_post :: proc(gs: ^Game_State) -> [2]i32 {
    return gs.grave.tile + {2, 0}
}

// The hero's slot means this level's store only: the same number elsewhere is
// another body.
risen_hero_here :: proc(gs: ^Game_State, i: int) -> bool {
    return gs.risen.walking && int(gs.grave.level) == gs.level_index && i == gs.risen.slot
}

// Called as enemy slot i leaves the pool, however it left: the kit lands where
// the body stood.
risen_hero_on_despawn :: proc(gs: ^Game_State, i: int, tile: [2]i32) {
    if !risen_hero_here(gs, i) do return
    for s in gs.risen.kit {
        if s.count > 0 do spawn_ground_item(&gs.world, tile, s.item, s.count)
    }
    gs.risen = {}
    notify(gs, "The hero falls - what they carried is yours")
    log_action(gs, "Risen hero falls at (%d,%d)", tile.x, tile.y)
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
grave_interact :: proc(gs: ^Game_State, cx, cy: int) {
    if !gs.grave.active || int(gs.grave.level) != gs.level_index do return
    t := gs.grave.tile
    if abs(int(t.x) - cx) > BENCH_RANGE || abs(int(t.y) - cy) > BENCH_RANGE do return
    buf: [128]u8
    notify(gs, "%s", grave_inscription(&gs.grave, buf[:]))
    coffer := [2]i32{t.x + 1, t.y}
    if get_tile(&gs.world, int(coffer.x), int(coffer.y)) == .Rune_Coffer {
        eq_push(&gs.events, Event{type = .Barrel_Interact, tile = coffer})
    }
}
