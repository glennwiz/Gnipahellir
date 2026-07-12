package game

// ─── Loot ─────────────────────────────────────────────────────────────────────
//
//  Table-driven enemy drops: on death each kind rolls its Drop_Entry rows
//  once (per-row chance, count in [min, max]) and the stacks land on or near
//  the death tile.  New enemy loot = new rows here, nothing else changes.
//  Rolls use the xorshift PRNG seated in Game_State — no globals, and tests
//  pin gs.loot_rng for determinism.

MAX_DROP_ROLLS :: 3

Drop_Entry :: struct {
    item:   Item,
    min:    u8,
    max:    u8,
    chance: f32,   // 0..1, rolled once per row
}

@(rodata)
enemy_drop_table := [Enemy_Kind][MAX_DROP_ROLLS]Drop_Entry{
    // The boss's last breath: the Hell Key falls where he stood.
    .Garm        = {{.Hell_Key, 1, 1, 1.0}, {}, {}},
    // Builders carry their trade: stone always, a sliver of silver sometimes.
    .Builder     = {{.Stone_Block, 1, 2, 1.0}, {.Silver_Ore, 1, 2, 0.35}, {}},
    // Not spawned by any level yet — rows land when their AI does.
    .Undead      = {},
    .Fire_Sprite = {},
}

// xorshift64 step.  Zero-guards so a zeroed test state still rolls.
rand_next :: proc(gs: ^Game_State) -> u64 {
    if gs.loot_rng == 0 do gs.loot_rng = 0x9E3779B97F4A7C15
    x := gs.loot_rng
    x ~= x << 13
    x ~= x >> 7
    x ~= x << 17
    gs.loot_rng = x
    return x
}

// Uniform in [0, 1).
rand_f32 :: proc(gs: ^Game_State) -> f32 {
    return f32(rand_next(gs) & 0xFFFFFF) / f32(0x1000000)
}

// Uniform in [lo, hi].
rand_range :: proc(gs: ^Game_State, lo, hi: int) -> int {
    if hi <= lo do return lo
    return lo + int(rand_next(gs) % u64(hi - lo + 1))
}

// Drop a stack on the ground at or near a tile.  Rings outward (nearest
// first) to the first cell that already stacks this item with room, or is
// empty and not inside solid terrain — so multiple drops from one death
// never clobber each other.  If everything nearby is taken, the origin cell
// is claimed outright: a guaranteed drop (the Hell Key) can never be lost.
spawn_ground_item :: proc(w: ^World_Grid, tile: [2]i32, item: Item, count: int) {
    if item == .None || count <= 0 do return
    n := u8(min(count, MAX_STACK))
    for r in i32(0) ..= 2 {
        for dy in -r ..= r do for dx in -r ..= r {
            if max(abs(dx), abs(dy)) != r do continue  // this ring only
            x := int(tile.x + dx)
            y := int(tile.y + dy)
            if !in_bounds(x, y) do continue
            idx := grid_idx(x, y)
            if .Solid in terrain_table[w.terrain[idx]].flags do continue
            if w.items[idx] == item && w.item_counts[idx] > 0 && int(w.item_counts[idx]) < MAX_STACK {
                w.item_counts[idx] += min(n, u8(MAX_STACK) - w.item_counts[idx])
                return
            }
            if w.items[idx] == .None || w.item_counts[idx] == 0 {
                w.items[idx]       = item
                w.item_counts[idx] = n
                return
            }
        }
    }
    idx := grid_idx(int(tile.x), int(tile.y))
    w.items[idx]       = item
    w.item_counts[idx] = n
}

roll_enemy_drops :: proc(gs: ^Game_State, kind: Enemy_Kind, tile: [2]i32) {
    for d in enemy_drop_table[kind] {
        if d.item == .None do continue
        if rand_f32(gs) >= d.chance do continue
        spawn_ground_item(&gs.world, tile, d.item, rand_range(gs, int(d.min), int(d.max)))
    }
}
