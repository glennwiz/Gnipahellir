package game

// agent_work.odin — the work goals: mine, gather, craft, place, and the store,
// withdraw, feed and collect of a barrel, silo or smelter.
//
// Each picks its own tool and walks into reach as go does (hero_go_tick), then
// works the world with the input a player gives: the mine button held on a
// tile, a place click, a click on a machine that opens its window.  A window is
// worked as a person works it (Glenn, 2026-11-03): it opens and is looked at,
// the cursor glides to the slot or the recipe card at HERO_CURSOR_SPEED, waits
// HERO_CLICK_PAUSE_S and grabs, glides to where the stack goes, waits and lets
// go, and after the last click the window is looked at again and shut.  What a
// click or a let-go does is the event the same mouse gesture pushes.  The
// cursor is gs.hero.cursor; the goal hands it to agent_input in gs.agent.cmd,
// which points the mouse there, and the UI draws it.  The hero never moves
// while the window is open.
//
// A goal that fails says why first: no_recipe, no_station, no_item,
// out_of_reach, unreachable, refused, blocked or full, then what.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "base:runtime"

// Feel: first guesses for Glenn to look at.
HERO_CURSOR_SPEED   :: f32(700)   // UI pixels a second the cursor glides
HERO_CLICK_PAUSE_S  :: f32(0.25)  // on a target before each click, and before a drag's grab and its let-go
HERO_WINDOW_LOOK_S  :: f32(0.4)   // a look at a window once it opens, and again before it shuts
HERO_MINE_GIVE_UP_S :: f32(6)     // on one tile in reach with nothing given: blocked
HERO_OPEN_TRIES     :: 4          // ticks a click has to open a window or set a block down
HERO_PLACE_ASIDE_TICKS :: 30      // ticks on a place's stand to take the body off the tile (card 164)
HERO_PLACE_NEAR     :: i32(4)     // tiles round home a place near:"home" looks at
HERO_PLACE_STAND    :: i32(3)     // a place out of reach walks this near

HERO_WORK_COUNT_MAX :: MAX_INVENTORY * MAX_STACK
HERO_WORK_SKIP      :: 8  // targets no ground reaches, passed over before the goal gives up
HERO_WORK_DIG_COST  :: i32(HERO_NAV_DIG_COST)  // a tile dug to stand on, in tiles of walk, as the planner prices it

// How far round the hero a gather, a station or a machine is looked for: the
// planner's own window, so what is found can be walked to.
HERO_WORK_SEARCH_X :: i32(HERO_NAV_W / 2 - 1)
HERO_WORK_SEARCH_Y :: i32(HERO_NAV_H / 2 - 1)

Hero_Work_Phase :: enum u8 { Walk, Open, Look, Clicks, Close }
// How a stand tile reaches the tile worked: a pick's swing round the body, a
// wand's range, a machine's BENCH_RANGE, a place's.
Hero_Work_Reach :: enum u8 { Pick, Wand, Bench, Place }

Hero_Work :: struct {
    kind:       Agent_Goal_Kind,
    item:       Item,
    count:      int,     // 0: all there is
    at:         [2]i32,  // the tile asked for: to mine, a machine, where to place; near:"home", the home tile
    has_at:     bool,
    near:       [2]i32,  // where a mine by item looks from
    has_near:   bool,
    near_home:  bool,
    recipe:     int,
    machine:    [2]i32,  // the station or machine worked
    target:     [2]i32,  // the tile being mined, the pile walked to, the tile placed on
    has_target: bool,
    pile:       bool,       // the target is a pile on the ground
    start_tile: Tile_Type,  // what the mined tile was
    phase:      Hero_Work_Phase,
    t:          f32,  // seconds in this phase, on this target, or on this click
    tries:      int,
    base:       int,  // the bag's count of item as the window opened
    last:       int,  // and as the last click went
    clicks:     int,
    made:       int,  // CRAFT clicks
    leg:        u8,   // a drag: 0 on the way to the grab, 1 carrying
    walking:    bool, // g.to is this goal's stand tile
    failing:    bool, // the window shuts, then the goal fails with g.reason
    by_item:    bool, // a mine by item: an unreachable tile gives way to the next
    skip:       [HERO_WORK_SKIP][2]i32,  // tiles that gave the item but could not be reached
    n_skip:     int,
    cornered:   bool, // a tile passed over was cornered: the goal fails so if none is left
    golem:      int,         // a crew goal's golem slot
    mode:       Golem_Mode,  // and crew_mode's mode
}

// One click at to, or a drag from `from` to `to`, and what the click or the
// let-go does.
Hero_Click :: struct {
    from, to: [2]f32,
    carry:    Item,  // .None: a click
    verb:     Agent_Verb,
    arg:      i32,
    limit:    i32,   // a feed's count, 0 the whole stack
}

Hero_Mined :: enum u8 { Working, Mined, Failed, Unreachable, Unsafe, Cornered }

// ─── Reading the goal ───

@(private="file")
hero_work_item :: proc(o: json.Object, key: string) -> (it: Item, present, ok: bool) {
    v, has := o[key]
    if !has do return
    present = true
    name, is_str := v.(json.String)
    if !is_str do return
    for i in Item do if i != .None && fmt.tprint(i) == name do return i, true, true
    return
}

// The goal's fields, read the same by the add check and the start.
@(private="file")
hero_work_parse :: proc(kind: Agent_Goal_Kind, o: json.Object) -> (w: Hero_Work, problem: string) {
    name := agent_goal_kinds[kind].name
    w.kind = kind
    present, ok: bool
    w.item, present, ok = hero_work_item(o, "item")
    if present && !ok do return w, fmt.tprintf("%s: item must name an item as state does, e.g. Wood_Log", name)
    if "count" in o {
        n, is_int := agent_int(o, "count")
        if !is_int || n < 1 || n > HERO_WORK_COUNT_MAX do return w, fmt.tprintf("%s: count must be 1..%d", name, HERO_WORK_COUNT_MAX)
        w.count = n
    }
    key := "tile" if kind == .Mine else "at"
    w.at, _, present, ok = agent_tile(o, key)
    if present && !ok do return w, fmt.tprintf("%s: %s takes [x,y] inside the level", name, key)
    w.has_at = ok
    if "near" in o {
        if kind == .Place {
            s, _ := o["near"].(json.String)
            if s != "home" do return w, `place: near takes "home"`
            w.near_home = true
        } else {
            w.near, _, _, ok = agent_tile(o, "near")
            if !ok do return w, fmt.tprintf("%s: near takes [x,y] inside the level", name)
            w.has_near = true
        }
    }
    need_item := false
    #partial switch kind {
    case .Crew_Mode, .Crew_Call, .Crew_Pickup:
        n, is_int := agent_int(o, "golem")
        if !is_int || n < 0 || n >= MAX_GOLEMS do return w, fmt.tprintf("%s needs golem: a slot from state's crew, 0..%d", name, MAX_GOLEMS - 1)
        w.golem = n
        if kind != .Crew_Mode do break
        s, _ := o["mode"].(json.String)
        for m in Golem_Mode {
            if fmt.tprint(m) != s do continue
            w.mode = m
            return
        }
        return w, "crew_mode needs mode: Gather, Build or Fight"
    case .Mine:
        if !w.has_at && w.item == .None do return w, "mine needs tile:[x,y] or item"
    case .Gather, .Craft, .Store, .Feed:
        need_item = true
    case .Place:
        need_item = true
        if w.has_at == w.near_home do return w, `place needs at:[x,y] or near:"home", one of them`
    case .Withdraw:
        if !w.has_at && w.item == .None do return w, "withdraw needs at:[x,y] or item"
    }
    if need_item && w.item == .None do return w, fmt.tprintf("%s needs item", name)
    return
}

// What the queued and running craft goals need of item it, by their recipes
// and counts (a running one's whole count: it over-holds while it works, never
// under): a bridge keeps that much back (card 159).
hero_craft_reserve :: proc(gs: ^Game_State, it: Item) -> (need: int) {
    q := gs.agent.goals
    if q == nil do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    for &g in q.slots[:q.n] do if g.kind == .Craft && (g.status == .Queued || g.status == .Running) {
        value, _ := json.parse_string(string(g.line[:g.len]), parse_integers = true, allocator = context.temp_allocator)
        o, _ := value.(json.Object)
        w, _ := hero_work_parse(g.kind, o)
        r := agent_find_recipe(gs, fmt.tprint(w.item))
        if r < 0 do continue
        for ing in recipe_table[r].ingredients do if ing.item == it do need += ing.count * max(w.count, 1)
    }
    return
}

hero_work_check :: proc(gs: ^Game_State, o: json.Object) -> string {
    name, _ := o["do"].(json.String)
    kind, _ := agent_goal_find_kind(name)
    _, problem := hero_work_parse(kind, o)
    return problem
}

// Judged against the world as it is when the goal comes up: what it works on
// is found now.
hero_work_start :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    value, _ := json.parse_string(string(g.line[:g.len]), parse_integers = true, allocator = context.temp_allocator)
    o, _ := value.(json.Object)
    g.work, _ = hero_work_parse(g.kind, o)
    w := &g.work
    feet := hero_feet(&gs.player)
    why: string
    #partial switch g.kind {
    case .Mine:
        switch {
        case w.has_at:
            t := get_tile(&gs.world, int(w.at.x), int(w.at.y))
            if .Mineable not_in terrain_table[t].flags || is_structure_tile[t] do why = fmt.tprintf("no_item: nothing to mine at [%d,%d]", w.at.x, w.at.y)
        case:
            t, ok := hero_work_nearest(gs, w.near if w.has_near else feet, w, hero_work_gives)
            if !ok do why = fmt.tprintf("no_item: no tile in %d that gives %v and a tool works", HERO_WORK_SEARCH_X, w.item)
            w.at, w.has_at, w.by_item = t, true, true
        }
    case .Craft:
        w.recipe = agent_find_recipe(gs, fmt.tprint(w.item))
        if w.recipe < 0 {
            why = fmt.tprintf("no_recipe: no revealed recipe makes %v", w.item)
            break
        }
        r := &recipe_table[w.recipe]
        for ing in r.ingredients {
            if ing.item != .None && inventory_count(&gs.player.inventory, ing.item) < ing.count {
                why = fmt.tprintf("no_item: %v needs %d %v", r.result, ing.count, ing.item)
                break
            }
        }
        if why != "" || r.station == .None do break
        t, ok := hero_work_nearest(gs, feet, w, hero_work_station)
        if !ok do why = fmt.tprintf("no_station: no %v in %d tiles", station_tile[r.station], HERO_WORK_SEARCH_X)
        w.machine = t
    case .Place:
        switch {
        case item_table[w.item].place_tile == .Air:
            why = fmt.tprintf("no_item: %v does not set down", w.item)
        case w.near_home:
            q := gs.agent.goals
            switch {
            case q != nil && q.has_home && q.home_level == gs.level_index: w.at = q.home
            case gs.level_index == LEVEL_SURFACE:                         w.at = hero_spawn_feet()
            case: why = "unreachable: no home on this level"
            }
            if is_solid(&gs.world, int(w.at.x), int(w.at.y)) && in_bounds(int(w.at.x), int(w.at.y - 1)) do w.at.y -= 1
        }
    case .Store, .Feed, .Withdraw, .Collect:
        why = hero_work_find_machine(gs, w, feet)
    case .Crew_Mode, .Crew_Call, .Crew_Pickup:
        why = hero_crew_check(gs, w)
    }
    if why != "" {
        agent_text_set(&g.reason, why)
        return false
    }
    return true
}

// A crew goal against the crew as it is: the wand in the bag, and a golem in
// the slot on this level that the roster can give the order to.
@(private="file")
hero_crew_check :: proc(gs: ^Game_State, w: ^Hero_Work) -> string {
    g := &gs.golems.data[w.golem]
    switch {
    case hero_held_or_first(gs, is_command_wand) < 0: return "no_item: no command wand in the bag"
    case g.status == .Empty:                          return fmt.tprintf("no_item: no golem in slot %d", w.golem)
    case g.status == .Carried:                        return fmt.tprintf("blocked: golem %d rides in the wand: place it first", w.golem)
    case g.level != gs.level_index:                   return fmt.tprintf("out_of_reach: golem %d is on level %d", w.golem, g.level)
    case g.status == .Broken && w.kind != .Crew_Pickup: return fmt.tprintf("blocked: golem %d is cracked: crew_pickup it and repair it at a Clay Hearth", w.golem)
    case w.kind == .Crew_Mode && g.mode == w.mode:    return fmt.tprintf("blocked: golem %d is in %v already", w.golem, w.mode)
    }
    w.machine = golem_tile(g)  // a cracked one is walked to: PICK UP needs it in reach
    return ""
}

// The crew goals work the roster; a cracked golem's PICK UP wants it in reach.
// The kind matters: a golem that cracks mid-goal leaves a call or a mode order
// with a dimmed button, which no walk lights.
@(private="file")
hero_crew_kind :: proc(k: Agent_Goal_Kind) -> bool {
    return k == .Crew_Mode || k == .Crew_Call || k == .Crew_Pickup
}

@(private="file")
hero_crew_walks :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    return g.kind == .Crew_Pickup && gs.golems.data[g.work.golem].status == .Broken
}

@(private="file")
hero_work_find_machine :: proc(gs: ^Game_State, w: ^Hero_Work, feet: [2]i32) -> string {
    names := #partial [Agent_Goal_Kind]string{.Store = "barrel", .Feed = "smelter", .Collect = "smelter", .Withdraw = "barrel, chest, silo or smelter"}
    if w.has_at {
        if !hero_work_fits(gs, w.kind, w.at) do return fmt.tprintf("no_station: no %s at [%d,%d]", names[w.kind], w.at.x, w.at.y)
        w.machine = w.at
    } else {
        t, ok := hero_work_nearest(gs, feet, w, hero_work_machine)
        if !ok && w.kind == .Withdraw do return fmt.tprintf("no_station: no barrel holding %v in %d tiles", w.item, HERO_WORK_SEARCH_X)
        if !ok do return fmt.tprintf("no_station: no %s in %d tiles", names[w.kind], HERO_WORK_SEARCH_X)
        w.machine = t
    }
    m := w.machine
    tile := get_tile(&gs.world, int(m.x), int(m.y))
    sd := gs.world.sim_data[grid_idx(int(m.x), int(m.y))]
    #partial switch w.kind {
    case .Store, .Feed:
        if hero_item_slot(gs, w.item) < 0 do return fmt.tprintf("no_item: no %v in the bag", w.item)
        _, is_ore := smelt_rule_for(w.item)
        if w.kind == .Feed && !is_ore && !smelter_is_fuel(w.item) do return fmt.tprintf("no_item: the furnace takes ore and wood, not %v", w.item)
    case .Collect:
        if sd.store_count == 0 do return "no_item: the tray is empty"
    case .Withdraw:
        #partial switch tile {
        case .Smelter:
            if sd.in_count == 0 do return "no_item: the furnace holds no ore"
        case .Barrel, .Rune_Coffer, .Sky_Rune_Scroll_Chest, .Rune_Scroll_Chest_A, .Rune_Scroll_Chest_B, .Rune_Scroll_Chest_C:
            if w.item == .None do return "no_item: a withdraw from a barrel names the item"
            if !hero_barrel_holds(gs, m, w.item) do return fmt.tprintf("no_item: the %s holds no %v", "chest" if is_rune_scroll_chest(tile) else "barrel", w.item)
        }
    }
    return ""
}

// ─── Finding ───

// The tile nearest from that want says yes to, inside the search window.
@(private="file")
hero_work_nearest :: proc(gs: ^Game_State, from: [2]i32, w: ^Hero_Work, want: proc(gs: ^Game_State, w: ^Hero_Work, t: [2]i32) -> bool) -> (best: [2]i32, ok: bool) {
    d_best := max(i32)
    for y in from.y - HERO_WORK_SEARCH_Y ..= from.y + HERO_WORK_SEARCH_Y {
        for x in from.x - HERO_WORK_SEARCH_X ..= from.x + HERO_WORK_SEARCH_X {
            d := abs(x - from.x) + abs(y - from.y)
            if d >= d_best || !in_bounds(int(x), int(y)) || !want(gs, w, {x, y}) do continue
            best, d_best, ok = {x, y}, d, true
        }
    }
    return
}

// A tile that gives the item, that a tool in the bag mines, and no rim.
@(private="file")
hero_work_gives :: proc(gs: ^Game_State, w: ^Hero_Work, t: [2]i32) -> bool {
    tile := get_tile(&gs.world, int(t.x), int(t.y))
    if terrain_table[tile].drop_item != w.item || .Mineable not_in terrain_table[tile].flags || is_structure_tile[tile] do return false
    if hero_rim(&gs.world, t) do return false
    for s in w.skip[:w.n_skip] do if s == t do return false
    _, _, _, ok := hero_work_tool(gs, t)
    return ok
}

// A pile of the item a body can walk over.
@(private="file")
hero_work_pile :: proc(gs: ^Game_State, w: ^Hero_Work, t: [2]i32) -> bool {
    idx := grid_idx(int(t.x), int(t.y))
    if gs.world.items[idx] != w.item || gs.world.item_counts[idx] == 0 do return false
    return hero_stand(&gs.world, t)  // a pile lies on the ground: stood in, it is picked up
}

@(private="file")
hero_work_station :: proc(gs: ^Game_State, w: ^Hero_Work, t: [2]i32) -> bool {
    return get_tile(&gs.world, int(t.x), int(t.y)) == station_tile[recipe_table[w.recipe].station]
}

// Whether the machine at t is one this kind works.
@(private="file")
hero_work_fits :: proc(gs: ^Game_State, kind: Agent_Goal_Kind, t: [2]i32) -> bool {
    tile := get_tile(&gs.world, int(t.x), int(t.y))
    barrel := tile == .Barrel || tile == .Rune_Coffer
    #partial switch kind {
    case .Store:          return barrel
    case .Feed, .Collect: return tile == .Smelter
    case .Withdraw:       return barrel || is_rune_scroll_chest(tile) || tile == .Smelter || tile == .Silo  // a scroll chest opens as a barrel (card 164)
    }
    return false
}

// A machine to go to: a withdraw with no at looks for a barrel holding its item.
@(private="file")
hero_work_machine :: proc(gs: ^Game_State, w: ^Hero_Work, t: [2]i32) -> bool {
    if !hero_work_fits(gs, w.kind, t) do return false
    if w.kind != .Withdraw do return true
    return hero_barrel_holds(gs, t, w.item)
}

// Whether the barrel at t holds the item.  A scroll chest never opened has no
// record yet: it holds its own scroll.
@(private="file")
hero_barrel_holds :: proc(gs: ^Game_State, t: [2]i32, it: Item) -> bool {
    if b := barrel_at(gs, gs.level_index, t); b != nil do return hero_barrel_slot(b, it) >= 0
    held, _ := rune_scroll_chest_item(get_tile(&gs.world, int(t.x), int(t.y)))
    return held == it
}

@(private="file")
hero_barrel_slot :: proc(b: ^Barrel_State, it: Item) -> int {
    for s, i in b.slots do if s.item == it && s.count > 0 do return i
    return -1
}

// The tool for tile t: the longest wand the mana fires, else the pickaxe, else
// bare hands on wood.  Slot -1 is the empty hand.
hero_work_tool :: proc(gs: ^Game_State, t: [2]i32) -> (slot: int, reach: Hero_Work_Reach, rng: i32, ok: bool) {
    p := &gs.player
    best := -1
    for s, i in p.inventory.slots {
        if s.count <= 0 || wand_mine_range[s.item] <= 0 || p.mana < wand_mana_cost[s.item] do continue
        if best < 0 || wand_mine_range[s.item] > wand_mine_range[p.inventory.slots[best].item] do best = i
    }
    if best >= 0 do return best, .Wand, wand_mine_range[p.inventory.slots[best].item], true
    if pick := hero_item_slot(gs, .Pickaxe); pick >= 0 do return pick, .Pick, PICK_RANGE, true
    if get_tile(&gs.world, int(t.x), int(t.y)) == .Wood do return -1, .Pick, PICK_RANGE, true
    return -1, .Pick, 0, false
}

// Whether a hero with its feet on s reaches t.  The pick swings round the
// body's two tiles, never into them; the rest measure from the feet tile,
// which is the player's centre tile when standing.
hero_work_reaches :: proc(reach: Hero_Work_Reach, rng: i32, s, t: [2]i32) -> bool {
    body := t.x == s.x && (t.y == s.y || t.y == s.y - 1)
    switch reach {
    case .Pick:  return !body && abs(t.x - s.x) <= rng && t.y >= s.y - 1 - rng && t.y <= s.y + rng
    case .Wand, .Place: return !body && chebyshev(t, s) <= rng
    case .Bench: return chebyshev(t, s) <= rng
    }
    return false
}

// The stand tile nearest the hero that reaches t.  With a pickaxe in the bag
// the pick's stands may be dug out first, as the walk there digs its way
// (a buried ore): each tile to dig counts HERO_WORK_DIG_COST tiles of walk.
// A stand on t itself is refused when digging t would drop the hero further
// than a free fall (hero_dig_safe); unsafe then gives that drop.
hero_work_stand :: proc(gs: ^Game_State, t: [2]i32, reach: Hero_Work_Reach, rng: i32) -> (s: [2]i32, ok: bool, unsafe: int, cornered: bool) {
    feet := hero_feet(&gs.player)
    dig := reach == .Pick && hero_item_slot(gs, .Pickaxe) >= 0
    wary := hero_wary(gs)
    r := rng
    best := max(i32)
    for y in t.y - r ..= t.y + r + 1 {
        for x in t.x - r ..= t.x + r {
            c := [2]i32{x, y}
            if !in_bounds(int(x), int(y)) || !hero_work_reaches(reach, rng, c, t) do continue
            dug := 0
            if !hero_stand(&gs.world, c) {
                n, can := hero_work_dig_stand(gs, c)
                if !dig || !can do continue
                dug = n
            }
            if drop, safe := hero_dig_safe(&gs.world, t, c.y, c.x, c.x); !safe {
                unsafe = drop
                continue
            }
            if wary && !hero_way_out_cheap(&gs.world, c) {
                cornered = true  // no work where a hunter corners it
                continue
            }
            if d := abs(x - feet.x) + abs(y - feet.y) + HERO_WORK_DIG_COST * i32(dug); d < best do best, s, ok = d, c, true
        }
    }
    return
}

// Whether c becomes a stand tile once dug: the feet and head tiles open or
// diggable, solid under the feet.  Gives the tiles to dig.  (A stand that
// reaches t never has t for its body: the pick never swings there.)
@(private="file")
hero_work_dig_stand :: proc(gs: ^Game_State, c: [2]i32) -> (dug: int, ok: bool) {
    w := &gs.world
    if !is_solid(w, int(c.x), int(c.y + 1)) do return
    for b in ([2][2]i32{c, c - {0, 1}}) {
        switch {
        case hero_open(w, b.x, b.y):
        case is_solid(w, int(b.x), int(b.y)) && hero_diggable(gs, b, true): dug += 1
        case:                           return
        }
    }
    return dug, true
}

// ─── Walking and mining ───

// Toward stand tile s as a go goes; true once there.  A walk that cannot get
// there fails the goal unreachable.
@(private="file")
hero_work_walk :: proc(gs: ^Game_State, g: ^Agent_Goal, s: [2]i32) -> bool {
    w := &g.work
    if !w.walking || g.to != s {
        g.to, g.best, g.stuck_t, g.replanned, g.left = s, max(i32), 0, false, 0
        gs.hero.path.n = 0
        w.walking = true
    }
    if hero_go_tick(gs, g) do return true
    if g.status == .Failed do agent_text_set(&g.reason, fmt.tprintf("unreachable: %s", string(g.reason.buf[:g.reason.len])))
    return false
}

@(private="file")
hero_work_fail :: proc(g: ^Agent_Goal, why: string) -> bool {
    g.status = .Failed
    agent_text_set(&g.reason, why)
    return false
}

@(private="file")
hero_work_target :: proc(gs: ^Game_State, g: ^Agent_Goal, t: [2]i32, pile: bool) {
    w := &g.work
    w.target, w.has_target, w.pile, w.t, w.tries, w.walking = t, true, pile, 0, 0, false
    w.start_tile = get_tile(&gs.world, int(t.x), int(t.y))
}

// In flight with no floor under the feet row, so no walk starts from it (a
// hover low over the floor still walks).  Flight zeroes the body's speed, so
// grounded keeps whatever it last was: the floor is read.
hero_hovering :: proc(gs: ^Game_State) -> bool {
    p := &gs.player
    if gs.flight_t <= 0 do return false
    fy := hero_feet_row(p)
    for x in i32(p.pos.x) ..= i32(p.pos.x + PLAYER_W - 0.001) do if is_solid(&gs.world, int(x), int(fy + 1)) do return false
    return true
}

// One tick on the target tile: into reach, the tool in hand, the button held
// on it.  Mined once the tile is another.
@(private="file")
hero_work_mine :: proc(gs: ^Game_State, g: ^Agent_Goal) -> Hero_Mined {
    w := &g.work
    p := &gs.player
    t := w.target
    if get_tile(&gs.world, int(t.x), int(t.y)) != w.start_tile do return .Mined
    slot, reach, rng, ok := hero_work_tool(gs, t)
    if !ok {
        hero_work_fail(g, fmt.tprintf("no_item: no pickaxe for the %v at [%d,%d]", w.start_tile, t.x, t.y))
        return .Failed
    }
    _, safe := hero_dig_safe(&gs.world, t, hero_feet_row(p), i32(p.pos.x), i32(p.pos.x + PLAYER_W - 0.001))
    // Hovering in flight (card 164, goal 316) the body never comes down to a
    // walk: it works what it reaches from there, and says so for the rest.
    hovering := hero_hovering(gs)
    if (!p.grounded && !hovering) || !hero_work_reaches(reach, rng, hero_feet(p), t) || !safe {
        if hovering {
            hero_work_fail(g, fmt.tprintf("unreachable: [%d,%d] is out of reach of the hover in flight", t.x, t.y))
            return .Unreachable
        }
        s := g.to
        if !w.walking {
            found, cornered: bool
            unsafe: int
            s, found, unsafe, cornered = hero_work_stand(gs, t, reach, rng)
            if !found && cornered {
                hero_work_fail(g, fmt.tprintf("cornered: every stand in reach of [%d,%d] has no cheap way out, and the hero is wary", t.x, t.y))
                return .Cornered
            }
            if !found && unsafe > 0 {
                hero_work_fail(g, fmt.tprintf("unsafe: [%d,%d] is the only floor in reach of it, over a %d-tile drop", t.x, t.y, unsafe))
                return .Unsafe
            }
            if !found {
                hero_work_fail(g, fmt.tprintf("unreachable: no ground in reach of [%d,%d]", t.x, t.y))
                return .Unreachable
            }
        }
        hero_work_walk(gs, g, s)
        return .Unreachable if g.status == .Failed else .Working
    }
    if b := &gs.hero; b.refused && b.refused_at == t {
        // A reflex took the pick off it last tick, and will again.
        hero_work_fail(g, fmt.tprintf("refused: the %s reflex keeps the pick off [%d,%d]", hero_reflexes[b.refused_by].name, t.x, t.y))
        return .Failed
    }
    w.t += gs.delta_time
    if w.t > HERO_MINE_GIVE_UP_S {
        hero_work_fail(g, fmt.tprintf("blocked: the %v at [%d,%d] gave nothing", w.start_tile, t.x, t.y))
        return .Failed
    }
    c := &gs.agent.cmd
    if p.inventory.selected != slot {
        c.verb, c.verb_arg = .Select, i32(slot)
        gs.agent.first = true
        return .Working
    }
    c.has_mine = true
    c.mine     = t
    c.aim      = {f32(t.x) + 0.5, f32(t.y) + 0.5}
    return .Working
}

hero_mine_goal_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    w := &g.work
    if !w.has_target {
        if w.n_skip > 0 {
            // The last one could not be reached: the next nearest.
            t, ok := hero_work_nearest(gs, w.near if w.has_near else hero_feet(&gs.player), w, hero_work_gives)
            if !ok && w.cornered do return hero_work_fail(g, fmt.tprintf("cornered: every %v in reach has no stand with a cheap way out, and the hero is wary", w.item))
            if !ok do return hero_work_fail(g, fmt.tprintf("unreachable: no %v in %d tiles that can be reached, %d tried", w.item, HERO_WORK_SEARCH_X, w.n_skip))
            w.at = t
        }
        hero_work_target(gs, g, w.at, false)
    }
    r := hero_work_mine(gs, g)
    if (r == .Unreachable || r == .Unsafe || r == .Cornered) && w.by_item do hero_work_skip(g, r == .Cornered)
    return r == .Mined
}

// A tile that gives the item but that no ground reaches is passed over, up to
// HERO_WORK_SKIP of them: the goal looks again.  Past that it fails, as it
// stands.
@(private="file")
hero_work_skip :: proc(g: ^Agent_Goal, cornered: bool) {
    w := &g.work
    if w.n_skip >= HERO_WORK_SKIP do return
    w.cornered ||= cornered
    w.skip[w.n_skip] = w.target
    w.n_skip += 1
    w.has_target = false
    g.status = .Running  // its reason is read only once it has failed
}

// Piles first, then the tiles that give the item, nearest each time, until
// the bag holds count.
hero_gather_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    w := &g.work
    p := &gs.player
    if inventory_count(&p.inventory, w.item) >= max(w.count, 1) do return true
    if !w.has_target {
        feet := hero_feet(p)
        if t, ok := hero_work_nearest(gs, feet, w, hero_work_pile); ok {
            hero_work_target(gs, g, t, true)
        } else if t, ok := hero_work_nearest(gs, feet, w, hero_work_gives); ok {
            hero_work_target(gs, g, t, false)
        } else if w.cornered {
            return hero_work_fail(g, fmt.tprintf("cornered: every %v in reach has no stand with a cheap way out, and the hero is wary", w.item))
        } else {
            return hero_work_fail(g, fmt.tprintf("no_item: no more %v in %d tiles", w.item, HERO_WORK_SEARCH_X))
        }
    }
    if !w.pile {
        #partial switch r := hero_work_mine(gs, g); r {
        case .Mined:       w.has_target = false
        case .Unreachable, .Unsafe, .Cornered: hero_work_skip(g, r == .Cornered)
        }
        return false
    }
    t := w.target
    idx := grid_idx(int(t.x), int(t.y))
    if gs.world.items[idx] != w.item || gs.world.item_counts[idx] == 0 || !hero_stand(&gs.world, t) {
        w.has_target = false
        return false
    }
    if hero_work_walk(gs, g, t) {
        // There, and the pile still lies: the bag takes none of it.
        w.tries += 1
        if w.tries > HERO_OPEN_TRIES do return hero_work_fail(g, "full: the bag takes no more")
    }
    return false
}

// Into reach, the item in hand, one place click, and the tile checked.
hero_place_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    w := &g.work
    p := &gs.player
    c := &gs.agent.cmd
    tile := item_table[w.item].place_tile
    if w.has_target {
        if get_tile(&gs.world, int(w.target.x), int(w.target.y)) == tile do return true
        w.tries += 1
        if w.tries > HERO_OPEN_TRIES {
            return hero_work_fail(g, fmt.tprintf("refused: the game refused the %v at [%d,%d]", w.item, w.target.x, w.target.y))
        }
        return false
    }
    slot := hero_item_slot(gs, w.item)
    if slot < 0 do return hero_work_fail(g, fmt.tprintf("no_item: no %v in the bag", w.item))
    if w.near_home {
        if !hero_work_walk(gs, g, w.at) do return false
        w.walking = false
        spot, ok := hero_place_spot(gs, w.item)
        if !ok do return hero_work_fail(g, fmt.tprintf("out_of_reach: no tile round home takes the %v", w.item))
        w.at, w.near_home = spot, false
    }
    at := w.at
    if !placement_ok(gs, w.item, int(at.x), int(at.y)) {
        in_reach := chebyshev(at, player_tile(p)) <= PLAYER_REACH &&
            !(.Solid in terrain_table[tile].flags && tile_overlaps_player(gs, int(at.x), int(at.y)))
        if in_reach {
            // In reach as the game measures it: the game's own words say why.
            why, _ := place_refusal_full(gs, w.item, int(at.x), int(at.y))
            return hero_work_fail(g, fmt.tprintf("refused: %s", why if why != "" else "it will not go there"))
        }
        s := g.to
        if !w.walking {
            found, cornered: bool
            s, found, _, cornered = hero_work_stand(gs, at, .Place, HERO_PLACE_STAND)
            if !found && cornered do return hero_work_fail(g, fmt.tprintf("cornered: every stand near [%d,%d] has no cheap way out, and the hero is wary", at.x, at.y))
            if !found do return hero_work_fail(g, fmt.tprintf("unreachable: no ground near [%d,%d]", at.x, at.y))
        }
        if hero_work_walk(gs, g, s) {
            // On the stand, the body still over the tile: a go ends as the
            // feet reach the stand's tile, so on to its middle (card 164).
            w.tries += 1
            if w.tries > HERO_PLACE_ASIDE_TICKS do return hero_work_fail(g, fmt.tprintf("blocked: the body stays over [%d,%d]", at.x, at.y))
            c.move = 1 if f32(s.x) + 0.5 > p.pos.x + PLAYER_W * 0.5 else -1
        }
        return false
    }
    gs.agent.first = true
    if p.inventory.selected != slot {
        c.verb, c.verb_arg = .Select, i32(slot)
        return false
    }
    c.has_place = true
    c.place     = at
    c.aim       = {f32(at.x) + 0.5, f32(at.y) + 0.5}
    w.target, w.has_target, w.tries = at, true, 0
    return false
}

// The free tile round the feet nearest them that takes the item.
@(private="file")
hero_place_spot :: proc(gs: ^Game_State, it: Item) -> (spot: [2]i32, ok: bool) {
    feet := hero_feet(&gs.player)
    best := max(i32)
    for dy in -HERO_PLACE_NEAR ..= HERO_PLACE_NEAR {
        for dx in -HERO_PLACE_NEAR ..= HERO_PLACE_NEAR {
            t := feet + {dx, dy}
            if d := abs(dx) + abs(dy); d < best && placement_ok(gs, it, int(t.x), int(t.y)) do best, spot, ok = d, t, true
        }
    }
    return
}

// ─── Windows ───

// Craft, store, withdraw, feed, collect: walk into reach of the machine, open
// its window, look, click, look, shut it.
hero_window_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    w := &g.work
    p := &gs.player
    b := &gs.hero
    c := &gs.agent.cmd
    m := w.machine
    crew := hero_crew_kind(g.kind)
    hand := g.kind == .Craft && recipe_table[w.recipe].station == .None || crew && !hero_crew_walks(gs, g)
    reach := i32(PLAYER_REACH if crew else BENCH_RANGE)
    if b.cursor == {} do b.cursor = {UI_W / 2, UI_H / 2}
    // Back from a pause before the window was seen: a flight's tick may have
    // swept it shut (card 175: playtest 136's flee flips, "did not open").
    resumed := w.phase == .Open && b.held == 0
    if (w.phase == .Look || w.phase == .Clicks || resumed) && !hero_window_up(gs, g) {
        // Shut under it, by a fight or a flight the goal paused for: back to
        // the machine, and open it again.
        w.phase, w.leg, w.walking = .Walk, 0, false
    }
    switch w.phase {
    case .Walk:
        if !hand && (!p.grounded || chebyshev(m, player_tile(p)) > reach) {
            s := g.to
            if !w.walking {
                found, cornered: bool
                s, found, _, cornered = hero_work_stand(gs, m, .Bench, reach)
                if !found && cornered do return hero_work_fail(g, fmt.tprintf("cornered: every stand in reach of [%d,%d] has no cheap way out, and the hero is wary", m.x, m.y))
                if !found do return hero_work_fail(g, fmt.tprintf("unreachable: no ground in reach of [%d,%d]", m.x, m.y))
            }
            hero_work_walk(gs, g, s)
            return false
        }
        w.walking = false
        w.phase, w.tries = .Open, 0
        fallthrough
    case .Open:
        c.has_cursor, c.cursor = true, b.cursor
        silo := !hand && get_tile(&gs.world, int(m.x), int(m.y)) == .Silo
        if silo && w.tries > 0 do return true  // a silo has no window: the click empties it into the bag
        if hero_window_up(gs, g) {  // a silo has none: never up
            w.phase, w.t = .Look, 0
            w.base = inventory_count(&p.inventory, w.item)
            return false
        }
        if w.tries > HERO_OPEN_TRIES do return hero_work_fail(g, fmt.tprintf("out_of_reach: the window at [%d,%d] did not open", m.x, m.y))
        if w.tries == 0 {
            if crew && equipped_command_wand(gs) == .None {
                c.verb, c.verb_arg = .Select, i32(hero_held_or_first(gs, is_command_wand))
                gs.agent.first = true
                return false  // the wand in hand first; the next tick opens the roster
            }
            if crew {
                c.verb = .Open_Roster  // the wand's click on the world
            } else if hand {
                c.verb = .Open_Craft
            } else {
                c.has_use = true
                c.use     = m
                c.aim     = {f32(m.x) + 0.5, f32(m.y) + 0.5}
            }
            gs.agent.first = true
        }
        w.tries += 1
    case .Look:
        c.has_cursor, c.cursor = true, b.cursor
        w.t += gs.delta_time
        if w.t >= HERO_WINDOW_LOOK_S do w.phase, w.t = .Clicks, 0
    case .Clicks:
        k, more := hero_next_click(gs, g)
        if !more {
            w.phase, w.t = .Close, 0
            c.has_cursor, c.cursor = true, b.cursor
            return false
        }
        hero_click_run(gs, g, k)
    case .Close:
        c.has_cursor, c.cursor = true, b.cursor
        w.t += gs.delta_time
        if w.t < HERO_WINDOW_LOOK_S do return false
        // A tick with nothing that works a window sweeps them shut.
        c.has_cursor = false
        gs.agent.first = true
        if w.failing {
            g.status = .Failed
            return false
        }
        return true
    }
    return false
}

// Whether the window this goal works is open, on its machine.
@(private="file")
hero_window_up :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    m := g.work.machine
    if hero_crew_kind(g.kind) do return gs.ui.show_golem_roster
    if g.kind == .Craft {
        st := recipe_table[g.work.recipe].station
        return gs.ui.show_crafting && (st == .None || gs.ui.active_station == st)
    }
    if get_tile(&gs.world, int(m.x), int(m.y)) == .Smelter do return gs.ui.show_smelter && gs.ui.smelter_tile == m
    return gs.ui.show_barrel && gs.ui.barrel_tile == m
}

// The cursor one tick nearer to, at HERO_CURSOR_SPEED; true once on it.
@(private="file")
hero_cursor_glide :: proc(gs: ^Game_State, to: [2]f32) -> bool {
    b := &gs.hero
    d := to - b.cursor
    dist := math.sqrt(d.x * d.x + d.y * d.y)
    step := HERO_CURSOR_SPEED * gs.delta_time
    if dist <= step {
        b.cursor = to
        return true
    }
    b.cursor += d * (step / dist)
    return false
}

// One tick of a click or a drag: glide, wait, grab; glide, wait, let go.
@(private="file")
hero_click_run :: proc(gs: ^Game_State, g: ^Agent_Goal, k: Hero_Click) {
    w := &g.work
    c := &gs.agent.cmd
    drag := k.carry != .None
    if drag && w.leg == 1 do c.carry = k.carry
    there := hero_cursor_glide(gs, k.from if drag && w.leg == 0 else k.to)
    c.has_cursor, c.cursor = true, gs.hero.cursor
    if !there do return
    w.t += gs.delta_time
    if w.t < HERO_CLICK_PAUSE_S do return
    w.t = 0
    if drag && w.leg == 0 {
        w.leg = 1  // the grab: the stack rides the cursor from the next tick
        return
    }
    w.leg = 0
    c.carry = .None
    c.verb, c.verb_arg, c.feed_count = k.verb, k.arg, k.limit
    gs.agent.first = true
    w.clicks += 1
    if k.verb == .Craft do w.made += 1
    w.last = inventory_count(&gs.player.inventory, w.item)
}

// The next click the goal's window needs, or none: done, or failing with the
// reason set.  A store, feed or withdraw drags whole stacks, as a mouse does,
// and stops once count have moved or a drag moved nothing.
@(private="file")
hero_next_click :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (k: Hero_Click, more: bool) {
    w := &g.work
    m := w.machine
    have := inventory_count(&gs.player.inventory, w.item)
    sd := gs.world.sim_data[grid_idx(int(m.x), int(m.y))]
    #partial switch g.kind {
    case .Craft:
        r := &recipe_table[w.recipe]
        if w.made >= max(w.count, 1) do return
        if !recipe_craftable(gs, r) {
            hero_work_failing(g, fmt.tprintf("no_item: not enough for another %v, %d made", r.result, w.made))
            return
        }
        if gs.ui.craft_selected != w.recipe {
            vis: [len(recipe_table)]int
            n := visible_recipes(gs, &vis)
            card := 0  // shown: the window is the recipe's station and the recipe revealed
            for i in 0 ..< n do if vis[i] == w.recipe do card = i
            x, y := craft_card_rect(gs, card)
            return {to = hero_slot_mid(x, y, CRAFT_CARD), verb = .Pick_Recipe, arg = i32(w.recipe)}, true
        }
        x, y := craft_button_rect(gs)
        return {to = {f32(x) + CRAFT_BTN_W / 2, f32(y) + CRAFT_BTN_H / 2}, verb = .Craft, arg = i32(w.recipe)}, true
    case .Store, .Feed:
        moved := w.base - have
        if w.clicks > 0 && have == w.last {
            if moved == 0 do hero_work_failing(g, fmt.tprintf("full: the %s takes no %v", "barrel" if g.kind == .Store else "furnace", w.item))
            return
        }
        if have == 0 || (w.count > 0 && moved >= w.count) do return
        slot := hero_item_slot(gs, w.item)
        k = {from = hero_bag_point(gs, slot), carry = w.item, arg = i32(slot)}
        if g.kind == .Store {
            k.to, k.verb = hero_barrel_drop(gs, m, w.item), .Store
        } else {
            x, y := smelter_input_rect(gs)
            if smelter_is_fuel(w.item) do x, y = smelter_fuel_rect(gs)
            k.to, k.verb = hero_slot_mid(x, y, SLOT_PX), .Feed
            if w.count > 0 do k.limit = i32(w.count - moved)
        }
        return k, true
    case .Withdraw:
        if get_tile(&gs.world, int(m.x), int(m.y)) == .Smelter {
            if w.clicks > 0 || sd.in_count == 0 do return
            x, y := smelter_input_rect(gs)
            return {from = hero_slot_mid(x, y, SLOT_PX), to = hero_bag_drop(gs, sd.in_item), carry = sd.in_item, verb = .Withdraw}, true
        }
        gained := have - w.base
        if w.clicks > 0 && have == w.last {
            if gained == 0 do hero_work_failing(g, "full: the bag takes no more")
            return
        }
        if w.count > 0 && gained >= w.count do return
        b := barrel_at(gs, gs.level_index, m)
        bslot := hero_barrel_slot(b, w.item) if b != nil else -1
        if bslot < 0 do return
        x, y := barrel_slot_rect(gs, bslot)
        return {from = hero_slot_mid(x, y, SLOT_PX), to = hero_bag_drop(gs, w.item), carry = w.item, verb = .Take, arg = i32(bslot)}, true
    case .Crew_Mode, .Crew_Call, .Crew_Pickup:
        if w.clicks > 0 do return
        btn := Roster_Button.Pickup if g.kind == .Crew_Pickup else .Call
        if g.kind == .Crew_Mode do btn = Roster_Button(int(w.mode))  // the mode buttons mirror Golem_Mode's order
        if !golem_roster_button_enabled(gs, w.golem, btn) {
            hero_work_failing(g, fmt.tprintf("blocked: golem %d's %s is dimmed in the roster", w.golem, roster_button_label[btn]))
            return
        }
        rows, n := golem_roster_rows(gs)
        row := 0
        for r in 0 ..< n do if rows[r] == w.golem do row = r
        x, y := golem_roster_button_rect(gs, row, btn)
        return {to = {f32(x) + f32(ROSTER_BTN_W) / 2, f32(y) + f32(ROSTER_BTN_H) / 2}, verb = .Roster, arg = i32(w.golem) | i32(btn) << 8}, true
    case .Collect:
        if w.clicks > 0 || sd.store_count == 0 do return
        x, y := smelter_tray_rect(gs)
        return {from = hero_slot_mid(x, y, SLOT_PX), to = hero_bag_drop(gs, sd.store_item), carry = sd.store_item, verb = .Collect}, true
    }
    return
}

@(private="file")
hero_work_failing :: proc(g: ^Agent_Goal, why: string) {
    g.work.failing = true
    agent_text_set(&g.reason, why)
}

@(private="file")
hero_slot_mid :: proc(x, y, size: i32) -> [2]f32 {
    return {f32(x) + f32(size) / 2, f32(y) + f32(size) / 2}
}

@(private="file")
hero_bag_point :: proc(gs: ^Game_State, slot: int) -> [2]f32 {
    bx, by := inv_bag_origin(gs)
    return hero_slot_mid(bx + i32(slot % INV_COLS) * SLOT_PX, by + i32(slot / INV_COLS) * SLOT_PX, SLOT_PX)
}

// Where a stack coming into the bag is let go: on the stack it joins, else the
// first empty slot.
@(private="file")
hero_bag_drop :: proc(gs: ^Game_State, it: Item) -> [2]f32 {
    slot := hero_item_slot(gs, it)
    if slot < 0 {
        for s, i in gs.player.inventory.slots {
            if s.count <= 0 {
                slot = i
                break
            }
        }
    }
    return hero_bag_point(gs, max(slot, 0))
}

// And into a barrel: on the stack it joins, else the first empty slot.
@(private="file")
hero_barrel_drop :: proc(gs: ^Game_State, m: [2]i32, it: Item) -> [2]f32 {
    slot := 0
    if b := barrel_at(gs, gs.level_index, m); b != nil {
        slot = hero_barrel_slot(b, it)
        if slot < 0 {
            for s, i in b.slots {
                if s.count <= 0 {
                    slot = i
                    break
                }
            }
        }
        slot = max(slot, 0)
    }
    x, y := barrel_slot_rect(gs, slot)
    return hero_slot_mid(x, y, SLOT_PX)
}
