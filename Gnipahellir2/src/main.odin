package gnipahellir

import rl "vendor:raylib/v55"
// NOTE: Desired vsync enable (FLAG_VSYNC_HINT) isn't exposed in current binding.
// We'll rely on SetTargetFPS and driver vsync. Once binding exposes flag, call:
// rl.SetConfigFlags(rl.ConfigFlags.VSYNC_HINT) BEFORE InitWindow.

// Window / view configuration
WINDOW_WIDTH :: 1024
WINDOW_HEIGHT :: 768

main :: proc() {
	// (VSync hint flag not available in binding—cannot set before InitWindow currently)

	rl.SetConfigFlags({.VSYNC_HINT})

	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Gnipahellir")
	// Disable Raylib's default ESC-to-exit so we can use ESC for UI closing only
	rl.SetExitKey(cast(rl.KeyboardKey)0)
	// Target 60 FPS; if driver forces vsync this will align with refresh.
	rl.SetTargetFPS(60)

	game := new(Game_State)
	defer free(game)
	init_game(game)

	// Initialize camera (will be properly set when game starts)
	game.camera.zoom = 1
	game.camera.target_x = cast(f32)(WORLD_WIDTH * TILE_SIZE / 2)
	game.camera.target_y = cast(f32)(WORLD_HEIGHT * TILE_SIZE / 2)

	for !rl.WindowShouldClose() {
		// Runtime toggles
		if rl.IsKeyPressed(rl.KeyboardKey.F11) {rl.ToggleFullscreen()}
		dt := rl.GetFrameTime()
		game_update(game, dt)
		update_camera(game, dt)

		// (Placeholder) F10 could be used later to toggle vsync once flag constant identified.

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{10, 8, 15, 255})
		render_game(game)
		rl.EndDrawing()
	}

	// Save game state before closing
	save_game_state(game)

	// Save persistent stats before closing
	save_persistent_stats(&game.stats)

	// Cleanup audio before closing
	cleanup_audio(&game.audio)
	rl.CloseWindow()
}
