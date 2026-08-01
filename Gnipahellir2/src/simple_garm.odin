// Simplified GARM AI - Much easier to understand and debug
package gnipahellir

import "core:math"
import rl "vendor:raylib"
import "core:fmt"

// Simple GARM states - no complex state machine
Simple_Garm_State :: enum {
    Idle,        // Just spawned or lost player
    Chasing,     // Hunting player  
    Building,    // Working on structure
}

// Simple build goals - one at a time, not complex plans
Simple_Build_Goal :: enum {
    None,
    Move_To_Center,      // Get to the center column
    Build_Center_Stone,  // Place stone in center column
    Clear_Above_Stone,   // Mine out space above stones
    Build_Perimeter,     // Build perimeter ring
    Fill_With_Lava,      // Fill interior with lava
}

// Simple GARM data - no complex planning arrays
Simple_Garm :: struct {
    // Basic entity data
    active: bool,
    pos_x, pos_y: f32,
    vel_x, vel_y: f32,
    tile_x, tile_y: int,
    health: int,
    max_health: int,
    
    // Simple AI state
    ai_state: Simple_Garm_State,
    ai_timer: f32,
    
    // Simple building system
    build_goal: Simple_Build_Goal,
    target_x, target_y: int,  // Current tile target
    project_center_x: int,    // Center of the build project
    project_center_y: int,
    project_radius: int,
    
    // Simple movement
    move_target_x, move_target_y: f32,
    stuck_timer: f32,
    last_pos_x, last_pos_y: f32,
    
    // Simple timers
    action_timer: f32,       // Time since last action
    fireball_timer: f32,     // Time since last fireball
    damage_timer: f32,       // Damage cooldown
    
    // Animation
    frame_x: int,
    anim_timer: f32,
}

// Constants for simple system
SIMPLE_GARM_CHASE_RANGE :: 6.0
SIMPLE_GARM_LOSE_RANGE :: 10.0
SIMPLE_GARM_ACTION_INTERVAL :: 0.5  // Half second between actions
SIMPLE_GARM_FIREBALL_INTERVAL :: 1.0
SIMPLE_GARM_MOVEMENT_SPEED :: 4.0
SIMPLE_GARM_JUMP_VELOCITY :: -6.0
SIMPLE_GARM_STUCK_THRESHOLD :: 2.0  // 2 seconds without movement = stuck

// Initialize simple GARM
simple_garm_init :: proc(garm: ^Simple_Garm, x, y: int) {
    garm.active = true
    garm.pos_x = cast(f32)x
    garm.pos_y = cast(f32)y
    garm.tile_x = x
    garm.tile_y = y
    garm.health = 10
    garm.max_health = 10
    
    garm.ai_state = .Idle
    garm.build_goal = .None
    garm.project_center_x = WORLD_WIDTH / 2
    garm.project_center_y = WORLD_HEIGHT / 2
    garm.project_radius = 10
    
    garm.move_target_x = garm.pos_x
    garm.move_target_y = garm.pos_y
    garm.last_pos_x = garm.pos_x
    garm.last_pos_y = garm.pos_y
    
    fmt.printf("Simple GARM initialized at (%d,%d)\n", x, y)
}

// Update simple GARM - much cleaner logic
simple_garm_update :: proc(game: ^Game_State, garm: ^Simple_Garm, dt: f32) {
    if !garm.active do return
    
    // Update timers
    garm.ai_timer += dt
    garm.action_timer += dt
    garm.fireball_timer += dt
    garm.damage_timer += dt
    garm.stuck_timer += dt
    
    // Update tile position
    garm.tile_x = cast(int)(garm.pos_x + 0.5)
    garm.tile_y = cast(int)(garm.pos_y + 0.5)
    
    // Apply gravity
    garm.vel_y += 18.0 * dt  // Same as player gravity
    if garm.vel_y > 12.0 do garm.vel_y = 12.0  // Terminal velocity
    
    // Update AI every 0.2 seconds
    if garm.ai_timer >= 0.2 {
        garm.ai_timer = 0
        simple_garm_update_ai(game, garm)
    }
    
    // Apply movement
    simple_garm_apply_movement(game, garm, dt)
    
    // Check if stuck
    simple_garm_check_stuck(garm, dt)
    
    // Update animation
    simple_garm_update_animation(garm, dt)
}

// Simple AI logic - easy to understand
simple_garm_update_ai :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    player := &game.player
    
    // Calculate distance to player
    dx := player.pos_x - garm.pos_x
    dy := player.pos_y - garm.pos_y
    distance := math.sqrt(dx*dx + dy*dy)
    
    // Simple state transitions
    switch garm.ai_state {
    case .Idle:
        if distance < SIMPLE_GARM_CHASE_RANGE {
            garm.ai_state = .Chasing
            fmt.printf("GARM: Idle -> Chasing (distance: %.1f)\n", distance)
        } else {
            // Start building if no player nearby
            garm.ai_state = .Building
            garm.build_goal = .Move_To_Center
            fmt.printf("GARM: Idle -> Building\n")
        }
        
    case .Chasing:
        if distance > SIMPLE_GARM_LOSE_RANGE {
            garm.ai_state = .Building
            garm.build_goal = .Move_To_Center
            fmt.printf("GARM: Chasing -> Building (lost player)\n")
        } else {
            // Chase the player
            simple_garm_chase_player(game, garm, player)
        }
        
    case .Building:
        if distance < SIMPLE_GARM_CHASE_RANGE {
            garm.ai_state = .Chasing
            fmt.printf("GARM: Building -> Chasing (player close)\n")
        } else {
            // Work on building project
            simple_garm_work_on_building(game, garm)
        }
    }
}

// Simple chase behavior
simple_garm_chase_player :: proc(game: ^Game_State, garm: ^Simple_Garm, player: ^Player) {
    // Set movement target to player
    garm.move_target_x = player.pos_x
    garm.move_target_y = player.pos_y
    
    // Fire fireballs if in range and timer ready
    distance := math.sqrt(math.pow(player.pos_x - garm.pos_x, 2) + math.pow(player.pos_y - garm.pos_y, 2))
    if distance <= 8.0 && garm.fireball_timer >= SIMPLE_GARM_FIREBALL_INTERVAL {
        simple_garm_fire_fireball(game, garm, player)
        garm.fireball_timer = 0
    }
    
    // Jump if blocked or need to reach player
    if simple_garm_should_jump(game, garm) {
        simple_garm_jump(garm)
    }
}

// Simple building work - one goal at a time
simple_garm_work_on_building :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    switch garm.build_goal {
    case .None, .Move_To_Center:
        simple_garm_goal_move_to_center(game, garm)
    case .Build_Center_Stone:
        simple_garm_goal_build_center_stone(game, garm)
    case .Clear_Above_Stone:
        simple_garm_goal_clear_above_stone(game, garm)
    case .Build_Perimeter:
        simple_garm_goal_build_perimeter(game, garm)
    case .Fill_With_Lava:
        simple_garm_goal_fill_lava(game, garm)
    }
}

// Goal: Move to center column
simple_garm_goal_move_to_center :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    center_x := garm.project_center_x
    
    // If already at center X, pick next goal
    if math.abs(garm.tile_x - center_x) <= 1 {
        garm.build_goal = .Build_Center_Stone
        garm.target_x = center_x
        garm.target_y = garm.tile_y
        fmt.printf("GARM: Goal Move_To_Center -> Build_Center_Stone\n")
        return
    }
    
    // Move toward center
    garm.move_target_x = cast(f32)center_x
    garm.move_target_y = garm.pos_y
    
    if simple_garm_should_jump(game, garm) {
        simple_garm_jump(garm)
    }
}

// Goal: Build stone in center column
simple_garm_goal_build_center_stone :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    center_x := garm.project_center_x
    
    // Find a spot to place stone
    for y := garm.tile_y; y < WORLD_HEIGHT - 1; y += 1 {
        if !bounds_check(center_x, y) do continue
        
        terrain := game.world.terrain[center_x][y]
        if terrain == .Air || terrain == .Void {
            // Found empty spot - try to place stone
            garm.target_x = center_x
            garm.target_y = y
            
            // Move to position if not close enough
            if !simple_garm_is_close_to_target(garm, center_x, y) {
                garm.move_target_x = cast(f32)center_x
                garm.move_target_y = cast(f32)y
                if simple_garm_should_jump(game, garm) {
                    simple_garm_jump(garm)
                }
                return
            }
            
            // Place stone if close enough and timer ready
            if garm.action_timer >= SIMPLE_GARM_ACTION_INTERVAL {
                game.world.terrain[center_x][y] = .Stone
                garm.action_timer = 0
                fmt.printf("GARM: Placed stone at (%d,%d)\n", center_x, y)
                return
            }
            return
        }
    }
    
    // No more spots to place stone, move to next goal
    garm.build_goal = .Clear_Above_Stone
    fmt.printf("GARM: Goal Build_Center_Stone -> Clear_Above_Stone\n")
}

// Goal: Clear space above stones
simple_garm_goal_clear_above_stone :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    center_x := garm.project_center_x
    
    // Find stone blocks and clear above them
    for y := 1; y < WORLD_HEIGHT - 2; y += 1 {
        if !bounds_check(center_x, y) do continue
        
        if game.world.terrain[center_x][y] == .Stone {
            // Check 2 tiles above stone
            for clear_y := y - 2; clear_y <= y - 1; clear_y += 1 {
                if !bounds_check(center_x, clear_y) do continue
                
                terrain := game.world.terrain[center_x][clear_y]
                if terrain != .Air && terrain != .Void {
                    // Need to clear this tile
                    garm.target_x = center_x
                    garm.target_y = clear_y
                    
                    // Move to position if not close enough
                    if !simple_garm_is_close_to_target(garm, center_x, clear_y) {
                        garm.move_target_x = cast(f32)center_x
                        garm.move_target_y = cast(f32)clear_y
                        if simple_garm_should_jump(game, garm) {
                            simple_garm_jump(garm)
                        }
                        return
                    }
                    
                    // Clear tile if close enough and timer ready
                    if garm.action_timer >= SIMPLE_GARM_ACTION_INTERVAL {
                        if game.level_offset <= 0 {
                            game.world.terrain[center_x][clear_y] = .Air
                        } else {
                            game.world.terrain[center_x][clear_y] = .Void
                        }
                        garm.action_timer = 0
                        fmt.printf("GARM: Cleared tile at (%d,%d)\n", center_x, clear_y)
                        return
                    }
                    return
                }
            }
        }
    }
    
    // No more clearing needed, move to perimeter
    garm.build_goal = .Build_Perimeter
    fmt.printf("GARM: Goal Clear_Above_Stone -> Build_Perimeter\n")
}

// Goal: Build perimeter (simplified version)
simple_garm_goal_build_perimeter :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    // For now, just move to lava filling
    garm.build_goal = .Fill_With_Lava
    fmt.printf("GARM: Goal Build_Perimeter -> Fill_With_Lava (skipped for simplicity)\n")
}

// Goal: Fill with lava (simplified version)
simple_garm_goal_fill_lava :: proc(game: ^Game_State, garm: ^Simple_Garm) {
    // Basic lava filling around center
    center_x := garm.project_center_x
    center_y := garm.project_center_y
    
    // Look for empty spots near center to fill with lava
    for radius := 1; radius <= 3; radius += 1 {
        for dx := -radius; dx <= radius; dx += 1 {
            for dy := -radius; dy <= radius; dy += 1 {
                x := center_x + dx
                y := center_y + dy
                
                if !bounds_check(x, y) do continue
                if dx*dx + dy*dy > radius*radius do continue
                
                terrain := game.world.terrain[x][y]
                if terrain == .Air || terrain == .Void {
                    // Found spot for lava
                    garm.target_x = x
                    garm.target_y = y
                    
                    // Move to position if not close enough
                    if !simple_garm_is_close_to_target(garm, x, y) {
                        garm.move_target_x = cast(f32)x
                        garm.move_target_y = cast(f32)y
                        if simple_garm_should_jump(game, garm) {
                            simple_garm_jump(garm)
                        }
                        return
                    }
                    
                    // Place lava if close enough and timer ready
                    if garm.action_timer >= SIMPLE_GARM_ACTION_INTERVAL {
                        game.world.terrain[x][y] = .Lava
                        garm.action_timer = 0
                        fmt.printf("GARM: Placed lava at (%d,%d)\n", x, y)
                        return
                    }
                    return
                }
            }
        }
    }
    
    // All done, just wander
    garm.build_goal = .Move_To_Center
    fmt.printf("GARM: Goal Fill_With_Lava -> Move_To_Center (cycle complete)\n")
}

// Helper functions
simple_garm_is_close_to_target :: proc(garm: ^Simple_Garm, target_x, target_y: int) -> bool {
    dx := math.abs(garm.tile_x - target_x)
    dy := math.abs(garm.tile_y - target_y)
    return dx <= 2 && dy <= 2
}

simple_garm_should_jump :: proc(game: ^Game_State, garm: ^Simple_Garm) -> bool {
    // Jump if on ground and there's an obstacle ahead
    if garm.vel_y < 0 do return false  // Already jumping
    
    // Check if on ground
    foot_y := cast(int)(garm.pos_y + 0.6)
    if !bounds_check(garm.tile_x, foot_y + 1) do return false
    if !tile_is_solid(&game.world, garm.tile_x, foot_y + 1) do return false
    
    // Check if blocked ahead
    ahead_x := garm.tile_x
    if garm.move_target_x > garm.pos_x do ahead_x += 1
    else if garm.move_target_x < garm.pos_x do ahead_x -= 1
    
    if bounds_check(ahead_x, foot_y) && tile_is_solid(&game.world, ahead_x, foot_y) {
        return true
    }
    
    // Jump if there's a gap ahead
    if bounds_check(ahead_x, foot_y + 1) && !tile_is_solid(&game.world, ahead_x, foot_y + 1) {
        return true
    }
    
    return false
}

simple_garm_jump :: proc(garm: ^Simple_Garm) {
    if garm.vel_y >= -1.0 {  // Only jump if not already jumping hard
        garm.vel_y = SIMPLE_GARM_JUMP_VELOCITY
        fmt.printf("GARM: Jump!\n")
    }
}

simple_garm_fire_fireball :: proc(game: ^Game_State, garm: ^Simple_Garm, player: ^Player) {
    // Simple fireball spawning (implementation depends on your fireball system)
    fmt.printf("GARM: Fire fireball at player!\n")
    // TODO: Spawn fireball projectile toward player
}

simple_garm_apply_movement :: proc(game: ^Game_State, garm: ^Simple_Garm, dt: f32) {
    // Simple movement toward target
    speed : f32 = SIMPLE_GARM_MOVEMENT_SPEED
    
    // Horizontal movement
    dx := garm.move_target_x - garm.pos_x
    if math.abs(dx) > 0.1 {
        if dx > 0 {
            garm.vel_x = speed
        } else {
            garm.vel_x = -speed
        }
    } else {
        garm.vel_x = 0
    }
    
    // Apply velocity with collision detection
    new_x := garm.pos_x + garm.vel_x * dt
    new_y := garm.pos_y + garm.vel_y * dt
    
    // Simple collision detection (horizontal)
    test_x := cast(int)(new_x + 0.5)
    if bounds_check(test_x, garm.tile_y) && !tile_is_solid(&game.world, test_x, garm.tile_y) {
        garm.pos_x = new_x
    } else {
        garm.vel_x = 0
    }
    
    // Simple collision detection (vertical)
    test_y := cast(int)(new_y + 0.5)
    if bounds_check(garm.tile_x, test_y) && !tile_is_solid(&game.world, garm.tile_x, test_y) {
        garm.pos_y = new_y
    } else {
        if garm.vel_y > 0 {  // Hit ground
            garm.vel_y = 0
        }
    }
}

simple_garm_check_stuck :: proc(garm: ^Simple_Garm, dt: f32) {
    // Check if GARM hasn't moved much
    dx := math.abs(garm.pos_x - garm.last_pos_x)
    dy := math.abs(garm.pos_y - garm.last_pos_y)
    
    if dx < 0.1 && dy < 0.1 {
        garm.stuck_timer += dt
        if garm.stuck_timer >= SIMPLE_GARM_STUCK_THRESHOLD {
            // Try to get unstuck with a jump
            simple_garm_jump(garm)
            garm.stuck_timer = 0
            fmt.printf("GARM: Unstuck jump!\n")
        }
    } else {
        garm.stuck_timer = 0
        garm.last_pos_x = garm.pos_x
        garm.last_pos_y = garm.pos_y
    }
}

simple_garm_update_animation :: proc(garm: ^Simple_Garm, dt: f32) {
    garm.anim_timer += dt
    if garm.anim_timer >= 0.2 {
        garm.anim_timer = 0
        garm.frame_x = (garm.frame_x + 1) % 4  // Assuming 4 animation frames
    }
}

simple_garm_take_damage :: proc(garm: ^Simple_Garm, damage: int) -> bool {
    if garm.damage_timer < 0.5 do return false  // Damage cooldown
    
    garm.health -= damage
    garm.damage_timer = 0
    fmt.printf("GARM: Took %d damage, health now %d\n", damage, garm.health)
    
    if garm.health <= 0 {
        garm.active = false
        fmt.printf("GARM: Defeated!\n")
        return true
    }
    return false
}
