package game

import "core:encoding/json"
import "core:fmt"
import "core:net"
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
agent_lines_arrive_over_a_real_socket :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.connected = false

    PORT :: 47666
    sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT}, 1)
    testing.expect_value(t, err, nil)
    net.set_blocking(sock, false)
    link.listener  = sock
    link.listening = true
    defer agent_close(link)

    client, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = PORT})
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
