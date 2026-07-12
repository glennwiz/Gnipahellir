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

// F1 cheat (debug builds): the ultimate mining wand — huge reach, free,
// and the impact detonates a 3×3.
ULTRA_WAND_RANGE :: i32(13)

@(rodata)
wand_mine_range := #partial [Item]i32{
    .Mine_Wand        = 2,
    .Mine_Wand_Silver = 4,
    .Mine_Wand_Gold   = 8,
    .Mine_Wand_Runic  = 12,
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

// The pick doesn't aim at the cursor — the cursor's rough DIRECTION from the
// player picks one of 8 ways, and the pick works the adjacent tile(s) that
// way.  Horizontal swings offer both head- and feet-height tiles (the body
// is 2 tiles tall: a walkable tunnel needs both), top first.  The bands are
// asymmetric — the horizontal band spans a full 45° up/down because "beside
// my head" reads as forward, not up.
@(private = "file")
pick_targets :: proc(p: ^Player, mouse_world: [2]f32, out: ^[2][2]i32) -> int {
    col := i32(p.pos.x + PLAYER_W*0.5)
    top := i32(p.pos.y + 0.1)
    bot := i32(p.pos.y + PLAYER_H - 0.1)

    dx := mouse_world.x/CELL_SIZE - (p.pos.x + PLAYER_W*0.5)
    dy := mouse_world.y/CELL_SIZE - (p.pos.y + PLAYER_H*0.5)
    adx := abs(dx)
    ady := abs(dy)

    dir: [2]i32
    if adx < 0.05 && ady < 0.05 {
        dir = {i32(p.facing), 0}   // cursor on the body: swing the way we face
    } else {
        if adx >= 0.414*ady { dir.x = 1 if dx >= 0 else -1 }   // outside the pure-vertical cone
        if ady >= adx       { dir.y = 1 if dy >= 0 else -1 }   // steeper than 45°
    }

    switch {
    case dir.y < 0:
        out[0] = {col + dir.x, top - 1}
        return 1
    case dir.y > 0:
        out[0] = {col + dir.x, bot + 1}
        return 1
    case:
        out[0] = {col + dir.x, top}
        out[1] = {col + dir.x, bot}
        return 2
    }
}

// Called from update_player while the mine button is held.
player_mine :: proc(gs: ^Game_State, dt: f32) {
    p := &gs.player
    p.mine_timer -= dt
    if !gs.input.mine || p.mine_timer > 0 { return }

    // Wand: pointing at a mineable tile beyond arm's reach fires the best
    // wand carried — precise cursor aim is what the upgrade buys.
    T := gs.input.mouse_tile
    d := chebyshev(T, player_tile(p))
    if d > PICK_RANGE && in_bounds(int(T.x), int(T.y)) &&
       .Mineable in terrain_table[get_tile(&gs.world, int(T.x), int(T.y))].flags {
        wand, wrange := best_wand(&p.inventory)
        cost  := WAND_MANA_COST
        blast := false
        when GAME_DEBUG {
            if gs.debug.ultra_wand {
                wand   = .Mine_Wand_Gold   // cheat needs no wand in the bag
                wrange = ULTRA_WAND_RANGE
                cost   = 0
                blast  = true
            }
        }
        if wand != .None && d <= wrange {
            if p.mana < cost {
                p.mine_timer = 0.6   // rate-limits the reminder while held
                notify(gs, "Not enough mana!")
                return
            }
            p.mana      -= cost
            p.mine_timer = WAND_COOLDOWN
            gs.mining = {active = true, blast = blast, target = T, travel = WAND_TRAVEL_TIME}
            spawn_wand_stream(gs, T)
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Wand_Fire)}})
            return
        }
    }

    // Pick: no aiming, just a rough direction — chip the first workable tile.
    if inventory_count(&p.inventory, .Pickaxe) == 0 { return }
    targets: [2][2]i32
    n := pick_targets(p, gs.input.mouse_world, &targets)
    for i in 0 ..< n {
        C := targets[i]
        if !in_bounds(int(C.x), int(C.y)) { continue }
        if .Mineable not_in terrain_table[get_tile(&gs.world, int(C.x), int(C.y))].flags { continue }

        if C.x != i32(p.pos.x + PLAYER_W*0.5) {
            p.facing = 1 if C.x > i32(p.pos.x + PLAYER_W*0.5) else -1
        }
        p.mine_timer = PICK_SWING_TIME
        if p.chip_tile != C {
            p.chip_tile = C
            p.chip_hits = 0
        }
        p.chip_hits += 1
        spawn_chip_sparks(gs, C)
        if int(p.chip_hits) >= PICK_HITS {
            p.chip_hits = 0
            eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = C})
        } else {
            eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Mine)}})
        }
        return
    }

    // Whiffed — nothing mineable in reach. Still swing (and turn toward the
    // cursor) so every click gives feedback, not just successful hits.
    p.mine_timer = PICK_SWING_TIME
    if n > 0 {
        cx := i32(p.pos.x + PLAYER_W*0.5)
        if targets[0].x != cx { p.facing = 1 if targets[0].x > cx else -1 }
    }
}

// Step 5 in game_update — pushes Tile_Mined, so it must precede process_events.
update_mining :: proc(gs: ^Game_State) {
    m := &gs.mining
    if !m.active { return }
    m.elapsed += gs.delta_time
    if m.elapsed < m.travel { return }

    T     := m.target
    blast := m.blast
    m^ = {}

    // Ultra-wand impact: a small explosion takes the whole 3×3.
    if blast {
        eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Blast)}})
        spawn_blast_sparks(gs, T)
        for dy in i32(-1) ..= 1 {
            for dx in i32(-1) ..= 1 {
                x := int(T.x + dx)
                y := int(T.y + dy)
                if !in_bounds(x, y) { continue }
                if .Mineable in terrain_table[get_tile(&gs.world, x, y)].flags {
                    eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = {T.x + dx, T.y + dy}})
                }
            }
        }
        return
    }

    // The tile may have changed mid-flight (mined by a builder, flooded);
    // the impact only mines what is still mineable.
    if .Mineable in terrain_table[get_tile(&gs.world, int(T.x), int(T.y))].flags {
        eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = T})
    }
}
