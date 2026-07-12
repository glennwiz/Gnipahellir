package game

import rl "vendor:raylib/v55"
import "core:fmt"
import "core:math"

// ─── UI Layout (virtual-resolution pixels) ────────────────────────────────────
//
//  Constants shared by draw procs here and hit-testing in input.odin.

INV_COLS :: 8
INV_ROWS :: 3
SLOT_PX  :: 44

// The inventory is a centered popup: header, then a paperdoll column of
// equip slots on the left and the bag grid to its right.
INV_PANEL_W :: 24 + 100 + 16 + INV_COLS*SLOT_PX + 24
INV_PANEL_H :: 450
INV_PANEL_X :: (SCREEN_W - INV_PANEL_W) / 2
INV_PANEL_Y :: (SCREEN_H - INV_PANEL_H) / 2
INV_X       :: INV_PANEL_X + 140                // bag grid origin
INV_Y       :: INV_PANEL_Y + 70

// Crafting: tall list right of the inventory popup (28 recipes needs the room).
CRAFT_X     :: INV_PANEL_X + INV_PANEL_W + 24
CRAFT_Y     :: 160
CRAFT_W     :: 430
CRAFT_ROW_H :: 26

// Equipment boxes — the paperdoll column (weapon, armor head→feet, charm).
EQUIP_X    :: INV_PANEL_X + 24
EQUIP_Y    :: INV_PANEL_Y + 70
EQUIP_STEP :: 50

@(rodata)
equip_slot_order := [7]Equip_Slot{.Weapon, .Head, .Chest, .Hands, .Legs, .Feet, .Charm}

@(rodata)
equip_slot_labels := [7]cstring{"WPN", "HEAD", "CHEST", "HANDS", "LEGS", "FEET", "CHM"}

// Blueprint overlay — centered panel.
BP_W :: 540
BP_H :: 360
BP_X :: (SCREEN_W - BP_W) / 2
BP_Y :: (SCREEN_H - BP_H) / 2

panel_bg     :: rl.Color{15, 15, 25, 230}
panel_border :: rl.Color{90, 90, 120, 255}
slot_bg      :: rl.Color{35, 35, 50, 255}
text_dim     :: rl.Color{140, 140, 150, 255}

// Norse palette — shared by the title, pause menu, settings and death screens.
NORSE_GOLD     :: rl.Color{200, 150, 70, 255}
NORSE_GOLD_HOT :: rl.Color{255, 220, 140, 255}
NORSE_PANEL    :: rl.Color{24, 20, 16, 235}
NORSE_ROW      :: rl.Color{30, 26, 20, 225}
NORSE_ROW_HOT  :: rl.Color{62, 46, 26, 235}
NORSE_BORDER   :: rl.Color{115, 88, 52, 255}

// ─── Title Screen (boot only; any key → menu) ─────────────────────────────────
//
//  Fully procedural: a slowly rotating ring of Elder Futhark runes spelling
//  GNIPAHELLIR, drifting embers, and the glowing title.  Animates on wall
//  clock (rl.GetTime) because the sim — and gs.elapsed_time — is frozen
//  while the title is up.

// Rune strokes in a unit box (y down), up to 4 segments of {x1,y1,x2,y2}.
Rune_Glyph :: struct {
    n:   int,
    seg: [4][4]f32,
}

@(rodata)
title_runes := [11]Rune_Glyph{  // G N I P A H E L L I R
    { 2, {{0.0, 0, 1.0, 1}, {1.0, 0, 0.0, 1}, {}, {}} },                                  // Gebo
    { 2, {{0.5, 0, 0.5, 1}, {0.2, 0.62, 0.8, 0.38}, {}, {}} },                            // Nauthiz
    { 1, {{0.5, 0, 0.5, 1}, {}, {}, {}} },                                                // Isa
    { 4, {{0.3, 0, 0.3, 1}, {0.3, 0, 0.7, 0.3}, {0.3, 1, 0.7, 0.7}, {0.7, 0.3, 0.7, 0.7}} }, // Perthro
    { 3, {{0.3, 0, 0.3, 1}, {0.3, 0.08, 0.8, 0.35}, {0.3, 0.42, 0.8, 0.69}, {}} },        // Ansuz
    { 3, {{0.25, 0, 0.25, 1}, {0.75, 0, 0.75, 1}, {0.25, 0.35, 0.75, 0.6}, {}} },         // Hagalaz
    { 4, {{0.2, 0, 0.2, 1}, {0.8, 0, 0.8, 1}, {0.2, 0, 0.5, 0.45}, {0.5, 0.45, 0.8, 0}} },// Ehwaz
    { 2, {{0.4, 0, 0.4, 1}, {0.4, 0, 0.8, 0.4}, {}, {}} },                                // Laguz
    { 2, {{0.4, 0, 0.4, 1}, {0.4, 0, 0.8, 0.4}, {}, {}} },                                // Laguz
    { 1, {{0.5, 0, 0.5, 1}, {}, {}, {}} },                                                // Isa
    { 4, {{0.3, 0, 0.3, 1}, {0.3, 0, 0.7, 0.22}, {0.7, 0.22, 0.3, 0.5}, {0.3, 0.5, 0.75, 1}} }, // Raidho
}

// One glyph, rotated about its own center, glow pass under the core stroke.
draw_title_rune :: proc(g: Rune_Glyph, cx, cy, size, rot: f32, col: rl.Color) {
    cr := math.cos(rot)
    sr := math.sin(rot)
    for k in 0 ..< g.n {
        p1 := [2]f32{g.seg[k][0] - 0.5, g.seg[k][1] - 0.5} * size
        p2 := [2]f32{g.seg[k][2] - 0.5, g.seg[k][3] - 0.5} * size
        a  := rl.Vector2{cx + p1.x*cr - p1.y*sr, cy + p1.x*sr + p1.y*cr}
        b  := rl.Vector2{cx + p2.x*cr - p2.y*sr, cy + p2.x*sr + p2.y*cr}
        glow := col
        glow.a = col.a / 4
        rl.DrawLineEx(a, b, 8, glow)
        rl.DrawLineEx(a, b, 3, col)
    }
}

draw_title :: proc(gs: ^Game_State) {
    t  := f32(rl.GetTime())
    cx := f32(SCREEN_W) / 2
    cy := f32(SCREEN_H) / 2 - 40

    // Night backdrop, warming toward a fire-lit horizon.
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{8, 8, 14, 255})
    rl.DrawRectangleGradientV(0, SCREEN_H*2/3, SCREEN_W, SCREEN_H/3,
        rl.Color{8, 8, 14, 255}, rl.Color{42, 20, 10, 255})
    // The cave mouth smolders below the horizon.
    rl.DrawCircleGradient(i32(cx), SCREEN_H + 100, 420,
        rl.Color{255, 120, 30, 70}, rl.Color{0, 0, 0, 0})

    // Embers: stateless — each i hashes to a column/speed, y wraps on time.
    for i in 0 ..< 70 {
        h     := whash(u32(i) * 7919 + 13)
        speed := 18 + f32(h % 70)
        x     := f32(h % SCREEN_W) + math.sin(t*1.3 + f32(i)) * 16
        y     := f32(SCREEN_H) - math.mod(t*speed + f32(h % SCREEN_H), f32(SCREEN_H + 60))
        rl.DrawRectangle(i32(x), i32(y), 3, 3,
            rl.Color{255, u8(110 + h % 90), 40, u8(70 + h % 130)})
    }

    // The rune ring: GNIPAHELLIR in Elder Futhark, wheeling slowly, each
    // glyph breathing on its own phase.  Faint rings frame the band.
    ring_col := rl.Color{200, 150, 70, 45}
    radius   := f32(310)
    rl.DrawRing({cx, cy}, radius - 54, radius - 50, 0, 360, 96, ring_col)
    rl.DrawRing({cx, cy}, radius + 50, radius + 54, 0, 360, 96, ring_col)
    for g, i in title_runes {
        ang    := t*0.12 + f32(i) * (2*math.PI / f32(len(title_runes)))
        rx     := cx + math.cos(ang) * radius
        ry     := cy + math.sin(ang) * radius
        breath := 0.55 + 0.45*math.sin(t*1.7 + f32(i)*2.4)
        col    := rl.Color{255, 200, 110, u8(120 + 135*breath)}
        draw_title_rune(g, rx, ry, 40, ang + math.PI/2, col)
    }

    center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
        tw := rl.MeasureText(text, size)
        rl.DrawText(text, (i32(SCREEN_W) - tw) / 2, y, size, color)
    }

    // Title, haloed in ember-light.
    ty     := i32(cy) - 70
    pulse  := 0.6 + 0.4*math.sin(t*1.5)
    center_text("GNIPAHELLIR", ty + 4, 110, rl.Color{120, 40, 10, u8(140 * pulse)})
    center_text("GNIPAHELLIR", ty - 4, 110, rl.Color{120, 40, 10, u8(140 * pulse)})
    center_text("GNIPAHELLIR", ty, 110, rl.Color{240, 205, 130, 255})
    center_text("— III —", ty + 120, 30, rl.Color{200, 150, 70, 255})
    center_text("The hound howls before the cliff-cave", ty + 170, 20, text_dim)

    prompt := u8(120 + 135*(0.5 + 0.5*math.sin(t*2.5)))
    center_text("PRESS ANY KEY", SCREEN_H - 130, 26, rl.Color{255, 240, 180, prompt})
}

// ─── Pause / Main Menu (ESC, or shown first at startup) ───────────────────────

MENU_ROWS  :: 4   // row 0: Resume; 1: Settings; 2: New Game; 3: Save and Quit
MENU_W     :: 360
MENU_ROW_H :: 56
MENU_X     :: (SCREEN_W - MENU_W) / 2
MENU_Y     :: (SCREEN_H - MENU_ROWS*MENU_ROW_H) / 2

@(rodata)
menu_labels := [MENU_ROWS]cstring{"Resume", "Settings", "New Game", "Save and Quit"}

// Menu row under the cursor, or -1.
menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < MENU_X || mx >= MENU_X + MENU_W do return -1
    r := int((my - MENU_Y) / MENU_ROW_H)
    if my < MENU_Y || r >= MENU_ROWS do return -1
    return r
}

draw_menu :: proc(gs: ^Game_State) {
    t := f32(rl.GetTime())

    // Dim the world, deepen the top and bottom edges.
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{8, 6, 10, 215})
    rl.DrawRectangleGradientV(0, 0, SCREEN_W, 220, rl.Color{0, 0, 0, 180}, rl.Color{0, 0, 0, 0})
    rl.DrawRectangleGradientV(0, SCREEN_H - 220, SCREEN_W, 220, rl.Color{0, 0, 0, 0}, rl.Color{0, 0, 0, 180})

    cx := f32(SCREEN_W) / 2
    cy := f32(SCREEN_H) / 2

    // The rune wheel turns slowly behind the menu, framed by faint rings.
    radius := f32(350)
    ring_col := rl.Color{NORSE_GOLD.r, NORSE_GOLD.g, NORSE_GOLD.b, 35}
    rl.DrawRing({cx, cy}, radius - 46, radius - 42, 0, 360, 96, ring_col)
    rl.DrawRing({cx, cy}, radius + 42, radius + 46, 0, 360, 96, ring_col)
    for g, i in title_runes {
        ang    := t*0.1 + f32(i) * (2*math.PI / f32(len(title_runes)))
        rx     := cx + math.cos(ang) * radius
        ry     := cy + math.sin(ang) * radius
        breath := 0.5 + 0.5*math.sin(t*1.4 + f32(i)*2.1)
        col    := rl.Color{NORSE_GOLD.r, NORSE_GOLD.g, NORSE_GOLD.b, u8(60 + 90*breath)}
        draw_title_rune(g, rx, ry, 30, ang + math.PI/2, col)
    }

    center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
        tw := rl.MeasureText(text, size)
        rl.DrawText(text, (i32(SCREEN_W) - tw) / 2, y, size, color)
    }

    // Ember-haloed title above the buttons.
    pulse := 0.6 + 0.4*math.sin(t*1.5)
    center_text("GNIPAHELLIR", MENU_Y - 136, 64, rl.Color{120, 40, 10, u8(140 * pulse)})
    center_text("GNIPAHELLIR", MENU_Y - 140, 64, rl.Color{240, 205, 130, 255})

    hover := menu_row_at_cursor(gs)
    for i in 0 ..< MENU_ROWS {
        y       := i32(MENU_Y + i*MENU_ROW_H)
        hovered := i == hover
        rl.DrawRectangle(MENU_X, y, MENU_W, MENU_ROW_H - 6, hovered ? NORSE_ROW_HOT : NORSE_ROW)
        rl.DrawRectangleLinesEx({MENU_X, f32(y), MENU_W, MENU_ROW_H - 6}, 2,
            hovered ? NORSE_GOLD_HOT : NORSE_BORDER)
        tw := rl.MeasureText(menu_labels[i], 22)
        rl.DrawText(menu_labels[i], MENU_X + (MENU_W - tw)/2, y + 13, 22,
            hovered ? NORSE_GOLD_HOT : rl.Color{225, 215, 195, 255})

        // Gebo marks flank the chosen row.
        if hovered {
            ry := f32(y) + (MENU_ROW_H - 6)/2
            draw_title_rune(title_runes[0], f32(MENU_X) - 34, ry, 18, 0, NORSE_GOLD_HOT)
            draw_title_rune(title_runes[0], f32(MENU_X + MENU_W) + 34, ry, 18, 0, NORSE_GOLD_HOT)
        }
    }

    center_text("The hound stirs beneath the cliff", MENU_Y + MENU_ROWS*MENU_ROW_H + 40,
        18, rl.Color{150, 130, 110, 255})
}

// ─── Settings Screen (volumes + key binds) ────────────────────────────────────

SET_W        :: 640
SET_ROW_H    :: 44
SET_X        :: (SCREEN_W - SET_W) / 2
SET_Y        :: (SCREEN_H - 684) / 2   // 684 = the panel's content height (SET_H)
SET_VOL_Y    :: SET_Y + 100                       // first volume slider row
SET_BIND_Y   :: SET_VOL_Y + 3*SET_ROW_H + 60      // first key-bind row
SET_H        :: SET_BIND_Y + len(Action)*SET_ROW_H + 40 - SET_Y
SET_SLIDER_X :: SET_X + 280
SET_SLIDER_W :: 300

@(rodata)
action_labels := [Action]cstring{
    .Move_Left  = "Move Left",
    .Move_Right = "Move Right",
    .Jump       = "Jump",
    .Interact   = "Interact",
    .Drop_Item  = "Drop Item",
    .Inventory  = "Inventory",
    .Crafting   = "Crafting",
    .Blueprint  = "Blueprint",
}

@(rodata)
volume_labels := [3]cstring{"Master", "Effects", "Music"}

// Volume slider row under the cursor, or -1.
settings_slider_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < SET_SLIDER_X - 10 || mx >= SET_SLIDER_X + SET_SLIDER_W + 10 do return -1
    for i in 0 ..< 3 {
        y := i32(SET_VOL_Y + i*SET_ROW_H)
        if my >= y && my < y + SET_ROW_H - 12 do return i
    }
    return -1
}

// Key-bind row under the cursor, or -1.
settings_bind_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < SET_X + 20 || mx >= SET_X + SET_W - 20 do return -1
    r := int((my - SET_BIND_Y) / SET_ROW_H)
    if my < SET_BIND_Y || r >= len(Action) do return -1
    return r
}

draw_settings :: proc(gs: ^Game_State) {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{8, 6, 10, 215})
    rl.DrawRectangle(SET_X, SET_Y, SET_W, SET_H, NORSE_PANEL)
    rl.DrawRectangleLinesEx({SET_X, SET_Y, SET_W, SET_H}, 2, NORSE_BORDER)
    rl.DrawText("SETTINGS", SET_X + 24, SET_Y + 20, 30, NORSE_GOLD_HOT)
    rl.DrawText("[ESC] back", SET_X + SET_W - 110, SET_Y + 28, 14, NORSE_GOLD)
    // Gold rule under the header.
    rl.DrawRectangle(SET_X + 24, SET_Y + 58, SET_W - 48, 2, NORSE_BORDER)

    // Volume sliders
    rl.DrawText("VOLUME", SET_X + 24, SET_VOL_Y - 30, 14, NORSE_GOLD)
    volumes := [3]f32{gs.audio.master_volume, gs.audio.sfx_volume, gs.audio.music_volume}
    for i in 0 ..< 3 {
        y := i32(SET_VOL_Y + i*SET_ROW_H)
        rl.DrawText(volume_labels[i], SET_X + 24, y + 6, 20, rl.Color{225, 215, 195, 255})

        bar_h := i32(SET_ROW_H - 22)
        rl.DrawRectangle(SET_SLIDER_X, y + 4, SET_SLIDER_W, bar_h, NORSE_ROW)
        fill := i32(f32(SET_SLIDER_W) * volumes[i])
        rl.DrawRectangle(SET_SLIDER_X, y + 4, fill, bar_h, NORSE_GOLD)
        hover := settings_slider_at_cursor(gs) == i || gs.ui.settings_drag == i
        rl.DrawRectangleLines(SET_SLIDER_X, y + 4, SET_SLIDER_W, bar_h,
            hover ? NORSE_GOLD_HOT : NORSE_BORDER)

        pct_buf: [8]u8
        fmt.bprintf(pct_buf[:7], "%d%%", int(volumes[i]*100 + 0.5))
        rl.DrawText(cstring(raw_data(pct_buf[:])), SET_SLIDER_X + SET_SLIDER_W + 14, y + 6, 20, NORSE_GOLD)
    }

    // Key binds
    rl.DrawText("KEY BINDS", SET_X + 24, SET_BIND_Y - 30, 14, NORSE_GOLD)
    hover_bind := settings_bind_at_cursor(gs)
    for a, i in Action {
        y := i32(SET_BIND_Y + i*SET_ROW_H)
        if i == hover_bind {
            rl.DrawRectangle(SET_X + 20, y, SET_W - 40, SET_ROW_H - 8, NORSE_ROW_HOT)
        }
        rl.DrawText(action_labels[a], SET_X + 36, y + 8, 20, rl.Color{225, 215, 195, 255})

        // Key chip on the right — or the capture prompt while rebinding.
        if gs.ui.settings_capture == i {
            rl.DrawText("PRESS A KEY...", SET_X + SET_W - 220, y + 8, 20, NORSE_GOLD_HOT)
        } else {
            key_buf: [24]u8
            fmt.bprintf(key_buf[:23], "%v", gs.bindings[a])
            key_str := cstring(raw_data(key_buf[:]))
            kw := rl.MeasureText(key_str, 20)
            kx := i32(SET_X + SET_W - 60) - kw
            rl.DrawRectangle(kx - 10, y + 2, kw + 20, SET_ROW_H - 12, NORSE_ROW)
            rl.DrawRectangleLines(kx - 10, y + 2, kw + 20, SET_ROW_H - 12, NORSE_BORDER)
            rl.DrawText(key_str, kx, y + 8, 20, NORSE_GOLD_HOT)
        }
    }
}

// ─── Debug Menu (F1, debug builds only) ───────────────────────────────────────

DBG_MENU_X     :: 24
DBG_MENU_Y     :: 80
DBG_MENU_W     :: 200
DBG_MENU_ROW_H :: 24
DBG_MENU_ROWS  :: 3   // row 0: fly mode; row 1: ultra wand; row 2: activate portals

// Menu row under the cursor, or -1.
debug_menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < DBG_MENU_X || mx >= DBG_MENU_X + DBG_MENU_W do return -1
    r := int((my - DBG_MENU_Y) / DBG_MENU_ROW_H)
    if my < DBG_MENU_Y || r >= DBG_MENU_ROWS do return -1
    return r
}

draw_debug_menu :: proc(gs: ^Game_State) {
    h := i32(DBG_MENU_ROWS * DBG_MENU_ROW_H)
    rl.DrawRectangle(DBG_MENU_X - 6, DBG_MENU_Y - 26, DBG_MENU_W + 12, h + 34, panel_bg)
    rl.DrawRectangleLines(DBG_MENU_X - 6, DBG_MENU_Y - 26, DBG_MENU_W + 12, h + 34, panel_border)
    rl.DrawText("DEBUG (F1)", DBG_MENU_X, DBG_MENU_Y - 20, 10, rl.YELLOW)

    fly_col := gs.debug.fly ? rl.GREEN : text_dim
    rl.DrawText(gs.debug.fly ? cstring("Fly mode: ON") : cstring("Fly mode: OFF"),
        DBG_MENU_X, DBG_MENU_Y + 7, 10, fly_col)

    uw_col := gs.debug.ultra_wand ? rl.GREEN : text_dim
    rl.DrawText(gs.debug.ultra_wand ? cstring("Ultra wand: ON") : cstring("Ultra wand: OFF"),
        DBG_MENU_X, DBG_MENU_Y + DBG_MENU_ROW_H + 7, 10, uw_col)

    // Action row (not a toggle): click to open this level's gated portals.
    rl.DrawText("Activate portals >", DBG_MENU_X, DBG_MENU_Y + 2*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)

    if r := debug_menu_row_at_cursor(gs); r >= 0 {
        rl.DrawRectangleLines(DBG_MENU_X - 2, DBG_MENU_Y + i32(r)*DBG_MENU_ROW_H + 1,
            DBG_MENU_W + 4, DBG_MENU_ROW_H - 2, rl.YELLOW)
    }
}

// True when the cursor is over an open UI panel (blocks mining/placing).
cursor_over_ui :: proc(gs: ^Game_State) -> bool {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    when GAME_DEBUG {
        if gs.debug.menu_open &&
           mx >= DBG_MENU_X - 6 && mx < DBG_MENU_X + DBG_MENU_W + 6 &&
           my >= DBG_MENU_Y - 26 && my < DBG_MENU_Y + DBG_MENU_ROWS*DBG_MENU_ROW_H + 8 {
            return true
        }
    }
    if gs.ui.show_inventory &&
       mx >= INV_PANEL_X && mx < INV_PANEL_X + INV_PANEL_W &&
       my >= INV_PANEL_Y && my < INV_PANEL_Y + INV_PANEL_H {
        return true
    }
    if gs.ui.show_crafting &&
       mx >= CRAFT_X && mx < CRAFT_X + CRAFT_W &&
       my >= CRAFT_Y && my < CRAFT_Y + i32(len(recipe_table))*CRAFT_ROW_H + 8 {
        return true
    }
    if gs.ui.show_blueprint &&
       mx >= BP_X && mx < BP_X + BP_W &&
       my >= BP_Y && my < BP_Y + BP_H {
        return true
    }
    if gs.ui.show_menu || gs.ui.show_title || gs.ui.show_settings {
        return true  // full-screen modals — everything behind them is blocked
    }
    return false
}

// Equip box under the cursor, or .None (the boxes stack vertically).
equip_slot_at_cursor :: proc(gs: ^Game_State) -> Equip_Slot {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < EQUIP_X || mx >= EQUIP_X + SLOT_PX do return .None
    for s, i in equip_slot_order {
        y := i32(EQUIP_Y + i*EQUIP_STEP)
        if my >= y && my < y + SLOT_PX do return s
    }
    return .None
}

// Inventory slot under the cursor, or -1.
slot_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < INV_X || my < INV_Y do return -1
    c := int((mx - INV_X) / SLOT_PX)
    r := int((my - INV_Y) / SLOT_PX)
    if c < 0 || c >= INV_COLS || r < 0 || r >= INV_ROWS do return -1
    return r*INV_COLS + c
}

// Crafting row under the cursor, or -1.
recipe_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < CRAFT_X || mx >= CRAFT_X + CRAFT_W do return -1
    r := int((my - CRAFT_Y - 4) / CRAFT_ROW_H)
    if r < 0 || r >= len(recipe_table) do return -1
    return r
}

// ─── Drawing ──────────────────────────────────────────────────────────────────

draw_ui :: proc(gs: ^Game_State) {
    draw_hud(gs)
    draw_notifications(gs)
    if gs.ui.show_inventory do draw_inventory(gs)
    if gs.ui.show_crafting  do draw_crafting(gs)
    if gs.ui.show_inventory || gs.ui.show_crafting do draw_tile_tooltip(gs)
    if gs.ui.show_blueprint do draw_blueprint(gs)
    if gs.game_won do draw_win_screen(gs)
    if gs.player.dead do draw_death_screen(gs)
    when GAME_DEBUG {
        if gs.debug.menu_open do draw_debug_menu(gs)
    }
    if gs.ui.show_menu     do draw_menu(gs)      // modal overlays — always drawn last, on top
    if gs.ui.show_settings do draw_settings(gs)
    if gs.ui.show_title    do draw_title(gs)     // title covers everything, menu included
}

// ─── Death Screen ─────────────────────────────────────────────────────────────
//
//  Roguelike death: the run is over and the save burns with it.  Blood-dark
//  fade paced by player.death_timer, the rune ring wheeling in red, and after
//  a beat the prompt to carve a new hero (ENTER/click → New_Game_Request).

DEATH_INPUT_DELAY :: f32(1.2)   // seconds before restart input is accepted

draw_death_screen :: proc(gs: ^Game_State) {
    t    := f32(rl.GetTime())
    fade := clamp(gs.player.death_timer, 0, 1)

    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{25, 0, 0, u8(215 * fade)})

    center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
        tw := rl.MeasureText(text, size)
        rl.DrawText(text, (i32(SCREEN_W) - tw) / 2, y, size, color)
    }

    cx := f32(SCREEN_W) / 2
    cy := f32(SCREEN_H) / 2 - 40

    // The rune ring again — but wheeling backwards, in blood.
    radius := f32(270)
    for g, i in title_runes {
        ang    := -t*0.08 + f32(i) * (2*math.PI / f32(len(title_runes)))
        rx     := cx + math.cos(ang) * radius
        ry     := cy + math.sin(ang) * radius
        breath := 0.55 + 0.45*math.sin(t*1.1 + f32(i)*2.4)
        col    := rl.Color{220, 60, 40, u8((90 + 120*breath) * fade)}
        draw_title_rune(g, rx, ry, 36, ang + math.PI/2, col)
    }

    ty := i32(cy) - 60
    center_text("YOU HAVE FALLEN", ty, 80, rl.Color{230, 60, 40, u8(255 * fade)})
    center_text("The Norns have cut your thread", ty + 100,
        24, rl.Color{200, 160, 140, u8(255 * fade)})

    mins := int(gs.elapsed_time) / 60
    secs := int(gs.elapsed_time) % 60
    buf: [96]u8
    fmt.bprintf(buf[:95], "Your saga lasted %d:%02d      Kills %d      Runs %d",
        mins, secs, gs.stats.total_kills, gs.stats.runs_played)
    center_text(cstring(raw_data(buf[:])), ty + 150, 20, rl.Color{255, 255, 255, u8(255 * fade)})

    center_text("Death is final — the save burns on the pyre.", ty + 200,
        18, rl.Color{160, 130, 120, u8(255 * fade)})

    if gs.player.death_timer > DEATH_INPUT_DELAY {
        pulse := u8(120 + 135*(0.5 + 0.5*math.sin(t*2.5)))
        center_text("PRESS [ENTER] — CARVE A NEW HERO", SCREEN_H - 150, 26,
            rl.Color{255, 220, 140, pulse})
    }
}

// The game is beaten: dark overlay, title, run stats.  Quitting ends the
// run (save cleared on exit); menus and restart flow land in Phase 6.
draw_win_screen :: proc(gs: ^Game_State) {
    rl.DrawRectangle(0, 0, SCREEN_W, SCREEN_H, rl.Color{0, 0, 0, 200})

    center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
        tw := rl.MeasureText(text, size)
        rl.DrawText(text, (i32(SCREEN_W) - tw) / 2, y, size, color)
    }

    center_text("GARM IS SLAIN", 380, 60, rl.Color{255, 200, 80, 255})
    center_text("Gnipahellir is conquered", 450, 30, rl.Color{255, 240, 180, 255})

    mins := int(gs.elapsed_time) / 60
    secs := int(gs.elapsed_time) % 60

    buf: [96]u8
    fmt.bprintf(buf[:95], "Run time %d:%02d      Kills %d      Runs won %d",
        mins, secs, gs.stats.total_kills, gs.stats.runs_won)
    center_text(cstring(raw_data(buf[:])), 520, 20, rl.WHITE)

    center_text("The hound guards the gate no more.", 580, 20, rl.Color{160, 160, 170, 255})
}

// Timed popups, stacked top-center, fading out over the last NOTIFY_FADE s.
draw_notifications :: proc(gs: ^Game_State) {
    NOTIFY_FONT :: 20
    for i in 0 ..< gs.notify.count {
        n := &gs.notify.items[i]

        alpha := f32(1)
        if remain := NOTIFY_DURATION - n.age; remain < NOTIFY_FADE {
            alpha = remain / NOTIFY_FADE
        }

        text := cstring(raw_data(n.text[:]))  // buffer is zeroed on push
        tw   := rl.MeasureText(text, NOTIFY_FONT)
        x    := (i32(SCREEN_W) - tw) / 2
        y    := i32(70 + i*28)

        rl.DrawText(text, x + 1, y + 1, NOTIFY_FONT, rl.Color{0, 0, 0, u8(180 * alpha)})
        rl.DrawText(text, x, y, NOTIFY_FONT, rl.Color{255, 240, 180, u8(255 * alpha)})
    }
}

draw_hud :: proc(gs: ^Game_State) {
    p := &gs.player

    // HP bar
    rl.DrawRectangle(24, 16, 200, 14, rl.Color{60, 20, 20, 255})
    hp_w := i32(200 * f32(p.hp) / f32(max(p.hp_max, 1)))
    rl.DrawRectangle(24, 16, hp_w, 14, rl.Color{200, 40, 40, 255})
    rl.DrawRectangleLines(24, 16, 200, 14, panel_border)

    // Mana bar
    rl.DrawRectangle(24, 34, 200, 10, rl.Color{20, 20, 60, 255})
    mana_w := i32(200 * p.mana / max(p.mana_max, 1))
    rl.DrawRectangle(24, 34, mana_w, 10, rl.Color{60, 90, 220, 255})
    rl.DrawRectangleLines(24, 34, 200, 10, panel_border)

    // Level name + selected item
    name_buf: [64]u8
    inv := &gs.player.inventory
    if inv.selected >= 0 && inv.slots[inv.selected].item != .None && inv.slots[inv.selected].count > 0 {
        sel := inv.slots[inv.selected]
        fmt.bprintf(name_buf[:63], "%s   [%s x%d]",
            level_names[gs.level_index], item_table[sel.item].name, sel.count)
    } else {
        fmt.bprintf(name_buf[:63], "%s", level_names[gs.level_index])
    }
    rl.DrawText(cstring(raw_data(name_buf[:])), 24, 50, 10, rl.WHITE)

    // Stat line (base + equipment)
    stat_buf: [48]u8
    fmt.bprintf(stat_buf[:47], "ATK %d  DEF %d  SPD %d",
        player_stat(p, .Attack), player_stat(p, .Defense), player_stat(p, .Speed))
    rl.DrawText(cstring(raw_data(stat_buf[:])), 24, 64, 10, text_dim)

    // Equipped gear, always visible: one mini box per slot + item name.
    for s, i in equip_slot_order {
        y := i32(82 + i*24)
        rl.DrawRectangle(24, y, 20, 20, slot_bg)
        rl.DrawRectangleLines(24, y, 20, 20, panel_border)
        rl.DrawText(equip_slot_labels[i], 50, y + 5, 10, text_dim)
        if it := p.equipment[s]; it != .None {
            rl.DrawRectangle(28, y + 4, 12, 12, item_table[it].color)
            rl.DrawText(cstring(raw_data(item_table[it].name)), 82, y + 5, 10, rl.WHITE)
        }
    }
}

draw_inventory :: proc(gs: ^Game_State) {
    inv := &gs.player.inventory

    // Centered Norse panel: header, equipment row, bag grid, footer.
    rl.DrawRectangle(INV_PANEL_X, INV_PANEL_Y, INV_PANEL_W, INV_PANEL_H, NORSE_PANEL)
    rl.DrawRectangleLinesEx({INV_PANEL_X, INV_PANEL_Y, INV_PANEL_W, INV_PANEL_H}, 2, NORSE_BORDER)
    rl.DrawText("INVENTORY", INV_PANEL_X + 24, INV_PANEL_Y + 16, 26, NORSE_GOLD_HOT)
    rl.DrawText("[TAB] close", INV_PANEL_X + INV_PANEL_W - 106, INV_PANEL_Y + 24, 12, NORSE_GOLD)
    rl.DrawRectangle(INV_PANEL_X + 24, INV_PANEL_Y + 52, INV_PANEL_W - 48, 2, NORSE_BORDER)

    // Equipment paperdoll: right-click a bag item to equip, a box to doff.
    rl.DrawText("GEAR", EQUIP_X, EQUIP_Y - 16, 12, NORSE_GOLD)
    for s, i in equip_slot_order {
        x := i32(EQUIP_X)
        y := i32(EQUIP_Y + i*EQUIP_STEP)
        hovered := equip_slot_at_cursor(gs) == s
        rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, NORSE_ROW)
        rl.DrawRectangleLinesEx({f32(x), f32(y), SLOT_PX, SLOT_PX}, hovered ? 2 : 1,
            hovered ? NORSE_GOLD_HOT : NORSE_BORDER)
        rl.DrawText(equip_slot_labels[i], x + SLOT_PX + 6, y + 17, 10, text_dim)
        if it := gs.player.equipment[s]; it != .None {
            rl.DrawRectangle(x + 10, y + 10, 24, 24, item_table[it].color)
        }
    }

    // Bag grid
    for i in 0 ..< MAX_INVENTORY {
        c := i32(i % INV_COLS)
        r := i32(i / INV_COLS)
        x := i32(INV_X) + c*SLOT_PX
        y := i32(INV_Y) + r*SLOT_PX
        rl.DrawRectangle(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, NORSE_ROW)
        rl.DrawRectangleLines(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, rl.Color{70, 56, 38, 255})

        s := inv.slots[i]
        if s.item != .None && s.count > 0 {
            rl.DrawRectangle(x + 10, y + 8, 24, 24, item_table[s.item].color)
            cnt_buf: [8]u8
            fmt.bprintf(cnt_buf[:7], "%d", s.count)
            rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
        }
        if i == inv.selected {
            rl.DrawRectangleLinesEx({f32(x) + 1, f32(y) + 1, SLOT_PX - 2, SLOT_PX - 2}, 2, NORSE_GOLD_HOT)
        }
    }

    // Footer: name of whatever is under the cursor (bag item or worn gear).
    footer_y := i32(INV_PANEL_Y + INV_PANEL_H - 28)
    if hov := slot_at_cursor(gs); hov >= 0 {
        s := inv.slots[hov]
        if s.item != .None && s.count > 0 {
            rl.DrawText(cstring(raw_data(item_table[s.item].name)), INV_X, footer_y, 12, NORSE_GOLD_HOT)
        }
    } else if es := equip_slot_at_cursor(gs); es != .None {
        if it := gs.player.equipment[es]; it != .None {
            rl.DrawText(cstring(raw_data(item_table[it].name)), INV_X, footer_y, 12, NORSE_GOLD_HOT)
        }
    }
}

draw_crafting :: proc(gs: ^Game_State) {
    h := i32(len(recipe_table))*CRAFT_ROW_H + 8
    rl.DrawRectangle(CRAFT_X - 6, CRAFT_Y - 6, CRAFT_W + 12, h + 12, panel_bg)
    rl.DrawRectangleLines(CRAFT_X - 6, CRAFT_Y - 6, CRAFT_W + 12, h + 12, panel_border)
    rl.DrawText("CRAFTING", CRAFT_X, CRAFT_Y - 22, 10,
        player_near_bench(gs) ? rl.GREEN : text_dim)

    for i in 0 ..< len(recipe_table) {
        r := &recipe_table[i]
        y := i32(CRAFT_Y) + 4 + i32(i)*CRAFT_ROW_H

        row_buf: [128]u8
        pos := 0
        s := fmt.bprintf(row_buf[pos:100], "%s x%d  <- ", item_table[r.result].name, r.result_count)
        pos += len(s)
        for ing in r.ingredients {
            if ing.item == .None do continue
            s = fmt.bprintf(row_buf[pos:120], "%d %s  ", ing.count, item_table[ing.item].name)
            pos += len(s)
        }
        if r.needs_bench {
            s = fmt.bprintf(row_buf[pos:126], "[bench]")
            pos += len(s)
        }

        col := recipe_craftable(gs, r) ? rl.GREEN : text_dim
        rl.DrawText(cstring(raw_data(row_buf[:])), CRAFT_X + 4, y + 6, 10, col)
    }
}

// The interactive blueprint overlay (B, or click a blueprint in the bag):
// what to gather, the build template for the altar, and the path to the cave.
draw_blueprint :: proc(gs: ^Game_State) {
    x, y := i32(BP_X), i32(BP_Y)
    rl.DrawRectangle(x, y, BP_W, BP_H, panel_bg)
    rl.DrawRectangleLines(x, y, BP_W, BP_H, panel_border)

    accent := rl.Color{130, 180, 255, 255}
    good   := rl.Color{120, 220, 120, 255}
    warm   := rl.Color{250, 220, 110, 255}

    rl.DrawText("[B] close", x + BP_W - 92, y + 14, 12, text_dim)

    // Opening objective: with the Sky Blueprint in hand and no gate raised yet,
    // show how to build the surface Sky Altar that opens the way above.
    if inventory_count(&gs.player.inventory, .Sky_Blueprint) > 0 && gs.progression.sky_altar_pos == {0, 0} {
        rl.DrawText("BLUEPRINT: The Sky Gate", x + 20, y + 18, 24, accent)
        rl.DrawText("Raise a Sky Altar on the surface to open the way above.",
            x + 20, y + 54, 16, rl.Color{225, 225, 240, 255})
        tpl := &structure_templates[0]  // tier A: the stone-and-wood altar
        rl.DrawText("BUILD THE ALTAR", x + 320, y + 90, 14, text_dim)
        draw_template_diagram(tpl, x + 415, y + 120)
        ly := y + 96
        draw_legend(x + 30, ly,      terrain_table[.Stone].color, "Stone Block")
        draw_legend(x + 30, ly + 22, terrain_table[.Wood].color,  "Wood (Plank/Log)")
        draw_legend(x + 30, ly + 44, item_table[.Sky_Altar].color, "Sky Altar (cap)")
        rl.DrawText("Build it on the grass — the portal blooms above the altar.",
            x + 20, y + BP_H - 32, 14, text_dim)
        return
    }

    tier := blueprint_active_tier(gs)
    if tier < 0 {
        rl.DrawText("BLUEPRINT", x + 20, y + 18, 24, accent)
        rl.DrawText("You carry no blueprint yet.", x + 20, y + 64, 18, text_dim)
        rl.DrawText("Delve the caves — a sky blueprint waits in each.", x + 20, y + 92, 16, text_dim)
        return
    }

    // Title + objective
    rl.DrawText("BLUEPRINT: The Sky Ritual", x + 20, y + 18, 24, accent)
    obj_buf: [96]u8
    fmt.bprintf(obj_buf[:95], "Raise the sky structure to unlock %s.", blueprint_unlocks_name(tier))
    rl.DrawText(cstring(raw_data(obj_buf[:])), x + 20, y + 52, 16, rl.Color{225, 225, 240, 255})

    // LEFT — ritual material checklist: icon, name, have/need, check when met
    rl.DrawText("THE ALTAR HUNGERS FOR", x + 20, y + 84, 14, text_dim)
    all_met := true
    for ing, i in structure_costs[tier] {
        ry   := y + 104 + i32(i)*30
        have := inventory_count(&gs.player.inventory, ing.item)
        met  := have >= ing.count
        if !met do all_met = false
        rl.DrawRectangle(x + 30, ry, 20, 20, item_table[ing.item].color)
        rl.DrawRectangleLines(x + 30, ry, 20, 20, panel_border)
        rl.DrawText(cstring(raw_data(item_table[ing.item].name)), x + 60, ry + 3, 15, rl.WHITE)
        cnt_buf: [32]u8
        fmt.bprintf(cnt_buf[:31], "%d / %d", have, ing.count)
        rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 210, ry + 3, 15, met ? good : warm)
        if met do draw_check(x + 268, ry + 2, good)
    }

    // RIGHT — the active tier's altar build template, from templates.odin
    tpl := &structure_templates[tier]
    rl.DrawText("BUILD THE ALTAR", x + 320, y + 84, 14, text_dim)
    name_buf: [32]u8
    fmt.bprintf(name_buf[:31], "%s", tpl.name)
    rl.DrawText(cstring(raw_data(name_buf[:])), x + 320, y + 100, 14, accent)
    draw_template_diagram(tpl, x + 415, y + 118)
    ly := y + 190
    if structure_template_uses(tpl, .Stone)      { draw_legend(x + 330, ly, terrain_table[.Stone].color,      "Stone Block");    ly += 19 }
    if structure_template_uses(tpl, .Wood)       { draw_legend(x + 330, ly, terrain_table[.Wood].color,       "Wood");           ly += 19 }
    if structure_template_uses(tpl, .Silver_Ore) { draw_legend(x + 330, ly, terrain_table[.Silver_Ore].color, "Silver Ore");     ly += 19 }
    if structure_template_uses(tpl, .Gold_Ore)   { draw_legend(x + 330, ly, terrain_table[.Gold_Ore].color,   "Gold Ore");       ly += 19 }
    draw_legend(x + 330, ly, item_table[.Sky_Altar].color, "Sky Altar (cap)")

    // Three-step path (left): find -> gather -> raise the altar
    steps_done := [3]bool{ true, all_met, gs.progression.sky_structure_complete[tier] }
    labels     := [3]cstring{ "FIND", "GATHER", "RAISE" }
    current    := 3
    for d, i in steps_done { if !d { current = i; break } }
    for i in 0 ..< 3 {
        nx  := x + 30 + i32(i)*90
        ny  := y + 196
        col := text_dim
        if steps_done[i]      { col = good }
        else if i == current  { col = warm }
        rl.DrawRectangle(nx, ny, 34, 34, slot_bg)
        rl.DrawRectangleLines(nx, ny, 34, 34, col)
        num_buf: [4]u8
        fmt.bprintf(num_buf[:3], "%d", i + 1)
        rl.DrawText(cstring(raw_data(num_buf[:])), nx + 12, ny + 8, 20, col)
        rl.DrawText(labels[i], nx - 2, ny + 40, 12, col)
        if i < 2 do rl.DrawText(">", nx + 42, ny + 4, 24, text_dim)
    }

    rl.DrawText("Build the altar in the Low Sky, gather the offering, then press E.",
        x + 20, y + BP_H - 32, 14, text_dim)
}

// A small checkmark drawn from two strokes (default font has no glyph for it).
draw_check :: proc(x, y: i32, col: rl.Color) {
    rl.DrawLineEx({f32(x), f32(y + 8)},  {f32(x + 5), f32(y + 14)}, 3, col)
    rl.DrawLineEx({f32(x + 5), f32(y + 14)}, {f32(x + 14), f32(y)}, 3, col)
}

// A labelled colour swatch for the template legend.
draw_legend :: proc(x, y: i32, col: rl.Color, label: cstring) {
    rl.DrawRectangle(x, y, 14, 14, col)
    rl.DrawRectangleLines(x, y, 14, 14, panel_border)
    rl.DrawText(label, x + 20, y + 1, 13, text_dim)
}

// Draw a build template as stacked colour blocks, centered horizontally on cx.
draw_template_diagram :: proc(tpl: ^Structure_Template, cx, top: i32) {
    CELL :: 16
    for line, r in tpl.rows {
        rw := i32(len(line)) * CELL
        rx := cx - rw/2
        for glyph, c in line {
            tile, kind := structure_template_cell(glyph)
            if kind == .Empty do continue
            col := kind == .Capstone ? item_table[tpl.capstone].color : terrain_table[tile].color
            bx := rx + i32(c)*CELL
            by := top + i32(r)*CELL
            rl.DrawRectangle(bx + 1, by + 1, CELL - 2, CELL - 2, col)
            rl.DrawRectangleLines(bx + 1, by + 1, CELL - 2, CELL - 2, panel_border)
        }
    }
}

draw_tile_tooltip :: proc(gs: ^Game_State) {
    if cursor_over_ui(gs) do return
    ht := gs.ui.hover_tile
    if !in_bounds(int(ht.x), int(ht.y)) do return

    t   := get_tile(&gs.world, int(ht.x), int(ht.y))
    idx := grid_idx(int(ht.x), int(ht.y))

    tip_buf: [64]u8
    it := gs.world.items[idx]
    if it != .None && gs.world.item_counts[idx] > 0 {
        fmt.bprintf(tip_buf[:63], "%s (drop: %s)", terrain_table[t].name, item_table[it].name)
    } else {
        fmt.bprintf(tip_buf[:63], "%s", terrain_table[t].name)
    }
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    rl.DrawText(cstring(raw_data(tip_buf[:])), mx + 12, my - 4, 10, rl.WHITE)
}

