package gnipahellir

import rl "vendor:raylib"

// Processes non-render interactions: pickups, debug placement commits, and
// world drops/placements that should occur outside the render pass.
update_interactions :: proc(game: ^Game_State, dt: f32) {
    _ = dt

    // Update popup lifetime
    if game.ui.popup_active {
        game.ui.popup_time -= dt
        if game.ui.popup_time <= 0 {
            game.ui.popup_active = false
        }
    }

    // Pickup moved to Movement event handling in process_events

    // --- Debug ghost placement commit/cancel ---
    if game.ui.debug_place_active {
        mouse := rl.GetMousePosition()
        if rl.IsMouseButtonPressed(rl.MouseButton(0)) && !point_in_any_window(game, cast(int)mouse.x, cast(int)mouse.y) {
            tx, ty, ok := mouse_world_tile(game)
            if ok {
                game.world.terrain[tx][ty] = game.ui.debug_place_terrain
            }
        }
        if rl.IsMouseButtonPressed(rl.MouseButton(1)) || rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
            game.ui.debug_place_active = false
        }
    }

    // --- World drop/placement handling when releasing a dragged inventory item outside UI ---
    if !rl.IsMouseButtonDown(rl.MouseButton(0)) && game.ui.dragging && game.ui.drag_from_inv {
        mouse := rl.GetMousePosition()
        if !point_in_any_window(game, cast(int)mouse.x, cast(int)mouse.y) {
            di := game.ui.drag_index
            if di >= 0 && di < INV_MAX_SLOTS {
                stack := &game.inventory.slots[di]
                if stack.id != .None && stack.count > 0 {
                    placed := false
                    // Attempt direct placement of one unit if placeable onto the tile under mouse
                    if item_is_placeable(stack.id) {
                        cam_origin_x := game.camera.target_x - cast(f32)WINDOW_WIDTH/2
                        cam_origin_y := game.camera.target_y - cast(f32)WINDOW_HEIGHT/2
                        world_px_x := mouse.x + cam_origin_x
                        world_px_y := mouse.y + cam_origin_y
                        tx := cast(int)(world_px_x) / TILE_SIZE
                        ty := cast(int)(world_px_y) / TILE_SIZE
                        if bounds_check(tx, ty) {
                            if stack.id == .Tree_Grower && !world_has_terrain(&game.world, .Crafting_Bench) {
                                // Show dependency popup
                                game.ui.popup_active = true
                                game.ui.popup_text = "Requires a Crafting Bench placed"
                                game.ui.popup_time = 2.2
                            } else if can_place_item_at(game, stack.id, tx, ty) {
                                if place_item_terrain_at(game, stack.id, tx, ty) {
                                    placed_id := stack.id
                                    old := stack.count
                                    stack.count -= 1
                                    if stack.count == 0 { stack.id = .None }
                                    debugf("Drag place %s at (%d,%d) %d->%d", item_name(placed_id), tx, ty, old, stack.count)
                                    placed = true
                                }
                            }
                        }
                    }
                    if !placed {
                        // Fallback: drop full remaining stack as ground items near player
                        debugf("Drag drop fallback for %s x%d", item_name(stack.id), stack.count)
                        dx := game.player.tile_x
                        dy := game.player.tile_y
                        dirs : [9][2]int = { {0,0},{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,1},{1,-1},{-1,-1} }
                        for d in dirs {
                            tx := dx + d[0]
                            ty := dy + d[1]
                            if !bounds_check(tx, ty) do continue
                            if game.world.items[tx][ty] == .None {
                                game.world.items[tx][ty] = stack.id
                                game.world.item_counts[tx][ty] = stack.count
                                debugf("Ground drop %s x%d at (%d,%d)", item_name(stack.id), stack.count, tx, ty)
                                stack.id = .None
                                stack.count = 0
                                break
                            }
                        }
                    }
                }
            }
        }
        game.ui.dragging = false
    }
}


