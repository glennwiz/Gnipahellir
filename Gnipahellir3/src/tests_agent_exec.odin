package game

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A connected link in real time, as a client finds it, on the surface.
@(private="file")
exec_test_world :: proc(seed: u32 = 781) -> (gs: ^Game_State, link: ^Agent_Link) {
    gs = new(Game_State)
    link = new(Agent_Link)
    game_state_init(gs, seed)
    gs.ui.show_title = false
    gs.player.pos = SURFACE_HOME_POS
    link.connected = true  // no socket: nothing is sent, the push buffer is read instead
    link.realtime  = true
    return
}

// n frames as main plays them.
@(private="file")
exec_test_frames :: proc(link: ^Agent_Link, gs: ^Game_State, n: int) {
    for _ in 0 ..< n {
        if agent_drive(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
}

@(private="file")
exec_test_reply :: proc(link: ^Agent_Link) -> json.Object {
    value, err := json.parse_string(string(link.out[:link.out_len]), allocator = context.temp_allocator)
    assert(err == .None, string(link.out[:link.out_len]))
    return value.(json.Object)
}

@(private="file")
exec_test_pushed :: proc(link: ^Agent_Link) -> string {
    return string(link.push[:link.push_len])
}

// The goal with that id in state's goals.
@(private="file")
exec_test_goal :: proc(link: ^Agent_Link, gs: ^Game_State, id: int) -> json.Object {
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    for g in exec_test_reply(link)["goals"].(json.Array) {
        o := g.(json.Object)
        if int(o["id"].(json.Float)) == id do return o
    }
    return nil
}

@(test)
agent_real_time_ticks_with_no_client_input :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    link.idle_off = false

    frame := gs.frame
    for _ in 0 ..< AGENT_IDLE_MAX * 2 do testing.expect(t, agent_drive(link, gs), "real time never waits")
    exec_test_frames(link, gs, 30)
    testing.expect_value(t, gs.frame, frame + 30)
    testing.expect_value(t, gs.delta_time, AGENT_STEP)  // the step stays fixed, so a run replays
    testing.expect_value(t, link.idle_ticks, 0)          // and nothing is idle about it
}

@(test)
agent_a_queued_act_goal_plays_its_frames_and_says_done :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 30)  // settle onto the ground
    start := gs.player.pos

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":30},{"do":"act","frames":5}]}`)
    reply := exec_test_reply(link)
    testing.expect_value(t, reply["re"].(json.String), "goals")
    testing.expect(t, reply["ok"].(json.Boolean))
    ids := reply["ids"].(json.Array)
    testing.expect_value(t, len(ids), 2)
    first := int(ids[0].(json.Float))
    testing.expect_value(t, int(ids[1].(json.Float)), first + 1)
    testing.expect(t, agent_listening(link), "the client talks on while goals play")

    exec_test_frames(link, gs, 10)
    g := exec_test_goal(link, gs, first)
    testing.expect_value(t, g["status"].(json.String), "running")
    testing.expect_value(t, g["left"].(json.Float), 20)
    testing.expect_value(t, exec_test_goal(link, gs, first + 1)["status"].(json.String), "queued")
    testing.expect_value(t, link.push_len, 0)

    exec_test_frames(link, gs, 20)
    testing.expect(t, gs.player.pos.x > start.x + 1, "the goal walked the hero")
    testing.expect_value(t, exec_test_goal(link, gs, first)["status"].(json.String), "done")
    testing.expect_value(t, exec_test_pushed(link), fmt.tprintf(`{{"event":"goal_done","f":%d,"id":%d}}`+"\n", gs.frame, first))
    testing.expect_value(t, link.out_len > 0 && !link.reply_due, true)  // a goal has no reply waiting on it

    exec_test_frames(link, gs, 5)
    testing.expect(t, strings.contains(exec_test_pushed(link), fmt.tprintf(`"id":%d}}`, first + 1)))
    testing.expect(t, !agent_goals_busy(&link.goals))
}

@(test)
agent_a_full_goal_queue_is_refused :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)

    one := `{"do":"act","frames":1}`
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, `{"cmd":"goals","add":[`)
    for i in 0 ..< AGENT_GOALS_MAX {
        if i > 0 do strings.write_byte(&b, ',')
        strings.write_string(&b, one)
    }
    strings.write_string(&b, `]}`)
    agent_handle_line(link, gs, strings.to_string(b))
    testing.expect(t, exec_test_reply(link)["ok"].(json.Boolean))

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":1}]}`)
    reply := exec_test_reply(link)
    testing.expect(t, !reply["ok"].(json.Boolean))
    testing.expect(t, strings.contains(reply["error"].(json.String), "full"), reply["error"].(json.String))
    testing.expect_value(t, link.goals.n, AGENT_GOALS_MAX)

    // Played out, the finished goals give their slots up, oldest first.
    exec_test_frames(link, gs, 2)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":1},{"do":"act","frames":1}]}`)
    testing.expect(t, exec_test_reply(link)["ok"].(json.Boolean))
    testing.expect_value(t, link.goals.n, AGENT_GOALS_MAX)
    testing.expect_value(t, link.goals.slots[0].id, 3)
    testing.expect_value(t, link.goals.slots[AGENT_GOALS_MAX - 1].id, AGENT_GOALS_MAX + 2)

    // All or nothing: one bad goal queues none of them.
    exec_test_frames(link, gs, 4)
    n := link.goals.n
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act"},{"do":"fly"}]}`)
    testing.expect(t, strings.contains(exec_test_reply(link)["error"].(json.String), "goal 1: do must name"))
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":0}]}`)
    testing.expect(t, strings.contains(exec_test_reply(link)["error"].(json.String), "goal 0: frames"))
    agent_handle_line(link, gs, `{"cmd":"goals","add":[]}`)
    testing.expect(t, !exec_test_reply(link)["ok"].(json.Boolean))
    agent_handle_line(link, gs, `{"cmd":"goals"}`)
    testing.expect(t, !exec_test_reply(link)["ok"].(json.Boolean))
    testing.expect_value(t, link.goals.n, n)
    testing.expect_value(t, link.goals.next_id, AGENT_GOALS_MAX + 2)
}

@(test)
agent_a_goal_can_be_cancelled_and_the_queue_cleared :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":20},{"do":"act","frames":20},{"do":"act","frames":20}]}`)
    exec_test_frames(link, gs, 3)

    agent_handle_line(link, gs, `{"cmd":"goals","cancel":2}`)
    testing.expect(t, exec_test_reply(link)["ok"].(json.Boolean))
    g := exec_test_goal(link, gs, 2)
    testing.expect_value(t, g["status"].(json.String), "failed")
    testing.expect_value(t, g["reason"].(json.String), "cancelled")
    testing.expect(t, strings.contains(exec_test_pushed(link), `{"event":"goal_failed","f":3,"id":2,"reason":"cancelled"}`), exec_test_pushed(link))
    testing.expect_value(t, exec_test_goal(link, gs, 1)["status"].(json.String), "running")

    agent_handle_line(link, gs, `{"cmd":"goals","cancel":2}`)
    testing.expect(t, !exec_test_reply(link)["ok"].(json.Boolean), "a finished goal cannot be cancelled again")
    agent_handle_line(link, gs, `{"cmd":"goals","cancel":99}`)
    testing.expect(t, !exec_test_reply(link)["ok"].(json.Boolean))

    // A clear stops the running goal on the spot: the next tick has no input from it.
    agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
    testing.expect(t, exec_test_reply(link)["ok"].(json.Boolean))
    testing.expect(t, !agent_goals_busy(&link.goals))
    testing.expect_value(t, exec_test_goal(link, gs, 1)["status"].(json.String), "failed")
    testing.expect_value(t, exec_test_goal(link, gs, 3)["status"].(json.String), "failed")
    exec_test_frames(link, gs, 1)
    testing.expect(t, !gs.input.move_right)
}

// Glenn 2026-11-03: the hero never moves while a window is open.
@(test)
agent_no_goal_tick_moves_with_a_window_open :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 30)
    T := player_tile(&gs.player)
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Smelter)
    gs.ui.show_inventory = true  // left open from before

    agent_handle_line(link, gs, fmt.tprintf(
        `{{"cmd":"goals","add":[{{"do":"act","move":"left","frames":5}},{{"do":"act","use":[%d,%d],"move":"right","frames":10}},{{"do":"act","move":"right","frames":20}}]}}`,
        T.x + 1, T.y))

    opened, moved_shut, ticks := false, false, 0
    for agent_goals_busy(&link.goals) && ticks < 100 {
        ticks += 1
        testing.expect(t, agent_drive(link, gs))
        update_agent_goals(gs)
        agent_input(gs)
        inp := &gs.input
        moving := inp.move_left || inp.move_right || inp.jump || inp.fly_up || inp.fly_down
        testing.expectf(t, !(agent_window_open(gs) && moving), "tick %d moves with a window open", ticks)
        if moving && !agent_window_open(gs) do moved_shut = true
        process_events(gs)
        eq_clear(&gs.events)
        opened ||= gs.ui.show_smelter
        agent_after_tick(link, gs)
    }
    testing.expect(t, !agent_goals_busy(&link.goals))
    testing.expect_value(t, ticks, 1 + 5 + 10 + 1 + 20)  // a closing tick before each goal that found a window open
    testing.expect(t, opened, "the use opened the smelter")
    testing.expect(t, moved_shut && !gs.ui.show_smelter, "and the hero moved once it was shut")
}

@(test)
agent_events_are_pushed_once_a_client_speaks_goals :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    hit :: proc(gs: ^Game_State, dmg: i32) {
        eq_push(&gs.events, Event{type = .Damage_Dealt, source = INVALID_ENTITY, target = PLAYER_ID, payload = {int_val = dmg}, cause = .Lava})
    }

    // A client of the old protocol reads one reply per line: nothing comes unasked.
    hit(gs, 1)
    exec_test_frames(link, gs, 1)
    gs.level_index = 2
    exec_test_frames(link, gs, 1)
    agent_test_type_line(link, gs, "hi")
    testing.expect_value(t, link.push_len, 0)

    agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
    testing.expect_value(t, exec_test_reply(link)["re"].(json.String), "goals")
    hp := gs.player.hp
    hit(gs, 2)
    exec_test_frames(link, gs, 1)
    want := fmt.tprintf(`{{"event":"hurt","f":%d,"by":"lava","hp":%d}}`+"\n", gs.frame, hp - 2)
    testing.expect_value(t, exec_test_pushed(link), want)
    link.push_len = 0

    exec_test_frames(link, gs, 1)
    testing.expect_value(t, link.push_len, 0)  // a tick without a blow says nothing

    gs.level_index = 1
    exec_test_frames(link, gs, 1)
    testing.expect(t, strings.contains(exec_test_pushed(link), `"event":"level_changed"`) && strings.contains(exec_test_pushed(link), `"level":1}`), exec_test_pushed(link))
    link.push_len = 0

    agent_test_type_line(link, gs, `say "this"`)
    testing.expect_value(t, exec_test_pushed(link), fmt.tprintf(`{{"event":"heard","f":%d,"text":"say \"this\""}}`+"\n", gs.frame))
    link.push_len = 0

    hit(gs, 100)
    exec_test_frames(link, gs, 1)
    testing.expect(t, gs.player.dead)
    testing.expect_value(t, exec_test_pushed(link), fmt.tprintf(`{{"event":"died","f":%d,"by":"lava"}}`+"\n", gs.frame))
    link.push_len = 0
    exec_test_frames(link, gs, 5)
    testing.expect_value(t, link.push_len, 0)  // dying is said once
}

// The watcher typing a line and pressing Enter.
@(private="file")
agent_test_type_line :: proc(link: ^Agent_Link, gs: ^Game_State, text: string) {
    agent_chat_enter(link, gs)
    for ch in text do agent_chat_char(&link.panel, ch)
    agent_chat_enter(link, gs)
}

@(test)
agent_every_reply_says_what_it_answers :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    link.realtime = false
    link.idle_off = true

    for line in ([]string{`{"cmd":"state"}`, `{"cmd":"say","text":"x"}`, `{"cmd":"fly"}`, `{"cmd":"act","frames":0}`}) {
        agent_handle_line(link, gs, line)
        value, _ := json.parse_string(line, allocator = context.temp_allocator)
        testing.expect_value(t, exec_test_reply(link)["re"].(json.String), value.(json.Object)["cmd"].(json.String))
    }
    agent_handle_line(link, gs, `not json`)
    testing.expect_value(t, exec_test_reply(link)["re"].(json.String), "")

    // An act's state comes when it is done, and says act.
    agent_handle_line(link, gs, `{"cmd":"act","frames":2}`)
    testing.expect(t, !agent_listening(link), "the old act still holds the next line")
    exec_test_frames(link, gs, 2)
    testing.expect(t, link.reply_due)
    testing.expect(t, strings.has_prefix(string(link.out[:link.out_len]), `{"re":"act","ok":true,"frame"`))
}

// The promise of the goal log: the same goals on the same frames, from the same
// seed, end the same.
@(test)
agent_a_goal_log_replays_to_the_same_player :: proc(t: ^testing.T) {
    path := "agent_goal_replay_test.jsonl"
    defer os.remove(path)

    gs, link := exec_test_world(782)
    defer free(gs)
    defer free(link)
    f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    testing.expect(t, err == nil)
    link.acts_file = f
    link.recording = true
    exec_test_frames(link, gs, 7)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":40},{"do":"act","jump":true,"move":"left","frames":20}]}`)
    exec_test_frames(link, gs, 13)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":30},{"do":"act","mine":[100,60],"frames":50}]}`)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, `{"cmd":"goals","cancel":2}`)
    exec_test_frames(link, gs, 60)
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":15}`)  // the old act: a clear and a goal
    exec_test_frames(link, gs, 30)
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"right","frames":10},{"jump":true,"frames":10}]}`)
    exec_test_frames(link, gs, 40)
    link.recording = false
    os.close(f)
    end := gs.frame

    data, read_err := os.read_entire_file(path, context.allocator)
    testing.expect(t, read_err == nil)
    defer delete(data)

    Op :: struct { f: u64, goal: string, kind: Agent_Goal_Kind, via: Agent_Goal_Via, id, step, cancel: int, clear: bool }
    ops := make([dynamic]Op)
    defer {
        for op in ops do delete(op.goal)
        delete(ops)
    }
    {
        heap := context.allocator
        context.allocator = context.temp_allocator
        defer free_all(context.temp_allocator)
        for row in strings.split_lines(string(data)) {
            if row == "" do continue
            value, _ := json.parse_string(row, parse_integers = true)
            rec := value.(json.Object)
            fr, _ := agent_int(rec, "f")
            op := Op{f = u64(fr)}
            switch {
            case "goal" in rec:
                op.goal = strings.clone(agent_canonical(rec["goal"]), heap)
                op.kind, _ = agent_goal_find_kind(rec["kind"].(json.String))
                for v in Agent_Goal_Via do if fmt.tprint(v) == rec["via"].(json.String) do op.via = v
                op.id, _   = agent_int(rec, "id")
                op.step, _ = agent_int(rec, "step")
            case "cancel" in rec:
                op.cancel, _ = agent_int(rec, "cancel")
            case "clear" in rec:
                op.clear = true
            case:
                continue
            }
            append(&ops, op)
        }
    }
    testing.expect_value(t, len(ops), 4 + 1 + 1 + 1 + 2)  // the plan cleared nothing: the act was done

    gs2, link2 := exec_test_world(782)
    defer free(gs2)
    defer free(link2)
    for op in ops {
        for gs2.frame < op.f do exec_test_frames(link2, gs2, 1)
        testing.expect_value(t, gs2.frame, op.f)
        switch {
        case op.clear:
            agent_goals_clear(link2, gs2, "cleared")
        case op.cancel > 0:
            for &g in link2.goals.slots[:link2.goals.n] do if g.id == op.cancel do agent_goal_cancel(link2, gs2, &g, "cancelled")
        case:
            testing.expect_value(t, agent_goal_add(link2, gs2, op.kind, op.via, op.goal, op.step), op.id)
        }
    }
    for gs2.frame < end do exec_test_frames(link2, gs2, 1)
    testing.expect_value(t, gs2.frame, gs.frame)
    testing.expect_value(t, gs2.player.pos, gs.player.pos)
    testing.expect_value(t, gs2.player.hp, gs.player.hp)
    testing.expect_value(t, gs2.world.terrain, gs.world.terrain)
}

// A goal that works the window it found open keeps it, and holds still.
@(test)
agent_a_goal_that_uses_the_open_window_holds_still_in_it :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 30)
    T := player_tile(&gs.player)
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Smelter)
    gs.ui.show_smelter = true
    gs.ui.smelter_tile = {T.x + 1, T.y}

    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"act","use":[%d,%d],"move":"right","frames":3}}]}}`, T.x + 1, T.y))
    ticks := 0
    for agent_goals_busy(&link.goals) && ticks < 10 {
        ticks += 1
        agent_drive(link, gs)
        update_agent_goals(gs)
        agent_input(gs)
        testing.expect(t, gs.ui.show_smelter, "the window it works stays open")
        testing.expect(t, !gs.input.move_right, "and the hero does not walk off with it")
        eq_clear(&gs.events)
        agent_after_tick(link, gs)
    }
    testing.expect_value(t, ticks, 3)  // no closing tick
}

// The window rule, window by window, named here and not read from the list the
// rule uses, so a window dropped from that list shows.
@(test)
agent_every_window_stops_the_hero :: proc(t: ^testing.T) {
    Window :: enum { Inventory, Crafting, Rune_Scroll, Smelter, Barrel, Golem_Roster }
    flag :: proc(gs: ^Game_State, w: Window) -> ^bool {
        switch w {
        case .Inventory:    return &gs.ui.show_inventory
        case .Crafting:     return &gs.ui.show_crafting
        case .Rune_Scroll:  return &gs.ui.show_rune_scroll
        case .Smelter:      return &gs.ui.show_smelter
        case .Barrel:       return &gs.ui.show_barrel
        case .Golem_Roster: return &gs.ui.show_golem_roster
        }
        return nil
    }
    for w in Window do for works in ([]bool{false, true}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 30)
        T := player_tile(&gs.player)
        // The machines the two machine windows follow, so they stay open.
        set_tile(&gs.world, int(T.x) + 1, int(T.y), .Smelter)
        gs.ui.smelter_tile = {T.x + 1, T.y}
        set_tile(&gs.world, int(T.x) - 1, int(T.y), .Barrel)
        gs.ui.barrel_tile = {T.x - 1, T.y}
        flag(gs, w)^ = true

        // A use on open air works no window but keeps them all, as a window verb does.
        line := `{"cmd":"goals","add":[{"do":"act","move":"right","jump":true,"frames":3}]}`
        if works do line = fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"act","use":[%d,%d],"move":"right","frames":3}}]}}`, T.x, T.y - 3)
        agent_handle_line(link, gs, line)
        ticks := 0
        for agent_goals_busy(&link.goals) && ticks < 10 {
            ticks += 1
            agent_drive(link, gs)
            update_agent_goals(gs)
            agent_input(gs)
            inp := &gs.input
            moving := inp.move_left || inp.move_right || inp.jump || inp.fly_up || inp.fly_down
            testing.expectf(t, !(flag(gs, w)^ && moving), "%v, works it %v: tick %d moves with the window open", w, works, ticks)
            eq_clear(&gs.events)
            agent_after_tick(link, gs)
        }
        testing.expectf(t, ticks == (3 if works else 4), "%v, works it %v: %d ticks", w, works, ticks)
        testing.expectf(t, flag(gs, w)^ == works, "%v, works it %v: open after is %v", w, works, flag(gs, w)^)
    }
}
