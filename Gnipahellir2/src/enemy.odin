package gnipahellir

import "core:math"
import rl "vendor:raylib"
import fmt "core:fmt"

// Enemy data structure for Garm the hell hound
Enemy :: struct {
    // Discrete tile the enemy currently occupies
    tile_x, tile_y : int,
    // Continuous world position in tile units
    pos_x, pos_y : f32,
    // Visual position (can diverge for effects)
    visual_x, visual_y : f32,
    // Velocity in tiles/second
    vel_x, vel_y : f32,
    // Health system
    health, max_health : i32,
    // Movement and animation
    facing_right : bool,
    walk_anim_timer : f32,
    walk_anim_frame : int,
    // AI behavior
    target_x, target_y : f32, // current movement target
    ai_timer : f32, // timer for AI decision making
    ai_state : Enemy_AI_State,
    // Building/chill behavior timers
    build_timer : f32, // accumulates time between build/mine actions
    bored_timer : f32, // time near a still player; used to drop aggro
    // Builder project (ring + lava fill)
    project_active : bool,
    project_center_x, project_center_y : int,
    project_radius  : int,
    project_phase   : Enemy_Project_Phase,
    project_index   : int,
    // Recently modified tiles to avoid hammering the same spot repeatedly
    recent : [24]Recent_Mod,
    // Damage system
    damage_timer : f32, // invincibility frames after taking damage
    // Attack system
    fireball_timer : f32, // timer for fireball attacks
    fireball_cooldown : f32, // time between fireball attacks
    // Entity tracking
    entity_id : Entity_ID,
    active : bool, // whether this enemy is alive and active
    // Stuck detection
    last_tile_x, last_tile_y : int,
    stuck_timer : f32,
    // Simple build plan buffer (up to 20 actions)
    plan         : [20]Enemy_Plan_Action,
    plan_len     : int,
    plan_cursor  : int,
    plan_lock_steps : int, // must complete at least this many steps before replanning
    // Plan execution diagnostics
    plan_noop_streak : int,   // consecutive Mine/Place steps that completed without changing terrain
    last_step_was_noop : bool, // set by executor when a step completes without a world change
    plan_step_timeout : f32,   // time spent on current plan step (for timeout detection)
    // MoveTo nudge control
    move_prev_dx : f32,
    move_stagnant_ticks : int,
    // Debug rays (visualize which tiles Garm is checking)
    debug_rays : [32]Enemy_Debug_Ray,
    // Horizontal center-row sweep state
    sweep_active : bool,
    sweep_dir    : int, // -1 left, +1 right
    sweep_y      : int,
    // Simple build mode
    build_mode   : Enemy_Build_Mode,
    circle_cx, circle_cy : int,
    circle_radius : int,
    // Targeting during circle building
    circle_target_x : int,
    circle_target_y : int,
    circle_thickness : int,
}

Enemy_AI_State :: enum {
    Idle,
    Wandering,
    Chasing,
    Jumping,
    Charging, // Fast aggressive charge at player
    Distracted, // Loses interest, mines/replaces blocks
}

Enemy_Project_Phase :: enum { None, Center_Column, Perimeter, Filling_Lava, Exiting_Circle, Closing_Circle, Project_Complete }

// Simple explicit build modes for the lightweight AI path
Enemy_Build_Mode :: enum { Build_Line, Build_Circle }

// Simple action plan for Garm
Enemy_Plan_Action_Type :: enum { MoveTo, Mine, Place, Jump }

Enemy_Plan_Action :: struct {
    kind : Enemy_Plan_Action_Type,
    x, y : int,                 // target tile for action
    material : Terrain_Type,    // for Place actions
}

// Debug ray to visualize a tile Garm is checking
Enemy_Debug_Ray :: struct {
    x, y : int,
    life : int,       // frames remaining; 0 == inactive
    color : rl.Color,
}

enemy_debug_ray_add :: proc(enemy: ^Enemy, x, y: int, color: rl.Color, life: int) {
    if life <= 0 do return
    // Try to find a free slot
    free_idx := -1
    weakest_idx := 0
    weakest_life := 1000000
    for i in 0 ..< len(enemy.debug_rays) {
        r := &enemy.debug_rays[i]
        if r.life <= 0 && free_idx < 0 { free_idx = i }
        if r.life < weakest_life { weakest_life = r.life; weakest_idx = i }
    }
    idx := free_idx
    if idx < 0 { idx = weakest_idx }
    enemy.debug_rays[idx] = Enemy_Debug_Ray{ x = x, y = y, life = life, color = color }
}

// Track a small set of recently modified tiles to avoid repeatedly mining/placing the
// same location every AI loop. Cooldown measured in AI update ticks.
Recent_Mod :: struct {
    x, y    : int,
    cooldown: int,
    active  : bool,
}

recent_can_modify :: proc(enemy: ^Enemy, x, y: int) -> bool {
    for i in 0 ..< len(enemy.recent) {
        r := &enemy.recent[i]
        if r.active && r.cooldown > 0 && r.x == x && r.y == y {
            return false
        }
    }
    return true
}

recent_mark_modified :: proc(enemy: ^Enemy, x, y: int) {
    // Refresh existing entry or allocate a free one
    free_idx := -1
    for i in 0 ..< len(enemy.recent) {
        r := &enemy.recent[i]
        if r.active && r.x == x && r.y == y {
            r.cooldown = cast(int)rl.GetRandomValue(4, 10)
            return
        }
        if free_idx < 0 && (!r.active || r.cooldown <= 0) {
            free_idx = i
        }
    }
    idx := free_idx
    if idx < 0 {
        // Overwrite a random slot when all are active
        idx = cast(int)rl.GetRandomValue(0, cast(i32)len(enemy.recent)-1)
    }
    enemy.recent[idx] = Recent_Mod{ x = x, y = y, cooldown = cast(int)rl.GetRandomValue(4, 10), active = true }
}

recent_tick :: proc(enemy: ^Enemy) {
    for i in 0 ..< len(enemy.recent) {
        r := &enemy.recent[i]
        if r.active && r.cooldown > 0 {
            r.cooldown -= 1
            if r.cooldown <= 0 { r.active = false }
        }
    }
}

// Returns true if (x,y) is part of the reserved void channel above the center stone column
is_reserved_void_tile :: proc(game: ^Game_State, enemy: ^Enemy, x, y: int) -> bool {
    if x != enemy.project_center_x { return false }
    // If there is stone 1 or 2 tiles below, this spot should remain empty
    y1 := y + 1
    y2 := y + 2
    if bounds_check(x, y1) && game.world.terrain[x][y1] == .Stone { return true }
    if bounds_check(x, y2) && game.world.terrain[x][y2] == .Stone { return true }
    return false
}

// Constants for enemy behavior
ENEMY_SPEED :: 4.0 // tiles per second (much faster than player)
ENEMY_JUMP_VELOCITY :: -11.0 // upward velocity for jumping (very high jump)
ENEMY_CHASE_RANGE :: 15.0 // tiles (very long detection range)
// Garm-specific proximity tuning
GARM_CHASE_TRIGGER_RANGE :: 5.0 // switch to combat when within this range
GARM_CHASE_LOSE_RANGE    :: 8.0 // leave combat if farther than this
GARM_BUILD_ACTION_INTERVAL :: 0.30 // seconds between build/mine actions (more frequent)
GARM_BORED_TIME :: 2.0 // seconds of still player at melee range to lose interest
GARM_PROJECT_RADIUS :: 10 // 20 tiles wide (diameter)
GARM_PROJECT_SAMPLES :: 24 // perimeter sampling granularity
ENEMY_AI_UPDATE_INTERVAL :: 0.10 // seconds between AI updates (more responsive)
ENEMY_DAMAGE_COOLDOWN :: 0.3 // seconds of invincibility after damage (shorter)
FIREBALL_SPEED :: 8.0 // tiles per second for fireball projectiles
FIREBALL_RANGE :: 10.0 // max range for fireball attacks
// Vision and anti-stuck
GARM_SIGHT_RANGE :: 20 // tiles radius vision for choosing goals
GARM_STUCK_TIME :: 0.9 // seconds staying on the same tile before unstuck action (react quicker)

// Fireball projectile system
MAX_FIREBALLS :: 8

Fireball :: struct {
    active : bool,
    pos_x, pos_y : f32,
    vel_x, vel_y : f32,
    life_time : f32, // how long the fireball has existed
    max_life : f32, // max lifetime before disappearing
}

Enemy_Fireballs :: struct {
    data : [MAX_FIREBALLS]Fireball
}

// Initialize enemy at given position
enemy_init :: proc(enemy: ^Enemy, x, y: int, id: Entity_ID) {
    enemy.tile_x = x
    enemy.tile_y = y
    enemy.pos_x = cast(f32)x
    enemy.pos_y = cast(f32)y
    enemy.visual_x = enemy.pos_x
    enemy.visual_y = enemy.pos_y
    enemy.vel_x = 0
    enemy.vel_y = 0
    enemy.health = 10
    enemy.max_health = 10
    enemy.facing_right = true
    enemy.walk_anim_timer = 0
    enemy.walk_anim_frame = 0
    enemy.target_x = enemy.pos_x
    enemy.target_y = enemy.pos_y
    enemy.ai_timer = 0
    enemy.ai_state = .Distracted // default to building/chilling
    enemy.build_timer = 0
    enemy.bored_timer = 0
    enemy.project_active = false
    enemy.project_center_x = x
    enemy.project_center_y = y
    enemy.project_radius = GARM_PROJECT_RADIUS
    enemy.project_phase = .None
    enemy.project_index = 0
    enemy.damage_timer = 0
    enemy.fireball_timer = 0
    enemy.fireball_cooldown = 1.0 // 1 second between fireballs
    enemy.entity_id = id
    enemy.active = true
    enemy.last_tile_x = x
    enemy.last_tile_y = y
    enemy.stuck_timer = 0
    enemy.plan_len = 0
    enemy.plan_cursor = 0
    enemy.plan_lock_steps = 0
    enemy.plan_noop_streak = 0
    enemy.last_step_was_noop = false
    enemy.plan_step_timeout = 0
    enemy.move_prev_dx = 1.0e9
    enemy.move_stagnant_ticks = 0
    // init debug rays
    for i in 0 ..< len(enemy.debug_rays) { enemy.debug_rays[i].life = 0 }
    // Init sweep across center horizontal line
    enemy.sweep_active = true
    enemy.sweep_dir = 1 if rl.GetRandomValue(0,1) == 1 else -1
    enemy.sweep_y = WORLD_HEIGHT/2
    // Init simple build mode: start with horizontal line, then circle
    enemy.build_mode = .Build_Line
    enemy.circle_cx = WORLD_WIDTH/2
    enemy.circle_cy = enemy.sweep_y
    enemy.circle_radius = 7 // 15x15 diameter
    enemy.circle_target_x = -1
    enemy.circle_target_y = -1
    enemy.circle_thickness = 2
}

// Update enemy AI and movement
enemy_update :: proc(game: ^Game_State, enemy: ^Enemy, dt: f32) {
    if !enemy.active do return

    // Apply gravity to vertical velocity (like player)
    gravity_accel : f32 = 18
    terminal_vel  : f32 = 12
    enemy.vel_y += gravity_accel * dt
    if enemy.vel_y > terminal_vel do enemy.vel_y = terminal_vel

    // Update AI (sets desired horizontal vel and performs build/remove actions)
    enemy_update_ai(game, enemy, dt)

    // Apply movement and collisions
    enemy_apply_movement(game, enemy, dt)

    // Update animation
    enemy_update_animation(enemy, dt)

    // Update damage timer
    if enemy.damage_timer > 0 {
        enemy.damage_timer -= dt
    }

    // Simple fireball behavior kept (optional). Disable shooting while focused on building.
    enemy.fireball_timer += dt

    // Update visual position to match actual position
    enemy.visual_x = enemy.pos_x
    enemy.visual_y = enemy.pos_y
}

// Grounded check using tile collision rather than velocity (reliable even before movement resolution)
enemy_is_on_ground :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    tx := enemy.tile_x
    ty := enemy.tile_y
    // Require inside world and standing in non-solid with solid directly below
    if !bounds_check(tx, ty) { return false }
    below_solid := tile_is_solid(&game.world, tx, ty+1)
    here_solid := tile_is_solid(&game.world, tx, ty)
    if here_solid { return false }
    if !below_solid { return false }
    // Snap threshold: land places pos_y to old_tile_y + 0.999
    frac := enemy.pos_y - cast(f32)ty
    return frac >= 0.98 || enemy.vel_y == 0
}

// AI behavior update
// New, simplified GARM movement/build system constants
GARM_SCAN_RADIUS_TILES :: 4   // 8x8 area (diameter)
GARM_LOCAL_ACTION_RANGE :: 2  // 4x4 area (diameter)

// Helper: set a tile to Air or Void depending on level
set_empty_for_level :: proc(game: ^Game_State, x, y: int) {
    if !bounds_check(x, y) do return
    desired : Terrain_Type = .Air
    if game.level_offset > 0 { desired = .Void }
    game.world.terrain[x][y] = desired
}

// Basic forward direction toward center X
garm_forward_dir :: proc(enemy: ^Enemy) -> int {
    cx := WORLD_WIDTH/2
    if enemy.pos_x < cast(f32)cx-0.05 { return 1 }
    if enemy.pos_x > cast(f32)cx+0.05 { return -1 }
    if enemy.facing_right { return 1 }
    return -1
}

// Try a jump if blocked or at a ledge
garm_consider_jump :: proc(game: ^Game_State, enemy: ^Enemy) {
    dir := garm_forward_dir(enemy)
    ahead_x := enemy.tile_x + dir
    y := enemy.tile_y
    // If obstacle at current y ahead, jump
    if bounds_check(ahead_x, y) && tile_is_solid(&game.world, ahead_x, y) {
        enemy.vel_y = ENEMY_JUMP_VELOCITY
        return
    }
    // If gap ahead, jump
    if bounds_check(ahead_x, y+1) && !tile_is_solid(&game.world, ahead_x, y+1) {
        enemy.vel_y = ENEMY_JUMP_VELOCITY
        return
    }
}

// Check if Garm should jump when in circle mode with no target
// Only jump if there's a significant obstacle that would prevent any movement
garm_should_jump_in_circle_mode :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    // Don't jump if we're already in the air
    if enemy.vel_y < 0 do return false
    
    // Check if there's a solid wall directly ahead that would block all movement
    dir := garm_forward_dir(enemy)
    ahead_x := enemy.tile_x + dir
    y := enemy.tile_y
    
    // Only jump if there's a solid wall at head level AND we're not at the center
    cx := WORLD_WIDTH/2
    if math.abs(enemy.tile_x - cx) <= 1 do return false  // Don't jump when at center
    
    if bounds_check(ahead_x, y) && tile_is_solid(&game.world, ahead_x, y) {
        // Also check if there's a gap below that would make jumping necessary
        if bounds_check(ahead_x, y+1) && !tile_is_solid(&game.world, ahead_x, y+1) {
            return true
        }
    }
    
    return false
}

// Try to place a stone step ahead, if allowed, with simple support
garm_try_place_step_ahead :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    dir := garm_forward_dir(enemy)
    x := enemy.tile_x + dir
    y := enemy.tile_y
    if !bounds_check(x, y) do return false
    if tile_is_solid(&game.world, x, y) do return false
    // require support below
    if !bounds_check(x, y+1) || !tile_is_solid(&game.world, x, y+1) do return false
    if !recent_can_modify(enemy, x, y) do return false
    game.world.terrain[x][y] = .Stone
    garm_action_log(game, fmt.tprintf("PLACE step (%d,%d)", x, y))
    enemy_debug_ray_add(enemy, x, y, rl.SKYBLUE, 18)
    recent_mark_modified(enemy, x, y)
    return true
}

// Helpers that aim toward a specific X (used in Circle build mode)
garm_forward_dir_to :: proc(enemy: ^Enemy, target_x: int) -> int {
    if enemy.pos_x < cast(f32)target_x-0.05 { return 1 }
    if enemy.pos_x > cast(f32)target_x+0.05 { return -1 }
    if enemy.facing_right { return 1 }
    return -1
}

garm_consider_jump_toward :: proc(game: ^Game_State, enemy: ^Enemy, target_x: int) {
    dir := garm_forward_dir_to(enemy, target_x)
    ahead_x := enemy.tile_x + dir
    y := enemy.tile_y
    if bounds_check(ahead_x, y) && tile_is_solid(&game.world, ahead_x, y) {
        enemy.vel_y = ENEMY_JUMP_VELOCITY
        return
    }
    if bounds_check(ahead_x, y+1) && !tile_is_solid(&game.world, ahead_x, y+1) {
        enemy.vel_y = ENEMY_JUMP_VELOCITY
        return
    }
}

garm_try_place_step_ahead_toward :: proc(game: ^Game_State, enemy: ^Enemy, target_x: int) -> bool {
    dir := garm_forward_dir_to(enemy, target_x)
    x := enemy.tile_x + dir
    y := enemy.tile_y
    if !bounds_check(x, y) do return false
    if tile_is_solid(&game.world, x, y) do return false
    if !bounds_check(x, y+1) || !tile_is_solid(&game.world, x, y+1) do return false
    if !recent_can_modify(enemy, x, y) do return false
    game.world.terrain[x][y] = .Stone
    garm_action_log(game, fmt.tprintf("PLACE step->target (%d,%d)", x, y))
    enemy_debug_ray_add(enemy, x, y, rl.SKYBLUE, 18)
    recent_mark_modified(enemy, x, y)
    return true
}

// If Garm is below the center row and has a solid tile directly above his head,
// clear it to create headroom so he can jump up.
garm_clear_overhead_if_stuck :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    cy := WORLD_HEIGHT/2
    if enemy.tile_y <= cy { return false }
    x := enemy.tile_x
    y := enemy.tile_y - 1 // tile over his head
    if !bounds_check(x, y) do return false
    if !tile_is_solid(&game.world, x, y) do return false
    if !recent_can_modify(enemy, x, y) do return false
    set_empty_for_level(game, x, y)
    garm_action_log(game, fmt.tprintf("REMOVE overhead (%d,%d)", x, y))
    enemy_debug_ray_add(enemy, x, y, rl.ORANGE, 16)
    recent_mark_modified(enemy, x, y)
    return true
}

// Try to fill the horizontal center row (X axis) with stone within local 4x4 around Garm
garm_fill_center_locally :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    cy := WORLD_HEIGHT/2
    tx := enemy.tile_x
    // Sweep horizontally within local range along the target row
    for dx := -GARM_LOCAL_ACTION_RANGE; dx <= GARM_LOCAL_ACTION_RANGE; dx += 1 {
        x := tx + dx
        y := cy
        if !bounds_check(x, y) do continue
    if enemy.build_mode == .Build_Circle { continue } // Do not place on center row while building circle
    if !tile_is_solid(&game.world, x, y) {
            if !recent_can_modify(enemy, x, y) do continue
            game.world.terrain[x][y] = .Stone
            garm_action_log(game, fmt.tprintf("PLACE center (%d,%d)", x, y))
            enemy_debug_ray_add(enemy, x, y, rl.GREEN, 16)
            recent_mark_modified(enemy, x, y)
            return true
        }
    }
    return false
}

// Try to remove tiles (mine) in a local 4x4, prioritizing the center column
// Row near the center to prioritize clearing, offset to avoid the exact center row
garm_center_clear_row :: proc(enemy: ^Enemy) -> int {
    cy := WORLD_HEIGHT/2
    // If above center, clear just above; if below, clear just below
    if enemy.tile_y <= cy { return cy - 1 } else { return cy + 1 }
}

garm_clear_locally :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    cy := WORLD_HEIGHT/2
    ryo := garm_center_clear_row(enemy)
    tx := enemy.tile_x
    ty := enemy.tile_y
    // First pass: preferred offset row within 4x4
    for dx := -GARM_LOCAL_ACTION_RANGE; dx <= GARM_LOCAL_ACTION_RANGE; dx += 1 {
        x := tx + dx
        y := ryo
        if !bounds_check(x, y) do continue
        // Never remove stone from the exact center row to prevent undoing the build
        if y == cy && game.world.terrain[x][y] == .Stone { continue }
        if tile_is_solid(&game.world, x, y) {
            if enemy.build_mode == .Build_Circle && garm_is_circle_ring_tile(enemy, x, y) {
                // Never clear circle perimeter while building the circle
                continue
            }
            if !recent_can_modify(enemy, x, y) do continue
            set_empty_for_level(game, x, y)
            garm_action_log(game, fmt.tprintf("REMOVE local (%d,%d)", x, y))
            enemy_debug_ray_add(enemy, x, y, rl.RED, 16)
            recent_mark_modified(enemy, x, y)
            return true
        }
    }
    // Second pass: any solid within 4x4 (skip center row)
    for dx := -GARM_LOCAL_ACTION_RANGE; dx <= GARM_LOCAL_ACTION_RANGE; dx += 1 {
        for dy := -GARM_LOCAL_ACTION_RANGE; dy <= GARM_LOCAL_ACTION_RANGE; dy += 1 {
            x := tx + dx
            y := ty + dy
            if !bounds_check(x, y) do continue
            // Skip exact center row to keep fill intact (handled elsewhere when needed)
            if y == cy { continue }
            if tile_is_solid(&game.world, x, y) {
                if enemy.build_mode == .Build_Circle && garm_is_circle_ring_tile(enemy, x, y) {
                    continue
                }
                if !recent_can_modify(enemy, x, y) do continue
                set_empty_for_level(game, x, y)
                garm_action_log(game, fmt.tprintf("REMOVE local (%d,%d)", x, y))
                enemy_debug_ray_add(enemy, x, y, rl.RED, 16)
                recent_mark_modified(enemy, x, y)
                return true
            }
        }
    }
    return false
}

// Check if the entire horizontal center row is filled with Stone
garm_center_row_complete :: proc(game: ^Game_State) -> bool {
    cy := WORLD_HEIGHT/2
    for x := 0; x < WORLD_WIDTH; x += 1 {
        if !bounds_check(x, cy) { continue }
        if game.world.terrain[x][cy] != .Stone {
            return false
        }
    }
    return true
}

// Return true if (x,y) lies on the discrete ring defined by center (cx,cy),
// outer radius r, and thickness t (tiles). Ring includes tiles with
// inner_r^2 <= d2 <= r^2 where inner_r = max(r-(t-1), 0)
garm_is_ring_tile :: proc(cx: int, cy: int, r: int, t: int, x: int, y: int) -> bool {
    dx := x - cx
    dy := y - cy
    d2 := dx*dx + dy*dy
    inner := r - (t - 1)
    if inner < 0 {
        inner = 0
    }
    return d2 >= inner*inner && d2 <= r*r
}

// Try to place one ring tile of the current build circle
garm_build_circle_locally :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    cx := enemy.circle_cx
    cy := enemy.circle_cy
    r  := enemy.circle_radius
    t  := enemy.circle_thickness
    // Scan bounding box and pick nearest unfilled ring tile
    best_px := -1; best_py := -1; best_d2 := 1000000
    for y := cy - (r+1); y <= cy + (r+1); y += 1 {
        for x := cx - (r+1); x <= cx + (r+1); x += 1 {
            if !bounds_check(x, y) do continue
            if !garm_is_ring_tile(cx, cy, r, t, x, y) do continue
            if tile_is_solid(&game.world, x, y) do continue
            if !recent_can_modify(enemy, x, y) do continue
            dx := x - enemy.tile_x; dy := y - enemy.tile_y
            d2 := dx*dx + dy*dy
            if d2 < best_d2 { best_d2 = d2; best_px = x; best_py = y }
        }
    }
    if best_px >= 0 {
    game.world.terrain[best_px][best_py] = .Stone
    garm_action_log(game, fmt.tprintf("PLACE circle (%d,%d)", best_px, best_py))
        enemy_debug_ray_add(enemy, best_px, best_py, rl.GREEN, 18)
        recent_mark_modified(enemy, best_px, best_py)
        return true
    }
    return false
}
// Pick the nearest unfilled ring tile to move toward
garm_pick_circle_target :: proc(game: ^Game_State, enemy: ^Enemy, cx, cy, r: int, out_tx: ^int, out_ty: ^int) -> bool {
    t := enemy.circle_thickness
    best_px := -1; best_py := -1; best_d2 := 1000000
    for y := cy - (r+1); y <= cy + (r+1); y += 1 {
        for x := cx - (r+1); x <= cx + (r+1); x += 1 {
            if !bounds_check(x, y) do continue
            if !garm_is_ring_tile(cx, cy, r, t, x, y) do continue
            if tile_is_solid(&game.world, x, y) do continue
            dx := x - enemy.tile_x; dy := y - enemy.tile_y
            d2 := dx*dx + dy*dy
            if d2 < best_d2 { best_d2 = d2; best_px = x; best_py = y }
        }
    }
    if best_px >= 0 {
        out_tx^ = best_px
        out_ty^ = best_py
        return true
    }
    return false
}

// Check whether the full discrete ring is filled with Stone
garm_circle_complete :: proc(game: ^Game_State, cx, cy, r: int, t: int) -> bool {
    for y := cy - (r+1); y <= cy + (r+1); y += 1 {
        for x := cx - (r+1); x <= cx + (r+1); x += 1 {
            if !bounds_check(x, y) do continue
            if !garm_is_ring_tile(cx, cy, r, t, x, y) do continue
            if game.world.terrain[x][y] != .Stone { return false }
        }
    }
    return true
}

// Check whether the circle interior is completely filled with lava
garm_lava_filling_complete :: proc(game: ^Game_State, cx, cy, r: int) -> bool {
    inner_radius := r - 1
    if inner_radius < 1 { inner_radius = 1 }
    
    for y := cy - inner_radius; y <= cy + inner_radius; y += 1 {
        for x := cx - inner_radius; x <= cx + inner_radius; x += 1 {
            if !bounds_check(x, y) do continue
            
            // Check if this tile is inside the circle interior
            dx := x - cx
            dy := y - cy
            d2 := dx*dx + dy*dy
            if d2 >= inner_radius*inner_radius do continue
            
            // Skip reserved void channel (center column)
            if x == cx do continue
            
            // Check if tile is filled with lava
            if game.world.terrain[x][y] != .Lava { return false }
        }
    }
    return true
}

// Returns true if (x,y) lies on the configured ring mask for the enemy
garm_is_circle_ring_tile :: proc(enemy: ^Enemy, x, y: int) -> bool {
    return garm_is_ring_tile(enemy.circle_cx, enemy.circle_cy, enemy.circle_radius, enemy.circle_thickness, x, y)
}

// Return true if (x,y) is strictly inside the circle interior (not on the ring)
garm_is_inside_circle_interior :: proc(enemy: ^Enemy, x, y: int) -> bool {
    cx := enemy.circle_cx
    cy := enemy.circle_cy
    r := enemy.circle_radius
    inner := r - (enemy.circle_thickness - 1)
    if inner < 0 { inner = 0 }
    dx := x - cx
    dy := y - cy
    d2 := dx*dx + dy*dy
    return d2 < inner*inner
}

// Try to remove a solid tile from the circle interior (not the ring), preferring nearest to Garm
garm_clear_circle_interior_locally :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    cx := enemy.circle_cx
    cy := enemy.circle_cy
    r  := enemy.circle_radius
    best_x := -1; best_y := -1; best_d2 := 1000000
    for y := cy - (r+1); y <= cy + (r+1); y += 1 {
        for x := cx - (r+1); x <= cx + (r+1); x += 1 {
            if !bounds_check(x, y) do continue
            if !garm_is_inside_circle_interior(enemy, x, y) do continue
            if tile_is_solid(&game.world, x, y) {
                if !recent_can_modify(enemy, x, y) do continue
                dx := x - enemy.tile_x; dy := y - enemy.tile_y
                d2 := dx*dx + dy*dy
                if d2 < best_d2 { best_d2 = d2; best_x = x; best_y = y }
            }
        }
    }
    if best_x >= 0 {
        set_empty_for_level(game, best_x, best_y)
        garm_action_log(game, fmt.tprintf("REMOVE interior (%d,%d)", best_x, best_y))
        enemy_debug_ray_add(enemy, best_x, best_y, rl.RED, 18)
        recent_mark_modified(enemy, best_x, best_y)
        return true
    }
    return false
}

// Scan an 8x8 (diameter) neighborhood around Garm for diagnostics/awareness
garm_scan_area :: proc(game: ^Game_State, enemy: ^Enemy) {
    tx := enemy.tile_x
    ty := enemy.tile_y
    r := GARM_SCAN_RADIUS_TILES
    for dx := -r; dx <= r; dx += 1 {
        for dy := -r; dy <= r; dy += 1 {
            x := tx + dx
            y := ty + dy
            if !bounds_check(x, y) do continue
            // Mark interesting tiles: center column and solids
            if y == WORLD_HEIGHT/2 {
                enemy_debug_ray_add(enemy, x, y, rl.PURPLE, 8)
            } else if tile_is_solid(&game.world, x, y) {
                enemy_debug_ray_add(enemy, x, y, rl.DARKGRAY, 6)
            }
        }
    }
}

// While sweeping along the center row, place Stone ahead within local range
garm_sweep_fill_ahead :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    cy := WORLD_HEIGHT/2
    dir := enemy.sweep_dir
    tx := enemy.tile_x
    // Ensure current and a few ahead tiles on the target row are solid
    for step := 0; step <= GARM_LOCAL_ACTION_RANGE; step += 1 {
        x := tx + step*dir
        y := cy
        if !bounds_check(x, y) do continue
        if !tile_is_solid(&game.world, x, y) {
            if !recent_can_modify(enemy, x, y) do continue
            game.world.terrain[x][y] = .Stone
            garm_action_log(game, fmt.tprintf("PLACE sweep (%d,%d)", x, y))
            enemy_debug_ray_add(enemy, x, y, rl.GREEN, 16)
            recent_mark_modified(enemy, x, y)
            return true
        }
    }
    return false
}

enemy_update_ai :: proc(game: ^Game_State, enemy: ^Enemy, dt: f32) {
    enemy.ai_timer += dt
    
    // Only update AI decisions every so often
    if enemy.ai_timer < ENEMY_AI_UPDATE_INTERVAL do return
    enemy.ai_timer = 0
    // Tick down recent-mod cooldowns once per AI update
    recent_tick(enemy)
    
    // New simple behavior: always work toward center X and manage tiles around
    cx := WORLD_WIDTH/2
    cy := WORLD_HEIGHT/2

    // Perform an 8x8 scan for awareness/visualization
    garm_scan_area(game, enemy)

    // Determine desired horizontal motion
    // Default: toward center X; Circle mode: toward nearest circle target
    circle_has_target := false
    target_x_for_motion := cx
    target_y_for_motion := cy
    if enemy.build_mode == .Build_Circle {
        tx := 0; ty := 0
        if garm_pick_circle_target(game, enemy, enemy.circle_cx, enemy.circle_cy, enemy.circle_radius, &tx, &ty) {
            enemy.circle_target_x = tx
            enemy.circle_target_y = ty
            circle_has_target = true
            target_x_for_motion = tx
            target_y_for_motion = ty
            garm_action_log(game, fmt.tprintf("target circle (%d,%d) pos=(%d,%d)", tx, ty, enemy.tile_x, enemy.tile_y))
        } else {
            enemy.circle_target_x = -1
            enemy.circle_target_y = -1
            garm_action_log(game, "no circle target available")
        }
    }

    if enemy.pos_x < cast(f32)target_x_for_motion-0.05 {
        enemy.vel_x = ENEMY_SPEED
        enemy.facing_right = true
    } else if enemy.pos_x > cast(f32)target_x_for_motion+0.05 {
        enemy.vel_x = -ENEMY_SPEED
        enemy.facing_right = false
    } else {
        enemy.vel_x = 0
    }

    // Decide mode based on vertical relation to center
    below_center := enemy.tile_y > cy
    above_by_two := enemy.tile_y <= cy-2

    // Switch to circle-building mode once the center row is complete
    if enemy.build_mode == .Build_Line {
        if garm_center_row_complete(game) {
            enemy.build_mode = .Build_Circle
            // Keep sweeping for mobility; circle params already set
            fmt.printf("GARM: Horizontal line complete -> start circle (r=%d)\n", enemy.circle_radius)
            garm_action_log(game, fmt.tprintf("mode Build_Line -> Build_Circle r=%d", enemy.circle_radius))
        }
    }

    // Throttle build/remove actions
    enemy.build_timer += ENEMY_AI_UPDATE_INTERVAL

    // If below center: only build and jump
    if below_center {
        did_action := false
        // If stuck under the center row, clear overhead first so we can jump up
        if enemy.build_timer >= GARM_BUILD_ACTION_INTERVAL {
            if garm_clear_overhead_if_stuck(game, enemy) {
                enemy.build_timer = 0
                did_action = true
            }
        }
        // Place support underfoot if falling through
        bx := enemy.tile_x
        by := enemy.tile_y + 1
        if enemy.build_timer >= GARM_BUILD_ACTION_INTERVAL && bounds_check(bx, by) && !tile_is_solid(&game.world, bx, by) {
            // In circle mode, don't place support blocks that would be inside the circle interior
            should_place_support := true
            if enemy.build_mode == .Build_Circle {
                if garm_is_inside_circle_interior(enemy, bx, by) {
                    should_place_support = false
                }
            }
            
            if should_place_support {
                // Prefer base support at y+2 when possible
                base_ok := true
                if bounds_check(bx, by+1) { base_ok = tile_is_solid(&game.world, bx, by+1) }
                if base_ok {
                    game.world.terrain[bx][by] = .Stone
                    garm_action_log(game, fmt.tprintf("PLACE support (%d,%d)", bx, by))
                    enemy.build_timer = 0
                    did_action = true
                }
            }
        }
        // Try to place a step ahead and jump
        if enemy_is_on_ground(game, enemy) {
            did_place := false
            if enemy.build_timer >= GARM_BUILD_ACTION_INTERVAL {
                did_place = garm_try_place_step_ahead(game, enemy)
                if did_place { enemy.build_timer = 0 }
            }
            if !did_place {
                garm_consider_jump(game, enemy)
            }
        }
        // Fill center row locally (4x4) unless we just modified overhead/support
        if !did_action && enemy.build_timer >= GARM_BUILD_ACTION_INTERVAL {
            // Prioritize circle building when in circle mode
            if enemy.build_mode == .Build_Circle {
                if garm_build_circle_locally(game, enemy) { enemy.build_timer = 0 }
            } else {
                if garm_fill_center_locally(game, enemy) { enemy.build_timer = 0 }
            }
        }
        return
    }

    // If above center by 2: only remove tiles
    if above_by_two {
        if enemy.build_timer >= GARM_BUILD_ACTION_INTERVAL {
            did_clear := false
            if enemy.build_mode == .Build_Circle {
                did_clear = garm_clear_circle_interior_locally(game, enemy)
            }
            if !did_clear {
                if garm_clear_locally(game, enemy) { enemy.build_timer = 0 }
            } else {
                enemy.build_timer = 0
            }
        }
        // Still jump when encountering obstacles to keep moving horizontally
        if enemy_is_on_ground(game, enemy) {
            garm_consider_jump(game, enemy)
        }
        return
    }

    // In the band near center (cy-1 .. cy): allow minor adjustments
    // Disable sweep while building circle; otherwise sweep the center row
    if enemy.build_mode == .Build_Circle {
        enemy.sweep_active = false
    garm_action_log(game, "sweep disabled for circle mode")
    }
    if enemy.sweep_active {
        // Reverse at world edges
        if enemy.sweep_dir < 0 && enemy.tile_x <= 1 { enemy.sweep_dir = 1 }
        if enemy.sweep_dir > 0 && enemy.tile_x >= WORLD_WIDTH-2 { enemy.sweep_dir = -1 }
        enemy.vel_x = ENEMY_SPEED * (1 if enemy.sweep_dir > 0 else -1)
        enemy.facing_right = enemy.sweep_dir > 0
    }
    if enemy.build_timer >= GARM_BUILD_ACTION_INTERVAL {
        did := false
        // Circle mode: try to place a circle perimeter tile first
        if enemy.build_mode == .Build_Circle {
            // Prefer clearing interior first if surrounded by filled ring
            if garm_circle_complete(game, enemy.circle_cx, enemy.circle_cy, enemy.circle_radius, enemy.circle_thickness) {
                did = garm_clear_circle_interior_locally(game, enemy)
            }
            if !did {
                did = garm_build_circle_locally(game, enemy)
            }
            if did { garm_action_log(game, fmt.tprintf("place circle stone near (%d,%d)", enemy.tile_x, enemy.tile_y)) }
        }
        // If still nothing, optionally use the center sweep helper
        if !did && enemy.sweep_active {
            did = garm_sweep_fill_ahead(game, enemy)
        }
        // Fallback to local fill/clear
    if !did {
            if enemy.build_mode == .Build_Circle {
                // Try interior clear, then circle again
                if garm_clear_circle_interior_locally(game, enemy) { did = true }
                if !did && garm_build_circle_locally(game, enemy) { did = true; garm_action_log(game, "retry circle place succeeded") }
            } else {
                if garm_fill_center_locally(game, enemy) { did = true }
            }
        }
        if !did {
            _ = garm_clear_locally(game, enemy)
        }
    if did { enemy.build_timer = 0; garm_action_log(game, "build_timer reset after action") }
    }
    if enemy_is_on_ground(game, enemy) {
        if enemy.build_mode == .Build_Circle && circle_has_target {
            // Place a step if helpful, then consider jump toward target
            if garm_try_place_step_ahead_toward(game, enemy, target_x_for_motion) { garm_action_log(game, "placed step ahead toward target") }
            garm_consider_jump_toward(game, enemy, target_x_for_motion)
            garm_action_log(game, "consider jump toward target")
        } else if enemy.build_mode != .Build_Circle {
            garm_consider_jump(game, enemy)
            garm_action_log(game, "consider jump generic")
        } else {
            // In circle mode but no target -> avoid pogo-jumping at center
            // Only jump if there's a clear obstacle blocking movement
            if garm_should_jump_in_circle_mode(game, enemy) {
                garm_consider_jump(game, enemy)
                garm_action_log(game, "consider jump (circle mode, obstacle detected)")
            } else {
                garm_action_log(game, "skip jump (circle mode, no target, no obstacle)")
            }
        }
    }
}

// ----------------
// Planning helpers
// ----------------

enemy_plan_clear :: proc(enemy: ^Enemy) {
    enemy.plan_len = 0
    enemy.plan_cursor = 0
}

enemy_plan_push :: proc(enemy: ^Enemy, act: Enemy_Plan_Action) {
    if enemy.plan_len < len(enemy.plan) {
        enemy.plan[enemy.plan_len] = act
        enemy.plan_len += 1
    }
}

enemy_generate_build_plan :: proc(game: ^Game_State, enemy: ^Enemy) {
    enemy_plan_clear(enemy)

    // Set up project if needed
    if !enemy.project_active {
        enemy.project_active = true
        enemy.project_center_x = WORLD_WIDTH / 2
        cy := enemy.tile_y
        mid_y := WORLD_HEIGHT / 2
        if cy > mid_y-1 { cy = mid_y-1 }
        if cy < 2 { cy = 2 }
        enemy.project_center_y = cy
        enemy.project_radius = GARM_PROJECT_RADIUS
        enemy.project_phase = .Center_Column
        enemy.project_index = 0
    }

    // Phase completion checks to advance deterministically
    cx := enemy.project_center_x
    cy := enemy.project_center_y
    if enemy.project_phase == .Center_Column {
        solid_rows := 0
        for yy := 0; yy < WORLD_HEIGHT; yy += 1 {
            if bounds_check(cx, yy) && tile_is_solid(&game.world, cx, yy) { solid_rows += 1 }
        }
        if solid_rows >= WORLD_HEIGHT-1 { // allow one gap due to entities/specials
            enemy.project_phase = .Perimeter
            enemy.project_index = 0
        }
    }
    
    // Check if perimeter is complete and transition to lava filling
    if enemy.project_phase == .Perimeter {
        if garm_circle_complete(game, cx, cy, enemy.project_radius, 2) { // thickness of 2
            enemy.project_phase = .Filling_Lava
            enemy.project_index = 0
            garm_log(game, "Perimeter complete -> Filling_Lava")
        }
    }
    
    // Check if lava filling is complete and transition to exiting
    if enemy.project_phase == .Filling_Lava {
        if garm_lava_filling_complete(game, cx, cy, enemy.project_radius) {
            enemy.project_phase = .Exiting_Circle
            enemy.project_index = 0
            garm_log(game, "Lava filling complete -> Exiting_Circle")
        }
    }
    
    // Check if Garm has exited the circle and transition to closing
    if enemy.project_phase == .Exiting_Circle {
        exit_x := cx + enemy.project_radius + 2
        if math.abs(enemy.tile_x - exit_x) <= 1 && math.abs(enemy.tile_y - cy) <= 1 {
            enemy.project_phase = .Closing_Circle
            enemy.project_index = 0
            garm_log(game, "Exited circle -> Closing_Circle")
        }
    }
    
    // Check if circle closing is complete and transition to project complete
    if enemy.project_phase == .Closing_Circle {
        if garm_circle_complete(game, cx, cy, enemy.project_radius, 2) {
            enemy.project_phase = .Project_Complete
            enemy.project_index = 0
            garm_log(game, "Circle closed -> Project_Complete")
        }
    }

    max_steps := cast(int)len(enemy.plan)
    cx = enemy.project_center_x
    cy = enemy.project_center_y

    // Plan according to current phase
    switch enemy.project_phase {
    case .None:
        // Small wander toward center to bootstrap
        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = enemy.tile_y })
    case .Center_Column:
        // Localized column work around GARM's current position instead of full world column
        garm_y := enemy.tile_y
        local_range := 8  // Only work within 8 tiles of current position
        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = garm_y })
        
        // Work on nearby positions only - start from GARM's Y and expand locally
        for offset := 0; enemy.plan_len < max_steps && offset <= local_range; offset += 1 {
            up_y := garm_y - offset
            down_y := garm_y + offset
            
            // Up row - only if close to GARM
            if up_y >= 1 && up_y < WORLD_HEIGHT-1 && bounds_check(cx, up_y) {
                terrain := game.world.terrain[cx][up_y]
                is_solid := tile_is_solid(&game.world, cx, up_y)
                garm_log(game, fmt.tprintf("SCAN (%d,%d) terrain=%v solid=%v", cx, up_y, terrain, is_solid))
                if !is_solid {
                    enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = up_y })
                    enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = cx, y = up_y, material = .Stone })
                }
                y1 := up_y - 1
                y2 := up_y - 2
                if bounds_check(cx, y1) {
                    terrain1 := game.world.terrain[cx][y1]
                    is_solid1 := tile_is_solid(&game.world, cx, y1)
                    garm_log(game, fmt.tprintf("SCAN (%d,%d) terrain=%v solid=%v", cx, y1, terrain1, is_solid1))
                    if is_solid1 {
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y1 })
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = cx, y = y1 })
                    } else {
                        desired1 : Terrain_Type = .Air
                        if game.level_offset > 0 { desired1 = .Void }
                        if terrain1 != desired1 {
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y1 })
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = cx, y = y1, material = desired1 })
                        }
                    }
                }
                if bounds_check(cx, y2) {
                    terrain2 := game.world.terrain[cx][y2]
                    is_solid2 := tile_is_solid(&game.world, cx, y2)
                    garm_log(game, fmt.tprintf("SCAN (%d,%d) terrain=%v solid=%v", cx, y2, terrain2, is_solid2))
                    if is_solid2 {
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y2 })
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = cx, y = y2 })
                    } else {
                        desired2 : Terrain_Type = .Air
                        if game.level_offset > 0 { desired2 = .Void }
                        if terrain2 != desired2 {
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y2 })
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = cx, y = y2, material = desired2 })
                        }
                    }
                }
            }
            // Down row (avoid duplicate when offset==0)
            if down_y != up_y && down_y >= 1 && down_y < WORLD_HEIGHT-1 && bounds_check(cx, down_y) {
                terrain := game.world.terrain[cx][down_y]
                is_solid := tile_is_solid(&game.world, cx, down_y)
                garm_log(game, fmt.tprintf("SCAN (%d,%d) terrain=%v solid=%v", cx, down_y, terrain, is_solid))
                if !is_solid {
                    enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = down_y })
                    enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = cx, y = down_y, material = .Stone })
                }
                y1 := down_y - 1
                y2 := down_y - 2
                if bounds_check(cx, y1) {
                    if tile_is_solid(&game.world, cx, y1) {
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y1 })
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = cx, y = y1 })
                    } else {
                        desired1 : Terrain_Type = .Air
                        if game.level_offset > 0 { desired1 = .Void }
                        if game.world.terrain[cx][y1] != desired1 {
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y1 })
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = cx, y = y1, material = desired1 })
                        }
                    }
                }
                if bounds_check(cx, y2) {
                    if tile_is_solid(&game.world, cx, y2) {
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y2 })
                        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = cx, y = y2 })
                    } else {
                        desired2 : Terrain_Type = .Air
                        if game.level_offset > 0 { desired2 = .Void }
                        if game.world.terrain[cx][y2] != desired2 {
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = y2 })
                            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = cx, y = y2, material = desired2 })
                        }
                    }
                }
            }
            if (up_y < 1 || up_y >= WORLD_HEIGHT-1) && (down_y < 1 || down_y >= WORLD_HEIGHT-1) {
                break
            }
        }
    case .Perimeter:
        samples := GARM_PROJECT_SAMPLES
        two_pi : f64 = 6.283185307179586
        // Find the nearest undone perimeter sample as a deterministic starting point
        nearest_idx := 0
        nearest_d2 := 1000000
        for i := 0; i < samples; i += 1 {
            theta := two_pi * cast(f64)i / cast(f64)samples
            qx := cx + cast(int)math.round(cast(f64)enemy.project_radius * math.cos(theta))
            qy := cy + cast(int)math.round(cast(f64)enemy.project_radius * math.sin(theta))
            if !bounds_check(qx, qy) { 
                garm_log(game, fmt.tprintf("SCAN perimeter (%d,%d) OOB", qx, qy))
                continue 
            }
            terrain := game.world.terrain[qx][qy]
            is_solid := tile_is_solid(&game.world, qx, qy)
            garm_log(game, fmt.tprintf("SCAN perimeter (%d,%d) terrain=%v solid=%v", qx, qy, terrain, is_solid))
            if is_solid { continue }
            dxp := qx - enemy.tile_x
            dyp := qy - enemy.tile_y
            d2 := dxp*dxp + dyp*dyp
            if d2 < nearest_d2 { nearest_d2 = d2; nearest_idx = i }
        }
        // Plan around the circle from the nearest index
        for i := 0; i < samples && enemy.plan_len < max_steps; i += 1 {
            sidx := (nearest_idx + i) % samples
            theta := two_pi * cast(f64)sidx / cast(f64)samples
            px := cx + cast(int)math.round(cast(f64)enemy.project_radius * math.cos(theta))
            py := cy + cast(int)math.round(cast(f64)enemy.project_radius * math.sin(theta))
            if !bounds_check(px, py) { continue }
            if tile_is_solid(&game.world, px, py) { continue }
            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = px, y = py })
            enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = px, y = py, material = .Stone })
        }
    case .Filling_Lava:
        // Deterministic outer-to-inner ring scan within the interior (radius-1)
        R := enemy.project_radius - 1
        if R < 1 { R = 1 }
        // Start scanning from outer ring toward center
        for ring := R; ring >= 0 && enemy.plan_len < max_steps; ring -= 1 {
            // top edge left->right
            y := cy - ring
            for x := cx - ring; x <= cx + ring && enemy.plan_len < max_steps; x += 1 {
                if !bounds_check(x, y) { continue }
                dx := x - cx; dy := y - cy
                if dx*dx + dy*dy > R*R { continue }
                terrain := game.world.terrain[x][y]
                is_solid := tile_is_solid(&game.world, x, y)
                is_reserved := is_reserved_void_tile(game, enemy, x, y)
                garm_log(game, fmt.tprintf("SCAN lava (%d,%d) terrain=%v solid=%v reserved=%v", x, y, terrain, is_solid, is_reserved))
                if is_reserved { continue }
                if terrain == .Lava { continue }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = x, y = y })
                if is_solid { enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = x, y = y }) }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = x, y = y, material = .Lava })
            }
            // right edge top->bottom
            x := cx + ring
            for y := cy - ring + 1; y <= cy + ring - 1 && enemy.plan_len < max_steps; y += 1 {
                if !bounds_check(x, y) { continue }
                dx := x - cx; dy := y - cy
                if dx*dx + dy*dy > R*R { continue }
                if is_reserved_void_tile(game, enemy, x, y) { continue }
                if game.world.terrain[x][y] == .Lava { continue }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = x, y = y })
                if tile_is_solid(&game.world, x, y) { enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = x, y = y }) }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = x, y = y, material = .Lava })
            }
            // bottom edge right->left
            y = cy + ring
            for x := cx + ring; x >= cx - ring && enemy.plan_len < max_steps; x -= 1 {
                if !bounds_check(x, y) { continue }
                dx := x - cx; dy := y - cy
                if dx*dx + dy*dy > R*R { continue }
                if is_reserved_void_tile(game, enemy, x, y) { continue }
                if game.world.terrain[x][y] == .Lava { continue }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = x, y = y })
                if tile_is_solid(&game.world, x, y) { enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = x, y = y }) }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = x, y = y, material = .Lava })
            }
            // left edge bottom->top
            x = cx - ring
            for y := cy + ring - 1; y >= cy - ring + 1 && enemy.plan_len < max_steps; y -= 1 {
                if !bounds_check(x, y) { continue }
                dx := x - cx; dy := y - cy
                if dx*dx + dy*dy > R*R { continue }
                if is_reserved_void_tile(game, enemy, x, y) { continue }
                if game.world.terrain[x][y] == .Lava { continue }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = x, y = y })
                if tile_is_solid(&game.world, x, y) { enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Mine, x = x, y = y }) }
                enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = x, y = y, material = .Lava })
            }
        }
    case .Exiting_Circle:
        // Move Garm outside the circle perimeter
        exit_x := cx + enemy.project_radius + 2  // Move 2 tiles outside the circle
        exit_y := cy
        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = exit_x, y = exit_y })
        garm_log(game, fmt.tprintf("EXITING circle to (%d,%d)", exit_x, exit_y))
    case .Closing_Circle:
        // Close up the circle by filling any gaps in the perimeter
        // Find gaps in the circle perimeter and plan to fill them
        for y := cy - (enemy.project_radius+1); y <= cy + (enemy.project_radius+1); y += 1 {
            for x := cx - (enemy.project_radius+1); x <= cx + (enemy.project_radius+1); x += 1 {
                if !bounds_check(x, y) do continue
                if !garm_is_ring_tile(cx, cy, enemy.project_radius, 2, x, y) do continue
                if game.world.terrain[x][y] != .Stone && enemy.plan_len < max_steps {
                    enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = x, y = y })
                    enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .Place, x = x, y = y, material = .Stone })
                }
            }
        }
        garm_log(game, "CLOSING circle perimeter")
    case .Project_Complete:
        // Project is done, just idle
        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = cy })
        garm_log(game, "PROJECT_COMPLETE - idling")
    case:
        // Fallback: just head toward center X
        enemy_plan_push(enemy, Enemy_Plan_Action{ kind = .MoveTo, x = cx, y = enemy.tile_y })
    }

    // Lock for at least 15 steps (or however many were planned if fewer)
    want_lock := 15
    if enemy.plan_len < want_lock { enemy.plan_lock_steps = enemy.plan_len } else { enemy.plan_lock_steps = want_lock }
    garm_log(game, fmt.tprintf("PLAN ready len=%d lock=%d phase=%v", enemy.plan_len, enemy.plan_lock_steps, enemy.project_phase))
}

enemy_execute_plan_step :: proc(game: ^Game_State, enemy: ^Enemy) -> bool {
    if enemy.plan_cursor >= enemy.plan_len { return false }
    act := enemy.plan[enemy.plan_cursor]
    enemy.last_step_was_noop = false

    switch act.kind {
    case .MoveTo:
        // Movement reset: treat MoveTo as immediately complete (no movement)
        enemy_debug_ray_add(enemy, act.x, act.y, rl.YELLOW, 14)
        enemy.plan_cursor += 1
        garm_log(game, fmt.tprintf("STEP MoveTo (%d,%d) skipped (movement disabled)", act.x, act.y))
        return true
    case .Mine:
        // Movement reset: skip mining logic to keep plans flowing
        enemy_debug_ray_add(enemy, act.x, act.y, rl.RED, 16)
        enemy.plan_cursor += 1
        enemy.last_step_was_noop = true
        garm_log(game, fmt.tprintf("STEP Mine (%d,%d) skipped (movement disabled)", act.x, act.y))
        return true
    case .Place:
        // Movement reset: skip placing logic to keep plans flowing
        enemy_debug_ray_add(enemy, act.x, act.y, rl.GREEN, 16)
        enemy.plan_cursor += 1
        enemy.last_step_was_noop = true
        garm_log(game, fmt.tprintf("STEP Place %v at (%d,%d) skipped (movement disabled)", act.material, act.x, act.y))
        return true
    case .Jump:
        // Movement reset: no jumping
        enemy.plan_cursor += 1
        enemy.last_step_was_noop = true
        garm_log(game, "STEP Jump skipped (movement disabled)")
        return true
    }
    return false
}

// Apply movement with collision detection (similar to player movement)
enemy_apply_movement :: proc(game: ^Game_State, enemy: ^Enemy, dt: f32) {
    // Desired motion
    dx := enemy.vel_x * dt
    dy := enemy.vel_y * dt
    
    // Horizontal movement with collision
    if dx != 0 {
        new_pos_x := enemy.pos_x + dx
        old_tile_x := enemy.tile_x
        new_tile_x := cast(int)new_pos_x
        if new_tile_x != old_tile_x {
            target_tile_x := new_tile_x
            target_tile_y := enemy.tile_y
            if tile_is_solid(&game.world, target_tile_x, target_tile_y) {
                // Block movement and zero velocity
                if dx > 0 {
                    enemy.pos_x = cast(f32)old_tile_x + 0.999
                } else {
                    enemy.pos_x = cast(f32)old_tile_x
                }
                enemy.vel_x = 0
            } else {
                enemy.pos_x = new_pos_x
            }
        } else {
            enemy.pos_x = new_pos_x
        }
    }
    
    // Vertical movement with collision
    if dy != 0 {
        new_pos_y := enemy.pos_y + dy
        old_tile_y := enemy.tile_y
        new_tile_y := cast(int)new_pos_y
        if new_tile_y != old_tile_y {
            target_tile_x := enemy.tile_x
            target_tile_y := new_tile_y
            if tile_is_solid(&game.world, target_tile_x, target_tile_y) {
                // Land or hit ceiling
                if dy > 0 { // falling onto solid
                    enemy.pos_y = cast(f32)old_tile_y + 0.999
                } else { // hitting ceiling
                    enemy.pos_y = cast(f32)old_tile_y
                }
                enemy.vel_y = 0
            } else {
                enemy.pos_y = new_pos_y
            }
        } else {
            enemy.pos_y = new_pos_y
        }
    }
    
    // Update tile position and entity grid
    new_tile_x := cast(int)enemy.pos_x
    new_tile_y := cast(int)enemy.pos_y
    if new_tile_x != enemy.tile_x || new_tile_y != enemy.tile_y {
        old_x := enemy.tile_x
        old_y := enemy.tile_y
        
        // Clear old position
        if bounds_check(old_x, old_y) {
            if game.world.entities[old_x][old_y] == enemy.entity_id {
                game.world.entities[old_x][old_y] = INVALID_ENTITY
            }
        }
        
        enemy.tile_x = new_tile_x
        enemy.tile_y = new_tile_y
        
        // Set new position
        if bounds_check(enemy.tile_x, enemy.tile_y) {
            game.world.entities[enemy.tile_x][enemy.tile_y] = enemy.entity_id
        }
    }
}

// Update animation frames
enemy_update_animation :: proc(enemy: ^Enemy, dt: f32) {
    // Only animate if moving horizontally
    if math.abs(enemy.vel_x) > 0.1 {
        enemy.walk_anim_timer += dt
        if enemy.walk_anim_timer >= 0.4 {
            enemy.walk_anim_frame = 1 - enemy.walk_anim_frame
            enemy.walk_anim_timer = 0
        }
    } else {
        enemy.walk_anim_frame = 0
        enemy.walk_anim_timer = 0
    }
}

// Deal damage to enemy
enemy_take_damage :: proc(enemy: ^Enemy, damage: i32) -> bool {
    if !enemy.active || enemy.damage_timer > 0 do return false
    
    enemy.health -= damage
    enemy.damage_timer = ENEMY_DAMAGE_COOLDOWN
    
    if enemy.health <= 0 {
        enemy.active = false
        return true // enemy died
    }
    
    return false // enemy survived
}

// Check if enemy is at given tile position
enemy_at_position :: proc(enemy: ^Enemy, x, y: int) -> bool {
    return enemy.active && enemy.tile_x == x && enemy.tile_y == y
}

// Fireball system functions
fireball_shoot :: proc(fireballs: ^Enemy_Fireballs, from_x, from_y, to_x, to_y: f32) {
    // Find an inactive fireball slot
    for i in 0..<MAX_FIREBALLS {
        fb := &fireballs.data[i]
        if !fb.active {
            fb.active = true
            fb.pos_x = from_x
            fb.pos_y = from_y
            
            // Calculate direction and velocity
            dx := to_x - from_x
            dy := to_y - from_y
            distance := math.sqrt(dx*dx + dy*dy)
            
            if distance > 0 {
                fb.vel_x = (dx / distance) * FIREBALL_SPEED
                fb.vel_y = (dy / distance) * FIREBALL_SPEED
            } else {
                fb.vel_x = FIREBALL_SPEED
                fb.vel_y = 0
            }
            
            fb.life_time = 0
            fb.max_life = FIREBALL_RANGE / FIREBALL_SPEED // time to travel max range
            break
        }
    }
}

fireballs_update :: proc(game: ^Game_State, dt: f32) {
    for i in 0..<MAX_FIREBALLS {
        fb := &game.fireballs.data[i]
        if !fb.active do continue
        
        // Update position
        fb.pos_x += fb.vel_x * dt
        fb.pos_y += fb.vel_y * dt
        fb.life_time += dt
        
        // Check if fireball should disappear
        if fb.life_time >= fb.max_life {
            fb.active = false
            continue
        }
        
        // Check collision with terrain
        tile_x := cast(int)fb.pos_x
        tile_y := cast(int)fb.pos_y
        if bounds_check(tile_x, tile_y) && tile_is_solid(&game.world, tile_x, tile_y) {
            fb.active = false
            // TODO: Could add explosion particles here
            continue
        }
        
        // Check collision with player
        player := &game.player
        dx := fb.pos_x - player.pos_x
        dy := fb.pos_y - player.pos_y
        distance := math.sqrt(dx*dx + dy*dy)
        
        if distance < 0.5 { // Hit player
            fb.active = false
            // Damage player
            game.player.health = max(game.player.health - 2, 0) // 2 damage per fireball
            
            // Check for player death
            if game.player.health <= 0 && !game.player_dead {
                game.player_dead = true
                game.death_timer = 0
                game.death_explosion_done = false
            }
        }
    }
}

fireballs_render :: proc(fireballs: ^Enemy_Fireballs, cam_x, cam_y: f32) {
    for i in 0..<MAX_FIREBALLS {
        fb := &fireballs.data[i]
        if !fb.active do continue
        
        // Convert world position to screen position
        screen_x := fb.pos_x * TILE_SIZE - cam_x
        screen_y := fb.pos_y * TILE_SIZE - cam_y
        
        // Draw fireball as a glowing red-orange circle
        size := 6 + cast(i32)(math.sin(fb.life_time * 10) * 2) // pulsing effect
        rl.DrawCircle(cast(i32)screen_x, cast(i32)screen_y, cast(f32)size, rl.Color{255, 100, 0, 200}) // Orange core
        rl.DrawCircle(cast(i32)screen_x, cast(i32)screen_y, cast(f32)(size - 2), rl.Color{255, 200, 0, 150}) // Yellow inner
        rl.DrawCircle(cast(i32)screen_x, cast(i32)screen_y, cast(f32)(size - 4), rl.Color{255, 255, 100, 100}) // Bright center
    }
}
