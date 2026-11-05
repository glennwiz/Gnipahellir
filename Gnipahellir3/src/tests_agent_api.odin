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
    for agent_goals_busy(&link.goals) {
        if agent_test_input(link, gs) {
            process_events(gs)
            eq_clear(&gs.events)
            gs.frame += 1
            agent_after_tick(link, gs)
        }
    }
}

// What main's frame does for the agent's input: the drive, then on a tick the
// executor and the input it feeds.
agent_test_input :: proc(link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    tick = agent_drive(link, gs)
    update_agent_goals(gs)
    agent_input(gs)
    return
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
        testing.expectf(t, strings.contains(agent_test_reply(link), `"ok":false`), "%s -> %s", line, agent_test_reply(link))
        testing.expect(t, !agent_goals_busy(&link.goals))
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
        testing.expect(t, agent_test_input(link, gs))
        testing.expect_value(t, gs.agent.first, i == 0)
        agent_after_tick(link, gs)
    }
    testing.expect(t, link.out_len > 0, "the act answers when it has run out")
    testing.expect(t, !agent_drive(link, gs))

    link.realtime = true
    testing.expect(t, agent_drive(link, gs), "realtime keeps ticking")
}

@(test)
agent_held_input_holds_and_one_shots_fire_once :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act","move":"right","jump":true,"frames":2}`)
    agent_test_input(link, gs)
    testing.expect(t, gs.input.move_right)
    testing.expect(t, gs.input.jump)

    agent_test_input(link, gs)
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
    agent_test_input(link, gs)
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
    agent_test_input(link, gs)
    testing.expect(t, !gs.input.mine, "the same rule update_input applies to a click")
}

@(test)
agent_place_goes_through_the_event_queue :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act","place":[30,40],"frames":2}`)
    agent_test_input(link, gs)
    testing.expect_value(t, gs.events.size, 1)
    eq_clear(&gs.events)
    agent_test_input(link, gs)
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
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":false`), "a hidden recipe is not offered")
}

// Card 160, playtest 127: state's recipes is the crafting book: each recipe
// the window shows by the same unlock rule, craftable now or not, with its
// count, station and needs; a hidden one is not there.
@(test)
agent_state_lists_the_recipe_book :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.progression.recipe_unlocked = {}
    reveal_recipe(&gs.progression, .Smelter)
    reveal_recipe(&gs.progression, .Plank)
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    value, err := json.parse_string(agent_test_reply(link), parse_integers = true, allocator = context.temp_allocator)
    testing.expect_value(t, err, json.Error.None)
    root, _ := value.(json.Object)
    book, is_list := root["recipes"].(json.Array)
    testing.expect(t, is_list, "state has recipes")
    names := make([dynamic]string, context.temp_allocator)
    for r in book {
        o, _ := r.(json.Object)
        name, _ := o["item"].(json.String)
        append(&names, name)
        if name != "Smelter" do continue
        station, _ := o["station"].(json.String)
        testing.expect_value(t, station, "Crafting_Bench")
        testing.expect_value(t, o["count"].(json.Integer), 1)
        needs, _ := o["needs"].(json.Array)
        testing.expect_value(t, len(needs), 2)
        n0, _ := needs[0].(json.Object)
        n1, _ := needs[1].(json.Object)
        testing.expect(t, n0["item"].(json.String) == "Stone_Block" && n0["count"].(json.Integer) == 8, "8 stone")
        testing.expect(t, n1["item"].(json.String) == "Iron_Ore" && n1["count"].(json.Integer) == 2, "2 iron ore")
    }
    testing.expectf(t, len(names) == 2 && names[0] == "Plank" && names[1] == "Smelter", "the revealed two, in book order: %v", names[:])
    plank, _ := book[0].(json.Object)
    testing.expect_value(t, plank["station"].(json.String), "hand")
    testing.expect_value(t, plank["count"].(json.Integer), 4)  // the recipe's own count, not 1 for all
    craftable, _ := root["craftable"].(json.Array)
    testing.expect_value(t, len(craftable), 0)  // the bag is empty: the book still lists them
    testing.expect(t, strings.contains(agent_write_brief(link, gs), "state's recipes is the crafting book"), "the brief names it")
}

// Card 160, playtest 133: state carries the saga page a player reads in the
// book (the record across runs), and on the death screen its line with the
// place; the brief names both.
@(test)
agent_state_carries_the_saga_and_the_death_line :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.stats.runs_played, gs.stats.runs_won, gs.stats.total_kills, gs.stats.deepest_cave = 5, 1, 37, 2
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    reply := agent_test_reply(link)
    testing.expect(t, strings.contains(reply, `"Heroes fallen before you: 4","Foes slain by all of them: 37","Deepest reached: `), reply[:min(len(reply), 200)])
    testing.expect(t, !strings.contains(reply, `"death_line"`), "alive: no death line")
    gs.player.dead = true
    gs.death_by = "Lava"
    gs.level_index = LEVEL_CAVE2
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    reply = agent_test_reply(link)
    want := fmt.tprintf(`"death_line":"Killed by Lava - %s"`, level_names[LEVEL_CAVE2])
    testing.expectf(t, strings.contains(reply, want), "want %s", want)
    brief := agent_write_brief(link, gs)
    testing.expect(t, strings.contains(brief, "state's saga is the book's saga page") && strings.contains(brief, "death_line is the death screen's line"), "the brief names them")
}

// Card 160, playtest 134: a block in mid-fall is out of the grid, so state
// lists it under falling, inside the view only; the brief names it.
@(test)
agent_state_lists_falling_blocks :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gravity_spawn(gs, 40, 20, .Wood)
    gs.gravity.blocks[0].y = 20.5
    agent_handle_line(link, gs, `{"cmd":"state","x":35,"y":15,"w":10,"h":10}`)
    reply := agent_test_reply(link)
    testing.expect(t, strings.contains(reply, `"falling":[{"tile":"Wood","x":40,"y":20.50}]`), reply[:min(len(reply), 120)])
    // Each edge of the view, the block just inside it and just past it (the
    // block's row is 20, its y 20.5).
    Edge :: struct { x, y, w, h: int, listed: bool }
    for e in ([]Edge{
        {40, 15, 10, 10, true}, {41, 15, 10, 10, false},  // left edge
        {31, 15, 10, 10, true}, {30, 15, 10, 10, false},  // right edge
        {35, 20, 10, 10, true}, {35, 21, 10, 10, false},  // top edge
        {35, 11, 10, 10, true}, {35, 10, 10, 10, false},  // bottom edge
    }) {
        agent_handle_line(link, gs, fmt.tprintf(`{{"cmd":"state","x":%d,"y":%d,"w":%d,"h":%d}}`, e.x, e.y, e.w, e.h))
        listed := strings.contains(agent_test_reply(link), `"falling":[{"tile":"Wood","x":40`)
        testing.expectf(t, listed == e.listed, "%v: listed %v", e, listed)
    }
    gs.gravity.blocks[0].active = false
    agent_handle_line(link, gs, `{"cmd":"state","x":35,"y":15,"w":10,"h":10}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"falling":[]`), "landed: not listed")
    testing.expect(t, strings.contains(agent_write_brief(link, gs), "state's falling lists the blocks in mid-fall"), "the brief names it")
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

// Card 165: state carries the game's objective line.
@(test)
agent_state_carries_the_objective :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    buf: [128]u8
    want := current_objective(gs, buf[:127])
    testing.expect(t, len(want) > 0, "a fresh run has an objective")
    agent_handle_line(link, gs, `{"cmd":"state"}`)
    testing.expectf(t, strings.contains(agent_test_reply(link), fmt.tprintf(`"objective":%s,`, agent_quote(want))), "state: %s", agent_test_reply(link))
    testing.expect(t, strings.contains(agent_write_brief(link, gs), "state's objective is the game's objective line"), "the brief tells it")

    // One of the card's longest lines goes through whole, in state and in the
    // brief: tier B's ritual, no altar in the sky yet.
    gs.progression.sky_altar_pos = {10, SURFACE_Y - 1}
    set_tile(&gs.world, 10, SURFACE_Y - 1, .Sky_Altar)
    gs.progression.sky_structure_complete[0] = true
    gs.progression.rune_scroll_found = {true, true, false}
    long := fmt.tprintf("Sky ritual: 12 Cloud Stone + 6 Silver Bar - build a Silver-Gold Altar in the Low Sky, [%v] at it", gs.bindings[.Interact])
    testing.expect(t, len(long) > 90, "the line is one of the long ones")
    agent_handle_line(link, gs, `{"cmd":"state"}`)
    testing.expectf(t, strings.contains(agent_test_reply(link), fmt.tprintf(`"objective":"%s",`, long)), "state: %s", agent_test_reply(link))
    testing.expect(t, strings.contains(agent_write_brief(link, gs), fmt.tprintf("the game's objective line: %s\n", long)), "the brief carries it whole")
}

@(test)
agent_death_screen_gives_no_orders :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    gs.player.dead = true
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","place":[30,40]}`)
    agent_test_input(link, gs)
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
    for agent_goals_busy(&link.goals) {
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
    agent_test_input(link, gs)
    testing.expect(t, gs.agent.first)

    link.listening = true  // agent_pump's early out; the socket is never touched
    link.connected = false
    link.goals = {}
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
    agent_test_input(link, gs)
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
    agent_test_input(link, gs)
    eq_clear(&gs.events)
    testing.expect(t, gs.ui.show_smelter, "a window verb keeps its window")
    link.goals = {}

    agent_handle_line(link, gs, `{"cmd":"act","move":"left"}`)
    agent_test_input(link, gs)
    testing.expect(t, !gs.ui.show_smelter, "any other act closes it")
    testing.expect(t, !gs.ui.show_inventory)
}

@(test)
agent_frames_the_view_for_a_watcher_again_after_a_new_game :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act"}`)
    agent_test_input(link, gs)
    testing.expect_value(t, gs.zoom_target, AGENT_VIEW_ZOOM)

    gs.zoom_target = 3  // the wheel's choice stands for the rest of the game
    agent_input(gs)
    testing.expect_value(t, gs.zoom_target, f32(3))

    game_state_init(gs)  // what New Game does: zooms out and forgets
    agent_test_input(link, gs)
    testing.expect_value(t, gs.zoom_target, AGENT_VIEW_ZOOM)
}

@(test)
agent_view_glide_finishes_while_the_game_waits :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"act"}`)
    agent_test_input(link, gs)
    link.goals = {}
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
            for agent_goals_busy(&link.goals) {
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
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":false`))

    gs.player.equipment[Equip_Slot(1)] = .Jade_Ring
    gs.level_index = 1  // the surface refuses: home already
    agent_handle_line(link, gs, `{"cmd":"act","warp":true}`)
    testing.expect(t, agent_goals_busy(&link.goals))
    agent_test_input(link, gs)
    testing.expect_value(t, gs.events.size, 1)
    eq_clear(&gs.events)
    link.goals = {}

    agent_handle_line(link, gs, `{"cmd":"act","reclaim":[20,40],"frames":2}`)
    for _ in 0 ..< 2 {
        agent_test_input(link, gs)
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
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":false`), agent_test_reply(link))
    testing.expect(t, strings.contains(agent_test_reply(link), "Already on the surface"), agent_test_reply(link))
    testing.expect(t, !agent_goals_busy(&link.goals))

    gs.level_index = 1
    agent_handle_line(link, gs, `{"cmd":"act","warp":true}`)
    testing.expect(t, agent_goals_busy(&link.goals))
}

@(test)
agent_a_queued_warp_is_judged_when_its_goal_starts :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    // Refused now, but a queued goal's world has not happened yet: the start decides.
    gs.player.equipment[Equip_Slot(1)] = .Jade_Ring
    gs.level_index = LEVEL_SURFACE
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","warp":true}]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":true`), agent_test_reply(link))
    for _ in 0 ..< AGENT_IDLE_EVERY * 3 do if agent_test_input(link, gs) do agent_after_tick(link, gs)
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
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":false`), "withdraw needs the window")

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

    path := test_scratch_path("agent_fight_test.log")
    defer delete(path)
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
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":false`))
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
    agent_test_input(link, gs)
    agent_after_tick(link, gs)
    testing.expect_value(t, link.idle_ticks, 0)
    for _ in 0 ..< AGENT_IDLE_EVERY do if agent_test_input(link, gs) do agent_after_tick(link, gs)
    testing.expect_value(t, link.idle_ticks, 1)

    link.idle_off = true
    for _ in 0 ..< AGENT_IDLE_EVERY * 2 do testing.expect(t, !agent_drive(link, gs))
}

@(test)
agent_goals_play_at_full_speed_and_an_act_overrides_them :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"left","frames":3},{"do":"act","move":"right","frames":2}]}`)
    link.out_len = 0

    for _ in 0 ..< 4 {
        testing.expect(t, agent_test_input(link, gs), "goals tick every frame")
        agent_after_tick(link, gs)
    }
    h := agent_goals_head(&link.goals)
    testing.expect(t, h != nil && h.via == .Goal && h.id == 2 && h.frames_left == 1)
    testing.expect_value(t, link.out_len, 0)  // nobody is waiting on a goal
    testing.expect(t, link.reply_due == false)
    testing.expect(t, agent_listening(link))

    agent_handle_line(link, gs, `{"cmd":"act","frames":2}`)
    h = agent_goals_head(&link.goals)
    testing.expect(t, h != nil && h.via == .Act && h.status == .Queued)
    testing.expect_value(t, agent_test_pending(link), 1)
}

// The goals that have yet to finish.
@(private="file")
agent_test_pending :: proc(link: ^Agent_Link) -> (n: int) {
    for &g in link.goals.slots[:link.goals.n] do if g.status == .Queued || g.status == .Running do n += 1
    return
}

@(test)
agent_override_keeps_its_own_input :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":50}]}`)
    if agent_test_input(link, gs) do agent_after_tick(link, gs)
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":30}`)
    agent_test_input(link, gs)
    testing.expect(t, gs.input.move_left && !gs.input.move_right)
    testing.expect(t, gs.agent.first)
}

// A queued goal is a promise about a world that has not happened yet, so what
// depends on that world is judged when the goal starts; the next goal still plays.
@(test)
agent_goals_judge_state_verbs_when_they_start :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":1},{"do":"act","feed":0},{"do":"act","frames":5}]}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), `"ok":true`))

    for _ in 0 ..< 3 do if agent_test_input(link, gs) do agent_after_tick(link, gs)
    h := agent_goals_head(&link.goals)
    testing.expect(t, h != nil && h.id == 3, "the goal after the failed one plays")
    agent_handle_line(link, gs, `{"cmd":"state","w":1,"h":1}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), `{"id":2,"do":"act","status":"failed","reason":"no smelter`), string(link.out[:link.out_len]))
}

@(test)
agent_goals_add_is_all_or_nothing :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"left"}]}`)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"left"},{"do":"act","frames":0}]}`)
    testing.expect(t, strings.contains(string(link.out[:link.out_len]), "goal 1"), string(link.out[:link.out_len]))
    testing.expect_value(t, agent_test_pending(link), 1)  // the good goal stands
}

// The plan, wait, idle and realtime commands are retired (card 154): each
// answers so, and changes nothing; the game keeps running in real time.
@(test)
agent_retired_commands_say_so_and_change_nothing :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.realtime, link.idle_off = true, false
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":50}]}`)
    for line in ([]string{
        `{"cmd":"plan","acts":[{"move":"left","frames":3}]}`, `{"cmd":"wait","frames":3}`,
        `{"cmd":"idle","on":false}`, `{"cmd":"realtime","on":false}`,
    }) {
        agent_handle_line(link, gs, line)
        reply := agent_test_reply(link)
        testing.expectf(t, strings.contains(reply, `"ok":false`) && strings.contains(reply, "is retired, use goals"), "%s -> %s", line, reply)
        testing.expectf(t, agent_test_pending(link) == 1 && agent_goals_head(&link.goals).id == 1, "%s: the queue stands", line)
        testing.expectf(t, link.realtime && !link.idle_off, "%s: the game still runs in real time", line)
    }
    agent_handle_line(link, gs, `{"cmd":"fly"}`)
    unknown := agent_test_reply(link)
    testing.expectf(t, strings.contains(unknown, "use state, act, goals") && !strings.contains(unknown, "plan") && !strings.contains(unknown, "realtime"), "an unknown cmd lists only the live ones: %s", unknown)
}

// What a replay does with a recording must be what the acts did: this plays the
// real rows back, act by act, as the old replay did.
@(test)
agent_recorded_acts_replay_from_their_rows :: proc(t: ^testing.T) {
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
    path := test_scratch_path("agent_plan_test.jsonl")
    defer delete(path)
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
    agent_handle_line(link, gs, `{"cmd":"act","move":"right","frames":40}`)
    run(link, gs, 40)
    agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":10}`)
    run(link, gs, 10)
    link.recording = false
    os.close(f)

    data, read_err := os.read_entire_file(path, context.allocator)
    testing.expect(t, read_err == nil)
    defer delete(data)
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
            if "goal" in rec || "clear" in rec || "cancel" in rec || "done" in rec || "failed" in rec || "window" in rec do continue  // the goal replay's rows
            if n, ok := agent_int(rec, "idle"); ok {
                append(&replay, Replay_Row{fmt.aprintf(`{{"cmd":"act","frames":%d}}`, n, allocator = heap), n})
                continue
            }
            act := rec["act"].(json.Object)
            frames, _ := agent_int(act, "frames")
            append(&replay, Replay_Row{fmt.aprintf("%s", agent_canonical(act), allocator = heap), frames})
        }
    }
    for r in replay {
        agent_handle_line(link2, gs2, r.line)
        testing.expect(t, agent_goals_busy(&link2.goals), r.line)
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
            for agent_goals_busy(&link.goals) {
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
    testing.expect(t, strings.contains(string(reply[:got]), `"ok":true`))

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
    for agent_goals_busy(&link.goals) {
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
    testing.expectf(t, strings.contains(agent_test_reply(link), `"ok":false`), "%s -> %s", line, agent_test_reply(link), loc = loc)
    testing.expect(t, !agent_goals_busy(&link.goals), loc = loc)
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
    agent_test_input(link, gs)
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
    agent_test_refused(t, link, gs, `{"cmd":"goals","add":[{"do":"act","count":3}]}`)
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
    sock, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0}, AGENT_PENDING_MAX)
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
    testing.expect(t, link.pending_n == 0, "and the connection is closed")

    client, _ := net.dial_tcp(at)
    defer net.close(client)
    out := agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, `"ok":true`))
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
                          "game's objective line: ", `"cmd":"act"`, "it drops what is queued and answers with state", `"cmd":"goals"`, `"cmd":"objective"`, "HOW THE GAME WAITS", "FIRST STEPS", `"move":"right"`, "TALK", "Read state's heard", `"cmd":"say"`, `"cmd":"listen"`, "Final Seal", "\"127.0.0.1\", 40123"}) {
        testing.expect(t, strings.contains(brief, want), want)
    }
    for retired in ([]string{`"cmd":"plan"`, `"cmd":"wait"`, `"cmd":"idle"`, `"cmd":"realtime"`}) do testing.expect(t, !strings.contains(brief, retired), retired)
    testing.expect(t, strings.contains(brief, "another agent is connected"), "the link has a client")
    tail := strings.trim_right_space(AGENT_LESSONS)
    testing.expect(t, strings.has_suffix(strings.trim_right_space(brief), tail[len(tail) - 40:]), "the lessons fit, all of them")
    testing.expect(t, !strings.contains(brief, "agent_play.sh"), "the lessons' harness head stays out")
    testing.expect(t, strings.contains(brief, AGENT_LESSONS_FROM))
    testing.expect(t, !strings.contains(brief, "%!"), "no format string went wrong")
    link.connected = false
    testing.expect(t, strings.contains(agent_write_brief(link, gs), "none, the socket is free"))
}

// Card 142: the brief is for goal play.  It names every goal kind in the table
// with its params (built from the table, so a new kind cannot be left out), says
// real time is fixed, carries the binary's options, and tells the truth about
// bare hands from the mining rule.
@(test)
the_brief_names_every_goal_kind_and_the_binary_options :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    brief := agent_write_brief(link, gs)
    for row in agent_goal_kinds do testing.expectf(t, strings.contains(brief, fmt.tprintf("    %s: %s\n", row.name, row.params)), "the brief names the %s goal", row.name)
    testing.expect(t, strings.contains(brief, "Real time is fixed: no command pauses or slows it"))
    testing.expect(t, strings.contains(brief, TOOL_USAGE), "the gnipa options, as --help gives them")
    testing.expect(t, strings.contains(brief, fmt.tprintf("Bare hands mine only %s, at %d times", terrain_table[BARE_HAND_TILE].name, BARE_HAND_MULT)))
    testing.expect(t, !strings.contains(brief, "Bare hands mine, slowly"))
    // Every behaviour that can pause a goal is named as a pause reason.
    _, _, reasons := strings.partition(brief, "goal_resumed (id, reason: ")
    reasons, _, _ = strings.partition(reasons, ")")
    for row, k in hero_behaviours do if k != .Work_Goal && k != .Idle && row.name != "" {
        testing.expectf(t, strings.contains(reasons, row.name), "the brief names %s as a pause reason: %q", row.name, reasons)
    }
    for want in ([]string{
        "You only send goals: the game turns each into the keys and mouse a player would use",
        "an act holds its keys for 1..", "The act fields, for an act goal:", `{"cmd":"act",...}  one act goal`,
        `A trip: {"cmd":"goals","add":[{"do":"go"`, "THE GAME BINARY", "One binary does everything",
        "earlier runs, most of them by a scripted bot", "## How to play it\n- Hold one connection for the whole run",
    }) {
        testing.expect(t, strings.contains(brief, want), want)
    }
    // The shipped lessons start at the brief's header, at How to play it: the
    // repo head before it and the notes after the first section stay out.
    testing.expect(t, strings.contains(brief, "\nLESSONS FROM EARLIER RUNS\nThese come from earlier runs, most of them by a scripted bot before goals.\n\n## How to play it\n"), "the lessons start at How to play it")
    for head in ([]string{"Read this before an agent run", "## While you think"}) do testing.expect(t, !strings.contains(brief, head), head)
    when GAME_DEBUG do testing.expect(t, strings.contains(brief, "Every run folder holds acts.jsonl, action.log and fight.log.\n"))
    else do testing.expect(t, strings.contains(brief, "Every run folder holds acts.jsonl and fight.log.\n"), "a release build writes no action.log")
}

@(test)
the_brief_is_served_while_a_client_plays_and_a_second_client_watches :: proc(t: ^testing.T) {
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
    reply = agent_test_ask(gs, link, second, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(reply, `"re":"state","ok":true`), reply[:min(len(reply), 60)])
    testing.expect_value(t, link.pending_n, 0)
    testing.expect_value(t, link.readers_n, 1)
    net.close(second)

    out := agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, `"ok":true`), "the first client never noticed")
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
    testing.expect(t, strings.contains(reply, `"ok":false`), reply)
    testing.expect(t, !link.connected, "a page's POST body does not get to play")
    testing.expect(t, !agent_goals_busy(&link.goals))
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
        if link.pending_n > 0 do break
    }
    testing.expect_value(t, link.pending_n, 1)
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
    link.realtime = false
    link.panel.goal.len = 3
    agent_goals_push(&link.goals, .Act, .Goal, `{"do":"act"}`)
    link.events_on = true

    client, _ := net.dial_tcp(at)
    defer net.close(client)
    agent_test_ask(gs, link, client, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect_value(t, gs.frame, 0)
    testing.expect(t, !link.idle_off && link.realtime, "a new client starts in real time")
    testing.expect(t, link.goals.n == 0 && !link.events_on, "with no goals of the last one's, and no events yet")
    frame := gs.frame
    testing.expect(t, agent_pump(link, gs) && agent_pump(link, gs), "and the game ticks with nobody sending")
    testing.expect_value(t, gs.frame, frame)  // agent_pump only says so: main's game_update moves the clock
    testing.expect_value(t, link.panel.goal.len, 0)
}

// The two title tests bind fixed ports, so those sit below Linux's ephemeral
// range (32768-60999): in it, a client socket from a test that listens on port 0
// can hold the next port and this one gets the one after.  Clear of 7777/7878.
@(test)
the_title_only_binds_loopback_and_steps_past_a_taken_port :: proc(t: ^testing.T) {
    first, port, ok := agent_title_bind(23311)
    testing.expect(t, ok)
    defer net.close(first)
    testing.expect_value(t, port, 23311)
    at, err := net.bound_endpoint(first)
    testing.expect_value(t, err, nil)
    testing.expect_value(t, at.address, net.Address(net.IP4_Loopback))

    second, next, ok2 := agent_title_bind(23311)
    testing.expect(t, ok2)
    defer net.close(second)
    testing.expect_value(t, next, 23312)
}

@(test)
the_title_bind_gives_up_when_every_port_is_taken :: proc(t: ^testing.T) {
    socks: [AGENT_TITLE_PORTS]net.TCP_Socket
    for &s, i in socks do s, _ = net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 23331 + i}, 1)
    defer for s in socks do net.close(s)
    _, _, ok := agent_title_bind(23331)
    testing.expect(t, !ok)
}

@(test)
a_sandbox_holds_its_marker_seed_and_a_copy_of_the_sprites :: proc(t: ^testing.T) {
    root := test_scratch_path("gnipa_agent_sandbox_scratch")
    defer delete(root)
    art  := fmt.aprintf("%s_art.dat", root)
    defer delete(art)
    defer os.remove_all(root)
    defer os.remove(art)
    bytes := "not the real sprite bank"
    testing.expect(t, os.write_entire_file(art, transmute([]u8)bytes) == nil)

    folder := fmt.aprintf("%s/runs/one", root)
    defer delete(folder)
    testing.expect(t, agent_sandbox_make(folder, 4242, art))
    testing.expect(t, os.exists(fmt.tprintf("%s/%s", folder, AGENT_SANDBOX_FILE)))
    seed, _ := os.read_entire_file_from_path(fmt.tprintf("%s/seed", folder), context.temp_allocator)
    testing.expect_value(t, string(seed), "4242\n")
    copied, _ := os.read_entire_file_from_path(fmt.tprintf("%s/%s", folder, PIXEL_ART_FILE), context.temp_allocator)
    testing.expect_value(t, string(copied), bytes)
    source, _ := os.read_entire_file_from_path(art, context.temp_allocator)
    testing.expect_value(t, string(source), bytes)

    testing.expect(t, agent_sandbox_make(fmt.tprintf("%s/runs/two", root), 1, fmt.tprintf("%s_no_art", root)), "no sprite bank is no failure")
    testing.expect(t, !os.exists(fmt.tprintf("%s/runs/two/%s", root, PIXEL_ART_FILE)))
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
    path := test_scratch_path("gnipa_action_held_scratch.log")
    defer delete(path)
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
    path := test_scratch_path("gnipa_action_title_scratch.log")
    defer delete(path)
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
    update_agent_goals(gs)
    update_input(gs)
    process_events(gs)
    update_player(gs)
    testing.expect(t, gs.ritual.active && gs.ritual.seal, "interact beside the Seal begins the end")

    gs.ritual.timer = RITUAL_DURATION
    gs.delta_time = AGENT_STEP
    update_ritual(gs)
    process_events(gs)
    testing.expect(t, gs.game_won)
    agent_reply_state(link, gs, nil, "state")
    testing.expect(t, strings.contains(agent_test_reply(link), `"screen":"book"`), "the saga comes first")

    agent_dismiss(gs)
    agent_reply_state(link, gs, nil, "state")
    testing.expect(t, strings.contains(agent_test_reply(link), `"screen":"won"`), agent_test_reply(link)[:60])

    gs.agent.driving = true
    agent_dismiss(gs)
    process_events(gs)
    testing.expect(t, !gs.game_won, "a dismiss starts the next run")
}

@(test)
the_sandbox_run_starts_with_nothing_of_the_humans :: proc(t: ^testing.T) {
    save := test_scratch_path("gnipa_agent_reset_scratch_save.dat")
    defer delete(save)
    stats := test_scratch_path("gnipa_agent_reset_scratch_stats.dat")
    defer delete(stats)
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
    agent_test_input(link, gs)
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
    testing.expect_value(t, agent_test_reply(link), `{"re":"say","ok":true}` + "\n")
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
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":true,"frame"`), "the answer is state")
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

// A run with talk records it and replays to the same game, act by act.
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
        for agent_goals_busy(&link.goals) {
            if agent_drive(link, gs) {
                game_update(gs)
                agent_after_tick(link, gs)
            }
        }
    }
    path := test_scratch_path("agent_talk_test.jsonl")
    defer delete(path)
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
    all_rows := strings.split_lines(strings.trim_right_space(string(data)))
    defer delete(all_rows)
    // The goal queue's own rows are for the goal replay; this is the old one.
    rows := make([dynamic]string)
    defer delete(rows)
    goal_rows := 0
    for row in all_rows {
        if strings.contains(row, `,"done":`) || strings.contains(row, `,"failed":`) || strings.contains(row, `,"window":`) do continue
        if strings.contains(row, `,"goal":`) || strings.contains(row, `,"clear":true}`) {
            goal_rows += 1
            continue
        }
        append(&rows, row)
    }
    testing.expect_value(t, goal_rows, 3)
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
    testing.expect(t, strings.has_suffix(out, `{"re":"say","ok":true}` + "\n"), "then the held line is answered")
    testing.expect_value(t, string(link.panel.say.buf[:link.panel.say.len]), "queued")

    // A line typed during an act is waiting when the listen comes: one answer, at once.
    agent_test_type(link, gs, "typed while you played")
    out = agent_test_ask(gs, link, client, `{"cmd":"listen","seconds":30}` + "\n", -1, buf[:])
    testing.expect_value(t, strings.count(out, "\n"), 1)
    testing.expect(t, strings.contains(out, `"text":"typed while you played"`))
    testing.expect(t, !link.awaiting)
    out = agent_test_ask(gs, link, client, `{"cmd":"say","text":"next"}` + "\n", 1, buf[:200])
    testing.expect_value(t, out, `{"re":"say","ok":true}` + "\n")  // and the next reply is the next request's

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

// Pumps until each client has its want lines or the far side closed (want -1).
@(private="file")
agent_test_collect :: proc(gs: ^Game_State, link: ^Agent_Link, clients: []net.TCP_Socket, wants: []int, bufs: [][]u8) -> (got: [4]int, closed: [4]bool) {
    for c in clients do net.set_blocking(c, false)
    for _ in 0 ..< 20000 {
        agent_pump(link, gs)
        done := true
        for c, i in clients {
            if closed[i] do continue
            n, err := net.recv_tcp(c, bufs[i][got[i]:])
            if err == nil && n == 0 { closed[i] = true; continue }
            if err != nil && err != .Would_Block && err != .Timeout { closed[i] = true; continue }
            got[i] += n
            lines := strings.count(string(bufs[i][:got[i]]), "\n")
            if wants[i] < 0 || lines < wants[i] do done = false
        }
        if done do break
    }
    return
}

@(test)
a_get_and_a_connect_in_one_frame_are_both_answered :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    web_buf := new([AGENT_BRIEF_MAX + 1024]u8)
    defer free(web_buf)
    play_buf := new([AGENT_REPLY_MAX]u8)
    defer free(play_buf)

    // Both connect and speak before the game's next frame looks.
    web, _ := net.dial_tcp(at)
    defer net.close(web)
    net.send_tcp(web, transmute([]u8)string("GET / HTTP/1.0\r\n\r\n"))
    client, _ := net.dial_tcp(at)
    defer net.close(client)
    net.send_tcp(client, transmute([]u8)string(`{"cmd":"state"}` + "\n"))
    time.sleep(50 * time.Millisecond)

    got, closed := agent_test_collect(gs, link, {web, client}, {-1, 1}, {web_buf[:], play_buf[:]})
    reply := string(web_buf[:got[0]])
    testing.expect(t, closed[0], "the brief is sent and closed")
    testing.expect(t, strings.has_prefix(reply, "HTTP/1.0 200 OK\r\n"), reply[:min(len(reply), 40)])
    testing.expect(t, strings.contains(reply, "HOW THE GAME WAITS"), "the whole brief")
    testing.expect(t, strings.contains(string(play_buf[:got[1]]), `"ok":true`), "and the socket client plays")
    testing.expect(t, link.connected)
    testing.expect_value(t, link.pending_n, 0)
}

@(test)
two_clients_in_one_frame_the_first_plays_the_second_only_watches :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    bufs: [2][4096]u8

    first, _ := net.dial_tcp(at)
    defer net.close(first)
    net.send_tcp(first, transmute([]u8)string(`{"cmd":"objective","goal":"first"}` + "\n"))
    time.sleep(20 * time.Millisecond)
    second, _ := net.dial_tcp(at)
    defer net.close(second)
    net.send_tcp(second, transmute([]u8)string(`{"cmd":"objective","goal":"second"}` + "\n"))
    time.sleep(50 * time.Millisecond)

    got, _ := agent_test_collect(gs, link, {first, second}, {1, 1}, {bufs[0][:], bufs[1][:]})
    testing.expect_value(t, string(bufs[0][:got[0]]), `{"re":"objective","ok":true}` + "\n")
    testing.expect(t, strings.contains(string(bufs[1][:got[1]]), "a watcher can only ask for state"), string(bufs[1][:got[1]]))
    testing.expect_value(t, string(link.panel.goal.buf[:link.panel.goal.len]), "first")
}

@(test)
silent_connections_past_the_limit_shed_the_oldest_and_the_brief_still_comes :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_BRIEF_MAX + 1024]u8)
    defer free(buf)

    silent: [AGENT_PENDING_MAX + 1]net.TCP_Socket
    for &s in silent {
        s, _ = net.dial_tcp(at)
        for _ in 0 ..< 200 {  // one at a time, so the order is the order they came
            n := link.pending_n
            agent_pump(link, gs)
            if link.pending_n != n || n == AGENT_PENDING_MAX do break
        }
    }
    defer for s in silent do net.close(s)
    testing.expect_value(t, link.pending_n, AGENT_PENDING_MAX)

    // The oldest was let go; the youngest still waits.
    one: [16]u8
    net.set_blocking(silent[0], false)
    n, err := net.recv_tcp(silent[0], one[:])
    testing.expect(t, (err == nil && n == 0) || (err != nil && err != .Would_Block && err != .Timeout), "the oldest is closed")
    net.set_blocking(silent[AGENT_PENDING_MAX], false)
    _, err = net.recv_tcp(silent[AGENT_PENDING_MAX], one[:])
    testing.expect(t, err == .Would_Block || err == .Timeout, "the youngest is held")

    web, _ := net.dial_tcp(at)
    defer net.close(web)
    net.send_tcp(web, transmute([]u8)string("GET / HTTP/1.0\r\n\r\n"))
    got, closed := agent_test_collect(gs, link, {web}, {-1}, {buf[:]})
    testing.expect(t, closed[0])
    testing.expect(t, strings.contains(string(buf[:got[0]]), "HOW THE GAME WAITS"))
    testing.expect(t, !link.connected, "silence never plays")
}

// Every waiting connection is looked at each frame, whatever leaves the list
// ahead of it, and the one that plays starts from its own first line.
@(test)
one_frame_serves_every_waiting_connection :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    bufs := new([3][AGENT_BRIEF_MAX + 1024]u8)
    defer free(bufs)
    get :: "GET / HTTP/1.0\r\n\r\n"

    silent, _ := net.dial_tcp(at)
    defer net.close(silent)
    web, _ := net.dial_tcp(at)
    defer net.close(web)
    net.send_tcp(web, transmute([]u8)string(get))
    client, _ := net.dial_tcp(at)
    defer net.close(client)
    net.send_tcp(client, transmute([]u8)string(`{"cmd":"objective","goal":"mine"}` + "\n"))
    web2, _ := net.dial_tcp(at)
    defer net.close(web2)
    net.send_tcp(web2, transmute([]u8)string(get))
    time.sleep(100 * time.Millisecond)

    agent_pump(link, gs)  // one frame
    testing.expect_value(t, link.pending_n, 1)  // only the silent one waits
    testing.expect(t, link.connected)
    testing.expect_value(t, string(link.panel.goal.buf[:link.panel.goal.len]), "mine")

    got, closed := agent_test_collect(gs, link, {web, web2, client}, {-1, -1, 1}, {bufs[0][:], bufs[1][:], bufs[2][:]})
    testing.expect(t, closed[0] && closed[1])
    testing.expect(t, strings.has_prefix(string(bufs[0][:got[0]]), "HTTP/1.0 200 OK"))
    testing.expect(t, strings.has_prefix(string(bufs[1][:got[1]]), "HTTP/1.0 200 OK"))
    testing.expect_value(t, string(bufs[2][:got[2]]), `{"re":"objective","ok":true}` + "\n")

    // One that leaves without a word gives its place back.
    gone, _ := net.dial_tcp(at)
    for _ in 0 ..< 200 {
        agent_pump(link, gs)
        if link.pending_n == 2 do break
    }
    testing.expect_value(t, link.pending_n, 2)
    net.close(gone)
    for _ in 0 ..< 200 {
        agent_pump(link, gs)
        if link.pending_n == 1 do break
    }
    testing.expect_value(t, link.pending_n, 1)
}

// The game's own bind holds a burst: four briefs asked for between two frames.
@(test)
the_games_bind_queues_a_burst_for_the_next_frame :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.connected = false
    sock, port, ok := agent_title_bind(47411)
    testing.expect(t, ok)
    net.set_blocking(sock, false)
    link.listener  = sock
    link.listening = true
    link.port      = port
    defer agent_close(link, gs)
    bufs := new([AGENT_PENDING_MAX][AGENT_BRIEF_MAX + 1024]u8)
    defer free(bufs)

    webs: [AGENT_PENDING_MAX]net.TCP_Socket
    for &w in webs {
        w, _ = net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
        net.send_tcp(w, transmute([]u8)string("GET / HTTP/1.0\r\n\r\n"))
    }
    defer for w in webs do net.close(w)
    time.sleep(100 * time.Millisecond)
    agent_pump(link, gs)
    testing.expect_value(t, link.pending_n, 0)  // all four came in and were answered in that frame

    got, closed := agent_test_collect(gs, link, webs[:], {-1, -1, -1, -1}, {bufs[0][:], bufs[1][:], bufs[2][:], bufs[3][:]})
    for i in 0 ..< AGENT_PENDING_MAX {
        testing.expect(t, closed[i])
        testing.expect(t, strings.has_prefix(string(bufs[i][:got[i]]), "HTTP/1.0 200 OK"))
    }
}

@(test)
closing_the_link_closes_the_waiting_connections :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    waiting, _ := net.dial_tcp(at)
    defer net.close(waiting)
    for _ in 0 ..< 200 {
        agent_pump(link, gs)
        if link.pending_n > 0 do break
    }
    testing.expect_value(t, link.pending_n, 1)
    agent_close(link, gs)
    testing.expect_value(t, link.pending_n, 0)
    net.set_option(waiting, .Receive_Timeout, 2 * time.Second)
    one: [16]u8
    n, err := net.recv_tcp(waiting, one[:])
    testing.expect(t, (err == nil && n == 0) || (err != nil && err != .Timeout && err != .Would_Block), "the far side sees it close")
}

// ─── The command wand's gestures, and what state shows of the crew ──────────

// The player holding a wand, on a cleared pad: open air above a stone floor
// under the feet, so a monument's footprint and its ground are both there.
@(private="file")
agent_test_wand :: proc(gs: ^Game_State, wand := Item.Command_Wand) -> (T: [2]i32) {
    hand := MAX_INVENTORY - 2
    gs.player.inventory.slots[hand] = {item = wand, count = 1}
    gs.player.inventory.selected = hand
    T = player_tile(&gs.player)
    for y in T.y - 6 ..= T.y do for x in T.x - 6 ..= T.x + 6 do set_tile(&gs.world, int(x), int(y), .Air)
    for x in T.x - 6 ..= T.x + 6 do set_tile(&gs.world, int(x), int(T.y) + 1, .Stone)
    return
}

@(private="file")
agent_test_golem :: proc(gs: ^Game_State, mode := Golem_Mode.Gather) -> ^Golem {
    T := player_tile(&gs.player)
    g := &gs.golems.data[0]
    g^ = {status = .Deployed, hp = GOLEM_HP, mode = mode, facing = 1, level = gs.level_index,
        pos = {f32(T.x + 2) + (1 - GOLEM_W) * 0.5, f32(T.y + 1) - GOLEM_H}, grounded = true, project_cell = -1}
    return g
}

@(test)
agent_zone_drags_the_gather_zone :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_test_refused(t, link, gs, `{"cmd":"act","zone":[10,20,15,25]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "command wand"), "a bare hand is told why")

    T := agent_test_wand(gs)
    agent_test_refused(t, link, gs, `{"cmd":"act","zone":[10,20,15]}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","zone":[10,20,15,999]}`)
    agent_test_refused(t, link, gs, `{"cmd":"act","zone":[10,20,10,20]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "two different corners"), "a click is not a drag")
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","zone":[10,20,15,25],"place":[%d,%d]}}`, T.x + 1, T.y))
    set_tile(&gs.world, 10, 20, .Smelter)
    agent_test_refused(t, link, gs, `{"cmd":"act","zone":[10,20,15,25]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "opens it"), "a press on a machine opens the machine")
    set_tile(&gs.world, 10, 20, .Air)
    testing.expect(t, !gs.golems.work[gs.level_index].active, "every refusal leaves the old zone")

    // Corners either way round, far from the player: the mouse has no reach limit.
    agent_test_run_act(link, gs, `{"cmd":"act","zone":[15,25,10,20]}`)
    z := gs.golems.work[gs.level_index]
    testing.expect(t, z.active)
    testing.expect_value(t, gs.input.mouse_tile, [2]i32{10, 20})  // the cursor ends where the drag let go
    testing.expect_value(t, z.min, [2]i32{10, 20})
    testing.expect_value(t, z.max, [2]i32{15, 25})
    zone := agent_test_state(link, gs)["crew"].(json.Object)["zone"].(json.Array)
    testing.expect_value(t, len(zone), 4)
    testing.expect_value(t, zone[0].(json.Float), 10)
    testing.expect_value(t, zone[1].(json.Float), 20)
    testing.expect_value(t, zone[2].(json.Float), 15)
    testing.expect_value(t, zone[3].(json.Float), 25)
}

@(test)
agent_crew_flips_the_crew_between_gather_and_build :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    g := agent_test_golem(gs)
    agent_test_refused(t, link, gs, `{"cmd":"act","crew":true}`)
    testing.expect_value(t, g.mode, Golem_Mode.Gather)

    agent_test_wand(gs)
    // crew is a key, not a click: a machine under the unset cursor (0,0) does not matter.
    set_tile(&gs.world, 0, 0, .Smelter)
    agent_test_run_act(link, gs, `{"cmd":"act","crew":true,"frames":3}`)
    testing.expect_value(t, g.mode, Golem_Mode.Build)  // once: a second press would flip it back
    agent_test_run_act(link, gs, `{"cmd":"act","crew":true}`)
    testing.expect_value(t, g.mode, Golem_Mode.Gather)

    // Card 148: with only a cracked golem the key changes nothing, and says so;
    // a golem at work on another level is that level's.
    g.status = .Broken
    gs.golems.data[5] = {status = .Deployed, mode = .Gather, level = (gs.level_index + 1) % NUM_LEVELS}
    gs.notify.count = 0
    agent_test_run_act(link, gs, `{"cmd":"act","crew":true}`)
    testing.expect_value(t, g.mode, Golem_Mode.Gather)
    testing.expect_value(t, gs.notify.count, 1)
    testing.expect_value(t, string(gs.notify.items[0].text[:gs.notify.items[0].len]), "Crew: a cracked golem takes no orders - PICK UP in the roster")
    testing.expect_value(t, gs.golems.data[5].mode, Golem_Mode.Gather)
    g.status = .Empty
    gs.notify.count = 0
    agent_test_run_act(link, gs, `{"cmd":"act","crew":true}`)
    testing.expect_value(t, string(gs.notify.items[0].text[:gs.notify.items[0].len]), "Crew: no golem at work on this level")
}

@(test)
agent_monument_marks_a_build_anchor :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    T := player_tile(&gs.player)
    at := fmt.tprintf(`"at":[%d,%d]`, T.x + 1, T.y)
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Clay_Hearth",%s}}`, at))
    testing.expect(t, strings.contains(agent_test_reply(link), "command wand"), "a bare hand is told why")

    agent_test_wand(gs)
    agent_test_refused(t, link, gs, `{"cmd":"act","monument":"Clay_Hearth"}`)
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act",%s}}`, at))
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Clay_Hearth",%s,"craft":"Plank"}}`, at))
    testing.expect(t, strings.contains(agent_test_reply(link), "at goes with monument"), "one verb per act")
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Longhouse",%s}}`, at))
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"None",%s}}`, at))
    testing.expect(t, strings.contains(agent_test_reply(link), "must be"), "None is no plan")
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Golem_Depot",%s}}`, at))
    testing.expect(t, strings.contains(agent_test_reply(link), "not unlocked"), "the basic wand shows no depot button")
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Clay_Hearth",%s,"use":[%d,%d]}}`, at, T.x, T.y))
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Smelter)
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Clay_Hearth",%s}}`, at))
    set_tile(&gs.world, int(T.x) + 1, int(T.y), .Air)
    testing.expect(t, !gs.golems.projects[gs.level_index].active, "every refusal marks nothing")

    // Out of reach is the game's own refusal, as for the mouse: it plays, and a toast says why.
    agent_test_run_act(link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Clay_Hearth","at":[%d,%d]}}`, T.x + PLAYER_REACH + 1, T.y))
    testing.expect(t, !gs.golems.projects[gs.level_index].active, "beyond reach")

    agent_test_run_act(link, gs, fmt.tprintf(`{{"cmd":"act","monument":"Clay_Hearth",%s}}`, at))
    p := gs.golems.projects[gs.level_index]
    testing.expect(t, p.active)
    testing.expect_value(t, p.plan, Golem_Plan.Clay_Hearth)
    testing.expect_value(t, p.anchor, [2]i32{T.x + 1, T.y})
    m := agent_test_state(link, gs)["crew"].(json.Object)["monument"].(json.Object)
    testing.expect_value(t, m["plan"].(json.String), "Clay_Hearth")
    testing.expect_value(t, m["x"].(json.Float), f64(T.x + 1))
    testing.expect_value(t, m["y"].(json.Float), f64(T.y))
    testing.expect_value(t, m["complete"].(json.Boolean), false)
}

@(test)
agent_state_lists_the_crew :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    crew := agent_test_state(link, gs)["crew"].(json.Object)
    testing.expect_value(t, len(crew["golems"].(json.Array)), 0)
    testing.expect(t, "zone" not_in crew && "monument" not_in crew, "nothing marked, nothing shown")

    g := agent_test_golem(gs, .Build)
    g.job = .Seek
    gs.golems.data[3] = {status = .Carried, mode = .Gather}
    golems := agent_test_state(link, gs)["crew"].(json.Object)["golems"].(json.Array)
    testing.expect_value(t, len(golems), 2)
    first := golems[0].(json.Object)
    testing.expect_value(t, first["slot"].(json.Float), 0)
    testing.expect_value(t, first["status"].(json.String), "Deployed")
    testing.expect_value(t, first["mode"].(json.String), "Build")
    testing.expect_value(t, first["job"].(json.String), "Seek")
    testing.expect_value(t, first["level"].(json.Float), f64(gs.level_index))
    testing.expect_value(t, first["hp"].(json.Float), f64(GOLEM_HP))
    testing.expect(t, abs(first["x"].(json.Float) - f64(g.pos.x)) < 0.01 && abs(first["y"].(json.Float) - f64(g.pos.y)) < 0.01, "where it stands")
    testing.expect_value(t, golems[1].(json.Object)["slot"].(json.Float), 3)
    testing.expect_value(t, golems[1].(json.Object)["status"].(json.String), "Carried")
    // Card 148: what it carries and packs, where it is headed, and whether it
    // is cracked or coming back from it.
    testing.expect_value(t, first["broken"].(json.Boolean), false)
    testing.expect_value(t, first["recovering"].(json.Boolean), false)
    testing.expect_value(t, first["carry"].(json.String), "None")
    testing.expect(t, "target" not_in first, "no target, none shown")
    testing.expect_value(t, len(first["pack"].(json.Array)), 0)
    g.carry, g.target, g.has_target, g.recovering = .Clay, {31, 42}, true, true
    g.pack[0], g.pack[2] = .Iron_Ore, .Stone_Block
    gs.golems.data[3].status = .Broken
    golems = agent_test_state(link, gs)["crew"].(json.Object)["golems"].(json.Array)
    first = golems[0].(json.Object)
    testing.expect_value(t, first["carry"].(json.String), "Clay")
    testing.expect_value(t, first["recovering"].(json.Boolean), true)
    target := first["target"].(json.Array)
    testing.expect(t, len(target) == 2 && target[0].(json.Float) == 31 && target[1].(json.Float) == 42, "the target tile")
    pack := first["pack"].(json.Array)
    testing.expect(t, len(pack) == 2 && pack[0].(json.String) == "Iron_Ore" && pack[1].(json.String) == "Stone_Block", "the pack, empty slots left out")
    testing.expect(t, strings.contains(agent_test_reply(link), `"pack":["Iron_Ore","Stone_Block"]`), "strict JSON, a comma between")
    testing.expect_value(t, golems[1].(json.Object)["broken"].(json.Boolean), true)

    // Another level's zone is that level's.
    gs.golems.work[(gs.level_index + 1) % NUM_LEVELS] = {active = true, min = {1, 1}, max = {4, 4}}
    testing.expect(t, "zone" not_in agent_test_state(link, gs)["crew"].(json.Object))

    // On level 1, with both levels marked, only level 1's show.
    gs.level_index = 1
    gs.golems.work[0]     = {active = true, min = {1, 1}, max = {4, 4}}
    gs.golems.work[1]     = {active = true, min = {7, 8}, max = {9, 10}}
    gs.golems.projects[0] = {active = true, plan = .Clay_Hearth, level = 0, anchor = {20, 30}}
    gs.golems.projects[1] = {active = true, complete = true, plan = .Golem_Depot, level = 1, anchor = {40, 50}}
    crew = agent_test_state(link, gs)["crew"].(json.Object)
    testing.expect_value(t, crew["zone"].(json.Array)[0].(json.Float), 7)
    testing.expect_value(t, crew["monument"].(json.Object)["plan"].(json.String), "Golem_Depot")
    testing.expect_value(t, crew["monument"].(json.Object)["x"].(json.Float), 40)
    testing.expect_value(t, crew["monument"].(json.Object)["y"].(json.Float), 50)
    testing.expect_value(t, crew["monument"].(json.Object)["complete"].(json.Boolean), true)
}

@(test)
agent_state_lists_the_flocks_in_view :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    whole := fmt.tprintf(`{{"cmd":"state","x":0,"y":0,"w":%d,"h":%d}}`, GRID_W, GRID_H)
    testing.expect_value(t, len(agent_test_state(link, gs, whole)["birds"].(json.Array)), 0)

    birds_seed(gs)
    f := &gs.birds.flocks[0]
    f.center = {50, 30}
    for &b in f.birds do b.pos = {50, 30}
    f.scatter_t = 1
    found := false
    for v in agent_test_state(link, gs, whole)["birds"].(json.Array) {
        o := v.(json.Object)
        if o["x"].(json.Float) != 50 || o["y"].(json.Float) != 30 do continue
        found = true
        testing.expect_value(t, o["heading"].(json.Float), f64(f.heading))
        testing.expect_value(t, o["scattered"].(json.Boolean), true)
    }
    testing.expect(t, found, "the flock is in the level")

    // A view the flock is not in leaves it out, and the others are elsewhere.
    for &o, i in gs.birds.flocks do if i > 0 do for &b in o.birds do b.pos = {150, 70}
    testing.expect_value(t, len(agent_test_state(link, gs, `{"cmd":"state","x":40,"y":25,"w":20,"h":10}`)["birds"].(json.Array)), 1)
    testing.expect_value(t, len(agent_test_state(link, gs, `{"cmd":"state","x":0,"y":0,"w":10,"h":10}`)["birds"].(json.Array)), 0)
    // In the view's columns but above its rows, and below them: not in view.
    testing.expect_value(t, len(agent_test_state(link, gs, `{"cmd":"state","x":40,"y":31,"w":20,"h":10}`)["birds"].(json.Array)), 0)
    testing.expect_value(t, len(agent_test_state(link, gs, `{"cmd":"state","x":40,"y":15,"w":20,"h":15}`)["birds"].(json.Array)), 0)
    // In the view's rows but beside its columns, either side: not in view.
    testing.expect_value(t, len(agent_test_state(link, gs, `{"cmd":"state","x":51,"y":25,"w":20,"h":10}`)["birds"].(json.Array)), 0)
    testing.expect_value(t, len(agent_test_state(link, gs, `{"cmd":"state","x":30,"y":25,"w":20,"h":10}`)["birds"].(json.Array)), 0)
    f.scatter_t = 0
    testing.expect_value(t, agent_test_state(link, gs, whole)["birds"].(json.Array)[0].(json.Object)["scattered"].(json.Boolean), false)
}

@(test)
agent_death_screen_counts_down_to_ready :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    inventory_insert(&gs.player.inventory, .Potion_Health, 1)
    slot := 0
    for s, i in gs.player.inventory.slots do if s.item == .Potion_Health do slot = i
    eq_push(&gs.events, Event{type = .Damage_Dealt, source = INVALID_ENTITY, target = PLAYER_ID,
        payload = {int_val = 100}, cause = .Lava})
    agent_test_play(link, gs, `{"cmd":"act","frames":1}`)
    testing.expect(t, gs.player.dead)

    left := int(agent_test_state(link, gs)["tithe"].(json.Object)["ready_in"].(json.Float))
    testing.expect(t, left > 60 && left <= 73, "about the 1.2 s the screen waits")
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, slot))
    testing.expect(t, strings.contains(agent_test_reply(link), fmt.tprintf("%d more frames", left)), "the refusal says how long")

    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","frames":%d}}`, left - 1))
    testing.expect_value(t, int(agent_test_state(link, gs)["tithe"].(json.Object)["ready_in"].(json.Float)), 1)
    agent_test_refused(t, link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, slot))
    agent_test_play(link, gs, `{"cmd":"act","frames":1}`)
    testing.expect_value(t, int(agent_test_state(link, gs)["tithe"].(json.Object)["ready_in"].(json.Float)), 0)
    agent_test_play(link, gs, fmt.tprintf(`{{"cmd":"act","tithe":%d}}`, slot))
    testing.expect_value(t, gs.stats.grave.tithe, Item.Potion_Health)
}

@(test)
agent_brief_names_the_crew_verbs_and_the_death_wait :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    brief := agent_write_brief(link, gs)
    for want in ([]string{"zone: [x0,y0,x1,y1]", "crew: true", "monument: Clay_Hearth", "at: [x,y]", "tithe.ready_in", "about its first 72 ticks", "birds",
                          "(slot, status, mode, job, hp, broken, recovering, carry, target, pack)", "The roster's per-golem orders are goals: crew_mode, crew_call, crew_pickup"}) {
        testing.expectf(t, strings.contains(brief, want), "the brief says %q", want)
    }
}

// ─── Aim within a tile, and each enemy's body (card 126) ────────────────────
//
//  Run 8: the API aimed only at a tile's centre, and a 0.4-tall eel straddling
//  two rows sat out of reach of the fire wand.  A mouse aims at any pixel.

// The cursor after one act's first tick.
@(private="file")
agent_test_cursor :: proc(line: string, wand := false) -> (tile: [2]i32, world: [2]f32) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    if wand do agent_test_wand(gs)
    agent_handle_line(link, gs, line)
    agent_test_input(link, gs)
    return gs.input.mouse_tile, gs.input.mouse_world
}

@(private="file")
agent_test_near :: proc(a, b: [2]f32) -> bool {
    return abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001
}

@(test)
agent_whole_numbers_still_aim_at_the_tile_centre :: proc(t: ^testing.T) {
    tile, world := agent_test_cursor(`{"cmd":"act","mine":[20,70]}`)
    testing.expect_value(t, tile, [2]i32{20, 70})
    testing.expect_value(t, world, [2]f32{205, 705})
}

// The aim is the cursor verbs' alone: no verb and a zone keep their tile centres.
@(test)
agent_acts_without_a_point_keep_the_tile_centre :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    T := player_tile(&gs.player)
    agent_handle_line(link, gs, `{"cmd":"act","move":"left"}`)
    agent_test_input(link, gs)
    testing.expect_value(t, gs.input.mouse_world, [2]f32{(f32(T.x) + 0.5) * CELL_SIZE, (f32(T.y) + 0.5) * CELL_SIZE})

    tile, world := agent_test_cursor(`{"cmd":"act","zone":[10,20,14,22]}`, wand = true)
    testing.expect_value(t, tile, [2]i32{14, 22})
    testing.expect_value(t, world, [2]f32{145, 225})
}

@(test)
agent_a_fraction_aims_within_the_tile :: proc(t: ^testing.T) {
    for key in ([]string{"mine", "place", "use", "reclaim", "at"}) {
        // at goes with monument, and that with a command wand
        extra := `"monument":"Clay_Hearth",` if key == "at" else ""
        tile, world := agent_test_cursor(fmt.tprintf(`{{"cmd":"act",%s"%s":[10.2,20.8]}}`, extra, key), key == "at")
        testing.expectf(t, tile == {10, 20}, "%s: tile %v", key, tile)
        testing.expectf(t, agent_test_near(world, {102, 208}), "%s: world %v", key, world)
    }
    // 10.0 is a fraction to a client that sends floats: the tile's corner.
    tile, world := agent_test_cursor(`{"cmd":"act","use":[10.0,20.0]}`)
    testing.expect_value(t, tile, [2]i32{10, 20})
    testing.expect_value(t, world, [2]f32{100, 200})
    // One whole, one fraction: each axis on its own.
    tile, world = agent_test_cursor(`{"cmd":"act","mine":[10,20.25]}`)
    testing.expect_value(t, tile, [2]i32{10, 20})
    testing.expect(t, agent_test_near(world, {105, 202.5}))
    // The map's last sliver is still inside it.
    tile, _ = agent_test_cursor(fmt.tprintf(`{{"cmd":"act","mine":[%v.99,%v.99]}}`, GRID_W - 1, GRID_H - 1))
    testing.expect_value(t, tile, [2]i32{GRID_W - 1, GRID_H - 1})
}

@(test)
agent_a_point_off_the_map_is_refused :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    lines := []string{
        `{"cmd":"act","mine":[-0.5,20]}`,   // truncation would have made it tile 0
        `{"cmd":"act","mine":[10,-0.01]}`,
        fmt.tprintf(`{{"cmd":"act","use":[%v.0,20]}}`, GRID_W),
        fmt.tprintf(`{{"cmd":"act","use":[10,%v.5]}}`, GRID_H),
        `{"cmd":"act","mine":[NaN,20]}`,
        `{"cmd":"act","at":[10,NaN]}`,
        `{"cmd":"act","mine":[Infinity,20]}`,
        `{"cmd":"act","mine":[10,-Infinity]}`,
        `{"cmd":"act","mine":[1e300,20]}`,
        `{"cmd":"act","mine":[10,"20"]}`,
    }
    for line in lines {
        agent_test_refused(t, link, gs, line)
        testing.expectf(t, strings.contains(agent_test_reply(link), "inside the map"), "%s -> %s", line, agent_test_reply(link))
    }
}

@(test)
agent_goals_keep_whole_numbers_and_fractions_apart :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","mine":[20,70]},{"do":"act","mine":[10.0,20.5]}]}`)
    want := [][2]f32{{205, 705}, {100, 205}}
    for w in want {
        testing.expect(t, agent_test_input(link, gs))
        testing.expect_value(t, gs.input.mouse_world, w)
        agent_after_tick(link, gs)
    }
}

// Run 8's shape: a Cave_Eel straddling rows 50 and 51, sixteen tiles off.
@(private="file")
agent_test_shoot_eel :: proc(line: string) -> (hurt: bool) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.delta_time = 1.0 / 60.0
    for y in 44 ..= 52 do for x in 30 ..= 80 {
        set_tile(&gs.world, x, y, .Stone if y == 52 else .Air)
    }
    gs.player.pos = {40 - PLAYER_W * 0.5, 52 - PLAYER_H}
    gs.player.mana = 100
    gs.player.inventory.slots[TEST_HAND] = {item = .Fire_Wand, count = 1}
    gs.player.inventory.selected = TEST_HAND

    id, ok := enemy_alloc(&gs.enemies)
    assert(ok)
    e := &gs.enemies.data[id]
    e.kind   = .Cave_Eel
    e.hp     = 100
    e.hp_max = 100
    e.pos    = {56 - CAVE_EEL_W * 0.5, 51 - CAVE_EEL_H * 0.5}

    agent_handle_line(link, gs, line)
    agent_test_input(link, gs)
    update_player(gs)
    gs.input.mine = false
    for _ in 0 ..< 120 {
        update_projectiles(gs)
        process_events(gs)
        eq_clear(&gs.events)
    }
    return e.hp < 100
}

@(test)
agent_a_fraction_hits_the_eel_a_whole_tile_misses :: proc(t: ^testing.T) {
    testing.expect(t, agent_test_shoot_eel(`{"cmd":"act","mine":[56.0,51.0]}`), "aimed at the eel's centre")
    testing.expect(t, !agent_test_shoot_eel(`{"cmd":"act","mine":[56,51]}`), "the centre of the tile below it")
    testing.expect(t, !agent_test_shoot_eel(`{"cmd":"act","mine":[56,50]}`), "the centre of the tile above it")
}

@(test)
agent_state_gives_each_enemy_its_body :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    spawn :: proc(gs: ^Game_State, kind: Enemy_Kind, pos: [2]f32) {
        id, _ := enemy_alloc(&gs.enemies)
        gs.enemies.data[id].kind = kind
        gs.enemies.data[id].pos  = pos
    }
    spawn(gs, .Cave_Eel, {30.5, 60.8})
    spawn(gs, .Undead, {34, 60})

    enemies := agent_test_state(link, gs, `{"cmd":"state","x":20,"y":50,"w":40,"h":20}`)["enemies"].(json.Array)
    seen := 0
    for v in enemies {
        o := v.(json.Object)
        kind := o["kind"].(json.String)
        if kind != "Cave_Eel" && kind != "Undead" do continue  // the level's own roamers
        seen += 1
        want := enemy_body_size(.Cave_Eel if kind == "Cave_Eel" else .Undead)
        got := [2]f32{f32(o["w"].(json.Float)), f32(o["h"].(json.Float))}
        testing.expectf(t, agent_test_near(got, want), "%s: %v, want %v", kind, got, want)
    }
    testing.expect_value(t, seen, 2)
    testing.expect(t, agent_test_near(enemy_body_size(.Cave_Eel), {1.1, 0.4}))
    testing.expect(t, agent_test_near(enemy_body_size(.Undead), {BUILDER_W, BUILDER_H}))
}

@(test)
agent_brief_says_how_to_aim_within_a_tile :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    brief := agent_write_brief(link, gs)
    for want in ([]string{"fractions aim at that point within it", "x,y the top-left of a w x h body"}) {
        testing.expectf(t, strings.contains(brief, want), "the brief says %q", want)
    }
}

// The brief tells the fight goal, its failures, the fight_back reflex and the
// work goals' unsafe, cornered and refused, a go blocked on a structure, and
// that death fails the goals.
@(test)
agent_brief_tells_the_fight :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    brief := agent_write_brief(link, gs)
    for want in ([]string{"    fight: kind: an enemy kind", "no_item, no_target, unreachable or low_hp", "fight_back: strikes back for 1.5 s", "else the pickaxe, 1 damage to the sword's 2", "the sword in reach (else the pickaxe, a weak blow)", "unreachable, unsafe, cornered (wary, and every stand in reach has no cheap way out), refused, blocked or full", "when the hero dies every goal but an act fails with died", "refused: a place the game turns away, in the game's own words", "a mine a reflex keeps the pick off, the reflex named", "it names a structure the tile stands on"}) {
        testing.expectf(t, strings.contains(brief, want), "the brief says %q", want)
    }
}

// Over the socket: a goal's end comes unasked, ahead of the next reply, and a
// client that goes takes its queue with it.
@(test)
a_socket_client_hears_its_goal_end_unasked :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)

    client, _ := net.dial_tcp(at)
    out := agent_test_ask(gs, link, client, `{"cmd":"goals","add":[{"do":"act","frames":3},{"do":"act","frames":600}]}` + "\n", 1, buf[:])
    testing.expect_value(t, out, `{"re":"goals","ok":true,"ids":[1,2]}` + "\n")
    testing.expect(t, link.realtime && link.events_on)

    got := 0
    for _ in 0 ..< 2000 {
        if agent_pump(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
        n, err := net.recv_tcp(client, buf[got:])
        if err == nil do got += n
        if strings.contains(string(buf[:got]), "\n") do break
    }
    testing.expect_value(t, string(buf[:got]), `{"event":"goal_done","f":3,"id":1}` + "\n")

    net.close(client)
    for _ in 0 ..< 2000 {
        agent_pump(link, gs)
        if !link.connected do break
    }
    testing.expect(t, !link.connected)
    testing.expect(t, link.goals.n == 0 && !link.events_on && link.push_len == 0, "the queue went with the client")
}

@(test)
agent_a_goal_too_long_to_record_is_refused :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    pad := strings.repeat("x", AGENT_GOAL_LINE, context.temp_allocator)
    for line in ([]string{
        fmt.tprintf(`{{"cmd":"goals","add":[{{"do":"act","pad":"%s"}}]}}`, pad),
        fmt.tprintf(`{{"cmd":"act","pad":"%s"}}`, pad),
    }) {
        agent_test_refused(t, link, gs, line)
        testing.expect(t, strings.contains(agent_test_reply(link), "too long to record"), agent_test_reply(link))
    }
    testing.expect_value(t, link.goals.n, 0)
}

// The first goals command starts the events from the game as it stands, not
// from whatever the last tick of an earlier client left.
@(test)
agent_events_start_from_the_game_as_it_stands :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    gs.level_index = 2
    gs.player.hp   = 4
    agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
    agent_after_tick(link, gs)
    testing.expect_value(t, string(link.push[:link.push_len]), "")
}

// Events waiting go out ahead of the reply that follows them.
@(test)
a_socket_client_hears_events_before_the_reply :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)

    client, _ := net.dial_tcp(at)
    agent_test_ask(gs, link, client, `{"cmd":"goals","add":[{"do":"act","frames":50}]}` + "\n", 1, buf[:])
    out := agent_test_ask(gs, link, client, `{"cmd":"goals","clear":true}` + "\n", 2, buf[:])
    testing.expect_value(t, out, `{"event":"goal_failed","f":0,"id":1,"reason":"cancelled"}` + "\n" + `{"re":"goals","ok":true}` + "\n")
    net.close(client)
}

// ─── Watchers and a reconnect, in place of the old bridge (card 141) ─────────

// Pumps and ticks, as main does, for this many frames.
@(private="file")
agent_test_frames :: proc(link: ^Agent_Link, gs: ^Game_State, frames: int) {
    for _ in 0 ..< frames {
        if agent_pump(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
}

@(test)
a_watcher_reads_state_hears_events_and_takes_the_game_when_the_driver_goes :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)

    driver, _ := net.dial_tcp(at)
    agent_test_ask(gs, link, driver, `{"cmd":"state"}` + "\n", 1, buf[:])
    watcher, _ := net.dial_tcp(at)
    defer net.close(watcher)
    out := agent_test_ask(gs, link, watcher, `{"cmd":"state","w":3,"h":3}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, `"re":"state","ok":true`), out[:min(len(out), 60)])
    testing.expect(t, link.connected && link.readers_n == 1, "the driver still drives")

    agent_test_type(link, gs, "hello agent")
    out = agent_test_ask(gs, link, watcher, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, "hello agent"), "a watcher sees the watcher's line")
    out = agent_test_ask(gs, link, driver, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, "hello agent"), "and leaves it for the driver")

    out = agent_test_ask(gs, link, watcher, `{"cmd":"act","move":"left","frames":5}` + "\n", 1, buf[:])
    testing.expect_value(t, out, `{"re":"act","ok":false,"error":"another agent drives: a watcher can only ask for state"}` + "\n")
    testing.expect(t, !agent_goals_busy(&link.goals), "and nothing of it plays")

    // A watcher hears every event, even before the driver speaks goals.
    agent_test_ask(gs, link, driver, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":3}]}` + "\n", 1, buf[:])
    agent_test_frames(link, gs, 10)
    net.set_blocking(watcher, false)
    got := 0
    for _ in 0 ..< 2000 {
        agent_pump(link, gs)
        n, err := net.recv_tcp(watcher, buf[got:])
        if err == nil do got += n
        if strings.contains(string(buf[:got]), "goal_done") do break
    }
    testing.expect(t, strings.contains(string(buf[:got]), `{"event":"goal_done"`), string(buf[:got]))
    agent_test_frames(link, gs, 5)
    for _ in 0 ..< 200 {
        n, err := net.recv_tcp(watcher, buf[got:])
        if err == nil do got += n
    }
    testing.expect_value(t, strings.count(string(buf[:got]), "goal_done"), 1)  // once

    // The driver goes: the watcher's next order takes the game, and plays.
    net.close(driver)
    agent_test_frames(link, gs, 20)
    testing.expect(t, !link.connected)
    out = agent_test_ask(gs, link, watcher, `{"cmd":"state"}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, `"ok":true`) && !link.connected, "state alone does not take the game")
    out = agent_test_ask(gs, link, watcher, `{"cmd":"objective","goal":"back"}` + "\n", 1, buf[:])
    testing.expect_value(t, out, `{"re":"objective","ok":true}` + "\n")
    testing.expect(t, link.connected && link.readers_n == 0, "the watcher drives now")
    testing.expect_value(t, string(link.panel.goal.buf[:link.panel.goal.len]), "back")
}

@(test)
a_client_that_lost_its_connection_comes_back_and_a_full_house_is_turned_away :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)

    first, _ := net.dial_tcp(at)
    agent_test_ask(gs, link, first, `{"cmd":"objective","goal":"one"}` + "\n", 1, buf[:])
    net.close(first)
    agent_test_frames(link, gs, 20)
    testing.expect(t, !link.connected)
    again, _ := net.dial_tcp(at)
    defer net.close(again)
    out := agent_test_ask(gs, link, again, `{"cmd":"objective","goal":"two"}` + "\n", 1, buf[:])
    testing.expect_value(t, out, `{"re":"objective","ok":true}` + "\n")
    testing.expect(t, link.connected, "a reconnect drives")

    watchers: [AGENT_READERS_MAX]net.TCP_Socket
    for &w in watchers {
        w, _ = net.dial_tcp(at)
        agent_test_ask(gs, link, w, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    }
    defer for w in watchers do net.close(w)
    testing.expect_value(t, link.readers_n, AGENT_READERS_MAX)
    extra, _ := net.dial_tcp(at)
    defer net.close(extra)
    out = agent_test_ask(gs, link, extra, `{"cmd":"state"}` + "\n", -1, buf[:])
    testing.expect(t, strings.contains(out, "every watcher's place is taken"), out)
    testing.expect_value(t, link.readers_n, AGENT_READERS_MAX)

    net.close(watchers[0])
    watchers[0], _ = net.dial_tcp(at)  // so the deferred close has a socket of its own
    agent_test_frames(link, gs, 3)
    testing.expect_value(t, link.readers_n, AGENT_READERS_MAX - 1)  // a watcher that hung up leaves
    out = agent_test_ask(gs, link, watchers[AGENT_READERS_MAX - 1], `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    testing.expect(t, strings.contains(out, `"ok":true`), "and the others are still served")
}

@(test)
a_watcher_that_stops_reading_or_sends_no_line_is_dropped :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)
    driver, _ := net.dial_tcp(at)
    defer net.close(driver)
    agent_test_ask(gs, link, driver, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])

    deaf, _ := net.dial_tcp(at)
    defer net.close(deaf)
    agent_test_ask(gs, link, deaf, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    ask := strings.repeat(`{"cmd":"state","x":0,"y":0,"w":192,"h":108}` + "\n", 400, context.temp_allocator)
    net.send_tcp(deaf, transmute([]u8)ask)
    for _ in 0 ..< 20 {
        if link.readers_n == 0 do break
        agent_pump(link, gs)
    }
    testing.expect_value(t, link.readers_n, 0)
    testing.expect(t, link.connected, "the driver plays on")

    long, _ := net.dial_tcp(at)
    defer net.close(long)
    agent_test_ask(gs, link, long, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    testing.expect_value(t, link.readers_n, 1)
    net.send_tcp(long, transmute([]u8)strings.repeat("x", AGENT_LINE_MAX + 10, context.temp_allocator))
    time.sleep(50 * time.Millisecond)
    agent_test_frames(link, gs, 3)
    testing.expect_value(t, link.readers_n, 0)  // a line this long is not the protocol
    net.set_blocking(long, true)
    net.set_option(long, .Receive_Timeout, 2 * time.Second)
    for {  // what it was sent, then the close
        n, err := net.recv_tcp(long, buf[:])
        if n > 0 && err == nil do continue
        hung_up := (n == 0 && err == nil) || (err != nil && err != .Timeout && err != .Would_Block)  // unread bytes make it a reset
        testing.expect(t, hung_up, "a dropped watcher is hung up on")
        break
    }

    last, _ := net.dial_tcp(at)
    defer net.close(last)
    agent_test_ask(gs, link, last, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    agent_close(link, gs)
    net.set_blocking(last, true)
    net.set_option(last, .Receive_Timeout, 2 * time.Second)
    n, err := net.recv_tcp(last, buf[:])
    testing.expect(t, n == 0 && err == nil, "closing the link hangs up on its watchers")
}

// The driver's going and a watcher's order in one frame: the going is read first.
@(test)
a_watcher_that_speaks_as_the_driver_goes_takes_the_game_that_frame :: proc(t: ^testing.T) {
    gs, link, at := agent_test_listening(t)
    defer free(gs)
    defer free(link)
    defer agent_close(link, gs)
    buf := new([AGENT_REPLY_MAX]u8)
    defer free(buf)

    driver, _ := net.dial_tcp(at)
    agent_test_ask(gs, link, driver, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    watcher, _ := net.dial_tcp(at)
    defer net.close(watcher)
    agent_test_ask(gs, link, watcher, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
    net.close(driver)
    net.send_tcp(watcher, transmute([]u8)string(`{"cmd":"objective","goal":"mine now"}` + "\n"))
    time.sleep(50 * time.Millisecond)  // both are in before the frame looks
    agent_pump(link, gs)
    testing.expect(t, link.connected && link.readers_n == 0, "one frame: the driver gone, the watcher in")
    agent_pump(link, gs)
    testing.expect_value(t, string(link.panel.goal.buf[:link.panel.goal.len]), "mine now")  // its order, the next
}

// reflexes switches each one by name, all or nothing, answers with all of them
// and is recorded; home marks a tile or clears the mark; go and home are goal
// kinds the add-time check knows.
@(test)
agent_reflexes_home_and_go_are_commands :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    path := test_scratch_path("agent_reflexes_test.jsonl")
    defer delete(path)
    defer os.remove(path)
    f, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    testing.expect(t, err == nil)
    link.acts_file = f
    link.recording = true

    agent_handle_line(link, gs, `{"cmd":"reflexes","potion":false,"rim_dig":false}`)
    testing.expect_value(t, agent_test_reply(link), `{"re":"reflexes","ok":true,"reflexes":{"leave_hazard":true,"potion":false,"floor_dig":true,"rim_dig":false,"fight_back":true}}` + "\n")
    testing.expect_value(t, link.goals.reflexes_off, bit_set[Hero_Reflex]{.Potion, .Rim_Dig})
    agent_handle_line(link, gs, `{"cmd":"reflexes","rim_dig":true,"swim":false}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "swim is not a reflex"))
    agent_handle_line(link, gs, `{"cmd":"reflexes","rim_dig":1}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "rim_dig is not a reflex to switch with true or false"))
    testing.expect_value(t, link.goals.reflexes_off, bit_set[Hero_Reflex]{.Potion, .Rim_Dig})  // all or nothing
    agent_handle_line(link, gs, `{"cmd":"reflexes"}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"potion":false`), "a bare reflexes reads them")

    agent_handle_line(link, gs, `{"cmd":"home","at":[40,30]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":true`))
    testing.expect(t, link.goals.has_home && link.goals.home == {40, 30} && link.goals.home_level == gs.level_index)
    agent_handle_line(link, gs, `{"cmd":"home","at":[400,30]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"ok":false`))
    testing.expect(t, link.goals.has_home, "a bad mark keeps the old")
    agent_handle_line(link, gs, `{"cmd":"home"}`)
    testing.expect(t, !link.goals.has_home)

    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"go"}]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "go needs to:[x,y]"))
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"fly"}]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), "do must name a goal kind: act, go, home"))
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"go","to":[40,30]},{"do":"home"}]}`)
    testing.expect(t, strings.contains(agent_test_reply(link), `"ids":[`))

    link.recording = false
    os.close(f)
    data, read_err := os.read_entire_file(path, context.allocator)
    testing.expect(t, read_err == nil)
    defer delete(data)
    text := string(data)
    testing.expect(t, strings.contains(text, `"reflexes":{"leave_hazard":true,"potion":false,"floor_dig":true,"rim_dig":false,"fight_back":true}`))
    testing.expect(t, strings.contains(text, `"home":[40,30],"level":`))
    testing.expect(t, strings.contains(text, `"home":null`))
    testing.expect(t, strings.contains(text, `"kind":"go"`) && strings.contains(text, `"kind":"home"`))
}

// Card 172, playtest 136: a driver that drops mid-act is seen going on the
// frames the act plays, so a watcher, or a fresh connection, drives at once;
// a line sent during an act still waits for the act's answer.
@(test)
a_driver_that_drops_mid_act_frees_the_seat :: proc(t: ^testing.T) {
    for fresh in ([2]bool{false, true}) {
        gs, link, at := agent_test_listening(t)
        defer free(gs)
        defer free(link)
        defer agent_close(link, gs)
        buf := new([AGENT_REPLY_MAX]u8)
        defer free(buf)

        driver, _ := net.dial_tcp(at)
        agent_test_ask(gs, link, driver, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
        watcher: net.TCP_Socket
        if !fresh {
            watcher, _ = net.dial_tcp(at)
            agent_test_ask(gs, link, watcher, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
        }
        net.send_tcp(driver, transmute([]u8)string(`{"cmd":"act","frames":600}` + "\n"))
        net.send_tcp(driver, transmute([]u8)string(`{"cmd":"state","w":1,"h":1}` + "\n"))
        time.sleep(50 * time.Millisecond)
        agent_test_frames(link, gs, 5)
        n, err := net.recv_tcp(driver, buf[:])
        testing.expectf(t, err == .Would_Block || err == .Timeout, "fresh %v: the state waits behind the act, got %d bytes %v", fresh, n, err)
        testing.expect(t, link.connected && agent_goals_busy(&link.goals), "the act plays")

        net.close(driver)
        time.sleep(50 * time.Millisecond)
        agent_test_frames(link, gs, 1)
        testing.expectf(t, !link.connected, "fresh %v: the driver gone mid-act is seen that frame", fresh)
        testing.expect(t, !agent_goals_busy(&link.goals), "its act ends")

        if fresh {
            watcher, _ = net.dial_tcp(at)
        }
        defer net.close(watcher)
        out := agent_test_ask(gs, link, watcher, `{"cmd":"objective","goal":"back"}` + "\n", 1, buf[:])
        for !strings.contains(out, `"re":"objective"`) && len(out) > 0 do out = agent_test_ask(gs, link, watcher, "", 1, buf[:])  // a watcher's events first
        testing.expectf(t, strings.contains(out, `{"re":"objective","ok":true}`), "fresh %v: %s", fresh, out)
        testing.expect(t, link.connected, "the next connection drives")
        testing.expect(t, strings.contains(agent_write_brief(link, gs), "when it closes, mid-act or not, its goals end"), "the brief says so")
    }
}

// Card 172: lines a driver sends during an act fill the read buffer and wait
// there, no drop; one line too long for it is still no protocol, act or not.
@(test)
held_lines_wait_in_a_full_buffer_but_an_endless_line_drops :: proc(t: ^testing.T) {
    for endless in ([2]bool{false, true}) {
        gs, link, at := agent_test_listening(t)
        defer free(gs)
        defer free(link)
        defer agent_close(link, gs)
        buf := new([AGENT_REPLY_MAX]u8)
        defer free(buf)

        driver, _ := net.dial_tcp(at)
        defer net.close(driver)
        agent_test_ask(gs, link, driver, `{"cmd":"state","w":1,"h":1}` + "\n", 1, buf[:])
        net.send_tcp(driver, transmute([]u8)string(`{"cmd":"act","frames":600}` + "\n"))
        line := `{"cmd":"state","w":1,"h":1}` + "\n"
        more := strings.repeat("x", AGENT_LINE_MAX + 10, context.temp_allocator) if endless else strings.repeat(line, AGENT_LINE_MAX / len(line) + 10, context.temp_allocator)
        net.send_tcp(driver, transmute([]u8)more)
        time.sleep(50 * time.Millisecond)
        agent_test_frames(link, gs, 5)
        testing.expectf(t, link.connected == !endless, "endless %v: connected %v", endless, link.connected)
        if !endless do testing.expect(t, link.in_len == AGENT_LINE_MAX && agent_goals_busy(&link.goals), "the buffer full, the act playing")
    }
}

// Card 172: an act the hero's brain holds (here at the pit's ledge, a beetle
// below and nowhere to run) ends failed with the reason, and is answered with
// state: it never waits forever (the pause cap, card 164).
@(test)
an_act_paused_by_the_brain_ends_with_a_reason :: proc(t: ^testing.T) {
    gs, link := agent_test_world()
    defer free(gs)
    defer free(link)
    link.realtime  = true
    link.events_on = true  // a client that speaks goals hears the pause
    // Flat stone, the hero hurt and unarmed between two walls, a beetle in a pit.
    x0, G := int(SURFACE_HOME_POS.x), int(SURFACE_Y)
    for x in x0 - 18 ..= x0 + 22 do for y in G - 10 ..= G + 12 do set_tile(&gs.world, x, y, .Air if y < G else .Stone)
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    gs.roamer_timer = -1e9
    gs.player.pos = {f32(x0) + 0.1, f32(G) - PLAYER_H}
    gs.player.inventory = {}
    gs.player.hp = 1
    for x in ([2]int{x0 - 3, x0 + 11}) do for y in G - 6 ..< G do set_tile(&gs.world, x, y, .Stone)
    for x in x0 + 3 ..= x0 + 5 do for y in G ..< G + 3 do set_tile(&gs.world, x, y, .Air)
    id, ok := enemy_alloc(&gs.enemies)
    testing.expect(t, ok)
    row := enemy_behaviour[.Ember_Beetle]
    e := &gs.enemies.data[id]
    e^ = Enemy{kind = .Ember_Beetle, hp = row.hp, hp_max = row.hp, facing = -1,
               pos = {f32(x0 + 4) + (1 - row.body.x) * 0.5, f32(G + 3) - row.body.y}}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))

    agent_handle_line(link, gs, `{"cmd":"act","move":"right","frames":120}`)
    frames := 0
    for ; frames < 6000 && agent_goals_busy(&link.goals); frames += 1 {
        if agent_drive(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
    testing.expectf(t, f32(frames) * AGENT_STEP > HERO_PAUSE_MAX_S, "held past a 120-frame act: %d frames", frames)
    testing.expect(t, !agent_goals_busy(&link.goals), "the act ended")
    pushed := string(link.push[:link.push_len])
    testing.expectf(t, strings.contains(pushed, "goal_paused"), "it was paused: %s", pushed)
    testing.expect(t, link.reply_due, "and the act is answered")
    reply := agent_test_reply(link)
    testing.expect(t, strings.contains(reply, `"re":"act"`), reply[:min(len(reply), 80)])
    held := false
    for &g in link.goals.slots[:link.goals.n] do if g.kind == .Act && g.status == .Failed {
        held = strings.has_prefix(string(g.reason.buf[:g.reason.len]), "held: paused by ")
    }
    testing.expect(t, held, "failed held, naming what held it")
}
