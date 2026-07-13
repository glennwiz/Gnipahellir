package game

// ─── Parallel Dimensions ──────────────────────────────────────────────────────
//
//  A placed Dimension Spawner opens a portal into a fresh, themed, mineable
//  world (draft1_machines.md §7).  v1 slice: one hardcoded Metal theme, and
//  every dimension is ephemeral — it regenerates from its seed each entry, so
//  mined state (and anything left inside) is lost on exit.  Dimension Locks,
//  blocks and background yield come later.
//
//  The dimension reuses the level machinery: it lives in Level_Store slot
//  LEVEL_DIMENSION, entered via a dynamic portal (like the surface sky gate)
//  from whichever level the spawner stands on.  The seed derives from the
//  spawner's tile, so one spawner always opens the same world layout.

Dimension_Kind :: enum u8 {
    Metal,
    Gold,
}

// Theme → generation parameters.  New dimension type = new table row (plus a
// spawner tile/item and a recipe whose cost mirrors the theme's riches).
// Veins are checked in order per stone tile (first row = dominant ore), each
// against its own hash byte; .Air rows are unused slots.
MAX_THEME_VEINS :: 4

Dimension_Vein :: struct {
    tile: Tile_Type,
    pct:  u32,   // vein chance per stone tile, percent
}

Dimension_Theme :: struct {
    name:  string,
    veins: [MAX_THEME_VEINS]Dimension_Vein,
}

@(rodata)
dimension_table := [Dimension_Kind]Dimension_Theme{
    .Metal = { "Metal Dimension", {{.Iron_Ore, 14}, {.Silver_Ore, 6}, {.Gold_Ore, 3}, {}} },
    .Gold  = { "Gold Dimension",  {{.Gold_Ore, 12}, {.Iron_Ore, 4},  {.Silver_Ore, 3}, {}} },
}

// Which placed tile opens which theme — the station_tile pattern.
@(rodata)
dimension_spawner_tile := [Dimension_Kind]Tile_Type{
    .Metal = .Dimension_Spawner,
    .Gold  = .Dimension_Spawner_Gold,
}

// Where the player came from — restored on exit.  Saved with the run so a
// save/quit inside a dimension still finds its way home.
Dimension_State :: struct {
    return_level: int,
    return_pos:   [2]f32,
    kind:         Dimension_Kind,
    seed:         u32,
}

// The return gate carved into every dimension's spawn chamber.
DIM_GATE_TILES :: [2][2]i32{{6, 14}, {7, 14}}
DIM_SPAWN_POS  :: [2]f32{8, 15 - PLAYER_H}

// ─── Enter / Exit ─────────────────────────────────────────────────────────────

// Step through a placed spawner.  Ephemeral by design: the generated flag is
// dropped first, so level_transition always regenerates from the seed.
dimension_enter :: proc(gs: ^Game_State, spawner: [2]i32, kind: Dimension_Kind) {
    gs.dimension.return_level = gs.level_index
    gs.dimension.return_pos   = gs.player.pos
    gs.dimension.kind         = kind
    gs.dimension.seed         = whash(u32(spawner.x) * 2654435761 + u32(spawner.y) * 97)
    gs.levels.generated[LEVEL_DIMENSION] = false

    p := Portal{
        tiles      = {spawner, spawner},
        dest_level = LEVEL_DIMENSION,
        dest_pos   = DIM_SPAWN_POS,
        gate_tier  = -1,
    }
    level_transition(gs, &p)
}

// Step back through the dimension's gate to wherever the spawner stands.
dimension_exit :: proc(gs: ^Game_State) {
    p := Portal{
        tiles      = DIM_GATE_TILES,
        dest_level = gs.dimension.return_level,
        dest_pos   = gs.dimension.return_pos,
        gate_tier  = -1,
    }
    level_transition(gs, &p)
}

// ─── Generation ───────────────────────────────────────────────────────────────
//
//  Same cellular-automata shape as gen_cave_level, salted by the dimension
//  seed, with ore density driven by the theme table instead of depth tier.

gen_dimension :: proc(w: ^World_Grid, kind: Dimension_Kind, seed: u32) {
    theme := &dimension_table[kind]

    w^ = {}
    for i in 0 ..< GRID_W * GRID_H {
        w.entity_map[i] = INVALID_ENTITY
        w.terrain[i]    = .Stone
    }

    salt_x := seed * 7346087  + 374761393
    salt_y := seed * 9176501  + 668265263

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

    // Open chambers so the dimension is traversable
    carve_ellipse(w, GRID_W/4,   30, 10, 6)
    carve_ellipse(w, GRID_W/2,   55, 11, 7)
    carve_ellipse(w, 3*GRID_W/4, 85, 10, 6)

    // Ore veins: theme-driven — this is the whole point of the place.  No
    // depth gating: a manufactured world is uniformly rich, unlike a cave.
    for y in CAVE_LVL_TOP ..< CAVE_LVL_BOT {
        for x in 1 ..< GRID_W - 1 {
            if get_tile(w, x, y) != .Stone do continue
            h := whash(u32(x) * 2654435761 + u32(y) * 1013904223 + seed)
            for vein, i in theme.veins {
                if vein.tile == .Air do continue
                if (h >> (u32(i) * 8)) % 100 < vein.pct {
                    set_tile(w, x, y, vein.tile)
                    break
                }
            }
        }
    }

    // Spawn chamber (top-left) with the return gate
    carve_box(w, 4, 8, 14, 14)
    for x in 4 ..= 14 do set_tile(w, x, 15, .Stone)
    gate := DIM_GATE_TILES
    set_tile(w, int(gate[0].x), int(gate[0].y), .Dimension_Gate)
    set_tile(w, int(gate[1].x), int(gate[1].y), .Dimension_Gate)
}
