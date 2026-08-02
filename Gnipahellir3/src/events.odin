package game

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

process_events :: proc(gs: ^Game_State) {
    for {
        e, ok := eq_pop(&gs.events)
        if !ok do break

        // Autosave trigger: meaningful player actions mark the run dirty (movement
        // never does).  One save is written at frame end (main loop).
        #partial switch e.type {
        case .Tile_Placed, .Item_Pickup, .Tile_Mined, .Craft_Complete, .Blueprint_Found, .Structure_Complete, .Smelter_Feed, .Smelter_Collect:
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
                        log_action(gs, "Player takes %d damage (hp %d)", dmg, gs.player.hp)
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
                    log_action(gs, "Enemy#%d takes %d damage (hp %d)", i, e.payload.int_val, en.hp)
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
                notify(gs, "Click the smelter and drag ore in — it casts bars")
            case .Tree_Grower:
                notify(gs, "The grower raises a tree when open sky is above")
            }

        case .Lava_Spread:
            // sim system not implemented yet (Phase 4+)

        case .Tree_Grew:
            audio_play(&gs.audio, .Place, audio_tile_gain(gs, e.tile))
            spawn_grow_burst(gs, e.tile)

        case .Item_Pickup:
            audio_play(&gs.audio, .Pickup)
            #partial switch Item(e.payload.int_val) {
            case .Blueprint_A:
                eq_push(&gs.events, Event{type = .Blueprint_Found, payload = {int_val = 0}})
            case .Blueprint_B:
                eq_push(&gs.events, Event{type = .Blueprint_Found, payload = {int_val = 1}})
            case .Blueprint_C:
                eq_push(&gs.events, Event{type = .Blueprint_Found, payload = {int_val = 2}})
            case .Hell_Key:
                eq_push(&gs.events, Event{type = .Game_Won})
            case .Sky_Blueprint:
                notify(gs, "Sky Blueprint found — raise a Sky Altar to open the way above (B)")
            case .Pickaxe:
                // First pickaxe: teach the core verb.  One-shot so a dropped-
                // and-repicked pick doesn't nag.
                if !gs.pickaxe_hint_shown {
                    gs.pickaxe_hint_shown = true
                    notify(gs, "Pickaxe in hand — hold left-click by a wall to mine")
                }
            case .Wood_Log:
                // First log: teach hand-crafting — the hidden bootstrap verb
                // (logs → planks → your first bench).  One-shot.
                if !gs.craft_hint_shown {
                    gs.craft_hint_shown = true
                    notify(gs, "Press [%v] to craft — turn logs into planks", gs.bindings[.Crafting])
                }
            }

        case .Craft_Request:
            handle_craft_request(gs, e)

        case .Craft_Complete:
            audio_play(&gs.audio, .Pickup)
            crafted := Item(e.payload.int_val)
            spawn_craft_burst(gs, crafted)
            // First wand: it's weapon-slot gear now, inert in the bag until worn.
            if is_wand(crafted) && !gs.wand_hint_shown {
                gs.wand_hint_shown = true
                notify(gs, "Equip the wand (right-click it in the bag) to mine at range")
            }

        case .Station_Interact:
            gs.ui.active_station = Station(e.payload.int_val)
            gs.ui.show_crafting  = true
            gs.ui.show_inventory = true  // the anvil drags from the bag
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

        case .Projectile_Fired:
            // damage/impact handled in update_projectiles
            audio_play(&gs.audio, .Fireball, audio_tile_gain(gs, e.tile))

        case .Projectile_Impact:
            // impact particles land in Phase 7

        case .Play_Sound:
            audio_play(&gs.audio, Sound_ID(e.payload.int_val))

        case .Play_Music:
            // music tracks land in Phase 7

        case .Stop_Music:
            // music tracks land in Phase 7

        case .Level_Enter:
            // transition already performed by level_transition
            lvl := int(e.payload.int_val)
            if lvl == LEVEL_DIMENSION {
                notify(gs, "— %s —", dimension_table[gs.dimension.kind].name)
            } else if lvl >= 0 && lvl < NUM_LEVELS {
                notify(gs, "— %s —", level_names[lvl])
            }
            garm_maybe_awaken(gs)

        case .Level_Exit:
            // informational; no handler yet

        case .Level_Locked:
            tier := int(e.payload.int_val)
            switch {
            case gs.progression.sky_altar_pos == {0, 0}:
                notify(gs, "Sealed by runes — raise a Sky Altar on the Surface first")
            case tier >= 0 && tier < MAX_PROGRESSION_TIERS && !gs.progression.blueprint_found[tier]:
                notify(gs, "Sealed by runes — find %s %s",
                    item_table[tier_blueprints[tier]].name, blueprint_places[tier])
            case:
                notify(gs, "Sealed by runes — the sky ritual will break the seal")
            }

        case .Player_Died:
            gs.player.dead = true

        case .Blueprint_Found:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.blueprint_found[tier] = true
                // Blueprints aren't inspectable yet — surface the ritual
                // cost at pickup so the player knows what to gather.
                c := structure_costs[tier]
                notify(gs, "Blueprint! Altar ritual needs %d %s + %d %s",
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
            notify(gs, "GARM has fallen — claim the Hell Key!")

        case .Builder_Mined:
            audio_play(&gs.audio, .Builder_Dig, audio_tile_gain(gs, e.tile))

        case .Builder_Placed:
            audio_play(&gs.audio, .Builder_Place, audio_tile_gain(gs, e.tile))

        case .Place_Request:
            handle_place_request(gs, e)

        case .Ritual_Request:
            handle_ritual_request(gs)

        case .Equip_Request:
            // Right-click routes here: drink a consumable, else equip the gear.
            slot := int(e.payload.int_val)
            if slot >= 0 && slot < MAX_INVENTORY && item_is_consumable(gs.player.inventory.slots[slot].item) {
                player_consume(gs, slot)
            } else {
                player_equip(gs, slot)
            }

        case .Unequip_Request:
            player_unequip(gs, Equip_Slot(e.payload.int_val))

        case .New_Game_Request:
            start_new_game(gs)

        case .Quit_Request:
            gs.quit_requested = true

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
        eq_push(&gs.events, Event{type = .Player_Died})
        audio_play(&gs.audio, .Death)
        gs.stats.runs_played += 1
        _ = save_stats(&gs.stats)  // persist immediately — a crash after death shouldn't lose the run
    } else {
        audio_play(&gs.audio, .Kill)
        gs.stats.total_kills += 1
        i := entity_id_to_enemy_index(e.source)
        if i >= 0 && i < MAX_ENEMIES && gs.enemies.active[i] {
            en := &gs.enemies.data[i]
            T  := builder_tile(en)
            roll_enemy_drops(gs, en.kind, T)   // loot lands where they fell
            if en.kind == .Garm {
                log_action(gs, "GARM slain — Hell Key drops at (%d,%d)", T.x, T.y)
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
                notify(gs, "The silo is too heavy to break — empty it first ([%v] beside it)",
                    gs.bindings[.Interact])
                return
            }
        }
        silo_on_mined(gs, e.tile)
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
    // rock drops to the ground as usual; the dirt is banked directly (below).
    shaft_earth := gs.level_index == LEVEL_SURFACE && in_shaft_apron(&gs.world, x, y)

    // Mining into a den's structure is a break-in: the owner hunts.
    // (Only the player pushes Tile_Mined — builders emit Builder_Mined.)
    if owner := den_owner_index(gs, e.tile); owner >= 0 {
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
    set_tile(&gs.world, x, y, fill)
    gs.world.tile_flags[idx] -= {.Placed}   // the placed block is gone from this cell
    audio_play(&gs.audio, .Mine)

    // Cutting this tile may leave a tree (or a wood/leaf build) hanging — drop
    // whatever just lost its last link to the ground.
    gravity_check_removed(gs, x, y)

    if drop != .None {
        // One drop stack per cell: stack onto a matching drop, claim an empty
        // cell, but never clobber a different item already lying there.
        existing := gs.world.items[idx]
        if existing == drop && gs.world.item_counts[idx] > 0 {
            if int(gs.world.item_counts[idx]) < MAX_STACK do gs.world.item_counts[idx] += 1
        } else if existing == .None || gs.world.item_counts[idx] == 0 {
            gs.world.items[idx]       = drop
            gs.world.item_counts[idx] = 1
        }
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

    // A mined smelter spills its tray AND its loaded ore — nothing in the
    // furnace is lost.  Timers and buffers die with the tile so a future
    // machine here starts fresh.
    sd := &gs.world.sim_data[idx]
    if old_tile == .Smelter {
        if sd.store_count > 0 {
            spawn_ground_item(&gs.world, e.tile, sd.store_item, int(sd.store_count))
        }
        if sd.in_count > 0 {
            spawn_ground_item(&gs.world, e.tile, sd.in_item, int(sd.in_count))
        }
    }
    sd^ = {}

    // A door is two tiles: mining one half takes the whole door.  The generic
    // path above already dropped a single Door for this half; remove the partner
    // (no second drop) so no half is left standing.
    if old_tile == .Door {
        if px, py, ok := door_partner(&gs.world, x, y); ok {
            pidx := grid_idx(px, py)
            gs.world.tile_flags[pidx] -= {.Placed}
            set_tile(&gs.world, px, py, gravity_open_tile(gs, py))
            gravity_check_removed(gs, px, py)
        }
    }
}
