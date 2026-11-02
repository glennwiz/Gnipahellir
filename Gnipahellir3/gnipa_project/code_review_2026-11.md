# Code review, 2026-11: are we fit to keep expanding?

By claude-gnipa-audit-5d2c, board card 74, at master `6089da7`. No game code was changed. All
experiments ran in a scratch copy.

Labels: **[ran]** I executed it. **[read]** I read the code or doc only.
**[opinion]** My judgment, not a fact.

## Verdict

**1. Vertical slice: aligned on paper, not yet proven.** Every card in the first-hour pass is Done
on the board, and the code matches the ones I checked. But I found no record of a human playing the
slice since those cards landed, and nobody has timed it at 20-30 minutes. Cards 64-73 now add
content to the same Surface, Cave 1 and Low Sky levels the slice is made of.

**2. Fit to keep adding features: yes, with four things fixed first.** The core architecture holds
and the test suite is strong: it caught 26 of 30 random bugs I injected. The risks are specific, and
none needs a rewrite:

1. Saves: the next layout change silently loses the current v28 run.
2. Slice: Glenn plays and times it before cards 64-73 change its levels.
3. Performance: the 256-enemy "frame-time test" does not bound frame time.
4. Structure: `enemy.odin` has no behaviour table, and nine roamers are queued.

Glenn's recorded decisions are not reopened here.

## Baseline [ran]

`odin build src` and the `GAME_DEBUG=false` build are green. `odin test src`: 478 of 478 pass in 52
s. With `GAME_DEBUG=false`: 470 pass, 8 fail (finding 7). Odin dev-2026-10 on Arch; nothing run on
Windows.

The box had a load average of 7 to 50 on 8 cores during this work, and the same search ranged from
2.15 to 11.33 ms on the same `-o:speed` build. **Trust the shape of the timings, not the digits.**

## Findings, ranked by what would hurt next

### 1. The next save layout change loses the live run, silently (high)

Facts:
- `save_data_read` accepts the current size, or the exact sizes of v24-v27 (`src/save.odin:211`).
  There is no `SAVE_V28_SIZE`. The asserts make the author update the expected size, but nothing
  makes them add a v28 path. [read]
- A rejected save returns false quietly, and `main.odin:62` starts a fresh world. The next autosave
  then overwrites the old file, with no backup (`src/main.odin:100`, `src/save.odin:259`). [read]
- `Save_Data_1024` and `Save_Data_v23` embed live types: `Player`, `World_Grid`, `Enemy`,
  `Golem_System`, `Sim_State` (`src/save.odin:56`). Change any of them and the frozen size asserts
  fire. The author must then freeze copies of those types or drop the old paths. [read]
- A same-size change passes every assert. Nothing pins enum ordinals: a grep of the tests and
  `types.odin` for pinned values found none. An inserted enum value would shift saved bytes with all
  asserts green. [ran]
- All migration fixtures are built from current structs (`src/tests.odin:9379`, `:11446`). No real
  old save file is loaded by any test, so a layout drift inside an embedded type cannot show up
  there. [read]
- Saving is a direct overwrite, not write-then-rename. A crash mid-write leaves a short file, which
  is then rejected on size and overwritten. [read]

Status: card 60 on `seat/claude-gnipa-impl-9b3e` does not change the saved layout, so this has not
fired yet. `Item` has 99 of 128 slots used. [ran]

### 2. No human has confirmed the slice, and the queue is moving past it (high)

Facts:
- Cards 9-18, 41-49 are Done on the board. [ran]
- `design_review.md` section 4 says: first-hour pass, ending, death, "then, and only then" the
  middle hour. The slice excludes steam, magic, golems, dimensions, gems. [read]
- I found no hand playtest recorded after those cards in `context.md`, `design_review.md` or
  `PLAYTEST.md`. `context.md` holds 47 "needs an eyeball" style flags by grep. Its section 5 "TOP
  PRIORITY: a big hand playtest is owed" still describes the 2026-08-02 pass. No `action.log` exists
  on this box, because Glenn plays elsewhere, so absence here is weak evidence. [ran]
- The 20-30 minute figure is unmeasured. The only number is the bot's "about eight minutes of sim
  time". The run it came from, `build/agent_runs/run2`, is no longer on this box, so it cannot be
  rechecked. [ran]
- Polish item P14, gold and silver pace, has no card. It is the only first-hour pacing check the
  harness could do. [ran]

**What serves the slice** [read, spot-checked in code]: objective line starts at the pickaxe
(`src/levels.odin` `current_objective`), death screen names the killer (`src/ui.odin:2257`), win
text no longer names Garm (`src/ui.odin:2404`), F3 rewind gated, character screen gone. Grave, seed
and risen hero give a reason to return.

**What has drifted** [opinion]: nothing is built wrong. The drift is in order. Cards 64-73 change
the slice's own levels before the slice has been felt, so any playtest afterwards judges a different
game. Turrets (60-63) sit outside the slice and do less harm. The objective line also never mentions
the Fire Wand, though the slice's sequence relies on it. [read]

### 3. The 256-enemy test does not bound frame time, and the default build misses 60 fps (high)

Glenn's Q5 decision was "256 with a frame-time test".

Facts:
- `a_full_enemy_store_holds_its_budgets_and_scales` (`src/tests.odin:12079`) reads the lower
  quartile of frames (`cap_quick`) and asserts only a ratio. It times `update_enemies` alone. Its
  log says 0.18 ms. [read, ran]
- Search work is bursty, so the lower quartile lands on frames with no search. [ran]
- Full `game_update`, 256 hunters, 200 frames, player on the surface, no rendering:

| Build | Scenario | p50 ms | p95 ms | p99 ms | Frames over 16 ms | A* ms each |
|---|---|---|---|---|---|---|
| `-o:speed`, quiet | mixed 256 | 0.09 | 7.9 | 8.6 | 0 of 200 | 2.15 |
| `-o:speed`, quiet | Vargr 256 | 4.6 | 8.7 | 9.1 | 0 of 200 | 2.18 |
| `-o:speed`, quiet | Vargr 256, player deep | 0.29 | 0.47 | 0.57 | 0 of 200 | 0.04 |
| `-o:speed`, loaded | Vargr 256 | 11.9 | 76 | 105 | 76 of 200 | 11.4 |
| default, best seen | mixed 256 | 0.45 | 54 | 86 | 62 of 200 | 14.6 |
| default, loaded | Vargr 256 | 155 | 1,478 | 2,009 | 106 of 200 | 229 |

- So the sim fits 60 fps at `-o:speed` with about 9 ms used, before any rendering. The 2.15 ms
  figure repeated across two runs. The default build does not fit: its best A* was about 7 times
  slower, and three searches in one frame already pass 16 ms. [ran]
- Nearly all of it is A*: 13.5 of 13.6 ms/frame in `update_enemies` in the default run I split by
  system. `update_sim` was 0.2 ms, fluid and gravity about 0. [ran]
- `astar_dig` is capped at 3 searches a frame, and the cap held in every run. The comment says
  1.2-1.4 ms a search (`src/enemy.odin:28`). The open set is a linear scan (`src/enemy.odin:594`).
  The binary heap is fix 5 of 5, still queued. [ran]
- Default `odin build src` has no optimisation flag. Neither does the documented release line in
  `PLAYTEST.md` or `tools/agent_play.sh`. I could not establish which build Glenn plays. [read]
- Golem searches go through `astar_dig` without touching the budget (`src/golem.odin:1007`). [read]
- A 4 MB autosave blocks the main thread: 44 ms median, 69 ms max, default build, loaded. It can
  recur every 5 s while the player is acting. [ran]

Not measured: rendering at 256, and anything on the game PC.

### 4. Reload wipes wave progress (medium, cheap)

`Save_Data` has no wave field, and `gs.wave` starts zeroed. A save and reload test gave pressure 900
to 0, cycle 5 to 0, cooldown 30 to 0. One-shot hints also re-fire (`pickaxe_hint_shown` true to
false). [ran]

Glenn accepted a reload dropping den grudges (section 6), and the raid director is transient by
design (`src/save.odin:332`). I found no such decision for waves. Save and quit is therefore a free
way to cancel a coming wave. Whether to keep it is Glenn's call, and saving it is a layout change,
so it should ride with finding 1.

### 5. `enemy.odin` is the weak spot for cards 64-70 (medium)

Facts: [read]
- 2,482 lines. There is no enemy behaviour table. `[Enemy_Kind]` tables cover only names, drops and
  blood colour.
- `update_enemies` is a `switch` where five of six cases repeat one `move_body` call with only
  constants changed (`src/enemy.odin:2446`).
- About 30 sites test a kind directly, 16 of them in `enemy.odin`. Size, speed, HP and gravity are
  per-kind constants or small switches (`src/enemy.odin:306`).
- All kinds share the `builder` sub-struct, and Vargr reuse `update_raider`.
- `astar_dig` is one proc of 328 lines and also serves golems.

Glenn asked for a shared roamer table. Opinion: card 64 should be the place that adds it, covering
body, speed, HP, gravity and update proc, and it should absorb the existing six kinds' `switch`.
Doing that after nine kinds costs far more. Adding roamers as more `case` lines breaks the table law
in the file that matters most. `is_wave_enemy` (`src/wave.odin:135`) must stay false for roamers,
per Glenn's "never join waves": give it a test.

`sim.odin` is healthy by contrast: 840 lines, largest proc 79, machines are table rows through
`tile_on_tick`, and card 60 follows that shape. Its grid scan costs 0.2 ms. [ran, read]

### 6. Two huge procs have no direct coverage (medium)

`update_input` is 824 lines (`src/input.odin:73`), and `process_events` is 451
(`src/events.odin:48`). Only one test reaches its real path (`src/tests.odin:9778`, via
`game_update`), with no window, so no key is ever down; the agent tests return at its first lines.
Real keys, mouse and rebinding have no effective coverage, so key bugs reach Glenn first. [ran,
read]

### 7. What the suite can and cannot see (mixed, mostly good)

- **Strong:** 30 condition flips, picked at random with a fixed seed from `enemy`, `sim`, `wave`,
  `save`, `events`, `garm`: **26 caught, 4 missed** [ran]. Missed: `src/sim.odin:565`,
  `src/save.odin:346` (bucket migration), `src/save.odin:548` (settings read error),
  `src/events.odin:115`. Small sample, so read it as "good", not "87%".
- **Blind:** zero `draw_*` calls in tests, so render and UI are untested. Only 7 `game_update` call
  sites. No test plays a whole run; the agent harness is the only thing that does, and it is outside
  `odin test`. [ran]
- **The 8 `GAME_DEBUG=false` failures are test gaps, not game bugs.** Six assert on logs that release strips. Two use debug-only features (`item_palette_maps_cursor_to_item`, `ultra_wand_cheat_blasts_a_3x3`). Each needs a `when GAME_DEBUG` guard. Until then the suite cannot run in release config, and the house rules only require the release *build*. [ran, read]
- `tests.odin` is 12,922 lines in one file. [ran]

### 8. Docs that lie (medium)

| Doc | Says | Reality |
|---|---|---|
| `context.md` | "a snapshot, not a changelog" | 287,617 bytes. 232 KB is a 157-line header of 120 dated bullets, the oldest from 2026-08 |
| `context.md:451`, `PLAYTEST.md:4`, the seat brief | "~2 s, 107 tests", "144 tests", "332 tests" | 478 tests, 7 to 52 s by box load |
| `context.md:172`, `plan.md:639` | Garm then win | The win is the Final Seal |
| `context.md` section 3 | source layout | Omits `grave`, `wave`, `barrel`, `buffs`, `draugr`, `rune_scroll_chest`, `reclaim`, `mining`, `projectile` |
| `context.md` section 2 | `game_update` order | Omits `update_den_revenge`, `update_item_fall`; says update.odin wins |
| Root `CLAUDE.md`, `AGENTS.md`, `board-monitor` skill, `coordinator_handover.md` | board on 7666 | 4, 3, 4 and 1 mentions; that board is gone, and root `CLAUDE.md` calls check-in "mandatory" |
| `CLAUDE.md` section 5 | "Windows primary", `odin run src` | No recent Windows run, and agents use `odin build` |

[ran grep and `wc`]

Reading `context.md` costs about 87,000 tokens, over three times the default file read limit. It
cannot be read whole in one normal read, so "read it first" is no longer a rule anyone can follow.
[ran]

### 9. Architecture laws, checked against code

| Law | Result | Evidence |
|---|---|---|
| No mutable globals | **Holds** | 13 `:=` tables lack `@(rodata)`, and none is ever written. Cosmetic [ran] |
| No `[dynamic]`, no TODOs | **Holds** | Zero of each in game code. `new`/`make` only at boot, save and profile [ran] |
| Bare `enemy_free` | **Holds** | Three are failed spawns before any map entry. One is the den revenge at `src/enemy.odin:2059`, which clears the map itself and says why [read] |
| Render read-only | **Holds as far as grep sees** | No state writes or mutator calls in `draw_*`. Local aliases are read-only by inspection of the grep, not line by line [ran]. `place_craft_pair` lives in `ui.odin` but is called from input and events, so it is fine [read] |
| Input never writes world | **Holds in release** | `set_tile` and HP writes at `src/input.odin:729-876` are all inside the `when GAME_DEBUG` at `:711` [ran] |
| Event-driven, no direct calls | **Not as written** | 274 cross-system call sites across 101 file pairs by my parser [ran]. `set_tile` is called from 16 files and `notify` from 22. `handle_tile_mined` is called directly from enemy and garm code at 4 sites, for a stated reason [read] |
| No switch sprawl | **Partly** | Terrain, items and machines are tables. Enemies are not (finding 5) |

Opinion: the event law as written has never matched the code. Most direct calls are queries or
helpers, and they are fine. Rewrite it to say what is actually enforced, so review can hold to it:
state owned by another system changes only through its own procs, and anything order-sensitive goes
through the queue.

### 10. Repo clutter (low)

Six save backups and `gnipa.spall` are tracked, about 19.7 MB. `*.dat` is ignored but `*.bak` is
not. The v14-v16 files cannot be loaded by any current path. [ran] They are real data, so moving
them is Glenn's call.

Largest files: `tests.odin` 12,922, `render.odin` 3,768, `ui.odin` 3,725, `enemy.odin` 2,482,
`golem.odin` 1,775. Opinion: `render` and `ui` are large but flat, so size alone is no reason to
split them.

## Recommended cards

In order. Cards 1-5 should come before card 64.

| # | Card | Why | Who |
|---|---|---|---|
| 1 | Save safety: keep a `.bak` of a rejected save, write through a temp file then rename, log the rejection | Finding 1. Small, and protects every later change | agent |
| 2 | Freeze a v28 path and add one real v28 golden file test, plus a test pinning enum ordinals | Finding 1 | agent |
| 3 | Slice playtest: one fresh seed to the cave 2 gate, timed, one line per annoyance, no new content landing until the list is read | Finding 2 | Glenn |
| 4 | Enemy behaviour table, inside card 64 or just before it | Finding 5 | agent |
| 5 | Real frame-time test: full `game_update` at 256, assert a p99 budget at `-o:speed` by counting work, since wall time here depends on box load; then the A* heap; budget golem searches | Finding 3 | agent |
| 6 | Name the build: choose the flags Glenn plays and ships with, and put them in docs and `agent_play.sh` | Finding 3 | Glenn decides |
| 7 | Decide: does a reload keep wave pressure? If yes, save it, with card 2's path | Finding 4 | Glenn decides |
| 8 | Guard the 8 tests with `when GAME_DEBUG` and add `odin test src -define:GAME_DEBUG=false` to the green rule | Finding 7 | agent |
| 9 | Pacing harness: card P14, time to Scroll B and 10 Gold Bars over 5 seeds, and keep the run data | Finding 2 | agent |
| 10 | Cut `context.md` to a real snapshot under about 20 KB, moving history to `Work_done.md`; fix the table in finding 8 | Finding 8 | agent |
| 11 | Point root `CLAUDE.md`, `AGENTS.md` and the `board-monitor` skill at the new board | Finding 8 | coordinator |
| 12 | Rewrite the event law to match practice | Finding 9 | Glenn agrees, agent writes |

Thin `update_input` into testable parts on the next change that touches it (finding 6); that needs no card of its own.
