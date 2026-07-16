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

// The inventory is a near-centered popup (nudged left so the crafting list
// fits beside it on the UI canvas): header, then a paperdoll column of
// equip slots on the left and the bag grid to its right.
INV_PANEL_W :: 24 + 100 + 16 + INV_COLS*SLOT_PX + 24
INV_PANEL_H :: 450
INV_PANEL_X :: (UI_W - INV_PANEL_W) / 2 - 40    // default position (draggable)
INV_PANEL_Y :: (UI_H - INV_PANEL_H) / 2

// Crafting: tall list right of the inventory popup, taking the remaining width.
CRAFT_X     :: INV_PANEL_X + INV_PANEL_W + 8    // default content origin (draggable)
CRAFT_Y     :: 160
CRAFT_W     :: UI_W - CRAFT_X - 6
CRAFT_ROW_H :: 20   // hand + one station's rows (max ~17) + anvil header must fit UI_H
CRAFT_OFFER_H  :: 132   // anvil header: offer slots + candidate results
CRAFT_SLOT_GAP :: 6

// Equipment boxes — the paperdoll column (weapon, armor head→feet, charm).
EQUIP_STEP :: 50

@(rodata)
equip_slot_order := [7]Equip_Slot{.Weapon, .Head, .Chest, .Hands, .Legs, .Feet, .Charm}

@(rodata)
equip_slot_labels := [7]cstring{"WPN", "HEAD", "CHEST", "HANDS", "LEGS", "FEET", "CHM"}

// Blueprint overlay — centered panel.
BP_W :: 540
BP_H :: 360
BP_X :: (UI_W - BP_W) / 2    // default position (draggable)
BP_Y :: (UI_H - BP_H) / 2

// Smelter window — the furnace fire, the ground cells beside it, the tray.
SMELT_W :: 250
SMELT_H :: 360
SMELT_X :: 140               // default position (draggable)
SMELT_Y :: 180

// ─── Floating Windows (draggable) ─────────────────────────────────────────────
//
//  Each floating window's top-left lives in UI_State.win_pos (defaults below);
//  grabbing the top WINDOW_HEADER_H band drags it.  Full-screen modals (menu,
//  settings, title, death) are not windows and stay fixed.

UI_Window :: enum u8 {
    Inventory,
    Crafting,
    Smelter,
    Blueprint,
}

WINDOW_HEADER_H :: 40

@(rodata)
default_window_pos := [UI_Window][2]i32{
    .Inventory = {INV_PANEL_X, INV_PANEL_Y},
    .Crafting  = {CRAFT_X - 6, CRAFT_Y - 28},
    .Smelter   = {SMELT_X, SMELT_Y},
    .Blueprint = {BP_X, BP_Y},
}

// draw_ui stacks windows in enum order; drag hit-testing walks this top-down.
@(rodata)
window_top_down := [4]UI_Window{.Blueprint, .Smelter, .Crafting, .Inventory}

// Outer bounds of a floating window at its current position, and whether it
// is open.  Crafting's height tracks its recipe list.
window_rect :: proc(gs: ^Game_State, w: UI_Window) -> (x, y, ww, wh: i32, open: bool) {
    p := gs.ui.win_pos[w]
    switch w {
    case .Inventory:
        return p.x, p.y, INV_PANEL_W, INV_PANEL_H, gs.ui.show_inventory
    case .Crafting:
        vis: [len(recipe_table)]int
        n := visible_recipes(gs, &vis)
        return p.x, p.y, CRAFT_W + 12, 42 + CRAFT_OFFER_H + i32(n)*CRAFT_ROW_H, gs.ui.show_crafting
    case .Smelter:
        return p.x, p.y, SMELT_W, SMELT_H, gs.ui.show_smelter
    case .Blueprint:
        return p.x, p.y, BP_W, BP_H, gs.ui.show_blueprint
    }
    return
}

// True when the cursor is inside an open window's bounds.
cursor_in_window :: proc(gs: ^Game_State, w: UI_Window) -> bool {
    x, y, ww, wh, open := window_rect(gs, w)
    if !open do return false
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    return mx >= x && mx < x + ww && my >= y && my < y + wh
}

// Runtime content origins, derived from the window position.
inv_bag_origin :: proc(gs: ^Game_State) -> (x, y: i32) {
    p := gs.ui.win_pos[.Inventory]
    return p.x + 140, p.y + 70
}

equip_origin :: proc(gs: ^Game_State) -> (x, y: i32) {
    p := gs.ui.win_pos[.Inventory]
    return p.x + 24, p.y + 70
}

// Content origin of the crafting window (win_pos is the panel corner; the
// title band above the content is 28px).
craft_origin :: proc(gs: ^Game_State) -> (x, y: i32) {
    p := gs.ui.win_pos[.Crafting]
    return p.x + 6, p.y + 28
}

// The smelter tray slot (cast bars wait here) — shared by draw and hit-test.
smelter_tray_rect :: proc(gs: ^Game_State) -> (x, y: i32) {
    p := gs.ui.win_pos[.Smelter]
    return p.x + 24, p.y + 272
}

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
draw_title_rune :: proc(g: Rune_Glyph, cx, cy, size, rot: f32, col: rl.Color, core: f32 = 3, glow_w: f32 = 8) {
    cr := math.cos(rot)
    sr := math.sin(rot)
    for k in 0 ..< g.n {
        p1 := [2]f32{g.seg[k][0] - 0.5, g.seg[k][1] - 0.5} * size
        p2 := [2]f32{g.seg[k][2] - 0.5, g.seg[k][3] - 0.5} * size
        a  := rl.Vector2{cx + p1.x*cr - p1.y*sr, cy + p1.x*sr + p1.y*cr}
        b  := rl.Vector2{cx + p2.x*cr - p2.y*sr, cy + p2.x*sr + p2.y*cr}
        glow := col
        glow.a = col.a / 4
        rl.DrawLineEx(a, b, glow_w, glow)
        rl.DrawLineEx(a, b, core, col)
    }
}

// GNIPAHELLIR as a quiet horizontal rune band, centered on cx — dressing
// for panel headers.
draw_rune_strip :: proc(cx, cy, size: f32, col: rl.Color) {
    step := size * 1.8
    x := cx - step * f32(len(title_runes) - 1) / 2
    for g in title_runes {
        draw_title_rune(g, x, cy, size, 0, col, 2, 4)
        x += step
    }
}

draw_title :: proc(gs: ^Game_State) {
    t  := f32(rl.GetTime())
    cx := f32(UI_W) / 2
    cy := f32(UI_H) / 2 - 40

    // Night backdrop, warming toward a fire-lit horizon.
    rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{8, 8, 14, 255})
    rl.DrawRectangleGradientV(0, UI_H*2/3, UI_W, UI_H/3,
        rl.Color{8, 8, 14, 255}, rl.Color{42, 20, 10, 255})
    // The cave mouth smolders below the horizon.
    rl.DrawCircleGradient(i32(cx), UI_H + 100, 420,
        rl.Color{255, 120, 30, 70}, rl.Color{0, 0, 0, 0})

    // Embers: stateless — each i hashes to a column/speed, y wraps on time.
    for i in 0 ..< 70 {
        h     := whash(u32(i) * 7919 + 13)
        speed := 18 + f32(h % 70)
        x     := f32(h % UI_W) + math.sin(t*1.3 + f32(i)) * 16
        y     := f32(UI_H) - math.mod(t*speed + f32(h % UI_H), f32(UI_H + 60))
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
        rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
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
    center_text("PRESS ANY KEY", UI_H - 130, 26, rl.Color{255, 240, 180, prompt})
}

// ─── Pause / Main Menu (ESC, or shown first at startup) ───────────────────────

MENU_ROWS  :: 4   // row 0: Resume; 1: Settings; 2: New Game; 3: Save and Quit
MENU_W     :: 360
MENU_ROW_H :: 56
MENU_X     :: (UI_W - MENU_W) / 2
MENU_Y     :: (UI_H - MENU_ROWS*MENU_ROW_H) / 2

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
    rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{8, 6, 10, 215})
    rl.DrawRectangleGradientV(0, 0, UI_W, 220, rl.Color{0, 0, 0, 180}, rl.Color{0, 0, 0, 0})
    rl.DrawRectangleGradientV(0, UI_H - 220, UI_W, 220, rl.Color{0, 0, 0, 0}, rl.Color{0, 0, 0, 180})

    cx := f32(UI_W) / 2
    cy := f32(UI_H) / 2

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
        rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
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
SET_X        :: (UI_W - SET_W) / 2
SET_Y        :: (UI_H - 684) / 2   // 684 = the panel's content height (SET_H)
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
    rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{8, 6, 10, 215})
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
DBG_MENU_ROWS  :: 11  // 0:fly; 1:wand; 2:portals; 3:structures; 4:resources; 5:full hp; 6:max mana; 7/8:stamp spawners; 9:give miner; 10:game of life

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

    // Action rows (click to invoke)
    rl.DrawText("Activate portals >", DBG_MENU_X, DBG_MENU_Y + 2*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)
    rl.DrawText("Add all structures >", DBG_MENU_X, DBG_MENU_Y + 3*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)
    rl.DrawText("Add resource stack >", DBG_MENU_X, DBG_MENU_Y + 4*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)
    rl.DrawText("Full HP >", DBG_MENU_X, DBG_MENU_Y + 5*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)
    rl.DrawText("Max mana >", DBG_MENU_X, DBG_MENU_Y + 6*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)

    // Snake-miner test kit: stamp a spawner with the next click, get a miner.
    ms_col := gs.debug.place_tile == .Dimension_Spawner ? rl.GREEN : rl.YELLOW
    gs_col := gs.debug.place_tile == .Dimension_Spawner_Gold ? rl.GREEN : rl.YELLOW
    rl.DrawText("Stamp Metal spawner >", DBG_MENU_X, DBG_MENU_Y + 7*DBG_MENU_ROW_H + 7, 10, ms_col)
    rl.DrawText("Stamp Gold spawner >", DBG_MENU_X, DBG_MENU_Y + 8*DBG_MENU_ROW_H + 7, 10, gs_col)
    rl.DrawText("Give Auto-Miner >", DBG_MENU_X, DBG_MENU_Y + 9*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)

    life_col := gs.debug.life ? rl.GREEN : text_dim
    rl.DrawText(gs.debug.life ? cstring("Game of Life: ON ?!") : cstring("Game of Life: OFF"),
        DBG_MENU_X, DBG_MENU_Y + 10*DBG_MENU_ROW_H + 7, 10, life_col)

    if r := debug_menu_row_at_cursor(gs); r >= 0 {
        rl.DrawRectangleLines(DBG_MENU_X - 2, DBG_MENU_Y + i32(r)*DBG_MENU_ROW_H + 1,
            DBG_MENU_W + 4, DBG_MENU_ROW_H - 2, rl.YELLOW)
    }
}

// ─── Altar Debug Menu (F2, debug builds only) ─────────────────────────────────

ALT_MENU_X    :: DBG_MENU_X + DBG_MENU_W + 36
ALT_MENU_Y    :: DBG_MENU_Y
ALT_MENU_W    :: 200
ALT_MENU_ROWS :: 7  // 0/1: stamp sky/rune altar; 2-4: raise tier structure; 5: blueprints; 6: complete ritual

// Menu row under the cursor, or -1.
altar_menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < ALT_MENU_X || mx >= ALT_MENU_X + ALT_MENU_W do return -1
    r := int((my - ALT_MENU_Y) / DBG_MENU_ROW_H)
    if my < ALT_MENU_Y || r >= ALT_MENU_ROWS do return -1
    return r
}

draw_altar_menu :: proc(gs: ^Game_State) {
    h := i32(ALT_MENU_ROWS * DBG_MENU_ROW_H)
    rl.DrawRectangle(ALT_MENU_X - 6, ALT_MENU_Y - 26, ALT_MENU_W + 12, h + 34, panel_bg)
    rl.DrawRectangleLines(ALT_MENU_X - 6, ALT_MENU_Y - 26, ALT_MENU_W + 12, h + 34, panel_border)
    rl.DrawText("ALTARS (F2)", ALT_MENU_X, ALT_MENU_Y - 20, 10, rl.YELLOW)

    sa_col := gs.debug.place_tile == .Sky_Altar ? rl.GREEN : rl.YELLOW
    ra_col := gs.debug.place_tile == .Rune_Altar ? rl.GREEN : rl.YELLOW
    rl.DrawText("Stamp Sky Altar (gate) >", ALT_MENU_X, ALT_MENU_Y + 7, 10, sa_col)
    rl.DrawText("Stamp Rune Altar >", ALT_MENU_X, ALT_MENU_Y + DBG_MENU_ROW_H + 7, 10, ra_col)

    tier_rows := [3]cstring{"Raise Stone Altar >", "Raise Silver-Gold Altar >", "Raise Golden Altar >"}
    for label, i in tier_rows {
        col := gs.debug.place_tier == i + 1 ? rl.GREEN : rl.YELLOW
        rl.DrawText(label, ALT_MENU_X, ALT_MENU_Y + i32(2+i)*DBG_MENU_ROW_H + 7, 10, col)
    }

    rl.DrawText("Find all blueprints >", ALT_MENU_X, ALT_MENU_Y + 5*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)
    rl.DrawText("Complete next ritual >", ALT_MENU_X, ALT_MENU_Y + 6*DBG_MENU_ROW_H + 7, 10, rl.YELLOW)

    if r := altar_menu_row_at_cursor(gs); r >= 0 {
        rl.DrawRectangleLines(ALT_MENU_X - 2, ALT_MENU_Y + i32(r)*DBG_MENU_ROW_H + 1,
            ALT_MENU_W + 4, DBG_MENU_ROW_H - 2, rl.YELLOW)
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
        if gs.debug.altar_menu &&
           mx >= ALT_MENU_X - 6 && mx < ALT_MENU_X + ALT_MENU_W + 6 &&
           my >= ALT_MENU_Y - 26 && my < ALT_MENU_Y + ALT_MENU_ROWS*DBG_MENU_ROW_H + 8 {
            return true
        }
    }
    for w in UI_Window {
        if cursor_in_window(gs, w) do return true
    }
    if gs.ui.show_menu || gs.ui.show_title || gs.ui.show_settings {
        return true  // full-screen modals — everything behind them is blocked
    }
    return false
}

// Equip box under the cursor, or .None (the boxes stack vertically).
equip_slot_at_cursor :: proc(gs: ^Game_State) -> Equip_Slot {
    ex, ey := equip_origin(gs)
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < ex || mx >= ex + SLOT_PX do return .None
    for s, i in equip_slot_order {
        y := ey + i32(i*EQUIP_STEP)
        if my >= y && my < y + SLOT_PX do return s
    }
    return .None
}

// Inventory slot under the cursor, or -1.
slot_at_cursor :: proc(gs: ^Game_State) -> int {
    bx, by := inv_bag_origin(gs)
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < bx || my < by do return -1
    c := int((mx - bx) / SLOT_PX)
    r := int((my - by) / SLOT_PX)
    if c < 0 || c >= INV_COLS || r < 0 || r >= INV_ROWS do return -1
    return r*INV_COLS + c
}

// Recipe-table index of the crafting row under the cursor, or -1.
recipe_at_cursor :: proc(gs: ^Game_State) -> int {
    cx, cy := craft_origin(gs)
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    if mx < cx || mx >= cx + CRAFT_W do return -1
    if my < cy + CRAFT_OFFER_H do return -1   // anvil header, not the list
    row := int((my - cy - CRAFT_OFFER_H - 4) / CRAFT_ROW_H)
    vis: [len(recipe_table)]int
    n := visible_recipes(gs, &vis)
    if row < 0 || row >= n do return -1
    return vis[row]
}

// Anvil offer slot i (0..2) top-left corner.
craft_offer_rect :: proc(gs: ^Game_State, i: int) -> (x, y: i32) {
    cx, cy := craft_origin(gs)
    return cx + 4 + i32(i)*(SLOT_PX + CRAFT_SLOT_GAP), cy + 14
}

// Candidate result slot j top-left corner.
craft_result_rect :: proc(gs: ^Game_State, j: int) -> (x, y: i32) {
    cx, cy := craft_origin(gs)
    return cx + 4 + i32(j)*(SLOT_PX + CRAFT_SLOT_GAP), cy + 80
}

// Anvil offer slot under the cursor, or -1.
craft_offer_at_cursor :: proc(gs: ^Game_State) -> int {
    if !gs.ui.show_crafting do return -1
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    for i in 0 ..< len(gs.ui.craft_offer) {
        x, y := craft_offer_rect(gs, i)
        if mx >= x && mx < x + SLOT_PX && my >= y && my < y + SLOT_PX do return i
    }
    return -1
}

// Recipe-table index of the candidate result under the cursor, or -1.
craft_result_at_cursor :: proc(gs: ^Game_State) -> int {
    if !gs.ui.show_crafting do return -1
    mx := i32(gs.input.mouse_screen.x)
    my := i32(gs.input.mouse_screen.y)
    matches: [len(recipe_table)]int
    m := offer_matches(gs, &matches)
    for j in 0 ..< m {
        x, y := craft_result_rect(gs, j)
        if mx >= x && mx < x + SLOT_PX && my >= y && my < y + SLOT_PX do return matches[j]
    }
    return -1
}

// ─── Drawing ──────────────────────────────────────────────────────────────────

// "[E] CRAFTING BENCH" while a station is in reach — hidden once the window
// is open.  Reads the focus computed by update_station_focus.
draw_station_prompt :: proc(gs: ^Game_State) {
    if gs.ui.focus_station == .None || gs.ui.show_crafting do return
    buf: [48]u8
    fmt.bprintf(buf[:47], "[%v] %v", gs.bindings[.Interact], station_title[gs.ui.focus_station])
    text := cstring(raw_data(buf[:]))
    w := rl.MeasureText(text, 20)
    rl.DrawText(text, (UI_W - w)/2, UI_H - 130, 20, NORSE_GOLD_HOT)
}

draw_ui :: proc(gs: ^Game_State) {
    draw_hud(gs)
    draw_objective(gs)
    draw_notifications(gs)
    draw_station_prompt(gs)
    if gs.ui.show_inventory do draw_inventory(gs)
    if gs.ui.show_crafting  do draw_crafting(gs)
    if gs.ui.show_smelter   do draw_smelter(gs)
    if gs.ui.show_inventory || gs.ui.show_crafting do draw_tile_tooltip(gs)
    if gs.ui.drag_item != .None {
        mx := i32(gs.input.mouse_screen.x)
        my := i32(gs.input.mouse_screen.y)
        draw_item_icon(gs.ui.drag_item, mx - 12, my - 12, 24)
        rl.DrawRectangleLines(mx - 12, my - 12, 24, 24, NORSE_GOLD_HOT)
    }
    if gs.ui.show_blueprint do draw_blueprint(gs)
    if gs.game_won do draw_win_screen(gs)
    if gs.player.dead do draw_death_screen(gs)
    when GAME_DEBUG {
        if gs.debug.menu_open  do draw_debug_menu(gs)
        if gs.debug.altar_menu do draw_altar_menu(gs)
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

    rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{25, 0, 0, u8(215 * fade)})

    center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
        tw := rl.MeasureText(text, size)
        rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
    }

    cx := f32(UI_W) / 2
    cy := f32(UI_H) / 2 - 40

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
        center_text("PRESS [ENTER] — CARVE A NEW HERO", UI_H - 150, 26,
            rl.Color{255, 220, 140, pulse})
    }
}

// The game is beaten: dark overlay, title, run stats.  Quitting ends the
// run (save cleared on exit); menus and restart flow land in Phase 6.
draw_win_screen :: proc(gs: ^Game_State) {
    rl.DrawRectangle(0, 0, UI_W, UI_H, rl.Color{0, 0, 0, 200})

    center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
        tw := rl.MeasureText(text, size)
        rl.DrawText(text, (i32(UI_W) - tw) / 2, y, size, color)
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

// The current objective — one dim line, top-center, always on so a new
// player knows the next step of the loop (text from current_objective).
draw_objective :: proc(gs: ^Game_State) {
    if gs.player.dead || gs.game_won || gs.ui.show_title do return
    buf: [128]u8
    s := current_objective(gs, buf[:127])
    if len(s) == 0 do return
    text := cstring(raw_data(buf[:]))
    tw   := rl.MeasureText(text, 18)
    x    := (i32(UI_W) - tw) / 2
    rl.DrawText(text, x + 1, 41, 18, rl.Color{0, 0, 0, 160})
    rl.DrawText(text, x, 40, 18, rl.Color{210, 185, 140, 220})
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
        x    := (i32(UI_W) - tw) / 2
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
            draw_item_icon(it, 27, y + 3, 14)
            rl.DrawText(cstring(raw_data(item_table[it].name)), 82, y + 5, 10, rl.WHITE)
        }
    }
}

draw_inventory :: proc(gs: ^Game_State) {
    inv := &gs.player.inventory
    px  := gs.ui.win_pos[.Inventory].x
    py  := gs.ui.win_pos[.Inventory].y
    ex, ey := equip_origin(gs)
    bx, by := inv_bag_origin(gs)

    // Norse panel: header (drag to move), equipment row, bag grid, footer.
    rl.DrawRectangle(px, py, INV_PANEL_W, INV_PANEL_H, NORSE_PANEL)
    rl.DrawRectangleLinesEx({f32(px), f32(py), INV_PANEL_W, INV_PANEL_H}, 2, NORSE_BORDER)
    rl.DrawText("INVENTORY", px + 24, py + 16, 26, NORSE_GOLD_HOT)
    draw_rune_strip(f32(px) + 295, f32(py) + 30, 11, rl.Color{200, 150, 70, 110})
    rl.DrawText("[TAB] close", px + INV_PANEL_W - 106, py + 24, 12, NORSE_GOLD)
    rl.DrawRectangle(px + 24, py + 52, INV_PANEL_W - 48, 2, NORSE_BORDER)

    // Equipment paperdoll: right-click a bag item to equip, a box to doff.
    rl.DrawText("GEAR", ex, ey - 16, 12, NORSE_GOLD)
    for s, i in equip_slot_order {
        x := ex
        y := ey + i32(i*EQUIP_STEP)
        hovered := equip_slot_at_cursor(gs) == s
        rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, NORSE_ROW)
        rl.DrawRectangleLinesEx({f32(x), f32(y), SLOT_PX, SLOT_PX}, hovered ? 2 : 1,
            hovered ? NORSE_GOLD_HOT : NORSE_BORDER)
        rl.DrawText(equip_slot_labels[i], x + SLOT_PX + 6, y + 17, 10, text_dim)
        if it := gs.player.equipment[s]; it != .None {
            draw_item_icon(it, x + 10, y + 10, 24)
        }
    }

    // Bag grid
    for i in 0 ..< MAX_INVENTORY {
        c := i32(i % INV_COLS)
        r := i32(i / INV_COLS)
        x := bx + c*SLOT_PX
        y := by + r*SLOT_PX
        rl.DrawRectangle(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, NORSE_ROW)
        rl.DrawRectangleLines(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, rl.Color{70, 56, 38, 255})

        s := inv.slots[i]
        if s.item != .None && s.count > 0 {
            draw_item_icon(s.item, x + 10, y + 8, 24)
            cnt_buf: [8]u8
            fmt.bprintf(cnt_buf[:7], "%d", s.count)
            rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
        }
        if i == inv.selected {
            rl.DrawRectangleLinesEx({f32(x) + 1, f32(y) + 1, SLOT_PX - 2, SLOT_PX - 2}, 2, NORSE_GOLD_HOT)
        }
    }

    // Footer: name of whatever is under the cursor (bag item or worn gear).
    footer_y := py + INV_PANEL_H - 28
    if hov := slot_at_cursor(gs); hov >= 0 {
        s := inv.slots[hov]
        if s.item != .None && s.count > 0 {
            rl.DrawText(cstring(raw_data(item_table[s.item].name)), bx, footer_y, 12, NORSE_GOLD_HOT)
        }
    } else if es := equip_slot_at_cursor(gs); es != .None {
        if it := gs.player.equipment[es]; it != .None {
            rl.DrawText(cstring(raw_data(item_table[it].name)), bx, footer_y, 12, NORSE_GOLD_HOT)
        }
    }
}

draw_crafting :: proc(gs: ^Game_State) {
    vis: [len(recipe_table)]int
    n := visible_recipes(gs, &vis)
    in_reach := player_near_station(gs, gs.ui.active_station)

    wx, wy, ww, wh, _ := window_rect(gs, .Crafting)
    cx, cy := craft_origin(gs)
    rl.DrawRectangle(wx, wy, ww, wh, panel_bg)
    rl.DrawRectangleLines(wx, wy, ww, wh, panel_border)
    rl.DrawText(station_title[gs.ui.active_station], cx, wy + 8, 10,
        in_reach ? rl.GREEN : text_dim)
    draw_rune_strip(f32(cx + CRAFT_W) - 100, f32(wy) + 13, 8, rl.Color{200, 150, 70, 90})

    // Anvil: offer slots hold references — the items themselves stay in the
    // bag until a result is actually crafted.
    rl.DrawText("LAY ON THE ANVIL  (drag from bag, click to take back)",
        cx + 4, cy + 2, 10, text_dim)
    hov_offer := craft_offer_at_cursor(gs)
    for it, i in gs.ui.craft_offer {
        x, y := craft_offer_rect(gs, i)
        rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, slot_bg)
        rl.DrawRectangleLinesEx({f32(x), f32(y), SLOT_PX, SLOT_PX},
            hov_offer == i ? 2 : 1, hov_offer == i ? NORSE_GOLD_HOT : panel_border)
        if it != .None {
            draw_item_icon(it, x + 10, y + 8, 24)
            cnt_buf: [8]u8
            fmt.bprintf(cnt_buf[:7], "%d", inventory_count(&gs.player.inventory, it))
            rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
        }
    }

    // Candidate results: everything the offered set could become here.
    // Green = craftable now, dim = matching shape but missing amounts.
    rl.DrawText("TAKES SHAPE", cx + 4, cy + 66, 10, text_dim)
    matches: [len(recipe_table)]int
    m := offer_matches(gs, &matches)
    hov_result := craft_result_at_cursor(gs)
    if hov_result >= 0 {
        rl.DrawText(cstring(raw_data(item_table[recipe_table[hov_result].result].name)),
            cx + 90, cy + 66, 10, NORSE_GOLD_HOT)
    }
    if m == 0 {
        offered := false
        for it in gs.ui.craft_offer do if it != .None do offered = true
        rl.DrawText(offered ? "these materials shape nothing here" :
            "lay materials to see what they may become",
            cx + 4, cy + 94, 10, text_dim)
    }
    for j in 0 ..< m {
        r := &recipe_table[matches[j]]
        x, y := craft_result_rect(gs, j)
        ok := recipe_craftable(gs, r)
        rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, slot_bg)
        border := panel_border
        if ok do border = hov_result == matches[j] ? NORSE_GOLD_HOT : rl.GREEN
        rl.DrawRectangleLinesEx({f32(x), f32(y), SLOT_PX, SLOT_PX}, ok ? 2 : 1, border)
        draw_item_icon(r.result, x + 10, y + 8, 24, ok ? 255 : 110)
        if r.result_count > 1 {
            cnt_buf: [8]u8
            fmt.bprintf(cnt_buf[:7], "x%d", r.result_count)
            rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
        }
    }

    // Recipe hints: click a row to load its materials onto the anvil.
    rl.DrawRectangle(cx - 2, cy + CRAFT_OFFER_H - 6, CRAFT_W + 4, 1, panel_border)
    for row in 0 ..< n {
        r := &recipe_table[vis[row]]
        y := cy + CRAFT_OFFER_H + 4 + i32(row)*CRAFT_ROW_H

        row_buf: [128]u8
        pos := 0
        s := fmt.bprintf(row_buf[pos:100], "%s x%d  <- ", item_table[r.result].name, r.result_count)
        pos += len(s)
        for ing in r.ingredients {
            if ing.item == .None do continue
            s = fmt.bprintf(row_buf[pos:120], "%d %s  ", ing.count, item_table[ing.item].name)
            pos += len(s)
        }
        if r.station != .None {
            s = fmt.bprintf(row_buf[pos:126], "%s", station_tag[r.station])
            pos += len(s)
        }

        col := recipe_craftable(gs, r) ? rl.GREEN : text_dim
        rl.DrawText(cstring(raw_data(row_buf[:])), cx + 4, y + 5, 10, col)
    }
}

// ─── Smelter Window ───────────────────────────────────────────────────────────
//
//  A 3×3 mirror of the tiles around the furnace: the center burns, the ring
//  shows the ground stacks lying beside it — the same ones tick_smelter eats.
//  Dragging ore from the bag anywhere onto this window lays it by the fire.

draw_smelter :: proc(gs: ^Game_State) {
    px   := gs.ui.win_pos[.Smelter].x
    py   := gs.ui.win_pos[.Smelter].y
    tile := gs.ui.smelter_tile
    w    := &gs.world

    pcx := i32(gs.player.pos.x + PLAYER_W*0.5)
    pcy := i32(gs.player.pos.y + PLAYER_H*0.5)
    in_reach := max(abs(tile.x - pcx), abs(tile.y - pcy)) <= BENCH_RANGE

    rl.DrawRectangle(px, py, SMELT_W, SMELT_H, NORSE_PANEL)
    rl.DrawRectangleLinesEx({f32(px), f32(py), SMELT_W, SMELT_H}, 2, NORSE_BORDER)
    rl.DrawText("SMELTER", px + 24, py + 12, 20, in_reach ? NORSE_GOLD_HOT : text_dim)
    rl.DrawText("[ESC] close", px + SMELT_W - 96, py + 16, 12, NORSE_GOLD)
    rl.DrawRectangle(px + 24, py + 38, SMELT_W - 48, 2, NORSE_BORDER)

    sd      := &w.sim_data[grid_idx(int(tile.x), int(tile.y))]
    heat    := clamp(sd.growth_timer / SMELT_TIME, 0, 1)
    burning := heat > 0

    // What lies beside the fire — drives the status line.
    has_ore, has_wood := false, false
    for dy in -1 ..= 1 do for dx in -1 ..= 1 {
        if dx == 0 && dy == 0 do continue
        nx, ny := int(tile.x) + dx, int(tile.y) + dy
        if !in_bounds(nx, ny) do continue
        it := w.items[grid_idx(nx, ny)]
        if w.item_counts[grid_idx(nx, ny)] == 0 do continue
        if it == SMELT_FUEL do has_wood = true
        for r in smelt_table do if it == r.ore { has_ore = true; break }
    }

    CELL :: SLOT_PX + 6
    x0 := px + (SMELT_W - (3*CELL - 6)) / 2
    y0 := py + 56
    for dy in i32(-1) ..= 1 {
        for dx in i32(-1) ..= 1 {
            x := x0 + (dx + 1)*CELL
            y := y0 + (dy + 1)*CELL
            if dx == 0 && dy == 0 {
                // the fire itself, glowing with smelting progress
                rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, rl.Color{30, 18, 14, 255})
                if burning {
                    glow := rl.Color{255, u8(120 + 100*heat), 50, u8(60 + 180*heat)}
                    rl.DrawCircleGradient(x + SLOT_PX/2, y + SLOT_PX/2, 16 + 8*heat, glow, rl.Color{})
                } else {
                    rl.DrawCircleGradient(x + SLOT_PX/2, y + SLOT_PX/2, 10, rl.Color{120, 60, 30, 90}, rl.Color{})
                }
                rl.DrawRectangleLinesEx({f32(x), f32(y), SLOT_PX, SLOT_PX}, 2,
                    burning ? NORSE_GOLD_HOT : NORSE_BORDER)
                continue
            }
            nx, ny := int(tile.x + dx), int(tile.y + dy)
            if !in_bounds(nx, ny) || .Solid in terrain_table[w.terrain[grid_idx(nx, ny)]].flags {
                // walled off — no stack can lie here
                rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, rl.Color{18, 14, 12, 255})
                rl.DrawRectangleLines(x, y, SLOT_PX, SLOT_PX, rl.Color{50, 42, 32, 255})
                continue
            }
            idx := grid_idx(nx, ny)
            rl.DrawRectangle(x, y, SLOT_PX, SLOT_PX, NORSE_ROW)
            rl.DrawRectangleLines(x, y, SLOT_PX, SLOT_PX, NORSE_BORDER)
            if it := w.items[idx]; it != .None && w.item_counts[idx] > 0 {
                draw_item_icon(it, x + 10, y + 8, 24)
                cnt_buf: [8]u8
                fmt.bprintf(cnt_buf[:7], "%d", w.item_counts[idx])
                rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
            }
        }
    }

    // Smelting progress toward the next bar
    bar_y := y0 + 3*CELL + 8
    rl.DrawRectangle(px + 24, bar_y, SMELT_W - 48, 10, NORSE_ROW)
    rl.DrawRectangle(px + 24, bar_y, i32(f32(SMELT_W - 48)*heat), 10, NORSE_GOLD)
    rl.DrawRectangleLines(px + 24, bar_y, SMELT_W - 48, 10, NORSE_BORDER)

    status := cstring("cold — lay ore beside the fire")
    switch {
    case burning:
        status = "the fire eats the ore"
    case has_ore && !has_wood && sd.fuel_charge == 0:
        status = "cold — the fire needs wood"
    case has_ore:
        status = "the tray blocks the cast — take the bars"
    }
    rl.DrawText(status, px + 24, bar_y + 18, 10, burning ? NORSE_GOLD_HOT : text_dim)

    // The tray: cast bars wait here — click it, or drag it onto the bag.
    tx, ty := smelter_tray_rect(gs)
    rl.DrawText("TRAY", tx, ty - 14, 10, NORSE_GOLD)
    rl.DrawRectangle(tx, ty, SLOT_PX, SLOT_PX, slot_bg)
    rl.DrawRectangleLinesEx({f32(tx), f32(ty), SLOT_PX, SLOT_PX},
        sd.store_count > 0 ? 2 : 1, sd.store_count > 0 ? rl.GREEN : NORSE_BORDER)
    if sd.store_count > 0 {
        draw_item_icon(sd.store_item, tx + 10, ty + 8, 24)
        cnt_buf: [8]u8
        fmt.bprintf(cnt_buf[:7], "%d", sd.store_count)
        rl.DrawText(cstring(raw_data(cnt_buf[:])), tx + 6, ty + SLOT_PX - 14, 10, rl.WHITE)
        rl.DrawText("click or drag to the bag", tx + SLOT_PX + 10, ty + 17, 10, text_dim)
    }

    rl.DrawText("drag ore and wood from the bag onto this window", px + 24, py + SMELT_H - 22, 10, text_dim)
    if !in_reach {
        rl.DrawText("(too far)", px + SMELT_W - 70, py + SMELT_H - 22, 10, text_dim)
    }
}

// The interactive blueprint overlay (B, or click a blueprint in the bag):
// what to gather, the build template for the altar, and the path to the cave.
draw_blueprint :: proc(gs: ^Game_State) {
    x := gs.ui.win_pos[.Blueprint].x
    y := gs.ui.win_pos[.Blueprint].y
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
        draw_item_icon(ing.item, x + 30, ry, 20)
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

