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

// Blueprint overlay — centered panel.
BP_W :: 540
BP_H :: 360
BP_X :: (SCREEN_W - BP_W) / 2
BP_Y :: (SCREEN_H - BP_H) / 2

panel_bg     :: rl.Color{15, 15, 25, 230}
panel_border :: rl.Color{90, 90, 120, 255}
slot_bg      :: rl.Color{35, 35, 50, 255}
text_dim     :: rl.Color{140, 140, 150, 255}

// ─── Debug Menu (F1, debug builds only) ───────────────────────────────────────

DBG_MENU_X     :: 24
DBG_MENU_Y     :: 80
DBG_MENU_W     :: 200
DBG_MENU_ROW_H :: 24
DBG_MENU_ROWS  :: 2   // row 0: fly mode; row 1: ultra wand

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

    uw_col := gs.debug.ultra_wand ? rl.GREEN : text_dim
    rl.DrawText(gs.debug.ultra_wand ? cstring("Ultra wand: ON") : cstring("Ultra wand: OFF"),
        DBG_MENU_X, DBG_MENU_Y + DBG_MENU_ROW_H + 7, 10, uw_col)

    if r := debug_menu_row_at_cursor(gs); r >= 0 {
        rl.DrawRectangleLines(DBG_MENU_X - 2, DBG_MENU_Y + i32(r)*DBG_MENU_ROW_H + 1,
            DBG_MENU_W + 4, DBG_MENU_ROW_H - 2, rl.YELLOW)
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
    if gs.ui.show_blueprint &&
       mx >= BP_X && mx < BP_X + BP_W &&
       my >= BP_Y && my < BP_Y + BP_H {
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
    if gs.ui.show_blueprint do draw_blueprint(gs)
    if gs.game_won do draw_win_screen(gs)
    when GAME_DEBUG {
        if gs.debug.menu_open do draw_debug_menu(gs)
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
