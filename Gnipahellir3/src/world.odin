package game

import rl "vendor:raylib/v55"

// ─── Terrain Behavior Table ───────────────────────────────────────────────────

Terrain_Behavior :: struct {
    name:              string,
    flags:             Terrain_Flags,
    color:             rl.Color,
    move_cost:         f32,   // 0 = solid, 1 = normal, 2 = slow
    damage_per_second: f32,
    drop_item:         Item,
}

@(rodata)
terrain_table := [Tile_Type]Terrain_Behavior{
    .Air            = { "Air",           {},                                                         rl.Color{135, 206, 235, 255}, 1,   0,   .None          },
    .Void           = { "Void",          {},                                                         rl.Color{0,   0,   0,   255}, 1,   0,   .None          },
    .Grass          = { "Grass",         {.Solid, .Mineable},                                        rl.Color{34,  139, 34,  255}, 0,   0,   .Grass_Turf    },
    .Stone          = { "Stone",         {.Solid, .Mineable},                                        rl.Color{128, 128, 128, 255}, 0,   0,   .Stone_Block   },
    .Water          = { "Water",         {.Walkable, .Swimmable},                                    rl.Color{30,  100, 200, 200}, 2,   0,   .None          },
    .Lava           = { "Lava",          {.Walkable, .Damaging},                                     rl.Color{220, 80,  0,   255}, 2,   2,   .None          },
    .Magic_Lava     = { "Magic Lava",    {.Walkable, .Damaging},                                     rl.Color{160, 0,   220, 255}, 2,   4,   .None          },
    .Wood           = { "Wood",          {.Solid, .Mineable, .Flammable},                            rl.Color{139, 90,  43,  255}, 0,   0,   .Wood_Log      },
    .Leaves         = { "Leaves",        {.Walkable, .Flammable, .Mineable},                         rl.Color{0,   180, 0,   200}, 1,   0,   .Leaf          },
    .Iron_Ore       = { "Iron Ore",      {.Solid, .Mineable},                                        rl.Color{180, 130, 100, 255}, 0,   0,   .Iron_Ore      },
    .Silver_Ore     = { "Silver Ore",    {.Solid, .Mineable},                                        rl.Color{200, 200, 220, 255}, 0,   0,   .Silver_Ore    },
    .Gold_Ore       = { "Gold Ore",      {.Solid, .Mineable},                                        rl.Color{220, 180, 0,   255}, 0,   0,   .Gold_Ore      },
    .Gold_Rare_Ore  = { "Rare Gold Ore", {.Solid, .Mineable},                                        rl.Color{255, 215, 50,  255}, 0,   0,   .Gold_Rare_Ore },
    .Crafting_Bench = { "Crafting Bench",{.Solid, .Placeable, .Mineable},                             rl.Color{160, 120, 60,  255}, 0,   0,   .Crafting_Bench},
    .Tree_Grower    = { "Tree Grower",   {.Solid, .Placeable, .Mineable},                             rl.Color{0,   140, 0,   255}, 0,   0,   .Tree_Grower   },
    .Smelter        = { "Smelter",       {.Solid, .Placeable, .Mineable},                             rl.Color{200, 100, 0,   255}, 0,   0,   .Smelter       },
    .Cave_Entrance  = { "Cave Entrance", {.Walkable},                                                rl.Color{60,  0,   80,  255}, 1,   0,   .None          },
    .Sky_Entrance   = { "Sky Entrance",  {.Walkable},                                                rl.Color{180, 220, 255, 255}, 1,   0,   .None          },
    .Sky_Altar      = { "Sky Altar",     {.Solid, .Placeable, .Mineable},                             rl.Color{200, 200, 255, 255}, 0,   0,   .Sky_Altar     },
    .Cloud          = { "Cloud",         {.Solid, .Mineable},                                        rl.Color{240, 240, 255, 200}, 0,   0,   .None          },
    .Cloud_Ore      = { "Cloud Ore",     {.Solid, .Mineable},                                        rl.Color{200, 220, 255, 255}, 0,   0,   .Cloud_Stone   },
    .Aether_Ore     = { "Aether Ore",    {.Solid, .Mineable},                                        rl.Color{180, 255, 200, 255}, 0,   0,   .Aether_Crystal},
    .Runic_Sky_Ore  = { "Runic Sky Ore", {.Solid, .Mineable},                                        rl.Color{255, 180, 255, 255}, 0,   0,   .Runic_Sky_Ore },
    .Wind_Current   = { "Wind Current",  {.Walkable},                                                rl.Color{200, 240, 255, 150}, 1,   0,   .None          },
    .Void_Sky       = { "Void Sky",      {.Walkable, .Damaging},                                     rl.Color{0,   0,   0,   255}, 1,   1,   .None          },
    .Flower         = { "Flower",        {.Walkable},                                                 rl.Color{255, 220,  50, 255}, 1,   0,   .None          },
    .Dvergr_Forge   = { "Dvergr Forge",  {.Solid, .Placeable, .Mineable},                             rl.Color{105, 105, 125, 255}, 0,   0,   .Dvergr_Forge  },
    .Rune_Altar     = { "Rune Altar",    {.Solid, .Placeable, .Mineable},                             rl.Color{150, 90,  220, 255}, 0,   0,   .Rune_Altar    },
    .Dimension_Spawner = { "Metal Dimension Spawner", {.Solid, .Placeable, .Mineable},                rl.Color{40,  200, 180, 255}, 0,   0,   .Dimension_Spawner },
    .Dimension_Gate    = { "Dimension Gate",    {.Walkable},                                          rl.Color{30,  140, 130, 255}, 1,   0,   .None              },
    .Dimension_Spawner_Gold = { "Gold Dimension Spawner", {.Solid, .Placeable, .Mineable},            rl.Color{235, 195, 60,  255}, 0,   0,   .Dimension_Spawner_Gold },
    .Emerald_Ore    = { "Emerald Ore",   {.Solid, .Mineable},                                        rl.Color{50,  205, 120, 255}, 0,   0,   .Emerald       },
    .Jade_Ore       = { "Jade Ore",      {.Solid, .Mineable},                                        rl.Color{150, 210, 165, 255}, 0,   0,   .Jade          },
    .Diamond_Ore    = { "Diamond Ore",   {.Solid, .Mineable},                                        rl.Color{190, 235, 255, 255}, 0,   0,   .Diamond       },
    .Hel_Gem_Ore    = { "Hel Gem Ore",   {.Solid, .Mineable},                                        rl.Color{200, 30,  70,  255}, 0,   0,   .Hel_Gem       },
}

// ─── Grid Helpers ─────────────────────────────────────────────────────────────

grid_idx :: #force_inline proc(x, y: int) -> int {
    return y * GRID_W + x
}

in_bounds :: #force_inline proc(x, y: int) -> bool {
    return x >= 0 && x < GRID_W && y >= 0 && y < GRID_H
}

get_tile :: #force_inline proc(w: ^World_Grid, x, y: int) -> Tile_Type {
    if !in_bounds(x, y) do return .Stone
    return w.terrain[grid_idx(x, y)]
}

set_tile :: proc(w: ^World_Grid, x, y: int, t: Tile_Type) {
    if !in_bounds(x, y) do return
    w.terrain[grid_idx(x, y)] = t
}

is_solid :: #force_inline proc(w: ^World_Grid, x, y: int) -> bool {
    t := get_tile(w, x, y)
    return .Solid in terrain_table[t].flags
}

// ─── Entity Map ───────────────────────────────────────────────────────────────
//
//  entity_map is a per-tile position index (center tile, last-writer-wins),
//  maintained by the player and enemy updates and used for entity lookups.
//  It is NOT a movement constraint: bodies are continuous AABBs and may
//  transiently overlap, in which case the later writer owns the cell.

entity_map_move :: proc(w: ^World_Grid, id: Entity_ID, from, to: [2]i32) {
    if in_bounds(int(from.x), int(from.y)) {
        idx := grid_idx(int(from.x), int(from.y))
        if w.entity_map[idx] == id do w.entity_map[idx] = INVALID_ENTITY
    }
    if in_bounds(int(to.x), int(to.y)) {
        w.entity_map[grid_idx(int(to.x), int(to.y))] = id
    }
}

entity_map_clear :: proc(w: ^World_Grid, id: Entity_ID, at: [2]i32) {
    if !in_bounds(int(at.x), int(at.y)) do return
    idx := grid_idx(int(at.x), int(at.y))
    if w.entity_map[idx] == id do w.entity_map[idx] = INVALID_ENTITY
}

// ─── World Generation Helpers ─────────────────────────────────────────────────

// Deterministic hash — u32 wraps naturally, no overflow concerns
whash :: proc(n: u32) -> u32 {
    x := n * 2246822519 + 2654435761
    x  = x * 2246822519 + 2654435761
    return x
}

// Crown offsets relative to the top of the trunk
@(rodata)
CROWN_OFFSETS := [][2]int{
    {0, -2},
    {-1, -1}, {0, -1}, {1, -1},
    {-2,  0}, {-1,  0}, {0,  0}, {1,  0}, {2, 0},
    {-1,  1}, {0,   1}, {1,  1},
}

place_tree :: proc(w: ^World_Grid, x, surface_y, height: int) {
    trunk_top := surface_y - height

    // Trunk: wood from trunk_top up to (but not including) surface_y
    for y in trunk_top ..< surface_y {
        set_tile(w, x, y, .Wood)
    }

    // Crown: leaves relative to trunk_top
    for off in CROWN_OFFSETS {
        lx := x + off[0]
        ly := trunk_top + off[1]
        if in_bounds(lx, ly) && get_tile(w, lx, ly) == .Air {
            set_tile(w, lx, ly, .Leaves)
        }
    }
}

// ─── World Constants ──────────────────────────────────────────────────────────

SURFACE_Y  :: 54
CAVE_TOP   :: SURFACE_Y + 6   // solid stone cap between surface and cave
CAVE_BOT   :: GRID_H - 2      // two-row stone floor at world bottom
CAVE_LEFT  :: 1
CAVE_RIGHT :: GRID_W - 1

// ─── Cave Generation Helpers ──────────────────────────────────────────────────

carve_ellipse :: proc(w: ^World_Grid, cx, cy, rx, ry: int) {
    for dy in -ry ..= ry {
        for dx in -rx ..= rx {
            if dx*dx*ry*ry + dy*dy*rx*rx <= rx*rx*ry*ry {
                set_tile(w, cx+dx, cy+dy, .Void)
            }
        }
    }
}

// Cellular automata cave generation for level 1.
// Writes Void cells into the already-stone cave region.
gen_cave_1 :: proc(w: ^World_Grid) {
    // Two working buffers; true = solid stone
    buf_a: [GRID_W * GRID_H]bool
    buf_b: [GRID_W * GRID_H]bool

    // ── 1. Random initial fill (~45% stone) ───────────────────────
    // Double-hash each axis independently then XOR for better 2D distribution
    for y in CAVE_TOP ..< CAVE_BOT {
        for x in CAVE_LEFT ..< CAVE_RIGHT {
            h := whash(u32(x) * 374761393) ~ whash(u32(y) * 668265263)
            buf_a[grid_idx(x, y)] = (h % 100) < 45
        }
    }
    // Solid border so the cave is always enclosed
    for y in CAVE_TOP ..< CAVE_BOT {
        buf_a[grid_idx(CAVE_LEFT,    y)] = true
        buf_a[grid_idx(CAVE_RIGHT-1, y)] = true
    }
    for x in CAVE_LEFT ..< CAVE_RIGHT {
        buf_a[grid_idx(x, CAVE_TOP)]   = true
        buf_a[grid_idx(x, CAVE_BOT-1)] = true
    }

    // ── 2. Cellular automata — 5 smoothing passes ─────────────────
    // Rule: stone cell survives if >=4 solid neighbours
    //       void  cell fills   if  >4 solid neighbours
    src := buf_a[:]
    dst := buf_b[:]
    for _ in 0 ..< 5 {
        for y in CAVE_TOP ..< CAVE_BOT {
            for x in CAVE_LEFT ..< CAVE_RIGHT {
                if x == CAVE_LEFT || x == CAVE_RIGHT-1 ||
                   y == CAVE_TOP  || y == CAVE_BOT-1 {
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

    // ── 3. Apply CA result to terrain ─────────────────────────────
    for y in CAVE_TOP ..< CAVE_BOT {
        for x in CAVE_LEFT ..< CAVE_RIGHT {
            if !src[grid_idx(x, y)] {
                set_tile(w, x, y, .Void)
            }
        }
    }

    // ── 4. Guarantee three open chambers so the cave isn't too tight
    mid_y := (CAVE_TOP + CAVE_BOT) / 2
    carve_ellipse(w, GRID_W / 4,     CAVE_TOP + 15, 9, 6)
    carve_ellipse(w, GRID_W / 2,     mid_y,         10, 7)
    carve_ellipse(w, 3*GRID_W / 4,   CAVE_BOT - 15, 9, 6)

    // ── 5. Entrance shaft: Void column from surface down into cave ─
    ent_x := GRID_W / 2
    for y in SURFACE_Y ..< CAVE_TOP {
        set_tile(w, ent_x,   y, .Void)
        set_tile(w, ent_x+1, y, .Void)
    }
    // Small landing chamber at the bottom of the shaft
    carve_ellipse(w, ent_x, CAVE_TOP + 4, 5, 3)

    // ── 6. Snapshot void cells BEFORE adding formations ───────────
    // Critical: stalactites/stalagmites must only detect ORIGINAL
    // ceilings/floors. Without this, each placed stone becomes a new
    // ceiling and cascades into long vertical lines all the way down.
    void_snap: [GRID_W * GRID_H]bool
    for y in CAVE_TOP ..< CAVE_BOT {
        for x in CAVE_LEFT ..< CAVE_RIGHT {
            void_snap[grid_idx(x, y)] = (get_tile(w, x, y) == .Void)
        }
    }

    // ── 7. Stalactites — fingers from original ceilings only ───────
    for x in CAVE_LEFT ..< CAVE_RIGHT {
        for y in CAVE_TOP + 1 ..< CAVE_BOT - 1 {
            // Original ceiling: this cell was void, cell above was stone
            if void_snap[grid_idx(x, y)] && !void_snap[grid_idx(x, y-1)] {
                h := whash(u32(x) * 54321 + u32(y))
                if h % 4 == 0 {  // 25% of ceiling positions
                    tip := 1 + int((h >> 8) % 2)  // 1–2 tiles
                    for i in 0 ..< tip {
                        ny := y + i
                        if ny < CAVE_BOT - 1 && void_snap[grid_idx(x, ny)] {
                            set_tile(w, x, ny, .Stone)
                        }
                    }
                }
            }
        }
    }

    // ── 8. Stalagmites — fingers from original floors only ─────────
    for x in CAVE_LEFT ..< CAVE_RIGHT {
        for y in CAVE_TOP + 1 ..< CAVE_BOT - 1 {
            // Original floor: this cell was void, cell below was stone
            if void_snap[grid_idx(x, y)] && !void_snap[grid_idx(x, y+1)] {
                h := whash(u32(x) * 98765 + u32(y))
                if h % 5 == 0 {  // 20% of floor positions
                    tip := 1 + int((h >> 8) % 2)  // 1–2 tiles
                    for i in 0 ..< tip {
                        ny := y - i
                        if ny > CAVE_TOP && void_snap[grid_idx(x, ny)] {
                            set_tile(w, x, ny, .Stone)
                        }
                    }
                }
            }
        }
    }

    // ── 9. Ore veins — depth-scaled scatter in stone walls ─────────
    for y in CAVE_TOP ..< CAVE_BOT {
        for x in CAVE_LEFT ..< CAVE_RIGHT {
            if get_tile(w, x, y) != .Stone do continue
            h     := whash(u32(x) * 2654435761 + u32(y) * 1013904223)
            gh    := whash(h)  // fresh bits for the gem roll — per-mille, not per-cent
            depth := y - CAVE_TOP
            switch {
            // Gems first: sparse enough that they steal almost nothing from
            // the metals, and a metal roll must never mask one.
            case depth > 30 && gh % 1000 < 5:
                set_tile(w, x, y, .Emerald_Ore)
            case (h % 100) < 6:
                set_tile(w, x, y, .Iron_Ore)
            case depth > 20 && (h >> 8) % 100 < 3:
                set_tile(w, x, y, .Silver_Ore)
            case depth > 35 && (h >> 16) % 100 < 1:
                set_tile(w, x, y, .Gold_Ore)
            }
        }
    }
}

// ─── World Init ───────────────────────────────────────────────────────────────

world_init :: proc(w: ^World_Grid) {
    // Zero entity map
    for i in 0 ..< GRID_W * GRID_H {
        w.terrain[i]    = .Void
        w.entity_map[i] = INVALID_ENTITY
    }

    // Sky
    for y in 0 ..< SURFACE_Y {
        for x in 0 ..< GRID_W {
            set_tile(w, x, y, .Air)
        }
    }

    // Surface: grass + stone cap
    for x in 0 ..< GRID_W {
        set_tile(w, x, SURFACE_Y,     .Grass)
        set_tile(w, x, SURFACE_Y + 1, .Stone)
        set_tile(w, x, SURFACE_Y + 2, .Stone)
        set_tile(w, x, SURFACE_Y + 3, .Stone)
    }

    // Fill underground with stone (cave gen will carve into this)
    for y in SURFACE_Y + 4 ..< GRID_H {
        for x in 0 ..< GRID_W {
            set_tile(w, x, y, .Stone)
        }
    }

    // Cave level 1
    gen_cave_1(w)

    // Surface decoration: trees and flowers
    CHUNK :: 12
    ent_x := GRID_W / 2
    for chunk in 0 ..< GRID_W / CHUNK {
        h1 := whash(u32(chunk) * 31337)
        h2 := whash(u32(chunk) * 99991)
        h3 := whash(u32(chunk) * 7919)

        if h1 % 10 < 7 {
            tx := chunk * CHUNK + int(h1 % u32(CHUNK))
            tree_height := 3 + int(h2 % 3)
            if abs(tx - ent_x) > 3 && in_bounds(tx, SURFACE_Y) {
                place_tree(w, tx, SURFACE_Y, tree_height)
            }
        }

        flower_count := int(h3 % 3)
        for i in 0 ..< flower_count {
            hf := whash(u32(chunk) * 1000 + u32(i))
            fx := chunk * CHUNK + int(hf % u32(CHUNK))
            fy := SURFACE_Y - 1
            if in_bounds(fx, fy) && get_tile(w, fx, fy) == .Air {
                set_tile(w, fx, fy, .Flower)
            }
        }
    }

    // Cave entrance: a hole in the grass the player can fall into
    set_tile(w, ent_x,   SURFACE_Y, .Cave_Entrance)
    set_tile(w, ent_x+1, SURFACE_Y, .Cave_Entrance)

    // Starter pickaxe resting on the grass, a few steps east of the player's
    // spawn (GRID_W/2 - 8) — the first thing to grab before any mining.
    pick_x   := GRID_W/2 - 4
    set_tile(w, pick_x, SURFACE_Y - 1, .Air)  // clear any decoration on the spot
    pick_idx := grid_idx(pick_x, SURFACE_Y - 1)
    w.items[pick_idx]       = .Pickaxe
    w.item_counts[pick_idx] = 1

    // Portals to cave 2 and the sky, plus Blueprint A
    carve_level0_portals(w)
}
