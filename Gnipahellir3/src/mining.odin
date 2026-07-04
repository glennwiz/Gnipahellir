package game

// ─── Mining: pick and wand ────────────────────────────────────────────────────
//
//  Two-stage tool progression (G2's feel, ported):
//    - Pickaxe: free, adjacent tiles only (chebyshev 1), PICK_HITS chips per
//      tile — clicks right in front of you, sparks on every hit.
//    - Mine wands: crafted tiers reach 2 / 4 / 8 tiles and drink mana per
//      shot.  A shot streams sparks to the tile and mines on impact
//      (WAND_TRAVEL_TIME later) — the mining lands where the magic lands.
//  The best wand carried decides reach; adjacent tiles always use the free
//  pick so the wand never wastes mana on trivial digs.

PICK_RANGE      :: i32(1)
PICK_HITS       :: 3
PICK_SWING_TIME :: f32(0.28)

WAND_MANA_COST   :: f32(5)     // pool 100, regen 5/s: ~20-shot burst, then throttled
WAND_COOLDOWN    :: f32(0.25)
WAND_TRAVEL_TIME :: f32(0.18)  // G2's spark travel

@(rodata)
wand_mine_range := #partial [Item]i32{
    .Mine_Wand        = 2,
    .Mine_Wand_Silver = 4,
    .Mine_Wand_Gold   = 8,
}

// Longest-reaching wand in the inventory (0 = none carried).
best_wand :: proc(inv: ^Inventory) -> (best: Item, r: i32) {
    for s in inv.slots {
        if s.count > 0 && wand_mine_range[s.item] > r {
            best = s.item
            r    = wand_mine_range[s.item]
        }
    }
    return
}

// Called from update_player while the mine button is held.
player_mine :: proc(gs: ^Game_State, dt: f32) {
    p := &gs.player
    p.mine_timer -= dt
    if !gs.input.mine || p.mine_timer > 0 { return }

    T  := gs.input.mouse_tile
    tx := int(T.x)
    ty := int(T.y)
    if !in_bounds(tx, ty) { return }
    if .Mineable not_in terrain_table[get_tile(&gs.world, tx, ty)].flags { return }

    d := chebyshev(T, player_tile(p))

    // Pick: right in front, free, chips per tile.
    if d <= PICK_RANGE {
        if inventory_count(&p.inventory, .Pickaxe) == 0 { return }
        p.mine_timer = PICK_SWING_TIME
        if p.chip_tile != T {
            p.chip_tile = T
            p.chip_hits = 0
        }
        p.chip_hits += 1
        spawn_chip_sparks(gs, T)
        if int(p.chip_hits) >= PICK_HITS {
            p.chip_hits = 0
            eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = T})
        } else {
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Mine)}})
        }
        return
    }

    // Wand: reach beyond arm's length costs mana.
    wand, wrange := best_wand(&p.inventory)
    if wand == .None || d > wrange { return }
    if p.mana < WAND_MANA_COST {
        p.mine_timer = 0.6   // rate-limits the reminder while the button is held
        notify(gs, "Not enough mana!")
        return
    }
    p.mana      -= WAND_MANA_COST
    p.mine_timer = WAND_COOLDOWN
    gs.mining = {active = true, target = T, travel = WAND_TRAVEL_TIME}
    spawn_wand_stream(gs, T)
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Wand_Fire)}})
}

// Step 5 in game_update — pushes Tile_Mined, so it must precede process_events.
update_mining :: proc(gs: ^Game_State) {
    m := &gs.mining
    if !m.active { return }
    m.elapsed += gs.delta_time
    if m.elapsed < m.travel { return }

    T := m.target
    m^ = {}
    // The tile may have changed mid-flight (mined by a builder, flooded);
    // the impact only mines what is still mineable.
    if .Mineable in terrain_table[get_tile(&gs.world, int(T.x), int(T.y))].flags {
        eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = T})
    }
}
