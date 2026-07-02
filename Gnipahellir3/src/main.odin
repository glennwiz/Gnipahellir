package game

import rl "vendor:raylib"

// Virtual resolution: the game always simulates and renders at this fixed size;
// the result is scaled (letterboxed) onto whatever the real window is.
SCREEN_W :: GRID_W * CELL_SIZE  // 1920
SCREEN_H :: GRID_H * CELL_SIZE  // 1080

// Maps virtual space onto the current window: uniform scale + letterbox offset.
screen_transform :: proc() -> (scale: f32, offset: [2]f32) {
    win_w := f32(rl.GetScreenWidth())
    win_h := f32(rl.GetScreenHeight())
    scale  = min(win_w / f32(SCREEN_W), win_h / f32(SCREEN_H))
    offset = {(win_w - f32(SCREEN_W)*scale) * 0.5, (win_h - f32(SCREEN_H)*scale) * 0.5}
    return
}

main :: proc() {
    rl.SetConfigFlags({.WINDOW_RESIZABLE})
    rl.InitWindow(1280, 720, "Gnipahellir III")
    rl.SetTargetFPS(60)

    target := rl.LoadRenderTexture(SCREEN_W, SCREEN_H)
    rl.SetTextureFilter(target.texture, .BILINEAR)

    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)

    // Spawn player on the surface, a few tiles left of the cave entrance
    gs.player.pos            = {f32(GRID_W/2) - 8, SURFACE_Y - PLAYER_H}
    gs.player.clothing_color = rl.BLUE
    gs.player.hair_color     = rl.ORANGE

    for !rl.WindowShouldClose() {
        if rl.IsKeyPressed(.F11) do rl.ToggleBorderlessWindowed()
        gs.delta_time = rl.GetFrameTime()
        game_update(gs)
        draw_game(gs, target)
    }

    flush_action_log(gs)
    rl.UnloadRenderTexture(target)
    rl.CloseWindow()
}
