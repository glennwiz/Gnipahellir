package game

// ─── Silo: wide-count bulk storage ────────────────────────────────────────────
//
//  A placed Silo vacuums item stacks lying beside it into wide u32 slots —
//  the first true bulk store (draft1_machines.md §7.6 step 1; the miner's
//  haul proved the pattern).  Feed it by Q-dropping stacks beside it; a
//  smelter standing next to one casts bars straight in, skipping its 99-cap
//  tray (sim.odin).  E in reach pours the hoard back out as 99-stacks.
//  A loaded silo is too heavy to break — player mining and enemy smashes
//  both refuse until it is emptied.  Silos refuse dimensions: their record
//  outlives an ephemeral world, so they stand on lasting ground only.
//
//  Records live in Sim_State.silos (saved), keyed by (level, tile); the
//  tile itself is ordinary terrain, so silos persist per level like any
//  other machine.

MAX_SILOS  :: 16
SILO_SLOTS :: 8

Silo_Slot :: struct {
    item:  Item,
    count: u32,   // wide count — thousands live here, not on u8 ground stacks
}

Silo_State :: struct {
    active: bool,
    level:  int,
    tile:   [2]i32,
    slots:  [SILO_SLOTS]Silo_Slot,
}

// The record behind a silo tile, or nil.
silo_at :: proc(gs: ^Game_State, level: int, tile: [2]i32) -> ^Silo_State {
    for &s in gs.sim.silos {
        if s.active && s.level == level && s.tile == tile do return &s
    }
    return nil
}

silo_slot_free :: proc(gs: ^Game_State) -> bool {
    for s in gs.sim.silos do if !s.active do return true
    return false
}

silo_total :: proc(s: ^Silo_State) -> (total: u32) {
    for slot in s.slots do total += slot.count
    return
}

silo_add :: proc(s: ^Silo_State, item: Item, n: u32) {
    if item == .None do return
    for &slot in s.slots {
        if slot.item == item { slot.count += n; return }
    }
    for &slot in s.slots {
        if slot.item == .None || slot.count == 0 { slot.item = item; slot.count = n; return }
    }
    // all slots hold other items — the stack stays on the ground
}

silo_has_room_for :: proc(s: ^Silo_State, item: Item) -> bool {
    for slot in s.slots {
        if slot.item == item do return true
        if slot.item == .None || slot.count == 0 do return true
    }
    return false
}

// The silo record beside a machine tile, or nil — how the smelter finds its
// out-chute.
silo_adjacent :: proc(gs: ^Game_State, x, y: int) -> ^Silo_State {
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            if gs.world.terrain[grid_idx(nx, ny)] == .Silo {
                if s := silo_at(gs, gs.level_index, {i32(nx), i32(ny)}); s != nil do return s
            }
        }
    }
    return nil
}

// ─── Tick (via tile_on_tick, sim.odin) ────────────────────────────────────────

// The silo vacuums whole item stacks lying in its 8 neighbor cells.  Feed it
// by Q-dropping beside it; geometry decides contested cells — a stack beside
// both a smelter and a silo goes to the silo, so lay smelter ore on the far
// side.
tick_silo :: proc(gs: ^Game_State, x, y: int) {
    s := silo_at(gs, gs.level_index, {i32(x), i32(y)})
    if s == nil do return

    w := &gs.world
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            if dx == 0 && dy == 0 do continue
            nx, ny := x + dx, y + dy
            if !in_bounds(nx, ny) do continue
            idx := grid_idx(nx, ny)
            it  := w.items[idx]
            if it == .None || w.item_counts[idx] == 0 do continue
            if !silo_has_room_for(s, it) do continue
            silo_add(s, it, u32(w.item_counts[idx]))
            w.items[idx]       = .None
            w.item_counts[idx] = 0
        }
    }
}

// ─── Player interactions ──────────────────────────────────────────────────────

// E beside the silo: pour the hoard into the bag, 99-stacks at a time.
silo_withdraw :: proc(gs: ^Game_State, s: ^Silo_State) {
    inv := &gs.player.inventory
    taken_any := false
    for &slot in s.slots {
        if slot.item == .None || slot.count == 0 do continue
        for slot.count > 0 {
            batch  := int(min(slot.count, u32(MAX_STACK)))
            before := inventory_count(inv, slot.item)
            inventory_insert(inv, slot.item, batch)
            taken := inventory_count(inv, slot.item) - before
            slot.count -= u32(taken)
            if taken > 0 do taken_any = true
            if taken < batch {  // bag is full
                notify(gs, "The bag is full — %d items stay in the silo", silo_total(s))
                if taken_any do audio_play(&gs.audio, .Pickup)
                return
            }
        }
        slot.item = .None
    }
    if taken_any {
        audio_play(&gs.audio, .Pickup)
        notify(gs, "The silo empties into the bag")
        log_action(gs, "Player withdraws silo at (%d,%d)", s.tile.x, s.tile.y)
    } else {
        notify(gs, "The silo is empty — drop stacks beside it to fill it")
    }
}

// Placing: claim a free record.  placement_ok guarantees one exists.
silo_on_placed :: proc(gs: ^Game_State, tile: [2]i32) {
    for &s in gs.sim.silos {
        if s.active do continue
        s = {
            active = true,
            level  = gs.level_index,
            tile   = tile,
        }
        notify(gs, "The silo stands ready — drop stacks beside it, [%v] to empty it",
            gs.bindings[.Interact])
        log_action(gs, "Silo placed at (%d,%d) on level %d", tile.x, tile.y, gs.level_index)
        return
    }
}

// Reclaiming an EMPTY silo frees its record (loaded silos refuse the pick —
// events.odin / enemy.odin guard before calling set_tile).
silo_on_mined :: proc(gs: ^Game_State, tile: [2]i32) {
    if s := silo_at(gs, gs.level_index, tile); s != nil {
        log_action(gs, "Silo at (%d,%d) reclaimed", tile.x, tile.y)
        s^ = {}
    }
}
