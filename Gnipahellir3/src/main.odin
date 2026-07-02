package game

import rl "vendor:raylib"

SCREEN_W :: GRID_W * CELL_SIZE  // 1920
SCREEN_H :: GRID_H * CELL_SIZE  // 1080

main :: proc() {
    rl.InitWindow(SCREEN_W, SCREEN_H, "Gnipahellir III")
    rl.SetTargetFPS(60)
    // rl.ToggleFullscreen()  // uncomment for real fullscreen

    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)

    // Spawn player on the surface, a few tiles left of the cave entrance
    gs.player.pos            = {f32(GRID_W/2) - 8, SURFACE_Y - PLAYER_H}
    gs.player.clothing_color = rl.BLUE
    gs.player.hair_color     = rl.ORANGE

    for !rl.WindowShouldClose() {
        gs.delta_time = rl.GetFrameTime()
        game_update(gs)
        draw_game(gs)
    }

    flush_action_log(gs)
    rl.CloseWindow()
}
