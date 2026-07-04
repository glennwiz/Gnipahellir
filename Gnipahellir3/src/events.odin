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

        #partial switch e.type {
        case .Player_Moved:
            // informational; no handler yet

        case .Enemy_Moved:
            // informational; no handler yet

        case .Damage_Dealt:
            if e.target == PLAYER_ID {
                if !gs.player.dead {
                    gs.player.hp -= int(e.payload.int_val)
                    audio_play(&gs.audio, .Hurt)
                    log_action(gs, "Player takes %d damage (hp %d)", e.payload.int_val, gs.player.hp)
                    if gs.player.hp <= 0 {
                        gs.player.hp = 0
                        eq_push(&gs.events, Event{type = .Entity_Died, source = PLAYER_ID})
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

        case .Lava_Spread:
            // sim system not implemented yet (Phase 4+)

        case .Tree_Grew:
            // sim system not implemented yet (Phase 4+)

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
            }

        case .Item_Dropped:
            // drop-to-world (Q key) not implemented yet

        case .Craft_Request:
            handle_craft_request(gs, e)

        case .Craft_Complete:
            audio_play(&gs.audio, .Pickup)

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
            if lvl >= 0 && lvl < NUM_LEVELS {
                notify(gs, "— %s —", level_names[lvl])
            }
            garm_maybe_awaken(gs)

        case .Level_Exit:
            // informational; no handler yet

        case .Level_Locked:
            notify(gs, "Sealed by runic magic — a sky structure must be built")

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
        // The boss's last breath: the Hell Key falls where he stood.
        if i >= 0 && i < MAX_ENEMIES && gs.enemies.active[i] && gs.enemies.data[i].kind == .Garm {
            T   := builder_tile(&gs.enemies.data[i])
            idx := grid_idx(int(T.x), int(T.y))
            gs.world.items[idx]       = .Hell_Key
            gs.world.item_counts[idx] = 1
            log_action(gs, "GARM slain — Hell Key drops at (%d,%d)", T.x, T.y)
            eq_push(&gs.events, Event{type = .Boss_Defeated})
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
    drop := terrain_table[old_tile].drop_item

    // Mining into a den's structure is a break-in: the owner hunts.
    // (Only the player pushes Tile_Mined — builders emit Builder_Mined.)
    if owner := den_owner_index(gs, e.tile); owner >= 0 {
        builder_alert(gs, owner)
    }

    // Mined tiles open to air above the surface line, to void underground
    fill: Tile_Type = .Void
    if gs.level_index == LEVEL_SKY || (gs.level_index == LEVEL_SURFACE && y < SURFACE_Y) {
        fill = .Air
    }
    set_tile(&gs.world, x, y, fill)
    audio_play(&gs.audio, .Mine)

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
}
