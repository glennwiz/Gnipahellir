package game

import rl "vendor:raylib/v55"
import "core:fmt"

// ─── UI Layout (virtual-resolution pixels) ────────────────────────────────────
//
//  Constants shared by draw procs here and hit-testing in input.odin.

INV_COLS :: 8
INV_ROWS :: 3
SLOT_PX  :: 44
INV_X    :: 24
INV_Y    :: SCREEN_H - INV_ROWS*SLOT_PX - 32

CRAFT_X     :: INV_X + INV_COLS*SLOT_PX + 32
CRAFT_Y     :: INV_Y
CRAFT_W     :: 430
CRAFT_ROW_H :: 26

panel_bg     :: rl.Color{15, 15, 25, 230}
panel_border :: rl.Color{90, 90, 120, 255}
slot_bg      :: rl.Color{35, 35, 50, 255}
text_dim     :: rl.Color{140, 140, 150, 255}

// ─── Debug Menu (F1, debug builds only) ───────────────────────────────────────

DBG_MENU_X     :: 24
DBG_MENU_Y     :: 80
DBG_MENU_W     :: 200
DBG_MENU_ROW_H :: 24
DBG_MENU_ROWS  :: 1   // row 0: fly mode

// Menu row under the cursor, or -1.
debug_menu_row_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_world.x)
    my := i32(gs.input.mouse_world.y)
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

    if debug_menu_row_at_cursor(gs) == 0 {
        rl.DrawRectangleLines(DBG_MENU_X - 2, DBG_MENU_Y + 1, DBG_MENU_W + 4, DBG_MENU_ROW_H - 2, rl.YELLOW)
    }
}

// True when the cursor is over an open UI panel (blocks mining/placing).
cursor_over_ui :: proc(gs: ^Game_State) -> bool {
    mx := i32(gs.input.mouse_world.x)
    my := i32(gs.input.mouse_world.y)
    when GAME_DEBUG {
        if gs.debug.menu_open &&
           mx >= DBG_MENU_X - 6 && mx < DBG_MENU_X + DBG_MENU_W + 6 &&
           my >= DBG_MENU_Y - 26 && my < DBG_MENU_Y + DBG_MENU_ROWS*DBG_MENU_ROW_H + 8 {
            return true
        }
    }
    if gs.ui.show_inventory &&
       mx >= INV_X && mx < INV_X + INV_COLS*SLOT_PX &&
       my >= INV_Y && my < INV_Y + INV_ROWS*SLOT_PX {
        return true
    }
    if gs.ui.show_crafting &&
       mx >= CRAFT_X && mx < CRAFT_X + CRAFT_W &&
       my >= CRAFT_Y && my < CRAFT_Y + i32(len(recipe_table))*CRAFT_ROW_H + 8 {
        return true
    }
    return false
}

// Inventory slot under the cursor, or -1.
slot_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_world.x)
    my := i32(gs.input.mouse_world.y)
    if mx < INV_X || my < INV_Y do return -1
    c := int((mx - INV_X) / SLOT_PX)
    r := int((my - INV_Y) / SLOT_PX)
    if c < 0 || c >= INV_COLS || r < 0 || r >= INV_ROWS do return -1
    return r*INV_COLS + c
}

// Crafting row under the cursor, or -1.
recipe_at_cursor :: proc(gs: ^Game_State) -> int {
    mx := i32(gs.input.mouse_world.x)
    my := i32(gs.input.mouse_world.y)
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
    when GAME_DEBUG {
        if gs.debug.menu_open do draw_debug_menu(gs)
    }
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
    sel := gs.player.inventory.slots[gs.player.inventory.selected]
    if sel.item != .None && sel.count > 0 {
        fmt.bprintf(name_buf[:63], "%s   [%s x%d]",
            level_names[gs.level_index], item_table[sel.item].name, sel.count)
    } else {
        fmt.bprintf(name_buf[:63], "%s", level_names[gs.level_index])
    }
    rl.DrawText(cstring(raw_data(name_buf[:])), 24, 50, 10, rl.WHITE)
}

draw_inventory :: proc(gs: ^Game_State) {
    inv := &gs.player.inventory
    rl.DrawRectangle(INV_X - 6, INV_Y - 6, INV_COLS*SLOT_PX + 12, INV_ROWS*SLOT_PX + 12, panel_bg)
    rl.DrawRectangleLines(INV_X - 6, INV_Y - 6, INV_COLS*SLOT_PX + 12, INV_ROWS*SLOT_PX + 12, panel_border)

    for i in 0 ..< MAX_INVENTORY {
        c := i32(i % INV_COLS)
        r := i32(i / INV_COLS)
        x := i32(INV_X) + c*SLOT_PX
        y := i32(INV_Y) + r*SLOT_PX
        rl.DrawRectangle(x + 2, y + 2, SLOT_PX - 4, SLOT_PX - 4, slot_bg)

        s := inv.slots[i]
        if s.item != .None && s.count > 0 {
            rl.DrawRectangle(x + 10, y + 8, 24, 24, item_table[s.item].color)
            cnt_buf: [8]u8
            fmt.bprintf(cnt_buf[:7], "%d", s.count)
            rl.DrawText(cstring(raw_data(cnt_buf[:])), x + 6, y + SLOT_PX - 14, 10, rl.WHITE)
        }
        if i == inv.selected {
            rl.DrawRectangleLines(x + 1, y + 1, SLOT_PX - 2, SLOT_PX - 2, rl.YELLOW)
        }
    }

    // Name of the hovered slot's item
    if hov := slot_at_cursor(gs); hov >= 0 {
        s := inv.slots[hov]
        if s.item != .None && s.count > 0 {
            rl.DrawText(cstring(raw_data(item_table[s.item].name)), INV_X, INV_Y - 20, 10, rl.WHITE)
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
    mx := i32(gs.input.mouse_world.x)
    my := i32(gs.input.mouse_world.y)
    rl.DrawText(cstring(raw_data(tip_buf[:])), mx + 12, my - 4, 10, rl.WHITE)
}

// Runic seals over locked portals on the active level.
draw_portal_seals :: proc(gs: ^Game_State) {
    for &p in level_portals[gs.level_index] {
        if !portal_valid(&p) do continue
        if p.gate_tier < 0 || gs.progression.cave_unlocked[p.gate_tier] do continue
        for t in p.tiles {
            x := t.x * CELL_SIZE
            y := t.y * CELL_SIZE
            seal := rl.Color{220, 40, 40, 220}
            rl.DrawRectangleLines(x, y, CELL_SIZE, CELL_SIZE, seal)
            rl.DrawLine(x, y, x + CELL_SIZE, y + CELL_SIZE, seal)
            rl.DrawLine(x + CELL_SIZE, y, x, y + CELL_SIZE, seal)
        }
    }
}
