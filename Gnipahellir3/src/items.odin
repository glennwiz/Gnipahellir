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
    .None             = { "None",             {0,   0,   0,   0  }, .Air },
    .Sword            = { "Sword",            {200, 200, 210, 255}, .Air },
    .Pickaxe          = { "Pickaxe",          {150, 110, 70,  255}, .Air },
    .Potion_Health    = { "Health Potion",    {220, 40,  40,  255}, .Air },
    .Potion_Mana      = { "Mana Potion",      {40,  40,  220, 255}, .Air },
    .Mine_Wand        = { "Mine Wand",        {160, 60,  200, 255}, .Air },
    .Mine_Wand_Silver = { "Silver Mine Wand", {210, 210, 235, 255}, .Air },
    .Mine_Wand_Gold   = { "Gold Mine Wand",   {235, 195, 60,  255}, .Air },
    .Wood_Log       = { "Wood Log",        {139, 90,  43,  255}, .Wood },
    .Leaf           = { "Leaf",            {30,  160, 30,  255}, .Leaves },
    .Stone_Block    = { "Stone Block",     {128, 128, 128, 255}, .Stone },
    .Grass_Turf     = { "Grass Turf",      {34,  139, 34,  255}, .Grass },
    .Plank          = { "Plank",           {180, 140, 90,  255}, .Wood },
    .Iron_Ore       = { "Iron Ore",        {180, 130, 100, 255}, .Air },
    .Silver_Ore     = { "Silver Ore",      {200, 200, 220, 255}, .Silver_Ore },
    .Gold_Ore       = { "Gold Ore",        {220, 180, 0,   255}, .Gold_Ore   },
    .Gold_Rare_Ore  = { "Rare Gold Ore",   {255, 215, 50,  255}, .Air },
    .Crafting_Bench = { "Crafting Bench",  {160, 120, 60,  255}, .Crafting_Bench },
    .Tree_Grower    = { "Tree Grower",     {0,   140, 0,   255}, .Tree_Grower },
    .Smelter        = { "Smelter",         {200, 100, 0,   255}, .Smelter },
    .Iron_Bucket    = { "Iron Bucket",     {120, 120, 140, 255}, .Air },
    .Hell_Key       = { "Hell Key",        {220, 30,  60,  255}, .Air },
    .Blueprint_A    = { "Blueprint A",     {80,  160, 255, 255}, .Air },
    .Blueprint_B    = { "Blueprint B",     {80,  160, 255, 255}, .Air },
    .Blueprint_C    = { "Blueprint C",     {80,  160, 255, 255}, .Air },
    .Sky_Blueprint  = { "Sky Blueprint",   {120, 200, 255, 255}, .Air },
    .Sky_Altar      = { "Sky Altar",       {200, 200, 255, 255}, .Sky_Altar },
    .Cloud_Stone    = { "Cloud Stone",     {200, 220, 255, 255}, .Air },
    .Aether_Crystal = { "Aether Crystal",  {180, 255, 200, 255}, .Air },
    .Runic_Sky_Ore  = { "Runic Sky Ore",   {255, 180, 255, 255}, .Air },
    .Aether_Charm   = { "Aether Charm",    {150, 255, 210, 255}, .Air },
    .Silver_Sword   = { "Silver Sword",    {210, 210, 235, 255}, .Air },
    .Gold_Sword     = { "Gold Sword",      {235, 195, 60,  255}, .Air },
    .Iron_Helm         = { "Iron Helm",         {150, 150, 165, 255}, .Air },
    .Silver_Helm       = { "Silver Helm",       {205, 205, 225, 255}, .Air },
    .Gold_Helm         = { "Gold Helm",         {235, 195, 60,  255}, .Air },
    .Iron_Chestplate   = { "Iron Chestplate",   {150, 150, 165, 255}, .Air },
    .Silver_Chestplate = { "Silver Chestplate", {205, 205, 225, 255}, .Air },
    .Gold_Chestplate   = { "Gold Chestplate",   {235, 195, 60,  255}, .Air },
    .Iron_Gauntlets    = { "Iron Gauntlets",    {150, 150, 165, 255}, .Air },
    .Silver_Gauntlets  = { "Silver Gauntlets",  {205, 205, 225, 255}, .Air },
    .Gold_Gauntlets    = { "Gold Gauntlets",    {235, 195, 60,  255}, .Air },
    .Iron_Greaves      = { "Iron Greaves",      {150, 150, 165, 255}, .Air },
    .Silver_Greaves    = { "Silver Greaves",    {205, 205, 225, 255}, .Air },
    .Gold_Greaves      = { "Gold Greaves",      {235, 195, 60,  255}, .Air },
    .Iron_Boots        = { "Iron Boots",        {150, 150, 165, 255}, .Air },
    .Silver_Boots      = { "Silver Boots",      {205, 205, 225, 255}, .Air },
    .Gold_Boots        = { "Gold Boots",        {235, 195, 60,  255}, .Air },
    .Dvergr_Forge      = { "Dvergr Forge",      {105, 105, 125, 255}, .Dvergr_Forge },
    .Rune_Altar        = { "Rune Altar",        {150, 90,  220, 255}, .Rune_Altar },
    .Mine_Wand_Runic   = { "Runic Mine Wand",   {230, 150, 255, 255}, .Air },
    .Runic_Sword       = { "Runic Sword",       {210, 130, 255, 255}, .Air },
    .Runic_Helm        = { "Runic Helm",        {210, 130, 255, 255}, .Air },
    .Runic_Chestplate  = { "Runic Chestplate",  {210, 130, 255, 255}, .Air },
    .Runic_Gauntlets   = { "Runic Gauntlets",   {210, 130, 255, 255}, .Air },
    .Runic_Greaves     = { "Runic Greaves",     {210, 130, 255, 255}, .Air },
    .Runic_Boots       = { "Runic Boots",       {210, 130, 255, 255}, .Air },
    .Iron_Bar          = { "Iron Bar",          {172, 172, 188, 255}, .Air },
    .Silver_Bar        = { "Silver Bar",        {222, 222, 240, 255}, .Air },
    .Gold_Bar          = { "Gold Bar",          {245, 205, 70,  255}, .Air },
    .Dimension_Spawner      = { "Metal Dimension Spawner", {40,  200, 180, 255}, .Dimension_Spawner },
    .Dimension_Spawner_Gold = { "Gold Dimension Spawner",  {235, 195, 60,  255}, .Dimension_Spawner_Gold },
    .Emerald           = { "Emerald",           {60,  220, 130, 255}, .Air },
    .Jade              = { "Jade",              {150, 210, 165, 255}, .Air },
    .Diamond           = { "Diamond",           {190, 235, 255, 255}, .Air },
    .Hel_Gem           = { "Hel Gem",           {220, 50,  80,  255}, .Air },
    .Auto_Miner        = { "Auto-Miner",        {90,  200, 190, 255}, .Auto_Miner },
    .Dimension_Spawner_Runic = { "Runic Dimension Spawner", {200, 120, 255, 255}, .Dimension_Spawner_Runic },
}

is_blueprint :: proc(it: Item) -> bool {
    return it == .Blueprint_A || it == .Blueprint_B || it == .Blueprint_C || it == .Sky_Blueprint
}

// ─── Equipment & Stats ────────────────────────────────────────────────────────
//
//  Which slot an item occupies (.None = not equippable) and what it grants.
//  New gear = one entry in each table; no code changes elsewhere.

@(rodata)
item_equip_slot := #partial [Item]Equip_Slot{
    .Sword        = .Weapon,
    .Silver_Sword = .Weapon,
    .Gold_Sword   = .Weapon,
    .Runic_Sword  = .Weapon,
    .Aether_Charm = .Charm,
    .Iron_Helm       = .Head,  .Silver_Helm       = .Head,  .Gold_Helm       = .Head,  .Runic_Helm       = .Head,
    .Iron_Chestplate = .Chest, .Silver_Chestplate = .Chest, .Gold_Chestplate = .Chest, .Runic_Chestplate = .Chest,
    .Iron_Gauntlets  = .Hands, .Silver_Gauntlets  = .Hands, .Gold_Gauntlets  = .Hands, .Runic_Gauntlets  = .Hands,
    .Iron_Greaves    = .Legs,  .Silver_Greaves    = .Legs,  .Gold_Greaves    = .Legs,  .Runic_Greaves    = .Legs,
    .Iron_Boots      = .Feet,  .Silver_Boots      = .Feet,  .Gold_Boots      = .Feet,  .Runic_Boots      = .Feet,
}

@(rodata)
item_stat_bonus := #partial [Item][Stat]i32{
    .Sword        = #partial {.Attack = SWORD_DAMAGE},
    .Silver_Sword = #partial {.Attack = 3},
    .Gold_Sword   = #partial {.Attack = 5},
    .Aether_Charm = #partial {.Speed = 3},
    // Helm/Greaves grow the health pool, the chestplate blunts blows,
    // gauntlets add swing weight, boots add stride.
    .Iron_Helm       = #partial {.Max_HP = 1},
    .Silver_Helm     = #partial {.Max_HP = 2},
    .Gold_Helm       = #partial {.Max_HP = 4},
    .Iron_Chestplate   = #partial {.Defense = 1},
    .Silver_Chestplate = #partial {.Defense = 2},
    .Gold_Chestplate   = #partial {.Defense = 3},
    .Iron_Gauntlets   = #partial {.Attack = 1},
    .Silver_Gauntlets = #partial {.Attack = 1},
    .Gold_Gauntlets   = #partial {.Attack = 2},
    .Iron_Greaves   = #partial {.Max_HP = 1},
    .Silver_Greaves = #partial {.Max_HP = 2},
    .Gold_Greaves   = #partial {.Max_HP = 3},
    .Iron_Boots   = #partial {.Speed = 1},
    .Silver_Boots = #partial {.Speed = 2},
    .Gold_Boots   = #partial {.Speed = 3},
    // Runic: the endgame rung above gold.
    .Runic_Sword      = #partial {.Attack = 8},
    .Runic_Helm       = #partial {.Max_HP = 6},
    .Runic_Chestplate = #partial {.Defense = 5},
    .Runic_Gauntlets  = #partial {.Attack = 3},
    .Runic_Greaves    = #partial {.Max_HP = 5},
    .Runic_Boots      = #partial {.Speed = 4},
}

@(rodata)
player_base_stats := [Stat]i32{
    .Attack  = 0,   // bare hands swing nothing — a weapon must be equipped
    .Defense = 0,
    .Max_HP  = 10,
    .Speed   = i32(MOVE_SPEED),   // base stride; boots add on top
}

// Total for one stat: base + every equipped item's bonus.
player_stat :: proc(p: ^Player, stat: Stat) -> i32 {
    total := player_base_stats[stat]
    for slot in Equip_Slot {
        if slot == .None do continue
        if it := p.equipment[slot]; it != .None {
            total += item_stat_bonus[it][stat]
        }
    }
    return total
}

// Max HP follows the stat; current hp is clamped, never raised for free.
player_apply_max_hp :: proc(p: ^Player) {
    p.hp_max = int(player_stat(p, .Max_HP))
    p.hp     = min(p.hp, p.hp_max)
}

// Equip from an inventory slot: the item leaves the bag; whatever held the
// equip slot returns to it.  No-op for non-equippable or empty slots, and
// refused (nothing lost) when the displaced gear can't fit back in the bag.
player_equip :: proc(gs: ^Game_State, inv_slot: int) {
    p := &gs.player
    s := &p.inventory.slots[inv_slot]
    eq := item_equip_slot[s.item]
    if eq == .None || s.count <= 0 do return

    item := s.item
    prev := p.equipment[eq]
    s.count -= 1
    if s.count == 0 do s.item = .None
    if prev != .None && !inventory_insert(&p.inventory, prev, 1) {
        s.item   = item   // no room for the displaced gear: undo the take
        s.count += 1
        return
    }
    p.equipment[eq] = item
    player_apply_max_hp(p)
    gs.save_dirty = true
    log_action(gs, "Player equips %s", item_table[item].name)
}

// Unequip back into the bag; refused when the bag can't hold the item.
player_unequip :: proc(gs: ^Game_State, slot: Equip_Slot) {
    p := &gs.player
    it := p.equipment[slot]
    if it == .None do return
    if !inventory_insert(&p.inventory, it, 1) do return

    p.equipment[slot] = .None
    player_apply_max_hp(p)
    gs.save_dirty = true
    log_action(gs, "Player unequips %s", item_table[it].name)
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
