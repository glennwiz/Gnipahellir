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

    // Settings screen: volume sliders + key rebinding. ESC returns to the menu.
    if gs.ui.show_settings {
        update_settings_input(gs)
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
            case 1: gs.ui.show_menu = false; gs.ui.show_settings = true    // Settings
            case 2: eq_push(&gs.events, Event{type = .New_Game_Request})
            case 3: eq_push(&gs.events, Event{type = .Quit_Request})
            }
        }
        return
    }

    // Death screen: the fallen give no orders. After a short beat, ENTER or a
    // click carves a new hero (roguelike — the old run is ash). ESC still
    // reaches the pause menu for Save and Quit.
    if gs.player.dead {
        if rl.IsKeyPressed(.ESCAPE) {
            gs.ui.show_menu = true
        } else if gs.player.death_timer > DEATH_INPUT_DELAY &&
           (rl.IsKeyPressed(.ENTER) || rl.IsMouseButtonPressed(.LEFT)) {
            eq_push(&gs.events, Event{type = .New_Game_Request})
        }
        return
    }

    // Rebindable keys come from the bindings table (settings screen); arrows
    // and space stay as fixed movement/jump alternates.
    bind := gs.bindings
    inp.move_left  = rl.IsKeyDown(bind[.Move_Left])  || rl.IsKeyDown(.LEFT)
    inp.move_right = rl.IsKeyDown(bind[.Move_Right]) || rl.IsKeyDown(.RIGHT)
    inp.jump       = rl.IsKeyPressed(bind[.Jump]) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.SPACE)
    inp.mine       = rl.IsMouseButtonDown(.LEFT) && !cursor_over_ui(gs)
    inp.attack     = rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs)
    inp.interact   = rl.IsKeyPressed(bind[.Interact])
    inp.drop_item  = rl.IsKeyPressed(bind[.Drop_Item])

    // UI toggles
    if rl.IsKeyPressed(bind[.Inventory]) {
        gs.ui.show_inventory = !gs.ui.show_inventory
    }
    if rl.IsKeyPressed(bind[.Crafting]) {
        gs.ui.show_crafting = !gs.ui.show_crafting
    }
    if rl.IsKeyPressed(bind[.Blueprint]) {
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

    // Right-click in the open bag equips the item; on an equip box, unequips.
    if rl.IsMouseButtonPressed(.RIGHT) && gs.ui.show_inventory {
        if slot := slot_at_cursor(gs); slot >= 0 {
            eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = i32(slot)}})
        } else if es := equip_slot_at_cursor(gs); es != .None {
            eq_push(&gs.events, Event{type = .Unequip_Request, payload = {int_val = i32(es)}})
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
        inp.fly_up   = rl.IsKeyDown(bind[.Jump]) || rl.IsKeyDown(.UP) || rl.IsKeyDown(.SPACE)
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

// Settings screen input: slider drags, bind-row clicks, and key capture.
// Edits apply live (audio_play reads the volume fields at play time) and
// persist via save_settings whenever something changes.
update_settings_input :: proc(gs: ^Game_State) {
    // Rebind capture: the next key becomes the binding; ESC cancels.
    if gs.ui.settings_capture >= 0 {
        k := rl.GetKeyPressed()
        if k == .ESCAPE {
            gs.ui.settings_capture = -1
        } else if k != .KEY_NULL {
            a := Action(gs.ui.settings_capture)
            // If the key already drives another action, hand that action the
            // old key — a duplicate could strand the player without a control.
            for other in Action {
                if other != a && gs.bindings[other] == k {
                    gs.bindings[other] = gs.bindings[a]
                }
            }
            gs.bindings[a] = k
            gs.ui.settings_capture = -1
            _ = save_settings(gs)
        }
        return
    }

    if rl.IsKeyPressed(.ESCAPE) {
        gs.ui.show_settings = false
        gs.ui.show_menu     = true
        _ = save_settings(gs)
        return
    }

    if rl.IsMouseButtonPressed(.LEFT) {
        gs.ui.settings_drag = settings_slider_at_cursor(gs)
        if row := settings_bind_at_cursor(gs); row >= 0 {
            gs.ui.settings_capture = row
        }
    }

    // A started drag follows the cursor while the button is held.
    if gs.ui.settings_drag >= 0 {
        if rl.IsMouseButtonDown(.LEFT) {
            v := clamp((gs.input.mouse_screen.x - f32(SET_SLIDER_X)) / f32(SET_SLIDER_W), 0, 1)
            switch gs.ui.settings_drag {
            case 0: gs.audio.master_volume = v
            case 1: gs.audio.sfx_volume    = v
            case 2: gs.audio.music_volume  = v
            }
        } else {
            gs.ui.settings_drag = -1
            audio_play(&gs.audio, .Pickup)  // preview the new loudness
            _ = save_settings(gs)
        }
    }
}
