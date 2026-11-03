package game

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import rl "vendor:raylib"

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
    gs.player.pos = SURFACE_HOME_POS
    link.connected = true  // no socket: agent_send is only reached through agent_pump
    link.idle_off  = true  // each test about idling turns it back on
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
    testing.expect(t, !gs.ui.show_title)

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
    gs.level_index = 1  // the surface refuses: home already
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
agent_refused_warp_says_so_and_plays_nothing :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    // Run 4's death 1: warp on the surface level answered ok, and nothing moved.
    gs.player.equipment[Equip_Slot(1)] = .Jade_Ring
    gs.level_index = LEVEL_SURFACE
    agent_handle_line(link, gs, `{"cmd":"act","warp":true}`)
    testing.expect(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`), agent_test_reply(link))
    testing.expect(t, strings.contains(agent_test_reply(link), "Already on the surface"), agent_test_reply(link))
    testing.expect_value(t, link.frames_left, 0)

    gs.level_index = 1
    agent_handle_line(link, gs, `{"cmd":"act","warp":true}`)
    testing.expect_value(t, link.frames_left, 1)
}

@(test)
agent_plan_judges_a_warp_when_its_step_starts :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    // Refused now, but a plan's world has not happened yet: the step decides.
    gs.player.equipment[Equip_Slot(1)] = .Jade_Ring
    gs.level_index = LEVEL_SURFACE
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"warp":true}]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"steps":1`), agent_test_reply(link))
    for _ in 0 ..< AGENT_IDLE_EVERY * 3 do if agent_drive(link, gs) do agent_after_tick(link, gs)
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "warp refused"), agent_test_reply(link))
}

@(test)
agent_place_with_nothing_to_place_is_reported :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    refused :: proc(link: ^Agent_Link, gs: ^Game_State) -> bool {
        T := player_tile(&gs.player)
        agent_test_run_act(link, gs, fmt.tprintf(`{{"cmd":"act","select":-1,"place":[%d,%d]}}`, T.x + 1, T.y))
        agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
        return strings.contains(agent_test_reply(link), `"refused":"place"`)
    }
    gs.player.inventory.slots[PLACE_SLOT] = {}
    testing.expect(t, refused(link, gs), "an empty Place Slot must say so")

    agent_test_run_act(link, gs, `{"cmd":"act"}`)
    gs.player.inventory.slots[PLACE_SLOT] = {item = .Pickaxe, count = 1}
    testing.expect(t, refused(link, gs), "a non-block in the Place Slot must say so")
    testing.expect_value(t, gs.player.inventory.slots[PLACE_SLOT].count, 1)
}

@(test)
agent_failed_place_is_reported_and_reach_is_in_state :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    state :: proc(link: ^Agent_Link, gs: ^Game_State) -> string {
        agent_handle_line(link, gs, `{"cmd":"state"}`)
        return agent_test_reply(link)
    }
    testing.expect(t, strings.contains(state(link, gs), fmt.tprintf(`"place_reach":%d`, PLAYER_REACH)))

    inventory_insert(&gs.player.inventory, .Stone_Block, 2)
    for s, i in gs.player.inventory.slots do if s.item == .Stone_Block do gs.player.inventory.selected = i
    T := player_tile(&gs.player)

    // Far outside reach: the stack stays and the reply says so.
    far := fmt.tprintf(`{{"cmd":"act","place":[%d,%d]}}`, (T.x + PLAYER_REACH + 5) % GRID_W, T.y)
    agent_test_run_act(link, gs, far)
    process_events(gs)
    testing.expect(t, strings.contains(state(link, gs), `"refused":"place"`), "a failed place must say so")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 2)

    // The next act clears it, and a place that lands never carries it.
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Air)
    set_tile(&gs.world, int(T.x) + 1, int(T.y) + 1, .Stone)
    agent_test_run_act(link, gs, fmt.tprintf(`{{"cmd":"act","place":[%d,%d]}}`, T.x + 1, T.y))
    process_events(gs)
    testing.expect(t, !strings.contains(state(link, gs), `"refused"`), "a place that landed is not refused")
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Stone_Block), 1)
}

@(test)
agent_withdraw_pulls_the_ore_through_the_key_handler :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    T := player_tile(&gs.player)
    sx, sy := int(T.x) + 1, int(T.y)
    agent_handle_line(link, gs, `{"cmd":"act","withdraw":true}`)
    testing.expect(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`), "withdraw needs the window")

    set_tile(&gs.world, sx, sy, .Smelter)
    sd := &gs.world.sim_data[grid_idx(sx, sy)]
    sd.in_item, sd.in_count = .Silver_Ore, 1
    gs.ui.show_smelter = true
    gs.ui.smelter_tile = {i32(sx), i32(sy)}
    agent_test_run_act(link, gs, `{"cmd":"act","withdraw":true}`)
    process_events(gs)
    testing.expect_value(t, int(sd.in_count), 0)
    testing.expect_value(t, sd.in_item, Item.None)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Silver_Ore), 1)
    testing.expect(t, gs.ui.show_smelter, "withdraw works on the window, so it stays open")
}

@(test)
an_agent_act_without_a_window_verb_shuts_the_smelter_window :: proc(t: ^testing.T) {
    // Run 3 f30120: the smelter window "closed itself".  It was this sweep: the
    // act after the one that opened it carried no window verb.
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    T := player_tile(&gs.player)
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Smelter)
    gs.ui.show_smelter = true
    gs.ui.smelter_tile = {T.x + 1, T.y}

    agent_test_run_act(link, gs, `{"cmd":"act","collect":true}`)
    testing.expect(t, gs.ui.show_smelter, "a window verb keeps it open")
    agent_test_run_act(link, gs, `{"cmd":"act","frames":2}`)
    testing.expect(t, !gs.ui.show_smelter, "any other act sweeps it shut")
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
agent_a_long_goal_sent_again_is_the_same_goal :: proc(t: ^testing.T) {
    panel: Agent_Panel
    long := strings.repeat("x", AGENT_TEXT_MAX + 50, context.temp_allocator)
    tabbed := "dig\tdown"
    for _ in 0 ..< 3 do agent_set_objective(&panel, long, "step", true, true, false)
    testing.expect_value(t, panel.count, 0)
    testing.expect_value(t, panel.step.len, 4)

    agent_set_objective(&panel, tabbed, "", true, false, false)
    agent_set_objective(&panel, tabbed, "kept", true, true, false)
    agent_set_objective(&panel, tabbed, "", true, false, false)
    testing.expect_value(t, panel.count, 1)
    testing.expect_value(t, panel.step.len, 4)
}

@(test)
agent_records_strict_json_whatever_it_was_sent :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    for line in ([?]string{"{cmd:'act',move:'left'}", "{\"cmd\":\"objective\",\"goal\":\"a\tb\"}"}) {
        value, err := json.parse_string(line)
        testing.expect_value(t, err, json.Error.None)
        recorded := agent_canonical(value)
        _, strict := json.parse_string(recorded, .JSON)
        testing.expect_value(t, strict, json.Error.None)
        testing.expect(t, !strings.contains_rune(recorded, '\t'), recorded)
    }
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
agent_idles_slowly_then_holds :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.idle_off = false

    ticks := 0
    for _ in 0 ..< AGENT_IDLE_EVERY * AGENT_IDLE_MAX * 2 {
        if agent_drive(link, gs) {
            ticks += 1
            agent_after_tick(link, gs)
        }
    }
    testing.expect_value(t, ticks, AGENT_IDLE_MAX)

    // An act starts a new wait.
    agent_handle_line(link, gs, `{"cmd":"act"}`)
    agent_drive(link, gs)
    agent_after_tick(link, gs)
    testing.expect_value(t, link.idle_ticks, 0)
    for _ in 0 ..< AGENT_IDLE_EVERY do if agent_drive(link, gs) do agent_after_tick(link, gs)
    testing.expect_value(t, link.idle_ticks, 1)

    agent_handle_line(link, gs, `{"cmd":"idle","on":false}`)
    for _ in 0 ..< AGENT_IDLE_EVERY * 2 do testing.expect(t, !agent_drive(link, gs))
}

@(test)
agent_plan_plays_slowly_and_an_act_overrides_it :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"left","frames":3},{"move":"right","frames":2}]}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), `"ticks":5`))
    link.out_len = 0

    ticks := 0
    for _ in 0 ..< AGENT_IDLE_EVERY * 4 {
        if agent_drive(link, gs) {
            ticks += 1
            agent_after_tick(link, gs)
        }
    }
    testing.expect_value(t, ticks, 4)
    testing.expect_value(t, link.frames_left, 1)
    testing.expect_value(t, link.out_len, 0)  // nobody is waiting on a plan step
    testing.expect(t, link.reply_due == false)
    testing.expect(t, agent_listening(link))

    agent_handle_line(link, gs, `{"cmd":"act","frames":2}`)
    testing.expect(t, !link.planning)
    testing.expect_value(t, link.frames_left, 2)
    testing.expect_value(t, link.plan_len, 0)
}

@(test)
agent_override_keeps_its_own_input :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"right","frames":50}]}`)
    for _ in 0 ..< AGENT_IDLE_EVERY do if agent_drive(link, gs) do agent_after_tick(link, gs)
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":30}`)
    testing.expect_value(t, link.cmd.move, -1)
    testing.expect(t, link.first)
}

// A plan is a promise about a world that has not happened yet, so what depends
// on that world is judged when the step starts.
@(test)
agent_plan_judges_state_verbs_when_the_step_starts :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"frames":1},{"feed":0},{"frames":5}]}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), `"steps":3`))

    for _ in 0 ..< AGENT_IDLE_EVERY * 3 do if agent_drive(link, gs) do agent_after_tick(link, gs)
    testing.expect_value(t, link.plan_len, 0)
    testing.expect_value(t, link.frames_left, 0)
    testing.expect(t, link.plan_stopped.len > 0)
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), `"plan_stopped":"step 1: no smelter`))
}

@(test)
agent_wait_has_no_first_frame :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"wait","frames":3}`)
    testing.expect_value(t, link.frames_left, 3)
    testing.expect(t, !link.first)
    agent_drive(link, gs)
    testing.expect(t, !gs.agent.first)
}

@(test)
agent_plan_is_all_or_nothing :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"left"}]}`)
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"left"},{"frames":0}]}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), "step 1"))
    testing.expect_value(t, link.plan_len, 1)  // the good plan stands
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"cmd":"wait","frames":5}]}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), "only be an act"))
    testing.expect_value(t, link.plan_len, 1)
}

// What a replay does with a recording must be what the plan did: this plays the
// real rows back, the way tools/agent_replay.py does.
@(test)
agent_recorded_plan_replays_from_its_rows :: proc(t: ^testing.T) {
    start :: proc(gs: ^Game_State, link: ^Agent_Link) {
        game_state_init(gs, 778)
        gs.ui.show_title = false
        gs.player.pos = SURFACE_HOME_POS
        link.connected = true
    }
    run :: proc(link: ^Agent_Link, gs: ^Game_State, ticks: int) {
        n := 0
        for _ in 0 ..< ticks * AGENT_IDLE_EVERY * 2 {
            if n == ticks do break
            if agent_drive(link, gs) {
                game_update(gs)
                agent_after_tick(link, gs)
                n += 1
            }
        }
    }
    path := "agent_plan_test.jsonl"
    defer os.remove(path)

    gs := new(Game_State)
    defer free(gs)
    link := new(Agent_Link)
    defer free(link)
    start(gs, link)
    f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    testing.expect(t, err == nil)
    link.acts_file = f
    link.recording = true
    agent_handle_line(link, gs, `{"cmd":"act","move":"right","frames":10}`)
    run(link, gs, 10)
    run(link, gs, 20)  // an idle wait
    agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"right","frames":40},{"move":"left","frames":50}]}`)
    run(link, gs, 47)
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":10}`)
    run(link, gs, 10)
    link.recording = false
    os.close(f)

    data, read_err := os.read_entire_file(path, context.allocator)
    testing.expect(t, read_err == nil)
    defer delete(data)
    testing.expect(t, strings.contains(string(data), `"played":7`))
    testing.expect(t, strings.contains(string(data), `"idle":20`))

    gs2 := new(Game_State)
    defer free(gs2)
    link2 := new(Agent_Link)
    defer free(link2)
    start(gs2, link2)
    link2.idle_off = true
    // Parsed up front: the temp allocator does not outlive a game tick.
    Replay_Row :: struct { line: string, ticks: int }
    replay := make([dynamic]Replay_Row)  // made here: appending below would pick the temp allocator
    defer {
        for r in replay do delete(r.line)
        delete(replay)
    }
    {
        heap := context.allocator
        context.allocator = context.temp_allocator
        defer free_all(context.temp_allocator)
        for row in strings.split_lines(string(data)) {
            if row == "" do continue
            value, _ := json.parse_string(row)
            rec := value.(json.Object)
            if n, ok := agent_int(rec, "idle"); ok {
                append(&replay, Replay_Row{fmt.aprintf(`{{"cmd":"wait","frames":%d}}`, n, allocator = heap), n})
                continue
            }
            act := rec["act"].(json.Object)
            frames, _ := agent_int(act, "frames")
            if played, ok := agent_int(rec, "played"); ok {
                frames = played
                act["frames"] = json.Integer(played)
            }
            act["cmd"] = "act"  // plan steps are recorded without one
            append(&replay, Replay_Row{fmt.aprintf("%s", agent_canonical(act), allocator = heap), frames})
        }
    }
    for r in replay {
        agent_handle_line(link2, gs2, r.line)
        testing.expect(t, link2.frames_left == r.ticks, r.line)
        run(link2, gs2, r.ticks)
    }
    testing.expect_value(t, gs2.frame, gs.frame)
    testing.expect_value(t, gs2.player.pos, gs.player.pos)
    testing.expect_value(t, gs2.enemies.count, gs.enemies.count)
}

// Replay plays a recorded wait as an empty act, so the two must be the same.
@(test)
agent_idle_ticks_equal_an_empty_act :: proc(t: ^testing.T) {
    play :: proc(idle: bool) -> (pos: [2]f32, frame: u64, enemies: [8][2]f32) {
        gs := new(Game_State)
        defer free(gs)
        link := new(Agent_Link)
        defer free(link)
        game_state_init(gs, 777)
        gs.ui.show_title = false
        gs.player.pos = SURFACE_HOME_POS
        link.connected = true
        link.idle_off = !idle
        run :: proc(link: ^Agent_Link, gs: ^Game_State) {
            for link.frames_left > 0 {
                agent_drive(link, gs)
                game_update(gs)
                agent_after_tick(link, gs)
            }
        }
        agent_handle_line(link, gs, `{"cmd":"act","move":"right","frames":30}`)
        run(link, gs)
        if idle {
            for link.idle_ticks < 90 {
                if agent_drive(link, gs) {
                    game_update(gs)
                    agent_after_tick(link, gs)
                }
            }
        } else {
            agent_handle_line(link, gs, `{"cmd":"act","frames":90}`)
            run(link, gs)
        }
        agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":30}`)
        run(link, gs)
        for i in 0 ..< len(enemies) do enemies[i] = gs.enemies.data[i].pos
        return gs.player.pos, gs.frame, enemies
    }
    p1, f1, e1 := play(true)
    p2, f2, e2 := play(false)
    testing.expect_value(t, f1, f2)
    testing.expect_value(t, p1, p2)
    testing.expect_value(t, e1, e2)
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

// The burn only exists if game_update runs its step: the whole frame, not the
// two procs by hand.
@(test)
a_flame_turret_burns_through_the_real_game_update :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.agent.driving = true
    X :: 60
    Y :: SURFACE_Y - 1
    turret_test_site(gs, X, Y)
    set_tile(&gs.world, X, Y, .Turret_Pillar)
    set_tile(&gs.world, X, Y - 1, .Flame_Turret)
    id := turret_test_enemy(gs, X + 2.5, f32(Y) - 0.5)
    for _ in 0 ..< 90 {
        gs.delta_time = AGENT_STEP
        gs.enemies.data[id].pos = {X + 2, f32(Y) - 1}  // held in the jet
        game_update(gs)
    }
    testing.expect(t, gs.enemies.data[id].hp < 50, "game_update ticks the burn")
}

// ─── Run 5 gaps (card 91) ─────────────────────────────────────────────────────

// Plays one request through the whole frame a real client gets.
@(private="file")
agent_test_play :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
    agent_handle_line(link, gs, line)
    for link.frames_left > 0 {
        if agent_drive(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
    link.reply_due = false
}

@(private="file")
agent_test_state :: proc(link: ^Agent_Link, gs: ^Game_State, line := `{"cmd":"state"}`) -> json.Object {
    agent_handle_line(link, gs, line)
    value, err := json.parse_string(agent_test_reply(link), allocator = context.temp_allocator)
    assert(err == .None)
    return value.(json.Object)
}

@(private="file")
agent_test_refused :: proc(t: ^testing.T, link: ^Agent_Link, gs: ^Game_State, line: string, loc := #caller_location) {
    agent_handle_line(link, gs, line)
    testing.expectf(t, strings.has_prefix(agent_test_reply(link), `{"ok":false`), "%s -> %s", line, agent_test_reply(link), loc = loc)
    testing.expect_value(t, link.frames_left, 0, loc = loc)
}

// The furnace beside the player, its window open as a `use` leaves it.
@(private="file")
agent_test_smelter :: proc(gs: ^Game_State) -> ^Sim_Tile_Data {
    T := player_tile(&gs.player)
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Smelter)
    gs.ui.show_smelter = true
    gs.ui.smelter_tile = {T.x + 1, T.y}
    return &gs.world.sim_data[grid_idx(int(T.x) + 1, int(T.y))]
}

@(test)
agent_tithe_sends_an_item_on_from_the_death_screen :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    inventory_insert(&gs.player.inventory, .Potion_Health, 5)
    inventory_insert(&gs.player.inventory, .Dirt, 2)
    inventory_insert(&gs.player.inventory, .Hell_Key, 1)
    slot, key := -1, -1
    for s, i in gs.player.inventory.slots {
        if s.item == .Potion_Health do slot = i
        if s.item == .Hell_Key do key = i
    }

    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, slot))
    testing.expect(t, strings.contains(agent_test_reply(link), "needs the death screen"), "the living are told why")

    eq_push(&gs.events, Event{type = .Damage_Dealt, source = INVALID_ENTITY, target = PLAYER_ID,
        payload = {int_val = 100}, cause = .Lava})
    agent_test_play(link, gs, `{"cmd":"act","frames":2}`)
    testing.expect(t, gs.player.dead, "the blow lands through the real update")

    root := agent_test_state(link, gs)
    testing.expect_value(t, root["screen"].(json.String), "dead")
    testing.expect_value(t, root["death_by"].(json.String), "lava")
    tithe := root["tithe"].(json.Object)
    testing.expect_value(t, tithe["chosen"].(json.Float), -1)
    offered := tithe["offerable"].(json.Array)
    found := false
    for v in offered {
        testing.expect(t, int(v.(json.Float)) != key, "a key is the run's own")
        found ||= int(v.(json.Float)) == slot
    }
    testing.expect(t, found, "the potions are on offer")
    testing.expect(t, len(offered) >= 2)
    testing.expect(t, strings.contains(agent_test_reply(link), fmt.tprintf(`%v,%v`, int(offered[0].(json.Float)), int(offered[1].(json.Float)))), "strict JSON, the lenient parser hides a missing comma")

    // A click does nothing until the screen has settled, and neither does this.
    testing.expect(t, gs.player.death_timer <= DEATH_INPUT_DELAY)
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, slot))
    for gs.player.death_timer <= DEATH_INPUT_DELAY do agent_test_play(link, gs, `{"cmd":"act","frames":30}`)

    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, key))
    agent_test_refused(t, link, gs, `{"cmd":"act","tithe":99}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","tithe":"potion"}`)
    testing.expect_value(t, gs.stats.grave.tithe, Item.None)

    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, slot))
    testing.expect_value(t, gs.stats.grave.tithe, Item.Potion_Health)
    testing.expect_value(t, gs.ui.tithe_slot, slot)
    testing.expect_value(t, agent_test_state(link, gs)["tithe"].(json.Object)["chosen"].(json.Float), f64(slot))
}

@(test)
agent_tithe_and_dismiss_in_one_act_send_the_item_first :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    inventory_insert(&gs.player.inventory, .Potion_Health, 1)
    slot := 0
    for s, i in gs.player.inventory.slots do if s.item == .Potion_Health do slot = i
    gs.player.dead = true
    gs.player.death_timer = DEATH_INPUT_DELAY + 1
    gs.stats.grave.active = true

    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d,"dismiss":true}}`, slot))
    agent_drive(link, gs)
    agent_input(gs)
    testing.expect_value(t, gs.events.size, 2)
    testing.expect_value(t, gs.events.events[gs.events.head].type, Event_Type.Tithe_Choose)
}

@(test)
agent_tithe_fires_once_however_long_the_act :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    inventory_insert(&gs.player.inventory, .Potion_Health, 1)
    slot := 0
    for s, i in gs.player.inventory.slots do if s.item == .Potion_Health do slot = i
    gs.player.dead = true
    gs.player.death_timer = DEATH_INPUT_DELAY + 1
    gs.stats.grave.active = true

    // A second firing would toggle it back off.
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d,"frames":4}}`, slot))
    testing.expect_value(t, gs.stats.grave.tithe, Item.Potion_Health)
    // The window sweep and the rest of the verbs do not touch a dead hero's choice.
    testing.expect_value(t, gs.ui.tithe_slot, slot)

    root := agent_test_state(link, gs)
    testing.expect(t, "death_by" not_in root, "a death with no blow names none")
    testing.expect(t, "tithe" in root)
}

@(test)
agent_state_is_silent_about_death_while_alive :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.death_by = "lava"  // a stale cause must not read as a death
    root := agent_test_state(link, gs)
    testing.expect(t, "death_by" not_in root)
    testing.expect(t, "tithe" not_in root)
}

@(test)
agent_feed_count_loads_only_that_many :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    sd := agent_test_smelter(gs)
    inventory_insert(&gs.player.inventory, .Iron_Ore, 20)
    inventory_insert(&gs.player.inventory, .Wood_Log, 9)
    ore, wood := 0, 0
    for s, i in gs.player.inventory.slots {
        if s.item == .Iron_Ore do ore = i
        if s.item == .Wood_Log do wood = i
    }

    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","feed":%d,"count":4}}`, ore))
    testing.expect_value(t, int(sd.in_count), 4)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Iron_Ore), 16)
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","feed":%d,"count":3}}`, wood))
    testing.expect_value(t, int(sd.fuel_count), 3)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Wood_Log), 6)

    // More than the stack is the stack; no count is still the whole of it.
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","feed":%d,"count":50}}`, wood))
    testing.expect_value(t, int(sd.fuel_count), 9)
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","feed":%d}}`, ore))
    testing.expect_value(t, int(sd.in_count), 20)
    inventory_insert(&gs.player.inventory, .Wood_Log, 5)
    for s, i in gs.player.inventory.slots do if s.item == .Wood_Log do wood = i
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","feed":%d}}`, wood))
    testing.expect_value(t, int(sd.fuel_count), 14)

    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","feed":0,"count":%d}}`, MAX_STACK + 1))
    agent_test_refused(t, link, gs, `{"cmd":"act","count":3}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","take":0,"count":3}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","feed":0,"count":0}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","feed":0,"count":"all"}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","feed":0,"count":100000000000}`)
    agent_test_refused(t, link, gs, `{"cmd":"plan","acts":[{"count":3}]}`)
}

@(test)
agent_smelter_window_shows_the_fuel_and_gives_it_back :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_test_refused(t, link, gs, `{"cmd":"act","withdraw_fuel":true}`)

    sd := agent_test_smelter(gs)
    sd.fuel_count = 7
    testing.expect_value(t, agent_test_state(link, gs)["smelter"].(json.Object)["fuel"].(json.Float), 7)

    agent_test_play(link, gs, `{"cmd":"act","withdraw_fuel":true}`)
    testing.expect_value(t, int(sd.fuel_count), 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Wood_Log), 7)
    testing.expect(t, gs.ui.show_smelter, "a window verb keeps it open")
}

@(test)
agent_feed_of_exactly_a_full_stack_is_a_count :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    sd := agent_test_smelter(gs)
    inventory_insert(&gs.player.inventory, .Wood_Log, MAX_STACK)
    slot := 0
    for s, i in gs.player.inventory.slots do if s.item == .Wood_Log do slot = i
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","feed":%d,"count":%d}}`, slot, MAX_STACK))
    testing.expect_value(t, int(sd.fuel_count), MAX_STACK)
}

@(test)
smelter_fuel_withdraw_keeps_every_log_and_every_rule :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    sd := agent_test_smelter(gs)
    tile := gs.ui.smelter_tile

    testing.expect(t, !smelter_withdraw_fuel(gs, tile), "an empty box gives nothing")
    testing.expect_value(t, gs.notify.count, 0)

    // A bag with room for 5: the rest stays in the furnace.
    sd.fuel_count = 8
    inv := &gs.player.inventory
    for &s in inv.slots do s = {.Stone_Block, MAX_STACK}
    inv.slots[3] = {.Wood_Log, MAX_STACK - 5}
    testing.expect(t, smelter_withdraw_fuel(gs, tile))
    testing.expect_value(t, int(sd.fuel_count), 3)
    testing.expect_value(t, inventory_count(inv, .Wood_Log), MAX_STACK)
    log_len := gs.debug_log.pos
    when GAME_DEBUG {  // a release build keeps no action.log
        testing.expect(t, strings.contains(string(gs.debug_log.buf[:log_len]), "pulls 5 wood back out"), "action.log is the playtest's truth")
    }
    gs.notify.count = 0
    testing.expect(t, !smelter_withdraw_fuel(gs, tile), "the bag is full")
    testing.expect_value(t, int(sd.fuel_count), 3)
    testing.expect_value(t, gs.notify.count, 1)
    when GAME_DEBUG do testing.expect_value(t, gs.debug_log.pos, log_len)

    inv.slots = {}
    gs.player.pos.x += (BENCH_RANGE + 2) * 1
    gs.notify.count = 0
    testing.expect(t, !smelter_withdraw_fuel(gs, tile), "out of reach")
    testing.expect_value(t, gs.notify.count, 1)
    testing.expect_value(t, int(sd.fuel_count), 3)
    gs.player.pos = SURFACE_HOME_POS

    gs.player.dead = true
    testing.expect(t, !smelter_withdraw_fuel(gs, tile), "the dead do not stoke")
    gs.player.dead = false

    eq_push(&gs.events, Event{type = .Smelter_Withdraw_Fuel, tile = tile})
    gs.save_dirty = false
    process_events(gs)
    testing.expect_value(t, int(sd.fuel_count), 0)
    testing.expect(t, gs.save_dirty, "moving logs is worth an autosave")

    testing.expect(t, !smelter_withdraw_fuel(gs, {-1, 0}), "off the map")
}

// The player's way to the same verb: API law, nothing a keyboard cannot do.
@(test)
smelter_fuel_slot_drags_back_to_the_bag :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    sd := agent_test_smelter(gs)
    fx, fy := smelter_fuel_rect(gs)
    gs.input.mouse_screen = {f32(fx) + 2, f32(fy) + 2}

    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "nothing to lift")

    sd.fuel_count = 4
    gs.input.mouse_screen = {f32(fx) - 2, f32(fy) + 2}
    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "a miss on the left of the slot")
    gs.input.mouse_screen = {f32(fx) + SLOT_PX, f32(fy) + 2}
    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "a miss on the right of the slot")
    gs.input.mouse_screen = {f32(fx) + 2, f32(fy) - 2}
    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "a miss above the slot")
    gs.input.mouse_screen = {f32(fx) + 2, f32(fy) + SLOT_PX}
    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "a miss below the slot")

    gs.input.mouse_screen = {f32(fx) + 2, f32(fy) + 2}
    gs.ui.drag_item = .Dirt
    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "the hand is already full")
    gs.ui.drag_item = .None

    gs.ui.show_smelter = false
    smelter_fuel_grab(gs)
    testing.expect(t, !gs.ui.drag_fuel, "no window, no slot")
    gs.ui.show_smelter = true

    smelter_fuel_grab(gs)
    testing.expect(t, gs.ui.drag_fuel)
    testing.expect_value(t, gs.ui.drag_item, FUEL_ITEM)

    // Dropped over the open world it stays in the furnace.
    gs.ui.show_inventory = false
    gs.input.mouse_screen = {-100, -100}
    smelter_fuel_drop(gs)
    testing.expect(t, !gs.ui.drag_fuel)
    testing.expect_value(t, gs.events.size, 0)

    smelter_fuel_grab(gs)  // misses: the cursor is off in the world
    gs.input.mouse_screen = {f32(fx) + 2, f32(fy) + 2}
    smelter_fuel_grab(gs)
    smelter_fuel_drop(gs)  // back on the window is a click in place
    testing.expect_value(t, gs.events.size, 1)
    process_events(gs)
    testing.expect_value(t, int(sd.fuel_count), 0)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Wood_Log), 4)

    gs.ui.show_inventory = true
    x, y, _, _, _ := window_rect(gs, .Inventory)
    gs.input.mouse_screen = {f32(x) + 2, f32(y) + 2}
    eq_clear(&gs.events)
    gs.ui.drag_fuel = true
    smelter_fuel_drop(gs)
    testing.expect_value(t, gs.events.size, 1)

    gs.ui.drag_item, gs.ui.drag_tray, gs.ui.drag_input, gs.ui.drag_fuel = .Dirt, true, true, true
    gs.ui.drag_barrel, gs.ui.drag_void = 2, true
    drag_cancel(gs)
    testing.expect_value(t, gs.ui.drag_item, Item.None)
    testing.expect(t, !gs.ui.drag_tray && !gs.ui.drag_input && !gs.ui.drag_fuel && !gs.ui.drag_void)
    testing.expect_value(t, gs.ui.drag_barrel, -1)
}

// Run 5: `solid` named the bench the body had just walked through.
@(test)
agent_solid_says_what_stops_the_body :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    for _ in 0 ..< 30 do agent_test_play(link, gs, `{"cmd":"act","frames":1}`)
    T := player_tile(&gs.player)
    x, y := int(T.x), int(T.y)
    for dx in 1 ..< 8 do for dy in -2 ..= 0 do set_tile(&gs.world, x + dx, y + dy, .Air)
    // Two tall: the body steps up a single tile, so one would prove nothing.
    for dy in -1 ..= 0 {
        set_tile(&gs.world, x + 2, y + dy, .Smelter)
        set_tile(&gs.world, x + 3, y + dy, .Door)
        set_tile(&gs.world, x + 4, y + dy, .Rune_Scroll_Chest_B)
        set_tile(&gs.world, x + 6, y + dy, .Stone)
    }

    root := agent_test_state(link, gs)
    view := root["view"].(json.Object)
    solid := view["solid"].(json.String)
    floor := view["floor"].(json.String)
    legend := view["legend"].(json.Object)
    char_of :: proc(legend: json.Object, name: string) -> string {
        for ch, v in legend do if v.(json.String) == name do return ch
        return "?"
    }
    testing.expect(t, strings.contains(solid, char_of(legend, "Stone")))
    testing.expect(t, strings.contains(floor, char_of(legend, "Stone")))
    testing.expect(t, !strings.contains(solid, char_of(legend, "Smelter")), "the body walks through a structure")
    testing.expect(t, strings.contains(floor, char_of(legend, "Smelter")), "and stands on top of one")
    testing.expect(t, !strings.contains(solid, char_of(legend, "Rune_Scroll_Chest_B")))
    testing.expect(t, strings.contains(floor, char_of(legend, "Rune_Scroll_Chest_B")))
    testing.expect(t, !strings.contains(solid, char_of(legend, "Door")), "and any way through a door")
    testing.expect(t, !strings.contains(floor, char_of(legend, "Door")))
    testing.expect(t, !strings.contains(floor, char_of(legend, "Air")))

    // What the view says is what the real update does.
    agent_test_play(link, gs, `{"cmd":"act","move":"right","frames":120}`)
    body := player_tile(&gs.player)
    testing.expect(t, int(body.x) >= x + 4, "past the structures and the door")
    testing.expect(t, int(body.x) < x + 6, "stopped by the stone")
}

@(test)
agent_state_carries_what_the_screen_warns_of :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    testing.expect_value(t, agent_test_state(link, gs)["fall_warning"].(json.Float), 0)
    gs.player.grounded = false
    gs.player.fall_peak_y = gs.player.pos.y - SAFE_FALL_TILES - FALL_WARN_RAMP_TILES
    testing.expect_value(t, agent_test_state(link, gs)["fall_warning"].(json.Float), 1)
    gs.player.fall_peak_y = gs.player.pos.y

    wave := agent_test_state(link, gs)["wave"].(json.Object)
    testing.expect_value(t, wave["threat"].(json.Float), 0)
    testing.expect_value(t, wave["gauge"].(json.Float), 0)
    testing.expect_value(t, wave["warning_s"].(json.Float), 0)

    gs.wave.threat = 37
    gs.wave.pressure = WAVE_PRESSURE_TARGET / 2
    gs.wave.warning_active = true
    gs.wave.warning_timer = 12.5
    wave = agent_test_state(link, gs)["wave"].(json.Object)
    testing.expect_value(t, wave["threat"].(json.Float), 37)
    testing.expect_value(t, wave["gauge"].(json.Float), 0.5)
    testing.expect_value(t, wave["warning_s"].(json.Float), 12.5)

    // A spent timer does not read as a warning.
    gs.wave.warning_active = false
    testing.expect_value(t, agent_test_state(link, gs)["wave"].(json.Object)["warning_s"].(json.Float), 0)
}

@(test)
agent_state_lists_dens_and_their_hoards :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    den :: proc(gs: ^Game_State, kind: Enemy_Kind, anchor: [2]i32, built: bool) -> int {
        id, _ := enemy_alloc(&gs.enemies)
        e := &gs.enemies.data[id]
        e.kind = kind
        e.pos = {5, 5}  // the owner is out robbing: the den still stands
        e.builder.anchor = anchor
        e.builder.den_built = built
        return id
    }
    built := den(gs, .Builder, {30, 60}, true)
    den(gs, .Builder, {40, 60}, false)
    den(gs, .Builder, {150, 20}, true)
    den(gs, .Garm, {50, 60}, true)
    gs.world.items[grid_idx(30, 60)], gs.world.item_counts[grid_idx(30, 60)] = .Iron_Ore, 4
    gs.world.items[grid_idx(31, 60)], gs.world.item_counts[grid_idx(31, 60)] = .Gold_Ore, 2

    dens := agent_test_state(link, gs, `{"cmd":"state","x":20,"y":50,"w":40,"h":20}`)["dens"].(json.Array)
    testing.expect_value(t, len(dens), 1)
    d := dens[0].(json.Object)
    testing.expect_value(t, int(d["owner"].(json.Float)), built)
    testing.expect_value(t, d["x"].(json.Float), 30)
    testing.expect_value(t, d["y"].(json.Float), 60)
    testing.expect_value(t, d["hoard"].(json.Float), 6)

    dens = agent_test_state(link, gs, `{"cmd":"state","x":0,"y":0,"w":192,"h":108}`)["dens"].(json.Array)
    testing.expect_value(t, len(dens), 2)
    testing.expect(t, strings.contains(agent_test_reply(link), `},{"owner"`), "strict JSON, the lenient parser hides a missing comma")
    dens = agent_test_state(link, gs, `{"cmd":"state","x":31,"y":61,"w":3,"h":3}`)["dens"].(json.Array)
    testing.expect_value(t, len(dens), 0)

    // The view's edges, each way: the anchor is at (30,60).
    edges := [?]struct{ line: string, n: int }{
        {`{"cmd":"state","x":30,"y":60,"w":1,"h":1}`, 1},
        {`{"cmd":"state","x":29,"y":60,"w":1,"h":1}`, 0},
        {`{"cmd":"state","x":30,"y":59,"w":1,"h":1}`, 0},
        {`{"cmd":"state","x":31,"y":60,"w":1,"h":1}`, 0},
        {`{"cmd":"state","x":30,"y":61,"w":1,"h":1}`, 0},
    }
    for e in edges {
        testing.expectf(t, len(agent_test_state(link, gs, e.line)["dens"].(json.Array)) == e.n, "%s", e.line)
    }
}

@(test)
agent_turbo_draws_once_a_second_and_only_while_driven :: proc(t: ^testing.T) {
    link := new(Agent_Link)
    defer free(link)
    start := time.tick_now()
    later :: proc(from: time.Tick, d: time.Duration) -> time.Tick {
        return time.Tick{from._nsec + i64(d)}
    }

    link.last_draw = start  // a draw just now: only the guards can say yes
    testing.expect(t, agent_draw_due(link, start), "the keyboard's game always draws")
    link.connected = true
    testing.expect(t, agent_draw_due(link, start), "a plain agent run always draws")
    link.connected, link.turbo = false, true
    testing.expect(t, agent_draw_due(link, start), "nobody driving: the window is someone's")
    link.connected = true

    link.last_draw = start
    testing.expect(t, !agent_draw_due(link, later(start, AGENT_TURBO_DRAW - 1)))
    testing.expect(t, agent_draw_due(link, later(start, AGENT_TURBO_DRAW)))
    testing.expect(t, !agent_draw_due(link, later(start, AGENT_TURBO_DRAW + 1)), "the clock restarts at a draw")
}

// ─── One address: the brief and the socket on one port (card 84) ──────────────

// A listening link on a port of its own, with no client yet.
@(private="file")
agent_test_listening :: proc(t: ^testing.T) -> (gs: ^Game_State, link: ^Agent_Link, at: net.Endpoint) {
    gs, link = agent_test_world()
    link.connected = false
    sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0}, 1)
    testing.expect_value(t, err, nil)
    bound, berr := net.bound_endpoint(sock)
    testing.expect_value(t, berr, nil)
    net.set_blocking(sock, false)
    link.listener  = sock
    link.listening = true
    link.port      = bound.port
    return gs, link, bound
}

// Sends one request and pumps until the far side closes or `want` newlines came.
@(private="file")
agent_test_ask :: proc(gs: ^Game_State, link: ^Agent_Link, client: net.TCP_Socket, text: string, want_lines := -1, buf: []u8) -> string {
    net.set_blocking(client, false)
    net.send_tcp(client, transmute([]u8)text)
    got, lines := 0, 0
    for _ in 0 ..< 20000 {
        agent_pump(link, gs)
        n, err := net.recv_tcp(client, buf[got:])
        if err == nil && n == 0 do break
        if err == nil {
            for b in buf[got:got + n] do if b == '\n' do lines += 1
            got += n
        }
        if want_lines > 0 && lines >= want_lines do break
    }
    return string(buf[:got])
}

@(test)
a_get_gets_the_brief_and_a_socket_client_plays_on_the_same_port :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    gs.world_seed = 90210
    buf := new([AGENT_BRIEF_MAX + 1024]u8)
    defer free(buf)

    web, _ := net.dial_tcp(at)
    reply := agent_test_ask(gs, link, web, "GET / HTTP/1.1\r\nHost: x\r\n\r\n", -1, buf[:])
    net.close(web)
    testing.expect(t, strings.has_prefix(reply, "HTTP/1.0 200 OK\r\n"), reply[:min(len(reply), 40)])
    testing.expect(t, strings.contains(reply, "Content-Type: text/plain"))
    head := strings.index(reply, "\r\n\r\n")
    testing.expect(t, strings.contains(reply[:head], fmt.tprintf("Content-Length: %d\r\n", len(reply) - head - 4)))
    testing.expect(t, !link.connected, "reading the brief does not take the game")
    testing.expect(t, !gs.agent.driving)
    testing.expect(t, !link.pending_open, "and the connection is closed")

    client, _ := net.dial_tcp(at)
    defer net.close(client)
    out := agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, strings.has_prefix(out, `{"ok":true`))
    testing.expect(t, link.connected, "a JSON first line is the client")
}

@(test)
the_brief_is_written_from_the_game_as_it_stands :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.port = 40123
    gs.world_seed = 90210
    gs.level_index = 2
    agent_handle_line(link, gs, `{"cmd":"objective","goal":"find the gold"}`)

    brief := agent_write_brief(link, gs)
    for want in ([]string{"127.0.0.1:40123", "world seed: 90210", "level 2", "screen: play", "the panel's goal: find the gold",
                          "game's objective line: ", `"cmd":"act"`, `"cmd":"plan"`, `"cmd":"objective"`, "HOW THE GAME WAITS", "FIRST STEPS", `"move":"right"`, "TALK", "Read state's heard", `"cmd":"say"`, `"cmd":"listen"`, "Final Seal", "\"127.0.0.1\", 40123"}) {
        testing.expect(t, strings.contains(brief, want), want)
    }
    testing.expect(t, strings.contains(brief, fmt.tprintf("up to %d ticks", AGENT_IDLE_MAX)))
    testing.expect(t, strings.contains(brief, "another agent is connected"), "the link has a client")
    tail := strings.trim_right_space(AGENT_LESSONS)
    testing.expect(t, strings.has_suffix(strings.trim_right_space(brief), tail[len(tail) - 40:]), "the lessons fit, all of them")
    testing.expect(t, !strings.contains(brief, "agent_play.sh"), "the lessons' harness head stays out")
    testing.expect(t, strings.contains(brief, AGENT_LESSONS_FROM))
    testing.expect(t, !strings.contains(brief, "%!"), "no format string went wrong")
    link.connected = false
    testing.expect(t, strings.contains(agent_write_brief(link, gs), "none, the socket is free"))
}

@(test)
the_brief_is_served_while_a_client_plays_and_a_second_client_is_turned_away :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_BRIEF_MAX + 1024]u8)
    defer free(buf)

    client, _ := net.dial_tcp(at)
    defer net.close(client)
    agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, link.connected)

    web, _ := net.dial_tcp(at)
    reply := agent_test_ask(gs, link, web, "GET / HTTP/1.0\r\n\r\n", -1, buf[:])
    net.close(web)
    testing.expect(t, strings.contains(reply, "HOW THE GAME WAITS"))

    second, _ := net.dial_tcp(at)
    reply = agent_test_ask(gs, link, second, `{"cmd":"state"}` + "\n", -1, buf[:])
    net.close(second)
    testing.expect(t, strings.contains(reply, "another agent is playing"), reply)
    testing.expect(t, !link.pending_open)

    out := agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, strings.has_prefix(out, `{"ok":true`), "the first client never noticed")
}

@(test)
a_first_line_that_is_not_json_is_refused_and_closed :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf: [1024]u8

    web, _ := net.dial_tcp(at)
    defer net.close(web)
    body := "POST / HTTP/1.1\r\n\r\n" + `{"cmd":"act","move":"left"}` + "\n"
    reply := agent_test_ask(gs, link, web, body, -1, buf[:])
    testing.expect(t, strings.has_prefix(reply, `{"ok":false`), reply)
    testing.expect(t, !link.connected, "a page's POST body does not get to play")
    testing.expect_value(t, link.frames_left, 0)
}

@(test)
a_silent_connection_does_not_drive_the_game_or_block_the_next :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_BRIEF_MAX + 1024]u8)
    defer free(buf)

    silent, _ := net.dial_tcp(at)
    defer net.close(silent)
    for _ in 0 ..< 200 {
        testing.expect(t, agent_pump(link, gs), "the keyboard keeps the game")
        if link.pending_open do break
    }
    testing.expect(t, link.pending_open)
    testing.expect(t, !link.connected)

    web, _ := net.dial_tcp(at)
    reply := agent_test_ask(gs, link, web, "GET / HTTP/1.0\r\n\r\n", -1, buf[:])
    net.close(web)
    testing.expect(t, strings.contains(reply, "HOW THE GAME WAITS"))
}

@(test)
a_client_connecting_on_the_title_starts_the_frame_clock :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)
    gs.ui.show_title = true
    gs.frame = 500
    link.idle_off = true
    link.realtime = true
    link.panel.goal.len = 3

    client, _ := net.dial_tcp(at)
    defer net.close(client)
    agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect_value(t, gs.frame, 0)
    testing.expect(t, !link.idle_off && !link.realtime, "a new client starts from the waiting game")
    testing.expect_value(t, link.panel.goal.len, 0)
}

@(test)
the_title_only_binds_loopback_and_steps_past_a_taken_port :: proc(t: ^testing.T) {
    first, port, ok := agent_title_bind(47311)
    testing.expect(t, ok)
    defer net.close(first)
    testing.expect_value(t, port, 47311)
    at, err := net.bound_endpoint(first)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, at.address, net.Address(net.IP4_Loopback))

    second, next, ok2 := agent_title_bind(47311)
    testing.expect(t, ok2)
    defer net.close(second)
    testing.expect_value(t, next, 47312)
}

@(test)
the_title_bind_gives_up_when_every_port_is_taken :: proc(t: ^testing.T) {
    socks: [AGENT_TITLE_PORTS]net.TCP_Socket
    for &s, i in socks do s, _ = net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 47331 + i}, 1)
    defer for s in socks do net.close(s)
    _, _, ok := agent_title_bind(47331)
    testing.expect(t, !ok)
}

@(test)
a_sandbox_holds_its_marker_seed_and_a_copy_of_the_sprites :: proc(t: ^testing.T) {
    root :: "gnipa_agent_sandbox_scratch"
    art  :: root + "_art.dat"
    defer os.remove_all(root)
    defer os.remove(art)
    bytes := "not the real sprite bank"
    testing.expect(t, os.write_entire_file(art, transmute([]u8)bytes) == nil)

    folder :: root + "/runs/one"
    testing.expect(t, agent_sandbox_make(folder, 4242, art))
    testing.expect(t, os.exists(folder + "/" + AGENT_SANDBOX_FILE))
    seed, _ := os.read_entire_file_from_path(folder + "/seed", context.temp_allocator)
    testing.expect_value(t, string(seed), "4242\n")
    copied, _ := os.read_entire_file_from_path(folder + "/" + PIXEL_ART_FILE, context.temp_allocator)
    testing.expect_value(t, string(copied), bytes)
    source, _ := os.read_entire_file_from_path(art, context.temp_allocator)
    testing.expect_value(t, string(source), bytes)

    testing.expect(t, agent_sandbox_make(root + "/runs/two", 1, root + "_no_art"), "no sprite bank is no failure")
    testing.expect(t, !os.exists(root + "/runs/two/" + PIXEL_ART_FILE))
}

@(test)
the_title_a_key_asks_for_an_agent_and_then_only_esc_answers :: proc(t: ^testing.T) {
    for fresh in ([]bool{true, false}) {
        gs, link := agent_test_world()
        defer free(gs)
        defer free(link)
        gs.ui.show_title  = true
        gs.ui.title_fresh = fresh

        testing.expect(t, !title_key(gs, .A), "A stays on the title, resumed run or fresh")
        testing.expect(t, gs.ui.agent_requested)

        gs.ui.agent_requested = false
        gs.ui.agent_port = 7878
        testing.expect(t, !title_key(gs, .SPACE), "the address stays up")
        testing.expect(t, !title_key(gs, .A))
        testing.expect(t, !gs.ui.agent_requested, "one sandbox per boot")
        title_begin(gs)
        testing.expect(t, gs.ui.show_title, "a click does not close it either")
        testing.expect_value(t, gs.events.size, 0)
        title_key(gs, .ESCAPE)
        process_events(gs)
        testing.expect(t, gs.quit_requested, "Esc leaves: a fullscreen window has no other door")
    }
}

@(test)
the_title_still_starts_a_run_with_no_agent :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.ui.show_title = true
    title_begin(gs)
    testing.expect(t, !gs.ui.show_title)

    gs.ui.show_title  = true
    gs.ui.title_fresh = true
    title_begin(gs)
    testing.expect_value(t, gs.events.size, 1)
}

@(test)
the_title_seed_picks_the_agents_world_too :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    copy(gs.ui.title_seed[:], "4242")
    gs.ui.title_seed_len = 4
    testing.expect_value(t, title_chosen_seed(gs), 4242)
}

@(test)
a_boot_leaves_the_old_action_log_alone_until_a_run_starts :: proc(t: ^testing.T) {
    when !GAME_DEBUG { return }
    path :: "gnipa_action_held_scratch.log"
    os.remove(path)
    defer os.remove(path)
    _ = os.write_entire_file(path, transmute([]u8)string("the last run\n"))

    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.debug_log.path = path
    gs.debug_log.held = true
    gs.debug_log.pos  = 0
    log_action(gs, "held line")
    flush_action_log(gs)
    kept, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect_value(t, string(kept), "the last run\n")

    action_log_release(gs)
    flush_action_log(gs)
    now, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, !strings.contains(string(now), "the last run"), "a run owns its log")
    testing.expect(t, strings.contains(string(now), "held line"), "and nothing logged on the title is lost")

    log_action(gs, "second line")
    action_log_release(gs)
    flush_action_log(gs)
    now, _ = os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, strings.contains(string(now), "held line"), "a second release truncates nothing")
}

@(test)
a_title_start_releases_the_log_before_the_reset_loses_it :: proc(t: ^testing.T) {
    when !GAME_DEBUG { return }
    path :: "gnipa_action_title_scratch.log"
    os.remove(path)
    defer os.remove(path)
    _ = os.write_entire_file(path, transmute([]u8)string("the last run\n"))

    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.debug_log.path = path
    gs.debug_log.held = true
    gs.debug_log.pos  = 0
    log_action(gs, "run header")
    gs.ui.title_fresh = true
    start_title_game(gs)
    flush_action_log(gs)
    now, _ := os.read_entire_file_from_path(path, context.temp_allocator)
    testing.expect(t, !strings.contains(string(now), "the last run"))
    testing.expect(t, strings.contains(string(now), "run header"))
}

@(test)
a_won_run_is_a_screen_an_agent_can_read_and_leave :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.level_index = LEVEL_DIMENSION
    gs.dimension.kind = .Hell
    inventory_insert(&gs.player.inventory, .Hell_Key, 1)
    set_tile(&gs.world, 60, 40, .Final_Seal)
    gs.player.pos = {59, 41 - PLAYER_H}

    // The last act of a run, through the same seam as every other.
    agent_handle_line(link, gs, `{"cmd":"act","interact":true,"frames":1}`)
    agent_drive(link, gs)
    update_input(gs)
    process_events(gs)
    update_player(gs)
    testing.expect(t, gs.ritual.active && gs.ritual.seal, "interact beside the Seal begins the end")

    gs.ritual.timer = RITUAL_DURATION
    gs.delta_time = AGENT_STEP
    update_ritual(gs)
    process_events(gs)
    testing.expect(t, gs.game_won)
    agent_reply_state(link, gs, nil)
    testing.expect(t, strings.contains(agent_test_reply(link), `"screen":"book"`), "the saga comes first")

    agent_dismiss(gs)
    agent_reply_state(link, gs, nil)
    testing.expect(t, strings.contains(agent_test_reply(link), `"screen":"won"`), agent_test_reply(link)[:60])

    gs.agent.driving = true
    agent_dismiss(gs)
    process_events(gs)
    testing.expect(t, !gs.game_won, "a dismiss starts the next run")
}

@(test)
the_sandbox_run_starts_with_nothing_of_the_humans :: proc(t: ^testing.T) {
    save  :: "gnipa_agent_reset_scratch_save.dat"
    stats :: "gnipa_agent_reset_scratch_stats.dat"
    os.remove(save)
    defer os.remove(stats)
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.stats.runs_played = 9
    gs.stats.grave       = {active = true, hero = 1}
    gs.save_path         = ""   // a boot that set an unreadable save aside
    gs.player.hp         = 3
    gs.ui.agent_failed   = true
    inventory_insert(&gs.player.inventory, .Hell_Key, 1)

    agent_run_reset(gs, 4242, 7878, save, stats)

    testing.expect_value(t, gs.stats.runs_played, 0)
    testing.expect(t, !gs.grave.active && !gs.stats.grave.active, "the human's grave stays home")
    testing.expect_value(t, gs.save_path, save)
    testing.expect_value(t, gs.stats_path, stats)
    testing.expect_value(t, gs.world_seed, 4242)
    testing.expect_value(t, gs.player.hp, 10)
    testing.expect_value(t, inventory_count(&gs.player.inventory, .Hell_Key), 0)
    testing.expect(t, gs.ui.show_title, "the title holds the address")
    testing.expect(t, !gs.ui.title_fresh, "and an agent's dismiss closes it, not a seed prompt")
    testing.expect_value(t, gs.ui.agent_port, 7878)
    testing.expect(t, !gs.ui.agent_failed)
    testing.expect(t, os.exists(stats), "the run's stats go where it was told")
}

@(test)
the_boot_title_hook_stays_off_with_no_env_and_a_port_run_shows_its_address :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_boot_title(link, gs)
    testing.expect(t, !gs.ui.agent_requested, "nothing listens unless asked")
    testing.expect_value(t, gs.ui.agent_port, 0)

    link.listening = true
    link.port      = 7777
    gs.debug_log.held = true
    gs.debug_log.path = ""
    link.listening = true
    agent_boot_title(link, gs)
    testing.expect_value(t, gs.ui.agent_port, 7777)
    link.listening = false
}

@(test)
a_boot_arms_the_action_log_but_holds_it :: proc(t: ^testing.T) {
    when !GAME_DEBUG { return }
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    action_log_begin_run(gs)
    testing.expect_value(t, gs.debug_log.path, ACTION_LOG_PATH)
    testing.expect(t, gs.debug_log.held, "a boot has not started a run: the last run's log stays as it is")
    testing.expect(t, strings.contains(string(gs.debug_log.buf[:gs.debug_log.pos]), "=== run start"))
    gs.debug_log = {}  // never flushed: this test's folder is not a run's
}

// The watcher's keys, as agent_chat_poll hands them over.
@(private="file")
agent_test_type :: proc(link: ^Agent_Link, gs: ^Game_State, text: string) {
    agent_chat_key(link, gs, .ENTER)
    for ch in text do agent_chat_char(&link.panel, ch)
    agent_chat_key(link, gs, .ENTER)
}

@(private="file")
agent_test_heard :: proc(t: ^testing.T, reply: string, loc := #caller_location) -> json.Array {
    value, err := json.parse_string(reply, .JSON, allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None, loc = loc)
    heard, _ := value.(json.Object)["heard"].(json.Array)
    return heard
}

@(test)
agent_a_typed_line_reaches_the_client_once :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    p := &link.panel

    agent_chat_char(p, 'x')
    testing.expect_value(t, p.draft.len, 0)  // the field is shut: keys go nowhere
    agent_chat_key(link, gs, .ENTER)
    testing.expect(t, p.typing, "Enter opens the field")
    agent_chat_key(link, gs, .BACKSPACE)  // nothing to erase
    testing.expect_value(t, p.draft.len, 0)
    for ch in "dig dowx\u00e9\n" do agent_chat_char(p, ch)
    agent_chat_key(link, gs, .BACKSPACE)
    testing.expect_value(t, p.draft.buf[p.draft.len], 0)
    agent_chat_char(p, 'n')
    testing.expect_value(t, string(p.draft.buf[:p.draft.len]), "dig down")
    testing.expect_value(t, p.draft.buf[p.draft.len], 0)
    gs.frame = 77
    agent_chat_key(link, gs, .KP_ENTER)
    testing.expect(t, !p.typing, "Enter sends and closes")
    testing.expect_value(t, string(p.sent.buf[:p.sent.len]), "dig down")

    agent_handle_line(link, gs, `{"cmd":"state"}`)
    heard := agent_test_heard(t, agent_test_reply(link))
    testing.expect_value(t, len(heard), 1)
    if len(heard) == 1 {
        h := heard[0].(json.Object)
        testing.expect_value(t, h["text"].(json.String), "dig down")
        testing.expect_value(t, h["f"].(json.Float), 77)
    }
    agent_handle_line(link, gs, `{"cmd":"state"}`)
    testing.expect_value(t, len(agent_test_heard(t, agent_test_reply(link))), 0)

    // An act's reply reads them too.
    agent_test_type(link, gs, "a \"quoted\" \\ line")
    agent_handle_line(link, gs, `{"cmd":"act","frames":1}`)
    agent_drive(link, gs)
    agent_after_tick(link, gs)
    heard = agent_test_heard(t, agent_test_reply(link))
    testing.expect_value(t, len(heard), 1)
    if len(heard) == 1 do testing.expect_value(t, heard[0].(json.Object)["text"].(json.String), `a "quoted" \ line`)

    // Esc drops the draft; Enter on an empty field just closes it.
    agent_chat_key(link, gs, .ENTER)
    agent_chat_char(p, 'q')
    agent_chat_key(link, gs, .ESCAPE)
    testing.expect(t, !p.typing)
    testing.expect_value(t, p.draft.len, 0)
    agent_chat_key(link, gs, .ENTER)
    agent_chat_key(link, gs, .ENTER)
    testing.expect(t, !p.typing)
    testing.expect_value(t, p.heard_len, 0)

    // The field holds AGENT_TEXT_MAX characters.
    agent_chat_key(link, gs, .ENTER)
    for _ in 0 ..< AGENT_TEXT_MAX + 5 do agent_chat_char(p, 'z')
    testing.expect_value(t, p.draft.len, AGENT_TEXT_MAX)
    testing.expect_value(t, p.draft.buf[AGENT_TEXT_MAX], 0)
}

@(test)
agent_a_full_queue_keeps_the_line_in_the_field :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    p := &link.panel
    for i in 0 ..< AGENT_HEARD_MAX do agent_test_type(link, gs, fmt.tprintf("line %d", i))
    testing.expect_value(t, p.heard_len, AGENT_HEARD_MAX)
    agent_test_type(link, gs, "one more")
    testing.expect(t, p.typing, "nothing is lost: the line waits")
    testing.expect_value(t, string(p.draft.buf[:p.draft.len]), "one more")
    testing.expect_value(t, p.heard_len, AGENT_HEARD_MAX)

    agent_handle_line(link, gs, `{"cmd":"state"}`)
    heard := agent_test_heard(t, agent_test_reply(link))
    testing.expect_value(t, len(heard), AGENT_HEARD_MAX)
    if len(heard) == AGENT_HEARD_MAX {
        testing.expect_value(t, heard[0].(json.Object)["text"].(json.String), "line 0")  // oldest first
    }
    agent_chat_key(link, gs, .ENTER)
    testing.expect_value(t, p.heard_len, 1)
    testing.expect(t, !p.typing)
}

@(test)
agent_say_reaches_the_screen_state :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"say","text":"Heading down\tto the gold"}`)
    testing.expect_value(t, agent_test_reply(link), `{"ok":true}` + "\n")
    agent_drive(link, gs)
    testing.expect(t, gs.agent.panel == &link.panel, "render reads the say through gs.agent.panel")
    say := &gs.agent.panel.say
    testing.expect_value(t, string(say.buf[:say.len]), "Heading down to the gold")

    long := strings.repeat("y", AGENT_TEXT_MAX + 20, context.temp_allocator)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"say","text":"%s"}}`, long))
    testing.expect_value(t, link.panel.say.len, AGENT_TEXT_MAX)

    agent_test_refused(t, link, gs, `{"cmd":"say"}`)
    agent_test_refused(t, link, gs, `{"cmd":"say","text":""}`)
    agent_test_refused(t, link, gs, `{"cmd":"say","text":5}`)
    testing.expect_value(t, link.panel.say.len, AGENT_TEXT_MAX)

    when GAME_DEBUG {
        testing.expect(t, strings.contains(string(gs.debug_log.buf[:gs.debug_log.pos]), "Agent says: Heading down to the gold"))
        agent_test_type(link, gs, "come back up")
        testing.expect(t, strings.contains(string(gs.debug_log.buf[:gs.debug_log.pos]), "Watcher says: come back up"))
    }
}

@(test)
agent_listen_answers_when_the_watcher_speaks_or_time_is_up :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"listen","seconds":30}`)
    testing.expect(t, link.awaiting)
    testing.expect_value(t, link.out_len, 0)
    testing.expect(t, !agent_listening(link), "the next line waits for the answer")
    now := time.tick_now()
    agent_await(link, gs, now)
    testing.expect(t, link.awaiting && !link.reply_due)

    agent_test_type(link, gs, "hello")
    agent_await(link, gs, now)
    testing.expect(t, !link.awaiting && link.reply_due)
    heard := agent_test_heard(t, agent_test_reply(link))
    testing.expect_value(t, len(heard), 1)
    testing.expect(t, strings.has_prefix(agent_test_reply(link), `{"ok":true,"frame"`), "the answer is state")
    testing.expect(t, agent_listening(link))
    link.reply_due = false

    // A line already waiting is answered at once.
    agent_test_type(link, gs, "again")
    agent_handle_line(link, gs, `{"cmd":"listen"}`)
    testing.expect(t, !link.awaiting)
    testing.expect(t, !link.reply_due, "answered once, by the read's send, not again by the pump")
    testing.expect_value(t, len(agent_test_heard(t, agent_test_reply(link))), 1)

    // Time up: state, with nothing heard.
    agent_handle_line(link, gs, `{"cmd":"listen","seconds":2}`)
    testing.expect_value(t, link.out_len, 0)  // no answer yet, not the last one again
    agent_await(link, gs, time.tick_add(time.tick_now(), 1500 * time.Millisecond))
    testing.expect(t, link.awaiting)
    agent_await(link, gs, time.tick_add(time.tick_now(), 2 * time.Second))
    testing.expect(t, !link.awaiting && link.reply_due)
    testing.expect_value(t, len(agent_test_heard(t, agent_test_reply(link))), 0)
    link.reply_due = false

    // The default wait is AGENT_LISTEN_S.
    agent_handle_line(link, gs, `{"cmd":"listen"}`)
    agent_await(link, gs, time.tick_add(time.tick_now(), (AGENT_LISTEN_S - 1) * time.Second))
    testing.expect(t, link.awaiting)
    agent_await(link, gs, time.tick_add(time.tick_now(), AGENT_LISTEN_S * time.Second))
    testing.expect(t, !link.awaiting)
    link.reply_due = false

    agent_test_refused(t, link, gs, `{"cmd":"listen","seconds":0}`)
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"listen","seconds":%d}}`, AGENT_LISTEN_MAX_S + 1))
    agent_test_refused(t, link, gs, `{"cmd":"listen","seconds":"soon"}`)
    testing.expect(t, !link.awaiting)
    agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"listen","seconds":%d}}`, AGENT_LISTEN_MAX_S))
    testing.expect(t, link.awaiting)
}

// Typing is the watcher's: the game it is typed over does not move.
@(test)
agent_typing_changes_nothing_in_the_game :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_drive(link, gs)
    before := new(Game_State)
    defer free(before)
    before^ = gs^

    for k in ([]rl.KeyboardKey{.ENTER, .E, .SPACE, .A, .D, .W, .ESCAPE, .TAB, .I, .F3, .ENTER, .BACKSPACE, .ENTER}) {
        agent_chat_key(link, gs, k)
        for ch in "wasd e1" do agent_chat_char(&link.panel, ch)
    }
    agent_test_type(link, gs, "jump now")
    agent_chat_key(link, gs, .ENTER)
    agent_chat_key(link, gs, .ESCAPE)
    testing.expect(t, link.panel.heard_len >= 2, "the lines went to the agent")

    before.debug_log = {}  // action.log records the talk; that is not the game
    gs.debug_log = {}
    testing.expect(t, runtime.memory_equal(before, gs, size_of(Game_State)), "typing touched Game_State")
}

// A run with talk records it and replays to the same game, as agent_replay.py does.
@(test)
agent_talk_is_recorded_and_the_replay_matches :: proc(t: ^testing.T) {
    start :: proc(gs: ^Game_State, link: ^Agent_Link) {
        game_state_init(gs, 779)
        gs.ui.show_title = false
        gs.player.pos = SURFACE_HOME_POS
        link.connected = true
        link.idle_off = true
    }
    play :: proc(link: ^Agent_Link, gs: ^Game_State, line: string) {
        agent_handle_line(link, gs, line)
        for link.frames_left > 0 {
            if agent_drive(link, gs) {
                game_update(gs)
                agent_after_tick(link, gs)
            }
        }
    }
    path := "agent_talk_test.jsonl"
    defer os.remove(path)

    gs := new(Game_State)
    defer free(gs)
    link := new(Agent_Link)
    defer free(link)
    start(gs, link)
    f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    testing.expect(t, err == nil)
    link.acts_file = f
    agent_test_type(link, gs, "before the recording")
    play(link, gs, `{"cmd":"say","text":"unrecorded"}`)
    link.recording = true
    play(link, gs, `{"cmd":"act","move":"right","frames":20}`)
    agent_test_type(link, gs, `go "left"`)
    play(link, gs, `{"cmd":"say","text":"going left"}`)
    play(link, gs, `{"cmd":"act","move":"left","frames":25}`)
    agent_test_type(link, gs, "thanks")
    play(link, gs, `{"cmd":"act","jump":true,"frames":15}`)
    link.recording = false
    os.close(f)

    data, read_err := os.read_entire_file(path, context.allocator)
    testing.expect(t, read_err == nil)
    defer delete(data)
    rows := strings.split_lines(strings.trim_right_space(string(data)))
    defer delete(rows)
    testing.expect_value(t, len(rows), 6)
    testing.expect_value(t, rows[1], `{"f":20,"heard":"go \"left\""}`)
    testing.expect_value(t, rows[2], `{"f":20,"say":"going left"}`)
    testing.expect_value(t, rows[4], `{"f":45,"heard":"thanks"}`)

    gs2 := new(Game_State)
    defer free(gs2)
    link2 := new(Agent_Link)
    defer free(link2)
    start(gs2, link2)
    for row in rows {
        value, perr := json.parse_string(row, .JSON, allocator = context.temp_allocator)
        testing.expect_value(t, perr, json.Error.None)
        rec := value.(json.Object)
        if "heard" in rec do continue
        if said, ok := rec["say"].(json.String); ok {
            play(link2, gs2, fmt.tprintf(`{{"cmd":"say","text":%q}}`, said))
            continue
        }
        act := agent_canonical(rec["act"])
        defer delete(act)
        play(link2, gs2, act)
    }
    testing.expect_value(t, gs2.frame, gs.frame)
    testing.expect_value(t, gs2.player.pos, gs.player.pos)
    testing.expect_value(t, gs2.player.hp, gs.player.hp)
    testing.expect_value(t, string(link2.panel.say.buf[:link2.panel.say.len]), "going left")
}

// Over the socket: a listen holds until the watcher types, and a client that goes
// while it listens is let go at once.
@(test)
a_listening_client_hears_the_watcher_over_the_socket :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)

    client, _ := net.dial_tcp(at)
    out := agent_test_ask(gs, link, client, `{"cmd":"listen","seconds":30}` + "\n" + `{"cmd":"say","text":"queued"}` + "\n", 1, buf[:200])
    testing.expect_value(t, out, "")  // ran out of tries: nothing came back
    testing.expect(t, link.connected && link.awaiting)
    testing.expect_value(t, link.panel.say.len, 0)  // the say waits behind the listen

    agent_test_type(link, gs, "are you there")
    out = agent_test_ask(gs, link, client, "", 2, buf[:])
    testing.expect(t, strings.contains(out, `"heard":[{"f":`), out[:min(len(out), 80)])
    testing.expect(t, strings.contains(out, `"text":"are you there"`))
    testing.expect(t, strings.has_suffix(out, `{"ok":true}` + "\n"), "then the held line is answered")
    testing.expect_value(t, string(link.panel.say.buf[:link.panel.say.len]), "queued")

    // A line typed during an act is waiting when the listen comes: one answer, at once.
    agent_test_type(link, gs, "typed while you played")
    out = agent_test_ask(gs, link, client, `{"cmd":"listen","seconds":30}` + "\n", -1, buf[:])
    testing.expect_value(t, strings.count(out, "\n"), 1)
    testing.expect(t, strings.contains(out, `"text":"typed while you played"`))
    testing.expect(t, !link.awaiting)
    out = agent_test_ask(gs, link, client, `{"cmd":"say","text":"next"}` + "\n", 1, buf[:200])
    testing.expect_value(t, out, `{"ok":true}` + "\n")  // and the next reply is the next request's

    agent_test_ask(gs, link, client, `{"cmd":"listen","seconds":30}` + "\n", 1, buf[:200])
    testing.expect(t, link.awaiting)
    net.close(client)
    for _ in 0 ..< 2000 {
        agent_pump(link, gs)
        if !link.connected do break
    }
    testing.expect(t, !link.connected, "a client gone during a listen is dropped")
    testing.expect(t, !link.awaiting)
}
