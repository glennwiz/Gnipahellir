package game

import rl "vendor:raylib/v55"
import "core:math"

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
sound_file := [Sound_ID]cstring{
    .None          = "",
    .Jump          = "sounds/splash_bang_pop/sound_woosh.wav",
    .Mine          = "sounds/splash_bang_pop/sfx_ar_primary_attack.wav",
    .Place         = "sounds/splash_bang_pop/sound_hit_shield.wav",
    .Pickup        = "sounds/splash_bang_pop/sound_loot_pickup.wav",
    .Hurt          = "sounds/splash_bang_pop/sound_hit_ally.wav",
    .Death         = "sounds/splash_bang_pop/sound_enemy_defeat.wav",
    .Kill          = "sounds/splash_bang_pop/sound_enemy_defeat_small.wav",
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
sound_base_volume := [Sound_ID]f32{
    .None          = 0,
    .Jump          = 0.4,
    .Mine          = 0.7,
    .Place         = 0.7,
    .Pickup        = 0.7,
    .Hurt          = 0.8,
    .Death         = 0.9,
    .Kill          = 0.8,
    .Builder_Dig    = 0.5,
    .Builder_Place  = 0.5,
    .Builder_Shriek = 0.9,   // the raid alarm — must cut through everything
    .Sword_Hit      = 0.8,
    .Fanfare        = 0.8,
    .Fireball       = 0.7,
    .Garm_Roar      = 1.0,   // a boss phase announcing itself — must dominate
    .Wand_Fire      = 0.6,
    .Blast          = 0.9,
}

AMBIENCE_FILE :: "sounds/splash_bang_pop/sound_horror_ambience.wav"

// Builder sounds fade with distance but stay faintly audible far away.
BUILDER_HEAR_RANGE :: 48.0  // tiles
BUILDER_MIN_GAIN   :: 0.1

audio_init :: proc(a: ^Audio_State) {
    rl.InitAudioDevice()
    if !rl.IsAudioDeviceReady() do return
    a.initialized   = true
    a.master_volume = 1.0
    a.sfx_volume    = 0.8
    a.music_volume  = 0.6

    for id in Sound_ID {
        if id == .None do continue
        s := rl.LoadSound(sound_file[id])
        if s.frameCount == 0 do continue  // missing file: stay silent, don't crash
        a.sounds[id] = s
        a.loaded[id] = true
    }

    a.ambience = rl.LoadMusicStream(AMBIENCE_FILE)
    if a.ambience.frameCount > 0 {
        a.ambience_loaded  = true
        a.ambience.looping = true
        rl.SetMusicVolume(a.ambience, 0)
        rl.PlayMusicStream(a.ambience)
    }
}

audio_shutdown :: proc(a: ^Audio_State) {
    if !a.initialized do return
    for id in Sound_ID {
        if a.loaded[id] do rl.UnloadSound(a.sounds[id])
    }
    if a.ambience_loaded do rl.UnloadMusicStream(a.ambience)
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
    dx := f32(tile.x) + 0.5 - (gs.player.pos.x + PLAYER_W*0.5)
    dy := f32(tile.y) + 0.5 - (gs.player.pos.y + PLAYER_H*0.5)
    dist := math.sqrt(dx*dx + dy*dy)
    return clamp(1 - dist/BUILDER_HEAR_RANGE, BUILDER_MIN_GAIN, 1)
}

// Step 8 in game_update: streams ambience, volume follows the player's depth.
update_audio :: proc(gs: ^Game_State) {
    a := &gs.audio
    if !a.initialized || !a.ambience_loaded do return

    rl.UpdateMusicStream(a.ambience)

    // Ambience swells as the player descends below the surface.
    depth  := (gs.player.pos.y - SURFACE_Y) / 12.0
    target := clamp(depth, 0, 1) * a.music_volume * a.master_volume
    a.ambience_gain += (target - a.ambience_gain) * min(gs.delta_time * 2, 1)
    rl.SetMusicVolume(a.ambience, a.ambience_gain)
}
