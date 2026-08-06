# Architecture Findings — Gnipahellir3 (2026-08-06)

Review date: 2026-08-06. Scope: full architecture-law audit of `src/*.odin`
(~23,000 LOC, 41 files — up from ~7.7k LOC at the last review). 103 commits
landed since the prior `architecture_findings.md` (2026-07-05, now deleted as
superseded — its "can this architecture carry a machine chain?" question is
answered: yes, and the machine layer it recommended (smelter/sim, dimensions,
silo, Auto-Miner, Clay Golems) is now built and shipped).

**Verdict up front: the architecture is healthy.** Every mandatory rule in
CLAUDE.md holds under the newest and largest system built to date
(`golem.odin`, 1,661 lines, the Clay Golem automation slice). Findings below
are all minor drift — misfiled procs, a couple of switches that want to be
tables, one undocumented design gap — nothing that threatens a rewrite or
blocks further building. No CRITICAL or 🔴-tier findings.

Method: build + full test run verified directly; four parallel sub-agent
audits each swept a different rule cluster against the current codebase
(compliance/fixed-arrays/tables, module call-discipline, event-system +
entity-map + update-order, save-versioning + `golem.odin` health).

> **STATUS 2026-08-06 (same-day fix pass):** ✅ all four P1 items closed —
> camera logic moved out of `render.odin` into new `camera.odin`;
> `golem_nav_tile`/`notify_reclaim_block` converted from switches to tables;
> append-only comments added to `Enemy_Kind`/`Garm_Phase`/`Dimension_Kind`/
> `Golem_Mode/Status/Job/Plan` (and `Station`, corrected to note it isn't
> actually saved); `build_templates`'s exception comment cross-references its
> three `golem.odin` siblings. Build clean, 189/189 tests green, save size
> unchanged. P2 (golem combat-exposure) also decided same day — Glenn said
> **no**, golems stay undamageable by Builders/Garm; documented in
> `context.md`, zero code change. P3 also closed same day —
> `golem_update_one`'s duplicated recovery/replan logic factored into
> `golem_recover_or_replan`, verified bit-for-bit soak-test identical
> pre/post; the two borderline switches re-checked and deliberately left as
> switches. **Nothing outstanding from this review.**

---

## 0. Build & test baseline

```
odin build src            → clean, zero errors
odin test src -all-packages → 189/189 tests green, 2.1s
save_data_size_probe: size_of(Save_Data) = 3,171,464 (expected 3,171,464)
```

Save version has climbed **v12 → v23** since the last architecture review
(12 bumps across 103 commits) — every bump paired with the size `#assert` in
the same commit, per the required discipline (verified in §3).

---

## 1. Fat struct / fixed arrays / table-driven — compliant, minor table-vs-switch drift

- **Fat struct: compliant.** No untyped/uninitialized mutable package-scope
  state. Every package-scope `:=` is either an `@(rodata)` table or one of
  four documented slice-initializer exceptions (see below).
- **Fixed-size arrays: compliant.** Zero `[dynamic]` or `append(` anywhere in
  `src/*.odin` — confirmed by full-repo grep. Holds under the golem system's
  worker packs, cargo, and recovery state (all fixed-size fields on `Golem`).
- **Table-driven behavior: minor drift, two new switch-sprawl instances.**
  - `golem.odin:141-160` `golem_nav_tile` — a 16-case `#partial switch` on
    `Item` mapping a placed item to its nav tile. Structurally identical to
    existing `@(rodata)` tables (`item_table`, `dimension_spawner_tile`).
    Should be a `[Item]Tile_Type` table.
  - `reclaim.odin:109-121` `notify_reclaim_block` — a 10-case switch that's
    pure `Reclaim_Block → cstring` message lookup, no logic. Directly
    analogous to `station_title` (already `@(rodata)`). The clearest
    should-be-a-table case in the new code.
  - Borderline, not flagged as violations: `golem.odin:640-651`
    `golem_resource_priority` and `reclaim.odin:34-49/79-101`
    (`structure_interact`, `structure_reclaim_block`) dispatch genuinely
    different side effects per tile kind, not pure data — closer to
    legitimate control flow. Worth a second look only if they keep growing.
- **Enums append-only: compliant, with a documentation gap.**
  `types.odin`'s save-critical enums (`Tile_Type`, `Item`, `Equip_Slot`,
  `Event_Type`) all carry explicit "appended: order is frozen" comments at
  every addition, through the newest golem entries. `git log --follow -p`
  confirms `Enemy_Kind`'s slightly odd order (Garm, Undead, Fire_Sprite,
  Builder) was introduced whole in one commit, never reordered — not a bug.
  **Gap:** newer non-`types.odin` save-embedded enums (`Enemy_Kind`,
  `Golem_Mode`/`Status`/`Job`/`Plan`, `Dimension_Kind`, `Station`,
  `Garm_Phase`) are memcpy'd into `Save_Data` just like the `types.odin` ones
  but lack the same "append-only" comment discipline. No evidence of an
  actual reorder — just missing guardrail comments for future editors.
- **The `build_templates` exception has quietly grown to four.**
  `enemy.odin:106-109`'s `build_templates` (non-`@(rodata)` because slice
  initializers can't be constant) was the one documented exception. Three
  more of the same shape now exist: `golem.odin:37,47,61`
  (`HEARTH_CELLS`/`DEPOT_CELLS`/`ANCHOR_CELLS`) and `golem.odin:76`
  (`golem_plan_table`) — same legitimate reason, just never added to the
  exception list. Not a violation; a paperwork gap.

## 2. Module call-discipline — compliant, one file-boundary drift

- **`render.odin` / every `draw_*` proc: minor drift.** All 44 `draw_*` procs
  in `render.odin` and all 29 in `ui.odin` are provably read-only — zero
  `gs.*` mutation, zero calls to update/input procs. **But two non-`draw_*`
  procs physically live in `render.odin` and mutate `Game_State` directly:**
  `camera_snap_y` (render.odin:104-109) and `update_camera`
  (render.odin:116-148), writing `gs.cam_y`, `gs.cam_pan`, `gs.zoom`,
  `gs.zoom_cursor_active`, `gs.player_step_visual_y`. `update_camera` is
  correctly called from the update loop (`update.odin:27`, step 2b) — the
  *sequencing* is fine — but its mutating logic sits in a file whose whole
  point is "never mutates," which undermines the boundary for the next
  reader who greps `render.odin` expecting read-only. Should move to
  `update.odin` or a new `camera.odin`.
- **`input.odin`: compliant.** Zero direct writes to `World_Grid` or entity
  fields outside the one deliberate exemption (inventory-slot selection,
  input.odin:351/355/380). The debug-menu writes (`set_tile`,
  player hp/mana resets, input.odin:588/624-625) remain fully contained
  inside `when GAME_DEBUG` — the accepted A3 exception from the 2026-07-18
  audit, still gated, not regressed.
- **Sim files (`world`, `enemy`, `golem`, `draugr`, `garm`, `miner`, `sim`,
  `gravity`): compliant.** Zero `draw_*` calls, zero `rl.Draw*`, zero input
  polling in any of them. `golem.odin` — the highest-risk file at 1,661
  lines — imports only `core:math`; it can't call raylib even by accident.
- **`types.odin` / `game_state.odin`: compliant.** `types.odin` defines zero
  procs. `game_state.odin` has exactly two — `new_game_world_seed` and
  `game_state_init` — both plain init/constructor logic, no gameplay
  decisions.

## 3. Event system, entity map, update order — healthy, one design gap worth deciding

- **Event queue saturation: healthy.** `MAX_EVENTS :: 512`, drop-with-
  telemetry intact (`eq.dropped`, surfaced via a `WARNING` log each frame,
  `update.odin:96-100`) — the fix from the 2026-07-18 audit (A1-adjacent) has
  not regressed. The guidance from the *last* architecture review — "machine
  state changes are direct writes; events are only for audio/UI/particles" —
  held under the golem build: `golem.odin` pushes from exactly **two**
  `eq_push` sites total (a smelter-style completion sound and a mining-
  completion sound), both gated by per-worker action completion, not a
  per-tick/per-item loop. Worst case with `MAX_GOLEMS :: 15` is ~15
  events/frame — nowhere near the 512 cap. `sim.odin` has one `eq_push`
  (gated by smelt completion); `gravity.odin`/`miner.odin` push zero events
  per tick. Combat events (enemy/draugr/garm) are all rate-limited by attack/
  mine timers, so even `MAX_ENEMIES :: 64` can't flood the queue in one
  frame.
- **Entity-map discipline: minor drift — one real, likely-deliberate gap.**
  `enemy_free` has exactly two call sites (the pre-existing spawn-abort
  exception at enemy.odin:698, and inside `despawn_enemy` itself at
  enemy.odin:727) — no new bare calls in `golem.odin` or `draugr.odin`.
  Draugr correctly reuse the ordinary enemy pool and `entity_map`
  (`draugr.odin:34,100`). **Golems, however, never touch `entity_map` at
  all** — they live in their own `[MAX_GOLEMS]` pool, referenced by slot
  index rather than `Entity_ID`, found only via a bespoke scan
  (`nearest_deployed_golem`, golem.odin:297) called exclusively from
  `update_undead` (draugr.odin:76). **Practical consequence: ordinary
  Builders and Garm are structurally incapable of ever attacking a deployed
  golem — only Draugr can.** This lines up with `den_protected` also
  shielding golem work from builder interference, so it reads as deliberate
  scope-limiting rather than an oversight — but it's undocumented as a
  decision, and it's exactly the gap `ideas.md`'s enemy-roster brainstorm
  already names: *"nothing threatens your machines... the long arc is
  automation, but a base you never defend has no stakes."* Worth an explicit
  yes/no from Glenn rather than leaving it implicit.
- **Update-order determinism: healthy.** `game_update` matches context.md's
  documented order exactly (1 input → 2 player → 2c clay golems → 3 enemies
  → 4 projectiles → 5 mining → 5a reclaim → 5b sim → 5b2 miner → 5c
  station-focus → 5d recipe-unlocks → 5e ritual → 6 process_events → 6b
  gravity → 7 notifications → 8 ambience → 9 particles → 10 audio). Two
  extra numbered sub-steps exist beyond context.md's one-line summary (2b
  camera, 9b floating text) — both carry explicit numbered comments in code
  and are documented elsewhere in context.md's prose, so this is summary
  compression, not implicit ordering.

## 4. Save versioning & the golem system — healthy

- **Save versioning: healthy.** `SAVE_VERSION :: i32(23)` and the size
  tripwire `#assert` are both present and live, backed by the
  `save_data_size_probe` test that logs the real size every run (confirmed
  above: matches exactly). The v22→v23 migration is structurally sound —
  loads the old `Golem_v22` shape (missing `pack`/`recovering`/
  `recover_from`), field-copies it into the current `Golem`, and correctly
  zero-defaults the new fields rather than dropping data; dead-player and
  version-mismatch saves both reject cleanly to a fresh run, as documented.
  Autosave debounce (`SAVE_DEBOUNCE :: f32(5)`, main.odin:73-78) is intact
  and not regressed — the fix for the old A2 finding (2.6MB alloc + blocking
  write on every mined-tile frame) is holding at ~3.17MB now, still
  debounced to at most once per 5s.
- **`golem.odin` health: healthy, better-organized than it looks.** 1,661
  lines sounds large, but it's 96 procs averaging ~17 lines/proc — more
  decomposed than `enemy.odin`'s builder AI (46 procs, ~33 lines/proc
  average). Its largest proc, `golem_update_one` (128 lines, the per-golem
  per-frame state machine), is less than half the size of `enemy.odin`'s
  largest (`astar_dig`, 298 lines). Zero dynamic allocation. All state lives
  inside `Game_State` via `Golem_System` — nothing leaked outside the fat
  struct. Named constants throughout, no bare magic numbers in the control
  flow reviewed. One small smell: `golem_update_one` inlines the same
  3-branch "target below reach → recover, else replan" logic twice
  (golem.odin:1518-1531 and 1562-1573) rather than factoring a helper —
  single-proc-local duplication, low severity.
- **TODOs / dead code: healthy.** Zero `TODO`/`FIXME`/`XXX`/`HACK` markers
  anywhere in `src/*.odin`. Spot-checked several less-obviously-called procs
  (`debug_golem_deploy`, `golem_hearth_use`, `golem_crew_toggle`) — all have
  live call sites and test coverage.

---

## Priority order (recommended)

**P1 — cheap, mechanical, do whenever convenient:** ✅ **all fixed 2026-08-06**
1. ~~Move `update_camera`/`camera_snap_y` out of `render.odin`~~ — **done.**
   Both procs plus `game_camera` and every zoom/deadzone constant moved to a
   new `camera.odin`; `render.odin` no longer mutates `Game_State` anywhere.
   Pure move, `game_update`'s step 2b call site unchanged.
2. ~~Convert `golem_nav_tile` and `notify_reclaim_block` from switches to
   tables~~ — **done.** `golem_nav_tile_table` (`#partial [Item]Tile_Type`,
   Odin still requires `#partial` on array literals same as switches) and
   `reclaim_block_message` (`[Reclaim_Block]string`) replace both switches;
   each proc is now a one-line table lookup.
3. ~~Add the append-only comment convention to non-`types.odin` save-embedded
   enums~~ — **done**, with one correction found along the way: `Station`
   turned out to **not** be saved at all (it only lives in transient
   `UI_State`, which `Save_Data` never includes) — the comment there notes
   that instead of falsely claiming save-format stability. `Enemy_Kind`,
   `Garm_Phase`, `Dimension_Kind`, and `Golem_Mode/Status/Job/Plan` were all
   confirmed genuinely memcpy'd into `Save_Data` before their comments were
   written.
4. ~~Note the three new `golem.odin` slice-initializer globals alongside
   `build_templates`~~ — **done** in both directions: `enemy.odin`'s
   `build_templates` comment now cross-references `golem.odin`'s three
   siblings, and `golem.odin`'s `HEARTH_CELLS` carries a matching note.

Verified: `odin build src` clean, `odin test src -all-packages` 189/189 green,
`save_data_size_probe` unchanged (all four fixes are comment/reorganization/
table-conversion only — no saved struct touched, no `SAVE_VERSION` bump
needed).

**P2 — a design decision, not a bug fix:** ✅ **decided 2026-08-06 — "no"**
5. ~~Decide whether golems should be attackable by Builders/Garm~~ — **Glenn's
   call: no.** Golems stay outside `entity_map`, undamageable by anything but
   Draugr, as before. Zero code change — documented as deliberate in
   `context.md`'s "Deliberate stubs (don't file as bugs)" section, alongside
   the reasoning (mirrors `den_protected`; automation-base defense is meant
   to arrive later as a dedicated enemy per `ideas.md`, not by teaching
   existing AI new targets). Nothing to verify — no `.odin` files touched.

**P3 — optional polish, low severity:** ✅ **closed 2026-08-06**
6. ~~Factor `golem_update_one`'s duplicated recovery-transition branch into a
   helper~~ — **done.** Extracted `golem_recover_or_replan(gs, g,
   reset_replan_timer: bool)`: both call sites (the replan-timer trip and the
   stale-path check) now call it, differing only in the bool that reproduces
   the one real difference between the two original blocks (whether
   `replan_timer` gets cleared). `golem_update_one` shrank from 128 to ~110
   lines. Verified behavior-preserving, not just build-clean: with the fixed
   default world seed, the soak tests (`garm_fight_soak`,
   `builder_surface_soak_no_pingpong`, `builder_soak_cave2_economy`) produced
   **bit-for-bit identical** numbers before and after (same fight duration,
   same hit counts, same fetch-trip counts) — as strong a confirmation as a
   headless suite can give that this was a pure refactor.
7. ~~Watch `golem_resource_priority` / `reclaim.odin`'s structure-interact
   switches~~ — **re-checked, left alone.** Both are unchanged since the
   original audit and still dispatch genuinely different side effects per
   tile kind rather than being pure data lookups — converting them now would
   be speculative churn against the audit's own "only if they keep growing"
   call, and CLAUDE.md's simplicity-first rule. Nothing to do.

Verified (P3): `odin build src` clean, `odin test src -all-packages` 189/189
green, identical soak-test output pre/post refactor, save size unchanged.

---

**All architecture-review findings from this pass (P1/P2/P3) are now
closed.** Nothing outstanding from the 2026-08-06 review.

---

## Bottom line

Nothing here blocks further building. The architecture absorbed a
1,661-line autonomous-agent system (arguably the hardest kind of feature to
keep disciplined — stateful, per-tick, many interacting workers) without a
single fixed-array violation, without event-queue saturation, and without
render/input boundary breaches in the new code. The handful of findings are
the ordinary residue of fast iterative development (a couple of switches
that outgrew being switches, one file that gained two procs that don't
belong there) plus one genuine design question (golem combat exposure) that
was always going to need a human call, not a code fix. Keep building; clear
the P1 list opportunistically, decide P2 when defense/automation-stakes come
up next.

*Compiled from a direct build+test verification plus four parallel
sub-agent audits (compliance/tables, module call-discipline, event+entity-
map+update-order, save+golem-health), 2026-08-06.*
