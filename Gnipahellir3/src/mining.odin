package game

import "core:fmt"

// ─── Mining: pick and wand ────────────────────────────────────────────────────
//
//  Two-stage tool progression (G2's feel, ported):
//    - Equipped pickaxe: free, adjacent tiles only (PICK_RANGE around the
//      body), PICK_HITS chips per tile — the cursor picks which one, nearest
//      to the pointer wins (pick_targets), sparks on every hit. With
//      NO equipped pickaxe you can still knock down trees bare-handed (Wood) at
//      BARE_HAND_MULT× the hits — no other tile yields to fists.
//    - Mine wands: crafted tiers reach 3 / 4 / 8 / 12 tiles and drink mana per
//      shot.  A shot streams sparks to the tile and mines on impact
//      (WAND_TRAVEL_TIME later) — the mining lands where the magic lands.
//  The pickaxe has its own Tool slot; wands and swords share Weapon. A valid
//  wand target takes priority, while an equipped pick remains the close-range
//  fallback when the wand cannot fire in the pointed direction.

PICK_RANGE :: i32(1)
PICK_HITS :: 3
PICK_SWING_TIME :: f32(0.28)
BARE_HAND_MULT :: 3 // no pickaxe: you can still knock down trees, 3× the hits

WAND_MANA_COST :: f32(5) // pool 100, regen 5/s: ~20-shot burst, then throttled
WAND_COOLDOWN :: f32(0.25)
WAND_TRAVEL_TIME :: f32(0.18) // G2's spark travel

// F1 cheat (debug builds): the ultimate mining wand — huge reach, free,
// and the impact detonates a 3×3.
ULTRA_WAND_RANGE :: i32(13)

@(rodata)
wand_mine_range := #partial [Item]i32 {
	.Mine_Wand        = 3,
	.Mine_Wand_Silver = 4,
	.Mine_Wand_Gold   = 8,
	.Mine_Wand_Runic  = 12,
}

// Silver is the first meaningful wand upgrade: alongside the extra reach it
// is more mana-efficient, so sustained mining does not empty the bar almost
// immediately. Other tiers retain their existing cost until separately tuned.
@(rodata)
wand_mana_cost := #partial [Item]f32 {
	.Mine_Wand        = WAND_MANA_COST,
	.Mine_Wand_Silver = 3,
	.Mine_Wand_Gold   = WAND_MANA_COST,
	.Mine_Wand_Runic  = WAND_MANA_COST,
}

// A mining wand (any tier) vs. a sword or ordinary item.
is_wand :: proc(it: Item) -> bool {
	return wand_mine_range[it] > 0
}

// Resolve the wand currently in hand and whether it can strike T. Shared by
// input and the hover effect so the visual promise exactly matches the shot:
// range, mineability and structure protection all come from one check.
wand_target :: proc(gs: ^Game_State, T: [2]i32) -> (wand: Item, cost: f32, blast, ok: bool) {
	wand = gs.player.equipment[.Weapon]
	wrange := wand_mine_range[wand]
	cost = wand_mana_cost[wand]
	when GAME_DEBUG {
		if gs.debug.ultra_wand {
			wand = .Mine_Wand_Gold
			wrange = ULTRA_WAND_RANGE
			cost = 0
			blast = true
		}
	}

	if wrange <= 0 || !in_bounds(int(T.x), int(T.y)) {return}
	t := get_tile(&gs.world, int(T.x), int(T.y))
	if .Mineable not_in terrain_table[t].flags || is_structure_tile[t] {return}
	if chebyshev(T, player_tile(&gs.player)) > wrange {return}
	ok = true
	return
}

// The tiles the pick can reach: the ring within PICK_RANGE of the BODY (which
// is up to three rows tall), not of the player's center tile.  Shared by the
// aim below and the crack overlay, so the marks can never appear on a tile the
// pick can't work — or, as they did, refuse to appear on one it can.
in_pick_reach :: proc(p: ^Player, tile: [2]i32) -> bool {
	col := i32(p.pos.x + PLAYER_W * 0.5)
	top := i32(p.pos.y + 0.1)
	bot := i32(p.pos.y + PLAYER_H - 0.1)
	return abs(tile.x - col) <= PICK_RANGE && tile.y >= top - PICK_RANGE && tile.y <= bot + PICK_RANGE
}

// The CURSOR chooses the block: of every tile the pick can reach, the swing
// works the ONE whose center is nearest the pointer.  Point at a block and you
// get that block — and if that block can't be mined you get nothing, rather
// than a neighbour you didn't point at.  Precision over convenience: the cost
// is that carving a two-tall tunnel wants a small cursor nudge between rows
// instead of one swing taking both.
//
// The one filter: a candidate must be CLOSER TO THE CURSOR THAN THE PLAYER IS
// ("the cursor points at or past it").  That's what stops a click at the far
// side of the screen from working the floor behind you — tiles on the cursor's
// side of the body pass, tiles behind it never do — while a distant click
// still swings at the reachable tile in that direction.  A cursor resting on
// the player's own body passes nothing, so it whiffs.
//
// This replaced a direction cone that bucketed the cursor into one of 8 ways
// and worked fixed tiles.  It measured the angle from the player's CENTER,
// which sits in the feet row — so "beside my head" came out at 47°, past the
// cone's 45° edge, and a cursor on the head block mined the block above it
// instead.  The boundary ran straight through the hovered tile, which is why
// aiming felt almost-right rather than wrong.
@(private = "file")
pick_target :: proc(p: ^Player, mouse_world: [2]f32) -> (target: [2]i32, ok: bool) {
	col := i32(p.pos.x + PLAYER_W * 0.5)
	top := i32(p.pos.y + 0.1)
	bot := i32(p.pos.y + PLAYER_H - 0.1)

	mx := mouse_world.x / CELL_SIZE
	my := mouse_world.y / CELL_SIZE

	pdx := mx - (p.pos.x + PLAYER_W * 0.5)
	pdy := my - (p.pos.y + PLAYER_H * 0.5)
	best := pdx * pdx + pdy * pdy // the player's own distance: the filter above

	for y := top - PICK_RANGE; y <= bot + PICK_RANGE; y += 1 {
		for x := col - PICK_RANGE; x <= col + PICK_RANGE; x += 1 {
			if x == col && y >= top && y <= bot {continue} 	// the body's own tiles
			if !in_bounds(int(x), int(y)) {continue}

			dx := f32(x) + 0.5 - mx
			dy := f32(y) + 0.5 - my
			if d2 := dx * dx + dy * dy; d2 < best {
				best = d2
				target = {x, y}
				ok = true
			}
		}
	}
	return
}

// Called from update_player while the mine button is held.
player_mine :: proc(gs: ^Game_State, dt: f32) {
	p := &gs.player
	p.mine_timer -= dt
	if !gs.input.mine || p.mine_timer > 0 {return}

	// Wand: an equipped wand mines the tile under the cursor at any range —
	// adjacent included — for mana.  Precise cursor aim (and reach) is what the
	// weapon slot buys over the pick.
	T := gs.input.mouse_tile
	_, cost, blast, wand_ok := wand_target(gs, T)
	if wand_ok {
		if p.mana < cost {
			p.mine_timer = 0.6 // rate-limits the reminder while held
			notify(gs, "Not enough mana!")
			log_mouse(gs, "NOMANA", T, "not enough mana")
			return
		}
		p.mana -= cost
		p.mine_timer = WAND_COOLDOWN
		gs.mining = {
			active = true,
			blast  = blast,
			target = T,
			travel = WAND_TRAVEL_TIME,
		}
		spawn_wand_stream(gs, T)
		log_mouse(gs, "WAND", T, blast ? "shot fired (blast)" : "shot fired")
		eq_push(
			&gs.events,
			Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Wand_Fire)}},
		)
		return
	}

	// Pick / bare hands: chip the reachable tile nearest the cursor that can be
	// worked. An equipped pickaxe works any mineable tile in PICK_HITS;
	// bare-handed you can still knock down TREES (Wood), but it takes
	// BARE_HAND_MULT× the hits — nothing else yields to fists.
	has_pick := p.equipment[.Tool] == .Pickaxe
	C, have_target := pick_target(p, gs.input.mouse_world)
	if !have_target {return} 	// cursor on the player's own body: no swing to make

	cx := i32(p.pos.x + PLAYER_W * 0.5)
	if C.x != cx {p.facing = 1 if C.x > cx else -1}
	p.mine_timer = PICK_SWING_TIME

	tile := get_tile(&gs.world, int(C.x), int(C.y))
	workable := .Mineable in terrain_table[tile].flags &&
		!is_structure_tile[tile] && // equipment needs Shift+hold reclaim
		(has_pick || tile == .Wood) // fists fell trees only
	if !workable {
		// Still swing, so every click gives feedback — but nothing else is
		// mined in its place: the cursor asked for THIS block.
		log_mouse(gs, "WHIFF", C, has_pick ? terrain_table[tile].name : "no pickaxe")
		return
	}

	if p.chip_tile != C {
		p.chip_tile = C
		p.chip_hits = 0
	}
	p.chip_hits += 1
	spawn_chip_sparks(gs, C)
	hits_needed := has_pick ? PICK_HITS : PICK_HITS * BARE_HAND_MULT
	when GAME_DEBUG {
		note_buf: [64]u8
		note := fmt.bprintf(
			note_buf[:],
			"%s %d/%d",
			int(p.chip_hits) >= hits_needed ? "MINED" : "chip",
			p.chip_hits,
			hits_needed,
		)
		log_mouse(gs, has_pick ? "PICK" : "HAND", C, note)
	}
	if int(p.chip_hits) >= hits_needed {
		p.chip_hits = 0
		eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = C})
	} else {
		eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Mine)}})
	}
}

// Step 5 in game_update — pushes Tile_Mined, so it must precede process_events.
update_mining :: proc(gs: ^Game_State) {
	m := &gs.mining
	if !m.active {return}
	m.elapsed += gs.delta_time
	if m.elapsed < m.travel {return}

	T := m.target
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
				if !in_bounds(x, y) {continue}
				if .Mineable in terrain_table[get_tile(&gs.world, x, y)].flags {
					eq_push(
						&gs.events,
						Event{type = .Tile_Mined, source = PLAYER_ID, tile = {T.x + dx, T.y + dy}},
					)
				}
			}
		}
		return
	}

	// The tile may have changed mid-flight (mined by a builder, flooded);
	// the impact only mines what is still mineable.
	still_mineable := .Mineable in terrain_table[get_tile(&gs.world, int(T.x), int(T.y))].flags
	// The cursor columns are where the mouse is NOW, not where it fired — the
	// shot was logged at that moment; this row is about the tile it landed on.
	log_mouse(gs, "IMPACT", T, still_mineable ? "MINED" : "gone before impact")
	if still_mineable {
		eq_push(&gs.events, Event{type = .Tile_Mined, source = PLAYER_ID, tile = T})
	}
}
