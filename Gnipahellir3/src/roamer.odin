package game

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

POND_FROG_HP    :: 2
POND_FROG_W     :: f32(0.7)
POND_FROG_H     :: f32(0.6)
POND_FROG_SPEED :: f32(3.0)

EMBER_BEETLE_HP    :: 3
EMBER_BEETLE_W     :: f32(0.8)
EMBER_BEETLE_H     :: f32(0.5)
EMBER_BEETLE_SPEED :: f32(2.5)

Roamer_Spec :: struct {
    level:    int,   // spawn floors come from find_surface_floor: surface rows only
    cap:      int,   // 0 = not a roamer
    friendly: bool,  // runs on sight and turrets leave it alone
    sight:    i32,   // tiles at which it reacts to the player
    damage:   int,   // bite; only an unhurt hostile comes to use it
}

@(rodata)
roamer_table := #partial [Enemy_Kind]Roamer_Spec{
    .Pond_Frog    = {level = LEVEL_SURFACE, cap = 4, friendly = true, sight = 7},
    .Ember_Beetle = {level = LEVEL_SURFACE, cap = 3, sight = 6, damage = 1},
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
    tx, ty, found := find_surface_floor(&gs.world, CAVE_LEFT + int(hash % u32(CAVE_RIGHT - CAVE_LEFT)))
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

// Friendlies run on sight.  A hurt roamer runs from further off and through
// walls: it knows who hit it.  An unhurt hostile comes for the player it can
// see and bites, and the rest of the time everyone wanders.
update_roamer :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    spec := roamer_table[e.kind]
    b    := &e.builder
    b.attack_timer = max(b.attack_timer - dt, 0)

    bt   := builder_tile(e)
    pt   := player_tile(&gs.player)
    away := 1 if bt.x >= pt.x else -1
    dist := chebyshev(bt, pt)
    seen := !gs.player.dead && dist <= spec.sight && sight_line_clear(&gs.world,
        {f32(bt.x) + 0.5, f32(bt.y) + 0.5}, {f32(pt.x) + 0.5, f32(pt.y) + 0.5}, skip_ends = true)

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
