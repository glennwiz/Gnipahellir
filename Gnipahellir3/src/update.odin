package game

game_update :: proc(gs: ^Game_State) {
    gs.delta_time = clamp(gs.delta_time, 0, 0.05)  // cap at 50ms
    gs.frame     += 1

    // 1. Input — always polled so ESC and menu clicks work while paused
    update_input(gs)

    // Pause menu: freezes the sim entirely. Only the menu's own requests
    // (New Game / Save and Quit), queued as events by input, still run.
    if gs.ui.show_menu {
        process_events(gs)
        eq_clear(&gs.events)
        return
    }

    gs.elapsed_time += gs.delta_time

    // 2. Player
    update_player(gs)

    // 3. Enemies
    update_enemies(gs)

    // 4. Projectiles
    update_projectiles(gs)

    // 5. Wand mining (delayed impact) — pushes Tile_Mined, must precede events
    update_mining(gs)

    // 5b. Sim  (stub)
    // update_sim(gs)

    // 6. Events — drains the queue completely, including events pushed by
    //    handlers mid-drain.  Systems ordered AFTER this step must not push
    //    events: they would be destroyed unprocessed by the clear below.
    process_events(gs)
    eq_clear(&gs.events)

    // 7. Notifications — ages/expires the popup stack (pushes no events)
    update_notifications(gs)

    // 8. Particles (visual only, pushes no events)
    update_particles(gs)

    // 9. Audio (reads state only, never pushes events)
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
