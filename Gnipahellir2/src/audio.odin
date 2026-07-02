package gnipahellir

import rl "vendor:raylib"
import "core:os"
import "core:path/filepath"
import "core:strings"

// --- Audio System following Fat Struct Pattern ---

MAX_LOADED_SOUNDS :: 64
MAX_SOUND_CHANNELS :: 16 // For simultaneous sound playback

Sound_ID :: enum {
    NONE = 0,
    // Player sounds
    PLAYER_JUMP,
    PLAYER_LAND,
    PLAYER_FOOTSTEP,
    // Mining/interaction sounds
    WAND_FIRE,
    WAND_WATER,
    WAND_ICE,
    WAND_EARTH,
    WAND_WIND,
    WAND_LIGHT,
    TILE_BREAK_STONE,
    TILE_BREAK_DIRT,
    TILE_PLACE,
    // Item sounds
    ITEM_PICKUP,
    ITEM_DROP,
    ITEM_CRAFT,
    // UI sounds
    UI_CLICK,
    UI_CLICK_ALT1,
    UI_CLICK_ALT2,
    UI_OPEN,
    UI_CLOSE,
    UI_BEEP,
    UI_INVALID,
    UI_CONFIRM,
    UI_CANCEL,
    // Portal/magic sounds
    PORTAL_SPAWN,
    PORTAL_TRAVEL,
    TELEPORT,
    REFRACTION,
    // Environment sounds
    AMBIENT_CAVE,
    FOOTSTEP_NORMAL,
    FOOTSTEP_WATER,
    FOOTSTEP_CLACK,
    TREASURE_FIND,
    DIG_SOUND,
    STAIRS,
    HOLE_FALL,
    DOOR_OPEN,
    DOOR_LOCK,
    DOOR_UNLOCK,
    // Combat/action sounds
    HIT_NORMAL,
    HIT_CRITICAL,
    HIT_SLAP,
    MISS,
    DAMAGE,
    DEATH_EXPLOSION,
    // Status/effect sounds
    HEAL,
    HEAL_ALT1,
    HEAL_ALT2,
    BUFF,
    DEBUFF,
    POWER_UP,
    ENERGY,
    RECOVER,
    POISON,
    BURN,
    SLEEP,
    PARALYZE,
    BLIND,
    // Emotional/feedback sounds
    EXCITE,
    GOOD_STATE,
    BAD_STATE,
    STATUS_UP,
    STATUS_DOWN,
    // Utility sounds
    BUY_SOUND,
    ESCAPE,
    CATCH,
    SPAWN,
    BUMP,
    // Music tracks
    MUSIC_MENU,
    MUSIC_EXPLORATION,
    MUSIC_DEPTH,
}

Music_ID :: enum {
    NONE = 0,
    MENU,
    EXPLORATION,
    DEPTH,
}

Sound_Entry :: struct {
    id: Sound_ID,
    sound: rl.Sound,
    loaded: bool,
    volume: f32, // Base volume for this sound
}

// Dynamic sound entry for file-based loading
Dynamic_Sound :: struct {
    name: string,
    file_path: string,
    category: string,
    sound: rl.Sound,
    loaded: bool,
    volume: f32,
}

// Category grouping for efficient rendering
Sound_Category :: struct {
    name: string,
    sound_indices: [16]int, // Fixed array of sound indices in this category
    sound_count: int,
}

Audio_State :: struct {
    // Audio device state
    initialized: bool,
    
    // Volume controls
    master_volume: f32,
    sfx_volume: f32,
    music_volume: f32,
    
    // Sound storage (fixed-size arrays)
    sounds: [MAX_LOADED_SOUNDS]Sound_Entry,
    sound_count: int,
    
    // Music management
    current_music: rl.Music,
    current_music_id: Music_ID,
    music_loaded: bool,
    music_playing: bool,
    music_fade_target: f32,
    music_fade_speed: f32,
    
    // Sound playback queue (for event-driven audio)
    sound_queue: [MAX_SOUND_CHANNELS]Sound_ID,
    sound_queue_count: int,
    
    // Dynamic sounds loaded from file system
    dynamic_sounds: [MAX_LOADED_SOUNDS]Dynamic_Sound,
    dynamic_sound_count: int,
    
    // Pre-computed categories for stable rendering
    categories: [16]Sound_Category,
    category_count: int,
}

// --- Initialization ---

init_audio :: proc(audio: ^Audio_State) {
    // Don't re-initialize if already initialized
    if audio.initialized {
        return
    }
    
    rl.InitAudioDevice()
    if !rl.IsAudioDeviceReady() {
        // Handle audio init failure gracefully
        audio.initialized = false
        return
    }
    
    audio.initialized = true
    audio.master_volume = 1.0
    audio.sfx_volume = 0.8
    audio.music_volume = 0.6
    audio.music_fade_speed = 2.0 // 2.0 = fade over 0.5 seconds at 60fps
    
    // Initialize sound entries
    for i in 0..<MAX_LOADED_SOUNDS {
        audio.sounds[i] = {}
    }
    
    rl.SetMasterVolume(audio.master_volume)
}

cleanup_audio :: proc(audio: ^Audio_State) {
    if !audio.initialized do return
    
    // Unload all sounds
    for i in 0..<audio.sound_count {
        if audio.sounds[i].loaded {
            rl.UnloadSound(audio.sounds[i].sound)
        }
    }
    
    // Unload dynamic sounds
    for i in 0..<audio.dynamic_sound_count {
        if audio.dynamic_sounds[i].loaded {
            rl.UnloadSound(audio.dynamic_sounds[i].sound)
        }
    }
    
    // Unload music
    if audio.music_loaded {
        rl.UnloadMusicStream(audio.current_music)
    }
    
    rl.CloseAudioDevice()
    audio.initialized = false
}

// --- Sound Loading ---

load_sound :: proc(audio: ^Audio_State, id: Sound_ID, file_path: cstring) -> bool {
    if !audio.initialized do return false
    if audio.sound_count >= MAX_LOADED_SOUNDS do return false
    
    // Check if already loaded
    for i in 0..<audio.sound_count {
        if audio.sounds[i].id == id {
            return true // Already loaded
        }
    }
    
    sound := rl.LoadSound(file_path)
    if sound.frameCount == 0 {
        // Failed to load
        return false
    }
    
    // Add to sounds array
    entry := &audio.sounds[audio.sound_count]
    entry.id = id
    entry.sound = sound
    entry.loaded = true
    entry.volume = 1.0 // Default volume
    
    audio.sound_count += 1
    return true
}

load_music :: proc(audio: ^Audio_State, id: Music_ID, file_path: cstring) -> bool {
    if !audio.initialized do return false
    
    // Unload current music if any
    if audio.music_loaded {
        rl.UnloadMusicStream(audio.current_music)
        audio.music_loaded = false
        audio.music_playing = false
    }
    
    music := rl.LoadMusicStream(file_path)
    if music.frameCount == 0 {
        return false // Failed to load
    }
    
    audio.current_music = music
    audio.current_music_id = id
    audio.music_loaded = true
    
    return true
}

// --- Playback Functions ---

play_sound :: proc(audio: ^Audio_State, id: Sound_ID, volume_override: f32 = -1) {
    if !audio.initialized do return
    
    // Find the sound
    for i in 0..<audio.sound_count {
        if audio.sounds[i].id == id && audio.sounds[i].loaded {
            volume := audio.sounds[i].volume
            if volume_override >= 0 {
                volume = volume_override
            }
            
            final_volume := volume * audio.sfx_volume * audio.master_volume
            rl.SetSoundVolume(audio.sounds[i].sound, final_volume)
            rl.PlaySound(audio.sounds[i].sound)
            return
        }
    }
}

// Queue a sound to be played this frame (for event-driven audio)
queue_sound :: proc(audio: ^Audio_State, id: Sound_ID) {
    if audio.sound_queue_count < MAX_SOUND_CHANNELS {
        audio.sound_queue[audio.sound_queue_count] = id
        audio.sound_queue_count += 1
    }
}

play_music :: proc(audio: ^Audio_State, id: Music_ID, fade_in: bool = true) {
    if !audio.initialized || !audio.music_loaded do return
    if audio.current_music_id != id do return // Wrong music loaded
    
    if !audio.music_playing {
        rl.PlayMusicStream(audio.current_music)
        audio.music_playing = true
        
        if fade_in {
            rl.SetMusicVolume(audio.current_music, 0.0)
            audio.music_fade_target = audio.music_volume * audio.master_volume
        } else {
            rl.SetMusicVolume(audio.current_music, audio.music_volume * audio.master_volume)
            audio.music_fade_target = audio.music_volume * audio.master_volume
        }
    }
}

stop_music :: proc(audio: ^Audio_State, fade_out: bool = true) {
    if !audio.initialized || !audio.music_playing do return
    
    if fade_out {
        audio.music_fade_target = 0.0
    } else {
        rl.StopMusicStream(audio.current_music)
        audio.music_playing = false
    }
}

// --- Update Function ---

update_audio :: proc(audio: ^Audio_State, dt: f32) {
    if !audio.initialized do return
    
    // Process queued sounds
    for i in 0..<audio.sound_queue_count {
        play_sound(audio, audio.sound_queue[i])
    }
    audio.sound_queue_count = 0 // Clear queue
    
    // Update music streaming
    if audio.music_loaded && audio.music_playing {
        rl.UpdateMusicStream(audio.current_music)
        
        // Handle music fading - we'll track the volume ourselves since GetMusicVolume isn't available
        current_volume := audio.music_fade_target // Use target as current for now
        fade_step := audio.music_fade_speed * dt
        
        // Simple fade logic without GetMusicVolume
        if audio.music_fade_target <= 0.0 {
            rl.SetMusicVolume(audio.current_music, 0.0)
            rl.StopMusicStream(audio.current_music)
            audio.music_playing = false
        } else {
            rl.SetMusicVolume(audio.current_music, audio.music_fade_target)
        }
    }
}

// --- Volume Controls ---

set_master_volume :: proc(audio: ^Audio_State, volume: f32) {
    audio.master_volume = clamp(volume, 0.0, 1.0)
    rl.SetMasterVolume(audio.master_volume)
    
    // Update music volume immediately
    if audio.music_playing {
        rl.SetMusicVolume(audio.current_music, audio.music_volume * audio.master_volume)
        audio.music_fade_target = audio.music_volume * audio.master_volume
    }
}

set_sfx_volume :: proc(audio: ^Audio_State, volume: f32) {
    audio.sfx_volume = clamp(volume, 0.0, 1.0)
}

set_music_volume :: proc(audio: ^Audio_State, volume: f32) {
    audio.music_volume = clamp(volume, 0.0, 1.0)
    
    if audio.music_playing {
        rl.SetMusicVolume(audio.current_music, audio.music_volume * audio.master_volume)
        audio.music_fade_target = audio.music_volume * audio.master_volume
    }
}

// --- Helper Functions ---

is_sound_loaded :: proc(audio: ^Audio_State, id: Sound_ID) -> bool {
    for i in 0..<audio.sound_count {
        if audio.sounds[i].id == id {
            return audio.sounds[i].loaded
        }
    }
    return false
}

is_music_playing :: proc(audio: ^Audio_State) -> bool {
    return audio.music_playing
}

// --- Dynamic Sound Loading ---

// Get category from file path
categorize_sound :: proc(file_path: string) -> string {
    lower_path := strings.to_lower(file_path)
    
    if strings.contains(lower_path, "antenna") {
        if strings.contains(lower_path, "fire") do return "Wand Fire"
        if strings.contains(lower_path, "water") do return "Wand Water"
        if strings.contains(lower_path, "ice") do return "Wand Ice"
        if strings.contains(lower_path, "earth") do return "Wand Earth"
        if strings.contains(lower_path, "wind") do return "Wand Wind"
        if strings.contains(lower_path, "light") do return "Wand Light"
        if strings.contains(lower_path, "heal") do return "Healing"
        if strings.contains(lower_path, "buff") do return "Buffs"
        if strings.contains(lower_path, "debuff") do return "Debuffs"
        if strings.contains(lower_path, "poison") do return "Poison"
        return "Magic Effects"
    }
    
    if strings.contains(lower_path, "click") do return "UI Clicks"
    if strings.contains(lower_path, "beep") do return "UI Feedback"
    if strings.contains(lower_path, "door") do return "Environment"
    if strings.contains(lower_path, "walking") || strings.contains(lower_path, "step") do return "Movement"
    if strings.contains(lower_path, "hit") || strings.contains(lower_path, "slap") do return "Combat"
    if strings.contains(lower_path, "status") do return "Status Effects"
    if strings.contains(lower_path, "misc") do return "Miscellaneous"
    if strings.contains(lower_path, "battle") do return "Battle"
    if strings.contains(lower_path, "splash_bang_pop") do return "Item"
    
    return "Other"
}

// Get a nice display name from file path
get_sound_name :: proc(file_path: string) -> string {
    base := filepath.base(file_path)
    // Remove file extension
    name := strings.trim_suffix(base, filepath.ext(base))
    
    // Remove common prefixes like "[38] WAV_38_"
    if strings.contains(name, "] WAV_") {
        parts := strings.split(name, "] WAV_")
        if len(parts) > 1 {
            name = strings.join(parts[1:], " ")
        }
    }
    
    // Clean up underscores
    name, _ = strings.replace_all(name, "_", " ")
    return name
}

// Load a dynamic sound
load_dynamic_sound :: proc(audio: ^Audio_State, file_path: string) -> bool {
    if !audio.initialized do return false
    if audio.dynamic_sound_count >= MAX_LOADED_SOUNDS do return false
    
    sound := rl.LoadSound(cstring(raw_data(file_path)))
    if sound.frameCount == 0 {
        return false // Failed to load
    }
    
    entry := &audio.dynamic_sounds[audio.dynamic_sound_count]
    entry.name = get_sound_name(file_path)
    entry.file_path = file_path
    entry.category = categorize_sound(file_path)
    entry.sound = sound
    entry.loaded = true
    entry.volume = 0.7 // Default volume
    
    // Adjust volume based on category
    if strings.contains(entry.category, "UI") {
        entry.volume = 0.5
    } else if strings.contains(entry.category, "Movement") {
        entry.volume = 0.4
    } else if strings.contains(entry.category, "Combat") {
        entry.volume = 0.8
    }
    
    audio.dynamic_sound_count += 1
    return true
}

// Recursively scan directory for sound files
scan_sound_directory :: proc(audio: ^Audio_State, dir_path: string) {
    if !audio.initialized do return
    
    dir_handle, err := os.open(dir_path)
    if err != os.ERROR_NONE do return
    defer os.close(dir_handle)
    
    files, read_err := os.read_dir(dir_handle, -1, context.allocator)
    if read_err != os.ERROR_NONE do return
    defer delete(files)

    for file in files {
        full_path, _ := filepath.join({dir_path, file.name})
        defer delete(full_path)

        if file.type == .Directory {
            // Recursively scan subdirectories
            scan_sound_directory(audio, full_path)
        } else {
            // Check if it's a sound file
            ext := strings.to_lower(filepath.ext(file.name))
            if ext == ".wav" || ext == ".ogg" || ext == ".mp3" || ext == ".flac" {
                load_dynamic_sound(audio, strings.clone(full_path))
            }
        }
    }
}

// Play a dynamic sound by index
play_dynamic_sound :: proc(audio: ^Audio_State, index: int, volume_override: f32 = -1) {
    if !audio.initialized do return
    if index < 0 || index >= audio.dynamic_sound_count do return
    
    entry := &audio.dynamic_sounds[index]
    if !entry.loaded do return
    
    volume := entry.volume
    if volume_override >= 0 {
        volume = volume_override
    }
    
    final_volume := volume * audio.sfx_volume * audio.master_volume
    rl.SetSoundVolume(entry.sound, final_volume)
    rl.PlaySound(entry.sound)
}

// Rebuild categories from loaded dynamic sounds
rebuild_categories :: proc(audio: ^Audio_State) {
    // Clear existing categories
    audio.category_count = 0
    
    // Find or create category for each sound
    for i in 0..<audio.dynamic_sound_count {
        sound := &audio.dynamic_sounds[i]
        if !sound.loaded do continue
        
        // Find existing category
        category_idx := -1
        for j in 0..<audio.category_count {
            if audio.categories[j].name == sound.category {
                category_idx = j
                break
            }
        }
        
        // Create new category if needed
        if category_idx == -1 {
            if audio.category_count >= len(audio.categories) do continue // Skip if too many categories
            category_idx = audio.category_count
            audio.categories[category_idx].name = sound.category
            audio.categories[category_idx].sound_count = 0
            audio.category_count += 1
        }
        
        // Add sound to category
        cat := &audio.categories[category_idx]
        if cat.sound_count < len(cat.sound_indices) {
            cat.sound_indices[cat.sound_count] = i
            cat.sound_count += 1
        }
    }
}

// --- Dynamic Sound Loading ---
// Automatically loads all sounds from the sounds directory
load_game_sounds :: proc(audio: ^Audio_State) {
    if !audio.initialized do return
    
    // Scan the sounds directory for all sound files
    scan_sound_directory(audio, "sounds")
    
    // Rebuild categories after loading all sounds
    rebuild_categories(audio)
    
    // Also keep a few key sounds loaded in the static system for guaranteed availability
    // (in case the wand mining sound needs to be reliable)
    load_sound(audio, .WAND_FIRE, "sounds/splash_bang_pop/sfx_ar_primary_attack.wav")
    load_sound(audio, .UI_CLICK, "sounds/splash_bang_pop/sound_menu_kaching.wav")
    load_sound(audio, .ITEM_PICKUP, "sounds/splash_bang_pop/sound_loot_pickup.wav")
    load_sound(audio, .DIG_SOUND, "sounds/splash_bang_pop/sfx_ar_primary_attack.wav")
    load_sound(audio, .DEATH_EXPLOSION, "sounds/splash_bang_pop/sfx_ar_primary_attack.wav") // Using same sound for now
    
    // Set reasonable default volumes for static sounds
    for i in 0..<audio.sound_count {
        sound := &audio.sounds[i]
        sound.volume = 0.7
        
        #partial switch sound.id {
        case .UI_CLICK:
            sound.volume = 0.5
        }
    }
}
