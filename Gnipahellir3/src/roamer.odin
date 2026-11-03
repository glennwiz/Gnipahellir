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
ROAMER_MAX_DROP    :: 3         // a wanderer walks off nothing taller: a surface
                                // creature stays out of the shafts
ROAMER_AIR_TOP     :: 10        // rows a flyer spawns and drifts in, on the sky
ROAMER_AIR_BOTTOM  :: 76        // level: above the void the player falls out of

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

MOLE_HP        :: 3
MOLE_W         :: f32(0.9)
MOLE_H         :: f32(0.6)
MOLE_SPEED     :: f32(2.0)
MOLE_DIG_EVERY :: f32(90)   // seconds of calm between holes

Roamer_Spec :: struct {
    level:    int,   // a walker's floor comes from find_surface_floor, surface rows only
    cap:      int,   // 0 = not a roamer
    friendly: bool,  // runs on sight and turrets leave it alone
    sight:    i32,   // tiles at which it reacts to the player
    damage:   int,   // bite; only an unhurt hostile comes to use it
    dig_every: f32,  // seconds of calm between holes; 0 = never digs
}

@(rodata)
roamer_table := #partial [Enemy_Kind]Roamer_Spec{
    .Pond_Frog    = {level = LEVEL_SURFACE, cap = 4, friendly = true, sight = 7},
    .Ember_Beetle = {level = LEVEL_SURFACE, cap = 3, sight = 6, damage = 1},
    .Rain_Wisp    = {level = LEVEL_SKY, cap = 3, sight = 10},
    .Mole         = {level = LEVEL_SURFACE, cap = 2, friendly = true, sight = 5, dig_every = MOLE_DIG_EVERY},
}

// What a digging roamer will open.  Never den material or a chest, so a den and
// a hoard are out of its reach by this table alone.  No Dirt: world gen lays
// none, and every Dirt in play was placed or settled and carries .Placed.
@(rodata)
roamer_earth := #partial [Tile_Type]bool{
    .Grass = true,
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

// One roamer on open ground out of the player's sight.  A bad roll (too near,
// standing in water or lava) spends the beat; the next one tries again.
spawn_roamer :: proc(gs: ^Game_State, kind: Enemy_Kind) -> bool {
    hash := whash(u32(gs.frame)*31 + u32(kind)*613)
    hint := CAVE_LEFT + int(hash % u32(CAVE_RIGHT - CAVE_LEFT))
    tx, ty, found := hint, ROAMER_AIR_TOP + int((hash >> 8) % (ROAMER_AIR_BOTTOM - ROAMER_AIR_TOP)), true
    if enemy_behaviour[kind].gravity != 0 do tx, ty, found = find_surface_floor(&gs.world, hint)
    if !found || get_tile(&gs.world, tx, ty) != .Air do return false
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

// May a roamer open the floor tile (x, y)?  Natural earth only, with nothing
// standing on it or beside it to fall in, and solid all round the hole, so it
// is one deep, it opens no cave roof, and a pit never gets dug deeper or wider.
// Nothing that falls may stand beside or under it, so a plank bridge or a tree
// leaning on the lip keeps its anchor.
roamer_may_dig :: proc(gs: ^Game_State, x, y: int) -> bool {
    w := &gs.world
    if !roamer_earth[get_tile(w, x, y)] || .Placed in w.tile_flags[grid_idx(x, y)] do return false
    for dx in -1 ..= 1 do if get_tile(w, x + dx, y - 1) != .Air do return false
    for n in ([3][2]int{{-1, 0}, {1, 0}, {0, 1}}) {
        nx, ny := x + n.x, y + n.y
        if !is_solid(w, nx, ny) || is_faller(w, nx, ny) do return false
    }
    return true
}

// Dig the floor out from under it, through the mine handler, and turn up
// whatever the row pays into the hole.
roamer_dig :: proc(e: ^Enemy, id: int, gs: ^Game_State) -> bool {
    T := builder_tile(e) + {0, 1}
    if !roamer_may_dig(gs, int(T.x), int(T.y)) do return false
    handle_tile_mined(gs, Event{type = .Tile_Mined, source = enemy_entity_id(id), tile = T})
    roll_drops(gs, e.kind, dig_drop_table[e.kind], T)
    return true
}

// Friendlies run on sight.  A hurt roamer runs from further off and through
// walls: it knows who hit it.  An unhurt hostile comes for the player it can
// see and bites, and the rest of the time everyone wanders.
update_roamer :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    spec := roamer_table[e.kind]
    b    := &e.builder
    b.attack_timer = max(b.attack_timer - dt, 0)

    away, dist, seen := roamer_sense(e, gs, spec.sight)

    if !gs.player.dead && e.hp < e.hp_max && dist <= i32(HUNT_LOSE_DIST) || seen && spec.friendly {
        roamer_walk(e, gs, away)
        return
    }
    if seen {
        if dist > 1 {
            roamer_walk(e, gs, -away)
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
            log_action(gs, "%v#%d bites the player", e.kind, id)
        }
        return
    }

    // A digger's clock runs only in calm; stuck_timer is otherwise a builder's.
    if spec.dig_every > 0 {
        b.stuck_timer += dt
        if b.stuck_timer >= spec.dig_every && e.grounded && roamer_dig(e, id, gs) do b.stuck_timer = 0
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
    if b.has_target && !roamer_walk(e, gs, e.facing, careful = true) do e.facing = -e.facing
}
