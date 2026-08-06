package game

// ─── Build Flags ──────────────────────────────────────────────────────────────

// Debug tooling (action log, scan rays, F3 overlay) compiles in by default.
// Release builds strip it: odin build src -define:GAME_DEBUG=false
GAME_DEBUG :: #config(GAME_DEBUG, true)

// ─── Constants ────────────────────────────────────────────────────────────────

GRID_W          :: 192
GRID_H          :: 108
CELL_SIZE       :: 10
MAX_ENEMIES     :: 64
MAX_PARTICLES   :: 256
MAX_PROJECTILES :: 32
MAX_FALLING     :: 256   // structural blocks in mid-fall at once (gravity.odin)
MAX_EVENTS      :: 512
MAX_INVENTORY   :: 24
MAX_AUDIO       :: 128
MAX_LEVELS      :: 16
MAX_PROGRESSION_TIERS :: 3
MAX_GOLEMS      :: 15

PLAYER_ID      :: Entity_ID(0)
INVALID_ENTITY :: max(Entity_ID)

// Friendly clay workers use their own fixed store rather than Enemy_IDs.
// All four saved as u8 (Golem.mode/status/job/plan, memcpy'd into Save_Data
// via Golem_System) — append-only, never reorder or remove a value.
Golem_Mode :: enum u8 { Gather, Build }
Golem_Status :: enum u8 { Empty, Carried, Deployed, Broken }
Golem_Job :: enum u8 { Idle, Seek, Mine, Deliver, Fetch_Build, Place }
Golem_Plan :: enum u8 { None, Clay_Hearth, Golem_Depot, World_Anchor }

// ─── ID Types ─────────────────────────────────────────────────────────────────

Entity_ID :: distinct u16
Object_ID :: distinct u8
Item_ID   :: distinct u8

// ─── Tile Types ───────────────────────────────────────────────────────────────

Tile_Type :: enum u8 {
    Air,
    Void,
    Grass,
    Stone,
    Water,
    Lava,
    Magic_Lava,
    Wood,
    Leaves,
    Iron_Ore,
    Silver_Ore,
    Gold_Ore,
    Gold_Rare_Ore,
    Crafting_Bench,
    Tree_Grower,
    Smelter,
    Cave_Entrance,
    Sky_Entrance,
    Sky_Altar,
    Cloud,
    Cloud_Ore,
    Aether_Ore,
    Runic_Sky_Ore,
    Wind_Current,
    Void_Sky,
    Flower,
    // Crafting stations (appended: terrain is saved as u8, order is frozen)
    Dvergr_Forge,
    Rune_Altar,
    // Parallel dimensions (appended: order is frozen)
    Dimension_Spawner,
    Dimension_Gate,
    Dimension_Spawner_Gold,
    // Gem ladder — one gem per depth layer (appended: order is frozen)
    Emerald_Ore,
    Jade_Ore,
    Diamond_Ore,
    Hel_Gem_Ore,
    // Auto-Miner (appended: order is frozen)
    Auto_Miner,   // the placed base; snake head grows from here
    Miner_Body,   // the expanding metal trail the head leaves behind
    // Runic dimension (appended: order is frozen)
    Dimension_Spawner_Runic,
    // Silo (appended: order is frozen)
    Silo,         // wide-count bulk storage — counts past the u8 world (silo.odin)
    // Placeable loose earth (appended: terrain is saved as u8, order is frozen)
    Dirt,
    // 2-tall wooden door — one tile type, open/closed via Tile_Flag.Open
    // (appended: terrain is saved as u8, order is frozen)
    Door,
    // Planted flower bed — a crop of 5 flowers, harvested by walking through
    // (appended: terrain is saved as u8, order is frozen)
    Flower_Bed,
    // Wooden 4×4 storage barrel — hand-organized inventory overflow (barrel.odin)
    // (appended: terrain is saved as u8, order is frozen)
    Barrel,
    // Permanent progression/storage coffers.  Each variant starts with the
    // named blueprint; appended because terrain enum ordinals are serialized.
    Sky_Blueprint_Chest,
    Blueprint_Chest_A,
    Blueprint_Chest_B,
    Blueprint_Chest_C,
    // Clay-golem automation (appended: terrain ordinals are serialized)
    Clay,
    Clay_Hearth,
    Golem_Depot,
    World_Anchor,
    // Free, instant, self-dissolving foothold a golem conjures for its own
    // vertical movement (golem.odin Quick Clay) — never mineable, never
    // placed by a player. (appended: terrain ordinals are serialized)
    Quick_Clay,
}

// ─── Item IDs ─────────────────────────────────────────────────────────────────

Item :: enum u8 {
    None,
    Sword,
    Pickaxe,
    Potion_Health,
    Potion_Mana,
    Mine_Wand,
    Mine_Wand_Silver,
    Mine_Wand_Gold,
    Wood_Log,
    Leaf,
    Stone_Block,
    Grass_Turf,
    Plank,
    Iron_Ore,
    Silver_Ore,
    Gold_Ore,
    Gold_Rare_Ore,
    Crafting_Bench,
    Tree_Grower,
    Smelter,
    Iron_Bucket,
    Hell_Key,
    Blueprint_A,
    Blueprint_B,
    Blueprint_C,
    Sky_Blueprint,
    Sky_Altar,
    Cloud_Stone,
    Aether_Crystal,
    Runic_Sky_Ore,
    Aether_Charm,
    // Weapon ladder (base Sword is above)
    Silver_Sword,
    Gold_Sword,
    // Armor: 5 pieces × 3 tiers, upgraded at a bench like the wands
    Iron_Helm,       Silver_Helm,       Gold_Helm,
    Iron_Chestplate, Silver_Chestplate, Gold_Chestplate,
    Iron_Gauntlets,  Silver_Gauntlets,  Gold_Gauntlets,
    Iron_Greaves,    Silver_Greaves,    Gold_Greaves,
    Iron_Boots,      Silver_Boots,      Gold_Boots,
    // Crafting stations (appended: items are saved as u8, order is frozen)
    Dvergr_Forge,
    Rune_Altar,
    // Runic tier — gold gear reforged with Runic Sky Ore at the Rune Altar
    Mine_Wand_Runic,
    Runic_Sword,
    Runic_Helm,
    Runic_Chestplate,
    Runic_Gauntlets,
    Runic_Greaves,
    Runic_Boots,
    // Smelted bars (appended: items are saved as u8, order is frozen)
    Iron_Bar,
    Silver_Bar,
    Gold_Bar,
    // Parallel dimensions (appended: order is frozen)
    Dimension_Spawner,
    Dimension_Spawner_Gold,
    // Gem ladder (appended: order is frozen)
    Emerald,
    Jade,
    Diamond,
    Hel_Gem,
    // Auto-Miner (appended: order is frozen)
    Auto_Miner,
    // Runic dimension (appended: order is frozen)
    Dimension_Spawner_Runic,
    // Silo (appended: order is frozen)
    Silo,
    // Loose earth from the shaft-mouth stratum (appended: order is frozen)
    Dirt,
    // Craftable 2-tall wooden door (appended: order is frozen)
    Door,
    // Foraged surface flower — the reagent for Health Potions (appended: order is frozen)
    Flower,
    // Flower farming: seeds shaken from a harvested flower, sown into a bed
    // (appended: order is frozen)
    Flower_Seed,
    Flower_Bed,
    // Wooden 4×4 storage barrel (appended: order is frozen)
    Barrel,
    // Recoverable one-stack trash buffer, unlocked by an equipped charm
    Void_Charm,
    // Clay-golem automation (appended: item ordinals are serialized)
    Clay,
    Command_Wand,
    Command_Wand_Emerald,
    Command_Wand_Hel,
    Clay_Golem,
}

// ─── Stats & Equipment ────────────────────────────────────────────────────────
//
//  Table-driven: base values live in player_base_stats, per-item bonuses in
//  item_stat_bonus (items.odin).  Only equipped gear counts — bag items are
//  inert.  Defense blunts enemy-dealt damage only; the world (lava, falls,
//  source == INVALID_ENTITY) ignores armor.

Stat :: enum u8 {
    Attack,    // melee damage per swing (a weapon must be equipped to swing)
    Defense,   // subtracted from enemy-dealt damage
    Max_HP,
    Speed,     // horizontal move speed, tiles/s
}

Equip_Slot :: enum u8 {
    None,      // zero value: the item is not equippable
    Weapon,
    Head,
    Chest,
    Hands,
    Legs,
    Feet,
    Charm,
    Tool,      // append-only: dedicated pickaxe slot; save v19
    Charm_2,   // append-only: extra charm belt sockets; save v21
    Charm_3,
}

// ─── Rebindable Actions ───────────────────────────────────────────────────────
//
//  Every action the settings screen can rebind.  The key table lives in
//  Game_State.bindings; arrows/space stay as fixed movement alternates.

Action :: enum u8 {
    Move_Left,
    Move_Right,
    Jump,
    Interact,
    Inventory,   // opens the bag + crafting panel together (crafting has no key of its own)
    Blueprint,
    Golem_Crew, // crew-wide Gather/Build toggle while the command wand is equipped
}

// ─── Terrain Flags ────────────────────────────────────────────────────────────

Terrain_Flag :: enum u8 {
    Solid,
    Walkable,
    Swimmable,
    Damaging,
    Flammable,
    Mineable,
    Placeable,
    Animated,
    Falls,       // obeys structural gravity unconditionally — drops when cut
                 // loose (gravity.odin): trees, placed wood/leaves, dirt
    Falls_Placed,// falls the same way, but ONLY when the cell is player-placed
                 // (Tile_Flag.Placed) — natural terrain of this type never caves
    Settles,     // a faller that re-settles as a TILE on landing (sand-style),
                 // instead of crumbling into item drops like a felled tree
}

Terrain_Flags :: bit_set[Terrain_Flag; u16]

// ─── Tile Flags (per-cell runtime state) ──────────────────────────────────────

Tile_Flag :: enum u8 {
    Fire,
    Poison,
    Corrupted,
    Lit,
    Placed,   // a player-placed block: distinguishes placed stone/grass from the
              // identical natural terrain so only placed ones obey gravity
    Golem_Placed, // temporary navigation masonry a clay golem may reclaim
    Golem_Marked, // explicit command-wand paint: mine this ordinary block
}

Tile_Flags :: bit_set[Tile_Flag; u8]

// ─── Event System ─────────────────────────────────────────────────────────────

Event_Type :: enum u8 {
    // Movement
    Player_Moved,
    Enemy_Moved,

    // Combat
    Damage_Dealt,
    Entity_Died,

    // World
    Tile_Mined,
    Tile_Placed,
    Lava_Spread,
    Tree_Grew,

    // Items
    Item_Pickup,
    Item_Drop,        // tile = target cell, int_val = bag slot; drops the stack as a ground pile
    Craft_Request,
    Craft_Complete,
    Station_Interact,
    Smelter_Interact, // tile = the clicked furnace; opens its window
    Smelter_Feed,     // tile = furnace, int_val = bag slot; loads ore into input or wood into fuel
    Smelter_Collect,  // tile = furnace; empties its tray into the bag
    Smelter_Withdraw, // tile = furnace; pulls the loaded ore back into the bag
    Barrel_Interact,  // tile = the clicked barrel; opens its window
    Barrel_Store,     // tile = barrel, int_val = bag slot; deposits that bag stack
    Barrel_Take,      // tile = barrel, int_val = barrel slot; withdraws it into the bag

    // Projectiles
    Projectile_Fired,
    Projectile_Impact,

    // Audio
    Play_Sound,
    Play_Music,
    Stop_Music,

    // Transitions
    Level_Enter,
    Level_Exit,
    Level_Locked,
    Player_Died,

    // Progression
    Blueprint_Found,
    Structure_Complete,
    Cave_Unlocked,
    Boss_Defeated,
    Game_Won,

    // Builder AI
    Builder_Mined,
    Builder_Placed,

    // Player world interaction
    Place_Request,   // tile = target; places the selected inventory item
    Ritual_Request,  // player activated a sky altar
    Equip_Request,   // int_val = bag slot; wear/wield that slot's item
    Unequip_Request, // int_val = Equip_Slot; the gear returns to the bag

    // Menu
    New_Game_Request,   // "New Game" clicked — wipes the save and resets state
    Quit_Request,       // "Save and Quit" clicked — the run is saved on shutdown

    // Inventory (appended so existing event values stay stable)
    Inventory_Split,    // int_val = bag slot; moves half into the first empty slot
    Inventory_Move,     // int_val = source slot, tile.x = target slot; move/merge/swap
    Structure_Interact, // tile = exact player-built equipment clicked
    Structure_Reclaim,  // tile = equipment whose deliberate hold completed
    Void_Store,         // int_val = bag slot; replaces (deletes) the prior void stack
    Void_Take,          // tile.x = target bag slot; recovers the current void stack
    // Clay-golem commands (appended so existing event values stay stable)
    Golem_Load,         // int_val = bag slot containing a crafted Clay_Golem
    Golem_Deploy,       // tile = deployment cell
    Golem_Toggle,       // int_val = golem slot
    Golem_Recall,       // int_val = golem slot
    Golem_Crew_Toggle,  // current level: Gather <-> Build
    Golem_Zone,         // tile = second corner; int_val packs first corner x/y
    Golem_Project,      // tile = anchor; int_val = Golem_Plan
    Golem_Hearth_Use,   // tile = hearth: repair first, then upgrade wand
    Golem_Damaged,      // tile.x = golem slot, int_val = damage
    Golem_Mark,         // Shift+left wand paint: explicit excavation tile
    Golem_Unmark,       // Shift+right wand paint: erase excavation tile
}

Event_Payload :: struct #raw_union {
    int_val:   i32,
    float_val: f32,
    entity_id: Entity_ID,
}

Event :: struct {
    type:    Event_Type,
    source:  Entity_ID,
    target:  Entity_ID,
    tile:    [2]i32,
    payload: Event_Payload,
}

// ─── Navigation ───────────────────────────────────────────────────────────────

MAX_NAV_PATH :: 64

Nav_Path :: struct {
    tiles:  [MAX_NAV_PATH][2]i32,
    len:    int,
    cursor: int,
}
