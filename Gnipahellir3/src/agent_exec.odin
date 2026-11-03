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
    if g == nil do return
    q.ran = true
    if agent_goal_kinds[g.kind].tick(gs, g) do g.status = .Done
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
