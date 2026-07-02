package gnipahellir

// Simple crafting recipe system

Craft_Ingredient :: struct { id: Item_ID, count: u16 }
Craft_Recipe :: struct {
    product : Item_ID,
    amount  : u16, // produced count
    ingredients : []Craft_Ingredient,
}

// Static recipe list and backing ingredient arrays so slices remain valid
craft_recipes : [5]Craft_Recipe
bench_ings    : [1]Craft_Ingredient
grower_ings   : [2]Craft_Ingredient
plank_ings    : [1]Craft_Ingredient
smelter_ings  : [3]Craft_Ingredient
bucket_ings   : [1]Craft_Ingredient

init_crafting_recipes :: proc() {
    bench_ings[0] = Craft_Ingredient{ id = .Wood_Log, count = 2 }
    grower_ings[0] = Craft_Ingredient{ id = .Wood_Log, count = 2 }
    grower_ings[1] = Craft_Ingredient{ id = .Leaf, count = 2 }
    plank_ings[0] = Craft_Ingredient{ id = .Wood_Log, count = 1 }
    craft_recipes[0] = Craft_Recipe{ product = .Crafting_Bench, amount = 1, ingredients = bench_ings[:] }
    craft_recipes[1] = Craft_Recipe{ product = .Tree_Grower, amount = 1, ingredients = grower_ings[:] }
    craft_recipes[2] = Craft_Recipe{ product = .Plank, amount = 4, ingredients = plank_ings[:] }
    // Smelter cost: 10 Wood Logs, 3 Iron Ore, 1 Silver Ore
    smelter_ings[0] = Craft_Ingredient{ id = .Wood_Log, count = 10 }
    smelter_ings[1] = Craft_Ingredient{ id = .Iron_Ore, count = 3 }
    smelter_ings[2] = Craft_Ingredient{ id = .Silver_Ore, count = 1 }
    craft_recipes[3] = Craft_Recipe{ product = .Smelter, amount = 1, ingredients = smelter_ings[:] }
    // Iron Bucket cost: 3 Iron Ore
    bucket_ings[0] = Craft_Ingredient{ id = .Iron_Ore, count = 3 }
    craft_recipes[4] = Craft_Recipe{ product = .Iron_Bucket, amount = 1, ingredients = bucket_ings[:] }
}

find_recipe_index :: proc(product: Item_ID) -> int {
    for i in 0..<len(craft_recipes) {
        if craft_recipes[i].product == product do return i
    }
    return -1
}

can_craft :: proc(inv: ^Inventory, r: ^Craft_Recipe) -> bool {
    for ing in r.ingredients {
        have := 0
        for i in 0..<INV_MAX_SLOTS {
            s := inv.slots[i]
            if s.id == ing.id { have += cast(int)s.count }
        }
        if have < cast(int)ing.count do return false
    }
    return true
}

consume_ingredients :: proc(inv: ^Inventory, r: ^Craft_Recipe) {
    for ing in r.ingredients {
        need := cast(int)ing.count
        for i in 0..<INV_MAX_SLOTS {
            if need <= 0 do break
            s := &inv.slots[i]
            if s.id != ing.id do continue
            take := need
            if cast(int)s.count < take { take = cast(int)s.count }
            s.count -= cast(u16)take
            need -= take
            if s.count == 0 { s.id = .None }
        }
    }
}

add_item_to_inventory :: proc(inv: ^Inventory, id: Item_ID, count: int) {
    if count <= 0 do return
    for i in 0..<INV_MAX_SLOTS {
        if inv.slots[i].id == id {
            inv.slots[i].count += cast(u16)count
            return
        }
    }
    for i in 0..<INV_MAX_SLOTS {
        if inv.slots[i].id == .None {
            inv.slots[i] = Item_Stack{ id = id, count = cast(u16)count }
            return
        }
    }
}

craft_attempt :: proc(game: ^Game_State, product: Item_ID) {
    // Convert direct craft into a request handled in process_events
    _ = event_queue_push(&game.events, Event{ type = .Craft_Request, source_id = PLAYER_ID, target_id = PLAYER_ID, data = Craft_Request{ product = product } })
}
