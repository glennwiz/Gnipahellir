package game

import "core:math"

// ─── Constants ────────────────────────────────────────────────────────────────

BUILDER_W        :: f32(0.8)
BUILDER_H        :: f32(1.0)
BUILDER_SPEED    :: f32(4.0)
BUILDER_JUMP     :: f32(-10.0)  // apex ~2.5 tiles — must clear the A*'s 2-up jumps
BUILDER_GRAVITY  :: f32(20.0)
BUILDER_MAX_FALL :: f32(12.0)

MINE_TIME       :: f32(0.4)   // pause after each mine/place action
MAX_ASTAR_NODES :: 4096       // search budget (nodes pushed)
ASTAR_H_WEIGHT  :: f32(2.0)   // greedy-ish A*: with mining the whole rock mass is
                              // searchable and an admissible h floods the budget

BUILDER_REACH   :: i32(3)     // chebyshev tile distance for mining/placing
REPLAN_MIN      :: f32(0.5)   // min seconds between path computations
STUCK_TIME      :: f32(3.0)   // no path progress for this long => strike
MAX_STRIKES     :: 3          // strikes before the current objective is dropped
AVOID_RADIUS    :: i32(4)     // given-up targets blacklist their whole cluster —
                              // unreachable ore (e.g. a ceiling vein over an open
                              // basin) usually comes in groups
JOB_COOLDOWN    :: f32(2.0)   // pause between objectives
SITE_SPACING    :: 20         // min x-distance between two builders' dens

// Path move costs.  Walking is cheapest so builders prefer open routes and
// only tunnel or bridge when it genuinely pays off.
COST_WALK  :: f32(1)
COST_PLACE :: f32(4)   // bridge: place a block underfoot
COST_MINE  :: f32(6)   // tunnel: mine a solid tile

// Bridge blocks are not conjured: every tile a builder mines credits its
// pocket, and every bridge block spends from it.
POCKET_MAX :: u8(8)

// Hunting.
HUNT_RADIUS    :: f32(12)   // spot the player within this distance + line of sight
HUNT_LOSE_DIST :: f32(20)   // give up the chase beyond this distance
LOS_MEMORY     :: f32(3.0)  // keep hunting this long after losing sight
ATTACK_TIME    :: f32(0.8)  // seconds between bites
ATTACK_DAMAGE  :: 1

// Den shell.  Tuned 3 -> 2 after playtest round 1: with 3 layers a dome
// took ~an hour of builder time, so the floor stockpile (the raid payout)
// never appeared in a real session.
DEN_SHELL_LAYERS :: 2       // mineral layers placed around the den

DEN_UNSET :: [2]i32{0, 0}   // anchor sentinel: no den site chosen yet

// ─── Build Templates ──────────────────────────────────────────────────────────
//
//  Anchor = a standable floor tile; offsets are relative to it, -y is up.
//  Steps are ordered so each is placeable from the ground: carves (.Void)
//  first, then solids bottom-up.  Everything stays within BUILDER_REACH of
//  the anchor area, so a whole structure is buildable without re-pathing.

Template_Tile :: struct {
    off:  [2]i32,
    tile: Tile_Type,
}

Build_Template :: struct {
    name:  string,
    tiles: []Template_Tile,
}

@(rodata)
CAIRN_TILES := [?]Template_Tile{
    {{-1, 0}, .Stone}, {{0, 0}, .Stone}, {{1, 0}, .Stone},
    {{0, -1}, .Stone},
}

@(rodata)
PILLAR_TILES := [?]Template_Tile{
    {{0, 0}, .Stone}, {{0, -1}, .Stone}, {{0, -2}, .Stone}, {{0, -3}, .Stone},
    {{-1, -3}, .Stone}, {{1, -3}, .Stone},
}

@(rodata)
SHELTER_TILES := [?]Template_Tile{
    // carve the interior + doorway
    {{-1, 0}, .Void}, {{0, 0}, .Void}, {{1, 0}, .Void}, {{2, 0}, .Void},
    {{-1, -1}, .Void}, {{0, -1}, .Void}, {{1, -1}, .Void},
    {{-1, -2}, .Void}, {{0, -2}, .Void}, {{1, -2}, .Void},
    // walls (2-high door gap stays open at {2, 0} and {2, -1})
    {{-2, 0}, .Wood},
    {{-2, -1}, .Wood},
    {{-2, -2}, .Wood}, {{2, -2}, .Wood},
    // roof
    {{-2, -3}, .Wood}, {{-1, -3}, .Wood}, {{0, -3}, .Wood}, {{1, -3}, .Wood}, {{2, -3}, .Wood},
}

// Static table; cannot be @(rodata) because the slice initializers are not
// compile-time constants.  The arrays it points into ARE rodata — treat this
// as read-only.
build_templates := [Build_Kind]Build_Template{
    .Cairn   = {"cairn",   CAIRN_TILES[:]},
    .Pillar  = {"pillar",  PILLAR_TILES[:]},
    .Shelter = {"shelter", SHELTER_TILES[:]},
}

// ─── Enemy Pool ───────────────────────────────────────────────────────────────

// Entity_ID convention: PLAYER_ID is 0; enemy slot i maps to Entity_ID(i + 1).
enemy_entity_id :: #force_inline proc(i: int) -> Entity_ID {
    return Entity_ID(i + 1)
}

entity_id_to_enemy_index :: #force_inline proc(id: Entity_ID) -> int {
    return int(id) - 1
}

enemy_alloc :: proc(es: ^Enemy_Store) -> (id: int, ok: bool) {
    for i in 0 ..< MAX_ENEMIES {
        if !es.active[i] {
            es.active[i] = true
            es.data[i]   = {}
            es.count    += 1
            return i, true
        }
    }
    return 0, false
}

enemy_free :: proc(es: ^Enemy_Store, id: int) {
    if id < 0 || id >= MAX_ENEMIES { return }
    es.active[id] = false
    es.count      = max(0, es.count - 1)
}

// ─── Standable / Snap ─────────────────────────────────────────────────────────

is_standable :: proc(w: ^World_Grid, x, y: int) -> bool {
    return in_bounds(x, y) && in_bounds(x, y+1) &&
           !is_solid(w, x, y) && is_solid(w, x, y+1)
}

is_builder_mineable :: proc(w: ^World_Grid, x, y: int) -> bool {
    if !in_bounds(x, y) { return false }
    return .Mineable in terrain_table[w.terrain[grid_idx(x, y)]].flags
}

is_mineral :: proc(t: Tile_Type) -> bool {
    #partial switch t {
    case .Iron_Ore, .Silver_Ore, .Gold_Ore, .Gold_Rare_Ore:
        return true
    }
    return false
}

snap_to_standable :: proc(w: ^World_Grid, x, y: int) -> (rx, ry: int) {
    for dy in 0 ..= 5 { if is_standable(w, x, y+dy) { return x, y+dy } }
    for dy in 1 ..= 5 { if is_standable(w, x, y-dy) { return x, y-dy } }
    return x, y
}

chebyshev :: proc(a, b: [2]i32) -> i32 {
    return max(abs(a.x - b.x), abs(a.y - b.y))
}

// Body size by kind — Garm is bigger than a builder.
enemy_body_size :: proc(kind: Enemy_Kind) -> [2]f32 {
    #partial switch kind {
    case .Garm: return {GARM_W, GARM_H}
    }
    return {BUILDER_W, BUILDER_H}
}

// Ground speed by kind — the boss must outpace a walking builder.
enemy_speed :: proc(kind: Enemy_Kind) -> f32 {
    #partial switch kind {
    case .Garm: return GARM_SPEED
    }
    return BUILDER_SPEED
}

// Center tile for any enemy kind (name predates Garm; used everywhere).
builder_tile :: proc(e: ^Enemy) -> [2]i32 {
    size := enemy_body_size(e.kind)
    return {i32(e.pos.x + size.x*0.5), i32(e.pos.y + size.y*0.5)}
}

// T lies on a den's structure geometry: template solids or shell ring cells
// (the door corridor is open and never part of the structure).
den_structure_slot :: proc(b: ^Builder_State, T: [2]i32) -> bool {
    rel := T - b.anchor
    if rel.x < i32(-2 - DEN_SHELL_LAYERS) || rel.x > i32(2 + DEN_SHELL_LAYERS) ||
       rel.y < i32(-3 - DEN_SHELL_LAYERS) || rel.y > 1 {
        return false
    }
    // Den template solids.
    for t in build_templates[b.build].tiles {
        if t.tile == .Void || t.tile == .Air { continue }
        if rel == t.off { return true }
    }
    // Shell ring cells (door corridor stays open).
    for k in 1 ..= DEN_SHELL_LAYERS {
        x0 := i32(-2 - k)
        x1 := i32( 2 + k)
        y0 := i32(-3 - k)
        y1 := i32( 1)
        if rel.x < x0 || rel.x > x1 || rel.y < y0 || rel.y > y1 { continue }
        if rel.x != x0 && rel.x != x1 && rel.y != y0 && rel.y != y1 { continue }
        if rel.x == x1 && (rel.y == 0 || rel.y == -1) { continue }
        return true
    }
    return false
}

// Builder index owning den structure at T, or -1.  Geometry only — natural
// rock sitting in an unfilled shell slot still counts as the den's wall zone.
den_owner_index :: proc(gs: ^Game_State, T: [2]i32) -> int {
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind != .Builder || !o.builder.den_built { continue }
        if den_structure_slot(&o.builder, T) { return i }
    }
    return -1
}

// Den tiles and shell slots must never be mined while pathing — otherwise
// builders tunnel through their own (or each other's) den walls and then loop
// forever repairing them.  Only the structure itself is protected; natural
// rock around a den stays diggable or nearby targets become unreachable.
den_protected :: proc(gs: ^Game_State, x, y: int) -> bool {
    if !in_bounds(x, y) { return false }

    // Only placed materials (den wood, shell minerals) are protected.  Natural
    // rock stays diggable even inside the den footprint — protecting it walls
    // builders out of their own home (e.g. when returning from below).
    t := gs.world.terrain[grid_idx(x, y)]
    if t != .Wood && !is_mineral(t) { return false }

    T := [2]i32{i32(x), i32(y)}
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind != .Builder || !o.builder.den_built { continue }
        if den_structure_slot(&o.builder, T) { return true }
    }
    return false
}

player_tile :: proc(p: ^Player) -> [2]i32 {
    return {i32(p.pos.x + PLAYER_W*0.5), i32(p.pos.y + PLAYER_H*0.5)}
}

// ─── Dig-Aware A* ─────────────────────────────────────────────────────────────
//
//  Cost-based platformer pathfinder.  Besides the normal walk/jump/drop moves
//  it plans straight through the world by paying for modifications:
//    - tunnel into a mineable wall            (COST_MINE)
//    - dig through a mineable floor           (COST_MINE)
//    - mine out a diagonal step upward        (COST_MINE + 1)
//    - bridge a gap by placing a block below  (COST_PLACE)
//  builder_exec_action performs the implied mine/place when each waypoint
//  becomes current, so any in-bounds target surrounded by mineable rock is
//  reachable and the search only fails on budget exhaustion.
//
//  Bridge blocks come from the builder's pocket: a path may plan at most
//  `bridge_budget` bridge moves, so an empty-handed builder plans tunnels
//  and detours instead of conjuring matter.
//
//  Succeeds when a node within chebyshev `stop_within` of `to` is expanded.
//  If the found path exceeds MAX_NAV_PATH, the prefix nearest the start is
//  kept — the builder walks it and replans from there.

astar_dig :: proc(gs: ^Game_State, from, to: [2]i32, stop_within: i32, bridge_budget: int, out: ^Nav_Path) -> bool {
    w := &gs.world
    out^ = {}

    fx, fy := snap_to_standable(w, int(from.x), int(from.y))
    sf := [2]i32{i32(fx), i32(fy)}
    if chebyshev(sf, to) <= stop_within { return true }

    A_Node :: struct {
        pos:     [2]i32,
        g:       f32,
        parent:  i16,   // index into nodes[], -1 = start
        bridges: u8,    // bridge moves on the path to this node
    }

    A_Trans :: struct {
        pos:    [2]i32,
        cost:   f32,
        bridge: bool,
    }

    nodes:   [MAX_ASTAR_NODES]A_Node
    n_count: int

    // Best known g-cost per grid cell.  f32 max = unvisited.
    g_cost: [GRID_W * GRID_H]f32
    for i in 0 ..< GRID_W * GRID_H { g_cost[i] = max(f32) }

    closed: [GRID_W * GRID_H]bool

    // Open set: node indices.  Linear scan for min-f (budget is small enough).
    open:      [MAX_ASTAR_NODES]i16
    open_size: int

    // Best-effort fallback: expanded node closest to the goal.  If the search
    // exhausts its budget, path there instead of failing — the builder makes
    // progress and replans from the new position.
    best_node := i16(0)
    best_h    := max(f32)

    heuristic :: proc(a, b: [2]i32) -> f32 {
        dx := f32(a.x - b.x)
        dy := f32(a.y - b.y)
        return math.sqrt(dx*dx + dy*dy)
    }

    push_trans :: proc(trans: ^[24]A_Trans, n: ^int, x, y: i32, cost: f32, bridge := false) {
        if n^ < len(trans) { trans[n^] = {{x, y}, cost, bridge}; n^ += 1 }
    }

    // Seed the open set with the start node.
    nodes[0]  = {pos = sf, g = 0, parent = -1}
    g_cost[grid_idx(fx, fy)] = 0
    open[0]   = 0
    n_count   = 1
    open_size = 1
    found     := i16(-1)

    trans: [24]A_Trans

    outer: for open_size > 0 {
        // Pick the open node with the lowest f = g + h.
        best_f  := max(f32)
        best_oi := 0
        for oi in 0 ..< open_size {
            ni := int(open[oi])
            f  := nodes[ni].g + ASTAR_H_WEIGHT * heuristic(nodes[ni].pos, to)
            if f < best_f { best_f = f; best_oi = oi }
        }

        // Pop it (swap with last).
        cur_idx := int(open[best_oi])
        open[best_oi] = open[open_size - 1]
        open_size -= 1

        cur := nodes[cur_idx]
        vi  := grid_idx(int(cur.pos.x), int(cur.pos.y))

        if closed[vi] { continue }   // already expanded via a shorter path
        closed[vi] = true

        if chebyshev(cur.pos, to) <= stop_within {
            found = i16(cur_idx)
            break outer
        }

        cur_h := heuristic(cur.pos, to)
        if cur_h < best_h { best_h = cur_h; best_node = i16(cur_idx) }

        // ── Generate transitions ──────────────────────────────────────────
        x  := int(cur.pos.x)
        y  := int(cur.pos.y)
        nt := 0

        // Dig through the floor (only when landing one tile down).
        if is_builder_mineable(w, x, y+1) && is_solid(w, x, y+2) && !den_protected(gs, x, y+1) {
            push_trans(&trans, &nt, i32(x), i32(y+1), COST_MINE)
        }

        HDIR :: [2]int{-1, 1}
        for d in HDIR {
            nx := x + d

            // Walk flat.
            if is_standable(w, nx, y) {
                push_trans(&trans, &nt, i32(nx), i32(y), COST_WALK)
            }

            // Step up 1.  Head clearance above the landing is required — a
            // 1-high notch is standable but the jump arc can't thread into it.
            if is_solid(w, nx, y) && !is_solid(w, x, y-1) && is_standable(w, nx, y-1) &&
               !is_solid(w, nx, y-2) {
                push_trans(&trans, &nt, i32(nx), i32(y-1), COST_WALK)
            }

            // Drop off edge.
            if !is_solid(w, nx, y) && !is_solid(w, nx, y+1) {
                for fall_y := y + 1; fall_y < GRID_H - 1; fall_y += 1 {
                    if is_standable(w, nx, fall_y) {
                        push_trans(&trans, &nt, i32(nx), i32(fall_y), COST_WALK)
                        break
                    }
                    if is_solid(w, nx, fall_y) { break }
                }
            }

            // Jump forward + up 1 or 2.  The arc must clear the rows it rises
            // through in every intermediate column — checking only the takeoff
            // row lets it plan jumps straight into overhangs (e.g. the wall
            // above a 1-high doorway).
            if !is_solid(w, x, y-1) {
                for jdx in 1 ..= 2 {
                    jx := x + d*jdx
                    arc_clear := true
                    for ix := x + d; ix != jx; ix += d {
                        if is_solid(w, ix, y) || is_solid(w, ix, y-1) { arc_clear = false; break }
                    }
                    if arc_clear && is_standable(w, jx, y-1) && !is_solid(w, jx, y-2) {
                        push_trans(&trans, &nt, i32(jx), i32(y-1), COST_WALK)
                    }
                }
                if !is_solid(w, x, y-2) {
                    for jdx in 1 ..= 2 {
                        jx := x + d*jdx
                        arc_clear := true
                        for ix := x + d; ix != jx; ix += d {
                            if is_solid(w, ix, y-1) || is_solid(w, ix, y-2) { arc_clear = false; break }
                        }
                        if arc_clear && !is_solid(w, jx, y-1) && is_standable(w, jx, y-2) {
                            push_trans(&trans, &nt, i32(jx), i32(y-2), COST_WALK)
                        }
                    }
                }
            }

            // Tunnel into a mineable wall (needs a floor under the mined tile).
            if is_builder_mineable(w, nx, y) && is_solid(w, nx, y+1) && !den_protected(gs, nx, y) {
                push_trans(&trans, &nt, i32(nx), i32(y), COST_MINE)
            }

            // Diagonal step upward, mining whatever blocks the climb: the
            // landing (nx,y-1), our own headroom (x,y-1) and the landing's
            // headroom (nx,y-2) may each be open or mineable.  This is the
            // builders' only way UP through solid rock (zigzag staircases);
            // without it anything above a sheer wall is unreachable — dens
            // included, which starves the whole economy.
            if is_solid(w, nx, y) && in_bounds(nx, y-2) {
                climb_tiles := [3][2]int{{nx, y - 1}, {x, y - 1}, {nx, y - 2}}
                mines     := 0
                climbable := true
                for c in climb_tiles {
                    if !is_solid(w, c.x, c.y) { continue }
                    if is_builder_mineable(w, c.x, c.y) && !den_protected(gs, c.x, c.y) {
                        mines += 1
                    } else {
                        climbable = false
                        break
                    }
                }
                // mines == 0 is the plain step-up move handled above.
                if climbable && mines > 0 {
                    cost := COST_MINE*f32(mines) + 1
                    // Alternating climbs (1-wide shafts) are self-contradicting:
                    // one tile must be both carved (headroom) and left solid
                    // (support).  Prefer straight staircases.
                    if cur.parent >= 0 {
                        pdx := cur.pos.x - nodes[cur.parent].pos.x
                        if pdx != 0 && int(pdx) != d { cost += COST_MINE * 2 }
                    }
                    push_trans(&trans, &nt, i32(nx), i32(y-1), cost)
                }
            }

            // Bridge a gap: place a block at (nx, y+1) and stand on it —
            // only while the path still has pocket blocks to spend.
            if int(cur.bridges) < bridge_budget &&
               !is_solid(w, nx, y) && in_bounds(nx, y+1) && !is_solid(w, nx, y+1) {
                push_trans(&trans, &nt, i32(nx), i32(y), COST_PLACE, bridge = true)
            }
        }

        // ── Enqueue neighbours ────────────────────────────────────────────
        for i in 0 ..< nt {
            np  := trans[i].pos
            nxi := int(np.x)
            nyi := int(np.y)
            if !in_bounds(nxi, nyi) { continue }
            nvi := grid_idx(nxi, nyi)
            if closed[nvi] { continue }

            tentative_g := cur.g + trans[i].cost
            if tentative_g >= g_cost[nvi] { continue }   // not an improvement
            g_cost[nvi] = tentative_g

            if n_count >= MAX_ASTAR_NODES || open_size >= MAX_ASTAR_NODES {
                break outer   // budget exhausted
            }
            bridges := cur.bridges + (u8(1) if trans[i].bridge else u8(0))
            nodes[n_count] = {pos = np, g = tentative_g, parent = i16(cur_idx), bridges = bridges}
            open[open_size] = i16(n_count)
            open_size += 1
            n_count   += 1

            if chebyshev(np, to) <= stop_within {
                found = i16(n_count - 1)
                break outer
            }
        }
    }

    if found < 0 {
        if best_node <= 0 { return false }   // couldn't move toward goal at all
        found = best_node
    }

    // Length of the found chain.
    length := 0
    for idx := int(found); idx >= 0; idx = int(nodes[idx].parent) { length += 1 }

    // Longer than the buffer: drop waypoints from the DESTINATION side so the
    // kept prefix still starts at the builder.
    skip := max(0, length - MAX_NAV_PATH)
    idx  := int(found)
    for _ in 0 ..< skip { idx = int(nodes[idx].parent) }

    tmp:     [MAX_NAV_PATH][2]i32
    tmp_len: int
    for idx >= 0 {
        tmp[tmp_len] = nodes[idx].pos
        tmp_len += 1
        idx = int(nodes[idx].parent)
    }
    out.len    = tmp_len
    out.cursor = 0
    for i in 0 ..< tmp_len {
        out.tiles[i] = tmp[tmp_len - 1 - i]
    }
    return true
}

// ─── Path Following ───────────────────────────────────────────────────────────

enemy_follow_path :: proc(e: ^Enemy, nav: ^Enemy_Nav, w: ^World_Grid) {
    if nav.path.cursor >= nav.path.len {
        e.vel.x = 0
        return
    }

    size := enemy_body_size(e.kind)
    target := nav.path.tiles[nav.path.cursor]
    tx := f32(target.x) + 0.5
    ty := f32(target.y) + 0.5
    cx := e.pos.x + size.x*0.5
    cy := e.pos.y + size.y*0.5
    dx := tx - cx
    dy := ty - cy

    // The FINAL waypoint must be stood on precisely: arrival checks are
    // tile-based, and the loose radius can tick it off while the builder's
    // center is still in the neighboring tile (replan livelock).
    accept := f32(0.85) if nav.path.cursor < nav.path.len - 1 else f32(0.35)
    // Never tick off an elevated waypoint while airborne: a jump arc sweeps
    // through several climb waypoints' accept radii, leaving the cursor on
    // one that is unreachable from the ground (jump-bounce livelock).
    if math.sqrt(dx*dx + dy*dy) < accept && (e.grounded || dy > 0) {
        nav.path.cursor += 1
        return
    }

    // Waypoint below: shrink the deadzone so the builder centers exactly over
    // the drop — with the normal deadzone its body can stay clipped onto the
    // adjacent ledge by a hair and never fall.
    below    := dy > 0.6
    deadzone := f32(0.03) if below else f32(0.15)
    if abs(dx) > deadzone {
        e.facing = 1 if dx >= 0 else -1
        e.vel.x  = f32(e.facing) * enemy_speed(e.kind)
    } else {
        e.vel.x = 0
    }

    // Jump when the waypoint is above, or when walking into a wall.
    if e.grounded {
        waypoint_above := dy < -0.4
        wall_ahead     := is_solid(w, int(e.pos.x + f32(e.facing)*(size.x + 0.1)), int(e.pos.y + size.y - 0.5))
        if waypoint_above || wall_ahead {
            e.vel.y = BUILDER_JUMP
        }
    }
}

// Movement/collision resolution lives in physics.odin (move_body), shared
// with the player.

// ─── Spawn ────────────────────────────────────────────────────────────────────

find_cave_floor :: proc(w: ^World_Grid, hint_x, min_clear: int) -> (tx, ty: int, ok: bool) {
    for r in 0 ..= 40 {
        for s in 0 ..= 1 {
            sign := 1 - 2*s
            cx := clamp(hint_x + r*sign, CAVE_LEFT, CAVE_RIGHT - 1)
            for y in CAVE_TOP ..< CAVE_BOT - 1 {
                if !is_solid(w, cx, y) && is_solid(w, cx, y+1) {
                    clear := 0
                    for cy := y; cy >= CAVE_TOP; cy -= 1 {
                        if is_solid(w, cx, cy) { break }
                        clear += 1
                    }
                    if clear >= min_clear { return cx, y, true }
                }
            }
        }
    }
    return 0, 0, false
}

spawn_builder :: proc(gs: ^Game_State, start_x: int) {
    id, ok := enemy_alloc(&gs.enemies)
    if !ok { return }

    e := &gs.enemies.data[id]
    e.kind   = .Builder
    e.hp     = 6
    e.hp_max = 6

    tx, ty, found := find_cave_floor(&gs.world, start_x, 3)
    if !found {
        enemy_free(&gs.enemies, id)
        return
    }

    e.pos = {f32(tx) + (1 - BUILDER_W)*0.5, f32(ty) - BUILDER_H + 1}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
}

// Enemy slot whose center tile is at or adjacent to T (the entity map is a
// center-tile index, so a fat cursor makes bodies clickable) — melee targeting.
enemy_near_tile :: proc(gs: ^Game_State, T: [2]i32) -> (idx: int, ok: bool) {
    for dy in i32(-1) ..= i32(1) {
        for dx in i32(-1) ..= i32(1) {
            x := int(T.x + dx)
            y := int(T.y + dy)
            if !in_bounds(x, y) { continue }
            id := gs.world.entity_map[grid_idx(x, y)]
            if id == PLAYER_ID || id == INVALID_ENTITY { continue }
            i := entity_id_to_enemy_index(id)
            if i >= 0 && i < MAX_ENEMIES && gs.enemies.active[i] { return i, true }
        }
    }
    return 0, false
}

// Clear the entity-map marker and release the pool slot.
despawn_enemy :: proc(gs: ^Game_State, i: int) {
    if i < 0 || i >= MAX_ENEMIES || !gs.enemies.active[i] { return }
    entity_map_clear(&gs.world, enemy_entity_id(i), builder_tile(&gs.enemies.data[i]))
    enemy_free(&gs.enemies, i)
}

spawn_level_1_enemies :: proc(gs: ^Game_State) {
    spawn_builder(gs, CAVE_LEFT  + 20)
    spawn_builder(gs, CAVE_RIGHT - 20)
}

// ─── Builder Path Actions (mine / place) ──────────────────────────────────────
//
//  Called each frame before path following.  If the current waypoint requires
//  a mine or bridge action, execute it (rate-limited by mine_timer) and return
//  true so the caller suppresses horizontal movement while working.

builder_exec_action :: proc(e: ^Enemy, nav: ^Enemy_Nav, gs: ^Game_State) -> (busy: bool) {
    // Cooling down after a recent action — stand still.
    if nav.mine_timer > 0 {
        e.vel.x = 0
        return true
    }

    if nav.path.cursor >= nav.path.len { return false }

    target := nav.path.tiles[nav.path.cursor]
    tx := int(target.x)
    ty := int(target.y)

    // Climbing waypoint: the up-step needs our own headroom and the
    // landing's headroom open too (see the A* climb move) — carve them.
    // Grounded only: while airborne the builder tile fluctuates and the
    // carves land on the wrong rows.
    bt := builder_tile(e)
    if target.y < bt.y && e.grounded {
        climb := [2][2]i32{{bt.x, bt.y - 1}, {target.x, target.y - 1}}
        for c in climb {
            cx := int(c.x)
            cy := int(c.y)
            if is_solid(&gs.world, cx, cy) && is_builder_mineable(&gs.world, cx, cy) &&
               !den_protected(gs, cx, cy) {
                set_tile(&gs.world, cx, cy, .Void)
                eq_push(&gs.events, Event{type = .Builder_Mined, tile = c})
                log_action(gs, "Builder clears climb tile (%d,%d)", cx, cy)
                e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
                nav.mine_timer = MINE_TIME
                e.vel.x = 0
                return true
            }
        }
    }

    // Mine: waypoint tile is solid and mineable (dens are off-limits).
    if is_builder_mineable(&gs.world, tx, ty) && !den_protected(gs, tx, ty) {
        set_tile(&gs.world, tx, ty, .Void)
        eq_push(&gs.events, Event{type = .Builder_Mined, tile = {i32(tx), i32(ty)}})
        log_action(gs, "Builder mines (%d,%d)", tx, ty)
        e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
        nav.mine_timer = MINE_TIME
        e.vel.x = 0
        return true
    }

    // Bridge: no floor below waypoint — spend a pocket block on it.  An
    // empty pocket (floor mined out from under a planned waypoint) clears
    // the path so the next replan routes around the gap instead.  Only for
    // waypoints at or below our height: a floor under an elevated waypoint
    // doesn't get us up there, and it feeds a place/carve livelock with
    // the climb rule above.
    if target.y >= bt.y && in_bounds(tx, ty+1) && !is_solid(&gs.world, tx, ty+1) {
        if e.builder.pocket == 0 {
            log_action(gs, "Builder out of blocks at (%d,%d) — replans", tx, ty+1)
            nav.path = {}
            e.vel.x  = 0
            return true
        }
        e.builder.pocket -= 1
        set_tile(&gs.world, tx, ty+1, .Stone)
        eq_push(&gs.events, Event{type = .Builder_Placed, tile = {i32(tx), i32(ty+1)}})
        log_action(gs, "Builder places at (%d,%d)", tx, ty+1)
        nav.mine_timer = MINE_TIME
        e.vel.x = 0
        return true
    }

    return false
}

// ─── Shared Helpers ───────────────────────────────────────────────────────────

tile_satisfied :: proc(w: ^World_Grid, T: [2]i32, desired: Tile_Type) -> bool {
    x := int(T.x)
    y := int(T.y)
    if !in_bounds(x, y) { return true }   // out of bounds — nothing to do
    if desired == .Void || desired == .Air {
        return !is_solid(w, x, y)
    }
    return get_tile(w, x, y) == desired
}

builder_overlaps_tile :: proc(e: ^Enemy, x, y: int) -> bool {
    size  := enemy_body_size(e.kind)
    left  := int(e.pos.x)
    right := int(e.pos.x + size.x - 0.01)
    top   := int(e.pos.y)
    bot   := int(e.pos.y + size.y - 0.01)
    return x >= left && x <= right && y >= top && y <= bot
}

builder_pause :: proc(b: ^Builder_State, t: f32, resume: Builder_Goal) {
    b.goal     = .Cooldown
    b.cooldown = t
    b.resume   = resume
}

// Place `t` at T, stepping aside first if the body overlaps the slot.
// Rate-limits via mine_timer.  Returns true once placed.
builder_place_tile :: proc(e: ^Enemy, gs: ^Game_State, T: [2]i32, t: Tile_Type) -> bool {
    x := int(T.x)
    y := int(T.y)
    if builder_overlaps_tile(e, x, y) {
        // Step out of the slot TOWARD the anchor: stepping away can carry
        // the builder out of its arrival radius and oscillate forever
        // (arrive -> step out -> walk back -> arrive).  Flip if that side
        // is walled off.
        dir := f32(1) if f32(e.builder.anchor.x) + 0.5 > e.pos.x + BUILDER_W*0.5 else f32(-1)
        ahead_x := e.pos.x - 0.2 if dir < 0 else e.pos.x + BUILDER_W + 0.2
        if is_solid(&gs.world, int(ahead_x), int(e.pos.y + BUILDER_H*0.5)) {
            dir = -dir
        }
        e.facing = int(dir)
        e.vel.x  = dir * BUILDER_SPEED
        return false
    }
    set_tile(&gs.world, x, y, t)
    eq_push(&gs.events, Event{type = .Builder_Placed, tile = T})
    e.nav.mine_timer = MINE_TIME
    return true
}

// Act on the current den template step: carve wrong solids, place the desired
// tile.  Rate-limited by mine_timer; the step advances via the satisfied-check.
builder_do_step :: proc(e: ^Enemy, id: int, gs: ^Game_State, T: [2]i32, desired: Tile_Type) {
    nav := &e.nav
    if nav.mine_timer > 0 { return }

    x := int(T.x)
    y := int(T.y)
    w := &gs.world

    if is_solid(w, x, y) {
        // Wrong tile in the slot — carve it out first.
        if is_builder_mineable(w, x, y) {
            set_tile(w, x, y, .Void)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = T})
            log_action(gs, "Builder#%d carves (%d,%d)", id, x, y)
            e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
            nav.mine_timer = MINE_TIME
        } else {
            e.builder.step += 1   // unmineable obstruction — skip this step
        }
        e.builder.stuck_timer = 0
        return
    }

    if builder_place_tile(e, gs, T, desired) {
        log_action(gs, "Builder#%d builds %v at (%d,%d)", id, desired, x, y)
        e.builder.stuck_timer = 0
    }
}

// Last-resort rescue: if the body overlaps solid tiles (walled in by another
// builder, or a physics edge case), mine every mineable tile it touches.
builder_dig_free :: proc(e: ^Enemy, id: int, gs: ^Game_State) {
    size := enemy_body_size(e.kind)
    if !body_embedded(&gs.world, e.pos, size) {
        return
    }
    left  := int(e.pos.x)
    right := int(e.pos.x + size.x - BODY_EPS)
    top   := int(e.pos.y)
    bot   := int(e.pos.y + size.y - BODY_EPS)
    for y in top ..= bot {
        for x in left ..= right {
            if is_builder_mineable(&gs.world, x, y) {
                set_tile(&gs.world, x, y, .Void)
                eq_push(&gs.events, Event{type = .Builder_Mined, tile = {i32(x), i32(y)}})
                e.builder.pocket = min(e.builder.pocket + 1, POCKET_MAX)
            }
        }
    }
    log_action(gs, "Builder#%d digs itself free at (%.1f,%.1f)", id, e.pos.x, e.pos.y)
}

// The den's owner senses harm to its home — mined structure or a trespasser
// inside — and hunts the intruder regardless of line of sight.
builder_alert :: proc(gs: ^Game_State, i: int) {
    e := &gs.enemies.data[i]
    b := &e.builder
    if b.goal == .Hunt { return }
    log_action(gs, "Builder#%d den breached — hunting", i)
    notify(gs, "A builder shrieks — it hunts you!")
    eq_push(&gs.events, Event{type = .Play_Sound, payload = {int_val = i32(Sound_ID.Builder_Shriek)}})
    b.goal        = .Hunt
    b.los_timer   = 0
    b.plan_target = {-99, -99}
    b.stuck_timer = 0
    b.stuck_count = 0
    e.nav.path    = {}
}

// Back to mineral duty after a hunt (or when prey is gone).
builder_return_to_work :: proc(e: ^Enemy) {
    b := &e.builder
    b.goal        = .Encase_Den if b.carry != .Air else .Fetch_Mineral
    b.has_target  = false
    b.stuck_timer = 0
    b.stuck_count = 0
    e.nav.path    = {}
}

builder_strike :: proc(e: ^Enemy, id: int, gs: ^Game_State, reason: string) {
    b := &e.builder
    b.stuck_count += 1
    b.stuck_timer  = 0
    log_action(gs, "Builder#%d strike %d (%s) pos=(%.1f,%.1f) cursor=%d/%d grounded=%v",
        id, b.stuck_count, reason, e.pos.x, e.pos.y,
        e.nav.path.cursor, e.nav.path.len, e.grounded)
    e.nav.path = {}

    if b.stuck_count >= MAX_STRIKES {
        b.stuck_count = 0
        builder_dig_free(e, id, gs)
        if e.kind == .Garm { return }   // the boss has no goals to shuffle — replan and keep hunting
        #partial switch b.goal {
        case .Build_Den:
            log_action(gs, "Builder#%d abandons den site (%d,%d)", id, b.anchor.x, b.anchor.y)
            b.anchor = DEN_UNSET
            b.step   = 0
            builder_pause(b, JOB_COOLDOWN, .Build_Den)
        case .Fetch_Mineral:
            log_action(gs, "Builder#%d gives up on (%d,%d)", id, b.target_tile.x, b.target_tile.y)
            b.avoid[b.avoid_n % len(b.avoid)] = b.target_tile
            b.avoid_n += 1
            b.has_target = false
            builder_pause(b, JOB_COOLDOWN, b.goal)
        case .Encase_Den:
            // Couldn't get home — drop the block and fetch elsewhere rather
            // than freeze in a retry loop.
            log_action(gs, "Builder#%d can't get home — drops %v", id, b.carry)
            b.carry = .Air
            builder_pause(b, JOB_COOLDOWN, .Fetch_Mineral)
        case .Hunt:
            log_action(gs, "Builder#%d gives up the hunt", id)
            builder_return_to_work(e)
        }
    }
}

// ─── Travel ───────────────────────────────────────────────────────────────────
//
//  Move toward T until within `stop` (chebyshev).  Handles pathing, mine/place
//  along the way, and the progress watchdog.  Returns true once in range.

builder_travel :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32, T: [2]i32, stop: i32) -> bool {
    b   := &e.builder
    nav := &e.nav

    // Arrival does NOT reset the watchdog: the on-site work loops (den step,
    // encase placement) accumulate stuck_timer and reset it on each completed
    // action, so a builder frozen at its worksite still strikes out.
    if chebyshev(builder_tile(e), T) <= stop {
        e.vel.x  = 0
        nav.path = {}
        return true
    }

    if nav.path.cursor >= nav.path.len {
        if b.replan_timer > 0 {
            e.vel.x = 0
            return false
        }
        b.replan_timer = REPLAN_MIN
        size := enemy_body_size(e.kind)
        from := [2]i32{i32(e.pos.x + size.x*0.5), i32(e.pos.y + size.y - 0.01)}
        if !astar_dig(gs, from, T, stop, int(b.pocket), &nav.path) {
            builder_strike(e, id, gs, "no path")
            return false
        }
    }

    // Watchdog measures PATH progress (waypoint reached or a mine/place
    // action), not raw movement — jump-bouncing in place must count as stuck.
    prev_cursor := nav.path.cursor
    acted := builder_exec_action(e, nav, gs)
    if !acted {
        enemy_follow_path(e, nav, &gs.world)
    }
    if acted || nav.path.cursor != prev_cursor {
        b.stuck_timer = 0
    } else {
        b.stuck_timer += dt
        if b.stuck_timer >= STUCK_TIME {
            builder_strike(e, id, gs, "no progress")
        }
    }
    return false
}

// ─── Den Site & Targets ───────────────────────────────────────────────────────

site_is_free :: proc(gs: ^Game_State, id: int, ax: int) -> bool {
    for i in 0 ..< MAX_ENEMIES {
        if i == id || !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind != .Builder || o.builder.anchor == DEN_UNSET { continue }
        if abs(int(o.builder.anchor.x) - ax) < SITE_SPACING { return false }
    }
    return true
}

builder_pick_den_site :: proc(e: ^Enemy, id: int, gs: ^Game_State) {
    b := &e.builder
    e.vel.x = 0

    seed := u32(gs.frame) + u32(id) * 7919
    for attempt in 0 ..< 8 {
        h := whash(seed + u32(attempt) * 131)

        // Prefer sites near the builder (short, reliable paths); widen the
        // search each attempt, going cave-wide on the last ones.
        hint_x: int
        if attempt < 5 {
            span := 25 + attempt*15
            hint_x = clamp(int(e.pos.x) - span + int(h % u32(span*2)), CAVE_LEFT, CAVE_RIGHT - 1)
        } else {
            hint_x = CAVE_LEFT + int(h % u32(CAVE_RIGHT - CAVE_LEFT))
        }

        ax, ay, found := find_cave_floor(&gs.world, hint_x, 4)
        if !found { continue }

        // Template extents (x ± 2, y − 3) must fit inside the cave shell.
        if ax - 2 <= CAVE_LEFT || ax + 2 >= CAVE_RIGHT - 1 { continue }
        if ay - 4 <= CAVE_TOP  || ay + 1 >= CAVE_BOT       { continue }

        if !site_is_free(gs, id, ax) { continue }

        b.build       = .Shelter
        b.anchor      = {i32(ax), i32(ay)}
        b.step        = 0
        b.den_built   = false
        b.stuck_count = 0
        b.stuck_timer = 0
        e.nav.path    = {}
        log_action(gs, "Builder#%d starts den at (%d,%d)", id, ax, ay)
        return
    }

    // No site this frame — brief pause, then try again.
    builder_pause(b, 1.0, .Build_Den)
}

// Nearest harvestable mineral (ore first, plain stone as fallback), skipping
// every builder's den + shell zone so nobody eats a den.
builder_find_mineral :: proc(e: ^Enemy, gs: ^Game_State) -> (best: [2]i32, ok: bool) {
    b  := &e.builder
    bt := builder_tile(e)
    // Dome extent + reach: anything closer sits in the pocket over/behind a
    // shell whose approach the den protection forbids digging through.
    exclude := i32(2 + DEN_SHELL_LAYERS) + BUILDER_REACH

    anchors:   [MAX_ENEMIES][2]i32
    n_anchors: int
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        o := &gs.enemies.data[i]
        if o.kind == .Builder && o.builder.anchor != DEN_UNSET {
            anchors[n_anchors] = o.builder.anchor
            n_anchors += 1
        }
    }

    best_d := max(i64)
    for pass in 0 ..< 2 {
        for y in CAVE_TOP ..< CAVE_BOT {
            for x in CAVE_LEFT ..< CAVE_RIGHT {
                t := gs.world.terrain[grid_idx(x, y)]
                want := is_mineral(t) if pass == 0 else t == .Stone
                if !want { continue }
                cand := [2]i32{i32(x), i32(y)}
                avoided := false
                for k in 0 ..< min(b.avoid_n, len(b.avoid)) {
                    if chebyshev(cand, b.avoid[k]) <= AVOID_RADIUS { avoided = true; break }
                }
                if avoided { continue }
                near_den := false
                for a in 0 ..< n_anchors {
                    if chebyshev(cand, anchors[a]) <= exclude { near_den = true; break }
                }
                if near_den { continue }
                dx := i64(cand.x - bt.x)
                dy := i64(cand.y - bt.y)
                d  := dx*dx + dy*dy
                if d < best_d { best_d = d; best = cand; ok = true }
            }
        }
        if ok { break }
    }
    return
}

// Next open slot on the den: damaged den walls first (patched with whatever is
// carried), then the mineral shell, ring by ring.  The 2-high door corridor is
// kept open through every layer.
den_next_build_tile :: proc(e: ^Enemy, gs: ^Game_State) -> (T: [2]i32, ok: bool) {
    b  := &e.builder
    pt := player_tile(&gs.player)

    usable :: proc(gs: ^Game_State, b: ^Builder_State, pt, cand: [2]i32) -> bool {
        if !in_bounds(int(cand.x), int(cand.y)) { return false }
        if is_solid(&gs.world, int(cand.x), int(cand.y)) { return false }
        if cand == pt && !gs.player.dead { return false }   // never entomb by accident
        return true
    }

    // Repair pass: missing solid den tiles.
    tmpl := build_templates[b.build]
    for t in tmpl.tiles {
        if t.tile == .Void || t.tile == .Air { continue }
        cand := b.anchor + t.off
        if usable(gs, b, pt, cand) { return cand, true }
    }

    // Shell pass: perimeter rings around the den box, closest layer first.
    for k in 1 ..= DEN_SHELL_LAYERS {
        x0 := i32(-2 - k)
        x1 := i32( 2 + k)
        y0 := i32(-3 - k)
        y1 := i32( 1)
        for dy in y0 ..= y1 {
            for dx in x0 ..= x1 {
                if dx != x0 && dx != x1 && dy != y0 && dy != y1 { continue }  // ring only
                if dx == x1 && (dy == 0 || dy == -1) { continue }             // door corridor
                cand := b.anchor + [2]i32{dx, dy}
                if usable(gs, b, pt, cand) { return cand, true }
            }
        }
    }
    return {}, false
}

// ─── Vision ───────────────────────────────────────────────────────────────────

builder_sees_player :: proc(e: ^Enemy, gs: ^Game_State, radius: f32) -> bool {
    if gs.player.dead { return false }
    bc := [2]f32{e.pos.x + BUILDER_W*0.5, e.pos.y + BUILDER_H*0.5}
    pc := [2]f32{gs.player.pos.x + PLAYER_W*0.5, gs.player.pos.y + PLAYER_H*0.5}
    d  := pc - bc
    dist2 := d.x*d.x + d.y*d.y
    if dist2 > radius*radius { return false }

    // Sample the sight line every half tile; any solid tile blocks it.
    steps := int(math.sqrt(dist2) * 2) + 1
    for i in 1 ..< steps {
        p := bc + d * (f32(i) / f32(steps))
        if is_solid(&gs.world, int(p.x), int(p.y)) { return false }
    }
    return true
}

// ─── Goals ────────────────────────────────────────────────────────────────────

builder_build_den :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if b.anchor == DEN_UNSET {
        builder_pick_den_site(e, id, gs)
        return
    }

    tmpl := build_templates[b.build]
    for b.step < len(tmpl.tiles) {
        t := tmpl.tiles[b.step]
        if !tile_satisfied(&gs.world, b.anchor + t.off, t.tile) { break }
        b.step += 1
    }
    if b.step >= len(tmpl.tiles) {
        log_action(gs, "Builder#%d den complete at (%d,%d)", id, b.anchor.x, b.anchor.y)
        b.den_built = true
        e.nav.path  = {}
        builder_pause(b, JOB_COOLDOWN, .Fetch_Mineral)
        return
    }

    t := tmpl.tiles[b.step]
    T := b.anchor + t.off
    if builder_travel(e, id, gs, dt, T, BUILDER_REACH) {
        builder_do_step(e, id, gs, T, t.tile)
        // do_step resets stuck_timer on every completed action; a builder
        // frozen at the worksite (step-aside pinned) must still strike out.
        b.stuck_timer += dt
        if b.stuck_timer >= STUCK_TIME {
            builder_strike(e, id, gs, "can't build")
        }
    }
}

builder_fetch :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if b.carry != .Air {
        b.goal = .Encase_Den
        return
    }

    // Target gone (mined by someone, or dug through en route)?
    if b.has_target {
        t := get_tile(&gs.world, int(b.target_tile.x), int(b.target_tile.y))
        if !is_mineral(t) && t != .Stone { b.has_target = false }
    }
    if !b.has_target {
        T, found := builder_find_mineral(e, gs)
        if !found {
            builder_pause(b, 2.0, .Fetch_Mineral)
            return
        }
        b.target_tile = T
        b.has_target  = true
        log_action(gs, "Builder#%d prospecting %v at (%d,%d)",
            id, get_tile(&gs.world, int(T.x), int(T.y)), T.x, T.y)
    }

    if builder_travel(e, id, gs, dt, b.target_tile, BUILDER_REACH) {
        if e.nav.mine_timer <= 0 {
            tx := int(b.target_tile.x)
            ty := int(b.target_tile.y)
            t  := get_tile(&gs.world, tx, ty)
            set_tile(&gs.world, tx, ty, .Void)
            eq_push(&gs.events, Event{type = .Builder_Mined, tile = b.target_tile})
            log_action(gs, "Builder#%d harvests %v at (%d,%d)", id, t, tx, ty)
            e.nav.mine_timer = MINE_TIME
            b.carry      = t
            b.has_target = false
            b.goal       = .Encase_Den
        }
    }
}

// Bank the carried block as loot on the den floor: the stockpile a raider
// can break in and steal.  Falls back to discarding when the floor stacks
// are full (the den can only hold so much).
builder_deposit_loot :: proc(e: ^Enemy, id: int, gs: ^Game_State) {
    b    := &e.builder
    drop := terrain_table[b.carry].drop_item
    if drop != .None {
        FLOOR_OFFS :: [3][2]i32{{0, 0}, {-1, 0}, {1, 0}}
        for off in FLOOR_OFFS {
            T := b.anchor + off
            if !in_bounds(int(T.x), int(T.y)) { continue }
            idx      := grid_idx(int(T.x), int(T.y))
            existing := gs.world.items[idx]
            if existing == drop && gs.world.item_counts[idx] > 0 {
                if int(gs.world.item_counts[idx]) < MAX_STACK {
                    gs.world.item_counts[idx] += 1
                    log_action(gs, "Builder#%d stockpiles %v at (%d,%d)", id, drop, T.x, T.y)
                    break
                }
            } else if existing == .None || gs.world.item_counts[idx] == 0 {
                gs.world.items[idx]       = drop
                gs.world.item_counts[idx] = 1
                log_action(gs, "Builder#%d stockpiles %v at (%d,%d)", id, drop, T.x, T.y)
                break
            }
        }
    }
    b.carry = .Air
}

builder_encase :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if b.carry == .Air {
        b.goal = .Fetch_Mineral
        return
    }

    // Work from home: walk back to the den, then fit the block into the next
    // open shell slot from there.  (Approaching each dome slot individually is
    // a reachability minefield — slots interleave with protected rock.)
    if !builder_travel(e, id, gs, dt, b.anchor, 2) { return }

    T, found := den_next_build_tile(e, gs)
    if !found {
        // Shell complete and intact — bank the haul as den loot and keep
        // fetching.  This is the ore economy: builders drain the shared
        // veins for as long as they live, and the stockpile is raidable.
        builder_deposit_loot(e, id, gs)
        b.stuck_timer = 0
        builder_pause(b, JOB_COOLDOWN, .Fetch_Mineral)
        return
    }
    // Same worksite watchdog as den building: a pinned step-aside must
    // strike out (3rd strike drops the block and refetches).
    b.stuck_timer += dt
    if b.stuck_timer >= STUCK_TIME {
        builder_strike(e, id, gs, "can't place")
        return
    }
    if e.nav.mine_timer <= 0 && builder_place_tile(e, gs, T, b.carry) {
        b.stuck_timer = 0
        log_action(gs, "Builder#%d encases den with %v at (%d,%d)",
            id, b.carry, T.x, T.y)
        b.carry = .Air
        b.goal  = .Fetch_Mineral
    }
}

builder_hunt :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    if gs.player.dead {
        log_action(gs, "Builder#%d prey eliminated — back to work", id)
        builder_return_to_work(e)
        return
    }

    pt := player_tile(&gs.player)
    bt := builder_tile(e)

    // Den defense: a raider on the den's grounds is never "lost" — the
    // den's own walls blocking sight must not protect the intruder.
    raiding := b.den_built &&
        chebyshev(pt, b.anchor) <= i32(2 + DEN_SHELL_LAYERS) + 2

    if raiding || builder_sees_player(e, gs, HUNT_LOSE_DIST) {
        b.los_timer = 0
    } else {
        b.los_timer += dt
    }
    if !raiding && (f32(chebyshev(bt, pt)) > HUNT_LOSE_DIST || b.los_timer > LOS_MEMORY) {
        log_action(gs, "Builder#%d lost the player — back to work", id)
        builder_return_to_work(e)
        return
    }

    // Player moved off the planned intercept — force a replan.
    if chebyshev(b.plan_target, pt) > 2 {
        b.plan_target = pt
        e.nav.path    = {}
    }

    if builder_travel(e, id, gs, dt, pt, 1) {
        e.facing = 1 if pt.x >= bt.x else -1
        if b.attack_timer <= 0 {
            b.attack_timer = ATTACK_TIME
            eq_push(&gs.events, Event{
                type    = .Damage_Dealt,
                source  = enemy_entity_id(id),
                target  = PLAYER_ID,
                payload = {int_val = ATTACK_DAMAGE},
            })
            log_action(gs, "Builder#%d bites the player", id)
        }
    }
}

// ─── Builder Update ───────────────────────────────────────────────────────────

update_builder :: proc(e: ^Enemy, id: int, gs: ^Game_State, dt: f32) {
    b := &e.builder
    e.nav.mine_timer -= dt
    b.replan_timer   -= dt
    b.attack_timer   -= dt

    // Trespass: the player standing inside the den enrages its owner, no
    // line of sight needed (interior box: template carve + door corridor).
    if b.den_built && b.goal != .Hunt && !gs.player.dead {
        rel := player_tile(&gs.player) - b.anchor
        if rel.x >= -1 && rel.x <= 2 && rel.y >= -2 && rel.y <= 0 {
            builder_alert(gs, id)
        }
    }

    // Spot the player while out working (den construction stays focused).
    if (b.goal == .Fetch_Mineral || b.goal == .Encase_Den) &&
       builder_sees_player(e, gs, HUNT_RADIUS) {
        log_action(gs, "Builder#%d spots the player — hunting", id)
        b.goal        = .Hunt
        b.los_timer   = 0
        b.plan_target = {-99, -99}
        b.stuck_timer = 0
        b.stuck_count = 0
        e.nav.path    = {}
    }

    switch b.goal {
    case .Build_Den:
        builder_build_den(e, id, gs, dt)
    case .Fetch_Mineral:
        builder_fetch(e, id, gs, dt)
    case .Encase_Den:
        builder_encase(e, id, gs, dt)
    case .Hunt:
        builder_hunt(e, id, gs, dt)
    case .Cooldown:
        e.vel.x     = 0
        b.cooldown -= dt
        if b.cooldown <= 0 { b.goal = b.resume }
    }
}

// ─── Update All Enemies ───────────────────────────────────────────────────────

update_enemies :: proc(gs: ^Game_State) {
    dt := gs.delta_time
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] { continue }
        e := &gs.enemies.data[i]
        prev := builder_tile(e)
        switch e.kind {
        case .Builder:
            move_body(&gs.world, &e.pos, &e.vel, {BUILDER_W, BUILDER_H}, dt,
                BUILDER_GRAVITY, BUILDER_MAX_FALL, &e.grounded)
            update_builder(e, i, gs, dt)
        case .Garm:
            move_body(&gs.world, &e.pos, &e.vel, {GARM_W, GARM_H}, dt,
                BUILDER_GRAVITY, BUILDER_MAX_FALL, &e.grounded)
            update_garm(e, i, gs, dt)
        case .Undead, .Fire_Sprite:
        }
        entity_map_move(&gs.world, enemy_entity_id(i), prev, builder_tile(e))
    }
}
