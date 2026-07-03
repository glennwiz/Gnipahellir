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

    // 6. Events — drains the queue completely, including events pushed by
    //    handlers mid-drain.  Systems ordered AFTER this step must not push
    //    events: they would be destroyed unprocessed by the clear below.
    process_events(gs)
    eq_clear(&gs.events)

    // 7. Particles  (stub — pushes events? move it above process_events)
    // update_particles(gs)

    // 8. Audio (reads state only, never pushes events)
    update_audio(gs)

    when GAME_DEBUG {
        // Surface silently dropped events — a saturated queue is a bug.
        if gs.events.dropped > 0 {
            log_action(gs, "WARNING: %d events dropped this frame (queue full)", gs.events.dropped)
            gs.events.dropped = 0
        }

        // Flush action log to disk every 5 seconds (300 frames) for crash safety
        if gs.frame % 300 == 0 && gs.frame > 0 {
            flush_action_log(gs)
        }
    }
}
