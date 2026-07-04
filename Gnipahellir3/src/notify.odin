package game

import "core:fmt"

// ─── Notifications ────────────────────────────────────────────────────────────
//
//  Timed popup messages, top-center of the screen (drawn in ui.odin).
//  Pushed directly by event handlers — this system consumes no events and
//  pushes none, so its update position in game_update is unconstrained.

NOTIFY_DURATION :: f32(4.0)   // seconds on screen
NOTIFY_FADE     :: f32(0.75)  // fade-out tail within the duration

notify :: proc(gs: ^Game_State, format: string, args: ..any) {
    ns := &gs.notify

    // Full: drop the oldest to make room.
    if ns.count >= MAX_NOTIFICATIONS {
        for i in 1 ..< ns.count do ns.items[i-1] = ns.items[i]
        ns.count -= 1
    }

    n := &ns.items[ns.count]
    n^ = {}
    s := fmt.bprintf(n.text[:NOTIFY_TEXT_LEN-1], format, ..args)  // keep a NUL for cstring
    n.len = len(s)
    ns.count += 1
}

update_notifications :: proc(gs: ^Game_State) {
    ns := &gs.notify
    for i in 0 ..< ns.count do ns.items[i].age += gs.delta_time

    // Compact expired entries (oldest are always at the front).
    keep := 0
    for i in 0 ..< ns.count {
        if ns.items[i].age < NOTIFY_DURATION {
            if keep != i do ns.items[keep] = ns.items[i]
            keep += 1
        }
    }
    ns.count = keep
}
