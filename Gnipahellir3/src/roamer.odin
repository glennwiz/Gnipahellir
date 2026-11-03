package game

import "core:math"

// ─── Roamers: creatures that live on a level ──────────────────────────────────
//
//  Step 5b1b in game_update tops each level up to its caps.  A roamer is a TABLE
//  ROW: a new creature is a row here, a row in enemy_behaviour, a drop row and a
//  look.  They hold ordinary enemy slots, so damage, drops and saves come free;
//  is_wave_enemy never names them, so they neither join a wave nor hold one back.
//
//  Every number is a first guess for Glenn to tune.

ROAMER_SPAWN_EVERY :: f32(15)   // seconds between top-ups, one per row
ROAMER_SPAWN_CLEAR :: i32(30)   // tiles from the player: nothing pops in on screen
ROAMER_WHIM_TIME   :: f32(2.5)  // seconds between wandering choices
ROAMER_HOP         :: f32(-7)   // apex ~1.2 tiles: over a one-tile step
ROAMER_SCATTER     :: 7919      // prime, so find_cave_home's walk meets every cell
ROAMER_MAX_DROP    :: 3         // a wanderer walks off nothing taller: a surface
                                // creature stays out of the shafts
ROAMER_AIR_TOP     :: 10        // rows a flyer spawns and drifts in, on the sky
ROAMER_AIR_BOTTOM  :: 76        // level: above the void the player falls out of
BITE_SLOW          :: f32(0.6)  // the player's speed while a bite's slow runs

POND_FROG_HP    :: 2
POND_FROG_W     :: f32(0.7)
POND_FROG_H     :: f32(0.6)
POND_FROG_SPEED :: f32(3.0)

EMBER_BEETLE_HP    :: 3
EMBER_BEETLE_W     :: f32(0.8)
EMBER_BEETLE_H     :: f32(0.5)
EMBER_BEETLE_SPEED :: f32(2.5)

RAIN_WISP_HP         :: 3
RAIN_WISP_W          :: f32(0.8)
RAIN_WISP_H          :: f32(0.6)
RAIN_WISP_SPEED      :: f32(2.5)
RAIN_WISP_HOVER      :: f32(5)    // tiles it holds over the player's head
RAIN_WISP_REACH      :: f32(1.5)  // sideways tiles off the head it still drips
RAIN_WISP_DRIP_TIME  :: f32(1.5)  // seconds between drips
RAIN_WISP_DRIP_SPEED :: f32(9)    // tiles a second, straight down
RAIN_WISP_ROAM       :: 6         // tiles a drifting whim reaches sideways
RAIN_WISP_FLEE       :: f32(8)    // tiles a hurt wisp aims away
RAIN_SOAK_TIME       :: f32(3)    // seconds one drip drags the player
RAIN_SOAK_DRAG       :: f32(0.6)  // stride while soaked

CAVE_EEL_HP        :: 4
CAVE_EEL_W         :: f32(1.1)
CAVE_EEL_H         :: f32(0.4)
CAVE_EEL_SPEED     :: f32(4.0)
CAVE_EEL_BITE_SLOW :: f32(2.0)  // seconds

MAGMA_CRAWLER_HP    :: 6
MAGMA_CRAWLER_W     :: f32(0.9)
MAGMA_CRAWLER_H     :: f32(0.5)
MAGMA_CRAWLER_SPEED :: f32(2.0)
CINDERS_LIFE        :: f32(6)   // seconds a burning tile stays alight

STONE_GRUB_HP       :: 12
STONE_GRUB_W        :: f32(0.9)
STONE_GRUB_H        :: f32(0.7)
STONE_GRUB_SPEED    :: f32(1.5)
STONE_GRUB_EAT_TIME :: f32(3)   // seconds a bite of wall takes

Roamer_Spec :: struct {
    level:    int,   // flyers spawn in the air; walkers on the surface use find_surface_floor, elsewhere find_cave_home
    cap:      int,   // 0 = not a roamer
    friendly: bool,  // runs on sight and turrets leave it alone
    sight:    i32,   // tiles at which it reacts to the player
    damage:   int,   // bite; only an unhurt hostile comes to use it
    swims:    bool,  // lives in water and notices only a player who is in it
    slows:    f32,   // seconds of BITE_SLOW a bite leaves on the player
    burns:    bool,  // sets the open cave floor it stands on alight
    eats:     bool,  // a wanderer chews through the natural wall it meets
}

@(rodata)
roamer_table := #partial [Enemy_Kind]Roamer_Spec{
    .Pond_Frog    = {level = LEVEL_SURFACE, cap = 4, friendly = true, sight = 7},
    .Ember_Beetle = {level = LEVEL_SURFACE, cap = 3, sight = 6, damage = 1},
    .Rain_Wisp    = {level = LEVEL_SKY, cap = 3, sight = 10},
    .Cave_Eel     = {level = LEVEL_CAVE2, cap = 3, sight = 8, damage = 2, swims = true, slows = CAVE_EEL_BITE_SLOW},
    .Magma_Crawler = {level = LEVEL_CAVE2, cap = 3, sight = 6, damage = 2, burns = true},
    .Stone_Grub   = {level = LEVEL_CAVE2, cap = 3, sight = 5, damage = 1, eats = true},
}

// Step 5b1b.
update_roamers :: proc(gs: ^Game_State) {
    gs.roamer_timer += gs.delta_time
    if gs.roamer_timer < ROAMER_SPAWN_EVERY do return
    gs.roamer_timer = 0
    for spec, kind in roamer_table {
        if spec.level != gs.level_index do continue
        n := 0
        for &e, i in gs.enemies.data do if gs.enemies.active[i] && e.kind == kind do n += 1
        if n < spec.cap do spawn_roamer(gs, kind)
    }
}

// A cave creature's home, out of the player's sight: the first water cell for a
// swimmer, or open floor for a walker, on a scattered walk through the grid, so
// a lone pool is found however little water the level holds.
find_cave_home :: proc(gs: ^Game_State, spec: Roamer_Spec, hash: u32) -> (tx, ty: int, ok: bool) {
    w := &gs.world
    n := GRID_W * GRID_H
    for i in 0 ..< n {
        c := (int(hash % u32(n)) + i*ROAMER_SCATTER) % n
        x, y := c % GRID_W, c / GRID_W
        home := swimmable(w, x, y) if spec.swims else get_tile(w, x, y) == .Void && is_solid(w, x, y + 1)
        if home && abs(i32(x) - player_tile(&gs.player).x) >= ROAMER_SPAWN_CLEAR do return x, y, true
    }
    return 0, 0, false
}

swimmable :: proc(w: ^World_Grid, x, y: int) -> bool {
    return .Swimmable in terrain_table[get_tile(w, x, y)].flags
}

// One roamer on open ground, or at its home in a cave, out of the player's
// sight.  A bad roll (too near, standing in water or lava) spends the beat; the
// next one tries again.
spawn_roamer :: proc(gs: ^Game_State, kind: Enemy_Kind) -> bool {
    hash := whash(u32(gs.frame)*31 + u32(kind)*613)
    hint := CAVE_LEFT + int(hash % u32(CAVE_RIGHT - CAVE_LEFT))
    tx, ty, found := hint, ROAMER_AIR_TOP + int((hash >> 8) % (ROAMER_AIR_BOTTOM - ROAMER_AIR_TOP)), true
    walks := enemy_behaviour[kind].gravity != 0
    if roamer_table[kind].swims || walks && roamer_table[kind].level != LEVEL_SURFACE {
        tx, ty, found = find_cave_home(gs, roamer_table[kind], hash)
    } else {
        if walks do tx, ty, found = find_surface_floor(&gs.world, hint)
        found &&= get_tile(&gs.world, tx, ty) == .Air
    }
    if !found do return false
    if abs(i32(tx) - player_tile(&gs.player).x) < ROAMER_SPAWN_CLEAR do return false

    id, ok := enemy_alloc(&gs.enemies)
    if !ok do return false
    row := enemy_behaviour[kind]
    e := &gs.enemies.data[id]
    e^ = Enemy{
        kind = kind, hp = row.hp, hp_max = row.hp,
        facing = 1 if hash & 1 == 0 else -1,
        pos = {f32(tx) + (1 - row.body.x)*0.5, f32(ty) + 1 - row.body.y},
    }
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    log_action(gs, "%v#%d wanders in at (%d,%d)", kind, id, tx, ty)
    return true
}

// Cinders burn out where they lie (tile_on_tick).  Only .Void is ever lit, so
// .Void is what comes back.
tick_cinders :: proc(gs: ^Game_State, x, y: int) {
    sd := &gs.world.sim_data[grid_idx(x, y)]
    sd.growth_timer += gs.delta_time
    if sd.growth_timer < CINDERS_LIFE do return
    sd.growth_timer = 0
    set_tile(&gs.world, x, y, .Void)
}

// Swim one way, and `climb` rows' way, staying inside the water.  Says whether
// any of it was open, so a wanderer can turn round at the bank.
roamer_swim :: proc(e: ^Enemy, gs: ^Game_State, dir, climb: int) -> bool {
    size := enemy_body_size(e.kind)
    mid  := e.pos + size*0.5
    e.facing = dir
    e.vel    = {}
    if swimmable(&gs.world, int(mid.x + f32(dir)*(size.x*0.5 + 0.2)), int(mid.y)) {
        e.vel.x = f32(dir) * enemy_speed(e.kind)
    }
    if swimmable(&gs.world, int(mid.x), int(mid.y + f32(climb)*(size.y*0.5 + 0.2))) {
        e.vel.y = f32(climb) * enemy_speed(e.kind)
    }
    return e.vel != {}
}

// What a grub's teeth may take: natural rock only.  is_builder_mineable keeps it
// off chests, loaded containers and anything holding water back.
roamer_may_eat :: proc(gs: ^Game_State, x, y: int) -> bool {
    return is_builder_mineable(gs, x, y) && !den_protected(gs, x, y) &&
           !is_structure_tile[get_tile(&gs.world, x, y)] &&
           .Placed not_in gs.world.tile_flags[grid_idx(x, y)]
}

// Chew the wall at the feet, one bite each STONE_GRUB_EAT_TIME, never the
// border columns.  Stone is eaten;
// anything else it spits out where it stood, so no ore or gem is lost to it.
// False when there is nothing here it may eat.
roamer_eat :: proc(e: ^Enemy, id: int, gs: ^Game_State) -> bool {
    size := enemy_body_size(e.kind)
    x := int(e.pos.x + size.x*0.5 + f32(e.facing)*(size.x*0.5 + 0.2))
    y := int(e.pos.y + size.y - 0.01)
    if x < CAVE_LEFT || x >= CAVE_RIGHT || !roamer_may_eat(gs, x, y) do return false
    if e.builder.attack_timer > 0 do return true
    e.builder.attack_timer = STONE_GRUB_EAT_TIME
    old  := get_tile(&gs.world, x, y)
    drop := terrain_table[old].drop_item
    // smash_tile already drops what knocks loose (a door): never twice.
    if !smash_tile(gs, x, y) && old != .Stone && drop != .None do spawn_ground_item(&gs.world, {i32(x), i32(y)}, drop, 1)
    log_action(gs, "%v#%d eats the %v at (%d,%d)", e.kind, id, old, x, y)
    return true
}

// Walk one way, hopping a one-tile step.  Refuses lava and walls too tall to
// hop, and when `careful` a tall drop, and says so, so a wanderer can turn round.
roamer_walk :: proc(e: ^Enemy, gs: ^Game_State, dir: int, careful := false) -> bool {
    size := enemy_body_size(e.kind)
    e.facing = dir
    e.vel.x  = 0
    x := int(e.pos.x + size.x*0.5 + f32(dir)*(size.x*0.5 + 0.2))
    y := int(e.pos.y + size.y - 0.01)
    if x < CAVE_LEFT || x >= CAVE_RIGHT do return false
    for dy in 0 ..= 1 {
        t := get_tile(&gs.world, x, y + dy)
        if t == .Lava || t == .Magic_Lava do return false
    }
    if is_solid(&gs.world, x, y) {
        if is_solid(&gs.world, x, y - 1) do return false
        if e.grounded do e.vel.y = ROAMER_HOP
    } else if careful {
        floor := false
        for dy in 1 ..= ROAMER_MAX_DROP do floor ||= is_solid(&gs.world, x, y + dy)
        if !floor do return false
    }
    e.vel.x = f32(dir) * enemy_speed(e.kind)
    return true
}

// Steer at a point in the air, rising over a wall dead ahead.  Zero gravity in
// the row: the shared mover does the collision, as for the fire sprite.
roamer_fly :: proc(e: ^Enemy, gs: ^Game_State, goal: [2]f32) {
    size   := enemy_body_size(e.kind)
    center := e.pos + size*0.5
    goal   := [2]f32{
        clamp(goal.x, f32(CAVE_LEFT) + 1, f32(CAVE_RIGHT) - 1),
        clamp(goal.y, f32(ROAMER_AIR_TOP), f32(ROAMER_AIR_BOTTOM)),
    }
    d := goal - center
    l := math.sqrt(d.x*d.x + d.y*d.y)
    if l < 0.1 {
        e.vel = {}
        return
    }
    speed := enemy_speed(e.kind)
    e.vel = d / l * speed
    if abs(d.x) < 0.1 do return
    e.facing = 1 if d.x > 0 else -1
    x := int(center.x + f32(e.facing)*(size.x*0.5 + 0.2))
    for y in int(e.pos.y) ..= int(e.pos.y + size.y) {
        if is_solid(&gs.world, x, y) {
            e.vel.y = -speed
            break
        }
    }
}

// What a roamer knows of the player: which way is away, how far, and whether
// it sees them.
roamer_sense :: proc(e: ^Enemy, gs: ^Game_State, sight: i32) -> (away: int, dist: i32, seen: bool) {
    bt := builder_tile(e)
    pt := player_tile(&gs.player)
    away = 1 if bt.x >= pt.x else -1
    dist = chebyshev(bt, pt)
    seen = !gs.player.dead && dist <= sight && sight_line_clear(&gs.world,
        {f32(bt.x) + 0.5, f32(bt.y) + 0.5}, {f32(pt.x) + 0.5, f32(pt.y) + 0.5}, skip_ends = true)
    return
}

// Drifts on a whim until it sees the player, then holds over their head and
// drips: a dodgeable drop, stopped by any roof, that soaks instead of hurts.
// Hurt, it flees up and away.
update_rain_wisp :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    b.attack_timer = max(b.attack_timer - dt, 0)
    away, dist, seen := roamer_sense(e, gs, roamer_table[e.kind].sight)

    if !gs.player.dead && e.hp < e.hp_max && dist <= i32(HUNT_LOSE_DIST) {
        roamer_fly(e, gs, e.pos + {f32(away)*RAIN_WISP_FLEE, -RAIN_WISP_FLEE*0.5})
        return
    }
    if seen {
        head   := gs.player.pos + {PLAYER_W*0.5, 0}
        mid    := e.pos.x + RAIN_WISP_W*0.5
        roamer_fly(e, gs, head - {0, RAIN_WISP_HOVER})
        if b.attack_timer <= 0 && abs(mid - head.x) <= RAIN_WISP_REACH && e.pos.y < head.y {
            b.attack_timer = RAIN_WISP_DRIP_TIME
            spawn_projectile(gs, {mid, e.pos.y + RAIN_WISP_H + PROJECTILE_RADIUS},
                {0, RAIN_WISP_DRIP_SPEED}, enemy_entity_id(id), 0, drip = true)
            log_action(gs, "%v#%d drips on the player", e.kind, id)
        }
        return
    }

    // Drift: target_tile is the whim's spot in the air.
    b.cooldown -= dt
    if b.cooldown <= 0 {
        b.cooldown = ROAMER_WHIM_TIME
        whim := whash(u32(gs.frame)*17 + u32(id)*7919)
        reach := u32(RAIN_WISP_ROAM*2 + 1)
        b.target_tile = builder_tile(e) + {i32(whim % reach) - RAIN_WISP_ROAM, i32((whim >> 8) % 5) - 2}
    }
    roamer_fly(e, gs, {f32(b.target_tile.x) + 0.5, f32(b.target_tile.y) + 0.5})
}

// Friendlies run on sight.  A hurt roamer runs from further off and through
// walls: it knows who hit it.  An unhurt hostile comes for the player it can
// see and bites, and the rest of the time everyone wanders.  A swimmer does all
// that in water and hears nothing outside it; with the water gone it falls and
// lies there until water comes back.
update_roamer :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    spec := roamer_table[e.kind]
    b    := &e.builder
    b.attack_timer = max(b.attack_timer - dt, 0)

    away, dist, seen := roamer_sense(e, gs, spec.sight)
    bt    := builder_tile(e)
    pt    := player_tile(&gs.player)
    below := 1 if bt.y >= pt.y else -1   // away, up and down

    if spec.burns && get_tile(&gs.world, int(bt.x), int(bt.y)) == .Void && is_solid(&gs.world, int(bt.x), int(bt.y) + 1) {
        set_tile(&gs.world, int(bt.x), int(bt.y), .Cinders)
        gs.world.sim_data[grid_idx(int(bt.x), int(bt.y))].growth_timer = 0
    }

    if spec.swims {
        if !swimmable(&gs.world, int(bt.x), int(bt.y)) {
            e.vel.x = 0
            e.vel.y = min(e.vel.y + BUILDER_GRAVITY*dt, BUILDER_MAX_FALL)
            return
        }
        e.vel.y = 0
        seen &&= player_in_water(gs)
    }

    if !gs.player.dead && e.hp < e.hp_max && dist <= i32(HUNT_LOSE_DIST) || seen && spec.friendly {
        if spec.swims {
            roamer_swim(e, gs, away, below)
        } else {
            roamer_walk(e, gs, away)
        }
        return
    }
    if seen {
        if dist > 1 {
            if spec.swims {
                roamer_swim(e, gs, -away, pt.y == bt.y ? 0 : -below)
            } else {
                roamer_walk(e, gs, -away)
            }
            return
        }
        e.vel.x  = 0
        e.facing = -away
        if b.attack_timer <= 0 {
            b.attack_timer = ATTACK_TIME
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = enemy_entity_id(id),
                target  = PLAYER_ID,
                payload = {int_val = i32(spec.damage)},
            })
            if spec.slows > 0 {
                eq_push(&gs.events, Event{type = .Player_Slowed, target = PLAYER_ID, payload = {float_val = spec.slows}})
            }
            log_action(gs, "%v#%d bites the player", e.kind, id)
        }
        return
    }

    // Wander: has_target is "walking", facing the way.
    b.cooldown -= dt
    if b.cooldown <= 0 {
        b.cooldown = ROAMER_WHIM_TIME
        whim := whash(u32(gs.frame)*17 + u32(id)*7919) % 3
        b.has_target = whim != 0
        if whim == 1 do e.facing = -e.facing
    }
    e.vel.x = 0
    if !b.has_target do return
    open := roamer_swim(e, gs, e.facing, 0) if spec.swims else roamer_walk(e, gs, e.facing, careful = true)
    if !open && !(spec.eats && roamer_eat(e, id, gs)) do e.facing = -e.facing
}
