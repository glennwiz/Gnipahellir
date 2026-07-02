package gnipahellir

import rl "vendor:raylib"
import "core:os"
import "core:fmt"
import "core:mem"

// Central game state aggregation (Phase 1 subset)

Camera2D :: struct { // minimal stub until raylib integration
    target_x, target_y : f32,
    offset_x, offset_y : f32,
    rotation           : f32,
    zoom               : f32,
}

// --- Inventory / UI -------------------------------------------------------
INV_MAX_SLOTS :: 24

Item_Stack :: struct {
    id     : Item_ID,
    count  : u16,
}

Inventory :: struct {
    slots : [INV_MAX_SLOTS]Item_Stack,
}

UI_State :: struct {
    bag_open : bool,
    character_open : bool,
    // Drag state
    dragging      : bool,
    drag_from_inv : bool,
    drag_index    : int, // inventory index or -1 for equipment
    // Click timing (for double-click detection in inventory)
    last_click_slot : int,
    last_click_time : f32,
    // Build menu
    build_menu_open : bool,
    build_selected  : Item_ID,
    build_scroll    : int,
    // Crafting menu
    crafting_open : bool,
    crafting_active_from_bench : bool, // true when opened via clicking a bench
    crafting_selected_index : int, // selected recipe dropdown (or -1 none)
    crafting_dropdown_open : bool,
    // Window positions (mutable)
    inv_x, inv_y         : int,
    char_x, char_y       : int,
    build_x, build_y     : int,
    craft_x, craft_y     : int,
    // Window dragging
    window_dragging      : bool,
    window_drag_target   : int, // 0 none 1 inv 2 char 3 build 4 craft
    window_drag_off_x    : int,
    window_drag_off_y    : int,
    // Tooltip hover data (transient per-frame)
    hover_item    : Item_ID,
    hover_terrain : Terrain_Type,
    tooltip_x, tooltip_y : int,
    // Debug menu
    debug_open : bool,
    debug_place_active : bool,
    debug_place_terrain : Terrain_Type,
    // Sound debug window
    sound_debug_open : bool,
    sound_debug_scroll : int,
    
    // Stats screen
    stats_open : bool,
    stats_scroll : int,

    // Transient popup message
    popup_active : bool,
    popup_text   : cstring,
    popup_time   : f32,
    
    // Menu system
    main_menu_active : bool,
    save_quit_dialog_active : bool,
    settings_menu_active : bool,
    menu_selection : int, // Current menu selection
}

// Window dimension constants
INVENTORY_W :: 320
INVENTORY_H :: 240
CHARACTER_W :: 200
CHARACTER_H :: 180
BUILD_MENU_W :: 220
BUILD_MENU_H :: 260
CRAFT_MENU_W :: 260
CRAFT_MENU_H :: 180

Level_Kind :: enum u8 { Surface, Cave, Sky }

SKY_LEVELS  :: 4
CAVE_LEVELS :: 8

// Persistent stats that carry between runs
Game_Stats :: struct {
    // Run statistics
    total_runs : u32,
    total_deaths : u32,
    best_depth_reached : i32,
    total_time_played : f32, // in seconds
    
    // Resource statistics
    total_blocks_destroyed : u32,
    total_items_picked_up : u32,
    total_blocks_placed : u32,
    total_crafting_attempts : u32,
    total_crafting_successes : u32,
    
    // Combat/action statistics
    total_mining_actions : u32,
    total_mana_spent : u32,
    total_lava_damage_taken : u32,
    total_deaths_by_lava : u32,
    
    // Exploration statistics
    total_levels_visited : u32,
    total_portals_used : u32,
    total_distance_traveled : u32, // in tiles
    
    // Item-specific statistics
    wood_logs_collected : u32,
    stone_blocks_collected : u32,
    iron_ore_collected : u32,
    silver_ore_collected : u32,
    gold_ore_collected : u32,
    gold_rare_ore_collected : u32,
    
    // Current run statistics (reset each run)
    current_run_time : f32,
    current_run_blocks_destroyed : u32,
    current_run_items_picked_up : u32,
    current_run_depth_reached : i32,
    current_run_mana_spent : u32,
}

// Shared save data structure (used by both save and load functions)
Save_Data :: struct {
    // Version for save file compatibility
    version: u32,
    
    // Current level and world state
    level_offset: int,
    surface_saved: bool,
    surface_world: World_Grid,
    cave_worlds: [CAVE_LEVELS]World_Grid,
    cave_generated: [CAVE_LEVELS]bool,
    sky_worlds: [SKY_LEVELS]World_Grid,
    sky_generated: [SKY_LEVELS]bool,
    
    // Player state
    player: Player,
    
    // Enemy state
    garm: Enemy,
    
    // Inventory
    inventory: Inventory,
    
    // UI state (excluding transient popups)
    ui_bag_open: bool,
    ui_character_open: bool,
    ui_build_menu_open: bool,
    ui_crafting_open: bool,
    ui_debug_open: bool,
    ui_sound_debug_open: bool,
    ui_stats_open: bool,
    ui_inv_x, ui_inv_y: int,
    ui_char_x, ui_char_y: int,
    ui_build_x, ui_build_y: int,
    ui_craft_x, ui_craft_y: int,
    ui_build_selected: Item_ID,
    ui_build_scroll: int,
    ui_sound_debug_scroll: int,
    ui_stats_scroll: int,
    
    // Game state
    elapsed_time: f32,
    mana_regen_accumulator: f32,
    player_dead: bool,
    death_explosion_done: bool,
    death_timer: f32,
    bucket_has_lava: bool,
    
    // Stats (already persistent, but include for completeness)
    stats: Game_Stats,
}

Game_State :: struct {
    world  : World_Grid,
    // Level system: level_offset = 0 surface, positive = caves below, negative = sky above
    level_offset : int,
    surface_saved : bool,
    surface_world : World_Grid,
    cave_worlds : [CAVE_LEVELS]World_Grid,
    cave_generated : [CAVE_LEVELS]bool,
    sky_worlds : [SKY_LEVELS]World_Grid,
    sky_generated : [SKY_LEVELS]bool,
    player : Player,
    // Enemy system - currently just Garm
    garm : Enemy,
    particles : Particles,
    portals : [2]Portal_Effect,
    // Wand mining projectile particles
    wand_projectiles : Wand_Projectiles,
    mining : Mining_Action,
    // Enemy fireball projectiles
    fireballs : Enemy_Fireballs,

    events : Event_Queue,
    camera : Camera2D,
    // Future expansions kept as placeholders
    mob_count : int,
    // Inventory / UI state
    inventory : Inventory,
    ui        : UI_State,
    // Audio system
    audio     : Audio_State,
    // Accumulated runtime (seconds) for UI timing (double-click detection)
    elapsed_time : f32,
    // Mana regeneration accumulator (fractional seconds)
    mana_regen_accumulator : f32,
    // Death state
    player_dead : bool,
    death_explosion_done : bool,
    death_timer : f32, // Timer for death sequence
    
    // Persistent stats and roguelike progression
    stats : Game_Stats,
    
    // Bucket state: does the equipped bucket contain lava?
    bucket_has_lava : bool,

    // Garm debug logging buffer (session-scoped; flushed to garm_move.log)
    garm_log_buf : [262144]u8, // 256 KB ring (simple cap)
    garm_log_len : int,
}

init_game :: proc(game: ^Game_State) {
    // Always show main menu first, regardless of save file existence
    game.ui.main_menu_active = true
    game.ui.menu_selection = 0
    
    // Initialize audio system for menu sounds
    init_audio(&game.audio)
    load_game_sounds(&game.audio)
}

start_new_game :: proc(game: ^Game_State) {
    // Initialize a completely fresh game
    game.level_offset = 0
    game.surface_saved = false
    // Mark all entity slots invalid & fill terrain
    for x in 0..<WORLD_WIDTH {
        for y in 0..<WORLD_HEIGHT {
            game.world.entities[x][y] = INVALID_ENTITY
            game.world.terrain[x][y] = .Air
            game.world.item_counts[x][y] = 1
            game.world.hit_counts[x][y] = 0
            game.world.lava_elapsed[x][y] = 0
            game.world.lava_target[x][y] = 0
        }
    }

    // Terrain layering: bottom row Stone, second-from-bottom Grass (explicit)
    bottom := WORLD_HEIGHT - 1
    second := WORLD_HEIGHT - 2
    if bottom >= 0 {
        for x in 0..<WORLD_WIDTH {
            game.world.terrain[x][bottom] = .Stone
        }
    }
    if second >= 0 {
        for x in 0..<WORLD_WIDTH {
            game.world.terrain[x][second] = .Grass
        }
    }

    // Reset Garm log
    game.garm_log_len = 0

    // Store initial surface snapshot
    world_copy(&game.surface_world, &game.world)
    game.surface_saved = true

    // Spawn player just above grass layer near bottom, wand two tiles right
    grass_y := WORLD_HEIGHT - 2
    air_y := grass_y - 1
    start_x := clamp_int(WORLD_WIDTH/2 - 1, 1, WORLD_WIDTH-3)
    player_init(&game.player, start_x, air_y)
    game.world.entities[start_x][air_y] = PLAYER_ID

    game.events.head = 0
    game.events.tail = 0

    // Seed inventory with some starter items for demonstration
    game.inventory.slots[0] = Item_Stack{ id = .Sword, count = 1 }
    game.inventory.slots[1] = Item_Stack{ id = .Potion_Health, count = 3 }
    game.inventory.slots[2] = Item_Stack{ id = .Potion_Mana, count = 2 }
    // mark rest empty
    for i in 3..<INV_MAX_SLOTS do game.inventory.slots[i].id = .None

    game.ui.bag_open = false
    game.ui.character_open = false
    game.ui.dragging = false
    game.ui.drag_from_inv = false
    game.ui.drag_index = -1
    game.ui.last_click_slot = -1
    game.ui.last_click_time = -1000
    game.ui.build_menu_open = false
    game.ui.build_selected = .None
    game.ui.build_scroll = 0
    game.ui.crafting_open = false
    game.ui.crafting_active_from_bench = false
    game.ui.crafting_selected_index = -1
    game.ui.crafting_dropdown_open = false
    game.mana_regen_accumulator = 0.0
    game.player_dead = false
    game.death_explosion_done = false
    game.death_timer = 0.0
    
    // Initialize stats
    init_game_stats(&game.stats)
    // Default positions
    game.ui.inv_x = (WINDOW_WIDTH - INVENTORY_W)/2
    game.ui.inv_y = (WINDOW_HEIGHT - INVENTORY_H)/2
    game.ui.char_x = 40
    game.ui.char_y = 40
    game.ui.build_x = WINDOW_WIDTH - BUILD_MENU_W - 40
    game.ui.build_y = 40
    game.ui.craft_x = 50
    game.ui.craft_y = 50
    game.ui.window_dragging = false
    game.ui.window_drag_target = 0
    game.ui.hover_item = .None
    game.ui.hover_terrain = .Air
    game.ui.tooltip_x = 0; game.ui.tooltip_y = 0
    game.ui.debug_open = false
    game.ui.debug_place_active = false
    game.ui.debug_place_terrain = .Air
    game.ui.sound_debug_open = false
    game.ui.sound_debug_scroll = 0
    game.ui.stats_open = false
    game.ui.stats_scroll = 0
    game.ui.popup_active = false
    game.ui.popup_text = ""
    game.ui.popup_time = 0
    game.ui.main_menu_active = false // Don't start with main menu for new games
    game.ui.save_quit_dialog_active = false
    game.ui.settings_menu_active = false
    game.ui.menu_selection = 0
    game.mining.active = false
    game.elapsed_time = 0

    // Audio system already initialized from main menu
    // Particles implicitly zeroed (all inactive)

    // Initialize camera position to center on player
    game.camera.zoom = 1
    game.camera.target_x = cast(f32)(game.player.tile_x*TILE_SIZE + TILE_SIZE/2)
    game.camera.target_y = cast(f32)(game.player.tile_y*TILE_SIZE + TILE_SIZE/2)

    // Place Mine_Wand item two tiles to the right in air above grass
    wand_x := start_x + 2
    if bounds_check(wand_x, air_y) {
        game.world.items[wand_x][air_y] = .Mine_Wand
        game.world.item_counts[wand_x][air_y] = 1
    }
    // Portal spawn FX for player & wand
    spawn_portal(&game.portals[0], start_x, air_y)
    spawn_portal(&game.portals[1], wand_x, air_y)

    // --- Random tree generation ---
    // Iterate columns, chance to spawn a tree on grass layer.
    // Tree: Wood trunk 2-3 high above grass, 3x3 Leaves canopy.
    for x in 0..<WORLD_WIDTH {
        if rl.GetRandomValue(0, 99) < 15 { // 15% chance
            ground_y := second
            if ground_y >= 0 {
                trunk_h := 2 + cast(int)rl.GetRandomValue(0, 1) // 2-3
                top_y := ground_y - trunk_h
                if top_y >= 0 {
                    // Trunk
                    for ty in 1..=trunk_h { // starting just above grass
                        ny := ground_y - ty
                        if ny >= 0 && game.world.terrain[x][ny] == .Air {
                            game.world.terrain[x][ny] = .Wood
                        }
                    }
                    canopy_center_y := top_y
                    // Canopy loops (explicit indices due to negative start)
                    for dx := -1; dx <= 1; dx += 1 {
                        for dy := -1; dy <= 1; dy += 1 {
                            cx := x + dx
                            cy := canopy_center_y + dy
                            if bounds_check(cx, cy) && game.world.terrain[cx][cy] == .Air {
                                game.world.terrain[cx][cy] = .Leaves
                            }
                        }
                    }
                }
            }
        }
    }

    // --- Generate Gnipahellir Cave Entrance ---
    // Create a distinctive cave entrance structure away from player spawn
    // Place it in the right half of the world for exploration
    entrance_x := WORLD_WIDTH * 3 / 4  // 3/4 across the world
    entrance_x = clamp_int(entrance_x, 5, WORLD_WIDTH-6) // Ensure we have room for structure
    
    // Create the cave entrance: a large stone archway with Cave_Entrance terrain in center
    // Structure: 5 wide x 4 tall archway
    arch_base_y := second // Same level as grass
    
    // Stone archway structure (shaped like ⌒)
    // Bottom base stones
    for dx in -2..=2 {
        bx := entrance_x + dx
        if bounds_check(bx, arch_base_y) {
            game.world.terrain[bx][arch_base_y] = .Stone
        }
    }
    
    // Side pillars (2 high)
    for dy in 1..=2 {
        // Left pillar
        lx := entrance_x - 2
        ly := arch_base_y - dy
        if bounds_check(lx, ly) {
            game.world.terrain[lx][ly] = .Stone
        }
        // Right pillar  
        rx := entrance_x + 2
        ry := arch_base_y - dy
        if bounds_check(rx, ry) {
            game.world.terrain[rx][ry] = .Stone
        }
    }
    
    // Arch top
    arch_top_y := arch_base_y - 3
    if bounds_check(entrance_x - 1, arch_top_y) {
        game.world.terrain[entrance_x - 1][arch_top_y] = .Stone
    }
    if bounds_check(entrance_x + 1, arch_top_y) {
        game.world.terrain[entrance_x + 1][arch_top_y] = .Stone
    }
    
    // The actual cave entrance in the center
    cave_entrance_y := arch_base_y
    if bounds_check(entrance_x, cave_entrance_y) {
        game.world.terrain[entrance_x][cave_entrance_y] = .Cave_Entrance
    }
    
    // Dark void spaces inside the archway to suggest depth
    void_y1 := arch_base_y - 1
    void_y2 := arch_base_y - 2
    if bounds_check(entrance_x, void_y1) {
        game.world.terrain[entrance_x][void_y1] = .Void
    }
    if bounds_check(entrance_x, void_y2) {
        game.world.terrain[entrance_x][void_y2] = .Void
    }

    // Init crafting recipes
    init_crafting_recipes()
}

// --- Cave Generation & Level Transition ------------------------------------
// Simple cellular automata cave generation for underground layers.
// We treat 'Stone' as wall and 'Void' as open space. Start with random fill,
// run a few smoothing steps, then ensure a spawn shaft at player's x.

generate_cave_layer :: proc(world: ^World_Grid, spawn_x: int, layer_index: int) {
    // Seed all tiles to Stone then carve caves as Void.
    for x in 0..<WORLD_WIDTH {
        for y in 0..<WORLD_HEIGHT {
            world.entities[x][y] = INVALID_ENTITY
            world.items[x][y] = .None
            world.item_counts[x][y] = 1
            world.hit_counts[x][y] = 0
            world.grower_height[x][y] = 0
            world.grower_timer[x][y] = 0
            world.lava_elapsed[x][y] = 0
            world.lava_target[x][y] = 0
            // border walls kept solid
            if x == 0 || y == 0 || x == WORLD_WIDTH-1 || y == WORLD_HEIGHT-1 {
                world.terrain[x][y] = .Stone
            } else {
                // 45% chance initial void
                if rl.GetRandomValue(0,99) < 45 { world.terrain[x][y] = .Void } else { world.terrain[x][y] = .Stone }
            }
        }
    }
    // Smoothing iterations
    tmp : [WORLD_WIDTH][WORLD_HEIGHT]Terrain_Type
    for iter in 0..<4 {
        for x in 0..<WORLD_WIDTH {
            for y in 0..<WORLD_HEIGHT {
                // Count neighbor walls (non-Void)
                walls := 0
                for dx in -1..=1 {
                    for dy in -1..=1 {
                        if dx == 0 && dy == 0 do continue
                        nx := x + dx; ny := y + dy
                        if nx < 0 || ny < 0 || nx >= WORLD_WIDTH || ny >= WORLD_HEIGHT { walls += 1; continue }
                        if world.terrain[nx][ny] != .Void { walls += 1 }
                    }
                }
                if world.terrain[x][y] != .Void {
                    if walls < 4 { tmp[x][y] = .Void } else { tmp[x][y] = .Stone }
                } else {
                    if walls > 5 { tmp[x][y] = .Stone } else { tmp[x][y] = .Void }
                }
            }
        }
        for x in 0..<WORLD_WIDTH {
            for y in 0..<WORLD_HEIGHT {
                world.terrain[x][y] = tmp[x][y]
            }
        }
    }
    // Carve vertical spawn shaft at spawn_x from top to first open space
    sx := spawn_x
    if sx < 0 || sx >= WORLD_WIDTH { sx = WORLD_WIDTH/2 }
    for y in 0..<WORLD_HEIGHT {
        world.terrain[sx][y] = .Void
        // Add some side widening near top
        if y < 6 {
            if sx > 1 { world.terrain[sx-1][y] = .Void }
            if sx < WORLD_WIDTH-2 { world.terrain[sx+1][y] = .Void }
        }
    }
    // All underground layers get minerals and lava (more lava deeper)
    if layer_index >= 0 && layer_index < CAVE_LEVELS { // process all cave levels
        // Collect candidate stone tiles upper half
        cand_x : [1024]int; cand_y : [1024]int; cand_count : int = 0
        for x in 1 ..< WORLD_WIDTH-1 {
            for y in 1 ..< WORLD_HEIGHT/2 {
                if world.terrain[x][y] == .Stone {
                    if cand_count < 1024 { cand_x[cand_count] = x; cand_y[cand_count] = y; cand_count += 1 }
                }
            }
        }
        for i in 0 ..< cand_count {
            if cand_count <= 0 do break
            j_i32 := rl.GetRandomValue(cast(i32)i, cast(i32)(cand_count-1))
            j := cast(int)j_i32
            tx := cand_x[i]; ty := cand_y[i]
            cand_x[i] = cand_x[j]; cand_y[i] = cand_y[j]
            cand_x[j] = tx; cand_y[j] = ty
        }
        // Place minerals only on first few levels
        if layer_index <= 2 {
            iron_needed := 5; silver_needed := 2; gold_needed := 1
            idx : int = 0
            place := proc(w: ^World_Grid, t: Terrain_Type, idx_ptr: ^int, cx: ^[1024]int, cy: ^[1024]int, total: int) {
                if idx_ptr^ >= total { return }
                x := cx[idx_ptr^]; y := cy[idx_ptr^]; idx_ptr^ += 1
                w.terrain[x][y] = t
            }
            for i in 0..<iron_needed { place(world, .Iron, &idx, &cand_x, &cand_y, cand_count) }
            for i in 0..<silver_needed { place(world, .Silver, &idx, &cand_x, &cand_y, cand_count) }
            for i in 0..<gold_needed {
                upgrade := rl.GetRandomValue(0,99) < 30
                if upgrade { place(world, .Gold_Rare, &idx, &cand_x, &cand_y, cand_count) } else { place(world, .Gold, &idx, &cand_x, &cand_y, cand_count) }
            }
        }
        // Place lava - more lava at deeper levels
        lava_count := 1 + layer_index // Level 0: 1 lava, Level 1: 2 lava, etc.
        if layer_index >= 4 {
            lava_count = 5 + (layer_index - 4) * 2 // Level 4: 5, Level 5: 7, Level 6: 9, Level 7: 11
        }
        
        for lava_i in 0..<lava_count {
            // Pick random position in bottom area
            target_x := rl.GetRandomValue(2, WORLD_WIDTH-3)
            target_y := rl.GetRandomValue(WORLD_HEIGHT*3/4, WORLD_HEIGHT-3)
            
            // Find nearest stone to target position using expanding search
            lava_placed := false
            for radius in i32(0)..<max(WORLD_WIDTH, WORLD_HEIGHT) {
                if lava_placed do break
                for dx in -radius..=radius {
                    for dy in -radius..=radius {
                        if abs(dx) != radius && abs(dy) != radius do continue // only check perimeter
                        stone_x := target_x + dx
                        stone_y := target_y + dy
                        if stone_x >= 0 && stone_x < WORLD_WIDTH && stone_y >= 0 && stone_y < WORLD_HEIGHT {
                            if world.terrain[stone_x][stone_y] == .Stone {
                                // Magic lava appears at deeper levels (levels 5+)
                                lava_type := Terrain_Type.Lava
                                if layer_index >= 5 && rl.GetRandomValue(0,99) < 40 {
                                    lava_type = .Magic_Lava
                                }
                                world.terrain[stone_x][stone_y] = lava_type
                                world.lava_elapsed[stone_x][stone_y] = 0
                                world.lava_target[stone_x][stone_y] = cast(f32)(rl.GetRandomValue(1,3))
                                lava_placed = true
                                break
                            }
                        }
                    }
                    if lava_placed do break
                }
            }
        }
    }
}

generate_sky_layer :: proc(world: ^World_Grid, spawn_x: int) {
    // Clear to Air
    for x in 0..<WORLD_WIDTH { for y in 0..<WORLD_HEIGHT { world.entities[x][y] = INVALID_ENTITY; world.items[x][y] = .None; world.item_counts[x][y] = 1; world.hit_counts[x][y] = 0; world.terrain[x][y] = .Air } }
    // Floating islands: random blobs (Stone core, Grass top surface)
    island_count := 5
    for i in 0..<island_count {
        cx := rl.GetRandomValue(6, WORLD_WIDTH-7)
        cy := rl.GetRandomValue(8, WORLD_HEIGHT-18)
        rx := rl.GetRandomValue(3,6)
        ry := rl.GetRandomValue(2,4)
        for x in cx-rx ..= cx+rx {
            for y in cy-ry ..= cy+ry {
                if x < 0 || y < 0 || x >= WORLD_WIDTH || y >= WORLD_HEIGHT do continue
                // Ellipse check
                dx := x - cx; dy := y - cy
                if (dx*dx)*1 + (dy*dy)*2 <= rx*rx + ry*ry {
                    world.terrain[x][y] = .Stone
                }
            }
        }
        // Grass top layer: for each stone tile that has air above
        for x in 0..<WORLD_WIDTH {
            for y in 1..<WORLD_HEIGHT {
                if world.terrain[x][y] == .Stone && world.terrain[x][y-1] == .Air { world.terrain[x][y] = .Grass }
            }
        }
    }
    // Guaranteed spawn platform: small 3x2 island near spawn_x
    sx := clamp_int(spawn_x, 2, WORLD_WIDTH-3)
    for x in sx-1 ..= sx+1 {
        yb := WORLD_HEIGHT-6
        world.terrain[x][yb] = .Grass
        world.terrain[x][yb+1] = .Stone
    }
}

save_current_level :: proc(game: ^Game_State) {
    if game.level_offset == 0 {
        world_copy(&game.surface_world, &game.world)
        game.surface_saved = true
    } else if game.level_offset > 0 {
        idx := game.level_offset - 1
        if idx >= 0 && idx < CAVE_LEVELS {
            world_copy(&game.cave_worlds[idx], &game.world)
            game.cave_generated[idx] = true
        }
    } else { // sky
        idx := -game.level_offset - 1
        if idx >= 0 && idx < SKY_LEVELS {
            world_copy(&game.sky_worlds[idx], &game.world)
            game.sky_generated[idx] = true
        }
    }
}

load_level :: proc(game: ^Game_State, new_offset: int, player_spawn_x: int, spawn_bottom: bool) {
    // Persist current
    save_current_level(game)
    // Generate if needed
    if new_offset == 0 {
        if !game.surface_saved {
            // fallback copy current world as surface
            world_copy(&game.surface_world, &game.world)
            game.surface_saved = true
        }
        world_copy(&game.world, &game.surface_world)
    } else if new_offset > 0 {
        idx := new_offset - 1
        if idx >= CAVE_LEVELS { return }
        if !game.cave_generated[idx] {
            generate_cave_layer(&game.cave_worlds[idx], player_spawn_x, idx)
            game.cave_generated[idx] = true
        }
        world_copy(&game.world, &game.cave_worlds[idx])
        
        // Spawn Garm in the first underground layer after copying world (idx == 0)
        if idx == 0 && !game.garm.active {
            spawn_garm_in_cave(game, player_spawn_x)
        }
    } else { // sky (negative)
        idx := -new_offset - 1
        if idx >= SKY_LEVELS { return }
        if !game.sky_generated[idx] {
            generate_sky_layer(&game.sky_worlds[idx], player_spawn_x)
            game.sky_generated[idx] = true
        }
        world_copy(&game.world, &game.sky_worlds[idx])
    }
    game.level_offset = new_offset
    // Place player
    px := clamp_int(player_spawn_x, 1, WORLD_WIDTH-2)
    if spawn_bottom {
        game.player.pos_x = cast(f32)px; game.player.tile_x = px
        game.player.pos_y = cast(f32)(WORLD_HEIGHT-2); game.player.tile_y = WORLD_HEIGHT-2
    } else {
        game.player.pos_x = cast(f32)px; game.player.tile_x = px
        game.player.pos_y = 1; game.player.tile_y = 1
    }
    game.player.visual_x = game.player.pos_x; game.player.visual_y = game.player.pos_y
    if bounds_check(game.player.tile_x, game.player.tile_y) {
        game.world.entities[game.player.tile_x][game.player.tile_y] = PLAYER_ID
    }
}

level_transition_check :: proc(game: ^Game_State) {
    // Check for Cave_Entrance interaction (only on surface level)
    if game.level_offset == 0 {
        // Look for Cave_Entrance terrain at player's feet or adjacent tiles
        px := game.player.tile_x
        py := game.player.tile_y
        
        // Check if player is standing on or adjacent to Cave_Entrance
        entrance_found := false
        entrance_x := px
        
        // Check current tile and adjacent tiles for Cave_Entrance
        for dx in -1..=1 {
            for dy in -1..=1 {
                check_x := px + dx
                check_y := py + dy
                if bounds_check(check_x, check_y) {
                    if game.world.terrain[check_x][check_y] == .Cave_Entrance {
                        entrance_found = true
                        entrance_x = check_x
                        break
                    }
                }
            }
            if entrance_found do break
        }
        
        if entrance_found {
            // Descend into Gnipahellir! Start at cave level 1
            new_offset := 1
            load_level(game, new_offset, entrance_x, false)
            return
        }
    }
    
    // Descend from cave levels when bottom tile open (still keep this for deeper cave transitions)
    if game.level_offset > 0 && game.player.tile_y == WORLD_HEIGHT-1 {
        t := game.world.terrain[game.player.tile_x][game.player.tile_y]
        if t == .Air || t == .Void {
            new_offset := game.level_offset + 1
            if new_offset <= CAVE_LEVELS { load_level(game, new_offset, game.player.tile_x, false) }
            return
        }
    }
    
    // Ascend when near top (works from any level)
    if game.player.tile_y <= 0 && game.player.pos_y < 0.15 {
        new_offset := game.level_offset - 1
        if new_offset >= -SKY_LEVELS { load_level(game, new_offset, game.player.tile_x, true) }
        return
    }
}

clamp_int :: proc(v, lo, hi: int) -> int { if v < lo { return lo }; if v > hi { return hi }; return v }

// Basic update aggregation; dt in seconds
game_update :: proc(game: ^Game_State, dt: f32) {
    handle_input(game)
    player_update(game, dt)
    
    // Update enemy (Garm)
    enemy_update(game, &game.garm, dt)
    
    // Update enemy fireballs
    fireballs_update(game, dt)
    
    // Mana regeneration: 1 mana every 5 seconds
    game.mana_regen_accumulator += dt
    if game.mana_regen_accumulator >= 5.0 {
        game.player.mana = min(game.player.mana + 1, game.player.max_mana)
        game.mana_regen_accumulator -= 5.0
    }
    
    // Level transition: if at surface (depth 0) and player digs below bottom grass+stone into void trigger next layer
    level_transition_check(game)
    growers_update(&game.world, dt)
    lava_update(&game.world, dt)
    // Lava bubble particle spawning (separate so we have access to particles & timing)
    for x in 0..<WORLD_WIDTH {
        for y in 0..<WORLD_HEIGHT {
            terrain := game.world.terrain[x][y]
            if terrain != .Lava && terrain != .Magic_Lava do continue
            // small random chance each frame scaled by dt
            if rl.GetRandomValue(0, 100) < cast(i32)(6 + 40*dt) {
                wx := cast(f32)(x*TILE_SIZE + TILE_SIZE/2)
                wy := cast(f32)(y*TILE_SIZE + TILE_SIZE/2)
                if terrain == .Magic_Lava {
                    particle_spawn_magic_sparkle(&game.particles, wx, wy)
                } else {
                    particle_spawn_lava_bubble(&game.particles, wx, wy)
                }
            }
        }
    }
    particles_update(&game.particles, dt)
    wand_projectiles_update(game, dt)
    portals_update(&game.portals, dt)
    process_events(game)
    event_queue_clear(&game.events)
    // Update audio system
    update_audio(&game.audio, dt)
    // Side-effect interactions (pickups, debug commits, drag-drop finalize)
    update_interactions(game, dt)
    // Death sequence timer
    if game.player_dead {
        game.death_timer += dt
    }
    
    // Update game statistics
    update_game_stats(&game.stats, dt, game.level_offset)
    
    // Advance accumulated time for UI timing helpers
    game.elapsed_time += dt
}

// Restart the game after death
restart_game :: proc(game: ^Game_State) {
    // Reset death state
    game.player_dead = false
    game.death_explosion_done = false
    game.death_timer = 0.0
    
    // Reset player
    player_init(&game.player, WORLD_WIDTH/2 - 1, WORLD_HEIGHT - 3)
    game.world.entities[game.player.tile_x][game.player.tile_y] = PLAYER_ID
    
    // Reset world to surface
    game.level_offset = 0
    world_copy(&game.world, &game.surface_world)
    
    // Reset UI
    game.ui.bag_open = false
    game.ui.character_open = false
    game.ui.build_menu_open = false
    game.ui.crafting_open = false
    game.ui.debug_open = false
    game.ui.sound_debug_open = false
    game.ui.stats_open = false
    game.ui.popup_active = false
    
    // Reset mana
    game.mana_regen_accumulator = 0.0
    
    // Clear events
    event_queue_clear(&game.events)
    
    // Clear particles
    for i in 0..<MAX_PARTICLES {
        game.particles.data[i].active = false
    }
    
    // Reset current run stats
    reset_current_run_stats(&game.stats)
    
    // Increment total runs and save
    game.stats.total_runs += 1
    save_persistent_stats(&game.stats)
}

// Initialize game statistics
init_game_stats :: proc(stats: ^Game_Stats) {
    // Try to load persistent stats first
    if load_persistent_stats(stats) {
        // Successfully loaded persistent stats, just reset current run
        reset_current_run_stats(stats)
        return
    }
    
    // No persistent stats found, initialize with defaults
    stats.total_runs = 0
    stats.total_deaths = 0
    stats.best_depth_reached = 0
    stats.total_time_played = 0.0
    
    stats.total_blocks_destroyed = 0
    stats.total_items_picked_up = 0
    stats.total_blocks_placed = 0
    stats.total_crafting_attempts = 0
    stats.total_crafting_successes = 0
    
    stats.total_mining_actions = 0
    stats.total_mana_spent = 0
    stats.total_lava_damage_taken = 0
    stats.total_deaths_by_lava = 0
    
    stats.total_levels_visited = 0
    stats.total_portals_used = 0
    stats.total_distance_traveled = 0
    
    stats.wood_logs_collected = 0
    stats.stone_blocks_collected = 0
    stats.iron_ore_collected = 0
    stats.silver_ore_collected = 0
    stats.gold_ore_collected = 0
    stats.gold_rare_ore_collected = 0
    
    reset_current_run_stats(stats)
}

// Reset current run statistics
reset_current_run_stats :: proc(stats: ^Game_Stats) {
    stats.current_run_time = 0.0
    stats.current_run_blocks_destroyed = 0
    stats.current_run_items_picked_up = 0
    stats.current_run_depth_reached = 0
    stats.current_run_mana_spent = 0
}

// Update stats with current run data
update_game_stats :: proc(stats: ^Game_Stats, dt: f32, level_offset: int) {
    stats.total_time_played += dt
    stats.current_run_time += dt
    
    // Update best depth reached
    if level_offset < cast(int)stats.best_depth_reached {
        stats.best_depth_reached = cast(i32)level_offset
    }
    if level_offset < cast(int)stats.current_run_depth_reached {
        stats.current_run_depth_reached = cast(i32)level_offset
    }
}

// Record a mining action
record_mining_action :: proc(stats: ^Game_Stats, mana_cost: u32 = 1) {
    stats.total_mining_actions += 1
    stats.total_mana_spent += mana_cost
    stats.current_run_mana_spent += mana_cost
}

// Record block destruction
record_block_destroyed :: proc(stats: ^Game_Stats, terrain: Terrain_Type) {
    stats.total_blocks_destroyed += 1
    stats.current_run_blocks_destroyed += 1
}

// Record item pickup
record_item_pickup :: proc(stats: ^Game_Stats, item_id: Item_ID) {
    stats.total_items_picked_up += 1
    stats.current_run_items_picked_up += 1
    
    // Track specific items
    #partial switch item_id {
    case .Wood_Log:
        stats.wood_logs_collected += 1
    case .Stone_Block:
        stats.stone_blocks_collected += 1
    case .Iron_Ore:
        stats.iron_ore_collected += 1
    case .Silver_Ore:
        stats.silver_ore_collected += 1
    case .Gold_Ore:
        stats.gold_ore_collected += 1
    case .Gold_Rare_Ore:
        stats.gold_rare_ore_collected += 1
    }
}

// Record lava damage
record_lava_damage :: proc(stats: ^Game_Stats) {
    stats.total_lava_damage_taken += 1
}

// Record death
record_death :: proc(stats: ^Game_Stats, by_lava: bool) {
    stats.total_deaths += 1
    if by_lava {
        stats.total_deaths_by_lava += 1
    }
}

// Save persistent stats to file
save_persistent_stats :: proc(stats: ^Game_Stats) -> bool {
    filename := "gnipahellir_stats.dat"
    
    // Create a simple binary format for stats
    data: [size_of(Game_Stats)]u8
    mem.copy(raw_data(data[:]), stats, size_of(Game_Stats))
    
    // Write to file
    if os.write_entire_file(filename, data[:]) == nil {
        return true
    }

    return false
}

// Load persistent stats from file
load_persistent_stats :: proc(stats: ^Game_Stats) -> bool {
    filename := "gnipahellir_stats.dat"

    // Try to read the file
    data, read_err := os.read_entire_file_from_path(filename, context.allocator)
    if read_err != nil {
        return false
    }
    defer delete(data)
    
    // Check if file size matches expected size
    if len(data) != size_of(Game_Stats) {
        return false
    }
    
    // Copy data to stats struct
    mem.copy(stats, raw_data(data), size_of(Game_Stats))
    
    return true
}

// Save complete game state to file
save_game_state :: proc(game: ^Game_State) -> bool {
    filename := "gnipahellir_save.dat"
    
    // CRITICAL FIX: Save current world state into the appropriate level storage
    // before saving to file, otherwise current modifications will be lost!
    save_current_level(game)
    
    // Use the shared save data structure
    
    // Create save data (use heap allocation for large struct)
    save_data := new(Save_Data)
    defer free(save_data)
    
    save_data.version = 1
    save_data.level_offset = game.level_offset
    save_data.surface_saved = game.surface_saved
    save_data.surface_world = game.surface_world
    save_data.cave_worlds = game.cave_worlds
    save_data.cave_generated = game.cave_generated
    save_data.sky_worlds = game.sky_worlds
    save_data.sky_generated = game.sky_generated
    save_data.player = game.player
    save_data.garm = game.garm
    save_data.inventory = game.inventory
    save_data.ui_bag_open = game.ui.bag_open
    save_data.ui_character_open = game.ui.character_open
    save_data.ui_build_menu_open = game.ui.build_menu_open
    save_data.ui_crafting_open = game.ui.crafting_open
    save_data.ui_debug_open = game.ui.debug_open
    save_data.ui_sound_debug_open = game.ui.sound_debug_open
    save_data.ui_stats_open = game.ui.stats_open
    save_data.ui_inv_x = game.ui.inv_x
    save_data.ui_inv_y = game.ui.inv_y
    save_data.ui_char_x = game.ui.char_x
    save_data.ui_char_y = game.ui.char_y
    save_data.ui_build_x = game.ui.build_x
    save_data.ui_build_y = game.ui.build_y
    save_data.ui_craft_x = game.ui.craft_x
    save_data.ui_craft_y = game.ui.craft_y
    save_data.ui_build_selected = game.ui.build_selected
    save_data.ui_build_scroll = game.ui.build_scroll
    save_data.ui_sound_debug_scroll = game.ui.sound_debug_scroll
    save_data.ui_stats_scroll = game.ui.stats_scroll
    save_data.elapsed_time = game.elapsed_time
    save_data.mana_regen_accumulator = game.mana_regen_accumulator
    save_data.player_dead = game.player_dead
    save_data.death_explosion_done = game.death_explosion_done
    save_data.death_timer = game.death_timer
    save_data.bucket_has_lava = game.bucket_has_lava
    save_data.stats = game.stats
    
    // Convert to bytes and write (use heap allocation for large data)
    data := make([]u8, size_of(Save_Data))
    defer delete(data)
    mem.copy(raw_data(data), save_data, size_of(Save_Data))
    
    if os.write_entire_file(filename, data) == nil {
        return true
    }

    return false
}

// Load complete game state from file
load_game_state :: proc(game: ^Game_State) -> bool {
    filename := "gnipahellir_save.dat"

    // Try to read the file
    data, read_err := os.read_entire_file_from_path(filename, context.allocator)
    if read_err != nil {
        return false
    }
    defer delete(data)
    
    // Check if file size matches expected size (use shared Save_Data struct)
    if len(data) != size_of(Save_Data) {
        fmt.printf("Save file size mismatch! File size: %d, Expected size: %d\n", len(data), size_of(Save_Data))
        return false
    }
    
    // Copy data to save struct (use heap allocation for large struct)
    save_data := new(Save_Data)
    if save_data == nil {
        return false
    }
    defer free(save_data)
    
    mem.copy(save_data, raw_data(data), size_of(Save_Data))
    
    // Check version compatibility
    if save_data.version != 1 {
        fmt.printf("Save file version mismatch! File version: %d, Expected: 1\n", save_data.version)
        return false
    }
    
    // Restore game state
    game.level_offset = save_data.level_offset
    game.surface_saved = save_data.surface_saved
    game.surface_world = save_data.surface_world
    game.cave_worlds = save_data.cave_worlds
    game.cave_generated = save_data.cave_generated
    game.sky_worlds = save_data.sky_worlds
    game.sky_generated = save_data.sky_generated
    game.player = save_data.player
    game.garm = save_data.garm
    game.inventory = save_data.inventory
    game.elapsed_time = save_data.elapsed_time
    game.mana_regen_accumulator = save_data.mana_regen_accumulator
    game.player_dead = save_data.player_dead
    game.death_explosion_done = save_data.death_explosion_done
    game.death_timer = save_data.death_timer
    game.bucket_has_lava = save_data.bucket_has_lava
    game.stats = save_data.stats
    
    // Restore UI state
    game.ui.bag_open = save_data.ui_bag_open
    game.ui.character_open = save_data.ui_character_open
    game.ui.build_menu_open = save_data.ui_build_menu_open
    game.ui.crafting_open = save_data.ui_crafting_open
    game.ui.debug_open = save_data.ui_debug_open
    game.ui.sound_debug_open = save_data.ui_sound_debug_open
    game.ui.stats_open = save_data.ui_stats_open
    game.ui.inv_x = save_data.ui_inv_x
    game.ui.inv_y = save_data.ui_inv_y
    game.ui.char_x = save_data.ui_char_x
    game.ui.char_y = save_data.ui_char_y
    game.ui.build_x = save_data.ui_build_x
    game.ui.build_y = save_data.ui_build_y
    game.ui.craft_x = save_data.ui_craft_x
    game.ui.craft_y = save_data.ui_craft_y
    game.ui.build_selected = save_data.ui_build_selected
    game.ui.build_scroll = save_data.ui_build_scroll
    game.ui.sound_debug_scroll = save_data.ui_sound_debug_scroll
    game.ui.stats_scroll = save_data.ui_stats_scroll
    
    // Load the current world based on level_offset
    if game.level_offset == 0 {
        game.world = game.surface_world  // Simple assignment instead of world_copy
    } else if game.level_offset > 0 {
        idx := game.level_offset - 1
        if idx >= 0 && idx < CAVE_LEVELS {
            game.world = game.cave_worlds[idx]  // Simple assignment instead of world_copy
        }
    } else {
        idx := -game.level_offset - 1
        if idx >= 0 && idx < SKY_LEVELS {
            game.world = game.sky_worlds[idx]  // Simple assignment instead of world_copy
        }
    }
    
    // Place player in the world
    if bounds_check(game.player.tile_x, game.player.tile_y) {
        game.world.entities[game.player.tile_x][game.player.tile_y] = PLAYER_ID
    }
    
    return true
}

// Lava spreading logic: lava flows into adjacent Void/Air/empty tiles downward preference at slow interval (1-3s)
lava_update :: proc(world: ^World_Grid, dt: f32) {
    for x in 0 ..< WORLD_WIDTH {
        for y in 0 ..< WORLD_HEIGHT {
            terrain := world.terrain[x][y]
            if terrain != .Lava && terrain != .Magic_Lava do continue
            world.lava_elapsed[x][y] += dt
            target := world.lava_target[x][y]
            if target <= 0 { world.lava_target[x][y] = cast(f32)(rl.GetRandomValue(1,3)); target = world.lava_target[x][y] }
            // Occasional bubble particle even if not spreading
            if world.lava_elapsed[x][y] > 0.2 && rl.GetRandomValue(0,100) < 4 {
                // Defer actual spawn to main game particles via event? Simpler: directly spawn using global game not in scope.
                // Placeholder: no-op (needs game reference). Real spawning handled in game_update after calling lava_update.
            }
            if world.lava_elapsed[x][y] >= target {
                world.lava_elapsed[x][y] = 0
                world.lava_target[x][y] = cast(f32)(rl.GetRandomValue(1,3))
                // Spread order: down, left, right
                dirs : [3][2]int = { {0,1},{-1,0},{1,0} }
                for d in dirs {
                    nx := x + d[0]; ny := y + d[1]
                    if !bounds_check(nx, ny) do continue
                    if world.terrain[nx][ny] == .Air || world.terrain[nx][ny] == .Void {
                        world.terrain[nx][ny] = terrain // spread same type of lava
                        world.lava_elapsed[nx][ny] = 0
                        world.lava_target[nx][ny] = cast(f32)(rl.GetRandomValue(1,3))
                        break
                    }
                }
            }
        }
    }
}

// Spawn Garm the hell hound in the first underground cave layer
spawn_garm_in_cave :: proc(game: ^Game_State, player_spawn_x: int) {
    // Find a suitable spawn location away from the player spawn shaft
    spawn_attempts := 50
    for attempt in 0..<spawn_attempts {
        // Try to spawn Garm away from the player spawn area
        x := cast(int)rl.GetRandomValue(10, WORLD_WIDTH-10)
        y := cast(int)rl.GetRandomValue(10, WORLD_HEIGHT-10)
        
        // Make sure it's not too close to player spawn
        if abs(x - player_spawn_x) < 8 do continue
        
        // Check if the position is suitable (void space with solid ground below)
        if !bounds_check(x, y) do continue
        if game.world.terrain[x][y] != .Void do continue
        if !bounds_check(x, y+1) do continue
        if game.world.terrain[x][y+1] == .Void do continue // need solid ground below
        
        // Initialize Garm at this position
        enemy_init(&game.garm, x, y, GARM_ID)
        
        // Place Garm in the entity grid
        game.world.entities[x][y] = GARM_ID
        
        break
    }

    // Fallback 1: If still not active, try the guaranteed spawn platform near the shaft
    if !game.garm.active {
        sx := clamp_int(player_spawn_x, 2, WORLD_WIDTH-3)
        yb := WORLD_HEIGHT - 6
        for fx in sx-1 ..= sx+1 {
            fy := yb - 1
            if !bounds_check(fx, fy) || !bounds_check(fx, fy+1) { continue }
            // Need empty space with solid ground below and no entity
            t_here := game.world.terrain[fx][fy]
            t_below := game.world.terrain[fx][fy+1]
            if (t_here == .Void || t_here == .Air) && t_below != .Void && game.world.entities[fx][fy] == INVALID_ENTITY {
                enemy_init(&game.garm, fx, fy, GARM_ID)
                game.world.entities[fx][fy] = GARM_ID
                break
            }
        }
    }

    // Fallback 2: As a last resort, scan the world for any valid tile
    if !game.garm.active {
        placed := false
        for y in 1 ..< WORLD_HEIGHT-1 {
            for x in 1 ..< WORLD_WIDTH-1 {
                if !bounds_check(x, y) || !bounds_check(x, y+1) { continue }
                if game.world.entities[x][y] != INVALID_ENTITY { continue }
                t := game.world.terrain[x][y]
                b := game.world.terrain[x][y+1]
                if (t == .Void || t == .Air) && b != .Void {
                    enemy_init(&game.garm, x, y, GARM_ID)
                    game.world.entities[x][y] = GARM_ID
                    placed = true
                    break
                }
            }
            if placed { break }
        }
    }
}
