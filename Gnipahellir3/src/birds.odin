package game

import "core:math"

// ─── Bird flocks ──────────────────────────────────────────────────────────────
//
//  Scenery for the sky level.  Each flock cruises an open lane between the
//  cloud bands; a player who comes close scatters it, and it re-forms further
//  on.  Birds live in their own store, not the enemy pool, so they cannot hurt
//  anyone, drop anything or count toward a wave.  Transient: never saved, and
//  dropped on leaving the sky.

// All first guesses, for Glenn to tune.  Distances in tiles, speeds in tiles/s.
BIRD_CRUISE_SPEED    :: f32(3.0)
BIRD_FLEE_SPEED      :: f32(7.0)   // the formation's own speed while scattered
BIRD_SCATTER_RADIUS  :: f32(8.0)   // player this close to any bird scatters the flock
BIRD_SCATTER_SPEED   :: f32(11.0)  // the slowest bird's burst
BIRD_SCATTER_SPEED_STEP :: f32(2.0) // so the birds do not leave as a ring
BIRD_SCATTER_FAN     :: f32(1.0)   // radians either side of straight away
BIRD_SCATTER_TIME    :: f32(2.5)   // seconds before the flock re-forms
BIRD_SCATTER_DRAG    :: f32(1.2)   // per second, so the burst tires
BIRD_REGROUP_RATE    :: f32(2.5)   // share of the gap to its slot closed per second
BIRD_WRAP_MARGIN     :: f32(10.0)  // tiles past the level edge before a flock wraps round
BIRD_BOB_HEIGHT      :: f32(0.4)
BIRD_BOB_SPEED       :: f32(1.4)   // rad/s
BIRD_SLOT_BACK       :: f32(1.6)   // V formation: tiles behind per rank
BIRD_SLOT_SIDE       :: f32(0.8)   // V formation: tiles aside per rank; 3 ranks plus the bob stay in the lane
BIRD_FLAP_SPEED      :: f32(7.0)   // rad/s
BIRD_FLAP_SPEED_SPOOKED :: f32(20.0)
BIRD_WING_SPAN       :: f32(0.45)  // tiles, body to wing tip
BIRD_WING_LIFT       :: f32(0.3)   // tiles, wing tip height at the top of a flap

// Open rows between gen_sky_level's cloud bands, whose puffs reach 3 rows down.
// The rainbow and the sky islands stand in them: flocks are scenery and fly in
// front of the arc, its foot islands and the islands under it.
@(rodata)
bird_lanes := [MAX_BIRD_FLOCKS + 1]f32{20, 34, 46, 58, 70}

// A flock's V slot for bird i: the leader at the centre, then a rank each side.
bird_slot :: proc(f: ^Bird_Flock, i: int, t: f32) -> [2]f32 {
    rank := f32((i + 1) / 2)
    side := f32(1) if i % 2 == 0 else f32(-1)
    bob := math.sin(t * BIRD_BOB_SPEED + f.phase + f32(i)) * BIRD_BOB_HEIGHT
    return {
        f.center.x - f.heading * rank * BIRD_SLOT_BACK,
        f.center.y + side * rank * BIRD_SLOT_SIDE + bob,
    }
}

// Lays the flocks out for this world: one lane each, spread along it.
birds_seed :: proc(gs: ^Game_State) {
    gs.birds.seeded = true
    first := int(whash(gs.world_seed + 4441) % len(bird_lanes))
    for i in 0 ..< MAX_BIRD_FLOCKS {
        f := &gs.birds.flocks[i]
        h := whash(gs.world_seed + 4447 + u32(i) * 7919)
        f.center = {f32(h % GRID_W), bird_lanes[(first + i) % len(bird_lanes)]}
        f.heading = f32(1) if h % 2 == 0 else f32(-1) // whash mixes its high bits poorly
        f.phase = f32(h % 64) * 0.1
        f.scatter_t = 0
        for j in 0 ..< BIRDS_PER_FLOCK {
            f.birds[j] = {pos = bird_slot(f, j, gs.elapsed_time)}
        }
    }
}

// A hashed value in -scale..scale.
bird_jitter :: proc(seed: u32, scale: f32) -> f32 {
    return (f32(whash(seed) % 1024) / 512 - 1) * scale
}

// Every bird bursts away from `from`, each on its own line, and the flock
// turns to re-form on the far side.
bird_flock_scatter :: proc(gs: ^Game_State, f: ^Bird_Flock, from: [2]f32) {
    f.scatter_t = BIRD_SCATTER_TIME
    f.heading = f32(1) if f.center.x >= from.x else f32(-1)
    for j in 0 ..< BIRDS_PER_FLOCK {
        b := &f.birds[j]
        seed := u32(gs.frame) * 131 + u32(j) * 977
        ang := math.atan2(b.pos.y - from.y, b.pos.x - from.x) + bird_jitter(seed, BIRD_SCATTER_FAN)
        speed := BIRD_SCATTER_SPEED + f32(j % 3) * BIRD_SCATTER_SPEED_STEP
        b.vel = {math.cos(ang) * speed, math.sin(ang) * speed}
    }
}

// Step 8b in game_update — visual only, pushes no events.
update_birds :: proc(gs: ^Game_State) {
    if gs.level_index != LEVEL_SKY {
        gs.birds = {}
        return
    }
    if !gs.birds.seeded do birds_seed(gs)

    dt := gs.delta_time
    player := gs.player.pos + {PLAYER_W, PLAYER_H} * 0.5
    span := f32(GRID_W) + 2 * BIRD_WRAP_MARGIN

    for i in 0 ..< MAX_BIRD_FLOCKS {
        f := &gs.birds.flocks[i]

        if f.scatter_t <= 0 {
            near := false
            for b in f.birds {
                d := b.pos - player
                near ||= d.x * d.x + d.y * d.y < BIRD_SCATTER_RADIUS * BIRD_SCATTER_RADIUS
            }
            if near do bird_flock_scatter(gs, f, player)
        }

        spooked := f.scatter_t > 0
        speed := BIRD_FLEE_SPEED if spooked else BIRD_CRUISE_SPEED
        f.center.x += f.heading * speed * dt
        f.scatter_t = max(0, f.scatter_t - dt)

        // Off one edge, on at the other: the birds move with it, unseen.
        shift := f32(0)
        if f.center.x > f32(GRID_W) + BIRD_WRAP_MARGIN do shift = -span
        if f.center.x < -BIRD_WRAP_MARGIN do shift = span
        f.center.x += shift

        for j in 0 ..< BIRDS_PER_FLOCK {
            b := &f.birds[j]
            b.pos.x += shift
            if spooked {
                b.vel *= max(0, 1 - BIRD_SCATTER_DRAG * dt)
            } else {
                b.vel = (bird_slot(f, j, gs.elapsed_time) - b.pos) * BIRD_REGROUP_RATE
            }
            b.pos += b.vel * dt
        }
    }
}

// How high bird j's wing tips stand this instant, in tiles: scattered birds
// beat harder.  Shared by the draw proc and the tests.
bird_wing_lift :: proc(f: ^Bird_Flock, j: int, t: f32) -> f32 {
    rate := BIRD_FLAP_SPEED_SPOOKED if f.scatter_t > 0 else BIRD_FLAP_SPEED
    return math.sin(t * rate + f.phase + f32(j) * 1.3) * BIRD_WING_LIFT
}
