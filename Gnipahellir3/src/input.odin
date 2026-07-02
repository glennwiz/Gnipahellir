package game

import rl "vendor:raylib"

update_input :: proc(gs: ^Game_State) {
    inp := &gs.input

    inp.move_left  = rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)
    inp.move_right = rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT)
    inp.jump       = rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.SPACE)
    inp.mine       = rl.IsMouseButtonDown(.LEFT)
    inp.interact   = rl.IsKeyPressed(.E)
    inp.drop_item  = rl.IsKeyPressed(.Q)

    // UI toggles
    if rl.IsKeyPressed(.TAB) {
        gs.ui.show_inventory = !gs.ui.show_inventory
    }
    if rl.IsKeyPressed(.F3) {
        gs.ui.show_debug = !gs.ui.show_debug
    }

    // Mouse tile position
    mouse := rl.GetMousePosition()
    inp.mouse_world = {mouse.x, mouse.y}
    inp.mouse_tile  = {
        i32(mouse.x) / CELL_SIZE,
        i32(mouse.y) / CELL_SIZE,
    }
    gs.ui.hover_tile = inp.mouse_tile
}
