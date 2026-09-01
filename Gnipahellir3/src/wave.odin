package game

// ─── Waves: the enemy pressure director ───────────────────────────────────────
//
//  Step 5b1a in game_update, right after the raid director and well before
//  process_events, so the notify/sound a wave pushes drains the same frame.
//
//  A wave is a TABLE ROW, not code: kind -> enemy, count, spawner.  Future
//  waves are edits here.  Everything funnels through `wave_force`, so the
//  director and the F4 menu send waves the identical way.
//
//  THE TRIGGER IS THE BASE ITSELF.  `wave_threat` scores every structure on
//  the surface; that score accumulates into `pressure`, and at the target a
//  25 s howl warning arms before the wave lands.  So the opening is calm
//  because an early base has almost nothing worth raiding — not because a
//  timer was set generously — and what draws the wave is exactly what the
//  wave comes to smash.  Scripted milestones ride the same warning through
//  `wave_trigger`, ignoring pressure and gates alike.
//
//  Every number here is a first guess for playtest tuning (F4 shows the live
//  threat/pressure).  Retune from observation, not from taste.

WAVE_PRESSURE_TARGET :: f32(1200)  // threat-seconds accumulated before a wave
WAVE_WARNING_TIME    :: f32(25)    // the telegraph IS the engagement: run home,
                                   // check the lasers, wield the wand
WAVE_COOLDOWN        :: f32(90)    // floor between pressure waves
WAVE_THREAT_RESCAN   :: f32(2)     // the scan is full-grid — keep it off the frame
WAVE_TIER_AIR        :: f32(20)
WAVE_TIER_UNDER      :: f32(40)
WAVE_SIZE_PIVOT      :: f32(40)    // wave size reaches the table count at PIVOT/2

Wave_Spec :: struct {
    enemy: Enemy_Kind,
    count: int,
    spawn: proc(gs: ^Game_State, n: int) -> bool,
}

@(rodata)
wave_table := [Wave_Kind]Wave_Spec{
    .Air         = {.Fire_Sprite, 4, spawn_wave_flyer},
    .Ground      = {.Vargr,       3, spawn_wave_walker},
    .Underground = {.Raider,      2, spawn_wave_tunneller},
}

@(rodata)
wave_name := [Wave_Kind]string{
    .Air         = "AIR",
    .Ground      = "GROUND",
    .Underground = "UNDERGROUND",
}

// What a structure is worth to the things outside.  Anything `is_structure_tile`
// but absent here scores 1 — a barrel is still loot.  Machines are the loud,
// rich prize; a laser scores because defense is wealth too, which is what keeps
// turret spam from being free.
@(rodata)
wave_threat_weight := #partial [Tile_Type]f32{
    .Smelter        = 3,
    .Boiler         = 3,
    .Steam_Engine   = 3,
    .Magic_Kettle   = 3,
    .Mana_Wheel     = 3,
    .Gem_Replicator = 3,
    .Auto_Miner     = 3,
    .Dvergr_Forge   = 3,
    .Rainbow_Laser  = 2,
}

// Threat at which each kind joins the cycle.  Ground is always open — some-
// thing always walks in.
@(rodata)
wave_tier_gate := [Wave_Kind]f32{
    .Air         = WAVE_TIER_AIR,
    .Ground      = 0,
    .Underground = WAVE_TIER_UNDER,
}

// How rich the surface looks from outside.  Full-grid scan: call it ONLY on
// the WAVE_THREAT_RESCAN beat, never per frame (raid_heat_target's per-frame
// scan is already a known smell — do not add a second one).
wave_threat :: proc(gs: ^Game_State) -> (score: f32) {
    for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
        t := gs.world.terrain[grid_idx(x, y)]
        if !is_structure_tile[t] do continue
        if w := wave_threat_weight[t]; w > 0 {
            score += w
        } else {
            score += 1
        }
    }
    // The world's danger rises as you progress, even for a lean base.
    for found in gs.progression.rune_scroll_found do if found do score += 5
    return
}

// The hunters' structure index — same grid walk as wave_threat, on the same
// beat (a second scan every 2 s, never per frame), plus lazily the first time
// a hunter asks before the beat has run.  Row-major order, so a base past
// MAX_WAVE_STRUCTURES entries is only ever hunted from the top rows down.
wave_index_structures :: proc(gs: ^Game_State) {
    w := &gs.wave
    w.structures_n = 0
    for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
        if !is_structure_tile[gs.world.terrain[grid_idx(x, y)]] do continue
        if w.structures_n >= MAX_WAVE_STRUCTURES do break
        w.structures[w.structures_n] = {i32(x), i32(y)}
        w.structures_n += 1
    }
    w.structures_indexed = true
}

// A wave enemy is one the director sent — shared by the no-stack guard and the
// F4 clear so the two can never drift apart.  An INDUSTRY raider holds .Hunt,
// not .Wave_Hunt, and that is the whole distinction.
is_wave_enemy :: proc(e: ^Enemy) -> bool {
    return e.kind == .Fire_Sprite || e.kind == .Vargr ||
           (e.kind == .Raider && e.builder.goal == .Wave_Hunt)
}

// Has the base grown loud enough for this kind to come?
wave_kind_unlocked :: proc(gs: ^Game_State, kind: Wave_Kind, threat: f32) -> bool {
    if threat < wave_tier_gate[kind] do return false
    // Raid parity (enemy.odin): nothing comes from below before the player is
    // in the progression loop.
    if kind == .Underground && !gs.progression.rune_scroll_found[0] do return false
    return true
}

// Walk the cycle through the UNLOCKED kinds only, so a young base meets Ground
// after Ground instead of cycling into waves that cannot come yet.
wave_pick_kind :: proc(gs: ^Game_State, threat: f32) -> Wave_Kind {
    unlocked: [len(Wave_Kind)]Wave_Kind
    n := 0
    for k in Wave_Kind do if wave_kind_unlocked(gs, k, threat) {
        unlocked[n] = k
        n += 1
    }
    // Ground's gate is 0, so the list is never empty; the guard is here
    // because the alternative to it is a modulo by zero.
    if n == 0 do return .Ground
    return unlocked[gs.wave.cycle %% n]
}

// How many a wave of this threat lands.  One formula both directions: a
// bench-and-barrel base (threat ~3) gets a single wolf, the table count
// arrives around threat 20, and a machine empire gets double.
wave_scaled_count :: proc(base: int, threat: f32) -> int {
    return clamp(int(f32(base) * (0.5 + threat/WAVE_SIZE_PIVOT)), 1, base*2)
}

// THE single entry point: spawn `count` enemies of `kind`, announce it, and
// report how many actually landed.  The director scales `count` by threat while
// the F4 menu passes the table's own, so a forced wave stays reproducible.
wave_force :: proc(gs: ^Game_State, kind: Wave_Kind, count: int) -> int {
    spec    := wave_table[kind]
    spawned := 0
    for n in 0 ..< count do if spec.spawn(gs, n) do spawned += 1

    if spawned == 0 {
        notify(gs, "The %s wave finds nowhere to enter", wave_name[kind])
        log_action(gs, "Wave %s failed to spawn", wave_name[kind])
        return 0
    }
    notify(gs, "A %s wave closes on the base - %d incoming!", wave_name[kind], spawned)
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
    log_action(gs, "Wave %s: %d %v spawned", wave_name[kind], spawned, spec.enemy)
    return spawned
}

// Arm the telegraph.  Both paths come through here, because to the player a
// pressure wave and a scripted one are the same event: something is coming,
// and there is still time to get home.
wave_arm_warning :: proc(gs: ^Game_State, kind: Wave_Kind) {
    w := &gs.wave
    w.warning_kind   = kind
    w.warning_timer  = WAVE_WARNING_TIME
    w.warning_active = true
    notify(gs, "A howl rises beyond the treeline - something comes for your works!")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
    log_action(gs, "Wave warning: %s in %.0fs (threat %.1f, pressure %.0f)",
        wave_name[kind], WAVE_WARNING_TIME, w.threat, w.pressure)
}

// THE hook for a scripted moment: a milestone asks for a wave, and the next
// surface frame arms it.  It rides the same warning machinery as a pressure
// wave — announced the same, landing the same — it just does not wait for the
// meter.  Wiring a new milestone is this one call.
wave_trigger :: proc(gs: ^Game_State, kind: Wave_Kind) {
    gs.wave.pending      = true
    gs.wave.pending_kind = kind
}

// Step 5b1a.  The director: threat -> pressure -> warning -> wave -> cooldown.
update_waves :: proc(gs: ^Game_State) {
    w := &gs.wave
    if w.cooldown > 0 do w.cooldown = max(0, w.cooldown - gs.delta_time)

    // Off-surface the buildup holds — threat, pressure and an armed warning
    // all freeze, the pending flag's old semantic widened to cover them.  The
    // cooldown above is the deliberate exception, and raid parity: it is a
    // floor BETWEEN waves rather than part of the buildup, so draining it in a
    // cave costs nothing and keeps a cave trip from being a way to sit one
    // out.  Hiding DELAYS the wave, it never dodges it; softer than the raid's
    // hard reset, because threat is the whole base rather than one hot machine.
    if gs.level_index != LEVEL_SURFACE do return

    w.threat_timer -= gs.delta_time
    if w.threat_timer <= 0 {
        w.threat       = wave_threat(gs)
        w.threat_timer = WAVE_THREAT_RESCAN
        wave_index_structures(gs)
    }

    // Never stack a fresh wave on survivors (the raid's raiders_present idiom).
    // A warning already armed still lands: the telegraph was a promise, and a
    // scripted trigger waits its turn rather than being lost.
    survivors := false
    for &e, i in gs.enemies.data do if gs.enemies.active[i] && is_wave_enemy(&e) {
        survivors = true
        break
    }
    if survivors && !w.warning_active do return

    if w.warning_active {
        w.warning_timer -= gs.delta_time
        if w.warning_timer > 0 do return
        // No cancel path.  Unlike a raid you cannot quiet the base down
        // mid-warning, and mining your own bench to dodge a wave is not a game
        // we reward.
        wave_force(gs, w.warning_kind, wave_scaled_count(wave_table[w.warning_kind].count, w.threat))
        w.cycle         += 1
        w.pressure       = 0
        w.cooldown       = WAVE_COOLDOWN
        w.warning_active = false
        return
    }

    // A scripted milestone is a designed moment: it ignores pressure, cooldown
    // and the tier gates alike.
    if w.pending {
        w.pending = false
        wave_arm_warning(gs, w.pending_kind)
        return
    }

    // Threat 0 is eternal peace, and that IS the grace period: no works, no
    // wave, and nothing out there worth hunting anyway.
    w.pressure += w.threat * gs.delta_time
    if w.pressure < WAVE_PRESSURE_TARGET || w.cooldown > 0 do return
    wave_arm_warning(gs, wave_pick_kind(gs, w.threat))
}

// ─── Wave Debug Actions (F4 menu, input.odin drives these) ──────────────────

debug_wave_spawn :: proc(gs: ^Game_State, kind: Wave_Kind) {
    wave_force(gs, kind, wave_table[kind].count)
}

// Repeatable testing: despawn every wave enemy and reset the director.  An
// INDUSTRY raider is not a wave enemy and survives — only .Wave_Hunt ones go.
debug_wave_clear :: proc(gs: ^Game_State) {
    cleared := 0
    for &e, i in gs.enemies.data {
        if !gs.enemies.active[i] do continue
        if is_wave_enemy(&e) {
            despawn_enemy(gs, i)
            cleared += 1
        }
    }
    gs.wave = {}
    notify(gs, "Debug: %d wave enemies cleared, cycle reset", cleared)
}
