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
MAX_EVENTS      :: 512
MAX_INVENTORY   :: 24
MAX_RECIPES     :: 16
MAX_AUDIO       :: 128
MAX_LEVELS      :: 16
MAX_PROGRESSION_TIERS :: 3

PLAYER_ID      :: Entity_ID(0)
INVALID_ENTITY :: max(Entity_ID)

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
    Drop_Item,
    Inventory,
    Crafting,
    Blueprint,
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
}

Terrain_Flags :: bit_set[Terrain_Flag; u8]

// ─── Tile Flags (per-cell runtime state) ──────────────────────────────────────

Tile_Flag :: enum u8 {
    Fire,
    Poison,
    Corrupted,
    Lit,
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
    Item_Dropped,
    Craft_Request,
    Craft_Complete,
    Station_Interact,

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
