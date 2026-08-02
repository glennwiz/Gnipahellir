package game

// ─── Barrel: a placed 4×4 chest ───────────────────────────────────────────────
//
//  The first player-facing overflow store: a wooden barrel crafted from planks
//  at the bench, placed like any machine, opened by clicking it in reach.  Its
//  window is a 4×4 grid you drag stacks to and from the bag — unlike the silo
//  (bulk u32 counts, proximity-fed and poured back out), the barrel is
//  hand-organized inventory overflow you sort by hand.
//
//  Records live in Sim_State.barrels (saved), keyed by (level, tile) — the same
//  book-keeping the silo uses; the tile itself is ordinary terrain, so barrels
//  persist per level like any other machine.  A loaded barrel refuses the pick
//  until emptied (events.odin guards mining), so nothing stored is ever lost.

MAX_BARRELS  :: 16
BARREL_COLS  :: 4
BARREL_ROWS  :: 4
BARREL_SLOTS :: BARREL_COLS * BARREL_ROWS   // 16

Barrel_State :: struct {
    active: bool,
    level:  int,
    tile:   [2]i32,
    slots:  [BARREL_SLOTS]Inventory_Slot,   // same {item, count} the bag uses
}

// The record behind a barrel tile, or nil.
barrel_at :: proc(gs: ^Game_State, level: int, tile: [2]i32) -> ^Barrel_State {
    for &b in gs.sim.barrels {
        if b.active && b.level == level && b.tile == tile do return &b
    }
    return nil
}

barrel_slot_free :: proc(gs: ^Game_State) -> bool {
    for b in gs.sim.barrels do if !b.active do return true
    return false
}

barrel_total :: proc(b: ^Barrel_State) -> (n: int) {
    for s in b.slots do n += s.count
    return
}

// Stow up to `count` of `item`, stacking onto matching slots first, then empty
// slots (MAX_STACK per slot — same rule as the bag).  Returns how many landed.
barrel_deposit :: proc(b: ^Barrel_State, item: Item, count: int) -> int {
    if item == .None do return 0
    left := count
    for &s in b.slots {
        if left == 0 do break
        if s.item == item && s.count > 0 && s.count < MAX_STACK {
            take := min(MAX_STACK - s.count, left)
            s.count += take
            left    -= take
        }
    }
    for &s in b.slots {
        if left == 0 do break
        if s.item == .None || s.count == 0 {
            take := min(MAX_STACK, left)
            s.item  = item
            s.count = take
            left   -= take
        }
    }
    return count - left
}

// ─── Player interactions ──────────────────────────────────────────────────────

// Drag a whole bag stack into the barrel; whatever doesn't fit stays in the bag.
barrel_store :: proc(gs: ^Game_State, b: ^Barrel_State, bag_slot: int) {
    if bag_slot < 0 || bag_slot >= MAX_INVENTORY do return
    s := &gs.player.inventory.slots[bag_slot]
    if s.item == .None || s.count <= 0 do return

    moved := barrel_deposit(b, s.item, s.count)
    if moved == 0 {
        notify(gs, "The barrel is full")
        return
    }
    s.count -= moved
    if s.count == 0 do s.item = .None
    audio_play(&gs.audio, .Pickup)
    gs.save_dirty = true
}

// Pull a barrel slot back into the bag; whatever doesn't fit stays in the barrel.
barrel_take :: proc(gs: ^Game_State, b: ^Barrel_State, barrel_slot: int) {
    if barrel_slot < 0 || barrel_slot >= BARREL_SLOTS do return
    s := &b.slots[barrel_slot]
    if s.item == .None || s.count <= 0 do return

    inv    := &gs.player.inventory
    before := inventory_count(inv, s.item)
    inventory_insert(inv, s.item, s.count)
    moved  := inventory_count(inv, s.item) - before
    if moved <= 0 {
        notify(gs, "The bag is full")
        return
    }
    s.count -= moved
    if s.count == 0 do s.item = .None
    audio_play(&gs.audio, .Pickup)
    gs.save_dirty = true
}

// Placing: claim a free record.  placement_ok guarantees one exists.
barrel_on_placed :: proc(gs: ^Game_State, tile: [2]i32) {
    for &b in gs.sim.barrels {
        if b.active do continue
        b = {
            active = true,
            level  = gs.level_index,
            tile   = tile,
        }
        notify(gs, "A barrel stands ready - click it to stow and retrieve")
        log_action(gs, "Barrel placed at (%d,%d) on level %d", tile.x, tile.y, gs.level_index)
        return
    }
}

// Reclaiming an EMPTY barrel frees its record (loaded barrels refuse the pick —
// events.odin guards before calling set_tile).
barrel_on_mined :: proc(gs: ^Game_State, tile: [2]i32) {
    if b := barrel_at(gs, gs.level_index, tile); b != nil {
        log_action(gs, "Barrel at (%d,%d) reclaimed", tile.x, tile.y)
        b^ = {}
    }
}
