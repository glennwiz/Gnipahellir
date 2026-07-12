package game

// ─── Crafting ─────────────────────────────────────────────────────────────────
//
//  Static recipe table.  Hand recipes work anywhere; bench recipes need a
//  Crafting_Bench tile within BENCH_RANGE of the player.  Crafting flows
//  through events: input pushes Craft_Request (payload = recipe index),
//  handle_craft_request validates, consumes and inserts.

BENCH_RANGE :: 3  // tiles, chebyshev

Ingredient :: struct {
    item:  Item,
    count: int,
}

Recipe :: struct {
    result:       Item,
    result_count: int,
    needs_bench:  bool,
    ingredients:  [3]Ingredient,   // .None entries are unused
}

@(rodata)
recipe_table := [?]Recipe{
    { .Plank,          4, false, {{.Wood_Log, 1},    {},               {}} },
    { .Crafting_Bench, 1, false, {{.Plank, 4},       {},               {}} },
    { .Smelter,        1, true,  {{.Stone_Block, 8}, {.Iron_Ore, 2},   {}} },
    { .Tree_Grower,    1, true,  {{.Plank, 2},       {.Leaf, 4},       {}} },
    { .Iron_Bucket,    1, true,  {{.Iron_Ore, 3},    {},               {}} },
    { .Sky_Altar,      1, true,  {{.Stone_Block, 6}, {.Plank, 4},      {}} },
    { .Sword,          1, true,  {{.Iron_Ore, 2},    {.Plank, 1},      {}} },
    // The miner's ladder: each wand tier consumes the one before it.
    { .Mine_Wand,        1, true, {{.Plank, 2},            {.Iron_Ore, 4},   {}} },
    { .Mine_Wand_Silver, 1, true, {{.Mine_Wand, 1},        {.Silver_Ore, 6}, {}} },
    { .Mine_Wand_Gold,   1, true, {{.Mine_Wand_Silver, 1}, {.Gold_Ore, 6},   {}} },
    // Weapon ladder — same pattern as the wands.
    { .Silver_Sword,   1, true,  {{.Sword, 1},        {.Silver_Ore, 6}, {}} },
    { .Gold_Sword,     1, true,  {{.Silver_Sword, 1}, {.Gold_Ore, 6},   {}} },
    // Armor: forge iron pieces, then upgrade each through silver into gold
    // (right-click a piece in the bag to wear it).
    { .Iron_Helm,       1, true, {{.Iron_Ore, 3}, {.Plank, 1}, {}} },
    { .Iron_Chestplate, 1, true, {{.Iron_Ore, 5}, {.Plank, 2}, {}} },
    { .Iron_Gauntlets,  1, true, {{.Iron_Ore, 2}, {.Plank, 1}, {}} },
    { .Iron_Greaves,    1, true, {{.Iron_Ore, 4}, {.Plank, 1}, {}} },
    { .Iron_Boots,      1, true, {{.Iron_Ore, 2}, {.Plank, 1}, {}} },
    { .Silver_Helm,       1, true, {{.Iron_Helm, 1},       {.Silver_Ore, 4}, {}} },
    { .Silver_Chestplate, 1, true, {{.Iron_Chestplate, 1}, {.Silver_Ore, 6}, {}} },
    { .Silver_Gauntlets,  1, true, {{.Iron_Gauntlets, 1},  {.Silver_Ore, 3}, {}} },
    { .Silver_Greaves,    1, true, {{.Iron_Greaves, 1},    {.Silver_Ore, 5}, {}} },
    { .Silver_Boots,      1, true, {{.Iron_Boots, 1},      {.Silver_Ore, 3}, {}} },
    { .Gold_Helm,       1, true, {{.Silver_Helm, 1},       {.Gold_Ore, 4}, {}} },
    { .Gold_Chestplate, 1, true, {{.Silver_Chestplate, 1}, {.Gold_Ore, 6}, {}} },
    { .Gold_Gauntlets,  1, true, {{.Silver_Gauntlets, 1},  {.Gold_Ore, 3}, {}} },
    { .Gold_Greaves,    1, true, {{.Silver_Greaves, 1},    {.Gold_Ore, 5}, {}} },
    { .Gold_Boots,      1, true, {{.Silver_Boots, 1},      {.Gold_Ore, 3}, {}} },
    // Trinkets
    { .Aether_Charm,   1, true,  {{.Aether_Crystal, 3}, {.Gold_Ore, 1}, {}} },
}

player_near_bench :: proc(gs: ^Game_State) -> bool {
    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            if get_tile(&gs.world, cx+dx, cy+dy) == .Crafting_Bench do return true
        }
    }
    return false
}

recipe_craftable :: proc(gs: ^Game_State, r: ^Recipe) -> bool {
    if r.needs_bench && !player_near_bench(gs) do return false
    for ing in r.ingredients {
        if ing.item == .None do continue
        if inventory_count(&gs.player.inventory, ing.item) < ing.count do return false
    }
    return true
}

handle_craft_request :: proc(gs: ^Game_State, e: Event) {
    if gs.player.dead do return
    idx := int(e.payload.int_val)
    if idx < 0 || idx >= len(recipe_table) do return
    r := &recipe_table[idx]
    if !recipe_craftable(gs, r) do return

    for ing in r.ingredients {
        if ing.item == .None do continue
        inventory_remove(&gs.player.inventory, ing.item, ing.count)
    }
    inventory_insert(&gs.player.inventory, r.result, r.result_count)
    eq_push(&gs.events, Event{type = .Craft_Complete, payload = {int_val = i32(r.result)}})
    log_action(gs, "Player crafts %v x%d", r.result, r.result_count)
}
