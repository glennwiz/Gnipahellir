package game

import rl "vendor:raylib/v55"

update_input :: proc(gs: ^Game_State) {
    inp := &gs.input

    // Mouse in virtual-screen space (window -> virtual, letterbox-aware).  UI
    // hit-testing uses this directly; gameplay uses the camera-inverse below.
    mouse := rl.GetMousePosition()
    scale, offset := screen_transform()
    vx := (mouse.x - offset.x) / scale
    vy := (mouse.y - offset.y) / scale
    inp.mouse_screen = {vx, vy}

    // Mouse wheel zooms toward the player (game_camera stays clamped to bounds).
    if wheel := rl.GetMouseWheelMove(); wheel != 0 {
        gs.zoom = clamp(gs.zoom + wheel*ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
    }

    // World-space mouse: invert the (same) game camera.
    cam := game_camera(gs)
    inp.mouse_world = {
        (vx - cam.offset.x)/cam.zoom + cam.target.x,
        (vy - cam.offset.y)/cam.zoom + cam.target.y,
    }
    inp.mouse_tile = {
        clamp(i32(inp.mouse_world.x) / CELL_SIZE, 0, GRID_W - 1),
        clamp(i32(inp.mouse_world.y) / CELL_SIZE, 0, GRID_H - 1),
    }
    gs.ui.hover_tile = inp.mouse_tile

    // Title screen: any key or click advances to the menu.
    if gs.ui.show_title {
        if rl.GetKeyPressed() != .KEY_NULL ||
           rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
            gs.ui.show_title = false
            gs.ui.show_menu  = true
        }
        return
    }

    // Pause menu takes over all input while open: ESC (or Resume) closes it,
    // New Game / Save and Quit are queued as events for process_events to
    // handle. Nothing below this block runs — the sim is frozen (see
    // game_update), and clicks shouldn't reach mining/placement/inventory.
    if gs.ui.show_menu {
        if rl.IsKeyPressed(.ESCAPE) {
            gs.ui.show_menu = false
        }
        if rl.IsMouseButtonPressed(.LEFT) {
            switch menu_row_at_cursor(gs) {
            case 0: gs.ui.show_menu = false                                // Resume
            case 1: eq_push(&gs.events, Event{type = .New_Game_Request})
            case 2: eq_push(&gs.events, Event{type = .Quit_Request})
            }
        }
        return
    }

    inp.move_left  = rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)
    inp.move_right = rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT)
    inp.jump       = rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.SPACE)
    inp.mine       = rl.IsMouseButtonDown(.LEFT) && !cursor_over_ui(gs)
    inp.attack     = rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs)
    inp.interact   = rl.IsKeyPressed(.E)
    inp.drop_item  = rl.IsKeyPressed(.Q)

    // UI toggles
    if rl.IsKeyPressed(.TAB) {
        gs.ui.show_inventory = !gs.ui.show_inventory
    }
    if rl.IsKeyPressed(.C) {
        gs.ui.show_crafting = !gs.ui.show_crafting
    }
    if rl.IsKeyPressed(.B) {
        gs.ui.show_blueprint = !gs.ui.show_blueprint
    }

    // Slot selection: number keys 1-8 pick the first inventory row; pressing the
    // selected slot's key again deselects (-1 = nothing held).
    for key, i in ([8]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT}) {
        if rl.IsKeyPressed(key) {
            gs.player.inventory.selected = gs.player.inventory.selected == i ? -1 : i
        }
    }
    if rl.IsKeyPressed(.ESCAPE) {
        gs.player.inventory.selected = -1  // deselect
        gs.ui.show_menu = true
    }

    // Clicks on open UI panels
    if rl.IsMouseButtonPressed(.LEFT) {
        if gs.ui.show_inventory {
            if slot := slot_at_cursor(gs); slot >= 0 {
                if gs.player.inventory.selected == slot {
                    gs.player.inventory.selected = -1  // click the selected slot again to deselect
                } else {
                    gs.player.inventory.selected = slot
                }
                if is_blueprint(gs.player.inventory.slots[slot].item) {
                    gs.ui.show_blueprint = true  // clicking a blueprint opens its overlay
                }
            }
        }
        if gs.ui.show_crafting {
            if row := recipe_at_cursor(gs); row >= 0 {
                eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = i32(row)}})
            }
        }
    }

    // Right-click: place the selected item at the mouse tile
    if rl.IsMouseButtonPressed(.RIGHT) && !cursor_over_ui(gs) {
        eq_push(&gs.events, Event{type = .Place_Request, tile = gs.input.mouse_tile})
    }
    when GAME_DEBUG {
        if rl.IsKeyPressed(.F3) {
            gs.ui.show_debug = !gs.ui.show_debug
        }
        if rl.IsKeyPressed(.F1) {
            gs.debug.menu_open = !gs.debug.menu_open
        }
        inp.fly_up   = rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) || rl.IsKeyDown(.SPACE)
        inp.fly_down = rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)

        if gs.debug.menu_open && rl.IsMouseButtonPressed(.LEFT) {
            switch debug_menu_row_at_cursor(gs) {
            case 0: gs.debug.fly        = !gs.debug.fly
            case 1: gs.debug.ultra_wand = !gs.debug.ultra_wand
            case 2: debug_unlock_level_portals(gs)
            }
        }
    }
}
