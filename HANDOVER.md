# Handover — session 2026-07-05 (Phase 5 complete + mining rework)

**Baton pass:** the last commits (Phase 5 M4/M5 + the mining rework) were
Fable's work. **Opus takes over the project from today, 2026-07-05.**

For the next session. Read `Plan.md` (roadmap), `Gnipahellir3/CLAUDE.md`
(architecture rules — mandatory), `Gnipahellir3/PLAYTEST.md` (controls),
`opus.md` (Fable's working notes on Glenn). Verify every change:
`odin build src` + `odin test src` from `Gnipahellir3/` (40 tests, ~2s; if the
game is running, add `-out:src_test.exe` or the linker can't write src.exe).
Commit per verified milestone.

## Done this session (all on master, tree clean)

**Phase 5 — Garm final boss: COMPLETE (M4 + M5)**
- M4: Garm AI — chases via `builder_travel`/`astar_dig` (reused, not
  reinvented) + a "smash" rule carving the extra clearance his 1.6×1.8 body
  needs through 1-tile corridors; fireballs via `spawn_projectile` (die on
  solid tiles, so cover works with no LOS test); G2's project phases as boss
  mechanics on hp thresholds: Chase → Column (≤20) → Ring (≤10) → Flood.
  Structures channeled at range, one tile/tick, all mineable stone. Lava's
  `damage_per_second` finally wired to the player.
- M5: Win — Garm dies → Hell_Key drops where he stood → pickup fires
  Boss_Defeated + Game_Won → win screen (run time, kills, runs won);
  runs_won++ persisted immediately; a won run clears the save on quit.
- `garm_fight_soak` (60s simulated fight) is a permanent test.

**Mining rework — COMPLETE + Glenn approved the feel**
- Replaces old click-at-range-5. Start with a Pickaxe: aims by rough cursor
  DIRECTION not exact tile (8-way, wide 45° horizontal band, forward carves
  head+feet rows), adjacent only, 3 chips/tile, free.
- Bench-crafted wand ladder Mine_Wand(2) → Silver(4) → Gold(8): keeps precise
  cursor aim, each tier consumes the previous, 5 mana/shot from a 100 pool,
  G2-style spark stream with delayed impact.
- F1 debug menu row 2: Ultra wand cheat (13-tile, free, 3×3 blast impact).
- Particle store is live (`mining.odin`, `particles.odin`).

SAVE_VERSION is 7. Save-layout changes trip the size assert in `save.odin` —
bump version + expected size together.

## Left to do

**Phase 5 playtest (only thing keeping the phase open):**
- Glenn's hand playtest of the boss fight — feel + tuning. The soak bot took
  66 hits in 60s vs player hp 10, so Garm may be tuned hot. Knobs: `GARM_*`
  in `garm.odin`. Also re-feel the new mining (pick pace + wand mana
  economics): `PICK_HITS`, `WAND_MANA_COST`, `wand_mine_range`, `pick_targets`
  direction bands.

**G2 look-and-feel port (the one remaining NEW-direction item):**
- Pixel 8-bit mage player (pickaxe, animated feet), mining particle polish.
  References: `Gnipahellir2/src/render.odin` + `particles.odin`. Glenn's branch
  `feature/render-port` already started this ("Port player pixel frames and
  Mine_Wand overlay from G2, visuals only") — **cherry-pick the intent, don't
  restart or merge**; it's now 16 behind / 11 ahead of master. Caveat: that
  branch carries stale mid-Phase-4 copies of `enemy.odin`/`tests.odin` — on
  conflict, master wins. It also has a `gni_rnd/` sandbox + docs worth a look.
- The G2 mining *mechanics* port (wand + proximity feel) is DONE — this
  remaining item is visuals only.

**Later phases:** Phase 6 shippability (menus/settings/onboarding/death +
win-restart flow), Phase 7 juice. `suggestion.md` still has C3/C5 + 2 perf
notes open.

## Repo note
No git remote is configured — the repo is local-only, no off-machine backup.
Set one up if you want it.

## Gotchas learned (timeless — keep these)
- Log ring buffer is 256 KB and silently stops — reset `gs.debug_log.pos`
  before capturing a window in long sims.
- Never clobber `action.log` (Glenn's ground truth); write diag files elsewhere.
- Diagnose builder/enemy stalls with a temporary diag test dumping per-frame
  state; frozen-position + suspiciously-cheap-frames + watchdog-silent means an
  early-return livelock. **Trust the soak, not a code proof** — it caught
  livelocks a proof missed twice.
- Odin: compound literals in conditions need a temp var; `odin test` links
  src.exe by default (collides with a running game — use `-out:src_test.exe`).
- raylib imports are pinned to `vendor:raylib/v55`; `physics.odin`'s
  `BODY_EPS < BODY_MARGIN < gravity*dt²` ordering is load-bearing.
- Glenn plays looking at his character, not the HUD — sound > text; if a
  mechanic lands, it should shriek.
