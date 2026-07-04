package game

// TEMPORARY diagnostic for the Phase 4 soak stall — delete before commit.

import "core:testing"
import "core:log"
import "core:os"

@(test)
diag_soak_states :: proc(t: ^testing.T) {
	gs := new(Game_State)
	game_state_init(gs)
	gs.delta_time = 1.0 / 60.0
	defer free(gs)

	gen_cave_level(&gs.world, 1)
	gs.enemies = {}
	gs.level_index = LEVEL_CAVE2
	spawn_builder(gs, 40)
	spawn_builder(gs, GRID_W - 40)
	spawn_builder(gs, GRID_W / 2)
	gs.player.pos = {6, 10}

	for frame in 0 ..< 10 * 3600 {
		update_enemies(gs)
		process_events(gs)
		eq_clear(&gs.events)

		if frame == 4 * 3600 - 600 {
			gs.debug_log.pos = 0   // capture only the stall window
			gs.debug_log.overflow = false
		}
		if frame == 4*3600 + 1200 {
			_ = os.write_entire_file("diag_action.log", gs.debug_log.buf[:gs.debug_log.pos])
		}

		if frame == 4 * 3600 {
			// Dump terrain around the stuck fetcher B#0 and its target
			e := &gs.enemies.data[0]
			bt := builder_tile(e)
			log.infof("B#0 grounded=%v vel=(%.2f,%.2f) path len=%d cursor=%d", e.grounded, e.vel.x, e.vel.y, e.nav.path.len, e.nav.path.cursor)
			for y in int(bt.y) - 10 ..= int(bt.y) + 4 {
				row: [32]u8
				n := 0
				for x in int(bt.x) - 12 ..= int(bt.x) + 12 {
					c: u8 = '?'
					if in_bounds(x, y) {
						#partial switch get_tile(&gs.world, x, y) {
						case .Void:       c = '.'
						case .Stone:      c = '#'
						case .Iron_Ore:   c = 'I'
						case .Silver_Ore: c = 'S'
						case .Gold_Ore:   c = 'G'
						case .Lava:       c = 'L'
						case .Magic_Lava: c = 'M'
						case .Wood:       c = 'W'
						case:             c = 'o'
						}
					}
					cell := [2]i32{i32(x), i32(y)}
					if cell == bt { c = 'B' }
					if cell == e.builder.target_tile { c = 'T' }
					row[n] = c
					n += 1
				}
				log.infof("y=%d  %s", y, string(row[:n]))
			}
		}

		if (frame + 1) % 3600 == 0 {
			log.infof("=== minute %d ===", (frame + 1) / 3600)
			for i in 0 ..< MAX_ENEMIES {
				if !gs.enemies.active[i] { continue }
				e := &gs.enemies.data[i]
				b := &e.builder
				log.infof("B#%d pos=(%.1f,%.1f) goal=%v resume=%v den_built=%v anchor=(%d,%d) step=%d carry=%v pocket=%d target=(%d,%d) has=%v stuck=%d/%.1f cooldown=%.1f",
					i, e.pos.x, e.pos.y, b.goal, b.resume, b.den_built,
					b.anchor.x, b.anchor.y, b.step, b.carry, b.pocket,
					b.target_tile.x, b.target_tile.y, b.has_target,
					b.stuck_count, b.stuck_timer, b.cooldown)
			}
		}
	}
}
