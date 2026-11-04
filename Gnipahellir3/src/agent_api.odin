package game

// agent_api.odin — lets an outside agent play the running game over a local
// socket.  Nothing listens until a human picks "Let an agent play" on the title,
// in any build, or a debug build starts with GNIPA_AGENT_PORT set.
//
// One port on 127.0.0.1.  A connection is judged by its first line: GET gets the
// plain-text brief (agent_write_brief) and is closed, a JSON object makes it the
// client, anything else is refused.  So a connection that has said nothing yet
// does not drive the game, and the brief is served while a client plays.  Up to
// AGENT_PENDING_MAX connections wait on their first line at once.  A JSON first
// line while a client drives makes a watcher: up to AGENT_READERS_MAX of them ask
// for state and hear every event line.  A watcher that sends anything else while
// nobody drives takes the game, so a client that lost its connection comes back.
//
// Protocol: one JSON object per line each way.
//   {"cmd":"state"}                                 full state, x/y/w/h pick the tile view
//   {"cmd":"act","move":"left","frames":30,...}     play those frames, reply with state after
//                                                   a refused warp answers ok:false and plays
//                                                   nothing; a place the game turned away
//                                                   leaves "refused":"place" in the state,
//                                                   the reason, if any, in notes;
//                                                   withdraw:true pulls an open smelter's ore,
//                                                   withdraw_fuel:true its wood; feed takes
//                                                   the whole stack unless count says less;
//                                                   tithe:slot, on the death screen, picks
//                                                   the item to send on, and again to take
//                                                   it back: state lists "tithe":{ready_in,
//                                                   chosen, offerable}, and both it and
//                                                   dismiss wait out ready_in ticks first.
//                                                   Dismiss then moves on.
//                                                   With a command wand selected: zone:
//                                                   [x0,y0,x1,y1] drags the Gather zone,
//                                                   monument:"Clay_Hearth" with at:[x,y]
//                                                   marks a Build anchor, crew:true is the
//                                                   crew's Gather/Build key; state's crew
//                                                   lists the golems, zone and monument
//   {"cmd":"goals","add":[{"do":"act",...},...]}    queue goals (agent_exec.odin); answers
//                                                   their ids, or ok:false for a full queue
//   {"cmd":"goals","clear":true} / "cancel":id      drop them; each ends as failed, cancelled
//   {"cmd":"reflexes","potion":false,...}           switch the hero's reflexes; answers with each
//   {"cmd":"home","at":[x,y]}                       mark this level's home for the home goal; no
//                                                   at clears it
//                                                   a view's "solid" chars stop the body from
//                                                   every side, "floor" ones hold it up: the
//                                                   body walks through structures and stands
//                                                   on them, and passes doors both ways
//   {"cmd":"plan"|"wait"|"idle"|"realtime",...}   retired (card 154): ok:false, use goals;
//                                                   the game never waits for a client
//   {"cmd":"objective","goal":"...","step":"..."}   tell the watcher what you are up to;
//                                                   a new goal files the old one, with
//                                                   "result":"failed" if it did not work
//   {"cmd":"say","text":"..."}                      a line to the watcher, over the item bar
//   {"cmd":"listen","seconds":60}                   answers with state when the watcher has
//                                                   typed a line, or when the time is up
//
// The watcher talks back: in agent mode Enter opens a field over the item bar,
// Enter sends, Esc closes.  It is the one key input an agent's game hears, and
// it reaches only the agent: every reply carries the unread lines in "heard",
// once.  Both sides are recorded and logged; a replay sends the says again and
// prints the watcher's lines, and neither touches the sim.
//
// While a client is connected the game runs in real time: every frame ticks,
// goal or none, and the executor plays the queue.  Every tick is a fixed 1/60 s
// step, and the keyboard and mouse are ignored.  Realtime off is the old waiting
// game, kept for tests and --replay and out of a client's reach: it ticks while a
// goal plays, and between goals idles at quarter speed with empty input for up to
// AGENT_IDLE_MAX ticks, then holds (idle_off holds at once).  Disconnecting hands
// the game straight back to the keyboard.
//
// Replies carry "re":<cmd>.  Once a client has sent a goals command the game
// also pushes event lines unasked, each with "event": goal_done, goal_failed
// (reason), goal_paused and goal_resumed (id, reason), idle (threats), hurt (by,
// hp), died (by), level_changed (level) and heard (text).
//
// An act drives the same seams a player does: Input_State for held input, the
// Event_Queue for one-shot verbs.  It is never handed a shortcut into world
// state, so every rule (reach, costs, stations) still applies.
//
// The link lives in main, not in Game_State: game_state_init zeroes gs on a New
// Game, and the socket has to outlive that.  gs.agent is rewritten every frame.
//
// A run is recorded and repeatable.  acts.jsonl holds every goal with the frame
// it arrived on, every cancel and clear, and every finished act with where it
// left the player.  The same goals on the same frames from the same GNIPA_SEED
// play out the same: the frame clock starts at the first connect, the step is
// fixed, and a New Game while driving derives its seeds from the last one.
// Each goal's end is a row too ("done" or "failed" with the id), and so is each
// window opening or closing ("window"), for `gnipa --summary`.  `gnipa --replay`
// feeds the goal rows back on their frames and stops at a disconnect.
//
// GNIPA_AGENT_TURBO=1 is for harness runs: the window draws about once a second, so
// ticks stop waiting for the display.  The sim never sees that; the frame clock in
// acts.jsonl does not care either, which is why a replay goes by it.
//
// An agent run writes a save and truncates action.log in the working directory,
// so agent_open refuses to run anywhere that does not hold AGENT_SANDBOX_FILE.
// The title option, and `gnipa --agent-run`, build such a folder and move the
// process into it, so every relative path the game writes lands there.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

AGENT_PORT_ENV     :: "GNIPA_AGENT_PORT"
AGENT_TITLE_ENV    :: "GNIPA_AGENT_TITLE" // a port: boot as if [A] was pressed
AGENT_TITLE_PORT   :: 7878 // the first port the title tries
AGENT_TITLE_PORTS  :: 16   // and how many, so a second game still gets one
AGENT_RUNS_DIR     :: "agent_runs"
AGENT_BRIEF_MAX    :: 64 * 1024
AGENT_TURBO_ENV    :: "GNIPA_AGENT_TURBO"
AGENT_TURBO_DRAW   :: 1 * time.Second // between draws of a turbo run
AGENT_SANDBOX_FILE :: "agent_sandbox"
AGENT_STEP         :: f32(1.0 / 60.0)
AGENT_MAX_FRAMES   :: 600
AGENT_IDLE_EVERY   :: 4    // render frames per tick of a plan or an idle wait
AGENT_IDLE_MAX     :: 180  // ticks per wait, 3 s of game time; a first guess
AGENT_PUSH_MAX     :: 32 * 1024  // event lines waiting for the next send; past this they drop
AGENT_VIEW_ZOOM    :: f32(2.5) // the framing a watching human gets; the wheel still changes it
AGENT_VIEW_W       :: 41   // default tile view, centered on the player
AGENT_VIEW_H       :: 25
AGENT_LINE_MAX     :: 4096
AGENT_REPLY_MAX    :: 512 * 1024
AGENT_ITEMS_MAX    :: 2000 // ground piles in one reply; caps it well inside AGENT_REPLY_MAX
AGENT_SEND_TIMEOUT :: 2 * time.Second // a client that stops reading is dropped
AGENT_LISTEN_S     :: 60   // a listen's wait when it names none
AGENT_LISTEN_MAX_S :: 600
AGENT_PENDING_MAX  :: 4    // connections waiting on their first line; a newer one past this sheds the oldest
AGENT_READERS_MAX  :: 4    // watching clients beside the one that drives

// Printable, JSON-safe, one per distinct tile type seen in a view.
AGENT_ACTS_FILE    :: "acts.jsonl"
AGENT_FIGHT_FILE   :: "fight.log"
AGENT_RUN_LOGS     :: "acts.jsonl, action.log and fight.log" when GAME_DEBUG else "acts.jsonl and fight.log" // a release build writes no action.log
AGENT_FIGHT_RANGE  :: 30      // tiles from the player
AGENT_FIGHT_BUF    :: 64 * 1024

// What a run has learned, from the lessons a run keeps up.  The file's head is about
// this repo's harness, not the game.
AGENT_LESSONS      :: #load("../gnipa_project/agent_lessons.md", string)
AGENT_LESSONS_FROM :: "## How to play it"

AGENT_TILE_CHARS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#*+-=~:;.,!?@$%^&()[]{}<>/|_"

// An accepted connection whose first line is not in yet.
Agent_Pending :: struct {
    sock: net.TCP_Socket,
    len:  int,
    buf:  [AGENT_LINE_MAX]u8,
}

// A watching client: its unread request bytes and the event lines it has not had.
Agent_Reader :: struct {
    sock:     net.TCP_Socket,
    in_len:   int,
    in_buf:   [AGENT_LINE_MAX]u8,
    push_len: int,
    push:     [AGENT_PUSH_MAX]u8,
}

Agent_Link :: struct {
    listening:   bool,
    connected:   bool,
    turbo:       bool,           // draw_game only every AGENT_TURBO_DRAW
    last_draw:   time.Tick,
    realtime:    bool,           // tick every frame, goal or none
    idle_off:    bool,           // the waiting game holds between goals, no idle ticks (tests)
    idle_step:   int,            // render frames since the last slow tick
    idle_ticks:  int,            // idle ticks in this wait, recorded when it ends
    goals:       Agent_Goals,
    events_on:   bool,           // the client speaks goals, so it hears events
    seen_hp:     int,            // the player as the last tick left it, for the events
    seen_dead:   bool,
    seen_level:  int,
    seen_notes:  int,            // goals.note_count as last pushed
    seen_window: bool,
    push_len:    int,
    push:        [AGENT_PUSH_MAX]u8,  // event lines not yet sent
    awaiting:    bool,           // a listen waits for the watcher's line
    await_until: time.Tick,      // or until then
    port:        int,
    listener:    net.TCP_Socket,
    client:      net.TCP_Socket,
    pending:     [AGENT_PENDING_MAX]Agent_Pending, // oldest first
    pending_n:   int,
    readers:     [AGENT_READERS_MAX]Agent_Reader,
    readers_n:   int,
    run_port:    int,            // gnipa --agent-run: this port only, and the next three fields
    run_seed:    u32,
    run_seeded:  bool,
    run_dir:     string,
    brief:       [AGENT_BRIEF_MAX]u8,
    panel:       Agent_Panel,
    reply_due:   bool,           // an act finished: its state waits in out
    recording:   bool,
    acts_file:   ^os.File,
    fight_file:  ^os.File,
    fight_len:   int,
    fight_buf:   [AGENT_FIGHT_BUF]u8,
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
        fmt.eprintfln("%s is set but this folder has no %s file: an agent run would overwrite the save and action.log here. Use gnipa --agent-run.",
            AGENT_PORT_ENV, AGENT_SANDBOX_FILE)
        os.exit(1)
    }
    sock, err := agent_bind(port)
    if err != nil {
        fmt.eprintfln("agent api: cannot listen on 127.0.0.1:%d: %v", port, err)
        os.exit(1)
    }
    agent_arm(link, sock, port)
    fmt.printfln("agent api: listening on 127.0.0.1:%d", port)
}

// A bound listener goes live; acts and fights record into the working directory.
@(private="file")
agent_arm :: proc(link: ^Agent_Link, sock: net.TCP_Socket, port: int) {
    net.set_blocking(sock, false)
    link.listener  = sock
    link.listening = true
    link.port      = port
    link.turbo     = os.get_env(AGENT_TURBO_ENV, context.temp_allocator) != ""
    if fd, ferr := os.open(AGENT_ACTS_FILE, os.O_WRONLY | os.O_CREATE | os.O_APPEND); ferr == nil {
        link.acts_file = fd
        link.recording = true
    }
    if fd, ferr := os.open(AGENT_FIGHT_FILE, os.O_WRONLY | os.O_CREATE | os.O_APPEND); ferr == nil {
        link.fight_file = fd
    }
}

// After boot: a run started under GNIPA_AGENT_PORT has been the agent's from the
// first line, and GNIPA_AGENT_TITLE asks for what [A] does.
agent_boot_title :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if link.listening {
        action_log_release(gs)
        gs.ui.agent_port = link.port
        return
    }
    gs.ui.agent_requested = os.get_env(AGENT_TITLE_ENV, context.temp_allocator) != ""
}

// "Let an agent play": a port, a folder of its own and a new world, and the game
// moves into that folder.  Nothing of the human's is read or written after this:
// the save, stats and action.log paths are relative, and the stats in memory go.
// A failure changes nothing and leaves the title up.
agent_title_start :: proc(link: ^Agent_Link, gs: ^Game_State) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    gs.ui.agent_requested = false
    gs.ui.agent_failed    = true

    sock, port, seed, folder, bound := agent_run_choice(link, gs)
    if !bound do return
    if !agent_sandbox_make(folder, seed) || os.set_working_directory(folder) != nil {
        net.close(sock)
        return
    }

    agent_arm(link, sock, port)
    agent_run_reset(gs, seed, port, SAVE_FILE, STATS_FILE)
    action_log_begin_run(gs)
    action_log_release(gs)
    log_action(gs, "World seed %d", seed)
    fmt.printfln("agent api: listening on 127.0.0.1:%d, run folder %s", port, folder)
}

// The port, seed and folder of a new run: the title's, or what gnipa --agent-run
// named in link.  A named port is that port or nothing.
agent_run_choice :: proc(link: ^Agent_Link, gs: ^Game_State) -> (sock: net.TCP_Socket, port: int, seed: u32, folder: string, bound: bool) {
    port = link.run_port
    if port > 0 {
        err: net.Network_Error
        sock, err = agent_bind(port)
        bound = err == nil
    } else {
        base := AGENT_TITLE_PORT
        if n, ok := strconv.parse_int(os.get_env(AGENT_TITLE_ENV, context.temp_allocator)); ok do base = n
        sock, port, bound = agent_title_bind(base)
    }
    if !bound do return
    seed   = link.run_seed if link.run_seeded else title_chosen_seed(gs)
    folder = agent_run_folder(port, link.run_dir if link.run_dir != "" else AGENT_RUNS_DIR)
    return
}

// The state the sandbox starts from: a new world, none of the human's stats, and
// the title up with the address.  save_path comes back too: a boot that set an
// unreadable save aside has cleared it.
agent_run_reset :: proc(gs: ^Game_State, seed: u32, port: int, save_path, stats_path: string) {
    gs.stats      = {}
    gs.save_path  = save_path
    gs.stats_path = stats_path
    start_new_game_with(gs, seed)
    gs.ui.show_title   = true
    gs.ui.agent_port   = port
}

// Loopback only, the one bind the game makes.  A burst of connections between two
// frames queues in the backlog until the next frame accepts it.
agent_bind :: proc(port: int) -> (net.TCP_Socket, net.Network_Error) {
    return net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port}, AGENT_PENDING_MAX)
}

// The title's ports, from base up.
agent_title_bind :: proc(base: int) -> (sock: net.TCP_Socket, port: int, ok: bool) {
    for p in base ..< base + AGENT_TITLE_PORTS {
        s, err := agent_bind(p)
        if err == nil do return s, p, true
    }
    return
}

// The port keeps two games from sharing a folder started in the same second.
@(private="file")
agent_run_folder :: proc(port: int, dir: string) -> string {
    now := time.now()
    y, mo, d := time.date(now)
    h, mi, s := time.clock(now)
    return fmt.tprintf("%s/%04d%02d%02d-%02d%02d%02d-%d", dir, y, int(mo), d, h, mi, s, port)
}

// A folder a run can live in.  The sprite bank
// is reloaded from disk on every New Game, so it comes along.
agent_sandbox_make :: proc(folder: string, seed: u32, art := PIXEL_ART_FILE) -> bool {
    if os.make_directory_all(folder) != nil do return false
    join :: proc(folder, name: string) -> string { return fmt.tprintf("%s/%s", folder, name) }
    if os.write_entire_file(join(folder, AGENT_SANDBOX_FILE), []u8{}) != nil do return false
    if os.write_entire_file(join(folder, "seed"), transmute([]u8)fmt.tprintf("%d\n", seed)) != nil do return false
    if data, err := os.read_entire_file_from_path(art, context.temp_allocator); err == nil {
        if os.write_entire_file(join(folder, PIXEL_ART_FILE), data) != nil do return false
    }
    return true
}

// Whether this frame draws.  Only a connected turbo run skips: the keyboard's
// game and a run nobody is driving always draw.
agent_draw_due :: proc(link: ^Agent_Link, now := time.Tick{}) -> bool {
    if !link.turbo || !link.connected do return true
    t := now if now != (time.Tick{}) else time.tick_now()
    if time.tick_diff(link.last_draw, t) < AGENT_TURBO_DRAW do return false
    link.last_draw = t
    return true
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
    for link.pending_n > 0 do agent_pending_close(link, 0)
    for link.readers_n > 0 do agent_reader_drop(link, 0)
    link.listening = false
}

// Before each frame: serves the client and says whether the sim ticks.
agent_pump :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    if !link.listening do return true

    if link.awaiting do agent_await(link, gs, time.tick_now())
    agent_flush_push(link, gs)
    if link.reply_due {
        link.reply_due = false
        agent_send(link, gs)
    }
    agent_accept(link)
    for i := 0; i < link.pending_n; {
        if !agent_read_pending(link, gs, i) do i += 1  // a served one leaves, and the next takes its index
    }
    if link.connected && (agent_listening(link) || link.awaiting) do agent_read(link, gs)
    // After the client's read: a client gone this frame lets a watcher take over.
    for i := 0; i < link.readers_n; {
        if agent_serve_reader(link, gs, i) do i += 1  // one that left gives its index to the next
    }
    if !link.connected {
        gs.agent = {}  // back to the keyboard, with nothing of the last act left to replay
        return true
    }
    return agent_drive(link, gs)
}

// Connections wait on their first line side by side, so a brief fetched just
// before a connect is still answered.  Past AGENT_PENDING_MAX the oldest goes:
// no timer can run here, and silent connections must not keep the brief from the next.
@(private="file")
agent_accept :: proc(link: ^Agent_Link) {
    for {
        sock, _, err := net.accept_tcp(link.listener)
        if err != nil do return
        if link.pending_n == AGENT_PENDING_MAX do agent_pending_close(link, 0)
        net.set_blocking(sock, false)
        net.set_option(sock, .TCP_Nodelay, true)
        link.pending[link.pending_n].sock = sock
        link.pending[link.pending_n].len  = 0
        link.pending_n += 1
    }
}

// Drops slot i; the younger ones move up, so the oldest stays first.
@(private="file")
agent_pending_close :: proc(link: ^Agent_Link, i: int, close := true) {
    if close do net.close(link.pending[i].sock)
    copy(link.pending[i:link.pending_n], link.pending[i + 1:link.pending_n])
    link.pending_n -= 1
}

// Reads slot i; true when it is answered or gone and has left the list.
@(private="file")
agent_read_pending :: proc(link: ^Agent_Link, gs: ^Game_State, i: int) -> (left: bool) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    p := &link.pending[i]
    n, err := net.recv_tcp(p.sock, p.buf[p.len:])
    if err == .Would_Block || err == .Timeout do return false
    if err != nil || n == 0 {  // gone, or a line this long is not the protocol
        agent_pending_close(link, i)
        return true
    }
    p.len += n
    nl := strings.index_byte(string(p.buf[:p.len]), '\n')
    if nl < 0 do return false
    line := string(p.buf[:nl])
    switch {
    case strings.has_prefix(line, "GET "):
        agent_pending_send(p.sock, agent_http_brief(link, gs))
    case !strings.has_prefix(strings.trim_left_space(line), "{"):
        // Not only tidiness: a web page can POST here, and its body must not play.
        agent_pending_send(p.sock, `{"ok":false,"error":"send one JSON object per line, or GET for the brief"}` + "\n")
    case link.connected && link.readers_n == AGENT_READERS_MAX:
        agent_pending_send(p.sock, `{"ok":false,"error":"another agent is playing and every watcher's place is taken"}` + "\n")
    case link.connected:
        r := &link.readers[link.readers_n]
        r.sock, r.push_len = p.sock, 0
        r.in_len = copy(r.in_buf[:], p.buf[:p.len])
        link.readers_n += 1
        agent_pending_close(link, i, false)
        return true
    case:
        agent_promote(link, gs, p.sock, p.buf[:p.len])
        agent_pending_close(link, i, false)
        return true
    }
    agent_pending_close(link, i)
    return true
}

@(private="file")
agent_pending_send :: proc(sock: net.TCP_Socket, text: string) {
    net.set_blocking(sock, true)
    net.set_option(sock, .Send_Timeout, AGENT_SEND_TIMEOUT)
    net.send_tcp(sock, transmute([]u8)text)
}

// A watcher's turn: its waiting events, then each whole line it sent.  State is
// answered; anything else is refused while a client drives, and takes the game
// when none does.  False when it has left the list, dropped or promoted.
@(private="file")
agent_serve_reader :: proc(link: ^Agent_Link, gs: ^Game_State, i: int) -> (stays: bool) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    r := &link.readers[i]
    sent := agent_reader_send(r, r.push[:r.push_len])
    r.push_len = 0
    for sent {
        nl := strings.index_byte(string(r.in_buf[:r.in_len]), '\n')
        if nl < 0 {
            // A full buffer reads 0, and goes: a line this long is not the protocol.
            n, err := net.recv_tcp(r.sock, r.in_buf[r.in_len:])
            if err == .Would_Block || err == .Timeout do return true
            if err != nil || n == 0 do break
            r.in_len += n
            continue
        }
        line := string(r.in_buf[:nl])
        cmd  := agent_line_cmd(line)
        if !link.connected && cmd != "state" {
            agent_promote(link, gs, r.sock, r.in_buf[:r.in_len])
            agent_reader_drop(link, i, false)
            return false
        }
        if cmd == "state" {
            unread := link.panel.heard_len  // the watcher's lines are the driver's to take
            agent_handle_line(link, gs, line)
            link.panel.heard_len = unread
        } else {
            agent_reply_error(link, cmd, "another agent drives: a watcher can only ask for state")
        }
        sent = agent_reader_send(r, link.out[:link.out_len])
        r.in_len = copy(r.in_buf[:], r.in_buf[nl + 1:r.in_len])
    }
    agent_reader_drop(link, i)
    return false
}

// A request's cmd, or "" for a line that has none.
@(private="file")
agent_line_cmd :: proc(line: string) -> string {
    value, _ := json.parse_string(line, allocator = context.temp_allocator)
    root, _ := value.(json.Object)  // not an object: no cmd
    cmd, _ := root["cmd"].(json.String)
    return cmd
}

@(private="file")
agent_reader_send :: proc(r: ^Agent_Reader, data: []u8) -> bool {
    net.set_blocking(r.sock, true)
    net.set_option(r.sock, .Send_Timeout, AGENT_SEND_TIMEOUT)
    n, err := net.send_tcp(r.sock, data)
    net.set_blocking(r.sock, false)
    return err == nil && n == len(data)
}

// Drops watcher i; the younger ones move up.
@(private="file")
agent_reader_drop :: proc(link: ^Agent_Link, i: int, close := true) {
    if close do net.close(link.readers[i].sock)
    copy(link.readers[i:link.readers_n], link.readers[i + 1:link.readers_n])
    link.readers_n -= 1
}

// The first JSON line: this connection is the client from here, the bytes it has
// sent first.
@(private="file")
agent_promote :: proc(link: ^Agent_Link, gs: ^Game_State, sock: net.TCP_Socket, sent: []u8) {
    link.client       = sock
    link.connected    = true
    link.in_len       = copy(link.in_buf[:], sent)
    link.realtime     = true
    link.panel        = {}
    link.goals        = {}
    link.events_on    = false
    link.push_len     = 0
    link.idle_off     = false
    link.idle_step    = 0
    link.idle_ticks   = 0
    if gs.ui.show_title do gs.frame = 0  // time spent on the title screen is not part of a run
}

@(private="file")
agent_http_brief :: proc(link: ^Agent_Link, gs: ^Game_State) -> string {
    body := agent_write_brief(link, gs)
    return fmt.tprintf("HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
}

// The brief, written fresh for each GET from the game as it stands.
agent_write_brief :: proc(link: ^Agent_Link, gs: ^Game_State) -> string {
    b := strings.builder_from_bytes(link.brief[:])
    w := &b
    fmt.sbprintf(w, "GNIPAHELLIR\n\n")
    fmt.sbprintf(w, "You are the player. A human gave you this address and watches you in the game's window.\n")
    fmt.sbprintf(w, "HP is 10 and does not regenerate. Death ends the life; the goal is to break the Final Seal.\n\n")

    fmt.sbprintf(w, "NOW\n")
    fmt.sbprintf(w, "address: 127.0.0.1:%d, loopback only\n", link.port)
    fmt.sbprintf(w, "world seed: %d\n", gs.world_seed)
    fmt.sbprintf(w, "screen: %s, level %d, frame %d\n", agent_screen(gs), gs.level_index, gs.frame)
    fmt.sbprintf(w, "client: %s\n", "another agent is connected: a second connection watches (state and events)" if link.connected else "none, the socket is free")
    objective: [128]u8
    fmt.sbprintf(w, "the game's objective line: %s\n", current_objective(gs, objective[:]))
    if link.panel.goal.len > 0 {
        fmt.sbprintf(w, "the panel's goal: %s\n", string(link.panel.goal.buf[:link.panel.goal.len]))
    }

    fmt.sbprintf(w, "\nCONNECT\n")
    fmt.sbprintf(w, "Same port, plain TCP: one JSON object per line each way. No HTTP, no keys, no account.\n")
    fmt.sbprintf(w, "Hold ONE connection for the whole run, from a background process if your tool calls are short: ")
    fmt.sbprintf(w, "when it closes the game runs on in real time with nobody at the keys.\n")
    fmt.sbprintf(w, "  import json, socket\n")
    fmt.sbprintf(w, "  s = socket.create_connection((\"127.0.0.1\", %d)); f = s.makefile(\"rb\")\n", link.port)
    fmt.sbprintf(w, "  def ask(o): s.sendall((json.dumps(o) + \"\\n\").encode()); return json.loads(f.readline())\n")
    fmt.sbprintf(w, "  ask({{\"cmd\": \"act\", \"dismiss\": True}})  # closes the title; the run starts\n")

    fmt.sbprintf(w, "\nCOMMANDS\n")
    fmt.sbprintf(w, "{{\"cmd\":\"state\",\"x\":0,\"y\":0,\"w\":%d,\"h\":%d}}  all optional: the default view is %dx%d round you, and the whole level is yours to read\n",
        GRID_W, GRID_H, AGENT_VIEW_W, AGENT_VIEW_H)
    fmt.sbprintf(w, "{{\"cmd\":\"goals\",\"add\":[{{\"do\":\"go\",\"to\":[90,60]}},{{\"do\":\"act\",\"move\":\"right\",\"frames\":30}},...]}}  queues goals, played in order while the game runs; answers their ids\n")
    fmt.sbprintf(w, "  You only send goals: the game turns each into the keys and mouse a player would use, so a goal can do nothing a player cannot.\n")
    fmt.sbprintf(w, "  The queue holds %d; a full one answers ok:false. {{\"cmd\":\"goals\",\"cancel\":id}} or \"clear\":true drops goals, which then end failed\n", AGENT_GOALS_MAX)
    fmt.sbprintf(w, "  state's goals lists each one: queued, running (with left), done, or failed with a reason. do names the kind:\n")
    for row in agent_goal_kinds do fmt.sbprintf(w, "    %s: %s\n", row.name, row.params)
    fmt.sbprintf(w, "  a go or home that cannot get nearer fails: no_route (nothing nearer to reach), blocked (no headway for %.0f s), hazard (the tile burns or drowns)\n", HERO_GO_STUCK_S)
    fmt.sbprintf(w, "  a work goal picks its tool (the longest mine wand the mana fires, else the pickaxe) and works windows at a person's pace;\n")
    fmt.sbprintf(w, "  it fails with no_recipe, no_station, no_item, out_of_reach, unreachable, unsafe, cornered (wary, and every stand in reach has no cheap way out), blocked or full first, then what\n")
    fmt.sbprintf(w, "  a fight is done when its enemy is gone; it fails with no_item, no_target, unreachable or low_hp (backed off) first\n")
    fmt.sbprintf(w, "  when the hero dies every goal but an act fails with died: queue again for the next life\n")
    fmt.sbprintf(w, "  an act holds its keys for 1..%d ticks at 60 a second; it fails only when its verb is refused as it starts, or at a drop that hurts or a burn ahead\n", AGENT_MAX_FRAMES)
    fmt.sbprintf(w, "The act fields, for an act goal:\n")
    fmt.sbprintf(w, "  move: left, right, none. jump, down, interact, dismiss, warp: true\n")
    fmt.sbprintf(w, "  one of mine, place, use, reclaim: [x,y] in tiles. Tiles are %dx%d; state's player x,y are tiles too\n", GRID_W, GRID_H)
    fmt.sbprintf(w, "    whole numbers aim at the tile's centre; fractions aim at that point within it (10.0 is the tile's left edge)\n")
    fmt.sbprintf(w, "  one of select, equip, feed (with count), store, take: bag slot. select -1 is an empty hand\n")
    fmt.sbprintf(w, "  craft: item name, from state's craftable. collect, withdraw, withdraw_fuel: true, on the smelter a use opened\n")
    fmt.sbprintf(w, "  store and take work on the barrel a use opened. tithe: slot, on the death screen; then dismiss moves on\n")
    fmt.sbprintf(w, "  The death screen hears neither tithe nor dismiss for about its first %d ticks: state's tithe.ready_in counts them down\n", int(DEATH_INPUT_DELAY / AGENT_STEP))
    fmt.sbprintf(w, "  with a command wand selected, place: [x,y] sets down a bound golem, and one of:\n")
    fmt.sbprintf(w, "    zone: [x0,y0,x1,y1]  drags the Gather zone, up to %dx%d tiles. crew: true  flips this level's golems between Gather and Build\n", GOLEM_ZONE_MAX_W, GOLEM_ZONE_MAX_H)
    fmt.sbprintf(w, "    monument: Clay_Hearth, Golem_Depot or World_Anchor, with at: [x,y] in reach  the anchor Build golems raise it from\n")
    fmt.sbprintf(w, "  state's crew lists the golems (slot, status, mode, job, hp, broken, recovering, carry, target, pack), and this level's zone and monument.\n")
    fmt.sbprintf(w, "  The roster's per-golem orders are goals: crew_mode, crew_call, crew_pickup. birds lists the sky flocks in view: scenery, harmless\n")
    fmt.sbprintf(w, "{{\"cmd\":\"home\",\"at\":[x,y]}}  marks this level's home for the home goal; with no at, the mark goes and home is the surface spawn\n")
    fmt.sbprintf(w, "{{\"cmd\":\"reflexes\",\"potion\":false}}  the hero's reflexes, under every goal, all on at first; answers with each:\n")
    fmt.sbprintf(w, "  leave_hazard: walks and jumps out of lava, water or a burn. potion: drinks a health potion under %.0f%% hp\n", HERO_LOW_HP_FRAC * 100)
    fmt.sbprintf(w, "  floor_dig: never digs the floor under itself over a fall that kills or burns. rim_dig: never digs beside water or lava\n")
    fmt.sbprintf(w, "  fight_back: strikes back for %.1f s at the enemy that hurt it, with the sword in reach (else the pickaxe, %d damage to the sword's %d) or the wand at range\n", HERO_FIGHT_BACK_S, PICKAXE_DAMAGE, SWORD_DAMAGE)
    fmt.sbprintf(w, "    and is the hero's own fighting: off, it neither fights an enemy that comes at it nor shoots back as it runs; a fight goal still fights\n")
    fmt.sbprintf(w, "{{\"cmd\":\"act\",...}}  one act goal with those fields in place of the queue: it drops what is queued and answers with state when it is done.\n")
    fmt.sbprintf(w, "A refused request answers ok:false with error. State's notes hold the toasts, the only reason some refusals give.\n")
    fmt.sbprintf(w, "A view's rows are one character per tile: legend names them, solid stops you, floor holds you up. enemies lists only what is inside the view, x,y the top-left of a w x h body in tiles.\n")
    fmt.sbprintf(w, "screen is title, settings, snapshots, menu, dead, book, won or play. dismiss gets past any but play, and starts the next life after dead or won.\n")

    fmt.sbprintf(w, "\nFIRST STEPS\n")
    fmt.sbprintf(w, "A trip: {{\"cmd\":\"goals\",\"add\":[{{\"do\":\"go\",\"to\":[x,y]}}]}}, then read the events for goal_done or goal_failed.\n")
    fmt.sbprintf(w, "A walk: {{\"cmd\":\"act\",\"move\":\"right\",\"frames\":60}}. move is the key; a key the game does not know does nothing and gives no error.\n")
    fmt.sbprintf(w, "Walking is about 4 tiles a second and stops when the act ends. A jump clears about 2 tiles. Falls hurt from a few tiles up.\n")
    fmt.sbprintf(w, "Read the whole level once: items lists what lies on the ground by tile cell, and walking through a cell takes up what lies there. The pickaxe is the first thing to find.\n")
    fmt.sbprintf(w, "select takes the slot number from state's inventory, not a hotbar key. Bare hands mine only %s, at %d times a pickaxe's hits, with no word until it drops; nothing else yields without the pickaxe.\n", terrain_table[BARE_HAND_TILE].name, BARE_HAND_MULT)
    fmt.sbprintf(w, "This address's HTTP side only reads the brief; everything else is the socket.\n")

    fmt.sbprintf(w, "\nHOW THE GAME WAITS\n")
    fmt.sbprintf(w, "It does not: while you are connected the game runs in real time at a fixed step, 60 ticks a second, and the keyboard is ignored.\n")
    fmt.sbprintf(w, "Real time is fixed: no command pauses or slows it, goal or none, thinking or not.\n")
    fmt.sbprintf(w, "Only the death screen and the menus stop play. Queue goals before a long think, and pick safe ones.\n")
    fmt.sbprintf(w, "The hero never moves while a window is open: a goal that would closes it first, and one that works the window holds still.\n")

    fmt.sbprintf(w, "\nEVENTS\n")
    fmt.sbprintf(w, "Every reply carries \"re\", the cmd it answers. After your first goals command the game also sends lines unasked,\n")
    fmt.sbprintf(w, "each with \"event\" and the frame \"f\": goal_done (id), goal_failed (id, reason), hurt (by, hp), died (by), level_changed (level), heard (text),\n")
    fmt.sbprintf(w, "goal_paused and goal_resumed (id, reason: fight, flee, ledge or retreat), idle (threats) once the queue runs dry.\n")
    fmt.sbprintf(w, "The hero has its own sense of danger: it fights or flees an enemy that comes at it and goes back to the goal after,\n")
    fmt.sbprintf(w, "stops at a drop the fall would hurt from (the goal fails, reason says the drop), and keeps to safe ground when idle.\n")

    fmt.sbprintf(w, "\nTHE GAME BINARY\n")
    fmt.sbprintf(w, "One binary does everything: the run, its replay and its reports. Every run folder holds %s.\n", AGENT_RUN_LOGS)
    strings.write_string(w, TOOL_USAGE)

    fmt.sbprintf(w, "\nOBJECTIVE PANEL\n")
    fmt.sbprintf(w, "The human reads your panel in the window, so keep it true:\n")
    fmt.sbprintf(w, "{{\"cmd\":\"objective\",\"goal\":\"kill Garm\",\"step\":\"perch at the east wall\"}}\n")
    fmt.sbprintf(w, "A new goal files the old one; add \"result\":\"failed\" if it did not work.\n")

    fmt.sbprintf(w, "\nTALK\n")
    fmt.sbprintf(w, "The human can type to you from the window. Read state's heard in every reply: each line comes once, so answer it.\n")
    fmt.sbprintf(w, "{{\"cmd\":\"say\",\"text\":\"...\"}}  your answer, shown over the item bar and in your panel, up to %d characters\n", AGENT_TEXT_MAX)
    fmt.sbprintf(w, "{{\"cmd\":\"listen\",\"seconds\":60}}  waits up to %d s for a line from the human, then replies with state. When you have nothing to do, listen.\n", AGENT_LISTEN_MAX_S)

    fmt.sbprintf(w, "\nTHE END OF A RUN\n")
    fmt.sbprintf(w, "Finish the rituals, kill Garm, take the Hell Key through the gate, and act with interact:true beside the Final Seal. ")
    fmt.sbprintf(w, "Stay alive through the ceremony. screen says won, and a dismiss starts over.\n")

    fmt.sbprintf(w, "\nLESSONS FROM EARLIER RUNS\n")
    fmt.sbprintf(w, "These come from earlier runs, most of them by a scripted bot before goals.\n\n")
    lessons := AGENT_LESSONS
    strings.write_string(w, lessons[strings.index(lessons, AGENT_LESSONS_FROM):])
    return strings.to_string(b)
}

// Points gs.agent at the link and decides whether the sim ticks.  The input
// itself comes from update_agent_goals, inside the tick.
agent_drive :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    gs.agent.driving = true
    gs.agent.panel   = &link.panel
    gs.agent.goals   = &link.goals
    gs.delta_time    = AGENT_STEP
    if link.realtime || agent_goals_busy(&link.goals) do return true
    if link.idle_off || link.idle_ticks >= AGENT_IDLE_MAX do return false
    return agent_slow_beat(link)
}

// The client can always talk, except while an act it sent is pending:
// those answer when they are done, and the next line waits for that.  A listen
// holds the next line until it has answered.
agent_listening :: proc(link: ^Agent_Link) -> bool {
    if link.awaiting do return false
    h := agent_goals_head(&link.goals)
    return h == nil || h.via != .Act
}

// A listen answers with state once the watcher has said something, or at its end.
agent_await :: proc(link: ^Agent_Link, gs: ^Game_State, now: time.Tick) {
    if link.panel.heard_len == 0 && time.tick_diff(link.await_until, now) < 0 do return
    link.awaiting = false
    agent_reply_state(link, gs, nil, "listen")
    link.reply_due = true
}

// The watcher's Enter: opens the field, or sends what is in it.  The line goes
// to the agent and the records, never to the game.
agent_chat_enter :: proc(link: ^Agent_Link, gs: ^Game_State) {
    p := &link.panel
    if !p.typing {
        p.typing = true
        return
    }
    if p.draft.len == 0 {
        p.typing = false
        return
    }
    if p.heard_len == AGENT_HEARD_MAX do return  // the agent has not caught up: the line waits in the field
    p.heard[p.heard_len] = {frame = gs.frame, text = p.draft}
    p.heard_len += 1
    p.sent   = p.draft
    p.draft  = {}
    p.typing = false
    agent_record_talk(link, gs, "heard", string(p.sent.buf[:p.sent.len]))
    log_action(gs, "Watcher says: %s", string(p.sent.buf[:p.sent.len]))
    agent_push_event(link, gs, "heard", fmt.tprintf(`"text":%s`, agent_quote(string(p.sent.buf[:p.sent.len]))))
}

// A typed character, if the field is open.  The window's font is ASCII.
agent_chat_char :: proc(p: ^Agent_Panel, ch: rune) {
    if !p.typing || ch < ' ' || ch > '~' || p.draft.len == AGENT_TEXT_MAX do return
    p.draft.buf[p.draft.len] = u8(ch)  // erase and close leave the rest zeroed: the text stays NUL-terminated
    p.draft.len += 1
}

agent_chat_erase :: proc(p: ^Agent_Panel) {
    if p.draft.len == 0 do return  // a shut field has no draft
    p.draft.len -= 1
    p.draft.buf[p.draft.len] = 0
}

agent_chat_close :: proc(p: ^Agent_Panel) {
    p.typing = false
    p.draft  = {}
}

@(private="file")
agent_slow_beat :: proc(link: ^Agent_Link) -> bool {
    link.idle_step += 1
    if link.idle_step < AGENT_IDLE_EVERY do return false
    link.idle_step = 0
    return true
}

// After a ticked frame: settles the goals that ended in it and pushes what the
// player went through.
agent_after_tick :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if !link.connected do return
    agent_fight_log(link, gs)
    if !link.goals.ran && !link.realtime do link.idle_ticks += 1
    link.goals.ran = false
    agent_hero_notes(link, gs)
    for &g in link.goals.slots[:link.goals.n] {
        if (g.status == .Done || g.status == .Failed) && !g.told do agent_goal_tell(link, gs, &g)
    }
    if open := agent_window_open(gs); open != link.seen_window {
        link.seen_window = open
        agent_record_op(link, gs, `"window":true` if open else `"window":false`)
    }
    agent_watch(link, gs)
}

// A goal's end: recorded, pushed, and for an act sent the old way, answered
// with state.
@(private="file")
agent_goal_tell :: proc(link: ^Agent_Link, gs: ^Game_State, g: ^Agent_Goal) {
    g.told = true
    if g.status == .Done && g.via != .Goal do agent_record_act(link, gs, g)
    if g.status == .Done {
        agent_record_op(link, gs, fmt.tprintf(`"done":%d`, g.id))
    } else {
        agent_record_op(link, gs, fmt.tprintf(`"failed":%d,"reason":%s`, g.id, agent_quote(string(g.reason.buf[:g.reason.len]))))
    }
    agent_fight_flush(link)
    flush_action_log(gs)  // what a reply reports is already on disk
    if g.status == .Done {
        agent_push_event(link, gs, "goal_done", fmt.tprintf(`"id":%d`, g.id))
    } else {
        agent_push_event(link, gs, "goal_failed", fmt.tprintf(`"id":%d,"reason":%s`, g.id, agent_quote(string(g.reason.buf[:g.reason.len]))))
    }
    // An act was judged live on the frame it came, and starts on it, so it ends
    // done, or failed at a ledge.
    if g.via == .Act {
        agent_reply_state(link, gs, nil, "act")
        link.reply_due = true
    }
}

// What the hero's behaviours did with the goals since the last push: a goal
// paused or resumed, and an empty queue.  A client too far behind gets the
// newest HERO_NOTES_MAX.
@(private="file")
agent_hero_notes :: proc(link: ^Agent_Link, gs: ^Game_State) {
    q := &link.goals
    for i in max(link.seen_notes, q.note_count - HERO_NOTES_MAX) ..< q.note_count {
        n := q.notes[i % HERO_NOTES_MAX]
        name := hero_note_names[n.kind]
        if n.kind == .Idle {
            agent_push_event(link, gs, name, fmt.tprintf(`"threats":%d`, n.threats))
        } else {
            agent_push_event(link, gs, name, fmt.tprintf(`"id":%d,"reason":"%s"`, n.goal, hero_behaviours[n.why].name))
        }
    }
    link.seen_notes = q.note_count
}

// Hurt, death and a new level, as the last tick left the player.
@(private="file")
agent_watch :: proc(link: ^Agent_Link, gs: ^Game_State) {
    p := &gs.player
    switch {
    case p.dead && !link.seen_dead:
        agent_push_event(link, gs, "died", fmt.tprintf(`"by":%s`, agent_quote(gs.death_by)))
    case !p.dead && p.hp < link.seen_hp:
        agent_push_event(link, gs, "hurt", fmt.tprintf(`"by":%s,"hp":%d`, agent_quote(gs.hurt_by), p.hp))
    }
    if gs.level_index != link.seen_level {
        agent_push_event(link, gs, "level_changed", fmt.tprintf(`"level":%d`, gs.level_index))
    }
    link.seen_hp    = p.hp
    link.seen_dead  = p.dead
    link.seen_level = gs.level_index
}

// One event line for every watcher, and for the client if it speaks goals.  A
// client this far behind loses events; state's goals still say how each one ended.
agent_push_event :: proc(link: ^Agent_Link, gs: ^Game_State, event, fields: string) {
    line := fmt.tprintf(`{{"event":"%s","f":%d,%s}}` + "\n", event, gs.frame, fields)
    for &r in link.readers[:link.readers_n] {
        if r.push_len + len(line) <= len(r.push) do r.push_len += copy(r.push[r.push_len:], line)
    }
    if !link.events_on do return
    if link.push_len + len(line) > len(link.push) do return
    link.push_len += copy(link.push[link.push_len:], line)
}

// A string as strict JSON.
agent_quote :: proc(text: string) -> string {
    quoted, _ := json.marshal(text, allocator = context.temp_allocator)
    return string(quoted)
}

// A goal for the queue: queued, and recorded with the frame it came on.
agent_goal_add :: proc(link: ^Agent_Link, gs: ^Game_State, kind: Agent_Goal_Kind, via: Agent_Goal_Via, line: string) -> int {
    id := agent_goals_push(&link.goals, kind, via, line)
    agent_record_op(link, gs, fmt.tprintf(`"goal":%s,"kind":"%s","id":%d,"via":"%v"`, line, agent_goal_kinds[kind].name, id, via))
    return id
}

// Ends a goal that has not finished.
agent_goal_cancel :: proc(link: ^Agent_Link, gs: ^Game_State, g: ^Agent_Goal, why: string) {
    g.status = .Failed
    agent_text_set(&g.reason, why)
    agent_goal_tell(link, gs, g)
}

// Cancels every goal still to finish.
agent_goals_clear :: proc(link: ^Agent_Link, gs: ^Game_State, why: string) {
    if !agent_goals_busy(&link.goals) do return
    agent_record_op(link, gs, `"clear":true`)
    for &g in link.goals.slots[:link.goals.n] {
        if g.status == .Queued || g.status == .Running do agent_goal_cancel(link, gs, &g, why)
    }
}

@(private="file")
agent_read :: proc(link: ^Agent_Link, gs: ^Game_State) {
    // A listen still reads, to see a client go, but holds its lines.
    for link.connected && (agent_listening(link) || link.awaiting) {
        // A line may already be buffered behind the one just answered.
        if nl := agent_newline(link); nl >= 0 && !link.awaiting {
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
agent_record_act :: proc(link: ^Agent_Link, gs: ^Game_State, g: ^Agent_Goal) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    p := &gs.player
    line := fmt.tprintf(`{{"f":%d,"act":%s,"x":%.3f,"y":%.3f,"hp":%d,"mana":%.2f,"lvl":%d,"enemies":%d}}` + "\n",
        gs.frame, string(g.line[:g.len]), p.pos.x, p.pos.y, p.hp, p.mana, gs.level_index, gs.enemies.count)
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

// A change to the goal queue, with the frame it came on: what a replay feeds back.
@(private="file")
agent_record_op :: proc(link: ^Agent_Link, gs: ^Game_State, fields: string) {
    if !link.recording do return
    os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,%s}}` + "\n", gs.frame, fields))
}

@(private="file")
agent_record_objective :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,"objective":%s}}` + "\n", gs.frame, line))
}

// One side of the talk: who and what, as strict JSON.
@(private="file")
agent_record_talk :: proc(link: ^Agent_Link, gs: ^Game_State, who, text: string) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    quoted, _ := json.marshal(text, allocator = context.temp_allocator)
    os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,"%s":%s}}` + "\n", gs.frame, who, string(quoted)))
}

@(private="file")
agent_record_mark :: proc(link: ^Agent_Link, gs: ^Game_State, mark: string) {
    if !link.recording do return
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    os.write_string(link.acts_file, fmt.tprintf(`{{"f":%d,"mark":"%s"}}` + "\n", gs.frame, mark))
}

@(private="file")
agent_drop_client :: proc(link: ^Agent_Link, gs: ^Game_State) {
    agent_record_idle(link, gs)
    agent_record_mark(link, gs, "disconnect")
    net.close(link.client)
    link.connected   = false
    link.awaiting    = false
    link.realtime    = false
    link.goals       = {}
    link.events_on   = false
    link.push_len    = 0
    link.reply_due   = false
}

// A reply is one line; a short send means the client stopped reading.  Events
// waiting go first.
@(private="file")
agent_send :: proc(link: ^Agent_Link, gs: ^Game_State) {
    agent_flush_push(link, gs)
    if !link.connected || link.out_len == 0 do return
    agent_send_bytes(link, gs, link.out[:link.out_len])
}

@(private="file")
agent_flush_push :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if !link.connected || link.push_len == 0 do return
    agent_send_bytes(link, gs, link.push[:link.push_len])
    link.push_len = 0
}

@(private="file")
agent_send_bytes :: proc(link: ^Agent_Link, gs: ^Game_State, data: []u8) {
    net.set_blocking(link.client, true)
    net.set_option(link.client, .Send_Timeout, AGENT_SEND_TIMEOUT)
    n, err := net.send_tcp(link.client, data)
    net.set_blocking(link.client, false)
    if err != nil || n != len(data) do agent_drop_client(link, gs)
}

// One request line.  Leaves the reply in link.out, except for an act, which
// replies when its frames have run.
agent_handle_line :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator

    value, err := json.parse_string(line, parse_integers = true)
    root, is_obj := value.(json.Object)
    if err != .None || !is_obj {
        agent_reply_error(link, "", "request is not a JSON object")
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
        agent_reply_state(link, gs, &view, cmd)
    case "act":
        // The old protocol: one act goal in place of whatever was queued, and the
        // reply waits until it is done.
        _, _, problem := agent_parse_act(gs, root)
        canonical := agent_canonical(value)
        if problem == "" && len(canonical) > AGENT_GOAL_LINE do problem = "act too long to record"
        if problem != "" {
            agent_reply_error(link, cmd, problem)
            return
        }
        agent_goals_clear(link, gs, "replaced by an act")  // and so a slot is free
        agent_record_idle(link, gs)
        agent_goal_add(link, gs, .Act, .Act, canonical)
        link.out_len = 0
    case "goals":
        agent_goals_command(link, gs, root)
    case "reflexes":
        agent_reflexes_command(link, gs, root)
    case "home":
        at, _, present, ok := agent_tile(root, "at")
        if present && !ok {
            agent_reply_error(link, cmd, fmt.tprintf("at must be [x,y] inside the %dx%d level", GRID_W, GRID_H))
            return
        }
        agent_home_set(link, gs, at, gs.level_index, present)
        agent_reply_text(link, cmd, `"ok":true`)
    case "plan", "wait", "idle", "realtime":
        // Retired (card 154): goals took their place, and the game never waits
        // for a client.
        agent_reply_error(link, cmd, fmt.tprintf("%s is retired, use goals", cmd))
    case "objective":
        goal, has_goal := root["goal"].(json.String)
        step, has_step := root["step"].(json.String)
        if !has_goal && !has_step {
            agent_reply_error(link, cmd, "objective needs goal or step")
            return
        }
        result, _ := root["result"].(json.String)
        agent_set_objective(&link.panel, goal, step, has_goal, has_step, result == "failed")
        agent_record_objective(link, gs, agent_canonical(value))
        agent_reply_text(link, cmd, `"ok":true`)
    case "say":
        text, _ := root["text"].(json.String)
        if len(text) == 0 {
            agent_reply_error(link, cmd, "say needs text")
            return
        }
        agent_text_set(&link.panel.say, text)
        said := string(link.panel.say.buf[:link.panel.say.len])
        agent_record_talk(link, gs, "say", said)
        log_action(gs, "Agent says: %s", said)
        agent_reply_text(link, cmd, `"ok":true`)
    case "listen":
        seconds := AGENT_LISTEN_S
        if "seconds" in root {
            n, _ := agent_int(root, "seconds")  // not a number reads as 0
            if n < 1 || n > AGENT_LISTEN_MAX_S {
                agent_reply_error(link, cmd, fmt.tprintf("seconds must be 1..%d", AGENT_LISTEN_MAX_S))
                return
            }
            seconds = n
        }
        if link.panel.heard_len > 0 {
            agent_reply_state(link, gs, nil, cmd)  // a line is waiting: answered now, by agent_read's send
            return
        }
        link.out_len     = 0
        link.awaiting    = true
        link.await_until = time.tick_add(time.tick_now(), time.Duration(seconds) * time.Second)
    case:
        agent_reply_error(link, cmd, "unknown cmd: use state, act, goals, reflexes, home, objective, say or listen")
    }
}

@(private="file")
agent_goal_kind_problem :: proc() -> string {
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "do must name a goal kind:")
    for row, k in agent_goal_kinds do fmt.sbprintf(&b, "%s %s", "" if k == .Act else ",", row.name)
    return strings.to_string(b)
}

// {"cmd":"reflexes","potion":false,...}: switches reflexes on and off, all or
// nothing, and answers with every one.
@(private="file")
agent_reflexes_command :: proc(link: ^Agent_Link, gs: ^Game_State, root: json.Object) {
    off := link.goals.reflexes_off
    for key, v in root {
        if key == "cmd" do continue
        on, is_bool := v.(json.Boolean)
        found := false
        for row, k in hero_reflexes do if row.name == key {
            found = true
            if on {
                off -= {k}
            } else {
                off += {k}
            }
        }
        if !found || !is_bool {
            agent_reply_error(link, "reflexes", fmt.tprintf("%s is not a reflex to switch with true or false", key))
            return
        }
    }
    agent_reply_text(link, "reflexes", fmt.tprintf(`"ok":true,"reflexes":{{%s}}`, agent_reflexes_set(link, gs, off)))
}

// The reflexes switched, recorded for a replay; gives them all as JSON fields.
agent_reflexes_set :: proc(link: ^Agent_Link, gs: ^Game_State, off: bit_set[Hero_Reflex]) -> string {
    link.goals.reflexes_off = off
    b := strings.builder_make(context.temp_allocator)
    for row, k in hero_reflexes do fmt.sbprintf(&b, `%s"%s":%v`, "" if k == min(Hero_Reflex) else ",", row.name, k not_in off)
    agent_record_op(link, gs, fmt.tprintf(`"reflexes":{{%s}}`, strings.to_string(b)))
    return strings.to_string(b)
}

// The home goal's tile on a level marked, or the mark taken away, recorded.
agent_home_set :: proc(link: ^Agent_Link, gs: ^Game_State, at: [2]i32, level: int, marked: bool) {
    q := &link.goals
    q.home, q.home_level, q.has_home = at, level, marked
    if marked {
        agent_record_op(link, gs, fmt.tprintf(`"home":[%d,%d],"level":%d`, at.x, at.y, level))
    } else {
        agent_record_op(link, gs, `"home":null`)
    }
}

// {"cmd":"goals",...}: add, clear or cancel.  The first one turns the pushed
// events on.
@(private="file")
agent_goals_command :: proc(link: ^Agent_Link, gs: ^Game_State, root: json.Object) {
    if !link.events_on {
        link.events_on  = true
        link.seen_hp    = gs.player.hp
        link.seen_dead  = gs.player.dead
        link.seen_level = gs.level_index
    }
    q := &link.goals
    switch {
    case agent_flag(root, "clear"):
        agent_goals_clear(link, gs, "cancelled")
        agent_reply_text(link, "goals", `"ok":true`)
    case "cancel" in root:
        id, _ := agent_int(root, "cancel")
        for &g in q.slots[:q.n] {
            if g.id != id || (g.status != .Queued && g.status != .Running) do continue
            agent_record_op(link, gs, fmt.tprintf(`"cancel":%d`, id))
            agent_goal_cancel(link, gs, &g, "cancelled")
            agent_reply_text(link, "goals", `"ok":true`)
            return
        }
        agent_reply_error(link, "goals", fmt.tprintf("no queued or running goal %d", id))
    case "add" in root:
        adds, ok := root["add"].(json.Array)
        if !ok || len(adds) == 0 {
            agent_reply_error(link, "goals", "add needs a list of goals")
            return
        }
        if room := agent_goals_room(q); len(adds) > room {
            agent_reply_error(link, "goals", fmt.tprintf("the goal queue is full: room for %d of %d", room, AGENT_GOALS_MAX))
            return
        }
        // All or nothing, as a plan is.
        lines: [AGENT_GOALS_MAX]string
        kinds: [AGENT_GOALS_MAX]Agent_Goal_Kind
        for a, i in adds {
            o, is_obj := a.(json.Object)
            name, _ := o["do"].(json.String)
            kind, known := agent_goal_find_kind(name)
            problem: string
            switch {
            case !is_obj: problem = "not an object"
            case !known:  problem = agent_goal_kind_problem()
            case:         problem = agent_goal_kinds[kind].check(gs, o)
            }
            lines[i] = agent_canonical(a)
            if problem == "" && len(lines[i]) > AGENT_GOAL_LINE do problem = "too long to record"
            if problem != "" {
                agent_reply_error(link, "goals", fmt.tprintf("goal %d: %s", i, problem))
                return
            }
            kinds[i] = kind
        }
        agent_record_idle(link, gs)
        b := agent_reply_begin(link, "goals")
        strings.write_string(&b, `"ok":true,"ids":[`)
        for i in 0 ..< len(adds) {
            if i > 0 do strings.write_byte(&b, ',')
            fmt.sbprintf(&b, "%d", agent_goal_add(link, gs, kinds[i], .Goal, lines[i]))
        }
        strings.write_string(&b, "]}\n")
        link.out_len = strings.builder_len(b)
    case:
        agent_reply_error(link, "goals", "goals needs add, clear:true or cancel:id")
    }
}

// The request as strict JSON.  The parser takes JSON5 and raw tabs, which the
// tools reading acts.jsonl do not, so what is recorded is re-encoded, not the
// line as sent.
agent_canonical :: proc(value: json.Value) -> string {
    data, err := json.marshal(value)
    return string(data) if err == nil else "{}"
}

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

// key:[x,y] in tiles.  A whole number aims at the tile's centre, as it always
// has; a fraction (10.0 included) aims at that point, as a mouse can.  point
// is in tiles.  present says the key was there at all.
agent_tile :: proc(o: json.Object, key: string) -> (tile: [2]i32, point: [2]f32, present, ok: bool) {
    if key not_in o do return
    present = true
    a, is_arr := o[key].(json.Array)
    if !is_arr || len(a) != 2 do return
    for v, i in a {
        #partial switch n in v {
        case json.Integer: point[i] = f32(n) + 0.5
        case json.Float:   point[i] = f32(n)
        case: return
        }
    }
    f := [2]f32{math.floor(point.x), math.floor(point.y)}
    // Written so NaN fails it: NaN compares false both ways.
    if !(f.x >= 0 && f.x < GRID_W && f.y >= 0 && f.y < GRID_H) do return
    return {i32(f.x), i32(f.y)}, point, true, true
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
    aim: [2]f32
    c.mine,  aim, present, ok = agent_tile(o, "mine");  c.has_mine  = ok; tile_ok &&= ok || !present; if ok do c.aim = aim
    c.place, aim, present, ok = agent_tile(o, "place"); c.has_place = ok; tile_ok &&= ok || !present; if ok do c.aim = aim
    c.use,   aim, present, ok = agent_tile(o, "use");   c.has_use   = ok; tile_ok &&= ok || !present; if ok do c.aim = aim
    c.reclaim, aim, present, ok = agent_tile(o, "reclaim"); c.has_reclaim = ok; tile_ok &&= ok || !present; if ok do c.aim = aim
    c.at,    aim, present, ok = agent_tile(o, "at");    c.has_at    = ok; tile_ok &&= ok || !present; if ok do c.aim = aim
    if !tile_ok {
        problem = "mine, place, use, reclaim and at take [x,y] inside the map"
        return
    }
    if "zone" in o {
        c.zone_from, c.zone_to, c.has_zone = agent_zone(o)
        if !c.has_zone {
            problem = "zone takes [x0,y0,x1,y1] inside the map"
            return
        }
    }
    if int(c.has_mine) + int(c.has_place) + int(c.has_use) + int(c.has_reclaim) + int(c.has_zone) + int(c.has_at) > 1 {
        problem = "one of mine, place, use, reclaim, zone or at per act: there is one cursor"
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
    if agent_flag(o, "withdraw_fuel") do c.verb = .Withdraw_Fuel
    if p := agent_slot_verb(&c, o, "tithe", .Tithe); p != "" { problem = p; return }
    if agent_flag(o, "crew") do c.verb = .Crew
    if "monument" in o {
        name, _ := o["monument"].(json.String)
        plan := agent_find_plan(name)
        if plan == .None {
            problem = "monument must be Clay_Hearth, Golem_Depot or World_Anchor"
            return
        }
        c.verb     = .Monument
        c.verb_arg = i32(plan)
    }

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
    // After every verb: a later one in the same act would leave at pointing nowhere.
    if c.verb == .Monument && !c.has_at {
        problem = "monument needs at:[x,y], its anchor"
        return
    }
    if c.has_at && c.verb != .Monument {
        problem = "at goes with monument"
        return
    }

    if "count" in o {
        n, _ := agent_int(o, "count")
        if c.verb != .Feed {
            problem = "count goes with feed"
            return
        }
        if n < 1 || n > MAX_STACK {
            problem = fmt.tprintf("count must be 1..%d", MAX_STACK)
            return
        }
        c.feed_count = i32(n)
    }

    if !live do return  // a plan's later steps run in a world not yet played

    // The command wand's gestures, refused where the mouse would do something else.
    if c.has_zone || c.verb == .Crew || c.verb == .Monument {
        corner := c.zone_from if c.has_zone else c.at
        t := get_tile(&gs.world, int(corner.x), int(corner.y))
        switch {
        case equipped_command_wand(gs) == .None:
            problem = "zone, crew and monument need a command wand selected"
        case c.has_zone && c.zone_from == c.zone_to:
            problem = "a zone needs two different corners"
        case c.verb != .Crew && (is_structure_tile[t] || is_rune_scroll_chest(t)):
            problem = fmt.tprintf("a click on the %v there opens it: start on open ground", t)
        case c.verb == .Monument && !golem_plan_unlocked(gs, Golem_Plan(c.verb_arg)):
            problem = fmt.tprintf("%v is not unlocked: it needs a stronger wand, and World_Anchor a dimension", Golem_Plan(c.verb_arg))
        }
        if problem != "" do return
    }

    // The smelter and barrel verbs act on the window a `use` opened, as the
    // drag-and-drop they stand in for does.
    #partial switch c.verb {
    case .Feed, .Collect, .Withdraw, .Withdraw_Fuel:
        t := get_tile(&gs.world, int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y))
        if !gs.ui.show_smelter || t != .Smelter {
            problem = "no smelter window open: use the smelter first"
        }
    case .Store, .Take:
        if !gs.ui.show_barrel do problem = "no barrel window open: use the barrel first"
    case .Tithe:
        switch {
        case !gs.player.dead:
            problem = "tithe needs the death screen"
        case gs.player.death_timer <= DEATH_INPUT_DELAY:
            problem = fmt.tprintf("the death screen is not ready yet: %d more frames", agent_death_ready_in(gs))
        case !tithe_offerable(gs.player.inventory.slots[c.verb_arg]):
            problem = "nothing in that slot can be sent on"
        }
    }
    return
}

// A zone's two corners, [x0,y0,x1,y1] in tiles.
@(private="file")
agent_zone :: proc(o: json.Object) -> (from, to: [2]i32, ok: bool) {
    a, is_arr := o["zone"].(json.Array)
    if !is_arr || len(a) != 4 do return
    n: [4]int
    for v, i in a {
        num, num_ok := agent_num(v)
        if !num_ok do return
        n[i] = num
    }
    if !in_bounds(n[0], n[1]) || !in_bounds(n[2], n[3]) do return
    return {i32(n[0]), i32(n[1])}, {i32(n[2]), i32(n[3])}, true
}

@(private="file")
agent_find_plan :: proc(name: string) -> Golem_Plan {
    for plan in Golem_Plan do if fmt.tprint(plan) == name do return plan
    return .None
}

// Ticks until the death screen hears a click: it waits DEATH_INPUT_DELAY.
agent_death_ready_in :: proc(gs: ^Game_State) -> int {
    if gs.player.death_timer > DEATH_INPUT_DELAY do return 0
    return int((DEATH_INPUT_DELAY - gs.player.death_timer) / AGENT_STEP) + 1
}

// By result name.  A result with several recipes prefers one that can be made now.
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

    // The executor's cursor, and the stack it drags, as a mouse shows them.
    if c.has_cursor do inp.mouse_screen = c.cursor
    gs.ui.drag_item = c.carry

    // Ahead of the dismiss: an act that does both sends the item, then moves on.
    if first && c.verb == .Tithe do eq_push(&gs.events, Event{type = .Tithe_Choose, payload = {int_val = c.verb_arg}})
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
    if first && !agent_cmd_keeps_windows(c) do agent_close_windows(gs)

    tile := player_tile(&gs.player)
    if c.has_mine  do tile = c.mine
    if c.has_place do tile = c.place
    if c.has_use   do tile = c.use
    if c.has_reclaim do tile = c.reclaim
    if c.has_zone do tile = c.zone_to  // where the drag lets go
    if c.has_at   do tile = c.at
    inp.mouse_tile   = tile
    inp.mouse_world  = {(f32(tile.x) + 0.5) * CELL_SIZE, (f32(tile.y) + 0.5) * CELL_SIZE}
    if c.has_mine || c.has_place || c.has_use || c.has_reclaim || c.has_at do inp.mouse_world = c.aim * CELL_SIZE
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
    if c.has_zone {
        packed := u32(c.zone_from.x) | (u32(c.zone_from.y) << 16)
        eq_push(&gs.events, Event{type = .Golem_Zone, tile = c.zone_to, payload = {int_val = i32(packed)}})
    }
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
    case .None, .Tithe:  // a tithe went out above, ahead of the death screen's return
    case .Monument: eq_push(&gs.events, Event{type = .Golem_Project, tile = tile, payload = {int_val = arg}})
    case .Crew:    eq_push(&gs.events, Event{type = .Golem_Crew_Toggle})
    case .Select:  gs.player.inventory.selected = int(arg)
    case .Craft:   eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = arg}})
    case .Open_Craft:  // TAB: the bag and crafting, with the recipes of a station in range
        gs.ui.active_station, _ = nearest_station(gs)
        gs.ui.show_inventory = true
        gs.ui.show_crafting  = true
        place_craft_pair(gs)
    case .Pick_Recipe: gs.ui.craft_selected = int(arg)
    case .Open_Roster: gs.ui.show_golem_roster = true  // the held command wand's click on the world, no drag
    case .Roster:  golem_roster_press(gs, int(arg & 0xff), Roster_Button(arg >> 8))
    case .Equip:   eq_push(&gs.events, Event{type = .Equip_Request, payload = {int_val = arg}})
    case .Feed:    eq_push(&gs.events, Event{type = .Smelter_Feed, tile = gs.ui.smelter_tile, payload = {int_val = arg}, count = c.feed_count})
    case .Collect: eq_push(&gs.events, Event{type = .Smelter_Collect, tile = gs.ui.smelter_tile})
    case .Withdraw: eq_push(&gs.events, Event{type = .Smelter_Withdraw, tile = gs.ui.smelter_tile})
    case .Withdraw_Fuel: eq_push(&gs.events, Event{type = .Smelter_Withdraw_Fuel, tile = gs.ui.smelter_tile})
    case .Store:   eq_push(&gs.events, Event{type = .Barrel_Store, tile = gs.ui.barrel_tile, payload = {int_val = arg}})
    case .Take:    eq_push(&gs.events, Event{type = .Barrel_Take, tile = gs.ui.barrel_tile, payload = {int_val = arg}})
    }
}

// What the first ESC does in update_input.
@(private="file")
agent_close_windows :: proc(gs: ^Game_State) {
    for open in agent_window_flags(&gs.ui) do open^ = false
}

// The one key that gets past any screen holding the game up.
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
    case gs.game_won:          eq_push(&gs.events, Event{type = .New_Game_Request})
    }
}

agent_screen :: proc(gs: ^Game_State) -> string {
    switch {
    case gs.ui.show_title:      return "title"
    case gs.ui.show_settings:   return "settings"
    case gs.ui.show_snapshots:  return "snapshots"
    case gs.ui.show_menu:       return "menu"
    case gs.player.dead:        return "dead"
    case gs.ui.show_book:       return "book"
    case gs.game_won:           return "won"
    }
    return "play"
}

Agent_View :: struct { x, y, w, h: int }

@(private="file")
agent_default_view :: proc(gs: ^Game_State) -> Agent_View {
    t := player_tile(&gs.player)
    return {int(t.x) - AGENT_VIEW_W / 2, int(t.y) - AGENT_VIEW_H / 2, AGENT_VIEW_W, AGENT_VIEW_H}
}

// Every reply opens with "re", the cmd it answers, so a client can tell it from
// an event.
@(private="file")
agent_reply_begin :: proc(link: ^Agent_Link, re: string) -> strings.Builder {
    b := strings.builder_from_bytes(link.out[:])
    strings.write_string(&b, `{"re":`)
    json_write_string(&b, re)
    strings.write_byte(&b, ',')
    return b
}

// fields is the rest of the object, without its braces.
@(private="file")
agent_reply_text :: proc(link: ^Agent_Link, re, fields: string) {
    b := agent_reply_begin(link, re)
    strings.write_string(&b, fields)
    strings.write_string(&b, "}\n")
    link.out_len = strings.builder_len(b)
}

@(private="file")
agent_reply_error :: proc(link: ^Agent_Link, re, text: string) {
    b := agent_reply_begin(link, re)
    strings.write_string(&b, `"ok":false,"error":`)
    json_write_string(&b, text)
    strings.write_string(&b, "}\n")
    link.out_len = strings.builder_len(b)
}

@(private="file")
json_write_string :: proc(b: ^strings.Builder, text: string) {
    strings.write_quoted_string(b, text)
}

// The whole reply fits link.out: the view is clamped to the map, enemies and
// dens are bounded by MAX_ENEMIES and piles by AGENT_ITEMS_MAX.  "items" lists the first
// piles in row order, so a whole-map view of a littered world can come up short.
agent_reply_state :: proc(link: ^Agent_Link, gs: ^Game_State, view: ^Agent_View, re: string) {
    v := view^ if view != nil else agent_default_view(gs)
    v.x = clamp(v.x, 0, GRID_W - 1)
    v.y = clamp(v.y, 0, GRID_H - 1)
    v.w = clamp(v.w, 1, GRID_W - v.x)
    v.h = clamp(v.h, 1, GRID_H - v.y)

    b := agent_reply_begin(link, re)
    p := &gs.player
    fmt.sbprintf(&b, `"ok":true,"frame":%d,"screen":"%s","level":%d,`, gs.frame, agent_screen(gs), gs.level_index)
    fmt.sbprintf(&b, `"player":{{"x":%.2f,"y":%.2f,"vx":%.2f,"vy":%.2f,"hp":%d,"hp_max":%d,"mana":%.1f,"grounded":%v,"facing":%d,"dead":%v}},`,
        p.pos.x, p.pos.y, p.vel.x, p.vel.y, p.hp, p.hp_max, p.mana, p.grounded, p.facing, p.dead)

    fmt.sbprintf(&b, `"place_reach":%d,"fall_warning":%.2f,`, PLAYER_REACH, fall_warning(p))
    agent_write_death(&b, gs)
    agent_write_wave(&b, gs)
    if gs.agent.place_refused do strings.write_string(&b, `"refused":"place",`)
    agent_write_goals(&b, &link.goals)
    agent_write_heard(&b, &link.panel)

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
        size := enemy_body_size(e.kind)
        if comma do strings.write_byte(&b, ',')
        comma = true
        fmt.sbprintf(&b, `{{"slot":%d,"kind":"%v","x":%.2f,"y":%.2f,"w":%.2f,"h":%.2f,"hp":%d}}`, i, e.kind, e.pos.x, e.pos.y, size.x, size.y, e.hp)
    }
    strings.write_string(&b, `],"dens":[`)
    comma = false
    for i in 0 ..< MAX_ENEMIES {
        if !gs.enemies.active[i] do continue
        e := &gs.enemies.data[i]
        if e.kind != .Builder || !e.builder.den_built do continue
        a := e.builder.anchor
        if int(a.x) < v.x || int(a.x) >= v.x + v.w || int(a.y) < v.y || int(a.y) >= v.y + v.h do continue
        if comma do strings.write_byte(&b, ',')
        comma = true
        fmt.sbprintf(&b, `{{"owner":%d,"x":%d,"y":%d,"hoard":%d}}`, i, a.x, a.y, den_hoard(gs, &e.builder))
    }
    strings.write_string(&b, "],")
    agent_write_birds(&b, gs, v)
    agent_write_crew(&b, gs)
    strings.write_string(&b, "}\n")
    link.out_len = strings.builder_len(b)
}

// The queue, finished goals and all.
@(private="file")
agent_write_goals :: proc(b: ^strings.Builder, q: ^Agent_Goals) {
    strings.write_string(b, `"goals":[`)
    for &g, i in q.slots[:q.n] {
        if i > 0 do strings.write_byte(b, ',')
        fmt.sbprintf(b, `{{"id":%d,"do":"%s","status":"%s"`, g.id, agent_goal_kinds[g.kind].name, agent_goal_status_names[g.status])
        if g.status == .Running do fmt.sbprintf(b, `,"left":%d`, g.frames_left)
        if g.status == .Failed {
            strings.write_string(b, `,"reason":`)
            json_write_string(b, string(g.reason.buf[:g.reason.len]))
        }
        strings.write_byte(b, '}')
    }
    strings.write_string(b, `],`)
}

// Sky flocks with a bird inside the view, by their V's point.  Scenery: they
// scatter from the player and touch nothing.
@(private="file")
agent_write_birds :: proc(b: ^strings.Builder, gs: ^Game_State, v: Agent_View) {
    strings.write_string(b, `"birds":[`)
    comma := false
    if gs.birds.seeded do for &f in gs.birds.flocks {
        seen := false
        for bird in f.birds {
            seen ||= int(bird.pos.x) >= v.x && int(bird.pos.x) < v.x + v.w && int(bird.pos.y) >= v.y && int(bird.pos.y) < v.y + v.h
        }
        if !seen do continue
        if comma do strings.write_byte(b, ',')
        comma = true
        fmt.sbprintf(b, `{{"x":%.2f,"y":%.2f,"heading":%d,"scattered":%v}}`, f.center.x, f.center.y, int(f.heading), f.scatter_t > 0)
    }
    strings.write_string(b, "],")
}

// Every golem the wand has bound, and this level's Gather zone and monument.
@(private="file")
agent_write_crew :: proc(b: ^strings.Builder, gs: ^Game_State) {
    strings.write_string(b, `"crew":{"golems":[`)
    comma := false
    for &g, i in gs.golems.data {
        if g.status == .Empty do continue
        if comma do strings.write_byte(b, ',')
        comma = true
        fmt.sbprintf(b, `{{"slot":%d,"status":"%v","level":%d,"x":%.2f,"y":%.2f,"hp":%d,"mode":"%v","job":"%v","broken":%v,"recovering":%v,"carry":"%v"`,
            i, g.status, g.level, g.pos.x, g.pos.y, g.hp, g.mode, g.job, g.status == .Broken, g.recovering, g.carry)
        if g.has_target do fmt.sbprintf(b, `,"target":[%d,%d]`, g.target.x, g.target.y)
        strings.write_string(b, `,"pack":[`)
        packed := false
        for it in g.pack {
            if it == .None do continue
            if packed do strings.write_byte(b, ',')
            packed = true
            fmt.sbprintf(b, `"%v"`, it)
        }
        strings.write_string(b, "]}")
    }
    strings.write_byte(b, ']')
    if z := gs.golems.work[gs.level_index]; z.active {
        fmt.sbprintf(b, `,"zone":[%d,%d,%d,%d]`, z.min.x, z.min.y, z.max.x, z.max.y)
    }
    if p := gs.golems.projects[gs.level_index]; p.active {
        fmt.sbprintf(b, `,"monument":{{"plan":"%v","x":%d,"y":%d,"complete":%v}}`, p.plan, p.anchor.x, p.anchor.y, p.complete)
    }
    strings.write_byte(b, '}')
}

// The watcher's unread lines.  A reply reads them: each comes once.
@(private="file")
agent_write_heard :: proc(b: ^strings.Builder, p: ^Agent_Panel) {
    strings.write_string(b, `"heard":[`)
    for i in 0 ..< p.heard_len {
        if i > 0 do strings.write_byte(b, ',')
        h := &p.heard[i]
        fmt.sbprintf(b, `{{"f":%d,"text":`, h.frame)
        json_write_string(b, string(h.text.buf[:h.text.len]))
        strings.write_byte(b, '}')
    }
    strings.write_string(b, "],")
    p.heard_len = 0
}

// What the death screen says: the blow, and what can still be sent on.
@(private="file")
agent_write_death :: proc(b: ^strings.Builder, gs: ^Game_State) {
    if !gs.player.dead do return
    if len(gs.death_by) > 0 {
        strings.write_string(b, `"death_by":`)
        json_write_string(b, gs.death_by)
        strings.write_byte(b, ',')
    }
    fmt.sbprintf(b, `"tithe":{{"ready_in":%d,"chosen":%d,"offerable":[`, agent_death_ready_in(gs), gs.ui.tithe_slot)
    comma := false
    for s, i in gs.player.inventory.slots {
        if !tithe_offerable(s) do continue
        if comma do strings.write_byte(b, ',')
        comma = true
        fmt.sbprintf(b, "%d", i)
    }
    strings.write_string(b, "]},")
}

// The gauge and warning a player sees, and the threat behind them.
@(private="file")
agent_write_wave :: proc(b: ^strings.Builder, gs: ^Game_State) {
    gauge, _ := wave_gauge(gs)
    fmt.sbprintf(b, `"wave":{{"threat":%.1f,"gauge":%.2f,"warning_s":%.1f}},`,
        gs.wave.threat, gauge, gs.wave.warning_timer if gs.wave.warning_active else 0)
}

// The contents of an open smelter or barrel window.
@(private="file")
agent_write_window :: proc(b: ^strings.Builder, gs: ^Game_State) {
    if gs.ui.show_smelter {
        sd := gs.world.sim_data[grid_idx(int(gs.ui.smelter_tile.x), int(gs.ui.smelter_tile.y))]
        fmt.sbprintf(b, `"smelter":{{"input":"%v","input_count":%d,"fuel":%d,"tray":"%v","tray_count":%d}},`,
            sd.in_item, sd.in_count, sd.fuel_count, sd.store_item, sd.store_count)
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
    for ch, t in chars do if ch != 0 && tile_blocks_player(t, true) do strings.write_byte(b, ch)
    strings.write_string(b, `","floor":"`)
    for ch, t in chars do if ch != 0 && tile_blocks_player(t, false) do strings.write_byte(b, ch)
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
