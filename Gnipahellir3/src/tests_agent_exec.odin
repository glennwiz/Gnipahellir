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
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":10},{"do":"act","jump":true,"frames":10}]}`)
    exec_test_frames(link, gs, 40)
    link.recording = false
    os.close(f)
    end := gs.frame

    data, read_err := os.read_entire_file(path, context.allocator)
    testing.expect(t, read_err == nil)
    defer delete(data)

    Op :: struct { f: u64, goal: string, kind: Agent_Goal_Kind, via: Agent_Goal_Via, id, cancel: int, clear: bool }
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
    testing.expect_value(t, len(ops), 4 + 1 + 1 + 1 + 2)  // the last goals cleared nothing: the act was done

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
            testing.expect_value(t, agent_goal_add(link2, gs2, op.kind, op.via, op.goal), op.id)
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
    closed, fired := false, false
    for _ in 0 ..< 60 {
        hero_test_tick(link, gs)
        out := gs.enemies.data[v].pos.x - gs.player.pos.x > HERO_WAND_RANGE + 1
        if out do testing.expect(t, !gs.input.mine, "no shot wasted out of range")
        closed ||= out && gs.input.move_right
        fired ||= gs.input.mine
    }
    testing.expect(t, closed, "out of wand range it closes in")
    testing.expect(t, fired, "in range it fires")
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

// Cornered at a drop with a threat coming: a fall that costs less than the
// Vargr's blow is taken, a fall that would kill sends it past the threat
// instead (one that only costs more is card 140's, with the Builder).
@(test)
hero_cornered_at_a_drop_is_never_frozen :: proc(t: ^testing.T) {
    Case :: enum { Survivable, Lethal, Burn }
    for c in Case {
        lethal := c != .Survivable
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        depth := 6 if c == .Survivable else 10  // six: a fall of 1 hp, under the Vargr's 2
        for x in x0 - 12 ..= x0 - 1 do for y in G ..< G + depth do set_tile(&gs.world, x, y, .Air)
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
            testing.expect(t, gs.player.pos.y + PLAYER_H > f32(G + depth - 1), "it took the drop")
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

// Up onto a ledge that overhangs open ground, as out of a shaft dug down:
// the wall is at head height only, and the jump still goes.
@(test)
hero_go_jumps_onto_an_overhanging_ledge :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 - 1, G - 2, .Stone)
    exec_test_frames(link, gs, 5)
    id, _ := go_test_run(link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0 - 1, G - 3), 600)
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason)
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

// ─── work: mine, gather, craft, place, store, withdraw, feed, collect ───

// What a work goal did on the way: frames that began with a window open, and
// how many of those had a move, a stack seen riding the cursor, frames the
// cursor moved, and the clicks, grabs and let-gos, with those the cursor was
// not where a mouse's would be for the same gesture.
Work_Watch :: struct {
    open_frames:  int,
    moved_open:   int,
    carried:      Item,
    cursor_moved: int,
    gestures:     int,
    off_target:   int,
    rushed:       int,  // gestures with the cursor still for less than the click pause
    hasty:        int,  // a first gesture, or a shut, sooner than the look after the open or the last gesture
}

// Whether the cursor is where a mouse doing this tick's gesture would be: on
// the recipe card, on CRAFT, on the bag slot grabbed, over the window a stack
// is let go on.  The hit tests are the ones update_input uses.
@(private="file")
work_test_on_target :: proc(gs: ^Game_State, grabbed: bool, carried: Item) -> (gesture, on: bool) {
    c := gs.agent.cmd
    win, in_win := window_at_cursor(gs)
    if grabbed {
        // On a stack of what rides the cursor, in the bag or the barrel; in
        // the furnace's window for its slots.
        it := gs.ui.drag_item
        if !in_win do return true, false
        #partial switch win {
        case .Inventory:
            s := slot_at_cursor(gs)
            return true, s >= 0 && gs.player.inventory.slots[s].item == it
        case .Barrel:
            b := barrel_at(gs, gs.level_index, gs.ui.barrel_tile)
            bs := barrel_slot_at_cursor(gs)
            return true, b != nil && bs >= 0 && b.slots[bs].item == it
        case .Smelter:
            return true, true
        }
        return true, false
    }
    if !gs.agent.first do return false, false
    #partial switch c.verb {
    case .Pick_Recipe: return true, craft_card_at_cursor(gs) == int(c.verb_arg)
    case .Roster:
        slot, btn, ok := golem_roster_button_at_cursor(gs)
        return true, ok && slot == int(c.verb_arg & 0xff) && btn == Roster_Button(c.verb_arg >> 8)
    case .Craft:       return true, craft_button_hovered(gs)
    case .Store:
        // On the barrel slot the stack went to.
        b := barrel_at(gs, gs.level_index, gs.ui.barrel_tile)
        bs := barrel_slot_at_cursor(gs)
        return true, in_win && win == .Barrel && b != nil && bs >= 0 && b.slots[bs].item == carried
    case .Feed:
        // On the fuel slot for fuel, the ore slot for ore.
        x, y := smelter_input_rect(gs)
        if smelter_is_fuel(carried) do x, y = smelter_fuel_rect(gs)
        m := gs.input.mouse_screen
        inside := m.x >= f32(x) && m.x < f32(x + SLOT_PX) && m.y >= f32(y) && m.y < f32(y + SLOT_PX)
        return true, in_win && win == .Smelter && inside
    case .Take, .Withdraw, .Collect:
        // On the bag slot the stack joined.
        s := slot_at_cursor(gs)
        return true, in_win && win == .Inventory && s >= 0 && gs.player.inventory.slots[s].item == carried
    }
    return false, false
}

@(private="file")
work_test_run :: proc(t: ^testing.T, link: ^Agent_Link, gs: ^Game_State, line: string, max_frames: int, watch: ^Work_Watch = nil, loc := #caller_location) -> (id: int) {
    own: Work_Watch
    watch := watch if watch != nil else &own
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, line))
    reply := exec_test_reply(link)
    ids, ok := reply["ids"].(json.Array)
    assert(ok, string(link.out[:link.out_len]))
    id = int(ids[0].(json.Float))
    last := gs.hero.cursor
    carrying := false
    held := Item.None
    still := 0
    pause_s := HERO_CLICK_PAUSE_S
    pause := int(pause_s / AGENT_STEP) - 2
    look_s := HERO_WINDOW_LOOK_S
    look := int(look_s / AGENT_STEP) - 2
    since := 0  // frames since the window opened or the last gesture
    gestured := false
    for f := 0; f < max_frames && agent_goals_busy(&link.goals); f += 1 {
        open := agent_window_open(gs)
        exec_test_frames(link, gs, 1)
        for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
        if open {
            watch.open_frames += 1
            if gs.input.move_left || gs.input.move_right || gs.input.jump do watch.moved_open += 1
        }
        if gs.ui.drag_item != .None do watch.carried = gs.ui.drag_item
        now_open := agent_window_open(gs)
        if !open && now_open do since, gestured = 0, false
        if gesture, on := work_test_on_target(gs, gs.ui.drag_item != .None && !carrying, held); gesture {
            watch.gestures += 1
            if !on do watch.off_target += 1
            if still < pause do watch.rushed += 1
            if !gestured && since < look do watch.hasty += 1
            since, gestured = 0, true
        }
        if open && !now_open && gestured && since < look do watch.hasty += 1
        since += 1
        if gs.hero.cursor != last {
            watch.cursor_moved += 1
            still = 0
        } else {
            still += 1
        }
        last = gs.hero.cursor
        carrying = gs.ui.drag_item != .None
        held = gs.ui.drag_item
    }
    // Whatever the goal: no step with a window open, no click where a mouse's
    // would not be.
    testing.expectf(t, watch.moved_open == 0, "%d moves with a window open", watch.moved_open, loc = loc)
    testing.expectf(t, watch.off_target == 0, "%d gestures off target", watch.off_target, loc = loc)
    testing.expectf(t, watch.rushed == 0, "%d gestures without the click pause", watch.rushed, loc = loc)
    testing.expectf(t, watch.hasty == 0, "%d windows worked or shut without the look", watch.hasty, loc = loc)
    return
}

@(private="file")
work_test_expect_done :: proc(t: ^testing.T, link: ^Agent_Link, gs: ^Game_State, id: int, loc := #caller_location) {
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "done", "%s %s", status, reason, loc = loc)
}

@(private="file")
work_test_expect_failed :: proc(t: ^testing.T, link: ^Agent_Link, gs: ^Game_State, id: int, why: string, loc := #caller_location) {
    status, reason := go_test_status(link, gs, id)
    testing.expectf(t, status == "failed" && strings.has_prefix(reason, why), "want failed %s, got %s %s", why, status, reason, loc = loc)
}

@(test)
hero_gathers_5_wood_logs :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for y in G - 7 ..< G do set_tile(&gs.world, x0 + 8, y, .Wood)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, `{"do":"gather","item":"Wood_Log","count":5}`, 60 * 60)
    work_test_expect_done(t, link, gs, id)
    // At least five: a cut trunk falls, and what lands on the hero is its too.
    testing.expectf(t, inventory_count(&gs.player.inventory, .Wood_Log) >= 5, "logs: %d", inventory_count(&gs.player.inventory, .Wood_Log))
}

// A pile on the ground is walked over before a tile is mined for it; a pile
// of something else, or one in a pocket no body fits, is let be.
@(test)
hero_gather_takes_a_pile_first :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 + 3, G - 1, .Iron_Ore)
    spawn_ground_item(&gs.world, {i32(x0 - 6), i32(G - 1)}, .Iron_Ore, 2)
    spawn_ground_item(&gs.world, {i32(x0 + 2), i32(G - 1)}, .Dirt, 3)
    set_tile(&gs.world, x0 - 3, G + 1, .Air)  // a pocket one tile high
    spawn_ground_item(&gs.world, {i32(x0 - 3), i32(G + 1)}, .Iron_Ore, 1)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, `{"do":"gather","item":"Iron_Ore","count":2}`, 20 * 60)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, x0 + 3, G - 1), Tile_Type.Iron_Ore)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Dirt), 0)
    id = work_test_run(t, link, gs, `{"do":"gather","item":"Iron_Ore","count":3}`, 20 * 60)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, x0 + 3, G - 1), Tile_Type.Air)
}

// Bench by hand, set down, then the Smelter, which needs the bench: the hero
// walks back to it.  Each window is worked at a person's pace, with no move
// while it is open.
@(test)
hero_crafts_a_bench_then_a_smelter_at_it :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    reveal_recipe(&gs.progression, .Crafting_Bench)
    go_test_give(gs, .Plank, 4)
    go_test_give(gs, .Stone_Block, 8)
    go_test_give(gs, .Iron_Ore, 2)
    exec_test_frames(link, gs, 5)
    watch: Work_Watch
    id := work_test_run(t, link, gs, `{"do":"craft","item":"Crafting_Bench"}`, 600, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Crafting_Bench), 1)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Plank), 0)
    // The look, the card's pause, the button's pause, the look again.
    pace := 2 * HERO_WINDOW_LOOK_S + 2 * HERO_CLICK_PAUSE_S
    least := int(pace / AGENT_STEP)
    testing.expectf(t, watch.open_frames >= least, "open %d frames, the pace wants %d", watch.open_frames, least)
    testing.expect_value(t, watch.moved_open, 0)
    testing.expect(t, watch.cursor_moved > 1, "the cursor glides")
    testing.expect_value(t, watch.gestures, 2)  // the card, then CRAFT
    testing.expect_value(t, watch.off_target, 0)
    testing.expect(t, !agent_window_open(gs), "shut after")

    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Crafting_Bench","at":[%d,%d]}}`, x0 + 9, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, x0 + 9, G - 1), Tile_Type.Crafting_Bench)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"go","to":[%d,%d]}}`, x0, G - 1), 600)
    work_test_expect_done(t, link, gs, id)

    watch = {}
    id = work_test_run(t, link, gs, `{"do":"craft","item":"Smelter"}`, 900, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Smelter), 1)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)
    testing.expectf(t, watch.open_frames >= least, "open %d frames", watch.open_frames)
    testing.expect_value(t, watch.moved_open, 0)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 6), i32(G - 1)})  // the nearest ground in reach of the bench
}

// Set down by home, fed ore and wood, and the cast bars collected: every
// count is where it went.
@(test)
hero_places_a_smelter_feeds_it_and_collects :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Smelter, 1)
    go_test_give(gs, .Iron_Ore, 6)
    go_test_give(gs, .Wood_Log, 3)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"home","at":[%d,%d]}}`, x0 + 12, G))  // the ground: home is the tile on it
    id := work_test_run(t, link, gs, `{"do":"place","item":"Smelter","near":"home"}`, 900)
    work_test_expect_done(t, link, gs, id)
    m: [2]i32
    found := false
    for y in G - 6 ..< G do for x in x0 - 4 ..= x0 + 20 do if get_tile(&gs.world, x, y) == .Smelter do m, found = {i32(x), i32(y)}, true
    testing.expect(t, found, "a smelter stands by home")
    testing.expect(t, abs(int(m.x) - (x0 + 12)) <= int(HERO_PLACE_NEAR), "near home")

    watch: Work_Watch
    id = work_test_run(t, link, gs, `{"do":"feed","item":"Iron_Ore"}`, 600, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, watch.carried, Item.Iron_Ore)
    testing.expect_value(t, watch.moved_open, 0)
    testing.expect_value(t, watch.gestures, 2)  // the grab and the let-go
    testing.expect_value(t, watch.off_target, 0)
    // With no fire the ore waits: it comes back out, and goes in again.
    watch = {}
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"withdraw","at":[%d,%d]}}`, m.x, m.y), 600, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, watch.gestures, 2)
    testing.expect_value(t, watch.off_target, 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 6)
    testing.expect_value(t, gs.world.sim_data[grid_idx(int(m.x), int(m.y))].in_count, 0)
    id = work_test_run(t, link, gs, `{"do":"feed","item":"Iron_Ore"}`, 600)
    work_test_expect_done(t, link, gs, id)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"feed","item":"Wood_Log","count":2,"at":[%d,%d]}}`, m.x, m.y), 600)
    work_test_expect_done(t, link, gs, id)
    rule, _ := smelt_rule_for(.Iron_Ore)
    sd := gs.world.sim_data[grid_idx(int(m.x), int(m.y))]
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 0)
    testing.expect_value(t, int(sd.in_count) + int(sd.store_count) * rule.ore_per_bar, 6)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Wood_Log), 1)
    testing.expect_value(t, int(sd.fuel_count) + int(sd.store_count) * FUEL_PER_BAR, 2)

    smelt := SMELT_TIME
    exec_test_frames(link, gs, int(smelt / AGENT_STEP) + 30)
    bars := int(gs.world.sim_data[grid_idx(int(m.x), int(m.y))].store_count)
    testing.expect(t, bars >= 1, "a bar is cast")
    watch = {}
    id = work_test_run(t, link, gs, `{"do":"collect"}`, 600, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, watch.gestures, 2)
    testing.expect_value(t, watch.off_target, 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, rule.bar), bars)
    testing.expect_value(t, gs.world.sim_data[grid_idx(int(m.x), int(m.y))].store_count, 0)
}

@(private="file")
work_test_total :: proc(gs: ^Game_State, b: ^Barrel_State, it: Item) -> int {
    n := inventory_count(&gs.player.inventory, it)
    for s in b.slots do if s.item == it do n += s.count
    return n
}

// Stored and withdrawn with nothing made or lost, and the store leaves the bag
// and the barrel as a human's drags of the same stacks do.
@(test)
hero_stores_and_withdraws_from_a_barrel :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Iron_Ore, 7)  // the first slot: a stack coming back goes to an empty one
    go_test_give(gs, .Barrel, 1)
    go_test_give(gs, .Stone_Block, 120)
    exec_test_frames(link, gs, 5)
    tile := [2]i32{i32(x0 + 3), i32(G - 1)}
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Barrel","at":[%d,%d]}}`, tile.x, tile.y), 600)
    work_test_expect_done(t, link, gs, id)
    b := barrel_at(gs, gs.level_index, tile)
    testing.expect(t, b != nil, "a barrel record")
    if b == nil do return

    twin := new(Game_State)
    defer free(twin)
    twin^ = gs^
    tb := barrel_at(twin, twin.level_index, tile)
    for s, i in twin.player.inventory.slots do if s.item == .Stone_Block do barrel_store(twin, tb, i)

    watch: Work_Watch
    id = work_test_run(t, link, gs, `{"do":"store","item":"Stone_Block"}`, 900, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, watch.carried, Item.Stone_Block)
    testing.expect_value(t, watch.moved_open, 0)
    testing.expect_value(t, watch.gestures, 4)  // two stacks, each a grab and a let-go
    testing.expect_value(t, watch.off_target, 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 0)
    testing.expect_value(t, work_test_total(gs, b, .Stone_Block), 120)
    testing.expect_value(t, b.slots, tb.slots)
    testing.expect_value(t, gs.player.inventory.slots, twin.player.inventory.slots)

    watch = {}
    id = work_test_run(t, link, gs, `{"do":"withdraw","item":"Stone_Block","count":50}`, 900, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, watch.gestures, 2)
    testing.expect_value(t, watch.off_target, 0)
    testing.expect(t, inventory_count(&gs.player.inventory, .Stone_Block) >= 50, "withdrawn")
    testing.expect(t, inventory_count(&gs.player.inventory, .Stone_Block) < 120, "whole stacks, only as many as count needs")
    testing.expect_value(t, work_test_total(gs, b, .Stone_Block), 120)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 7)
}

// Each failure says why first.
@(test)
hero_work_goals_fail_with_reasons :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, `{"do":"craft","item":"Smelter"}`, 60)
    work_test_expect_failed(t, link, gs, id, "no_recipe")

    go_test_give(gs, .Stone_Block, 8)
    go_test_give(gs, .Iron_Ore, 2)  // reveals the smelter
    go_test_give(gs, .Pickaxe, 1)
    go_test_give(gs, .Barrel, 1)
    exec_test_frames(link, gs, 2)
    id = work_test_run(t, link, gs, `{"do":"craft","item":"Smelter"}`, 60)
    work_test_expect_failed(t, link, gs, id, "no_station")
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"store","item":"Iron_Ore","at":[%d,%d]}}`, x0 + 3, G - 1), 60)
    work_test_expect_failed(t, link, gs, id, "no_station")
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Barrel","at":[%d,%d]}}`, x0 + 3, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"store","item":"Gold_Ore","at":[%d,%d]}}`, x0 + 3, G - 1), 60)
    work_test_expect_failed(t, link, gs, id, "no_item")
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Stone_Block","at":[%d,%d]}}`, x0 + 2, G), 60)
    work_test_expect_failed(t, link, gs, id, "out_of_reach")
    // A block on top of a stone column nine high: its top is safe ground in
    // reach, but no walk gets up there.
    for y in G - 9 ..< G do set_tile(&gs.world, x0 + 8, y, .Stone)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 8, G - 9), 900)
    work_test_expect_failed(t, link, gs, id, "unreachable: ")
    for y in G - 9 ..< G do set_tile(&gs.world, x0 + 8, y, .Air)
    // A block hung in the air: the only ground in reach is its own top, and
    // digging it from there drops the hero eight tiles.
    set_tile(&gs.world, x0 + 3, G - 9, .Stone)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 3, G - 9), 900)
    work_test_expect_failed(t, link, gs, id, "unsafe: [")
    // Under a barrel, which no pick digs: no ground reaches it, not even dug out.
    set_tile(&gs.world, x0 + 3, G - 10, .Barrel)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 3, G - 9), 60)
    work_test_expect_failed(t, link, gs, id, "unreachable: no ground")
    id = work_test_run(t, link, gs, `{"do":"gather","item":"Gold_Ore"}`, 60)
    work_test_expect_failed(t, link, gs, id, "no_item")
}

// The mine wand while the mana fires it, from where the hero stands; the pick
// without mana, and bare hands only on wood.
@(test)
hero_work_picks_its_tool :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    gs.player.inventory.selected = -1
    stone := [2]i32{i32(x0 + 3), i32(G - 1)}
    set_tile(&gs.world, int(stone.x), int(stone.y), .Stone)
    _, _, _, ok := hero_work_tool(gs, stone)
    testing.expect(t, !ok, "nothing mines stone bare-handed")
    set_tile(&gs.world, x0 + 5, G - 1, .Wood)
    slot, reach, _, wood_ok := hero_work_tool(gs, {i32(x0 + 5), i32(G - 1)})
    testing.expect(t, wood_ok && slot == -1 && reach == .Pick, "bare hands on wood")
    set_tile(&gs.world, x0 + 5, G - 1, .Air)
    go_test_give(gs, .Pickaxe, 1)
    go_test_give(gs, .Mine_Wand, 1)
    go_test_give(gs, .Mine_Wand_Silver, 1)
    gs.player.mana = 0
    slot, reach, _, _ = hero_work_tool(gs, stone)
    testing.expect_value(t, gs.player.inventory.slots[slot].item, Item.Pickaxe)
    gs.player.mana = gs.player.mana_max
    rng: i32
    slot, reach, rng, _ = hero_work_tool(gs, stone)
    testing.expect_value(t, gs.player.inventory.slots[slot].item, Item.Mine_Wand_Silver)  // the longest
    testing.expect_value(t, reach, Hero_Work_Reach.Wand)
    testing.expect_value(t, rng, wand_mine_range[Item.Mine_Wand_Silver])

    exec_test_frames(link, gs, 5)
    feet := hero_feet(&gs.player)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, stone.x, stone.y), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, int(stone.x), int(stone.y)), Tile_Type.Air)
    testing.expect_value(t, held_item(&gs.player), Item.Mine_Wand_Silver)
    testing.expect_value(t, hero_feet(&gs.player), feet)
}

// A mine by item finds the nearest tile that gives it, round near, and never
// one beside water.
@(test)
hero_mine_by_item_takes_the_nearest :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 + 4, G - 1, .Iron_Ore)
    set_tile(&gs.world, x0 + 11, G - 1, .Iron_Ore)
    set_tile(&gs.world, x0 + 20, G - 1, .Iron_Ore)
    set_tile(&gs.world, x0 + 13, G, .Iron_Ore)  // nearer near, but beside water
    set_tile(&gs.world, x0 + 13, G + 1, .Water)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","item":"Iron_Ore","near":[%d,%d]}}`, x0 + 13, G - 1), 900)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, x0 + 11, G - 1), Tile_Type.Air)
    testing.expect_value(t, get_tile(&gs.world, x0 + 4, G - 1), Tile_Type.Iron_Ore)
    testing.expect_value(t, get_tile(&gs.world, x0 + 20, G - 1), Tile_Type.Iron_Ore)
    testing.expect_value(t, get_tile(&gs.world, x0 + 13, G), Tile_Type.Iron_Ore)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 1)
}

// What a work goal asks for is checked when it is added.
@(test)
hero_work_goals_are_checked_when_added :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    bad := [?][2]string{
        {`{"do":"mine"}`, "mine needs tile"},
        {`{"do":"gather","item":"Moonbeam"}`, "gather: item must name"},
        {`{"do":"gather"}`, "gather needs item"},
        {`{"do":"craft","item":"Smelter","count":0}`, "craft: count must be"},
        {`{"do":"place","item":"Barrel","at":[1,1],"near":"home"}`, "place needs at"},
        {`{"do":"place","item":"Barrel","near":"hearth"}`, `place: near takes "home"`},
        {`{"do":"store","item":"Barrel","at":[-1,1]}`, "store: at takes"},
        {`{"do":"withdraw"}`, "withdraw needs at"},
        {`{"do":"mine","item":"Iron_Ore","near":"here"}`, "mine: near takes"},
    }
    for c in bad {
        agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, c[0]))
        r := exec_test_reply(link)
        why, _ := r["error"].(json.String)
        testing.expectf(t, strings.contains(why, c[1]), "%s: %s", c[0], why)
    }
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"collect"},{"do":"withdraw","item":"Iron_Ore"},{"do":"mine","tile":[3,3]}]}`)
    testing.expect_value(t, exec_test_reply(link)["ok"].(json.Boolean), true)
}

// The failures a goal meets as it starts, before a step is taken.
@(test)
hero_work_goals_fail_at_the_start :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    reveal_recipe(&gs.progression, .Crafting_Bench)
    set_tile(&gs.world, x0 + 6, G - 1, .Iron_Ore)  // there, but no pickaxe mines it
    exec_test_frames(link, gs, 5)
    tile :: proc(x, y: int) -> string { return fmt.tprintf("[%d,%d]", x, y) }
    fails := [?][2]string{
        {fmt.tprintf(`{{"do":"mine","tile":%s}}`, tile(x0 + 3, G - 3)), "no_item: nothing to mine"},
        {fmt.tprintf(`{{"do":"mine","tile":%s}}`, tile(x0 + 2, G)), "no_item: no pickaxe"},
        {`{"do":"mine","item":"Gold_Ore"}`, "no_item: no tile"},
        {`{"do":"mine","item":"Iron_Ore"}`, "no_item: no tile"},
        {`{"do":"gather","item":"Stone_Block"}`, "no_item"},
        {`{"do":"craft","item":"Crafting_Bench"}`, "no_item: Crafting_Bench needs"},
        {fmt.tprintf(`{{"do":"place","item":"Pickaxe","at":%s}}`, tile(x0 + 3, G - 1)), "no_item: Pickaxe does not set down"},
        {fmt.tprintf(`{{"do":"place","item":"Barrel","at":%s}}`, tile(x0 + 3, G - 1)), "no_item: no Barrel"},
        {`{"do":"collect"}`, "no_station: no smelter"},
        {`{"do":"withdraw","item":"Iron_Ore"}`, "no_station: no barrel holding"},
        {fmt.tprintf(`{{"do":"withdraw","at":%s}}`, tile(x0 + 3, G - 1)), "no_station: no barrel, silo or smelter"},
    }
    for f in fails {
        id := work_test_run(t, link, gs, f[0], 120)
        work_test_expect_failed(t, link, gs, id, f[1])
    }

    go_test_give(gs, .Barrel, 1)
    go_test_give(gs, .Smelter, 1)
    go_test_give(gs, .Stone_Block, 3)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Barrel","at":[%d,%d]}}`, x0 + 3, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Smelter","at":[%d,%d]}}`, x0 - 3, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    barrel := tile(x0 + 3, G - 1)
    smelter := tile(x0 - 3, G - 1)
    fails2 := [?][2]string{
        {`{"do":"feed","item":"Stone_Block"}`, "no_item: the furnace takes ore and wood"},
        {`{"do":"collect"}`, "no_item: the tray is empty"},
        {fmt.tprintf(`{{"do":"withdraw","at":%s}}`, smelter), "no_item: the furnace holds no ore"},
        {fmt.tprintf(`{{"do":"withdraw","at":%s}}`, barrel), "no_item: a withdraw from a barrel names the item"},
        {fmt.tprintf(`{{"do":"withdraw","item":"Gold_Ore","at":%s}}`, barrel), "no_item: the barrel holds no Gold_Ore"},
        {`{"do":"withdraw","item":"Gold_Ore"}`, "no_station: no barrel holding"},  // a barrel, but empty
    }
    for f in fails2 {
        id = work_test_run(t, link, gs, f[0], 120)
        work_test_expect_failed(t, link, gs, id, f[1])
    }
}

// No home marked: near home is the surface spawn; off the surface, none.
@(test)
hero_places_near_the_spawn_with_no_home_marked :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    _, _ = hero_test_arena(gs)
    go_test_give(gs, .Pickaxe, 1)  // in hand: the barrel is taken up first
    go_test_give(gs, .Barrel, 2)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, `{"do":"place","item":"Barrel","near":"home"}`, 600)
    work_test_expect_done(t, link, gs, id)
    // The free tile nearest the feet, not the body's own, and no step after
    // home is reached.
    home := hero_spawn_feet()
    near := false
    for b in gs.sim.barrels do if b.active && b.tile == home + {-1, 0} do near = true
    testing.expect(t, near, "a barrel beside the spawn")
    testing.expect_value(t, hero_feet(&gs.player), home)
    gs.level_index = LEVEL_SURFACE + 1
    id = work_test_run(t, link, gs, `{"do":"place","item":"Barrel","near":"home"}`, 10)
    gs.level_index = LEVEL_SURFACE
    work_test_expect_failed(t, link, gs, id, "unreachable: no home")
}

// The trunk above falls into the cut: one log is one mine.
@(test)
hero_mines_one_log_from_a_falling_trunk :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for y in G - 3 ..< G do set_tile(&gs.world, x0 + 3, y, .Wood)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 3, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Wood_Log), 1)
}

// A tile the reflexes will not let it dig gives nothing: the goal gives up.
@(test)
hero_mine_gives_up_on_a_tile_that_gives_nothing :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 + 3, G - 1, .Stone)
    set_tile(&gs.world, x0 + 4, G - 1, .Water)
    set_tile(&gs.world, x0 + 5, G - 1, .Stone)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 3, G - 1), 900)
    work_test_expect_failed(t, link, gs, id, "blocked")
    testing.expect_value(t, get_tile(&gs.world, x0 + 3, G - 1), Tile_Type.Stone)
}

// A full bag takes no pile in: the gather says so.
@(test)
hero_gather_stops_when_the_bag_is_full :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    exec_test_frames(link, gs, 5)
    for &s in gs.player.inventory.slots do s = {item = .Dirt, count = MAX_STACK}
    spawn_ground_item(&gs.world, {i32(x0 + 4), i32(G - 1)}, .Iron_Ore, 2)
    id := work_test_run(t, link, gs, `{"do":"gather","item":"Iron_Ore"}`, 600)
    work_test_expect_failed(t, link, gs, id, "full")
}

// A silo has no window: the click empties it into the bag.
@(test)
hero_withdraws_from_a_silo :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Silo, 1)
    exec_test_frames(link, gs, 5)
    at := [2]i32{i32(x0 + 6), i32(G - 1)}
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Silo","at":[%d,%d]}}`, at.x, at.y), 600)
    work_test_expect_done(t, link, gs, id)
    s := silo_at(gs, gs.level_index, at)
    testing.expect(t, s != nil, "a silo record")
    if s == nil do return
    silo_add(s, .Iron_Ore, 150)
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"withdraw","at":[%d,%d]}}`, at.x, at.y), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 150)
}

// A window shut under a store (a fight the goal paused for sweeps it) is
// opened again, and the store finishes with every count kept.
@(test)
hero_work_reopens_a_window_shut_under_it :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Barrel, 1)
    go_test_give(gs, .Stone_Block, 150)
    exec_test_frames(link, gs, 5)
    tile := [2]i32{i32(x0 + 3), i32(G - 1)}
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Barrel","at":[%d,%d]}}`, tile.x, tile.y), 600)
    work_test_expect_done(t, link, gs, id)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"store","item":"Stone_Block"}]}`)
    id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    shut, blind, loose := 0, 0, 0
    carrying := false
    for f := 0; f < 1200 && agent_goals_busy(&link.goals); f += 1 {
        exec_test_frames(link, gs, 1)
        if gs.agent.first && gs.agent.cmd.verb == .Store && !gs.ui.show_barrel do blind += 1
        // A grab begins with the cursor on the bag slot, after a reopen too.
        if gs.ui.drag_item != .None && !carrying {
            s := slot_at_cursor(gs)
            if s < 0 || gs.player.inventory.slots[s].item != gs.ui.drag_item do loose += 1
        }
        carrying = gs.ui.drag_item != .None
        b := barrel_at(gs, gs.level_index, tile)
        // Mid-drag after the first stack went in, the stack over the barrel,
        // the windows are swept shut, once.
        win, in_win := window_at_cursor(gs)
        if shut == 0 && b != nil && b.slots[0].count > 0 && gs.ui.show_barrel && carrying && in_win && win == .Barrel {
            gs.ui.show_barrel, gs.ui.show_inventory = false, false
            shut += 1
        }
    }
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, shut, 1)
    testing.expect_value(t, blind, 0)  // every let-go with the window up
    testing.expect_value(t, loose, 0)
    b := barrel_at(gs, gs.level_index, tile)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 0)
    testing.expect_value(t, work_test_total(gs, b, .Stone_Block), 150)
}

// The reach each tool has from a stand tile: the pick round the body two up
// and one down, never into it; wands and placing by chebyshev, never the
// body; a window by chebyshev, the body too.
@(test)
hero_work_reach_by_tool :: proc(t: ^testing.T) {
    s := [2]i32{50, 50}
    cases := [?]struct{ reach: Hero_Work_Reach, rng: i32, t: [2]i32, want: bool }{
        {.Pick, PICK_RANGE, {51, 48}, true},
        {.Pick, PICK_RANGE, {51, 47}, false},
        {.Pick, PICK_RANGE, {50, 51}, true},
        {.Pick, PICK_RANGE, {50, 49}, false},
        {.Wand, 4, {54, 46}, true},
        {.Wand, 4, {55, 50}, false},
        {.Wand, 4, {50, 49}, false},
        {.Place, 8, {50, 50}, false},
        {.Bench, 3, {53, 47}, true},
        {.Bench, 3, {54, 50}, false},
        {.Bench, 3, {50, 49}, true},
    }
    for c in cases {
        testing.expectf(t, hero_work_reaches(c.reach, c.rng, s, c.t) == c.want, "%v %d to %v: want %v", c.reach, c.rng, c.t, c.want)
    }
}

// A tile two over the head is mined from the floor below it.
@(test)
hero_mines_a_tile_over_its_head :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    ore := [2]i32{i32(x0 + 4), i32(G - 3)}
    set_tile(&gs.world, int(ore.x), int(ore.y), .Iron_Ore)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, ore.x, ore.y), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, int(ore.x), int(ore.y)), Tile_Type.Air)
    testing.expect_value(t, hero_feet(&gs.player).y, i32(G - 1))
}

// Of the stand tiles that reach, the nearest: the ore in a tall wall is mined
// from this side, not from over it.
@(test)
hero_mine_stands_on_the_near_side :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for y in G - 8 ..< G do set_tile(&gs.world, x0 + 6, y, .Stone)
    ore := [2]i32{i32(x0 + 6), i32(G - 3)}
    set_tile(&gs.world, int(ore.x), int(ore.y), .Iron_Ore)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, ore.x, ore.y), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, int(ore.x), int(ore.y)), Tile_Type.Air)
    testing.expect_value(t, hero_feet(&gs.player), [2]i32{i32(x0 + 5), i32(G - 1)})
}

// A craft by hand needs no station and no air round it: under water too.
@(test)
hero_crafts_by_hand_under_water :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    feet := hero_feet(&gs.player)
    for x in feet.x - HERO_WORK_SEARCH_X ..= feet.x + HERO_WORK_SEARCH_X {
        for y in feet.y - HERO_WORK_SEARCH_Y ..= feet.y + HERO_WORK_SEARCH_Y {
            if in_bounds(int(x), int(y)) && get_tile(&gs.world, int(x), int(y)) == .Air do set_tile(&gs.world, int(x), int(y), .Water)
        }
    }
    reveal_recipe(&gs.progression, .Crafting_Bench)
    go_test_give(gs, .Plank, 4)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, `{"do":"craft","item":"Crafting_Bench"}`, 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Crafting_Bench), 1)
}

// With the bag full the mined drop lies where the tile was: mined all the same.
@(test)
hero_mines_with_a_full_bag :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 + 3, G - 1, .Stone)
    go_test_give(gs, .Pickaxe, 1)
    go_test_give(gs, .Iron_Ore, (MAX_INVENTORY - 1) * MAX_STACK)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 3, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, x0 + 3, G - 1), Tile_Type.Air)
}

// A pile taken by something else on the way is let go: the next is sought.
@(test)
hero_gather_lets_a_pile_gone_go :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    set_tile(&gs.world, x0 + 3, G - 1, .Iron_Ore)
    pile := [2]i32{i32(x0 - 8), i32(G - 1)}
    spawn_ground_item(&gs.world, pile, .Iron_Ore, 1)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"gather","item":"Iron_Ore","count":1}]}`)
    reply := exec_test_reply(link)
    id := int(reply["ids"].(json.Array)[0].(json.Float))
    exec_test_frames(link, gs, 10)
    testing.expect(t, hero_feet(&gs.player).x < i32(x0), "off toward the pile")
    idx := grid_idx(int(pile.x), int(pile.y))
    gs.world.items[idx], gs.world.item_counts[idx] = .None, 0
    gone_at := hero_feet(&gs.player).x
    least := gone_at
    for f := 0; f < 20 * 60 && agent_goals_busy(&link.goals); f += 1 {
        exec_test_frames(link, gs, 1)
        least = min(least, hero_feet(&gs.player).x)
    }
    testing.expectf(t, least >= gone_at - 1, "went on toward the gone pile: from %d to %d", gone_at, least)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, get_tile(&gs.world, x0 + 3, G - 1), Tile_Type.Air)
}

// A place clicked that does not take, whatever the cause, fails after a few
// looks rather than waiting on it.
@(test)
hero_place_that_does_not_take_fails :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Stone_Block, 5)
    exec_test_frames(link, gs, 5)
    at := [2]int{x0 + 3, G - 1}
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"place","item":"Stone_Block","at":[%d,%d]}}]}}`, at.x, at.y))
    reply := exec_test_reply(link)
    id := int(reply["ids"].(json.Array)[0].(json.Float))
    for f := 0; f < 600 && agent_goals_busy(&link.goals); f += 1 {
        exec_test_frames(link, gs, 1)
        set_tile(&gs.world, at.x, at.y, .Air)  // taken back as soon as set
    }
    work_test_expect_failed(t, link, gs, id, "out_of_reach")
}

// Home walled in tight: no tile round it takes the item, and the goal says so.
@(test)
hero_place_near_home_with_no_room_fails :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    _, _ = hero_test_arena(gs)
    go_test_give(gs, .Barrel, 1)
    exec_test_frames(link, gs, 5)
    feet := hero_feet(&gs.player)
    testing.expect_value(t, feet, hero_spawn_feet())
    for dy in -HERO_PLACE_NEAR - 1 ..= HERO_PLACE_NEAR + 1 {
        for dx in -HERO_PLACE_NEAR - 1 ..= HERO_PLACE_NEAR + 1 {
            if dx == 0 && (dy == 0 || dy == -1) do continue
            set_tile(&gs.world, int(feet.x + dx), int(feet.y + dy), .Stone)
        }
    }
    id := work_test_run(t, link, gs, `{"do":"place","item":"Barrel","near":"home"}`, 600)
    work_test_expect_failed(t, link, gs, id, "out_of_reach: no tile round home")
}

// The stand chosen is the nearest of those that reach, whichever side.
@(test)
hero_work_stand_is_the_nearest :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    ore := [2]i32{i32(x0 + 6), i32(G)}
    s, ok, _ := hero_work_stand(gs, ore, .Pick, PICK_RANGE)
    testing.expect(t, ok, "a stand")
    testing.expect_value(t, s, [2]i32{i32(x0 + 5), i32(G - 1)})
    gs.player.pos.x = f32(x0 + 12)
    s, ok, _ = hero_work_stand(gs, ore, .Pick, PICK_RANGE)
    testing.expect_value(t, s, [2]i32{i32(x0 + 7), i32(G - 1)})
}

// A goal added and run until it ends, with no watch: for the full cases, where
// a drop has no slot to land on and a mouse lets go anywhere.
@(private="file")
work_test_bare :: proc(link: ^Agent_Link, gs: ^Game_State, line: string, max_frames: int) -> (id: int) {
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, line))
    id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    for f := 0; f < max_frames && agent_goals_busy(&link.goals); f += 1 do exec_test_frames(link, gs, 1)
    return
}

// A full barrel, a full bag: a drag that moves nothing ends the goal, full.
@(test)
hero_store_and_withdraw_stop_when_full :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Barrel, 1)
    go_test_give(gs, .Stone_Block, 10)
    exec_test_frames(link, gs, 5)
    tile := [2]i32{i32(x0 + 3), i32(G - 1)}
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Barrel","at":[%d,%d]}}`, tile.x, tile.y), 600)
    work_test_expect_done(t, link, gs, id)
    b := barrel_at(gs, gs.level_index, tile)
    if b == nil do return
    for &s in b.slots do s = {item = .Iron_Ore, count = MAX_STACK}
    id = work_test_bare(link, gs, `{"do":"store","item":"Stone_Block"}`, 900)
    work_test_expect_failed(t, link, gs, id, "full: the barrel takes no Stone_Block")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 10)

    b.slots[0] = {item = .Stone_Block, count = 5}
    go_test_give(gs, .Stone_Block, MAX_STACK - 10)
    for s in gs.player.inventory.slots do if s.count == 0 do go_test_give(gs, .Iron_Ore, MAX_STACK)
    id = work_test_bare(link, gs, `{"do":"withdraw","item":"Stone_Block"}`, 900)
    work_test_expect_failed(t, link, gs, id, "full: the bag takes no more")
    testing.expect_value(t, b.slots[0].count, 5)
}

// One drag empties the tray or the furnace into the bag; a full bag leaves
// it there and the goal ends.
@(test)
hero_collect_with_a_full_bag_ends :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Smelter, 1)
    exec_test_frames(link, gs, 5)
    m := [2]i32{i32(x0 + 3), i32(G - 1)}
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Smelter","at":[%d,%d]}}`, m.x, m.y), 600)
    work_test_expect_done(t, link, gs, id)
    sd := &gs.world.sim_data[grid_idx(int(m.x), int(m.y))]
    sd.store_item, sd.store_count = .Iron_Bar, 3
    sd.in_item, sd.in_count = .Iron_Ore, 2
    go_test_give(gs, .Stone_Block, MAX_INVENTORY * MAX_STACK)
    id = work_test_bare(link, gs, `{"do":"collect"}`, 900)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, sd.store_count, 3)
    id = work_test_bare(link, gs, fmt.tprintf(`{{"do":"withdraw","at":[%d,%d]}}`, m.x, m.y), 900)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, sd.in_count, 2)
}

// Count two with the means for one: one made, then the reason.
@(test)
hero_craft_stops_when_the_means_run_out :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    _, _ = hero_test_arena(gs)
    reveal_recipe(&gs.progression, .Crafting_Bench)
    go_test_give(gs, .Plank, 6)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, `{"do":"craft","item":"Crafting_Bench","count":2}`, 900)
    work_test_expect_failed(t, link, gs, id, "no_item: not enough for another Crafting_Bench, 1 made")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Crafting_Bench), 1)
}

// A place far off with no ground in reach of it: unreachable, and why.
@(test)
hero_place_with_no_ground_near_fails :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Stone_Block, 5)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Stone_Block","at":[%d,%d]}}`, x0 + 15, G - 9), 300)
    work_test_expect_failed(t, link, gs, id, "unreachable: no ground near")
}

// A machine on a pillar with no ground in reach of it: unreachable, and why.
@(test)
hero_window_goal_with_no_ground_near_fails :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    for y in G - 12 ..< G do set_tile(&gs.world, x0 + 10, y, .Stone)  // its top four up: out of reach too
    set_tile(&gs.world, x0 + 10, G - 8, .Smelter)
    go_test_give(gs, .Iron_Ore, 2)
    exec_test_frames(link, gs, 5)
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"feed","item":"Iron_Ore","at":[%d,%d]}}`, x0 + 10, G - 8), 300)
    work_test_expect_failed(t, link, gs, id, "unreachable: no ground in reach")
}

// The machine gone as the hero clicks it: one click, a few looks, then why.
@(test)
hero_window_that_does_not_open_fails :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Barrel, 1)
    go_test_give(gs, .Stone_Block, 10)
    exec_test_frames(link, gs, 5)
    tile := [2]i32{i32(x0 + 3), i32(G - 1)}
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Barrel","at":[%d,%d]}}`, tile.x, tile.y), 600)
    work_test_expect_done(t, link, gs, id)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"store","item":"Stone_Block"}]}`)
    id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    exec_test_frames(link, gs, 1)
    set_tile(&gs.world, int(tile.x), int(tile.y), .Stone)
    uses := 0
    for f := 0; f < 600 && agent_goals_busy(&link.goals); f += 1 {
        exec_test_frames(link, gs, 1)
        if gs.agent.first && gs.agent.cmd.has_use do uses += 1
    }
    work_test_expect_failed(t, link, gs, id, "out_of_reach: the window")
    testing.expect_value(t, uses, 1)
}

// A window open on another machine is not this goal's: the hero goes to its
// own, opens it, and works that one.
@(test)
hero_works_its_own_machine_not_the_open_one :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Barrel, 2)
    go_test_give(gs, .Smelter, 2)
    go_test_give(gs, .Stone_Block, 10)
    go_test_give(gs, .Iron_Ore, 4)
    reveal_recipe(&gs.progression, .Crafting_Bench)
    go_test_give(gs, .Crafting_Bench, 1)
    go_test_give(gs, .Plank, 4)
    exec_test_frames(link, gs, 5)
    // Both of each in reach of where the hero stands: no walk sweeps the
    // other window shut first.
    a, b := [2]i32{i32(x0 + 2), i32(G - 1)}, [2]i32{i32(x0 + 3), i32(G - 1)}
    sa, sb := [2]i32{i32(x0 - 2), i32(G - 1)}, [2]i32{i32(x0 - 3), i32(G - 1)}
    for at, i in ([4][2]i32{a, b, sa, sb}) {
        it := "Barrel" if i < 2 else "Smelter"
        id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"%s","at":[%d,%d]}}`, it, at.x, at.y), 600)
        work_test_expect_done(t, link, gs, id)
    }
    stand :: proc(gs: ^Game_State, x0, G: int) {
        gs.player.pos, gs.player.vel = {f32(x0) + 0.1, f32(G) - PLAYER_H}, {}
    }
    // The stack joins the barrel's own stack, past an empty first slot.
    barrel_at(gs, gs.level_index, b).slots[3] = {item = .Stone_Block, count = 5}
    stand(gs, x0, G)
    gs.ui.show_barrel, gs.ui.barrel_tile, gs.ui.show_inventory = true, a, true
    id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"store","item":"Stone_Block","at":[%d,%d]}}`, b.x, b.y), 900)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, work_test_total(gs, barrel_at(gs, gs.level_index, b), .Stone_Block), 15)

    stand(gs, x0, G)
    gs.ui.show_smelter, gs.ui.smelter_tile, gs.ui.show_inventory = true, sa, true
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"feed","item":"Iron_Ore","at":[%d,%d]}}`, sb.x, sb.y), 900)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, int(gs.world.sim_data[grid_idx(int(sb.x), int(sb.y))].in_count), 4)

    // The hand window open, and a bench recipe asked for: the bench's own.
    id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"place","item":"Crafting_Bench","at":[%d,%d]}}`, x0 + 1, G - 1), 600)
    work_test_expect_done(t, link, gs, id)
    stand(gs, x0, G)
    gs.ui.show_crafting, gs.ui.active_station, gs.ui.show_inventory = true, .None, true
    go_test_give(gs, .Stone_Block, 8)
    go_test_give(gs, .Iron_Ore, 2)
    id = work_test_run(t, link, gs, `{"do":"craft","item":"Smelter"}`, 900)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Smelter), 1)
}

// Natural ground: a turf of grass over the stone.  Stone and ore lie under
// it, out of the pick's reach from the grass: the hero digs its way down.
@(private="file")
work_test_turf :: proc(gs: ^Game_State, x0, G: int) {
    for x in x0 - 18 ..= x0 + 22 do set_tile(&gs.world, x, G, .Grass)
}

@(test)
hero_gathers_stone_under_the_turf :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    work_test_turf(gs, x0, G)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    hp := gs.player.hp
    id := work_test_run(t, link, gs, `{"do":"gather","item":"Stone_Block","count":3}`, 60 * 60)
    work_test_expect_done(t, link, gs, id)
    testing.expect(t, inventory_count(&gs.player.inventory, .Stone_Block) >= 3, "three stone")
    testing.expect_value(t, gs.player.hp, hp)
}

// Three under the turf: a stair down to it, no drop that hurts.
@(test)
hero_mines_an_ore_deep_under_the_turf :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    work_test_turf(gs, x0, G)
    set_tile(&gs.world, x0 + 6, G + 3, .Iron_Ore)
    go_test_give(gs, .Pickaxe, 1)
    exec_test_frames(link, gs, 5)
    hp := gs.player.hp
    id := work_test_run(t, link, gs, `{"do":"mine","item":"Iron_Ore"}`, 60 * 60)
    work_test_expect_done(t, link, gs, id)
    testing.expect(t, get_tile(&gs.world, x0 + 6, G + 3) != .Iron_Ore, "mined")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 1)
    testing.expect_value(t, gs.player.hp, hp)
}

// Two ores no walk reaches before one that can be: walled in by barrels,
// which no pick digs (no ground in reach of it, dug or not), and atop a
// barrel pillar nothing climbs (the walk fails).  Each is passed over, by a
// mine by item and by a gather.  With none left that can be reached the goal
// says so; a tile asked for by name is not passed over.
@(private="file")
work_test_unreachable_ores :: proc(gs: ^Game_State, x0, G: int) {
    walled := [2]int{x0 - 3, G - 1}
    for x in walled.x - 1 ..= walled.x + 1 do for y in walled.y - 1 ..= walled.y + 2 do set_tile(&gs.world, x, y, .Barrel)
    set_tile(&gs.world, walled.x, walled.y, .Iron_Ore)
    for y in G - 6 ..< G do set_tile(&gs.world, x0 + 4, y, .Barrel)
    set_tile(&gs.world, x0 + 4, G - 7, .Iron_Ore)
}

@(test)
hero_mine_passes_over_an_ore_it_cannot_reach :: proc(t: ^testing.T) {
    for kind in ([2]string{"mine", "gather"}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        work_test_unreachable_ores(gs, x0, G)
        set_tile(&gs.world, x0 + 12, G - 1, .Iron_Ore)
        go_test_give(gs, .Pickaxe, 1)
        exec_test_frames(link, gs, 5)
        id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"%s","item":"Iron_Ore"}}`, kind), 60 * 60)
        work_test_expect_done(t, link, gs, id)
        testing.expect_value(t, get_tile(&gs.world, x0 + 12, G - 1), Tile_Type.Air)
        testing.expect_value(t, get_tile(&gs.world, x0 - 3, G - 1), Tile_Type.Iron_Ore)
        testing.expect_value(t, get_tile(&gs.world, x0 + 4, G - 7), Tile_Type.Iron_Ore)
        if kind == "gather" do continue
        // No other ore in the level, past the arena either.
        for x in 0 ..< GRID_W do for y in 0 ..< GRID_H {
            here := [2]int{x, y}
            if here == {x0 - 3, G - 1} || here == {x0 + 4, G - 7} do continue
            if get_tile(&gs.world, x, y) == .Iron_Ore do set_tile(&gs.world, x, y, .Stone)
        }
        id = work_test_run(t, link, gs, `{"do":"mine","item":"Iron_Ore"}`, 60 * 60)
        work_test_expect_failed(t, link, gs, id, "unreachable: no Iron_Ore in")
        id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 4, G - 7), 60 * 60)
        work_test_expect_failed(t, link, gs, id, "unsafe")  // its top, over the pillar of barrels
        id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 - 3, G - 1), 60 * 60)
        work_test_expect_failed(t, link, gs, id, "unreachable")
    }
}

// Seed 781's lone ore over a cave: a dig never takes the hero's own floor
// over a drop that hurts.  Stood on the ore, the hero steps to the side to
// mine it; with no side in reach the tile fails unsafe and the item passes
// it over.  No hp lost.
@(private="file")
work_test_ore_over_a_cave :: proc(gs: ^Game_State, x0, G: int, sides: bool) -> [2]i32 {
    for x in x0 + 3 ..= x0 + 9 {
        for y in G + 1 ..= G + 12 do set_tile(&gs.world, x, y, .Air)
        set_tile(&gs.world, x, G + 13, .Stone)
    }
    if !sides do for x in ([2]int{x0 + 5, x0 + 7}) do set_tile(&gs.world, x, G, .Air)
    set_tile(&gs.world, x0 + 6, G, .Iron_Ore)
    return {i32(x0 + 6), i32(G)}
}

@(test)
hero_mine_never_takes_its_own_floor_over_a_drop :: proc(t: ^testing.T) {
    {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        ore := work_test_ore_over_a_cave(gs, x0, G, sides = true)
        _, hurts, _ := hero_dig_fall(&gs.world, ore)
        testing.expect(t, hurts > 0, "the cave's drop hurts")
        gs.player.pos = {f32(ore.x) + 0.1, f32(G) - PLAYER_H}  // on the ore
        go_test_give(gs, .Pickaxe, 1)
        exec_test_frames(link, gs, 5)
        hp := gs.player.hp
        id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, ore.x, ore.y), 60 * 60)
        work_test_expect_done(t, link, gs, id)
        testing.expect_value(t, get_tile(&gs.world, int(ore.x), int(ore.y)), Tile_Type.Void)
        testing.expect_value(t, gs.player.hp, hp)
        testing.expect(t, hero_feet_row(&gs.player) < i32(G), "on the ground above, not down the cave")
    }
    {
        // Only its own floor is held back: a block beside its head, hung over
        // the drop, is mined.
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        work_test_ore_over_a_cave(gs, x0, G, sides = false)
        set_tile(&gs.world, x0 + 5, G - 2, .Stone)
        gs.player.pos = {f32(x0 + 4) + 0.1, f32(G) - PLAYER_H}
        go_test_give(gs, .Pickaxe, 1)
        exec_test_frames(link, gs, 5)
        id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x0 + 5, G - 2), 60 * 60)
        work_test_expect_done(t, link, gs, id)
    }
    for kind in ([3]string{"tile", "mine", "gather"}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        ore := work_test_ore_over_a_cave(gs, x0, G, sides = false)
        go_test_give(gs, .Pickaxe, 1)
        exec_test_frames(link, gs, 5)
        hp := gs.player.hp
        if kind == "tile" {
            id := work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, ore.x, ore.y), 60 * 60)
            work_test_expect_failed(t, link, gs, id, "unsafe")
            // A drop short enough to fall for free, into lava: unsafe all the same.
            // Hung in mid air, and as a pool on the ground two below.
            set_tile(&gs.world, int(ore.x), int(ore.y) + 3, .Lava)
            id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, ore.x, ore.y), 60 * 60)
            work_test_expect_failed(t, link, gs, id, "unsafe")
            for x in ore.x - 2 ..= ore.x + 2 {
                set_tile(&gs.world, int(x), int(ore.y) + 1, .Air)
                set_tile(&gs.world, int(x), int(ore.y) + 2, .Stone if abs(x - ore.x) == 2 else .Lava)
                set_tile(&gs.world, int(x), int(ore.y) + 3, .Stone)
            }
            id = work_test_run(t, link, gs, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, ore.x, ore.y), 60 * 60)
            work_test_expect_failed(t, link, gs, id, "unsafe")
        } else {
            // The cave's ore the nearest, one on firm ground past it.
            for x in 0 ..< GRID_W do for y in 0 ..< GRID_H {
                if (x != int(ore.x) || y != int(ore.y)) && get_tile(&gs.world, x, y) == .Iron_Ore do set_tile(&gs.world, x, y, .Stone)
            }
            set_tile(&gs.world, x0 - 12, G - 1, .Iron_Ore)
            line := `{"do":"mine","item":"Iron_Ore"}` if kind == "mine" else `{"do":"gather","item":"Iron_Ore","count":1}`
            id := work_test_run(t, link, gs, line, 60 * 60)
            work_test_expect_done(t, link, gs, id)
            testing.expect_value(t, get_tile(&gs.world, x0 - 12, G - 1), Tile_Type.Air)
        }
        testing.expect_value(t, get_tile(&gs.world, int(ore.x), int(ore.y)), Tile_Type.Iron_Ore)
        testing.expect_value(t, gs.player.hp, hp)
    }
}

// Of the stands that reach a buried ore, one on open ground beats one to dig
// that is as near: each tile to dig weighs HERO_WORK_DIG_COST of walk.  With
// no pickaxe, nothing is dug: buried wood has no ground in reach.
@(test)
hero_work_stand_digs_only_with_a_pick_and_when_worth_it :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    x0, G := hero_test_arena(gs)
    ore := [2]i32{i32(x0 + 5), i32(G + 1)}
    set_tile(&gs.world, int(ore.x), int(ore.y), .Iron_Ore)
    set_tile(&gs.world, x0 + 4, G, .Air)  // a pocket beside it, two high, open from above
    set_tile(&gs.world, x0 + 4, G + 1, .Air)
    go_test_give(gs, .Pickaxe, 1)
    s, ok, _ := hero_work_stand(gs, ore, .Pick, PICK_RANGE)
    testing.expect(t, ok, "a stand")
    testing.expect_value(t, s, [2]i32{i32(x0 + 4), i32(G + 1)})

    gs2, link2 := exec_test_world()
    defer free(gs2)
    defer free(link2)
    x1, G1 := hero_test_arena(gs2)
    work_test_turf(gs2, x1, G1)
    set_tile(&gs2.world, x1 + 5, G1 + 1, .Wood)
    exec_test_frames(link2, gs2, 5)
    id := work_test_run(t, link2, gs2, fmt.tprintf(`{{"do":"mine","tile":[%d,%d]}}`, x1 + 5, G1 + 1), 600)
    work_test_expect_failed(t, link2, gs2, id, "unreachable: no ground in reach")
}

// A hand craft opens the bag and the crafting window as TAB lays them out.
@(test)
hero_hand_craft_opens_the_windows_as_tab_does :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    _, _ = hero_test_arena(gs)
    reveal_recipe(&gs.progression, .Crafting_Bench)
    go_test_give(gs, .Plank, 4)
    exec_test_frames(link, gs, 5)
    gs.ui.win_pos[.Inventory], gs.ui.win_pos[.Crafting] = {5, 5}, {5, 5}  // left where nothing lays them
    twin := new(Game_State)
    defer free(twin)
    twin^ = gs^
    place_craft_pair(twin)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"craft","item":"Crafting_Bench"}]}`)
    id := int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    seen := false
    for f := 0; f < 600 && agent_goals_busy(&link.goals); f += 1 {
        exec_test_frames(link, gs, 1)
        if gs.ui.show_crafting && !seen {
            seen = true
            testing.expect_value(t, gs.ui.win_pos[.Inventory], twin.ui.win_pos[.Inventory])
            testing.expect_value(t, gs.ui.win_pos[.Crafting], twin.ui.win_pos[.Crafting])
        }
    }
    testing.expect(t, seen, "the crafting window opened")
    work_test_expect_done(t, link, gs, id)
}

// ─── fight ───

// An enemy of a kind whose body's bottom sits on row `bottom`, at tile x.
@(private="file")
fight_test_body :: proc(gs: ^Game_State, kind: Enemy_Kind, x, bottom: int) -> int {
    id, ok := enemy_alloc(&gs.enemies)
    assert(ok)
    row := enemy_behaviour[kind]
    e := &gs.enemies.data[id]
    e^ = Enemy{kind = kind, hp = row.hp, hp_max = row.hp, facing = -1,
               pos = {f32(x) + (1 - row.body.x) * 0.5, f32(bottom) - row.body.y}}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    return id
}

@(private="file")
Fight_Watch :: struct {
    dug:      int,  // tiles of the arena that changed under the fight
    blind:    int,  // wand shots with no clear line to the target
    swings:   int,  // sword blows
    shots:    int,  // frames the wand fired
    in_pit:   int,  // wand shots with the hero's feet below row `floor`
    off_aim:  int,  // shots not aimed at the target's body centre
    brain:    int,  // frames the brain fought or fled instead of the goal
}

// A fight goal run to its end, the arena's tiles compared before and after.
@(private="file")
fight_test_run :: proc(link: ^Agent_Link, gs: ^Game_State, line: string, target: int, x0, G, max_frames: int, floor := max(int)) -> (id: int, w: Fight_Watch) {
    W :: 41
    H :: 23
    before: [W * H]Tile_Type
    for dx in 0 ..< W do for dy in 0 ..< H do before[dy * W + dx] = get_tile(&gs.world, x0 - 18 + dx, G - 10 + dy)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, line))
    ids, ok := exec_test_reply(link)["ids"].(json.Array)
    assert(ok, string(link.out[:link.out_len]))
    id = int(ids[0].(json.Float))
    kind := gs.enemies.data[target].kind
    for f := 0; f < max_frames && agent_goals_busy(&link.goals); f += 1 {
        // The hero decides on where things are as the frame starts.
        p := &gs.player
        e := &gs.enemies.data[target]
        hc := p.pos + [2]f32{PLAYER_W, PLAYER_H} * 0.5
        ec := e.pos + enemy_body_size(e.kind) * 0.5
        feet_row := int(p.pos.y + PLAYER_H - 0.01)
        exec_test_frames(link, gs, 1)
        if gs.hero.current == .Fight || gs.hero.current == .Flee do w.brain += 1
        if !gs.input.mine || !gs.enemies.active[target] || gs.enemies.data[target].kind != kind do continue
        if c := gs.agent.cmd; c.has_mine && abs(c.aim.x - ec.x) + abs(c.aim.y - ec.y) > 0.01 do w.off_aim += 1
        if is_melee_weapon(held_item(p)) do w.swings += 1
        if !is_fire_wand(held_item(p)) do continue
        w.shots += 1
        if !sight_line_clear(&gs.world, hc, ec, skip_ends = true) do w.blind += 1
        if feet_row > floor do w.in_pit += 1
    }
    for dx in 0 ..< W do for dy in 0 ..< H do if before[dy * W + dx] != get_tile(&gs.world, x0 - 18 + dx, G - 10 + dy) do w.dug += 1
    return
}

// A frog, a beetle and an eel in its pool, each killed with the wand alone.
@(test)
hero_fight_kills_a_frog_a_beetle_and_an_eel_with_the_wand :: proc(t: ^testing.T) {
    for kind in ([3]Enemy_Kind{.Pond_Frog, .Ember_Beetle, .Cave_Eel}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        go_test_give(gs, .Fire_Wand, 1)
        gs.player.mana = gs.player.mana_max
        bottom := G
        if kind == .Cave_Eel {
            // A pool four deep from x0+5 to x0+12, the eel at its bottom.
            for x in x0 + 5 ..= x0 + 12 do for y in G ..< G + 4 do set_tile(&gs.world, x, y, .Water)
            bottom = G + 3
        }
        e := fight_test_body(gs, kind, x0 + 8, bottom)
        id, w := fight_test_run(link, gs, fmt.tprintf(`{{"do":"fight","kind":"%v"}}`, kind), e, x0, G, 1800)
        status, reason := go_test_status(link, gs, id)
        testing.expectf(t, status == "done", "%v: %s %s", kind, status, reason)
        testing.expectf(t, !gs.enemies.active[e] || gs.enemies.data[e].kind != kind, "%v: still alive", kind)
        testing.expectf(t, w.shots > 0 && w.swings == 0, "%v: %d shots %d swings", kind, w.shots, w.swings)
        testing.expectf(t, w.blind == 0, "%v: %d shots into a wall", kind, w.blind)
        testing.expectf(t, w.off_aim == 0, "%v: %d shots not at the body's centre", kind, w.off_aim)
        testing.expectf(t, w.brain == 0, "%v: %d frames the brain took over the fight", kind, w.brain)
        testing.expect(t, !gs.player.dead)
    }
}

// Run 8: the hero tunnelled under a frog and shot the dirt.  From a trench
// whose near wall hides the frog it climbs the stair out and shoots from its
// top step or the ground, digging nothing.
@(test)
hero_fight_walks_out_of_a_pit_and_digs_nothing :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    // A trench three deep from x0-2 to x0+2, a stair up out of its right end
    // toward the frog, the stair's own steps in the way of a shot.
    for x in x0 - 2 ..= x0 + 2 do for y in G ..< G + 3 do set_tile(&gs.world, x, y, .Air)
    set_tile(&gs.world, x0 + 3, G, .Air)
    set_tile(&gs.world, x0 + 3, G + 1, .Air)
    set_tile(&gs.world, x0 + 4, G, .Air)
    gs.player.pos = {f32(x0) + 0.1, f32(G + 3) - PLAYER_H}
    go_test_give(gs, .Fire_Wand, 1)
    go_test_give(gs, .Pickaxe, 1)  // a pick in the bag: still no digging
    gs.player.mana = gs.player.mana_max
    e := fight_test_body(gs, .Pond_Frog, x0 + 10, G)
    testing.expect(t, !sight_line_clear(&gs.world, gs.player.pos + [2]f32{PLAYER_W, PLAYER_H} * 0.5,
                                        gs.enemies.data[e].pos + enemy_body_size(.Pond_Frog) * 0.5, skip_ends = true), "the wall hides it")
    id, w := fight_test_run(link, gs, `{"do":"fight","kind":"Pond_Frog"}`, e, x0, G, 1800, floor = G)
    work_test_expect_done(t, link, gs, id)
    testing.expect(t, !gs.enemies.active[e] || gs.enemies.data[e].kind != .Pond_Frog, "the frog is dead")
    testing.expectf(t, w.dug == 0, "%d tiles dug", w.dug)
    testing.expectf(t, w.blind == 0 && w.in_pit == 0, "%d shots into a wall, %d from the pit", w.blind, w.in_pit)
}

// Behind a wall five high that no walk crosses, a frog: a pick in the bag
// would tunnel through, but a fight never digs; it gives up unreachable.
@(test)
hero_fight_never_tunnels_to_a_target :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    for y in G - 5 ..< G do set_tile(&gs.world, x0 + 3, y, .Stone)
    go_test_give(gs, .Fire_Wand, 1)
    go_test_give(gs, .Pickaxe, 1)
    gs.player.mana = gs.player.mana_max
    e := fight_test_body(gs, .Ember_Beetle, x0 + 9, G)
    gs.enemies.data[e].hp, gs.enemies.data[e].hp_max = 1000, 1000
    id, w := fight_test_run(link, gs, `{"do":"fight","kind":"Ember_Beetle"}`, e, x0, G, 60 * 30)
    work_test_expect_failed(t, link, gs, id, "unreachable")
    testing.expectf(t, w.dug == 0, "%d tiles dug", w.dug)
    testing.expectf(t, w.blind == 0, "%d shots into the wall", w.blind)
}

// Low on hp it backs off, shooting as it goes, and gives the fight up once
// clear; a sword is not swung while backing off.
@(test)
hero_fight_backs_off_at_low_hp :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    // Flat ground far to the left: room to back off into.
    for x in x0 - 50 ..< x0 - 18 do for y in G - 10 ..= G + 12 do set_tile(&gs.world, x, y, .Air if y < G else .Stone)
    go_test_give(gs, .Sword, 1)
    go_test_give(gs, .Fire_Wand, 1)
    gs.player.mana = gs.player.mana_max
    v := hero_test_vargr(gs, f32(x0) + 1.6, G, {})  // in the sword's reach
    gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
    gs.player.hp_max = 100
    gs.player.hp = int(HERO_FIGHT_RETREAT_FRAC * f32(gs.player.hp_max)) - 1
    link.goals.reflexes_off = {.Fight_Back}  // the shots are the goal's own
    hp0 := gs.player.hp
    id, w := fight_test_run(link, gs, `{"do":"fight","kind":"Vargr"}`, v, x0, G, 900)
    work_test_expect_failed(t, link, gs, id, "low_hp")
    testing.expect(t, !gs.player.dead, "it got away")
    testing.expect(t, gs.player.hp <= hp0)
    testing.expectf(t, w.swings == 0 && w.shots > 0, "%d swings, %d shots", w.swings, w.shots)
    testing.expectf(t, w.brain == 0, "%d frames the brain fled instead", w.brain)
    e := &gs.enemies.data[v]
    testing.expect(t, abs(e.pos.x - gs.player.pos.x) >= HERO_THREAT_FAR - 2, "clear of it")
}

// A bite answered: under half its hp with a sword, the hero runs rather than
// fights; with fight_back on it swings at the biter as it goes, off it only runs.
@(test)
hero_fight_back_answers_a_bite :: proc(t: ^testing.T) {
    for on in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        go_test_give(gs, .Sword, 1)
        if !on do link.goals.reflexes_off = {.Fight_Back}
        gs.player.hp_max, gs.player.hp = 100, 40
        v := hero_test_vargr(gs, f32(x0) + 1.6, G, {})
        gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
        bitten, struck, fled := false, 0, false
        for _ in 0 ..< 120 {
            hp := gs.player.hp
            exec_test_frames(link, gs, 1)
            bitten ||= gs.player.hp < hp
            fled ||= gs.hero.current == .Flee
            if gs.input.mine && is_melee_weapon(held_item(&gs.player)) do struck += 1
        }
        testing.expect(t, bitten, "the vargr bit")
        testing.expect(t, fled, "the hero ran")
        if on do testing.expectf(t, struck > 0, "struck back %d times", struck)
        else do testing.expectf(t, struck == 0, "struck %d times with the reflex off", struck)
    }
}

// Fight lines the check refuses, and starts with nothing to fight with or at.
@(test)
hero_fight_goal_reasons :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    for c in ([?][2]string{
        {`{"do":"fight"}`, "fight needs kind or slot"},
        {`{"do":"fight","kind":"Frog","slot":3}`, "fight needs kind or slot"},
        {`{"do":"fight","kind":"Dragon"}`, "fight: kind must name an enemy kind, not Dragon"},
        {`{"do":"fight","slot":256}`, "fight: slot takes 0 to 255"},
        {`{"do":"fight","slot":1.5}`, "fight: slot takes 0 to 255"},
    }) {
        agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, c[0]))
        testing.expectf(t, strings.contains(string(link.out[:link.out_len]), c[1]), "%s: %s", c[0], string(link.out[:link.out_len]))
    }
    e := fight_test_body(gs, .Pond_Frog, x0 + 6, G)
    id, _ := fight_test_run(link, gs, `{"do":"fight","kind":"Pond_Frog"}`, e, x0, G, 30)
    work_test_expect_failed(t, link, gs, id, "no_item: no sword or fire wand")
    go_test_give(gs, .Sword, 1)
    id, _ = fight_test_run(link, gs, `{"do":"fight","kind":"Ember_Beetle"}`, e, x0, G, 30)
    work_test_expect_failed(t, link, gs, id, "no_target: no Ember_Beetle in sight")
    id, _ = fight_test_run(link, gs, `{"do":"fight","slot":200}`, e, x0, G, 30)
    work_test_expect_failed(t, link, gs, id, "no_target: slot 200 holds no enemy")
    id, _ = fight_test_run(link, gs, fmt.tprintf(`{{"do":"fight","slot":%d}}`, e), e, x0, G, 900)
    work_test_expect_done(t, link, gs, id)
}


// Seed 999: fleeing a Builder, the hero walked off a ledge for a 17-tile fall
// (hp 10 to 3).  Cornered at a drop, it takes a hurt fall only when the fall
// costs less than the blow running back past the threat would; a Builder's
// blow is 1 hp, so it runs back past it instead.
@(test)
hero_flee_takes_no_fall_that_costs_more_than_the_threat :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    // A chasm seventeen deep from x0-12 to x0-5.
    for x in x0 - 12 ..= x0 - 5 {
        for y in G ..< G + 17 do set_tile(&gs.world, x, y, .Air)
        set_tile(&gs.world, x, G + 17, .Stone)
    }
    _, hurts, _ := hero_dig_fall(&gs.world, {i32(x0 - 6), i32(G - 1)})
    testing.expect(t, hurts > ATTACK_DAMAGE * HERO_PASS_BLOWS, "the fall costs more than the blow")
    gs.player.pos = {f32(x0 - 4) + 0.1, f32(G) - PLAYER_H}
    go_test_give(gs, .Pickaxe, 1)
    b := fight_test_body(gs, .Builder, x0, G)
    gs.enemies.data[b].hp, gs.enemies.data[b].hp_max = 1000, 1000
    hp := gs.player.hp
    fled, fell := false, false
    fled_at, x_fled, x_after := 0, f32(0), f32(0)
    for f in 0 ..< 600 {
        exec_test_frames(link, gs, 1)
        if !fled && gs.hero.current == .Flee do fled_at, x_fled = f, gs.player.pos.x
        fled ||= gs.hero.current == .Flee
        if fled && f == fled_at + 24 do x_after = gs.player.pos.x
        fell ||= hero_feet_row(&gs.player) >= i32(G)
    }
    testing.expect(t, fled, "the hero fled")
    testing.expect(t, !fell, "it never went over the edge")
    testing.expectf(t, x_after - x_fled > 1, "it turned from the edge at once, not hovering there: %.2f tiles in 0.4 s", x_after - x_fled)
    testing.expectf(t, hp - gs.player.hp < hurts, "lost %d hp, the fall would cost %d", hp - gs.player.hp, hurts)
}

// Cornered at the ledge with a wall at its back: no way past.  With the Vargr
// on it at the ledge the fall, which leaves the hero standing, beats the
// mauling; never a fall that a blow on the way makes deadly, nor one into
// lava (that case starts at the ledge with the way already found shut, as
// lava keeps the hero off it).  With the Vargr held off by the wall, out of
// reach of the ledge, the hero spends no hp on a fall, and the way is marked
// shut until the hero is clear of it.  A wall the pick cannot work, or no
// pick, leaves the fall as the way out.  (The Vargr is held where it stands:
// a raider would dig through the wall.)
@(test)
hero_flee_takes_the_fall_when_the_way_past_is_shut :: proc(t: ^testing.T) {
    Case :: struct{vx: f32, lethal, lava, fall: bool, wall: Tile_Type, pick: bool}
    for c in ([?]Case{
        {-3.8, false, false, true,  .Rune_Stone, true},
        {-2.0, false, false, false, .Rune_Stone, true},
        {-3.8, true,  false, false, .Rune_Stone, true},
        {-3.8, false, true,  false, .Rune_Stone, true},
        {-3.8, false, false, true,  .Smelter,    true},   // a machine: the pick leaves it be
        {-3.8, false, false, true,  .Stone,      false},  // nothing to dig with
    }) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 12 ..= x0 - 5 {
            for y in G ..< G + 17 do set_tile(&gs.world, x, y, .Air)
            set_tile(&gs.world, x, G + 17, .Stone)
            if c.lava do set_tile(&gs.world, x, G + 16, .Lava)
        }
        for y in G - 10 ..< G do set_tile(&gs.world, x0 - 2, y, c.wall)  // the wall at its back
        if c.wall == .Smelter do for y in G - 10 ..< G - 1 do set_tile(&gs.world, x0 - 2, y, .Rune_Stone)  // a machine at the feet under rock
        _, hurts, _ := hero_dig_fall(&gs.world, {i32(x0 - 6), i32(G - 1)})
        testing.expect(t, hurts > WAVE_DAMAGE * HERO_PASS_BLOWS, "the fall costs more than a blow")
        gs.player.pos = {f32(x0 - 3) + 0.1, f32(G) - PLAYER_H}
        if c.lava do gs.player.pos.x, gs.hero.break_shut = f32(x0 - 4) + 0.1, true
        if c.pick do go_test_give(gs, .Pickaxe, 1)
        v := hero_test_vargr(gs, f32(x0) + c.vx, G, {})
        gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
        gs.player.hp_max, gs.player.hp = 20, 20
        if c.lethal do gs.player.hp = hurts + WAVE_DAMAGE  // standing after the fall, not after a blow too
        fell, fled, shut := false, false, false
        for _ in 0 ..< 60 * 15 {
            hero_test_tick(link, gs)
            fled ||= gs.hero.current == .Flee
            shut ||= gs.hero.break_shut
            fell ||= hero_feet_row(&gs.player) >= i32(G)
            if gs.player.dead || fell do break
        }
        testing.expectf(t, fled, "%v: the hero fled", c)
        testing.expectf(t, shut, "%v: the way was marked shut", c)
        testing.expectf(t, fell == c.fall, "%v: fell %v", c, fell)
        testing.expectf(t, !gs.player.dead, "%v: and lived", c)
        if fell do continue
        testing.expectf(t, gs.hero.turned_dir != 0, "%v: the shut way counts as a turned end", c)
        gs.enemies.data[v].pos.x = gs.player.pos.x + HERO_SAFE_CLEAR + 2
        for _ in 0 ..< 5 do hero_test_tick(link, gs)
        testing.expectf(t, !gs.hero.break_shut, "%v: clear of it, the way is not shut", c)
        testing.expectf(t, gs.hero.turned_dir == 0 && !gs.hero.drop_back, "%v: and the turn is forgotten", c)
        gs.hero.turned_dir, gs.hero.drop_back = 1, true
        despawn_enemy(gs, v)
        for _ in 0 ..< 2 do hero_test_tick(link, gs)
        testing.expectf(t, gs.hero.turned_dir == 0 && !gs.hero.drop_back, "%v: with no threat in mind, too", c)
    }
}

// Fleeing into a wall with the Vargr still off it: the hero keeps at the wall
// (a step or a dig may yet open it) rather than turn back toward the Vargr.
@(test)
hero_flee_into_a_wall_does_not_turn_back_at_a_threat_off_it :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    for y in G - 10 ..< G do set_tile(&gs.world, x0 + 2, y, .Stone)
    gs.player.pos = {f32(x0) + 0.5, f32(G) - PLAYER_H}
    v := hero_test_vargr(gs, f32(x0) - 4, G, {})
    gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
    fled := false
    min_x := gs.player.pos.x
    for _ in 0 ..< 60 * 3 {
        hero_test_tick(link, gs)
        fled ||= gs.hero.current == .Flee
        min_x = min(min_x, gs.player.pos.x)
    }
    testing.expect(t, fled, "the hero fled")
    testing.expectf(t, min_x > f32(x0) - 0.5, "it never turned back toward the Vargr: got to %.2f", min_x - f32(x0))
}

// Card 155.  An unarmed hero's goal waits while a hunter comes at it, and
// resumes when the hunter is gone.  It does not wait for a hero with a sword,
// for an enemy that is not coming, or for one coming from past
// HERO_THREAT_FAR (a goal starts under that one).
@(test)
hero_goal_waits_while_a_hunter_it_cannot_fight_comes :: proc(t: ^testing.T) {
    Case :: struct{armed: bool, vx: f32, vel: [2]f32, line: string, waits: bool}
    for c in ([?]Case{
        {false, 10, {-1, 0}, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":600}]}`, true},
        {true,  10, {-1, 0}, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":600}]}`, false},
        {false, 7,  {},      `{"cmd":"goals","add":[{"do":"act","move":"left","frames":600}]}`,  false},
        {false, 15, {-1, 0}, `{"cmd":"goals","add":[{"do":"act","move":"left","frames":600}]}`,  false},
    }) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        if c.armed do go_test_give(gs, .Sword, 1)
        v := hero_test_vargr(gs, f32(x0) + c.vx, G, c.vel)
        for _ in 0 ..< 30 do hero_test_tick(link, gs)  // noticed before the goal comes
        agent_handle_line(link, gs, c.line)
        for _ in 0 ..< 30 do hero_test_tick(link, gs)
        waiting := gs.hero.scores[.Work_Goal] == 0
        testing.expectf(t, waiting == c.waits, "%v: waiting %v (%v)", c, waiting, gs.hero.current)
        if c.waits do testing.expect(t, gs.hero.current != .Work_Goal && gs.hero.paused_goal != 0, "the goal is paused")
        if !c.waits do continue
        despawn_enemy(gs, v)
        for _ in 0 ..< 30 do hero_test_tick(link, gs)
        testing.expect_value(t, gs.hero.current, Hero_Behaviour.Work_Goal)
    }
}

// Card 155.  Fleeing into a dead end, a drop at its back and a wall ahead too
// high to jump, a hero with a pick digs through the wall and gets away, the
// pick taken in hand first; with no pick it is held there, and a hero with a
// wand to fight with keeps the wand in hand.  A wall the pick cannot take,
// stone it cannot cut or a structure, is never swung at.
@(test)
hero_cornered_with_a_pick_digs_out :: proc(t: ^testing.T) {
    Case :: struct{pick, wand, out: bool, wall, foot: Tile_Type}  // foot: the wall's lowest tile
    for c in ([?]Case{
        {true, false, true, .Stone, .Stone}, {false, false, false, .Stone, .Stone}, {true, true, false, .Stone, .Stone},
        {true, false, false, .Rune_Stone, .Rune_Stone}, {true, false, false, .Rune_Stone, .Smelter},
    }) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 12 ..= x0 - 1 do for y in G ..< G + 12 do set_tile(&gs.world, x, y, .Air)
        for y in G - 4 ..< G - 1 do set_tile(&gs.world, x0 + 1, y, c.wall)
        set_tile(&gs.world, x0 + 1, G - 1, c.foot)
        go_test_give(gs, .Stone_Block, 1)
        gs.player.inventory.selected = hero_item_slot(gs, .Stone_Block)  // the pick not in hand
        if c.pick do go_test_give(gs, .Pickaxe, 1)
        if c.wand do go_test_give(gs, .Fire_Wand, 1)
        hero_test_vargr(gs, f32(x0) - 3, G, {})
        out, fell, picked, swung := false, false, false, false
        for _ in 0 ..< 60 * 8 {
            hero_test_tick(link, gs)
            out    ||= gs.player.pos.x > f32(x0) + 2
            fell   ||= hero_feet_row(&gs.player) >= i32(G)
            picked ||= held_item(&gs.player) == .Pickaxe
            swung  ||= gs.agent.cmd.has_mine && gs.agent.cmd.mine.x == i32(x0 + 1)
        }
        testing.expectf(t, out == c.out, "%v: got out %v", c, out)
        testing.expectf(t, !fell, "%v: never over the edge", c)
        if c.wand do testing.expectf(t, !picked, "%v: the wand stays in hand", c)
        if c.wall == .Rune_Stone do testing.expectf(t, !swung, "%v: the pick never swung at a wall it cannot take", c)
    }
}

// Card 155.  Cornered at a drop by a Builder: the fall that costs more than
// one blow is refused while the flight has cost nothing, and taken once the
// blows already taken in this flight cost more than it.
@(test)
hero_flee_takes_the_fall_once_the_blows_cost_more :: proc(t: ^testing.T) {
    for mauled in ([2]bool{false, true}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 12 ..= x0 - 5 do for y in G ..< G + 9 do set_tile(&gs.world, x, y, .Air)
        _, hurts, _ := hero_dig_fall(&gs.world, {i32(x0 - 6), i32(G - 1)})
        testing.expect(t, hurts > ATTACK_DAMAGE * HERO_PASS_BLOWS && 2 * hurts < gs.player.hp, "the fall costs more than a blow, and leaves the hero standing after the blows")
        gs.player.pos = {f32(x0 - 1) + 0.1, f32(G) - PLAYER_H}
        b := fight_test_body(gs, .Builder, x0 + 3, G)
        gs.enemies.data[b].hp, gs.enemies.data[b].hp_max = 1000, 1000
        fell, hit := false, false
        for _ in 0 ..< 300 {
            hero_test_tick(link, gs)
            if mauled && !hit && hero_threat(&gs.hero) != nil do gs.player.hp, hit = gs.player.hp - hurts, true  // as if mauled that much as it turned to run
            fell ||= hero_feet_row(&gs.player) >= i32(G)
            if fell do break
        }
        testing.expectf(t, fell == mauled, "mauled %v: fell %v", mauled, fell)
    }
}

// Card 155.  Fleeing to a gap the jump arc clears, the hero jumps it as a
// player does and lands on the far side, and from there flees on foot again
// (a costly drop beyond is not walked off).  A chasm wider than a jump, or a
// block at head height over the take-off, the gap or the landing, turns it.
@(test)
hero_flee_jumps_a_gap :: proc(t: ^testing.T) {
    Case :: struct{wide, roof: int, over: bool}  // roof: column over which a block sits at head height, 0 none
    for c in ([?]Case{{2, 0, true}, {6, 0, false}, {2, 3, false}, {2, 5, false}, {2, 6, false}}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 + 4 ..< x0 + 4 + c.wide do for y in G ..< G + 12 do set_tile(&gs.world, x, y, .Air)
        for x in x0 + 13 ..< x0 + 18 do for y in G ..< G + 9 do set_tile(&gs.world, x, y, .Air)  // beyond, a drop the hero would not take
        if c.roof != 0 do set_tile(&gs.world, x0 + c.roof, G - 3, .Stone)
        hero_test_vargr(gs, f32(x0) - 3, G, {})
        gs.player.hp = 2
        over, fell := false, false
        for _ in 0 ..< 60 * 4 {
            hero_test_tick(link, gs)
            over ||= gs.player.pos.x > f32(x0 + 4 + c.wide) && hero_feet_row(&gs.player) == i32(G - 1) && gs.player.grounded
            fell ||= hero_feet_row(&gs.player) >= i32(G)
        }
        testing.expectf(t, over == c.over, "%v: over %v", c, over)
        testing.expectf(t, !fell, "%v: never down a drop", c)
    }
}

// Card 155.  A remembered safe spot that lies past the threat is never run to:
// the hero flees away from it.
@(test)
hero_flee_never_runs_back_past_the_threat_to_a_safe_spot :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    hero_test_vargr(gs, f32(x0) - 4, G, {})
    gs.hero.senses.safe[0], gs.hero.senses.n_safe, gs.hero.senses.safe_next = {i32(x0 - 16), i32(G - 1)}, 1, 1
    min_x := gs.player.pos.x
    fled := false
    for _ in 0 ..< 90 {
        hero_test_tick(link, gs)
        fled ||= gs.hero.current == .Flee
        min_x = min(min_x, gs.player.pos.x)
    }
    testing.expect(t, fled, "the hero fled")
    testing.expectf(t, min_x > f32(x0) - 0.5, "it never ran back toward the Vargr: got to %.2f", min_x - f32(x0))
}

// A goal walking at a drop with a Vargr on it from behind: the 0.4 s look at
// the edge gives way the moment the Vargr would take over from the goal.
@(test)
hero_ledge_look_waits_for_a_threat :: proc(t: ^testing.T) {
    for armed in ([2]bool{false, true}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 12 ..= x0 - 5 {
            for y in G ..< G + 10 do set_tile(&gs.world, x, y, .Air)
            set_tile(&gs.world, x, G + 10, .Stone)
        }
        if armed do go_test_give(gs, .Sword, 1)
        gs.player.pos = {f32(x0) - 1, f32(G) - PLAYER_H}
        v := hero_test_vargr(gs, f32(x0) + 3.1, G, {})
        gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
        agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"left","frames":120}]}`)
        looked_pressed, answered := 0, false
        for _ in 0 ..< 120 {
            exec_test_frames(link, gs, 1)
            b := &gs.hero
            pressed := max(b.scores[.Fight], b.scores[.Flee]) > HERO_GOAL_SCORE + HERO_SWITCH_MARGIN
            if b.current == .Avoid_Ledge && pressed do looked_pressed += 1
            answered ||= b.current == (.Fight if armed else .Flee)
        }
        // At most the tick the edge comes up, while the goal is under
        // HERO_MIN_HOLD_S and no rival may take over from it yet.
        testing.expectf(t, looked_pressed <= 1, "armed %v: %d frames looking at the edge with the Vargr on it", armed, looked_pressed)
        testing.expect(t, answered)
        testing.expect(t, hero_feet_row(&gs.player) < i32(G), "not over the edge")
    }
}

// By kind, the nearest in view: past the view's edge is not in sight.  By
// slot, the fight ends when the slot is given up, even if another kind fills it.
@(test)
hero_fight_picks_its_target :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    go_test_give(gs, .Fire_Wand, 1)
    gs.player.mana = gs.player.mana_max
    near := fight_test_body(gs, .Ember_Beetle, x0 + 4, G)
    far := fight_test_body(gs, .Ember_Beetle, x0 + 9, G)
    gs.enemies.data[far].hp, gs.enemies.data[far].hp_max = 1000, 1000
    frog := fight_test_body(gs, .Pond_Frog, x0 + AGENT_VIEW_W / 2 + 1, G)
    id, _ := fight_test_run(link, gs, `{"do":"fight","kind":"Pond_Frog"}`, frog, x0, G, 30)
    work_test_expect_failed(t, link, gs, id, "no_target")
    id, _ = fight_test_run(link, gs, `{"do":"fight","kind":"Ember_Beetle"}`, near, x0, G, 1800)
    work_test_expect_done(t, link, gs, id)
    testing.expect(t, !gs.enemies.active[near], "the near one fought")
    testing.expect(t, gs.enemies.active[far], "the far one left")
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"fight","slot":%d}}]}}`, far))
    id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
    exec_test_frames(link, gs, 5)
    despawn_enemy(gs, far)
    fight_test_body(gs, .Mole, x0 - 10, G)  // into the dead beetle's lower slot
    testing.expect_value(t, hero_test_vargr(gs, f32(x0) + 9.1, G, {}), far)
    gs.enemies.data[far].hp, gs.enemies.data[far].hp_max = 1000, 1000
    exec_test_frames(link, gs, 3)
    work_test_expect_done(t, link, gs, id)
}

// With the wand, a Vargr nearer than HERO_KITE_TILES is backed off from as it
// is shot: by a fight goal and by the brain's own fight.
@(test)
hero_kites_with_the_wand :: proc(t: ^testing.T) {
    for goal in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 50 ..< x0 - 18 do for y in G - 10 ..= G + 12 do set_tile(&gs.world, x, y, .Air if y < G else .Stone)
        go_test_give(gs, .Fire_Wand, 1)
        gs.player.mana = gs.player.mana_max
        link.goals.reflexes_off = {.Fight_Back}
        v := hero_test_vargr(gs, f32(x0) + 2.6, G, {})
        gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
        if goal do agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"fight","kind":"Vargr"}]}`)
        x := gs.player.pos.x
        shots := 0
        for _ in 0 ..< 60 {
            exec_test_frames(link, gs, 1)
            if gs.input.mine do shots += 1
        }
        testing.expectf(t, shots > 0, "goal %v: shot", goal)
        testing.expectf(t, x - gs.player.pos.x > 2, "goal %v: backed off %.1f", goal, x - gs.player.pos.x)
    }
}

// Out of mana with only the wand: no shot, no fight from the brain, and a
// fight goal keeps away and waits for the mana rather than giving up.  (The
// brain flees, as card 149 has it.)
@(test)
hero_with_an_empty_wand_keeps_away :: proc(t: ^testing.T) {
    for goal in ([2]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 50 ..< x0 - 18 do for y in G - 10 ..= G + 12 do set_tile(&gs.world, x, y, .Air if y < G else .Stone)
        go_test_give(gs, .Fire_Wand, 1)
        gs.player.mana, gs.player.mana_regen = 0, 0
        link.goals.reflexes_off = {.Fight_Back}
        v := hero_test_vargr(gs, f32(x0) + 3.1, G, {})
        gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
        id := -1
        if goal {
            agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"fight","kind":"Vargr"}]}`)
            id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
        }
        shots, fought, away := 0, 0, f32(0)
        frames := int((HERO_FIGHT_WAIT_S + 1) * 60)
        for _ in 0 ..< frames {
            exec_test_frames(link, gs, 1)
            if gs.input.mine do shots += 1
            if gs.hero.current == .Fight do fought += 1
            away += abs(gs.enemies.data[v].pos.x - gs.player.pos.x) / f32(frames)
        }
        testing.expectf(t, shots == 0, "goal %v: %d shots with no mana", goal, shots)
        testing.expectf(t, fought == 0, "goal %v: %d frames fighting unarmed", goal, fought)
        if goal {
            testing.expectf(t, away > 3, "kept %.1f away on the mean", away)
            status, reason := go_test_status(link, gs, id)
            testing.expectf(t, status == "running", "%s %s", status, reason)
        }
    }
}

// The stand a fight walks to is on the target's row when one is in range,
// and the hero's centre there is where the orb leaves from.
@(test)
hero_fight_stands_on_the_targets_row :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    for x in x0 + 6 ..= x0 + 12 do set_tile(&gs.world, x, G - 3, .Stone)  // a shelf
    go_test_give(gs, .Fire_Wand, 1)
    gs.player.mana = gs.player.mana_max
    e := fight_test_body(gs, .Ember_Beetle, x0 + 6, G - 3)  // at the edge: the ground below sees it too
    f := Hero_Fight{target = e, target_kind = .Ember_Beetle}
    sw, wa := hero_blow_from(gs, {i32(x0 + 1), i32(G - 1)}, hero_fight_centre({i32(x0 + 1), i32(G - 1)}), e)
    testing.expect(t, wa && !sw, "a shot lands from the ground nearer the hero")
    s, ok := hero_fight_stand(gs, &f)
    testing.expect(t, ok)
    testing.expect_value(t, s.y, i32(G - 4))
    p := &gs.player
    hc := hero_fight_centre(player_tile(p))
    testing.expectf(t, abs(hc.x - (p.pos.x + PLAYER_W * 0.5)) < 0.15 && abs(hc.y - (p.pos.y + PLAYER_H * 0.5)) < 0.15, "%v", hc)
}

// The weapon in hand is the one fought with: of two swords, no swap.
@(test)
hero_fights_with_the_sword_in_hand :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    gs.player.inventory.slots[0] = {item = .Sword, count = 1}
    gs.player.inventory.slots[1] = {item = .Sword, count = 1}
    gs.player.inventory.selected = 1
    v := hero_test_vargr(gs, f32(x0) + 1.6, G, {})
    gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
    swaps, swings := 0, 0
    for _ in 0 ..< 90 {
        hero_test_tick(link, gs)
        if gs.agent.cmd.verb == .Select do swaps += 1
        if gs.input.mine do swings += 1
    }
    testing.expect(t, swings > 0)
    testing.expect_value(t, swaps, 0)
}

// fight_back: struck by a Vargr, the hero strikes back at that Vargr, not at
// a frog nearer it or a Vargr out of reach; for HERO_FIGHT_BACK_S, then no
// more; never with a window open, and a potion due goes first.
@(test)
hero_fight_back_answers_the_one_that_hurt_it :: proc(t: ^testing.T) {
    Case :: enum { Plain, Window, Potion }
    for c in Case {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        // Boxed in: the hero cannot run, the Vargr stays in reach.
        for y in G - 3 ..< G do for x in ([2]int{x0 - 1, x0 + 3}) do set_tile(&gs.world, x, y, .Stone)
        gs.player.inventory.slots[0] = {item = .Sword, count = 1}
        gs.player.hp_max, gs.player.hp = 100, 40
        if c == .Potion {
            gs.player.inventory.slots[1] = {item = .Potion_Health, count = 1}
            gs.player.inventory.selected = 1
            low := HERO_LOW_HP_FRAC
            gs.player.hp = int(low * 100) + 1  // a bite takes it under the potion line
        }
        v := hero_test_vargr(gs, f32(x0) + 1.6, G, {})
        frog := fight_test_body(gs, .Pond_Frog, x0, G)  // nearer than the Vargr
        far := hero_test_vargr(gs, f32(x0) + 9.1, G, {})
        for i in ([3]int{v, frog, far}) do gs.enemies.data[i].hp, gs.enemies.data[i].hp_max = 1000, 1000
        hp0 := gs.player.hp
        for f := 0; f < 300 && gs.player.hp == hp0; f += 1 do exec_test_frames(link, gs, 1)
        testing.expectf(t, gs.hurt_by == enemy_kind_names[.Vargr], "%v: bitten (%s)", c, gs.hurt_by)
        if c == .Window do gs.ui.show_inventory = true
        if c == .Potion {
            hero_test_tick(link, gs)
            testing.expect_value(t, gs.agent.cmd.verb, Agent_Verb.Equip)  // the potion, not a swap to the sword
        }
        // Everyone held where they stand from here: no more bites.
        early, late, off := 0, 0, 0
        for k in 0 ..< int(HERO_FIGHT_BACK_S * 60) * 2 {
            open := agent_window_open(gs)
            hero_test_tick(link, gs)
            if !gs.input.mine do continue
            if c == .Window && open do early += 1000
            if gs.agent.cmd.mine != builder_tile(&gs.enemies.data[v]) do off += 1
            if f32(k) < HERO_FIGHT_BACK_S * 60 - 2 do early += 1
            else if f32(k) > HERO_FIGHT_BACK_S * 60 + 2 do late += 1
        }
        switch c {
        case .Plain:
            testing.expectf(t, early > 0 && late == 0 && off == 0, "early %d late %d off %d", early, late, off)
        case .Window:
            testing.expectf(t, early < 1000, "a strike with the window open")
        case .Potion:
            testing.expect_value(t, inventory_count(&gs.player.inventory, .Potion_Health), 0)
        }
    }
}

// Fleeing with only the wand, the hero shoots back as it runs.
@(test)
hero_flees_shooting :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    for x in x0 - 50 ..< x0 - 18 do for y in G - 10 ..= G + 12 do set_tile(&gs.world, x, y, .Air if y < G else .Stone)
    go_test_give(gs, .Fire_Wand, 1)
    gs.player.mana = gs.player.mana_max
    gs.player.hp = gs.player.hp_max / 5
    link.goals.reflexes_off = {.Fight_Back}
    v := hero_test_vargr(gs, f32(x0) + 4.1, G, {})
    gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
    fled, shots := 0, 0
    for _ in 0 ..< 90 {
        exec_test_frames(link, gs, 1)
        if gs.hero.current == .Flee {
            fled += 1
            if gs.input.mine do shots += 1
        }
    }
    testing.expect(t, fled > 0, "it fled")
    testing.expectf(t, shots > 0, "%d shots as it fled", shots)
}

// Card 156: a Sky Egg heals under the line as a potion does; a potion held too
// goes first, in hero_heal_items' order.
@(test)
hero_eats_a_sky_egg_under_the_line :: proc(t: ^testing.T) {
    for both in ([]bool{false, true}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        hero_test_arena(gs)
        go_test_give(gs, .Sky_Egg, 1)
        if both do go_test_give(gs, .Potion_Health, 1)
        exec_test_frames(link, gs, 5)
        gs.player.hp = 1
        exec_test_frames(link, gs, 3)
        testing.expectf(t, gs.player.hp > 1, "potion too %v: it healed", both)
        testing.expect_value(t, inventory_count(&gs.player.inventory, .Sky_Egg), 1 if both else 0)
        testing.expect_value(t, inventory_count(&gs.player.inventory, .Potion_Health), 0)
    }
}

// Card 156: on a mesa between two drops, each dearer than a blow, a Vargr
// coming on: the hero turns back from the first drop at most once, and takes
// the cheaper of the two, going back for it when the second is dearer.  No
// running back and forth past the Vargr.
@(test)
hero_with_drops_both_ways_takes_the_cheaper_once :: proc(t: ^testing.T) {
    // dl, dr: the drops' depths; lava: a burn under the left one; left: the one
    // to take; turns: the most times the hero may turn back.
    Case :: struct{dl, dr: int, lava: bool, left: bool, turns: int}
    for c in ([?]Case{
        {12, 9,  false, false, 1},  // the first, left, dearer: on to the right
        {9,  12, false, true,  2},  // the first cheaper: back to it, once
        {9,  9,  false, false, 1},  // as dear: the one it is at
        {13, 16, true,  false, 1},  // a burn costs more than any fall
    }) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        exec_test_frames(link, gs, 10)
        x0, G := hero_test_arena(gs)
        for x in x0 - 14 ..= x0 - 5 do for y in G ..< G + c.dl do set_tile(&gs.world, x, y, .Air)
        for x in x0 + 5 ..= x0 + 14 do for y in G ..< G + c.dr do set_tile(&gs.world, x, y, .Air)
        if c.lava do for x in x0 - 14 ..= x0 - 5 do set_tile(&gs.world, x, G + c.dl - 1, .Lava)
        hl := hero_column(&gs.world, x0 - 5, G - 1).hurts
        hr := hero_column(&gs.world, x0 + 5, G - 1).hurts
        testing.expectf(t, min(hl, hr) > WAVE_DAMAGE * HERO_PASS_BLOWS, "%v: drops of %d and %d, both dearer than a blow", c, hl, hr)
        if c.lava do testing.expectf(t, hero_column(&gs.world, x0 - 5, G - 1).hazard && hl < hr, "%v: a burn under the cheaper fall", c)
        gs.player.hp_max, gs.player.hp = 20, 20
        gs.player.pos = {f32(x0 - 3) + 0.1, f32(G) - PLAYER_H}
        v := hero_test_vargr(gs, f32(x0) + 2, G, {})
        gs.enemies.data[v].hp, gs.enemies.data[v].hp_max = 1000, 1000
        turns, last := 0, i8(0)
        for _ in 0 ..< 60 * 20 {
            hero_test_tick(link, gs)
            if gs.player.dead || hero_feet_row(&gs.player) >= i32(G) do break
            d := i8(0)
            if gs.input.move_left do d = -1
            if gs.input.move_right do d = 1
            if d != 0 && last != 0 && d != last && gs.player.grounded do turns += 1
            if d != 0 do last = d
        }
        testing.expectf(t, !gs.player.dead, "%v: the hero lived", c)
        testing.expectf(t, hero_feet_row(&gs.player) >= i32(G), "%v: it took a drop", c)
        testing.expectf(t, (gs.player.pos.x < f32(x0)) == c.left, "%v: the cheaper one (%d left, %d right), at x %.1f", c, hl, hr, gs.player.pos.x - f32(x0))
        testing.expectf(t, turns <= c.turns, "%v: turned %d times", c, turns)
    }
}

// Card 156: the flee's gap jump only leaves the ground.  Held a hair over the
// take-off, off its feet, the hero starts no leap: in the air one carried it
// on over drops it could not clear (seed 1).
@(test)
hero_flee_starts_no_gap_jump_in_the_air :: proc(t: ^testing.T) {
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    exec_test_frames(link, gs, 10)
    x0, G := hero_test_arena(gs)
    for x in x0 + 4 ..< x0 + 6 do for y in G ..< G + 12 do set_tile(&gs.world, x, y, .Air)
    hero_test_vargr(gs, f32(x0) - 3, G, {})
    gs.player.hp = 2
    fled := false
    for _ in 0 ..< 60 {
        gs.player.pos = {f32(x0 + 3) + 0.2, f32(G) - PLAYER_H - 0.3}
        gs.player.vel, gs.player.grounded = {}, false
        hero_test_tick(link, gs)
        fled ||= gs.hero.current == .Flee
        testing.expect_value(t, gs.hero.leap_dir, 0)
    }
    testing.expect(t, fled, "the hero fled")
    _, _, ok := hero_gap_landing(&gs.world, {i32(x0 + 3), i32(G - 1)}, 1)
    testing.expect(t, ok, "from the ground the gap is jumpable")
}

// Card 156: a work dig yields to a hunter under HERO_LOW_HP_FRAC, sword or no:
// the hunted pause covers an armed hero then.  With its health up the armed
// hero is not hunted, and does not flee from the dig.
@(test)
hero_low_on_health_leaves_a_dig_even_armed :: proc(t: ^testing.T) {
    for low in ([]bool{true, false}) {
        gs, link := exec_test_world()
        defer free(gs)
        defer free(link)
        x0, G := hero_test_arena(gs)
        exec_test_frames(link, gs, 10)
        go_test_give(gs, .Pickaxe, 1)
        go_test_give(gs, .Sword, 1)
        for y in G - 3 ..< G do set_tile(&gs.world, x0 + 1, y, .Stone)
        if low do gs.player.hp = max(1, gs.player.hp_max / 5)
        agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"mine","tile":[%d,%d]}}]}}`, x0 + 1, G - 1))
        for k := 0; k < 300 && !gs.hero.dug; k += 1 do hero_test_tick(link, gs)
        testing.expectf(t, gs.hero.dug, "low %v: the goal is digging", low)
        hero_test_vargr(gs, f32(x0) - 5, G, {RAIDER_SPEED, 0})
        fled := false
        for _ in 0 ..< 30 {
            hero_test_tick(link, gs)
            fled ||= gs.hero.current == .Flee && link.goals.slots[0].status == .Running
        }
        testing.expectf(t, fled == low, "low %v: fled %v", low, fled)
        testing.expectf(t, hero_test_count(exec_test_pushed(link), `"reason":"flee"`) == (1 if low else 0), "low %v: one pause, held: %s", low, exec_test_pushed(link))
        if !low {
            // Health up, the armed hero is no quarry: the dig goes on, unpaused.
            testing.expectf(t, !strings.contains(exec_test_pushed(link), `"goal_paused"`), "low false: no pause at all: %s", exec_test_pushed(link))
            testing.expect_value(t, gs.hero.current, Hero_Behaviour.Work_Goal)
            testing.expect_value(t, link.goals.slots[0].status, Agent_Goal_Status.Running)
        }
    }
}

// ─── Crew goals (card 148) ───

// A golem in slot, standing dx tiles from the hero on the arena's floor.
@(private="file")
crew_test_golem :: proc(gs: ^Game_State, slot: int, dx: int, G: int, status := Golem_Status.Deployed, mode := Golem_Mode.Gather) -> ^Golem {
    x := int(gs.player.pos.x) + dx
    g := &gs.golems.data[slot]
    g^ = {status = status, hp = 0 if status == .Broken else GOLEM_HP, mode = mode, facing = 1, level = gs.level_index,
        pos = {f32(x) + (1 - GOLEM_W) * 0.5, f32(G) - GOLEM_H}, grounded = true, project_cell = -1}
    return g
}

// The hero on the arena with a command wand in the bag, not in hand.
@(private="file")
crew_test_world :: proc() -> (gs: ^Game_State, link: ^Agent_Link, x0, G: int) {
    gs, link = exec_test_world()
    exec_test_frames(link, gs, 10)
    x0, G = hero_test_arena(gs)
    go_test_give(gs, .Command_Wand, 1)
    gs.player.inventory.selected = -1
    return
}

// Card 148: crew_mode works the roster as a person does (the wand taken in
// hand, the window opened, looked at, the golem's button clicked where a mouse
// would click it, the window shut) and sets that one golem's mode.
@(test)
hero_crew_mode_sets_one_golems_mode :: proc(t: ^testing.T) {
    gs, link, _, G := crew_test_world()
    defer free(gs)
    defer free(link)
    crew_test_golem(gs, 0, 3, G)
    crew_test_golem(gs, 2, -3, G)
    watch: Work_Watch
    id := work_test_run(t, link, gs, `{"do":"crew_mode","golem":2,"mode":"Fight"}`, 600, &watch)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, gs.golems.data[2].mode, Golem_Mode.Fight)
    testing.expect_value(t, gs.golems.data[0].mode, Golem_Mode.Gather)
    testing.expect(t, is_command_wand(held_item(&gs.player)), "the wand in hand")
    testing.expect_value(t, watch.gestures, 1)
    testing.expect(t, watch.open_frames > 0 && !gs.ui.show_golem_roster, "the roster opened, and is shut")
}

// Card 148: the roster has no reach, but a cracked golem's PICK UP does.
// Each crew goal against a working golem far off, one in reach, a cracked one
// far off, and one far off that cracks mid-goal (a fight shuts the roster as
// it does): whether the hero walked, how the goal ended, and the order the
// golem got.  Only the cracked golem's PICK UP walks; an order to a golem far
// off is given from where the hero stands, as a person gives it, and a call or
// mode order to one cracked under it fails dimmed where the hero stands.
@(test)
hero_crew_walks_only_to_a_cracked_golems_pickup :: proc(t: ^testing.T) {
    Golem_At :: enum { Far, Near, Cracked, Cracks }
    Case :: struct{line: string, at: Golem_At, walks: bool, why: string}
    for c in ([?]Case{
        {`{"do":"crew_call","golem":0}`,                  .Far,     false, ""},
        {`{"do":"crew_call","golem":0}`,                  .Near,    false, ""},
        {`{"do":"crew_call","golem":0}`,                  .Cracked, false, "blocked: golem 0 is cracked"},
        {`{"do":"crew_call","golem":0}`,                  .Cracks,  false, "dimmed"},
        {`{"do":"crew_mode","golem":0,"mode":"Build"}`,   .Far,     false, ""},
        {`{"do":"crew_mode","golem":0,"mode":"Build"}`,   .Near,    false, ""},
        {`{"do":"crew_mode","golem":0,"mode":"Build"}`,   .Cracked, false, "blocked: golem 0 is cracked"},
        {`{"do":"crew_mode","golem":0,"mode":"Build"}`,   .Cracks,  false, "dimmed"},
        {`{"do":"crew_pickup","golem":0}`,                .Far,     false, ""},
        {`{"do":"crew_pickup","golem":0}`,                .Near,    false, ""},
        {`{"do":"crew_pickup","golem":0}`,                .Cracked, true,  ""},
    }) {
        gs, link, _, G := crew_test_world()
        defer free(gs)
        defer free(link)
        dxs := [Golem_At]int{.Far = 16, .Near = 2, .Cracked = PLAYER_REACH + 4, .Cracks = 16}
        dx := dxs[c.at]
        g := crew_test_golem(gs, 0, dx, G, .Broken if c.at == .Cracked else .Deployed)
        testing.expectf(t, (chebyshev(golem_tile(g), player_tile(&gs.player)) <= PLAYER_REACH) == (c.at == .Near), "%v: reach as set", c)
        x := gs.player.pos.x
        id: int
        if c.at == .Cracks {
            // The roster up and looked at, then shut by a fight as the golem cracks.
            agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, c.line))
            id = int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
            for k := 0; k < 600 && !gs.ui.show_golem_roster; k += 1 do exec_test_frames(link, gs, 1)
            testing.expectf(t, gs.ui.show_golem_roster, "%v: the roster opened", c)
            exec_test_frames(link, gs, 3)
            gs.ui.show_golem_roster, g.status, g.hp = false, .Broken, 0
            for k := 0; k < 1200 && (link.goals.slots[0].status == .Queued || link.goals.slots[0].status == .Running); k += 1 do exec_test_frames(link, gs, 1)
        } else {
            id = work_test_run(t, link, gs, c.line, 1200)
        }
        walked := abs(gs.player.pos.x - x) >= 1
        testing.expectf(t, walked == c.walks, "%v: walked %v (%.2f to %.2f)", c, walked, x, gs.player.pos.x)
        if c.why != "" {
            status, reason := go_test_status(link, gs, id)
            testing.expectf(t, status == "failed" && strings.contains(reason, c.why), "%v: want failed %s, got %s %s", c, c.why, status, reason)
            testing.expectf(t, gs.golem_calls[0] == .None && g.status == .Broken && g.mode == .Gather, "%v: no order given", c)
            continue
        }
        work_test_expect_done(t, link, gs, id)
        switch {
        case strings.contains(c.line, "call"):
            testing.expectf(t, gs.golem_calls[0] == .Come || gs.golem_calls[0] == .Waiting, "%v: called: %v", c, gs.golem_calls[0])
        case strings.contains(c.line, "mode"):
            testing.expectf(t, g.mode == .Build && gs.golem_calls[0] == .None, "%v: in Build, not called: %v %v", c, g.mode, gs.golem_calls[0])
        case c.at == .Far:
            // Picked up from afar: it walks back and goes into the wand there.
            testing.expectf(t, gs.golem_calls[0] == .Come_Pickup || g.status == .Carried, "%v: told to come and be picked up: %v %v", c, gs.golem_calls[0], g.status)
        case:
            testing.expectf(t, g.status == .Carried, "%v: in the wand: %v", c, g.status)
        }
    }
}

// Card 148: CALL brings the golem; PICK UP takes a cracked golem back into the
// wand (to repair at a Clay Hearth), the hero walking into reach of it first:
// over the API a cracked golem no longer holds the basic wand's one slot.
@(test)
hero_crew_call_and_pickup :: proc(t: ^testing.T) {
    {
        gs, link, _, G := crew_test_world()
        defer free(gs)
        defer free(link)
        crew_test_golem(gs, 0, 5, G)
        id := work_test_run(t, link, gs, `{"do":"crew_call","golem":0}`, 600)
        work_test_expect_done(t, link, gs, id)
        testing.expect(t, gs.golem_calls[0] != .None, "the golem was called")
    }
    gs, link, x0, G := crew_test_world()
    defer free(gs)
    defer free(link)
    crew_test_golem(gs, 0, PLAYER_REACH + 4, G, .Broken)
    testing.expect(t, !golem_roster_button_enabled(gs, 0, .Pickup), "out of reach, PICK UP is dimmed")
    id := work_test_run(t, link, gs, `{"do":"crew_pickup","golem":0}`, 1200)
    work_test_expect_done(t, link, gs, id)
    testing.expect_value(t, gs.golems.data[0].status, Golem_Status.Carried)
    testing.expect(t, gs.player.pos.x > f32(x0) + 2, "it walked into reach")
    testing.expectf(t, gs.player.pos.x < f32(x0 + PLAYER_REACH + 4 - BENCH_RANGE - 1), "PICK UP's reach, not a bench's: stopped at %.1f", gs.player.pos.x - f32(x0))
}

// Card 148: each crew goal says why it cannot run, as the roster would refuse.
@(test)
hero_crew_goals_say_why_not :: proc(t: ^testing.T) {
    Case :: struct{line: string, status: Golem_Status, wand, away: bool, why: string}
    for c in ([?]Case{
        {`{"do":"crew_call","golem":0}`, .Deployed, false, false, "no_item: no command wand"},
        {`{"do":"crew_call","golem":1}`, .Deployed, true, false, "no_item: no golem in slot 1"},
        {`{"do":"crew_call","golem":0}`, .Carried, true, false, "blocked: golem 0 rides in the wand"},
        {`{"do":"crew_call","golem":0}`, .Deployed, true, true, "out_of_reach: golem 0 is on level"},
        {`{"do":"crew_mode","golem":0,"mode":"Build"}`, .Broken, true, false, "blocked: golem 0 is cracked"},
        {`{"do":"crew_mode","golem":0,"mode":"Gather"}`, .Deployed, true, false, "blocked: golem 0 is in Gather already"},
    }) {
        gs, link, _, G := crew_test_world()
        defer free(gs)
        defer free(link)
        if !c.wand do gs.player.inventory.slots[hero_item_slot(gs, .Command_Wand)] = {}
        g := crew_test_golem(gs, 0, 3, G, c.status)
        if c.away do g.level = (gs.level_index + 1) % NUM_LEVELS
        id := work_test_run(t, link, gs, c.line, 60)
        work_test_expect_failed(t, link, gs, id, c.why)
    }
    {
        // Cracked while the roster is up: CALL is dimmed, so no click, and the
        // goal says why rather than claim it called.
        gs, link, _, G := crew_test_world()
        defer free(gs)
        defer free(link)
        g := crew_test_golem(gs, 0, 3, G)
        agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"crew_call","golem":0}]}`)
        id := int(exec_test_reply(link)["ids"].(json.Array)[0].(json.Float))
        for k := 0; k < 120 && !gs.ui.show_golem_roster; k += 1 do exec_test_frames(link, gs, 1)
        g.status, g.hp = .Broken, 0
        for k := 0; k < 300 && agent_goals_busy(&link.goals); k += 1 do exec_test_frames(link, gs, 1)
        work_test_expect_failed(t, link, gs, id, "blocked: golem 0's CALL is dimmed")
        testing.expect_value(t, gs.golem_calls[0], Golem_Call.None)
    }
    {
        // The roster's press itself: a dimmed button pushes nothing, as a
        // mouse click on it does nothing.
        gs, link, _, G := crew_test_world()
        defer free(gs)
        defer free(link)
        crew_test_golem(gs, 0, 3, G, .Broken)
        n := gs.events.size
        golem_roster_press(gs, 0, .Call)
        testing.expect_value(t, gs.events.size, n)
        golem_roster_press(gs, 0, .Pickup)  // in reach, the one live button
        testing.expect_value(t, gs.events.size, n + 1)
    }
    gs, link := exec_test_world()
    defer free(gs)
    defer free(link)
    for line in ([]string{`{"do":"crew_call"}`, `{"do":"crew_pickup","golem":99}`, `{"do":"crew_mode","golem":0,"mode":"Dance"}`}) {
        agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"goals","add":[%s]}}`, line))
        testing.expect(t, strings.contains(string(link.out[:link.out_len]), "error"), line)
    }
}
