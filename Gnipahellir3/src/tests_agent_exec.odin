package game

import "core:encoding/json"
import "core:fmt"
import "core:math"
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

// ─── The hero's senses and behaviours (card 149) ──────────────────────────────

// Flat stone ground at row G from x0-18 to x0+22 with open air above it, no
// enemies about, and the hero standing at x0.
@(private="file")
hero_test_arena :: proc(gs: ^Game_State) -> (x0, G: int) {
    x0, G = int(SURFACE_HOME_POS.x), int(SURFACE_Y)
    for x in x0 - 18 ..= x0 + 22 do for y in G - 10 ..= G + 12 {
        set_tile(&gs.world, x, y, .Air if y < G else .Stone)
    }
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    gs.roamer_timer = -1e9
    gs.player.pos = {f32(x0) + 0.1, f32(G) - PLAYER_H}
    gs.player.vel = {}
    return
}

// A Vargr standing at x on row G's ground, its velocity saying where it heads.
@(private="file")
hero_test_vargr :: proc(gs: ^Game_State, x: f32, G: int, vel: [2]f32) -> int {
    id, ok := enemy_alloc(&gs.enemies)
    assert(ok)
    e := &gs.enemies.data[id]
    e^ = Enemy{kind = .Vargr, hp = VARGR_HP, hp_max = VARGR_HP, pos = {x, f32(G) - BUILDER_H}, vel = vel, facing = -1}
    e.builder.goal = .Wave_Hunt
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    return id
}

// One tick of the agent, the hero and the events, with every enemy held where
// it stands, so a test says where its threat is.
@(private="file")
hero_test_tick :: proc(link: ^Agent_Link, gs: ^Game_State) {
    agent_drive(link, gs)
    gs.frame += 1
    update_agent_goals(gs)
    update_input(gs)
    update_player(gs)
    process_events(gs)
    eq_clear(&gs.events)
    agent_after_tick(link, gs)
}

@(private="file")
hero_test_count :: proc(text, of: string) -> int {
    return strings.count(text, of)
}

// Glenn 2026-11-03: a goal walking the hero toward a 10-tile drop stops at the
// edge and never walks off.
@(test)
hero_a_goal_toward_a_big_drop_stops_at_the_edge :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 4 ..= x0 + 8 do for y in G ..< G + 10 do set_tile(&gs.world, x, y, .Air)
    exec_test_frames(link, gs, 10)
    hp := gs.player.hp
    testing.expect_value(t, hero_column(&gs.world, x0 + 4, G - 1).drop, 10)

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":120}]}`)
    id := int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    for _ in 0 ..< 200 {
        exec_test_frames(link, gs, 1)
        for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
        testing.expectf(t, gs.player.pos.y + PLAYER_H <= f32(G) + 0.01, "the hero went over at x %.2f", gs.player.pos.x)
    }
    testing.expect_value(t, gs.player.hp, hp)
    testing.expect(t, gs.player.pos.x + PLAYER_W > f32(x0 + 4) - 0.5, "it walked up to the edge")
    g := exec_test_goal(link, gs, id)
    testing.expect_value(t, g["status"].(json.String), "failed")
    testing.expect_value(t, g["reason"].(json.String), "a 10-tile drop ahead")
    pushed := exec_test_pushed(link)
    testing.expect(t, strings.contains(pushed, fmt.tprintf(`"event":"goal_paused","f":`)) && strings.contains(pushed, fmt.tprintf(`"id":%d,"reason":"ledge"}}`, id)), pushed)
    testing.expect(t, !strings.contains(pushed, `"goal_resumed"`), "a goal given up at the edge does not resume")
}

// A drop the fall rule lets go free gets a look first, then the step.
@(test)
hero_looks_at_a_safe_drop_then_steps_down :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    // Two steps down, three tiles each: each gets its own look.
    for x in x0 + 4 ..= x0 + 22 do for y in G ..< G + 3 do set_tile(&gs.world, x, y, .Air)
    for x in x0 + 8 ..= x0 + 22 do for y in G + 3 ..< G + 6 do set_tile(&gs.world, x, y, .Air)
    exec_test_frames(link, gs, 10)
    hp := gs.player.hp

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":80}]}`)
    looks: [dynamic]int
    defer delete(looks)
    run := 0
    for agent_goals_busy(&link.goals) && gs.frame < 600 {
        exec_test_frames(link, gs, 1)
        if gs.hero.current == .Avoid_Ledge {
            run += 1
            testing.expect(t, !gs.input.move_right, "the hero holds still while it looks")
        } else if run > 0 {
            append(&looks, run)
            run = 0
        }
    }
    testing.expect_value(t, len(looks), 2)
    for looked in looks {
        testing.expect(t, f32(looked) >= HERO_LEDGE_LOOK_S / AGENT_STEP - 1, fmt.tprintf("looked %d ticks", looked))
        testing.expect(t, f32(looked) <= HERO_LEDGE_LOOK_S / AGENT_STEP + 1, fmt.tprintf("looked %d ticks", looked))
    }
    testing.expect_value(t, link.goals.slots[link.goals.n - 1].status, Agent_Goal_Status.Done)
    exec_test_frames(link, gs, 60)
    testing.expect(t, gs.player.pos.y + PLAYER_H > f32(G + 6) - 0.01, "and stepped down both")
    testing.expect_value(t, gs.player.hp, hp)
    testing.expect_value(t, hero_test_count(exec_test_pushed(link), `"reason":"ledge"`), 4)  // paused, resumed, twice
}

// A Vargr closing in pauses the goal; a hero with health and a sword fights it,
// and the goal goes on after.
@(test)
hero_fights_a_closing_vargr_then_resumes_the_goal :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.selected = 0
    vargr := hero_test_vargr(gs, f32(x0) + 6.1, G, {-RAIDER_SPEED, 0})

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":60}]}`)
    id := int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    fought := 0
    for agent_goals_busy(&link.goals) && fought < 2000 {
        hero_test_tick(link, gs)
        if gs.hero.current == .Fight do fought += 1
    }
    pushed := exec_test_pushed(link)
    testing.expect(t, !gs.enemies.active[vargr], "the hero cut the Vargr down")
    testing.expect(t, fought > 0)
    testing.expect(t, strings.contains(pushed, fmt.tprintf(`"event":"goal_paused","f":`)) && strings.contains(pushed, fmt.tprintf(`"id":%d,"reason":"fight"}}`, id)), pushed)
    testing.expect(t, strings.contains(pushed, `"event":"goal_resumed"`), pushed)
    testing.expect_value(t, hero_test_count(pushed, `"reason":"fight"`), 2)
    testing.expect(t, strings.index(pushed, `"goal_paused"`) < strings.index(pushed, `"goal_resumed"`))
    testing.expect(t, strings.index(pushed, `"goal_resumed"`) < strings.index(pushed, `"goal_done"`), pushed)
    testing.expect_value(t, exec_test_goal(link, gs, id)["status"].(json.String), "done")
}

// The same Vargr against a hero low on health: it turns back to the safe ground
// it came from, and the goal waits for the danger to pass.
@(test)
hero_flees_a_closing_vargr_when_hurt_then_resumes :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.selected = 0
    gs.player.hp = max(1, gs.player.hp_max / 5)
    hp := gs.player.hp
    vargr := hero_test_vargr(gs, f32(x0) + 10.1, G, {-RAIDER_SPEED, 0})
    start := gs.player.pos.x
    reached := start

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":60}]}`)
    id := int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    fled := 0
    for fled < 60 && gs.frame < 1000 {
        hero_test_tick(link, gs)
        if gs.hero.current == .Flee do fled += 1
        reached = max(reached, gs.player.pos.x)
        testing.expect(t, gs.hero.current != .Fight, "too hurt to fight")
    }
    testing.expect_value(t, fled, 60)
    testing.expect(t, reached > start + 1, "the goal walked it toward the Vargr first")
    testing.expect(t, abs(gs.player.pos.x - start) < 0.5, fmt.tprintf("turned back from %.2f to %.2f, safe ground at %.2f", reached, gs.player.pos.x, start))
    testing.expect_value(t, exec_test_goal(link, gs, id)["status"].(json.String), "running")
    testing.expect(t, strings.contains(exec_test_pushed(link), fmt.tprintf(`"id":%d,"reason":"flee"}}`, id)), exec_test_pushed(link))

    // It drops back out of HERO_THREAT_FAR and stops coming: the run is over.
    e := &gs.enemies.data[vargr]
    e.pos.x = gs.player.pos.x + HERO_THREAT_FAR + 2
    e.vel = {}
    for agent_goals_busy(&link.goals) && gs.frame < 2000 do hero_test_tick(link, gs)
    testing.expect(t, gs.enemies.active[vargr])
    pushed := exec_test_pushed(link)
    testing.expect(t, strings.contains(pushed, fmt.tprintf(`"event":"goal_resumed","f":`)), pushed)
    testing.expect_value(t, hero_test_count(pushed, `"reason":"flee"`), 2)
    testing.expect_value(t, exec_test_goal(link, gs, id)["status"].(json.String), "done")
    testing.expect_value(t, gs.player.hp, hp)
}

// Two behaviours scoring near the same do not trade places every tick; a clear
// winner takes over once the running one has had its hold, and danger at once.
@(test)
hero_near_equal_scores_do_not_flip :: proc(t: ^testing.T) {
    b: Hero_Brain
    b.current = .Fight
    b.held = 10
    flips := 0
    for i in 0 ..< 40 {
        b.scores[.Fight] = 60 if i % 2 == 0 else 62
        b.scores[.Flee]  = 62 if i % 2 == 0 else 60
        if next := hero_pick(&b); next != b.current {
            b.current, b.held = next, 0
            flips += 1
        } else {
            b.held += AGENT_STEP
        }
    }
    testing.expect_value(t, flips, 0)
    testing.expect_value(t, b.current, Hero_Behaviour.Fight)

    // A clear winner, but the running one has only just started.
    b.held = 0
    b.scores[.Fight] = 60
    b.scores[.Flee]  = 60 + HERO_SWITCH_MARGIN + 1
    testing.expect_value(t, hero_pick(&b), Hero_Behaviour.Fight)
    b.held = HERO_MIN_HOLD_S - 0.01
    testing.expect_value(t, hero_pick(&b), Hero_Behaviour.Fight)
    b.held = HERO_MIN_HOLD_S
    testing.expect_value(t, hero_pick(&b), Hero_Behaviour.Flee)
    b.scores[.Flee] = 60 + HERO_SWITCH_MARGIN
    testing.expect_value(t, hero_pick(&b), Hero_Behaviour.Fight)  // a tie at the margin holds

    // Danger cuts the hold short, and a behaviour with nothing to do lets go.
    b.held = 0
    b.scores[.Avoid_Ledge] = HERO_URGENT_SCORE
    testing.expect_value(t, hero_pick(&b), Hero_Behaviour.Avoid_Ledge)
    b.scores[.Avoid_Ledge] = 0
    b.scores[.Fight] = 0
    b.scores[.Flee]  = 1
    testing.expect_value(t, hero_pick(&b), Hero_Behaviour.Flee)
}

// Nothing queued and a threat about: the hero makes for the safe ground it
// walked, and tells the agent once that it is idle.
@(test)
hero_idle_with_a_threat_near_goes_to_safe_ground :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":60}]}`)
    for agent_goals_busy(&link.goals) do hero_test_tick(link, gs)
    testing.expect(t, gs.hero.senses.n_safe >= 3, "the walk left safe ground behind it")
    far := gs.player.pos.x
    testing.expect(t, far > f32(x0) + 5)

    hero_test_vargr(gs, far + 10, G, {})
    still := 0
    for _ in 0 ..< 240 {
        hero_test_tick(link, gs)
        testing.expect_value(t, gs.hero.current, Hero_Behaviour.Idle)
        still = still + 1 if !gs.input.move_left && !gs.input.move_right else 0
    }
    testing.expect(t, still >= 60, "there it stands, no jitter")
    testing.expect(t, gs.player.pos.x < far - 4, fmt.tprintf("from %.2f to %.2f", far, gs.player.pos.x))
    spot := false
    hx := i32(gs.player.pos.x + PLAYER_W * 0.5)
    for s in gs.hero.senses.safe[:gs.hero.senses.n_safe] do spot ||= abs(s.x - hx) <= 1
    testing.expect(t, spot, "and stands on ground it stood on safe")
    testing.expect(t, gs.player.grounded)
    testing.expect_value(t, hero_test_count(exec_test_pushed(link), `"event":"idle"`), 1)
}

// The danger map's columns, each from the fall rule in update_player.
@(test)
hero_columns_read_the_fall_rule :: proc(t: ^testing.T) {
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs, 781)
    x0, G := hero_test_arena(gs)
    w := &gs.world
    pit :: proc(w: ^World_Grid, x, G, depth: int) {
        for y in G ..< G + depth do set_tile(w, x, y, .Air)
    }
    pit(w, x0 + 1, G, 5)
    pit(w, x0 + 2, G, 6)
    pit(w, x0 + 3, G, 7)
    pit(w, x0 + 4, G, 8)
    pit(w, x0 + 5, G, 9)
    set_tile(w, x0 + 5, G + 8, .Water)  // the last tile of its drop is water
    set_tile(w, x0 + 6, G - 1, .Stone)
    pit(w, x0 + 7, G, 2)
    set_tile(w, x0 + 7, G + 1, .Lava)
    set_tile(w, x0 + 8, G - 4, .Wood)
    set_tile(w, x0 + 9, G - 4, .Stone)
    set_tile(w, x0 + 9, G - 5, .Wood)
    set_tile(w, x0 + 10, G - 1 - 2 - HERO_LOOSE_ROWS, .Wood)  // past the rows searched

    fy := G - 1
    testing.expect_value(t, hero_column(w, x0, fy), Hero_Column{})
    testing.expect_value(t, hero_column(w, x0 + 1, fy), Hero_Column{drop = 5})
    testing.expect_value(t, hero_column(w, x0 + 2, fy), Hero_Column{drop = 6, hurts = 1})
    testing.expect_value(t, hero_column(w, x0 + 3, fy), Hero_Column{drop = 7, hurts = 2})
    testing.expect_value(t, hero_column(w, x0 + 4, fy), Hero_Column{drop = 8, hurts = 2})
    testing.expect_value(t, hero_column(w, x0 + 5, fy), Hero_Column{drop = 8})
    testing.expect_value(t, hero_column(w, x0 + 6, fy), Hero_Column{wall = true})
    testing.expect_value(t, hero_column(w, x0 + 7, fy), Hero_Column{drop = 1, hazard = true})
    testing.expect_value(t, hero_column(w, x0 + 8, fy), Hero_Column{loose = true})
    testing.expect_value(t, hero_column(w, x0 + 9, fy), Hero_Column{})  // stone holds what hangs over it
    testing.expect_value(t, hero_column(w, x0 + 10, fy), Hero_Column{})
    set_tile(w, x0 + 11, fy, .Lava)
    testing.expect_value(t, hero_column(w, x0 + 11, fy), Hero_Column{hazard = true})
    set_tile(w, x0 + 12, fy - 1, .Lava)
    testing.expect_value(t, hero_column(w, x0 + 12, fy), Hero_Column{hazard = true})
}

// What the hero sees: the enemies on screen, nearest first, and how long each
// has been there; and the safe ground it leaves behind.
@(test)
hero_senses_see_the_screen_nearest_first :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    hx := gs.player.pos.x + PLAYER_W * 0.5
    s := &gs.hero.senses
    testing.expect_value(t, s.n_safe, 1)
    testing.expect_value(t, s.safe[0], [2]i32{i32(x0), i32(G - 1)})
    testing.expect_value(t, s.origin_x, i32(x0))
    testing.expect_value(t, s.feet_y, i32(G - 1))

    // Two more than the senses hold, the far ones first, and one off screen.
    off := hero_test_vargr(gs, hx + f32(AGENT_VIEW_W) / 2 + 1, G, {})
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_threats, 0)
    gs.enemies.data[off].pos = {hx - 2, gs.player.pos.y - f32(AGENT_VIEW_H) / 2 - 2}
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_threats, 0)
    despawn_enemy(gs, off)
    for i in 0 ..< HERO_THREATS_MAX + 2 do hero_test_vargr(gs, f32(x0) + 3 + f32(HERO_THREATS_MAX + 2 - i), G, {})
    hero_test_vargr(gs, f32(x0) + 17, G, {})  // farther than all, once the senses are full
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_threats, HERO_THREATS_MAX)
    for i in 1 ..< s.n_threats do testing.expect(t, s.threats[i - 1].dist <= s.threats[i].dist)
    testing.expect(t, s.threats[0].dist < 5, "the nearest is kept")
    testing.expect_value(t, s.threats[0].damage, WAVE_DAMAGE)
    testing.expect_value(t, s.threats[0].kind, Enemy_Kind.Vargr)
    testing.expect(t, s.threats[0].in_line)
    testing.expect(t, !s.threats[0].closing)
    testing.expect_value(t, s.threats[0].seen_for, 0)
    testing.expect(t, s.threats[0].dx > 0)
    testing.expect(t, hero_threat(&gs.hero) == nil, "not noticed yet")
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.threats[0].seen_for, gs.delta_time)
    for gs.hero.senses.threats[0].seen_for < HERO_REACTION_S do hero_sense(gs, &gs.hero)
    testing.expect(t, hero_threat(&gs.hero) == &s.threats[0], "noticed after the reaction delay")

    // Coming at the hero, behind a wall, a roamer's bite and a Draugr's claw.
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    a := hero_test_vargr(gs, f32(x0) + 4, G, {-1, 0})
    hero_sense(gs, &gs.hero)
    testing.expect(t, s.threats[0].closing)
    // It stops: still coming, for a while.
    gs.enemies.data[a].vel = {1, 0}
    hero_sense(gs, &gs.hero)
    testing.expect(t, s.threats[0].closing, "a hunter that pauses is still coming")
    for i := 0; s.threats[0].closing_ago < HERO_CLOSING_MEMORY_S - 0.001 && i < 1000; i += 1 {
        testing.expect(t, s.threats[0].closing)
        hero_sense(gs, &gs.hero)
    }
    hero_sense(gs, &gs.hero)
    testing.expect(t, !s.threats[0].closing, "and then it is not")
    // Standing still but nearer than a tick ago is coming too.
    gs.enemies.data[a].vel = {}
    gs.enemies.data[a].pos.x -= 0.1
    hero_sense(gs, &gs.hero)
    testing.expect(t, s.threats[0].closing)
    for _ in 0 ..< 100 do hero_sense(gs, &gs.hero)
    testing.expect(t, !s.threats[0].closing)
    for y in G - 4 ..< G do set_tile(&gs.world, x0 + 3, y, .Stone)
    s.n_threats = 0  // seen first behind it
    hero_sense(gs, &gs.hero)
    testing.expect(t, !s.threats[0].in_line)
    for i in 0 ..< 200 do hero_sense(gs, &gs.hero)
    testing.expect(t, hero_threat(&gs.hero) == nil, "one only ever behind a wall cannot come at the hero")
    for y in G - 4 ..< G do set_tile(&gs.world, x0 + 3, y, .Air)
    for y in G - 4 ..< G do set_tile(&gs.world, x0 + 1, y, .Stone)
    gs.enemies.data[a].pos.x = f32(x0) + 2
    for i in 0 ..< 30 do hero_sense(gs, &gs.hero)
    testing.expect(t, !s.threats[0].in_line && hero_threat(&gs.hero) != nil, "but one in sword reach can")
    for y in G - 4 ..< G do set_tile(&gs.world, x0 + 1, y, .Air)
    gs.enemies.data[a].kind = .Ember_Beetle
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.threats[0].damage, roamer_table[.Ember_Beetle].damage)
    testing.expect_value(t, s.threats[0].seen_for, 0)  // a new kind in the slot is a new enemy
    gs.enemies.data[a].kind = .Pond_Frog
    for i in 0 ..< 30 do hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.threats[0].damage, 0)
    testing.expect(t, hero_threat(&gs.hero) == nil, "a frog is no threat")
    gs.enemies.data[a].kind = .Undead
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.threats[0].damage, (gs.player.hp_max + 3) / 4)
}

// Safe ground is laid only where the hero stands clear, and spaced out.
@(test)
hero_safe_ground_is_ground_stood_on_clear :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    s := &gs.hero.senses
    testing.expect_value(t, s.n_safe, 1)

    // A step to the next tile is too close to the last spot; two make a new one.
    gs.player.pos.x += 1
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_safe, 1)
    gs.player.pos.x += 1
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_safe, 2)
    testing.expect_value(t, s.safe[1], [2]i32{i32(x0 + 2), i32(G - 1)})

    // Not with a threat near, not in the air, not on a burn.
    v := hero_test_vargr(gs, gs.player.pos.x + HERO_SAFE_CLEAR - 1, G, {})
    gs.player.pos.x += 2
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_safe, 2)
    despawn_enemy(gs, v)
    gs.enemies.data[hero_test_vargr(gs, gs.player.pos.x + HERO_SAFE_CLEAR - 1, G, {})].kind = .Pond_Frog
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_safe, 3)  // a frog bites nobody
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    gs.player.pos.x += 2
    gs.player.grounded = false
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_safe, 3)
    gs.player.grounded = true
    set_tile(&gs.world, int(gs.player.pos.x + PLAYER_W * 0.5), G - 1, .Lava)
    hero_sense(gs, &gs.hero)
    testing.expect_value(t, s.n_safe, 3)

    // The ring keeps the last HERO_SAFE_MAX.
    for i in 0 ..< HERO_SAFE_MAX + 3 {
        gs.player.pos.x = f32(x0 - 16 + 2 * i) + 0.1
        hero_sense(gs, &gs.hero)
    }
    testing.expect_value(t, s.n_safe, HERO_SAFE_MAX)
    newest := s.safe[(s.safe_next + HERO_SAFE_MAX - 1) % HERO_SAFE_MAX]
    testing.expect_value(t, newest.x, i32(x0 - 16 + 2 * (HERO_SAFE_MAX + 2)))
}

// The behaviours' walk: never into a drop that hurts or a burn, over a wall too
// high to step, and a tick to shut the windows first.
@(test)
hero_walk_keeps_off_bad_drops_and_jumps_walls :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    b := &gs.hero
    walk :: proc(gs: ^Game_State, dir: i8) -> Agent_Command {
        gs.agent.cmd, gs.agent.first = {}, false
        hero_sense(gs, &gs.hero)
        hero_walk(gs, &gs.hero, dir)
        return gs.agent.cmd
    }
    // Right at the edge of a 7-deep pit, two columns on.
    for y in G ..< G + 7 do set_tile(&gs.world, x0 + 1, y, .Air)
    gs.player.pos.x = f32(x0 + 1) - PLAYER_W - HERO_LEDGE_LOOKAHEAD + 0.01
    testing.expect_value(t, walk(gs, 1).move, 0)
    testing.expect_value(t, walk(gs, -1).move, -1)
    gs.flight_t = 1
    testing.expect_value(t, walk(gs, 1).move, 1)  // flight takes any drop
    gs.flight_t = 0
    gs.leaf_fall_t = 1
    testing.expect_value(t, walk(gs, 1).move, 1)
    gs.leaf_fall_t = 0
    gs.player.pos.x -= 0.05
    testing.expect_value(t, walk(gs, 1).move, 1)  // not there yet
    gs.player.pos.x = f32(x0 + 1) - PLAYER_W + 0.3  // already hanging over it
    testing.expect_value(t, walk(gs, 1).move, 0)
    for y in G ..< G + 7 do set_tile(&gs.world, x0 + 1, y, .Stone)

    // A burn ahead, on the left.
    gs.player.pos.x = f32(x0) + 0.1
    set_tile(&gs.world, x0 - 1, G - 1, .Lava)
    gs.player.pos.x = f32(x0) + HERO_LEDGE_LOOKAHEAD - 0.01
    testing.expect_value(t, walk(gs, -1).move, 0)
    set_tile(&gs.world, x0 - 1, G - 1, .Air)

    // A step up is walked; a two-high wall is jumped, on a first tick.
    set_tile(&gs.world, x0 + 1, G - 1, .Stone)
    gs.player.pos.x = f32(x0 + 1) - PLAYER_W - 0.1
    c := walk(gs, 1)
    testing.expect(t, c.move == 1 && !c.jump)
    set_tile(&gs.world, x0 + 1, G - 2, .Stone)
    c = walk(gs, 1)
    testing.expect(t, c.move == 1 && c.jump && gs.agent.first)
    gs.player.grounded = false
    c = walk(gs, 1)
    testing.expect(t, c.move == 1 && !c.jump, "no jump from the air")
    gs.player.grounded = true

    // An open window: one still tick that sweeps it.
    gs.ui.show_inventory = true
    c = walk(gs, -1)
    testing.expect(t, c.move == 0 && gs.agent.first)
    _ = b
}

// The fight behaviour swings at a human pace and only in reach; a fire wand
// shoots from range.
@(test)
hero_fight_swings_at_a_human_pace :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.selected = 0
    v := hero_test_vargr(gs, f32(x0) + 5, G, {-1, 0})
    gs.enemies.data[v].hp = 1000
    gs.enemies.data[v].hp_max = 1000
    // Out of reach it walks up and does not swing at air.
    walked := false
    for _ in 0 ..< 60 {
        hero_test_tick(link, gs)
        e := &gs.enemies.data[v]
        if chebyshev(builder_tile(e), player_tile(&gs.player)) > MELEE_REACH {
            testing.expect(t, !gs.input.attack, "a swing out of reach")
            walked ||= gs.input.move_right
        }
    }
    testing.expect(t, walked)
    gs.player.pos.x = f32(x0) + 0.1
    gs.enemies.data[v].pos.x = f32(x0) + 1.5
    gs.enemies.data[v].vel = {}
    gs.enemies.data[v].hp = 1000
    swings := 0
    ticks := 180  // 3 s
    for _ in 0 ..< ticks {
        hero_test_tick(link, gs)
        if gs.input.attack do swings += 1
        if gs.hero.current == .Fight do testing.expect(t, !gs.input.move_right && !gs.input.move_left, "in reach it stands")
    }
    fought := 3 - HERO_REACTION_S
    testing.expect(t, swings >= int(fought / HERO_SWING_S) - 1 && swings <= int(fought / HERO_SWING_S) + 1, fmt.tprintf("%d swings", swings))
    testing.expect_value(t, gs.enemies.data[v].hp, 1000 - swings * int(player_stat(&gs.player, .Attack)))

    // A fire wand shoots from where it stands, and walks up from out of range.
    gs.enemies.data[v].pos.x = f32(x0) + 6
    gs.player.inventory.slots[0] = {item = .Fire_Wand, count = 1}
    gs.player.mana = 1000
    hero_test_tick(link, gs)
    testing.expect(t, gs.input.mine && !gs.input.move_right, "the wand needs no reach")
    gs.enemies.data[v].pos.x = f32(x0) + HERO_WAND_RANGE + 1.5
    closed := false
    for _ in 0 ..< 30 {
        hero_test_tick(link, gs)
        closed ||= gs.input.move_right && gs.input.mine
    }
    testing.expect(t, closed, "out of wand range it closes in, firing")
}

// A goal walked to a burn gives up, a jump over a pit is no walk off it, and
// a flying hero takes any drop.
@(test)
hero_ledge_gives_up_at_a_burn_and_lets_a_jump_go :: proc(t: ^testing.T) {
    {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        for x in x0 + 2 ..= x0 + 6 do for y in G ..< G + 10 do set_tile(&gs.world, x, y, .Air)
        for _ in 0 ..< 10 do hero_test_tick(link, gs)
        gs.flight_t = 100
        agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":30}]}`)
        for agent_goals_busy(&link.goals) && gs.frame < 300 do hero_test_tick(link, gs)
        testing.expect_value(t, link.goals.slots[0].status, Agent_Goal_Status.Done)
        testing.expect(t, gs.player.pos.x > f32(x0 + 3), "it flew over the drop")
    }
    {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        set_tile(&gs.world, x0 + 3, G - 1, .Lava)
        for _ in 0 ..< 10 do hero_test_tick(link, gs)
        hp := gs.player.hp
        agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":60}]}`)
        for agent_goals_busy(&link.goals) && gs.frame < 300 do hero_test_tick(link, gs)
        testing.expect_value(t, link.goals.slots[0].status, Agent_Goal_Status.Failed)
        testing.expect_value(t, string(link.goals.slots[0].reason.buf[:link.goals.slots[0].reason.len]), "a burn ahead")
        testing.expect_value(t, gs.player.hp, hp)
    }
    {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        for x in x0 + 1 ..= x0 + 3 do for y in G ..< G + 10 do set_tile(&gs.world, x, y, .Air)
        gs.player.pos.x = f32(x0 + 1) - PLAYER_W - 0.05
        for _ in 0 ..< 10 do hero_test_tick(link, gs)
        hp := gs.player.hp
        agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","jump":true,"frames":30}]}`)
        for agent_goals_busy(&link.goals) && gs.frame < 300 do hero_test_tick(link, gs)
        testing.expect_value(t, link.goals.slots[0].status, Agent_Goal_Status.Done)
        testing.expect(t, gs.player.pos.x > f32(x0 + 4), "it jumped the pit")
        testing.expect(t, gs.player.pos.y + PLAYER_H <= f32(G) + 0.01)
        testing.expect_value(t, gs.player.hp, hp)
    }
}

// The notes reach a client once each, one far behind gets the newest, and a New
// Game does not lose the count.
@(test)
hero_notes_are_pushed_once_and_survive_a_new_game :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
    testing.expect(t, link.goals.note_count > 0, "idle was noted before the client spoke goals")
    testing.expect_value(t, link.seen_notes, link.goals.note_count)  // and is not news
    link.push_len = 0

    for i in 0 ..< HERO_NOTES_MAX + 2 {
        link.goals.notes[link.goals.note_count % HERO_NOTES_MAX] = {kind = .Paused, goal = 100 + i, why = .Fight}
        link.goals.note_count += 1
    }
    agent_after_tick(link, gs)
    pushed := exec_test_pushed(link)
    testing.expect_value(t, hero_test_count(pushed, `"goal_paused"`), HERO_NOTES_MAX)
    testing.expect(t, !strings.contains(pushed, `"id":101,`) && strings.contains(pushed, `"id":102,`) && strings.contains(pushed, fmt.tprintf(`"id":%d,"reason":"fight"}}`, 100 + HERO_NOTES_MAX + 1)), pushed)
    link.push_len = 0
    agent_after_tick(link, gs)
    testing.expect_value(t, link.push_len, 0)

    gs.hero = {}  // a New Game's brain
    link.goals.notes[link.goals.note_count % HERO_NOTES_MAX] = {kind = .Resumed, goal = 7, why = .Flee}
    link.goals.note_count += 1
    agent_after_tick(link, gs)
    testing.expect_value(t, exec_test_pushed(link), fmt.tprintf(`{{"event":"goal_resumed","f":%d,"id":7,"reason":"flee"}}`+"\n", gs.frame))
    link.push_len = 0

    // The queue running dry says idle once, with what it has noticed.
    hero_test_vargr(gs, f32(x0) + 15, G, {})
    gs.enemies.data[hero_test_vargr(gs, f32(x0) - 6, G, {})].kind = .Pond_Frog  // in sight, bites nobody
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":30}]}`)
    for _ in 0 ..< 60 do hero_test_tick(link, gs)
    testing.expect(t, strings.contains(exec_test_pushed(link), `"event":"idle"`) && strings.contains(exec_test_pushed(link), `"threats":1}`), exec_test_pushed(link))
    testing.expect_value(t, hero_test_count(exec_test_pushed(link), `"event":"idle"`), 1)
}

// A goal cancelled while a fight holds it is forgotten; the next goal the fight
// holds is paused in its own name.
@(test)
hero_a_goal_cancelled_while_paused_is_forgotten :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.selected = 0
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":600}]}`)
    v := hero_test_vargr(gs, f32(x0) + 1.5, G, {})
    gs.enemies.data[v].hp = 1000
    for gs.hero.current != .Fight && gs.frame < 200 do hero_test_tick(link, gs)
    testing.expect_value(t, gs.hero.paused_goal, 1)
    agent_handle_line(link, gs, `{"cmd":"goals","cancel":1}`)
    hero_test_tick(link, gs)
    testing.expect_value(t, gs.hero.paused_goal, 0)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":600}]}`)
    hero_test_tick(link, gs)
    testing.expect_value(t, gs.hero.paused_goal, 2)
    testing.expect(t, strings.contains(exec_test_pushed(link), `"id":2,"reason":"fight"}`), exec_test_pushed(link))
    testing.expect(t, !strings.contains(exec_test_pushed(link), `"goal_resumed"`))

    // A one-frame goal held by the fight resumes and ends on one tick: the
    // resume is told first.
    agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":1}]}`)
    hero_test_tick(link, gs)
    testing.expect_value(t, gs.hero.paused_goal, 3)
    link.push_len = 0
    despawn_enemy(gs, v)
    hero_test_tick(link, gs)
    testing.expect_value(t, exec_test_pushed(link), fmt.tprintf(`{{"event":"goal_resumed","f":%d,"id":3,"reason":"fight"}}`+"\n"+`{{"event":"goal_done","f":%d,"id":3}}`+"\n", gs.frame, gs.frame))
}

// Unarmed and unhurt, a closing threat still sends the hero off: straight away
// when it has no safe ground far enough from the threat.
@(test)
hero_unarmed_runs_straight_away_with_no_safe_ground :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.hero.senses.n_safe = 0
    gs.hero.senses.safe_next = 0
    hero_test_vargr(gs, f32(x0) + 4, G, {-RAIDER_SPEED, 0})
    start := gs.player.pos.x
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":600}]}`)
    fled := 0
    for _ in 0 ..< 120 {
        hero_test_tick(link, gs)
        testing.expect(t, gs.hero.current != .Fight, "no sword, no fight")
        if gs.hero.current == .Flee do fled += 1
    }
    testing.expect(t, fled > 60, fmt.tprintf("fled %d ticks", fled))
    testing.expect(t, gs.player.pos.x < start - 4, fmt.tprintf("ran from %.2f to %.2f", start, gs.player.pos.x))
}

// How much a threat presses on the scores.
@(test)
hero_press_falls_off_with_distance :: proc(t: ^testing.T) {
    th := Hero_Threat{dist = HERO_THREAT_NEAR, closing = true}
    testing.expect_value(t, hero_press(&th), 1)
    th.dist = HERO_THREAT_FAR
    testing.expect_value(t, hero_press(&th), 0)
    th.dist = (HERO_THREAT_NEAR + HERO_THREAT_FAR) / 2
    testing.expect_value(t, hero_press(&th), 0.5)
    th.closing = false
    testing.expect_value(t, hero_press(&th), 0.25)  // one out there not coming counts half
    th.dist = HERO_THREAT_NEAR
    testing.expect_value(t, hero_press(&th), 1)     // but not when it is this close
}

// On every screen but play the goal plays straight through: a dead hero's
// dismiss is not held up by a threat beside the body.
@(test)
hero_off_the_play_screen_goals_play_straight :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    hero_test_vargr(gs, f32(x0) + 2, G, {-1, 0})
    gs.player.dead = true
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":40}]}`)
    for _ in 0 ..< 41 do hero_test_tick(link, gs)
    testing.expect_value(t, link.goals.slots[link.goals.n - 1].status, Agent_Goal_Status.Done)
    testing.expect(t, !strings.contains(exec_test_pushed(link), `"goal_paused"`), exec_test_pushed(link))
}

// A live Vargr, its own AI running, hunts in stops and starts: a hurt hero that
// runs keeps running until the Vargr is out of HERO_THREAT_FAR or gone, and
// never turns back at it.
@(test)
hero_flight_from_a_live_vargr_holds :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 10)
    gs.player.hp = max(1, gs.player.hp_max / 5)
    v := hero_test_vargr(gs, f32(x0) + 10.1, G, {})
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":60}]}`)
    fleeing, paused_goal_moves := false, 0
    for _ in 0 ..< 600 {
        exec_test_frames(link, gs, 1)
        if gs.player.dead do break
        if !fleeing {
            fleeing = gs.hero.current == .Flee
            continue
        }
        if !gs.enemies.active[v] do break
        e := &gs.enemies.data[v]
        d := e.pos + enemy_body_size(e.kind) * 0.5 - (gs.player.pos + {PLAYER_W, PLAYER_H} * 0.5)
        if math.sqrt(d.x * d.x + d.y * d.y) >= HERO_THREAT_FAR do break
        testing.expectf(t, gs.hero.current == .Flee, "frame %d: %v with the Vargr %.1f tiles off", gs.frame, gs.hero.current, math.sqrt(d.x * d.x + d.y * d.y))
        if gs.hero.current != .Flee do paused_goal_moves += 1
    }
    testing.expect(t, fleeing, "the hero ran")
    testing.expect_value(t, paused_goal_moves, 0)
}

// Cornered at a drop with a threat coming: a fall that leaves the hero
// standing is taken, a fall that would kill sends it past the threat instead.
@(test)
hero_cornered_at_a_drop_is_never_frozen :: proc(t: ^testing.T) {
    Case :: enum { Survivable, Lethal, Burn }
    for c in Case {
        lethal := c != .Survivable
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        for x in x0 - 12 ..= x0 - 1 do for y in G ..< G + 10 do set_tile(&gs.world, x, y, .Air)
        if c == .Burn do for x in x0 - 12 ..= x0 - 1 do set_tile(&gs.world, x, G + 9, .Lava)
        gs.player.pos.x = f32(x0) + 0.05
        exec_test_frames(link, gs, 10)
        agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
        if c == .Lethal do gs.player.hp = hero_column(&gs.world, x0 - 1, G - 1).hurts
        if c == .Burn do testing.expect(t, hero_column(&gs.world, x0 - 1, G - 1).hazard && hero_column(&gs.world, x0 - 1, G - 1).hurts < gs.player.hp)
        hp := gs.player.hp
        vx := f32(x0) + 5.1
        hero_test_vargr(gs, vx, G, {})
        stood, ticks, answered := 0, 0, false
        for ticks < 600 && !gs.player.dead {
            exec_test_frames(link, gs, 1)
            ticks += 1
            if gs.player.pos.y + PLAYER_H > f32(G) + 0.5 || gs.player.pos.x > vx + 2 do break
            noticed := hero_threat(&gs.hero) != nil
            if lethal && noticed && !answered {
                answered = true
                testing.expectf(t, gs.input.move_right, "%v: the first answer is the way past", c)
            }
            stood = stood + 1 if noticed && !gs.input.move_left && !gs.input.move_right else 0
            testing.expectf(t, stood < 30, "%v: stood %d ticks with the threat on it", c, stood)
        }
        testing.expectf(t, !gs.player.dead, "%v: the hero died", c)
        if lethal {
            testing.expectf(t, gs.player.pos.x > vx + 2, "%v: it ran past the threat", c)
            testing.expectf(t, gs.player.pos.y + PLAYER_H <= f32(G) + 0.01, "%v: and kept off the drop", c)
            exec_test_frames(link, gs, 5)
            testing.expect_value(t, gs.hero.break_dir, 0)  // past it, the run is plain flight again
        } else {
            exec_test_frames(link, gs, 90)
            testing.expect(t, gs.player.pos.y + PLAYER_H > f32(G + 9), "it took the drop")
            testing.expect(t, gs.player.hp < hp && gs.player.hp > 0, fmt.tprintf("and lived, hp %d", gs.player.hp))
        }
    }
}

// The reviewer's soak, kept: natural home terrain, a live Vargr ten tiles off
// on either side, a hurt hero walking at it.  Holes and bumps cut the line of
// sight on and off; the hero must not hand a fight or a flight back to the
// goal while the Vargr is still within HERO_THREAT_FAR.
@(test)
hero_soak_no_hand_back_while_the_vargr_is_near :: proc(t: ^testing.T) {
    // Home is laid by hand, so the seeds mostly change what roams; the start
    // distances change the ground the chase crosses.
    seeds := [?]u32{781, 7, 42}
    hand_backs, runs := 0, 0
    for seed in seeds do for off in ([3]f32{8, 10, 13}) do for side in ([2]f32{-1, 1}) do for div in ([2]int{5, 2}) {
        gs, link := exec_test_world(seed)
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
        gs.roamer_timer = -1e9
        gs.player.hp = max(1, gs.player.hp_max / div)
        vx := int(gs.player.pos.x) + int(side * off)
        G := 0
        for G < GRID_H - 1 && !is_solid(&gs.world, vx, G) do G += 1
        v := hero_test_vargr(gs, f32(vx) + 0.1, G, {})
        agent_handle_line(link, gs, side < 0 ? `{"cmd":"goals","add":[{"do":"act","move":"left","frames":300}]}` : `{"cmd":"goals","add":[{"do":"act","move":"right","frames":300}]}`)
        runs += 1
        prev := gs.hero.current
        for _ in 0 ..< 300 {
            exec_test_frames(link, gs, 1)
            if gs.player.dead || !gs.enemies.active[v] do break
            cur := gs.hero.current
            e := &gs.enemies.data[v]
            d := e.pos + enemy_body_size(e.kind) * 0.5 - (gs.player.pos + {PLAYER_W, PLAYER_H} * 0.5)
            near := math.sqrt(d.x * d.x + d.y * d.y) < HERO_THREAT_FAR - 0.5  // the senses read it a tick earlier
            if near && (prev == .Flee || prev == .Fight) && cur != .Flee && cur != .Fight do hand_backs += 1
            prev = cur
        }
    }
    testing.expect_value(t, runs, 36)
    testing.expectf(t, hand_backs <= HERO_SOAK_HAND_BACKS, "%d hand-backs in %d runs", hand_backs, runs)
}

HERO_SOAK_HAND_BACKS :: 0

// Noticed once, a threat stays noticed behind a wall while it is near, is
// forgotten past HERO_THREAT_FAR, and one never seen in line is never noticed.
@(test)
hero_a_noticed_threat_is_kept_behind_a_wall_until_far :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    v := hero_test_vargr(gs, f32(x0) + 6.1, G, {})
    for _ in 0 ..< 30 do hero_test_tick(link, gs)
    testing.expect(t, hero_threat(&gs.hero) != nil, "seen in line, it is noticed")
    for y in G - 4 ..< G do set_tile(&gs.world, x0 + 3, y, .Stone)
    for _ in 0 ..< 30 do hero_test_tick(link, gs)
    th := hero_threat(&gs.hero)
    testing.expect(t, th != nil && !th.in_line, "behind the wall it is still in mind")
    gs.enemies.data[v].pos.x = f32(x0) + 16
    hero_test_tick(link, gs)
    testing.expect(t, hero_threat(&gs.hero) == nil, "past FAR it is forgotten")
    gs.enemies.data[v].pos.x = f32(x0) + 6.1
    for _ in 0 ..< 30 do hero_test_tick(link, gs)
    testing.expect(t, hero_threat(&gs.hero) == nil, "back behind the wall, never in line, it is not noticed")
}

// A look at a ledge runs to its end: a tick off the ground halfway (a knock, a
// step's bounce) does not hand the turn back to the goal and restart the look.
@(test)
hero_a_look_at_a_ledge_runs_to_its_end :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 4 ..= x0 + 8 do for y in G ..< G + 4 do set_tile(&gs.world, x, y, .Air)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":120}]}`)
    for i := 0; i < 120 && gs.hero.current != .Avoid_Ledge; i += 1 do hero_test_tick(link, gs)
    testing.expect_value(t, gs.hero.current, Hero_Behaviour.Avoid_Ledge)
    for _ in 0 ..< 5 do hero_test_tick(link, gs)
    gs.player.grounded = false
    hero_test_tick(link, gs)
    testing.expect_value(t, gs.hero.current, Hero_Behaviour.Avoid_Ledge)
    testing.expect(t, gs.hero.ledge_t > 5 * gs.delta_time, "the look goes on")
}

// ─── go and home ───

// Queues one goal, plays until it ends or max frames pass with no enemy about,
// and gives its id and the frames it took.
// What a go did on the way: the longest it went with no headway, whether a
// tile dug while it stood counted as headway, ticks with its feet in water.
Go_Watch :: struct {
    max_stuck: f32,
    dig_reset: bool,
    wet:       int,
}

@(private="file")
go_test_run :: proc(link: ^Agent_Link, gs: ^Game_State, line: string, max_frames: int, watch: ^Go_Watch = nil) -> (id, frames: int) {
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, line))
    id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    for frames < max_frames && agent_goals_busy(&link.goals) {
        feet := hero_feet(&gs.player)
        stuck := f32(-1)
        for &g in link.goals.slots[:link.goals.n] do if g.id == id do stuck = g.stuck_t
        exec_test_frames(link, gs, 1)
        for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
        frames += 1
        if watch == nil do continue
        for &g in link.goals.slots[:link.goals.n] do if g.id == id && g.status == .Running {
            watch.max_stuck = max(watch.max_stuck, g.stuck_t)
            if stuck > 0.3 && g.stuck_t == 0 && hero_feet(&gs.player) == feet do watch.dig_reset = true
        }
        f := hero_feet(&gs.player)
        if .Swimmable in terrain_table[get_tile(&gs.world, int(f.x), int(f.y))].flags do watch.wet += 1
    }
    return
}

@(private="file")
go_test_status :: proc(link: ^Agent_Link, gs: ^Game_State, id: int) -> (status, reason: string) {
    g := exec_test_goal(link, gs, id)
    status = g["status"].(json.String)
    reason, _ = g["reason"].(json.String)
    return
}

@(private="file")
go_test_give :: proc(gs: ^Game_State, it: Item, n: int) {
    testing_ok := inventory_insert(&gs.player.inventory, it, n)
    assert(testing_ok)
}

@(test)
hero_go_across_flat_ground :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    watch: Go_Watch
    id, frames := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 15, G - 1), 600, &watch)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expectf(t, watch.max_stuck < 0.5, "each step nearer is headway: %.2f s without", watch.max_stuck)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 15), i32(G - 1)})
    testing.expectf(t, frames < 3 * 60, "walked it in %d frames", frames)
    // A solid tile asked for is the one stood on.
    id, _ = go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 2, G), 600)
    status, reason = go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 2), i32(G - 1)})
}

// A cliff three tiles high, too high to jump: the hero cuts a step into it
// with the pick and climbs.
@(test)
hero_go_up_a_3_tile_step :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 6 ..= x0 + 22 do for y in G - 3 ..< G do set_tile(&gs.world, x, y, .Stone)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    hp := gs.player.hp
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 10, G - 4), 1200)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 10), i32(G - 4)})
    testing.expect_value(t, gs.player.hp, hp)
}

// Steps and jumps need no pick: a stair of one-tile steps, then a two-tile one.
@(test)
hero_go_climbs_steps_and_jumps_without_a_pick :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for i in 0 ..< 3 do for x in x0 + 4 + 2 * i ..= x0 + 22 do set_tile(&gs.world, x, G - 1 - i, .Stone)
    for x in x0 + 12 ..= x0 + 22 do for y in G - 5 ..< G - 3 do set_tile(&gs.world, x, y, .Stone)
    exec_test_frames(link, gs, 5)
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 15, G - 6), 900)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 15), i32(G - 6)})
}

// A dirt wall too high to jump: the hero tunnels it.
@(test)
hero_go_through_a_dirt_wall :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 6 ..= x0 + 7 do for y in G - 10 ..< G do set_tile(&gs.world, x, y, .Dirt)
    go_test_give(gs, .Pickaxe, 1)
    gs.player.inventory.selected = -1  // an empty hand: it takes the pick up itself
    exec_test_frames(link, gs, 5)
    hp := gs.player.hp
    watch: Go_Watch
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 12, G - 1), 1200, &watch)
    testing.expect(t, watch.dig_reset, "a tile dug where it stands is headway")
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 12), i32(G - 1)})
    testing.expect_value(t, gs.player.hp, hp)
    // Dirt falls: the tunnel fills behind the hero, and the wall is lower.
    left := 0
    for x in x0 + 6 ..= x0 + 7 do for y in G - 10 ..< G do if is_solid(&gs.world, x, y) do left += 1
    testing.expectf(t, left < 20, "the wall was dug, %d of 20 left", left)
}

// A pond in the way, too wide to jump: no route digs its rim, and the water
// stays where it is.
@(test)
hero_go_never_digs_a_pool_rim :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 5 ..= x0 + 10 do for y in G ..< G + 2 do set_tile(&gs.world, x, y, .Water)
    go_test_give(gs, .Pickaxe, 1)
    testing.expect(t, !hero_diggable(gs, {i32(x0 + 4), i32(G)}, true), "a rim tile is not to be dug")
    testing.expect(t, hero_diggable(gs, {i32(x0 + 2), i32(G)}, true))
    exec_test_frames(link, gs, 5)
    rim: [dynamic][2]i32
    defer delete(rim)
    for x in x0 + 3 ..= x0 + 12 do for y in G - 2 ..= G + 3 do if hero_rim(&gs.world, {i32(x), i32(y)}) && is_solid(&gs.world, x, y) do append(&rim, [2]i32{i32(x), i32(y)})
    watch: Go_Watch
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 14, G - 1), 6000, &watch)
    testing.expect_value(t, watch.wet, 0)  // never through the pond either
    for r in rim do testing.expectf(t, is_solid(&gs.world, int(r.x), int(r.y)), "rim tile %v dug", r)
    for x in x0 + 5 ..= x0 + 10 do testing.expect_value(t, get_tile(&gs.world, x, G + 1), Tile_Type.Water)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done" || reason == "no_route" || reason == "blocked", "%s %s", status, reason)
}

// Dropped on lava, the hero walks out of it, goal or none; with the reflex off
// it stays.
@(test)
hero_dropped_on_lava_leaves_it :: proc(t: ^testing.T) {
    for on in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        for x in x0 + 4 ..= x0 + 8 do set_tile(&gs.world, x, G, .Lava)
        exec_test_frames(link, gs, 5)
        if !on {
            agent_handle_line(link, gs, `{"cmd":"reflexes","leave_hazard":false}`)
            testing.expect(t, exec_test_reply(link)["ok"].(json.Boolean))
        }
        gs.player.pos = {f32(x0) + 6.1, f32(G + 1) - PLAYER_H}
        gs.player.vel = {}
        in_lava := 0
        for _ in 0 ..< 120 {
            exec_test_frames(link, gs, 1)
            for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
            f := hero_feet(&gs.player)
            if get_tile(&gs.world, int(f.x), int(f.y)) == .Lava do in_lava += 1
        }
        f := hero_feet(&gs.player)
        if on {
            testing.expectf(t, get_tile(&gs.world, int(f.x), int(f.y)) != .Lava, "out of the lava, at %v", f)
            testing.expect(t, !gs.player.dead)
            testing.expectf(t, in_lava < 60, "%d ticks in it", in_lava)
        } else {
            testing.expect(t, in_lava > 100, "the reflex off, it stands in it")
        }
    }
}

// A tile in the air, out of reach: the hero gets as near as it can, and the
// goal fails no_route well inside the stuck limit.
@(test)
hero_go_no_route_fails_in_time :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    id, frames := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 8, G - 8), 1200)
    status, reason := go_test_status(link, gs, id)
    testing.expect_value(t, status, "failed")
    testing.expect_value(t, reason, "no_route")
    testing.expectf(t, f32(frames) < HERO_GO_STUCK_S * 60, "%d frames", frames)
    testing.expect(t, abs(hero_feet(&gs.player).x - i32(x0 + 8)) <= 1, "it went under it first")
}

// A target that burns is refused at the start.
@(test)
hero_go_to_a_burn_fails_hazard :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 + 6, G - 1, .Lava)
    exec_test_frames(link, gs, 5)
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 6, G - 1), 60)
    status, reason := go_test_status(link, gs, id)
    testing.expect_value(t, status, "failed")
    testing.expect_value(t, reason, "hazard")
}

// Glenn 2026-11-03: across a 12-deep pit, a block in the bag bridges it; with
// none the hero finds another way; never a fall that would kill it.
@(test)
hero_go_across_a_deep_pit :: proc(t: ^testing.T) {
    for blocks in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        for x in x0 + 5 ..= x0 + 10 do for y in G ..< G + 12 do set_tile(&gs.world, x, y, .Air)
        go_test_give(gs, .Pickaxe, 1)
        if blocks do go_test_give(gs, .Stone_Block, 8)
        exec_test_frames(link, gs, 5)
        gs.player.hp = 5
        id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 14, G - 1), 6000)
        status, reason := go_test_status(link, gs, id)
        testing.expectf(t, status == "done", "blocks %v: %s %s", blocks, status, reason)
        testing.expect(t, !gs.player.dead)
        testing.expectf(t, f32(gs.player.hp) >= HERO_LOW_HP_FRAC * f32(gs.player.hp_max), "blocks %v: hp %d", blocks, gs.player.hp)
        if blocks {
            testing.expect_value(t, gs.player.hp, 5)
            bridged := 0
            for x in x0 + 5 ..= x0 + 10 do if get_tile(&gs.world, x, G) == .Stone do bridged += 1
            testing.expect(t, bridged > 0, "it set blocks down over the pit")
        }
    }
}

// The marked home on this level, else the surface spawn.
@(test)
hero_home_goes_to_the_mark_or_the_spawn :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"home","at":[%d,%d]}}`, x0 + 9, G - 1))
    testing.expect(t, exec_test_reply(link)["ok"].(json.Boolean))
    id, _ := go_test_run(link, gs, `{"do":"home"}`, 600)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 9), i32(G - 1)})
    agent_handle_line(link, gs, `{"cmd":"home"}`)  // no mark: the spawn
    id, _ = go_test_run(link, gs, `{"do":"home"}`, 600)
    status, reason = go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), hero_spawn_feet())
}

// The dig reflexes: an act that mines the floor over a deadly fall, or a pond's
// rim, mines nothing; with the reflex off it does.
@(test)
hero_reflexes_veto_deadly_and_rim_digs :: proc(t: ^testing.T) {
    for on in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        go_test_give(gs, .Pickaxe, 1)
        gs.player.inventory.selected = hero_item_slot(gs, .Pickaxe)
        hx := i32(gs.player.pos.x + PLAYER_W * 0.5)
        for y in G + 1 ..= G + 12 do set_tile(&gs.world, int(hx), y, .Air)  // under the floor, a shaft
        set_tile(&gs.world, int(hx) + 2, G, .Water)                           // and a pool past the next tile
        exec_test_frames(link, gs, 5)
        gs.player.hp = 3
        if !on {
            agent_handle_line(link, gs, `{"cmd":"reflexes","floor_dig":false,"rim_dig":false}`)
        }
        go_test_run(link, gs, fmt.tprintf(`{{"do":"act","mine":[%d,%d],"frames":120}}`, hx + 1, G), 200)
        testing.expectf(t, is_solid(&gs.world, int(hx) + 1, G) == on, "reflex %v: the rim", on)
        if gs.player.dead do continue
        go_test_run(link, gs, fmt.tprintf(`{{"do":"act","mine":[%d,%d],"frames":120}}`, hx, G), 200)
        testing.expectf(t, is_solid(&gs.world, int(hx), G) == on, "reflex %v: the floor", on)
    }
}

// Under the reflex line with a potion in the bag, the hero drinks one, once.
@(test)
hero_drinks_a_potion_under_the_line :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    hero_test_arena(gs)
    go_test_give(gs, .Potion_Health, 2)
    exec_test_frames(link, gs, 5)
    potions :: proc(gs: ^Game_State) -> int {
        if s := hero_item_slot(gs, .Potion_Health); s >= 0 do return gs.player.inventory.slots[s].count
        return 0
    }
    gs.player.hp = 1
    exec_test_frames(link, gs, 3)
    testing.expect(t, gs.player.hp > 1, "it drank")
    testing.expect_value(t, potions(gs), 1)
    gs.player.hp = 1
    exec_test_frames(link, gs, 3)
    testing.expect_value(t, potions(gs), 1)  // not again inside HERO_POTION_COOLDOWN_S
    exec_test_frames(link, gs, int(HERO_POTION_COOLDOWN_S * 60))
    gs.player.hp = 1
    exec_test_frames(link, gs, 3)
    testing.expect_value(t, potions(gs), 0)  // and again after it
}

// The tile rules the planner stands on.
@(test)
hero_nav_tile_rules :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    w := &gs.world
    X, Y := i32(x0), i32(G)
    set_tile(w, x0 + 2, G - 1, .Water)
    set_tile(w, x0 + 4, G - 1, .Lava)
    testing.expect(t, hero_open(w, X, Y - 1) && !hero_open(w, X, Y), "air is open, stone is not")
    testing.expect(t, !hero_open(w, X + 2, Y - 1), "water is not stood in")
    testing.expect(t, !hero_open(w, X + 4, Y - 1), "nor lava")
    testing.expect(t, hero_stand(w, {X, Y - 1}))
    set_tile(w, x0, G - 2, .Stone)
    testing.expect(t, !hero_stand(w, {X, Y - 1}), "no room for the head")
    set_tile(w, x0, G - 2, .Air)
    testing.expect(t, hero_rim(w, {X + 2, Y}) && hero_rim(w, {X + 4, Y}), "beside water, beside lava")
    testing.expect(t, !hero_rim(w, {X + 7, Y}))
    testing.expect(t, hero_diggable(gs, {X + 7, Y}, true))
    testing.expect(t, !hero_diggable(gs, {X + 7, Y}, false), "stone wants the pick")
    set_tile(w, x0 + 7, G - 1, .Wood)
    testing.expect(t, hero_diggable(gs, {X + 7, Y - 1}, false), "a log does not")
    set_tile(w, x0 + 9, G, .Rune_Stone)
    testing.expect(t, !hero_diggable(gs, {X + 9, Y}, true), "a tile the pick cannot work")
    tiles, n := hero_dig_tiles({X, Y - 1}, {X + 1, Y - 2})
    testing.expect_value(t, n, 3)
    testing.expect_value(t, tiles[2], [2]i32{X, Y - 3})  // the headroom to step up into the cut
    gs.player.hp = 10
    testing.expect(t, hero_fall_ok(gs, 7) && !hero_fall_ok(gs, 8), "a fall leaves 30% or it is not taken")
    gs.player.hp = 2
    testing.expect(t, hero_fall_ok(gs, 0), "a free fall is always free")
    testing.expect(t, !hero_fall_ok(gs, 1))
    gs.player.inventory = {}
    go_test_give(gs, .Leaf, 5)
    testing.expect_value(t, hero_block_slot(gs), -1)  // leaves set down are no floor
    go_test_give(gs, .Stone_Block, 3)
    testing.expect_value(t, hero_block_slot(gs), hero_item_slot(gs, .Stone_Block))
}

// Every step of a plan lands on a floor, or on a block it sets down.
@(private="file")
plan_test_lands :: proc(t: ^testing.T, gs: ^Game_State, path: ^Hero_Path, loc := #caller_location) {
    for st in path.steps[:path.n] {
        floor := st.to + {0, 1}
        testing.expectf(t, st.move == .Bridge || is_solid(&gs.world, int(floor.x), int(floor.y)), "step %v lands on nothing", st, loc = loc)
    }
}

// The search: it says when it reached the tile, takes the cheaper of two ways
// to a tile it saw first the dear way, never plans onto air, and never digs
// what the pick cannot.
@(test)
hero_plan_finds_the_cheaper_way_and_lands :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    X, Y := i32(x0), i32(G)
    path := &gs.hero.path
    testing.expect(t, hero_plan(gs, {X, Y - 1}, {X + 6, Y - 1}, path), "flat ground: reached")
    testing.expect_value(t, path.n, 6)
    testing.expect(t, !hero_plan(gs, {X, Y - 1}, {X + 6, Y - 6}, path), "a tile in the air: not reached")

    // A one-wide hole one deep: a gap jump over it is seen first, but down and
    // up is cheaper.
    set_tile(&gs.world, x0 + 1, G, .Air)
    hero_plan(gs, {X, Y - 1}, {X + 2, Y - 1}, path)
    testing.expect_value(t, path.n, 2)
    testing.expect_value(t, path.steps[0].move, Hero_Move.Drop)
    set_tile(&gs.world, x0 + 1, G, .Stone)

    // A dirt wall over a hollow: a tunnel would end over air.
    go_test_give(gs, .Pickaxe, 1)
    for y in G - 3 ..< G do set_tile(&gs.world, x0 + 3, y, .Dirt)
    for y in G ..< G + 2 do set_tile(&gs.world, x0 + 3, y, .Air)
    hero_plan(gs, {X, Y - 1}, {X + 6, Y - 1}, path)
    plan_test_lands(t, gs, path)

    // A wall the pick cannot work, too high to climb: no way through.
    for y in G - 10 ..< G + 12 do set_tile(&gs.world, x0 + 3, y, .Rune_Stone)
    testing.expect(t, !hero_plan(gs, {X, Y - 1}, {X + 6, Y - 1}, path))
    for st in path.steps[:path.n] do testing.expect(t, st.to.x < X + 3, "nothing goes through it")
}

// Done only standing on the tile: passing through it in the air is not there.
@(test)
hero_go_is_done_standing_not_passing :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    gs.player.pos = {f32(x0 + 3) + 0.1, f32(G) - 0.5 - PLAYER_H}  // feet in the tile, half a tile up
    gs.player.vel = {}
    gs.player.grounded = false
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 3, G - 1))
    exec_test_frames(link, gs, 1)
    testing.expect(t, agent_goals_busy(&link.goals), "not done in the air")
    for i := 0; i < 60 && agent_goals_busy(&link.goals); i += 1 do exec_test_frames(link, gs, 1)
    testing.expect(t, !agent_goals_busy(&link.goals), "done once it lands")

    // Falling onto the tile from above: planned from the ground, not the air.
    gs.player.pos = {f32(x0 + 8) + 0.1, f32(G - 6) - PLAYER_H}
    gs.player.vel = {}
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 8, G - 1), 120)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
}

// A wall goes up across the path while the hero walks: it plans again within
// HERO_GO_REPLAN_S of no headway and fails no_route, well before blocked.
@(test)
hero_go_replans_when_the_way_closes :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 15, G - 1))
    exec_test_frames(link, gs, 10)
    for y in G - 10 ..< G do set_tile(&gs.world, x0 + 8, y, .Rune_Stone)
    frames := 0
    for frames < 600 && agent_goals_busy(&link.goals) {
        exec_test_frames(link, gs, 1)
        frames += 1
    }
    g := link.goals.slots[link.goals.n - 1]
    testing.expect_value(t, string(g.reason.buf[:g.reason.len]), "no_route")
    testing.expectf(t, f32(frames) < (HERO_GO_REPLAN_S + 1) * 60, "%d frames", frames)
}

// The bag runs out halfway over a pit: it plans again with what it has.
@(test)
hero_go_plans_again_when_the_blocks_run_out :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 5 ..= x0 + 10 do for y in G ..< G + 12 do set_tile(&gs.world, x, y, .Air)
    go_test_give(gs, .Stone_Block, 8)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 14, G - 1))
    frames, emptied := 0, -1
    for frames < 900 && agent_goals_busy(&link.goals) {
        exec_test_frames(link, gs, 1)
        frames += 1
        if b := hero_item_slot(gs, .Stone_Block); b >= 0 && is_solid(&gs.world, x0 + 5, G) {
            gs.player.inventory.slots[b] = {}
            emptied = frames
        }
    }
    testing.expect(t, emptied > 0, "it set the first block")
    g := link.goals.slots[link.goals.n - 1]
    testing.expect_value(t, string(g.reason.buf[:g.reason.len]), "no_route")
    testing.expectf(t, f32(frames - emptied) < HERO_GO_REPLAN_S * 60 / 2, "%d frames after the bag ran out", frames - emptied)
}

// The fall rule prices drops: down a stair of free steps rather than a fall
// that hurts, and at low hp never a fall that would leave it under the line.
@(test)
hero_go_prices_drops_by_the_fall_rule :: proc(t: ^testing.T) {
    for stairs in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        // A tunnel under the hero, reached by a 7-tile shaft on its left, or
        // by a stair of one-tile steps on its right.
        for x in x0 - 1 ..= x0 + 5 do for y in G + 5 ..= G + 6 do set_tile(&gs.world, x, y, .Air)
        for y in G ..= G + 6 do set_tile(&gs.world, x0 - 1, y, .Air)
        if stairs {
            for i in 1 ..= 4 do for y in G ..< G + i do set_tile(&gs.world, x0 + i, y, .Air)
            for y in G ..= G + 6 do set_tile(&gs.world, x0 + 5, y, .Air)
        }
        exec_test_frames(link, gs, 5)
        testing.expect_value(t, hero_column(&gs.world, x0 - 1, G - 1).hurts, 2)
        if !stairs do gs.player.hp = 3
        hp := gs.player.hp
        id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 2, G + 6), 900)
        status, reason := go_test_status(link, gs, id)
        testing.expect_value(t, gs.player.hp, hp)
        if stairs {
            testing.expectf(t, status == "done", "%s %s", status, reason)
        } else {
            testing.expect_value(t, reason, "no_route")
        }
    }
}

// In lava two deep against a wall, the way out is a jump on the other side.
@(test)
hero_leaves_lava_away_from_a_wall :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for y in G - 4 ..< G do set_tile(&gs.world, x0 + 3, y, .Stone)
    for x in x0 + 4 ..= x0 + 6 do for y in G ..= G + 1 do set_tile(&gs.world, x, y, .Lava)  // two deep: a jump out
    exec_test_frames(link, gs, 5)
    gs.player.pos = {f32(x0) + 4.1, f32(G + 2) - PLAYER_H}
    gs.player.vel = {}
    for _ in 0 ..< 120 do exec_test_frames(link, gs, 1)
    f := hero_feet(&gs.player)
    testing.expectf(t, f.x >= i32(x0 + 7) && get_tile(&gs.world, int(f.x), int(f.y)) != .Lava, "out on the open side, at %v", f - {i32(x0), i32(G)})
}

// Held where it stands, the hero plans again after HERO_GO_REPLAN_S and the
// goal fails blocked at HERO_GO_STUCK_S, not before.
@(test)
hero_go_held_fails_blocked :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 15, G - 1))
    hold := gs.player.pos
    frames := 0
    for frames < 600 && agent_goals_busy(&link.goals) {
        exec_test_frames(link, gs, 1)
        gs.player.pos, gs.player.vel = hold, {}
        frames += 1
    }
    g := link.goals.slots[link.goals.n - 1]
    testing.expect_value(t, string(g.reason.buf[:g.reason.len]), "blocked")
    testing.expectf(t, abs(f32(frames) - HERO_GO_STUCK_S * 60) < 3, "%d frames", frames)
}

// Knocked back off its path, the hero plans from where it landed at once.
@(test)
hero_go_knocked_off_plans_from_there :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 15, G - 1))
    exec_test_frames(link, gs, 30)
    for knock in ([2]f32{-3, 4}) {
        gs.player.pos.x += knock
        landed := hero_feet(&gs.player)
        exec_test_frames(link, gs, 1)
        p := &gs.hero.path
        testing.expectf(t, p.at == 0 && p.steps[0].from == landed, "knocked %v: planned from %v, landed at %v", knock, p.steps[0].from, landed)
    }
}

// A goal walking off with the bag open shuts it first, as any goal does.
@(test)
hero_go_shuts_a_window_first :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    gs.ui.show_inventory = true
    x := gs.player.pos.x
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 6, G - 1))
    exec_test_frames(link, gs, 1)
    testing.expect(t, !gs.ui.show_inventory, "shut")
    testing.expect_value(t, gs.player.pos.x, x)  // and that tick stood still
    exec_test_frames(link, gs, 5)
    testing.expect(t, gs.player.pos.x > x, "then it walks")
}

// The dig reflexes judge digs, not swings, and only the floor under the body:
// a sword swung at a rim tile still swings, a wall tile with a shaft under it
// is dug, and a floor over deep water is dug (water breaks the fall).
@(test)
hero_reflexes_judge_only_floor_digs :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    hx := x0
    gs.player.hp = 1
    set_tile(&gs.world, hx + 2, G, .Water)  // (hx+1, G) is a rim
    go_test_give(gs, .Sword, 1)
    gs.player.inventory.selected = hero_item_slot(gs, .Sword)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"act","mine":[%d,%d],"frames":3}}]}}`, hx + 1, G))
    exec_test_frames(link, gs, 1)
    testing.expect(t, gs.input.mine, "a swing is no dig")
    exec_test_frames(link, gs, 5)

    go_test_give(gs, .Pickaxe, 1)
    gs.player.inventory.selected = hero_item_slot(gs, .Pickaxe)
    set_tile(&gs.world, hx - 1, G - 1, .Stone)
    for y in G ..= G + 12 do set_tile(&gs.world, hx - 1, y, .Air)
    go_test_run(link, gs, fmt.tprintf(`{{"do":"act","mine":[%d,%d],"frames":120}}`, hx - 1, G - 1), 200)
    testing.expect(t, !is_solid(&gs.world, hx - 1, G - 1), "a wall over a shaft is no floor")

    for y in G + 1 ..= G + 12 do set_tile(&gs.world, hx, y, .Air)
    for y in G + 10 ..= G + 12 do set_tile(&gs.world, hx, y, .Water)
    for y in G + 10 ..= G + 12 do set_tile(&gs.world, hx - 1, y, .Stone)
    go_test_run(link, gs, fmt.tprintf(`{{"do":"act","mine":[%d,%d],"frames":120}}`, hx, G), 200)
    testing.expect(t, !is_solid(&gs.world, hx, G), "a floor over deep water is dug")
}

// Dropped in a pond two deep, the hero gets out of the water.
@(test)
hero_dropped_in_deep_water_gets_out :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 4 ..= x0 + 8 do for y in G ..= G + 1 do set_tile(&gs.world, x, y, .Water)
    exec_test_frames(link, gs, 5)
    gs.player.pos = {f32(x0) + 6.1, f32(G + 2) - PLAYER_H}
    gs.player.vel = {}
    for _ in 0 ..< 240 do exec_test_frames(link, gs, 1)
    f := hero_feet(&gs.player)
    testing.expectf(t, !hero_wet_or_burning(&gs.world, f.x, f.y) && !hero_wet_or_burning(&gs.world, f.x, f.y - 1), "out of the water, at %v", f - {i32(x0), i32(G)})
}

// With no pick a trunk in the way is cut by hand, the sword put away for it.
@(test)
hero_go_cuts_a_trunk_by_hand_without_a_pick :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for y in G - 6 ..< G do set_tile(&gs.world, x0 + 6, y, .Wood)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.selected = 0
    exec_test_frames(link, gs, 5)
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 12, G - 1), 3600)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 12), i32(G - 1)})
    testing.expect(t, inventory_count(&gs.player.inventory, .Wood_Log) > 0, "the trunk was cut")
}

// A dig leaves the pick in hand; a Vargr coming then is fought with the sword
// taken back up, not fled from.
@(test)
hero_takes_the_sword_back_up_to_fight_after_a_dig :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 6 ..= x0 + 7 do for y in G - 10 ..< G do set_tile(&gs.world, x, y, .Dirt)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.slots[1] = {item = .Pickaxe, count = 1}
    gs.player.inventory.selected = 0
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"go","to":[%d,%d]}}]}}`, x0 + 12, G - 1))
    for i := 0; i < 600 && held_item(&gs.player) != .Pickaxe; i += 1 do hero_test_tick(link, gs)
    testing.expect_value(t, held_item(&gs.player), Item.Pickaxe)
    hx := gs.player.pos.x + PLAYER_W * 0.5
    vargr := hero_test_vargr(gs, hx - 3, G, {RAIDER_SPEED, 0})
    armed_fight, fled := 0, 0
    for _ in 0 ..< 600 {
        hero_test_tick(link, gs)
        if !gs.enemies.active[vargr] do break
        if gs.hero.current == .Fight && held_item(&gs.player) == .Sword do armed_fight += 1
        if gs.hero.current == .Flee do fled += 1
    }
    testing.expect(t, armed_fight > 0, "fought with the sword")
    testing.expect_value(t, fled, 0)
    testing.expect(t, !gs.enemies.active[vargr] || gs.enemies.data[vargr].hp < VARGR_HP, "the Vargr was hit")
}

// Bridges are bought with blocks: a plan never sets down more than the bag holds.
@(test)
hero_plan_spends_no_more_blocks_than_the_bag_holds :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for x in x0 + 5 ..= x0 + 11 do for y in G ..< G + 26 do set_tile(&gs.world, x, y, .Air)
    exec_test_frames(link, gs, 5)
    from, to := [2]i32{i32(x0), i32(G - 1)}, [2]i32{i32(x0 + 14), i32(G - 1)}
    bridges :: proc(p: ^Hero_Path) -> (n: int) {
        for st in p.steps[:p.n] do if st.move == .Bridge do n += 1
        return
    }
    path: Hero_Path
    go_test_give(gs, .Stone_Block, 2)
    reached := hero_plan(gs, from, to, &path)
    testing.expect(t, !reached, "two blocks do not span the pit")
    testing.expectf(t, bridges(&path) <= 2, "%d bridges from 2 blocks", bridges(&path))
    go_test_give(gs, .Stone_Block, 8)
    reached = hero_plan(gs, from, to, &path)
    testing.expect(t, reached, "ten do")
    testing.expect(t, bridges(&path) > 2)
}

// A home marked on another level is not this one's: home goes to the spawn.
@(test)
hero_home_marked_on_another_level_is_not_used :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 + 8, G - 1), 600)
    agent_home_set(link, gs, {i32(x0 + 15), i32(G - 1)}, gs.level_index + 1, true)
    id, _ = go_test_run(link, gs, `{"do":"home"}`, 900)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
    testing.expect_value(t, hero_feet(&gs.player), hero_spawn_feet())
}

// A weapon already in hand is the one fought with: no swap to the bag's first.
@(test)
hero_fights_with_the_weapon_in_hand :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for _ in 0 ..< 10 do hero_test_tick(link, gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.slots[1] = {item = .Fire_Wand, count = 1}
    gs.player.inventory.selected = 1
    hero_test_vargr(gs, f32(x0) + 5.1, G, {-RAIDER_SPEED, 0})
    fought := 0
    for _ in 0 ..< 120 {
        hero_test_tick(link, gs)
        if gs.hero.current == .Fight do fought += 1
        testing.expect_value(t, gs.player.inventory.selected, 1)
    }
    testing.expect(t, fought > 0)
}
