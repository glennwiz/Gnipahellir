package gnipahellir

import fmt "core:fmt"

// Event system (extended)

Event_Type :: enum u8 {
    Movement,
    Damage,
    Item,
    // New application-specific events
    Pickup,      // player picked up an item from world
    Crafted,       // crafting completed
    Craft_Request, // request to craft a product
    Mining_Request,// request to mine a tile (apply terrain/item change)
    Mining_Impact, // notification after mining is applied
    // Audio events
    Play_Sound,  // trigger a sound effect
    Play_Music,  // start playing music
    Stop_Music,  // stop current music
}

Movement_Event :: struct {
    entity : Entity_ID,
    from_x, from_y : int,
    to_x, to_y : int,
}

Damage_Event :: struct { target: Entity_ID, amount: i32 }
Item_Event   :: struct { entity: Entity_ID, item: Item_ID }

// Payloads for new events
Pickup_Event :: struct {
    item  : Item_ID,
    count : u16,
    x, y  : int,
}

Craft_Event :: struct {
    product : Item_ID,
    amount  : u16,
}

Craft_Request :: struct {
    product : Item_ID,
}

Mining_Event :: struct {
    tx, ty  : int,
    removed : Terrain_Type,
    drop    : Item_ID,
}

// Audio event payloads
Sound_Event :: struct {
    sound_id : Sound_ID,
    volume   : f32, // -1 to use default
}

Music_Event :: struct {
    music_id : Music_ID,
    fade_in  : bool,
}

Event :: struct {
    type      : Event_Type,
    source_id : Entity_ID,
    target_id : Entity_ID,
    data      : union { Movement_Event, Damage_Event, Item_Event, Pickup_Event, Craft_Event, Craft_Request, Mining_Event, Sound_Event, Music_Event },
}

Event_Queue :: struct {
    events : [256]Event,
    head   : int,
    tail   : int,
}

// Push event (returns false if full)
event_queue_push :: proc(q: ^Event_Queue, e: Event) -> bool {
    next := (q.tail + 1) % len(q.events)
    if next == q.head do return false // full
    q.events[q.tail] = e
    q.tail = next
    return true
}

// Pop event (returns false if empty)
event_queue_pop :: proc(q: ^Event_Queue, out: ^Event) -> bool {
    if q.head == q.tail do return false
    out^ = q.events[q.head]
    q.head = (q.head + 1) % len(q.events)
    return true
}

event_queue_clear :: proc(q: ^Event_Queue) {
    q.head = 0
    q.tail = 0
}

process_events :: proc(game: ^Game_State) {
    e : Event
    for event_queue_pop(&game.events, &e) {
        switch e.type {
        case .Movement: {
            // Auto-pickup when player moves onto an item
            if e.source_id == PLAYER_ID {
                px := game.player.tile_x
                py := game.player.tile_y
                if bounds_check(px, py) {
                    it := game.world.items[px][py]
                    if it != .None {
                        // move to inventory
                        placed := false
                        for i in 0..<INV_MAX_SLOTS {
                            if game.inventory.slots[i].id == it { game.inventory.slots[i].count += 1; placed = true; break }
                        }
                        if !placed {
                            for i in 0..<INV_MAX_SLOTS {
                                if game.inventory.slots[i].id == .None { game.inventory.slots[i] = Item_Stack{ id = it, count = 1 }; placed = true; break }
                            }
                        }
                        game.world.items[px][py] = .None
                        // notify
                        _ = event_queue_push(&game.events, Event{ type = .Pickup, source_id = PLAYER_ID, target_id = PLAYER_ID, data = Pickup_Event{ item = it, count = 1, x = px, y = py } })
                    }
                }
            }
        }
        case .Damage:
            _ = e
        case .Item:
            _ = e
        case .Pickup: {
            // Record item pickup
            pe := e.data.(Pickup_Event)
            record_item_pickup(&game.stats, pe.item)
            
            // Auto-equip wand when picked up
            if pe.item == .Mine_Wand && game.player.main_hand != .Mine_Wand {
                // Find the wand in inventory and equip it
                for i in 0..<INV_MAX_SLOTS {
                    if game.inventory.slots[i].id == .Mine_Wand && game.inventory.slots[i].count > 0 {
                        equip_inventory_slot_to_main_hand(game, i)
                        break
                    }
                }
            }
            
            // Lightweight UI feedback
            game.ui.popup_active = true
            game.ui.popup_text = "Picked up"
            game.ui.popup_time = 1.0
            // Play pickup sound
            _ = event_queue_push(&game.events, Event{
                type = .Play_Sound,
                source_id = PLAYER_ID,
                target_id = PLAYER_ID,
                data = Sound_Event{ sound_id = .ITEM_PICKUP, volume = -1 }
            })
        }
        case .Craft_Request: {
            // Validate dependencies (bench for most recipes)
            req := e.data.(Craft_Request)
            if req.product != .Crafting_Bench && !world_has_terrain(&game.world, .Crafting_Bench) {
                continue
            }
            idx := find_recipe_index(req.product)
            if idx < 0 { continue }
            r := &craft_recipes[idx]
            if !can_craft(&game.inventory, r) { continue }
            consume_ingredients(&game.inventory, r)
            add_item_to_inventory(&game.inventory, r.product, cast(int)r.amount)
            _ = event_queue_push(&game.events, Event{ type = .Crafted, source_id = PLAYER_ID, target_id = PLAYER_ID, data = Craft_Event{ product = r.product, amount = r.amount } })
        }
        case .Crafted: {
            game.ui.popup_active = true
            game.ui.popup_text = "Crafted!"
            game.ui.popup_time = 1.0
        }
        case .Mining_Request: {
            // Apply terrain change and optional drop
            me := e.data.(Mining_Event)
            tx := me.tx; ty := me.ty
            if !bounds_check(tx, ty) { continue }
            tt := game.world.terrain[tx][ty]
            if tt == .Air { continue }
            
            // Record block destruction
            record_block_destroyed(&game.stats, tt)
            
            if me.drop != .None && game.world.items[tx][ty] == .None {
                game.world.items[tx][ty] = me.drop
                game.world.item_counts[tx][ty] = 1
            }
            if game.level_offset <= 0 { game.world.terrain[tx][ty] = .Air } else { game.world.terrain[tx][ty] = .Void }
            // visual spark
            wx := cast(f32)(tx*TILE_SIZE + TILE_SIZE/2)
            wy := cast(f32)(ty*TILE_SIZE + TILE_SIZE/2)
            particle_spawn_spark(&game.particles, wx, wy)
            _ = event_queue_push(&game.events, Event{ type = .Mining_Impact, source_id = PLAYER_ID, target_id = PLAYER_ID, data = Mining_Event{ tx = tx, ty = ty, removed = tt, drop = me.drop } })
        }
        case .Mining_Impact: {
            // Trigger mining sound effect
            me := e.data.(Mining_Event)
            sound_to_play : Sound_ID = .TILE_BREAK_STONE
            if me.removed == .Grass || me.removed == .Leaves {
                sound_to_play = .TILE_BREAK_DIRT
            }
            _ = event_queue_push(&game.events, Event{
                type = .Play_Sound,
                source_id = PLAYER_ID,
                target_id = PLAYER_ID,
                data = Sound_Event{ sound_id = sound_to_play, volume = -1 }
            })
        }
        case .Play_Sound: {
            se := e.data.(Sound_Event)
            queue_sound(&game.audio, se.sound_id)
        }
        case .Play_Music: {
            me := e.data.(Music_Event)
            play_music(&game.audio, me.music_id, me.fade_in)
        }
        case .Stop_Music: {
            stop_music(&game.audio, true) // fade out
        }
        }
    }
}