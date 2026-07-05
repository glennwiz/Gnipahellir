package gnipahellir

// Placeholder input system for Phase 1.
// Will be replaced with actual event polling & key handling (raylib) in later phases.

import "core:os"
import rl "vendor:raylib/v55"

handle_input :: proc(game: ^Game_State) {
	// Handle menu input first
	if game.ui.main_menu_active {
		handle_main_menu_input(game)
		return
	}

	if game.ui.save_quit_dialog_active {
		handle_save_quit_dialog_input(game)
		return
	}

	if game.ui.settings_menu_active {
		handle_settings_menu_input(game)
		return
	}

	// Don't handle game input if player is dead
	if game.player_dead {
		return
	}

	p := &game.player
	move_speed: f32 = 6 // horizontal speed
	target_vx: f32 = 0

	// WASD movement
	if rl.IsKeyDown(rl.KeyboardKey.A) {target_vx -= move_speed}
	if rl.IsKeyDown(rl.KeyboardKey.D) {target_vx += move_speed}
	// Arrow key movement
	if rl.IsKeyDown(rl.KeyboardKey.LEFT) {target_vx -= move_speed}
	if rl.IsKeyDown(rl.KeyboardKey.RIGHT) {target_vx += move_speed}
	p.vel_x = target_vx

	// Jumping / flight
	if p.can_fly {
		// Free vertical movement (future buff): WASD and arrow key style
		target_vy: f32 = 0
		if rl.IsKeyDown(rl.KeyboardKey.W) {target_vy -= move_speed}
		if rl.IsKeyDown(rl.KeyboardKey.S) {target_vy += move_speed}
		if rl.IsKeyDown(rl.KeyboardKey.UP) {target_vy -= move_speed}
		if rl.IsKeyDown(rl.KeyboardKey.DOWN) {target_vy += move_speed}
		if target_vy != 0 {p.vel_y = target_vy} 	// override gravity when moving
	} else {
		// Grounded jump: detect ground by checking solid tile directly below when vertical velocity is ~0
		on_ground := false
		below_y := p.tile_y + 1
		if p.vel_y == 0 && tile_is_solid(&game.world, p.tile_x, below_y) {
			on_ground = true
		}
		jump_speed: f32 = 10
		if on_ground &&
		   (rl.IsKeyPressed(rl.KeyboardKey.SPACE) ||
				   rl.IsKeyPressed(rl.KeyboardKey.W) ||
				   rl.IsKeyPressed(rl.KeyboardKey.UP)) {
			p.vel_y = -jump_speed
			// Trigger jump sound
			_ = event_queue_push(
				&game.events,
				Event {
					type = .Play_Sound,
					source_id = PLAYER_ID,
					target_id = PLAYER_ID,
					data = Sound_Event{sound_id = .PLAYER_JUMP, volume = -1},
				},
			)
		}
	}

	// Toggle bag with B key (on press)
	if rl.IsKeyPressed(rl.KeyboardKey.B) {
		game.ui.bag_open = !game.ui.bag_open
		// Play UI sound
		sound_id: Sound_ID = game.ui.bag_open ? .UI_OPEN : .UI_CLOSE
		_ = event_queue_push(
			&game.events,
			Event {
				type = .Play_Sound,
				source_id = PLAYER_ID,
				target_id = PLAYER_ID,
				data = Sound_Event{sound_id = sound_id, volume = -1},
			},
		)
	}
	if rl.IsKeyPressed(rl.KeyboardKey.C) {
		game.ui.character_open = !game.ui.character_open
		// Play UI sound
		sound_id: Sound_ID = game.ui.character_open ? .UI_OPEN : .UI_CLOSE
		_ = event_queue_push(
			&game.events,
			Event {
				type = .Play_Sound,
				source_id = PLAYER_ID,
				target_id = PLAYER_ID,
				data = Sound_Event{sound_id = sound_id, volume = -1},
			},
		)
	}
	if rl.IsKeyPressed(rl.KeyboardKey.R) {
		game.ui.build_menu_open = !game.ui.build_menu_open
		// Play UI sound
		sound_id: Sound_ID = game.ui.build_menu_open ? .UI_OPEN : .UI_CLOSE
		_ = event_queue_push(
			&game.events,
			Event {
				type = .Play_Sound,
				source_id = PLAYER_ID,
				target_id = PLAYER_ID,
				data = Sound_Event{sound_id = sound_id, volume = -1},
			},
		)
	}
	// Debug menu toggle (F3)
	if rl.IsKeyPressed(rl.KeyboardKey.F3) {game.ui.debug_open = !game.ui.debug_open}

	// Stats screen toggle (F10)
	if rl.IsKeyPressed(rl.KeyboardKey.F10) {
		game.ui.stats_open = !game.ui.stats_open
		// Play a sound when opening the stats window
		if game.ui.stats_open {
			_ = event_queue_push(
				&game.events,
				Event {
					type = .Play_Sound,
					source_id = PLAYER_ID,
					target_id = PLAYER_ID,
					data = Sound_Event{sound_id = .UI_BEEP, volume = -1},
				},
			)
		}
	}

	// Save and quit dialog (F5)
	if rl.IsKeyPressed(rl.KeyboardKey.F5) {
		game.ui.save_quit_dialog_active = true
		game.ui.menu_selection = 0 // Select "Save and Quit" by default
	}

	// New game (F9) - only when not dead
	if rl.IsKeyPressed(rl.KeyboardKey.F9) && !game.player_dead {
		// Delete save file to start fresh
		os.remove("gnipahellir_save.dat")
		// Restart the game
		start_new_game(game)
		game.ui.popup_active = true
		game.ui.popup_text = "New game started!"
		game.ui.popup_time = 2.0
	}

	// Stats screen scrolling (when stats window is open)
	if game.ui.stats_open {
		// Mouse wheel scrolling
		wheel_move := rl.GetMouseWheelMove()
		if wheel_move != 0 {
			game.ui.stats_scroll -= cast(int)wheel_move * 3 // Scroll 3 lines per wheel tick
			if game.ui.stats_scroll < 0 {
				game.ui.stats_scroll = 0
			}
		}

		// Arrow key scrolling
		if rl.IsKeyPressed(rl.KeyboardKey.UP) {
			game.ui.stats_scroll -= 1
			if game.ui.stats_scroll < 0 {
				game.ui.stats_scroll = 0
			}
		}
		if rl.IsKeyPressed(rl.KeyboardKey.DOWN) {
			game.ui.stats_scroll += 1
		}
	}

	// Sound debug window toggle (F12)
	if rl.IsKeyPressed(rl.KeyboardKey.F12) {
		game.ui.sound_debug_open = !game.ui.sound_debug_open
		// Play a sound when opening the debug window
		if game.ui.sound_debug_open {
			_ = event_queue_push(
				&game.events,
				Event {
					type = .Play_Sound,
					source_id = PLAYER_ID,
					target_id = PLAYER_ID,
					data = Sound_Event{sound_id = .UI_BEEP, volume = -1},
				},
			)
		}
	}

	// Debug level switching (only when debug menu is open for safety)
	if game.ui.debug_open {
		// G key to spawn Garm for testing (only if not already active)
		if rl.IsKeyPressed(rl.KeyboardKey.G) && !game.garm.active {
			// Spawn Garm near the player for testing
			spawn_x := game.player.tile_x + 5
			spawn_y := game.player.tile_y
			if bounds_check(spawn_x, spawn_y) {
				enemy_init(&game.garm, spawn_x, spawn_y, GARM_ID)
				game.world.entities[spawn_x][spawn_y] = GARM_ID
			}
		}

		// Number keys 1-8 for cave levels
		if rl.IsKeyPressed(rl.KeyboardKey.ONE) {
			load_level(game, 1, game.player.tile_x, false) // Cave level 1
		}
		if rl.IsKeyPressed(rl.KeyboardKey.TWO) {
			load_level(game, 2, game.player.tile_x, false) // Cave level 2
		}
		if rl.IsKeyPressed(rl.KeyboardKey.THREE) {
			load_level(game, 3, game.player.tile_x, false) // Cave level 3
		}
		if rl.IsKeyPressed(rl.KeyboardKey.FOUR) {
			load_level(game, 4, game.player.tile_x, false) // Cave level 4
		}
		if rl.IsKeyPressed(rl.KeyboardKey.FIVE) {
			load_level(game, 5, game.player.tile_x, false) // Cave level 5
		}
		if rl.IsKeyPressed(rl.KeyboardKey.SIX) {
			load_level(game, 6, game.player.tile_x, false) // Cave level 6
		}
		if rl.IsKeyPressed(rl.KeyboardKey.SEVEN) {
			load_level(game, 7, game.player.tile_x, false) // Cave level 7
		}
		if rl.IsKeyPressed(rl.KeyboardKey.EIGHT) {
			load_level(game, 8, game.player.tile_x, false) // Cave level 8
		}
		// Zero for surface
		if rl.IsKeyPressed(rl.KeyboardKey.ZERO) {
			load_level(game, 0, game.player.tile_x, false) // Surface
		}
		// F1-F4 for sky levels (negative offsets)
		if rl.IsKeyPressed(rl.KeyboardKey.F1) {
			load_level(game, -1, game.player.tile_x, false) // Sky Level 1
		}
		if rl.IsKeyPressed(rl.KeyboardKey.F2) {
			load_level(game, -2, game.player.tile_x, false) // Sky Level 2
		}
		if rl.IsKeyPressed(rl.KeyboardKey.F3) {
			// F3 is debug toggle, skip level switching
		}
		if rl.IsKeyPressed(rl.KeyboardKey.F4) {
			load_level(game, -4, game.player.tile_x, false) // Sky Level 4
		}
		// Minus key for going up one sky level
		if rl.IsKeyPressed(rl.KeyboardKey.MINUS) {
			new_offset := game.level_offset - 1
			if new_offset >= -SKY_LEVELS {
				load_level(game, new_offset, game.player.tile_x, false) // Sky levels
			}
		}
		// Plus/Equal key for deeper caves or down from sky
		if rl.IsKeyPressed(rl.KeyboardKey.EQUAL) { 	// Equal key (same as plus without shift)
			new_offset := game.level_offset + 1
			if new_offset <= CAVE_LEVELS {
				load_level(game, new_offset, game.player.tile_x, false)
			}
		}
	}

	// Close all popups with ESC or Q
	if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) || rl.IsKeyPressed(rl.KeyboardKey.Q) {
		game.ui.bag_open = false
		game.ui.character_open = false
		game.ui.build_menu_open = false
		game.ui.crafting_open = false
		game.ui.dragging = false
		game.ui.debug_open = false
	}

	// Fullscreen toggle (F11 or Alt+Enter)
	alt_enter :=
		rl.IsKeyPressed(rl.KeyboardKey.ENTER) &&
		(rl.IsKeyDown(rl.KeyboardKey.LEFT_ALT) || rl.IsKeyDown(rl.KeyboardKey.RIGHT_ALT))
	if rl.IsKeyPressed(rl.KeyboardKey.F11) || alt_enter {
		was_full := rl.IsWindowFullscreen()
		rl.ToggleFullscreen()
		if was_full {
			// Restore to designed window size
			rl.SetWindowSize(WINDOW_WIDTH, WINDOW_HEIGHT)
		}
		// Clamp UI windows into new bounds
		sw_i32 := rl.GetScreenWidth()
		sh_i32 := rl.GetScreenHeight()
		sw := cast(int)sw_i32
		sh := cast(int)sh_i32
		ui := &game.ui
		// helper local proc
		clamp := proc(v, lo, hi: int) -> int {if v < lo {return lo};if v > hi {return hi};return v}
		if ui.inv_x + INVENTORY_W > sw {ui.inv_x = clamp(sw - INVENTORY_W, 0, sw - 10)}
		if ui.inv_y + INVENTORY_H > sh {ui.inv_y = clamp(sh - INVENTORY_H, 0, sh - 10)}
		if ui.char_x + CHARACTER_W > sw {ui.char_x = clamp(sw - CHARACTER_W, 0, sw - 10)}
		if ui.char_y + CHARACTER_H > sh {ui.char_y = clamp(sh - CHARACTER_H, 0, sh - 10)}
		if ui.build_x + BUILD_MENU_W > sw {ui.build_x = clamp(sw - BUILD_MENU_W, 0, sw - 10)}
		if ui.build_y + BUILD_MENU_H > sh {ui.build_y = clamp(sh - BUILD_MENU_H, 0, sh - 10)}
		if ui.craft_x + CRAFT_MENU_W > sw {ui.craft_x = clamp(sw - CRAFT_MENU_W, 0, sw - 10)}
		if ui.craft_y + CRAFT_MENU_H > sh {ui.craft_y = clamp(sh - CRAFT_MENU_H, 0, sh - 10)}
	}

	// Click interaction: open crafting when clicking bench (priority over mining)
	if rl.IsMouseButtonPressed(rl.MouseButton(0)) {
		mouse := rl.GetMousePosition()
		if !point_in_any_window(game, cast(int)mouse.x, cast(int)mouse.y) {
			mtx, mty, ok := mouse_world_tile(game)
			if ok {
				px := game.player.tile_x
				py := game.player.tile_y
				dx := mtx - px
				dy := mty - py
				// Range limit (Manhattan <=5 OR Euclidean < ~5)
				if dx * dx + dy * dy <= 25 { 	// 5^2
					tt := game.world.terrain[mtx][mty]
					// Crafting bench opens crafting UI
					if tt == .Crafting_Bench {
						game.ui.crafting_open = true
						game.ui.crafting_active_from_bench = true
						if game.ui.crafting_selected_index <
						   0 {game.ui.crafting_selected_index = 0}
						return // suppress mining this click
					}
					if !game.ui.build_menu_open && game.player.main_hand == .Mine_Wand {
						// Check if player has enough mana to mine
						if game.player.mana >= 1.0 {
							// Check if there's an enemy at target location
							target_entity := game.world.entities[mtx][mty]
							enemy_target := target_entity == GARM_ID && game.garm.active

							if tt != .Air || enemy_target {
								// Start delayed mining action if none active targeting same tile
								drop_id: Item_ID = .None
								if tt ==
								   .Wood {drop_id = .Wood_Log} else if tt == .Leaves {drop_id = .Leaf} else if tt == .Crafting_Bench {drop_id = .Crafting_Bench} else if tt == .Tree_Grower {drop_id = .Tree_Grower} else if tt == .Stone {drop_id = .Stone_Block} else if tt == .Grass {drop_id = .Grass_Turf} else if tt == .Iron {drop_id = .Iron_Ore} else if tt == .Silver {drop_id = .Silver_Ore} else if tt == .Gold {drop_id = .Gold_Ore} else if tt == .Gold_Rare {drop_id = .Gold_Rare_Ore} else if tt == .Smelter {drop_id = .Smelter}
								// Wand tip pixel world coords for nicer origin
								from_x, from_y, ok_tip := player_wand_tip_world(&game.player)
								if !ok_tip {
									from_x = game.player.visual_x * TILE_SIZE
									from_y = game.player.visual_y * TILE_SIZE - 2
								}
								to_x := cast(f32)(mtx * TILE_SIZE + TILE_SIZE / 2)
								to_y := cast(f32)(mty * TILE_SIZE + TILE_SIZE / 2)
								travel: f32 = 0.18 // seconds base travel
								// Spawn a burst of small traveling sparks
								wand_projectiles_spawn(
									&game.wand_projectiles,
									from_x,
									from_y,
									to_x,
									to_y,
									6,
									travel,
								)
								// Play wand fire sound
								_ = event_queue_push(
									&game.events,
									Event {
										type = .Play_Sound,
										source_id = PLAYER_ID,
										target_id = PLAYER_ID,
										data = Sound_Event{sound_id = .WAND_FIRE, volume = -1},
									},
								)
								// Register mining action (overwrites any existing action)
								game.mining.active = true
								game.mining.target_tx = mtx
								game.mining.target_ty = mty
								game.mining.drop_id = drop_id
								game.mining.travel_time = travel
								game.mining.elapsed = 0
								game.mining.target_enemy = enemy_target

								// Consume mana for mining
								game.player.mana -= 1.0

								// Record mining action
								record_mining_action(&game.stats, 1)
							}
						} else {
							// Not enough mana - show feedback
							game.ui.popup_active = true
							game.ui.popup_text = "Not enough mana!"
							game.ui.popup_time = 1.0
						}
					} else if !game.ui.build_menu_open {
						// Hand mining: only Wood, requires 3 hits
						if tt == .Wood {
							cnt := &game.world.hit_counts[mtx][mty]
							cnt^ += 1
							spark_x := cast(f32)(mtx * TILE_SIZE + TILE_SIZE / 2)
							spark_y := cast(f32)(mty * TILE_SIZE + TILE_SIZE / 2)
							particle_spawn_spark(&game.particles, spark_x, spark_y)
							if cnt^ >= 3 {
								cnt^ = 0
								// Defer world mutation to event processor
								_ = event_queue_push(
									&game.events,
									Event {
										type = .Mining_Request,
										source_id = PLAYER_ID,
										target_id = PLAYER_ID,
										data = Mining_Event {
											tx = mtx,
											ty = mty,
											removed = .Wood,
											drop = .Wood_Log,
										},
									},
								)
							}
						}
					}
				}
			}
		}
	}

	// Right-click interaction: bucket functionality
	if rl.IsMouseButtonPressed(rl.MouseButton(1)) {
		mouse := rl.GetMousePosition()
		if !point_in_any_window(game, cast(int)mouse.x, cast(int)mouse.y) {
			mtx, mty, ok := mouse_world_tile(game)
			if ok && game.player.main_hand == .Iron_Bucket {
				px := game.player.tile_x
				py := game.player.tile_y
				dx := mtx - px
				dy := mty - py
				// Range limit (Manhattan <=5 OR Euclidean < ~5)
				if dx * dx + dy * dy <= 25 { 	// 5^2
					tt := game.world.terrain[mtx][mty]
					if !game.bucket_has_lava && (tt == .Lava || tt == .Magic_Lava) {
						// Pick up lava
						game.world.terrain[mtx][mty] = .Air
						game.bucket_has_lava = true
						game.ui.popup_active = true
						game.ui.popup_text = "Lava collected!"
						game.ui.popup_time = 1.5
					} else if game.bucket_has_lava && (tt == .Air || tt == .Void) {
						// Place lava
						game.world.terrain[mtx][mty] = .Lava
						game.world.lava_elapsed[mtx][mty] = 0
						game.world.lava_target[mtx][mty] = cast(f32)(rl.GetRandomValue(1, 3))
						game.bucket_has_lava = false
						game.ui.popup_active = true
						game.ui.popup_text = "Lava placed!"
						game.ui.popup_time = 1.5
					}
				}
			}
		}
	}

	// Update facing direction based on mouse horizontal position relative to player center
	mouse := rl.GetMousePosition()
	cam_origin_x2 := game.camera.target_x - cast(f32)WINDOW_WIDTH / 2
	cam_origin_y2 := game.camera.target_y - cast(f32)WINDOW_HEIGHT / 2
	player_center_x := game.player.visual_x * TILE_SIZE - cam_origin_x2
	// Compare screen x positions
	if mouse.x >=
	   player_center_x {game.player.facing_right = true} else {game.player.facing_right = false}

	// Placement with left mouse click (build mode always overrides mining)
	if rl.IsMouseButtonPressed(rl.MouseButton(0)) &&
	   game.ui.build_selected != .None &&
	   game.ui.build_menu_open {
		// If clicking inside build menu (use dynamic position), ignore placement
		ignore := false
		if game.ui.build_menu_open {
			mouse := rl.GetMousePosition()
			bx := game.ui.build_x
			by := game.ui.build_y
			bw := BUILD_MENU_W
			bh := BUILD_MENU_H
			if mouse.x >= cast(f32)bx &&
			   mouse.x < cast(f32)(bx + bw) &&
			   mouse.y >= cast(f32)by &&
			   mouse.y < cast(f32)(by + bh) {
				ignore = true
			}
		}
		if !ignore {
			debugf("Click attempt selected=%s", item_name(game.ui.build_selected))
			place_build_block(game)
		} else {
			debugf(
				"Click ignored inside build menu selected=%s",
				item_name(game.ui.build_selected),
			)
		}
	}

	// Scroll wheel for build menu list
	if game.ui.build_menu_open {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			game.ui.build_scroll -= cast(int)wheel // wheel >0 means scroll up -> decrease scroll index
			if game.ui.build_scroll < 0 {game.ui.build_scroll = 0}
		}
	}
}

// Helper to convert mouse to world tile
mouse_world_tile :: proc(game: ^Game_State) -> (int, int, bool) {
	mouse := rl.GetMousePosition()
	screen_w := rl.GetScreenWidth()
	screen_h := rl.GetScreenHeight()
	cam_origin_x := game.camera.target_x - cast(f32)screen_w / 2
	cam_origin_y := game.camera.target_y - cast(f32)screen_h / 2
	world_px_x := mouse.x + cam_origin_x
	world_px_y := mouse.y + cam_origin_y
	tx := cast(int)(world_px_x) / TILE_SIZE
	ty := cast(int)(world_px_y) / TILE_SIZE
	if !bounds_check(tx, ty) {return 0, 0, false}
	return tx, ty, true
}

place_build_block :: proc(game: ^Game_State) {
	if game.ui.build_selected == .None {
		debugf("place_build_block: no selection")
		return
	}
	tx, ty, ok := mouse_world_tile(game)
	if !ok {
		debugf("place_build_block: mouse tile invalid")
		return
	}
	if !bounds_check(tx, ty) {
		debugf("place_build_block: OOB (%d,%d)", tx, ty)
		return
	}
	if game.ui.build_selected == .Tree_Grower && !world_has_terrain(&game.world, .Crafting_Bench) {
		// Show popup warning
		game.ui.popup_active = true
		game.ui.popup_text = "Requires a Crafting Bench placed"
		game.ui.popup_time = 2.2
		debugf("place_build_block: Tree_Grower requires bench")
		return
	}
	if !can_place_item_at(
		game,
		game.ui.build_selected,
		tx,
		ty,
	) {debugf("place_build_block: blocked at (%d,%d)", tx, ty);return}
	if game.world.entities[tx][ty] != INVALID_ENTITY {
		debugf("place_build_block: entity present at (%d,%d)", tx, ty)
		return
	}
	found := false
	for i in 0 ..< INV_MAX_SLOTS {
		stack := &game.inventory.slots[i]
		if stack.id == game.ui.build_selected && stack.count > 0 {
			if !place_item_terrain_at(
				game,
				stack.id,
				tx,
				ty,
			) {debugf("place_build_block: place failed");return}
			old := stack.count
			stack.count -= 1
			if stack.count == 0 {stack.id = .None}
			debugf(
				"Placed %s at (%d,%d) %d->%d",
				item_name(game.ui.build_selected),
				tx,
				ty,
				old,
				stack.count,
			)
			found = true
			break
		}
	}
	if !found {debugf("place_build_block: inventory stack not found for %s", item_name(game.ui.build_selected))}
	remaining := false
	for i in 0 ..< INV_MAX_SLOTS {
		if game.inventory.slots[i].id == game.ui.build_selected {remaining = true;break}
	}
	if !remaining {
		debugf(
			"place_build_block: no remaining of %s clearing selection",
			item_name(game.ui.build_selected),
		)
		game.ui.build_selected = .None
	}
}

// Menu input handling functions
handle_main_menu_input :: proc(game: ^Game_State) {
	// Menu navigation
	if rl.IsKeyPressed(rl.KeyboardKey.UP) {
		game.ui.menu_selection -= 1
		if game.ui.menu_selection < 0 {
			game.ui.menu_selection = 3 // Wrap to bottom
		}
	}
	if rl.IsKeyPressed(rl.KeyboardKey.DOWN) {
		game.ui.menu_selection += 1
		if game.ui.menu_selection > 3 {
			game.ui.menu_selection = 0 // Wrap to top
		}
	}

	// Menu selection
	if rl.IsKeyPressed(rl.KeyboardKey.ENTER) || rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
		switch game.ui.menu_selection {
		case 0:
			// New Game
			// Delete save file and start fresh
			os.remove("gnipahellir_save.dat")
			game.ui.main_menu_active = false
			start_new_game(game)
		case 1:
			// Load Game
			if load_game_state(game) {
				game.ui.main_menu_active = false
				// Audio already initialized at startup, don't re-initialize

				// CRITICAL FIX: Initialize camera position to center on loaded player
				game.camera.zoom = 1
				game.camera.target_x = cast(f32)(game.player.tile_x * TILE_SIZE + TILE_SIZE / 2)
				game.camera.target_y = cast(f32)(game.player.tile_y * TILE_SIZE + TILE_SIZE / 2)
			} else {
				// Show error popup
				game.ui.popup_active = true
				game.ui.popup_text = "No save file found!"
				game.ui.popup_time = 2.0
			}
		case 2:
			// Settings
			game.ui.settings_menu_active = true
		case 3:
			// Quit
			rl.CloseWindow()
		}
	}

	// ESC to quit from main menu
	if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
		rl.CloseWindow()
	}
}

handle_save_quit_dialog_input :: proc(game: ^Game_State) {
	// Dialog navigation
	if rl.IsKeyPressed(rl.KeyboardKey.LEFT) || rl.IsKeyPressed(rl.KeyboardKey.RIGHT) {
		game.ui.menu_selection = game.ui.menu_selection == 0 ? 1 : 0
	}

	// Dialog selection
	if rl.IsKeyPressed(rl.KeyboardKey.ENTER) || rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
		if game.ui.menu_selection == 0 { 	// Save and Quit
			if save_game_state(game) {
				save_persistent_stats(&game.stats)
				rl.CloseWindow()
			} else {
				game.ui.popup_active = true
				game.ui.popup_text = "Save failed!"
				game.ui.popup_time = 2.0
			}
		} else { 	// Cancel
			game.ui.save_quit_dialog_active = false
		}
	}

	// ESC to cancel
	if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
		game.ui.save_quit_dialog_active = false
	}
}

handle_settings_menu_input :: proc(game: ^Game_State) {
	// Settings navigation
	if rl.IsKeyPressed(rl.KeyboardKey.UP) {
		game.ui.menu_selection -= 1
		if game.ui.menu_selection < 0 {
			game.ui.menu_selection = 1 // Wrap to bottom
		}
	}
	if rl.IsKeyPressed(rl.KeyboardKey.DOWN) {
		game.ui.menu_selection += 1
		if game.ui.menu_selection > 1 {
			game.ui.menu_selection = 0 // Wrap to top
		}
	}

	// Settings selection
	if rl.IsKeyPressed(rl.KeyboardKey.ENTER) || rl.IsKeyPressed(rl.KeyboardKey.SPACE) {
		switch game.ui.menu_selection {
		case 0:
			// Back to Main Menu
			game.ui.settings_menu_active = false
			game.ui.menu_selection = 2 // Return to Settings option in main menu
		case 1:
			// Reset Stats
			os.remove("gnipahellir_stats.dat")
			game.ui.popup_active = true
			game.ui.popup_text = "Stats reset!"
			game.ui.popup_time = 2.0
		}
	}

	// ESC to go back
	if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
		game.ui.settings_menu_active = false
		game.ui.menu_selection = 2 // Return to Settings option in main menu
	}
}

// End of input helpers
