# Threat-Driven Wave Director — the real trigger replaces the craft hack

## Context

The wave system (task #164) shipped with a TESTING trigger: every Fire Wand
craft armed one wave in a blind Air → Ground → Underground cycle. That trigger
did its job — waves are playtested, the flyer steering is fixed (#166, `eaad54d`),
and Glenn has called time on it: *"we are done with the tests and need to move
away from the craft wand debug trigger."*

**The design Glenn confirmed (2026-08-29):** a **threat score** system — the
base itself draws the waves, so the start is calm *because* an early base has
almost no threat, not because a timer was set generously. Plus: **scripted
milestone triggers stay** — *"we will also keep the triggers for stuff like
finishing portals and stuff."* The one-line `pending` hook was designed for
exactly this day (`events.odin:208-211` says so in its own comment).

The model is the proven raid director (`update_raids`, `enemy.odin:926-996`):
pressure → warning → spawn → cooldown, transient state, no-stack guard,
progression gate. The wave director becomes its sibling, reading the whole
base where raids read one hot machine.

Decisions locked with Glenn: threat score (not a timer); scripted triggers kept
alongside it; craft trigger deleted. Numbers below are **first-guess, Glenn
tunes in playtest** — flag anything that feels off rather than silently retuning.

All paths under `Gnipahellir3\`. House rules: each commit standalone green
(`odin build src` + `odin test src`, **321** currently green), save probe
`#assert` 3_171_512 at `save.odin:24-25` must not fire (everything here is
transient state — if it fires, stop and redesign). No gen-file edits in this
plan, so no emit-check needed.

**Board protocol (before any edit):** this work is **board task #167**. Check
in on http://127.0.0.1:7666 as `claude-opus-threat-<4 hex>` (status post, NO
`files` — the task carries the claims), `GET /tasks`, read #167's current
`rev`, `claim` with that rev. `renew` before long quiet stretches. On
completion post your write-up, then `submit` with `result_seq` = that post's
seq. Do NOT commit this plan file. Commit only the task's listed files via
`git commit -- <paths>` (shared index — never bare `git commit`, never
stash/reset).

---

## Commit 1 — the threat-driven director

Files: `src\game_state.odin`, `src\wave.odin`, `src\events.odin`, `src\tests.odin`

- **State** (`game_state.odin:154-157`, `Wave_State` grows — still transient,
  still zero save impact; the comment there already explains why):
  ```odin
  Wave_State :: struct {
      pending:        bool,      // a scripted trigger fired (commit 2 sets it)
      pending_kind:   Wave_Kind, // which wave the script asked for
      cycle:          int,       // how many pressure waves have been sent
      threat:         f32,       // cached base score, rescanned on a slow beat
      threat_timer:   f32,
      pressure:       f32,       // threat-seconds accumulated toward the next wave
      warning_timer:  f32,
      warning_active: bool,
      warning_kind:   Wave_Kind, // decided when the warning arms, not at spawn
      cooldown:       f32,
  }
  ```
- **Constants** (`wave.odin`, beside the table): `WAVE_PRESSURE_TARGET :: f32(1200)`
  (threat-seconds), `WAVE_WARNING_TIME :: f32(25)` (longer than the raid's 10 —
  the telegraph is the engagement; time to run home, check the lasers, wield
  the wand), `WAVE_COOLDOWN :: f32(90)` (floor between pressure waves),
  `WAVE_THREAT_RESCAN :: f32(2)`, tier gates `WAVE_TIER_AIR :: f32(20)`,
  `WAVE_TIER_UNDER :: f32(40)`.
- **`wave_threat(gs) -> f32`** (`wave.odin`): full-grid scan of `gs.world` —
  run ONLY on the 2 s rescan beat, never per frame (raid finding #6 is the
  parked lesson: `raid_heat_target`'s per-frame full-grid scan is already a
  known smell; do not add a second one). Score: every `is_structure_tile`
  counts **1**, overridden by a `#partial [Tile_Type]f32` weight table:
  **machines 3** (`.Smelter .Boiler .Steam_Engine .Magic_Kettle .Mana_Wheel
  .Gem_Replicator .Auto_Miner .Dvergr_Forge`), **`.Rainbow_Laser` 2** (defense
  is wealth too — RimWorld's lesson, and it self-balances turret spam). Add
  **+5 per `gs.progression.rune_scroll_found[tier]`** — the world's danger
  rises as you progress, even for a lean base. The threat is honest: what
  draws the wave is exactly what the wave comes to smash.
- **`update_waves` rewritten** (director, still step 5b1a in `update.odin` —
  order unchanged, no `update.odin` edit):
  1. Tick `cooldown` down. **Off-surface: early-out, everything holds frozen**
     (pending's existing hold semantic, now covering the whole director —
     hiding in a cave delays the wave, never dodges it; deliberately softer
     than raids' hard reset, because threat is the whole base, not one fire).
  2. Rescan threat on the beat.
  3. **No-stack guard:** extract the `debug_wave_clear` predicate
     (`wave.odin:85-86`: `.Fire_Sprite`, `.Vargr`, `.Raider` with
     `.Wave_Hunt`) into a shared `is_wave_enemy(e) -> bool` used by both; if
     any is alive and no warning is armed, pressure holds (raids'
     `raiders_present` idiom, `enemy.odin:941-949`).
  4. **Warning armed:** tick `warning_timer`; at zero, `wave_force(gs,
     warning_kind)`, then `cycle += 1`, `pressure = 0`, `cooldown =
     WAVE_COOLDOWN`, clear the warning. No cancel path — unlike a raid you
     cannot quiet the base down mid-warning, and mining your own bench to
     dodge a wave is not a game we reward.
  5. **Pending (scripted):** if `pending`, arm the warning with
     `pending_kind` immediately — ignores pressure, cooldown AND tier gates
     (a scripted wave is a designed moment), clears `pending`.
  6. **Pressure:** `pressure += threat * dt` (threat 0 → eternal peace: the
     grace gate IS the score — no bench, no waves, nothing to hunt anyway).
     At `WAVE_PRESSURE_TARGET` with `cooldown <= 0`: pick the kind — walk
     `cycle` through the UNLOCKED kinds only (Ground always; Air at threat ≥
     `WAVE_TIER_AIR`; Underground at threat ≥ `WAVE_TIER_UNDER` **and**
     `rune_scroll_found[0]`, raid parity `enemy.odin:932`) — arm
     `warning_kind`, `warning_timer = WAVE_WARNING_TIME`, notify **"A howl
     rises beyond the treeline - something comes for your works!"** +
     `Builder_Shriek` + `log_action` the threat/pressure numbers.
- **Wave size scales with threat** (`wave_force` gains the scale, single
  formula both directions):
  `count := clamp(int(f32(spec.count) * (0.5 + threat/40)), 1, spec.count*2)`
  — a bench-and-barrel base (threat ~3) gets **1 Vargr**, the table count
  arrives around threat 20, a machine empire (threat 60+) gets double. The F4
  debug rows pass the table count unchanged (scale 1) so forced waves stay
  reproducible.
- **Delete the craft trigger**: `events.odin:208-211` (the comment block +
  the `.Fire_Wand` line). The Fire Wand TESTING recipe itself stays for now —
  reverting it to Plank 2 + Iron Ore 2 + Emerald 1 is a separate ask Glenn
  makes when wave tuning is done (it is his main test weapon; see plan_enemy_waves.md commit 1 for the revert shape).
- **Tests** (the old `crafting_fire_wands_cycles_air_ground_underground_waves`
  dies with its trigger — REWRITE it, don't strand it):
  - `a_bare_start_draws_no_waves` — no structures, long simulated run,
    pressure stays 0, zero spawns.
  - `the_base_you_build_draws_the_wave` — seed bench + smelter on the surface
    (`wave_clear_structures` first, `tests.odin:9484` idiom), step past
    rescan + pressure target, assert warning arms with notify, wave lands
    only after `WAVE_WARNING_TIME`, cooldown then holds the next one.
  - `threat_tiers_gate_the_wave_kinds` — low threat cycles Ground only; stack
    machines past `WAVE_TIER_AIR` and Air joins the cycle; Underground
    refuses until `rune_scroll_found[0]` even past its tier.
  - `wave_size_grows_from_the_threat` — threat ~3 spawns 1 Vargr; threat ~60
    spawns double the table.
  - `survivors_hold_the_next_wave` — a live Vargr on the field freezes
    pressure (the no-stack guard).

## Commit 2 — scripted milestone triggers (Glenn: "finishing portals and stuff")

Files: `src\wave.odin`, `src\events.odin`, `src\garm.odin`, `src\tests.odin`

- **`wave_trigger :: proc(gs: ^Game_State, kind: Wave_Kind)`** (`wave.odin`):
  sets `pending + pending_kind` — THE one-line hook for any future scripted
  moment. It rides the same warning machinery, so a scripted wave is
  announced like any other; it just doesn't wait for pressure.
- **Wire two, as the proof of the path** (more milestones are one-line edits
  later, which is the entire point of the design):
  - `handle_place_request` (events.odin, the point the tile lands): a placed
    `.Dimension_Spawner` / `.Dimension_Spawner_Gold` / `.Dimension_Spawner_Runic`
    → `wave_trigger(gs, .Underground)` + notify ("The ground shudders as the
    portal takes hold...") — finishing a portal is loud, and the underground
    answers.
  - `garm_open_hell_gate` (`garm.odin:160`): → `wave_trigger(gs, .Air)` —
    fire sprites pour out with the gate. Thematic: Hell opens, its embers
    scatter.
- **Tests:**
  - `a_scripted_trigger_ignores_pressure_and_gates` — zero threat, zero
    scrolls, `wave_trigger(.Underground)` → warning arms → wave lands after
    `WAVE_WARNING_TIME`.
  - `placing_a_portal_summons_the_underground` — drive the real
    `Place_Request` event with a spawner item, assert `pending` armed.

## Commit 3 — the F4 readout (tuning eyes)

Files: `src\ui.odin`, `src\tests.odin` (only if a draw-free assert is practical)

- One line in the F4 raid/wave menu header: `threat 23  pressure 41%  cooldown 12s`
  (read-only from `gs.wave`, render rules apply — no state writes). This is
  what lets Glenn SEE why a wave came when it came; without it every tuning
  session starts with "why now?".

---

## Verification (end-to-end)

1. Per commit: `odin build src` + `odin test src` green standalone (throwaway
   worktree OUTSIDE the repo, house precedent).
2. Save probe 3_171_512 untouched (all transient — if it fires, redesign).
3. Manual playtest script for Glenn: fresh world → mine, build bench + barrel
   → note the long quiet (~7 min at threat ~3) → one Vargr with a 25 s howl
   warning → add smelter + lasers and watch F4 threat climb + gaps shrink →
   place a Dimension Spawner → immediate Underground warning regardless of
   the meter → find scroll A → Underground joins the pressure cycle.
4. Update `context.md` + board `submit` at session end.

## Risks / notes

- **Every number is first-guess**: 1200 target, 25 s warning, 90 s cooldown,
  weights 3/2/1, +5/scroll, tier 20/40, the size formula. The F4 readout
  (commit 3) exists so tuning is observation, not archaeology.
- **Threat scans `gs.world`** — the active grid. The director only runs on
  LEVEL_SURFACE frames, so it always scores the surface base. Structures on
  other levels are invisible to it (fine: waves can't reach them either).
- **The no-cancel warning is deliberate** — revisit only if playtest shows
  Glenn *wanting* a counter-action; the raid already owns that verb.
- **Pending survives reload as nothing** (Wave_State transient) — a scripted
  wave lost to a reload mid-warning is acceptable, same contract as raids.
- The old craft-cycle test must be rewritten in the same commit that kills
  the trigger, or the suite goes red between commits — watch the split.
