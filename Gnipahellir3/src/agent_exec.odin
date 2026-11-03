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
Agent_Goal_Kind   :: enum u8 { Act }
// How a goal came: the old act and wait answer with state when it is done, and a
// plan's goals stop together.
Agent_Goal_Via    :: enum u8 { Goal, Act, Wait, Plan }

Agent_Goal :: struct {
    id:          int,
    status:      Agent_Goal_Status,
    kind:        Agent_Goal_Kind,
    via:         Agent_Goal_Via,
    told:        bool,  // its end has been settled: pushed, recorded, answered
    step:        int,   // a plan goal's place in its plan
    cmd:         Agent_Command,
    frames:      int,
    frames_left: int,
    first:       bool,  // the next tick it plays is its first
    reason:      Agent_Text,  // why it failed
    len:         int,
    line:        [AGENT_GOAL_LINE]u8,  // the goal as strict JSON
}

Agent_Goals :: struct {
    slots:        [AGENT_GOALS_MAX]Agent_Goal,  // id order
    n:            int,
    next_id:      int,
    ran:          bool,  // this tick played a goal's frame
    plan_stopped: Agent_Text,  // why a plan's step could not start, until the next plan
    notes:        [HERO_NOTES_MAX]Hero_Note,  // what the hero did with the goals: a ring
    note_count:   int,  // every note ever, so the link knows what it has not pushed
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
    } else if g != nil && agent_goal_kinds[g.kind].tick(gs, g) {
        g.status = .Done
    }
}

// The running goal, or the first queued one that starts.  One that cannot start
// fails, and a plan's failed step ends its plan.
@(private="file")
agent_goals_current :: proc(gs: ^Game_State, q: ^Agent_Goals) -> ^Agent_Goal {
    for &g in q.slots[:q.n] {
        if g.status == .Running do return &g
        if g.status != .Queued do continue
        if !agent_goal_kinds[g.kind].start(gs, &g) {
            g.status = .Failed
            if g.via == .Plan do agent_goals_stop_plan(q, &g)
            continue
        }
        g.status = .Running
        return &g
    }
    return nil
}

@(private="file")
agent_goals_stop_plan :: proc(q: ^Agent_Goals, failed: ^Agent_Goal) {
    agent_text_set(&q.plan_stopped, fmt.tprintf("step %d: %s", failed.step, string(failed.reason.buf[:failed.reason.len])))
    for &g in q.slots[:q.n] {
        if g.via != .Plan || g.status != .Queued do continue
        g.status = .Failed
        agent_text_set(&g.reason, "plan stopped")
    }
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
agent_goals_push :: proc(q: ^Agent_Goals, kind: Agent_Goal_Kind, via: Agent_Goal_Via, line: string, step := 0) -> int {
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
    g^ = {id = q.next_id, status = .Queued, kind = kind, via = via, step = step}
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
    return c.has_use
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
    g.first       = g.via != .Wait  // a wait is no act: nothing fires on its first tick
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
    break_dir:   i8,  // cornered, running past the threat this way until it is behind
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

// One tick of the brain on the play screen: sense, score, pick, run, tell.
@(private="file")
hero_think :: proc(gs: ^Game_State, q: ^Agent_Goals, g: ^Agent_Goal) {
    b := &gs.hero
    hero_sense(gs, b)
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
            damage  = hero_threat_damage[e.kind],
        }
        if roamer_table[e.kind].cap > 0 do th.damage = roamer_table[e.kind].damage
        if th.damage < 0 do th.damage = (p.hp_max + 3) / 4
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

@(private="file")
hero_armed :: proc(gs: ^Game_State) -> bool {
    held := held_item(&gs.player)
    return is_melee_weapon(held) || is_fire_wand(held)
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
// HERO_SAFE_CLEAR from it, else straight away.  Cornered at a drop it will
// not walk, it takes the drop if the fall leaves it standing, and otherwise
// runs the other way, past the threat: never frozen in danger.
@(private="file")
hero_get_clear :: proc(gs: ^Game_State, b: ^Hero_Brain, th: ^Hero_Threat) {
    s := &b.senses
    hx := gs.player.pos.x + PLAYER_W * 0.5
    tx := hx + th.dx
    best_x, best_d := hx - math.sign(th.dx) * HERO_THREAT_FAR, HERO_SAFE_CLEAR
    for spot in s.safe[:s.n_safe] {
        sx := f32(spot.x) + 0.5
        if d := abs(sx - tx); d > best_d do best_x, best_d = sx, d
    }
    if b.break_dir != 0 && math.sign(th.dx) != -f32(b.break_dir) {
        hero_walk(gs, b, b.break_dir)  // still on the way past it
        return
    }
    b.break_dir = 0
    if abs(best_x - hx) < 0.3 do return
    dir: i8 = 1 if best_x > hx else -1
    if col, _ := hero_step(gs, s, dir); !hero_falls_safe(gs) && hero_unsafe(col) {
        if !col.hazard && col.hurts < gs.player.hp {
            hero_walk(gs, b, dir, drop_ok = true)  // a hurt fall beats a mauling
            return
        }
        b.break_dir = -dir
        dir = -dir
    }
    hero_walk(gs, b, dir)
}

// ─── Behaviours ───

@(private="file")
hero_goal_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    return HERO_GOAL_SCORE if g != nil else 0
}

@(private="file")
hero_goal_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    if agent_goal_kinds[g.kind].tick(gs, g) do g.status = .Done
}

@(private="file")
hero_fight_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    th := hero_threat(b)
    if th == nil || !hero_armed(gs) do return 0
    return hero_press(th) * (30 + 60 * hero_hp_frac(gs))
}

@(private="file")
hero_fight_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    th := hero_threat(b)
    b.swing_t -= gs.delta_time
    e := &gs.enemies.data[th.slot]
    et := builder_tile(e)
    c := &gs.agent.cmd
    wand := is_fire_wand(held_item(&gs.player))
    if th.dist > HERO_WAND_RANGE || (!wand && chebyshev(et, player_tile(&gs.player)) > MELEE_REACH) {
        hero_walk_to(gs, b, gs.player.pos.x + PLAYER_W * 0.5 + th.dx)
        if !wand do return
    }
    // A wand fires while the button is held and paces its own shots; a sword
    // swings on a click, which the hero gives every HERO_SWING_S.
    if !wand {
        if b.swing_t > 0 do return
        b.swing_t = HERO_SWING_S
        gs.agent.first = true
    }
    c.has_mine = true
    c.mine     = et
    c.aim      = e.pos + enemy_body_size(e.kind) * 0.5
}

@(private="file")
hero_flee_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    th := hero_threat(b)
    if th == nil do return 0
    s := 30 + 60 * (1 - hero_hp_frac(gs))
    if !hero_armed(gs) do s += HERO_UNARMED_FLEE
    // Once running, the hero keeps running until the threat is out of
    // HERO_THREAT_FAR: no turning back toward it at the margin.
    if b.current == .Flee && th.dist < HERO_THREAT_FAR do return s
    return hero_press(th) * s
}

@(private="file")
hero_flee_run :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) {
    hero_get_clear(gs, b, hero_threat(b))
}

// A goal walking the hero to the edge of a drop: stop, look, then step if the
// fall is free and give the goal up if it is not.
@(private="file")
hero_ledge_score :: proc(gs: ^Game_State, b: ^Hero_Brain, g: ^Agent_Goal) -> f32 {
    if g == nil || g.status != .Running || g.cmd.move == 0 || (g.first && g.cmd.jump) do return 0
    if hero_falls_safe(gs) do return 0
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
