package game

// ─── The fight goal (card 140) ────────────────────────────────────────────────
//
// {"do":"fight","kind":"Pond_Frog"} or {"do":"fight","slot":12} fights one
// enemy until it is gone: the sword (else the pickaxe's weak blow, card 168)
// when it is in reach, the fire wand at range when there is mana and the line
// to its body is clear (hero_strike, shared with the brain's own fight and the
// fight_back reflex).  With no blow from where it stands the hero walks, as a
// go does but never digging, to the open ground nearest the enemy's row from
// which one lands.  It never shoots into a wall: from a pit or behind a ridge
// it walks out first.  Under HERO_FIGHT_RETREAT_FRAC of its hp it backs off,
// shooting as it goes, and the goal fails once the enemy is HERO_THREAT_FAR
// away.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:slice"
import "base:runtime"

Hero_Fight :: struct {
    kind:       Enemy_Kind,  // asked for by kind: the nearest in sight
    has_kind:   bool,
    target:     int,         // the enemy slot fought
    target_kind: Enemy_Kind, // what was in it, so a slot given up and filled again ends the fight
    retreating: bool,
    wait_t:     f32,         // how long, in all, no ground a blow lands from was found
    skip:       [HERO_FIGHT_SKIP][2]i32,  // stands no walk got to
    n_skip:     int,
}

HERO_FIGHT_WAIT_S :: f32(5)  // a target no blow can reach is waited on this long in all, then given up
HERO_FIGHT_SKIP   :: 8       // stands no walk gets to, passed over before the fight is given up

@(private="file")
hero_fight_parse :: proc(o: json.Object) -> (f: Hero_Fight, problem: string) {
    name, has_name := o["kind"].(json.String)
    slot, has_slot := o["slot"].(json.Float)
    if !has_slot {
        if n, ok := o["slot"].(json.Integer); ok do slot, has_slot = f64(n), true
    }
    switch {
    case has_name == has_slot:
        return f, "fight needs kind or slot, one of them"
    case has_name:
        for k in Enemy_Kind do if fmt.tprint(k) == name do f.kind, f.has_kind = k, true
        if !f.has_kind do return f, fmt.tprintf("fight: kind must name an enemy kind, not %s", name)
    case:
        if slot < 0 || slot >= MAX_ENEMIES || slot != math.floor(slot) do return f, fmt.tprintf("fight: slot takes 0 to %d", MAX_ENEMIES - 1)
        f.target = int(slot)
    }
    return
}

hero_fight_check :: proc(gs: ^Game_State, o: json.Object) -> string {
    _, problem := hero_fight_parse(o)
    return problem
}

// The enemy is found as the goal comes up: by kind, the nearest in sight.
hero_fight_start :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    value, _ := json.parse_string(string(g.line[:g.len]), parse_integers = true, allocator = context.temp_allocator)
    o, _ := value.(json.Object)
    g.fight, _ = hero_fight_parse(o)
    g.no_dig = true
    f := &g.fight
    p := &gs.player
    if hero_melee_slot(gs) < 0 && hero_held_or_first(gs, is_fire_wand) < 0 {
        agent_text_set(&g.reason, "no_item: no sword, pickaxe or fire wand in the bag")
        return false
    }
    if f.has_kind {
        best := max(f32)
        hc := p.pos + [2]f32{PLAYER_W, PLAYER_H} * 0.5
        for i in 0 ..< MAX_ENEMIES {
            if !gs.enemies.active[i] || gs.enemies.data[i].kind != f.kind do continue
            e := &gs.enemies.data[i]
            d := e.pos + enemy_body_size(e.kind) * 0.5 - hc
            if abs(d.x) > f32(AGENT_VIEW_W) * 0.5 || abs(d.y) > f32(AGENT_VIEW_H) * 0.5 do continue
            if n := d.x * d.x + d.y * d.y; n < best do best, f.target = n, i
        }
        if best == max(f32) {
            agent_text_set(&g.reason, fmt.tprintf("no_target: no %v in sight", f.kind))
            return false
        }
    } else if !gs.enemies.active[f.target] {
        agent_text_set(&g.reason, fmt.tprintf("no_target: slot %d holds no enemy", f.target))
        return false
    }
    f.target_kind = gs.enemies.data[f.target].kind
    g.to, g.best = hero_feet(p), max(i32)
    return true
}

hero_fight_goal_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    f := &g.fight
    b := &gs.hero
    p := &gs.player
    if !gs.enemies.active[f.target] || gs.enemies.data[f.target].kind != f.target_kind do return true  // dead, or gone
    e := &gs.enemies.data[f.target]
    d := e.pos + enemy_body_size(e.kind) * 0.5 - (p.pos + [2]f32{PLAYER_W, PLAYER_H} * 0.5)
    dist := math.sqrt(d.x * d.x + d.y * d.y)

    if !f.retreating && f32(p.hp) < HERO_FIGHT_RETREAT_FRAC * f32(p.hp_max) do f.retreating = true
    if f.retreating {
        if dist >= HERO_THREAT_FAR {
            g.status = .Failed
            agent_text_set(&g.reason, fmt.tprintf("low_hp: backed off from the %v with %d hp", e.kind, p.hp))
            return false
        }
        // Not to a safe spot near it: all the way out of HERO_THREAT_FAR.
        th := Hero_Threat{slot = f.target, kind = e.kind, dist = dist, dx = d.x, damage = hero_enemy_damage(gs, e.kind)}
        hero_get_clear(gs, b, &th, clear = HERO_THREAT_FAR)
        hero_strike(gs, b, f.target, sword_ok = false)
        return false
    }

    if hero_strike(gs, b, f.target) {
        if is_fire_wand(held_item(p)) && dist < HERO_KITE_TILES {
            th := Hero_Threat{slot = f.target, kind = e.kind, dist = dist, dx = d.x, damage = hero_enemy_damage(gs, e.kind)}
            hero_get_clear(gs, b, &th)
        }
        return false
    }

    // No blow from here: to open ground one lands from, kept while it still does.
    if sw, wa := hero_blow_from(gs, g.to, hero_fight_centre(g.to), f.target); !(sw || wa) {
        s, ok := hero_fight_stand(gs, f)
        if !ok {
            // Out of mana with only the wand: keep away and let it come back.
            if hero_held_or_first(gs, is_melee_weapon) < 0 && p.mana < FIRE_ORB_MANA {
                th := Hero_Threat{slot = f.target, kind = e.kind, dist = dist, dx = d.x, damage = hero_enemy_damage(gs, e.kind)}
                if dist < HERO_KITE_TILES do hero_get_clear(gs, b, &th)
                return false
            }
            // A target that moves may come out where a blow lands: wait a while.
            f.wait_t += gs.delta_time
            if f.wait_t < HERO_FIGHT_WAIT_S do return false
            g.status = .Failed
            agent_text_set(&g.reason, fmt.tprintf("unreachable: no open ground a blow at the %v lands from", e.kind))
            return false
        }
        g.to, g.best, g.stuck_t, g.replanned, g.left = s, max(i32), 0, false, 0
    }
    if hero_go_tick(gs, g) do return false  // there: the next tick strikes
    if g.status != .Failed do return false
    if f.n_skip < HERO_FIGHT_SKIP {
        // No walk there: another stand, from here.
        f.skip[f.n_skip] = g.to
        f.n_skip += 1
        g.status, g.to = .Running, hero_feet(p)
        return false
    }
    agent_text_set(&g.reason, fmt.tprintf("unreachable: %s", string(g.reason.buf[:g.reason.len])))
    return false
}

// The stand tile a blow at the target lands from that is nearest its row,
// then nearest the hero, and that no walk has failed to get to.
hero_fight_stand :: proc(gs: ^Game_State, f: ^Hero_Fight) -> (s: [2]i32, ok: bool) {
    i := f.target
    e := &gs.enemies.data[i]
    et := builder_tile(e)
    row := i32(e.pos.y + enemy_body_size(e.kind).y - 0.001)
    feet := hero_feet(&gs.player)
    r := i32(HERO_WAND_RANGE)
    best := max(i32)
    for y in et.y - r ..= et.y + r {
        for x in et.x - r ..= et.x + r {
            c := [2]i32{x, y}
            if !in_bounds(int(x), int(y)) || !hero_stand(&gs.world, c) do continue
            if slice.contains(f.skip[:f.n_skip], c) do continue
            if sw, wa := hero_blow_from(gs, c, hero_fight_centre(c), i); !(sw || wa) do continue
            if d := 4 * abs(y - row) + abs(x - feet.x) + abs(y - feet.y); d < best do best, s, ok = d, c, true
        }
    }
    return
}

// Where the hero's centre is, its feet on tile s.
hero_fight_centre :: proc(s: [2]i32) -> [2]f32 {
    return {f32(s.x) + 0.5, f32(s.y) + 1 - PLAYER_H * 0.5}
}
