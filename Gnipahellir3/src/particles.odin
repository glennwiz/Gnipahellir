package game

import rl "vendor:raylib"
import "core:math"

// ─── Particles ────────────────────────────────────────────────────────────────
//
//  Purely visual: fixed store, no events pushed, spawned from update code
//  (never from render).  A negative age is a start delay — the particle
//  waits invisibly, which is what turns a wand burst into a stream.
//  Deterministic jitter comes from whash, not the raylib RNG.

spawn_particle :: proc(ps: ^Particle_Store, pos, vel: [2]f32, color: rl.Color, lifetime: f32, delay: f32 = 0, homing := false, target: [2]f32 = {}) {
    for i in 0 ..< MAX_PARTICLES {
        p := &ps.data[i]
        if p.active { continue }
        p^ = {pos = pos, vel = vel, color = color, lifetime = lifetime, age = -delay, active = true, homing = homing, target = target}
        ps.count += 1
        return
    }
    // Store full: the spark is lost, nobody mourns it.
}

// Pull (tiles/s²) a collect mote feels toward its target, and its safety-cap
// lifetime — it normally dies early, on arrival at the bag.
COLLECT_PULL     :: f32(70)
COLLECT_LIFETIME :: f32(0.7)

// An item banked straight into the bag: a mote in the item's color pops up off
// the tile, then curves and accelerates into the player — reads as "flew into
// your inventory."  Vertical slice: it homes to the player body; retarget to
// the hotbar corner once collect motes get a screen-space pass.
spawn_collect_mote :: proc(gs: ^Game_State, from_tile: [2]i32, it: Item) {
    p := &gs.player
    start  := [2]f32{f32(from_tile.x) + 0.5, f32(from_tile.y) + 0.5}
    target := [2]f32{p.pos.x + PLAYER_W*0.5, p.pos.y + PLAYER_H*0.5}
    seed   := u32(gs.frame)*29 + 131
    vel    := [2]f32{jitter(seed, 1.0), -3 + jitter(seed + 1, 0.6)}  // little upward pop first
    spawn_particle(&gs.particles, start, vel, item_table[it].color, COLLECT_LIFETIME,
        homing = true, target = target)
}

// Clay-worker cargo: a compact, delayed stream makes the direction of every
// material transfer readable without UI text. Mining/fetching flies inward;
// building/storing uses the same effect in reverse.
spawn_transfer_motes :: proc(gs:^Game_State, from,to:[2]f32, color:rl.Color) {
	d:=to-from
	dist:=math.sqrt(d.x*d.x+d.y*d.y)
	if dist<0.05 do return
	dir:=d/dist
	side:=[2]f32{-dir.y,dir.x}
	TRANSFER_COUNT :: 5
	for i in 0..<TRANSFER_COUNT {
		seed:=u32(gs.frame)*43+u32(i)*719
		vel:=d*1.5+side*jitter(seed,1.4)+[2]f32{0,-0.8+jitter(seed+1,0.4)}
		c:=color
		if i==0 {c=rl.Color{255,245,190,255}} else {c.a=255}
		spawn_particle(&gs.particles,from,vel,c,0.72,f32(i)*0.035,homing=true,target=to)
	}
}

spawn_item_transfer_motes :: proc(gs:^Game_State, from,to:[2]f32, item:Item) {
	color:=rl.Color{210,180,140,255}
	if item!=.None do color=item_table[item].color
	spawn_transfer_motes(gs,from,to,color)
}

// Signed jitter in [-scale, +scale] from a deterministic hash.
@(private = "file")
jitter :: proc(seed: u32, scale: f32) -> f32 {
    return (f32(whash(seed) % 1024) / 512.0 - 1.0) * scale
}

// G2's wand stream: sparks fly from the player to the target tile, timed so
// the last ones arrive as the mining impact lands.
spawn_wand_stream :: proc(gs: ^Game_State, T: [2]i32) {
    from := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.35}
    to   := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}

    STREAM_COUNT :: 6
    for i in 0 ..< STREAM_COUNT {
        seed := u32(gs.frame)*31 + u32(i)*977
        t    := to + {jitter(seed, 0.3), jitter(seed + 1, 0.3)}
        d    := t - from
        vel  := d / WAND_TRAVEL_TIME
        delay := f32(i) * (WAND_TRAVEL_TIME / STREAM_COUNT) * 0.6
        spawn_particle(&gs.particles, from, vel,
            rl.Color{255, 230, 80, 255}, WAND_TRAVEL_TIME, delay)
    }
}

// What a struck body sprays: red blood for the living, pale grave-ichor for
// the risen, embers for sprites, hell-magic for Garm.
@(rodata)
enemy_blood := [Enemy_Kind]rl.Color{
    .Garm        = {200, 60, 210, 255},
    .Undead      = {140, 190, 150, 255},
    .Fire_Sprite = {255, 150, 40, 255},
    .Builder     = {200, 40, 35, 255},
    .Raider      = {185, 55, 28, 255},
}

// A landed blow sprays the victim's blood away from the hit — the fan gives
// the strike a direction, the upward bias and mixed shades give it weight.
// A hot white flash at the impact point sells the moment of contact.
spawn_hit_burst :: proc(gs: ^Game_State, center: [2]f32, dir: [2]f32, color: rl.Color) {
    dark := rl.Color{color.r / 2, color.g / 2, color.b / 2, color.a}
    for i in 0 ..< 18 {
        seed := u32(gs.frame)*41 + u32(i)*547
        vel  := dir * (3.5 + jitter(seed, 2.5)) +
                [2]f32{jitter(seed + 1, 3.0), -2.5 + jitter(seed + 3, 2.5)}
        pos  := center + {jitter(seed + 5, 0.3), jitter(seed + 7, 0.3)}
        spawn_particle(&gs.particles, pos, vel,
            color if i % 2 == 0 else dark, 0.35 + jitter(seed + 9, 0.18),
            f32(i % 3) * 0.02)   // three micro-waves so the spray lingers a beat
    }
    // Impact flash: a few fast hot sparks straight off the point of contact.
    for i in 0 ..< 4 {
        seed := u32(gs.frame)*53 + u32(i)*613
        vel  := dir * (7 + jitter(seed, 2)) + [2]f32{jitter(seed + 1, 1.5), jitter(seed + 3, 1.5)}
        spawn_particle(&gs.particles, center, vel,
            rl.Color{255, 245, 230, 255}, 0.15 + jitter(seed + 5, 0.05))
    }
}

// A flying fire orb sheds one ember behind it: a short-lived fleck knocked
// off the flight line, sinking as it dies — sparse by the caller's period so
// the trail never reads as a solid laser.
spawn_orb_ember :: proc(gs: ^Game_State, pos: [2]f32) {
    seed  := u32(gs.frame)*59 + 197
    color := rl.Color{255, 150, 40, 230} if whash(seed) % 3 != 0 else rl.Color{150, 30, 20, 230}
    spawn_particle(&gs.particles, pos + {jitter(seed + 1, 0.15), jitter(seed + 3, 0.15)},
        {jitter(seed + 5, 0.6), 0.6 + jitter(seed + 7, 0.5)},
        color, 0.3 + jitter(seed + 9, 0.1))
}

// The orb bursting on whatever it struck: a white-hot contact flash first,
// embers fanning out a beat later, and one slow smoke mote curling up last —
// sequenced by spawn delays, not code.
spawn_orb_impact :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}
    for i in 0 ..< 4 {
        seed := u32(gs.frame)*61 + u32(i)*431
        vel  := [2]f32{jitter(seed, 5), jitter(seed + 1, 5)}
        spawn_particle(&gs.particles, center, vel, rl.Color{255, 245, 230, 255}, 0.12)
    }
    for i in 0 ..< 7 {
        seed  := u32(gs.frame)*67 + u32(i)*509
        vel   := [2]f32{jitter(seed, 3.5), -2 + jitter(seed + 1, 2)}
        color := rl.Color{255, 150, 40, 255} if i % 2 == 0 else rl.Color{200, 60, 25, 255}
        spawn_particle(&gs.particles, center, vel, color, 0.35 + jitter(seed + 3, 0.12), 0.03)
    }
    spawn_particle(&gs.particles, center, {0, -1.2}, rl.Color{90, 80, 75, 180}, 0.5, 0.08)
}

// Pick chips: a fan of sparks off the struck tile, with a few dark rock
// chips tumbling among the bright ones.
spawn_chip_sparks :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}
    for i in 0 ..< 9 {
        seed := u32(gs.frame)*17 + u32(i)*563
        vel  := [2]f32{jitter(seed, 5), -2.5 + jitter(seed + 1, 2.5)}
        color := rl.Color{255, 240, 180, 255} if i % 3 != 2 else rl.Color{120, 105, 90, 255}
        spawn_particle(&gs.particles, center, vel,
            color, 0.25 + jitter(seed + 3, 0.08))
    }
}

// Ultra-wand impact: a ring of hot sparks thrown out from the blast center.
spawn_blast_sparks :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}
    RING :: 16
    for i in 0 ..< RING {
        seed  := u32(gs.frame)*13 + u32(i)*401
        angle := f32(i) * (2 * 3.14159 / RING)
        speed := 6 + jitter(seed, 2)
        vel   := [2]f32{math.cos(angle) * speed, math.sin(angle) * speed}
        color := rl.Color{255, 160, 40, 255} if i % 2 == 0 else rl.Color{255, 230, 80, 255}
        spawn_particle(&gs.particles, center, vel, color, 0.35 + jitter(seed + 1, 0.1))
    }
}

// Craft success: a slow ring of sparks blooms off the crafter — gold and
// rune-light woven with the crafted item's own color, drifting upward.
spawn_craft_burst :: proc(gs: ^Game_State, it: Item) {
    p := &gs.player
    center := [2]f32{p.pos.x + PLAYER_W/2, p.pos.y + PLAYER_H/2}
    RING :: 18
    for i in 0 ..< RING {
        seed  := u32(gs.frame)*17 + u32(i)*611
        angle := f32(i) * (2 * math.PI / RING)
        speed := 3 + jitter(seed, 1.5)
        vel   := [2]f32{math.cos(angle) * speed, math.sin(angle) * speed - 2}
        color := item_table[it].color
        switch i % 3 {
        case 1: color = rl.Color{255, 220, 80, 255}   // gold
        case 2: color = rl.Color{225, 185, 255, 255}  // rune-light
        }
        spawn_particle(&gs.particles, center, vel, color,
            0.6 + jitter(seed + 1, 0.2), f32(i % 5) * 0.03)
    }
}

// Smelter output: a spray of embers and a curl of smoke off the furnace mouth.
spawn_smelt_burst :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.3}
    for i in 0 ..< 8 {
        seed := u32(gs.frame)*23 + u32(i)*733
        vel  := [2]f32{jitter(seed, 2.5), -2.5 + jitter(seed + 1, 1)}
        color := rl.Color{255, 160, 40, 255} if i % 2 == 0 else rl.Color{120, 110, 100, 200}
        spawn_particle(&gs.particles, center, vel, color, 0.5 + jitter(seed + 3, 0.15))
    }
}

// A grown tree shakes loose a drift of leaves around the new crown.
spawn_grow_burst :: proc(gs: ^Game_State, T: [2]i32) {
    for i in 0 ..< 10 {
        seed := u32(gs.frame)*19 + u32(i)*457
        pos  := [2]f32{f32(T.x) + 0.5 + jitter(seed, 1.5), f32(T.y) - 3 + jitter(seed + 1, 1.5)}
        vel  := [2]f32{jitter(seed + 3, 0.8), 0.6 + jitter(seed + 5, 0.4)}
        color := rl.Color{112, 208, 88, 220} if i % 2 == 0 else rl.Color{58, 158, 48, 220}
        spawn_particle(&gs.particles, pos, vel, color, 0.9 + jitter(seed + 7, 0.3))
    }
}

// A cave mushroom reaching full size: a ring of neon spores shed around the
// cap, drifting up and outward, staggered in three waves so the glow lingers
// a beat instead of popping all at once.
spawn_mushroom_glow :: proc(gs: ^Game_State, T: [2]i32) {
    for i in 0 ..< 12 {
        seed := u32(gs.frame)*23 + u32(i)*389
        pos  := [2]f32{f32(T.x) + 0.5 + jitter(seed, 0.8), f32(T.y) + 0.5 + jitter(seed + 1, 0.8)}
        vel  := [2]f32{jitter(seed + 3, 0.7), -0.5 + jitter(seed + 5, 0.5)}
        color := rl.Color{57, 235, 40, 230} if i % 2 == 0 else rl.Color{160, 255, 120, 230}
        spawn_particle(&gs.particles, pos, vel, color, 0.8 + jitter(seed + 7, 0.4),
            delay = f32(i % 3) * 0.15)
    }
}

// Sky-Altar ritual: each frame of the offering, a few rainbow motes spiral in
// from a ring toward the point above the altar — reads as the gift being drawn
// together.  Hue rides the ritual clock so the whole swirl cycles the spectrum.
RITUAL_SWIRL_R :: f32(3.5)  // tiles — the ring the motes spiral in from
spawn_ritual_swirl :: proc(gs: ^Game_State, altar: [2]i32, t: f32) {
    center := [2]f32{f32(altar.x) + 0.5, f32(altar.y) - 1.5}  // float above the capstone
    for i in 0 ..< 3 {
        seed := u32(gs.frame)*47 + u32(i)*733
        ang  := f32(whash(seed) % 628) / 100.0                // 0..2π
        r    := RITUAL_SWIRL_R * (0.7 + jitter(seed + 1, 0.3))
        pos  := center + {math.cos(ang) * r, math.sin(ang) * r}
        inward := center - pos
        tang   := [2]f32{-inward.y, inward.x} * 0.6           // swirl as it falls in
        vel    := inward * 1.6 + tang
        hue    := f32(math.mod(f64(t*140 + f32(i)*47 + ang*57.3), 360))
        spawn_particle(&gs.particles, pos, vel, rl.ColorFromHSV(hue, 0.8, 1.0),
            0.5 + jitter(seed + 3, 0.15))
    }
}

// The finishing flash: a bright radial burst of white and gold thrown out from
// the altar as the structure is raised.
spawn_ritual_flash :: proc(gs: ^Game_State, altar: [2]i32) {
    center := [2]f32{f32(altar.x) + 0.5, f32(altar.y) - 1.5}
    RING :: 28
    for i in 0 ..< RING {
        ang   := f32(i) * (2 * math.PI / RING)
        seed  := u32(gs.frame)*13 + u32(i)*401
        speed := 8 + jitter(seed, 3)
        vel   := [2]f32{math.cos(ang) * speed, math.sin(ang) * speed}
        col   := rl.Color{255, 255, 255, 255} if i % 2 == 0 else rl.Color{255, 230, 140, 255}
        spawn_particle(&gs.particles, center, vel, col, 0.4 + jitter(seed + 1, 0.12))
    }
}

// The swirl's rebirth: a beat after the finishing flash fades, a blue burst
// in the altar's own glow color — the eternal minor swirl igniting.  Every
// particle spawns delayed so the white/gold climax gets the stage first.
RITUAL_REBIRTH_DELAY :: f32(0.45)
spawn_ritual_rebirth :: proc(gs: ^Game_State, altar: [2]i32) {
    center := [2]f32{f32(altar.x) + 0.5, f32(altar.y) - 1.5}
    RING :: 20
    for i in 0 ..< RING {
        ang   := f32(i) * (2 * math.PI / RING)
        seed  := u32(gs.frame)*17 + u32(i)*577
        speed := 5 + jitter(seed, 2)
        vel   := [2]f32{math.cos(ang) * speed, math.sin(ang) * speed}
        col   := rl.Color{130, 200, 255, 255} if i % 2 == 0 else rl.Color{210, 240, 255, 255}
        spawn_particle(&gs.particles, center, vel, col,
            0.4 + jitter(seed + 1, 0.12), RITUAL_REBIRTH_DELAY)
    }
}

// A worker's temporary Quick Clay foothold dissolving after use: a few damp
// motes sag downward and fade, reading as melting away rather than breaking.
spawn_clay_drip :: proc(gs: ^Game_State, T: [2]i32) {
    center := [2]f32{f32(T.x) + 0.5, f32(T.y) + 0.5}
    for i in 0 ..< 6 {
        seed := u32(gs.frame)*37 + u32(i)*821
        vel  := [2]f32{jitter(seed, 0.6), 1.2 + jitter(seed + 1, 0.6)}
        spawn_particle(&gs.particles, center, vel,
            rl.Color{190, 150, 115, 220}, 0.5 + jitter(seed + 3, 0.15), f32(i) * 0.04)
    }
}

// ─── Ambience ─────────────────────────────────────────────────────────────────
//
//  Stray motes of magic drifting up through each level's air, and station
//  tiles shedding the occasional rising spark in their glow color.  Random
//  tile sampling keeps it cheap: a few probes per tick over the whole grid.

AMBIENCE_INTERVAL :: 0.12
AMBIENCE_PROBES   :: 4
AMBIENCE_CHANCE   :: 30 // % of air probes that become a mote

// Mote colors per level: surface gold, cave2 cold blue, cave3 hell embers,
// sky aurora, dimension pale shimmer.
@(rodata)
level_mote_colors := [NUM_LEVELS][2]rl.Color{
    LEVEL_SURFACE   = {{255, 226, 130, 200}, {200, 240, 160, 170}},
    LEVEL_CAVE2     = {{140, 170, 230, 170}, {120, 220, 210, 150}},
    LEVEL_CAVE3     = {{255, 140, 60, 200}, {230, 70, 40, 180}},
    LEVEL_SKY       = {{170, 240, 255, 200}, {230, 190, 255, 190}},
    LEVEL_DIMENSION = {{200, 200, 225, 180}, {255, 215, 140, 160}},
}

update_ambience :: proc(gs: ^Game_State) {
    gs.ambience_timer -= gs.delta_time
    if gs.ambience_timer > 0 do return
    gs.ambience_timer = AMBIENCE_INTERVAL

    for i in 0 ..< AMBIENCE_PROBES {
        seed := u32(gs.frame)*31 + u32(i)*977
        x := int(whash(seed) % GRID_W)
        y := int(whash(seed ~ 0x9E3779B9) % GRID_H)
        t := get_tile(&gs.world, x, y)
        pos := [2]f32{f32(x) + 0.5 + jitter(seed + 3, 0.4), f32(y) + 0.5}

        if glow := station_glow[t]; glow.a != 0 {
            // A station breathes out a spark that rises and dies quickly.
            spawn_particle(&gs.particles, {pos.x, f32(y) + 0.2},
                {jitter(seed + 5, 0.5), -1.6 + jitter(seed + 7, 0.4)},
                glow, 0.9)
        } else if t == .Air && whash(seed + 11) % 100 < AMBIENCE_CHANCE {
            color := level_mote_colors[gs.level_index][int(whash(seed + 13) % 2)]
            spawn_particle(&gs.particles, pos,
                {jitter(seed + 17, 0.3), -0.35 + jitter(seed + 19, 0.15)},
                color, 3 + jitter(seed + 23, 1.5))
        }
    }
}

// Step 8 in game_update — visual only, pushes no events.
update_particles :: proc(gs: ^Game_State) {
    dt := gs.delta_time
    for i in 0 ..< MAX_PARTICLES {
        p := &gs.particles.data[i]
        if !p.active { continue }
        p.age += dt
        if p.age >= p.lifetime {
            p.active = false
            gs.particles.count = max(0, gs.particles.count - 1)
            continue
        }
        if p.age >= 0 {
            if p.homing {
                to   := p.target - p.pos
                dist := math.sqrt(to.x*to.x + to.y*to.y)
                if dist < 0.4 {   // reached the bag — pop out of existence
                    p.active = false
                    gs.particles.count = max(0, gs.particles.count - 1)
                    continue
                }
                p.vel += (to / dist) * COLLECT_PULL * dt   // accelerate inward
            }
            p.pos += p.vel * dt
        }
    }
}

// Read-only, called from render.
draw_particles :: proc(ps: ^Particle_Store) {
    for i in 0 ..< MAX_PARTICLES {
        p := &ps.data[i]
        if !p.active || p.age < 0 { continue }
        fade := 1.0 - p.age / max(p.lifetime, 0.001)
        c := p.color
        c.a = u8(f32(c.a) * clamp(fade, 0, 1))
        rl.DrawRectangle(
            i32(p.pos.x * CELL_SIZE) - 1,
            i32(p.pos.y * CELL_SIZE) - 1,
            3, 3, c)
    }
}
