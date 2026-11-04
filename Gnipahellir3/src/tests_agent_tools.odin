package game

// The run tools of agent_tools.odin: what tools/agent_summary.py,
// agent_pacing.py, builder_trace.py and agent_replay.py did and their tests
// checked, ported (card 141).

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"

// A run folder of its own for one test, holding these files.
@(private="file")
tools_test_run :: proc(name: string, files: ..[2]string) -> string {
    folder := fmt.aprintf("tools_test_%s", name)
    os.remove_all(folder)
    os.make_directory_all(folder)
    for f in files do _ = os.write_entire_file(fmt.tprintf("%s/%s", folder, f[0]), f[1])
    return folder
}

@(private="file")
tools_test_done :: proc(folder: string) {
    os.remove_all(folder)
    delete(folder)
}

// A report's text, and whether it ran.
@(private="file")
tools_test_say :: proc(args: ..string) -> (text: string, code: int) {
    b := strings.builder_make()  // not the temp arena: a report frees what it put there
    defer strings.builder_destroy(&b)
    _, _, code = tool_args(args, &b)
    return strings.clone(strings.to_string(b), context.temp_allocator), code
}

// ─── --summary (tools/test_agent_summary.py) ────────────────────────────────

@(private="file")
tools_test_summary :: proc(name, log: string) -> string {
    run := tools_test_run(name, {"action.log", log})
    defer tools_test_done(run)
    text, _ := tools_test_say("--summary", run)
    return text
}

@(private="file")
tools_test_repeat :: proc(line: string, n: int) -> string {
    return strings.repeat(line, n, context.temp_allocator)
}

@(test)
summary_builder_mines_and_places_count_on_one_tile :: proc(t: ^testing.T) {
    log := tools_test_repeat("[f0000010] Builder#1 mines (5,6)\n[f0000020] Builder#1 places at (5,6)\n", 4)
    text := tools_test_summary("churn_named", log)
    testing.expect(t, strings.contains(text, "churn: tile (5,6) mined or placed 8 times by builders"), text)
}

@(test)
summary_old_unnamed_builder_lines_count_too :: proc(t: ^testing.T) {
    log := tools_test_repeat("[f0000010] Builder mines (5,6)\n[f0000020] Builder places at (5,6)\n", 4)
    text := tools_test_summary("churn_old", log)
    testing.expect(t, strings.contains(text, "mined or placed 8 times"), text)
}

@(test)
summary_other_kinds_are_not_builder_churn :: proc(t: ^testing.T) {
    log := tools_test_repeat("[f0000010] Vargr#2 mines (5,6)\n[f0000020] Vargr#2 places at (5,6)\n", 4)
    text := tools_test_summary("churn_vargr", log)
    testing.expect(t, !strings.contains(text, "churn:"), text)
}

@(test)
summary_names_each_life_its_killer_and_the_parked_bodies :: proc(t: ^testing.T) {
    b := strings.builder_make(context.temp_allocator)
    strings.write_string(&b, "[f0000001] Player takes 3 damage from Vargr#12 (hp 7)\n[f0000002] Player dies at (4,5)\n")
    strings.write_string(&b, "[f0000003] New game - world seed 9\n[f0000004] Player enters level 1\n[f0000005] Builder#2 no path to (1,1)\n")
    strings.write_string(&b, "[f0000006] pos Player (9.0,9.0) Player takes Rune Scroll B from chest\n[f0000007] Player takes Rune Scroll B from chest\n")
    for i in 0 ..< 7 do fmt.sbprintf(&b, "[f%07d] pos Enemy#3 Builder (50.0,60.0) hp=10 goal=Hunt target=(0,0)\n", 300 * (i + 1))
    for i in 0 ..< 6 do fmt.sbprintf(&b, "[f%07d] pos Player (1.0,2.0) hp=10\n", 300 * (i + 1))
    text := tools_test_summary("lives", strings.to_string(b))
    for want in ([]string{"life 1: Player dies at (4,5) - last hurt by Vargr", "  New game - world seed 9", "deaths by cause: Vargr 1",
                          "[f0000004] Player enters level 1", "stuck: Enemy#3 Builder parked 30 s at (50.0,60.0), ending frame 2100",
                          "no path: 1 lines", "[f0000007] Player takes Rune Scroll B from chest"}) {
        testing.expect(t, strings.contains(text, want), want)
    }
    testing.expect(t, !strings.contains(text, "stuck: Player"), "five still steps are not stuck")
    testing.expect(t, !strings.contains(text, "[f0000006]"), "a breadcrumb is not a milestone")
}

// The goal queue's rows (Glenn, 2026-11-03): how long the hero stood with
// nothing to do, how fast the next goal came, how often goals failed and why.
@(test)
summary_measures_how_the_goal_queue_kept_the_hero_busy :: proc(t: ^testing.T) {
    goal :: proc(f, id: int) -> string {
        return fmt.tprintf(`{{"f":%d,"goal":{{"do":"act","frames":30}},"kind":"act","id":%d,"via":"Goal","step":0}}`+"\n", f, id)
    }
    rows := strings.concatenate({
        goal(0, 1), `{"f":60,"done":1}` + "\n",
        goal(180, 2), `{"f":200,"window":true}` + "\n", `{"f":230,"failed":2,"reason":"no path"}` + "\n", `{"f":260,"window":false}` + "\n",
        goal(290, 3), goal(300, 4), `{"f":330,"failed":3,"reason":"cancelled"}` + "\n", `{"f":330,"failed":4,"reason":"cancelled"}` + "\n",
        `{"f":400,"objective":{"goal":"find gold"}}` + "\n", `{"f":410,"act":{"mine":[1,2]},"x":5,"y":6,"hp":10}` + "\n",
        `{"f":420,"act":{"mine":[1,3]},"x":5,"y":6,"hp":10}` + "\n", `{"f":430,"act":{"move":"left"},"x":5,"y":6,"hp":10}` + "\n",
        `{"f":440,"act":{"place":[1,3]},"x":6,"y":6,"hp":10}` + "\n",
        `{"f":600,"objective":{"goal":"go home","result":"failed"}}` + "\n",
        `{"f":630,"mark":"disconnect"}` + "\n",
        goal(900, 5), `{"f":960,"done":5}` + "\n", `{"f":1080,"mark":"disconnect"}` + "\n",
    }, context.temp_allocator)
    run := tools_test_run("goals", {"action.log", ""}, {"acts.jsonl", rows}, {"fight.log", "5,2,Vargr,1,2,3\n5,P,1,2,10\n6,2,Vargr,1,2,3\n6,4,Builder,1,2,3\n"})
    defer tools_test_done(run)
    text, code := tools_test_say("--summary", run)
    testing.expect_value(t, code, 0)
    for want in ([]string{
        "5 goals in 0.2 min connected, 22.2 per minute",
        "empty queue: 10 s, longest 5 s from frame 330",
        "next goal after one ends: median 1.5 s, max 2.0 s, over 2 ends",
        "ended: 2 done, 3 failed (60%): cancelled 40%, no path 20%",
        "window open: 1 s",
        "objectives:\n  f400: find gold - 3 s (failed)\n  f600: go home - 8 s\n",
        "4 acts, last frame 1080", "acts with no visible effect on the player, by verb: mine 1\n", "frame 630: disconnect",
        "2 frames with enemies near; enemy-frames by kind: Vargr 2, Builder 1",
    }) {
        testing.expect(t, strings.contains(text, want), want)
    }
}

@(test)
summary_counts_the_last_stretch_of_a_run_still_connected :: proc(t: ^testing.T) {
    rows := `{"f":0,"goal":{"do":"act","frames":30},"kind":"act","id":1,"via":"Goal","step":0}` + "\n" +
            `{"f":60,"done":1}` + "\n" + `{"f":360,"act":{"move":"left"},"x":5,"y":6,"hp":10}` + "\n"
    run := tools_test_run("goals_open", {"action.log", ""}, {"acts.jsonl", rows})
    defer tools_test_done(run)
    text, _ := tools_test_say("--summary", run)
    for want in ([]string{"1 goals in 0.1 min connected", "empty queue: 5 s, longest 5 s from frame 60"}) {
        testing.expect(t, strings.contains(text, want), want)
    }
}

// A dropped client's goals are wiped with no failed rows: the next stretch
// starts with an empty queue.
@(test)
summary_starts_a_reconnect_with_an_empty_queue :: proc(t: ^testing.T) {
    goal :: proc(f, id: int) -> string {
        return fmt.tprintf(`{{"f":%d,"goal":{{"do":"act","frames":30}},"kind":"act","id":%d,"via":"Goal","step":0}}`+"\n", f, id)
    }
    rows := strings.concatenate({
        goal(0, 1), `{"f":60,"mark":"disconnect"}` + "\n", `{"f":120,"act":{"move":"left"},"x":5,"y":6,"hp":10}` + "\n",
        goal(300, 2), `{"f":360,"done":2}` + "\n", `{"f":420,"act":{"move":"left"},"x":5,"y":6,"hp":10}` + "\n",
    }, context.temp_allocator)
    run := tools_test_run("goals_dropped", {"action.log", ""}, {"acts.jsonl", rows})
    defer tools_test_done(run)
    text, _ := tools_test_say("--summary", run)
    testing.expect(t, strings.contains(text, "empty queue: 4 s, longest 3 s from frame 120"), text)
}

@(test)
summary_of_a_run_with_no_log_says_so :: proc(t: ^testing.T) {
    text, code := tools_test_say("--summary", "tools_test_no_such_run")
    testing.expect_value(t, code, 1)
    testing.expect(t, strings.contains(text, "cannot read"), text)
}

// ─── --pacing (tools/test_agent_pacing.py) ──────────────────────────────────

@(private="file")
TWO_LIVES :: `[f0000000] === run start 2026-11-02 15:05:22 - save v28 ===
[f0000000] World seed 111
[f0000600] Player takes Gold_Bar x4 from smelter at (1,2)
[f0001200] Player dies at (40,64) after 20 s
[f0000000] New game - world seed 222
continuation line with no frame
[f0003000] Player takes Silver_Bar x9 from smelter at (1,2)
[f0006000] Player takes Rune Scroll A from permanent chest at (1,1)
[f0009000] Player takes Rune Scroll B from permanent chest at (12,101)
[f0009060] Player takes Rune Scroll B from permanent chest at (12,101)
[f0012000] Player takes Gold_Bar x9 from smelter at (1,2)
[f0012600] Player takes Gold_Bar x1 from smelter at (1,2)
[f0013000] Player takes Gold_Bar x5 from smelter at (1,2)`

@(test)
pacing_reads_each_life_from_the_log :: proc(t: ^testing.T) {
    lives := tool_pacing_parse(strings.split_lines(TWO_LIVES, context.temp_allocator))
    defer delete(lives)
    testing.expect_value(t, len(lives), 2)
    one, two := lives[0], lives[1]
    testing.expect_value(t, one.seed, 111)  // a New Game starts a life with its own seed
    testing.expect_value(t, two.seed, 222)
    testing.expect_value(t, one.scroll_b, -1)  // marks land in the life that made them
    testing.expect_value(t, two.scroll_b, 9000.0 / 60)  // Scroll A does not count, the first B does
    testing.expect_value(t, two.gold_10, 12600.0 / 60)  // ten bars add up across takes, and only gold
    testing.expect_value(t, two.bars, 15)
    testing.expect_value(t, one.gold_10, -1)  // bars do not carry over a death
    testing.expect_value(t, one.bars, 4)
    testing.expect(t, one.died && !two.died)
    testing.expect_value(t, one.lasted, 20)
    testing.expect_value(t, two.lasted, 13000.0 / 60)
    testing.expect_value(t, one.before, 0)  // before counts the lives lost on the way
    testing.expect_value(t, two.before, 20)
}

@(test)
pacing_nine_bars_are_not_ten_and_ten_are :: proc(t: ^testing.T) {
    nine := tool_pacing_parse({"[f0000060] Player takes Gold_Bar x9 from smelter at (1,2)"})
    defer delete(nine)
    testing.expect_value(t, nine[0].gold_10, -1)
    ten := tool_pacing_parse({"[f0000060] Player takes Gold_Bar x10 from smelter at (1,2)"})
    defer delete(ten)
    testing.expect_value(t, ten[0].gold_10, 1)
}

@(test)
pacing_first_takes_the_earliest_life_and_adds_what_came_before :: proc(t: ^testing.T) {
    lives := []Tool_Life{{scroll_b = -1, before = 0}, {scroll_b = 5, before = 7}, {scroll_b = 1, before = 30}}
    s, with, ok := tool_pacing_first(lives, false)
    testing.expect(t, ok && s == 5 && with == 12)
    _, _, ok = tool_pacing_first(lives[:1], false)
    testing.expect(t, !ok)
}

@(test)
pacing_medians_are_over_the_runs_that_got_there :: proc(t: ^testing.T) {
    a := tools_test_run("pace_a", {"action.log", "[f0000600] Player takes Rune Scroll B from x\n[f0006000] Player takes Gold_Bar x10 from smelter\n"})
    defer tools_test_done(a)
    b := tools_test_run("pace_b", {"action.log", "[f0001800] Player takes Rune Scroll B from x\n"})
    defer tools_test_done(b)
    c := tools_test_run("pace_c", {"action.log", "[f0000300] Player dies\n[f0000000] New game\n[f0001200] Player takes Rune Scroll B from x\n"})
    defer tools_test_done(c)
    d := tools_test_run("pace_d", {"action.log", "[f0000300] Player walks\n"})
    defer tools_test_done(d)
    text, code := tools_test_say("--pacing", a, b, c, d)
    testing.expect_value(t, code, 0)
    testing.expect(t, strings.contains(text, "scroll_b_s: reached 3 of 4, median 20 s, with lost lives 25 s"), text)
    testing.expect(t, strings.contains(text, "gold_10_s: reached 1 of 4, median 100 s, with lost lives 100 s"), text)
    text, _ = tools_test_say("--pacing", d)
    testing.expect(t, strings.contains(text, "gold_10_s: reached 0 of 1, median - s, with lost lives - s"), text)
}

@(test)
pacing_reads_a_folder_prints_and_writes_csv :: proc(t: ^testing.T) {
    run := tools_test_run("run1", {"action.log", TWO_LIVES})
    defer tools_test_done(run)
    csv := "tools_test_pacing.csv"
    defer os.remove(csv)
    text, code := tools_test_say("--pacing", fmt.tprintf("./%s/", run), "--csv", csv)
    testing.expect_value(t, code, 0)
    testing.expect(t, strings.contains(text, "scroll_b_s: reached 1 of 1, median 150 s, with lost lives 170 s"), text)
    testing.expect(t, strings.contains(text, "gold_10_s: reached 1 of 1, median 210 s, with lost lives 230 s"), text)
    testing.expect(t, strings.contains(text, "tools_test_run1"), "the run is named by its folder")
    data, err := os.read_entire_file(csv, context.temp_allocator)
    testing.expect(t, err == nil)
    rows := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
    testing.expect_value(t, len(rows), 3)
    testing.expect_value(t, strings.trim_space(rows[0]), "run,life,seed,scroll_b_s,gold_10_s,lasted_s,died,before_s")
    testing.expect_value(t, strings.trim_space(rows[1]), "tools_test_run1,1,111,,,20.0,True,0.0")
    testing.expect(t, strings.has_prefix(rows[2], "tools_test_run1,2,222,150.0,210.0,216.6"), rows[2])
}

@(test)
pacing_with_no_folders_says_how :: proc(t: ^testing.T) {
    text, code := tools_test_say("--pacing")
    testing.expect_value(t, code, 2)
    testing.expect(t, strings.contains(text, "usage:"))
}

// ─── --builder-trace (tools/test_builder_trace.py) ──────────────────────────

@(private="file")
TRACE_LOG :: `[f0000000] === run start ===
[f0000300] pos Enemy#1 Builder (50.0,60.0) hp=10 goal=Hunt target=(0,0)
[f0000310] Builder#1 mines (51,60)
[f0000320] Vargr#2 mines (52,60)
[f0000330] Vargr#2 clears climb tile (52,59)
[f0000340] Vargr#2 places at (53,61)
[f0000350] Raider#3 mines (49,60)
[f0000360] Builder mines (50,61)
[f0000600] pos Enemy#1 Builder (50.0,60.0) hp=10 goal=Hunt target=(0,0)`

@(test)
trace_named_digs_go_to_their_digger_only :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    tr := trace_parse(strings.split_lines(TRACE_LOG + "\n[f0002000] Builder mines (50,62)"))
    w := tr.worlds[{1, 0}]
    testing.expect(t, w != nil)
    testing.expect(t, 2 not_in w.bots && 3 not_in w.bots, "a Vargr's or a Raider's dig is not a Builder's")
    ops := w.bots[1].ops[:]
    testing.expect_value(t, len(ops), 2)  // the dig at f2000 is past every Builder's track
    testing.expect_value(t, ops[0], Trace_Op{310, "mine", 51, 60, false})
    testing.expect_value(t, ops[1], Trace_Op{360, "mine", 50, 61, true})
}

@(test)
trace_reports_a_builders_tiles_and_what_it_undid :: proc(t: ^testing.T) {
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< 4 {
        fmt.sbprintf(&b, "[f%07d] pos Enemy#4 Builder (%d.0,60.0) hp=10 goal=Build_Den target=(1,2)\n", 300 * (i + 1), 10 + 3 * i)
        fmt.sbprintf(&b, "[f%07d] Builder#4 places at (5,6)\n[f%07d] Builder#4 mines (5,6)\n", 300 * (i + 1) + 10, 300 * (i + 1) + 40)
    }
    strings.write_string(&b, "[f0001300] Builder mines (12,60)\n[f0001310] Builder#4 strike 2 (no path)\n[f0001320] Builder#4 starts den at (7,8)\n")
    run := tools_test_run("trace", {"action.log", strings.to_string(b)})
    defer tools_test_done(run)
    text, code := tools_test_say("--builder-trace", fmt.tprintf("%s/action.log", run), "--min-frames", "0")
    testing.expect_value(t, code, 0)
    for want in ([]string{
        "== life 1 level 0: 1320 frames (22 s) with the player here ==",
        "  Builder#4: 4 crumbs over frames 300-1200 (15 s): Build_Den 100%",
        "    still while not idle: 0 s (0%)\n",
        "    den_start=1 no_path=1",
        "    ops: mine=5 place=4 (~1 attributed)",
        "    den sites: (7,8)@f1320",
        "    tiles touched: (5,6)x8",
        "    put then taken: 4, median gap 30 frames: place>mine=4",
        "      e.g. (5, 6) place f310, mine f340",
        "life 1 level 0: 100% of 1 builder-minutes: carousel 100%",
        "bots=1 den_start=1 no_path=1",
    }) {
        testing.expect(t, strings.contains(text, want), want)
    }
    text, _ = tools_test_say("--builder-trace", run, "--min-frames", "0", "--tiles", "0")
    testing.expect(t, !strings.contains(text, "tiles touched"), "--tiles 0 lists no tile")
}

@(test)
trace_pairs_each_take_with_one_put :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    pairs := trace_put_then_taken({{10, "place", 1, 1, false}, {20, "mine", 1, 1, false}, {30, "mine", 1, 1, false}})
    testing.expect_value(t, len(pairs), 1)
}

// A life ends at its last Builder crumb; a level no Builder showed on is left out.
@(test)
trace_clocks_a_life_to_its_end_and_skips_empty_levels :: proc(t: ^testing.T) {
    log := `[f0000300] pos Enemy#1 Builder (10.0,10.0) hp=10 goal=Hunt target=(0,0)
[f0000900] pos Enemy#1 Builder (10.0,10.0) hp=10 goal=Hunt target=(0,0)
[f0000000] New game - world seed 2
[f0000100] Player enters level 3
[f0000400] Player walks
`
    run := tools_test_run("trace_lives", {"action.log", log})
    defer tools_test_done(run)
    text, _ := tools_test_say("--builder-trace", run, "--min-frames", "0")
    testing.expect(t, strings.contains(text, "== life 1 level 0: 900 frames (15 s) with the player here =="), text)
    testing.expect(t, !strings.contains(text, "life 2"), text)
}

@(test)
tool_find_takes_the_first_match_or_the_last_and_no_empty_number :: proc(t: ^testing.T) {
    caps, _, ok := tool_find("a1 a2", "a{d}")
    testing.expect(t, ok && caps.v[0] == "1")
    caps, _, ok = tool_find("a1 a2", "a{d}", last = true)
    testing.expect(t, ok && caps.v[0] == "2")
    _, _, ok = tool_find("at (,5)", "at ({d},{d})")
    testing.expect(t, !ok, "a number needs a digit")
}

@(test)
trace_cycles_and_rounding_match_the_old_tool :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    seq := []string{"a", "b", "a", "b", "a", "b", "c", "c", "c", "c"}
    found := trace_cycles(seq)
    testing.expect_value(t, len(found), 1)
    testing.expect_value(t, found[0], [3]int{0, 2, 6})  // one value over and over is no cycle
    testing.expect_value(t, trace_round(2.5), 2)  // a half goes to the even neighbour
    testing.expect_value(t, trace_round(3.5), 4)
    testing.expect_value(t, trace_round(-2.5), -2)
    testing.expect_value(t, trace_round(2.6), 3)
}

// ─── The command line ───────────────────────────────────────────────────────

@(test)
tool_args_pick_the_mode_and_turn_away_what_is_wrong :: proc(t: ^testing.T) {
    b := strings.builder_make(context.temp_allocator)
    run, exit, code := tool_args({}, &b)
    testing.expect(t, run.mode == .Play && !exit)
    run, exit, _ = tool_args({"--agent-run"}, &b)
    testing.expect(t, run.mode == .Agent_Run && !exit && run.port == TOOL_RUN_PORT && !run.seeded)
    run, exit, _ = tool_args({"--agent-run", "--seed", "42", "--port", "7790"}, &b)
    testing.expect(t, run.port == 7790 && run.seeded && run.seed == 42 && !exit)
    for bad in ([][]string{{"--agent-run", "--port", "0"}, {"--agent-run", "--port"}, {"--agent-run", "--fast"}, {"--replay"},
                           {"--summary"}, {"--builder-trace"}, {"--builder-trace", "a", "b"}, {"--builder-trace", "a", "--tiles", "x"}, {"--nope"}}) {
        _, exit, code = tool_args(bad, &b)
        testing.expect(t, exit && code == 2, fmt.tprint(bad))
    }
    run, exit, _ = tool_args({"--replay", "somewhere"}, &b)
    testing.expect(t, run.mode == .Replay && run.folder == "somewhere" && !exit)
    _, exit, code = tool_args({"--help"}, &b)
    testing.expect(t, exit && code == 0)
}

// ─── --replay (tools/agent_replay.py) ───────────────────────────────────────

@(private="file")
tools_test_world :: proc() -> (gs: ^Game_State, link: ^Agent_Link) {
    gs = new(Game_State)
    link = new(Agent_Link)
    game_state_init(gs, 778)
    gs.ui.show_title = false
    gs.player.pos = SURFACE_HOME_POS
    return
}

@(private="file")
tools_test_record :: proc(link: ^Agent_Link, path: string) {
    f, _ := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
    link.acts_file, link.recording = f, true
}

// A run in real time: goals, the old act and wait, a plan an act cuts, and a
// cancel, each on its own frame, with idle frames between.
@(private="file")
tools_test_play :: proc(link: ^Agent_Link, gs: ^Game_State, frames: int, wait_off := false) {
    link.connected, link.realtime = true, true
    for frame in 0 ..< frames {
        switch frame {
        case 5:   agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"right","frames":40},{"do":"act","move":"left","jump":true,"frames":30}]}`)
        case 90:  agent_handle_line(link, gs, `{"cmd":"act","move":"left","frames":20}`)
        case 130: agent_handle_line(link, gs, `{"cmd":"plan","acts":[{"move":"right","frames":40},{"move":"left","frames":50}]}`)
        case 150: agent_handle_line(link, gs, `{"cmd":"act","move":"right","jump":true,"frames":15}`)
        case 200: agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"left","frames":60},{"do":"act","move":"right","frames":60}]}`)
        case 210: agent_handle_line(link, gs, `{"cmd":"objective","goal":"walk about","step":"left"}`)
        case 215: agent_handle_line(link, gs, `{"cmd":"say","text":"turning"}`)
        case 220: agent_handle_line(link, gs, `{"cmd":"goals","cancel":7}`)
        case 240: agent_handle_line(link, gs, `{"cmd":"wait","frames":25}`)
        }
        if agent_drive(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
}

// Replays rows into a fresh world until the replay is done.
@(private="file")
tools_test_replay :: proc(rows, got: string) -> (rep: Tool_Replay, gs: ^Game_State, link: ^Agent_Link) {
    gs, link = tools_test_world()
    tools_test_record(link, got)
    tool_replay_begin(&rep, link, gs, rows, got)
    for _ in 0 ..< 5000 {
        if rep.done do break
        if tool_replay_frame(&rep, link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
    return
}

@(test)
replay_feeds_the_goals_back_on_their_frames_and_lands_the_same :: proc(t: ^testing.T) {
    rec_path, got_path := "tools_test_replay_rec.jsonl", "tools_test_replay_got.jsonl"
    defer os.remove(rec_path)
    defer os.remove(got_path)
    gs, link := tools_test_world()
    defer free(gs)
    defer free(link)
    tools_test_record(link, rec_path)
    tools_test_play(link, gs, 400)
    os.close(link.acts_file)
    data, _ := os.read_entire_file(rec_path, context.allocator)
    defer delete(data)
    for want in ([]string{`"via":"Goal"`, `"via":"Act"`, `"via":"Plan"`, `"via":"Wait"`, `"cancel":7`, `"clear":true`, `"played":`, `"done":1`, `"failed":4`, `"failed":7`, `"failed":8`}) {
        testing.expect(t, strings.contains(string(data), want), want)
    }

    rep, gs2, link2 := tools_test_replay(string(data), got_path)
    defer free(gs2)
    defer free(link2)
    testing.expect(t, rep.done && !rep.diverged, "every act lands where it did")
    testing.expect(t, !rep.cut)
    testing.expect_value(t, gs2.player.pos, gs.player.pos)
    testing.expect_value(t, gs2.enemies.count, gs.enemies.count)
    testing.expect(t, gs2.frame <= gs.frame, "it stops once the last goal is done")
    testing.expect(t, !link2.connected && !link2.recording, "a finished replay lets go")
    testing.expect_value(t, string(link2.panel.goal.buf[:link2.panel.goal.len]), "walk about")  // the watcher sees what the agent said
    testing.expect_value(t, string(link2.panel.say.buf[:link2.panel.say.len]), "turning")
    n, ok, _ := tool_replay_compare(string(data), string(data))
    testing.expect(t, ok && n >= 4, "the run's acts are all checked")
}

@(test)
replay_says_where_a_run_parts_from_its_recording :: proc(t: ^testing.T) {
    want := `{"f":10,"act":{"frames":10},"x":1.000,"y":2.000,"hp":10,"mana":3.00,"lvl":0,"enemies":0}` + "\n" +
            `{"f":20,"act":{"frames":10},"x":1.000,"y":2.000,"hp":10,"mana":3.00,"lvl":0,"enemies":0}` + "\n"
    n, ok, note := tool_replay_compare(want, want)
    testing.expect(t, ok && n == 2)
    moved, _ := strings.replace(want, `"x":1.000,"y":2.000,"hp":10,"mana":3.00,"lvl":0,"enemies":0}`+"\n", `"x":1.020,"y":2.000,"hp":10,"mana":3.00,"lvl":0,"enemies":0}`+"\n", 1, context.temp_allocator)
    n, ok, note = tool_replay_compare(want, moved)
    testing.expect(t, !ok && n == 0 && strings.contains(note, "DIVERGED after 0 acts"), note)
    nudged, _ := strings.replace(want, `"x":1.000`, `"x":1.005`, 1, context.temp_allocator)
    _, ok, _ = tool_replay_compare(want, nudged)
    testing.expect(t, ok, "within a hundredth of a tile is the same place")
    hurt, _ := strings.replace(want, `"hp":10`, `"hp":9`, 2, context.temp_allocator)
    n, ok, _ = tool_replay_compare(want, hurt)
    testing.expect(t, !ok && n == 0)
    for changed in ([][2]string{{`"lvl":0`, `"lvl":1`}, {`"mana":3.00`, `"mana":3.50`}, {`{"f":10,`, `{"f":11,`}}) {
        other, _ := strings.replace(want, changed[0], changed[1], 1, context.temp_allocator)
        _, ok, _ = tool_replay_compare(want, other)
        testing.expect(t, !ok, changed[1])
    }
    calm, _ := strings.replace(want, `"mana":3.00`, `"mana":3.05`, 1, context.temp_allocator)
    _, ok, _ = tool_replay_compare(want, calm)
    testing.expect(t, ok, "mana within a tenth is the same")
    _, ok, note = tool_replay_compare(want, want[:strings.index_byte(want, '\n') + 1])
    testing.expect(t, !ok && strings.contains(note, "1 of 2"), note)
}

@(test)
replay_of_a_changed_world_diverges :: proc(t: ^testing.T) {
    rec_path, got_path := "tools_test_replay_rec2.jsonl", "tools_test_replay_got2.jsonl"
    defer os.remove(rec_path)
    defer os.remove(got_path)
    gs, link := tools_test_world()
    defer free(gs)
    defer free(link)
    tools_test_record(link, rec_path)
    tools_test_play(link, gs, 120)
    os.close(link.acts_file)
    data, _ := os.read_entire_file(rec_path, context.allocator)
    defer delete(data)
    // A goal that went right goes left: the act after it no longer lands where it did.
    turned, _ := strings.replace(string(data), `"right"`, `"left"`, 1, context.temp_allocator)  // the first goal's
    testing.expect(t, strings.has_prefix(string(data), `{"f":5,"goal":`) && turned != string(data))
    rep, gs2, link2 := tools_test_replay(turned, got_path)
    defer free(gs2)
    defer free(link2)
    testing.expect(t, rep.done && rep.diverged)
}

@(test)
replay_stops_at_a_disconnect :: proc(t: ^testing.T) {
    got_path := "tools_test_replay_got3.jsonl"
    defer os.remove(got_path)
    rows := `{"f":3,"goal":{"do":"act","move":"right","frames":100},"kind":"act","id":1,"via":"Goal","step":0}` + "\n" +
            `{"f":3,"goal":{"do":"fly"},"kind":"fly","id":9,"via":"Goal","step":0}` + "\n" +
            `{"f":40,"mark":"disconnect"}` + "\n" +
            `{"f":41,"goal":{"do":"act","move":"left","frames":10},"kind":"act","id":2,"via":"Goal","step":0}` + "\n"
    rep, gs, link := tools_test_replay(rows, got_path)
    defer free(gs)
    defer free(link)
    testing.expect(t, rep.done && rep.cut && !rep.diverged)
    testing.expect_value(t, gs.frame, 40)
    testing.expect_value(t, link.goals.n, 1)
}

// A replay ticks through a gap longer than the idle wait, as the run did in
// real time, and once the rows are out it plays the last goal to its end.
@(test)
replay_ticks_between_goals_and_plays_the_last_one_out :: proc(t: ^testing.T) {
    got_path := "tools_test_replay_got4.jsonl"
    defer os.remove(got_path)
    rows := `{"f":3,"goal":{"do":"act","move":"right","frames":30},"kind":"act","id":1,"via":"Goal","step":0}` + "\n" +
            `{"f":400,"goal":{"do":"act","move":"left","frames":30},"kind":"act","id":2,"via":"Goal","step":0}` + "\n"
    rep, gs, link := tools_test_replay(rows, got_path)
    defer free(gs)
    defer free(link)
    testing.expect(t, rep.done && !rep.diverged)
    testing.expect(t, gs.frame >= 430, "the last goal ran its 30 frames")
}

// ─── Turbo (tools/test_agent_turbo.py) ──────────────────────────────────────

// GNIPA_AGENT_TURBO changes how often the window draws and nothing the game
// does: the same goals land the same acts and end in the same world.  Rows are
// compared by what they say: the game writes a goal's keys in map order.
@(test)
turbo_changes_the_drawing_and_nothing_the_game_does :: proc(t: ^testing.T) {
    play :: proc(turbo: bool, path: string) -> (gs: ^Game_State, rows: []u8) {
        link: ^Agent_Link
        gs, link = tools_test_world()
        defer free(link)
        link.turbo = turbo
        tools_test_record(link, path)
        tools_test_play(link, gs, 300)
        os.close(link.acts_file)
        rows, _ = os.read_entire_file(path, context.allocator)
        os.remove(path)
        return
    }
    plain, plain_rows := play(false, "tools_test_turbo_plain.jsonl")
    defer free(plain)
    defer delete(plain_rows)
    turbo, turbo_rows := play(true, "tools_test_turbo_on.jsonl")
    defer free(turbo)
    defer delete(turbo_rows)
    n, same, note := tool_replay_compare(string(plain_rows), string(turbo_rows))
    testing.expect(t, same && n >= 4, note)
    testing.expect_value(t, strings.count(string(turbo_rows), "\n"), strings.count(string(plain_rows), "\n"))
    testing.expect_value(t, turbo.frame, plain.frame)
    testing.expect_value(t, turbo.player.pos, plain.player.pos)
    testing.expect_value(t, turbo.player.hp, plain.player.hp)
    for i in 0 ..< MAX_ENEMIES do testing.expect_value(t, turbo.enemies.data[i].pos, plain.enemies.data[i].pos)
}

@(test)
replay_closed_mid_way_lets_go_of_its_record :: proc(t: ^testing.T) {
    path := "tools_test_replay_end.jsonl"
    defer os.remove(path)
    gs, link := tools_test_world()
    defer free(gs)
    defer free(link)
    tools_test_record(link, path)
    rep: Tool_Replay
    tool_replay_begin(&rep, link, gs, `{"f":50,"mark":"disconnect"}` + "\n", path)
    tool_replay_frame(&rep, link, gs)
    testing.expect(t, link.connected && !rep.done, "still replaying")
    tool_replay_end(&rep, link)
    testing.expect(t, !link.connected && !link.recording, "no socket to drop, and the record closed")
}

// ─── What acts.jsonl now carries for the summary ────────────────────────────

@(test)
a_run_records_each_goals_end_and_each_window :: proc(t: ^testing.T) {
    path := "tools_test_rows.jsonl"
    defer os.remove(path)
    gs, link := tools_test_world()
    defer free(gs)
    defer free(link)
    tools_test_record(link, path)
    link.connected, link.realtime = true, true
    tick :: proc(link: ^Agent_Link, gs: ^Game_State, n: int) {
        for _ in 0 ..< n {
            agent_drive(link, gs)
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","frames":3},{"do":"act","frames":50}]}`)
    tick(link, gs, 5)
    agent_handle_line(link, gs, `{"cmd":"goals","clear":true}`)
    tick(link, gs, 1)
    gs.ui.show_inventory = true
    tick(link, gs, 2)
    gs.ui.show_inventory = false
    tick(link, gs, 2)
    os.close(link.acts_file)
    data, _ := os.read_entire_file(path, context.temp_allocator)
    rows := string(data)
    for want in ([]string{`{"f":3,"done":1}`, `{"f":5,"failed":2,"reason":"cancelled"}`, `{"f":7,"window":true}`, `{"f":9,"window":false}`}) {
        testing.expect(t, strings.contains(rows, want), want)
    }
    testing.expect_value(t, strings.count(rows, `"window"`), 2)
}

// ─── --agent-run's port, seed and folder ────────────────────────────────────

// --agent-run keeps the binary that played beside the run, and says how to replay with it.
@(test)
an_agent_run_keeps_its_binary_and_says_how_to_replay :: proc(t: ^testing.T) {
    run := tools_test_run("keep_bin", {"exe", "the binary"})
    defer tools_test_done(run)
    here := fmt.tprintf("%s/run", run)
    os.make_directory(here)
    hint, ok := tool_run_keep_binary(fmt.tprintf("%s/exe", run), "/where/assets/are", here)
    testing.expect(t, ok)
    name := "gnipa.exe" when ODIN_OS == .Windows else "gnipa"
    data, err := os.read_entire_file(fmt.tprintf("%s/%s", here, name), context.temp_allocator)
    testing.expect(t, err == nil && string(data) == "the binary", "the run keeps a copy of the binary")
    testing.expect_value(t, hint, fmt.tprintf("replay it with: cd /where/assets/are && %s/%s --replay %s", here, name, here))
    _, ok = tool_run_keep_binary(fmt.tprintf("%s/no_such_exe", run), "/", here)
    testing.expect(t, !ok, "no binary, no hint")
}

@(test)
an_agent_run_takes_the_port_seed_and_folder_it_names :: proc(t: ^testing.T) {
    gs, link := tools_test_world()
    defer free(gs)
    defer free(link)
    probe, _ := agent_bind(0)
    free_at, _ := net.bound_endpoint(probe)
    net.close(probe)
    link.run_port, link.run_seed, link.run_seeded, link.run_dir = free_at.port, 4242, true, "tools_test_runs"
    sock, port, seed, folder, ok := agent_run_choice(link, gs)
    testing.expect(t, ok)
    testing.expect_value(t, port, free_at.port)
    testing.expect_value(t, seed, 4242)
    testing.expect(t, strings.has_prefix(folder, "tools_test_runs/") && strings.has_suffix(folder, fmt.tprintf("-%d", port)), folder)
    _, _, _, _, again := agent_run_choice(link, gs)
    testing.expect(t, !again, "a named port that is taken is not traded for another")
    net.close(sock)
    gs.ui.title_seed_len = copy(gs.ui.title_seed[:], "77")
    link.run_seeded = false
    other, _, typed, _, _ := agent_run_choice(link, gs)
    net.close(other)
    testing.expect_value(t, typed, 77)
}

@(test)
trace_reads_searches_dens_loops_and_levels :: proc(t: ^testing.T) {
    b := strings.builder_make(context.temp_allocator)
    for f in ([]int{300, 600, 900, 1200}) do fmt.sbprintf(&b, "[f%07d] pos Enemy#5 Builder (30.0,40.0) hp=10 goal=Fetch_Mineral target=(1,2)\n", f)
    strings.write_string(&b, `[f0000310] nav#5 goal=Fetch_Mineral from=(30,40) to=(35,40) stop=0 budget=4000 ok=false complete=false len=0 end=(30,40) nodes=4000 us=1500
[f0000320] nav#5 goal=Fetch_Mineral from=(30,40) to=(35,40) stop=0 budget=4000 ok=true complete=false len=3 end=(33,40) nodes=12 us=500
[f0000330] beat#5 lvl=0 (30.0,40.0) x=1 goal=Wander goal=Encase_Den resume=None carry=Wood pocket=2 anchor=(31,41) den=true step=0 open=3+4 hoard=6
[f0000340] beat#5 lvl=0 (30.0,40.0) goal=Encase_Den resume=None carry=Wood pocket=2 anchor=(31,41) den=true step=0 open=1+2 hoard=7
[f0000345] beat#5 lvl=0 (30.0,40.0) goal=Encase_Den resume=None carry=Wood pocket=2 anchor=(31,41) den=false step=0 open=0+0 hoard=7
[f0000350] Builder#5 mines (31,41) was=Stone goal=Encase_Den dbg_den=#5(31,41)
[f0000360] Builder#5 clears climb tile (32,41) was=Dirt goal=Hunt dbg_den=#6(1,1)
[f0000370] Builder#5 loops at (30,40)
[f0000380] Builder loops at (30,41)
[f0000390] Builder#5 strike 1 (no progress)
[f0001500] Player enters level 2
`)
    for i in 0 ..< 6 do fmt.sbprintf(&b, "[f%07d] pos Enemy#7 Builder (%d.0,60.0) hp=10 goal=Hunt target=(1,2)\n", 1800 + 300 * i, 60 if i % 2 == 0 else 66)
    run := tools_test_run("trace_more", {"action.log", strings.to_string(b)})
    defer tools_test_done(run)
    text, _ := tools_test_say("--builder-trace", run, "--min-frames", "0", "--tiles", "1")
    for want in ([]string{
        "== life 1 level 0: 1500 frames (25 s) with the player here ==",
        "    still while not idle: 15 s (100%), longest 15 s at (30.0,40.0) Fetch_Mineral ending f1200",
        "    no_progress=1 pillar_loop=2 own_den_dug=1 other_den_dug=1\n",
        "    ops: mine=1 climb=1\n",
        "    A*: 2 searches, 1 no route, 1 best-effort, 1 ran the node budget, 2 ms total",
        "    den: open slots 3+4 at f330, 1+2 at f340, lowest 3, hoard 7",
        "life 1 level 0: 100% of 1 builder-minutes: wall_dig 100% bounce 100%",
        "== life 1 level 2: 1800 frames (30 s) with the player here ==",
        "    position cycle, period 10 s, 30 s long, from f1800: (60,60) > (66,60)",
    }) {
        testing.expect(t, strings.contains(text, want), want)
    }
    testing.expect(t, !strings.contains(text, "goal cycle"), "one goal throughout is no cycle")
    testing.expect(t, !strings.contains(text, "tiles touched"), "no tile was touched three times")
    text, _ = tools_test_say("--builder-trace", run, "--min-frames", "1600")
    testing.expect(t, !strings.contains(text, "== life 1 level 0") && strings.contains(text, "== life 1 level 2"), "a level played less than --min-frames is left out")
}
