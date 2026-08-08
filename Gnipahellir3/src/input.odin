package game

import rl "vendor:raylib"

GOLEM_ZONE_DRAG_THRESHOLD :: f32(6)

golem_zone_drag_ready :: proc(start,now:[2]f32) -> bool {
	dx,dy:=now.x-start.x,now.y-start.y
	return dx*dx+dy*dy>=GOLEM_ZONE_DRAG_THRESHOLD*GOLEM_ZONE_DRAG_THRESHOLD
}

// Rasterize between sampled mouse positions so a fast sweep or distant zoom
// cannot leave holes in a painted tunnel.
golem_queue_paint_line :: proc(gs:^Game_State,a,b:[2]i32,mark:bool) {
	x0,y0,x1,y1:=a.x,a.y,b.x,b.y
	dx:=abs(x1-x0); sx:=i32(1) if x0<x1 else -1
	dy:=-abs(y1-y0); sy:=i32(1) if y0<y1 else -1
	err:=dx+dy
	for {
		if in_bounds(int(x0),int(y0)) {
			eq_push(&gs.events,Event{type=.Golem_Mark if mark else .Golem_Unmark,tile={x0,y0}})
		}
		if x0==x1 && y0==y1 do break
		e2:=2*err
		if e2>=dy {err+=dy; x0+=sx}
		if e2<=dx {err+=dx; y0+=sy}
	}
}

// Wheel zoom request. A plain notch zooms the player-centered view and glides
// any ALT offset home, so the hero is never left off screen. With ALT held, capture
// the world point beneath the cursor so update_camera can keep that pixel under
// the pointer throughout the eased zoom.
request_zoom :: proc(gs: ^Game_State, wheel: f32, cursor: [2]f32, to_cursor: bool) {
    next := clamp(gs.zoom_target + wheel*ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
    if next == gs.zoom_target do return

    // A followed body owns the framing (camera.odin): both wheel paths then just
    // change the zoom, so neither the cursor anchor nor "back to the hero" can
    // take the view off the worker you are watching.
    if to_cursor && gs.cam_follow_kind == .None {
        cam := game_camera(gs)
        gs.zoom_anchor_screen = cursor
        gs.zoom_anchor_world = {
            (cursor.x - cam.offset.x)/cam.zoom + cam.target.x,
            (cursor.y - cam.offset.y)/cam.zoom + cam.target.y,
        }
        gs.zoom_cursor_active = true
    } else {
        gs.zoom_cursor_active = false
        if gs.cam_follow_kind == .None do camera_begin_recenter(gs)
    }
    // Restart the glide from where the view actually is and at the pace it
    // already carries (camera.odin), so a notch landing mid-glide retargets
    // smoothly instead of snapping and braking.  Sample the framing before
    // zoom_target moves — it is the old glide's endpoint.
    from_target := game_camera(gs).target
    gs.zoom_target = next
    camera_begin_zoom_glide(gs, from_target)
}

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

    // ALT is the camera modifier: wheel zooms toward the cursor instead of the
    // player, and a held mouse button drags the view.  Shift stays free for
    // deliberate reclaim.  A plain wheel notch keeps the view on the player.
    alt_down := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
    if wheel := rl.GetMouseWheelMove(); wheel != 0 {
        request_zoom(gs, wheel, {vx, vy}, alt_down)
    }

    // ALT+drag pan (either button — both their world actions are suppressed
    // while ALT is held, below).  Releasing leaves the view where you put it;
    // it glides back to the player as soon as you move.
    mouse_held := rl.IsMouseButtonDown(.LEFT) || rl.IsMouseButtonDown(.RIGHT)
    if gs.cam_dragging && (!alt_down || !mouse_held) do gs.cam_dragging = false
    if alt_down && !gs.cam_dragging && !cursor_over_ui(gs) && gs.ui.drag_item == .None &&
       (rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT)) {
        gs.cam_dragging  = true
        gs.cam_drag_last = {vx, vy}
    }
    // Only a cursor that actually moved is a pan: a still ALT+click is how you
    // pick a body to follow (below), and camera_pan_drag takes the view off it.
    if gs.cam_dragging {
        d := [2]f32{vx - gs.cam_drag_last.x, vy - gs.cam_drag_last.y}
        if d.x != 0 || d.y != 0 {
            camera_pan_drag(gs, d)
            gs.cam_drag_last = {vx, vy}
        }
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

    // Title screen: any key or click advances to the character-select.
    if gs.ui.show_title {
        if rl.GetKeyPressed() != .KEY_NULL ||
           rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
            gs.ui.show_title      = false
            gs.ui.show_charselect = true
        }
        return
    }

    // Character-select: click a form card or press its number (1..N) to choose
    // a look and drop into the world. Nothing else runs while it's up.
    if gs.ui.show_charselect {
        chosen := -1
        if rl.IsMouseButtonPressed(.LEFT) {
            chosen = charselect_card_at_cursor(gs)
        }
        for n in 0 ..< PLAYER_FORM_COUNT {
            if rl.IsKeyPressed(rl.KeyboardKey(i32(rl.KeyboardKey.ONE) + i32(n))) {
                chosen = n
            }
        }
        if chosen >= 0 {
            gs.player_form        = Player_Form(chosen)
            gs.ui.show_charselect = false
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

    // The instruction tome the ritual leaves: E / ESC / click turns the last
    // page and the world resumes (the sim is frozen while it's open — see
    // game_update).
    if gs.ui.show_book {
        if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(gs.bindings[.Interact]) ||
           rl.IsMouseButtonPressed(.LEFT) {
            gs.ui.show_book = false
        }
        return
    }

    // Rebindable keys come from the bindings table (settings screen); arrows
    // and space stay as fixed movement/jump alternates.
    bind := gs.bindings
    shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
    // ALT claims the mouse for the camera, so no mining/placing/zone painting
    // happens under a pan drag.
    world_mouse := !cursor_over_ui(gs) && gs.ui.drag_item == .None && !alt_down
    command_active := equipped_command_wand(gs) != .None
	if !command_active {
		gs.ui.golem_zone_press=false
		gs.ui.golem_zone_drag=false
	}
	if command_active && shift_down {
		gs.ui.golem_zone_press=false
		gs.ui.golem_zone_drag=false
	}
    inp.move_left  = rl.IsKeyDown(bind[.Move_Left])  || rl.IsKeyDown(.LEFT)
    inp.move_right = rl.IsKeyDown(bind[.Move_Right]) || rl.IsKeyDown(.RIGHT)
    inp.jump       = rl.IsKeyPressed(bind[.Jump]) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.SPACE)
    inp.mine       = rl.IsMouseButtonDown(.LEFT) && world_mouse && !shift_down
    inp.attack     = rl.IsMouseButtonPressed(.LEFT) && world_mouse && !shift_down
    inp.reclaim    = rl.IsMouseButtonDown(.LEFT) && world_mouse && shift_down
    inp.interact   = rl.IsKeyPressed(bind[.Interact])
    if command_active {
        inp.mine = false
        inp.attack = false
        inp.reclaim = false
    }

    // Player-built equipment always wins over mining. Normal click uses it;
    // Shift+hold is handled separately by update_reclaim.
    hover_t := get_tile(&gs.world, int(inp.mouse_tile.x), int(inp.mouse_tile.y))
    if is_structure_tile[hover_t] || is_rune_scroll_chest(hover_t) {
        inp.mine = false
        inp.attack = false
    }

    // The smelter window follows its furnace: if that tile stops being a
    // smelter (mined out), the window closes.
    if gs.ui.show_smelter &&
       get_tile(&gs.world, int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y)) != .Smelter {
        gs.ui.show_smelter = false
    }
    if gs.ui.show_barrel {
        container_t := get_tile(&gs.world, int(gs.ui.barrel_tile.x), int(gs.ui.barrel_tile.y))
        if container_t != .Barrel && container_t != .Rune_Coffer && !is_rune_scroll_chest(container_t) {
            gs.ui.show_barrel = false
        }
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
            gs.ui.win_moved[w] = true  // hand-placed now — auto-layout won't touch it
        } else {
            gs.ui.win_drag = -1
        }
    }

    // The bottom-center placement chip is a shortcut to the bag: click it to
    // toggle the inventory (mine/attack were already suppressed over the chip).
    if rl.IsMouseButtonPressed(.LEFT) && sel_chip_hovered(gs) && gs.ui.win_drag < 0 && gs.ui.drag_item == .None {
        gs.ui.show_inventory = !gs.ui.show_inventory
        if gs.ui.show_inventory && !gs.ui.show_crafting do place_bag_centered(gs)
    }

    // The rune scroll chip beside it: click to toggle the rune scroll overlay —
    // the same action as the [B] key.
    if rl.IsMouseButtonPressed(.LEFT) && rs_chip_hovered(gs) && gs.ui.win_drag < 0 && gs.ui.drag_item == .None {
        gs.ui.show_rune_scroll = !gs.ui.show_rune_scroll
    }

    // The command-wand strip chooses a monument plan; selecting the active
    // plan again returns the wand to Gather-zone painting.
    if command_active && rl.IsMouseButtonPressed(.LEFT) && !alt_down {
        if plan := golem_plan_button_at_cursor(gs); plan != .None {
            gs.ui.golem_plan = .None if gs.ui.golem_plan == plan else plan
        }
    }

    // ALT+click hands the camera to the body under the cursor — a worker or a
    // builder — and it rides that body (through zooming too) until you drag the
    // view, walk, click empty ground, or it is gone.  ALT already suppresses
    // every world action, so this press mines/orders nothing.
    if alt_down && rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) && gs.ui.drag_item == .None {
        if gid := golem_at_world_point(gs, inp.mouse_world); gid >= 0 {
            camera_follow_entity(gs, .Golem, gid)
        } else if eid := enemy_at_world_point(gs, inp.mouse_world); eid >= 0 {
            camera_follow_entity(gs, .Enemy, eid)
        } else {
            camera_stop_follow(gs)
        }
    }

    // Machines get the exact tile click; the golem uses its visible padded
    // body. Empty world only arms a zone gesture—it does not alter the order
    // unless the cursor subsequently crosses the deliberate drag threshold.
    if rl.IsMouseButtonPressed(.LEFT) && world_mouse {
		if command_active {
			gs.ui.golem_zone_press=false
			gs.ui.golem_zone_drag=false
		}
        if !shift_down && is_rune_scroll_chest(hover_t) {
            // Queue this like barrel interaction so the newly opened window
            // cannot consume the same mouse press that clicked the world chest.
            eq_push(&gs.events, Event{type = .Barrel_Interact, tile = inp.mouse_tile})
        } else if !shift_down && is_structure_tile[hover_t] {
            eq_push(&gs.events, Event{type = .Structure_Interact, tile = inp.mouse_tile})
		} else if gid:=golem_at_world_point(gs,inp.mouse_world); command_active && gid>=0 {
			eq_push(&gs.events,Event{
				type=.Golem_Recall if shift_down else .Golem_Toggle,
				payload={int_val=i32(gid)},
			})
        } else if command_active && !shift_down {
            if gs.ui.golem_plan != .None {
                eq_push(&gs.events, Event{type = .Golem_Project, tile = inp.mouse_tile,
                    payload = {int_val = i32(gs.ui.golem_plan)}})
            } else {
				gs.ui.golem_zone_press = true
                gs.ui.golem_zone_start = inp.mouse_tile
				gs.ui.golem_zone_press_screen=inp.mouse_screen
            }
        }
    }

	if command_active && gs.ui.golem_zone_press && rl.IsMouseButtonDown(.LEFT) &&
	   golem_zone_drag_ready(gs.ui.golem_zone_press_screen,inp.mouse_screen) {
		gs.ui.golem_zone_drag=true
	}
	if gs.ui.golem_zone_press && rl.IsMouseButtonReleased(.LEFT) {
		if command_active && gs.ui.golem_zone_drag && world_mouse && inp.mouse_tile!=gs.ui.golem_zone_start {
			a:=gs.ui.golem_zone_start
			packed:=u32(a.x)|(u32(a.y)<<16)
			eq_push(&gs.events,Event{type=.Golem_Zone,tile=inp.mouse_tile,
				payload={int_val=i32(packed)}})
		}
		gs.ui.golem_zone_press=false
		gs.ui.golem_zone_drag=false
	}

	// Precision excavation brush. Shift keeps normal rectangle painting out of
	// the way; left tags blocks and right erases tags. A direct Shift-click on a
	// golem remains Recall and is deliberately not also painted beneath it.
	paint_button:=i8(0)
	if rl.IsMouseButtonDown(.LEFT) do paint_button=1
	if rl.IsMouseButtonDown(.RIGHT) do paint_button=2
	if command_active && shift_down && world_mouse && paint_button!=0 {
		left_on_golem:=paint_button==1 && golem_at_world_point(gs,inp.mouse_world)>=0
		if !left_on_golem && (inp.golem_paint_button!=paint_button || inp.golem_paint_last!=inp.mouse_tile) {
			start:=inp.mouse_tile
			if inp.golem_paint_button==paint_button do start=inp.golem_paint_last
			golem_queue_paint_line(gs,start,inp.mouse_tile,paint_button==1)
			inp.golem_paint_last=inp.mouse_tile
		}
		inp.golem_paint_button=paint_button
	} else {
		inp.golem_paint_button=0
	}

    if command_active && rl.IsKeyPressed(bind[.Golem_Crew]) {
        eq_push(&gs.events, Event{type = .Golem_Crew_Toggle})
    }

    // UI toggles. TAB with any window open sweeps them all shut (like ESC);
    // otherwise it opens your inventory + crafting together. Factorio-style:
    // crafting has no key of its own — it's the panel beside the bag, and the
    // recipe list grows to whatever station is in range.
    if rl.IsKeyPressed(bind[.Inventory]) {
        if gs.ui.show_inventory || gs.ui.show_crafting || gs.ui.show_rune_scroll || gs.ui.show_smelter || gs.ui.show_barrel {
            gs.ui.show_inventory = false
            gs.ui.show_crafting  = false
            gs.ui.show_rune_scroll = false
            gs.ui.show_smelter   = false
            gs.ui.show_barrel    = false
            gs.ui.drag_item      = .None
            gs.ui.drag_tray      = false
            gs.ui.drag_input     = false
            gs.ui.drag_barrel    = -1
            gs.ui.drag_void      = false
        } else {
            // Standing at a station? Its recipes fill the panel; otherwise hand
            // crafting. Scanned fresh here — input runs before station-focus.
            gs.ui.active_station, _ = nearest_station(gs)
            gs.ui.show_inventory = true
            gs.ui.show_crafting  = true
            place_craft_pair(gs)   // center the bag+craft pair so nothing spills
        }
    }
    if rl.IsKeyPressed(bind[.Rune_Scroll]) {
        gs.ui.show_rune_scroll = !gs.ui.show_rune_scroll
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
        if gs.ui.show_inventory || gs.ui.show_crafting || gs.ui.show_rune_scroll || gs.ui.show_smelter || gs.ui.show_barrel || gs.ui.show_pixel_editor {
            // First ESC sweeps every window closed; the next one opens the menu.
            gs.ui.show_inventory    = false
            gs.ui.show_crafting     = false
            gs.ui.show_rune_scroll    = false
            gs.ui.show_smelter      = false
            gs.ui.show_barrel       = false
            gs.ui.show_pixel_editor = false
            gs.ui.drag_item      = .None
            gs.ui.drag_tray      = false
            gs.ui.drag_input     = false
            gs.ui.drag_barrel    = -1
            gs.ui.drag_void      = false
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
                if is_rune_scroll(gs.player.inventory.slots[slot].item) {
                    gs.ui.show_rune_scroll = true  // clicking a rune scroll opens its overlay
                }
                // Grabbing a bag stack starts a drag: released on a furnace or
                // barrel window it feeds/stores; released on the open world it
                // drops a ground pile (for the auto-pull hoppers).
                s := gs.player.inventory.slots[slot]
                if s.item != .None && s.count > 0 {
                    shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
                    if shift && s.count > 1 {
                        eq_push(&gs.events, Event{
                            type    = .Inventory_Split,
                            payload = {int_val = i32(slot)},
                        })
                    } else {
                        gs.ui.drag_item   = s.item
                        gs.ui.drag_slot   = slot
                        gs.ui.drag_barrel = -1   // source is the bag, not a barrel
                        gs.ui.drag_void   = false
                    }
                }
            }
        }
        // The Jade Ring's button: click (not drag) to warp to the surface.
        if gs.ui.show_inventory && gs.ui.drag_item == .None && warp_button_hovered(gs) {
            eq_push(&gs.events, Event{type = .Warp_Home_Request})
        }
        // The last voided stack is an undo buffer: drag it back onto a bag
        // slot before replacing it if it should be kept.
        if gs.ui.show_inventory && gs.ui.drag_item == .None && void_slot_hovered(gs) {
            s := gs.player.void_slot
            if s.item != .None && s.count > 0 {
                gs.ui.drag_item = s.item
                gs.ui.drag_slot = -1
                gs.ui.drag_void = true
            }
        }
        // Grabbing a filled barrel slot starts a drag of that stack toward the bag.
        if gs.ui.show_barrel && gs.ui.drag_item == .None {
            if bslot := barrel_slot_at_cursor(gs); bslot >= 0 {
                if b := barrel_at(gs, gs.level_index, gs.ui.barrel_tile); b != nil {
                    s := b.slots[bslot]
                    if s.item != .None && s.count > 0 {
                        gs.ui.drag_item   = s.item
                        gs.ui.drag_slot   = -1
                        gs.ui.drag_barrel = bslot
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
        // Grabbing the smelter INPUT slot starts a drag to pull the ore back out.
        if gs.ui.show_smelter && gs.ui.drag_item == .None {
            ix, iy := smelter_input_rect(gs)
            mx := i32(inp.mouse_screen.x)
            my := i32(inp.mouse_screen.y)
            if mx >= ix && mx < ix + SLOT_PX && my >= iy && my < iy + SLOT_PX {
                sd := gs.world.sim_data[grid_idx(int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y))]
                if sd.in_count > 0 {
                    gs.ui.drag_item  = sd.in_item
                    gs.ui.drag_input = true
                }
            }
        }
        if gs.ui.show_crafting {
            // Click the CRAFT button to forge the shown recipe; else click a
            // recipe card to select it.
            if craft_button_hovered(gs) {
                if sel := craft_selected_recipe(gs); sel >= 0 {
                    eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = i32(sel)}})
                }
            } else if card := craft_card_at_cursor(gs); card >= 0 {
                gs.ui.craft_selected = card
            }
        }
    }

    // Dropping a dragged stack onto an anvil slot offers it (a reference —
    // the items stay in the bag).  Anything already offered is not doubled.
    // Dropping onto the smelter window feeds the furnace instead — that one
    // really moves the stack out of the bag onto a cell beside the fire.
    if rl.IsMouseButtonReleased(.LEFT) && gs.ui.drag_item != .None {
        if gs.ui.drag_void {
            // Recover only onto a real bag cell. Elsewhere the stack remains
            // safely buffered, including a click-and-release on the VOID box.
            if target := slot_at_cursor(gs); target >= 0 {
                eq_push(&gs.events, Event{type = .Void_Take, tile = {i32(target), 0}})
            }
            gs.ui.drag_void = false
        } else if gs.ui.drag_tray {
            // Dropping the tray on the bag — or a click-in-place on the tray
            // itself — empties it into the inventory.
            if cursor_in_window(gs, .Inventory) || cursor_in_window(gs, .Smelter) {
                eq_push(&gs.events, Event{type = .Smelter_Collect, tile = gs.ui.smelter_tile})
            }
            gs.ui.drag_tray = false
        } else if gs.ui.drag_input {
            // Dropping the INPUT slot on the bag — or a click-in-place — pulls
            // the loaded ore back out of the furnace.
            if cursor_in_window(gs, .Inventory) || cursor_in_window(gs, .Smelter) {
                eq_push(&gs.events, Event{type = .Smelter_Withdraw, tile = gs.ui.smelter_tile})
            }
            gs.ui.drag_input = false
        } else if gs.ui.drag_barrel >= 0 {
            // Dragging a container item out — drop it on the bag to withdraw it.
            if cursor_in_window(gs, .Inventory) {
                eq_push(&gs.events, Event{
                    type    = .Barrel_Take,
                    tile    = gs.ui.barrel_tile,
                    payload = {int_val = i32(gs.ui.drag_barrel)},
                })
            }
            gs.ui.drag_barrel = -1
        } else if void_slot_hovered(gs) {
            // This is the deliberate destructive edge: the handler moves the
            // bag stack in and erases whatever the buffer previously showed.
            eq_push(&gs.events, Event{
                type    = .Void_Store,
                payload = {int_val = i32(gs.ui.drag_slot)},
            })
        } else if win, at_win := window_at_cursor(gs); at_win {
            // Whichever window is topmost at the cursor claims the drop — a
            // window drawn over the bag (e.g. a chest) must win even though
            // the bag's own rect also contains this point.
            #partial switch win {
            case .Inventory:
                // Bag-to-bag drag: move to an empty slot, consolidate a matching
                // stack, or swap unlike items. Releasing on the source is a no-op.
                if target := slot_at_cursor(gs); target >= 0 && target != gs.ui.drag_slot {
                    eq_push(&gs.events, Event{
                        type    = .Inventory_Move,
                        tile    = {i32(target), 0},
                        payload = {int_val = i32(gs.ui.drag_slot)},
                    })
                }
            case .Barrel:
                // Dragging a bag stack onto the barrel deposits it.
                eq_push(&gs.events, Event{
                    type    = .Barrel_Store,
                    tile    = gs.ui.barrel_tile,
                    payload = {int_val = i32(gs.ui.drag_slot)},
                })
            case .Smelter:
                eq_push(&gs.events, Event{
                    type    = .Smelter_Feed,
                    tile    = gs.ui.smelter_tile,
                    payload = {int_val = i32(gs.ui.drag_slot)},
                })
            }
        } else if !cursor_over_ui(gs) {
            // Released over the open world — drop the stack as a ground pile.
            eq_push(&gs.events, Event{
                type    = .Item_Drop,
                tile    = gs.input.mouse_tile,
                payload = {int_val = i32(gs.ui.drag_slot)},
            })
        }
        gs.ui.drag_item = .None
        gs.ui.drag_void = false
    }

    // Right-click in the open bag equips the item; on an equip box, unequips.
    if rl.IsMouseButtonPressed(.RIGHT) && gs.ui.show_inventory {
        if slot := slot_at_cursor(gs); slot >= 0 {
            if gs.player.inventory.slots[slot].item == .Clay_Golem {
                eq_push(&gs.events, Event{type = .Golem_Load, payload = {int_val = i32(slot)}})
            } else {
                eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = i32(slot)}})
            }
        } else if es := equip_slot_at_cursor(gs); es != .None {
            eq_push(&gs.events, Event{type = .Unequip_Request, payload = {int_val = i32(es)}})
        }
    }

    // Right-click places the selected item.  Hold and sweep to "draw" a run of
    // blocks — one per tile — until the bag runs dry (the handler stops when the
    // stack hits zero).  Fires on a fresh press or when the cursor crosses into a
    // new tile, so holding still doesn't re-fire (which would spam the
    // special-item rejection toasts and churn the event queue).
    if command_active && !shift_down && !alt_down && rl.IsMouseButtonPressed(.RIGHT) && !cursor_over_ui(gs) {
        eq_push(&gs.events, Event{type = .Golem_Deploy, tile = inp.mouse_tile})
    } else if !command_active && !alt_down && rl.IsMouseButtonDown(.RIGHT) && !cursor_over_ui(gs) {
        if rl.IsMouseButtonPressed(.RIGHT) || inp.mouse_tile != inp.place_last {
            eq_push(&gs.events, Event{type = .Place_Request, tile = inp.mouse_tile})
            inp.place_last = inp.mouse_tile
        }
    }
    when GAME_DEBUG {
        if rl.IsKeyPressed(.F3) {
            gs.ui.show_debug = !gs.ui.show_debug
        }
        if rl.IsKeyPressed(.F1) {
            gs.debug.menu_open = !gs.debug.menu_open
        }
        if rl.IsKeyPressed(.F2) {
            gs.debug.altar_menu = !gs.debug.altar_menu
        }
        inp.fly_up   = rl.IsKeyDown(bind[.Jump]) || rl.IsKeyDown(.UP) || rl.IsKeyDown(.SPACE)
        inp.fly_down = rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)

        // Armed stamp: the next world click sets the armed tile where it lands
        // (the arming click itself is over the menu, which cursor_over_ui eats).
        if gs.debug.place_tile != .Air && rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) {
            x, y := int(inp.mouse_tile.x), int(inp.mouse_tile.y)
            set_tile(&gs.world, x, y, gs.debug.place_tile)
            notify(gs, "Debug: %s stamped at (%d,%d)", terrain_table[gs.debug.place_tile].name, x, y)
            // A surface Sky Altar stamp raises the gate, as real placement would.
            if gs.debug.place_tile == .Sky_Altar && gs.level_index == LEVEL_SURFACE {
                gs.progression.sky_altar_pos = {i32(x), i32(y)}
                notify(gs, "The Sky Altar rises - a portal opens to the heavens!")
                spawn_deep_rune_scroll(gs)
            }
            gs.debug.place_tile = .Air
            inp.mine   = false  // the stamp click must not also chip or swing
            inp.attack = false
        }
		if gs.debug.place_golem && rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) {
			_ = debug_golem_deploy(gs,inp.mouse_tile)
			gs.debug.place_golem=false
			inp.mine=false
			inp.attack=false
		}

        // Armed altar stamp (F2 menu): the next world click raises the tier's
        // full sky structure — foundation and capstone — at the clicked tile.
        if gs.debug.place_tier > 0 && rl.IsMouseButtonPressed(.LEFT) && !cursor_over_ui(gs) {
            x, y := int(inp.mouse_tile.x), int(inp.mouse_tile.y)
            debug_stamp_altar_template(gs, gs.debug.place_tier - 1, x, y)
            gs.debug.place_tier = 0
            inp.mine   = false
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
				gs.debug.place_golem = false
                gs.debug.menu_open  = false
                notify(gs, "Debug: click a tile to stamp the Metal spawner")
            case 8:
                gs.debug.place_tile = .Dimension_Spawner_Gold
				gs.debug.place_golem = false
                gs.debug.menu_open  = false
                notify(gs, "Debug: click a tile to stamp the Gold spawner")
            case 9:
                inventory_insert(&gs.player.inventory, .Auto_Miner, 1)
                notify(gs, "Debug: Auto-Miner in the bag - place it inside a dimension")
            case 10:
                if inventory_insert(&gs.player.inventory,.Command_Wand,1) {
                    notify(gs,"Debug: Clay Command Wand added to the bag")
                } else {
                    notify(gs,"Debug: bag full - Command Wand not added")
                }
            case 11:
				gs.debug.place_tile=.Air
				gs.debug.place_tier=0
				gs.debug.place_golem=true
				gs.debug.menu_open=false
				notify(gs,"Debug: click an open grounded tile to place a Clay Golem")
            case 12:
                gs.debug.life = !gs.debug.life
                if gs.debug.life {
                    gs.debug.life_timer = 0
                    gs.debug.life_gen   = 0
                    notify(gs, "The world stirs - Conway wakes")
                } else {
                    notify(gs, "The world settles after %d generations", gs.debug.life_gen)
                }
            case 13:
                gs.ui.show_pixel_editor = !gs.ui.show_pixel_editor
                gs.debug.menu_open      = false
            }
        }

        // Pixel Art Editor: paint/erase/cycle-sprite/save/clear. Debug-only
        // direct mutation of gs.pixel_art, same exception the menu above uses.
        if gs.ui.show_pixel_editor {
            if rl.IsMouseButtonDown(.LEFT) {
                if sw := palette_swatch_at_cursor(gs); sw >= 0 {
                    gs.ui.pixel_editor_color = u8(sw) // slot 0 = eraser, N = color N
                } else if c, r, ok := pixel_cell_at_cursor(gs); ok {
                    data := &gs.pixel_art.sprites[gs.ui.pixel_editor_target]
                    if !data.has_data {
                        // First stroke: start from the real original look, not blank.
                        data.grid = seed_pixel_grid(gs.ui.pixel_editor_target)
                    }
                    data.grid[r][c] = gs.ui.pixel_editor_color
                    data.has_data   = true
                }
            }
            if rl.IsMouseButtonPressed(.LEFT) {
                switch pixel_editor_button_at_cursor(gs) {
                case 0: // Prev
                    n := len(Pixel_Sprite_ID)
                    gs.ui.pixel_editor_target = Pixel_Sprite_ID((int(gs.ui.pixel_editor_target) + n - 1) % n)
                case 1: // Next
                    n := len(Pixel_Sprite_ID)
                    gs.ui.pixel_editor_target = Pixel_Sprite_ID((int(gs.ui.pixel_editor_target) + 1) % n)
                case 2: // Save
                    eq_push(&gs.events, Event{type = .Pixel_Art_Save})
                case 3: // Clear
                    gs.pixel_art.sprites[gs.ui.pixel_editor_target] = {}
                }
            }
        }

        if gs.debug.altar_menu && rl.IsMouseButtonPressed(.LEFT) {
            switch r := altar_menu_row_at_cursor(gs); r {
            case 0:
                gs.debug.place_tile = .Sky_Altar
				gs.debug.place_golem = false
                gs.debug.altar_menu = false
                notify(gs, "Debug: click a tile to stamp the Sky Altar")
            case 1:
                gs.debug.place_tile = .Rune_Altar
				gs.debug.place_golem = false
                gs.debug.altar_menu = false
                notify(gs, "Debug: click a tile to stamp the Rune Altar")
            case 2, 3, 4:
                gs.debug.place_tier = r - 1  // tier + 1
				gs.debug.place_golem = false
                gs.debug.altar_menu = false
                notify(gs, "Debug: click a tile to raise the %s", structure_templates[r-2].name)
            case 5:
                for t in 0 ..< MAX_PROGRESSION_TIERS do gs.progression.rune_scroll_found[t] = true
                notify(gs, "Debug: all rune scrolls found")
            case 6:
                debug_complete_next_ritual(gs)
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
