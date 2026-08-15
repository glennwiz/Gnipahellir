package game

import "core:testing"
import "core:log"

// ─── Conservation fuzz harness ────────────────────────────────────────────────
//
//  Drives the real item-moving handlers (pickup, drop, mine, place, craft,
//  loot spawn) with a seeded random action stream inside a private arena and
//  checks the ledger after every action: no item may be created or destroyed
//  except by the table-defined delta of the action that ran.
//
//  Fully deterministic: the same FUZZ_SEED replays the identical stream, so a
//  logged iteration number is a complete reproduction recipe.  The run does
//  not stop at the first violation — it censuses them (first FUZZ_LOG_CAP in
//  detail) so one run maps every leak the stream can reach.

FUZZ_SEED    :: 0x6E69_7061
FUZZ_ITERS   :: 3000
FUZZ_LOG_CAP :: 10

// The fuzz arena: an underground yard rebuilt from scratch so every tile,
// flag, and pile in it is known.  The ledger still counts the whole grid —
// drops that ring just past the arena edge stay on the books.
FUZZ_X0 :: 30
FUZZ_Y0 :: 62
FUZZ_W  :: 40
FUZZ_H  :: 26

// Simple stackables only.  Rune scrolls route into chests and use-items
// (buckets transmute, golems load wands) are their own systems — separate
// harness scenarios when their turn comes.
@(rodata)
fuzz_pool := [?]Item{.Dirt, .Stone_Block, .Wood_Log, .Iron_Ore, .Silver_Ore, .Flower_Seed}

// The subset the place action wields on purpose (the rest of the pool still
// reaches placement through the random-hand path).
@(rodata)
fuzz_blocks := [?]Item{.Dirt, .Stone_Block, .Wood_Log}

// Own xorshift so the stream never entangles with gs.loot_rng.
@(private = "file")
fz_next :: proc(s: ^u64) -> u64 {
    x := s^
    if x == 0 do x = 0x9E3779B97F4A7C15
    x ~= x << 13
    x ~= x >> 7
    x ~= x << 17
    s^ = x
    return x
}

@(private = "file")
fz_range :: proc(s: ^u64, lo, hi: int) -> int { // inclusive
    if hi <= lo do return lo
    return lo + int(fz_next(s) % u64(hi - lo + 1))
}

// Every place an item count lives.  Barrels/silos/depots are not exercised
// by this stream (the arena holds none), so their records stay zero.
@(private = "file")
fuzz_ledger :: proc(gs: ^Game_State) -> [Item]int {
    tot: [Item]int
    for it, i in gs.world.items {
        if it != .None && gs.world.item_counts[i] > 0 {
            tot[it] += int(gs.world.item_counts[i])
        }
    }
    for sd in gs.world.sim_data {
        if sd.store_count > 0 do tot[sd.store_item] += int(sd.store_count)
        if sd.in_count > 0 do tot[sd.in_item] += int(sd.in_count)
    }
    for s in gs.player.inventory.slots {
        if s.item != .None && s.count > 0 do tot[s.item] += s.count
    }
    for it in gs.player.equipment {
        if it != .None do tot[it] += 1
    }
    if v := gs.player.void_slot; v.item != .None && v.count > 0 {
        tot[v.item] += v.count
    }
    tot[.None] = 0
    return tot
}

@(private = "file")
fuzz_delta_is :: proc(before, after, want: ^[Item]int) -> bool {
    for v, it in after {
        if v - before[it] != want[it] do return false
    }
    return true
}

@(test)
items_are_conserved_under_random_play :: proc(t: ^testing.T) {
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs)
    gs.delta_time = 1.0 / 60.0

    rng: u64 = FUZZ_SEED

    // Rebuild the arena: known pct-0 tiles, no flags, no piles, cold sim data.
    for y in FUZZ_Y0 ..< FUZZ_Y0 + FUZZ_H {
        for x in FUZZ_X0 ..< FUZZ_X0 + FUZZ_W {
            idx := grid_idx(x, y)
            tile: Tile_Type = .Air
            r := fz_range(&rng, 0, 99)
            switch {
            case r < 45: tile = .Stone
            case r < 55: tile = .Iron_Ore
            case r < 60: tile = .Silver_Ore
            }
            set_tile(&gs.world, x, y, tile)
            gs.world.tile_flags[idx]  = {}
            gs.world.sim_data[idx]    = {}
            gs.world.items[idx]       = .None
            gs.world.item_counts[idx] = 0
        }
    }

    violations := 0
    viol_by: [6]int
    action_names := [6]string{"pickup", "drop", "mine", "place", "craft", "loot spawn"}
    inv := &gs.player.inventory

    for iter in 0 ..< FUZZ_ITERS {
        // ── Scenario mutation — before the snapshot, totals may change freely ──
        px := fz_range(&rng, FUZZ_X0, FUZZ_X0 + FUZZ_W - 1)
        py := fz_range(&rng, FUZZ_Y0, FUZZ_Y0 + FUZZ_H - 1)
        gs.player.pos = {f32(px), f32(py)}

        if fz_range(&rng, 0, 9) == 0 do inv.slots = {}
        for _ in 0 ..< fz_range(&rng, 0, 4) {
            s := &inv.slots[fz_range(&rng, 0, MAX_INVENTORY - 1)]
            switch fz_range(&rng, 0, 3) {
            case 0: s^ = {}  // open a hole
            case 1: s^ = {fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)], MAX_STACK}
            case:   s^ = {fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)], fz_range(&rng, 1, MAX_STACK)}
            }
        }
        if fz_range(&rng, 0, 2) == 0 {
            // Seed a pile — solid cells included: placing a block onto a pile is
            // legal play (handle_place_request never looks at the item layer),
            // so an entombed pile is a reachable state, not a fixture fantasy.
            gidx := grid_idx(fz_range(&rng, FUZZ_X0, FUZZ_X0 + FUZZ_W - 1),
                             fz_range(&rng, FUZZ_Y0, FUZZ_Y0 + FUZZ_H - 1))
            gs.world.items[gidx]       = fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)]
            gs.world.item_counts[gidx] = u8(fz_range(&rng, 0, 3) == 0 ? MAX_STACK : fz_range(&rng, 1, MAX_STACK))
        }
        if fz_range(&rng, 0, 3) == 0 {
            // Stock a random recipe's ingredients so crafts sometimes succeed —
            // then sometimes brick every remaining slot shut, so the craft has
            // ingredients but nowhere to bank a result that frees no slot.
            r := &recipe_table[fz_range(&rng, 0, len(recipe_table) - 1)]
            for ing in r.ingredients {
                if ing.item != .None do inventory_insert(inv, ing.item, ing.count)
            }
            if fz_range(&rng, 0, 1) == 0 {
                for &s in inv.slots {
                    if s.item == .None || s.count == 0 {
                        s = {fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)], MAX_STACK}
                    }
                }
            }
        }

        // ── One action: set up, snapshot, fire, judge ──
        name: string
        want: [Item]int  // expected exact delta ...
        allow_zero := true  // ... OR nothing at all (refusal paths), unless cleared

        before: [Item]int
        placed_at:  [2]int
        placed_old: Tile_Type

        action := fz_range(&rng, 0, 5)
        switch action {
        case 0:
            name = "pickup"
            before = fuzz_ledger(gs)
            player_pickup(gs)

        case 1:
            name = "drop"
            slot := fz_range(&rng, 0, MAX_INVENTORY - 1)
            tx := px + fz_range(&rng, -3, 3)
            ty := py + fz_range(&rng, -3, 3)
            before = fuzz_ledger(gs)
            eq_push(&gs.events, Event{
                type = .Item_Drop, tile = {i32(tx), i32(ty)},
                payload = {int_val = i32(slot)},
            })

        case 2:
            name = "mine"
            mx, my, found := 0, 0, false
            for _ in 0 ..< 24 {
                cx := fz_range(&rng, FUZZ_X0, FUZZ_X0 + FUZZ_W - 1)
                cy := fz_range(&rng, FUZZ_Y0, FUZZ_Y0 + FUZZ_H - 1)
                if .Mineable in terrain_table[get_tile(&gs.world, cx, cy)].flags {
                    mx, my, found = cx, cy, true
                    break
                }
            }
            if !found do continue
            old := get_tile(&gs.world, mx, my)
            // Mirror handle_tile_mined's drop decision exactly.
            drop := terrain_table[old].drop_item
            if pct := terrain_table[old].drop_pct; pct > 0 {
                if whash(u32(grid_idx(mx, my)) * 2246822519 + 101) % 100 >= u32(pct) do drop = .None
            }
            if drop != .None do want[drop] += 1
            if gs.level_index == LEVEL_SURFACE && in_shaft_apron(&gs.world, mx, my) {
                want[.Dirt] += 1
            }
            allow_zero = false  // a mine always lands its table-defined payout
            before = fuzz_ledger(gs)
            eq_push(&gs.events, Event{type = .Tile_Mined, tile = {i32(mx), i32(my)}})

        case 3:
            name = "place"
            if fz_range(&rng, 0, 1) == 0 {
                inv.slots[TEST_HAND] = {
                    item  = fuzz_blocks[fz_range(&rng, 0, len(fuzz_blocks) - 1)],
                    count = fz_range(&rng, 1, 5),
                }
                inv.selected = TEST_HAND
            } else {
                inv.selected = fz_range(&rng, 0, MAX_INVENTORY - 1)
            }
            placed_at  = {px + fz_range(&rng, -2, 2), py + fz_range(&rng, -2, 2)}
            placed_old = get_tile(&gs.world, placed_at.x, placed_at.y)
            before = fuzz_ledger(gs)
            eq_push(&gs.events, Event{
                type = .Place_Request, tile = {i32(placed_at.x), i32(placed_at.y)},
            })

        case 4:
            name = "craft"
            ri := fz_range(&rng, 0, len(recipe_table) - 1)
            r := &recipe_table[ri]
            for ing in r.ingredients {
                if ing.item != .None do want[ing.item] -= ing.count
            }
            want[r.result] += r.result_count
            before = fuzz_ledger(gs)
            eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = i32(ri)}})

        case 5:
            // The loot-drop contract every caller relies on (enemy deaths,
            // machine spills, full-bag fallbacks): the whole stack must land.
            name = "loot spawn"
            it := fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)]
            n := fz_range(&rng, 1, MAX_STACK)
            want[it] += n
            allow_zero = false
            before = fuzz_ledger(gs)
            spawn_ground_item(&gs.world, {i32(px + fz_range(&rng, -2, 2)), i32(py + fz_range(&rng, -2, 2))}, it, n)
        }

        process_events(gs)
        after := fuzz_ledger(gs)

        ok: bool
        if action == 3 {
            // Judged by what the terrain did: an unchanged target must move no
            // items; a raised tile must cost exactly one item that places it.
            placed_new := get_tile(&gs.world, placed_at.x, placed_at.y)
            if placed_new == placed_old {
                ok = fuzz_delta_is(&before, &after, &want)  // want is all zero
            } else {
                spent: Item = .None
                ok = true
                for v, it in after {
                    d := v - before[it]
                    if d == 0 do continue
                    if d == -1 && spent == .None && item_table[it].place_tile == placed_new {
                        spent = it
                        want[it] = -1  // recorded so a failure log shows the expectation
                    } else {
                        ok = false
                    }
                }
                if spent == .None do ok = false
            }
        } else {
            zero: [Item]int
            ok = fuzz_delta_is(&before, &after, &want) ||
                 (allow_zero && fuzz_delta_is(&before, &after, &zero))
        }

        if !ok {
            violations += 1
            viol_by[action] += 1
            if violations <= FUZZ_LOG_CAP {
                log.errorf("conservation violation #%d -- iter %d, action %s:", violations, iter, name)
                for v, it in after {
                    d := v - before[it]
                    if d != 0 || want[it] != 0 {
                        log.errorf("    %s: delta %+d (expected %+d)", item_table[it].name, d, want[it])
                    }
                }
            }
        }
    }

    if violations > 0 {
        for n, a in viol_by {
            if n > 0 do log.errorf("  %s: %d violations", action_names[a], n)
        }
    }
    testing.expectf(t, violations == 0,
        "%d conservation violations in %d actions (seed 0x%x) -- first %d logged above",
        violations, FUZZ_ITERS, u64(FUZZ_SEED), min(violations, FUZZ_LOG_CAP))
}
