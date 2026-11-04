package game

import "core:testing"
import "core:log"

// ─── Conservation fuzz harness ────────────────────────────────────────────────
//
//  Drives the real item-moving handlers (pickup, drop, mine, place, craft,
//  loot spawn, machine ticks) with a seeded random action stream inside a private arena and
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
FUZZ_MACHINE_MIN :: 5  // fewest runs of each machine path (cast, burn, copy, pull) a stream must show

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
fuzz_blocks := [?]Item{.Dirt, .Stone_Block, .Wood_Log, .Crafting_Bench, .Door, .Turret_Pillar, .Flame_Head, .Water_Head, .Earth_Head, .Rainbow_Laser}

// What the machine action runs, and what it lays around one: the feed every
// machine takes (ores, wood, gems) and some it must refuse.
@(rodata)
fuzz_machines := [?]Tile_Type{.Smelter, .Boiler, .Magic_Kettle, .Gem_Replicator, .Silo}
@(rodata)
fuzz_feed := [?]Item{.Wood_Log, .Iron_Ore, .Silver_Ore, .Gold_Ore, .Gold_Rare_Ore, .Emerald, .Jade, .Diamond, .Dirt, .Iron_Bar}
@(rodata)
fuzz_gems := [?]Item{.Emerald, .Jade, .Diamond, .Hel_Gem}

// One cell of the machine action's 3x3, kept so the arena gets it back.
@(private = "file")
Fuzz_Cell :: struct {
    tile:  Tile_Type,
    flags: Tile_Flags,
    sd:    Sim_Tile_Data,
    item:  Item,
    count: u8,
}

// Coverage of the machine action: each path must run FUZZ_MACHINE_MIN times,
// or the fuzzer proves next to nothing about it.
@(private = "file")
Fuzz_Machine_Census :: struct {
    casts, wood_burnt, gems_burnt, copies, barrel_pulls, silo_intakes: int,
}

@(private = "file")
fuzz_store_totals :: proc(gs: ^Game_State) -> (barrels, silos: int) {
    for &b in gs.sim.barrels do if b.active do barrels += barrel_total(&b)
    for &s in gs.sim.silos do if s.active do silos += int(silo_total(&s))
    return
}

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

// Every place an item count lives.
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
        tot[FUEL_ITEM] += int(sd.fuel_count)
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
    for s in gs.risen.kit {
        if s.item != .None && s.count > 0 do tot[s.item] += s.count
    }
    for d in gs.golems.depots do if d.active {
        for s in d.slots do tot[s.item] += int(s.count)
    }
    for b in gs.sim.barrels do if b.active {
        for s in b.slots do if s.count > 0 do tot[s.item] += s.count
    }
    for s in gs.sim.silos do if s.active {
        for slot in s.slots do tot[slot.item] += int(slot.count)
    }
    tot[.None] = 0
    return tot
}

// Mirror turret_come_apart: mining one part of a fused turret pays the rest.
@(private = "file")
fuzz_turret_parts :: proc(gs: ^Game_State, x, y: int, old: Tile_Type, want: ^[Item]int) {
    head_y := y
    rule   := turret_table[old]
    if old == .Turret_Pillar {
        head_y -= 1
        for get_tile(&gs.world, x, head_y) == .Turret_Pillar do head_y -= 1
        rule = turret_table[get_tile(&gs.world, x, head_y)]
        if rule.pillars < y - head_y do return
        want[terrain_table[get_tile(&gs.world, x, head_y)].drop_item] += 1
    }
    for i in 1 ..= rule.pillars {
        if head_y + i == y do continue
        if get_tile(&gs.world, x, head_y + i) != .Turret_Pillar do break
        want[.Turret_Pillar] += 1
    }
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
    viol_by: [14]int
    action_names := [14]string{"pickup", "drop", "mine", "place", "craft", "loot spawn", "risen hero falls", "smelter feed", "smelter fuel back", "undermine", "monument smash", "depot smash", "monument fall", "machine tick"}
    census: Fuzz_Machine_Census
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
        furnace_at:  [2]int  // the furnace a smelter action borrows, and what stood there
        furnace_old: Tile_Type
        depot_at:  [2]i32  // the depot a depot smash raises, and what stood there
        depot_old: Tile_Type
        mach_at:  [2]int  // the machine a machine tick raises, and the 3x3 it stood in
        mach_box: [9]Fuzz_Cell
        mach_kind: Tile_Type
        frame_bad := false  // a machine frame moved items no rule explains
        bad_frame: struct { frame, sounds: int, burnt: bool }

        action := fz_range(&rng, 0, 13)
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
            fuzz_turret_parts(gs, mx, my, old, &want)
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

        case 6:
            // The risen hero falls: the kit leaves the record for the ground,
            // and the ledger counts both, so the only allowed delta is nothing.
            name = "risen hero falls"
            id, got := enemy_alloc(&gs.enemies)
            if !got do continue
            gs.enemies.data[id].pos = {f32(px + fz_range(&rng, -2, 2)), f32(py + fz_range(&rng, -2, 2))}
            gs.risen = {has_kit = true, walking = true, slot = id}
            for i in 0 ..< fz_range(&rng, 1, RISEN_KIT) {
                gs.risen.kit[i] = {fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)], fz_range(&rng, 1, MAX_STACK)}
            }
            before = fuzz_ledger(gs)
            despawn_enemy(gs, id)

        case 7, 8:
            // Moves between the bag and the furnace: only ever nothing lost.
            name = action_names[action]
            furnace_at  = {px + fz_range(&rng, -2, 2), py + fz_range(&rng, -2, 2)}
            furnace_old = get_tile(&gs.world, furnace_at.x, furnace_at.y)
            if !in_bounds(furnace_at.x, furnace_at.y) do continue
            set_tile(&gs.world, furnace_at.x, furnace_at.y, .Smelter)
            gs.world.sim_data[grid_idx(furnace_at.x, furnace_at.y)] = {fuel_count = u8(fz_range(&rng, 0, MAX_STACK))}
            T := [2]i32{i32(furnace_at.x), i32(furnace_at.y)}
            before = fuzz_ledger(gs)
            if action == 7 {
                eq_push(&gs.events, Event{
                    type = .Smelter_Feed, tile = T,
                    payload = {int_val = i32(fz_range(&rng, 0, MAX_INVENTORY - 1))},
                    count = i32(fz_range(&rng, 0, MAX_STACK)),
                })
            } else {
                eq_push(&gs.events, Event{type = .Smelter_Withdraw_Fuel, tile = T})
            }

        case 9:
            // Whatever lost its ground pays out as if mined, and nothing else.
            name = "undermine"
            for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
                if !is_undermined(gs, x, y) do continue
                old := get_tile(&gs.world, x, y)
                want[terrain_table[old].drop_item] += 1
                fuzz_turret_parts(gs, x, y, old, &want)
                allow_zero = false
            }
            before = fuzz_ledger(gs)
            update_undermined(gs)

        case 10:
            // An enemy breaks a golem-built monument cell, by a dig or by a
            // raid's demolition: the item it was built from lands, nothing else.
            name = "monument smash"
            plan := Golem_Plan(fz_range(&rng, int(Golem_Plan.Clay_Hearth), int(Golem_Plan.World_Anchor)))
            cells := golem_plan_table[plan].cells
            c := cells[fz_range(&rng, 0, len(cells) - 1)]
            T := [2]i32{i32(px + fz_range(&rng, -2, 2)), i32(py + fz_range(&rng, -2, 2))}
            gs.golems.projects[gs.level_index] = {active = true, plan = plan, level = gs.level_index, anchor = T - c.off}
            set_tile(&gs.world, int(T.x), int(T.y), c.tile)
            gs.monument_cells[gs.level_index][grid_idx(int(T.x), int(T.y))] = c.tile
            if !is_structure_tile[c.tile] do gs.world.tile_flags[grid_idx(int(T.x), int(T.y))] += {.Placed}
            want[c.item] += 1
            allow_zero = false
            before = fuzz_ledger(gs)
            if fz_range(&rng, 0, 1) == 0 {
                smash_tile(gs, int(T.x), int(T.y))
            } else {
                handle_tile_mined(gs, Event{type = .Tile_Mined, source = enemy_entity_id(0), tile = T})
            }
            gs.golems.projects[gs.level_index] = {}

        case 11:
            // An enemy takes a stocked Golem Depot: refused while it holds
            // cargo, or, by a direct mine, the cargo spills and its Emerald lands.
            name = "depot smash"
            c: Golem_Build_Cell
            for cell in golem_plan_table[.Golem_Depot].cells do if cell.tile == .Golem_Depot do c = cell
            depot_at = {i32(px + fz_range(&rng, -2, 2)), i32(py + fz_range(&rng, -2, 2))}
            depot_old = get_tile(&gs.world, int(depot_at.x), int(depot_at.y))
            gs.golems.projects[gs.level_index] = {active = true, plan = .Golem_Depot, level = gs.level_index, anchor = depot_at - c.off}
            set_tile(&gs.world, int(depot_at.x), int(depot_at.y), .Golem_Depot)
            gs.monument_cells[gs.level_index][grid_idx(int(depot_at.x), int(depot_at.y))] = .Golem_Depot
            golem_depot_on_built(gs, depot_at)
            d := golem_depot_at(gs, gs.level_index, depot_at)
            for _ in 0 ..< fz_range(&rng, 0, 3) {
                golem_depot_add(d, fuzz_pool[fz_range(&rng, 0, len(fuzz_pool) - 1)], u32(fz_range(&rng, 1, 3 * MAX_STACK)))
            }
            want[c.item] += 1
            before = fuzz_ledger(gs)
            if fz_range(&rng, 0, 1) == 0 {
                smash_tile(gs, int(depot_at.x), int(depot_at.y))
            } else {
                handle_tile_mined(gs, Event{type = .Tile_Mined, source = enemy_entity_id(0), tile = depot_at})
            }
            gs.golems.projects[gs.level_index] = {}

        case 12:
            // A golem-built block that falls (card 153) still pays the item it
            // was built from: where it crumbles, or by the pick where it settles.
            name = "monument fall"
            plan := Golem_Plan(fz_range(&rng, int(Golem_Plan.Clay_Hearth), int(Golem_Plan.World_Anchor)))
            cells := golem_plan_table[plan].cells
            c := cells[fz_range(&rng, 0, len(cells) - 1)]
            if .Falls not_in terrain_table[c.tile].flags && .Falls_Placed not_in terrain_table[c.tile].flags do continue
            x := fz_range(&rng, FUZZ_X0 + 2, FUZZ_X0 + FUZZ_W - 3)
            y := fz_range(&rng, FUZZ_Y0 + 1, FUZZ_Y0 + FUZZ_H - 6)
            drop := fz_range(&rng, 1, 3)  // rows of air under the cell
            // A pocket: a natural anchor on the left, natural rock round it, air under the cell to a floor.
            for yy in y - 1 ..= y + drop + 1 do for xx in x - 2 ..= x + 1 {
                set_tile(&gs.world, xx, yy, .Stone)
                gs.world.tile_flags[grid_idx(xx, yy)] = {}
            }
            set_tile(&gs.world, x, y - 1, .Air)
            set_tile(&gs.world, x + 1, y, .Air)
            for yy in y + 1 ..= y + drop do set_tile(&gs.world, x, yy, .Air)
            T := [2]i32{i32(x), i32(y)}
            gs.golems.projects[gs.level_index] = {active = true, plan = plan, level = gs.level_index, anchor = T - c.off}
            set_tile(&gs.world, x, y, c.tile)
            gs.monument_cells[gs.level_index][grid_idx(x, y)] = c.tile
            gs.world.tile_flags[grid_idx(x, y)] += {.Placed}
            want[c.item] += 1
            allow_zero = false
            before = fuzz_ledger(gs)
            set_tile(&gs.world, x - 1, y, .Air)
            gravity_check_removed(gs, x - 1, y)
            for _ in 0 ..< 120 do update_gravity(gs)
            if land := y + drop; get_tile(&gs.world, x, land) == c.tile {
                if gs.level_index == LEVEL_SURFACE && in_shaft_apron(&gs.world, x, land) do want[.Dirt] += 1
                eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {i32(x), i32(land)}})
            }
            gs.golems.projects[gs.level_index] = {}

        case 13:
            // A machine runs on its own (card 173): a smelter, boiler, Magic
            // Kettle, Gem Replicator or silo, ringed by piles, barrels, silos, a
            // depot and fluids, ticked frame by frame.  Each frame may move items
            // only between piles, buffers and stores, except by the rule of a
            // sink or source the frame showed by other means: a cast (its pour
            // sound) eats a bar's ore and, cold, FUEL_PER_BAR wood for one bar; a
            // burn (the burn clock restarting) eats one fuel unit, wood for a
            // boiler, a gem for the kettle; a copy (its sound) adds one seed gem.
            name = "machine tick"
            mx := fz_range(&rng, FUZZ_X0 + 1, FUZZ_X0 + FUZZ_W - 2)
            my := fz_range(&rng, FUZZ_Y0 + 1, FUZZ_Y0 + FUZZ_H - 2)
            mach_at = {mx, my}
            for dy in -1 ..= 1 do for dx in -1 ..= 1 {
                i := grid_idx(mx + dx, my + dy)
                w := &gs.world
                mach_box[(dy + 1) * 3 + dx + 1] = {w.terrain[i], w.tile_flags[i], w.sim_data[i], w.items[i], w.item_counts[i]}
                set_tile(w, mx + dx, my + dy, .Air)
                w.tile_flags[i], w.sim_data[i], w.items[i], w.item_counts[i] = {}, {}, .None, 0
            }
            mach_kind = fuzz_machines[fz_range(&rng, 0, len(fuzz_machines) - 1)]
            kind := mach_kind
            T := [2]i32{i32(mx), i32(my)}
            set_tile(&gs.world, mx, my, kind)
            if kind == .Silo do silo_on_placed(gs, T)
            // A kettle mostly gets an open mouth and its drink, or it would
            // never burn: those two cells are kept out of the random ring.
            rule, is_boiler := boiler_rule_for(kind)
            kept := is_boiler && fz_range(&rng, 0, 2) > 0
            sides := [3][2]i32{{-1, 0}, {1, 0}, {0, 1}}
            drink := T + sides[fz_range(&rng, 0, 2)]
            if kept do set_tile(&gs.world, int(drink.x), int(drink.y), rule.source)
            for dy in -1 ..= 1 do for dx in -1 ..= 1 {
                if dx == 0 && dy == 0 do continue
                at := [2]i32{i32(mx + dx), i32(my + dy)}
                if kept && (at == drink || at == T + {0, -1}) do continue
                i  := grid_idx(int(at.x), int(at.y))
                r  := fz_range(&rng, 0, 9)
                switch {
                case r < 4:
                    gs.world.items[i]       = fuzz_feed[fz_range(&rng, 0, len(fuzz_feed) - 1)]
                    gs.world.item_counts[i] = u8(fz_range(&rng, 1, MAX_STACK))
                case r < 6:
                    if !barrel_slot_free(gs) do continue
                    set_tile(&gs.world, int(at.x), int(at.y), .Barrel)
                    barrel_on_placed(gs, at)
                    b := barrel_at(gs, gs.level_index, at)
                    for _ in 0 ..< fz_range(&rng, 0, 6) {
                        _ = barrel_deposit(b, fuzz_feed[fz_range(&rng, 0, len(fuzz_feed) - 1)], fz_range(&rng, 1, 2 * MAX_STACK))
                    }
                case r < 7:
                    if !silo_slot_free(gs) do continue
                    set_tile(&gs.world, int(at.x), int(at.y), .Silo)
                    silo_on_placed(gs, at)
                    s := silo_at(gs, gs.level_index, at)
                    for _ in 0 ..< fz_range(&rng, 0, SILO_SLOTS + 1) {
                        silo_add(s, fuzz_feed[fz_range(&rng, 0, len(fuzz_feed) - 1)], u32(fz_range(&rng, 1, 3 * MAX_STACK)))
                    }
                case r < 8:
                    set_tile(&gs.world, int(at.x), int(at.y), .Golem_Depot)
                    golem_depot_on_built(gs, at)
                    d := golem_depot_at(gs, gs.level_index, at)
                    if d == nil {
                        set_tile(&gs.world, int(at.x), int(at.y), .Air)
                        continue
                    }
                    for _ in 0 ..< fz_range(&rng, 0, 3) {
                        _ = golem_depot_add(d, fuzz_feed[fz_range(&rng, 0, len(fuzz_feed) - 1)], u32(fz_range(&rng, 1, 3 * MAX_STACK)))
                    }
                case r < 9:
                    fluids := [3]Tile_Type{.Water, .Lava, .Magic_Lava}
                    set_tile(&gs.world, int(at.x), int(at.y), fluids[fz_range(&rng, 0, 2)])
                }
            }
            sd := &gs.world.sim_data[grid_idx(mx, my)]
            #partial switch kind {
            case .Smelter:
                if fz_range(&rng, 0, 1) == 0 {
                    sd.in_item  = smelt_table[fz_range(&rng, 0, len(smelt_table) - 1)].ore
                    sd.in_count = u8(fz_range(&rng, 1, MAX_STACK))
                }
                sd.fuel_count = u8(fz_range(&rng, 0, MAX_STACK))
                if fz_range(&rng, 0, 1) == 0 {
                    sd.store_item  = smelt_table[fz_range(&rng, 0, len(smelt_table) - 1)].bar
                    sd.store_count = u8(fz_range(&rng, 1, MAX_STACK))
                }
                sd.growth_timer = f32(fz_range(&rng, 0, 29)) * 0.1
            case .Boiler:
                sd.fuel_count   = u8(fz_range(&rng, 0, MAX_STACK))
                sd.spread_timer = f32(fz_range(&rng, 0, 5)) * 0.1  // near a burn: one puff dries or caps it
                sd.growth_timer = f32(fz_range(&rng, 0, 19)) * 0.1
            case .Magic_Kettle:
                if fz_range(&rng, 0, 1) == 0 {
                    sd.in_item  = fuzz_gems[fz_range(&rng, 0, len(fuzz_gems) - 1)]
                    sd.in_count = u8(fz_range(&rng, 1, MAX_STACK))
                }
                sd.spread_timer = f32(fz_range(&rng, 0, 5)) * 0.1  // near a burn: one puff dries or caps it
                sd.growth_timer = f32(fz_range(&rng, 0, 19)) * 0.1
            case .Gem_Replicator:
                if fz_range(&rng, 0, 2) > 0 {
                    sd.in_item  = fuzz_gems[fz_range(&rng, 0, len(fuzz_gems) - 1)]
                    sd.in_count = 1
                    period, _ := gem_replicate_time_for(sd.in_item)
                    sd.growth_timer = period - f32(fz_range(&rng, 0, 50)) * 0.1
                }
                if fz_range(&rng, 0, 1) == 0 {
                    sd.store_item  = fz_range(&rng, 0, 1) == 0 && sd.in_item != .None ? sd.in_item : fuzz_gems[fz_range(&rng, 0, len(fuzz_gems) - 1)]
                    sd.store_count = u8(fz_range(&rng, 1, MAX_STACK))
                }
            }
            if fz_range(&rng, 0, 2) == 0 do gs.power.charge[grid_idx(mx, my)] = 1000
            gs.delta_time = fz_range(&rng, 0, 1) == 0 ? 1.0 / 60.0 : 0.5
            allow_zero = false
            before = fuzz_ledger(gs)

            prev := before
            for f in 0 ..< fz_range(&rng, 1, 60) {
                pre       := sd^
                is_pw     := powered(gs, mx, my)
                q_size    := gs.events.size
                q_tail    := gs.events.tail
                b0, s0    := fuzz_store_totals(gs)
                for dy in -1 ..= 1 do for dx in -1 ..= 1 {  // update_sim's scan order, over the 3x3
                    if tick := tile_on_tick[get_tile(&gs.world, mx + dx, my + dy)]; tick != nil do tick(gs, mx + dx, my + dy)
                }
                sounds := 0
                for k in 0 ..< gs.events.size - q_size {
                    e := gs.events.events[(q_tail + k) % MAX_EVENTS]
                    if e.type != .Play_Sound || e.tile != T do continue
                    if (kind == .Smelter && Sound_ID(e.payload.int_val) == .Smelter_Pour) ||
                       (kind == .Gem_Replicator && Sound_ID(e.payload.int_val) == .Place) {
                        sounds += 1
                    }
                }
                burnt := (kind == .Boiler || kind == .Magic_Kettle) && sd.spread_timer > pre.spread_timer

                // Every delta this frame's observations allow; exactly one must match.
                cands: [len(smelt_table) + len(fuzz_gems) + 1][Item]int
                n_cands := 0
                switch {
                case sounds > 1:
                    // more than one cast or copy in a frame: no rule allows it
                case kind == .Smelter && sounds == 1:
                    for r in smelt_table {
                        cands[n_cands][r.bar] += 1
                        cands[n_cands][r.ore] -= r.ore_per_bar
                        if !is_pw do cands[n_cands][FUEL_ITEM] -= FUEL_PER_BAR
                        n_cands += 1
                    }
                case kind == .Gem_Replicator && sounds == 1:
                    cands[n_cands][sd.in_item] += 1
                    n_cands += 1
                case kind == .Boiler && burnt:
                    rule, _ := boiler_rule_for(.Boiler)
                    cands[n_cands][rule.fuel_item] -= 1
                    n_cands += 1
                case kind == .Magic_Kettle && burnt:
                    for g in fuzz_gems {
                        cands[n_cands][g] -= 1
                        n_cands += 1
                    }
                case sounds == 0:
                    n_cands = 1  // nothing made or burnt: nothing may change
                }
                now := fuzz_ledger(gs)
                hit := -1
                for &c, ci in cands[:n_cands] {
                    if fuzz_delta_is(&prev, &now, &c) { hit = ci; break }
                }
                if hit < 0 {
                    frame_bad = true
                    bad_frame = {f, sounds, burnt}
                    break
                }
                for v, it in cands[hit] do want[it] += v
                switch {
                case kind == .Smelter && sounds == 1:   census.casts += 1
                case kind == .Gem_Replicator && sounds == 1: census.copies += 1
                case kind == .Boiler && burnt:          census.wood_burnt += 1
                case kind == .Magic_Kettle && burnt:    census.gems_burnt += 1
                }
                b1, s1 := fuzz_store_totals(gs)
                if b1 < b0 do census.barrel_pulls += 1
                if s1 > s0 do census.silo_intakes += 1
                prev = now
            }
            gs.delta_time = 1.0 / 60.0
        }

        process_events(gs)
        for _ in 0 ..< ITEM_FALL_FRAMES {  // falling piles move, and only move
            update_item_fall(gs)
            gs.frame += 1
        }
        after := fuzz_ledger(gs)
        if action == 7 || action == 8 {  // the arena gets its tile back; totals may move freely here
            set_tile(&gs.world, furnace_at.x, furnace_at.y, furnace_old)
            gs.world.sim_data[grid_idx(furnace_at.x, furnace_at.y)] = {}
        }
        if action == 11 && get_tile(&gs.world, int(depot_at.x), int(depot_at.y)) == .Golem_Depot {
            // A refused depot gives the arena its tile back, record and all.
            if d := golem_depot_at(gs, gs.level_index, depot_at); d != nil do d^ = {}
            gs.monument_cells[gs.level_index][grid_idx(int(depot_at.x), int(depot_at.y))] = .Air
            set_tile(&gs.world, int(depot_at.x), int(depot_at.y), depot_old)
        }

        if action == 13 {
            // The arena gets its 3x3 back; every record raised in it is freed.
            for dy in -1 ..= 1 do for dx in -1 ..= 1 {
                x, y := mach_at.x + dx, mach_at.y + dy
                at := [2]i32{i32(x), i32(y)}
                if b := barrel_at(gs, gs.level_index, at); b != nil do b^ = {}
                if s := silo_at(gs, gs.level_index, at); s != nil do s^ = {}
                if d := golem_depot_at(gs, gs.level_index, at); d != nil do d^ = {}
                c := mach_box[(dy + 1) * 3 + dx + 1]
                i := grid_idx(x, y)
                set_tile(&gs.world, x, y, c.tile)
                gs.world.tile_flags[i], gs.world.sim_data[i], gs.world.items[i], gs.world.item_counts[i] = c.flags, c.sd, c.item, c.count
                gs.power.charge[i] = 0
            }
        }

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
            ok = !frame_bad && (fuzz_delta_is(&before, &after, &want) ||
                 (allow_zero && fuzz_delta_is(&before, &after, &zero)))
        }

        if !ok {
            violations += 1
            viol_by[action] += 1
            if violations <= FUZZ_LOG_CAP {
                log.errorf("conservation violation #%d -- iter %d, action %s:", violations, iter, name)
                if frame_bad {
                    log.errorf("    %v at %v, frame %d: items moved that no cast, burn or copy explains (sounds %d, burnt %v); the frames before it are summed below",
                        mach_kind, mach_at, bad_frame.frame, bad_frame.sounds, bad_frame.burnt)
                }
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
    log.infof("machine census: %v", census)
    testing.expectf(t, min(census.casts, census.wood_burnt, census.gems_burnt, census.copies,
                           census.barrel_pulls, census.silo_intakes) >= FUZZ_MACHINE_MIN,
        "a machine path ran under %d times: %v", FUZZ_MACHINE_MIN, census)
    testing.expectf(t, violations == 0,
        "%d conservation violations in %d actions (seed 0x%x) -- first %d logged above",
        violations, FUZZ_ITERS, u64(FUZZ_SEED), min(violations, FUZZ_LOG_CAP))
}
