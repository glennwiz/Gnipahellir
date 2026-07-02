package game

// ─── Event Queue ──────────────────────────────────────────────────────────────

eq_push :: proc(eq: ^Event_Queue, e: Event) {
    if eq.size >= MAX_EVENTS do return  // drop silently when full
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
            // handled by player system

        case .Enemy_Moved:
            // handled by enemy system

        case .Damage_Dealt:
            if e.target == PLAYER_ID && !gs.player.dead {
                gs.player.hp -= int(e.payload.int_val)
                audio_play(&gs.audio, .Hurt)
                log_action(gs, "Player takes %d damage (hp %d)", e.payload.int_val, gs.player.hp)
                if gs.player.hp <= 0 {
                    gs.player.hp = 0
                    eq_push(&gs.events, Event{type = .Entity_Died, source = PLAYER_ID})
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
            // sim handles lava adjacency

        case .Tree_Grew:
            // sim handles tree growth

        case .Item_Pickup:
            // interaction handles inventory insert
            audio_play(&gs.audio, .Pickup)

        case .Item_Dropped:
            // interaction handles world item placement

        case .Craft_Request:
            // crafting system handles

        case .Craft_Complete:
            // crafting system handles

        case .Projectile_Fired:
            // projectile system handles

        case .Projectile_Impact:
            // projectile system handles

        case .Play_Sound:
            audio_play(&gs.audio, Sound_ID(e.payload.int_val))

        case .Play_Music:
            // audio system handles

        case .Stop_Music:
            // audio system handles

        case .Level_Enter:
            // level transition

        case .Level_Exit:
            // level transition

        case .Level_Locked:
            // notify player

        case .Player_Died:
            gs.player.dead = true

        case .Blueprint_Found:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.blueprint_found[tier] = true
            }

        case .Structure_Complete:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.sky_structure_complete[tier] = true
                eq_push(&gs.events, Event{
                    type    = .Cave_Unlocked,
                    payload = e.payload,
                })
            }

        case .Cave_Unlocked:
            tier := int(e.payload.int_val)
            if tier >= 0 && tier < MAX_PROGRESSION_TIERS {
                gs.progression.cave_unlocked[tier] = true
            }

        case .Boss_Defeated:
            gs.progression.final_boss_defeated = true

        case .Builder_Mined:
            audio_play(&gs.audio, .Builder_Dig, audio_tile_gain(gs, e.tile))

        case .Builder_Placed:
            audio_play(&gs.audio, .Builder_Place, audio_tile_gain(gs, e.tile))

        case .Game_Won:
            // handle win screen
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
    }
}

handle_tile_mined :: proc(gs: ^Game_State, e: Event) {
    x := int(e.tile.x)
    y := int(e.tile.y)
    if !in_bounds(x, y) do return

    idx := grid_idx(x, y)
    old_tile := gs.world.terrain[idx]
    drop := terrain_table[old_tile].drop_item

    set_tile(&gs.world, x, y, .Void)
    audio_play(&gs.audio, .Mine)

    if drop != .None {
        // Place drop in world
        gs.world.items[idx]       = drop
        gs.world.item_counts[idx] = 1
    }
}
