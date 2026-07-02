package game

game_update :: proc(gs: ^Game_State) {
    gs.delta_time    = clamp(gs.delta_time, 0, 0.05)  // cap at 50ms
    gs.elapsed_time += gs.delta_time
    gs.frame        += 1

    // 1. Input
    update_input(gs)

    // 2. Player
    update_player(gs)

    // 3. Enemies
    update_enemies(gs)

    // 4. Projectiles  (stub)
    // update_projectiles(gs)

    // 5. Sim  (stub)
    // update_sim(gs)

    // 6. Events
    process_events(gs)

    // 7. Particles  (stub)
    // update_particles(gs)

    // 8. Audio
    update_audio(gs)

    // 9. Clear event queue
    eq_clear(&gs.events)

    // Flush action log to disk every 5 seconds (300 frames) for crash safety
    if gs.frame % 300 == 0 && gs.frame > 0 {
        flush_action_log(gs)
    }
}
