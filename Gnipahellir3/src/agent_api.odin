package game

// agent_api.odin — lets an outside agent play the running game over a local
// socket.  Diagnostic only: everything is behind GAME_DEBUG, and nothing listens
// unless GNIPA_AGENT_PORT is set.
//
// Protocol: one JSON object per line each way, on 127.0.0.1.
//   {"cmd":"state"}                                 full state, x/y/w/h pick the tile view
//   {"cmd":"act","move":"left","frames":30,...}     play those frames, reply with state after
//                                                   a refused warp answers ok:false and plays
//                                                   nothing; a place the game turned away
//                                                   leaves "refused":"place" in the state,
//                                                   the reason, if any, in notes;
//                                                   withdraw:true pulls an open smelter's ore
//   {"cmd":"plan","acts":[{"move":"left","frames":30},...]}
//                                                   what to do while you think: played
//                                                   at quarter speed, no reply per step;
//                                                   an act, a plan or realtime drops the rest;
//                                                   state, warp, craft and window verbs are
//                                                   judged when the step starts, and one
//                                                   that fails ends the plan: state then
//                                                   carries plan_stopped
//   {"cmd":"wait","frames":30}                      play ticks with no act, as an idle wait
//   {"cmd":"realtime","on":true}                    keep ticking between acts
//   {"cmd":"idle","on":false}                       hold between acts, no idle ticks
//   {"cmd":"objective","goal":"...","step":"..."}   tell the watcher what you are up to;
//                                                   a new goal files the old one, with
//                                                   "result":"failed" if it did not work
//
// While a client is connected the game WAITS: between acts it plays the agent's
// plan at quarter speed, about 15 ticks a second, so a plan meant to fill a 20 s
// think is 300 ticks.  With no plan left it idles at that speed with empty input
// for up to AGENT_IDLE_MAX ticks, then holds, so a long think is not a death.
// Every tick is a fixed 1/60 s step, and the keyboard and mouse are ignored.
// Disconnecting hands the game straight back to them.
//
// An act drives the same seams a player does: Input_State for held input, the
// Event_Queue for one-shot verbs.  It is never handed a shortcut into world
// state, so every rule (reach, costs, stations) still applies.
//
// The link lives in main, not in Game_State: game_state_init zeroes gs on a New
// Game, and the socket has to outlive that.  gs.agent is rewritten every frame.
//
// A run is recorded and repeatable.  acts.jsonl holds every act with where it
// left the player, and the same acts from the same GNIPA_SEED play out the same:
// the frame clock starts at the first connect, the step is fixed, and a New Game
// while driving derives its seeds from the last one.  `realtime` and a disconnect
// let wall time in, so they are recorded, and a replay stops at them.
// tools/agent_replay.py plays a recording back.
//
// An agent run writes a save and truncates action.log in the working directory,
// so agent_open refuses to run anywhere that does not hold AGENT_SANDBOX_FILE.
// tools/agent_play.sh builds such a folder.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

AGENT_PORT_ENV     :: "GNIPA_AGENT_PORT"
AGENT_SANDBOX_FILE :: "agent_sandbox"
AGENT_STEP         :: f32(1.0 / 60.0)
AGENT_MAX_FRAMES   :: 600
AGENT_IDLE_EVERY   :: 4    // render frames per tick of a plan or an idle wait
AGENT_IDLE_MAX     :: 180  // ticks per wait, 3 s of game time; a first guess
AGENT_PLAN_MAX     :: 32   // steps in one plan
AGENT_PLAN_LINE    :: 256  // one step, as it is recorded
AGENT_VIEW_ZOOM    :: f32(2.5) // the framing a watching human gets; the wheel still changes it
AGENT_VIEW_W       :: 41   // default tile view, centered on the player
AGENT_VIEW_H       :: 25
AGENT_LINE_MAX     :: 4096
AGENT_REPLY_MAX    :: 512 * 1024
AGENT_ITEMS_MAX    :: 2000 // ground piles in one reply; caps it well inside AGENT_REPLY_MAX
AGENT_SEND_TIMEOUT :: 2 * time.Second // a client that stops reading is dropped

// Printable, JSON-safe, one per distinct tile type seen in a view.
AGENT_ACTS_FILE    :: "acts.jsonl"
AGENT_FIGHT_FILE   :: "fight.log"
AGENT_FIGHT_RANGE  :: 30      // tiles from the player
AGENT_FIGHT_BUF    :: 64 * 1024

AGENT_TILE_CHARS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#*+-=~:;.,!?@$%^&()[]{}<>/|_"

Agent_Plan_Step :: struct {
    frames: int,
    len:    int,
    line:   [AGENT_PLAN_LINE]u8,
}

Agent_Link :: struct {
    listening:   bool,
    connected:   bool,
    realtime:    bool,
    idle_off:    bool,
    idle_step:   int,            // render frames since the last slow tick
    idle_ticks:  int,            // idle ticks in this wait, recorded when it ends
    plan:        [AGENT_PLAN_MAX]Agent_Plan_Step,
    plan_len:    int,
    plan_next:   int,            // the step after the one playing
    planning:    bool,           // the act in progress is a plan step
    step_frames: int,            // that step's whole length
    plan_stopped: Agent_Text,    // why a step could not start, until the next plan
    listener:    net.TCP_Socket,
    client:      net.TCP_Socket,
    panel:       Agent_Panel,
    cmd:         Agent_Command,  // the act in progress
    first:       bool,           // its first frame has not run yet
    frames_left: int,
    reply_due:   bool,           // an act finished: its state waits in out
    recording:   bool,
    acts_file:   ^os.File,
    fight_file:  ^os.File,
    fight_len:   int,
    fight_buf:   [AGENT_FIGHT_BUF]u8,
    act_len:     int,            // the act in progress, as it was sent
    act_line:    [AGENT_LINE_MAX]u8,
    in_len:      int,
    in_buf:      [AGENT_LINE_MAX]u8,
    out_len:     int,
    out:         [AGENT_REPLY_MAX]u8,
}

// Startup: arms the listener when the env var asks for it.  Runs before anything
// touches disk, because a refused sandbox has to leave action.log alone.
agent_open :: proc(link: ^Agent_Link) {
    when !GAME_DEBUG { return }
    port_text := os.get_env(AGENT_PORT_ENV, context.temp_allocator)
    if port_text == "" do return
    port, ok := strconv.parse_int(port_text)
    if !ok || port <= 0 || port > 65535 {
        fmt.eprintfln("%s: bad port %q", AGENT_PORT_ENV, port_text)
        os.exit(1)
    }
    if !os.exists(AGENT_SANDBOX_FILE) {
        fmt.eprintfln("%s is set but this folder has no %s file: an agent run would overwrite the save and action.log here. Use tools/agent_play.sh.",
            AGENT_PORT_ENV, AGENT_SANDBOX_FILE)
        os.exit(1)
    }
    sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port}, 1)
    if err != nil {
        fmt.eprintfln("agent api: cannot listen on 127.0.0.1:%d: %v", port, err)
        os.exit(1)
    }
    net.set_blocking(sock, false)
    link.listener  = sock
    link.listening = true
    if fd, ferr := os.open(AGENT_ACTS_FILE, os.O_WRONLY | os.O_CREATE | os.O_APPEND); ferr == nil {
        link.acts_file = fd
        link.recording = true
    }
    if fd, ferr := os.open(AGENT_FIGHT_FILE, os.O_WRONLY | os.O_CREATE | os.O_APPEND); ferr == nil {
        link.fight_file = fd
    }
    fmt.printfln("agent api: listening on 127.0.0.1:%d", port)
}

// The boot world: GNIPA_SEED when a run names one, so a replay starts in it.
agent_boot_seed :: proc(link: ^Agent_Link) -> u32 {
    if link.listening do return new_game_world_seed()
    return DEFAULT_WORLD_SEED
}

// The seed for a New Game: chained while an agent drives, so one seed fixes every
// world of a run.
agent_new_game_seed :: proc(gs: ^Game_State) -> u32 {
    return gs.world_seed * 2654435761 + 1 if gs.agent.driving else new_game_world_seed()
}

agent_close :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if link.connected do agent_drop_client(link, gs)
    if link.listening do net.close(link.listener)
    if link.recording do os.close(link.acts_file)
    if link.fight_file != nil {
        agent_fight_flush(link)
        os.close(link.fight_file)
    }
    link.listening = false
}

// Before each frame: serves the client and says whether the sim ticks.
agent_pump :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    if !link.listening do return true

    if link.reply_due {
        link.reply_due = false
        agent_send(link, gs)
    }
    if !link.connected {
        client, _, err := net.accept_tcp(link.listener)
        if err == nil {
            net.set_blocking(client, false)
            net.set_option(client, .TCP_Nodelay, true)
            link.client    = client
            link.connected = true
            link.realtime  = false
            link.in_len    = 0
            link.panel     = {}
            link.plan_stopped = {}
            link.idle_off  = false
            link.idle_step = 0
            link.idle_ticks = 0
            if gs.ui.show_title do gs.frame = 0  // time spent on the title screen is not part of a run
        }
    }
    if link.connected && agent_listening(link) do agent_read(link, gs)
    if !link.connected {
        gs.agent = {}  // back to the keyboard, with nothing of the last act left to replay
        return true
    }
    return agent_drive(link, gs)
}

// Loads this frame's input into gs.agent and decides whether the sim ticks.
agent_drive :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    gs.agent.driving = true
    gs.agent.panel   = &link.panel
    if !link.realtime do gs.delta_time = AGENT_STEP
    if link.frames_left == 0 && link.plan_next < link.plan_len do agent_plan_step(link, gs)
    if link.frames_left > 0 && (!link.planning || agent_slow_beat(link)) {
        gs.agent.cmd   = link.cmd
        gs.agent.first = link.first
        link.first     = false
        return true
    }
    gs.agent.cmd   = {}
    gs.agent.first = false
    if link.frames_left > 0 do return false
    if link.realtime do return true
    if link.idle_off || link.idle_ticks >= AGENT_IDLE_MAX do return false
    return agent_slow_beat(link)
}

// Between a plan's ticks the client can still talk: an act overrides the plan.
agent_listening :: proc(link: ^Agent_Link) -> bool {
    return link.frames_left == 0 || link.planning
}

@(private="file")
agent_slow_beat :: proc(link: ^Agent_Link) -> bool {
    link.idle_step += 1
    if link.idle_step < AGENT_IDLE_EVERY do return false
    link.idle_step = 0
    return true
}

@(private="file")
agent_plan_step :: proc(link: ^Agent_Link, gs: ^Game_State) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator

    step := &link.plan[link.plan_next]
    value, _ := json.parse_string(string(step.line[:step.len]))
    o, _ := value.(json.Object)
    c, _, problem := agent_parse_act(gs, o)
    if problem != "" {
        // The live check an act gets: a replay only ever sees what passed it.
        agent_text_set(&link.plan_stopped, fmt.tprintf("step %d: %s", link.plan_next, problem))
        link.plan_len  = 0
        link.plan_next = 0
        return
    }
    agent_record_idle(link, gs)
    link.plan_next  += 1
    link.cmd         = c
    link.first       = true
    link.frames_left = step.frames
    link.step_frames = step.frames
    link.planning    = true
    link.act_len     = copy(link.act_line[:], step.line[:step.len])
}

// Ends a plan, recording how much of the running step was really played.
@(private="file")
agent_plan_cut :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if link.planning {
        played := link.step_frames - link.frames_left
        if played > 0 do agent_record_act(link, gs, played)
        link.planning    = false
        link.frames_left = 0
        link.cmd         = {}
        agent_fight_flush(link)
        flush_action_log(gs)
    }
    link.plan_len  = 0
    link.plan_next = 0
}

// After a ticked frame: counts the act down and answers when it has run out.
agent_after_tick :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if !link.connected do return
    agent_fight_log(link, gs)
    if link.frames_left == 0 {
        if !link.realtime do link.idle_ticks += 1
        return
    }
    link.frames_left -= 1
    if link.frames_left == 0 {
        link.cmd = {}
        agent_record_act(link, gs)
        agent_fight_flush(link)
        flush_action_log(gs)  // what a reply reports is already on disk
        if link.planning {
            link.planning = false  // a plan step has nobody waiting for its reply
            return
        }
        agent_reply_state(link, gs, nil)
        link.reply_due = true
    }
}

@(private="file")
agent_read :: proc(link: ^Agent_Link, gs: ^Game_State) {
    for agent_listening(link) && link.connected {
        // A line may already be buffered behind the one just answered.
        if nl := agent_newline(link); nl >= 0 {
            line := string(link.in_buf[:nl])
            agent_handle_line(link, gs, line)
            agent_send(link, gs)
            remaining := link.in_len - nl - 1
            copy(link.in_buf[:], link.in_buf[nl + 1:link.in_len])
            link.in_len = remaining
            continue
        }
        if link.in_len == len(link.in_buf) {
            agent_drop_client(link, gs)  // a line this long is not the protocol
            return
        }
        n, err := net.recv_tcp(link.client, link.in_buf[link.in_len:])
        if err == .Would_Block || err == .Timeout do return
        if err != nil || n == 0 {
            agent_drop_client(link, gs)
            return
        }
        link.in_len += n
    }
}

@(private="file")
agent_newline :: proc(link: ^Agent_Link) -> int {
    for i in 0 ..< link.in_len do if link.in_buf[i] == '\n' do return i
    return -1
}

// Every enemy near the player, every frame: frame,slot,kind,x,y,hp,goal,tx,ty.
// A frame with one also gets a `P` line, frame,P,x,y,hp, so a fight reads whole.
agent_fight_log :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if link.fight_file == nil do return
    p := &gs.player
    near := false
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] do continue
        e := &gs.enemies.data[i]
        if abs(e.pos.x - p.pos.x) > AGENT_FIGHT_RANGE || abs(e.pos.y - p.pos.y) > AGENT_FIGHT_RANGE do continue
        near = true
        if link.fight_len > AGENT_FIGHT_BUF - 128 do agent_fight_flush(link)
        s := fmt.bprintf(link.fight_buf[link.fight_len:], "%d,%d,%v,%.2f,%.2f,%d,%v,%d,%d\n",
            gs.frame, i, e.kind, e.pos.x, e.pos.y, e.hp, e.builder.goal, e.builder.target_tile.x, e.builder.target_tile.y)
        link.fight_len += len(s)
    }
    if near {
        if link.fight_len > AGENT_FIGHT_BUF - 128 do agent_fight_flush(link)
        s := fmt.bprintf(link.fight_buf[link.fight_len:], "%d,P,%.2f,%.2f,%d\n", gs.frame, p.pos.x, p.pos.y, p.hp)
        link.fight_len += len(s)
    }
}

agent_fight_flush :: proc(link: ^Agent_Link) {
    if link.fight_file == nil || link.fight_len == 0 do return
    os.write(link.fight_file, link.fight_buf[:link.fight_len])
    link.fight_len = 0
}

// One line per finished act: the request as sent, and where it left the player,
// which is what a replay checks itself against.
@(private="file")
agent_record_act :: proc(link: ^Agent_Link, gs: ^Game_State, played := 0) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    p := &gs.player
    cut := fmt.tprintf(`"played":%d,`, played) if played > 0 else ""
    line := fmt.tprintf(`{{"f":%d,%s"act":%s,"x":%.3f,"y":%.3f,"hp":%d,"mana":%.2f,"lvl":%d,"enemies":%d}}` + "\n",
        gs.frame, cut, string(link.act_line[:link.act_len]), p.pos.x, p.pos.y, p.hp, p.mana, gs.level_index, gs.enemies.count)
    os.write_string(link.acts_file, line)
}

// A wait's ticks, so a replay can play them as an empty act of that length.
@(private="file")
agent_record_idle :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if link.recording && link.idle_ticks > 0 {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
        os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,"idle":%d}}` + "\n", gs.frame, link.idle_ticks))
    }
    link.idle_ticks = 0
    link.idle_step  = 0
}

@(private="file")
agent_record_objective :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,"objective":%s}}` + "\n", gs.frame, line))
}

@(private="file")
agent_record_mark :: proc(link: ^Agent_Link, gs: ^Game_State, mark: string) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,"mark":"%s"}}` + "\n", gs.frame, mark))
}

@(private="file")
agent_drop_client :: proc(link: ^Agent_Link, gs: ^Game_State) {
    agent_plan_cut(link, gs)
    agent_record_idle(link, gs)
    agent_record_mark(link, gs, "disconnect")
    net.close(link.client)
    link.connected   = false
    link.realtime    = false
    link.frames_left = 0
    link.reply_due   = false
    link.cmd         = {}
}

// A reply is one line; a short send means the client stopped reading.
@(private="file")
agent_send :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if !link.connected || link.out_len == 0 do return
    net.set_blocking(link.client, true)
    net.set_option(link.client, .Send_Timeout, AGENT_SEND_TIMEOUT)
    n, err := net.send_tcp(link.client, link.out[:link.out_len])
    net.set_blocking(link.client, false)
    if err != nil || n != link.out_len do agent_drop_client(link, gs)
}

// One request line.  Leaves the reply in link.out, except for an act, which
// replies when its frames have run.
agent_handle_line :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator

    value, err := json.parse_string(line)
    root, is_obj := value.(json.Object)
    if err != .None || !is_obj {
        agent_reply_error(link, "request is not a JSON object")
        return
    }
    cmd, _ := root["cmd"].(json.String)
    switch cmd {
    case "state":
        view := agent_default_view(gs)
        if v, ok := agent_int(root, "x"); ok do view.x = v
        if v, ok := agent_int(root, "y"); ok do view.y = v
        if v, ok := agent_int(root, "w"); ok do view.w = v
        if v, ok := agent_int(root, "h"); ok do view.h = v
        agent_reply_state(link, gs, &view)
    case "act":
        c, frames, problem := agent_parse_act(gs, root)
        if problem != "" {
            agent_reply_error(link, problem)
            return
        }
        canonical := agent_canonical(value)
        if len(canonical) > len(link.act_line) {
            agent_reply_error(link, "act too long to record")
            return
        }
        agent_plan_cut(link, gs)
        agent_record_idle(link, gs)
        link.cmd         = c
        link.first       = true
        link.frames_left = frames
        link.out_len     = 0
        link.act_len     = copy(link.act_line[:], canonical)
    case "wait":
        frames, ok := agent_int(root, "frames")
        if !ok || frames < 1 || frames > AGENT_MAX_FRAMES {
            agent_reply_error(link, fmt.tprintf("frames must be 1..%d", AGENT_MAX_FRAMES))
            return
        }
        canonical := agent_canonical(value)
        if len(canonical) > len(link.act_line) {
            agent_reply_error(link, "wait too long to record")
            return
        }
        agent_plan_cut(link, gs)
        agent_record_idle(link, gs)
        link.cmd         = {}
        link.first       = false
        link.frames_left = frames
        link.out_len     = 0
        link.act_len     = copy(link.act_line[:], canonical)
    case "realtime":
        on, ok := root["on"].(json.Boolean)
        if !ok {
            agent_reply_error(link, "realtime needs on:true or on:false")
            return
        }
        agent_plan_cut(link, gs)
        link.realtime = on
        agent_record_mark(link, gs, "realtime on" if on else "realtime off")
        agent_reply_text(link, `{"ok":true}`)
    case "plan":
        acts, ok := root["acts"].(json.Array)
        if !ok || len(acts) > AGENT_PLAN_MAX {
            agent_reply_error(link, fmt.tprintf("plan needs acts, at most %d", AGENT_PLAN_MAX))
            return
        }
        if link.realtime {
            agent_reply_error(link, "plan needs the game waiting: realtime is on")
            return
        }
        // All or nothing: a bad step must not leave half a plan playing.
        steps: [AGENT_PLAN_MAX]Agent_Plan_Step
        ticks := 0
        for act, i in acts {
            o, is_act := act.(json.Object)
            if !is_act {
                agent_reply_error(link, "a plan step is not an object")
                return
            }
            _, frames, problem := agent_parse_act(gs, o, false)
            if step_cmd, named := o["cmd"]; named {
                if s, is_text := step_cmd.(json.String); !is_text || s != "act" do problem = "a plan step can only be an act"
            }
            canonical := agent_canonical(act)
            if problem == "" && len(canonical) > AGENT_PLAN_LINE do problem = "plan step too long to record"
            if problem != "" {
                agent_reply_error(link, fmt.tprintf("step %d: %s", i, problem))
                return
            }
            steps[i].frames = frames
            steps[i].len    = copy(steps[i].line[:], canonical)
            ticks += frames
        }
        agent_plan_cut(link, gs)
        link.plan_stopped = {}
        link.plan     = steps
        link.plan_len = len(acts)
        agent_reply_text(link, fmt.tprintf(`{{"ok":true,"steps":%d,"ticks":%d}}`, len(acts), ticks))
    case "idle":
        on, ok := root["on"].(json.Boolean)
        if !ok {
            agent_reply_error(link, "idle needs on:true or on:false")
            return
        }
        if !on do agent_record_idle(link, gs)
        link.idle_off = !on
        agent_reply_text(link, `{"ok":true}`)
    case "objective":
        goal, has_goal := root["goal"].(json.String)
        step, has_step := root["step"].(json.String)
        if !has_goal && !has_step {
            agent_reply_error(link, "objective needs goal or step")
            return
        }
        result, _ := root["result"].(json.String)
        agent_set_objective(&link.panel, goal, step, has_goal, has_step, result == "failed")
        agent_record_objective(link, gs, agent_canonical(value))
        agent_reply_text(link, `{"ok":true}`)
    case:
        agent_reply_error(link, "unknown cmd: use state, act, realtime or objective")
    }
}

// The request as strict JSON.  The parser takes JSON5 and raw tabs, which the
// tools reading acts.jsonl do not, so what is recorded is re-encoded, not the
// line as sent.
agent_canonical :: proc(value: json.Value) -> string {
    data, err := json.marshal(value)
    return string(data) if err == nil else "{}"
}

@(private="file")
agent_text_set :: proc(t: ^Agent_Text, s: string) {
    t.len = copy(t.buf[:AGENT_TEXT_MAX], s)
    t.buf[t.len] = 0
    for &ch in t.buf[:t.len] do if ch < 0x20 do ch = ' '
}

agent_set_objective :: proc(p: ^Agent_Panel, goal, step: string, has_goal, has_step, failed: bool) {
    // Compared as stored: the text is cut and cleaned, so a goal sent again with
    // a new step is the same goal however long it is.
    next: Agent_Text
    agent_text_set(&next, goal)
    if has_goal && string(next.buf[:next.len]) != string(p.goal.buf[:p.goal.len]) {
        if p.goal.len > 0 {
            copy(p.past[1:], p.past[:AGENT_LOG_MAX - 1])
            p.past[0]  = {text = p.goal, failed = failed}
            p.count    = min(p.count + 1, AGENT_LOG_MAX)
        }
        p.goal = next
        p.step = {}
    }
    if has_step do agent_text_set(&p.step, step)
}

agent_int :: proc(o: json.Object, key: string) -> (int, bool) {
    #partial switch v in o[key] {
    case json.Integer: return int(v), true
    case json.Float:   return int(v), true
    }
    return 0, false
}

@(private="file")
agent_flag :: proc(o: json.Object, key: string) -> bool {
    v, _ := o[key].(json.Boolean)
    return v
}

// key:[x,y] in tile coordinates.  present says the key was there at all.
@(private="file")
agent_tile :: proc(o: json.Object, key: string) -> (tile: [2]i32, present, ok: bool) {
    if key not_in o do return
    present = true
    a, is_arr := o[key].(json.Array)
    if !is_arr || len(a) != 2 do return
    x, xok := agent_num(a[0])
    y, yok := agent_num(a[1])
    if !xok || !yok || !in_bounds(x, y) do return
    return {i32(x), i32(y)}, true, true
}

@(private="file")
agent_num :: proc(v: json.Value) -> (int, bool) {
    #partial switch n in v {
    case json.Integer: return int(n), true
    case json.Float:   return int(n), true
    }
    return 0, false
}

// A slot verb's argument; absent means the verb was not asked for.
@(private="file")
agent_slot_verb :: proc(c: ^Agent_Command, o: json.Object, key: string, verb: Agent_Verb) -> (problem: string) {
    if key not_in o do return ""
    slot, ok := agent_int(o, key)
    if !ok || slot < 0 || slot >= MAX_INVENTORY do return fmt.tprintf("%s needs a bag slot, 0..%d", key, MAX_INVENTORY - 1)
    c.verb     = verb
    c.verb_arg = i32(slot)
    return ""
}

agent_parse_act :: proc(gs: ^Game_State, o: json.Object, live := true) -> (c: Agent_Command, frames: int, problem: string) {
    frames = 1
    if "frames" in o {
        n, ok := agent_int(o, "frames")
        if !ok || n < 1 || n > AGENT_MAX_FRAMES {
            problem = fmt.tprintf("frames must be 1..%d", AGENT_MAX_FRAMES)
            return
        }
        frames = n
    }

    if "move" in o {
        move, _ := o["move"].(json.String)
        switch move {
        case "left":  c.move = -1
        case "right": c.move = 1
        case "none":
        case:
            problem = "move must be left, right or none"
            return
        }
    }
    c.jump     = agent_flag(o, "jump")
    c.down     = agent_flag(o, "down")
    c.interact = agent_flag(o, "interact")
    c.dismiss  = agent_flag(o, "dismiss")

    tile_ok := true
    present: bool
    ok: bool
    c.mine,  present, ok = agent_tile(o, "mine");  c.has_mine  = ok; tile_ok &&= ok || !present
    c.place, present, ok = agent_tile(o, "place"); c.has_place = ok; tile_ok &&= ok || !present
    c.use,   present, ok = agent_tile(o, "use");   c.has_use   = ok; tile_ok &&= ok || !present
    c.reclaim, present, ok = agent_tile(o, "reclaim"); c.has_reclaim = ok; tile_ok &&= ok || !present
    if !tile_ok {
        problem = "mine, place, use and reclaim take [x,y] inside the map"
        return
    }
    if int(c.has_mine) + int(c.has_place) + int(c.has_use) + int(c.has_reclaim) > 1 {
        problem = "one of mine, place, use or reclaim per act: there is one cursor"
        return
    }
    if agent_flag(o, "warp") {
        ring := false
        for it in gs.player.equipment do ring ||= it == .Jade_Ring
        if live && !ring {
            problem = "warp needs the Jade Ring worn"
            return
        }
        if why := warp_refusal(gs); live && why != "" {
            problem = fmt.tprintf("warp refused: %s", why)
            return
        }
        c.warp = true
    }

    if "select" in o {
        slot, is_int := agent_int(o, "select")
        if !is_int || slot < -1 || slot >= MAX_INVENTORY {
            problem = fmt.tprintf("select needs a bag slot, or -1 for an empty hand")
            return
        }
        c.verb     = .Select
        c.verb_arg = i32(slot)
    }
    if p := agent_slot_verb(&c, o, "equip", .Equip); p != "" { problem = p; return }
    if p := agent_slot_verb(&c, o, "feed", .Feed);   p != "" { problem = p; return }
    if p := agent_slot_verb(&c, o, "store", .Store); p != "" { problem = p; return }
    if p := agent_slot_verb(&c, o, "take", .Take);   p != "" { problem = p; return }
    if agent_flag(o, "collect") do c.verb = .Collect
    if agent_flag(o, "withdraw") do c.verb = .Withdraw

    if "craft" in o {
        name, _ := o["craft"].(json.String)
        idx := agent_find_recipe(gs, name)
        if live && idx < 0 {
            problem = fmt.tprintf("no revealed recipe makes %s", name)
            return
        }
        c.verb     = .Craft
        c.verb_arg = i32(idx)
    }

    if !live do return  // a plan's later steps run in a world not yet played

    // The smelter and barrel verbs act on the window a `use` opened, as the
    // drag-and-drop they stand in for does.
    #partial switch c.verb {
    case .Feed, .Collect, .Withdraw:
        t := get_tile(&gs.world, int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y))
        if !gs.ui.show_smelter || t != .Smelter {
            problem = "no smelter window open: use the smelter first"
        }
    case .Store, .Take:
        if !gs.ui.show_barrel do problem = "no barrel window open: use the barrel first"
    }
    return
}

// By result name.  A result with several recipes prefers one that can be made now.
@(private="file")
agent_find_recipe :: proc(gs: ^Game_State, name: string) -> int {
    found := -1
    for &r, i in recipe_table {
        if fmt.tprint(r.result) != name || !recipe_revealed(&gs.progression, r.result) do continue
        if recipe_craftable(gs, &r) do return i
        if found < 0 do found = i
    }
    return found
}

// Stands in for update_input while a client is connected: same outputs, read
// from the act instead of the hardware.  Called from update_input, under the
// same rules as it: Input_State, Event_Queue, UI_State, inventory selection.
agent_input :: proc(gs: ^Game_State) {
    inp   := &gs.input
    c     := gs.agent.cmd
    first := gs.agent.first

    if !gs.agent.framed {
        gs.agent.framed = true
        gs.loot_rng = u64(gs.world_seed) * 2 + 1  // the clock seeds it otherwise
        request_zoom(gs, (AGENT_VIEW_ZOOM - gs.zoom_target) / ZOOM_STEP, {}, false)
    }

    inp.move_left  = false
    inp.move_right = false
    inp.jump       = false
    inp.mine       = false
    inp.attack     = false
    inp.reclaim    = false
    inp.interact   = false
    inp.fly_up     = false
    inp.fly_down   = false

    if first && c.dismiss do agent_dismiss(gs)
    if gs.ui.show_title || gs.ui.show_settings ||
       gs.ui.show_snapshots || gs.ui.show_menu || gs.player.dead || gs.ui.show_book {
        return
    }

    // A window follows its machine, as in update_input: mined out, it closes.
    if gs.ui.show_smelter &&
       get_tile(&gs.world, int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y)) != .Smelter {
        gs.ui.show_smelter = false
    }
    if gs.ui.show_barrel {
        t := get_tile(&gs.world, int(gs.ui.barrel_tile.x), int(gs.ui.barrel_tile.y))
        if t != .Barrel && t != .Rune_Coffer && !is_rune_scroll_chest(t) do gs.ui.show_barrel = false
    }

    // Windows are only open for the verbs that work on them.  Anything else
    // sweeps them shut, so the view stays clear for whoever is watching.
    if first && !c.has_use && c.verb != .Feed && c.verb != .Collect && c.verb != .Withdraw && c.verb != .Store && c.verb != .Take {
        agent_close_windows(gs)
    }

    tile := player_tile(&gs.player)
    if c.has_mine  do tile = c.mine
    if c.has_place do tile = c.place
    if c.has_use   do tile = c.use
    if c.has_reclaim do tile = c.reclaim
    inp.mouse_tile   = tile
    inp.mouse_world  = {(f32(tile.x) + 0.5) * CELL_SIZE, (f32(tile.y) + 0.5) * CELL_SIZE}
    gs.ui.hover_tile = tile

    inp.move_left  = c.move < 0
    inp.move_right = c.move > 0
    inp.jump       = first && c.jump
    inp.interact   = first && c.interact
    inp.fly_up     = c.jump
    inp.fly_down   = c.down

    // A click on a structure interacts rather than mines, and the command wand
    // never mines: the two rules update_input applies to the same button.
    hover_t := get_tile(&gs.world, int(tile.x), int(tile.y))
    command_active := equipped_command_wand(gs) != .None
    if c.has_mine && !command_active && !is_structure_tile[hover_t] && !is_rune_scroll_chest(hover_t) {
        inp.mine   = true
        inp.attack = first
    }

    inp.reclaim = c.has_reclaim && !command_active  // a held Shift+click

    if !first do return
    gs.agent.place_refused = false

    if c.warp do eq_push(&gs.events, Event{type = .Warp_Home_Request})
    if c.has_place {
        type := Event_Type.Golem_Deploy if command_active else Event_Type.Place_Request
        eq_push(&gs.events, Event{type = type, tile = tile})
    }
    if c.has_use {
        if is_rune_scroll_chest(hover_t) {
            eq_push(&gs.events, Event{type = .Barrel_Interact, tile = tile})
        } else if is_structure_tile[hover_t] {
            eq_push(&gs.events, Event{type = .Structure_Interact, tile = tile})
        }
    }

    arg := c.verb_arg
    switch c.verb {
    case .None:
    case .Select:  gs.player.inventory.selected = int(arg)
    case .Craft:   eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = arg}})
    case .Equip:   eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = arg}})
    case .Feed:    eq_push(&gs.events, Event{type = .Smelter_Feed, tile = gs.ui.smelter_tile, payload = {int_val = arg}})
    case .Collect: eq_push(&gs.events, Event{type = .Smelter_Collect, tile = gs.ui.smelter_tile})
    case .Withdraw: eq_push(&gs.events, Event{type = .Smelter_Withdraw, tile = gs.ui.smelter_tile})
    case .Store:   eq_push(&gs.events, Event{type = .Barrel_Store, tile = gs.ui.barrel_tile, payload = {int_val = arg}})
    case .Take:    eq_push(&gs.events, Event{type = .Barrel_Take, tile = gs.ui.barrel_tile, payload = {int_val = arg}})
    }
}

// What the first ESC does in update_input.
@(private="file")
agent_close_windows :: proc(gs: ^Game_State) {
    gs.ui.show_inventory    = false
    gs.ui.show_crafting     = false
    gs.ui.show_rune_scroll  = false
    gs.ui.show_smelter      = false
    gs.ui.show_barrel       = false
    gs.ui.show_golem_roster = false
}

// The one key that gets past any screen holding the game up.
@(private="file")
agent_dismiss :: proc(gs: ^Game_State) {
    switch {
    case gs.ui.show_title:     gs.ui.show_title     = false
    case gs.ui.show_settings:  gs.ui.show_settings  = false
    case gs.ui.show_snapshots: gs.ui.show_snapshots = false
    case gs.ui.show_menu:      gs.ui.show_menu      = false
    case gs.player.dead:
        if gs.player.death_timer > DEATH_INPUT_DELAY {
            eq_push(&gs.events, Event{type = .New_Game_Request})
        }
    case gs.ui.show_book:      gs.ui.show_book      = false
    }
}

@(private="file")
agent_screen :: proc(gs: ^Game_State) -> string {
    switch {
    case gs.ui.show_title:      return "title"
    case gs.ui.show_settings:   return "settings"
    case gs.ui.show_snapshots:  return "snapshots"
    case gs.ui.show_menu:       return "menu"
    case gs.player.dead:        return "dead"
    case gs.ui.show_book:       return "book"
    }
    return "play"
}

Agent_View :: struct { x, y, w, h: int }

@(private="file")
agent_default_view :: proc(gs: ^Game_State) -> Agent_View {
    t := player_tile(&gs.player)
    return {int(t.x) - AGENT_VIEW_W / 2, int(t.y) - AGENT_VIEW_H / 2, AGENT_VIEW_W, AGENT_VIEW_H}
}

@(private="file")
agent_reply_text :: proc(link: ^Agent_Link, text: string) {
    b := strings.builder_from_bytes(link.out[:])
    strings.write_string(&b, text)
    strings.write_byte(&b, '\n')
    link.out_len = strings.builder_len(b)
}

@(private="file")
agent_reply_error :: proc(link: ^Agent_Link, text: string) {
    b := strings.builder_from_bytes(link.out[:])
    strings.write_string(&b, `{"ok":false,"error":`)
    json_write_string(&b, text)
    strings.write_string(&b, "}\n")
    link.out_len = strings.builder_len(b)
}

@(private="file")
json_write_string :: proc(b: ^strings.Builder, text: string) {
    strings.write_quoted_string(b, text)
}

// The whole reply fits link.out: the view is clamped to the map, enemies are
// bounded by MAX_ENEMIES and piles by AGENT_ITEMS_MAX.  "items" lists the first
// piles in row order, so a whole-map view of a littered world can come up short.
agent_reply_state :: proc(link: ^Agent_Link, gs: ^Game_State, view: ^Agent_View) {
    v := view^ if view != nil else agent_default_view(gs)
    v.x = clamp(v.x, 0, GRID_W - 1)
    v.y = clamp(v.y, 0, GRID_H - 1)
    v.w = clamp(v.w, 1, GRID_W - v.x)
    v.h = clamp(v.h, 1, GRID_H - v.y)

    b := strings.builder_from_bytes(link.out[:])
    p := &gs.player
    fmt.sbprintf(&b, `{{"ok":true,"frame":%d,"screen":"%s","level":%d,`, gs.frame, agent_screen(gs), gs.level_index)
    fmt.sbprintf(&b, `"player":{{"x":%.2f,"y":%.2f,"vx":%.2f,"vy":%.2f,"hp":%d,"hp_max":%d,"mana":%.1f,"grounded":%v,"facing":%d,"dead":%v}},`,
        p.pos.x, p.pos.y, p.vel.x, p.vel.y, p.hp, p.hp_max, p.mana, p.grounded, p.facing, p.dead)

    fmt.sbprintf(&b, `"place_reach":%d,`, PLAYER_REACH)
    if gs.agent.place_refused do strings.write_string(&b, `"refused":"place",`)
    fmt.sbprintf(&b, `"plan_left":%d,`, link.plan_len - link.plan_next)
    if link.plan_stopped.len > 0 {
        strings.write_string(&b, `"plan_stopped":`)
        json_write_string(&b, string(link.plan_stopped.buf[:link.plan_stopped.len]))
        strings.write_byte(&b, ',')
    }

    // What a player reads off the screen: the buffs, the tile the body is in, and
    // the toasts, which are also the only reason a refused action ever gives.
    body := player_tile(p)
    fmt.sbprintf(&b, `"flight_s":%.1f,"leaf_s":%.1f,"in_tile":"%v","notes":[`,
        gs.flight_t, gs.leaf_fall_t, get_tile(&gs.world, int(body.x), int(body.y)))
    for i in 0 ..< gs.notify.count {
        if i > 0 do strings.write_byte(&b, ',')
        n := &gs.notify.items[i]
        strings.write_quoted_string(&b, string(n.text[:n.len]))
    }
    strings.write_string(&b, "],")
    agent_write_window(&b, gs)

    fmt.sbprintf(&b, `"selected":%d,"inventory":[`, p.inventory.selected)
    comma := false
    for s, i in p.inventory.slots {
        if s.item == .None || s.count <= 0 do continue
        if comma do strings.write_byte(&b, ',')
        comma = true
        fmt.sbprintf(&b, `{{"slot":%d,"item":"%v","count":%d}}`, i, s.item, s.count)
    }

    strings.write_string(&b, `],"craftable":[`)
    comma = false
    for &r in recipe_table {
        if !recipe_revealed(&gs.progression, r.result) || !recipe_craftable(gs, &r) do continue
        if comma do strings.write_byte(&b, ',')
        comma = true
        fmt.sbprintf(&b, `"%v"`, r.result)
    }

    fmt.sbprintf(&b, `],"ui":{{"inventory":%v,"crafting":%v,"smelter":%v,"barrel":%v}},`,
        gs.ui.show_inventory, gs.ui.show_crafting, gs.ui.show_smelter, gs.ui.show_barrel)

    agent_write_view(&b, gs, v)

    strings.write_string(&b, `,"items":[`)
    comma = false
    piles := 0
    for y in v.y ..< v.y + v.h do for x in v.x ..< v.x + v.w {
        idx := grid_idx(x, y)
        if gs.world.items[idx] == .None || gs.world.item_counts[idx] == 0 || piles == AGENT_ITEMS_MAX do continue
        piles += 1
        if comma do strings.write_byte(&b, ',')
        comma = true
        fmt.sbprintf(&b, `{{"x":%d,"y":%d,"item":"%v","count":%d}}`, x, y, gs.world.items[idx], gs.world.item_counts[idx])
    }

    strings.write_string(&b, `],"enemies":[`)
    comma = false
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] do continue
        e := &gs.enemies.data[i]
        if int(e.pos.x) < v.x || int(e.pos.x) >= v.x + v.w || int(e.pos.y) < v.y || int(e.pos.y) >= v.y + v.h do continue
        if comma do strings.write_byte(&b, ',')
        comma = true
        fmt.sbprintf(&b, `{{"slot":%d,"kind":"%v","x":%.2f,"y":%.2f,"hp":%d}}`, i, e.kind, e.pos.x, e.pos.y, e.hp)
    }
    strings.write_string(&b, "]}\n")
    link.out_len = strings.builder_len(b)
}

// The contents of an open smelter or barrel window.
@(private="file")
agent_write_window :: proc(b: ^strings.Builder, gs: ^Game_State) {
    if gs.ui.show_smelter {
        sd := gs.world.sim_data[grid_idx(int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y))]
        fmt.sbprintf(b, `"smelter":{{"input":"%v","input_count":%d,"tray":"%v","tray_count":%d}},`,
            sd.in_item, sd.in_count, sd.store_item, sd.store_count)
    }
    if gs.ui.show_barrel {
        if barrel := barrel_at(gs, gs.level_index, gs.ui.barrel_tile); barrel != nil {
            strings.write_string(b, `"barrel":[`)
            comma := false
            for s, i in barrel.slots {
                if s.item == .None || s.count <= 0 do continue
                if comma do strings.write_byte(b, ',')
                comma = true
                fmt.sbprintf(b, `{{"slot":%d,"item":"%v","count":%d}}`, i, s.item, s.count)
            }
            strings.write_string(b, "],")
        }
    }
}

// Tiles as rows of single characters, with a legend for just the ones present.
@(private="file")
agent_write_view :: proc(b: ^strings.Builder, gs: ^Game_State, v: Agent_View) {
    alphabet := AGENT_TILE_CHARS
    chars: [Tile_Type]u8
    next := 0
    fmt.sbprintf(b, `"view":{{"x":%d,"y":%d,"w":%d,"h":%d,"rows":[`, v.x, v.y, v.w, v.h)
    for y in v.y ..< v.y + v.h {
        if y > v.y do strings.write_byte(b, ',')
        strings.write_byte(b, '"')
        for x in v.x ..< v.x + v.w {
            t := get_tile(&gs.world, x, y)
            if chars[t] == 0 {
                // More kinds in one view than characters: the rest share the last.
                chars[t] = alphabet[min(next, len(alphabet) - 1)]
                next += 1
            }
            strings.write_byte(b, chars[t])
        }
        strings.write_byte(b, '"')
    }
    strings.write_string(b, `],"solid":"`)
    for ch, t in chars do if ch != 0 && .Solid in terrain_table[t].flags do strings.write_byte(b, ch)
    strings.write_string(b, `","legend":{`)
    comma := false
    for ch, t in chars {
        if ch == 0 do continue
        if comma do strings.write_byte(b, ',')
        comma = true
        fmt.sbprintf(b, `"%c":"%v"`, rune(ch), t)
    }
    strings.write_string(b, "}}")
}
