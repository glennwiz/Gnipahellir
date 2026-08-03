package game

// Spall profiler wiring — compiled in ONLY when built with `-define:SPALL=true`.
// Normal `odin run src` builds strip all of this: no globals, no trace file,
// zero overhead.  When enabled the game writes `gnipa.spall`, which you open in
// the Spall viewer (desktop app or gravitymoth.com/spall) to read the flamegraph.
//
//   Profile:  odin run src -define:SPALL=true
//   (play a bit, then quit cleanly so the buffer flushes)
//
// The profiling state lives here as file-scope globals rather than in
// Game_State on purpose: it is debug tooling, absent from every shipping build,
// and must not touch the fat-struct architecture.

@(require) import "core:prof/spall"
@(require) import "core:sync"

SPALL :: #config(SPALL, false)

when SPALL {
    spall_ctx:     spall.Context
    spall_buffer:  spall.Buffer
    spall_backing: []u8
}

profile_init :: proc() {
    when SPALL {
        spall_ctx     = spall.context_create("gnipa.spall")
        spall_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE)
        spall_buffer  = spall.buffer_create(spall_backing, u32(sync.current_thread_id()))
    }
}

profile_shutdown :: proc() {
    when SPALL {
        spall.buffer_destroy(&spall_ctx, &spall_buffer)
        spall.context_destroy(&spall_ctx)
        delete(spall_backing)
    }
}

// Scoped timing: `profile_scope("name")` at the top of a proc/block times it
// until the enclosing scope exits (the end event fires via @(deferred_none)).
@(deferred_none = _profile_scope_end)
profile_scope :: proc(name: string, loc := #caller_location) {
    when SPALL {
        spall._buffer_begin(&spall_ctx, &spall_buffer, name, "", loc)
    }
}

_profile_scope_end :: proc() {
    when SPALL {
        spall._buffer_end(&spall_ctx, &spall_buffer)
    }
}
