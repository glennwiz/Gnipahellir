package game

// ─── Auto-Miner: the snake that strips a dimension ────────────────────────────
//
//  A placed Auto_Miner base (dimensions only, one per expedition) grows a
//  snake: each tick the head BFS-tunnels one tile toward the nearest themed
//  ore, eats what it enters (ore → haul, stone → Stone_Block tax) and leaves
//  a Miner_Body trail.  The haul lives in wide u32 counts on the base — the
//  first bulk storage (draft1_machines.md §7.2) — withdrawn with E in
//  99-stacks.  Q-drop a gem beside the base to permanently raise its speed
//  tier.  Placing a miner ANCHORS the dimension (it stops regenerating —
//  the miner is the first Dimension Lock, §7.2.1); mining the base back
//  releases the anchor and the world collapses on next entry (§7.2.3).
//
//  While the player is elsewhere the snake sleeps; on re-entering the
//  dimension the owed game time pours into the tick timer and drains at a
//  capped rate per frame — the snake visibly blitzes through its backlog
//  instead of stalling the frame (flagg G6).

MINER_BASE_INTERVAL :: f32(3.0)  // seconds per block at tier 0
MINER_HAUL_SLOTS    :: 6
MINER_STEPS_PER_FRAME :: 32      // max BFS steps drained per frame — caps the re-entry hitch

// Feeding a gem sets the tier permanently (higher gem = faster snake).
@(rodata)
miner_gem_tier := #partial [Item]u8{
    .Emerald = 1,
    .Jade    = 2,
    .Diamond = 3,
    .Hel_Gem = 4,
}

@(rodata)
miner_tier_mult := [5]f32{1, 1.5, 2, 3, 5}

Miner_Haul :: struct {
    item:  Item,
    count: u32,   // wide count — thousands live here, not on u8 ground stacks
}

Miner_State :: struct {
    active:     bool,
    asleep:     bool,     // no reachable ore left — the dimension is played out
    base:       [2]i32,
    head:       [2]i32,
    tier:       u8,
    mine_timer: f32,
    last_time:  f32,      // gs.elapsed_time when the snake last ticked (catch-up)
    haul:       [MINER_HAUL_SLOTS]Miner_Haul,
}

miner_interval :: proc(m: ^Miner_State) -> f32 {
    return MINER_BASE_INTERVAL / miner_tier_mult[m.tier]
}

// ─── Tick (step 5b2, dimension level only) ────────────────────────────────────

update_miner :: proc(gs: ^Game_State) {
    m := &gs.dimension.miner
    if !m.active || gs.level_index != LEVEL_DIMENSION do return

    miner_absorb_gem(gs, m)
    m.last_time = gs.elapsed_time
    if m.asleep do return

    m.mine_timer += gs.delta_time
    steps := 0
    for m.mine_timer >= miner_interval(m) && steps < MINER_STEPS_PER_FRAME {
        m.mine_timer -= miner_interval(m)
        steps += 1
        if !miner_step(gs, &gs.world, m) {
            miner_fall_asleep(gs, m)
            return
        }
    }
}

// Re-entering the dimension: the game time that passed while the snake
// worked unwatched pours into the tick timer, and update_miner drains it
// MINER_STEPS_PER_FRAME at a time — hours away never stall a frame, the
// backlog plays out as a visible fast-forward.
miner_catchup :: proc(gs: ^Game_State) {
    m := &gs.dimension.miner
    if !m.active || m.asleep do return

    owed := gs.elapsed_time - m.last_time
    m.last_time = gs.elapsed_time
    steps := int(owed / miner_interval(m))
    if steps <= 0 do return

    m.mine_timer += owed
    notify(gs, "The miner kept gnawing — %d blocks of backlog to chew through", steps)
    log_action(gs, "Miner catch-up: %d steps queued", steps)
}

miner_fall_asleep :: proc(gs: ^Game_State, m: ^Miner_State) {
    m.asleep = true
    notify(gs, "The dimension is played out — the miner sleeps")
    log_action(gs, "Miner asleep: no reachable ore")
}

// ─── The snake step ───────────────────────────────────────────────────────────

// Which tiles the snake hunts: the dimension theme's veins (table-driven —
// a new theme automatically teaches the snake its riches).
miner_is_target :: proc(gs: ^Game_State, t: Tile_Type) -> bool {
    for vein in dimension_table[gs.dimension.kind].veins {
        if vein.tile != .Air && vein.tile == t do return true
    }
    return false
}

// Snake movement medium: it tunnels stone, crosses open voids, eats ore.
// `through_self` is the boxed-in fallback: the snake may re-enter its own
// body trail when virgin rock alone no longer reaches any ore.
miner_passable :: proc(gs: ^Game_State, t: Tile_Type, through_self: bool) -> bool {
    if through_self && t == .Miner_Body do return true
    return t == .Stone || t == .Void || miner_is_target(gs, t)
}

// BFS from the head to the nearest themed ore; returns the grid index of the
// FIRST step along that path, or -1 when no ore is reachable.
miner_find_step :: proc(gs: ^Game_State, w: ^World_Grid, m: ^Miner_State, through_self: bool) -> int {
    // BFS over the grid.  Fixed buffers, no allocation (CLAUDE.md).
    prev:    [GRID_W * GRID_H]i32
    visited: [GRID_W * GRID_H]bool
    queue:   [GRID_W * GRID_H]i32
    q_head, q_tail := 0, 0

    start := grid_idx(int(m.head.x), int(m.head.y))
    queue[q_tail] = i32(start); q_tail += 1
    visited[start] = true
    prev[start] = -1

    goal := -1
    for q_head < q_tail {
        cur := int(queue[q_head]); q_head += 1
        cx, cy := cur % GRID_W, cur / GRID_W
        if cur != start && miner_is_target(gs, w.terrain[cur]) {
            goal = cur
            break
        }
        dirs := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
        for d in dirs {
            nx, ny := cx + d.x, cy + d.y
            if nx < 1 || nx >= GRID_W-1 || ny < 1 || ny >= GRID_H-1 do continue
            n := grid_idx(nx, ny)
            if visited[n] do continue
            if !miner_passable(gs, w.terrain[n], through_self) do continue
            visited[n] = true
            prev[n] = i32(cur)
            queue[q_tail] = i32(n); q_tail += 1
        }
    }
    if goal < 0 do return -1

    // Walk back from the goal to find the FIRST step away from the head.
    step := goal
    for prev[step] != i32(start) do step = int(prev[step])
    return step
}

// One block of progress: advance one tile toward the nearest themed ore, eat
// what we enter, leave a body segment behind.  Prefers virgin rock; a snake
// boxed in by its own trail gnaws back through it.  Returns false when no
// ore is reachable either way.
miner_step :: proc(gs: ^Game_State, w: ^World_Grid, m: ^Miner_State) -> bool {
    step := miner_find_step(gs, w, m, false)
    if step < 0 do step = miner_find_step(gs, w, m, true)
    if step < 0 do return false  // played out

    // Eat the tile we enter.
    t := w.terrain[step]
    if miner_is_target(gs, t) {
        miner_haul_add(m, terrain_table[t].drop_item, 1)
    } else if t == .Stone {
        miner_haul_add(m, .Stone_Block, 1)  // the stone tax
    }

    // The trail: where the head was becomes body (the base tile stays).
    hx, hy := int(m.head.x), int(m.head.y)
    if get_tile(w, hx, hy) != .Auto_Miner {
        set_tile(w, hx, hy, .Miner_Body)
    }
    m.head = {i32(step % GRID_W), i32(step / GRID_W)}
    set_tile(w, int(m.head.x), int(m.head.y), .Miner_Body)
    return true
}

miner_haul_add :: proc(m: ^Miner_State, item: Item, n: u32) {
    if item == .None do return
    for &h in m.haul {
        if h.item == item { h.count += n; return }
    }
    for &h in m.haul {
        if h.item == .None || h.count == 0 { h.item = item; h.count = n; return }
    }
    // all slots taken by other items — drop the overflow (6 slots > any theme)
}

miner_haul_total :: proc(m: ^Miner_State) -> (total: u32) {
    for h in m.haul do total += h.count
    return
}

// ─── Player interactions ──────────────────────────────────────────────────────

// E beside the base: pour the haul into the bag, 99-stacks at a time.
miner_withdraw :: proc(gs: ^Game_State) {
    m   := &gs.dimension.miner
    inv := &gs.player.inventory
    taken_any := false
    for &h in m.haul {
        if h.item == .None || h.count == 0 do continue
        for h.count > 0 {
            batch  := int(min(h.count, u32(MAX_STACK)))
            before := inventory_count(inv, h.item)
            inventory_insert(inv, h.item, batch)
            taken := inventory_count(inv, h.item) - before
            h.count -= u32(taken)
            if taken > 0 do taken_any = true
            if taken < batch {  // bag is full
                notify(gs, "The bag is full — %d blocks stay in the miner", miner_haul_total(m))
                if taken_any do audio_play(&gs.audio, .Pickup)
                return
            }
        }
        h.item = .None
    }
    if taken_any {
        audio_play(&gs.audio, .Pickup)
        notify(gs, "Haul claimed — the miner keeps gnawing")
        log_action(gs, "Player withdraws miner haul")
    } else {
        notify(gs, "The miner has nothing yet — tier %d, one block per %.1fs",
            m.tier, miner_interval(m))
    }
}

// A gem Q-dropped beside the base is absorbed as a permanent speed tier.
miner_absorb_gem :: proc(gs: ^Game_State, m: ^Miner_State) {
    w := &gs.world
    for dy in -1 ..= 1 {
        for dx in -1 ..= 1 {
            x, y := int(m.base.x) + dx, int(m.base.y) + dy
            if !in_bounds(x, y) do continue
            idx := grid_idx(x, y)
            it  := w.items[idx]
            tier := miner_gem_tier[it]
            if tier == 0 || w.item_counts[idx] == 0 do continue
            if tier <= m.tier do continue  // lesser gems just lie there
            w.item_counts[idx] -= 1
            if w.item_counts[idx] == 0 do w.items[idx] = .None
            m.tier = tier
            audio_play(&gs.audio, .Fanfare)
            notify(gs, "The %s sinks in — the miner surges to one block per %.1fs",
                item_table[it].name, miner_interval(m))
            log_action(gs, "Miner fed %v: tier %d", it, m.tier)
            return  // one gem per tick is plenty
        }
    }
}

// Placing the base: wake the snake and anchor the dimension.
miner_on_placed :: proc(gs: ^Game_State, tile: [2]i32) {
    gs.dimension.miner = {
        active    = true,
        base      = tile,
        head      = tile,
        last_time = gs.elapsed_time,
    }
    audio_play(&gs.audio, .Fanfare)
    notify(gs, "The Auto-Miner bites the rock — this world is anchored while it works")
    log_action(gs, "Auto-Miner placed at (%d,%d), dimension anchored", tile.x, tile.y)
}

// Mining the base back: release the anchor; unclaimed haul is lost with the
// world (it collapses to seed on the next entry).
miner_on_mined :: proc(gs: ^Game_State) {
    m := &gs.dimension.miner
    lost := miner_haul_total(m)
    if lost > 0 {
        notify(gs, "The miner is reclaimed — %d unclaimed blocks are lost with the world", lost)
    } else {
        notify(gs, "The miner is reclaimed — the anchor releases")
    }
    log_action(gs, "Auto-Miner reclaimed; %d blocks lost", lost)
    m^ = {}
}
