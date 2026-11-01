package game

// agent_api.odin — lets an outside agent play the running game over a local
// socket.  Diagnostic only: everything is behind GAME_DEBUG, and nothing listens
// unless GNIPA_AGENT_PORT is set.
//
// Protocol: one JSON object per line each way, on 127.0.0.1.
//   {"cmd":"state"}                                 full state, x/y/w/h pick the tile view
//   {"cmd":"act","move":"left","frames":30,...}     play those frames, reply with state after
//   {"cmd":"realtime","on":true}                    keep ticking between acts
//
// While a client is connected the game WAITS: the sim only ticks through an act,
// at a fixed 1/60 s step, and the keyboard and mouse are ignored.  Disconnecting
// hands the game straight back to them.
//
// An act drives the same seams a player does: Input_State for held input, the
// Event_Queue for one-shot verbs.  It is never handed a shortcut into world
// state, so every rule (reach, costs, stations) still applies.
//
// The link lives in main, not in Game_State: game_state_init zeroes gs on a New
// Game, and the socket has to outlive that.  gs.agent is rewritten every frame.
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
AGENT_VIEW_W       :: 41   // default tile view, centered on the player
AGENT_VIEW_H       :: 25
AGENT_LINE_MAX     :: 4096
AGENT_REPLY_MAX    :: 512 * 1024
AGENT_SEND_TIMEOUT :: 2 * time.Second // a client that stops reading is dropped

// Printable, JSON-safe, one per distinct tile type seen in a view.
AGENT_TILE_CHARS :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#*+-=~:;.,!?@$%^&()[]{}<>/|_"

Agent_Link :: struct {
    listening:   bool,
    connected:   bool,
    realtime:    bool,
    listener:    net.TCP_Socket,
    client:      net.TCP_Socket,
    cmd:         Agent_Command,  // the act in progress
    first:       bool,           // its first frame has not run yet
    frames_left: int,
    reply_due:   bool,           // an act finished: its state waits in out
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
    fmt.printfln("agent api: listening on 127.0.0.1:%d", port)
}

agent_close :: proc(link: ^Agent_Link) {
    if link.connected do agent_drop_client(link)
    if link.listening do net.close(link.listener)
    link.listening = false
}

// Before each frame: serves the client and says whether the sim ticks.
agent_pump :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    if !link.listening do return true

    if link.reply_due {
        link.reply_due = false
        agent_send(link)
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
        }
    }
    if link.connected && link.frames_left == 0 do agent_read(link, gs)
    if !link.connected {
        gs.agent = {}  // back to the keyboard, with nothing of the last act left to replay
        return true
    }
    return agent_drive(link, gs)
}

// Loads this frame's input into gs.agent and decides whether the sim ticks.
agent_drive :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    gs.agent.driving = true
    if !link.realtime do gs.delta_time = AGENT_STEP
    if link.frames_left > 0 {
        gs.agent.cmd   = link.cmd
        gs.agent.first = link.first
        link.first     = false
        return true
    }
    gs.agent.cmd   = {}
    gs.agent.first = false
    return link.realtime
}

// After a ticked frame: counts the act down and answers when it has run out.
agent_after_tick :: proc(link: ^Agent_Link, gs: ^Game_State) {
    if !link.connected || link.frames_left == 0 do return
    link.frames_left -= 1
    if link.frames_left == 0 {
        link.cmd = {}
        agent_reply_state(link, gs, nil)
        link.reply_due = true
    }
}

@(private="file")
agent_read :: proc(link: ^Agent_Link, gs: ^Game_State) {
    for link.frames_left == 0 && link.connected {
        // A line may already be buffered behind the one just answered.
        if nl := agent_newline(link); nl >= 0 {
            line := string(link.in_buf[:nl])
            agent_handle_line(link, gs, line)
            agent_send(link)
            remaining := link.in_len - nl - 1
            copy(link.in_buf[:], link.in_buf[nl + 1:link.in_len])
            link.in_len = remaining
            continue
        }
        if link.in_len == len(link.in_buf) {
            agent_drop_client(link)  // a line this long is not the protocol
            return
        }
        n, err := net.recv_tcp(link.client, link.in_buf[link.in_len:])
        if err == .Would_Block || err == .Timeout do return
        if err != nil || n == 0 {
            agent_drop_client(link)
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

@(private="file")
agent_drop_client :: proc(link: ^Agent_Link) {
    net.close(link.client)
    link.connected   = false
    link.realtime    = false
    link.frames_left = 0
    link.reply_due   = false
    link.cmd         = {}
}

// A reply is one line; a short send means the client stopped reading.
@(private="file")
agent_send :: proc(link: ^Agent_Link) {
    if !link.connected || link.out_len == 0 do return
    net.set_blocking(link.client, true)
    net.set_option(link.client, .Send_Timeout, AGENT_SEND_TIMEOUT)
    n, err := net.send_tcp(link.client, link.out[:link.out_len])
    net.set_blocking(link.client, false)
    if err != nil || n != link.out_len do agent_drop_client(link)
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
        link.cmd         = c
        link.first       = true
        link.frames_left = frames
        link.out_len     = 0
    case "realtime":
        on, ok := root["on"].(json.Boolean)
        if !ok {
            agent_reply_error(link, "realtime needs on:true or on:false")
            return
        }
        link.realtime = on
        agent_reply_text(link, `{"ok":true}`)
    case:
        agent_reply_error(link, "unknown cmd: use state, act or realtime")
    }
}

@(private="file")
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

agent_parse_act :: proc(gs: ^Game_State, o: json.Object) -> (c: Agent_Command, frames: int, problem: string) {
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
    if !tile_ok {
        problem = "mine, place and use take [x,y] inside the map"
        return
    }
    if int(c.has_mine) + int(c.has_place) + int(c.has_use) > 1 {
        problem = "one of mine, place or use per act: there is one cursor"
        return
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

    if "craft" in o {
        name, _ := o["craft"].(json.String)
        idx := agent_find_recipe(gs, name)
        if idx < 0 {
            problem = fmt.tprintf("no revealed recipe makes %s", name)
            return
        }
        c.verb     = .Craft
        c.verb_arg = i32(idx)
    }

    // The smelter and barrel verbs act on the window a `use` opened, as the
    // drag-and-drop they stand in for does.
    #partial switch c.verb {
    case .Feed, .Collect:
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
    if gs.ui.show_title || gs.ui.show_charselect || gs.ui.show_settings ||
       gs.ui.show_snapshots || gs.ui.show_menu || gs.player.dead || gs.ui.show_book {
        return
    }

    tile := player_tile(&gs.player)
    if c.has_mine  do tile = c.mine
    if c.has_place do tile = c.place
    if c.has_use   do tile = c.use
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

    if !first do return

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
    case .Store:   eq_push(&gs.events, Event{type = .Barrel_Store, tile = gs.ui.barrel_tile, payload = {int_val = arg}})
    case .Take:    eq_push(&gs.events, Event{type = .Barrel_Take, tile = gs.ui.barrel_tile, payload = {int_val = arg}})
    }
}

// The one key that gets past any screen holding the game up.
@(private="file")
agent_dismiss :: proc(gs: ^Game_State) {
    switch {
    case gs.ui.show_title:
        gs.ui.show_title      = false
        gs.ui.show_charselect = true
    case gs.ui.show_charselect:
        gs.player_form        = Player_Form(0)
        gs.ui.show_charselect = false
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
    case gs.ui.show_charselect: return "charselect"
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

// The whole reply fits link.out: the view is clamped to the map, and the lists
// are bounded by the view and the bag.
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
    for y in v.y ..< v.y + v.h do for x in v.x ..< v.x + v.w {
        idx := grid_idx(x, y)
        if gs.world.items[idx] == .None || gs.world.item_counts[idx] == 0 do continue
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
    strings.write_string(b, `],"legend":{`)
    comma := false
    for ch, t in chars {
        if ch == 0 do continue
        if comma do strings.write_byte(b, ',')
        comma = true
        fmt.sbprintf(b, `"%c":"%v"`, rune(ch), t)
    }
    strings.write_string(b, "}}")
}
