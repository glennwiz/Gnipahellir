package game

// ─── Item Placement ───────────────────────────────────────────────────────────
//
//  Right-click places the selected inventory item as a tile.  Input pushes
//  Place_Request with the target tile; the handler validates and mutates.

PLAYER_REACH :: 8  // tiles, chebyshev from player center; placement only (mining uses PICK_RANGE/wands)

// Would placing `item` at tile (x,y) succeed?  Pure — no notify, no mutation —
// so the placement handler and the cursor ghost preview agree exactly.
placement_ok :: proc(gs: ^Game_State, item: Item, x, y: int) -> bool {
    place_tile := item_table[item].place_tile
    if place_tile == .Air do return false          // not placeable
    if !in_bounds(x, y) do return false

    if place_tile == .Door do return door_placement_ok(gs, x, y)  // 1×2, own rules

    t := get_tile(&gs.world, x, y)                 // target must be open
    if t != .Air && t != .Void do return false

    // The Auto-Miner wakes only inside a spawned dimension, one per expedition.
    if place_tile == .Auto_Miner &&
       (gs.level_index != LEVEL_DIMENSION || gs.dimension.miner.active) {
        return false
    }

    // Silos stand on lasting ground only (a dimension collapses under them),
    // and the record book holds MAX_SILOS.
    if place_tile == .Silo &&
       (gs.level_index == LEVEL_DIMENSION || !silo_slot_free(gs)) {
        return false
    }

    // Barrels keep their contents in a record, so they too need lasting ground
    // and a free record slot (MAX_BARRELS).  A rune coffer stores identically,
    // so it answers to the same two gates.
    if (place_tile == .Barrel || place_tile == .Rune_Coffer) &&
       (gs.level_index == LEVEL_DIMENSION || !barrel_slot_free(gs)) {
        return false
    }

    // The Gem Replicator only works at the pressure gems form under: the deep
    // rows, never the sky.  Trees need open sky; gems need pressure.
    if place_tile == .Gem_Replicator &&
       (gs.level_index == LEVEL_SKY || y < REPLICATOR_DEPTH_Y) {
        return false
    }

    pcx := int(gs.player.pos.x + PLAYER_W*0.5)     // within reach
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    if abs(x - pcx) > PLAYER_REACH || abs(y - pcy) > PLAYER_REACH do return false

    if tpl := structure_template_for(gs, item); tpl != nil {  // finished foundation
        if ok, _ := structure_template_satisfied(&gs.world, tpl, x, y); !ok do return false
    }

    // needs a solid neighbour to attach to
    if !is_solid(&gs.world, x-1, y) && !is_solid(&gs.world, x+1, y) &&
       !is_solid(&gs.world, x, y-1) && !is_solid(&gs.world, x, y+1) {
        return false
    }

    if .Solid in terrain_table[place_tile].flags && tile_overlaps_player(gs, x, y) do return false  // don't seal the player in
    return true
}

// A door needs two stacked open cells (clicked cell + the one above), both in
// reach, plus a solid neighbour on some side to hang on.  No overlap check —
// the player phases through doors, so placing one on yourself can't trap you.
door_placement_ok :: proc(gs: ^Game_State, x, y: int) -> bool {
    pcx := int(gs.player.pos.x + PLAYER_W*0.5)
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    has_anchor := false
    for c in door_cells(x, y) {
        cx, cy := c[0], c[1]
        if !in_bounds(cx, cy) do return false
        t := get_tile(&gs.world, cx, cy)
        if t != .Air && t != .Void do return false                     // must be open
        if abs(cx - pcx) > PLAYER_REACH || abs(cy - pcy) > PLAYER_REACH do return false
        if is_solid(&gs.world, cx-1, cy) || is_solid(&gs.world, cx+1, cy) ||
           is_solid(&gs.world, cx, cy-1) || is_solid(&gs.world, cx, cy+1) {
            has_anchor = true
        }
    }
    return has_anchor
}

handle_place_request :: proc(gs: ^Game_State, e: Event) {
    if gs.player.dead do return
    inv := &gs.player.inventory
    x := int(e.tile.x)
    y := int(e.tile.y)

    // Use-items act from the hand — deliberate verbs on the held stack.
    if inv.selected >= 0 {
        held := inv.slots[inv.selected]
        if held.item != .None && held.count > 0 {
            // Buckets place no tile of their own (place_tile is .Air), so they
            // would fall straight through placement_ok — they get the click first.
            if held.item == .Iron_Bucket || bucket_fluid_for(held.item) != .Air {
                bucket_use(gs, x, y)
                return
            }
            // Mana Pipe is a Tile_Flag.Piped overlay, not a Tile_Type (place_tile
            // is .Air), so it takes the click first too — same reason as buckets.
            if held.item == .Mana_Pipe {
                mana_pipe_use(gs, x, y)
                return
            }
            // A held Clay Golem is bound into the command wand on use (place_tile
            // is .Air) — the same load the bag right-click route performs.
            if held.item == .Clay_Golem {
                eq_push(&gs.events, Event{type = .Golem_Load, payload = {int_val = i32(inv.selected)}})
                return
            }
        }
    }

    // The placing stack: the hand when its item places a tile; otherwise the
    // dedicated Place Slot, so building while holding the pick or wand never
    // needs a hand swap. (The command wand can't reach here — its right-click
    // is golem deploy, routed in input before a Place_Request is ever pushed.)
    idx := inv.selected
    if idx < 0 || item_table[inv.slots[idx].item].place_tile == .Air {
        idx = PLACE_SLOT
    }
    slot := &inv.slots[idx]
    if slot.item == .None || slot.count <= 0 do return
    place_tile := item_table[slot.item].place_tile
    if place_tile == .Air do return  // the Place Slot holds a non-block

    if !placement_ok(gs, slot.item, x, y) {
        // Explain the common templated-structure miss (the red ghost shows the rest).
        if tpl := structure_template_for(gs, slot.item); tpl != nil {
            if ok, want := structure_template_satisfied(&gs.world, tpl, x, y); !ok {
                notify(gs, "The %s needs its %s foundation - build the plan (press B)",
                    tpl.name, terrain_table[want].name)
            }
        }
        // Explain the miner's two gates.
        if place_tile == .Auto_Miner {
            if gs.level_index != LEVEL_DIMENSION {
                notify(gs, "The Auto-Miner only wakes inside a spawned dimension")
            } else if gs.dimension.miner.active {
                notify(gs, "One miner per expedition - reclaim the working one first")
            }
        }
        // Explain the silo's two gates.
        if place_tile == .Silo {
            if gs.level_index == LEVEL_DIMENSION {
                notify(gs, "The silo needs lasting ground - this world will collapse")
            } else if !silo_slot_free(gs) {
                notify(gs, "Every silo is spoken for - reclaim one first")
            }
        }
        // Explain the barrel's (and the coffer's) two gates.
        if place_tile == .Barrel || place_tile == .Rune_Coffer {
            if gs.level_index == LEVEL_DIMENSION {
                notify(gs, "The chest needs lasting ground - this world will collapse")
            } else if !barrel_slot_free(gs) {
                notify(gs, "Every container is spoken for - reclaim one first")
            }
        }
        // Explain the replicator's depth gate.
        if place_tile == .Gem_Replicator &&
           (gs.level_index == LEVEL_SKY || y < REPLICATOR_DEPTH_Y) {
            notify(gs, "Gems take root only under pressure - carry it deeper")
        }
        return
    }

    slot.count -= 1
    if slot.count == 0 do slot.item = .None
    set_tile(&gs.world, x, y, place_tile)
    gs.world.sim_data[grid_idx(x, y)] = {}  // a fresh machine starts cold, tray empty
    gs.world.tile_flags[grid_idx(x, y)] += {.Placed}  // player-built: gravity-eligible

    // A door is two tiles: raise its upper half in the cell above.
    if place_tile == .Door {
        set_tile(&gs.world, x, y-1, .Door)
        gs.world.tile_flags[grid_idx(x, y-1)] += {.Placed}
    }
    eq_push(&gs.events, Event{type = .Tile_Placed, source = PLAYER_ID, tile = e.tile})

    // A placed spawner is a door waiting to be opened.
    if place_tile == .Dimension_Spawner || place_tile == .Dimension_Spawner_Gold || place_tile == .Dimension_Spawner_Runic {
        notify(gs, "The spawner hums - press [%v] beside it to cross over", gs.bindings[.Interact])
    }

    // A placed Auto-Miner wakes the snake and anchors this dimension.
    if place_tile == .Auto_Miner {
        miner_on_placed(gs, e.tile)
    }

    // A placed Silo opens its record book entry.
    if place_tile == .Silo {
        silo_on_placed(gs, e.tile)
    }

    // A placed Barrel — or a re-placed rune coffer — opens its record entry.
    if place_tile == .Barrel || place_tile == .Rune_Coffer {
        barrel_on_placed(gs, e.tile)
    }

    // Raising a Sky Altar on the surface opens the gate to the heavens above it.
    if place_tile == .Sky_Altar && gs.level_index == LEVEL_SURFACE {
        gs.progression.sky_altar_pos = {i32(x), i32(y)}
        audio_play(&gs.audio, .Fanfare)
        notify(gs, "The Sky Altar rises - a portal opens to the heavens!")
        spawn_deep_rune_scroll(gs)
    }
}

// Each liquid pairs with a filled-bucket item; the load lives on the stack, so
// three buckets haul three loads (retired the one-load Player.bucket_fluid).
@(rodata)
bucket_loads := [?]struct {
    fluid: Tile_Type,
    item:  Item,
}{
    {.Water, .Water_Bucket},
    {.Lava, .Lava_Bucket},
    {.Magic_Lava, .Magic_Lava_Bucket},
}

filled_bucket_for :: proc(fluid: Tile_Type) -> Item {
    for l in bucket_loads do if l.fluid == fluid do return l.item
    return .None
}

bucket_fluid_for :: proc(it: Item) -> Tile_Type {
    for l in bucket_loads do if l.item == it do return l.fluid
    return .Air
}

// The Iron Bucket: right-click a water/lava cell to scoop it up — the selected
// empty bucket becomes its filled variant — and right-click an open cell with a
// filled bucket selected to pour it out and get the empty bucket back.  The
// scooped cell opens exactly as a mined one does, so a lifted tile leaves the
// same hole digging it would.
bucket_use :: proc(gs: ^Game_State, x, y: int) {
    if !in_bounds(x, y) do return
    inv  := &gs.player.inventory
    slot := &inv.slots[inv.selected]

    pcx := int(gs.player.pos.x + PLAYER_W*0.5)
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    if abs(x - pcx) > PLAYER_REACH || abs(y - pcy) > PLAYER_REACH {
        notify(gs, "Too far away to reach with the bucket")
        return
    }

    if slot.item == .Iron_Bucket {
        t := get_tile(&gs.world, x, y)
        if !is_liquid_tile(t) {
            notify(gs, "The bucket carries only water or lava")
            return
        }
        // Swap one empty bucket for the filled variant before touching the
        // world, so a full bag refuses without losing the fluid.
        slot.count -= 1
        if slot.count == 0 do slot.item = .None
        if !inventory_insert(inv, filled_bucket_for(t)) {
            slot.item = .Iron_Bucket
            slot.count += 1
            notify(gs, "No room in the bag for a filled bucket")
            return
        }
        set_tile(&gs.world, x, y, gravity_open_tile(gs, y))
        notify(gs, "The bucket fills with %s", terrain_table[t].name)
        audio_play(&gs.audio, .Pickup)
        return
    }

    fluid := bucket_fluid_for(slot.item)
    if fluid == .Air do return
    if !fluid_open(&gs.world, x, y) {
        notify(gs, "Pour the bucket into an open cell")
        return
    }
    slot.count -= 1
    if slot.count == 0 do slot.item = .None
    if !inventory_insert(inv, .Iron_Bucket) {
        slot.item = filled_bucket_for(fluid)
        slot.count += 1
        notify(gs, "No room in the bag for the emptied bucket")
        return
    }
    notify(gs, "You pour out the %s", terrain_table[fluid].name)
    set_tile(&gs.world, x, y, fluid)
    audio_play(&gs.audio, .Place)
}

// Mana Pipe is a Tile_Flag.Piped overlay (types.odin/render.odin), not a
// Tile_Type — so it can't go through the ordinary place-then-mine cycle
// every real tile uses. Right-click toggles it: an open (non-solid) cell
// gets piped, an already-piped cell gets un-piped and the item returned —
// place and remove share one action, symmetric and easy to find. The
// underlying tile is never touched either way: fluid physics never learns
// pipes exist.
mana_pipe_use :: proc(gs: ^Game_State, x, y: int) {
    if !in_bounds(x, y) do return
    inv  := &gs.player.inventory
    slot := &inv.slots[inv.selected]

    pcx := int(gs.player.pos.x + PLAYER_W*0.5)
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    if abs(x - pcx) > PLAYER_REACH || abs(y - pcy) > PLAYER_REACH {
        notify(gs, "Too far away to fit a pipe there")
        return
    }

    idx := grid_idx(x, y)
    if .Piped in gs.world.tile_flags[idx] {
        if !inventory_insert(inv, .Mana_Pipe) {
            notify(gs, "No room in the bag for the pipe")
            return
        }
        gs.world.tile_flags[idx] -= {.Piped}
        audio_play(&gs.audio, .Pickup)
        return
    }

    if is_solid(&gs.world, x, y) {
        notify(gs, "A pipe needs an open cell to sit in")
        return
    }
    slot.count -= 1
    if slot.count == 0 do slot.item = .None
    gs.world.tile_flags[idx] += {.Piped}
    audio_play(&gs.audio, .Place)
}

// Dropping a bag stack onto an open ground cell (drag it out of the bag onto
// the world) — a manual pile for the auto-pull hoppers (smelter ore/fuel, silo
// vacuum) and future automation pipelines.  The exact cursor cell takes the
// pile when it is open, in reach, and empty or already holds the same item with
// room; otherwise the drop is refused and nothing leaves the bag.
handle_item_drop :: proc(gs: ^Game_State, e: Event) {
    if gs.player.dead do return
    slot := int(e.payload.int_val)
    if slot < 0 || slot >= MAX_INVENTORY do return
    s := &gs.player.inventory.slots[slot]
    if s.item == .None || s.count <= 0 do return

    x := int(e.tile.x)
    y := int(e.tile.y)
    if !in_bounds(x, y) do return

    pcx := int(gs.player.pos.x + PLAYER_W*0.5)
    pcy := int(gs.player.pos.y + PLAYER_H*0.5)
    in_reach := abs(x - pcx) <= PLAYER_REACH && abs(y - pcy) <= PLAYER_REACH
    // Rune Scrolls re-seal themselves when deliberately dropped.  They remain
    // unique progression objects instead of joining automation item piles —
    // and they keep the strict refusals (never thrown: spawn_ground_item's
    // scroll path can silently fail, which would void a progression item).
    if is_rune_scroll(s.item) {
        if !in_reach {
            notify(gs, "Too far to drop there")
            return
        }
        if is_solid(&gs.world, x, y) {
            notify(gs, "No room to drop there")
            return
        }
        if tile_overlaps_player(gs, x, y) {
            notify(gs, "Step aside before sealing the rune scroll there")
            return
        }
        if gs.world.items[grid_idx(x, y)] != .None {
            notify(gs, "Something is already lying there")
            return
        }
        item := s.item
        if !place_rune_scroll_chest(&gs.world, x, y, item) {
            notify(gs, "The rune scroll chest needs clear ground")
            return
        }
        s.count -= 1
        if s.count == 0 do s.item = .None
        audio_play(&gs.audio, .Place)
        log_action(gs, "Player seals %v in a chest at (%d,%d)", item, x, y)
        return
    }
    // An in-reach drop onto a clear (or matching, roomy) cell lands exactly
    // where aimed — precise piles matter for machine fuel hoppers.
    idx      := grid_idx(x, y)
    existing := gs.world.items[idx]
    have     := int(gs.world.item_counts[idx])
    matches  := existing == s.item && have > 0
    clear    := existing == .None || have == 0
    room     := MAX_STACK - (matches ? have : 0)
    if in_reach && !is_solid(&gs.world, x, y) && (clear || matches) && room > 0 {
        n := min(s.count, room)
        gs.world.items[idx]       = s.item
        gs.world.item_counts[idx] = u8((matches ? have : 0) + n)
        item := s.item
        s.count -= n
        if s.count == 0 do s.item = .None
        audio_play(&gs.audio, .Place)
        log_action(gs, "Player drops %v x%d at (%d,%d)", item, n, x, y)
        return
    }

    // Anywhere else the drop is never refused: the player throws the whole
    // stack toward the cursor and it lands as a ground pickup at most two
    // tiles out — spawn_ground_item rings to the first legal cell.  Aimed at
    // your own feet it lands on you and the walk-over vacuum takes it back.
    tx := pcx + clamp(x - pcx, -2, 2)
    ty := pcy + clamp(y - pcy, -2, 2)
    if tx == pcx && ty == pcy do tx += gs.player.facing >= 0 ? 2 : -2
    tx = clamp(tx, 0, GRID_W - 1)   // spawn's last resort indexes the origin
    ty = clamp(ty, 0, GRID_H - 1)   // cell unchecked, so keep it on the grid
    item := s.item
    n    := int(s.count)
    spawn_ground_item(&gs.world, {i32(tx), i32(ty)}, item, n)
    s.count = 0
    s.item  = .None
    audio_play(&gs.audio, .Place)
    log_action(gs, "Player throws %v x%d toward (%d,%d)", item, n, tx, ty)
}

tile_overlaps_player :: proc(gs: ^Game_State, x, y: int) -> bool {
    p := &gs.player
    return f32(x) < p.pos.x + PLAYER_W && f32(x+1) > p.pos.x &&
           f32(y) < p.pos.y + PLAYER_H && f32(y+1) > p.pos.y
}
