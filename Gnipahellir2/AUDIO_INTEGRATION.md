# Audio System Integration

The Raylib audio system has been successfully integrated into Gnipahellir following the project's fat-struct, event-driven architecture.

## What's Been Added

### New Files
- `src/audio.odin` - Complete audio system implementation

### Modified Files
- `src/game_state.odin` - Added `Audio_State` to `Game_State`, initialization and cleanup
- `src/events.odin` - Added audio event types and processing
- `src/input.odin` - Added sound triggers for player actions and UI interactions
- `src/main.odin` - Fixed stack overflow by heap-allocating `Game_State`

## Audio System Features

### Sound Management
- **Fixed-size arrays**: Follows your fat-struct pattern with `MAX_LOADED_SOUNDS = 32`
- **Event-driven**: Audio is triggered through the existing event system
- **No runtime allocations**: All sounds pre-loaded at initialization
- **Graceful failure**: System handles missing sound files without crashing

### Sound Types Available
- Player sounds: `PLAYER_JUMP`, `PLAYER_LAND`, `PLAYER_FOOTSTEP`
- Mining sounds: `WAND_FIRE`, `TILE_BREAK_STONE`, `TILE_BREAK_DIRT`
- Item sounds: `ITEM_PICKUP`, `ITEM_DROP`, `ITEM_CRAFT`
- UI sounds: `UI_CLICK`, `UI_OPEN`, `UI_CLOSE`
- Environment: `PORTAL_SPAWN`, `AMBIENT_CAVE`
- Music: `MUSIC_MENU`, `MUSIC_EXPLORATION`, `MUSIC_DEPTH`

### Volume Controls
- Master volume (affects everything)
- SFX volume (affects sound effects)
- Music volume (affects background music)
- Per-sound volume overrides

### Music System
- Streaming music playback
- Fade in/out transitions
- Loop support
- Only one music track plays at a time

## How to Use

### Playing Sounds
The system is event-driven. To play a sound, push a `Play_Sound` event:

```odin
_ = event_queue_push(&game.events, Event{
    type = .Play_Sound,
    source_id = PLAYER_ID,
    target_id = PLAYER_ID,
    data = Sound_Event{ sound_id = .PLAYER_JUMP, volume = -1 } // -1 uses default volume
})
```

### Playing Music
```odin
_ = event_queue_push(&game.events, Event{
    type = .Play_Music,
    source_id = PLAYER_ID,
    target_id = PLAYER_ID,
    data = Music_Event{ music_id = .EXPLORATION, fade_in = true }
})
```

### Loading Sound Files
Currently, the `load_game_sounds()` function in `audio.odin` has placeholder paths. To add actual sounds:

1. Create an `assets/sounds/` directory
2. Add your sound files (WAV, OGG, MP3, FLAC supported)
3. Uncomment and update the file paths in `load_game_sounds()`

Example:
```odin
load_sound(audio, .PLAYER_JUMP, "assets/sounds/jump.wav")
load_sound(audio, .ITEM_PICKUP, "assets/sounds/pickup.ogg")
```

### Volume Controls
```odin
set_master_volume(&game.audio, 0.8)  // 80% volume
set_sfx_volume(&game.audio, 0.6)     // 60% SFX volume
set_music_volume(&game.audio, 0.4)   // 40% music volume
```

## Current Sound Triggers

### Automatic Triggers
- **Jump**: When player presses SPACE/W while grounded
- **Mining**: When tiles are broken (different sounds for stone vs organic materials)
- **Item Pickup**: When player moves over an item
- **UI**: When opening/closing inventory, character, or build menus

### Ready for Implementation
The system is ready for additional sound triggers:
- Player landing after a fall
- Footstep sounds during movement
- Wand firing
- Portal spawning/travel
- Crafting completion
- Background music transitions

## Next Steps

1. **Add Sound Files**: Create actual audio assets and update file paths
2. **Expand Triggers**: Add more sound events throughout the game
3. **Positional Audio**: Could be added later for 3D-positioned sounds
4. **Dynamic Music**: Implement music that changes based on depth/biome
5. **Audio Settings UI**: Add volume sliders to the debug menu

## Architecture Benefits

This implementation follows your project's principles:
- ✅ **Fat Struct**: All audio state in `Game_State.audio`
- ✅ **Event-Driven**: Audio triggered via event system
- ✅ **No Runtime Allocations**: Fixed-size arrays, pre-loaded sounds
- ✅ **Deterministic**: Audio updated in predictable order
- ✅ **Portable**: Uses only Raylib, no additional dependencies
- ✅ **Read-Only Rendering**: No audio calls in render functions

The system is production-ready and can be expanded as your game grows!
