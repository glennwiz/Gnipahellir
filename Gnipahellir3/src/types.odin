package game

// ─── Build Flags ──────────────────────────────────────────────────────────────

// Debug tooling (action log, scan rays, F4 overlay) compiles in by default.
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

// Headroom for every per-Item array that lives inside a SAVED struct (today
// just Progression_State.recipe_unlocked).  Keying those by [Item] directly
// meant every single appended item silently changed size_of(Save_Data) and
// broke every existing save — a tax paid on Sand, on Rune_Coffer, and again on
// Scroll_Of_Waters.  Sizing to a fixed ceiling instead makes appending an item
// free forever.  Raise this (and bump SAVE_VERSION once) if it ever fills up.
MAX_ITEM_SLOTS  :: 128
#assert(len(Item) <= MAX_ITEM_SLOTS)

PLAYER_ID      :: Entity_ID(0)
INVALID_ENTITY :: max(Entity_ID)

// Friendly clay workers use their own fixed store rather than Enemy_IDs.
// All four saved as u8 (Golem.mode/status/job/plan, memcpy'd into Save_Data
// via Golem_System) — append-only, never reorder or remove a value.
Golem_Mode :: enum u8 { Gather, Build, Fight }
Golem_Status :: enum u8 { Empty, Carried, Deployed, Broken }
Golem_Job :: enum u8 { Idle, Seek, Mine, Deliver, Fetch_Build, Place }
Golem_Plan :: enum u8 { None, Clay_Hearth, Golem_Depot, World_Anchor }

// Roster-window call orders: walk to the player, optionally recall on arrival,
// then stand down until given a new state. Transient — never saved; a reload
// drops the call and the golem resumes its mode.
Golem_Call :: enum u8 { None, Come, Come_Pickup, Waiting }

// Which store the ALT-click camera follow is indexing into (camera.odin).
// .None = the ordinary player-centered camera.  Transient — never saved.
Cam_Follow :: enum u8 { None, Enemy, Golem }

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
    // named rune scroll; appended because terrain enum ordinals are serialized.
    Sky_Rune_Scroll_Chest,
    Rune_Scroll_Chest_A,
    Rune_Scroll_Chest_B,
    Rune_Scroll_Chest_C,
    // Clay-golem automation (appended: terrain ordinals are serialized)
    Clay,
    Clay_Hearth,
    Golem_Depot,
    World_Anchor,
    // Free, instant, self-dissolving foothold a golem conjures for its own
    // vertical movement (golem.odin Quick Clay) — never mineable, never
    // placed by a player. (appended: terrain ordinals are serialized)
    Quick_Clay,
    // Surface pond shore (appended: terrain ordinals are serialized)
    Sand,
    // A rune scroll chest carried off and re-placed: the same ornate coffer
    // without a tier seal, storing like an ordinary barrel.  (appended:
    // terrain ordinals are serialized)
    Rune_Coffer,
    // Scalding vapour — the first gas: the fluid sim mirrored, so it rises,
    // pools under whatever ceiling you leave it, and fades if it escapes.
    // (appended: terrain ordinals are serialized)
    Steam,
    // The steam track's kettle: drinks an adjacent water cell, breathes a
    // steam cell into the open tile above.  (appended: terrain ordinals are
    // serialized)
    Boiler,
    // The steam track's power take-off: drinks pooled steam, stamps a powered
    // field on nearby cells.  (appended: terrain ordinals are serialized)
    Steam_Engine,
    // The gem farm: seed it with one gem and it grows copies forever — the
    // gem economy's renewal path, Tree Grower parity.  (appended: terrain
    // ordinals are serialized)
    Gem_Replicator,
    // Cave-floor forage — mines into the Green Cave Mushroom item, the
    // GreenBerrie's cave-trip ingredient.  (appended: terrain ordinals are
    // serialized)
    Green_Cave_Mushroom,
    // The block a cave mushroom sprouts from — stone furred with moss,
    // mines like stone.  (appended: terrain ordinals are serialized)
    Mossy_Stone,
    // The magic track's kettle: drinks an adjacent Magic_Lava cell, breathes
    // a Mana_Mist cell into the open tile above — the gem economy's power
    // sink.  (appended: terrain ordinals are serialized)
    Magic_Kettle,
    // The magic track's power take-off: drinks pooled Mana_Mist, stamps the
    // same powered() field the steam engine does.  (appended: terrain
    // ordinals are serialized)
    Mana_Wheel,
    // Harmless magic vapour — Mana Mist, the Mist twin of Steam: rises,
    // pools, fades, but deals no damage (comfort is the luxury track's
    // perk).  (appended: terrain ordinals are serialized)
    Mana_Mist,
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
    Rune_Scroll_A,
    Rune_Scroll_B,
    Rune_Scroll_C,
    Sky_Rune_Scroll,
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
    // Cheap early recall: warps the player back to the surface. (appended:
    // item ordinals are serialized)
    Jade_Ring,
    // Surface pond shore material (appended: item ordinals are serialized)
    Sand,
    // An emptied rune scroll chest, prised loose and carried off (appended:
    // item ordinals are serialized)
    Rune_Coffer,
    // Readable lore found on the pond shore — teaches how fluids flow and how a
    // spring is built.  NOT a Rune Scroll: those are progression seals, and
    // is_rune_scroll deliberately excludes this one.  (appended: item ordinals
    // are serialized)
    Scroll_Of_Waters,
    // The steam industry's first machine (appended: item ordinals are
    // serialized)
    Boiler,
    // (appended: item ordinals are serialized)
    Steam_Engine,
    // Filled buckets — the load lives on the stack, so every bucket you own
    // carries its own fluid (retired Player.bucket_fluid).  (appended: item
    // ordinals are serialized)
    Water_Bucket,
    Lava_Bucket,
    Magic_Lava_Bucket,
    // The gem farm (appended: item ordinals are serialized)
    Gem_Replicator,
    GreenBerrie, // (appended via gnipa_studio: item ordinals are serialized)
    // Mined from cave-floor mushrooms — GreenBerrie ingredient (appended:
    // item ordinals are serialized)
    Green_Cave_Mushroom,
    // The magic track: kettle + wheel (appended: item ordinals are serialized)
    Magic_Kettle,
    Mana_Wheel,
    // A pipe fitting: place it on an open cell to mark that cell piped
    // (Tile_Flag.Piped) — pure decoration over whatever fluid physics is
    // already doing there, auto-tiled casing art connects into a network.
    // (appended: item ordinals are serialized)
    Mana_Pipe,
    // <gen:item-append> — gnipa_studio's new-item wizard inserts above this line
}

// Which text the full-screen tome is showing.  `Seal` is the ritual's passage
// tome (keyed further by UI_State.book_tier); `Waters` is the pond-shore scroll.
// Transient UI state — never saved.
Book_Page :: enum u8 {
    Seal,
    Waters,
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
    Weapon,    // legacy since the hotbar (2026-08-12): hand gear lives in the bag;
               // kept for save layout, loads migrate any content to the bag
    Head,
    Chest,
    Hands,
    Legs,
    Feet,
    Charm,
    Tool,      // append-only: dedicated pickaxe slot, save v19; legacy like Weapon
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
    Rune_Scroll,
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
    Piped,        // a Mana Pipe fitting sits here — decoration only, set_tile
                  // never touches this bit, so it survives whatever fluid
                  // tile-type churns through the cell underneath (fluid.odin
                  // is completely unaware pipes exist; the 8th and last bit)
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
    Rune_Scroll_Found,
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
    Pixel_Art_Save,     // debug Pixel Art Editor "SAVE" button: writes gs.pixel_art to disk
    Warp_Home_Request,  // inventory "Return to Surface" button (Jade Ring worn)
    // Golem roster window buttons (appended so existing event values stay stable)
    Golem_Set_Mode,     // int_val = golem slot | Golem_Mode<<8
    Golem_Call_To_Me,   // int_val = golem slot; walk to the player, then wait
    Golem_Pickup,       // int_val = golem slot; recall in reach, else come-then-recall
    // (appended so existing event values stay stable)
    Mushroom_Grew,      // tile = the sprouted mushroom; sound + spore glow burst
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
