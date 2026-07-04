package game

import rl "vendor:raylib/v55"

update_input :: proc(gs: ^Game_State) {
    inp := &gs.input

    // Mouse tile position first (window space -> virtual space, letterbox-aware);
    // everything below hit-tests against the fresh position.
    mouse := rl.GetMousePosition()
    scale, offset := screen_transform()
    vx := (mouse.x - offset.x) / scale
    vy := (mouse.y - offset.y) / scale
    inp.mouse_world = {vx, vy}
    inp.mouse_tile  = {
        clamp(i32(vx) / CELL_SIZE, 0, GRID_W - 1),
        clamp(i32(vy) / CELL_SIZE, 0, GRID_H - 1),
    }
    gs.ui.hover_tile = inp.mouse_tile

    inp.move_left  = rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)
    inp.move_right = rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT)
    inp.jump       = rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.SPACE)
    inp.mine       = rl.IsMouseButtonDown(.LEFT) && !cursor_over_ui(gs)
    inp.interact   = rl.IsKeyPressed(.E)
    inp.drop_item  = rl.IsKeyPressed(.Q)

    // UI toggles
    if rl.IsKeyPressed(.TAB) {
        gs.ui.show_inventory = !gs.ui.show_inventory
    }
    if rl.IsKeyPressed(.C) {
        gs.ui.show_crafting = !gs.ui.show_crafting
    }

    // Slot selection: number keys 1-8 pick the first inventory row
    for key, i in ([8]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT}) {
        if rl.IsKeyPressed(key) do gs.player.inventory.selected = i
    }

    // Clicks on open UI panels
    if rl.IsMouseButtonPressed(.LEFT) {
        if gs.ui.show_inventory {
            if slot := slot_at_cursor(gs); slot >= 0 {
                gs.player.inventory.selected = slot
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
            case 0: gs.debug.fly = !gs.debug.fly
            }
        }
    }
}
