package game

import "core:math"
import rl "vendor:raylib"

// ─── Audio ────────────────────────────────────────────────────────────────────
//
//  Fixed table of sounds keyed by Sound_ID, triggered from the event handlers
//  in events.odin.  Builder work sounds attenuate with distance to the player,
//  so distant digging is heard before the builder is seen.  Cave ambience is a
//  looping music stream whose volume follows the player's depth.

Sound_ID :: enum u8 {
	None,
	Jump,
	Mine,
	Place,
	Pickup,
	Hurt,
	Death,
	Kill,
	Builder_Dig,
	Builder_Place,
	Builder_Shriek,
	Sword_Hit,
	Fanfare,
	Fireball,
	Garm_Roar,
	Wand_Fire,
	Blast,
}

@(rodata)
sound_file := [Sound_ID]cstring {
	.None           = "",
	.Jump           = "sounds/splash_bang_pop/sound_woosh.wav",
	.Mine           = "sounds/splash_bang_pop/sfx_ar_primary_attack.wav",
	.Place          = "sounds/splash_bang_pop/sound_hit_shield.wav",
	.Pickup         = "sounds/splash_bang_pop/sound_loot_pickup.wav",
	.Hurt           = "sounds/splash_bang_pop/sound_hit_ally.wav",
	.Death          = "sounds/splash_bang_pop/sound_enemy_defeat.wav",
	.Kill           = "sounds/splash_bang_pop/sound_enemy_defeat_small.wav",
	.Builder_Dig    = "sounds/splash_bang_pop/sfx_ar_primary_attack.wav",
	.Builder_Place  = "sounds/splash_bang_pop/sound_hit_shield.wav",
	.Builder_Shriek = "sounds/splash_bang_pop/sound_enrage_start.wav",
	.Sword_Hit      = "sounds/splash_bang_pop/sound_melee_hit.wav",
	.Fanfare        = "sounds/splash_bang_pop/sound_level_up.wav",
	.Fireball       = "sounds/splash_bang_pop/sfx_br_flamehook_attack.wav",
	.Garm_Roar      = "sounds/splash_bang_pop/sound_enrage_blast.wav",
	.Wand_Fire      = "sounds/splash_bang_pop/sfx_sr_magickedfleche_attack.wav",
	.Blast          = "sounds/splash_bang_pop/sfx_sr_novidark_attack.wav",
}

@(rodata)
sound_base_volume := [Sound_ID]f32 {
	.None           = 0,
	.Jump           = 0.4,
	.Mine           = 0.7,
	.Place          = 0.7,
	.Pickup         = 0.7,
	.Hurt           = 0.8,
	.Death          = 0.9,
	.Kill           = 0.8,
	.Builder_Dig    = 0.5,
	.Builder_Place  = 0.5,
	.Builder_Shriek = 0.9, // the raid alarm — must cut through everything
	.Sword_Hit      = 0.8,
	.Fanfare        = 0.8,
	.Fireball       = 0.7,
	.Garm_Roar      = 1.0, // a boss phase announcing itself — must dominate
	.Wand_Fire      = 0.6,
	.Blast          = 0.9,
}

// World sounds (builders digging and placing, raiders, growth, fireballs)
// fade linearly with distance and are SILENT past hear range.  There used to
// be a faint far floor as a "something is digging toward you" warning; with
// hundreds of enemies tunnelling at once it became a map-wide clatter
// (Glenn, 2026-09-02), so nothing carries past this radius now.
BUILDER_HEAR_RANGE :: 48.0 // tiles

// ─── Procedural cave ambience (tuning knobs) ────────────────────────────────────
//  A deep rumble (double-lowpassed brown noise) + a faint wind hiss, both
//  swelling slowly, with occasional water drips.  Volume follows depth, so the
//  surface stays silent.  These are the ear-tuned constants — bump them if the
//  cave is too quiet/loud; none of it loops.
AMBIENCE_BUF :: 2048     // frames per stream refill (~46 ms @ 44.1 kHz)
AMB_SR       :: 44100.0
DRONE_LP_K   :: 0.020    // rumble lowpass coefficient (smaller = deeper/darker)
AIR_LP_K     :: 0.120    // wind-hiss lowpass coefficient
RUMBLE_GAIN  :: 3.0
WIND_GAIN    :: 0.15
DRIP_GAIN    :: 0.6
DRIP_MIN     :: 2.2      // seconds between drips, deep in the cave
DRIP_MAX     :: 7.0      // seconds between drips, just under the surface
TAU          :: 6.2831853

audio_init :: proc(a: ^Audio_State) {
	rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() do return
	a.initialized = true
	a.master_volume = 1.0
	a.sfx_volume = 0.8
	a.music_volume = 0.6

	for id in Sound_ID {
		if id == .None do continue
		s := rl.LoadSound(sound_file[id])
		if s.frameCount == 0 do continue // missing file: stay silent, don't crash
		a.sounds[id] = s
		a.loaded[id] = true
	}

	// Synthesized cave ambience: a self-filled mono 16-bit stream.
	a.amb_rng = 0x9E3779B97F4A7C15 // any nonzero xorshift seed
	a.drip_timer = 2.0
	rl.SetAudioStreamBufferSizeDefault(AMBIENCE_BUF)
	a.ambience = rl.LoadAudioStream(u32(AMB_SR), 16, 1)
	rl.PlayAudioStream(a.ambience)
	a.ambience_loaded = true
}

audio_shutdown :: proc(a: ^Audio_State) {
	if !a.initialized do return
	for id in Sound_ID {
		if a.loaded[id] do rl.UnloadSound(a.sounds[id])
	}
	if a.ambience_loaded do rl.UnloadAudioStream(a.ambience)
	rl.CloseAudioDevice()
	a.initialized = false
}

audio_play :: proc(a: ^Audio_State, id: Sound_ID, gain: f32 = 1.0) {
	if !a.initialized || !a.loaded[id] do return
	v := sound_base_volume[id] * gain * a.sfx_volume * a.master_volume
	rl.SetSoundVolume(a.sounds[id], v)
	rl.PlaySound(a.sounds[id])
}

// Gain for a sound emitted at a tile, attenuated by distance to the player.
audio_tile_gain :: proc(gs: ^Game_State, tile: [2]i32) -> f32 {
	dx := f32(tile.x) + 0.5 - (gs.player.pos.x + PLAYER_W * 0.5)
	dy := f32(tile.y) + 0.5 - (gs.player.pos.y + PLAYER_H * 0.5)
	dist := math.sqrt(dx * dx + dy * dy)
	return clamp(1 - dist / BUILDER_HEAR_RANGE, 0, 1)
}

// Machine sounds are strictly local: same shape as above but a much shorter
// radius, because a boiler puffing every two seconds is not worth hearing
// from across the base.
MACHINE_HEAR_RANGE :: 16.0 // tiles

audio_machine_gain :: proc(gs: ^Game_State, tile: [2]i32) -> f32 {
	dx := f32(tile.x) + 0.5 - (gs.player.pos.x + PLAYER_W * 0.5)
	dy := f32(tile.y) + 0.5 - (gs.player.pos.y + PLAYER_H * 0.5)
	dist := math.sqrt(dx * dx + dy * dy)
	return clamp(1 - dist / MACHINE_HEAR_RANGE, 0, 1)
}

// Step 8 in game_update: refills the synthesized ambience stream; its gain and
// character follow the player's depth (surface is silent).
update_audio :: proc(gs: ^Game_State) {
	a := &gs.audio
	if !a.initialized || !a.ambience_loaded do return

	// Depth 0 at the surface → 1 down in the cave; smoothed so it fades in.
	depth := clamp((gs.player.pos.y - SURFACE_Y) / 12.0, 0, 1)
	a.amb_depth += (depth - a.amb_depth) * min(gs.delta_time * 2, 1)
	a.ambience_gain = a.amb_depth * a.music_volume * a.master_volume

	// Feed every buffer the mixer has drained this frame.
	for rl.IsAudioStreamProcessed(a.ambience) {
		fill_ambience(a)
		rl.UpdateAudioStream(a.ambience, &a.amb_buf[0], AMBIENCE_BUF)
	}
}

// xorshift64 — cheap deterministic noise/scheduling source for the ambience.
@(private = "file")
amb_rand_f :: proc(a: ^Audio_State) -> f32 {
	x := a.amb_rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	a.amb_rng = x
	return f32(x >> 40) / f32(1 << 24) // 0..1
}

// Synthesizes one buffer of cave ambience into a.amb_buf.  Deep rumble +
// wind + occasional drips, all scaled by a.ambience_gain (depth × volumes).
@(private = "file")
fill_ambience :: proc(a: ^Audio_State) {
	dt :: 1.0 / AMB_SR
	g := a.ambience_gain
	// Deeper = a touch louder rumble and more frequent, brighter drips.
	rumble_amp := f32(RUMBLE_GAIN) * (0.8 + 0.4 * a.amb_depth)

	for i in 0 ..< AMBIENCE_BUF {
		white := amb_rand_f(a) * 2 - 1

		// Deep rumble: brown noise (leaky integrator) through a two-pole lowpass.
		a.amb_brown = (a.amb_brown + white * 0.015) * 0.995
		a.amb_brown = clamp(a.amb_brown, -1, 1)
		a.amb_lp1 += (a.amb_brown - a.amb_lp1) * DRONE_LP_K
		a.amb_lp2 += (a.amb_lp1 - a.amb_lp2) * DRONE_LP_K
		rumble := a.amb_lp2 * rumble_amp

		// Faint wind hiss: gently lowpassed white noise.
		a.amb_air += (white - a.amb_air) * AIR_LP_K
		wind := a.amb_air * WIND_GAIN

		// Slow swell — the cave "breathing".
		a.amb_lfo += TAU * 0.06 * dt
		if a.amb_lfo > TAU do a.amb_lfo -= TAU
		swell := 0.7 + 0.3 * math.sin(a.amb_lfo)

		// Occasional water drips: a decaying sine that glides up slightly.
		a.drip_timer -= dt
		if a.drip_timer <= 0 {
			span := f32(DRIP_MAX) - a.amb_depth * (DRIP_MAX - DRIP_MIN)
			a.drip_timer = DRIP_MIN + amb_rand_f(a) * max(span - DRIP_MIN, 0.1)
			a.drip_env = 1
			a.drip_phase = 0
			a.drip_freq = 500 + amb_rand_f(a) * 900 // 500..1400 Hz plink
		}
		drip: f32 = 0
		if a.drip_env > 0.0005 {
			a.drip_phase += TAU * a.drip_freq * dt
			drip = math.sin(a.drip_phase) * a.drip_env * DRIP_GAIN
			a.drip_env *= 0.9994  // ~0.3 s tail
			a.drip_freq *= 1.00002 // slight upward glide
		}

		s := (rumble + wind) * swell + drip
		s = clamp(s * g, -1, 1)
		a.amb_buf[i] = i16(s * 32767)
	}
}
