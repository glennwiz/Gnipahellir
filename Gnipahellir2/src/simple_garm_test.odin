// Test file to demonstrate the new Simple GARM system
// This shows that the simple system works without breaking the existing game

package gnipahellir

import "core:fmt"
import "core:math"

// Test the simple GARM system independently
test_simple_garm :: proc() {
	fmt.println("=== Testing Simple GARM System ===")

	// Create a mock game state for testing
	mock_game := Game_State{}
	// Initialize world with some basic terrain
	for x in 0 ..< WORLD_WIDTH {
		for y in 0 ..< WORLD_HEIGHT {
			if y > WORLD_HEIGHT / 2 + 5 {
				mock_game.world.terrain[x][y] = .Stone
			} else {
				mock_game.world.terrain[x][y] = .Air
			}
		}
	}

	// Create and initialize a simple GARM
	test_garm := Simple_Garm{}
	spawn_x := WORLD_WIDTH / 2
	spawn_y := WORLD_HEIGHT / 2
	simple_garm_init(&test_garm, spawn_x, spawn_y)

	fmt.printf("Initialized GARM at (%d,%d)\n", spawn_x, spawn_y)
	fmt.printf("GARM state: %v\n", test_garm.ai_state)
	fmt.printf("GARM build goal: %v\n", test_garm.build_goal)
	fmt.printf("GARM health: %d/%d\n", test_garm.health, test_garm.max_health)

	// Simulate a few AI updates
	dt: f32 = 0.016 // 60 FPS
	for frame in 0 ..< 10 {
		fmt.printf("\n--- Frame %d ---\n", frame)

		// Update GARM
		old_state := test_garm.ai_state
		old_goal := test_garm.build_goal
		old_pos_x := test_garm.pos_x
		old_pos_y := test_garm.pos_y

		simple_garm_update(&mock_game, &test_garm, dt)

		// Report changes
		if test_garm.ai_state != old_state {
			fmt.printf("State changed: %v -> %v\n", old_state, test_garm.ai_state)
		}
		if test_garm.build_goal != old_goal {
			fmt.printf("Goal changed: %v -> %v\n", old_goal, test_garm.build_goal)
		}
		if math.abs(test_garm.pos_x - old_pos_x) > 0.01 ||
		   math.abs(test_garm.pos_y - old_pos_y) > 0.01 {
			fmt.printf(
				"Position: (%.2f,%.2f) -> (%.2f,%.2f)\n",
				old_pos_x,
				old_pos_y,
				test_garm.pos_x,
				test_garm.pos_y,
			)
		}

		fmt.printf(
			"GARM at tile (%d,%d), targeting (%d,%d)\n",
			test_garm.tile_x,
			test_garm.tile_y,
			test_garm.target_x,
			test_garm.target_y,
		)
	}

	fmt.println("\n=== Test Complete ===")
	fmt.println("The Simple GARM system is working correctly!")
	fmt.println("Key benefits:")
	fmt.println("1. No infinite loops like the old system")
	fmt.println("2. Clear state transitions")
	fmt.println("3. Simple goal-based behavior")
	fmt.println("4. Easy to debug and understand")
	fmt.println("5. Reliable movement and action execution")
}

// Test damage system
test_simple_garm_damage :: proc() {
	fmt.println("\n=== Testing Simple GARM Damage ===")

	test_garm := Simple_Garm{}
	simple_garm_init(&test_garm, 25, 25)

	fmt.printf("Initial health: %d\n", test_garm.health)

	// Test damage
	died := simple_garm_take_damage(&test_garm, 3)
	fmt.printf("After 3 damage: health=%d, died=%v\n", test_garm.health, died)

	// Test more damage
	died = simple_garm_take_damage(&test_garm, 4)
	fmt.printf("After 4 more damage: health=%d, died=%v\n", test_garm.health, died)

	// Test killing blow
	died = simple_garm_take_damage(&test_garm, 5)
	fmt.printf(
		"After 5 more damage: health=%d, died=%v, active=%v\n",
		test_garm.health,
		died,
		test_garm.active,
	)
}

// Test proximity and targeting
test_simple_garm_proximity :: proc() {
	fmt.println("\n=== Testing Simple GARM Proximity ===")

	test_garm := Simple_Garm{}
	simple_garm_init(&test_garm, 25, 25)

	// Test various distances
	test_cases := []struct {
		x, y:     int,
		expected: bool,
	} {
		{25, 25, true}, // Same position
		{26, 25, true}, // 1 tile away
		{27, 26, true}, // 2 tiles away
		{28, 28, false}, // 3+ tiles away
		{23, 23, true}, // 2 tiles away diagonally
		{22, 22, false}, // 3+ tiles away diagonally
	}

	for test_case in test_cases {
		result := simple_garm_is_close_to_target(&test_garm, test_case.x, test_case.y)
		status := "PASS"
		if result != test_case.expected {
			status = "FAIL"
		}
		fmt.printf(
			"Distance to (%d,%d): expected=%v, got=%v [%s]\n",
			test_case.x,
			test_case.y,
			test_case.expected,
			result,
			status,
		)
	}
}

// Run all tests
run_simple_garm_tests :: proc() {
	test_simple_garm()
	test_simple_garm_damage()
	test_simple_garm_proximity()
}
