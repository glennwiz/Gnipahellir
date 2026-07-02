package gnipahellir

// Basic world grid & tile queries (Phase 1)

WORLD_WIDTH  :: 50
WORLD_HEIGHT :: 50
TILE_SIZE    :: 16

Entity_ID :: distinct u32
// Use max u32 as invalid sentinel
INVALID_ENTITY :: cast(Entity_ID)(0xffff_ffff)
PLAYER_ID      :: cast(Entity_ID)(0)
GARM_ID        :: cast(Entity_ID)(1) // Garm the hell hound enemy

// Forward declared enumerations (to refine later)
// Added Wood (tree trunk) and Leaves for basic trees plus Crafting_Bench & Tree_Grower
// Added Void for underground open space (distinct from Air/sky) used in cave layers
// Added underground mineral terrain types: Iron, Silver, Gold, Gold_Rare (very rare variant) and Smelter workstation
// Added Cave_Entrance: the mythical gateway to Gnipahellir's depths
Terrain_Type :: enum u8 { Air, Void, Grass, Stone, Water, Lava, Magic_Lava, Wood, Leaves, Crafting_Bench, Tree_Grower, Iron, Silver, Gold, Gold_Rare, Smelter, Cave_Entrance }
// Basic item id list (expand later). Keep small for now.
// Added Wood_Log and Leaf for tree resource drops; Crafting_Bench & Tree_Grower craftables
// Added Stone_Block & Grass_Turf so mined Stone/Grass can be picked up & placed.
// Added Plank (crafted from Wood_Log) – non-placeable resource.
// Added ore item drops for new mineral terrain plus rare gold and Smelter workstation item
Item_ID      :: enum u16 { None, Sword, Potion_Health, Potion_Mana, Mine_Wand, Wood_Log, Leaf, Crafting_Bench, Tree_Grower, Stone_Block, Grass_Turf, Plank, Iron_Ore, Silver_Ore, Gold_Ore, Gold_Rare_Ore, Smelter, Iron_Bucket, Hell_Key }

// Item categorization for equip rules
Item_Category :: enum u8 { None, Weapon, Tool, Consumable }

item_category :: proc(id: Item_ID) -> Item_Category {
    #partial switch id {
    case .Sword:      return .Weapon
    case .Mine_Wand, .Iron_Bucket:  return .Tool
    case .Potion_Health, .Potion_Mana: return .Consumable
    }
    return .None
}

item_is_equipable :: proc(id: Item_ID) -> bool {
    c := item_category(id)
    return c == .Weapon || c == .Tool
}
// Each tile stores a 16-bit mask of effect flags (fire, slow, poison, etc.)
Tile_Flags :: distinct u16

World_Grid :: struct {
    entities   : [WORLD_WIDTH][WORLD_HEIGHT]Entity_ID,
    terrain    : [WORLD_WIDTH][WORLD_HEIGHT]Terrain_Type,
    items      : [WORLD_WIDTH][WORLD_HEIGHT]Item_ID,
    item_counts: [WORLD_WIDTH][WORLD_HEIGHT]u16,
    tile_flags : [WORLD_WIDTH][WORLD_HEIGHT]Tile_Flags,
    grower_height : [WORLD_WIDTH][WORLD_HEIGHT]u8, // trunk height grown so far (0..10)
    grower_timer  : [WORLD_WIDTH][WORLD_HEIGHT]f32, // time accumulator for growth
    hit_counts    : [WORLD_WIDTH][WORLD_HEIGHT]u8, // generic hit accumulation for hand mining
    // Lava flow timing (per-tile) - only used for Lava but arrays kept parallel for simplicity
    lava_elapsed  : [WORLD_WIDTH][WORLD_HEIGHT]f32,
    lava_target   : [WORLD_WIDTH][WORLD_HEIGHT]f32, // next spread time threshold 1-3s
}

// Copy full world grid (simple struct field-wise copy)
world_copy :: proc(dst: ^World_Grid, src: ^World_Grid) {
    for x in 0..<WORLD_WIDTH {
        for y in 0..<WORLD_HEIGHT {
            dst.entities[x][y]    = src.entities[x][y]
            dst.terrain[x][y]     = src.terrain[x][y]
            dst.items[x][y]       = src.items[x][y]
            dst.item_counts[x][y] = src.item_counts[x][y]
            dst.tile_flags[x][y]  = src.tile_flags[x][y]
            dst.grower_height[x][y] = src.grower_height[x][y]
            dst.grower_timer[x][y]  = src.grower_timer[x][y]
            dst.hit_counts[x][y]    = src.hit_counts[x][y]
            dst.lava_elapsed[x][y]  = src.lava_elapsed[x][y]
            dst.lava_target[x][y]   = src.lava_target[x][y]
        }
    }
}

// --- Building helpers ---
item_is_placeable :: proc(id: Item_ID) -> bool {
    #partial switch id {
    case .Wood_Log, .Leaf, .Crafting_Bench, .Tree_Grower, .Stone_Block, .Grass_Turf, .Smelter: return true
    case .Iron_Ore, .Silver_Ore, .Gold_Ore, .Gold_Rare_Ore: return true
    }
    return false
}

item_place_terrain :: proc(id: Item_ID) -> Terrain_Type {
    #partial switch id {
    case .Wood_Log: return .Wood
    case .Leaf: return .Leaves
    case .Crafting_Bench: return .Crafting_Bench
    case .Tree_Grower: return .Tree_Grower
    case .Stone_Block: return .Stone
    case .Grass_Turf: return .Grass
    case .Smelter: return .Smelter
    case .Iron_Ore: return .Iron
    case .Silver_Ore: return .Silver
    case .Gold_Ore: return .Gold
    case .Gold_Rare_Ore: return .Gold_Rare
    }
    return .Air
}

// Global world helpers
bounds_check :: proc(x, y: int) -> bool {
    return x >= 0 && y >= 0 && x < WORLD_WIDTH && y < WORLD_HEIGHT
}

// Query if any tile of a given terrain type exists in the world (simple O(W*H) scan)
world_has_terrain :: proc(world: ^World_Grid, t: Terrain_Type) -> bool {
    for x in 0..<WORLD_WIDTH {
        for y in 0..<WORLD_HEIGHT {
            if world.terrain[x][y] == t { return true }
        }
    }
    return false
}

// Basic walkability (expand with terrain table in Phase 2)
tile_is_solid :: proc(world: ^World_Grid, x, y: int) -> bool {
    if !bounds_check(x, y) do return true
    t := world.terrain[x][y]
    // Solid terrain types (expand later). Wood (trunk) is solid; Leaves are not (allow passing through canopy)
    // Grass now treated as solid ground like Stone
    // Cave_Entrance is solid but has special interaction logic for descending
    return t == .Stone || t == .Grass || t == .Water || t == .Lava || t == .Magic_Lava || t == .Wood || t == .Crafting_Bench || t == .Tree_Grower || t == .Iron || t == .Silver || t == .Gold || t == .Gold_Rare || t == .Smelter || t == .Cave_Entrance
}

tile_is_walkable :: proc(world: ^World_Grid, x, y: int) -> bool {
    if !bounds_check(x, y) do return false
    if tile_is_solid(world, x, y) do return false
    if world.entities[x][y] != INVALID_ENTITY do return false
    return true
}

// Air tile with no entity (gravity passes through)
tile_is_empty_air :: proc(world: ^World_Grid, x, y: int) -> bool {
    if !bounds_check(x, y) do return false
    return (world.terrain[x][y] == .Air || world.terrain[x][y] == .Void) && world.entities[x][y] == INVALID_ENTITY
}

// Update all tree growers; called each frame with dt seconds
growers_update :: proc(world: ^World_Grid, dt: f32) {
    for x in 0..<WORLD_WIDTH {
        for y in 0..<WORLD_HEIGHT {
            if world.terrain[x][y] != .Tree_Grower {
                continue
            }
            MAX_TREE_HEIGHT :: 10
            if world.grower_height[x][y] >= MAX_TREE_HEIGHT {
                continue
            }
            world.grower_timer[x][y] += dt
            if world.grower_timer[x][y] >= 2.0 {
                world.grower_timer[x][y] -= 2.0
                next_height := cast(int)world.grower_height[x][y] + 1
                target_y := y - next_height
                if target_y >= 0 && world.terrain[x][target_y] == .Air {
                    world.terrain[x][target_y] = .Wood
                    world.grower_height[x][y] += 1
                    // Every 2nd trunk segment (even height) sprout horizontal leaves
                    // Height counting starts at 1 for first placed trunk block, so check new height value
                    h_now := world.grower_height[x][y]
                    if (h_now % 2) == 0 {
                        // Place leaves left & right (and a bit above) of this trunk segment
                        offsets := [2]int{-1, 1}
                        for dx in offsets {
                            lx := x + dx
                            ly := target_y
                            if bounds_check(lx, ly) && world.terrain[lx][ly] == .Air do world.terrain[lx][ly] = .Leaves
                            ly_above := ly - 1
                            if bounds_check(lx, ly_above) && world.terrain[lx][ly_above] == .Air do world.terrain[lx][ly_above] = .Leaves
                        }
                    }
                    // If reached max height, generate a small canopy (3x3 blob) above & around top
                    if h_now == MAX_TREE_HEIGHT {
                        top_y := target_y
                        for cx := -1; cx <= 1; cx += 1 {
                            for cy := -1; cy <= 1; cy += 1 {
                                px := x + cx
                                py := top_y + cy - 1 // shift canopy one tile up
                                if !bounds_check(px, py) do continue
                                if px == x && py == top_y do continue // keep trunk clear
                                if world.terrain[px][py] == .Air do world.terrain[px][py] = .Leaves
                            }
                        }
                    }
                } else {
                    // Blocked -> mark as complete to stop attempts
                    world.grower_height[x][y] = MAX_TREE_HEIGHT
                }
            }
        }
    }
}
