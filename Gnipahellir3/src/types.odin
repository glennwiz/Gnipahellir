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
