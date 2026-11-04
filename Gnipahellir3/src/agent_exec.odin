package game

// agent_exec.odin — the goal queue an agent fills, and the executor that turns
// its goals into the per-frame input a keyboard and mouse give.
//
// The game runs on while the agent thinks; the agent sends goals, not frames.
// Each tick update_agent_goals (game_update step 0) takes the running goal, or
// starts the next queued one, and writes this tick's gs.agent.cmd, which
// update_input turns into Input_State and Event_Queue pushes.  It never touches
// world state.  What a goal kind does is a row of agent_goal_kinds.
//
// The queue is fixed: AGENT_GOALS_MAX slots in id order, finished goals kept so
// state can say how they ended, and the oldest finished one gives its slot up
// to a new goal.  A queue with no slot left to give refuses the add.
//
// Windows are worked like a human would: the hero never moves while one is
// open.  A goal that would move with a window open first spends a tick closing
// it, unless the goal works that window, and then it holds still.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "base:runtime"

AGENT_GOALS_MAX  :: 32
AGENT_GOAL_LINE  :: 512  // one goal as recorded; a longer one is refused

Agent_Goal_Status :: enum u8 { Empty, Queued, Running, Done, Failed }
Agent_Goal_Kind   :: enum u8 { Act, Go, Home, Mine, Gather, Craft, Place, Store, Withdraw, Feed, Collect, Fight }
// How a goal came: the old act answers with state when it is done.
Agent_Goal_Via    :: enum u8 { Goal, Act }

Agent_Goal :: struct {
    id:          int,
    status:      Agent_Goal_Status,
    kind:        Agent_Goal_Kind,
    via:         Agent_Goal_Via,
    told:        bool,  // its end has been settled: pushed, recorded, answered
    cmd:         Agent_Command,
    frames:      int,
    frames_left: int,
    first:       bool,  // the next tick it plays is its first
    reason:      Agent_Text,  // why it failed
    to:          [2]i32,  // a go's feet tile
    best:        i32,     // the nearest it has come, in tiles
    stuck_t:     f32,     // seconds since it came nearer
    replanned:   bool,    // stuck long enough to plan again, once
    left:        int,     // tiles the step being dug still has
    no_dig:      bool,    // its walks never dig (a fight's)
    work:        Hero_Work,  // a work goal's plan and progress (agent_work.odin)
    fight:       Hero_Fight,  // a fight goal's target (agent_fight.odin)
    len:         int,
    line:        [AGENT_GOAL_LINE]u8,  // the goal as strict JSON
}

Agent_Goals :: struct {
    slots:        [AGENT_GOALS_MAX]Agent_Goal,  // id order
    n:            int,
    next_id:      int,
    ran:          bool,  // this tick played a goal's frame
    notes:        [HERO_NOTES_MAX]Hero_Note,  // what the hero did with the goals: a ring
    note_count:   int,  // every note ever, so the link knows what it has not pushed
    reflexes_off: bit_set[Hero_Reflex],  // the reflexes the agent switched off
    home:         [2]i32,  // the tile {"cmd":"home","at":[x,y]} marked
    home_level:   int,
    has_home:     bool,
}

// One goal kind: what its parameters are, the add-time check, the start-time
// check against the world as it is then, and one tick of it.
Agent_Goal_Kind_Row :: struct {
    name:   string,
    params: string,
    check:  proc(gs: ^Game_State, o: json.Object) -> (problem: string),
    start:  proc(gs: ^Game_State, g: ^Agent_Goal) -> (ok: bool),  // false leaves the reason in g
    tick:   proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool),
}

@(rodata)
agent_goal_kinds := [Agent_Goal_Kind]Agent_Goal_Kind_Row{
    .Act = {
        name   = "act",
        params = "the act fields: move, frames, jump, down, interact, dismiss, warp, mine, place, use, reclaim, select, ...",
        check  = agent_goal_act_check,
        start  = agent_goal_act_start,
        tick   = agent_goal_act_tick,
    },
    .Go = {
        name   = "go",
        params = "to: [x,y], the tile to stand in (a solid one: the tile on it); walks, jumps, drops, digs with the pick and bridges with blocks from the bag",
        check  = agent_goal_go_check,
        start  = agent_goal_go_start,
        tick   = hero_go_tick,
    },
    .Home = {
        name   = "home",
        params = `none: goes as go does to the tile {"cmd":"home","at":[x,y]} marked on this level, else the surface spawn`,
        check  = agent_goal_home_check,
        start  = agent_goal_home_start,
        tick   = hero_go_tick,
    },
    .Mine = {
        name   = "mine",
        params = `tile: [x,y], or item: an ore name and near: [x,y] (else the hero's feet), the nearest tile that gives it; walks into reach and mines it with the best tool`,
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_mine_goal_tick,
    },
    .Gather = {
        name   = "gather",
        params = "item, count (1): picks up piles of it and mines the tiles that give it until the bag holds count",
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_gather_tick,
    },
    .Craft = {
        name   = "craft",
        params = "item, count (1): walks to the station the recipe needs, opens it and clicks the recipe and CRAFT count times",
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_window_tick,
    },
    .Place = {
        name   = "place",
        params = `item, and at: [x,y] or near: "home" (a free tile round the home goal's tile); walks into reach and sets it down`,
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_place_tick,
    },
    .Store = {
        name   = "store",
        params = "item, count (all), at: [x,y] (else the nearest barrel): drags the bag's stacks of it into the barrel, whole stacks as a mouse does",
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_window_tick,
    },
    .Withdraw = {
        name   = "withdraw",
        params = "at: [x,y] a barrel (item, count (all), whole stacks as a mouse drags them, so it may take more), silo or smelter (its ore back); no at: the nearest barrel holding item",
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_window_tick,
    },
    .Feed = {
        name   = "feed",
        params = "item (ore or wood), count (all), at: [x,y] (else the nearest smelter): drags it into the furnace",
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_window_tick,
    },
    .Collect = {
        name   = "collect",
        params = "at: [x,y] (else the nearest smelter): drags the cast bars from the tray into the bag",
        check  = hero_work_check,
        start  = hero_work_start,
        tick   = hero_window_tick,
    },
    .Fight = {
        name   = "fight",
        params = `kind: an enemy kind (the nearest in sight), or slot: its slot in state; the sword in reach, the fire wand at range with mana, from open ground with a clear line, never digging; backs off at low hp`,
        check  = hero_fight_check,
        start  = hero_fight_start,
        tick   = hero_fight_goal_tick,
    },
}

agent_goal_find_kind :: proc(name: string) -> (Agent_Goal_Kind, bool) {
    for row, k in agent_goal_kinds do if row.name == name do return k, true
    return {}, false
}

// Game_update step 0: this tick's input from the goal queue.
update_agent_goals :: proc(gs: ^Game_State) {
    q := gs.agent.goals
    if q == nil do return
    gs.agent.cmd   = {}
    gs.agent.first = false
    g := agent_goals_current(gs, q)
    if g != nil do q.ran = true
    if agent_screen(gs) == "play" {
        hero_think(gs, q, g)  // the hero's own sense of danger has a say first
        hero_reflexes_run(gs, q)  // and its reflexes the last
    } else if g != nil && agent_goal_kinds[g.kind].tick(gs, g) {
        g.status = .Done
    }
}

// The running goal, or the first queued one that starts.  One that cannot start
// fails.
@(private="file")
agent_goals_current :: proc(gs: ^Game_State, q: ^Agent_Goals) -> ^Agent_Goal {
    for &g in q.slots[:q.n] {
        if g.status == .Running do return &g
        if g.status != .Queued do continue
        if !agent_goal_kinds[g.kind].start(gs, &g) {
            g.status = .Failed
            continue
        }
        g.status = .Running
        return &g
    }
    return nil
}

// Whether any goal is waiting or playing.
agent_goals_busy :: proc(q: ^Agent_Goals) -> bool {
    for &g in q.slots[:q.n] do if g.status == .Queued || g.status == .Running do return true
    return false
}

// The goal playing or next to play.
agent_goals_head :: proc(q: ^Agent_Goals) -> ^Agent_Goal {
    for &g in q.slots[:q.n] do if g.status == .Queued || g.status == .Running do return &g
    return nil
}

// Slots a new goal can have: empty ones, and finished ones already settled.
agent_goals_room :: proc(q: ^Agent_Goals) -> int {
    room := AGENT_GOALS_MAX - q.n
    for &g in q.slots[:q.n] do if (g.status == .Done || g.status == .Failed) && g.told do room += 1
    return room
}

// Queues one goal and gives its id; the caller has checked the room.
agent_goals_push :: proc(q: ^Agent_Goals, kind: Agent_Goal_Kind, via: Agent_Goal_Via, line: string) -> int {
    if q.n == AGENT_GOALS_MAX {
        for &g, i in q.slots[:q.n] {
            if (g.status != .Done && g.status != .Failed) || !g.told do continue
            copy(q.slots[i:q.n], q.slots[i + 1:q.n])
            q.n -= 1
            break
        }
    }
    q.next_id += 1
    g := &q.slots[q.n]
    g^ = {id = q.next_id, status = .Queued, kind = kind, via = via}
    g.len = copy(g.line[:], line)
    q.n += 1
    return g.id
}

// Every window a player works with the mouse: the one list the window rule
// and the sweep that shuts them both read.
agent_window_flags :: proc(ui: ^UI_State) -> [6]^bool {
    return {&ui.show_inventory, &ui.show_crafting, &ui.show_rune_scroll, &ui.show_smelter, &ui.show_barrel, &ui.show_golem_roster}
}

// Whether one is open.  Only play has them: the screens that hold the game up
// take no movement anyway.
agent_window_open :: proc(gs: ^Game_State) -> bool {
    if agent_screen(gs) != "play" do return false
    for open in agent_window_flags(&gs.ui) do if open^ do return true
    return false
}

// The act verbs that work on an open window, and so keep it open.
agent_cmd_keeps_windows :: proc(c: Agent_Command) -> bool {
    #partial switch c.verb {
    case .Feed, .Collect, .Withdraw, .Withdraw_Fuel, .Store, .Take: return true
    }
    return c.has_use || c.has_cursor
}

@(private="file")
agent_goal_act_check :: proc(gs: ^Game_State, o: json.Object) -> string {
    _, _, problem := agent_parse_act(gs, o, false)
    return problem
}

// Judged live, as an act is, now that its world has come.
@(private="file")
agent_goal_act_start :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    value, _ := json.parse_string(string(g.line[:g.len]), parse_integers = true, allocator = context.temp_allocator)
    o, _ := value.(json.Object)
    c, frames, problem := agent_parse_act(gs, o)
    if problem != "" {
        agent_text_set(&g.reason, problem)
        return false
    }
    g.cmd         = c
    g.frames      = frames
    g.frames_left = frames
    g.first       = true
    return true
}

@(private="file")
agent_goal_act_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    c := g.cmd
    if agent_window_open(gs) && (c.move != 0 || c.jump || c.down) {
        if g.first && !agent_cmd_keeps_windows(c) {
            // Stop and close: an empty first tick sweeps the windows shut, and
            // the act starts on the next.
            gs.agent.first = true
            return false
        }
        c.move = 0
        c.jump = false
        c.down = false
    }
    gs.agent.cmd   = c
    gs.agent.first = g.first
    g.first        = false
    g.frames_left -= 1
    return g.frames_left == 0
}

@(rodata)
agent_goal_status_names := [Agent_Goal_Status]string{
    .Empty   = "empty",
    .Queued  = "queued",
    .Running = "running",
    .Done    = "done",
    .Failed  = "failed",
}

// ─── The hero's senses and behaviours ─────────────────────────────────────────
//
// Between the goal queue and the input sits a small utility AI, so the hero acts
// like a player and not a macro: it notices enemies on screen and the drops
// round its feet, stops at a ledge a goal would walk it off, fights or flees a
// threat and goes back to its goal after, and keeps near safe ground with
// nothing queued.  It writes gs.agent.cmd, the same seam a goal does, and
// nothing else; its memory is gs.hero, which a New Game zeroes.
//
// Each tick hero_sense rebuilds the senses, every row of hero_behaviours scores
// from them, and hero_pick keeps the running behaviour unless another beats it
// by HERO_SWITCH_MARGIN after HERO_MIN_HOLD_S, or scores HERO_URGENT_SCORE.  The
// running goal is the Work_Goal row: another winner pauses it and the game says
// so (goal_paused, goal_resumed).  The pacing is a person's: a threat counts
// only after HERO_REACTION_S in sight, and a big drop gets HERO_LEDGE_LOOK_S of
// looking before the step.  gnipa_project/ai_algo.md has the design.

HERO_THREATS_MAX :: 8
HERO_SAFE_MAX    :: 8
HERO_SENSE_REACH :: 4  // danger-map columns each side of the hero
HERO_NOTES_MAX   :: 4

// Feel: first guesses for Glenn to look at.
HERO_REACTION_S       :: f32(0.3)   // in sight this long before a threat is answered
HERO_LEDGE_LOOK_S     :: f32(0.4)   // the look at a drop before stepping, or giving up
HERO_LEDGE_LOOK_TILES :: 3          // a drop this deep or more gets a look
HERO_LEDGE_LOOKAHEAD  :: f32(0.2)   // tiles past the leading edge a step is judged at; over a tick's walk
HERO_MIN_HOLD_S       :: f32(0.5)   // a behaviour runs this long before a rival can take over
HERO_SWITCH_MARGIN    :: f32(10)    // and the rival must beat it by this much
HERO_URGENT_SCORE     :: f32(95)    // a score this high takes over at once
HERO_GOAL_SCORE       :: f32(50)
HERO_IDLE_SCORE       :: f32(10)
HERO_UNARMED_FLEE     :: f32(40)    // added to flee with nothing to fight with: an unhurt hero still runs
HERO_LEDGE_SCORE      :: f32(100)
HERO_THREAT_NEAR      :: f32(5)     // tiles: a threat this close counts in full
HERO_THREAT_FAR       :: f32(12)    // and one this far not at all
HERO_CLOSING_MEMORY_S :: f32(1.5)   // a hunter that stops for breath is still coming
HERO_SWING_S          :: f32(0.45)  // between sword swings; the sword itself allows SWORD_COOLDOWN
HERO_WAND_RANGE       :: f32(8)     // a fire wand shoots at a threat this close
HERO_PASS_BLOWS       :: 1          // blows a threat gets in as the hero runs back past it
HERO_BREAK_STUCK_S    :: f32(0.5)   // a flight with no headway this long: the way is shut
HERO_MAULED_TILES     :: f32(1.5)   // a threat this near across is striking: with the way shut, a fall that leaves the hero standing beats it
HERO_KITE_TILES       :: f32(4)     // with the wand, a threat nearer than this is backed off from as it is shot
HERO_FIGHT_BACK_S     :: f32(1.5)   // the fight_back reflex answers a blow this long
HERO_FIGHT_RETREAT_FRAC :: f32(0.3) // a fight goal backs off under this share of max hp
HERO_SAFE_CLEAR       :: f32(8)     // safe ground has no threat nearer than this
HERO_SAFE_SPACING     :: i32(2)     // tiles between remembered safe spots
HERO_LOOSE_ROWS       :: 4          // rows above the head searched for loose blocks

Hero_Behaviour :: enum u8 { None, Work_Goal, Fight, Flee, Avoid_Ledge, Idle }

// An enemy on screen.
Hero_Threat :: struct {
    slot:     int,
    kind:     Enemy_Kind,
    dist:     f32,
    dx:       f32,  // its centre less the hero's, in tiles
    closing:  bool,  // it came at the hero within HERO_CLOSING_MEMORY_S
    closing_ago: f32,  // seconds since it last came at the hero
    in_line:  bool,  // nothing solid between: it can come at the hero, and be hit
    noticed:  bool,  // answered: in sight HERO_REACTION_S and in line or in reach; once so, kept within HERO_THREAT_FAR
    damage:   int,   // one blow at the hero
    seen_for: f32,   // seconds in sight
}

// One column round the hero, judged from the hero's feet row.
Hero_Column :: struct {
    wall:   bool,  // solid at the feet: a step up, or a wall
    drop:   int,   // open tiles below the step before a landing
    hurts:  int,   // hp the fall rule takes for that drop
    hazard: bool,  // the step or its landing burns
    loose:  bool,  // a block that falls hangs over the head
}

Hero_Senses :: struct {
    threats:   [HERO_THREATS_MAX]Hero_Threat,  // nearest first
    n_threats: int,
    columns:   [2 * HERO_SENSE_REACH + 1]Hero_Column,  // origin_x - HERO_SENSE_REACH upward
    origin_x:  i32,  // the hero's centre column
    feet_y:    i32,
    safe:      [HERO_SAFE_MAX][2]i32,  // ring of the last safe tiles stood on
    n_safe:    int,
    safe_next: int,
}

Hero_Note_Kind :: enum u8 { Paused, Resumed, Idle }

// What the hero tells a client, kept in the goal queue, which outlives a New
// Game as the link does: agent_after_tick pushes each once.
Hero_Note :: struct {
    kind:    Hero_Note_Kind,
    goal:    int,
    why:     Hero_Behaviour,
    threats: int,
}

Hero_Brain :: struct {
    senses:      Hero_Senses,
    scores:      [Hero_Behaviour]f32,
    current:     Hero_Behaviour,
    held:        f32,  // seconds it has run
    paused_goal: int,  // the goal a behaviour has paused, 0 none
    paused_by:   Hero_Behaviour,
    idle_told:   bool,
    ledge_t:     f32,  // seconds looking at this edge
    looked:      [2]i32,  // the edge looked at, safe to step
    has_looked:  bool,
    swing_t:     f32,
    last_hp:     int,  // the hp a tick ago: a drop is a blow
    hurt_slot:   int,  // the enemy that landed the last blow, answered by fight_back
    hurt_t:      f32,  // seconds fight_back still answers it
    break_dir:   i8,  // cornered, running past the threat this way until it is behind
    break_x:     f32, // where the flight last made headway
    break_t:     f32, // seconds since it did
    break_shut:  bool, // a way got nowhere: a fall that leaves the hero standing is taken
    flight_hp:   int,  // the hp when no threat was last in mind: what this flight has cost since
    leap_dir:    i8,   // over a gap this way, held until the feet are down
    potion_t:    f32,  // seconds until the potion reflex may fire again
    path:        Hero_Path,
    nav:         Hero_Nav,
    cursor:      [2]f32,  // the pointer a work goal works windows with, in UI pixels
}

Hero_Behaviour_Row :: struct {
    name:  string,
    score: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32,
    run:   proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal),
}

@(rodata)
hero_behaviours := #partial [Hero_Behaviour]Hero_Behaviour_Row{
    .Work_Goal   = {"goal",  hero_goal_score,  hero_goal_run},
    .Fight       = {"fight", hero_fight_score, hero_fight_run},
    .Flee        = {"flee",  hero_flee_score,  hero_flee_run},
    .Avoid_Ledge = {"ledge", hero_ledge_score, hero_ledge_run},
    .Idle        = {"idle",  hero_idle_score,  hero_idle_run},
}

// One blow at the hero, by kind; a roamer's is its roamer_table bite.  -1: a
// quarter of the hero's max hp, as a Draugr claws.
@(rodata)
hero_threat_damage := #partial [Enemy_Kind]int{
    .Garm          = GARM_BITE_DAMAGE,
    .Undead        = -1,
    .Fire_Sprite   = WAVE_DAMAGE,
    .Builder       = ATTACK_DAMAGE,
    .Raider        = RAIDER_DAMAGE,
    .Vargr         = WAVE_DAMAGE,
}

// One blow of a kind of enemy at the hero.
hero_enemy_damage :: proc(gs: ^Game_State, kind: Enemy_Kind) -> int {
    if roamer_table[kind].cap > 0 do return roamer_table[kind].damage
    if hero_threat_damage[kind] < 0 do return (gs.player.hp_max + 3) / 4
    return hero_threat_damage[kind]
}

// One tick of the brain on the play screen: sense, score, pick, run, tell.
@(private="file")
hero_think :: proc(gs: ^Game_State, q: ^Agent_Goals, g: ^Agent_Goal) {
    b := &gs.hero
    b.swing_t -= gs.delta_time
    hero_sense(gs, b)
    if hero_threat(b) == nil do b.flight_hp = gs.player.hp
    for row, k in hero_behaviours do if row.score != nil do b.scores[k] = row.score(gs, b, g)
    next := hero_pick(b)
    if next != b.current {
        b.current = next
        b.held    = 0
        b.ledge_t = 0
    } else {
        b.held += gs.delta_time
    }
    hero_behaviours[b.current].run(gs, b, g)

    if b.paused_goal != 0 && (g == nil || g.id != b.paused_goal) do b.paused_goal = 0  // it ended while paused
    switch {
    case g != nil && g.status == .Running && b.current != .Work_Goal && b.paused_goal != g.id:
        b.paused_goal = g.id
        b.paused_by   = b.current
        hero_note(q, {kind = .Paused, goal = g.id, why = b.current})
    case g != nil && b.current == .Work_Goal && b.paused_goal == g.id:
        b.paused_goal = 0
        hero_note(q, {kind = .Resumed, goal = g.id, why = b.paused_by})
    }
    if g != nil do b.idle_told = false
    if g == nil && !b.idle_told {
        b.idle_told = true
        hero_note(q, {kind = .Idle, threats = hero_threats_in_sight(b)})
    }
}

@(private="file")
hero_note :: proc(q: ^Agent_Goals, n: Hero_Note) {
    q.notes[q.note_count % HERO_NOTES_MAX] = n
    q.note_count += 1
}

// The behaviour to run this tick, from the scores already in b: the best one,
// held back by the hysteresis rules.  Pure.  A score is 0 only when its cause
// is gone (no goal, the threat past HERO_THREAT_FAR or off the screen, the look
// at a ledge done): every sense a score reads remembers, so one tick's read
// never zeroes it, and a zero hands over without the hold.
hero_pick :: proc(b: ^Hero_Brain) -> Hero_Behaviour {
    top := Hero_Behaviour.None
    for k in Hero_Behaviour do if k != .None && b.scores[k] > b.scores[top] do top = k
    cur := b.current
    if top == cur || top == .None do return cur
    if cur == .None || b.scores[cur] <= 0 do return top  // nothing to hold on to
    s := b.scores[top]
    if s >= HERO_URGENT_SCORE do return top
    if b.held >= HERO_MIN_HOLD_S && s > b.scores[cur] + HERO_SWITCH_MARGIN do return top
    return cur
}

// ─── Senses ───

hero_feet_row :: proc(p: ^Player) -> i32 {
    return i32(p.pos.y + PLAYER_H - 0.001)
}

hero_sense :: proc(gs: ^Game_State, b: ^Hero_Brain) {
    s := &b.senses
    p := &gs.player
    dt := gs.delta_time
    hc := [2]f32{p.pos.x + PLAYER_W * 0.5, p.pos.y + PLAYER_H * 0.5}

    // Threats: every enemy inside the watcher's framing, nearest first, each
    // carrying how long it has been in sight.
    old := s.threats
    old_n := s.n_threats
    s.n_threats = 0
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] do continue
        e := &gs.enemies.data[i]
        size := enemy_body_size(e.kind)
        ec := e.pos + size * 0.5
        d := ec - hc
        if abs(d.x) > f32(AGENT_VIEW_W) * 0.5 || abs(d.y) > f32(AGENT_VIEW_H) * 0.5 do continue
        th := Hero_Threat{
            slot    = i,
            kind    = e.kind,
            dist    = math.sqrt(d.x * d.x + d.y * d.y),
            dx      = d.x,
            in_line = sight_line_clear(&gs.world, hc, ec, skip_ends = true),
            damage  = hero_enemy_damage(gs, e.kind),
        }
        // Coming at the hero: moving toward it, or nearer than a tick ago.
        // Remembered a while, so a stop-and-go hunter reads as coming.
        coming := e.vel.x * -d.x + e.vel.y * -d.y > 0
        th.closing_ago = HERO_CLOSING_MEMORY_S
        for o in old[:old_n] do if o.slot == i && o.kind == e.kind {
            th.seen_for    = o.seen_for + dt
            th.closing_ago = o.closing_ago + dt
            th.noticed     = o.noticed
            coming ||= th.dist < o.dist - 0.001
        }
        if coming do th.closing_ago = 0
        th.closing = th.closing_ago < HERO_CLOSING_MEMORY_S
        // Noticed once, a threat stays in mind while it is near, as it would
        // for a person: a bump that cuts the line for a step does not make the
        // wolf go away.
        th.noticed = th.noticed && th.dist < HERO_THREAT_FAR
        if th.seen_for >= HERO_REACTION_S && (th.in_line || th.dist <= f32(MELEE_REACH)) do th.noticed = true
        at := s.n_threats
        for at > 0 && s.threats[at - 1].dist > th.dist do at -= 1
        if at == HERO_THREATS_MAX do continue
        last := min(s.n_threats, HERO_THREATS_MAX - 1)
        copy(s.threats[at + 1:last + 1], s.threats[at:last])
        s.threats[at] = th
        s.n_threats = last + 1
    }

    // The danger map.
    s.origin_x = i32(hc.x)
    s.feet_y   = hero_feet_row(p)
    for &c, i in s.columns do c = hero_column(&gs.world, int(s.origin_x) + i - HERO_SENSE_REACH, int(s.feet_y))

    // Safe ground: where the hero stands, grounded, nothing burning, no threat near.
    if !p.grounded || hero_here(s).hazard do return
    for &th in s.threats[:s.n_threats] do if th.damage > 0 && th.dist < HERO_SAFE_CLEAR do return
    here := [2]i32{s.origin_x, s.feet_y}
    if s.n_safe > 0 {
        last := s.safe[(s.safe_next + HERO_SAFE_MAX - 1) % HERO_SAFE_MAX]
        if chebyshev(last, here) < HERO_SAFE_SPACING do return
    }
    s.safe[s.safe_next] = here
    s.safe_next = (s.safe_next + 1) % HERO_SAFE_MAX
    s.n_safe = min(s.n_safe + 1, HERO_SAFE_MAX)
}

// Column x as a step from feet row y: what the fall rule in update_player would
// do to a hero walking into it.  Water breaks the fall; lava, steam and the like
// end it in a burn.
hero_column :: proc(w: ^World_Grid, x, y: int) -> (c: Hero_Column) {
    if is_solid(w, x, y) {
        c.wall = true
        return
    }
    land := y + 1
    for in_bounds(x, land) && !is_solid(w, x, land) {
        f := terrain_table[get_tile(w, x, land)].flags
        if .Swimmable in f || .Damaging in f do break
        land += 1
    }
    c.drop = land - y - 1
    landing := terrain_table[get_tile(w, x, land)].flags
    if .Swimmable not_in landing && f32(c.drop) > SAFE_FALL_TILES {
        c.hurts = int((f32(c.drop) - SAFE_FALL_TILES) / FALL_TILES_PER_HP) + 1
    }
    c.hazard = .Damaging in landing || .Damaging in terrain_table[get_tile(w, x, y)].flags ||
               .Damaging in terrain_table[get_tile(w, x, y - 1)].flags
    for i in 0 ..< HERO_LOOSE_ROWS {
        r := y - 2 - i
        if !is_solid(w, x, r) do continue
        c.loose = is_faller(w, x, r)
        break
    }
    return
}

@(private="file")
hero_here :: proc(s: ^Hero_Senses) -> Hero_Column {
    return s.columns[HERO_SENSE_REACH]
}

// The column the hero's leading edge is in, or reaches this tick, walking in
// dir: the ground under it once the trailing edge leaves the last.
@(private="file")
hero_step :: proc(gs: ^Game_State, s: ^Hero_Senses, dir: i8) -> (col: Hero_Column, x: i32) {
    p := &gs.player
    if dir > 0 {
        x = i32(p.pos.x + PLAYER_W + HERO_LEDGE_LOOKAHEAD)
    } else {
        x = i32(math.floor(p.pos.x - HERO_LEDGE_LOOKAHEAD))
    }
    return s.columns[int(x - s.origin_x) + HERO_SENSE_REACH], x
}

// Whether a fall, flight or water saves this hero from any drop.
@(private="file")
hero_falls_safe :: proc(gs: ^Game_State) -> bool {
    when GAME_DEBUG do if gs.debug.fly do return true
    return gs.flight_t > 0 || gs.leaf_fall_t > 0
}

@(private="file")
hero_unsafe :: proc(c: Hero_Column) -> bool {
    return c.hurts > 0 || c.hazard
}

// The nearest threat the hero has noticed.
hero_threat :: proc(b: ^Hero_Brain) -> ^Hero_Threat {
    for &th in b.senses.threats[:b.senses.n_threats] do if th.damage > 0 && th.noticed do return &th
    return nil
}

@(private="file")
hero_threats_in_sight :: proc(b: ^Hero_Brain) -> (n: int) {
    for &th in b.senses.threats[:b.senses.n_threats] do if th.damage > 0 do n += 1
    return
}

// How much a threat presses: 1 near, 0 at the edge of caring, halved for one
// out there that is not coming.
hero_press :: proc(th: ^Hero_Threat) -> f32 {
    u := clamp((HERO_THREAT_FAR - th.dist) / (HERO_THREAT_FAR - HERO_THREAT_NEAR), 0, 1)
    if !th.closing && th.dist > HERO_THREAT_NEAR do u *= 0.5
    return u
}

// A sword, or a fire wand with the mana for a shot.
@(private="file")
hero_armed :: proc(gs: ^Game_State) -> bool {
    return hero_held_or_first(gs, is_melee_weapon) >= 0 ||
           (hero_held_or_first(gs, is_fire_wand) >= 0 && gs.player.mana >= FIRE_ORB_MANA)
}

// The bag slot of a kind of item: the hand's if it holds one, else the first.
hero_held_or_first :: proc(gs: ^Game_State, is: proc(it: Item) -> bool) -> int {
    inv := &gs.player.inventory
    if inv.selected >= 0 && inv.slots[inv.selected].count > 0 && is(inv.slots[inv.selected].item) do return inv.selected
    for s, i in inv.slots do if s.count > 0 && is(s.item) do return i
    return -1
}

// Whether a hero with its feet on s and its centre at hc lands a blow on
// enemy i: the sword in reach, or the wand with mana in range along a clear
// line from hc, where the orb leaves, to its body.
hero_blow_from :: proc(gs: ^Game_State, s: [2]i32, hc: [2]f32, i: int) -> (sword, wand: bool) {
    e := &gs.enemies.data[i]
    ec := e.pos + enemy_body_size(e.kind) * 0.5
    d := ec - hc
    sword = hero_held_or_first(gs, is_melee_weapon) >= 0 && chebyshev(builder_tile(e), s) <= MELEE_REACH
    wand = hero_held_or_first(gs, is_fire_wand) >= 0 && gs.player.mana >= FIRE_ORB_MANA &&
           math.sqrt(d.x * d.x + d.y * d.y) <= HERO_WAND_RANGE && sight_line_clear(&gs.world, hc, ec, skip_ends = true)
    return
}

// One tick of a blow at enemy i, if one lands from where the hero is: the
// sword in reach (unless sword_ok is false), else the fire wand.  A dig left
// the pick in hand: the weapon is taken up first.  The aim is the body's
// centre.  False when no blow lands from here.
hero_strike :: proc(gs: ^Game_State, b: ^Hero_Brain, i: int, sword_ok := true) -> bool {
    p := &gs.player
    e := &gs.enemies.data[i]
    sword, wand := hero_blow_from(gs, player_tile(p), p.pos + [2]f32{PLAYER_W, PLAYER_H} * 0.5, i)
    slot := -1
    if sword && sword_ok {
        slot = hero_held_or_first(gs, is_melee_weapon)
    } else if wand {
        slot = hero_held_or_first(gs, is_fire_wand)
    }
    if slot < 0 do return false
    c := &gs.agent.cmd
    if slot != p.inventory.selected {
        c.verb, c.verb_arg = .Select, i32(slot)
        gs.agent.first = true
        return true
    }
    // A wand fires while the button is held and paces its own shots; a sword
    // swings on a click, which the hero gives every HERO_SWING_S.
    if is_melee_weapon(held_item(p)) {
        if b.swing_t > 0 do return true
        b.swing_t = HERO_SWING_S
        gs.agent.first = true
    }
    c.has_mine = true
    c.mine     = builder_tile(e)
    c.aim      = e.pos + enemy_body_size(e.kind) * 0.5
    return true
}

// The running goal is a fight: it does the fighting and the backing off.
@(private="file")
hero_fighting_goal :: proc(g: ^Agent_Goal) -> bool {
    return g != nil && g.kind == .Fight && g.status == .Running
}

@(private="file")
hero_hp_frac :: proc(gs: ^Game_State) -> f32 {
    return f32(gs.player.hp) / f32(max(gs.player.hp_max, 1))
}

// ─── Moving ───

// A walk in dir that never steps into a drop the fall rule would charge for,
// or into a burn, unless drop_ok, and jumps a wall too high to step up.
hero_walk :: proc(gs: ^Game_State, b: ^Hero_Brain, dir: i8, drop_ok := false) {
    if dir == 0 do return
    if agent_window_open(gs) {
        gs.agent.first = true  // a tick to sweep the windows shut, as a goal does
        return
    }
    s := &b.senses
    col, x := hero_step(gs, s, dir)
    if !drop_ok && !hero_falls_safe(gs) && hero_unsafe(col) do return
    gs.agent.cmd.move = dir
    if col.wall && gs.player.grounded && is_solid(&gs.world, int(x), int(s.feet_y) - 1) {
        gs.agent.cmd.jump = true
        gs.agent.first    = true
    }
}

@(private="file")
hero_walk_to :: proc(gs: ^Game_State, b: ^Hero_Brain, x: f32) {
    hero_walk(gs, b, 1 if x > gs.player.pos.x + PLAYER_W * 0.5 else -1)
}

// Away from th: to the remembered safe spot farthest from it, if one lies
// clear (HERO_SAFE_CLEAR unless asked) from it, else straight away.  Cornered
// at a drop it will not walk, it takes the drop only when the fall costs less
// than running back past the threat would (HERO_PASS_BLOWS of its blows: every
// threat is slower than the hero, so it gets in that many at most), and
// otherwise runs the other way, past the threat.  A way that makes no headway
// for HERO_BREAK_STUCK_S with the threat on it (HERO_MAULED_TILES) is shut: the
// hero turns back, and with the threat on it takes a fall that leaves it
// standing, a blow taken as it goes included.  Never frozen in danger.
hero_get_clear :: proc(gs: ^Game_State, b: ^Hero_Brain, th: ^Hero_Threat, clear := HERO_SAFE_CLEAR) {
    s := &b.senses
    hx := gs.player.pos.x + PLAYER_W * 0.5
    tx := hx + th.dx
    best_x, best_d := hx - math.sign(th.dx) * HERO_THREAT_FAR, clear
    for spot in s.safe[:s.n_safe] {
        sx := f32(spot.x) + 0.5
        if math.sign(sx - hx) == math.sign(th.dx) do continue  // never back past it
        if d := abs(sx - tx); d > best_d do best_x, best_d = sx, d
    }
    if th.dist >= clear do b.break_shut = false  // got clear: the next corner is weighed afresh
    if gs.player.grounded do b.leap_dir = 0
    if b.leap_dir != 0 {
        hero_walk(gs, b, b.leap_dir, drop_ok = true)  // in the air over a gap: on to the far side
        return
    }
    dir: i8
    if b.break_dir != 0 && math.sign(th.dx) != -f32(b.break_dir) {
        dir = b.break_dir  // still on the way past it
    } else {
        b.break_dir = 0
        if abs(best_x - hx) < 0.3 do return  // at rest by choice
        dir = 1 if best_x > hx else -1
    }
    // A way that gives no headway for HERO_BREAK_STUCK_S with the threat on
    // the hero is shut: the other way, where a fall that leaves the hero
    // standing beats a mauling.  With the threat still off it keeps at it.
    b.break_t += gs.delta_time
    if abs(hx - b.break_x) > 0.5 do b.break_x, b.break_t = hx, 0
    if b.break_t >= HERO_BREAK_STUCK_S && hero_dig_out(gs, b, dir) do return
    if b.break_t >= HERO_BREAK_STUCK_S && abs(th.dx) < HERO_MAULED_TILES {
        dir = -dir
        b.break_dir, b.break_x, b.break_t, b.break_shut = dir, hx, 0, true
    }
    if col, _ := hero_step(gs, s, dir); !hero_falls_safe(gs) && hero_unsafe(col) {
        if _, _, ok := hero_gap_landing(&gs.world, hero_feet(&gs.player), i32(dir)); ok {
            hero_walk(gs, b, dir, drop_ok = true)  // over it, as a player jumps a gap
            b.leap_dir = dir
            gs.agent.cmd.jump = true
            gs.agent.first    = true
            return
        }
        if !col.hazard && col.hurts < gs.player.hp && (col.hurts < th.damage * HERO_PASS_BLOWS + max(b.flight_hp - gs.player.hp, 0) || b.break_shut && abs(th.dx) < HERO_MAULED_TILES && col.hurts + th.damage < gs.player.hp) {
            hero_walk(gs, b, dir, drop_ok = true)  // a fall that costs less than the blows, or than a mauling
            return
        }
        dir = -dir
        b.break_dir, b.break_x, b.break_t = dir, hx, 0
    }
    hero_walk(gs, b, dir)
}

// Stuck in flight with a pick and nothing to fight with: the tile in the way,
// at head height or at the feet, dug to open a way out.  A side dig never
// takes the hero's floor.  False when nothing in the way yields to the pick.
@(private="file")
hero_dig_out :: proc(gs: ^Game_State, b: ^Hero_Brain, dir: i8) -> bool {
    pick := hero_item_slot(gs, .Pickaxe)
    if pick < 0 || hero_armed(gs) do return false
    s := &b.senses
    _, x := hero_step(gs, s, dir)
    for y in ([2]i32{s.feet_y - 1, s.feet_y}) {
        t := [2]i32{x, y}
        tile := get_tile(&gs.world, int(x), int(y))
        if .Mineable not_in terrain_table[tile].flags || is_structure_tile[tile] do continue  // the pick's own rule
        c := &gs.agent.cmd
        if held_item(&gs.player) != .Pickaxe {
            c.verb, c.verb_arg = .Select, i32(pick)
            gs.agent.first = true
            return true
        }
        c.has_mine, c.mine, c.aim = true, t, {f32(x) + 0.5, f32(y) + 0.5}
        return true
    }
    return false
}

// ─── Behaviours ───

// A goal waits while an enemy the hero cannot fight hunts it: flee, which
// scores whenever a hunter is near, takes over until the hunter is gone.
@(private="file")
hero_goal_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    return HERO_GOAL_SCORE if g != nil && !hero_hunted(gs, b) else 0
}

// Unarmed, with a noticed enemy coming at it inside HERO_THREAT_FAR.
@(private="file")
hero_hunted :: proc(gs: ^Game_State, b: ^Hero_Brain) -> bool {
    th := hero_threat(b)
    return th != nil && th.closing && th.dist < HERO_THREAT_FAR && !hero_armed(gs)
}

@(private="file")
hero_goal_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    if agent_goal_kinds[g.kind].tick(gs, g) do g.status = .Done
}

@(private="file")
hero_fight_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    th := hero_threat(b)
    if th == nil || !hero_armed(gs) || hero_fighting_goal(g) do return 0
    return hero_press(th) * (30 + 60 * hero_hp_frac(gs))
}

@(private="file")
hero_fight_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    th := hero_threat(b)
    if hero_strike(gs, b, th.slot) {
        // The wand keeps its distance: too near, the hero backs off shooting.
        if is_fire_wand(held_item(&gs.player)) && th.dist < HERO_KITE_TILES do hero_get_clear(gs, b, th)
        return
    }
    hero_walk_to(gs, b, gs.player.pos.x + PLAYER_W * 0.5 + th.dx)  // into reach, or range
}

@(private="file")
hero_flee_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    th := hero_threat(b)
    if th == nil || hero_fighting_goal(g) do return 0
    s := 30 + 60 * (1 - hero_hp_frac(gs))
    if !hero_armed(gs) do s += HERO_UNARMED_FLEE
    // Once running, the hero keeps running until the threat is out of
    // HERO_THREAT_FAR: no turning back toward it at the margin.
    if b.current == .Flee && th.dist < HERO_THREAT_FAR do return s
    return hero_press(th) * s
}

@(private="file")
hero_flee_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    th := hero_threat(b)
    hero_get_clear(gs, b, th)
    hero_strike(gs, b, th.slot, sword_ok = false)  // a wand shoots back as the hero runs
}

// A goal walking the hero to the edge of a drop: stop, look, then step if the
// fall is free and give the goal up if it is not.
@(private="file")
hero_ledge_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    if g == nil || g.status != .Running || g.cmd.move == 0 || (g.first && g.cmd.jump) do return 0
    if hero_falls_safe(gs) do return 0
    // A threat that takes over from the goal comes first, a look begun or not:
    // fight and flee walk into no step that hurts.  It takes over as hero_pick
    // would let it take over from the goal; the look itself holds nothing.
    rival := max(hero_fight_score(gs, b, g), hero_flee_score(gs, b, g))
    held := b.held if b.current == .Work_Goal else HERO_MIN_HOLD_S
    if held >= HERO_MIN_HOLD_S && rival > HERO_GOAL_SCORE + HERO_SWITCH_MARGIN do return 0
    col, x := hero_step(gs, &b.senses, g.cmd.move)
    looked := b.has_looked && b.looked == {x, b.senses.feet_y}
    if b.current == .Avoid_Ledge && !looked do return HERO_LEDGE_SCORE  // a look, once begun, runs to its end
    if !gs.player.grounded do return 0
    if hero_unsafe(col) do return HERO_LEDGE_SCORE
    if col.drop < HERO_LEDGE_LOOK_TILES || looked do return 0
    return HERO_LEDGE_SCORE
}

@(private="file")
hero_ledge_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    b.ledge_t += gs.delta_time
    if b.ledge_t < HERO_LEDGE_LOOK_S do return
    col, x := hero_step(gs, &b.senses, g.cmd.move)
    b.looked     = {x, b.senses.feet_y}
    b.has_looked = true
    if !hero_unsafe(col) do return
    g.status = .Failed
    if col.hazard {
        agent_text_set(&g.reason, "a burn ahead")
    } else {
        agent_text_set(&g.reason, fmt.tprintf("a %d-tile drop ahead", col.drop))
    }
}

@(private="file")
hero_idle_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    return HERO_IDLE_SCORE if g == nil else 0
}

// Nothing queued: stand, unless a threat is about or the ground burns, and then
// make for safe ground.
@(private="file")
hero_idle_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    if th := hero_threat(b); th != nil {
        hero_get_clear(gs, b, th)
        return
    }
    s := &b.senses
    if !hero_here(s).hazard || s.n_safe == 0 do return
    spot := s.safe[(s.safe_next + HERO_SAFE_MAX - 1) % HERO_SAFE_MAX]
    hero_walk_to(gs, b, f32(spot.x) + 0.5)
}

@(rodata)
hero_note_names := [Hero_Note_Kind]string{
    .Paused  = "goal_paused",
    .Resumed = "goal_resumed",
    .Idle    = "idle",
}

// ─── Going somewhere: the go and home goals ───────────────────────────────────
//
// {"do":"go","to":[x,y]} and {"do":"home"} walk the hero to a tile as a player
// would: hero_plan searches the feet tiles round the hero (a fixed window, a
// fixed budget) for walks, step-ups, jumps, gap jumps and drops, a block from
// the bag set down as a bridge, and digs with the pick (a tunnel, a step cut
// up, a stair down: one down and one across, never a shaft).  Each step has a
// price: a drop costs nothing to SAFE_FALL_TILES and HERO_NAV_HP_COST per hp
// the fall rule takes after, and one that would kill or leave the hero under
// the reflex line is never taken; burning and water tiles are never stood in,
// and a pond or lava rim is never dug.  hero_go_tick follows the path through
// gs.agent.cmd alone, replans when knocked off it or stuck, and fails the goal
// with no_route (nothing nearer can be reached), blocked (no headway for
// HERO_GO_STUCK_S) or hazard (the tile asked for burns or drowns).

HERO_NAV_W      :: 64  // the search window round the hero, in tiles
HERO_NAV_H      :: 48
HERO_NAV_NODES  :: HERO_NAV_W * HERO_NAV_H
HERO_NAV_OPEN   :: 4 * HERO_NAV_NODES
HERO_NAV_BUDGET :: 4000  // nodes one search expands at most
HERO_PATH_MAX   :: 64    // a longer path keeps the start of it, and is planned again from its end
HERO_GAP_MAX    :: 4     // a running jump lands this many columns over at most

// Feel: first guesses for Glenn to look at.
HERO_GO_REPLAN_S     :: f32(1.5)  // no headway this long: plan again
HERO_GO_STUCK_S      :: f32(5)    // and this long: blocked
HERO_NAV_JUMP_COST   :: f32(2)    // steps a jump is worth, over its walk
HERO_NAV_DIG_COST    :: f32(3)    // per tile dug
HERO_NAV_BRIDGE_COST :: f32(4)    // per block set down
HERO_NAV_HP_COST     :: f32(20)   // per hp a fall takes
HERO_LOW_HP_FRAC     :: f32(0.3)  // the reflex line: a potion under it, no fall that ends below it
HERO_POTION_COOLDOWN_S :: f32(1)  // between potions

Hero_Move :: enum u8 { Walk, Jump, Drop, Gap, Dig, Bridge }

Hero_Step :: struct {
    from, to: [2]i32,  // feet tiles
    move:     Hero_Move,
}

Hero_Path :: struct {
    steps: [HERO_PATH_MAX]Hero_Step,
    n, at: int,
    goal:  int,  // the goal it was planned for
}

// One search's scratch, sized once and kept in gs.hero.
Hero_Nav :: struct {
    g:       [HERO_NAV_NODES]f32,
    parent:  [HERO_NAV_NODES]i16,
    move:    [HERO_NAV_NODES]Hero_Move,
    bridges: [HERO_NAV_NODES]u8,
    seen:    [HERO_NAV_NODES]bool,
    closed:  [HERO_NAV_NODES]bool,
    open:    [HERO_NAV_OPEN]A_Open,
}

hero_feet :: proc(p: ^Player) -> [2]i32 {
    return {i32(p.pos.x + PLAYER_W * 0.5), hero_feet_row(p)}
}

hero_wet_or_burning :: proc(w: ^World_Grid, x, y: i32) -> bool {
    f := terrain_table[get_tile(w, int(x), int(y))].flags
    return .Damaging in f || .Swimmable in f
}

// A tile the body can be in: not solid, not burning, not water.
hero_open :: proc(w: ^World_Grid, x, y: i32) -> bool {
    return !is_solid(w, int(x), int(y)) && !hero_wet_or_burning(w, x, y)  // outside the level reads as stone
}

// A feet tile the hero can stand on.
hero_stand :: proc(w: ^World_Grid, t: [2]i32) -> bool {
    return hero_open(w, t.x, t.y) && hero_open(w, t.x, t.y - 1) && is_solid(w, int(t.x), int(t.y + 1))
}

// Next to water or a burn: dug, it lets the pond or the lava in.
hero_rim :: proc(w: ^World_Grid, t: [2]i32) -> bool {
    for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do if hero_wet_or_burning(w, t.x + d.x, t.y + d.y) do return true
    return false
}

// A tile the hero may dig: the pick works it, and it is no rim.
hero_diggable :: proc(gs: ^Game_State, t: [2]i32, has_pick: bool) -> bool {
    if !in_bounds(int(t.x), int(t.y)) do return false
    return pick_workable(gs, t, has_pick) && !hero_rim(&gs.world, t)
}

// The tiles a dig step clears, by its rise: a tunnel, a step cut up (and the
// headroom to step into it), a stair down (one down, one across).
hero_dig_tiles :: proc(from, to: [2]i32) -> (tiles: [3][2]i32, n: int) {
    x := to.x
    switch to.y - from.y {
    case 0:  return {{x, to.y}, {x, to.y - 1}, {}}, 2
    case -1: return {{x, to.y}, {x, to.y - 1}, {from.x, from.y - 2}}, 3
    case:    return {{x, from.y - 1}, {x, from.y}, {x, to.y}}, 3
    }
}

// Where a running jump from feet tile a over the gap on side d lands: the
// first stand within HERO_GAP_MAX columns, with the arc's three rows open
// over the gap and head room at both ends.
hero_gap_landing :: proc(w: ^World_Grid, a: [2]i32, d: i32) -> (l: [2]i32, k: i32, ok: bool) {
    if !hero_open(w, a.x, a.y - 2) do return
    for k = 2; k <= HERO_GAP_MAX; k += 1 {
        m := [2]i32{a.x + d * (k - 1), a.y}
        if !hero_open(w, m.x, m.y) || !hero_open(w, m.x, m.y - 1) || !hero_open(w, m.x, m.y - 2) do return
        if l = {a.x + d * k, a.y}; hero_stand(w, l) && hero_open(w, l.x, l.y - 2) do return l, k, true
    }
    return
}

// Whether a fall that takes hurts hp leaves the hero above the reflex line.
hero_fall_ok :: proc(gs: ^Game_State, hurts: int) -> bool {
    if hurts == 0 do return true
    left := gs.player.hp - hurts
    return left > 0 && f32(left) >= HERO_LOW_HP_FRAC * f32(gs.player.hp_max)
}

// The bag slot whose blocks bridge: the first that sets down a solid tile.
hero_block_slot :: proc(gs: ^Game_State) -> int {
    for s, i in gs.player.inventory.slots {
        if s.count <= 0 do continue
        t := item_table[s.item].place_tile
        if t != .Air && !is_structure_tile[t] && .Solid in terrain_table[t].flags do return i
    }
    return -1
}

hero_item_slot :: proc(gs: ^Game_State, it: Item) -> int {
    for s, i in gs.player.inventory.slots do if s.item == it && s.count > 0 do return i
    return -1
}

@(private="file")
hero_nav_index :: proc(o, t: [2]i32) -> int {
    r := t - o
    if r.x < 0 || r.y < 0 || r.x >= HERO_NAV_W || r.y >= HERO_NAV_H do return -1
    return int(r.y) * HERO_NAV_W + int(r.x)
}

@(private="file")
hero_nav_h :: proc(a, b: [2]i32) -> f32 {
    return f32(abs(a.x - b.x)) + 0.5 * f32(abs(a.y - b.y))
}

// A path from feet tile from toward to, into out: to itself when the search
// reaches it, else the tile nearest it the search found.  An empty path: no
// tile nearer than from.
hero_plan :: proc(gs: ^Game_State, from, to: [2]i32, out: ^Hero_Path, dig := true) -> (reached: bool) {
    n := &gs.hero.nav
    w := &gs.world
    o := [2]i32{clamp(from.x - HERO_NAV_W / 2, 0, GRID_W - HERO_NAV_W), clamp(from.y - HERO_NAV_H / 2, 0, GRID_H - HERO_NAV_H)}
    n.seen   = {}
    n.closed = {}
    out.n, out.at = 0, 0
    s := hero_nav_index(o, from)
    if s < 0 do return false
    has_pick := dig && hero_item_slot(gs, .Pickaxe) >= 0
    blocks := 0
    if b := hero_block_slot(gs); b >= 0 do blocks = gs.player.inventory.slots[b].count

    size, work := 0, 0
    n.g[s], n.seen[s], n.bridges[s] = 0, true, 0
    astar_open_push(n.open[:], &size, {hero_nav_h(from, to), i16(s)}, &work)
    best, best_h := s, hero_nav_h(from, to)
    expanded := 0
    for size > 0 && expanded < HERO_NAV_BUDGET {
        i := int(astar_open_pop(n.open[:], &size, &work).node)
        if n.closed[i] do continue
        n.closed[i] = true
        expanded += 1
        a := o + {i32(i % HERO_NAV_W), i32(i / HERO_NAV_W)}
        if a == to {
            best, reached = i, true
            break
        }
        if h := hero_nav_h(a, to); h < best_h || (h == best_h && n.g[i] < n.g[best]) do best, best_h = i, h
        x, y := a.x, a.y
        nb := n.bridges[i]
        for d in ([2]i32{-1, 1}) {
            f := [2]i32{x + d, y}
            if hero_stand(w, f) do hero_nav_relax(n, &size, o, i, f, 1, .Walk, nb, to)
            if up := ([2]i32{x + d, y - 1}); hero_stand(w, up) && hero_open(w, x, y - 2) {
                hero_nav_relax(n, &size, o, i, up, 1.5, .Walk, nb, to)
            }
            if up := ([2]i32{x + d, y - 2}); hero_stand(w, up) && hero_open(w, x, y - 2) && hero_open(w, x, y - 3) {
                hero_nav_relax(n, &size, o, i, up, 2 + HERO_NAV_JUMP_COST, .Jump, nb, to)
            }
            if hero_open(w, f.x, f.y) && hero_open(w, f.x, f.y - 1) && !is_solid(w, int(f.x), int(f.y + 1)) {
                // Off the edge: a drop to wherever it lands, or a running jump
                // over the gap, or a block set down to walk on.
                col := hero_column(w, int(f.x), int(f.y))
                land := [2]i32{f.x, f.y + i32(col.drop)}
                if !col.hazard && hero_stand(w, land) && hero_fall_ok(gs, col.hurts) {
                    hero_nav_relax(n, &size, o, i, land, 1 + 0.3 * f32(col.drop) + HERO_NAV_HP_COST * f32(col.hurts), .Drop, nb, to)
                }
                if l, k, ok := hero_gap_landing(w, a, d); ok {
                    hero_nav_relax(n, &size, o, i, l, f32(k) + HERO_NAV_JUMP_COST, .Gap, nb, to)
                }
                under := get_tile(w, int(f.x), int(f.y + 1))
                if int(nb) < blocks && (under == .Air || under == .Void) {
                    hero_nav_relax(n, &size, o, i, f, 1 + HERO_NAV_BRIDGE_COST, .Bridge, nb + 1, to)
                }
            }
            for dt in ([3][2]i32{{x + d, y}, {x + d, y - 1}, {x + d, y + 1}}) {
                tiles, k := hero_dig_tiles(a, dt)
                floor := dt + {0, 1}
                if !is_solid(w, int(floor.x), int(floor.y)) do continue
                dug, ok := 0, true
                for t in tiles[:k] {
                    switch {
                    case hero_open(w, t.x, t.y):
                    case is_solid(w, int(t.x), int(t.y)) && hero_diggable(gs, t, has_pick): dug += 1
                    case: ok = false
                    }
                }
                if ok && dug > 0 do hero_nav_relax(n, &size, o, i, dt, 1 + HERO_NAV_DIG_COST * f32(dug), .Dig, nb, to)
            }
        }
    }

    // The chain back from best, kept from the start end.
    length := 0
    for j := best; j != s; j = int(n.parent[j]) do length += 1
    pos := length - 1
    for j := best; j != s; j = int(n.parent[j]) {
        if pos < HERO_PATH_MAX {
            p := int(n.parent[j])
            out.steps[pos] = {
                from = o + {i32(p % HERO_NAV_W), i32(p / HERO_NAV_W)},
                to   = o + {i32(j % HERO_NAV_W), i32(j / HERO_NAV_W)},
                move = n.move[j],
            }
        }
        pos -= 1
    }
    out.n = min(length, HERO_PATH_MAX)
    return reached && length <= HERO_PATH_MAX
}

@(private="file")
hero_nav_relax :: proc(n: ^Hero_Nav, size: ^int, o: [2]i32, i: int, b: [2]i32, cost: f32, m: Hero_Move, nb: u8, to: [2]i32) {
    j := hero_nav_index(o, b)
    if j < 0 do return
    g := n.g[i] + cost
    if n.seen[j] && g >= n.g[j] do return
    n.g[j], n.parent[j], n.move[j], n.bridges[j], n.seen[j] = g, i16(i), m, nb, true
    work := 0
    if size^ < HERO_NAV_OPEN do astar_open_push(n.open[:], size, {g + hero_nav_h(b, to), i16(j)}, &work)
}

// ─── The goal rows ───

@(private="file")
agent_goal_go_check :: proc(gs: ^Game_State, o: json.Object) -> string {
    if _, _, _, ok := agent_tile(o, "to"); !ok do return fmt.tprintf("go needs to:[x,y] inside the %dx%d level", GRID_W, GRID_H)
    return ""
}

@(private="file")
agent_goal_go_start :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    value, _ := json.parse_string(string(g.line[:g.len]), parse_integers = true, allocator = context.temp_allocator)
    o, _ := value.(json.Object)
    to, _, _, _ := agent_tile(o, "to")
    return hero_go_start(gs, g, to)
}

@(private="file")
agent_goal_home_check :: proc(gs: ^Game_State, o: json.Object) -> string {
    return ""
}

// Home: the tile the agent marked on this level, else the spawn on the surface.
@(private="file")
agent_goal_home_start :: proc(gs: ^Game_State, g: ^Agent_Goal) -> bool {
    q := gs.agent.goals
    switch {
    case q != nil && q.has_home && q.home_level == gs.level_index:
        return hero_go_start(gs, g, q.home)
    case gs.level_index == LEVEL_SURFACE:
        return hero_go_start(gs, g, hero_spawn_feet())
    }
    agent_text_set(&g.reason, "no_route: no home on this level")
    return false
}

// The feet tile of the surface spawn.
hero_spawn_feet :: proc() -> [2]i32 {
    p := SURFACE_HOME_POS
    return {i32(p.x + PLAYER_W * 0.5), i32(p.y + PLAYER_H - 0.001)}
}

// A solid tile asked for means the one standing on it.
@(private="file")
hero_go_start :: proc(gs: ^Game_State, g: ^Agent_Goal, to: [2]i32) -> bool {
    w := &gs.world
    to := to
    if is_solid(w, int(to.x), int(to.y)) && in_bounds(int(to.x), int(to.y - 1)) do to.y -= 1
    if !hero_open(w, to.x, to.y) && !is_solid(w, int(to.x), int(to.y)) {
        agent_text_set(&g.reason, "hazard")
        return false
    }
    g.to      = to
    g.best    = max(i32)
    g.stuck_t = 0
    return true
}

// One tick of a go: follow the path, plan when there is none or it has gone
// stale, and judge the headway.
hero_go_tick :: proc(gs: ^Game_State, g: ^Agent_Goal) -> (last: bool) {
    b := &gs.hero
    p := &gs.player
    w := &gs.world
    path := &b.path
    feet := hero_feet(p)
    if p.grounded && feet == g.to do return true
    if agent_window_open(gs) {
        gs.agent.first = true  // a still tick sweeps the windows shut, as for any goal
        return false
    }

    if d := abs(feet.x - g.to.x) + abs(feet.y - g.to.y); d < g.best {
        g.best, g.stuck_t, g.replanned = d, 0, false
    } else {
        g.stuck_t += gs.delta_time
    }
    if g.stuck_t >= HERO_GO_STUCK_S {
        g.status = .Failed
        agent_text_set(&g.reason, "blocked")
        return false
    }
    stale := path.goal != g.id || path.at >= path.n
    if g.stuck_t >= HERO_GO_REPLAN_S && !g.replanned {
        stale, g.replanned = true, true
    }
    if p.grounded && !stale {
        st := path.steps[path.at]
        if feet == st.to {
            path.at += 1
            stale = path.at >= path.n
        } else {
            // Off the box between the step's ends: knocked off it.  Inside it
            // is on the way, as at an edge that still holds the body up.
            a, z := st.from, st.to
            stale = feet.x < min(a.x, z.x) || feet.x > max(a.x, z.x) || feet.y < min(a.y, z.y) || feet.y > max(a.y, z.y)
        }
    }
    if stale {
        if !p.grounded do return false  // plan from the ground
        hero_plan(gs, feet, g.to, path, dig = !g.no_dig)
        path.goal = g.id
        if path.n == 0 {
            g.status = .Failed
            agent_text_set(&g.reason, "no_route")
            return false
        }
    }

    st := path.steps[path.at]
    c := &gs.agent.cmd
    switch st.move {
    case .Dig:
        tiles, k := hero_dig_tiles(st.from, st.to)
        left := 0
        for t in tiles[:k] do if is_solid(w, int(t.x), int(t.y)) do left += 1
        if left < g.left do g.stuck_t = 0  // a tile dug is headway
        g.left = left
        for t in tiles[:k] {
            if !is_solid(w, int(t.x), int(t.y)) do continue
            // The pick if the bag has one; without, wood by hand, with no
            // sword or wand in it to swing instead.
            held := held_item(p)
            pick := hero_item_slot(gs, .Pickaxe)
            if (pick >= 0 && held != .Pickaxe) || (pick < 0 && (is_melee_weapon(held) || is_fire_wand(held) || is_command_wand(held))) {
                c.verb, c.verb_arg = .Select, i32(pick)
                gs.agent.first = true
                return false
            }
            c.has_mine = true
            c.mine     = t
            c.aim      = {f32(t.x) + 0.5, f32(t.y) + 0.5}
            return false
        }
    case .Bridge:
        under := st.to + {0, 1}
        if !is_solid(w, int(under.x), int(under.y)) {
            if feet != st.from {
                hero_go_toward(gs, st.from)
                return false
            }
            slot := hero_block_slot(gs)
            if slot < 0 {
                path.n = 0  // the bag ran out: plan again
                return false
            }
            c.verb, c.verb_arg = .Select, i32(slot)
            c.has_place = true
            c.place     = under
            c.aim       = {f32(under.x) + 0.5, f32(under.y) + 0.5}
            gs.agent.first = true
            return false
        }
    case .Walk, .Jump, .Drop, .Gap:
    }
    hero_go_toward(gs, st.to)
    if !p.grounded do return false
    col, x := hero_step(gs, &b.senses, c.move)
    #partial switch st.move {
    case .Jump:
        // The landing's own ground is at head height ahead: a wall, or a
        // ledge over an open foot of the shaft dug to get here.
        if is_solid(w, int(x), int(b.senses.feet_y) - 1) do c.jump = true
    case .Gap:
        if !col.wall && col.drop > 0 do c.jump = true
    }
    if c.jump do gs.agent.first = true
    return false
}

// The key toward tile t's middle.  A step ends as the feet reach its tile, so
// this never has to stop.
@(private="file")
hero_go_toward :: proc(gs: ^Game_State, t: [2]i32) {
    gs.agent.cmd.move = 1 if f32(t.x) + 0.5 > gs.player.pos.x + PLAYER_W * 0.5 else -1
}

// ─── Reflexes ───
//
// Under every goal, after the brain has had its say, each reflex the agent has
// left on ({"cmd":"reflexes"}) may change this tick's input: off a burn or out
// of water, a potion under the reflex line, no dig of the floor when the fall
// would kill, no dig of a pond or lava rim.

Hero_Reflex :: enum u8 { Leave_Hazard, Potion, Floor_Dig, Rim_Dig, Fight_Back }

@(rodata)
hero_reflexes := [Hero_Reflex]struct {
    name: string,
    run:  proc(gs: ^Game_State, b: ^Hero_Brain),
}{
    .Leave_Hazard = {"leave_hazard", hero_reflex_leave},
    .Potion       = {"potion",       hero_reflex_potion},
    .Floor_Dig    = {"floor_dig",    hero_reflex_floor},
    .Rim_Dig      = {"rim_dig",      hero_reflex_rim},
    .Fight_Back   = {"fight_back",   hero_reflex_fight_back},
}

@(private="file")
hero_reflexes_run :: proc(gs: ^Game_State, q: ^Agent_Goals) {
    b := &gs.hero
    b.potion_t = max(b.potion_t - gs.delta_time, 0)
    for r, k in hero_reflexes do if k not_in q.reflexes_off do r.run(gs, b)
}

// In a burn or in water, or in the air over one: for the nearest column either
// side the body can be in, walking and jumping, until out.
@(private="file")
hero_reflex_leave :: proc(gs: ^Game_State, b: ^Hero_Brain) {
    w := &gs.world
    f := hero_feet(&gs.player)
    over := !gs.player.grounded && hero_wet_or_burning(w, f.x, f.y + 1)  // a jump out not yet clear of it
    if !hero_wet_or_burning(w, f.x, f.y) && !over do return
    blocked: [2]bool  // a wall that side: no way out past it
    for k in i32(1) ..= HERO_SENSE_REACH {
        for d, side in ([2]i8{-1, 1}) {
            if blocked[side] do continue
            x := f.x + i32(d) * k
            level := hero_open(w, x, f.y) && hero_open(w, x, f.y - 1) && !hero_wet_or_burning(w, x, f.y + 1)
            // Ground a jump reaches: one up or two.
            step := is_solid(w, int(x), int(f.y)) &&
                    (hero_open(w, x, f.y - 1) && hero_open(w, x, f.y - 2) ||
                     hero_open(w, x, f.y - 2) && hero_open(w, x, f.y - 3))
            if !level && !step {
                blocked[side] = is_solid(w, int(x), int(f.y)) || is_solid(w, int(x), int(f.y - 1))
                continue
            }
            gs.agent.cmd.move = d
            if gs.player.grounded {
                gs.agent.cmd.jump = true
                gs.agent.first    = true
            }
            return
        }
    }
}

@(private="file")
hero_reflex_potion :: proc(gs: ^Game_State, b: ^Hero_Brain) {
    p := &gs.player
    c := &gs.agent.cmd
    if b.potion_t > 0 || c.verb != .None || f32(p.hp) >= HERO_LOW_HP_FRAC * f32(p.hp_max) do return
    slot := hero_item_slot(gs, .Potion_Health)
    if slot < 0 do return
    c.verb, c.verb_arg = .Equip, i32(slot)
    gs.agent.first = true
    b.potion_t = HERO_POTION_COOLDOWN_S
}

// A pick or a wand at work on terrain; a weapon's swing is not a dig.
@(private="file")
hero_digging :: proc(gs: ^Game_State) -> bool {
    held := held_item(&gs.player)
    c := &gs.agent.cmd
    return c.has_mine && !is_melee_weapon(held) && !is_fire_wand(held) && !is_command_wand(held)
}

// The floor under the body, when the fall through it would kill or burn.
@(private="file")
hero_reflex_floor :: proc(gs: ^Game_State, b: ^Hero_Brain) {
    if !hero_digging(gs) do return
    p := &gs.player
    t := gs.agent.cmd.mine
    if t.y != hero_feet_row(p) + 1 || t.x < i32(p.pos.x) || t.x > i32(p.pos.x + PLAYER_W - 0.001) do return
    _, hurts, burns := hero_dig_fall(&gs.world, t)
    if hurts >= p.hp || burns do gs.agent.cmd.has_mine = false
}

// The fall a body standing on tile t takes once t is dug out: the tiles it
// drops, the hp the fall rule takes for them (water breaks the fall), and
// whether it lands in a burn.
hero_dig_fall :: proc(w: ^World_Grid, t: [2]i32) -> (drop, hurts: int, burns: bool) {
    land := int(t.y) + 1
    for in_bounds(int(t.x), land) && !is_solid(w, int(t.x), land) {
        f := terrain_table[get_tile(w, int(t.x), land)].flags
        if .Swimmable in f || .Damaging in f do break
        land += 1
    }
    drop = land - int(t.y)
    landing := terrain_table[get_tile(w, int(t.x), land)].flags
    if .Swimmable not_in landing && f32(drop) > SAFE_FALL_TILES do hurts = int((f32(drop) - SAFE_FALL_TILES) / FALL_TILES_PER_HP) + 1
    burns = .Damaging in landing
    return
}

// The check every work dig passes first: whether digging t out leaves a hero
// whose feet are on row fy, its body over columns x0..x1, standing, or drops
// it only as far as falls for free (SAFE_FALL_TILES, into no burn).  A body
// still on another column's floor does not fall.  Gives the drop.
hero_dig_safe :: proc(w: ^World_Grid, t: [2]i32, fy, x0, x1: i32) -> (drop: int, safe: bool) {
    if t.y != fy + 1 do return 0, true
    for x in x0 ..= x1 do if x != t.x && is_solid(w, int(x), int(t.y)) do return 0, true
    d, hurts, burns := hero_dig_fall(w, t)
    return d, hurts == 0 && !burns
}

@(private="file")
hero_reflex_rim :: proc(gs: ^Game_State, b: ^Hero_Brain) {
    if hero_digging(gs) && hero_rim(&gs.world, gs.agent.cmd.mine) do gs.agent.cmd.has_mine = false
}

// A blow from an enemy is answered for HERO_FIGHT_BACK_S: a swing or a shot
// at it when one lands from where the hero is, the brain's walk kept.
@(private="file")
hero_reflex_fight_back :: proc(gs: ^Game_State, b: ^Hero_Brain) {
    p := &gs.player
    hurt := p.hp < b.last_hp
    b.last_hp = p.hp
    b.hurt_t = max(b.hurt_t - gs.delta_time, 0)
    if hurt {
        // The blow's dealer, by the name the game gave it: the nearest of that kind.
        best := HERO_THREAT_FAR
        for i in 0 ..< MAX_ENEMIES {
            if !gs.enemies.active[i] || enemy_kind_names[gs.enemies.data[i].kind] != gs.hurt_by do continue
            e := &gs.enemies.data[i]
            if d := chebyshev(builder_tile(e), player_tile(p)); f32(d) < best do best, b.hurt_slot, b.hurt_t = f32(d), i, HERO_FIGHT_BACK_S
        }
    }
    if b.hurt_t <= 0 || !gs.enemies.active[b.hurt_slot] do return
    if gs.agent.cmd.verb != .None || agent_window_open(gs) do return  // a potion first; never a click in a window
    hero_strike(gs, b, b.hurt_slot)
}
