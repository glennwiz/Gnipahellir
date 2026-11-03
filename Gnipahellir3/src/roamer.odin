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
ROAMER_SCATTER     :: 7919      // prime, so find_cave_home's walk meets every cell
ROAMER_MAX_DROP    :: 3         // a wanderer walks off nothing taller: a surface
                                // creature stays out of the shafts
BITE_SLOW          :: f32(0.6)  // the player's speed while a bite's slow runs

POND_FROG_HP    :: 2
POND_FROG_W     :: f32(0.7)
POND_FROG_H     :: f32(0.6)
POND_FROG_SPEED :: f32(3.0)

EMBER_BEETLE_HP    :: 3
EMBER_BEETLE_W     :: f32(0.8)
EMBER_BEETLE_H     :: f32(0.5)
EMBER_BEETLE_SPEED :: f32(2.5)

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

Roamer_Spec :: struct {
    level:    int,
    cap:      int,   // 0 = not a roamer
    friendly: bool,  // runs on sight and turrets leave it alone
    sight:    i32,   // tiles at which it reacts to the player
    damage:   int,   // bite; only an unhurt hostile comes to use it
    swims:    bool,  // lives in water and notices only a player who is in it
    slows:    f32,   // seconds of BITE_SLOW a bite leaves on the player
    burns:    bool,  // sets the open cave floor it stands on alight
}

@(rodata)
roamer_table := #partial [Enemy_Kind]Roamer_Spec{
    .Pond_Frog    = {level = LEVEL_SURFACE, cap = 4, friendly = true, sight = 7},
    .Ember_Beetle = {level = LEVEL_SURFACE, cap = 3, sight = 6, damage = 1},
    .Cave_Eel     = {level = LEVEL_CAVE2, cap = 3, sight = 8, damage = 2, swims = true, slows = CAVE_EEL_BITE_SLOW},
    .Magma_Crawler = {level = LEVEL_CAVE2, cap = 3, sight = 6, damage = 2, burns = true},
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
    tx, ty: int
    found: bool
    if roamer_table[kind].level != LEVEL_SURFACE {
        tx, ty, found = find_cave_home(gs, roamer_table[kind], hash)
    } else {
        tx, ty, found = find_surface_floor(&gs.world, CAVE_LEFT + int(hash % u32(CAVE_RIGHT - CAVE_LEFT)))
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
// see and bites, and the rest of the time everyone wanders.  A swimmer does all
// that in water and hears nothing outside it; with the water gone it falls and
// lies there until water comes back.
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
    if !open do e.facing = -e.facing
}
