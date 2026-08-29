package game

import "core:math"

// ─── Event Queue ──────────────────────────────────────────────────────────────

eq_push :: proc(eq: ^Event_Queue, e: Event) {
    if eq.size >= MAX_EVENTS {  // drop when full; game_update logs the count in debug
        eq.dropped += 1
        return
    }
    eq.events[eq.tail] = e
    eq.tail = (eq.tail + 1) % MAX_EVENTS
    eq.size += 1
}

eq_pop :: proc(eq: ^Event_Queue) -> (Event, bool) {
    if eq.size == 0 do return {}, false
    e := eq.events[eq.head]
    eq.head = (eq.head + 1) % MAX_EVENTS
    eq.size -= 1
    return e, true
}

eq_clear :: proc(eq: ^Event_Queue) {
    eq.head = 0
    eq.tail = 0
    eq.size = 0
}

// ─── Event Processing ─────────────────────────────────────────────────────────

// The event trace's exclusion list — the ONLY events kept out of the log, and
// only because they are pure audio/visual noise with no bearing on what
// happened in the world.  Everything else is traced, including the types with
// no handler and no bespoke line: the point is that a run reconstructs from
// the log, and a type nobody thought worth announcing is exactly the one
// missing when a mystery turns up.
//
// Direct handler calls (a raider calling handle_tile_mined itself) bypass this
// trace entirely and are covered at handler level instead.
@(rodata)
event_log_skip := #partial [Event_Type]bool{
    .Play_Sound        = true,  // audio cue, nothing else
    .Projectile_Impact = true,  // spawns an impact burst, nothing else
}

process_events :: proc(gs: ^Game_State) {
    for {
        e, ok := eq_pop(&gs.events)
        if !ok do break

        when GAME_DEBUG {
            if !event_log_skip[e.type] {
                log_action(gs, "evt %v src=%d tgt=%d tile=(%d,%d) val=%d",
                    e.type, e.source, e.target, e.tile.x, e.tile.y, e.payload.int_val)
            }
        }

        // Autosave trigger: meaningful player actions mark the run dirty (movement
        // never does).  One save is written at frame end (main loop).
        #partial switch e.type {
        case .Tile_Placed, .Item_Pickup, .Item_Drop, .Tile_Mined, .Craft_Complete, .Rune_Scroll_Found, .Structure_Complete, .Smelter_Feed, .Smelter_Collect, .Smelter_Withdraw, .Barrel_Store, .Barrel_Take, .Golem_Load, .Golem_Deploy, .Golem_Toggle, .Golem_Recall, .Golem_Crew_Toggle, .Golem_Zone, .Golem_Project, .Golem_Hearth_Use, .Golem_Damaged, .Golem_Mark, .Golem_Unmark, .Golem_Set_Mode, .Golem_Pickup:
            gs.save_dirty = true
        }

        #partial switch e.type {
        case .Player_Moved:
            // informational; no handler yet

        case .Enemy_Moved:
            // informational; no handler yet

        case .Damage_Dealt:
            if e.target == PLAYER_ID {
                if !gs.player.dead {
                    dmg := int(e.payload.int_val)
                    // Armor blunts enemy blows but never below 1 — no gear
                    // set makes an enemy harmless; the world (lava, falls —
                    // source INVALID_ENTITY) strikes past it.
                    if e.source != PLAYER_ID && e.source != INVALID_ENTITY {
                        dmg = max(dmg - int(player_stat(&gs.player, .Defense)), 1)
                    }
                    if dmg > 0 {
                        gs.player.hp -= dmg
                        audio_play(&gs.audio, .Hurt)
                        spawn_damage_number(&gs.floating_text,
                            {gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y}, dmg, DAMAGE_COLOR)
                        src_buf: [32]u8
                        log_action(gs, "Player takes %d damage from %s (hp %d)",
                            dmg, entity_name(gs, e.source, src_buf[:]), gs.player.hp)
                        if gs.player.hp <= 0 {
                            gs.player.hp = 0
                            eq_push(&gs.events, Event{type = .Entity_Died, source = PLAYER_ID})
                        }
                    } else {
                        log_action(gs, "Player's armor absorbs the blow")
                    }
                }
            } else {
                i := entity_id_to_enemy_index(e.target)
                if i >= 0 && i < MAX_ENEMIES && gs.enemies.active[i] {
                    en := &gs.enemies.data[i]
                    en.hp -= int(e.payload.int_val)
                    audio_play(&gs.audio, .Sword_Hit)
                    // The hit is SEEN: a gold damage number pops off the body
                    // and its blood sprays away from whoever struck it.
                    ec := [2]f32{en.pos.x + 0.5, en.pos.y + 0.5}
                    spawn_damage_number(&gs.floating_text, {ec.x, en.pos.y}, int(e.payload.int_val), ENEMY_HIT_COLOR)
                    dir := [2]f32{f32(en.facing), 0}
                    if e.source == PLAYER_ID {
                        pc := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.5}
                        d  := ec - pc
                        dist := math.sqrt(d.x*d.x + d.y*d.y)
                        if dist > 0.1 do dir = d / dist
                    }
                    spawn_hit_burst(gs, ec, dir, enemy_blood[en.kind])
                    src_buf: [32]u8
                    log_action(gs, "Enemy#%d(%v) takes %d damage from %s (hp %d)",
                        i, en.kind, e.payload.int_val, entity_name(gs, e.source, src_buf[:]), en.hp)
                    if en.hp <= 0 {
                        eq_push(&gs.events, Event{type = .Entity_Died, source = e.target})
                    } else if en.kind == .Builder && e.source == PLAYER_ID {
                        builder_alert(gs, i)   // a wounded builder retaliates
                    }
                }
            }

        case .Entity_Died:
            handle_entity_died(gs, e)

        case .Tile_Mined:
            handle_tile_mined(gs, e)

        case .Tile_Placed:
            // tile already set before event was pushed
            audio_play(&gs.audio, .Place)
            // Machines teach themselves on placement.
            #partial switch get_tile(&gs.world, int(e.tile.x), int(e.tile.y)) {
            case .Smelter:
                notify(gs, "Click the smelter and drag ore in - it casts bars")
            case .Tree_Grower:
                notify(gs, "The grower raises a tree when open sky is above")
            case .Boiler:
                notify(gs, "Set it beside water and stoke it with wood - its steam rises")
            case .Steam_Engine:
                notify(gs, "Feed it pooled steam - machines within 3 tiles run fast and free")
            case .Gem_Replicator:
                notify(gs, "Drop a gem beside it - it grows more of that gem")
            }

        case .Lava_Spread:
            // Unused: fluid flow (fluid.odin) walks the grid on its own clock
            // rather than announcing every cell it moves, which would swamp
            // the queue.  The event is kept only because Event_Type is frozen.

        case .Tree_Grew:
            audio_play(&gs.audio, .Place, audio_tile_gain(gs, e.tile))
            spawn_grow_burst(gs, e.tile)

        case .Mushroom_Grew:
            audio_play(&gs.audio, .Place, audio_tile_gain(gs, e.tile))
            spawn_mushroom_glow(gs, e.tile)

        case .Item_Pickup:
            audio_play(&gs.audio, .Pickup)
            #partial switch Item(e.payload.int_val) {
            case .Rune_Scroll_A:
                eq_push(&gs.events, Event{type = .Rune_Scroll_Found, payload = {int_val = 0}})
            case .Rune_Scroll_B:
                eq_push(&gs.events, Event{type = .Rune_Scroll_Found, payload = {int_val = 1}})
            case .Rune_Scroll_C:
                eq_push(&gs.events, Event{type = .Rune_Scroll_Found, payload = {int_val = 2}})
            case .Hell_Key:
                // Not the win anymore: the key turns the Hell_Gate Garm's
                // death tore open — the Final Seal beyond it ends the run.
                notify(gs, "The Hell Key burns cold - it turns the gate Garm guarded")
            case .Sky_Rune_Scroll:
                notify(gs, "Sky Rune Scroll found - raise a Sky Altar to open the way above (B)")
            case .Pickaxe:
                // First pickaxe: teach the hotbar and the core verb.
                // One-shot so a dropped-and-repicked pick doesn't nag.
                if !gs.pickaxe_hint_shown {
                    gs.pickaxe_hint_shown = true
                    notify(gs, "Select the pickaxe (number keys 1-8), then hold left-click to mine")
                }
            case .Wood_Log:
                // First log: teach hand-crafting — the hidden bootstrap verb
                // (logs → planks → your first bench).  One-shot.
                if !gs.craft_hint_shown {
                    gs.craft_hint_shown = true
                    notify(gs, "Press [%v] to open your bag and craft - turn logs into planks", gs.bindings[.Inventory])
                }
            }

        case .Craft_Request:
            handle_craft_request(gs, e)

        case .Craft_Complete:
            audio_play(&gs.audio, .Pickup)
            crafted := Item(e.payload.int_val)
            spawn_craft_burst(gs, crafted)
            // First wand: inert in the bag until it's the selected slot.
            if is_wand(crafted) && !gs.wand_hint_shown {
                gs.wand_hint_shown = true
                notify(gs, "Hold the wand (select its slot) to mine at range")
            }
            if crafted == .Command_Wand {
                notify(gs, "Hold the Command Wand; right-click crafted golems to bind them")
            }

        case .Station_Interact:
            gs.ui.active_station = Station(e.payload.int_val)
            gs.ui.show_crafting  = true
            gs.ui.show_inventory = true  // the anvil drags from the bag
            place_craft_pair(gs)         // center the pair so nothing spills off-screen
            log_action(gs, "Player opens %v station", gs.ui.active_station)

        case .Smelter_Interact:
            gs.ui.show_smelter   = true
            gs.ui.smelter_tile   = e.tile
            gs.ui.show_inventory = true  // the furnace feeds from the bag
            log_action(gs, "Player opens smelter at (%d,%d)", e.tile.x, e.tile.y)

        case .Smelter_Feed:
            smelter_feed(gs, e.tile, int(e.payload.int_val))

        case .Smelter_Collect:
            smelter_collect(gs, e.tile)

        case .Smelter_Withdraw:
            smelter_withdraw(gs, e.tile)

        case .Barrel_Interact:
            if is_rune_scroll_chest(get_tile(&gs.world, int(e.tile.x), int(e.tile.y))) {
                open_rune_scroll_chest(gs, e.tile)
            } else {
                gs.ui.show_barrel    = true
                gs.ui.barrel_tile    = e.tile
                gs.ui.show_inventory = true  // the barrel trades with the bag
                log_action(gs, "Player opens barrel at (%d,%d)", e.tile.x, e.tile.y)
            }

        case .Barrel_Store:
            if b := barrel_at(gs, gs.level_index, e.tile); b != nil {
                barrel_store(gs, b, int(e.payload.int_val))
            }

        case .Barrel_Take:
            if b := barrel_at(gs, gs.level_index, e.tile); b != nil {
                slot := int(e.payload.int_val)
                if is_rune_scroll_chest(get_tile(&gs.world, int(e.tile.x), int(e.tile.y))) &&
                   slot >= 0 && slot < BARREL_SLOTS && is_rune_scroll(b.slots[slot].item) {
                    rune_scroll_chest_take(gs, b, slot)
                } else {
                    barrel_take(gs, b, slot)
                }
            }

        case .Projectile_Fired:
            // damage/impact handled in update_projectiles
            audio_play(&gs.audio, .Fireball, audio_tile_gain(gs, e.tile))

        case .Projectile_Impact:
            spawn_orb_impact(gs, e.tile)

        case .Play_Sound:
            // A tile-stamped Play_Sound is a world sound (a machine's puff,
            // golem work) and dies away with distance; a tile-less one is a
            // deliberate global cue (a shriek, the boss roar) at full gain.
            gain := f32(1)
            if e.tile != {0, 0} do gain = audio_machine_gain(gs, e.tile)
            audio_play(&gs.audio, Sound_ID(e.payload.int_val), gain)

        case .Play_Music:
            // music tracks land in Phase 7

        case .Stop_Music:
            // music tracks land in Phase 7

        case .Level_Enter:
            // transition already performed by level_transition
            lvl := int(e.payload.int_val)
            if lvl == LEVEL_DIMENSION {
                notify(gs, "- %s -", dimension_table[gs.dimension.kind].name)
            } else if lvl >= 0 && lvl < NUM_LEVELS {
                notify(gs, "- %s -", level_names[lvl])
            }
            garm_maybe_awaken(gs)

        case .Level_Exit:
            // informational; no handler yet

        case .Level_Locked:
            tier := int(e.payload.int_val)
            switch {
            case gs.progression.sky_altar_pos == {0, 0}:
                notify(gs, "Sealed by runes - raise a Sky Altar on the Surface first")
            case tier >= 0 && tier < MAX_PROGRESSION_TIERS && !gs.progression.rune_scroll_found[tier]:
                notify(gs, "Sealed by runes - find %s %s",
                    item_table[tier_rune_scrolls[tier]].name, rune_scroll_places[tier])
            case:
                notify(gs, "Sealed by runes - the sky ritual will break the seal")
            }

        case .Player_Died:
            gs.player.dead = true

        case .Rune_Scroll_Found:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.rune_scroll_found[tier] = true
                // Rune Scrolls aren't inspectable yet — surface the ritual
                // cost at pickup so the player knows what to gather.
                c := structure_costs[tier]
                notify(gs, "Rune Scroll! Altar ritual needs %d %s + %d %s",
                    c[0].count, item_table[c[0].item].name,
                    c[1].count, item_table[c[1].item].name)
            }

        case .Structure_Complete:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.sky_structure_complete[tier] = true
                audio_play(&gs.audio, .Fanfare)
                notify(gs, "Sky structure complete!")
                eq_push(&gs.events, Event{
                    type    = .Cave_Unlocked,
                    payload = e.payload,
                })
            }

        case .Cave_Unlocked:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.cave_unlocked[tier] = true
                switch tier {
                case 0: notify(gs, "The seal on %s has broken", level_names[LEVEL_CAVE2])
                case 1: notify(gs, "The seal on %s has broken", level_names[LEVEL_CAVE3])
                case 2:
                    notify(gs, "The final depths tremble...")
                    garm_maybe_awaken(gs)  // ritual completed while inside cave 3
                }
            }

        case .Boss_Defeated:
            gs.progression.final_boss_defeated = true
            audio_play(&gs.audio, .Fanfare)
            notify(gs, "GARM has fallen - claim the Hell Key!")

        case .Builder_Mined:
            audio_play(&gs.audio, .Builder_Dig, audio_tile_gain(gs, e.tile))

        case .Builder_Placed:
            audio_play(&gs.audio, .Builder_Place, audio_tile_gain(gs, e.tile))

        case .Place_Request:
            handle_place_request(gs, e)

        case .Item_Drop:
            handle_item_drop(gs, e)

        case .Ritual_Request:
            handle_ritual_request(gs)

        case .Equip_Request:
            // Right-click routes here: read a scroll, drink a consumable, else
            // equip the gear.
            slot := int(e.payload.int_val)
            if slot >= 0 && slot < MAX_INVENTORY && item_is_readable(gs.player.inventory.slots[slot].item) {
                player_read(gs, slot)
            } else if slot >= 0 && slot < MAX_INVENTORY && item_is_consumable(gs.player.inventory.slots[slot].item) {
                player_consume(gs, slot)
            } else {
                player_equip(gs, slot)
            }

        case .Unequip_Request:
            player_unequip(gs, Equip_Slot(e.payload.int_val))

        case .Warp_Home_Request:
            player_warp_home(gs)

        case .New_Game_Request:
            start_new_game(gs)

        case .Quit_Request:
            gs.quit_requested = true

        case .Inventory_Split:
            inventory_split_stack(gs, int(e.payload.int_val))

        case .Inventory_Move:
            inventory_move_stack(gs, int(e.payload.int_val), int(e.tile.x))

        case .Void_Store:
            void_slot_store(gs, int(e.payload.int_val))

        case .Void_Take:
            void_slot_take(gs, int(e.tile.x))

        case .Golem_Load:
            golem_load(gs, int(e.payload.int_val))

        case .Golem_Deploy:
            golem_deploy(gs, e.tile)

        case .Golem_Toggle:
            golem_toggle(gs, int(e.payload.int_val))

        case .Golem_Recall:
            golem_recall(gs, int(e.payload.int_val))

        case .Golem_Crew_Toggle:
            golem_crew_toggle(gs)

        case .Golem_Zone:
            packed := u32(e.payload.int_val)
            start := [2]i32{i32(packed & 0xffff), i32((packed >> 16) & 0xffff)}
            golem_set_zone(gs, start, e.tile)

        case .Golem_Project:
            golem_project_start(gs, Golem_Plan(e.payload.int_val), e.tile)

        case .Golem_Hearth_Use:
            golem_hearth_use(gs)

        case .Golem_Damaged:
            golem_damage(gs, int(e.tile.x), int(e.payload.int_val))

        case .Golem_Mark:
            golem_set_block_mark(gs,e.tile,true)

        case .Golem_Unmark:
            golem_set_block_mark(gs,e.tile,false)

        case .Golem_Set_Mode:
            v := e.payload.int_val
            golem_set_mode(gs, int(v & 0xff), Golem_Mode(v >> 8))

        case .Golem_Call_To_Me:
            golem_call(gs, int(e.payload.int_val))

        case .Golem_Pickup:
            golem_pickup(gs, int(e.payload.int_val))

        case .Pixel_Art_Save:
            if save_pixel_art(gs) {
                notify(gs, "Pixel art saved")
            } else {
                notify(gs, "Pixel art save failed")
            }

        case .Structure_Interact:
            structure_interact(gs, e.tile)

        case .Structure_Reclaim:
            // Revalidate at completion in case a machine filled on the last tick.
            if block := structure_reclaim_block(gs, e.tile); block != .None {
                notify_reclaim_block(gs, block)
            } else {
                handle_tile_mined(gs, Event{type = .Tile_Mined, source = PLAYER_ID, tile = e.tile})
                gs.save_dirty = true
            }

        case .Game_Won:
            if !gs.game_won {
                gs.game_won = true
                gs.stats.runs_played += 1
                gs.stats.runs_won    += 1
                _ = save_stats(&gs.stats)   // the victory survives even a crash
                audio_play(&gs.audio, .Fanfare)
                log_action(gs, "GAME WON after %.0f s, %d kills",
                    gs.elapsed_time, gs.stats.total_kills)
            }
        }
    }
}

handle_entity_died :: proc(gs: ^Game_State, e: Event) {
    if e.source == PLAYER_ID {
        pt := player_tile(&gs.player)
        log_action(gs, "Player dies at (%d,%d) after %.0f s", pt.x, pt.y, gs.elapsed_time)
        eq_push(&gs.events, Event{type = .Player_Died})
        audio_play(&gs.audio, .Death)
        gs.stats.runs_played += 1
        _ = save_stats(&gs.stats)  // persist immediately — a crash after death shouldn't lose the run
    } else {
        i := entity_id_to_enemy_index(e.source)
        if i >= 0 && i < MAX_ENEMIES && gs.enemies.active[i] {
            en := &gs.enemies.data[i]
            // A felled builder does not die — it claws back up as a draugr.
            // The kill (count, drops, sound) is deferred to the draugr's death.
            if en.kind == .Builder {
                rise_draugr(gs, i)
                return
            }
            T := builder_tile(en)
            audio_play(&gs.audio, .Kill)
            gs.stats.total_kills += 1
            log_action(gs, "Enemy#%d(%v) dies at (%d,%d)", i, en.kind, T.x, T.y)
            roll_enemy_drops(gs, en.kind, T)   // loot lands where they fell
            if en.kind == .Garm {
                log_action(gs, "GARM slain - Hell Key drops at (%d,%d)", T.x, T.y)
                garm_open_hell_gate(gs, en)
                eq_push(&gs.events, Event{type = .Boss_Defeated})
            }
        }
        despawn_enemy(gs, i)
    }
}

handle_tile_mined :: proc(gs: ^Game_State, e: Event) {
    x := int(e.tile.x)
    y := int(e.tile.y)
    if !in_bounds(x, y) do return

    idx := grid_idx(x, y)
    old_tile := gs.world.terrain[idx]

    // A loaded silo is too heavy to lift — nothing is ever lost from one.
    if old_tile == .Silo {
        if s := silo_at(gs, gs.level_index, e.tile); s != nil {
            if silo_total(s) > 0 {
                notify(gs, "The silo is too heavy to break - empty it first ([%v] beside it)",
                    gs.bindings[.Interact])
                log_action(gs, "mine refused: loaded silo at (%d,%d)", x, y)
                return
            }
        }
        silo_on_mined(gs, e.tile)
    }

    // A loaded barrel refuses the pick — empty it before reclaiming the wood.
    // Rune coffers (and the sealed chests they come from) share the record
    // book, so they share the rule: nothing stored is ever lost to a reclaim.
    if old_tile == .Barrel || old_tile == .Rune_Coffer || is_rune_scroll_chest(old_tile) {
        // A chest whose rune scroll is still inside stays put — the scroll is
        // the progression find, and prising the coffer loose must never be the
        // thing that swallows it.
        if is_rune_scroll_chest(old_tile) && rune_scroll_chest_holds_scroll(gs, e.tile) {
            notify(gs, "Take the rune scroll first")
            log_action(gs, "mine refused: %v still holds its rune scroll at (%d,%d)", old_tile, x, y)
            return
        }
        if b := barrel_at(gs, gs.level_index, e.tile); b != nil {
            if barrel_total(b) > 0 {
                notify(gs, "The chest is full - empty it before you break it")
                log_action(gs, "mine refused: loaded %v at (%d,%d)", old_tile, x, y)
                return
            }
        }
        barrel_on_mined(gs, e.tile)
    }

    drop := terrain_table[old_tile].drop_item
    // Chance drops roll a per-tile hash — deterministic per run, so the
    // yield can't be re-rolled by save-scumming.
    if pct := terrain_table[old_tile].drop_pct; pct > 0 {
        if whash(u32(idx)*2246822519 + 101) % 100 >= u32(pct) do drop = .None
    }

    // The loose stratum the cave mouth cuts through pays a clod of dirt on top
    // of the tile's normal drop — a small starter reward for digging right
    // beside the descent shaft (the tiles draw_shaft_mouth scuffs brown).  The
    // rock drops to the ground as usual; the dirt is banked directly (below) —
    // into the PLAYER's bag, so only the player's own mining earns it.
    shaft_earth := e.source == PLAYER_ID &&
        gs.level_index == LEVEL_SURFACE && in_shaft_apron(&gs.world, x, y)

    // Mining into a den's structure is a break-in: the owner hunts — but only
    // a PLAYER break-in. Raiders route their demolition through Tile_Mined
    // too (update_raider), and a machine standing in a den footprint must not
    // make its owner hunt the player over a raider's smash — the shriek
    // notify would blame the player for a crime they watched happen.
    if owner := den_owner_index(gs, e.tile); owner >= 0 && e.source == PLAYER_ID {
        builder_alert(gs, owner)
    }

    // Reclaiming the Auto-Miner's base releases the dimension anchor.
    if old_tile == .Auto_Miner && gs.dimension.miner.active &&
       gs.dimension.miner.base == e.tile {
        miner_on_mined(gs)
    }

    // Release valve: while a miner anchors a world, reclaiming ANY spawner
    // of that kind also releases the anchor — losing the original spawner
    // tile can no longer lock every dimension gate in the game.
    if gs.dimension.miner.active && gs.level_index != LEVEL_DIMENSION &&
       old_tile == dimension_spawner_tile[gs.dimension.kind] {
        miner_on_mined(gs)
    }

    // Mined tiles open to air above the surface line, to void underground
    fill: Tile_Type = .Void
    if gs.level_index == LEVEL_SKY || (gs.level_index == LEVEL_SURFACE && y < SURFACE_Y) {
        fill = .Air
    }
    // Ground truth for the whole demolition story: one line naming WHO took
    // this tile.  Every mine funnels through here - the player's pick and wand,
    // a reclaim, and the raiders and sprites that call this handler directly
    // instead of queueing an event - so the bespoke flavor lines elsewhere add
    // intent on top of this rather than being the only record.
    actor_buf: [32]u8
    log_action(gs, "%s %s %v at (%d,%d)",
        entity_name(gs, e.source, actor_buf[:]),
        e.source == PLAYER_ID ? "mines" : "smashes", old_tile, x, y)

    set_tile(&gs.world, x, y, fill)
    golem_remove_block_mark(gs,e.tile)
    gs.world.tile_flags[idx] -= {.Placed,.Golem_Placed} // the placed block is gone
    audio_play(&gs.audio, .Mine)

    // Cutting this tile may leave a tree (or a wood/leaf build) hanging — drop
    // whatever just lost its last link to the ground.
    gravity_check_removed(gs, x, y)

    if drop != .None {
        // The drop lands on the mined cell when it can, and rings outward when
        // a different pile (or a capped one) already lies there — a mined
        // tile's payout is never voided.
        spawn_ground_item(&gs.world, e.tile, drop, 1)
    }

    // The dirt half of the payout flies straight into the bag with a collect
    // mote; a full bag falls back to a ground drop so nothing is silently lost.
    if shaft_earth {
        if inventory_insert(&gs.player.inventory, .Dirt, 1) {
            spawn_collect_mote(gs, e.tile, .Dirt)
        } else {
            spawn_ground_item(&gs.world, e.tile, .Dirt, 1)
        }
    }

    // A mined smelter, boiler or gem replicator spills its tray, its loaded
    // input AND its fuel — nothing in the machine is lost.  (The replicator's
    // in_* is its seed gem; its fuel_count is always 0, a harmless no-op.)
    // Timers and buffers die with the tile so a future machine starts fresh.
    sd := &gs.world.sim_data[idx]
    boiler_rule, is_boiler := boiler_rule_for(old_tile)
    if old_tile == .Smelter || old_tile == .Gem_Replicator || is_boiler {
        fuel := is_boiler ? boiler_rule.fuel_item : FUEL_ITEM
        if sd.store_count > 0 {
            spawn_ground_item(&gs.world, e.tile, sd.store_item, int(sd.store_count))
        }
        if sd.in_count > 0 {
            spawn_ground_item(&gs.world, e.tile, sd.in_item, int(sd.in_count))
        }
        if sd.fuel_count > 0 {
            spawn_ground_item(&gs.world, e.tile, fuel, int(sd.fuel_count))
        }
    }
    sd^ = {}

    // A door is two tiles: mining one half takes the whole door.  The generic
    // path above already dropped a single Door for this half; remove the partner
    // (no second drop) so no half is left standing.
    if old_tile == .Door {
        if px, py, ok := door_partner(&gs.world, x, y); ok {
            pidx := grid_idx(px, py)
            golem_remove_block_mark(gs,{i32(px),i32(py)})
            gs.world.tile_flags[pidx] -= {.Placed,.Golem_Placed}
            set_tile(&gs.world, px, py, gravity_open_tile(gs, py))
            gravity_check_removed(gs, px, py)
        }
    }
}
