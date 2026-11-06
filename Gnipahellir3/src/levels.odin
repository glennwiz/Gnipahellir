package game

import "core:fmt"
import "core:slice"
import "core:strings"

// ─── Levels ───────────────────────────────────────────────────────────────────
//
//  Level 0: surface + cave 1 in one grid (world_init).  Level 1: cave 2.
//  Level 2: cave 3.  Level 3: low sky.  Only the active level lives in
//  gs.world/gs.enemies; the rest are stashed in Level_Store and frozen.
//  World gen is deterministic, so portal coordinates are compile-time
//  constants; portal chambers are carved explicitly during generation.

LEVEL_SURFACE   :: 0
LEVEL_CAVE2     :: 1
LEVEL_CAVE3     :: 2
LEVEL_SKY       :: 3
LEVEL_DIMENSION :: 4   // ephemeral spawner world; regenerated per entry (dimensions.odin)
NUM_LEVELS      :: 5

@(rodata)
level_names := [NUM_LEVELS]string{"Surface", "Deep Cave", "Gnipahellir", "Low Sky", "Dimension"}

Level_Store :: struct {
    worlds:    [NUM_LEVELS]World_Grid,
    enemies:   [NUM_LEVELS]Enemy_Store,
    generated: [NUM_LEVELS]bool,
}

Portal :: struct {
    tiles:      [2][2]i32,   // two tiles wide; {0,0} pair = unused slot
    dest_level: int,
    dest_pos:   [2]f32,      // player position in the destination level
    gate_tier:  int,         // -1 = open, else requires progression.cave_unlocked[tier]
}

MAX_LEVEL_PORTALS :: 2

// The cave spawn/return chamber (gen_cave_level) sits mid-map instead of the
// top-left corner, so a fresh descent doesn't dump the player at the map edge.
CAVE_GATE_TILES :: [2][2]i32{{93, 26}, {94, 26}}
CAVE_SPAWN_POS  :: [2]f32{95, 27 - PLAYER_H}

@(rodata)
level_portals := [NUM_LEVELS][MAX_LEVEL_PORTALS]Portal{
    LEVEL_SURFACE = {
        // Deep in cave 1 → cave 2 (locked behind sky structure A)
        { {{143, 94}, {144, 94}},  LEVEL_CAVE2,   CAVE_SPAWN_POS,        0 },
        {},  // the sky gate is dynamic now — raised by a surface Sky Altar (sky_gate_portal)
    },
    LEVEL_CAVE2 = {
        // Spawn chamber → back to cave 1's portal chamber
        { CAVE_GATE_TILES,         LEVEL_SURFACE, {143, 95 - PLAYER_H}, -1 },
        // Bottom-right → cave 3 (locked behind sky structure B)
        { {{180, 102}, {181, 102}}, LEVEL_CAVE3,  CAVE_SPAWN_POS,        1 },
    },
    LEVEL_CAVE3 = {
        // Spawn chamber → back to cave 2's deep portal chamber
        { CAVE_GATE_TILES,         LEVEL_CAVE2,   {178, 103 - PLAYER_H}, -1 },
        {},
    },
    LEVEL_SKY = {
        // Base platform → back to the surface next to the sky gate
        { {{95, 79}, {96, 79}},    LEVEL_SURFACE, {6, 53 - PLAYER_H},   -1 },
        {},
    },
}

portal_valid :: proc(p: ^Portal) -> bool {
    return p.tiles[0] != {0, 0}
}

// Debug cheat: open every gated portal on the current level.
debug_unlock_level_portals :: proc(gs: ^Game_State) {
    for &p in level_portals[gs.level_index] {
        if portal_valid(&p) && p.gate_tier >= 0 {
            gs.progression.cave_unlocked[p.gate_tier] = true
        }
    }
    notify(gs, "Debug: portals on this level activated")
}

// Portal the player is currently standing in, or nil.
portal_at_player :: proc(gs: ^Game_State) -> ^Portal {
    pc := [2]i32{
        i32(gs.player.pos.x + PLAYER_W*0.5),
        i32(gs.player.pos.y + PLAYER_H*0.5),
    }
    for &p in level_portals[gs.level_index] {
        if !portal_valid(&p) do continue
        if pc == p.tiles[0] || pc == p.tiles[1] do return &p
    }
    return nil
}

// ─── Transition ───────────────────────────────────────────────────────────────

level_transition :: proc(gs: ^Game_State, portal: ^Portal) {
    // Remove the player's entity-map marker from the level we are leaving
    entity_map_clear(&gs.world, PLAYER_ID, player_tile(&gs.player))

    ls := &gs.levels
    ls.worlds[gs.level_index]  = gs.world
    ls.enemies[gs.level_index] = gs.enemies
    gs.enemy_status = {}

    dest := portal.dest_level
    if ls.generated[dest] {
        gs.world   = ls.worlds[dest]
        gs.enemies = ls.enemies[dest]
    } else {
        gs.enemies = {}
        switch dest {
        case LEVEL_CAVE2:
            gen_cave_level(&gs.world, 1, gs.world_seed)
            spawn_builder(gs, 40)
            spawn_builder(gs, GRID_W - 40)
            spawn_builder(gs, GRID_W / 2)
        case LEVEL_CAVE3:
            gen_cave_level(&gs.world, 2, gs.world_seed)
            spawn_builder(gs, 40)
            spawn_builder(gs, GRID_W - 40)
            spawn_builder(gs, GRID_W / 2)
        case LEVEL_SKY:
            gen_sky_level(&gs.world, gs.world_seed)
        case LEVEL_DIMENSION:
            gen_dimension(&gs.world, gs.dimension.kind, gs.dimension.seed)
        }
        ls.generated[dest] = true
    }

    dest_pos := portal.dest_pos
    // The way home from the sky is wherever the altar that raised the gate
    // stands — the table's left-edge dest is only the no-altar fallback.
    if gs.level_index == LEVEL_SKY && dest == LEVEL_SURFACE &&
       gs.progression.sky_altar_pos != {0, 0} {
        ap := gs.progression.sky_altar_pos
        dest_pos = {f32(ap.x), f32(ap.y) - PLAYER_H}
    }

    gs.level_index = dest
    golem_sweep_orphan_quick_clay(gs) // clear any Quick Clay left orphaned by a save/load while this level was stashed
    golem_transfer_forget_all(gs)     // sources a worker gave up on are this visit's, not the next one's
    gs.player.pos  = dest_pos
    gs.player.vel  = {}
    camera_snap_y(gs)  // cut the view to the new spot, don't slide across levels
    // Entering mid-jump must not carry the old level's fall peak: the
    // drop would be measured across worlds and land as phantom damage.
    gs.player.fall_peak_y = dest_pos.y
    eq_push(&gs.events, Event{type = .Level_Enter, payload = {int_val = i32(dest)}})
    log_action(gs, "Player enters level %d (%s)", dest, level_names[dest])
}

// ─── Interaction (E key): portals, then the sky altar ritual ──────────────────

// The sky gate a surface altar raises: travel surface → the low sky.
sky_gate_portal :: proc(gs: ^Game_State) -> Portal {
    return Portal{
        tiles      = {gs.progression.sky_altar_pos, gs.progression.sky_altar_pos},
        dest_level = LEVEL_SKY,
        dest_pos   = {95, 80 - PLAYER_H},
        gate_tier  = -1,
    }
}

// The gate was raised and its altar is gone: smashed or reclaimed.  Only the
// surface can tell, because the altar stands there.
sky_gate_down :: proc(gs: ^Game_State) -> bool {
    ap := gs.progression.sky_altar_pos
    return gs.level_index == LEVEL_SURFACE && ap != {0, 0} &&
           get_tile(&gs.world, int(ap.x), int(ap.y)) != .Sky_Altar
}

player_interact :: proc(gs: ^Game_State) {
    if portal := portal_at_player(gs); portal != nil {
        if portal.gate_tier >= 0 && !gs.progression.cave_unlocked[portal.gate_tier] {
            eq_push(&gs.events, Event{type = .Level_Locked, payload = {int_val = i32(portal.gate_tier)}})
            log_action(gs, "Portal locked (tier %d)", portal.gate_tier)
            return
        }
        level_transition(gs, portal)
        return
    }

    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)

    // Rune Scroll coffers get first claim on the broad interaction key: they are
    // permanent progression finds, not mineable storage furniture.
    if open_nearby_rune_scroll_chest(gs, cx, cy) do return

    // Standing in a dimension's return gate: step back home.
    if gs.level_index == LEVEL_DIMENSION && get_tile(&gs.world, cx, cy) == .Dimension_Gate {
        dimension_exit(gs)
        return
    }

    // The Final Seal, deep in Hell: the run's last door.  Breaking it with
    // the Hell Key is the win — the door outranks every other interaction.
    if gs.level_index == LEVEL_DIMENSION && gs.dimension.kind == .Hell {
        for dy in -BENCH_RANGE ..= BENCH_RANGE {
            for dx in -BENCH_RANGE ..= BENCH_RANGE {
                if get_tile(&gs.world, cx+dx, cy+dy) == .Final_Seal {
                    if inventory_count(&gs.player.inventory, .Hell_Key) == 0 {
                        notify(gs, "The seal ignores you - it answers only the Hell Key")
                        return
                    }
                    if !gs.ritual.active do start_seal_ceremony(gs, {i32(cx + dx), i32(cy + dy)})
                    return
                }
            }
        }
    }

    // A Sky_Altar tile near the player: in the sky it runs the ritual; on the
    // surface it's the gate the player raised — step through to the heavens.
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            if get_tile(&gs.world, cx+dx, cy+dy) == .Sky_Altar {
                if gs.level_index == LEVEL_SURFACE && gs.progression.sky_altar_pos != {0, 0} {
                    p := sky_gate_portal(gs)
                    level_transition(gs, &p)
                } else {
                    eq_push(&gs.events, Event{type = .Ritual_Request})
                }
                return
            }
        }
    }

    // A Dimension Spawner in reach: step into its world.  Spawners are inert
    // inside a dimension — no worlds within worlds.
    if gs.level_index != LEVEL_DIMENSION {
        for dy in -BENCH_RANGE ..= BENCH_RANGE {
            for dx in -BENCH_RANGE ..= BENCH_RANGE {
                t := get_tile(&gs.world, cx+dx, cy+dy)
                for kind in Dimension_Kind {
                    if dimension_spawner_tile[kind] == t {
                        // Hell opens only to Garm's key — the gate is a lock,
                        // not a doorway.
                        if kind == .Hell && inventory_count(&gs.player.inventory, .Hell_Key) == 0 {
                            notify(gs, "The gate is shut - only the Hell Key turns it")
                            return
                        }
                        dimension_enter(gs, {i32(cx + dx), i32(cy + dy)}, kind)
                        return
                    }
                }
            }
        }
    }

    // The Auto-Miner's base in reach: claim the haul.
    if gs.level_index == LEVEL_DIMENSION && gs.dimension.miner.active {
        b := gs.dimension.miner.base
        if max(abs(b.x - i32(cx)), abs(b.y - i32(cy))) <= BENCH_RANGE {
            miner_withdraw(gs)
            return
        }
    }

    // A Silo in reach: pour the hoard into the bag.
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            if get_tile(&gs.world, cx+dx, cy+dy) == .Silo {
                if s := silo_at(gs, gs.level_index, {i32(cx + dx), i32(cy + dy)}); s != nil {
                    silo_withdraw(gs, s)
                    return
                }
            }
        }
    }

    // A crafting station in reach opens its crafting window.
    if st, _ := nearest_station(gs); st != .None {
        eq_push(&gs.events, Event{type = .Station_Interact, payload = {int_val = i32(st)}})
        return
    }

    // Otherwise a smelter in reach opens the furnace window.
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            if get_tile(&gs.world, cx+dx, cy+dy) == .Smelter {
                eq_push(&gs.events, Event{
                    type = .Smelter_Interact,
                    tile = {i32(cx + dx), i32(cy + dy)},
                })
                return
            }
        }
    }

    // Last: the grave takes only an E nothing else claimed, because it stands
    // near home, where players build.
    grave_interact(gs, cx, cy)
}

// ─── Sky Structure Ritual ─────────────────────────────────────────────────────
//
//  One cost per progression tier.  v1.0 has a single sky level, so tier 1
//  mixes sky and cave-2 materials instead of the cut sky -2 level's ore.

@(rodata)
structure_costs := [MAX_PROGRESSION_TIERS][2]Ingredient{
    { {.Cloud_Stone, 8},  {.Plank, 4}      },   // A → unlocks cave 2
    { {.Cloud_Stone, 12}, {.Silver_Bar, 6} },   // B → unlocks cave 3
    { {.Cloud_Stone, 20}, {.Gold_Bar, 10}  },   // final → boss gate (Phase 5)
}

// The tier the rune scroll overlay speaks to: the first rune scroll found whose
// sky structure isn't raised yet.  -1 = the player carries no active rune scroll.
rune_scroll_active_tier :: proc(gs: ^Game_State) -> int {
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if gs.progression.rune_scroll_found[t] && !gs.progression.sky_structure_complete[t] {
            return t
        }
    }
    return -1
}

// Which cave a tier's ritual unlocks — for the rune scroll overlay text.
rune_scroll_unlocks_name :: proc(tier: int) -> string {
    switch tier {
    case 0:  return level_names[LEVEL_CAVE2]
    case 1:  return level_names[LEVEL_CAVE3]
    case:    return "the final depths"
    }
}

// Each tier's rune scroll item and where it rests — for the locked-gate toast
// and the HUD objective line.
@(rodata)
tier_rune_scrolls := [MAX_PROGRESSION_TIERS]Item{.Rune_Scroll_A, .Rune_Scroll_B, .Rune_Scroll_C}

@(rodata)
rune_scroll_places := [MAX_PROGRESSION_TIERS]string{
    "deep beneath the Surface",
    "in the Deep Cave",
    "in Gnipahellir",
}

// The level each tier's rune scroll chest lies on, for the objective's hints.
@(rodata)
rune_scroll_levels := [MAX_PROGRESSION_TIERS]int{LEVEL_SURFACE, LEVEL_CAVE2, LEVEL_CAVE3}

// The objective's compass hint (card 165): within OBJECTIVE_NEAR tiles a way
// reads as nothing, past OBJECTIVE_FAR as "far".  First guesses, Glenn's call.
OBJECTIVE_NEAR :: 4
OBJECTIVE_FAR  :: 30

// Raising the Sky Altar reveals Rune Scroll A in the sealed portal chamber
// (carved by carve_level0_portals) — one goal at a time for new players.
// Idempotent: no respawn once found or while it already lies anywhere.  A tile
// or pile on its cell moves the chest to the nearest clear one with footing,
// because nothing else would ever raise it.
spawn_deep_rune_scroll :: proc(gs: ^Game_State) {
    if gs.progression.rune_scroll_found[0] do return
    for t in gs.world.terrain do if t == .Rune_Scroll_Chest_A do return
    for r in 0 ..< GRID_W {
        for dy in -r ..= r do for dx in -r ..= r {
            if !is_solid(&gs.world, 141 + dx, 95 + dy) do continue  // never in mid-air
            if place_rune_scroll_chest(&gs.world, 141 + dx, 94 + dy, .Rune_Scroll_A) {
                notify(gs, "Something stirs deep below - seek the sealed chamber")
                return
            }
        }
    }
}

// Does a Crafting Bench stand on any level?  No flag holds this across a
// save, so the tiles answer; only the opening objectives ask, until the altar.
bench_placed :: proc(gs: ^Game_State) -> bool {
    for t in gs.world.terrain {
        if t == .Crafting_Bench do return true
    }
    for i in 0 ..< NUM_LEVELS {
        if i == gs.level_index do continue
        for t in gs.levels.worlds[i].terrain {
            if t == .Crafting_Bench do return true
        }
    }
    return false
}

// A compass hint from the player to a tile on its level: up or down, east or
// west, never the tile itself.  "close by" within OBJECTIVE_NEAR both ways.
objective_hint :: proc(gs: ^Game_State, to: [2]i32, buf: []u8) -> string {
    d := to - player_tile(&gs.player)
    far :: proc(n: i32) -> string { return "far " if abs(n) > OBJECTIVE_FAR else "" }
    up := ""
    if d.y > OBJECTIVE_NEAR do up = "below"
    if d.y < -OBJECTIVE_NEAR do up = "above"
    across := ""
    if d.x > OBJECTIVE_NEAR do across = "east"
    if d.x < -OBJECTIVE_NEAR do across = "west"
    switch {
    case up != "" && across != "": return fmt.bprintf(buf, "%s%s, %sto the %s", far(d.y), up, far(d.x), across)
    case up != "":                 return fmt.bprintf(buf, "%s%s", far(d.y), up)
    case across != "":             return fmt.bprintf(buf, "%sto the %s", far(d.x), across)
    }
    return "close by"
}

// The first tile of a kind on the current level.
objective_find :: proc(gs: ^Game_State, t: Tile_Type) -> (at: [2]i32, ok: bool) {
    for tt, i in gs.world.terrain do if tt == t do return {i32(i % GRID_W), i32(i / GRID_W)}, true
    return
}

// The gate on the current level toward `level`: the one straight there, else
// the level's first (slot 0).  The levels are a chain (sky, surface, cave 2,
// cave 3) and only cave 2 has two gates, one to each neighbour, so slot 0 is
// the way whenever none goes straight there.  The dimension has none: no hint.
objective_gate :: proc(gs: ^Game_State, level: int) -> (at: [2]i32, ok: bool) {
    for &pt in level_portals[gs.level_index] do if portal_valid(&pt) && pt.dest_level == level do return pt.tiles[0], true
    first := &level_portals[gs.level_index][0]
    return first.tiles[0], portal_valid(first)
}

// The HUD objective line: the first incomplete step of the progression loop,
// so a new player always knows the next move.  Pure read; formats into the
// caller's buffer.  Empty = nothing to show (game won).
current_objective :: proc(gs: ^Game_State, buf: []u8) -> string {
    if gs.game_won do return ""
    p := &gs.progression
    if p.final_boss_defeated {
        return fmt.bprintf(buf, "GARM is slain - take his key through the gate, break the Final Seal")
    }

    tier := -1
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if !p.sky_structure_complete[t] {
            tier = t
            break
        }
    }
    if tier < 0 {
        return fmt.bprintf(buf, "All rituals done - face GARM in %s", level_names[LEVEL_CAVE3])
    }
    if p.sky_altar_pos == {0, 0} {
        if !bench_placed(gs) {
            inv := &gs.player.inventory
            switch {
            case inventory_count(inv, .Crafting_Bench) > 0:
                return fmt.bprintf(buf, "Place your Crafting Bench")
            // Stone once held means the pick was found, even if it was dropped.
            case inventory_count(inv, .Pickaxe) == 0 && !recipe_revealed(p, .Sky_Altar):
                return fmt.bprintf(buf, "Find the pickaxe on the ledge down the shaft")
            case inventory_count(inv, .Wood_Log) == 0 && inventory_count(inv, .Plank) < 4:
                return fmt.bprintf(buf, "Chop a tree for wood")
            case:
                return fmt.bprintf(buf, "Press [%v]: turn logs into planks, planks into a Crafting Bench",
                    gs.bindings[.Inventory])
            }
        }
        return fmt.bprintf(buf, "Raise a Sky Altar on the Surface to open the way above")
    }
    if sky_gate_down(gs) {
        return fmt.bprintf(buf, "The Sky Altar is down - raise it again on a %s foundation",
            structure_templates[0].name)
    }
    hint: [48]u8
    if !p.rune_scroll_found[tier] {
        scroll := tier_rune_scrolls[tier]
        name := item_table[scroll].name
        chest, _ := rune_scroll_chest_tile(scroll)
        // Its chest open in front of the player: the scroll is dragged out.
        if gs.ui.show_barrel && get_tile(&gs.world, int(gs.ui.barrel_tile.x), int(gs.ui.barrel_tile.y)) == chest {
            return fmt.bprintf(buf, "Drag %s out of the chest into your bag", name)
        }
        if gs.level_index == rune_scroll_levels[tier] {
            if at, ok := objective_find(gs, chest); ok {
                return fmt.bprintf(buf, "Find %s in its sealed chest - %s", name, objective_hint(gs, at, hint[:]))
            }
        } else if at, ok := objective_gate(gs, rune_scroll_levels[tier]); ok {
            return fmt.bprintf(buf, "Find %s %s - through the %s %s", name, rune_scroll_places[tier],
                terrain_table[get_tile(&gs.world, int(at.x), int(at.y))].name, objective_hint(gs, at, hint[:]))
        }
        return fmt.bprintf(buf, "Find %s %s", name, rune_scroll_places[tier])
    }
    c := structure_costs[tier]
    // The ritual answers only at a Sky Altar in the sky, and the sky has none
    // until the player raises one on the tier's foundation.
    if gs.level_index == LEVEL_SKY {
        if at, ok := objective_find(gs, .Sky_Altar); ok {
            return fmt.bprintf(buf, "Sky ritual: %d %s + %d %s - [%v] at the Sky Altar, %s",
                c[0].count, item_table[c[0].item].name, c[1].count, item_table[c[1].item].name,
                gs.bindings[.Interact], objective_hint(gs, at, hint[:]))
        }
        tpl := structure_template_for(gs, .Sky_Altar)
        return fmt.bprintf(buf, "Build a %s here: a Sky Altar on %s", tpl.name, objective_template_parts(tpl, hint[:]))
    }
    if slice.contains(gs.levels.worlds[LEVEL_SKY].terrain[:], Tile_Type.Sky_Altar) {
        return fmt.bprintf(buf, "Sky ritual: %d %s + %d %s - [%v] at the altar in the %s",
            c[0].count, item_table[c[0].item].name,
            c[1].count, item_table[c[1].item].name,
            gs.bindings[.Interact], level_names[LEVEL_SKY])
    }
    return fmt.bprintf(buf, "Sky ritual: %d %s + %d %s - build a %s in the %s, [%v] at it",
        c[0].count, item_table[c[0].item].name, c[1].count, item_table[c[1].item].name,
        structure_templates[tier].name, level_names[LEVEL_SKY], gs.bindings[.Interact])
}

// A foundation's support blocks by kind, top row first: "3 Wood, 5 Stone".
objective_template_parts :: proc(tpl: ^Structure_Template, buf: []u8) -> string {
    kinds: [8]Tile_Type
    counts: [8]int
    n := 0
    for line in tpl.rows do for glyph in line {
        tile, kind := structure_template_cell(glyph)
        if kind != .Support do continue
        k := 0
        for k < n && kinds[k] != tile do k += 1
        if k == n do kinds[k], n = tile, n + 1
        counts[k] += 1
    }
    b := strings.builder_from_bytes(buf)
    for k in 0 ..< n {
        if k > 0 do strings.write_string(&b, ", ")
        fmt.sbprintf(&b, "%d %s", counts[k], terrain_table[kinds[k]].name)
    }
    return strings.to_string(b)
}

handle_ritual_request :: proc(gs: ^Game_State) {
    if gs.player.dead do return
    if gs.ritual.active do return  // an offering is already underway
    // The ritual only answers in the sky (design doc, review item C4) —
    // altars built below are inert.
    if gs.level_index != LEVEL_SKY {
        notify(gs, "The altar is inert - the ritual only answers in the sky")
        log_action(gs, "Ritual rejected: not on the sky level")
        return
    }
    // First tier whose rune scroll is found but structure unbuilt
    tier := -1
    all_built := true
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if gs.progression.sky_structure_complete[t] do continue
        all_built = false
        if gs.progression.rune_scroll_found[t] {
            tier = t
            break
        }
    }
    if tier < 0 {
        if all_built {
            notify(gs, "The altar's work is done")
        } else {
            notify(gs, "The altar is silent - find a rune scroll first")
        }
        return
    }

    for ing in structure_costs[tier] {
        have := inventory_count(&gs.player.inventory, ing.item)
        if have < ing.count {
            notify(gs, "Ritual needs %d %s (you have %d)", ing.count, item_table[ing.item].name, have)
            log_action(gs, "Ritual tier %d: missing %v", tier, ing.item)
            return
        }
    }
    // The offering is complete — begin the swirl.  Materials aren't consumed
    // until the finishing flash (update_ritual), so a save or an interruption
    // mid-swirl loses nothing.
    altar, ok := altar_near_player(gs)
    if !ok {
        // E only routes here when an altar is in reach, but fall back to the
        // player's tile so the animation still has a stage.
        altar = {i32(gs.player.pos.x + PLAYER_W*0.5), i32(gs.player.pos.y + PLAYER_H*0.5)}
    }
    start_ritual(gs, tier, altar)
}

// The Sky_Altar tile within reach of the player — the ritual's stage.
altar_near_player :: proc(gs: ^Game_State) -> ([2]i32, bool) {
    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            if get_tile(&gs.world, cx+dx, cy+dy) == .Sky_Altar {
                return {i32(cx+dx), i32(cy+dy)}, true
            }
        }
    }
    return {}, false
}

// How long the offering swirls over the altar before the finishing flash.
RITUAL_DURATION :: f32(2.0)

start_ritual :: proc(gs: ^Game_State, tier: int, altar: [2]i32) {
    gs.ritual = {active = true, timer = 0, tier = tier, altar = altar}
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Ritual_Swirl)}})
    notify(gs, "The altar draws in your offering...")
    log_action(gs, "Ritual tier %d begun", tier)
}

// The Seal comes undone the way every altar was raised, backwards: the swirl
// pours out of it, and the win lands when the ceremony ends (update_ritual).
start_seal_ceremony :: proc(gs: ^Game_State, seal: [2]i32) {
    gs.ritual = {active = true, altar = seal, seal = true}
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Ritual_Swirl)}})
    notify(gs, "The Hell Key turns...")
    log_action(gs, "The Final Seal ceremony begins")
}

// The eternal swirl's gift: stand inside the ring over a blessed altar and it
// bears you aloft — FLIGHT_BUFF_TIME of free flight, kept topped up while you
// stay in the swirl.  Same gates as draw_altar_eternal_swirl, so the buff can
// only come from a swirl the player can see.
FLIGHT_BUFF_TIME :: f32(20.0)
ALTAR_BLESS_R    :: f32(2.5)  // tiles from the swirl's center — the ring's reach

altar_blessing :: proc(gs: ^Game_State) {
    if gs.player.dead do return
    if gs.level_index != LEVEL_SKY do return
    if !gs.progression.sky_structure_complete[0] do return
    pc := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.5}
    cx := int(pc.x)
    cy := int(pc.y)
    // The swirl hangs 2 tiles above its altar, so hovering at the ring's top
    // puts the altar up to ~4.5 tiles below the body — scan deeper than wide.
    for dy in -1 ..= 5 {
        for dx in -3 ..= 3 {
            if get_tile(&gs.world, cx+dx, cy+dy) != .Sky_Altar do continue
            center := [2]f32{f32(cx+dx) + 0.5, f32(cy+dy) - 2}
            d := center - pc
            if d.x*d.x + d.y*d.y > ALTAR_BLESS_R*ALTAR_BLESS_R do continue
            if gs.flight_t <= 0 {
                notify(gs, "The swirl bears you aloft - flight!")
                log_action(gs, "Flight blessing granted at the altar")
                audio_play(&gs.audio, .Wand_Fire)
            }
            gs.flight_t = FLIGHT_BUFF_TIME
            return
        }
    }
}

// Step 5f — one-shot: the first time the sky apparition (render.odin) is
// genuinely glimpsed (window open, altitude above the gate), announce it
// once.  Uses sky_apparition_glimpse's own timing math so the notify only
// fires on a moment the player could actually see something.  Ambience
// only — pushes no events.
update_sky_apparition :: proc(gs: ^Game_State) {
    if gs.sky_apparition_glimpsed do return
    fade, _ := sky_apparition_glimpse(gs)
    if fade <= 0 do return
    gs.sky_apparition_glimpsed = true
    notify(gs, "Something moves at the edge of the sky...")
    log_action(gs, "First glimpse of the sky apparition")
}

// Step 5e — advances the offering animation.  Spawns the rainbow swirl each
// frame; at RITUAL_DURATION it consumes the materials, raises the structure
// (Structure_Complete) and opens the instruction tome.  Pushes an event, so it
// must run before process_events.  While no offering runs, the completed
// altar's eternal swirl hands out its flight blessing instead.
update_ritual :: proc(gs: ^Game_State) {
    if !gs.ritual.active {
        altar_blessing(gs)
        return
    }
    gs.ritual.timer += gs.delta_time
    spawn_ritual_swirl(gs, gs.ritual.altar, gs.ritual.timer, gs.ritual.seal)

    if gs.ritual.timer < RITUAL_DURATION do return

    tier := gs.ritual.tier
    altar := gs.ritual.altar
    seal := gs.ritual.seal
    gs.ritual.active = false

    if seal {
        if gs.player.dead do return  // killed mid-ceremony: the Seal holds
        log_action(gs, "The Final Seal breaks")
        spawn_ritual_flash(gs, altar)
        eq_push(&gs.events, Event{type = .Game_Won})
        gs.ui.show_book       = true
        gs.ui.book_page       = .Saga
        gs.ui.book_open_frame = gs.frame
        return
    }

    // Re-check the offering is still in the bag — nothing normally spends it
    // during the swirl, but be safe: if it's gone, the altar falls silent.
    for ing in structure_costs[tier] {
        if inventory_count(&gs.player.inventory, ing.item) < ing.count {
            notify(gs, "The offering slipped away - the altar falls silent")
            log_action(gs, "Ritual tier %d aborted: offering gone", tier)
            return
        }
    }
    for ing in structure_costs[tier] {
        inventory_remove(&gs.player.inventory, ing.item, ing.count)
    }
    spawn_ritual_flash(gs, altar)
    spawn_ritual_rebirth(gs, altar)
    eq_push(&gs.events, Event{type = .Structure_Complete, payload = {int_val = i32(tier)}})
    gs.ui.show_book       = true
    gs.ui.book_page       = .Seal
    gs.ui.book_tier       = tier
    gs.ui.book_open_frame = gs.frame
    log_action(gs, "Sky structure %d complete (ritual)", tier)
}

// How deep a level lies, for stats.deepest_cave.  Dimensions other than Hell
// hang off the map and do not count.
deepest_rank :: proc(gs: ^Game_State, level: int) -> int {
    switch level {
    case LEVEL_CAVE2: return 1
    case LEVEL_CAVE3: return 2
    case LEVEL_DIMENSION: return gs.dimension.kind == .Hell ? 3 : 0
    }
    return 0
}

// A life is over, by death or the win: its time joins the saga's.  Call before
// dead or game_won is set, and before the stats file is written; a life that
// has ended already (a second death, a death after the win) banks nothing.
saga_bank :: proc(gs: ^Game_State) {
    if gs.player.dead || gs.game_won do return
    gs.saga_life = gs.elapsed_time
    gs.stats.saga_seconds += f64(gs.saga_life)
}

// How long the saga has lasted: every life before this one, and this one while
// it runs (an ended life is banked already).
saga_seconds :: proc(gs: ^Game_State) -> f64 {
    if gs.player.dead || gs.game_won do return gs.stats.saga_seconds
    return gs.stats.saga_seconds + f64(gs.elapsed_time)
}

// The death screen's record line: the saga's clock, and the counts beside it.
death_saga_line :: proc(gs: ^Game_State, buf: []u8) -> string {
    secs := int(saga_seconds(gs))
    return fmt.bprintf(buf, "Your saga lasted %d:%02d      Kills %d      Runs %d",
        secs / 60, secs % 60, gs.stats.total_kills, gs.stats.runs_played)
}

// The tome's account of the run, one line each; `bufs` holds the formatted text.
// Every line is the player's whole record, across all their lives.
saga_lines :: proc(gs: ^Game_State, bufs: ^[4][64]u8) -> [4]string {
    deepest := [4]string{"the Surface", level_names[LEVEL_CAVE2], level_names[LEVEL_CAVE3], dimension_table[.Hell].name}
    secs := int(saga_seconds(gs))
    return {
        fmt.bprintf(bufs[0][:63], "This saga lasted %d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60),
        fmt.bprintf(bufs[1][:63], "Heroes fallen before you: %d", gs.stats.runs_played - gs.stats.runs_won),
        fmt.bprintf(bufs[2][:63], "Foes slain by all of them: %d", gs.stats.total_kills),
        fmt.bprintf(bufs[3][:63], "Deepest reached: %s", deepest[clamp(gs.stats.deepest_cave, 0, 3)]),
    }
}

// ─── Generation: caves 2–3 ────────────────────────────────────────────────────
//
//  Full-grid cellular-automata cave.  `depth_tier` 1 = cave 2, 2 = cave 3;
//  deeper tiers are richer in ore and wetter with lava.

CAVE_POOL_W :: 16
CAVE_POOL_H :: 4

// A stone-lined tub whose rim is `top`: it holds its water whatever the noise
// carved around it, which a bare chamber floor would not.
dig_cave_pool :: proc(w: ^World_Grid, cx, top: int) {
    x0, x1 := cx - CAVE_POOL_W/2, cx + CAVE_POOL_W/2 - 1
    for y in top ..= top + CAVE_POOL_H {
        for x in x0 - 1 ..= x1 + 1 {
            wall := x < x0 || x > x1 || y == top + CAVE_POOL_H
            set_tile(w, x, y, wall ? Tile_Type.Stone : Tile_Type.Water)
        }
    }
}

CAVE_LVL_TOP :: 3
CAVE_LVL_BOT :: GRID_H - 2

gen_cave_level :: proc(w: ^World_Grid, depth_tier: int, seed: u32 = 0) {
    w^ = {}
    for i in 0 ..< GRID_W * GRID_H {
        w.entity_map[i] = INVALID_ENTITY
        w.terrain[i]    = .Stone
    }

    salt_x := u32(depth_tier) * 7346087  + 374761393
    salt_y := u32(depth_tier) * 9176501  + 668265263

    buf_a: [GRID_W * GRID_H]bool
    buf_b: [GRID_W * GRID_H]bool

    for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT {
        for x in 1 ..< GRID_W - 1 {
            h := whash(u32(x) * salt_x + seed) ~ whash(u32(y) * salt_y + seed)
            buf_a[grid_idx(x, y)] = (h % 100) < 45
        }
    }
    for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT {
        buf_a[grid_idx(1, y)]        = true
        buf_a[grid_idx(GRID_W-2, y)] = true
    }
    for x in 1 ..< GRID_W - 1 {
        buf_a[grid_idx(x, CAVE_LVL_TOP)]   = true
        buf_a[grid_idx(x, CAVE_LVL_BOT-1)] = true
    }

    src := buf_a[:]
    dst := buf_b[:]
    for _ in 0 ..< 5 {
        for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT {
            for x in 1 ..< GRID_W - 1 {
                if x == 1 || x == GRID_W-2 || y == CAVE_LVL_TOP || y == CAVE_LVL_BOT-1 {
                    dst[grid_idx(x, y)] = true
                    continue
                }
                solid := 0
                for dy in -1 ..= 1 {
                    for dx in -1 ..= 1 {
                        if dx == 0 && dy == 0 do continue
                        if src[grid_idx(x+dx, y+dy)] do solid += 1
                    }
                }
                if src[grid_idx(x, y)] {
                    dst[grid_idx(x, y)] = solid >= 4
                } else {
                    dst[grid_idx(x, y)] = solid > 4
                }
            }
        }
        src, dst = dst, src
    }

    for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT {
        for x in 1 ..< GRID_W - 1 {
            if !src[grid_idx(x, y)] do set_tile(w, x, y, .Void)
        }
    }

    // Open chambers so the cave is traversable
    carve_ellipse(w, GRID_W/4,   30, 10, 6)
    carve_ellipse(w, GRID_W/2,   55, 11, 7)
    carve_ellipse(w, 3*GRID_W/4, 85, 10, 6)

    // Ore veins: richer with depth tier
    for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT {
        for x in 1 ..< GRID_W - 1 {
            if get_tile(w, x, y) != .Stone do continue
            h     := whash(u32(x) * 2654435761 + u32(y) * 1013904223 + u32(depth_tier) * 97)
            gh    := whash(h)  // fresh bits for the gem roll — per-mille, not per-cent
            depth := y - CAVE_LVL_TOP
            switch {
            // Gems first (sparse, must never be masked by a metal roll).
            // One gem per layer: Jade in cave 2, Diamond in cave 3, and
            // Hel Gems only in the hellish band around the boss arena —
            // the arena carve wipes any inside the room itself.
            case depth_tier == 2 && y > ARENA_Y0 - 10 && (gh >> 10) % 1000 < 4:
                set_tile(w, x, y, .Hel_Gem_Ore)
            case depth_tier == 1 && depth > 60 && gh % 1000 < 6:
                set_tile(w, x, y, .Jade_Ore)
            case depth_tier == 2 && depth > 60 && gh % 1000 < 3:
                set_tile(w, x, y, .Diamond_Ore)
            case (h % 100) < u32(4 + 2*depth_tier):
                set_tile(w, x, y, .Iron_Ore)
            case depth > 15 && (h >> 8) % 100 < u32(2 + 2*depth_tier):
                set_tile(w, x, y, .Silver_Ore)
            case depth > 30 && (h >> 16) % 100 < u32(2*depth_tier):
                set_tile(w, x, y, .Gold_Ore)
            }
        }
    }

    // Lava pools in bottom-region voids; cave 3 gets magic lava too
    for y in CAVE_LVL_BOT - 14 ..< CAVE_LVL_BOT - 1 {
        for x in 1 ..< GRID_W - 1 {
            if get_tile(w, x, y) != .Void do continue
            below := get_tile(w, x, y+1)
            if !is_solid(w, x, y+1) && below != .Lava && below != .Magic_Lava {
                continue
            }
            h := whash(u32(x) * 31337 + u32(y) * 271 + u32(depth_tier))
            if h % 100 < 22 {
                lava: Tile_Type = .Lava
                if depth_tier >= 2 && (h >> 8) % 3 == 0 do lava = .Magic_Lava
                set_tile(w, x, y, lava)
            }
        }
    }

    // Deep Cave's pool: the only water underground, and the Cave Eels' home.
    if depth_tier == 1 do dig_cave_pool(w, GRID_W/4, 36)

    // Spawn chamber (mid-map) with the return portal
    carve_box(w, 91, 20, 101, 26)
    for x in 91 ..= 101 do set_tile(w, x, 27, .Stone)
    set_tile(w, 93, 26, .Cave_Entrance)
    set_tile(w, 94, 26, .Cave_Entrance)

    // Deep portal chamber (bottom-right) — cave 2 only: gateway to cave 3
    if depth_tier == 1 {
        carve_box(w, 176, 96, 186, 102)
        for x in 176 ..= 186 do set_tile(w, x, 103, .Stone)
        set_tile(w, 180, 102, .Cave_Entrance)
        set_tile(w, 181, 102, .Cave_Entrance)
    }

    // Boss arena (bottom-right) — cave 3 only: a generated room, not open
    // cave.  Garm spawns here once structure C is built (see garm.odin).
    if depth_tier == 2 {
        carve_box(w, ARENA_X0, ARENA_Y0, ARENA_X1, ARENA_Y1)
        for x in ARENA_X0 ..= ARENA_X1 do set_tile(w, x, ARENA_Y1 + 1, .Stone)
    }

    // Rune Scroll chamber (bottom-left)
    carve_box(w, 8, 96, 16, 101)
    for x in 8 ..= 16 do set_tile(w, x, 102, .Stone)
    bp: Item = depth_tier == 1 ? .Rune_Scroll_B : .Rune_Scroll_C
    place_rune_scroll_chest(w, 12, 101, bp)

    // Green cave mushrooms thrive down here — the deep caves are the real
    // patch, where the surface cave only hints (gen_cave_1 grows 1–3).
    // Runs last so a chamber carve can never orphan a sprout from its moss.
    for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT - 1 {
        for x in 1 ..< GRID_W - 1 {
            if get_tile(w, x, y) != .Void do continue
            if get_tile(w, x, y + 1) != .Stone do continue
            mh := whash(u32(x) * 374761393 + u32(y) * 668265263 + u32(depth_tier) * 131)
            if mh % 100 < 4 {
                set_tile(w, x, y, .Green_Cave_Mushroom)
                set_tile(w, x, y + 1, .Mossy_Stone)
            }
        }
    }
}

carve_box :: proc(w: ^World_Grid, x0, y0, x1, y1: int) {
    for y in y0 ..= y1 {
        for x in x0 ..= x1 {
            set_tile(w, x, y, .Void)
        }
    }
}

// ─── Generation: low sky ──────────────────────────────────────────────────────
//
//  Open air with cloud platforms; Cloud_Ore pockets sit on the platforms.
//  The base platform holds the return portal.  A rainbow arcs over it all, and
//  islands with a tree, a pond and nests float under it.

// Falling below this row on the sky level returns the player to the surface
// (the base platform sits at row 80; see gen_sky_level).
SKY_FALL_Y :: 85

// The rainbow: a parabola of bridge tiles between two cloud islands, one tile
// a column and rising at most one row a column, so a walker's step-up climbs
// it end to end.  It rises from the gap under band row 64 to below band row 28.
// Fixed, not hashed: it is the same landmark in every world.  Tune by eye.
RAINBOW_CENTER_X  :: GRID_W / 2
RAINBOW_HALF_SPAN :: 72  // columns from the apex to either foot
RAINBOW_APEX_Y    :: 34
RAINBOW_FOOT_Y    :: 70
RAINBOW_HEADROOM  :: 3   // rows of cloud cleared over the deck; a body is 1.8
RAINBOW_ISLAND_W  :: 13  // columns of each foot's island

rainbow_deck_y :: proc(x: int) -> int {
    dx := x - RAINBOW_CENTER_X
    return RAINBOW_APEX_Y + (RAINBOW_FOOT_Y - RAINBOW_APEX_Y) * dx * dx / (RAINBOW_HALF_SPAN * RAINBOW_HALF_SPAN)
}

// Puffy body: the top row stays flat and walkable, the underside bulges 1–3
// tiles deep — deepest mid-platform, tapering toward the edges, hash-jittered
// so no two clouds share a silhouette.
stamp_cloud :: proc(w: ^World_Grid, x0, x1, row: int) {
    for x in x0 ..< x1 {
        edge  := min(x - x0, x1 - 1 - x)
        depth := 1
        if edge >= 1 do depth = 2
        if edge >= 3 && whash(u32(x)*2654435761 + u32(row)*97) % 100 < 55 do depth = 3
        for d in 0 ..< depth do set_tile(w, x, row + d, .Cloud)
    }
}

// The bands are hashed, so the deck cuts its own way through whatever cloud
// lies across it.
gen_rainbow_bridge :: proc(w: ^World_Grid) {
    left  := RAINBOW_CENTER_X - RAINBOW_HALF_SPAN
    right := RAINBOW_CENTER_X + RAINBOW_HALF_SPAN
    stamp_cloud(w, left - RAINBOW_ISLAND_W + 1, left + 1, RAINBOW_FOOT_Y)
    stamp_cloud(w, right, right + RAINBOW_ISLAND_W, RAINBOW_FOOT_Y)
    for x in left ..= right {
        y := rainbow_deck_y(x)
        set_tile(w, x, y, .Rainbow_Bridge)
        for up in 1 ..= RAINBOW_HEADROOM do set_tile(w, x, y - up, .Air)
    }
}

// Four islands stand in the gaps between the bands, under the rainbow and above
// row 63, so the base platform and the portal stay clear of them.  The hash
// nudges each one and deals the four kinds out once, so every sky has them all.
Sky_Island_Kind :: enum { Tree, Pond, Egg_Nest, Ore_Nest }

SKY_ISLAND_SPOTS := [len(Sky_Island_Kind)][2]int{{62, 48}, {116, 48}, {46, 60}, {134, 60}}
SKY_ISLAND_W      :: 13
SKY_ISLAND_NUDGE  :: 5  // columns of hashed drift
SKY_TREE_HEIGHT   :: 3  // trunk rows; the crown stops short of the band above
SKY_POND_REACH    :: 2  // columns of water each side of the middle
SKY_POND_DEPTH    :: 2
SKY_NEST_EGGS     :: 2  // first guess, Glenn's to tune

gen_sky_islands :: proc(w: ^World_Grid, seed: u32) {
    deal := int(whash(seed + 6151) % len(Sky_Island_Kind))
    for spot, i in SKY_ISLAND_SPOTS {
        x0  := spot.x + int(whash(seed + u32(i) * 3571) % SKY_ISLAND_NUDGE)
        row := spot.y
        stamp_cloud(w, x0, x0 + SKY_ISLAND_W, row)
        mid := x0 + SKY_ISLAND_W / 2

        switch Sky_Island_Kind((i + deal) % len(Sky_Island_Kind)) {
        case .Tree:
            place_tree(w, mid, row, SKY_TREE_HEIGHT)
        case .Pond:
            for x in mid - SKY_POND_REACH ..= mid + SKY_POND_REACH {
                for d in 0 ..< SKY_POND_DEPTH do set_tile(w, x, row + d, .Water)
                set_tile(w, x, row + SKY_POND_DEPTH, .Cloud)
            }
        case .Egg_Nest:
            for x in mid - 1 ..= mid + 1 do set_tile(w, x, row - 1, .Nest)
            idx := grid_idx(mid, row - 1)
            w.items[idx], w.item_counts[idx] = .Sky_Egg, SKY_NEST_EGGS
        case .Ore_Nest:
            for x in mid - 1 ..= mid + 1 do set_tile(w, x, row - 1, .Nest)
            set_tile(w, mid, row - 1, .Cloud_Ore)
        }
    }
}

gen_sky_level :: proc(w: ^World_Grid, seed: u32 = 0) {
    w^ = {}
    for i in 0 ..< GRID_W * GRID_H {
        w.entity_map[i] = INVALID_ENTITY
        w.terrain[i]    = .Air
    }

    // Platform bands: rows of cloud segments, offset per band by hash
    band_rows := [5]int{28, 40, 52, 64, 76}
    for row, band in band_rows {
        for seg in 0 ..< 8 {
            h := whash(u32(band) * 1543 + u32(seg) * 7919 + seed)
            if h % 100 < 70 {
                x0  := seg * 24 + int(h % 10)
                len := 8 + int((h >> 8) % 8)
                x1  := min(x0 + len, GRID_W - 2)
                stamp_cloud(w, x0, x1, row)
                // Cloud ore pocket on ~half the platforms
                if (h >> 16) % 100 < 50 {
                    ox := x0 + len/2
                    for dx in 0 ..< 3 {
                        if get_tile(w, ox+dx, row) == .Cloud {
                            set_tile(w, ox+dx, row, .Cloud_Ore)
                        }
                    }
                }
                // Aether crystal pocket — the two highest bands only, rarer
                // than cloud ore, sits at the platform's left edge so both
                // pockets can share a platform.
                if band < 2 && (h >> 24) % 100 < 25 {
                    for dx in 1 ..< 3 {
                        if get_tile(w, x0+dx, row) == .Cloud {
                            set_tile(w, x0+dx, row, .Aether_Ore)
                        }
                    }
                }
            }
        }
    }

    gen_rainbow_bridge(w)
    gen_sky_islands(w, seed)

    // Base platform with the return portal — puffy underside like the bands
    for x in 88 ..= 104 do set_tile(w, x, 80, .Cloud)
    for x in 89 ..= 103 do set_tile(w, x, 81, .Cloud)
    for x in 91 ..= 101 do set_tile(w, x, 82, .Cloud)
    set_tile(w, 95, 79, .Sky_Entrance)
    set_tile(w, 96, 79, .Sky_Entrance)
}

// ─── Level 0 additions: portals + rune scroll (called from world_init) ──────────

carve_level0_portals :: proc(w: ^World_Grid) {
    // Portal chamber deep in cave 1 (bottom-right chamber region)
    carve_box(w, 139, 89, 149, 94)
    for x in 139 ..= 149 do set_tile(w, x, 95, .Stone)
    set_tile(w, 143, 94, .Cave_Entrance)
    set_tile(w, 144, 94, .Cave_Entrance)

    // Rune Scroll A is NOT placed here — it appears in this chamber only once
    // the Sky Altar stands (spawn_deep_rune_scroll), so new players face one
    // rune scroll at a time.

    // The Sky Rune Scroll waits in a rune-locked coffer near spawn.  It reveals
    // the Sky Altar that, once built, opens the gate to the heavens.
    sbp_x := GRID_W/2 - 12
    set_tile(w, sbp_x, SURFACE_Y - 1, .Air)  // clear any decoration
    place_rune_scroll_chest(w, sbp_x, SURFACE_Y - 1, .Sky_Rune_Scroll)
}

debug_add_all_structures :: proc(gs: ^Game_State) {
    structures := [?]Item{.Crafting_Bench, .Tree_Grower, .Smelter, .Dvergr_Forge, .Rune_Altar, .Sky_Altar, .Dimension_Spawner, .Dimension_Spawner_Gold}
    for s in structures {
        for &slot in gs.player.inventory.slots {
            if slot.item == .None {
                slot.item = s
                slot.count = 1
                break
            }
        }
    }
    notify(gs, "Debug: added all structures to inventory")
}

// F2 altar kit: raise a tier's full sky structure — foundation and capstone —
// with the capstone at (ax, ay), skipping the build grind.
debug_stamp_altar_template :: proc(gs: ^Game_State, tier: int, ax, ay: int) {
    tpl := &structure_templates[tier]
    acol, arow := structure_template_anchor(tpl)
    for line, r in tpl.rows {
        for glyph, c in line {
            tile, kind := structure_template_cell(glyph)
            wx := ax + (c - acol)
            wy := ay + (r - arow)
            if !in_bounds(wx, wy) do continue
            switch kind {
            case .Support:  set_tile(&gs.world, wx, wy, tile)
            case .Capstone: set_tile(&gs.world, wx, wy, .Sky_Altar)
            case .Empty:
            }
        }
    }
    notify(gs, "Debug: %s raised - the ritual answers in the sky", tpl.name)
}

// F2 altar kit: complete the next ritual free of charge.  The real
// Structure_Complete path runs (cave unlock, fanfare, Garm's wakening).
debug_complete_next_ritual :: proc(gs: ^Game_State) {
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if gs.progression.sky_structure_complete[t] do continue
        gs.progression.rune_scroll_found[t] = true
        eq_push(&gs.events, Event{type = .Structure_Complete, payload = {int_val = i32(t)}})
        log_action(gs, "Debug: ritual tier %d completed", t)
        return
    }
    notify(gs, "Debug: all rituals already complete")
}

debug_add_resources :: proc(gs: ^Game_State) {
    resources := [?]Item{.Wood_Log, .Stone_Block, .Iron_Ore, .Silver_Ore, .Gold_Ore, .Gold_Rare_Ore, .Iron_Bar, .Silver_Bar, .Gold_Bar, .Cloud_Stone, .Aether_Crystal, .Runic_Sky_Ore, .Emerald, .Jade, .Diamond, .Hel_Gem}
    for r in resources {
        for &slot in gs.player.inventory.slots {
            if slot.item == .None {
                slot.item = r
                slot.count = 64
                break
            }
        }
    }
    notify(gs, "Debug: added resource stacks to inventory")
}
