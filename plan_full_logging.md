# Full-Coverage Action Logging — "log ALL actions and happenings"

## Context

Glenn's ask after the wave playtest: the action log answered *some* questions (the
Fire Wand craft → AIR wave trigger and the wand kills were all visible) but not
others — two fire sprites spawned at the right map edge and vanished from the
record for 63 s; player mining/placing left zero trace; damage lines don't say
what hit; deaths are implicit ("hp -2"). The game is a deterministic 2D grid —
Glenn wants the log to capture **all actions and all events/happenings** so any
run is fully reconstructable after the fact.

Current state (`src\debug_log.odin`): `log_action` writes into a fixed 256 KB
buffer that **stops logging when full** (drops, sets `overflow`), flushed to
`action.log` every 5 s (`update.odin:131-133`) by rewriting the whole file, plus
on exit (`main.odin:87`) and on save/load (`save.odin:282,317`). `GAME_DEBUG`
compiles it in by default (`types.odin:5`).

House rules apply: each commit standalone green (`odin build src` + `odin test
src`, **317 currently green**), save probe 3_171_512 untouched (nothing here goes
near `Save_Data` — `Debug_Log` lives outside it; verify that stays true), render
stays read-only, table-driven over switch sprawl.

**Board protocol (before any edit):** this work is a board task (id in the task
list — text starts "Full-coverage action logging"). Check in on
http://127.0.0.1:7666 as `claude-opus-logging-<4 hex>` (status post, NO `files`
— the task carries the claims), `GET /tasks`, read the task's current `rev`,
`claim` with that rev. `renew` before quiet stretches. On completion post your
write-up, then `submit` with `result_seq` = that post's seq. Commit only via
`git commit -- <paths>` (shared index — never bare commit, never stash/reset).
Do NOT commit plan_full_logging.md or plan_enemy_waves.md (both untracked).

---

## Commit A — streaming log core (never drops, never clobbers a playtest log)

Files: `src\debug_log.odin`, `src\game_state.odin` (only if a path/offset field
is needed on `Debug_Log` — it is NOT in Save_Data, confirm), `src\update.odin`,
`src\main.odin`, `src\tests.odin`

- **Flush appends and clears**: `flush_action_log` opens the log file in
  append/create mode, writes `buf[:pos]`, closes, sets `pos = 0`. The file grows
  across the run; the buffer never fills up across a run.
- **Run header**: at game start (where the first log becomes possible —
  game_state init or main before the loop) truncate the file and write a header
  line: datetime, `SAVE_VERSION`, and the world seed **if one exists** in
  `Game_State` (check; the gen hash `whash` may be seedless — skip if so).
  Loading a save mid-session logs a `"=== load ==="` line rather than truncating.
- **Auto-flush on pressure**: in `log_action`, when `pos >= DEBUG_LOG_CAP - 512`
  call the flush instead of dropping. Retire `overflow` (remove the field only
  if nothing else reads it — grep first).
- **Tests must not clobber `src\action.log`** (it is Glenn's playtest ground
  truth): make the target path a `Debug_Log` field or proc parameter defaulting
  to `"action.log"`; the test points it at a scratch filename and deletes it
  after. `odin test src` runs in the repo — this is the one hazard in this
  commit, treat it as a hard requirement.
- Test: `the_action_log_streams_instead_of_dropping` — against a scratch path,
  write well past `DEBUG_LOG_CAP`, assert nothing was dropped (file size ≥ bytes
  written) and `pos` reset. Verify it FAILS against the old drop behavior.

Verify: build, tests, and confirm `src\action.log` untouched by the suite.

## Commit B — world actions + attribution + deaths

Files: `src\events.odin`, `src\placement.odin`, `src\sim.odin`, `src\loot.odin`,
wherever item pickup enters the inventory (find it — likely `player.odin` or
`items.odin`), `src\tests.odin`

- **`handle_tile_mined`** (events.odin:484+): one line per successful mine/smash
  naming the actor — `"Player mines Stone at (x,y)"` / `"Enemy#3(Fire_Sprite)
  smashes Crafting_Bench at (x,y)"` — from `e.source`. This single hook covers
  player mining AND all enemy demolition (including the direct handler calls
  from raiders/sprites that bypass the event queue). Keep the existing bespoke
  flavor lines (tunneller/sprite) — they add intent, this adds ground truth.
  Also log the refusal branches ("mine refused: loaded silo at (x,y)").
- **`handle_place_request`** success path (placement.odin:173-183):
  `"Player places <Tile> at (x,y)"`.
- **Pickups**: at the point items enter the player inventory from the ground:
  `"Player picks up <Item> x<N> at (x,y)"`.
- **Damage attribution**: events.odin:94 → `"Enemy#%d takes %d damage from %s
  (hp %d)"` where %s names the source entity ("Player" / "Enemy#j(kind)");
  same for the player-damage line at :67. A tiny helper
  `entity_name(gs, id) -> string` (into a caller buffer) keeps it one place.
- **Explicit deaths + loot**: where enemy death resolves (Entity_Died handling /
  despawn on hp<=0): `"Enemy#%d (%v) dies at (x,y)"`; in the loot drop code log
  what actually dropped: `"Enemy#%d drops <Item> x<N>"`.
- **Laser attribution**: `tick_rainbow_laser` (sim.odin): `"Laser at (x,y) zaps
  Enemy#%d for %d"` — distinguishes laser hits from wand hits (both arrive as
  source = PLAYER_ID).
- Test: `a_smashed_bench_logs_its_killer` — enemy-sourced handle_tile_mined on a
  bench, assert the log buffer contains the attributed line (search
  `gs.debug_log.buf[:pos]`). Cheap and pins the attribution plumbing.

## Commit C — event trace + breadcrumbs + wave cycle

Files: `src\events.odin`, `src\update.odin` (or a proc in `debug_log.odin`),
`src\wave.odin`, `src\tests.odin`

- **Event trace — the "all happenings" net**: in `process_events`, one compact
  line per event: `"evt <Type> src=%d tgt=%d tile=(%d,%d) val=%d"`, gated by a
  `@(rodata) event_log_skip := #partial [Event_Type]bool` exclusion table
  (table-driven, house style) listing ONLY pure audio/visual noise —
  `.Play_Sound` and any particle/fx-only event types. Everything else logs, even
  types with no bespoke line. Comment on the table: direct handler calls bypass
  this trace and are covered at handler level (Commit B).
- **Breadcrumbs every 5 s**: piggyback the existing 300-frame flush block in
  `update.odin:131-133` — immediately before the flush, write one line per live
  body: `"pos Player (%.1f,%.1f) hp=%d mana=%.0f"` and for every active enemy
  `"pos Enemy#%d %v (%.1f,%.1f) hp=%d goal=%v target=(%d,%d)"` (goal/target from
  `e.builder`). Worst case 65 lines per 5 s — negligible streamed. This is what
  makes a stuck/wandering flyer (the #4/#6 mystery) visible.
- **Wave cycle state**: `update_waves`/`wave_force` logs the cycle on each
  trigger: `"wave cycle %d -> spawning %s, next %s"`.
- Test: `the_event_trace_logs_what_the_queue_processed` — push a couple of
  events (one skipped kind, one logged kind), run process_events, assert the
  logged one is in the buffer and the skipped one is not.

---

## Verification (end-to-end)

1. Per commit: `odin build src` + `odin test src` green standalone (throwaway
   worktree outside the repo). No gen files touched — no emit-check needed.
2. Save probe `#assert` untouched (Debug_Log must stay outside Save_Data).
3. Confirm the test suite leaves `src\action.log` exactly as it was (hash it
   before/after the suite).
4. Smoke: `odin run src` briefly (if practical) or rely on Glenn's next
   playtest; the acceptance smoke is: header line present, mining/placing lines
   appear, 5 s breadcrumbs appear, file grows past 256 KB without loss.
5. Update `Gnipahellir3\context.md` with a dated bullet (2026-08-28), commit it
   with the last commit.

## Risks / notes

- **The one real hazard**: tests writing the real `action.log`. The scratch-path
  requirement in Commit A is load-bearing — verify with a before/after hash.
- Log volume: builders are chatty; the event trace multiplies lines. Streamed
  appending makes this a disk-space non-issue; do NOT add throttling or
  sampling — Glenn explicitly wants everything.
- `fmt.bprintf` into the fixed buffer is the existing pattern — keep it; no
  dynamic allocation in the log path.
- Determinism/replay (same seed + input → same log) is a natural follow-up but
  explicitly OUT of scope here.
