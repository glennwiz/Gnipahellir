# Handover — session 2026-07-04 (Phase 4 + Phase 5 start)

For the next session. Read `Plan.md` (roadmap), `Gnipahellir3/CLAUDE.md`
(architecture rules — mandatory), `Gnipahellir3/PLAYTEST.md` (controls).
Verify every change: `odin build src` + `odin test src` from `Gnipahellir3/`
(32 tests, ~2s; if the game is running, add `-out:src_test.exe` or the linker
can't write src.exe). Commit per verified milestone.

## Done this session (all on master, tree clean)

**Phase 4 — builder economy: COMPLETE + playtested + tuned**
- C4: sky-altar ritual gated to the sky level.
- Honest bridging: pocket blocks (cap 8) earned by mining, spent on bridges;
  A* takes a bridge budget.
- Raidable dens: finished shells bank hauls as floor-item stockpiles; mining
  den structure or trespassing → owner Hunts (shriek sound + notification);
  den defense: hunt never drops while raider within cheb 7 of the anchor.
- Builder mobility: A* climb move mines zigzag staircases (their only way UP
  through rock — fixed total economy collapse), weighted A* (h×2), airborne
  waypoint fix, avoid-radius blacklisting, worksite watchdogs.
- Tuning: DEN_SHELL_LAYERS 3→2 (raids pay out in-session). Soak: 306
  trips/hour, ~35s avg, 134 loot banked. 60-min economy soak + hunt-escape
  soak are permanent tests.

**Phase 5 — Garm: M1–M3 of 5 done**
- M1: Player melee — left-click press swings Sword (craft: 2 Iron Ore +
  1 Plank @ bench; 2 dmg, 2-tile reach, 0.35s cd). Wounded builders retaliate.
- M2: Projectile system live (slot 4, straight-line, owner-immune, entity-map
  hits; drawn as orange circles).
- M3: Boss arena carved in cave 3 (ARENA_* consts in garm.odin); Garm (30 hp)
  spawns ONLY once structure C is built (spawn is the gate) — on Level_Enter
  or on Cave_Unlocked tier 2. update_garm is a stub: he stands still.

SAVE_VERSION is 5. Save-layout changes trip the size assert in save.odin —
bump version + expected size together.

## Left to do

**Phase 5 remainder (task list #9, #10):**
- M4: Garm AI — chase via astar_dig/builder_travel infra, fireball via
  spawn_projectile, and G2's phases as boss mechanics: center column →
  perimeter ring → lava flood (G2 reference: Gnipahellir2/src/simple_garm.odin
  — primitive, reimplement in G3 idiom). Garm needs a Garm_State struct in
  Enemy (save bump!). Soak-style test like the builder ones.
- M5: Win — Garm dies → Hell_Key drop → pickup → Boss_Defeated/Game_Won →
  win screen + run stats; runs_won++.

**NEW direction from Glenn (start next session, maybe before/alongside M4):**
1. **G2 look-and-feel port**: pixel 8-bit mage player (pickaxe, animated
   feet), mining particle effects. References: Gnipahellir2/src/render.odin
   (128 KB) + particles.odin. IMPORTANT: Glenn's branch `feature/render-port`
   already started exactly this ("Port player pixel frames and Mine_Wand
   overlay from G2, visuals only") — review/cherry-pick it rather than
   restart. Caveat: that branch also accidentally contains stale mid-Phase-4
   copies of Gnipahellir3 enemy.odin/tests.odin — on conflict, master wins.
   It also has a gni_rnd/ sandbox + docs (ai_algo.md, enemy_ai.md) worth a look.
2. **G2 mining mechanics**: Glenn wants G3's mining to work like G2's —
   currently G3 mines instantly at 5-tile click range; G2 uses the wand and
   proximity (see Gnipahellir2/src/wand_mining.odin). Clarify exact feel with
   Glenn, then port. Ties into "mining costs no mana" known stub.
   G3 particles store exists but update_particles is stubbed (slot 8 —
   must move above process_events if it pushes events).

**Later phases:** Phase 6 shippability (menus/settings/onboarding/death
screen), Phase 7 juice. suggestion.md still has C3/C5 + 2 perf notes open.

## Gotchas learned this session
- Log ring buffer is 256 KB and silently stops — reset gs.debug_log.pos
  before capturing a window in long sims.
- Never clobber action.log (Glenn's ground truth); write diag files elsewhere.
- Diagnose builder stalls with a temporary diag test dumping per-frame state;
  the frozen-position + cheap-frames signature means an early-return livelock.
- Odin: compound literals in conditions need a temp var; `odin test` links
  src.exe by default (collides with a running game).
