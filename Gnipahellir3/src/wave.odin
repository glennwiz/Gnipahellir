package game

// ─── Waves: the enemy pressure director ───────────────────────────────────────
//
//  Step 5b1a in game_update, right after the raid director and well before
//  process_events, so the notify/sound a wave pushes drains the same frame.
//
//  A wave is a TABLE ROW, not code: kind -> enemy, count, spawner.  Future
//  waves are edits here.  Everything funnels through `wave_force`, so the
//  trigger and the F4 menu send waves the identical way and swapping the
//  trigger later never touches the spawning.
//
//  TESTING TRIGGER: every Fire Wand craft arms one wave, and the cycle walks
//  Air -> Ground -> Underground -> repeat (events.odin, .Craft_Complete).
//  Waves deliberately STACK — craft three wands and three waves are on the
//  field at once, which is the point while Glenn is tuning pressure.

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

// THE single entry point: spawn one wave of `kind`, announce it, and report
// how many actually landed.  The director and the F4 menu both come through
// here, so a forced wave and a triggered one are the same event.
wave_force :: proc(gs: ^Game_State, kind: Wave_Kind) -> int {
    spec    := wave_table[kind]
    spawned := 0
    for n in 0 ..< spec.count do if spec.spawn(gs, n) do spawned += 1

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

// Step 5b1a.  Spend an armed trigger on the surface.  Off-surface the pending
// flag HOLDS rather than firing into a cave: a wave hunts the base, and the
// base is up top.
update_waves :: proc(gs: ^Game_State) {
    if !gs.wave.pending || gs.level_index != LEVEL_SURFACE do return
    gs.wave.pending = false
    wave_force(gs, Wave_Kind(gs.wave.cycle %% len(Wave_Kind)))
    gs.wave.cycle += 1
}

// ─── Wave Debug Actions (F4 menu, input.odin drives these) ──────────────────

debug_wave_spawn :: proc(gs: ^Game_State, kind: Wave_Kind) {
    wave_force(gs, kind)
}

// Repeatable testing: despawn every wave enemy and reset the cycle.  An
// INDUSTRY raider is not a wave enemy and survives — only .Wave_Hunt ones go.
debug_wave_clear :: proc(gs: ^Game_State) {
    cleared := 0
    for &e, i in gs.enemies.data {
        if !gs.enemies.active[i] do continue
        if e.kind == .Fire_Sprite || e.kind == .Vargr ||
           (e.kind == .Raider && e.builder.goal == .Wave_Hunt) {
            despawn_enemy(gs, i)
            cleared += 1
        }
    }
    gs.wave = {}
    notify(gs, "Debug: %d wave enemies cleared, cycle reset", cleared)
}
