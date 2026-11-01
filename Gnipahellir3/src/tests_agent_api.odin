package game

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"

@(private="file")
agent_test_reply :: proc(link: ^Agent_Link) -> string {
    return string(link.out[:link.out_len])
}

// A world with the title screens past, standing on the surface.
@(private="file")
agent_test_world :: proc() -> (gs: ^Game_State, link: ^Agent_Link) {
    gs = new(Game_State)
    link = new(Agent_Link)
    game_state_init(gs)
    gs.ui.show_title = false
    gs.ui.show_charselect = false
    gs.player.pos = SURFACE_HOME_POS
    link.connected = true  // no socket: agent_send is only reached through agent_pump
    return
}

@(private="file")
agent_test_run_act :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
    agent_handle_line(link, gs, line)
    for link.frames_left > 0 {
        tick := agent_drive(link, gs)
        if tick {
            agent_input(gs)
            process_events(gs)
            eq_clear(&gs.events)
            gs.frame += 1
            link.frames_left -= 1
        }
    }
    link.cmd = {}
}

@(test)
agent_state_reply_is_valid_json_and_describes_the_world :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"state","x":0,"y":0,"w":192,"h":108}`)
    reply := agent_test_reply(link)
    value, err := json.parse_string(reply, allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)

    root := value.(json.Object)
    testing.expect(t, root["ok"].(json.Boolean))
    testing.expect_value(t, root["screen"].(json.String), "play")
    view := root["view"].(json.Object)
    rows := view["rows"].(json.Array)
    testing.expect_value(t, len(rows), GRID_H)
    testing.expect_value(t, len(rows[0].(json.String)), GRID_W)

    // Every character in the rows is explained, and means the tile it stands on.
    legend := view["legend"].(json.Object)
    ch := rows[int(SURFACE_Y) + 2].(json.String)[10:11]
    testing.expect_value(t, legend[ch].(json.String), fmt.tprint(get_tile(&gs.world, 10, int(SURFACE_Y) + 2)))
    testing.expect(t, len(legend) >= 2)
}

@(test)
agent_view_is_clamped_to_the_map :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"state","x":-50,"y":9000,"w":100000,"h":-3}`)
    value, err := json.parse_string(agent_test_reply(link), allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    view := value.(json.Object)["view"].(json.Object)
    testing.expect_value(t, view["x"].(json.Float), 0)
    testing.expect_value(t, view["y"].(json.Float), GRID_H - 1)
    testing.expect_value(t, view["h"].(json.Float), 1)
}

@(test)
agent_bad_requests_are_refused_and_change_nothing :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    bad := [?]string{
        `not json`, `[1,2]`, `{"cmd":"fly"}`,
        `{"cmd":"act","frames":0}`, `{"cmd":"act","frames":601}`,
        `{"cmd":"act","move":"up"}`,
        `{"cmd":"act","mine":[9999,0]}`, `{"cmd":"act","mine":"here"}`,
        `{"cmd":"act","mine":[1,1],"place":[1,2]}`,
        `{"cmd":"act","select":99}`, `{"cmd":"act","equip":-1}`,
        `{"cmd":"act","craft":"No_Such_Item"}`,
        `{"cmd":"act","feed":0}`, `{"cmd":"act","take":0}`,
        `{"cmd":"realtime"}`,
    }
    for line in bad {
        agent_handle_line(link, gs, line)
        testing.expectf(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`), "%s -> %s", line, agent_test_reply(link))
        testing.expect_value(t, link.frames_left, 0)
    }
}

@(test)
agent_game_waits_until_it_is_told_to_act :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    testing.expect(t, !agent_drive(link, gs), "idle client must hold the sim")
    testing.expect(t, gs.agent.driving, "the keyboard must stay out while connected")
    testing.expect_value(t, gs.delta_time, AGENT_STEP)

    agent_handle_line(link, gs, `{"cmd":"act","frames":3}`)
    testing.expect_value(t, link.out_len, 0)  // no reply until the frames have run
    for i in 0 ..< 3 {
        testing.expect(t, agent_drive(link, gs))
        testing.expect_value(t, gs.agent.first, i == 0)
        agent_after_tick(link, gs)
    }
    testing.expect(t, link.out_len > 0, "the act answers when it has run out")
    testing.expect(t, !agent_drive(link, gs))

    agent_handle_line(link, gs, `{"cmd":"realtime","on":true}`)
    testing.expect(t, agent_drive(link, gs), "realtime keeps ticking")
}

@(test)
agent_held_input_holds_and_one_shots_fire_once :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act","move":"right","jump":true,"frames":2}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect(t, gs.input.move_right)
    testing.expect(t, gs.input.jump)

    agent_drive(link, gs)
    agent_input(gs)
    testing.expect(t, gs.input.move_right, "move is held")
    testing.expect(t, !gs.input.jump, "a jump is a press")
    testing.expect(t, gs.input.fly_up, "flying is a hold")
}

@(test)
agent_cursor_lands_on_the_tile_it_names :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act","mine":[20,70]}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.input.mouse_tile, [2]i32{20, 70})
    testing.expect_value(t, i32(gs.input.mouse_world.x) / CELL_SIZE, 20)
    testing.expect_value(t, i32(gs.input.mouse_world.y) / CELL_SIZE, 70)
    testing.expect(t, gs.input.mine)
    testing.expect(t, gs.input.attack)
}

@(test)
agent_mining_a_structure_does_not_mine_it :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    set_tile(&gs.world, 20, 70, .Crafting_Bench)
    agent_handle_line(link, gs, `{"cmd":"act","mine":[20,70]}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect(t, !gs.input.mine, "the same rule update_input applies to a click")
}

@(test)
agent_place_goes_through_the_event_queue :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act","place":[30,40],"frames":2}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.events.size, 1)
    eq_clear(&gs.events)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.events.size, 0)  // one placement per act, however long
}

@(test)
agent_cannot_craft_what_the_player_could_not :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    // A revealed recipe with an empty bag: the request goes in and the handler
    // refuses it, exactly as for a click on CRAFT.
    idx := -1
    for &r, i in recipe_table {
        if recipe_revealed(&gs.progression, r.result) && !recipe_craftable(gs, &r) { idx = i; break }
    }
    testing.expect(t, idx >= 0)
    before := gs.player.inventory
    handle_craft_request(gs, Event{payload = {int_val = i32(idx)}})
    testing.expect_value(t, gs.player.inventory, before)

    gs.progression.recipe_unlocked = {}
    agent_handle_line(link, gs, `{"cmd":"act","craft":"Crafting_Bench"}`)
    testing.expect(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`), "a hidden recipe is not offered")
}

@(test)
agent_dismiss_walks_past_each_screen_in_turn :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    gs.ui.show_title = true
    agent_test_run_act(link, gs, `{"cmd":"act","dismiss":true}`)
    testing.expect(t, gs.ui.show_charselect)
    agent_test_run_act(link, gs, `{"cmd":"act","dismiss":true}`)
    testing.expect(t, !gs.ui.show_charselect)

    agent_handle_line(link, gs, `{"cmd":"state"}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"screen":"play"`))
}

@(test)
agent_death_screen_gives_no_orders :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    gs.player.dead = true
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","place":[30,40]}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect(t, !gs.input.move_left)
    testing.expect_value(t, gs.events.size, 0)
}

@(test)
agent_act_plays_through_the_real_game_update :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    for _ in 0 ..< 30 {  // settle onto the ground first
        agent_drive(link, gs)
        gs.delta_time = AGENT_STEP
        gs.agent.driving = true
        game_update(gs)
    }
    start := gs.player.pos
    agent_handle_line(link, gs, `{"cmd":"act","move":"right","frames":30}`)
    for link.frames_left > 0 {
        testing.expect(t, agent_drive(link, gs))
        game_update(gs)
        agent_after_tick(link, gs)
    }
    testing.expect(t, gs.player.pos.x > start.x, "a held move walks the player")
}

@(test)
agent_client_gone_mid_act_leaves_nothing_to_replay :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    // The state a client leaves behind when it dies right after a 1-frame act.
    agent_handle_line(link, gs, `{"cmd":"act","move":"right","jump":true}`)
    agent_drive(link, gs)
    testing.expect(t, gs.agent.first)

    link.listening = true  // agent_pump's early out; the socket is never touched
    link.connected = false
    link.frames_left = 0
    link.listener = net.TCP_Socket(-1)
    testing.expect(t, agent_pump(link, gs), "the game runs on")
    testing.expect(t, !gs.agent.driving)
    testing.expect_value(t, gs.agent.cmd, Agent_Command{})
}

@(test)
agent_reply_stays_valid_json_in_a_littered_world :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    for &it, i in gs.world.items {
        it = .Stone_Block
        gs.world.item_counts[i] = 99
    }
    agent_handle_line(link, gs, `{"cmd":"state","x":0,"y":0,"w":192,"h":108}`)
    testing.expect_value(t, link.out[link.out_len - 1], '\n')
    _, err := json.parse_string(agent_test_reply(link), allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
}

@(test)
agent_a_window_closes_with_its_machine :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    set_tile(&gs.world, 20, 40, .Air)
    gs.ui.show_barrel = true
    gs.ui.barrel_tile = {20, 40}
    gs.ui.show_smelter = true
    gs.ui.smelter_tile = {20, 40}
    agent_handle_line(link, gs, `{"cmd":"act"}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect(t, !gs.ui.show_barrel)
    testing.expect(t, !gs.ui.show_smelter)
}

@(test)
agent_windows_close_unless_the_act_works_on_them :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    set_tile(&gs.world, 20, 40, .Smelter)
    gs.ui.show_inventory = true
    gs.ui.show_smelter   = true
    gs.ui.smelter_tile   = {20, 40}

    agent_handle_line(link, gs, `{"cmd":"act","collect":true}`)
    agent_drive(link, gs)
    agent_input(gs)
    eq_clear(&gs.events)
    testing.expect(t, gs.ui.show_smelter, "a window verb keeps its window")
    link.frames_left = 0

    agent_handle_line(link, gs, `{"cmd":"act","move":"left"}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect(t, !gs.ui.show_smelter, "any other act closes it")
    testing.expect(t, !gs.ui.show_inventory)
}

@(test)
agent_frames_the_view_for_a_watcher_again_after_a_new_game :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act"}`)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.zoom_target, AGENT_VIEW_ZOOM)

    gs.zoom_target = 3  // the wheel's choice stands for the rest of the game
    agent_input(gs)
    testing.expect_value(t, gs.zoom_target, f32(3))

    game_state_init(gs)  // what New Game does: zooms out and forgets
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.zoom_target, AGENT_VIEW_ZOOM)
}

@(test)
agent_view_glide_finishes_while_the_game_waits :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act"}`)
    agent_drive(link, gs)
    agent_input(gs)
    link.frames_left = 0
    frame := gs.frame

    for _ in 0 ..< 60 {
        testing.expect(t, !agent_drive(link, gs))
        agent_watcher_input(gs, false)
    }
    testing.expect_value(t, gs.zoom, AGENT_VIEW_ZOOM)
    testing.expect_value(t, gs.frame, frame)  // the sim did not move
}

@(test)
agent_seeds_chain_while_driving :: proc(t: ^testing.T) {
    gs := new(Game_State)
    defer free(gs)
    game_state_init(gs, 1234)
    gs.agent.driving = true
    a := agent_new_game_seed(gs)
    b := agent_new_game_seed(gs)
    testing.expect_value(t, a, b)
    testing.expect(t, a != 1234, "a new life is a new world")
}

// The promise a replay rests on: the same acts from the same seed end the same.
@(test)
agent_same_acts_same_seed_same_world :: proc(t: ^testing.T) {
    play :: proc() -> (pos: [2]f32, hp: int, terrain_sum: u64, enemies: [8][2]f32) {
        gs := new(Game_State)
        defer free(gs)
        link := new(Agent_Link)
        defer free(link)
        game_state_init(gs, 777)
        gs.ui.show_title = false
        gs.player.pos = SURFACE_HOME_POS
        link.connected = true
        script := [?]string{
            `{"cmd":"act","move":"right","frames":90}`,
            `{"cmd":"act","jump":true,"move":"left","frames":40}`,
            `{"cmd":"act","mine":[92,53],"frames":120}`,
            `{"cmd":"act","frames":300}`,
        }
        for line in script {
            agent_handle_line(link, gs, line)
            for link.frames_left > 0 {
                agent_drive(link, gs)
                game_update(gs)
                agent_after_tick(link, gs)
            }
        }
        for tile in gs.world.terrain do terrain_sum = terrain_sum*31 + u64(tile)
        for i in 0 ..< len(enemies) do enemies[i] = gs.enemies.data[i].pos
        return gs.player.pos, gs.player.hp, terrain_sum, enemies
    }
    p1, h1, t1, e1 := play()
    p2, h2, t2, e2 := play()
    testing.expect_value(t, p1, p2)
    testing.expect_value(t, h1, h2)
    testing.expect_value(t, t1, t2)
    testing.expect_value(t, e1, e2)
}

@(test)
agent_state_says_what_the_screen_says :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    notify(gs, "The bag is \"full\"")
    gs.flight_t = 7
    set_tile(&gs.world, 20, 40, .Smelter)
    gs.ui.show_smelter = true
    gs.ui.smelter_tile = {20, 40}
    gs.world.sim_data[grid_idx(20, 40)].in_item  = .Iron_Ore
    gs.world.sim_data[grid_idx(20, 40)].in_count = 5

    agent_handle_line(link, gs, `{"cmd":"state"}`)
    value, err := json.parse_string(agent_test_reply(link), allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    root := value.(json.Object)
    testing.expect_value(t, root["notes"].(json.Array)[0].(json.String), `The bag is "full"`)
    testing.expect_value(t, root["flight_s"].(json.Float), 7)
    testing.expect_value(t, root["smelter"].(json.Object)["input"].(json.String), "Iron_Ore")
    testing.expect_value(t, root["smelter"].(json.Object)["input_count"].(json.Float), 5)
    view := root["view"].(json.Object)
    testing.expect(t, len(view["solid"].(json.String)) > 0)
}

@(test)
agent_warp_needs_the_ring_and_reclaim_holds :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act","warp":true}`)
    testing.expect(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`))

    gs.player.equipment[Equip_Slot(1)] = .Jade_Ring
    agent_handle_line(link, gs, `{"cmd":"act","warp":true}`)
    testing.expect_value(t, link.frames_left, 1)
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.events.size, 1)
    eq_clear(&gs.events)
    link.frames_left = 0

    agent_handle_line(link, gs, `{"cmd":"act","reclaim":[20,40],"frames":2}`)
    for _ in 0 ..< 2 {
        agent_drive(link, gs)
        agent_input(gs)
        testing.expect(t, gs.input.reclaim)
        testing.expect_value(t, gs.input.mouse_tile, [2]i32{20, 40})
    }
}

@(test)
agent_fight_log_names_enemies_near_the_player_only :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    link.fight_file = nil
    for i in 0 ..< 2 do gs.enemies.active[i] = true
    gs.enemies.data[0].pos = gs.player.pos + {5, 0}
    gs.enemies.data[0].kind = .Builder
    gs.enemies.data[1].pos = gs.player.pos + {AGENT_FIGHT_RANGE + 1, 0}

    // No file: nothing is logged and nothing is buffered.
    agent_fight_log(link, gs)
    testing.expect_value(t, link.fight_len, 0)

    path := "agent_fight_test.log"
    defer os.remove(path)
    fd, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    testing.expect_value(t, err, nil)
    link.fight_file = fd
    gs.frame = 42
    agent_fight_log(link, gs)
    line := string(link.fight_buf[:link.fight_len])
    testing.expect(t, strings.has_prefix(line, "42,0,Builder,"), line)
    testing.expect(t, strings.contains(line, "42,P,"))
    testing.expect(t, !strings.contains(line, "42,1,"), "out of range")
    os.close(fd)
}

@(test)
agent_objectives_stack_up_for_the_watcher :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"objective","goal":"Reach cave 2","step":"Dig the shaft"}`)
    testing.expect_value(t, string(link.panel.goal.buf[:link.panel.goal.len]), "Reach cave 2")
    testing.expect_value(t, link.panel.count, 0)

    agent_handle_line(link, gs, `{"cmd":"objective","step":"Climb out"}`)
    testing.expect_value(t, string(link.panel.step.buf[:link.panel.step.len]), "Climb out")
    testing.expect_value(t, link.panel.count, 0)  // a new step is not a new goal

    agent_handle_line(link, gs, `{"cmd":"objective","goal":"Find gold","result":"failed"}`)
    testing.expect_value(t, link.panel.count, 1)
    testing.expect(t, link.panel.past[0].failed)
    testing.expect_value(t, link.panel.step.len, 0)

    for i in 0 ..< AGENT_LOG_MAX + 3 {
        agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"objective","goal":"goal %d"}}`, i))
    }
    testing.expect_value(t, link.panel.count, AGENT_LOG_MAX)

    agent_handle_line(link, gs, `{"cmd":"objective"}`)
    testing.expect(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`))
}

@(test)
agent_text_is_cut_to_fit_and_cleaned :: proc(t: ^testing.T) {
    panel: Agent_Panel
    long := strings.repeat("x", AGENT_TEXT_MAX + 50, context.temp_allocator)
    agent_set_objective(&panel, long, "two\nlines", true, true, false)
    testing.expect_value(t, panel.goal.len, AGENT_TEXT_MAX)
    testing.expect_value(t, panel.goal.buf[AGENT_TEXT_MAX], 0)
    testing.expect_value(t, string(panel.step.buf[:panel.step.len]), "two lines")
}

@(test)
agent_panel_goes_when_the_client_does :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_drive(link, gs)
    testing.expect(t, gs.agent.panel == &link.panel)
    link.connected = false
    link.listening = true
    link.listener  = net.TCP_Socket(-1)
    agent_pump(link, gs)
    testing.expect(t, gs.agent.panel == nil)
}

@(test)
agent_lines_arrive_over_a_real_socket :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.connected = false

    // Port 0: a fixed port here lands in the ephemeral range, where any other
    // connection on the machine can be holding it.
    sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0}, 1)
    testing.expect_value(t, err, nil)
    bound, berr := net.bound_endpoint(sock)
    testing.expect_value(t, berr, nil)
    net.set_blocking(sock, false)
    link.listener  = sock
    link.listening = true
    defer agent_close(link, gs)

    client, derr := net.dial_tcp(bound)
    testing.expect_value(t, derr, nil)

    testing.expect(t, agent_pump(link, gs) == false || link.connected)
    testing.expect(t, link.connected)

    // Two lines in one write, split across a partial third.
    net.send_tcp(client, transmute([]u8)string("{\"cmd\":\"state\"}\n{\"cmd\":\"state\"}\n{\"cmd\""))
    reply: [64 * 1024]u8
    got := 0
    newlines := 0
    for _ in 0 ..< 2000 {
        agent_pump(link, gs)
        n, _ := net.recv_tcp(client, reply[got:])
        for b in reply[got:got + n] do if b == '\n' do newlines += 1
        got += n
        if newlines == 2 do break
    }
    testing.expect_value(t, newlines, 2)
    testing.expect(t, strings.has_prefix(string(reply[:got]), `{"ok":true`))

    net.close(client)
    for _ in 0 ..< 2000 {
        if agent_pump(link, gs) && !link.connected do break
    }
    testing.expect(t, !link.connected, "a closed client hands the game back")
    testing.expect(t, !gs.agent.driving, "the keyboard is live again")
    testing.expect_value(t, gs.agent.cmd, Agent_Command{})
    testing.expect(t, !gs.agent.first)
}
