package game

// ─── Crafting ─────────────────────────────────────────────────────────────────
//
//  Static recipe table.  Hand recipes (.None) work anywhere; station recipes
//  need their station's tile within BENCH_RANGE of the player.  Stations form
//  a ladder — Bench (iron) → Dvergr Forge (silver/gold) → Rune Altar (sky
//  magic) — but higher stations do not include lower ones.  Crafting flows
//  through events: input pushes Craft_Request (payload = recipe index),
//  handle_craft_request validates, consumes and inserts.

BENCH_RANGE :: 3  // tiles, chebyshev

// Not itself saved (only lives in transient UI_State), but keep it
// append-only anyway: it indexes station_tile/station_title below and
// world.odin's terrain_table keys off individual Tile_Type values that
// mirror this list — reordering would desync those lookups even without
// touching the save format.
Station :: enum u8 {
    None,        // craftable by hand, anywhere
    Bench,
    Forge,
    Rune_Altar,
}

@(rodata)
station_tile := [Station]Tile_Type{
    .None       = .Air,
    .Bench      = .Crafting_Bench,
    .Forge      = .Dvergr_Forge,
    .Rune_Altar = .Rune_Altar,
}


// Window title and interact-prompt name, per station.
@(rodata)
station_title := [Station]cstring{
    .None       = "CRAFTING",
    .Bench      = "CRAFTING BENCH",
    .Forge      = "DVERGR FORGE",
    .Rune_Altar = "RUNE ALTAR",
}

Ingredient :: struct {
    item:  Item,
    count: int,
}

Recipe :: struct {
    result:       Item,
    result_count: int,
    station:      Station,
    ingredients:  [3]Ingredient,   // .None entries are unused
}

@(rodata)
recipe_table := [?]Recipe{
    { .Plank,          4, .None,  {{.Wood_Log, 1},    {},               {}} },
    { .Crafting_Bench, 1, .None,  {{.Plank, 4},       {},               {}} },
    { .Smelter,        1, .Bench, {{.Stone_Block, 8}, {.Iron_Ore, 2},   {}} },
    { .Tree_Grower,    1, .Bench, {{.Plank, 2},       {.Leaf, 4},       {}} },
    { .Iron_Bucket,    1, .Bench, {{.Iron_Bar, 3},    {},               {}} },
    { .Sky_Altar,      1, .Bench, {{.Stone_Block, 6}, {.Plank, 4},      {}} },
    { .Sword,          1, .Bench, {{.Iron_Bar, 2},    {.Plank, 1},      {}} },
    // The station ladder: forge is smithed at the bench from smelted iron,
    // the altar raised at the forge — its cloud stone means reaching the sky
    // first.  Forge-tier and up runs on bars: the smelter casts them from
    // ore stacks dropped beside it (1 iron ore = 1 bar; silver/gold 2 = 1).
    { .Dvergr_Forge,   1, .Bench, {{.Stone_Block, 10}, {.Iron_Bar, 3},    {}} },
    { .Rune_Altar,     1, .Forge, {{.Gold_Bar, 2},     {.Cloud_Stone, 6}, {}} },
    // The miner's ladder: each wand tier consumes the one before it.
    { .Mine_Wand,        1, .Bench, {{.Plank, 2},            {.Iron_Ore, 4},   {}} },
    { .Mine_Wand_Silver, 1, .Forge, {{.Mine_Wand, 1},        {.Silver_Bar, 3}, {}} },
    { .Mine_Wand_Gold,   1, .Forge, {{.Mine_Wand_Silver, 1}, {.Gold_Bar, 3},   {}} },
    // Weapon ladder — same pattern as the wands.
    { .Silver_Sword,   1, .Forge, {{.Sword, 1},        {.Silver_Bar, 3}, {}} },
    { .Gold_Sword,     1, .Forge, {{.Silver_Sword, 1}, {.Gold_Bar, 3},   {}} },
    // Armor: forge iron pieces, then upgrade each through silver into gold
    // (right-click a piece in the bag to wear it).
    { .Iron_Helm,       1, .Bench, {{.Iron_Bar, 3}, {.Plank, 1}, {}} },
    { .Iron_Chestplate, 1, .Bench, {{.Iron_Bar, 5}, {.Plank, 2}, {}} },
    { .Iron_Gauntlets,  1, .Bench, {{.Iron_Bar, 2}, {.Plank, 1}, {}} },
    { .Iron_Greaves,    1, .Bench, {{.Iron_Bar, 4}, {.Plank, 1}, {}} },
    { .Iron_Boots,      1, .Bench, {{.Iron_Bar, 2}, {.Plank, 1}, {}} },
    { .Silver_Helm,       1, .Forge, {{.Iron_Helm, 1},       {.Silver_Bar, 2}, {}} },
    { .Silver_Chestplate, 1, .Forge, {{.Iron_Chestplate, 1}, {.Silver_Bar, 3}, {}} },
    { .Silver_Gauntlets,  1, .Forge, {{.Iron_Gauntlets, 1},  {.Silver_Bar, 2}, {}} },
    { .Silver_Greaves,    1, .Forge, {{.Iron_Greaves, 1},    {.Silver_Bar, 3}, {}} },
    { .Silver_Boots,      1, .Forge, {{.Iron_Boots, 1},      {.Silver_Bar, 2}, {}} },
    { .Gold_Helm,       1, .Forge, {{.Silver_Helm, 1},       {.Gold_Bar, 2}, {}} },
    { .Gold_Chestplate, 1, .Forge, {{.Silver_Chestplate, 1}, {.Gold_Bar, 3}, {}} },
    { .Gold_Gauntlets,  1, .Forge, {{.Silver_Gauntlets, 1},  {.Gold_Bar, 2}, {}} },
    { .Gold_Greaves,    1, .Forge, {{.Silver_Greaves, 1},    {.Gold_Bar, 3}, {}} },
    { .Gold_Boots,      1, .Forge, {{.Silver_Boots, 1},      {.Gold_Bar, 2}, {}} },
    // Trinkets
    { .Aether_Charm,   1, .Rune_Altar, {{.Aether_Crystal, 3}, {.Gold_Bar, 1}, {}} },
    // Bulk storage: the first machine that counts past 99 (draft1 §7.6 step 1).
    // Q-drop stacks beside it to feed it; a smelter next door casts bars
    // straight in.
    { .Silo,           1, .Forge, {{.Stone_Block, 20}, {.Iron_Bar, 4}, {}} },
    // Parallel dimensions: the metal you pay is the metal the world is rich
    // in — each theme's recipe mirrors its riches.
    { .Dimension_Spawner,      1, .Rune_Altar, {{.Iron_Bar, 4}, {.Cloud_Stone, 8}, {.Stone_Block, 20}} },
    { .Dimension_Spawner_Gold, 1, .Rune_Altar, {{.Gold_Bar, 4}, {.Cloud_Stone, 8}, {.Stone_Block, 20}} },
    // The endgame sink: 500 bars is roughly a strip-mined Gold world — one
    // whole dimension traded for the door to the runic tier.
    { .Dimension_Spawner_Runic, 1, .Rune_Altar, {{.Gold_Bar, 500}, {.Cloud_Stone, 20}, {}} },
    // The snake miner: strips a dimension on its own.  The emerald is the
    // first gem sink — nature seeds the machine that industrializes worlds.
    { .Auto_Miner,             1, .Rune_Altar, {{.Iron_Bar, 6}, {.Gold_Bar, 2}, {.Emerald, 1}} },
    // Runic tier: gold gear reforged with sky runes at the altar.
    { .Mine_Wand_Runic,  1, .Rune_Altar, {{.Mine_Wand_Gold, 1},  {.Runic_Sky_Ore, 6}, {}} },
    { .Runic_Sword,      1, .Rune_Altar, {{.Gold_Sword, 1},      {.Runic_Sky_Ore, 6}, {}} },
    { .Runic_Helm,       1, .Rune_Altar, {{.Gold_Helm, 1},       {.Runic_Sky_Ore, 4}, {}} },
    { .Runic_Chestplate, 1, .Rune_Altar, {{.Gold_Chestplate, 1}, {.Runic_Sky_Ore, 6}, {}} },
    { .Runic_Gauntlets,  1, .Rune_Altar, {{.Gold_Gauntlets, 1},  {.Runic_Sky_Ore, 3}, {}} },
    { .Runic_Greaves,    1, .Rune_Altar, {{.Gold_Greaves, 1},    {.Runic_Sky_Ore, 5}, {}} },
    { .Runic_Boots,      1, .Rune_Altar, {{.Gold_Boots, 1},      {.Runic_Sky_Ore, 3}, {}} },
    // A 2-tall wooden door, buildable from the very first bench — E toggles it
    // open (walk through) or shut (solid).  One log's worth of planks.
    // (Appended to keep existing recipe indices stable.)
    { .Door,             1, .Bench, {{.Plank, 4},          {},                  {}} },
    // Healing: surface flowers, foraged by walking through them, brew into a
    // Health Potion at the bench — early-game recovery.  (Appended to keep
    // existing recipe indices stable.)
    { .Potion_Health,    1, .Bench, {{.Flower, 3},         {},                  {}} },
    // Flower farming: sow seeds into a bed (with soil + a plank frame) — it
    // grows 5 flowers you harvest by walking through it.  (Appended.)
    { .Flower_Bed,       1, .Bench, {{.Dirt, 1},           {.Plank, 1},         {.Flower_Seed, 5}} },
    // Storage: a wooden 4×4 barrel — early overflow for a 24-slot bag.
    // Cheap on purpose (2 logs' worth of planks).  (Appended.)
    { .Barrel,           1, .Bench, {{.Plank, 8},          {},                  {}} },
    // A recoverable trash buffer: the newest offered stack replaces and
    // permanently erases the previous one. Forged from all three tier-2 riches.
    { .Void_Charm,       1, .Forge, {{.Silver_Bar, 4},     {.Gold_Bar, 2},      {.Emerald, 1}} },
    // Clay automation begins after the first cast iron.  Each worker is a
    // material investment; the Hearth upgrades the wand itself later.
    { .Command_Wand,     1, .Bench, {{.Clay, 2}, {.Plank, 2}, {.Iron_Bar, 1}} },
    { .Clay_Golem,       1, .Bench, {{.Clay, 4}, {.Iron_Bar, 1}, {}} },
    // A cheap early recall charm: forged at the bench with an iron bar and
    // a jade.  Worn in a charm slot, not spent — while equipped, the
    // inventory's "Return to Surface" button warps straight home.
    { .Jade_Ring,        1, .Bench, {{.Iron_Bar, 1}, {.Jade, 1}, {}} },
    // Steam industry, machine one: the kettle.  (Appended — recipe indices
    // are load-bearing for tests.)
    { .Boiler,           1, .Bench, {{.Iron_Bar, 4},       {.Stone_Block, 6},   {}} },
    { .Steam_Engine,     1, .Forge, {{.Iron_Bar, 10},      {.Silver_Bar, 2},    {}} },
}

// ─── Recipe unlock tree ───────────────────────────────────────────────────────
//
//  A recipe stays hidden until the player first obtains its gating material —
//  turning the craft window from a firehose into a paced reveal.  Keyed by the
//  recipe's (unique) RESULT item; .None (the map default) = known from the
//  start.  The unlock is STICKY (Progression_State.recipe_unlocked): once the
//  material has been held, the recipe stays available even after it's spent.
//  Tuning the pace of the early game = editing this table.
@(rodata)
recipe_unlock := #partial [Item]Item{
    // Domestic tier — the moment you can work wood / forage
    .Tree_Grower   = .Plank,
    .Door          = .Plank,
    .Barrel        = .Plank,
    .Sky_Altar     = .Stone_Block,
    .Potion_Health = .Flower,
    .Flower_Bed    = .Flower_Seed,
    // Iron tier — reward for reaching the first ore
    .Smelter     = .Iron_Ore,
    .Sword       = .Iron_Ore,
    .Mine_Wand   = .Iron_Ore,
    // Smelted tier — opens once you cast your first bar.  The Jade Ring
    // shows up here too, ungated by Jade itself, so the recipe card (and its
    // Jade cost) is the player's cue to go look for the gem.
    .Iron_Helm = .Iron_Bar, .Iron_Chestplate = .Iron_Bar, .Iron_Gauntlets = .Iron_Bar,
    .Iron_Greaves = .Iron_Bar, .Iron_Boots = .Iron_Bar,
    .Dvergr_Forge = .Iron_Bar, .Silo = .Iron_Bar, .Jade_Ring = .Iron_Bar,
    .Iron_Bucket = .Iron_Bar, .Boiler = .Iron_Bar,
    // Silver / gold ladders
    .Steam_Engine = .Silver_Bar,   // power is a real mid-game gate
    .Silver_Sword = .Silver_Bar, .Mine_Wand_Silver = .Silver_Bar,
    .Silver_Helm = .Silver_Bar, .Silver_Chestplate = .Silver_Bar, .Silver_Gauntlets = .Silver_Bar,
    .Silver_Greaves = .Silver_Bar, .Silver_Boots = .Silver_Bar,
    .Gold_Sword = .Gold_Bar, .Mine_Wand_Gold = .Gold_Bar,
    .Gold_Helm = .Gold_Bar, .Gold_Chestplate = .Gold_Bar, .Gold_Gauntlets = .Gold_Bar,
    .Gold_Greaves = .Gold_Bar, .Gold_Boots = .Gold_Bar,
    .Dimension_Spawner_Gold = .Gold_Bar, .Dimension_Spawner_Runic = .Gold_Bar,
    // Sky tier
    .Rune_Altar = .Cloud_Stone, .Dimension_Spawner = .Cloud_Stone,
    .Aether_Charm = .Aether_Crystal,
    .Auto_Miner = .Emerald,
    .Void_Charm = .Emerald,
    .Command_Wand = .Clay,
    .Clay_Golem   = .Command_Wand,
    // Runic endgame
    .Mine_Wand_Runic = .Runic_Sky_Ore, .Runic_Sword = .Runic_Sky_Ore,
    .Runic_Helm = .Runic_Sky_Ore, .Runic_Chestplate = .Runic_Sky_Ore, .Runic_Gauntlets = .Runic_Sky_Ore,
    .Runic_Greaves = .Runic_Sky_Ore, .Runic_Boots = .Runic_Sky_Ore,
    // .Plank and .Crafting_Bench default to .None — known from the very start.
}

// Reveal recipes whose gating material the player now holds (sticky), popping a
// one-shot "New recipe" note.  Step in game_update; reads inventory, pushes no
// events.  Pre-marked (.None) recipes never notify — see game_state_init.
// recipe_unlocked is sized to MAX_ITEM_SLOTS rather than [Item] so that
// appending an item never changes the save layout — these two keep the call
// sites reading in terms of items rather than raw indices.
recipe_revealed :: #force_inline proc(p: ^Progression_State, it: Item) -> bool {
    return p.recipe_unlocked[int(it)]
}

reveal_recipe :: #force_inline proc(p: ^Progression_State, it: Item) {
    p.recipe_unlocked[int(it)] = true
}

update_recipe_unlocks :: proc(gs: ^Game_State) {
    first: Item = .None
    more  := 0
    for r in recipe_table {
        if recipe_revealed(&gs.progression, r.result) do continue
        req := recipe_unlock[r.result]
        if req != .None && inventory_count(&gs.player.inventory, req) == 0 do continue
        reveal_recipe(&gs.progression, r.result)
        if first == .None { first = r.result } else { more += 1 }
    }
    if first != .None {
        if more > 0 {
            notify(gs, "New recipe: %s  (+%d more)", item_table[first].name, more)
        } else {
            notify(gs, "New recipe: %s", item_table[first].name)
        }
    }
}

// One scan of the tiles around the player: which stations are in range.
// .None is always "in range" — hand recipes work anywhere.
stations_in_range :: proc(gs: ^Game_State) -> [Station]bool {
    near: [Station]bool
    near[.None] = true
    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)
    for dy in -BENCH_RANGE ..= BENCH_RANGE {
        for dx in -BENCH_RANGE ..= BENCH_RANGE {
            t := get_tile(&gs.world, cx+dx, cy+dy)
            for st in Station {
                if st != .None && station_tile[st] == t do near[st] = true
            }
        }
    }
    return near
}

player_near_station :: proc(gs: ^Game_State, st: Station) -> bool {
    if st == .None do return true
    return stations_in_range(gs)[st]
}

// The station on a tile, or .None.
station_at_tile :: proc(w: ^World_Grid, tx, ty: i32) -> Station {
    t := get_tile(w, int(tx), int(ty))
    for st in Station {
        if st != .None && station_tile[st] == t do return st
    }
    return .None
}

// Nearest interactable station within BENCH_RANGE of the player — scanned
// ring by ring (chebyshev) so the closest tile wins.  .None when nothing near.
nearest_station :: proc(gs: ^Game_State) -> (st: Station, tile: [2]i32) {
    cx := int(gs.player.pos.x + PLAYER_W*0.5)
    cy := int(gs.player.pos.y + PLAYER_H*0.5)
    for r in 0 ..= BENCH_RANGE {
        for dy in -r ..= r {
            for dx in -r ..= r {
                if max(abs(dx), abs(dy)) != r do continue  // shell of this ring only
                if s := station_at_tile(&gs.world, i32(cx+dx), i32(cy+dy)); s != .None {
                    return s, {i32(cx + dx), i32(cy + dy)}
                }
            }
        }
    }
    return .None, {}
}

// Per-frame station focus: the station the player could interact with right
// now, read by the hover prompt, tile highlight and click handler.
update_station_focus :: proc(gs: ^Game_State) {
    if gs.player.dead {
        gs.ui.focus_station = .None
        return
    }
    gs.ui.focus_station, gs.ui.focus_tile = nearest_station(gs)
}

// Recipes shown in the crafting window: hand recipes plus those of the
// station the window was opened at (ui.active_station; .None = hand only).
// Fills idx_buf with recipe-table indices, returns the count.  Draw and
// cursor hit-test both use this so rows always line up.
visible_recipes :: proc(gs: ^Game_State, idx_buf: ^[len(recipe_table)]int) -> int {
    n := 0
    for r, i in recipe_table {
        if r.station != .None && r.station != gs.ui.active_station do continue
        if !recipe_revealed(&gs.progression, r.result) do continue   // hidden until discovered
        idx_buf[n] = i
        n += 1
    }
    return n
}

recipe_craftable :: proc(gs: ^Game_State, r: ^Recipe) -> bool {
    if !player_near_station(gs, r.station) do return false
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
