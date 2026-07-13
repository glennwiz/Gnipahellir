package game

import rl "vendor:raylib/v55"

update_input :: proc(gs: ^Game_State) {
    inp := &gs.input

    // Mouse in virtual-screen space (window -> virtual, letterbox-aware).  UI
    // hit-testing uses the UI-canvas version; gameplay uses the camera-inverse
    // below on the world-virtual coords.
    mouse := rl.GetMousePosition()
    scale, offset := screen_transform()
    vx := (mouse.x - offset.x) / scale
    vy := (mouse.y - offset.y) / scale
    inp.mouse_screen = {vx / UI_SCALE, vy / UI_SCALE}

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
    inp.mine       = rl.IsMouseButtonDown(.LEFT) && !cursor_over_ui(gs) && gs.ui.drag_item == .None
    inp.attack     = rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) && gs.ui.drag_item == .None
    inp.interact   = rl.IsKeyPressed(bind[.Interact])
    inp.drop_item  = rl.IsKeyPressed(bind[.Drop_Item])

    // The smelter window follows its furnace: if that tile stops being a
    // smelter (mined out), the window closes.
    if gs.ui.show_smelter &&
       get_tile(&gs.world, int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y)) != .Smelter {
        gs.ui.show_smelter = false
    }

    // Grabbing a floating window's header drags it; the press is eaten so it
    // doesn't also hit slots or the world.  Topmost window under the cursor
    // wins — a press on a covered window's header is blocked by the one above.
    if rl.IsMouseButtonPressed(.LEFT) && gs.ui.win_drag < 0 && gs.ui.drag_item == .None {
        mx := i32(inp.mouse_screen.x)
        my := i32(inp.mouse_screen.y)
        for w in window_top_down {
            x, y, ww, wh, open := window_rect(gs, w)
            if !open || mx < x || mx >= x + ww || my < y || my >= y + wh do continue
            if my < y + WINDOW_HEADER_H {
                gs.ui.win_drag     = int(w)
                gs.ui.win_drag_off = {mx - gs.ui.win_pos[w].x, my - gs.ui.win_pos[w].y}
                inp.mine   = false
                inp.attack = false
            }
            break  // the cursor is over this window — lower ones are covered
        }
    }
    if gs.ui.win_drag >= 0 {
        if rl.IsMouseButtonDown(.LEFT) {
            w := UI_Window(gs.ui.win_drag)
            _, _, ww, _, _ := window_rect(gs, w)
            gs.ui.win_pos[w] = {
                clamp(i32(inp.mouse_screen.x) - gs.ui.win_drag_off.x, 80 - ww, UI_W - 80),
                clamp(i32(inp.mouse_screen.y) - gs.ui.win_drag_off.y, 0, UI_H - WINDOW_HEADER_H),
            }
        } else {
            gs.ui.win_drag = -1
        }
    }

    // Clicking a station or smelter tile in reach opens its window instead of
    // striking it (the press is eaten so it doesn't also mine/attack).
    if rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) && gs.ui.drag_item == .None {
        px := i32(gs.player.pos.x + PLAYER_W*0.5)
        py := i32(gs.player.pos.y + PLAYER_H*0.5)
        in_reach := max(abs(inp.mouse_tile.x - px), abs(inp.mouse_tile.y - py)) <= BENCH_RANGE
        if st := station_at_tile(&gs.world, inp.mouse_tile.x, inp.mouse_tile.y); st != .None && in_reach {
            eq_push(&gs.events, Event{type = .Station_Interact, payload = {int_val = i32(st)}})
            inp.mine   = false
            inp.attack = false
        } else if in_reach && get_tile(&gs.world, int(inp.mouse_tile.x), int(inp.mouse_tile.y)) == .Smelter {
            eq_push(&gs.events, Event{type = .Smelter_Interact, tile = inp.mouse_tile})
            inp.mine   = false
            inp.attack = false
        }
    }

    // UI toggles
    if rl.IsKeyPressed(bind[.Inventory]) {
        gs.ui.show_inventory = !gs.ui.show_inventory
    }
    if rl.IsKeyPressed(bind[.Crafting]) {
        gs.ui.show_crafting = !gs.ui.show_crafting
        if gs.ui.show_crafting {
            gs.ui.active_station = .None  // the hotkey is hand crafting only
            gs.ui.show_inventory = true   // the anvil drags from the bag
        }
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
        if gs.ui.show_inventory || gs.ui.show_crafting || gs.ui.show_blueprint || gs.ui.show_smelter {
            // First ESC sweeps every window closed; the next one opens the menu.
            gs.ui.show_inventory = false
            gs.ui.show_crafting  = false
            gs.ui.show_blueprint = false
            gs.ui.show_smelter   = false
            gs.ui.drag_item      = .None
            gs.ui.drag_tray      = false
        } else {
            gs.ui.show_menu = true
        }
    }

    // Clicks on open UI panels (skipped while a window is being dragged)
    if rl.IsMouseButtonPressed(.LEFT) && gs.ui.win_drag < 0 {
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
                // Grabbing a bag stack starts a drag while the anvil or the
                // furnace can take it
                if gs.ui.show_crafting || gs.ui.show_smelter {
                    s := gs.player.inventory.slots[slot]
                    if s.item != .None && s.count > 0 {
                        gs.ui.drag_item = s.item
                        gs.ui.drag_slot = slot
                    }
                }
            }
        }
        // Grabbing the smelter tray starts a drag of the cast bars.
        if gs.ui.show_smelter && gs.ui.drag_item == .None {
            tx, ty := smelter_tray_rect(gs)
            mx := i32(inp.mouse_screen.x)
            my := i32(inp.mouse_screen.y)
            if mx >= tx && mx < tx + SLOT_PX && my >= ty && my < ty + SLOT_PX {
                sd := gs.world.sim_data[grid_idx(int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y))]
                if sd.store_count > 0 {
                    gs.ui.drag_item = sd.store_item
                    gs.ui.drag_tray = true
                }
            }
        }
        if gs.ui.show_crafting {
            if off := craft_offer_at_cursor(gs); off >= 0 {
                gs.ui.craft_offer[off] = .None  // take an offering back off the anvil
            } else if idx := craft_result_at_cursor(gs); idx >= 0 {
                eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = i32(idx)}})
            } else if row := recipe_at_cursor(gs); row >= 0 {
                // A hint row lays its materials on the anvil for you
                for ing, i in recipe_table[row].ingredients {
                    gs.ui.craft_offer[i] = ing.item
                }
            }
        }
    }

    // Dropping a dragged stack onto an anvil slot offers it (a reference —
    // the items stay in the bag).  Anything already offered is not doubled.
    // Dropping onto the smelter window feeds the furnace instead — that one
    // really moves the stack out of the bag onto a cell beside the fire.
    if rl.IsMouseButtonReleased(.LEFT) && gs.ui.drag_item != .None {
        if gs.ui.drag_tray {
            // Dropping the tray on the bag — or a click-in-place on the tray
            // itself — empties it into the inventory.
            if cursor_in_window(gs, .Inventory) || cursor_in_window(gs, .Smelter) {
                eq_push(&gs.events, Event{type = .Smelter_Collect, tile = gs.ui.smelter_tile})
            }
            gs.ui.drag_tray = false
        } else if off := craft_offer_at_cursor(gs); off >= 0 {
            already := false
            for it in gs.ui.craft_offer do if it == gs.ui.drag_item do already = true
            if !already do gs.ui.craft_offer[off] = gs.ui.drag_item
        } else if cursor_in_window(gs, .Smelter) {
            eq_push(&gs.events, Event{
                type    = .Smelter_Feed,
                tile    = gs.ui.smelter_tile,
                payload = {int_val = i32(gs.ui.drag_slot)},
            })
        }
        gs.ui.drag_item = .None
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

        // Armed stamp: the next world click sets the armed tile where it lands
        // (the arming click itself is over the menu, which cursor_over_ui eats).
        if gs.debug.place_tile != .Air && rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) {
            x, y := int(inp.mouse_tile.x), int(inp.mouse_tile.y)
            set_tile(&gs.world, x, y, gs.debug.place_tile)
            notify(gs, "Debug: %s stamped at (%d,%d)", terrain_table[gs.debug.place_tile].name, x, y)
            gs.debug.place_tile = .Air
            inp.mine   = false  // the stamp click must not also chip or swing
            inp.attack = false
        }

        if gs.debug.menu_open && rl.IsMouseButtonPressed(.LEFT) {
            switch debug_menu_row_at_cursor(gs) {
            case 0: gs.debug.fly        = !gs.debug.fly
            case 1: gs.debug.ultra_wand = !gs.debug.ultra_wand
            case 2: debug_unlock_level_portals(gs)
            case 3: debug_add_all_structures(gs)
            case 4: debug_add_resources(gs)
            case 5: gs.player.hp = gs.player.hp_max
            case 6: gs.player.mana = gs.player.mana_max
            case 7:
                gs.debug.place_tile = .Dimension_Spawner
                gs.debug.menu_open  = false
                notify(gs, "Debug: click a tile to stamp the Metal spawner")
            case 8:
                gs.debug.place_tile = .Dimension_Spawner_Gold
                gs.debug.menu_open  = false
                notify(gs, "Debug: click a tile to stamp the Gold spawner")
            case 9:
                inventory_insert(&gs.player.inventory, .Auto_Miner, 1)
                notify(gs, "Debug: Auto-Miner in the bag — place it inside a dimension")
            case 10:
                gs.debug.life = !gs.debug.life
                if gs.debug.life {
                    gs.debug.life_timer = 0
                    gs.debug.life_gen   = 0
                    notify(gs, "The world stirs — Conway wakes")
                } else {
                    notify(gs, "The world settles after %d generations", gs.debug.life_gen)
                }
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
