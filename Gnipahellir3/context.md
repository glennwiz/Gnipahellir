# context.md — Source of Truth

**Read this first every session; update it at the end of every session.** It is a
snapshot: what the game is, where the code stands now, what is owed. Not a changelog:
history lives in git log and `gnipa_project/Work_done.md` (the full pre-2026-11-03
text of this file is archived verbatim at its end). Where this file disagrees with
older docs, trust it; where it disagrees with the code or git log, they win.

- **Branch:** master · **Build:** green (`odin build src`) · **Tests:** 1266 green in both configs (`odin test src` and `odin test src -define:GAME_DEBUG=false`; a test that reads logs or debug tools carries a `when GAME_DEBUG` guard — includes the conservation fuzzer, GREEN since 372c30f; if it ever goes red again, a handler is leaking items — fix the handler, never the harness)
- **Last updated:** 2026-11-04
- **Save:** `SAVE_VERSION` 30 (`save.odin`; v30 added `monument_cells`). v28 and v29 are frozen and read by fixed offsets (`save_data_from_v28`), and every pre-v30 load marks the standing cells of each level's monument project as golem-built; v23-v27 read through the frozen 1024-enemy layout and shrink to 256. Enums are pinned by `saved_enum_ordinals_never_move` and `every_saved_enum_is_pinned` (`tests_save.odin`).
- **Board:** Thingvellir, http://127.0.0.1:41070, board `gnipahellir`. Task state lives there. Glenn's design decisions: `gnipa_project/design_review.md` section 6.
- **Toolchain:** Arch Linux, Odin dev-2026-10. Nothing has been run on Windows lately.

---

## 1. What the game is

**Gnipahellir** ("Yawning Chasm", Old Norse): a grid-based 2D Norse-underworld
mining roguelike. Odin + Raylib.

- **Dual-axis loop:** descend into caves, ascend into the sky. Find a Rune Scroll in a
  sealed chest, build the matching Sky Structure, a ritual opens the next cave gate.
  Three tiers, Garm the hound boss in cave 3, Hell beyond him, and the win is the
  **Final Seal**: E with the Hell Key starts the seal ceremony, which ends the run on
  the saga page. A Hel boss guarding the Seal is designed for later.
- **Fragile player, hostile world.** Death is permanent. One chosen item (the tithe)
  waits at a grave stone where the hero fell, guarded by the risen dead hero.
  Persistent stats survive across runs.
- **The long arc is automation:** hands in the dirt, then machines, golems and
  manufactured dimensions strip-mined by snake miners.
- **North star (Glenn):** the cost mirrors the reward.

Design bible: `gnipa_project/plan.md`. Issue audit: `gnipa_project/flagg.md`.

---

## 2. Architecture law (mandatory, full text in CLAUDE.md)

One Odin package (`game`); boundaries are call-discipline rules, checked by review.

- **Fat struct:** all runtime state in `Game_State`. No module-level mutable globals.
- **Fixed-size arrays only.** No `[dynamic]` growth during play. A full pool drops silently (logged in debug).
- **Event-driven:** systems talk through `Event_Queue`, drained in `process_events`.
- **Render is read-only:** `draw_*` reads state and calls raylib, never mutates.
- **Table-driven behavior:** terrain, item, enemy, roamer, turret, recipe = a table row. No `switch` sprawl.
- **Deterministic update order:** every system has an explicit line in `game_update`.
- **Saves:** enums are append-only (stored as u8). A layout change to a saved struct bumps `SAVE_VERSION` and the size `#assert` in the same commit. Never key a saved array by `[Item]`/`[Tile_Type]`; size it to a ceiling like `MAX_ITEM_SLOTS`. Enumerated arrays in `@(rodata)` tables are fine.
- **Entity map** (`World_Grid.entity_map`): per-tile lookup index, not a movement constraint. Player = 0, enemy slot i = i+1. Despawn via `despawn_enemy`, never bare `enemy_free`.
- **No TODOs in committed code.**

### Module responsibility
- `render.odin` / every `draw_*`: read `Game_State`, call raylib. Never mutate, never call update/input.
- `input.odin`: polls hardware, pushes events, toggles `UI_State`, sets inventory selection (the one exemption). Never writes `World_Grid` or entity data.
- `world.odin`, `enemy.odin`, sim code: never call `draw_*` or input procs.
- `types.odin`, `game_state.odin`: types, constants and the fat struct only.

### Key constants (don't change without updating plan.md)
```
GRID_W 192 · GRID_H 108 · CELL_SIZE 10
MAX_ENEMIES 256 · MAX_PARTICLES 256 · MAX_PROJECTILES 32 · MAX_EVENTS 512
```

### game_update order (`update.odin`; its comments carry the ordering constraints, and it wins over this list)
0 agent goals · 1 input (menus freeze the sim here) · 2 player · 2b camera · 2c golems · 3 enemies · 4 projectiles ·
5 mining · 5a reclaim · 5b0 power decay · 5b sim · 5b0 enemy status · 5b1 raids · 5b1z den revenge ·
5b1a waves · 5b1b roamers · 5b2 auto-miner · 5b3 life (debug toy) · 5c station focus · 5c2 hover text ·
5d recipe unlocks · 5e ritual · 5f sky apparition · 5g undermined structures · 6 process_events ·
6b gravity · 6b2 item fall · 6c fluids · 7 notifications · 8 ambience · 8b birds · 9 particles ·
9b floating text · 9c tile fx · 10 audio.

---

## 3. Source layout (`src/`)

- **Core:** `main.odin` loop · `types.odin` enums/events/consts · `game_state.odin` fat struct · `update.odin` order · `events.odin` dispatch · `input.odin` · `physics.odin` AABB `move_body` · `profile.odin`.
- **World:** `world.odin` terrain table, grid · `levels.odin` level store, portals, ritual, gen (rainbow, sky islands) · `dimensions.odin` spawner worlds and Hell · `gravity.odin` · `fluid.odin` · `undermine.odin` · `templates.odin` build templates · `rune_scroll_chest.odin` · `door.odin`.
- **Player and items:** `player.odin` · `mining.odin` · `reclaim.odin` Shift+hold pick-up · `placement.odin` · `items.odin` · `loot.odin` · `crafting.odin` · `buffs.odin` · `projectile.odin` · `grave.odin` tithe, grave stone, risen hero.
- **Enemies:** `enemy.odin` builders, dens, `astar_dig`, raiders · `garm.odin` · `draugr.odin` · `wave.odin` threat director · `roamer.odin` roaming creatures · `birds.odin` sky flocks (scenery).
- **Industry:** `sim.odin` machine tick, turrets, power · `barrel.odin` · `silo.odin` · `miner.odin` snake miner · `golem.odin` clay workers.
- **Presentation:** `render.odin` · `ui.odin` · `notify.odin` · `particles.odin` · `floating_text.odin` · `fx.odin` tile telegraphs · `audio.odin` · `camera.odin` · `assets.odin` · `pixel_art.odin` · `item_art.odin`.
- **Generated by GNIPA Studio (`tools/gnipa_studio`):** `gen_terrain.odin` · `gen_items.odin` · `gen_item_icons.odin` · `gen_recipes.odin` · `gen_player_art.odin`.
- **Persistence and tooling:** `save.odin` versioned binary · `debug_log.odin` action.log · `cam_log.odin` · `mouse_log.odin` · `agent_api.odin` local agent socket · `agent_exec.odin` agent goal queue and executor · `agent_tools.odin` the run tools as `gnipa --` options · `life.odin` Game-of-Life toy (debug only, not game content).
- **Tests:** `tests.odin` plus `tests_*.odin` (agent_api, agent_exec, agent_tools, birds, conservation, den_slot, dig, nav_budget, roamers, save, sky, sky_roamers, smash, turrets, undermine). A test's scratch file or folder takes its name from `test_scratch_path` (the pid in front), so two `odin test` runs in one folder never share one; `no_test_writes_a_scratch_file_under_a_fixed_name` reads the test sources and fails on a fixed name, or on the game's own path constants used in the test folder; a name the pid cannot tag (an unarmed save's `.tmp`) is taken with an exclusive create so runs take turns (card 177).

---

## 4. Where the code stands

One line per system; the long form of each is in the archive at the end of `Work_done.md`.

- **Levels:** surface with cave 1 below (`LEVEL_SURFACE`), cave 2, cave 3 with Garm's arena, sky, and a dimension slot. Hell is a fixed-seed world that persists across visits. Scroll A's chest always spawns (`spawn_deep_rune_scroll`); the surface altar is the sky gate and always rebuilds on tier A.
- **Sky:** a rainbow bridge between cloud islands (`gen_rainbow_bridge`), four floating islands (tree, pond, egg nest, Cloud Ore nest), bird flocks that scatter from the player, Rain Wisp and Rock Harpy roamers.
- **Progression:** Rune Scrolls A/B/C in sealed chests that no enemy can dig; the HUD objective line (`current_objective`, levels.odin; also state's `objective` on the agent socket) names the next concrete step with a compass hint, never a tile (card 165: the scroll's chest below/above, east/west, `far` past `OBJECTIVE_FAR`, the gate on the way (Cave or Sky Entrance), dragging the scroll out of its open chest, and which altar foundation the sky still lacks); Sky Altar ritual swirl consumes on completion; seal ceremony then `Game_Won` and the saga page.
- **Death and new runs:** the death screen names killer and place; the tithe click picks one item; the next world raises a `Rune_Stone` where the hero fell with a `Rune_Coffer` holding the tithe; the risen hero (a Draugr-turned Builder with the old kit) guards it. Title seed field and "Yesterday's world" (Y).
- **Progression:** Rune Scrolls A/B/C in sealed chests that no enemy can dig; Sky Altar ritual swirl consumes on completion; seal ceremony then `Game_Won` and the saga page.
- **Death and new runs:** the death screen names killer and place; the tithe click picks one item; the next world raises a `Rune_Stone` where the hero fell with a `Rune_Coffer` holding the tithe; the risen hero (a Draugr-turned Builder with the old kit) guards it, within `RISEN_GUARD_RANGE` of the stone; on the surface the stone stands more than `RISEN_GUARD_RANGE + GRAVE_RING_MARGIN` from the spawn and from the starting pickaxe, or, with no room for that, `GRAVE_SPAWN_CLEAR` from both (card 169, playtest 133). Title seed field and "Yesterday's world" (Y).
- **Player loop:** cursor-aimed pick, wands, sword, the pickaxe's soft blow (card 168: a click on an enemy's body in `MELEE_REACH` swings for `PICKAXE_DAMAGE` 1 every `PICKAXE_SWING_COOLDOWN` 0.5 s and mines nothing; anywhere else the pick mines as ever and swings at nothing; `pick_swing_target`), hotbar (replaced the equip slots), mined drops in reach go straight to the bag, drag-to-drop piles that fall until they land, potions, Jade Ring, buckets.
- **Enemies:** Builders live in dens (dungeons with floor hoards; robbing one arms a revenge wave), dig and build through `astar_dig` (binary heap, per-frame `gs.nav_work` budget, pond-safe, pays `COST_SELF_UNDONE` for floor it carves, never rises onto it unless nothing else goes, turns a climb at a wall with a carved hop two columns back, and pillars once for a target it has no route to, up to its row). Player-placed blocks take dig time (`dig_time_table`). Industry raids, a threat-driven wave director with a HUD gauge (steam lures Underground hunters, magic lures Air), Vargr that tunnel, Fire Sprites that give up, Draugr (a felled builder rises at its den and waits `DRAUGR_RISE_DELAY` 0.8 s before its first claw). `MAX_ENEMIES` 256. At `-o:speed` a 110k-work frame is about 4.8 ms and 256 hunters plus the crew run p99 3.6 ms with no rendering (code review finding 3).
- **Garm:** a hound boss that builds a 10x8 lair vault, floods it with lava, cages the player and breaks into his own cage. Lava is static except where Garm pours it.
- **Roamers** (`roamer_table`): Pond Frog, Mole, Ember Beetle on the surface; Cave Eel, Magma Crawler, Stone Grub in cave 2; Rain Wisp, Rock Harpy in the sky.
- **Industry:** Bench, Smelter (ore buffer, wood fuel, auto-pull from adjacent ground piles, else from an adjacent barrel with a mote stream barrel -> machine; boilers and the Magic Kettle pull fuel the same way; a silo stays a sink, never a source), Tree Grower, Storage Barrel, Silo, Auto-Miner (dimensions only), Gem Replicator, Steam (Boiler, Engine) and Magic (Kettle, Mana Wheel, Mana Mist, Mana Pipes) feeding one track-agnostic `powered()`. Turrets built in the world: Turret Pillar plus a head (Flame, Rainbow Laser with line of sight); any block destroyed breaks the whole turret into items.
- **Clay golems:** Command Wand, roster window, Gather/Build modes, eight-block packs, Quick Clay footholds, monument templates. A build fetch or delivery whose target has no route, or that gets no closer for `GOLEM_TRANSFER_STALL_TIME` (10 s), drops that source or store for the next (`golem_watch_transfer`, transient per-golem list, cleared after `GOLEM_TRANSFER_RETRY_TIME` 60 s, on recall, on deploy into the slot and on level change); with no source left the crew files its NEEDS notice. A Rune_Coffer (the grave's tithe) is never crew storage, in or out. A golem idle for `GOLEM_IDLE_FOOTHOLD_TIME` (1 s) loses its own Quick Clay and comes down; a job reset ends a recovery climb (`golem_reset_job`). A golem never digs (gather or path) the ground under a structure or the last anchor of a player-placed falling block (`removal_undermines`), unless the player marked that cell. `gravity_piece_held` keeps its held answers in `gs.held_memo` while the world stands still (one A* search); `held_memo_reset` ends that. Builders and Garm never hurt a golem (deliberate); Draugr, raid Tunnellers/Vargr and fire sprites do.
- **Clay golems:** Command Wand, roster window, Gather/Build modes, eight-block packs, Quick Clay footholds, monument templates. A build fetch or delivery whose target has no route, or that gets no closer for `GOLEM_TRANSFER_STALL_TIME` (10 s), drops that source or store for the next (`golem_watch_transfer`, transient per-golem list, cleared after `GOLEM_TRANSFER_RETRY_TIME` 60 s, on recall, on deploy into the slot and on level change); with no source left the crew files its NEEDS notice. The same watch covers a Place and a Gather worker's climb back to its zone; neither takes a dropped-list slot: the worker waits `GOLEM_TRANSFER_RETRY_TIME` (`build_wait`, "can't reach the build at x,y"; `climb_wait`, "can't climb back to its zone"). A Build fetch or Place with no route and a full pack sets the pack down where it stands and tries again (`golem_set_down_pack`). A natural or golem-navigation block in a footprint cell is dug out on arrival (`golem_clear_footprint`). Any footprint block no worker may dig (`golem_dig_forbidden`, shared with golem_mine_tile's path rules: the player's masonry or structure, a den, the ground under the base, an undiggable block) is skipped by every worker without a list slot and said once per set ("crew: something is in the way at x,y" / "N blocks in the way", `golem_note_in_way`, like the NEEDS notice); another golem's block in its grace is waited out. A falling monument block carries its mark: it settles still marked or crumbles to its build item, and the crew digs a marked block out of a footprint. A worker below its zone climbs back only for work (cargo, a resource or cleanup); an empty zone leaves it on the ground ("the crew's zone is empty", once). A job reset zeroes `vel.x`. A Rune_Coffer (the grave's tithe) is never crew storage, in or out. A golem idle for `GOLEM_IDLE_FOOTHOLD_TIME` (1 s) loses its own Quick Clay and comes down; a job reset ends a recovery climb (`golem_reset_job`). Builders and Garm never hurt a golem (deliberate); Draugr, raid Tunnellers/Vargr and fire sprites do.
- **Clay golems:** Command Wand, roster window, Gather/Build modes, eight-block packs, Quick Clay footholds, monument templates. A golem never digs (gather or path) the ground under a structure or the last anchor of a player-placed falling block (`removal_undermines`), unless the player marked that cell. `gravity_piece_held` keeps its held answers in `gs.held_memo` while the world stands still (one A* search); `held_memo_reset` ends that. Builders and Garm never hurt a golem (deliberate); Draugr, raid Tunnellers/Vargr and fire sprites do.
- **Physics and terrain:** placed-block gravity (a block landing in a player, enemy or golem body crumbles to its item), falling trees, water and lava flow, springs, quench (water on lava makes `Scoria`), undermined structures break into their item; an undermined loaded barrel or silo breaks too, spilling every stored stack as ground piles (`spill_store`), while a loaded coffer, depot or Auto-Miner stands until emptied (`holds_hoard`). Enemy digs conserve items (`smash_tile` spills machines and both door halves). A loaded Golem Depot, like a loaded silo or barrel, is refused as a raid or dig target (`wave_target_refused`); a depot taken anyway spills its cargo and drops its record (`spill_machine`). A golem-built monument cell, core or masonry, gives back the item it was built from to whoever takes it: `golem_place_reserved` marks it in `gs.monument_cells` (saved, per level), `monument_cell_take` (events.odin) pays and forgets it, for smash_tile, handle_tile_mined and a Gather golem (`golem_mine_tile`). A marked block that falls carries its mark (`Falling_Block.monument`): it lands marked, or crumbles to its build item, and the crew digs it out of a footprint as its own. A block the player lays in a footprint pays its own drop.
- **Saves:** write to `<path>.tmp` then rename; a refused save moves to a `.N.bak` slot; stats file is versioned and an unreadable one goes to `.unread`.
- **Agent play:** a connected agent's game runs in real time at a fixed 1/60 s step and never waits for it (the old waiting game is internal, for tests and `--replay`; `plan`, `wait`, `idle` and `realtime` answer "retired, use goals", card 154). The agent queues goals (`goals` add/cancel/clear, 32 slots, table-driven kinds in `agent_exec.odin`; `act`, `go`, `home`, and the work kinds `mine`, `gather`, `craft`, `place`, `store`, `withdraw`, `feed`, `collect` (card 139, `agent_work.odin`: each picks its tool and walks into reach; windows worked with a visible cursor at a person's pace, `HERO_CURSOR_SPEED`/`HERO_CLICK_PAUSE_S`/`HERO_WINDOW_LOOK_S`, each click the event the same mouse gesture pushes; no work dig takes the hero's own floor over a drop that hurts, `hero_dig_safe`), the crew goals `crew_mode` {golem, mode}, `crew_call` {golem}, `crew_pickup` {golem} (card 148: they work the roster window as a person does, the command wand taken in hand first; a cracked golem's PICK UP walks into reach; the mouse and the goals share `golem_roster_press`), `fight` {kind|slot} (card 140, `agent_fight.odin`: sword in reach (else the pickaxe's soft blow, card 168, also for fight_back; a wand shot comes before it, and the brain's own fight and flee count a pickaxe as an arm only against a threat it outlasts, `hero_pick_beats`, card 176: its `PICKAXE_DAMAGE` blows fell it in fewer blows than the threat's fell the hero at its hp now, so a whole hero fights a Builder and runs from a Draugr or a Vargr), fire wand at range along a clear line to the body's centre, walks to open ground without digging, backs off at low hp); go/home plan a path with drops priced by the fall rule, gap jumps, bridges and pick digs, card 138; reflexes switchable by `reflexes`: leave lava/water, potion at low hp, no deadly floor dig, no pond/lava rim dig, fight back at what hurt it; fight_back off also stops the brain's own Fight and the flee's shots back, a fight goal still fights, card 161) and the executor (game_update step 0) turns the running one into `gs.agent.cmd`; the hero never moves with a window open. Between the queue and the input a utility AI (`gs.hero`, `hero_behaviours`, card 149; design in `ai_algo.md`) senses on-screen threats, a danger map of drops and burns, and remembered safe ground: it pauses a goal to fight or flee (by hp), stops at a drop the fall would hurt from (the goal fails) unless a threat takes over, takes a hurt fall in flight only when it costs less than the threat's blow, or when the way past is shut and the threat is on it (card 140), or when the blows this flight has taken already cost more than the fall; jumps a gap the jump arc clears; cornered and unarmed with a pick, digs through the wall (card 155); with drops both ways (or a shut way behind) it takes the cheaper and turns at most once more to reach it, no running back and forth past the threat (card 156); no goal runs while a hunter it cannot fight closes on it, nor an armed hero's dig under `HERO_LOW_HP_FRAC` (cards 155, 156); wary (a threat in the senses inside `HERO_WARY_S`, or spent: low with no heal in the bag) it takes no work stand whose way out (`hero_exit_cost`) costs more than `HERO_WARY_EXIT_HP`, and spent with no threat it retreats out of such a pit, a work goal paused (the `retreat` behaviour, card 157); card 158: a hunting threat coming at the hero within `HERO_THREAT_NEAR` is noticed through rock, a noticed threat stays in mind `HERO_CLEAR_MARGIN` past `HERO_THREAT_FAR`, a goal paused for flight more than `HERO_HUNTED_PAUSES` times by a hunting threat still in sight fails `hunted`, a dig out never takes placed blocks or a tile `hero_dig_safe` refuses, go/home take a hurtful drop only when no way without one reaches, and death fails every goal live at it but an act `died`, once (goals queued on the death screen run in the next life); card 159: a bridge sets down the plain block with the most to spare past what the queued craft goals need of it (`HERO_BRIDGE_BLOCKS`, never a log; `hero_craft_reserve`), never into a pile; no plan digs its goal's floor or stands on a floor its own digs take; the floor_dig reflex lets a body on another column's floor dig (the playtest 127/128 "gave nothing"), and a dig a reflex refuses fails `refused: the <reflex> reflex`; a place refused in reach fails `refused: <the game's note>` (`place_refusal_full`, the click's note too); a go blocked on a structure's top names it; card 169: the risen hero holding its post (`risen_hero_guarding`: the player outside its ring) is a `guarding` threat in the senses: no goal held, no wariness, so an unarmed hero walks past it, and a goal into its ring fails `hunted`; card 164: a threat is closing by its own move only (the hero's walk at it is not), a goal paused longer than `HERO_PAUSE_MAX_S` at a stretch fails `held`, withdraw takes a scroll chest (opened or not), a place under the hero's own body steps to the stand's middle (`HERO_PLACE_ASIDE_TICKS`, else `blocked`), and in the sky a fall through `SKY_FALL_Y` is no drop to fear; the walk goes into a structure, scroll chest or door from the side as the body does (`hero_walk_in`), a mine goal hovering in flight works from the hover or fails naming it, and an act's pick at a workable tile out of its reach toasts "Out of reach: (x,y)" (`pick_target` shared from mining.odin); the potion reflex also eats a Sky Egg (`hero_heal_items`, card 156: HP never regenerates, so these are the only heals), and keeps to safe ground when idle, with hysteresis and human pacing in `HERO_*` constants. The brief (a GET on the port, `agent_write_brief`, card 142) is for goal play: every goal kind with its params from the table (a test keeps it so), fail reasons, real time fixed, events, reflexes, act as a goal, the bare-hand rule from `BARE_HAND_TILE` and `gnipa --help`'s `TOOL_USAGE`; playtests send goals, rules in `agent_playtests.md`, a missing goal kind or a goal that fails where a player would succeed is a `[goal]` finding. Replies carry `re`; after its first `goals` a client is pushed goal_done/goal_failed/goal_paused/goal_resumed/idle/hurt/died/level_changed/heard lines. acts.jsonl logs every goal, cancel and clear with its arrival frame, each goal's end (`done`/`failed`) and each window open/close, so seed + goals replays exactly; `act` stays as a shorthand that queues one act goal and answers with state when it is done. One client drives; up to 4 more connections watch (state only, every event line) and one takes the game when the driver is gone, so a lost connection reconnects. `agent_api.odin` serves a local HTTP API; the title's `[A] Let an agent play` runs in a sandbox folder under `agent_runs/`. Verbs include `tithe:slot` on the death screen (state's `tithe.ready_in` counts the screen's 1.2 s wait down) and, with a command wand selected, `zone`, `crew` and `monument`+`at` for the golem crew; state lists the crew (golems with hp, broken, recovering, carry, target and pack, card 148; the level's zone and monument), the sky flocks in view, and each enemy's body `w`,`h` beside its top-left `x`,`y`. Cursor verbs take `[x,y]` in tiles: whole numbers aim at the tile centre, fractions (`10.0` included) at that point, as a mouse does. Glenn can chat to the agent with Enter. `GNIPA_AGENT_TURBO=1` for fast runs. The run tools are options of the game binary (`agent_tools.odin`, `gnipa --help`): `--agent-run [--port 7777] [--seed N | --load save]` (folder under `build/agent_runs/`, binary copied in; `--load` starts from a save as Continue does, keeps it as `start.sav`; a path that is no save is refused before the window, and the title boots the save's own seed), `--make-save --seed N --out F` (card 170: a save just past ritual A, the route played headless through the game's own handlers with two shortcuts, standing beside each station and the exact materials handed over; see `agent_playtests.md`), `--replay <run>` (feeds the goal rows back by frame, checks each act's landing, stops at a disconnect; a `--load` run from its `start.sav`, card 178), `--summary <run>` (with goal-queue idle, gaps, fail reasons, window time), `--pacing <runs>... [--csv]` (leaves a `--load` run out), `--builder-trace <run|action.log>`, `--hero-soak` (the hero's live chase, 80 runs per kit; the deaths per kit are pinned by tests in `tests_agent_tools.odin`: a gain moves the number down in the same commit, card 156).
- **Debug (debug builds):** F1 cheat menu and Item Palette, F2 altar menu, F3 ten snapshot slots, F4 raid/wave menu, action.log streamed for every run.
- **Art:** pixel-art atlas `pixel_art.dat` (Glenn's runtime file, not in git), edited in GNIPA Studio. Provenance list: `gnipa_project/art_provenance.md`.

Controls: `gnipa_project/PLAYTEST.md`.

---

## 5. What's owed

### Glenn's look (first-guess numbers in named constants)
Grave stone art and tithe layout; risen hero fight; seal ceremony and saga page; quench
walk-feel; wave gauge; the four new sounds; turret recipes, stats, art and shed pixels;
Rainbow Laser particle beam; all roamers; rainbow, sky islands and birds; the pickaxe's blow (`PICKAXE_DAMAGE`, `PICKAXE_SWING_COOLDOWN`, card 168); the objective line's wording and `OBJECTIVE_NEAR`/`OBJECTIVE_FAR` (card 165); placed-block
dig times and `COST_SELF_UNDONE`; the builder hop that turns a climb (card 118); builder den and no-route behaviour (cards 87, 99, 111);
mined drops to the bag; den revenge delay; the agent title lines, chat field and FUEL drag; agent runs in real time with goals (card 137);
Garm's cage and lair; golems leaving the ground under the base (card 144); the golem transfer stall and retry times (card 145); the idle foothold time (card 146); older Aug items (tree grower motes, tile ambience, Garm's trot).
mined drops to the bag; den revenge delay; the agent title lines, chat field and FUEL drag; agent runs in real time with goals (card 137); the hero's fight/flee/ledge/idle pacing (`HERO_*`, card 149); the path costs, stuck limits and reflex line (`HERO_NAV_*`, `HERO_GO_*`, `HERO_LOW_HP_FRAC`, card 138); the agent's window pace and give-up limits (`HERO_CURSOR_SPEED`, `HERO_CLICK_PAUSE_S`, `HERO_WINDOW_LOOK_S`, `HERO_MINE_GIVE_UP_S`, card 139); the fight goal's kite, retreat, wait and fight-back times and the flee's blow count (`HERO_KITE_TILES`, `HERO_FIGHT_RETREAT_FRAC`, `HERO_FIGHT_WAIT_S`, `HERO_FIGHT_BACK_S`, `HERO_PASS_BLOWS`, `HERO_BREAK_STUCK_S`, `HERO_MAULED_TILES`, card 140); the flee's gap jump width and when a cornered hero digs (`HERO_GAP_MAX`, `HERO_BREAK_STUCK_S`, card 155); the heal order (`hero_heal_items`, card 156);
Garm's cage and lair; older Aug items (tree grower motes, tile ambience, Garm's trot).
mined drops to the bag; den revenge delay; the agent title lines, chat field and FUEL drag;
Garm's cage and lair; the golem transfer stall and retry times (card 145, also Place and the zone climb since card 152); the idle foothold time (card 146); the set-down pack and the four crew notices (card 152); older Aug items (tree grower motes, tile ambience, Garm's trot).

### Open
- **Board Drafts:** 35 (Garm smashes lava: left as is, revisit with playtest data), 85 (Steam Early Access road), 95 (agent companion in the world), 96 (ask Valve about agent chat and AI content).
- **Art provenance:** waits on Glenn's six questions in `art_provenance.md`; three concept PNGs are gpt-image output and `sounds/splash_bang_pop` has no licence on file.
- **Code review 2026-11** (`gnipa_project/code_review_2026-11.md`): its recommended cards are the queue (frame time at 256, reload wipes wave progress, `enemy.odin` hardening, thin `update_input`, the event law).
- **Builder pathing debt** from the 2026-08-15 clear logs: `strike N (no path)` spam in late cave 3, mine/place oscillation, a give-up that never fires. Cards 99-111 cut much of it; re-check against a fresh log.
- **Gravity:** a place-anywhere anchor block (Glenn's endgame), placed Grass falling, enemy smashes do not trigger falls, `GRAVITY_ALL` unplaytested, falling blocks in flight are not saved.
- **Fluids:** flow only in the loaded level; falling blocks land on water instead of sinking; no fluid art or sound; a lava spring has no off switch.
- **Gem economy sinks** beyond the magic track stay parked in `gnipa_project/ideas.md`.
- **Polish:** collect motes home to the player, not the hotbar; the door ghost previews one cell; Hell_Gate and Final_Seal are flat red cells.

### Deliberate (don't file as bugs)
Golems are not attackable by Builders or Garm. Draugr hit them, and so do the raid
enemies (Tunnellers/Vargr, fire sprites), which came later as the base-defence threat. The `.Cave_Entrance` tile is dead and kept for save compat.
`life.odin` is a debug toy.

---

## 6. How to work here

- **Verify every change** from `Gnipahellir3`: `odin build src`, `odin build src -define:GAME_DEBUG=false`, `odin test src`, `odin test src -define:GAME_DEBUG=false`. A full test run takes about 1.5 minutes and 600 MB; run them one at a time. Every feature lands with tests; extend the soak tests. A red conservation fuzzer means a handler leaks items: fix the handler, never the harness.
- **Toolchain:** imports are plain `vendor:raylib`. `DrawCircleGradient` takes a `Vector2` center; use `DrawRectangleLinesEx` for hairlines. `delete_key` on a `typeid`-keyed map hangs the compiler at `-o:size` and above.
- **Working with Glenn:** he designs by conversation: concrete options with a recommendation, write his decisions down, don't re-litigate. He playtests by hand; `action.log` is ground truth (grep `strike`/`WARNING`/`Player`). Feel is his: a feature that needs a look is not finished until he has looked.
- **Commits:** conventional (`feat:`/`fix:`/`docs:`), lowercase. Glenn often drives git himself: check `git log` first.
- **Never delete real data** (saves, logs) for testing: copy it aside.
- `feature/render-port` is Glenn's stale R&D branch; on a conflict prefer master for `enemy.odin`/`tests.odin`.

---

## 7. The rest of the doc set

- `CLAUDE.md` (this folder): architecture law, full text.
- `gnipa_project/plan.md`: design bible. `gnipa_project/design_review.md`: the 2026-11 review and Glenn's decisions (section 6).
- `gnipa_project/code_review_2026-11.md`: code review and its recommended cards.
- `gnipa_project/flagg.md`: issue audit. `gnipa_project/PLAYTEST.md`: controls, debug tools, loop walkthrough.
- `gnipa_project/Work_done.md`: holiday log, locked decisions, and the archived long form of this file.
- `gnipa_project/OPUS_HANDOVER.md`: how to work with Glenn, the game's soul.
- Industry specs, kept as references: `draft1_machines.md`, `gem_industry.md`, `mana_industry.md`, `Steam_industry.md`, `studio_tiles.md`, `gem_progression.md`, `ai_algo.md`, `ideas.md` (raw backlog).
- Root: `pixel_style.md` art direction, `upgrade_system.md` (wand/gear upgrades, not built).

---

## Update ritual (end of every session)

Edit the header lines and sections 4 and 5 to match what landed: one line per system,
owed items moved in or out. Keep the `- **Branch:** ... **Tests:** N` line's shape;
`land.sh` rewrites its count. Long form goes in the commit message or `Work_done.md`,
not here. Keep this file under about 20 KB.
