package game

import "core:fmt"

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

@(rodata)
level_portals := [NUM_LEVELS][MAX_LEVEL_PORTALS]Portal{
    LEVEL_SURFACE = {
        // Deep in cave 1 → cave 2 (locked behind sky structure A)
        { {{143, 94}, {144, 94}},  LEVEL_CAVE2,   {8, 15 - PLAYER_H},    0 },
        {},  // the sky gate is dynamic now — raised by a surface Sky Altar (sky_gate_portal)
    },
    LEVEL_CAVE2 = {
        // Spawn chamber → back to cave 1's portal chamber
        { {{6, 14}, {7, 14}},      LEVEL_SURFACE, {143, 95 - PLAYER_H}, -1 },
        // Bottom-right → cave 3 (locked behind sky structure B)
        { {{180, 102}, {181, 102}}, LEVEL_CAVE3,  {8, 15 - PLAYER_H},    1 },
    },
    LEVEL_CAVE3 = {
        // Spawn chamber → back to cave 2's deep portal chamber
        { {{6, 14}, {7, 14}},      LEVEL_CAVE2,   {178, 103 - PLAYER_H}, -1 },
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

    dest := portal.dest_level
    if ls.generated[dest] {
        gs.world   = ls.worlds[dest]
        gs.enemies = ls.enemies[dest]
    } else {
        gs.enemies = {}
        switch dest {
        case LEVEL_CAVE2:
            gen_cave_level(&gs.world, 1)
            spawn_builder(gs, 40)
            spawn_builder(gs, GRID_W - 40)
            spawn_builder(gs, GRID_W / 2)
        case LEVEL_CAVE3:
            gen_cave_level(&gs.world, 2)
            spawn_builder(gs, 40)
            spawn_builder(gs, GRID_W - 40)
            spawn_builder(gs, GRID_W / 2)
        case LEVEL_SKY:
            gen_sky_level(&gs.world)
        case LEVEL_DIMENSION:
            gen_dimension(&gs.world, gs.dimension.kind, gs.dimension.seed)
        }
        ls.generated[dest] = true
    }

    gs.level_index = dest
    gs.player.pos  = portal.dest_pos
    gs.player.vel  = {}
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

    // Standing in a dimension's return gate: step back home.
    if gs.level_index == LEVEL_DIMENSION && get_tile(&gs.world, cx, cy) == .Dimension_Gate {
        dimension_exit(gs)
        return
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
                        dimension_enter(gs, {i32(cx + dx), i32(cy + dy)}, kind)
                        return
                    }
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
}

// ─── Sky Structure Ritual ─────────────────────────────────────────────────────
//
//  One cost per progression tier.  v1.0 has a single sky level, so tier 1
//  mixes sky and cave-2 materials instead of the cut sky -2 level's ore.

@(rodata)
structure_costs := [MAX_PROGRESSION_TIERS][2]Ingredient{
    { {.Cloud_Stone, 8},  {.Plank, 4}      },   // A → unlocks cave 2
    { {.Cloud_Stone, 12}, {.Silver_Ore, 6} },   // B → unlocks cave 3
    { {.Cloud_Stone, 20}, {.Gold_Ore, 10}  },   // final → boss gate (Phase 5)
}

// The tier the blueprint overlay speaks to: the first blueprint found whose
// sky structure isn't raised yet.  -1 = the player carries no active blueprint.
blueprint_active_tier :: proc(gs: ^Game_State) -> int {
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if gs.progression.blueprint_found[t] && !gs.progression.sky_structure_complete[t] {
            return t
        }
    }
    return -1
}

// Which cave a tier's ritual unlocks — for the blueprint overlay text.
blueprint_unlocks_name :: proc(tier: int) -> string {
    switch tier {
    case 0:  return level_names[LEVEL_CAVE2]
    case 1:  return level_names[LEVEL_CAVE3]
    case:    return "the final depths"
    }
}

// Each tier's blueprint item and where it rests — for the locked-gate toast
// and the HUD objective line.
@(rodata)
tier_blueprints := [MAX_PROGRESSION_TIERS]Item{.Blueprint_A, .Blueprint_B, .Blueprint_C}

@(rodata)
blueprint_places := [MAX_PROGRESSION_TIERS]string{
    "deep beneath the Surface",
    "in the Deep Cave",
    "in Gnipahellir",
}

// Raising the Sky Altar reveals Blueprint A in the sealed portal chamber
// (carved by carve_level0_portals) — one goal at a time for new players.
// Idempotent: no respawn once found or while it already lies there.
spawn_deep_blueprint :: proc(gs: ^Game_State) {
    if gs.progression.blueprint_found[0] do return
    idx := grid_idx(141, 94)
    if gs.world.items[idx] != .None do return
    gs.world.items[idx]       = .Blueprint_A
    gs.world.item_counts[idx] = 1
    notify(gs, "Something stirs deep below — seek the sealed chamber")
}

// The HUD objective line: the first incomplete step of the progression loop,
// so a new player always knows the next move.  Pure read; formats into the
// caller's buffer.  Empty = nothing to show (game won).
current_objective :: proc(gs: ^Game_State, buf: []u8) -> string {
    if gs.game_won do return ""
    p := &gs.progression
    if p.final_boss_defeated {
        return fmt.bprintf(buf, "GARM is slain — claim the Hell Key")
    }

    tier := -1
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if !p.sky_structure_complete[t] {
            tier = t
            break
        }
    }
    if tier < 0 {
        return fmt.bprintf(buf, "All rituals done — face GARM in %s", level_names[LEVEL_CAVE3])
    }
    if p.sky_altar_pos == {0, 0} {
        return fmt.bprintf(buf, "Raise a Sky Altar on the Surface to open the way above")
    }
    if !p.blueprint_found[tier] {
        return fmt.bprintf(buf, "Find %s %s",
            item_table[tier_blueprints[tier]].name, blueprint_places[tier])
    }
    c := structure_costs[tier]
    return fmt.bprintf(buf, "Sky ritual: %d %s + %d %s — [%v] at the altar in the %s",
        c[0].count, item_table[c[0].item].name,
        c[1].count, item_table[c[1].item].name,
        gs.bindings[.Interact], level_names[LEVEL_SKY])
}

handle_ritual_request :: proc(gs: ^Game_State) {
    if gs.player.dead do return
    // The ritual only answers in the sky (design doc, review item C4) —
    // altars built below are inert.
    if gs.level_index != LEVEL_SKY {
        notify(gs, "The altar is inert — the ritual only answers in the sky")
        log_action(gs, "Ritual rejected: not on the sky level")
        return
    }
    // First tier whose blueprint is found but structure unbuilt
    tier := -1
    all_built := true
    for t in 0 ..< MAX_PROGRESSION_TIERS {
        if gs.progression.sky_structure_complete[t] do continue
        all_built = false
        if gs.progression.blueprint_found[t] {
            tier = t
            break
        }
    }
    if tier < 0 {
        if all_built {
            notify(gs, "The altar's work is done")
        } else {
            notify(gs, "The altar is silent — find a blueprint first")
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
    for ing in structure_costs[tier] {
        inventory_remove(&gs.player.inventory, ing.item, ing.count)
    }
    eq_push(&gs.events, Event{type = .Structure_Complete, payload = {int_val = i32(tier)}})
    log_action(gs, "Sky structure %d complete", tier)
}

// ─── Generation: caves 2–3 ────────────────────────────────────────────────────
//
//  Full-grid cellular-automata cave.  `depth_tier` 1 = cave 2, 2 = cave 3;
//  deeper tiers are richer in ore and wetter with lava.

CAVE_LVL_TOP :: 3
CAVE_LVL_BOT :: GRID_H - 2

gen_cave_level :: proc(w: ^World_Grid, depth_tier: int) {
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
            h := whash(u32(x) * salt_x) ~ whash(u32(y) * salt_y)
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
            case depth_tier == 1 && depth > 60 && gh % 1000 < 3:
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

    // Spawn chamber (top-left) with the return portal
    carve_box(w, 4, 8, 14, 14)
    for x in 4 ..= 14 do set_tile(w, x, 15, .Stone)
    set_tile(w, 6, 14, .Cave_Entrance)
    set_tile(w, 7, 14, .Cave_Entrance)

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

    // Blueprint chamber (bottom-left)
    carve_box(w, 8, 96, 16, 101)
    for x in 8 ..= 16 do set_tile(w, x, 102, .Stone)
    bp: Item = depth_tier == 1 ? .Blueprint_B : .Blueprint_C
    idx := grid_idx(12, 101)
    w.items[idx]       = bp
    w.item_counts[idx] = 1
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
//  The base platform holds the return portal.

// Falling below this row on the sky level returns the player to the surface
// (the base platform sits at row 80; see gen_sky_level).
SKY_FALL_Y :: 85

gen_sky_level :: proc(w: ^World_Grid) {
    w^ = {}
    for i in 0 ..< GRID_W * GRID_H {
        w.entity_map[i] = INVALID_ENTITY
        w.terrain[i]    = .Air
    }

    // Platform bands: rows of cloud segments, offset per band by hash
    band_rows := [5]int{28, 40, 52, 64, 76}
    for row, band in band_rows {
        for seg in 0 ..< 8 {
            h := whash(u32(band) * 1543 + u32(seg) * 7919)
            if h % 100 < 70 {
                x0  := seg * 24 + int(h % 10)
                len := 8 + int((h >> 8) % 8)
                for x in x0 ..< min(x0 + len, GRID_W - 2) {
                    set_tile(w, x, row, .Cloud)
                }
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

    // Base platform with the return portal
    for x in 88 ..= 104 do set_tile(w, x, 80, .Cloud)
    set_tile(w, 95, 79, .Sky_Entrance)
    set_tile(w, 96, 79, .Sky_Entrance)
}

// ─── Level 0 additions: portals + blueprint (called from world_init) ──────────

carve_level0_portals :: proc(w: ^World_Grid) {
    // Portal chamber deep in cave 1 (bottom-right chamber region)
    carve_box(w, 139, 89, 149, 94)
    for x in 139 ..= 149 do set_tile(w, x, 95, .Stone)
    set_tile(w, 143, 94, .Cave_Entrance)
    set_tile(w, 144, 94, .Cave_Entrance)

    // Blueprint A is NOT placed here — it appears in this chamber only once
    // the Sky Altar stands (spawn_deep_blueprint), so new players face one
    // blueprint at a time.

    // Sky Blueprint rests on the grass near spawn — it reveals the Sky Altar
    // that, once built, opens the gate to the heavens.
    sbp_x := GRID_W/2 - 12
    set_tile(w, sbp_x, SURFACE_Y - 1, .Air)  // clear any decoration
    sbp := grid_idx(sbp_x, SURFACE_Y - 1)
    w.items[sbp]       = .Sky_Blueprint
    w.item_counts[sbp] = 1
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
