package gnipahellir

import "core:math"
import rl "vendor:raylib/v55"

// Player data & movement (Phase 1)

Player :: struct {
    // Discrete tile the player currently occupies (derived from pos each frame)
    tile_x, tile_y : int,
    // Continuous world position in tile units (0,0) top-left
    pos_x, pos_y : f32,
    // Visual position (can diverge for effects; currently mirrors pos)
    visual_x, visual_y : f32,
    // Velocity in tiles/second
    vel_x, vel_y : f32,
    // Legacy move timer (kept for potential action cooldowns)
    move_timer : f32,
    gravity_accum : f32, // unused after velocity gravity, kept for compatibility
    health, max_health : i32,
    mana, max_mana     : i32,
    // Equipment (simple: main_hand tool/weapon)
    main_hand : Item_ID,
    // Movement capability flags
    can_fly : bool, // when true, allow free vertical movement (future buff)
    facing_right : bool, // sprite orientation (true=right)
    walk_anim_timer : f32, // accumulator for walk frame switching
    walk_anim_frame : int, // 0 or 1
    lava_damage_timer : f32, // timer for lava damage ticks
    clothing_r, clothing_g, clothing_b : u8, // base clothing color
    hair_r, hair_g, hair_b : u8, // hair/base accent color
}

// Compute wand tip world position in pixels (world coordinate space) if Mine_Wand equipped.
// Returns (x,y,ok). ok=false if wand not equipped.
player_wand_tip_world :: proc(p: ^Player) -> (f32, f32, bool) {
    if p.main_hand != .Mine_Wand { return 0,0,false }
    // Mirror placement logic from draw_player_pixels: sprite centered at (visual_x*TILE_SIZE, visual_y*TILE_SIZE)
    pixel_size := TILE_SIZE/8
    if pixel_size < 1 { pixel_size = 1 }
    total_w := FRAME_WIDTH * pixel_size
    total_h := FRAME_HEIGHT * pixel_size
    base_x := p.visual_x*TILE_SIZE
    base_y := p.visual_y*TILE_SIZE
    origin_x := base_x - cast(f32)total_w/2
    origin_y := base_y - cast(f32)total_h + cast(f32)pixel_size
    // In render we place wand starting at side facing mouse
    wand_base_x : f32
    if p.facing_right { wand_base_x = origin_x + cast(f32)(total_w - pixel_size*2) } else { wand_base_x = origin_x + cast(f32)(pixel_size) }
    wand_base_y := origin_y + cast(f32)(pixel_size*6)
    // Tip after steps-1 along diagonal (steps=5 for wand)
    steps : int = 5
    dir : f32 = 1
    if !p.facing_right { dir = -1 }
    half_step := cast(f32)0.5
    tip_x := wand_base_x + (cast(f32)(steps-1) + half_step)*cast(f32)pixel_size*dir
    tip_y := wand_base_y - (cast(f32)(steps-1) + half_step)*cast(f32)pixel_size
    return tip_x, tip_y, true
}

player_init :: proc(p: ^Player, x, y: int) {
    p.tile_x = x; p.tile_y = y
    p.pos_x = cast(f32)x
    p.pos_y = cast(f32)y
    p.visual_x = p.pos_x
    p.visual_y = p.pos_y
    p.vel_x = 0; p.vel_y = 0
    p.health = 10; p.max_health = 10
    p.mana = 20; p.max_mana = 20
    p.gravity_accum = 0
    p.main_hand = .None
    p.can_fly = false
    p.facing_right = true
    p.walk_anim_timer = 0
    p.walk_anim_frame = 0
    p.lava_damage_timer = 0
    // Randomize clothing palette
    palettes : [4][3]u8 = { {70,90,200}, {160,60,180}, {40,140,80}, {180,120,50} }
    idx := rl.GetRandomValue(0, cast(i32)len(palettes)-1)
    p.clothing_r = palettes[idx][0]
    p.clothing_g = palettes[idx][1]
    p.clothing_b = palettes[idx][2]
    // Hair fixed golden.
    p.hair_r = 230; p.hair_g = 200; p.hair_b = 60
}

// player_try_move_or_attack no longer performs discrete tile stepping; placeholder retained for future combat
player_try_move_or_attack :: proc(game: ^Game_State, dx, dy: int) -> bool { _ = game; _ = dx; _ = dy; return false }

player_update :: proc(game: ^Game_State, dt: f32) {
    p := &game.player

    // Apply gravity to vertical velocity
    gravity_accel : f32 = 18 // tiles/s^2 downward
    terminal_vel  : f32 = 12
    p.vel_y += gravity_accel * dt
    if p.vel_y > terminal_vel do p.vel_y = terminal_vel

    // Desired motion
    dx := p.vel_x * dt
    dy := p.vel_y * dt

    // Horizontal move with tile boundary collision (treat player as point)
    if dx != 0 {
        new_pos_x := p.pos_x + dx
        // Determine if crossing into a new tile horizontally
        old_tile_x := p.tile_x
        new_tile_x := cast(int)new_pos_x
        if new_tile_x != old_tile_x {
            // Check tile in movement direction at current vertical tile
            target_tile_x := new_tile_x
            target_tile_y := p.tile_y
            if tile_is_solid(&game.world, target_tile_x, target_tile_y) {
                // Block: clamp to edge and zero horizontal velocity
                if dx > 0 {
                    p.pos_x = cast(f32)old_tile_x + 0.999
                } else {
                    p.pos_x = cast(f32)old_tile_x
                }
                p.vel_x = 0
            } else {
                p.pos_x = new_pos_x
            }
        } else {
            p.pos_x = new_pos_x
        }
    }

    // Vertical move with collision
    if dy != 0 {
        new_pos_y := p.pos_y + dy
        old_tile_y := p.tile_y
        new_tile_y := cast(int)new_pos_y
        if new_tile_y != old_tile_y {
            target_tile_x := p.tile_x
            target_tile_y := new_tile_y
            if tile_is_solid(&game.world, target_tile_x, target_tile_y) {
                // Land / hit ceiling
                if dy > 0 { // falling onto solid
                    p.pos_y = cast(f32)old_tile_y + 0.999
                } else { // hitting ceiling
                    p.pos_y = cast(f32)old_tile_y
                }
                p.vel_y = 0
            } else {
                p.pos_y = new_pos_y
            }
        } else {
            p.pos_y = new_pos_y
        }
    }

    // Update derived tile indices & entity grid if changed
    new_tile_x := cast(int)p.pos_x
    new_tile_y := cast(int)p.pos_y
    if new_tile_x != p.tile_x || new_tile_y != p.tile_y {
        old_x := p.tile_x; old_y := p.tile_y
        // Clear old
        if bounds_check(old_x, old_y) {
            if game.world.entities[old_x][old_y] == PLAYER_ID {
                game.world.entities[old_x][old_y] = INVALID_ENTITY
            }
        }
        p.tile_x = new_tile_x; p.tile_y = new_tile_y
        if bounds_check(p.tile_x, p.tile_y) {
            game.world.entities[p.tile_x][p.tile_y] = PLAYER_ID
        }
        _ = event_queue_push(&game.events, Event{type = .Movement, source_id = PLAYER_ID, target_id = PLAYER_ID, data = Movement_Event{entity = PLAYER_ID, from_x = old_x, from_y = old_y, to_x = p.tile_x, to_y = p.tile_y}})
    }

    // Lava damage: take damage when standing on lava or inside lava
    if bounds_check(p.tile_x, p.tile_y) {
        terrain := game.world.terrain[p.tile_x][p.tile_y]
        // Also check tile below player for standing on lava
        below_tile_terrain : Terrain_Type = .Air
        if bounds_check(p.tile_x, p.tile_y + 1) {
            below_tile_terrain = game.world.terrain[p.tile_x][p.tile_y + 1]
        }
        
        if terrain == .Lava || terrain == .Magic_Lava || below_tile_terrain == .Lava || below_tile_terrain == .Magic_Lava {
            // Take damage every 0.5 seconds
            p.lava_damage_timer += dt
                            if p.lava_damage_timer >= 0.5 {
                    p.health = max(p.health - 1, 0)
                    p.lava_damage_timer = 0
                    
                    // Record lava damage
                    record_lava_damage(&game.stats)
                
                // Check for death
                if p.health <= 0 && !game.player_dead {
                    game.player_dead = true
                    game.death_timer = 0.0
                    
                    // Record death statistics
                    record_death(&game.stats, true) // Death by lava
                    
                    // Save persistent stats
                    save_persistent_stats(&game.stats)
                    
                    // Play death explosion sound
                    _ = event_queue_push(&game.events, Event{
                        type = .Play_Sound,
                        source_id = PLAYER_ID,
                        target_id = PLAYER_ID,
                        data = Sound_Event{ sound_id = .DEATH_EXPLOSION, volume = -1 }
                    })
                    
                    // Spawn death explosion
                    wx := cast(f32)(p.tile_x*TILE_SIZE + TILE_SIZE/2)
                    wy := cast(f32)(p.tile_y*TILE_SIZE + TILE_SIZE/2)
                    particle_spawn_death_explosion(&game.particles, wx, wy)
                    
                    // Destroy blocks in radius around player
                    destroy_blocks_around_player(game, p.tile_x, p.tile_y, 3) // 3 tile radius
                } else if p.health > 0 {
                    // Show damage feedback
                    game.ui.popup_active = true
                    game.ui.popup_text = "Lava burns!"
                    game.ui.popup_time = 0.5
                }
            }
        } else {
            p.lava_damage_timer = 0
        }
    }

    // Visual position directly follows continuous position (no centering snap)
    p.visual_x = p.pos_x
    p.visual_y = p.pos_y

    // Update walking animation: alternate frames while moving horizontally
    speed_threshold : f32 = 0.15
    if math.abs(p.vel_x) > speed_threshold {
        // Only advance when roughly on ground (vertical velocity small) to avoid rapid cycling while falling
        if math.abs(p.vel_y) < 0.5 {
            p.walk_anim_timer += dt
            frame_period : f32 = 0.25
            if p.walk_anim_timer >= frame_period {
                p.walk_anim_timer -= frame_period
                p.walk_anim_frame = 1 - p.walk_anim_frame // toggle 0<->1
            }
        }
    } else {
        // Idle -> reset to base frame
        p.walk_anim_frame = 0
        p.walk_anim_timer = 0
    }
}

// Equip one item from an inventory slot into main hand (consumes 1 count) and
// returns true if an equip occurred. Handles swapping previous main hand back
// into inventory (finding an existing stack or empty slot). If the slot is not
// equipable or empty, returns false.
equip_inventory_slot_to_main_hand :: proc(game: ^Game_State, slot_index: int) -> bool {
    if slot_index < 0 || slot_index >= INV_MAX_SLOTS do return false
    stack := &game.inventory.slots[slot_index]
    if stack.id == .None do return false
    if !item_is_equipable(stack.id) do return false
    prev := game.player.main_hand
    game.player.main_hand = stack.id
    // consume one
    if stack.count > 0 { stack.count -= 1 }
    if stack.count == 0 { stack.id = .None }
    if prev != .None {
        // try merge
        for i in 0..<INV_MAX_SLOTS {
            if game.inventory.slots[i].id == prev { game.inventory.slots[i].count += 1; prev = .None; break }
        }
        if prev != .None {
            for i in 0..<INV_MAX_SLOTS {
                if game.inventory.slots[i].id == .None { game.inventory.slots[i] = Item_Stack{ id = prev, count = 1 }; prev = .None; break }
            }
        }
    }
    return true
}

// Destroy blocks in a radius around the player when they die
destroy_blocks_around_player :: proc(game: ^Game_State, center_x, center_y, radius: int) {
    for dx := -radius; dx <= radius; dx += 1 {
        for dy := -radius; dy <= radius; dy += 1 {
            // Check if within circular radius
            if dx*dx + dy*dy <= radius*radius {
                x := center_x + dx
                y := center_y + dy
                
                if bounds_check(x, y) {
                    terrain := game.world.terrain[x][y]
                    // Don't destroy air, void, or lava (let lava stay)
                    if terrain != .Air && terrain != .Void && terrain != .Lava && terrain != .Magic_Lava {
                        // Convert terrain to appropriate drops
                        drop_id : Item_ID = .None
                        #partial switch terrain {
                        case .Wood:
                            drop_id = .Wood_Log
                        case .Leaves:
                            drop_id = .Leaf
                        case .Stone:
                            drop_id = .Stone_Block
                        case .Grass:
                            drop_id = .Grass_Turf
                        case .Iron:
                            drop_id = .Iron_Ore
                        case .Silver:
                            drop_id = .Silver_Ore
                        case .Gold:
                            drop_id = .Gold_Ore
                        case .Gold_Rare:
                            drop_id = .Gold_Rare_Ore
                        case .Crafting_Bench:
                            drop_id = .Crafting_Bench
                        case .Tree_Grower:
                            drop_id = .Tree_Grower
                        case .Smelter:
                            drop_id = .Smelter
                        }
                        
                        // Clear the terrain
                        game.world.terrain[x][y] = .Air
                        
                        // Spawn the drop if there is one
                        if drop_id != .None {
                            game.world.items[x][y] = drop_id
                            game.world.item_counts[x][y] = 1
                        }
                        
                        // Clear any entities
                        game.world.entities[x][y] = INVALID_ENTITY
                    }
                }
            }
        }
    }
}
