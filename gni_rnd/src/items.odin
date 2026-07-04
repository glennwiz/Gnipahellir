package game

import rl "vendor:raylib/v55"

// ─── Item Behavior Table ──────────────────────────────────────────────────────

MAX_STACK :: 99

Item_Info :: struct {
    name:       string,
    color:      rl.Color,
    place_tile: Tile_Type,   // .Air = not placeable
}

@(rodata)
item_table := [Item]Item_Info{
    .None           = { "None",            {0,   0,   0,   0  }, .Air },
    .Sword          = { "Sword",           {200, 200, 210, 255}, .Air },
    .Potion_Health  = { "Health Potion",   {220, 40,  40,  255}, .Air },
    .Potion_Mana    = { "Mana Potion",     {40,  40,  220, 255}, .Air },
    .Mine_Wand      = { "Mine Wand",       {160, 60,  200, 255}, .Air },
    .Wood_Log       = { "Wood Log",        {139, 90,  43,  255}, .Wood },
    .Leaf           = { "Leaf",            {30,  160, 30,  255}, .Leaves },
    .Stone_Block    = { "Stone Block",     {128, 128, 128, 255}, .Stone },
    .Grass_Turf     = { "Grass Turf",      {34,  139, 34,  255}, .Grass },
    .Plank          = { "Plank",           {180, 140, 90,  255}, .Wood },
    .Iron_Ore       = { "Iron Ore",        {180, 130, 100, 255}, .Air },
    .Silver_Ore     = { "Silver Ore",      {200, 200, 220, 255}, .Air },
    .Gold_Ore       = { "Gold Ore",        {220, 180, 0,   255}, .Air },
    .Gold_Rare_Ore  = { "Rare Gold Ore",   {255, 215, 50,  255}, .Air },
    .Crafting_Bench = { "Crafting Bench",  {160, 120, 60,  255}, .Crafting_Bench },
    .Tree_Grower    = { "Tree Grower",     {0,   140, 0,   255}, .Tree_Grower },
    .Smelter        = { "Smelter",         {200, 100, 0,   255}, .Smelter },
    .Iron_Bucket    = { "Iron Bucket",     {120, 120, 140, 255}, .Air },
    .Hell_Key       = { "Hell Key",        {220, 30,  60,  255}, .Air },
    .Blueprint_A    = { "Blueprint A",     {80,  160, 255, 255}, .Air },
    .Blueprint_B    = { "Blueprint B",     {80,  160, 255, 255}, .Air },
    .Blueprint_C    = { "Blueprint C",     {80,  160, 255, 255}, .Air },
    .Sky_Altar      = { "Sky Altar",       {200, 200, 255, 255}, .Sky_Altar },
    .Cloud_Stone    = { "Cloud Stone",     {200, 220, 255, 255}, .Air },
    .Aether_Crystal = { "Aether Crystal",  {180, 255, 200, 255}, .Air },
    .Runic_Sky_Ore  = { "Runic Sky Ore",   {255, 180, 255, 255}, .Air },
}

// ─── Inventory Operations ─────────────────────────────────────────────────────

// Insert items, stacking onto existing slots first.  Returns false if the
// inventory could not hold everything (whatever fit stays inserted).
inventory_insert :: proc(inv: ^Inventory, item: Item, count: int = 1) -> bool {
    left := count
    for &s in inv.slots {
        if left == 0 do break
        if s.item == item && s.count > 0 && s.count < MAX_STACK {
            take := min(MAX_STACK - s.count, left)
            s.count += take
            left    -= take
        }
    }
    for &s in inv.slots {
        if left == 0 do break
        if s.item == .None || s.count == 0 {
            take := min(MAX_STACK, left)
            s.item  = item
            s.count = take
            left   -= take
        }
    }
    return left == 0
}

inventory_count :: proc(inv: ^Inventory, item: Item) -> int {
    total := 0
    for s in inv.slots {
        if s.item == item do total += s.count
    }
    return total
}

inventory_remove :: proc(inv: ^Inventory, item: Item, count: int) -> bool {
    if inventory_count(inv, item) < count do return false
    left := count
    for &s in inv.slots {
        if s.item != item do continue
        take := min(s.count, left)
        s.count -= take
        left    -= take
        if s.count == 0 do s.item = .None
        if left == 0 do break
    }
    return true
}
