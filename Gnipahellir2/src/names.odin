package gnipahellir

// Centralized item and terrain names for UI/logging. Pure helpers.

item_name :: proc(id: Item_ID) -> cstring {
    #partial switch id {
    case .Sword: return "Sword"
    case .Potion_Health: return "Health Potion"
    case .Potion_Mana: return "Mana Potion"
    case .Mine_Wand: return "Mine Wand"
    case .Wood_Log: return "Wood"
    case .Leaf: return "Leaf"
    case .Crafting_Bench: return "Craft Bench"
    case .Tree_Grower: return "Tree Grower"
    case .Stone_Block: return "Stone"
    case .Grass_Turf: return "Grass"
    case .Plank: return "Plank"
    case .Iron_Ore: return "Iron Ore"
    case .Silver_Ore: return "Silver Ore"
    case .Gold_Ore: return "Gold Ore"
    case .Gold_Rare_Ore: return "Rare Gold Ore"
    case .Smelter: return "Smelter"
    case .Iron_Bucket: return "Iron Bucket"
    case .Hell_Key: return "Hell Key"
    }
    return "?"
}

terrain_name :: proc(t: Terrain_Type) -> cstring {
    switch t {
    case .Air: return "Air"
    case .Void: return "Void"
    case .Grass: return "Grass"
    case .Stone: return "Stone"
    case .Water: return "Water"
    case .Lava: return "Lava"
    case .Magic_Lava: return "Magic Lava"
    case .Wood: return "Wood"
    case .Leaves: return "Leaves"
    case .Crafting_Bench: return "Craft Bench"
    case .Tree_Grower: return "Tree Grower"
    case .Iron: return "Iron"
    case .Silver: return "Silver"
    case .Gold: return "Gold"
    case .Gold_Rare: return "Gold (Rare)"
    case .Smelter: return "Smelter"
    case .Cave_Entrance: return "Gnipahellir"
    }
    return "?"
}


