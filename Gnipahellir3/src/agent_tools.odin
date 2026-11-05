package game

// agent_tools.odin — the run tools, as options of the game binary (card 141).
//
//   gnipa --agent-run [--port P] [--seed N | --load F]
//                                             an agent run in a new folder under
//                                             build/agent_runs/, as the title's [A];
//                                             --load starts it from the save F
//   gnipa --replay <run folder>               plays a run's goals back in the window
//   gnipa --summary <run folder>              one page on a run, for finding bugs
//   gnipa --pacing <run folder>... [--csv f]  seconds to Scroll B and to 10 Gold Bars
//   gnipa --builder-trace <run folder|action.log> [--min-frames N] [--tiles N]
//   gnipa --make-save --seed N --out F        a save just past ritual A, for --load
//
// The three reports read files and print, and the game never starts: they run
// before the window opens, outside play, so they use the heap (a temp arena
// freed on return) where the game keeps to fixed arrays.  The replay and the
// agent run are play, and use the game's own link and state.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

TOOL_RUNS_DIR     :: "build/agent_runs"  // where --agent-run makes its folder
TOOL_RUN_PORT     :: 7777                // --agent-run's port when it names none
TOOL_START_SAVE   :: "start.sav"         // a --load run keeps the save it began from
TOOL_FPS          :: 60                  // the agent's fixed step: seconds are frames / 60
TOOL_GOLD_GOAL    :: 10                  // the pacing mark: Gold Bars taken in one life
TOOL_TRACE_FRAMES :: 600                 // --builder-trace skips levels played less than this
TOOL_TRACE_TILES  :: 8                   // and lists this many hot tiles per Builder

TOOL_USAGE :: `usage:
  gnipa                                  play
  gnipa --agent-run [--port P] [--seed N | --load save]
                                         an agent run in a new folder under build/agent_runs/;
                                         --load starts it from a save, as Continue does
  gnipa --replay <run folder>            play a run's goals back in the window, from its
                                         seed, or from its start.sav for a --load run, and
                                         check each goal ends where it did
  gnipa --summary <run folder>           one page on a run, aimed at finding game bugs
  gnipa --pacing <run folder>... [--csv out.csv]
                                         seconds to Scroll B and to 10 Gold Bars; a --load
                                         run is left out, its clock starts at the save
  gnipa --builder-trace <run folder|action.log> [--min-frames N] [--tiles N]
                                         what each Builder did, per life and level
  gnipa --hero-soak                      the hero's live chase: deaths per kit, of 80 runs each
  gnipa --make-save --seed N --out save  a save of seed N just past ritual A (Deep Cave open),
                                         for --agent-run --load; see agent_playtests.md
`

Tool_Mode :: enum u8 { Play, Agent_Run, Replay }

Tool_Run :: struct {
    mode:   Tool_Mode,
    port:   int,
    seed:   u32,
    seeded: bool,
    folder: string,
    load:   string,  // --agent-run --load: the save the run starts from
}

// The command line.  A report runs here and says so with exit; play, an agent
// run and a replay come back in run.
tool_args :: proc(args: []string, out: ^strings.Builder) -> (run: Tool_Run, exit: bool, code: int) {
    if len(args) == 0 do return
    usage :: proc(out: ^strings.Builder, why: string) -> (Tool_Run, bool, int) {
        fmt.sbprintf(out, "%s\n%s", why, TOOL_USAGE)
        return {}, true, 2
    }
    number :: proc(args: []string, i: int) -> (n: int, ok: bool) {
        if i + 1 >= len(args) do return
        return strconv.parse_int(args[i + 1])
    }
    switch args[0] {
    case "--help", "-h":
        strings.write_string(out, TOOL_USAGE)
        return {}, true, 0
    case "--summary":
        if len(args) != 2 do return usage(out, "--summary takes one run folder")
        return {}, true, 0 if tool_summary(out, args[1]) else 1
    case "--pacing":
        folders := make([dynamic]string, context.temp_allocator)
        csv: string
        for i := 1; i < len(args); i += 1 {
            if args[i] != "--csv" {
                append(&folders, args[i])
                continue
            }
            if i + 1 >= len(args) do return usage(out, "--csv needs a file")
            csv = args[i + 1]
            i += 1
        }
        if len(folders) == 0 do return usage(out, "--pacing takes one or more run folders")
        return {}, true, 0 if tool_pacing(out, folders[:], csv) else 1
    case "--builder-trace":
        path: string
        min_frames, tiles := TOOL_TRACE_FRAMES, TOOL_TRACE_TILES
        for i := 1; i < len(args); i += 1 {
            switch args[i] {
            case "--min-frames", "--tiles":
                n, ok := number(args, i)
                if !ok do return usage(out, fmt.tprintf("%s needs a number", args[i]))
                if args[i] == "--tiles" do tiles = n
                else do min_frames = n
                i += 1
            case:
                if path != "" do return usage(out, "--builder-trace takes one run folder or action.log")
                path = args[i]
            }
        }
        if path == "" do return usage(out, "--builder-trace takes one run folder or action.log")
        return {}, true, 0 if tool_builder_trace(out, path, min_frames, tiles) else 1
    case "--hero-soak":
        if len(args) != 1 do return usage(out, "--hero-soak takes nothing")
        tool_hero_soak(out)
        return {}, true, 0
    case "--make-save":
        seed, seeded, path := u32(0), false, ""
        for i := 1; i < len(args); i += 1 {
            n, ok := number(args, i)
            switch {
            case args[i] == "--seed" && ok:                 seed, seeded = u32(n), true
            case args[i] == "--out" && i + 1 < len(args): path = args[i + 1]
            case: return usage(out, fmt.tprintf("--make-save takes --seed N and --out file, not %q", args[i]))
            }
            i += 1
        }
        if !seeded || path == "" do return usage(out, "--make-save needs --seed N and --out file")
        return {}, true, 0 if tool_make_save(out, seed, path) else 1
    case "--replay":
        if len(args) != 2 do return usage(out, "--replay takes one run folder")
        return {mode = .Replay, folder = args[1]}, false, 0
    case "--agent-run":
        run = {mode = .Agent_Run, port = TOOL_RUN_PORT}
        for i := 1; i < len(args); i += 1 {
            n, ok := number(args, i)
            switch {
            case args[i] == "--port" && ok && n > 0 && n <= 65535: run.port = n
            case args[i] == "--seed" && ok:                         run.seed, run.seeded = u32(n), true
            case args[i] == "--load" && i + 1 < len(args):         run.load = args[i + 1]
            case: return usage(out, fmt.tprintf("--agent-run takes --port 1..65535, --seed N and --load save, not %q", args[i]))
            }
            i += 1
        }
        if run.seeded && run.load != "" do return usage(out, "--agent-run --load takes its world from the save: drop --seed")
        if run.load != "" {  // here, before the window opens
            data, err := os.read_entire_file_from_path(run.load, context.allocator)
            defer delete(data)
            if err != nil {
                fmt.sbprintfln(out, "agent run: cannot read the save %s: %v", run.load, err)
                return {}, true, 1
            }
            seed, ok := tool_save_seed(data)
            if !ok {
                fmt.sbprintfln(out, "agent run: %s is not a save this build runs", run.load)
                return {}, true, 1
            }
            run.seed = seed  // the title boots the save's own seed, so action.log names only that one
        }
        return run, false, 0
    }
    return usage(out, fmt.tprintf("unknown option %q", args[0]))
}

// ─── --agent-run ────────────────────────────────────────────────────────────

// The port, seed and folder an agent run hands the title.  A --load run's seed
// is the save's, so the title boots it and action.log names only that one.
tool_run_link :: proc(link: ^Agent_Link, run: Tool_Run) {
    link.run_port, link.run_seed, link.run_seeded, link.run_dir = run.port, run.seed, run.seeded || run.load != "", TOOL_RUNS_DIR
}

// What the title's [A] does, on a port and seed the command line names, into
// build/agent_runs/.  The binary is copied into the folder too, so the run can
// be replayed by the code that played it.
tool_agent_run :: proc(link: ^Agent_Link, gs: ^Game_State, run: Tool_Run) -> bool {
    exe, exe_err := os.get_executable_path(context.temp_allocator)
    from, _ := os.get_working_directory(context.temp_allocator)  // where the assets are
    start: []u8  // --load: read before the run moves into its folder
    if run.load != "" {
        err: os.Error
        start, err = os.read_entire_file_from_path(run.load, context.allocator)
        if err != nil {
            fmt.eprintfln("agent run: cannot read the save %s: %v", run.load, err)
            return false
        }
    }
    defer delete(start)
    tool_run_link(link, run)
    agent_title_start(link, gs)
    if !link.listening {
        fmt.eprintfln("agent run: cannot start: is port %d taken, or %s not writable?", run.port, TOOL_RUNS_DIR)
        return false
    }
    here, _ := os.get_working_directory(context.temp_allocator)
    if run.load != "" && !tool_run_load(gs, start, run.load) {
        fmt.eprintfln("agent run: %s is not a save this build runs", run.load)
        return false
    }
    if hint, kept := tool_run_keep_binary(exe, from, here); exe_err == nil && kept do fmt.println(hint)
    return true
}

// A --load run, in its folder: the save it begins from is kept there as
// TOOL_START_SAVE and loaded as the title's Continue loads one, and the run's
// own autosave and seed file start from it.  The title stays up: the agent's
// first dismiss closes it, onto the loaded world.
tool_run_load :: proc(gs: ^Game_State, data: []u8, name: string, dir := ".") -> bool {
    start := fmt.tprintf("%s/%s", dir, TOOL_START_SAVE)
    if os.write_entire_file(start, data) != nil do return false
    if !load_game_from(gs, start) do return false
    golem_sweep_orphan_quick_clay(gs)  // as main does after a load: the pool isn't saved
    camera_snap_y(gs)
    _ = os.write_entire_file(fmt.tprintf("%s/seed", dir), transmute([]u8)fmt.tprintf("%d\n", gs.world_seed))
    _ = save_game(gs)
    log_action(gs, "Run starts from the save %s: world seed %d, level %d", name, gs.world_seed, gs.level_index)
    return true
}

// The world seed a save holds, and whether this build reads it as a save.  The
// oldest saves (v23) hold none: 0, and the load says whether it runs.
tool_save_seed :: proc(data: []u8) -> (seed: u32, ok: bool) {
    if len(data) == size_of(Save_Data_v23) do return 0, true
    sd := save_data_read(data)
    if sd == nil do return 0, false
    defer free(sd)
    return sd.world_seed, true
}

// Copies the binary at exe into the run folder here, and says how to replay
// the run with it from from, where the assets are.
tool_run_keep_binary :: proc(exe, from, here: string) -> (hint: string, ok: bool) {
    copy_name := "gnipa.exe" when ODIN_OS == .Windows else "gnipa"
    if os.copy_file(fmt.tprintf("%s/%s", here, copy_name), exe) != nil do return "", false
    return fmt.tprintf("replay it with: cd %s && %s/%s --replay %s", from, here, copy_name, here), true
}

// ─── --make-save ────────────────────────────────────────────────────────────

// A save just past ritual A on a seed, for playtests that start at the Deep
// Cave (card 170).  The route a player takes, every step through the game's
// own handlers: the pickaxe off its ledge, a bench crafted and placed, two Sky
// Altars crafted, the tier-A foundation and the gate altar raised on the
// Surface (which reveals Scroll A), the scroll taken from its chest, the gate
// to the Low Sky, a second foundation and altar there, the ritual, and the
// sky's return portal home.  No progression flag is set by hand: the unlocks
// come from Place_Request, Item_Pickup, Ritual_Request and update_ritual.
// Two shortcuts, and only two: the player is set beside each station instead
// of walking there, and each step's exact materials are handed over instead
// of gathered, all of them spent by the end.  Nothing else is ticked, so no
// time passes and nothing hunts.
tool_make_save :: proc(out: ^strings.Builder, seed: u32, path: string) -> bool {
    gs := new(Game_State)
    defer free(gs)
    start_new_game_with(gs, seed)  // the title's New Game; empty paths, so nothing is written
    if why := fixture_past_ritual_a(gs, out); why != "" {
        fmt.sbprintf(out, "make-save: seed %d: %s\n", seed, why)
        return false
    }
    if !save_game_to(gs, path) {
        fmt.sbprintf(out, "make-save: cannot write %s\n", path)
        return false
    }
    fmt.sbprintf(out, "wrote %s: seed %d, ritual A done, %s open; start a run from it with --agent-run --load %s\n",
        path, seed, level_names[LEVEL_CAVE2], path)
    return true
}

// The route of tool_make_save on gs, a new game the caller started.  "" when
// it ends past ritual A with the bag as the route leaves it; else why not.
// Each step is a line in say, and a step the game refused says "refused".
fixture_past_ritual_a :: proc(gs: ^Game_State, say: ^strings.Builder) -> string {
    gs.delta_time = AGENT_STEP
    inv := &gs.player.inventory

    kit: [Item]int  // what the route leaves in the bag: the start kit, the pickaxe and Scroll A
    for sl in inv.slots do kit[sl.item] += sl.count
    pick, found := fixture_find_item(&gs.world, .Pickaxe)
    if !found do return "no pickaxe on the ledge"
    fixture_stand(gs, pick, say, "the pickaxe ledge")
    player_pickup(gs)

    x, g := fixture_site(gs, int(SURFACE_HOME_POS.x), 1)
    fixture_stand(gs, {i32(x + 5), i32(g - 2)}, say, "the Surface build site")
    fixture_grant(gs, say, .Plank, 4)
    fixture_craft(gs, say, .Crafting_Bench)
    fixture_foundation(gs, say, x, g, .Stone_Block)
    fixture_place(gs, say, .Crafting_Bench, x + 2, g - 2)
    fixture_grant(gs, say, .Stone_Block, 12)
    fixture_grant(gs, say, .Plank, 8)
    for _ in 0 ..< 2 do fixture_craft(gs, say, .Sky_Altar)
    fixture_foundation(gs, say, x, g, .Plank)
    fixture_place(gs, say, .Sky_Altar, x, g - 3)  // the gate: it reveals Scroll A

    chest, _ := fixture_find_tile(&gs.world, .Rune_Scroll_Chest_A)
    fixture_stand(gs, chest, say, "the Scroll A chest")
    rune_scroll_chest_take(gs, rune_scroll_chest_record(gs, chest, get_tile(&gs.world, int(chest.x), int(chest.y))), RUNE_SCROLL_CHEST_SLOT)

    gate := sky_gate_portal(gs)
    level_transition(gs, &gate)

    sx, sg := fixture_site(gs, int(gate.dest_pos.x), int(gate.dest_pos.y) - 4)
    fixture_foundation(gs, say, sx, sg, .Stone_Block)
    fixture_foundation(gs, say, sx, sg, .Plank)
    fixture_place(gs, say, .Sky_Altar, sx, sg - 3)

    for ing in structure_costs[0] do fixture_grant(gs, say, ing.item, ing.count)
    eq_push(&gs.events, Event{type = .Ritual_Request})
    process_events(gs)
    for i := 0; gs.ritual.active && i < 10 * TOOL_FPS; i += 1 do update_ritual(gs)
    process_events(gs)
    if !gs.progression.cave_unlocked[0] do return "ritual A did not complete: see the refused step"

    home := level_portals[LEVEL_SKY][0]
    level_transition(gs, &home)

    kit[.Pickaxe] += 1
    kit[.Rune_Scroll_A] += 1
    have: [Item]int
    for sl in inv.slots do have[sl.item] += sl.count
    for n, it in have do if it != .None && n != kit[it] {
        return fmt.tprintf("the bag ends with %d %v, the route leaves %d", n, it, kit[it])
    }
    fmt.sbprintf(say, "  ritual A done, %s open, back on the Surface\n", level_names[LEVEL_CAVE2])
    return ""
}

// The pile of it in the world: the route's pickaxe lies once.
@(private="file")
fixture_find_item :: proc(w: ^World_Grid, it: Item) -> ([2]i32, bool) {
    for i in 0 ..< GRID_W * GRID_H do if w.items[i] == it && w.item_counts[i] > 0 {
        return {i32(i % GRID_W), i32(i / GRID_W)}, true
    }
    return {}, false
}

@(private="file")
fixture_find_tile :: proc(w: ^World_Grid, t: Tile_Type) -> ([2]i32, bool) {
    for i in 0 ..< GRID_W * GRID_H do if w.terrain[i] == t do return {i32(i % GRID_W), i32(i / GRID_W)}, true
    return {}, false
}

// Shortcut one: the player is set down centred on tile, as if walked there.
@(private="file")
fixture_stand :: proc(gs: ^Game_State, tile: [2]i32, say: ^strings.Builder, what: string) {
    gs.player.pos = {f32(tile.x) + 0.5 - PLAYER_W*0.5, f32(tile.y) + 0.5 - PLAYER_H*0.5}
    fmt.sbprintf(say, "  stand at %s (%d,%d)\n", what, tile.x, tile.y)
}

// Shortcut two: a step's exact materials, as if gathered.  Holding them
// reveals their recipes, as a frame of play would.
@(private="file")
fixture_grant :: proc(gs: ^Game_State, say: ^strings.Builder, it: Item, n: int) {
    inventory_insert(&gs.player.inventory, it, n)
    update_recipe_unlocks(gs)
    fmt.sbprintf(say, "  grant %d %v\n", n, it)
}

@(private="file")
fixture_craft :: proc(gs: ^Game_State, say: ^strings.Builder, it: Item) {
    before := inventory_count(&gs.player.inventory, it)
    for r, i in recipe_table do if r.result == it {
        eq_push(&gs.events, Event{type = .Craft_Request, payload = {int_val = i32(i)}})
        process_events(gs)
        break
    }
    if inventory_count(&gs.player.inventory, it) == before do fmt.sbprintf(say, "  refused: craft %v\n", it)
}

// A Place_Request from the bag slot holding it, as a right-click with it in hand.
@(private="file")
fixture_place :: proc(gs: ^Game_State, say: ^strings.Builder, it: Item, x, y: int) {
    inv := &gs.player.inventory
    before := inventory_count(inv, it)
    for sl, i in inv.slots do if sl.item == it && sl.count > 0 { inv.selected = i; break }
    eq_push(&gs.events, Event{type = .Place_Request, tile = {i32(x), i32(y)}})
    process_events(gs)
    if inventory_count(inv, it) == before do fmt.sbprintf(say, "  refused: place %v at (%d,%d)\n", it, x, y)
}

// One course of tier A's foundation under a capstone at (x, g-3): five stone
// on the ground row g, or three planks on the stone.
@(private="file")
fixture_foundation :: proc(gs: ^Game_State, say: ^strings.Builder, x, g: int, it: Item) {
    half, row := 2, g - 1
    if it == .Plank do half, row = 1, g - 2
    fixture_grant(gs, say, it, 2 * half + 1)
    for c in x - half ..= x + half do fixture_place(gs, say, it, c, row)
}

// The column nearest x0 where five columns share a ground row g, scanning down
// from row top, with three open rows above them and no portal among them, and
// room for the player to stand 5 to the right.  {0, 0} when there is none.
fixture_site :: proc(gs: ^Game_State, x0, top: int) -> (x, g: int) {
    ground :: proc(w: ^World_Grid, c, top: int) -> int {
        for y in top ..< GRID_H do if is_solid(w, c, y) do return y
        return -1
    }
    fits :: proc(gs: ^Game_State, x, top: int) -> (g: int, ok: bool) {
        if x + 5 >= GRID_W do return  // room to stand right; off the left edge get_tile is Stone, so no ground row matches
        g = ground(&gs.world, x, top)
        for c in x - 2 ..= x + 2 {
            if ground(&gs.world, c, top) != g do return
            for y in g - 3 ..= g - 1 {
                t := get_tile(&gs.world, c, y)
                if t != .Air && t != .Void do return
                for &p in level_portals[gs.level_index] do if portal_valid(&p) && (p.tiles[0] == {i32(c), i32(y)} || p.tiles[1] == {i32(c), i32(y)}) do return
            }
        }
        return g, true
    }
    for d in 0 ..< GRID_W {
        for sx in ([2]int{x0 + d, x0 - d}) {
            if fg, ok := fits(gs, sx, top); ok do return sx, fg
        }
    }
    return
}

// ─── --replay ───────────────────────────────────────────────────────────────

// A recorded run fed back by frame.  Every row of acts.jsonl carries the frame
// it came on, and a frame counts ticks, so feeding each goal, clear and cancel
// on its frame plays the run again whether it ran in real time, waited, or idled.
// A disconnect handed the game to the keyboard, so the replay stops there.
Tool_Replay :: struct {
    rows:     string,  // the run's acts.jsonl
    at:       int,     // the next row
    got:      string,  // where the replay records, to check itself against rows
    cut:      bool,    // a disconnect ended what can be replayed
    done:     bool,
    diverged: bool,
    checked:  int,     // landings the replay compared with the run's
}

// What a replay boots from, read from the run's folder: its seed and goal rows,
// and for a --load run the save it began from.
Tool_Replay_From :: struct {
    seed:       u32,
    rows:       []u8,
    start:      []u8,    // nil unless the run began from a save
    start_path: string,
}

// Reads a run's folder for its replay, refusing a run that cannot be replayed
// before anything is made.  The caller frees start; rows stay with the replay.
tool_replay_read :: proc(run: string) -> (from: Tool_Replay_From, ok: bool) {
    seed_text, seed_err := os.read_entire_file(fmt.tprintf("%s/seed", run), context.temp_allocator)
    rows, rows_err := os.read_entire_file(fmt.tprintf("%s/%s", run, AGENT_ACTS_FILE), context.allocator)
    seed, seed_ok := strconv.parse_u64(strings.trim_space(string(seed_text)))
    if seed_err != nil || rows_err != nil || !seed_ok {
        fmt.eprintfln("replay: %s needs a seed and an %s", run, AGENT_ACTS_FILE)
        delete(rows)
        return {}, false
    }
    from = {seed = u32(seed), rows = rows, start_path = fmt.tprintf("%s/%s", run, TOOL_START_SAVE)}
    // A --load run began from a save: the replay begins from the same one.
    if os.exists(from.start_path) {
        err: os.Error
        from.start, err = os.read_entire_file(from.start_path, context.allocator)
        if err != nil {
            fmt.eprintfln("replay: cannot read %s: %v", from.start_path, err)
            delete(rows)
            return {}, false
        }
        if _, saved := tool_save_seed(from.start); !saved {
            fmt.eprintfln("replay: %s is not a save this build runs", from.start_path)
            delete(rows)
            delete(from.start)
            return {}, false
        }
    }
    return from, true
}

// Boots the replay in a new folder inside the run, from what the run's folder
// holds, as an agent run boots, with the link driving and the frame clock at 0.
tool_replay_start :: proc(rep: ^Tool_Replay, link: ^Agent_Link, gs: ^Game_State, run: string) -> bool {
    from, ok := tool_replay_read(run)  // before the replay moves into its folder
    if !ok do return false
    defer delete(from.start)
    h, m, s := time.clock(time.now())
    folder := fmt.tprintf("%s/replay-%02d%02d%02d", run, h, m, s)
    if !agent_sandbox_make(folder, from.seed) || os.set_working_directory(folder) != nil {
        fmt.eprintfln("replay: cannot make %s", folder)
        return false
    }
    fd, ferr := os.open(AGENT_ACTS_FILE, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
    if ferr != nil do return false
    link.acts_file, link.recording = fd, true
    if !tool_replay_boot(gs, from) {
        fmt.eprintfln("replay: %s is not a save this build runs", from.start_path)
        return false
    }
    tool_replay_begin(rep, link, gs, string(from.rows))
    fmt.printfln("replaying %s in %s", run, folder)
    return true
}

// A replay's world, booted as its run's was: a new game on the run's seed with
// the action log opened, then, for a run that began from a save, that save,
// kept in dir and loaded as tool_run_load loaded it.  log is off only in tests,
// which keep no action.log.
tool_replay_boot :: proc(gs: ^Game_State, from: Tool_Replay_From, save_path := SAVE_FILE, stats_path := STATS_FILE, dir := ".", log := true) -> bool {
    agent_run_reset(gs, from.seed, 0, save_path, stats_path)
    if log {
        action_log_begin_run(gs)
        action_log_release(gs)
        log_action(gs, "World seed %d", from.seed)
    }
    return from.start == nil || tool_run_load(gs, from.start, from.start_path, dir)
}

// A window closed mid-replay: the link has no socket to drop.
tool_replay_end :: proc(rep: ^Tool_Replay, link: ^Agent_Link) {
    if rep.rows == "" || rep.done do return
    link.connected = false
    if link.recording do os.close(link.acts_file)
    link.recording = false
}

tool_replay_begin :: proc(rep: ^Tool_Replay, link: ^Agent_Link, gs: ^Game_State, rows: string, got := AGENT_ACTS_FILE) {
    rep^ = {rows = rows, got = got}
    link.connected = true  // no socket: the replay never reaches agent_pump
    link.realtime  = true
}

// main's frame in a replay: the rows due, then whether the sim ticks.  Once
// the rows are out and the last goal has ended, the replay checks itself and
// holds the window.
tool_replay_frame :: proc(rep: ^Tool_Replay, link: ^Agent_Link, gs: ^Game_State) -> (tick: bool) {
    if rep.done do return false
    if !tool_replay_feed(rep, link, gs) && (rep.cut || !agent_goals_busy(&link.goals)) {
        tool_replay_finish(rep, link)
        return false
    }
    return agent_drive(link, gs)
}

// Applies every row due on this frame.  False when none are left to come.
tool_replay_feed :: proc(rep: ^Tool_Replay, link: ^Agent_Link, gs: ^Game_State) -> (more: bool) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator
    for rep.at < len(rep.rows) && !rep.cut {
        end := strings.index_byte(rep.rows[rep.at:], '\n')
        end = len(rep.rows) if end < 0 else rep.at + end
        value, err := json.parse_string(rep.rows[rep.at:end], parse_integers = true)
        rec, is_obj := value.(json.Object)
        f, _ := agent_int(rec, "f")
        if err == .None && is_obj && u64(f) > gs.frame do return true
        rep.at = end + 1
        if err != .None || !is_obj do continue
        tool_replay_row(rep, link, gs, rec)
    }
    return false
}

@(private="file")
tool_replay_row :: proc(rep: ^Tool_Replay, link: ^Agent_Link, gs: ^Game_State, rec: json.Object) {
    switch {
    case "goal" in rec:
        name, _ := rec["kind"].(json.String)
        via_name, _ := rec["via"].(json.String)
        kind, known := agent_goal_find_kind(name)
        via := Agent_Goal_Via.Goal
        for v in Agent_Goal_Via do if fmt.tprint(v) == via_name do via = v
        if !known do return
        agent_goal_add(link, gs, kind, via, agent_canonical(rec["goal"]))
    case "clear" in rec:
        why, given := rec["reason"].(json.String)
        agent_goals_clear(link, gs, why if given else "cancelled")  // a row from before clears kept their reason
    case "cancel" in rec:
        id, _ := agent_int(rec, "cancel")
        for &g in link.goals.slots[:link.goals.n] {
            if g.id == id && (g.status == .Queued || g.status == .Running) do agent_goal_cancel(link, gs, &g, "cancelled")
        }
    case "objective" in rec:
        o, _ := rec["objective"].(json.Object)
        goal, has_goal := o["goal"].(json.String)
        step, has_step := o["step"].(json.String)
        result, _ := o["result"].(json.String)
        agent_set_objective(&link.panel, goal, step, has_goal, has_step, result == "failed")
    case "say" in rec:
        text, _ := rec["say"].(json.String)
        agent_text_set(&link.panel.say, text)
    case "reflexes" in rec:
        o, _ := rec["reflexes"].(json.Object)
        off: bit_set[Hero_Reflex]
        for row, k in hero_reflexes do if on, _ := o[row.name].(json.Boolean); !on do off += {k}
        agent_reflexes_set(link, gs, off)
    case "home" in rec:
        at, _, _, marked := agent_tile(rec, "home")
        level, _ := agent_int(rec, "level")
        agent_home_set(link, gs, at, level, marked)
    case "mark" in rec:
        if mark, _ := rec["mark"].(json.String); mark == "disconnect" do rep.cut = true
    }
}

// Checks the replay's own landings against the run's, and says how it went.
@(private="file")
tool_replay_finish :: proc(rep: ^Tool_Replay, link: ^Agent_Link) {
    rep.done = true
    link.connected = false
    if link.recording {
        os.close(link.acts_file)
        link.recording = false
    }
    got, _ := os.read_entire_file(rep.got, context.temp_allocator)
    n, ok, note := tool_replay_compare(rep.rows[:min(rep.at, len(rep.rows))], string(got))
    rep.diverged = !ok
    rep.checked  = n
    fmt.println(tool_replay_verdict(n, ok, note))
    if rep.cut && rep.at < len(rep.rows) do fmt.println("stopped at a disconnect: the keyboard had the game after it, so the rest cannot be replayed")
    fmt.println("close the game window when done watching")
}

// What a replay says of itself.  One that checked nothing has not shown the run
// repeats, so it warns rather than passing.
tool_replay_verdict :: proc(n: int, ok: bool, note: string) -> string {
    if !ok do return note
    if n == 0 do return "WARNING: 0 landings checked: the run has no goal ends or acts to compare, so this replay shows nothing"
    return fmt.tprintf("%d landings replayed, each where it landed before", n)
}

// The landing rows of a recording and of its replay, in order: each goal's end
// (done or failed, with its reason) and each finished act, with where it left
// the player.  False, with the first difference, when they part.  A goal end
// recorded before its landing was written is checked by frame and outcome.
tool_replay_compare :: proc(want, got: string) -> (matched: int, ok: bool, note: string) {
    Landing :: struct { f, goal: int, failed, placed: bool, reason: string, x, y: f64, hp, lvl: int, mana: f64 }
    landings :: proc(rows: string) -> [dynamic]Landing {
        out := make([dynamic]Landing, context.temp_allocator)
        for line in strings.split_lines(rows, context.temp_allocator) {
            value, err := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
            rec, is_obj := value.(json.Object)
            if err != .None || !is_obj do continue
            l: Landing
            switch {
            case "act" in rec:
                l.lvl, _  = agent_int(rec, "lvl")
                l.mana    = tool_json_f64(rec["mana"])
            case "done" in rec:
                l.goal, _ = agent_int(rec, "done")
            case "failed" in rec:
                l.goal, _ = agent_int(rec, "failed")
                l.failed  = true
                l.reason, _ = rec["reason"].(json.String)
            case:
                continue
            }
            l.f, _    = agent_int(rec, "f")
            l.placed  = "x" in rec
            l.hp, _   = agent_int(rec, "hp")
            l.x       = tool_json_f64(rec["x"])
            l.y       = tool_json_f64(rec["y"])
            append(&out, l)
        }
        return out
    }
    w, g := landings(want), landings(got)
    for a, i in w {
        if i >= len(g) do return i, false, fmt.tprintf("the replay reached %d of %d landings", i, len(w))
        b := g[i]
        same := a.f == b.f && a.goal == b.goal && a.failed == b.failed && a.reason == b.reason && a.lvl == b.lvl && abs(a.mana - b.mana) <= 0.1
        if a.placed do same = same && abs(a.x - b.x) <= 0.01 && abs(a.y - b.y) <= 0.01 && a.hp == b.hp
        if same do continue
        if a.goal != 0 {
            return i, false, fmt.tprintf("DIVERGED at goal %d, frame %d: recorded %v, replayed %v", a.goal, a.f, a, b)
        }
        return i, false, fmt.tprintf("DIVERGED after %d landings, at an act on frame %d: recorded %v, replayed %v", i, a.f, a, b)
    }
    return len(w), true, ""
}

tool_json_f64 :: proc(v: json.Value) -> f64 {
    #partial switch n in v {
    case json.Float:   return f64(n)
    case json.Integer: return f64(n)
    }
    return 0
}

// ─── Reading logs ───────────────────────────────────────────────────────────

// What a capture pattern caught.
Tool_Caps :: struct {
    v: [16]string,
    n: int,
}

// Matches pat at the start of s.  pat is literal text with these captures:
// {d} digits, {n} digits with an optional minus, {w} a word, {f} digits and
// dots, {o} an optional # then digits that may be none.
tool_pat_at :: proc(s, pat: string, caps: ^Tool_Caps) -> (end: int, ok: bool) {
    i, j := 0, 0
    for j < len(pat) {
        if pat[j] == '{' && j + 2 < len(pat) && pat[j + 2] == '}' {
            kind := pat[j + 1]
            j += 3
            if kind == 'o' && i < len(s) && s[i] == '#' do i += 1
            from := i
            if kind == 'n' && i < len(s) && s[i] == '-' do i += 1
            start := i
            for i < len(s) {
                c := s[i]
                digit := c >= '0' && c <= '9'
                word  := digit || c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                if !(word if kind == 'w' else digit || (kind == 'f' && c == '.')) do break
                i += 1
            }
            if i == start && kind != 'o' do return 0, false
            if caps.n < len(caps.v) {
                caps.v[caps.n] = s[from:i]
                caps.n += 1
            }
            continue
        }
        if i >= len(s) || s[i] != pat[j] do return 0, false
        i += 1
        j += 1
    }
    return i, true
}

// The first place in s that pat matches, or with last the final one.  end is
// where the match stops in s.
tool_find :: proc(s, pat: string, last := false) -> (caps: Tool_Caps, end: int, ok: bool) {
    head := pat
    if k := strings.index_byte(pat, '{'); k >= 0 do head = pat[:k]
    from := 0
    for from <= len(s) {
        k := strings.index(s[from:], head)
        if k < 0 do break
        at := from + k
        c: Tool_Caps
        if e, matched := tool_pat_at(s[at:], pat, &c); matched {
            caps, end, ok = c, at + e, true
            if !last do return
        }
        from = at + 1
    }
    return
}

tool_int :: proc(s: string) -> int {
    n, _ := strconv.parse_int(s)
    return n
}

tool_f64 :: proc(s: string) -> f64 {
    n, _ := strconv.parse_f64(s)
    return n
}

// `[f0000123] body`: the frame and the body, for a line the game logged.
tool_log_line :: proc(line: string) -> (frame: int, body: string, ok: bool) {
    caps: Tool_Caps
    end := tool_pat_at(line, "[f{d}] ", &caps) or_return
    return tool_int(caps.v[0]), line[end:], true
}

// What follows the first "] " of a line, as the reports quote it.
tool_after_frame :: proc(line: string) -> string {
    k := strings.index(line, "] ")
    return line[k + 2:] if k >= 0 else line
}

// A run folder's file, or the file itself when it is one.
tool_run_file :: proc(path, name: string) -> string {
    return fmt.tprintf("%s/%s", path, name) if os.is_dir(path) else path
}

// How often each key came, in the order keys first came.
Tool_Tally :: struct($K: typeid) {
    keys: [dynamic]K,
    n:    map[K]int,
}

tool_tally :: proc(t: ^Tool_Tally($K), k: K, by := 1) {
    if k not_in t.n do append(&t.keys, k)
    t.n[k] += by
}

// The keys, most counted first; a tie keeps first-come order.
tool_tally_top :: proc(t: ^Tool_Tally($K)) -> []K {
    out := make([]K, len(t.keys))
    copy(out, t.keys[:])
    for i in 1 ..< len(out) {
        for j := i; j > 0 && t.n[out[j]] > t.n[out[j - 1]]; j -= 1 do out[j], out[j - 1] = out[j - 1], out[j]
    }
    return out
}

tool_tally_line :: proc(b: ^strings.Builder, t: ^Tool_Tally(string)) {
    if len(t.keys) == 0 {
        strings.write_string(b, "none")
        return
    }
    for k, i in tool_tally_top(t) {
        if i > 0 do strings.write_string(b, ", ")
        fmt.sbprintf(b, "%s %d", k, t.n[k])
    }
}

tool_median :: proc(values: []f64) -> f64 {
    s := make([]f64, len(values), context.temp_allocator)
    copy(s, values)
    for i in 1 ..< len(s) {
        for j := i; j > 0 && s[j] < s[j - 1]; j -= 1 do s[j], s[j - 1] = s[j - 1], s[j]
    }
    n := len(s)
    return s[n / 2] if n % 2 == 1 else (s[n / 2 - 1] + s[n / 2]) / 2
}

// ─── --summary ──────────────────────────────────────────────────────────────

// One page on a run, aimed at finding game bugs: lives, milestones, bug flags,
// and from acts.jsonl the acts and how the goal queue kept the hero busy.
tool_summary :: proc(b: ^strings.Builder, run: string) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator
    data, err := os.read_entire_file(fmt.tprintf("%s/action.log", run), context.allocator)
    if err != nil {
        fmt.sbprintfln(b, "cannot read %s/action.log: %v", run, err)
        return false
    }
    log := strings.split_lines(string(data))

    strings.write_string(b, "== lives ==\n")
    life, last_hurt := 1, ""
    deaths: Tool_Tally(string)
    for line in log {
        if _, end, ok := tool_find(line, "Player takes {d} damage from "); ok {
            if k := strings.index(line[end:], " (hp"); k > 0 do last_hurt = line[end:end + k]
        }
        if strings.contains(line, "Player dies") {
            cause := tool_strip_slots(last_hurt if last_hurt != "" else "unknown")
            tool_tally(&deaths, cause)
            fmt.sbprintfln(b, "life %d: %s - last hurt by %s", life, tool_after_frame(line), cause)
            life += 1
        }
        if strings.contains(line, "New game") do fmt.sbprintfln(b, "  %s", tool_after_frame(line))
    }
    strings.write_string(b, "deaths by cause: ")
    tool_tally_line(b, &deaths)

    strings.write_string(b, "\n\n== milestones ==\n")
    for line in log {
        if strings.contains(line, " pos ") || strings.contains(line, " evt ") do continue
        if tool_milestone(line) do fmt.sbprintln(b, line[:min(len(line), 100)])
    }

    strings.write_string(b, "\n== bug flags ==\n")
    tool_summary_stuck(b, log)
    churn: Tool_Tally([2]int)
    for line in log {
        caps, _, ok := tool_find(line, "Builder{o} mines ({d},{d})")
        if !ok do caps, _, ok = tool_find(line, "Builder{o} places at ({d},{d})")
        if ok do tool_tally(&churn, [2]int{tool_int(caps.v[1]), tool_int(caps.v[2])})
    }
    for tile, i in tool_tally_top(&churn) {
        if i < 5 && churn.n[tile] >= 8 do fmt.sbprintfln(b, "churn: tile (%d,%d) mined or placed %d times by builders", tile.x, tile.y, churn.n[tile])
    }
    for key in ([]string{"no path", "gives up", "WARNING"}) {
        n := 0
        for line in log do if strings.contains(line, key) do n += 1
        if n > 0 do fmt.sbprintfln(b, "%s: %d lines", key, n)
    }

    if acts, acts_err := os.read_entire_file(fmt.tprintf("%s/%s", run, AGENT_ACTS_FILE), context.allocator); acts_err == nil {
        rows := make([dynamic]json.Object)
        for line in strings.split_lines(string(acts)) {
            value, perr := json.parse_string(line, parse_integers = true)
            if rec, is_obj := value.(json.Object); perr == .None && is_obj do append(&rows, rec)
        }
        tool_summary_acts(b, rows[:])
        tool_summary_goals(b, rows[:])
    }

    if fights, fight_err := os.read_entire_file(fmt.tprintf("%s/%s", run, AGENT_FIGHT_FILE), context.allocator); fight_err == nil {
        strings.write_string(b, "\n== fights ==\n")
        kinds: Tool_Tally(string)
        near: map[string]bool
        for line in strings.split_lines(string(fights)) {
            row := strings.split(line, ",")
            if len(row) > 3 && row[1] != "P" {
                tool_tally(&kinds, row[2])
                near[row[0]] = true
            }
        }
        fmt.sbprintf(b, "%d frames with enemies near; enemy-frames by kind: ", len(near))
        tool_tally_line(b, &kinds)
        strings.write_byte(b, '\n')
    }
    return true
}

// A name without its slot numbers: "Vargr#2" is a Vargr.
@(private="file")
tool_strip_slots :: proc(s: string) -> string {
    out := strings.builder_make()
    for i := 0; i < len(s); i += 1 {
        if s[i] == '#' && i + 1 < len(s) && s[i + 1] >= '0' && s[i + 1] <= '9' {
            for i + 1 < len(s) && s[i + 1] >= '0' && s[i + 1] <= '9' do i += 1
            continue
        }
        strings.write_byte(&out, s[i])
    }
    return strings.to_string(out)
}

@(private="file")
tool_milestone :: proc(line: string) -> bool {
    if strings.contains(line, "Player enters level") || strings.contains(line, "Garm") do return true
    for craft in ([]string{"Sky_Altar", "Fire_Wand", "Smelter"}) {
        if strings.contains(line, fmt.tprintf("Player crafts %s", craft)) do return true
    }
    for from := 0; from < len(line); {
        k := strings.index(line[from:], "Rune Scroll ")
        if k < 0 do break
        at := from + k + len("Rune Scroll ") + 1  // any one character, then " from"
        if at <= len(line) && strings.has_prefix(line[at:], " from") do return true
        from += k + 1
    }
    return false
}

// A body parked on the 5 s breadcrumbs.
@(private="file")
tool_summary_stuck :: proc(b: ^strings.Builder, log: []string) {
    Crumb :: struct { f: int, x, y: string }
    order := make([dynamic]string)
    tracks: map[string][dynamic]Crumb
    for line in log {
        frame, body, ok := tool_log_line(line)
        if !ok || !strings.has_prefix(body, "pos ") do continue
        rest := body[4:]
        who: string
        caps: Tool_Caps
        switch {
        case strings.has_prefix(rest, "Player"):
            who = "Player"
        case strings.has_prefix(rest, "Enemy#"):
            end, slot := tool_pat_at(rest, "Enemy#{d}", &caps)
            if !slot do continue
            who = rest[:end]
        case:
            continue
        }
        rest = rest[len(who):]
        kind, x, y: string
        caps = {}
        if _, has_kind := tool_pat_at(rest, " {w} ({f},{f})", &caps); has_kind {
            kind, x, y = caps.v[0], caps.v[1], caps.v[2]
        } else {
            caps = {}
            if _, plain := tool_pat_at(rest, " ({f},{f})", &caps); !plain do continue
            x, y = caps.v[0], caps.v[1]
        }
        key := fmt.tprintf("%s %s", who, kind) if kind != "" else who
        if key not_in tracks {
            append(&order, key)
            tracks[key] = make([dynamic]Crumb)
        }
        track := &tracks[key]
        append(track, Crumb{frame, x, y})
    }
    for key in order {
        t := tracks[key]
        run, best := 0, 0
        at: Crumb
        for i in 1 ..< len(t) {
            a, c := t[i - 1], t[i]
            run = run + 1 if a.x == c.x && a.y == c.y && c.f > a.f else 0
            if run > best do best, at = run, c
        }
        if best >= 6 do fmt.sbprintfln(b, "stuck: %s parked %d s at (%s,%s), ending frame %d", key, best * 5, at.x, at.y, at.f)
    }
}

// The objectives the agent named, the acts and the ones that changed nothing.
@(private="file")
tool_summary_acts :: proc(b: ^strings.Builder, rows: []json.Object) {
    strings.write_string(b, "\n== acts ==\n")
    frame :: proc(rec: json.Object) -> int {
        f, _ := agent_int(rec, "f")
        return f
    }
    objective_goal :: proc(rec: json.Object) -> string {
        o, _ := rec["objective"].(json.Object)
        goal, _ := o["goal"].(json.String)
        return goal
    }
    goals := make([dynamic]json.Object)
    for rec in rows {
        goal := objective_goal(rec)
        if goal != "" && (len(goals) == 0 || objective_goal(goals[len(goals) - 1]) != goal) do append(&goals, rec)
    }
    if len(goals) > 0 do strings.write_string(b, "objectives:\n")
    for a, i in goals {
        end := frame(rows[len(rows) - 1])
        note := ""
        if i + 1 < len(goals) {
            next := goals[i + 1]
            end = frame(next)
            o, _ := next["objective"].(json.Object)
            if result, _ := o["result"].(json.String); result == "failed" do note = " (failed)"
        }
        fmt.sbprintfln(b, "  f%d: %s - %d s%s", frame(a), objective_goal(a), (end - frame(a)) / 60, note)
    }
    played := make([dynamic]json.Object)
    for rec in rows do if "act" in rec do append(&played, rec)
    fmt.sbprintfln(b, "%d acts, last frame %d", len(played), frame(rows[len(rows) - 1]) if len(rows) > 0 else 0)
    wasted: Tool_Tally(string)
    for i in 1 ..< len(played) {
        a, c := played[i - 1], played[i]
        same := tool_json_f64(a["x"]) == tool_json_f64(c["x"]) && tool_json_f64(a["y"]) == tool_json_f64(c["y"]) && tool_json_f64(a["hp"]) == tool_json_f64(c["hp"])
        act, _ := c["act"].(json.Object)
        for verb in ([]string{"mine", "place", "use", "reclaim", "craft", "feed"}) {
            if verb not_in act do continue
            if same do tool_tally(&wasted, verb)
            break
        }
    }
    strings.write_string(b, "acts with no visible effect on the player, by verb: ")
    tool_tally_line(b, &wasted)
    strings.write_byte(b, '\n')
    for rec in rows {
        if mark, is_text := rec["mark"].(json.String); is_text do fmt.sbprintfln(b, "frame %d: %s", frame(rec), mark)
    }
}

// How the goal queue kept the hero busy (Glenn, 2026-11-03: play should look
// seamless).  Counted over the connected stretches: from the first row, and
// from the first row after each disconnect, to the next disconnect or the last.
tool_summary_goals :: proc(b: ^strings.Builder, rows: []json.Object) {
    Stats :: struct {
        goals, done, failed:        int,
        active, empty, longest:     int,   // frames
        longest_at:                 int,
        window:                     int,   // frames with a window open
        open:                       map[int]bool,
        empty_from, window_from:    int,
        window_open, connected:     bool,
        seg_from:                   int,
        ends, gaps:                 [dynamic]f64,
        reasons:                    Tool_Tally(string),
    }
    s: Stats
    any_goal := false
    for rec in rows do if "goal" in rec do any_goal = true
    if !any_goal do return

    close_stretches :: proc(s: ^Stats, f: int) {
        if len(s.open) == 0 {
            d := f - s.empty_from
            s.empty += d
            if d > s.longest do s.longest, s.longest_at = d, s.empty_from
        }
        if s.window_open do s.window += f - s.window_from
        s.active += f - s.seg_from
    }
    first, _ := agent_int(rows[0], "f")
    s.connected, s.seg_from, s.empty_from = true, first, first
    last := first
    for rec in rows {
        f, _ := agent_int(rec, "f")
        last = f
        if !s.connected {
            s.connected, s.seg_from, s.empty_from = true, f, f
        }
        switch {
        case "goal" in rec:
            id, _ := agent_int(rec, "id")
            if len(s.open) == 0 {
                d := f - s.empty_from
                s.empty += d
                if d > s.longest do s.longest, s.longest_at = d, s.empty_from
            }
            s.open[id] = true
            s.goals += 1
            for e in s.ends do append(&s.gaps, f64(f) - e)
            clear(&s.ends)
        case "done" in rec, "failed" in rec:
            failed := "failed" in rec
            id, _ := agent_int(rec, "failed" if failed else "done")
            if id in s.open {
                delete_key(&s.open, id)
                if len(s.open) == 0 do s.empty_from = f
            }
            append(&s.ends, f64(f))
            if failed {
                s.failed += 1
                reason, _ := rec["reason"].(json.String)
                tool_tally(&s.reasons, reason)
            } else {
                s.done += 1
            }
        case "window" in rec:
            on, _ := rec["window"].(json.Boolean)
            if on && !s.window_open do s.window_from = f
            if !on && s.window_open do s.window += f - s.window_from
            s.window_open = bool(on)
        case "mark" in rec:
            if mark, _ := rec["mark"].(json.String); mark != "disconnect" do break
            close_stretches(&s, f)
            s.connected, s.window_open = false, false
            clear(&s.open)
            clear(&s.ends)
        }
    }
    if s.connected do close_stretches(&s, last)

    seconds :: proc(frames: int) -> f64 { return f64(frames) / TOOL_FPS }
    minutes := f64(s.active) / (TOOL_FPS * 60)
    strings.write_string(b, "\n== goals ==\n")
    fmt.sbprintfln(b, "%d goals in %.1f min connected, %.1f per minute", s.goals, minutes, f64(s.goals) / minutes if minutes > 0 else 0)
    fmt.sbprintfln(b, "empty queue: %.0f s, longest %.0f s from frame %d", seconds(s.empty), seconds(s.longest), s.longest_at)
    if len(s.gaps) > 0 {
        top := 0.0
        for g in s.gaps do top = max(top, g)
        fmt.sbprintfln(b, "next goal after one ends: median %.1f s, max %.1f s, over %d ends", tool_median(s.gaps[:]) / TOOL_FPS, top / TOOL_FPS, len(s.gaps))
    } else {
        strings.write_string(b, "next goal after one ends: no goal came after an end\n")
    }
    ended := s.done + s.failed
    fmt.sbprintf(b, "ended: %d done, %d failed (%d%%)", s.done, s.failed, 100 * s.failed / max(1, ended))
    for reason, i in tool_tally_top(&s.reasons) {
        fmt.sbprintf(b, "%s%s %d%%", ": " if i == 0 else ", ", reason, 100 * s.reasons.n[reason] / max(1, ended))
    }
    fmt.sbprintfln(b, "\nwindow open: %.0f s", seconds(s.window))
}

// ─── --pacing ───────────────────────────────────────────────────────────────

// One life's marks, from action.log.  A mark not reached is negative.
Tool_Life :: struct {
    seed:      u32,
    seeded:    bool,
    scroll_b:  f64,   // seconds to the first Rune Scroll B
    gold_10:   f64,   // seconds to the tenth Gold Bar
    lasted:    f64,
    died:      bool,
    bars:      int,
    before:    f64,   // seconds of the lives lost before this one
}

tool_pacing_parse :: proc(lines: []string) -> [dynamic]Tool_Life {
    lives := make([dynamic]Tool_Life)
    append(&lives, Tool_Life{scroll_b = -1, gold_10 = -1})
    for line in lines {
        frame, text, ok := tool_log_line(line)
        if !ok do continue
        seconds := f64(frame) / TOOL_FPS
        if strings.has_prefix(text, "New game") {
            append(&lives, Tool_Life{scroll_b = -1, gold_10 = -1})
        }
        life := &lives[len(lives) - 1]
        if !strings.has_prefix(text, "New game") do life.lasted = max(life.lasted, seconds)
        caps, _, found := tool_find(text, "World seed {d}")
        if !found do caps, _, found = tool_find(text, "world seed {d}")
        if found {
            n, _ := strconv.parse_u64(caps.v[0])
            life.seed, life.seeded = u32(n), true
        }
        if strings.has_prefix(text, "Player takes Rune Scroll B from") && life.scroll_b < 0 do life.scroll_b = seconds
        if caps, _, found := tool_find(text, "Player takes Gold_Bar x{d} from smelter"); found {
            life.bars += tool_int(caps.v[0])
            if life.bars >= TOOL_GOLD_GOAL && life.gold_10 < 0 do life.gold_10 = seconds
        }
        if strings.has_prefix(text, "Player dies") do life.died = true
    }
    before := 0.0
    for &life in lives {
        life.before = before
        before += life.lasted
    }
    return lives
}

// A run's mark: the first life that reached it, as seconds and as seconds with
// the lives lost before it.
tool_pacing_first :: proc(lives: []Tool_Life, gold: bool) -> (s, with_deaths: f64, ok: bool) {
    for l in lives {
        v := l.gold_10 if gold else l.scroll_b
        if v >= 0 do return v, l.before + v, true
    }
    return
}

tool_pacing :: proc(b: ^strings.Builder, folders: []string, csv_path := "") -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator
    FIELDS :: [8]string{"run", "life", "seed", "scroll_b_s", "gold_10_s", "lasted_s", "died", "before_s"}
    secs :: proc(v: f64) -> string { return "-" if v < 0 else fmt.tprintf("%.0f", v) }
    runs := make([dynamic][dynamic]Tool_Life)
    names := make([dynamic]string)
    for folder in folders {
        // A --load run's clock starts at the save, minutes into the game: its
        // seconds are not a new game's, so it is left out, saying so.
        if os.exists(fmt.tprintf("%s/%s", folder, TOOL_START_SAVE)) {
            fmt.sbprintfln(b, "%s began from a save (--agent-run --load): its seconds count from the save, not from a new game, so it is left out", folder)
            continue
        }
        data, err := os.read_entire_file(fmt.tprintf("%s/action.log", folder), context.allocator)
        if err != nil {
            fmt.sbprintfln(b, "cannot read %s/action.log: %v", folder, err)
            return false
        }
        append(&runs, tool_pacing_parse(strings.split_lines(string(data))))
        trimmed := strings.trim_right(folder, "/\\")
        cut := max(strings.last_index_byte(trimmed, '/'), strings.last_index_byte(trimmed, '\\'))
        append(&names, trimmed[cut + 1:])
    }
    if len(runs) == 0 {
        strings.write_string(b, "no run left to pace\n")
        return false
    }
    for h, i in FIELDS do fmt.sbprintf(b, "%s%12s", " " if i > 0 else "", h)
    strings.write_byte(b, '\n')
    csv := strings.builder_make()
    for h, i in FIELDS do fmt.sbprintf(&csv, "%s%s", "," if i > 0 else "", h)
    strings.write_string(&csv, "\r\n")
    csv_secs :: proc(v: f64) -> string {
        if v < 0 do return ""
        return fmt.tprintf("%.1f", v) if v == math.floor(v) else fmt.tprintf("%v", v)
    }
    for lives, r in runs {
        for l, i in lives {
            seed := fmt.tprintf("%d", l.seed) if l.seeded else "-"
            fmt.sbprintfln(b, "%12s %12d %12s %12s %12s %12s %12s %12s", names[r], i + 1, seed, secs(l.scroll_b), secs(l.gold_10), secs(l.lasted), "True" if l.died else "False", secs(l.before))
            fmt.sbprintf(&csv, "%s,%d,%s,%s,%s,%s,%s,%s\r\n", names[r], i + 1, seed if l.seeded else "", csv_secs(l.scroll_b), csv_secs(l.gold_10),
                csv_secs(l.lasted), "True" if l.died else "False", csv_secs(l.before))
        }
    }
    for gold in ([]bool{false, true}) {
        got, with := make([dynamic]f64), make([dynamic]f64)
        for lives in runs {
            if s, w, ok := tool_pacing_first(lives[:], gold); ok {
                append(&got, s)
                append(&with, w)
            }
        }
        median := secs(tool_median(got[:])) if len(got) > 0 else "-"
        with_median := secs(tool_median(with[:])) if len(with) > 0 else "-"
        fmt.sbprintfln(b, "%s: reached %d of %d, median %s s, with lost lives %s s", "gold_10_s" if gold else "scroll_b_s", len(got), len(runs), median, with_median)
    }
    if csv_path != "" {
        if err := os.write_entire_file(csv_path, strings.to_string(csv)); err != nil {
            fmt.sbprintfln(b, "cannot write %s: %v", csv_path, err)
            return false
        }
    }
    return true
}

// ─── --builder-trace ────────────────────────────────────────────────────────
//
// What each Builder did, per life and level: goal time shares from the 5 s
// breadcrumbs, tiles touched again and again, place-then-mine pairs, cycles of
// goal and position, time still while not idle, strikes, give-ups, dens and
// hoards.  Old logs name no Builder on `mines`, `places` and `clears climb`
// lines, so those go to the nearest Builder on the breadcrumbs and are marked ~,
// Vargr and Raider digs included.  From card 120 on a log names kind and slot
// (`Builder#3 mines`, `Vargr#7 mines`): a Builder's line goes to that Builder and
// any other kind's is left out.  A world only ticks while the player is on its
// level, so a level's clock is frames with the player there; a new life is a
// new world, and its frames start again.

Trace_Crumb :: struct { f: int, x, y: f64, goal: string, tx, ty: int }
Trace_Op    :: struct { f: int, kind: string, x, y: int, guessed: bool }
Trace_Nav   :: struct { f: int, ok, complete: bool, nodes, us: int }
Trace_Beat  :: struct { f: int, goal: string, open_wall, open_shell, hoard: int, den: bool }
Trace_Sign  :: struct { f: int, name: string }

Trace_Bot :: struct {
    track:   [dynamic]Trace_Crumb,
    ops:     [dynamic]Trace_Op,
    count:   map[string]int,
    anchors: [dynamic][3]int,  // frame, x, y of each den started
    nav:     [dynamic]Trace_Nav,
    beats:   [dynamic]Trace_Beat,
    signs:   [dynamic]Trace_Sign,  // which loop a line belongs to
}

// One life and level: its Builders by slot, in the order they first showed.
Trace_World :: struct {
    bots:    map[int]^Trace_Bot,
    order:   [dynamic]int,
    orphans: [dynamic]Trace_Op,  // digs no Builder was named on
}

Trace :: struct {
    worlds: map[[2]int]^Trace_World,  // life, level
    clock:  map[[2]int]int,           // frames with the player there
}

// A line that puts down or takes up a tile.  The last two captures are the tile,
// the first the slot, empty on an old line that names none.
@(rodata)
TRACE_EVENTS := [?]struct { kind, pat: string }{
    {"harvest", "Builder#{d} harvests {w} at ({d},{d})"},
    {"encase",  "Builder#{d} encases den with {w} at ({d},{d})"},
    {"build",   "Builder#{d} builds {w} at ({d},{d})"},
    {"carve",   "Builder#{d} carves ({d},{d})"},
    {"mine",    "Builder{o} mines ({d},{d})"},
    {"climb",   "Builder{o} clears climb tile ({d},{d})"},
    {"place",   "Builder{o} places at ({d},{d})"},
}

// A line to count, and the loop it is a sign of, by the Builder's goal.
@(rodata)
TRACE_COUNTERS := [?]struct { name, pat: string }{
    {"no_path",     "Builder#{d} strike {d} (no path)"},
    {"no_progress", "Builder#{d} strike {d} (no progress)"},
    {"cant_place",  "Builder#{d} strike {d} (can't place)"},
    {"cant_build",  "Builder#{d} strike {d} (can't build)"},
    {"give_up",     "Builder#{d} gives up on"},
    {"cant_home",   "Builder#{d} can't get home"},
    {"abandon",     "Builder#{d} abandons den site"},
    {"den_start",   "Builder#{d} starts den at"},
    {"den_done",    "Builder#{d} den complete"},
    {"hoard",       "Builder#{d} stockpiles"},
    {"escape",      "Builder#{d} escape ends"},
    {"hunt",        "Builder#{d} spots the player"},
    {"hunt",        "Builder#{d} den breached"},
    {"dig_free",    "Builder#{d} digs itself free"},
}

TRACE_COUNT_KEYS :: [?]string{"den_start", "den_done", "abandon", "hoard", "no_path", "no_progress", "cant_place",
    "cant_build", "give_up", "cant_home", "pillar_loop", "escape", "dig_free", "hunt", "own_den_dug", "other_den_dug"}

@(private="file")
trace_world :: proc(tr: ^Trace, key: [2]int) -> ^Trace_World {
    if w, ok := tr.worlds[key]; ok do return w
    w := new(Trace_World)
    tr.worlds[key] = w
    return w
}

@(private="file")
trace_bot :: proc(w: ^Trace_World, id: int) -> ^Trace_Bot {
    if b, ok := w.bots[id]; ok do return b
    b := new(Trace_Bot)
    w.bots[id] = b
    append(&w.order, id)
    return b
}

// Which loop a strike line is a sign of.
@(private="file")
trace_loop_sign :: proc(name, goal: string) -> string {
    switch name {
    case "no_path":     return "home_lockout" if goal == "Encase_Den" else "carousel"
    case "give_up":     return "carousel"
    case "cant_home":   return "home_lockout"
    case "no_progress": return "bounce"
    case "cant_place":  return "slot_pinned"
    }
    return ""
}

trace_parse :: proc(lines: []string) -> (tr: Trace) {
    life, level, entered, frame := 1, 0, 0, 0
    for line in lines {
        f, body, ok := tool_log_line(line)
        if !ok do continue
        frame = f
        if strings.has_prefix(body, "New game") {
            tr.clock[{life, level}] += max(0, trace_last_frame(&tr, life) - entered)
            life, level, entered = life + 1, 0, 0
            continue
        }
        caps: Tool_Caps
        if _, entering := tool_pat_at(body, "Player enters level {d}", &caps); entering {
            tr.clock[{life, level}] += frame - entered
            level, entered = tool_int(caps.v[0]), frame
            continue
        }
        w := trace_world(&tr, {life, level})
        if c, _, nav := tool_find(body, "nav#{d} goal={w} from=({d},{d}) to=({d},{d}) stop={d} budget={d} ok={w} complete={w} len={d} end=({d},{d}) nodes={d} us={d}"); nav {
            append(&trace_bot(w, tool_int(c.v[0])).nav, Trace_Nav{frame, c.v[8] == "true", c.v[9] == "true", tool_int(c.v[13]), tool_int(c.v[14])})
            continue
        }
        if c, end, beat := tool_find(body, "beat#{d} lvl={d} ({f},{f}) "); beat {
            if t, _, tail := tool_find(body[end:], "goal={w} resume={w} carry={w} pocket={d} anchor=({d},{d}) den={w} step={d} open={d}+{d} hoard={d}", last = true); tail {
                append(&trace_bot(w, tool_int(c.v[0])).beats, Trace_Beat{frame, t.v[0], tool_int(t.v[8]), tool_int(t.v[9]), tool_int(t.v[10]), t.v[6] == "true"})
                continue
            }
        }
        trace_own_den(w, body, frame)
        if c, _, crumb := tool_find(body, "pos Enemy#{d} Builder ({f},{f}) hp={d} goal={w} target=({n},{n})"); crumb {
            append(&trace_bot(w, tool_int(c.v[0])).track, Trace_Crumb{frame, tool_f64(c.v[1]), tool_f64(c.v[2]), c.v[4], tool_int(c.v[5]), tool_int(c.v[6])})
            continue
        }
        if trace_event(w, body, frame) do continue
        for row in TRACE_COUNTERS {
            c, _ := tool_find(body, row.pat) or_continue
            bot := trace_bot(w, tool_int(c.v[0]))
            bot.count[row.name] += 1
            goal := bot.beats[len(bot.beats) - 1].goal if len(bot.beats) > 0 else bot.track[len(bot.track) - 1].goal if len(bot.track) > 0 else ""
            if sign := trace_loop_sign(row.name, goal); sign != "" do append(&bot.signs, Trace_Sign{frame, sign})
            if row.name == "den_start" {
                if a, _, at := tool_find(body, "at ({d},{d})"); at do append(&bot.anchors, [3]int{frame, tool_int(a.v[0]), tool_int(a.v[1])})
            }
            break
        }
        if c, _, loop := tool_find(body, "Builder{o} loops at ({d},{d})"); loop {
            if c.v[0] != "" {
                bot := trace_bot(w, tool_int(c.v[0]))
                bot.count["pillar_loop"] += 1
                append(&bot.signs, Trace_Sign{frame, "bounce"})
            } else {
                append(&w.orphans, Trace_Op{frame, "loop", tool_int(c.v[1]), tool_int(c.v[2]), true})
            }
        }
    }
    tr.clock[{life, level}] += frame - entered
    for _, w in tr.worlds do trace_attribute(w)
    return
}

// A Builder digging a den wall: its own, or another's.
@(private="file")
trace_own_den :: proc(w: ^Trace_World, body: string, frame: int) {
    c, end, ok := tool_find(body, "Builder#{d} mines ({d},{d})")
    if !ok do c, end, ok = tool_find(body, "Builder#{d} clears climb tile ({d},{d})")
    if !ok do return
    t, _, mine := tool_find(body[end:], " was={w} goal={w} dbg_den=#{d}(", last = true)
    if !mine do return
    bot := trace_bot(w, tool_int(c.v[0]))
    if c.v[0] == t.v[2] {
        bot.count["own_den_dug"] += 1
        append(&bot.signs, Trace_Sign{frame, "wall_dig"})
    } else {
        bot.count["other_den_dug"] += 1
    }
}

// A tile put down or taken up; true when the line was one.
@(private="file")
trace_event :: proc(w: ^Trace_World, body: string, frame: int) -> bool {
    for row in TRACE_EVENTS {
        c, _ := tool_find(body, row.pat) or_continue
        op := Trace_Op{frame, row.kind, tool_int(c.v[c.n - 2]), tool_int(c.v[c.n - 1]), false}
        if c.v[0] != "" do append(&trace_bot(w, tool_int(c.v[0])).ops, op)
        else do append(&w.orphans, op)
        return true
    }
    return false
}

@(private="file")
trace_last_frame :: proc(tr: ^Trace, life: int) -> int {
    best := 0
    for key, w in tr.worlds {
        if key[0] != life do continue
        for _, b in w.bots do if len(b.track) > 0 do best = max(best, b.track[len(b.track) - 1].f)
    }
    return best
}

// Where a Builder was at a frame, between its breadcrumbs.
@(private="file")
trace_where :: proc(b: ^Trace_Bot, frame: int) -> (x, y: f64) {
    t := b.track[:]
    i := 0
    for i < len(t) && t[i].f < frame do i += 1
    if i == 0 do return t[0].x, t[0].y
    if i == len(t) do return t[i - 1].x, t[i - 1].y
    a, c := t[i - 1], t[i]
    u := f64(frame - a.f) / f64(max(1, c.f - a.f))
    return a.x + (c.x - a.x) * u, a.y + (c.y - a.y) * u
}

// Unnamed digs go to the nearest Builder alive then.
@(private="file")
trace_attribute :: proc(w: ^Trace_World) {
    for orphan in w.orphans {
        op := orphan
        op.guessed = true
        best, best_d := -1, f64(1e9)
        for id in w.order {
            b := w.bots[id]
            if len(b.track) == 0 || op.f < b.track[0].f - 600 || op.f > b.track[len(b.track) - 1].f + 600 do continue
            px, py := trace_where(b, op.f)
            d := max(abs(px - f64(op.x)), abs(py - f64(op.y)))
            if d < best_d do best, best_d = id, d
        }
        if best < 0 do continue
        if op.kind == "loop" do w.bots[best].count["pillar_loop"] += 1
        else do append(&w.bots[best].ops, op)
    }
    less :: proc(a, b: Trace_Op) -> bool {
        if a.f != b.f do return a.f < b.f
        if a.kind != b.kind do return a.kind < b.kind
        if a.x != b.x do return a.x < b.x
        if a.y != b.y do return a.y < b.y
        return !a.guessed && b.guessed
    }
    for _, b in w.bots {
        ops := b.ops[:]
        for i in 1 ..< len(ops) {
            for j := i; j > 0 && less(ops[j], ops[j - 1]); j -= 1 do ops[j], ops[j - 1] = ops[j - 1], ops[j]
        }
    }
}

// Runs where seq repeats with a period of 2..8 for three periods, and is not
// one value: (start, period, length).
trace_cycles :: proc(seq: []$T) -> [dynamic][3]int {
    MIN_REPEATS :: 3
    MAX_PERIOD  :: 8
    out := make([dynamic][3]int)
    n := len(seq)
    for i := 0; i < n; {
        best_p, best_span := 0, 0
        for p in 2 ..= MAX_PERIOD {
            j := i
            for j + p < n && seq[j] == seq[j + p] do j += 1
            span := j - i + p
            varied := false
            for k in i ..< min(i + p, n) do if seq[k] != seq[i] do varied = true
            if span >= p * MIN_REPEATS && varied && span > best_span do best_p, best_span = p, span
        }
        if best_p > 0 {
            append(&out, [3]int{i, best_p, best_span})
            i += best_span
        } else {
            i += 1
        }
    }
    return out
}

// Python's round: a half goes to the even neighbour.  The tile cycles bucket
// positions the way the old tool did.
trace_round :: proc(v: f64) -> int {
    r := math.round(v)
    if abs(v - math.trunc(v)) == 0.5 && int(r) % 2 != 0 do r -= math.sign(v)
    return int(r)
}

// A tile put down, then taken again with nothing between on that tile.
Trace_Pair :: struct { tile: [2]int, put, took: string, f0, f1: int }

trace_put_then_taken :: proc(ops: []Trace_Op) -> [dynamic]Trace_Pair {
    is_put :: proc(k: string) -> bool { return k == "encase" || k == "build" || k == "place" }
    is_take :: proc(k: string) -> bool { return k == "harvest" || k == "carve" || k == "mine" || k == "climb" }
    Put :: struct { f: int, kind: string }
    last: map[[2]int]Put
    pairs := make([dynamic]Trace_Pair)
    for op in ops {
        t := [2]int{op.x, op.y}
        if is_put(op.kind) {
            last[t] = {op.f, op.kind}
        } else if is_take(op.kind) {
            if p, ok := last[t]; ok {
                delete_key(&last, t)
                append(&pairs, Trace_Pair{t, p.kind, op.kind, p.f, op.f})
            }
        }
    }
    return pairs
}

@(private="file")
trace_report_bot :: proc(b: ^strings.Builder, i: int, bot: ^Trace_Bot, tiles: int) -> bool {
    t := bot.track[:]
    if len(t) < 2 do return false
    goals: Tool_Tally(string)
    for c in t do tool_tally(&goals, c.goal)
    fmt.sbprintf(b, "\n  Builder#%d: %d crumbs over frames %d-%d (%d s):", i, len(t), t[0].f, t[len(t) - 1].f, (t[len(t) - 1].f - t[0].f) / 60)
    for g in tool_tally_top(&goals) do fmt.sbprintf(b, " %s %d%%", g, 100 * goals.n[g] / len(t))
    strings.write_byte(b, '\n')

    still, best, run := 0, 0, 0
    at: Trace_Crumb
    for k in 1 ..< len(t) {
        a, c := t[k - 1], t[k]
        same := abs(a.x - c.x) < 0.6 && abs(a.y - c.y) < 0.6 && c.f - a.f <= 330
        if same && c.goal != "Cooldown" && a.goal != "Cooldown" {
            still += 1
            run += 1
            if run > best do best, at = run, c
        } else {
            run = 0
        }
    }
    fmt.sbprintf(b, "    still while not idle: %d s (%d%%)", still * 5, 100 * still / max(1, len(t) - 1))
    if best >= 2 do fmt.sbprintf(b, ", longest %d s at (%.1f,%.1f) %s ending f%d", best * 5, at.x, at.y, at.goal, at.f)
    strings.write_byte(b, '\n')

    goal_seq := make([]string, len(t))
    tile_seq := make([][2]int, len(t))
    for c, k in t {
        goal_seq[k] = c.goal
        tile_seq[k] = {trace_round(c.x / 3), trace_round(c.y / 3)}
    }
    for name in ([]string{"goal", "position"}) {
        found := trace_cycles(goal_seq) if name == "goal" else trace_cycles(tile_seq)
        for k in 1 ..< len(found) {  // longest first, ties in order
            for j := k; j > 0 && found[j][2] > found[j - 1][2]; j -= 1 do found[j], found[j - 1] = found[j - 1], found[j]
        }
        for c in found[:min(3, len(found))] {
            s, p, n := c[0], c[1], c[2]
            fmt.sbprintf(b, "    %s cycle, period %d s, %d s long, from f%d: ", name, p * 5, n * 5, t[s].f)
            for k in s ..< s + p {
                if k > s do strings.write_string(b, " > ")
                if name == "goal" do strings.write_string(b, goal_seq[k])
                else do fmt.sbprintf(b, "(%d,%d)", tile_seq[k].x * 3, tile_seq[k].y * 3)
            }
            strings.write_byte(b, '\n')
        }
    }

    strings.write_string(b, "   ")
    for k in TRACE_COUNT_KEYS do if bot.count[k] > 0 do fmt.sbprintf(b, " %s=%d", k, bot.count[k])
    kinds: Tool_Tally(string)
    guessed := 0
    for op in bot.ops {
        tool_tally(&kinds, op.kind)
        if op.guessed do guessed += 1
    }
    strings.write_string(b, "\n    ops:")
    for k in tool_tally_top(&kinds) do fmt.sbprintf(b, " %s=%d", k, kinds.n[k])
    if guessed > 0 do fmt.sbprintf(b, " (~%d attributed)", guessed)
    strings.write_byte(b, '\n')

    if len(bot.nav) > 0 {
        fail, partial, full, us := 0, 0, 0, 0
        for n in bot.nav {
            if !n.ok do fail += 1
            if n.ok && !n.complete do partial += 1
            if n.nodes >= 4000 do full += 1
            us += n.us
        }
        fmt.sbprintfln(b, "    A*: %d searches, %d no route, %d best-effort, %d ran the node budget, %.0f ms total", len(bot.nav), fail, partial, full, f64(us) / 1000)
    }
    first_den, last_den: Trace_Beat
    dens, low := 0, max(int)
    for beat in bot.beats {
        if !beat.den do continue
        if dens == 0 do first_den = beat
        last_den = beat
        dens += 1
        low = min(low, beat.open_wall + beat.open_shell)
    }
    if dens > 0 {
        fmt.sbprintfln(b, "    den: open slots %d+%d at f%d, %d+%d at f%d, lowest %d, hoard %d",
            first_den.open_wall, first_den.open_shell, first_den.f, last_den.open_wall, last_den.open_shell, last_den.f, low, last_den.hoard)
    }
    if len(bot.anchors) > 0 {
        strings.write_string(b, "    den sites:")
        for a in bot.anchors[:min(12, len(bot.anchors))] do fmt.sbprintf(b, " (%d,%d)@f%d", a[1], a[2], a[0])
        strings.write_byte(b, '\n')
    }

    touch: Tool_Tally([2]int)
    for op in bot.ops do tool_tally(&touch, [2]int{op.x, op.y})
    hot := 0
    for tile, k in tool_tally_top(&touch) {
        if k >= tiles || touch.n[tile] < 3 do break
        strings.write_string(b, "    tiles touched:" if hot == 0 else "")
        fmt.sbprintf(b, " (%d,%d)x%d", tile.x, tile.y, touch.n[tile])
        hot += 1
    }
    if hot > 0 do strings.write_byte(b, '\n')

    pairs := trace_put_then_taken(bot.ops[:])
    if len(pairs) > 0 {
        gaps := make([]f64, len(pairs))
        by: Tool_Tally(string)
        for p, k in pairs {
            gaps[k] = f64(p.f1 - p.f0)
            tool_tally(&by, fmt.tprintf("%s>%s", p.put, p.took))
        }
        sorted := make([]f64, len(gaps))
        copy(sorted, gaps)
        for k in 1 ..< len(sorted) {
            for j := k; j > 0 && sorted[j] < sorted[j - 1]; j -= 1 do sorted[j], sorted[j - 1] = sorted[j - 1], sorted[j]
        }
        fmt.sbprintf(b, "    put then taken: %d, median gap %.0f frames:", len(pairs), sorted[len(sorted) / 2])
        for k, n in tool_tally_top(&by) do if n < 5 do fmt.sbprintf(b, " %s=%d", k, by.n[k])
        strings.write_byte(b, '\n')
        for p in pairs[:min(3, len(pairs))] do fmt.sbprintfln(b, "      e.g. (%d, %d) %s f%d, %s f%d", p.tile.x, p.tile.y, p.put, p.f0, p.took, p.f1)
    }
    return true
}

tool_builder_trace :: proc(b: ^strings.Builder, path: string, min_frames := TOOL_TRACE_FRAMES, tiles := TOOL_TRACE_TILES) -> bool {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    context.allocator = context.temp_allocator
    file := tool_run_file(path, "action.log")
    data, err := os.read_entire_file(file, context.allocator)
    if err != nil {
        fmt.sbprintfln(b, "cannot read %s: %v", file, err)
        return false
    }
    tr := trace_parse(strings.split_lines(string(data)))
    keys := make([dynamic][2]int)
    for k, w in tr.worlds do if len(w.order) > 0 || len(w.orphans) > 0 do append(&keys, k)  // a level no Builder showed on
    for i in 1 ..< len(keys) {
        for j := i; j > 0 && (keys[j][0] < keys[j - 1][0] || (keys[j][0] == keys[j - 1][0] && keys[j][1] < keys[j - 1][1])); j -= 1 {
            keys[j], keys[j - 1] = keys[j - 1], keys[j]
        }
    }
    totals: map[string]int
    for key in keys {
        if tr.clock[key] < min_frames do continue
        fmt.sbprintfln(b, "\n== life %d level %d: %d frames (%d s) with the player here ==", key[0], key[1], tr.clock[key], tr.clock[key] / 60)
        w := tr.worlds[key]
        ids := make([]int, len(w.order))
        copy(ids, w.order[:])
        for i in 1 ..< len(ids) {
            for j := i; j > 0 && ids[j] < ids[j - 1]; j -= 1 do ids[j], ids[j - 1] = ids[j - 1], ids[j]
        }
        for id in ids {
            bot := w.bots[id]
            if !trace_report_bot(b, id, bot, tiles) do continue
            for k, n in bot.count do totals[k] += n
            totals["bots"] += 1
        }
    }
    strings.write_string(b, "\n== loop signs by builder-minute ==\n")
    for key in keys {
        w := tr.worlds[key]
        signs: Tool_Tally(string)
        total, any_loop := 0, 0
        for id in w.order {
            bot := w.bots[id]
            if len(bot.track) == 0 do continue
            total += bot.track[len(bot.track) - 1].f / 3600 - bot.track[0].f / 3600 + 1
            seen: map[string]bool  // each sign counts once in a minute
            minutes: map[int]bool
            for s in bot.signs {
                minutes[s.f / 3600] = true
                k := fmt.tprintf("%d %s", s.f / 3600, s.name)
                if seen[k] do continue
                seen[k] = true
                tool_tally(&signs, s.name)
            }
            any_loop += len(minutes)
        }
        if any_loop == 0 do continue
        fmt.sbprintf(b, "life %d level %d: %d%% of %d builder-minutes:", key[0], key[1], 100 * any_loop / total, total)
        for k in tool_tally_top(&signs) do fmt.sbprintf(b, " %s %d%%", k, 100 * signs.n[k] / total)
        strings.write_byte(b, '\n')
    }
    strings.write_string(b, "\n== run totals ==\n")
    names := make([dynamic]string)
    for k in totals do append(&names, k)
    for i in 1 ..< len(names) {
        for j := i; j > 0 && names[j] < names[j - 1]; j -= 1 do names[j], names[j - 1] = names[j - 1], names[j]
    }
    for k, i in names do fmt.sbprintf(b, "%s%s=%d", " " if i > 0 else "", k, totals[k])
    strings.write_byte(b, '\n')
    return true
}

// ─── --hero-soak ────────────────────────────────────────────────────────────

// The hero's live chase (cards 149, 140, 155, 156): on natural home terrain, a
// hunting Vargr 6 or 10 tiles off on either side, the hero at a fifth or half
// of its hp walking at it for TOOL_SOAK_FRAMES with one act goal.  Ten seeds,
// so 80 runs per kit.  Each run is a fresh Game_State, whose save, stats and
// log paths stay empty, so a death removes no save and nothing is written.
TOOL_SOAK_FRAMES :: 400
TOOL_SOAK_SEEDS  :: [?]u32{781, 1, 2, 3, 5, 7, 11, 13, 42, 99}

Tool_Soak_Kit :: enum u8 { Unarmed, Pickaxe, Sword, Wand, Both }

@(rodata)
tool_soak_kits := [Tool_Soak_Kit]struct { name: string, items: []Item }{
    .Unarmed = {"unarmed", {}},
    .Pickaxe = {"pickaxe", {.Pickaxe}},
    .Sword   = {"sword",   {.Sword}},
    .Wand    = {"wand",    {.Fire_Wand}},
    .Both    = {"both",    {.Sword, .Fire_Wand}},
}

// One run: whether the hero died.
tool_soak_run :: proc(seed: u32, off, side: f32, div: int, items: []Item) -> (dead: bool) {
    gs := new(Game_State)
    defer free(gs)
    link := new(Agent_Link)
    defer free(link)
    game_state_init(gs, seed)
    gs.ui.show_title = false
    gs.player.pos = SURFACE_HOME_POS
    link.connected, link.realtime = true, true
    frames :: proc(link: ^Agent_Link, gs: ^Game_State, n: int) {
        for _ in 0 ..< n do if agent_drive(link, gs) {
            game_update(gs)
            agent_after_tick(link, gs)
        }
    }
    frames(link, gs, 10)
    for i in 0 ..< MAX_ENEMIES do if gs.enemies.active[i] do despawn_enemy(gs, i)
    gs.roamer_timer = -1e9
    for it in items do inventory_insert(&gs.player.inventory, it, 1)
    gs.player.hp = max(1, gs.player.hp_max / div)
    vx := int(gs.player.pos.x) + int(side * off)
    G := 0
    for G < GRID_H - 1 && !is_solid(&gs.world, vx, G) do G += 1
    id, ok := enemy_alloc(&gs.enemies)
    if !ok do return false
    e := &gs.enemies.data[id]
    e^ = Enemy{kind = .Vargr, hp = VARGR_HP, hp_max = VARGR_HP, pos = {f32(vx) + 0.1, f32(G) - BUILDER_H}, facing = -1}
    entity_map_move(&gs.world, enemy_entity_id(id), builder_tile(e), builder_tile(e))
    agent_handle_line(link, gs, `{"cmd":"goals","add":[{"do":"act","move":"left","frames":300}]}` if side < 0 else `{"cmd":"goals","add":[{"do":"act","move":"right","frames":300}]}`)
    for _ in 0 ..< TOOL_SOAK_FRAMES {
        frames(link, gs, 1)
        if gs.player.dead do return true
    }
    return false
}

// Deaths of one kit over every seed, side, distance and hp.
tool_soak_kit :: proc(kit: Tool_Soak_Kit) -> (deaths, runs: int) {
    for seed in TOOL_SOAK_SEEDS do for off in ([2]f32{6, 10}) do for side in ([2]f32{-1, 1}) do for div in ([2]int{5, 2}) {
        runs += 1
        if tool_soak_run(seed, off, side, div, tool_soak_kits[kit].items) do deaths += 1
    }
    return
}

tool_hero_soak :: proc(b: ^strings.Builder) {
    strings.write_string(b, "SOAK")
    for kit in Tool_Soak_Kit {
        d, n := tool_soak_kit(kit)
        fmt.sbprintf(b, " %s %d/%d", tool_soak_kits[kit].name, d, n)
    }
    strings.write_byte(b, '\n')
}
