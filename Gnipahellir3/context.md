# context.md — Source of Truth

**This file is the main source of truth for Gnipahellir3. Read it first every
session; update it at the end of every session.** It is a living snapshot: what
the game is, where the code stands right now, and what's queued next. When it
disagrees with older docs, trust this file — then reconcile.

- **Last updated:** 2026-08-01
- **Branch:** master · **Build:** green (`odin run src`) · **Tests:** 100 green (`odin test src`)
- **Save version:** 14 (`gnipahellir_save.dat` ≈ 2,658,280 bytes)
- **Recent HEAD:** a693b85 (pickaxe hover-target fix), 82481b8 (structural gravity), 4368902 (hold-to-place)

---

## 1. What the game is

**Gnipahellir** ("Yawning Chasm", Old Norse) — a fullscreen, grid-based 2D
Norse-underworld **mining roguelike**. Odin + Raylib, Windows primary.

- **Dual-axis loop:** descend into caves, ascend into the sky. Neither axis is
  completable alone. Descend → find a Blueprint → ascend → build the matching
  Sky Structure → that unlocks the next cave gate. Three tiers, then the Garm
  boss fight, then the win.
- **The player is fragile; the world is hostile.** Death is permanent
  (roguelike); persistent stats survive across runs.
- **The long arc is automation:** hands in the dirt early → architect of
  machines late → eventually *manufacture whole worlds* (dimensions) and
  strip-mine them with snake miners.
- **Design north star (Glenn's):** *the cost mirrors the reward* — pay iron to
  open an iron-rich world; the gem you feed a machine is the speed you get back.

Full design bible: `gnipa_project/plan.md`. Live issue audit: `gnipa_project/flagg.md`.

---

## 2. Architecture law (mandatory — full text in CLAUDE.md)

One Odin package (`game`); boundaries are call-discipline rules, checked by review.

- **Fat struct:** all runtime state in `Game_State`. No module-level mutable globals.
- **Fixed-size arrays only.** No `[dynamic]` growth during gameplay; buffers sized at startup. Full pool = silent drop (log in debug).
- **Event-driven:** systems talk via `Event_Queue`, consumed once per frame in `process_events`. No direct cross-system calls.
- **Render is read-only:** `draw_*` procs read state + call raylib, never mutate.
- **Table-driven behavior:** terrain/item/enemy/recipe = a table row. No `switch` sprawl.
- **Deterministic update order:** every system has an explicit numbered line in `game_update`.
- **Enums are append-only** (saves store them as u8). Any layout change to a saved struct → bump `SAVE_VERSION` + the size `#assert` in the same commit. There's a probe test that logs real `size_of(Save_Data)`.
- **Entity map** (`World_Grid.entity_map`): per-tile position index (center tile, last-writer-wins) for lookups/combat targeting — NOT a movement constraint (bodies are continuous AABBs, may overlap). Entity_ID: player = 0, enemy slot i = i+1. Despawn via `despawn_enemy`, never bare `enemy_free`.
- **No TODOs in committed code** — implement or file it here.

### Module responsibility (who may touch what)
- `render.odin` / every `draw_*` → read `Game_State`, call raylib. Never mutate, never call update/input.
- `input.odin` → polls hardware, pushes to `Event_Queue`, toggles `UI_State`, sets inventory selection (the one deliberate exemption). Never writes `World_Grid` or entity data.
- `world.odin`, `enemy.odin`, sim code → never call `draw_*` or input procs.
- `types.odin`, `game_state.odin` → shared foundation only (types, constants, fat struct); no game logic.

### Key constants (don't change without updating plan.md)
```
GRID_W 192 · GRID_H 108 · CELL_SIZE 10
MAX_ENEMIES 64 · MAX_PARTICLES 256 · MAX_PROJECTILES 32 · MAX_EVENTS 512
```

### game_update order
1 input · 2 player · 3 enemies · 4 projectiles · 5 mining · 5b sim (smelters/growers) ·
5b2 miner (dimension only) · 5c station-focus · **6b falling-blocks (gravity)** ·
6 process_events · 7 notifications · 8 ambience · 9 particles · 10 audio.

---

## 3. Source layout (`src/`)

`main.odin` loop · `types.odin` flags/consts/enums/events · `game_state.odin` fat struct ·
`world.odin` terrain table + grid/gen · `levels.odin` level store/portals/ritual/gen ·
`physics.odin` AABB `move_body` · `player.odin` · `enemy.odin` builder AI · `garm.odin` boss ·
`input.odin` · `events.odin` dispatch · `update.odin` order · `crafting.odin` recipes/stations ·
`dimensions.odin` ephemeral worlds · `miner.odin` snake miner · `sim.odin` machine tick ·
`silo.odin` bulk storage · `gravity.odin` structural falling · `placement.odin` · `items.odin` ·
`loot.odin` drops · `notify.odin` popups · `audio.odin` · `render.odin` · `ui.odin` ·
`save.odin` versioned binary · `debug_log.odin` action log · `tests.odin` headless suite ·
`life.odin` Game-of-Life easter-egg toy (debug only, NOT game content) · `templates.odin` build templates.

---

## 4. Where the code stands (systems that work)

- **Full v1 loop is beatable:** Cave 1→Blueprint A→Sky→Sky Altar ritual→cave-2 unlock→…→Garm→Hell_Key→win. Death/win clear the save.
- **Progression:** blueprints (pickup = activation, never consumed), Sky Altar rituals (A: 8 Cloud Stone + 4 Plank; B: 12 Cloud Stone + 6 Silver **Bar**; C: 20 Cloud Stone + 10 Gold **Bar**), sequential cave gates.
- **Mining:** Pickaxe (adjacent, direction-aimed not tile-aimed, 3 chips, free) → wand ladder Mine(2)→Silver(4)→Gold(8), 5 mana/shot. **Pickaxe horizontal swing now mines the body tile nearer the cursor first.**
- **Combat / Garm:** retuned to **75 HP / bite 4 / fireball 3**, phases at 50/25 (column→ring→lava flood). Min-1 player damage floor. Gear ladder Iron→Silver→Gold→Runic.
- **Enemies:** cave builders (A*, dens, hunt on LOS ~12 tiles). Table-driven drops.
- **Machines / sim:** Smelter (2 ore→1 bar, 1 log fires 3, bars land in tray), Tree Grower. **Silo** — wide u32 bulk storage counting past 99; vacuums neighbor Q-drops, E pours 99-stacks; a smelter beside a silo casts bars straight in (skips the 99 tray). Loaded silo refuses mining + smash.
- **Dimensions + Auto-Miner:** spawner opens ephemeral themed worlds (Metal/Gold/Runic). Auto-Miner = snake tunneling to nearest ore, wide-count haul, gem-fed speed tiers (emerald×1.5→jade×2→diamond×3→hel×5). Anchors its dimension while working; catch-up on re-entry amortized (G6 fixed — no stall).
- **Runic tier obtainable:** Runic Dimension Spawner (500 Gold Bars + 20 Cloud Stone at Rune Altar). Cloud Stone softlock fixed (plain clouds 20% hash-drop stone; puffy animated sky).
- **Structural gravity (newest slice, `gravity.odin`):** `.Falls` terrain flag (Wood, Leaves). A flagged block stays up only while a 4-connected chain links it to an anchor (any solid non-faller tile, or the map edge). Cut the last link → the hanging piece detaches and slides at `FALL_SPEED` 3 tiles/s, landing as **collectible drops** (a felled tree crumbles into logs + leaves). Detach fires from the `Tile_Mined` handler; motion is step 6b; `draw_falling_blocks` read-only. `Gravity_State` pool [256], NOT saved.
- **Hold-to-place:** right-click held paints a run of blocks, one per tile (`Input_State.place_last` dedupes the sweep).

### Controls (quick ref — full in PLAYTEST.md)
A/D move · W/Space jump · L-click hold mine (or weapon swing on enemy if equipped) ·
R-click place (hold to paint) · TAB inventory · C craft · E interact (portal/ritual/empty silo/open station) ·
Q drop stack 2 tiles ahead · ESC close windows / pause · F1 debug menu · F3 debug overlay.

---

## 5. What's queued (open work)

### Gravity follow-ups (this session's owed list, priority-ish)
1. **Place-anywhere ANCHOR block** — Glenn's stated endgame: a placeable tile that anchors structures in mid-air. Hook already named: `is_anchor_cell`. This is the "later" block he flagged.
2. **Placed stone/grass falling** — needs per-cell "was-placed" tracking (those tile types are shared with natural terrain, so a flag alone can't tell them apart). Extend the existing per-cell `Tile_Flags` bitset (add `.Placed`). Pairs with the anchor block.
3. **Enemy/Garm smashes don't trigger falls** — only player `Tile_Mined` does (deliberate slice scope). One call in `smash_tile` adds it if wanted.
4. **`GRAVITY_ALL` const** — flips to full cave-in physics (all mineable tiles fall, anchored only to map edges). Wired but **UNPLAYTESTED**.
5. **Save-during-fall** drops airborne blocks (pool not in `Save_Data`) — rare, cosmetic; harden only if it bites.
6. **`blueprints.md`** — blueprints A/B/C are pixel-identical; owed original art + particles (recipes already differ).

### Visual polish owed (for the concurrent Sonnet "how things look" session)
- **Entrance shaft mouth** — removing the old `Cave_Entrance` cap (master cbd2cc2) exposed the level-0 descent as a raw 2-wide `.Void` slot in the surface grass (center `x=96`, `y=54–67`), then the starter pickaxe moved to its floor (a8632c1). This is the **first place `.Void` renders above ground against the sky** — any Void styling is now surface-visible here. Owed: dress the pit lip (a bit of stone edge / a proper cave-mouth read). The `.Cave_Entrance` tile type is now **dead** (enum kept for save compat, but placed nowhere) — don't spend art on its `{60,0,80}` purple.

### TOP PRIORITY: a big hand playtest is owed
None of the retune/Silo/gravity work has been *felt* in-game yet:
- Garm at 75/4/3 with min-1 chip — losable at Gold set, comfortable win at Runic?
- Puffy animated sky + Cloud Stone chance-drops; Runic spawner path end-to-end.
- Silo in-game fly-by; structural gravity (fell a tree, watch it pile).
- Still unseen: gem tile art, miner snake visuals, Gold spawner world.

### Open from flagg.md (tick off there as they close)
G4 (structure templates B/C skippable), G7 (infinite ore regen — accepted v1),
G9 (permadeath soft against force-quit), A3 (debug-menu input discipline), and
the ⚪ INFO list (dead items: Iron_Bucket/potions/Gold_Rare_Ore; doc drift;
stats file has no version field). G5 + G6 already fixed — verify in the playtest.

### Deliberate stubs (don't file as bugs)
Iron_Bucket can't scoop lava; potions exist but are unobtainable/unusable.

---

## 6. How to work here

- **Verify every change:** `odin run src` builds, `odin test src` (headless, ~1 s, 100 tests). Every feature lands with tests. Extend soak tests (AI/boss), don't skip.
- **Toolchain caveat:** Odin dev-2026-07 dropped versioned raylib — imports are plain `vendor:raylib` (NOT `vendor:raylib/v55`). Two signatures shifted: `DrawCircleGradient` takes a `Vector2` center; hairline `DrawRectangleLines` flickers under the supersample → use `DrawRectangleLinesEx`. If a build breaks on an import, check `odin root`'s vendor tree AND raylib call shapes. (See memory `[[odin-toolchain-quirks]]`.)
- **Working with Glenn:** he designs by conversation — give concrete options WITH a recommendation, then respect his fast, good decisions (write them down, don't re-litigate). He hand-playtests between sessions (`action.log` is ground truth — grep it for `strike`/`WARNING`/`Player`). He picks the FUN slice before the prerequisite; meet that energy but keep prereqs visible here. Small, verified commits. Keep it warm. ⚒️
- **Commits:** conventional (`feat:`/`fix:`/`chore:`/`docs:`), lowercase, ≤50 chars. Glenn often drives git himself — check `git log` before assuming state.
- **Never delete real data** (saves, logs) for testing — copy aside.
- **Branch note:** `feature/render-port` is Glenn's R&D branch with stale mid-Phase-4 copies of `enemy.odin`/`tests.odin` — on any merge conflict prefer master for those.

---

## 7. The rest of the doc set (detail lives here)

- `CLAUDE.md` (root) — architecture law, full text. Non-negotiable.
- `gnipa_project/plan.md` — design bible: full loop, terrain/item tables, progression, data layout.
- `gnipa_project/flagg.md` — prioritized issue audit (2026-07-18 + status patches).
- `gnipa_project/PLAYTEST.md` — controls, build/test, debug tools (F1 fly), full loop walkthrough.
- `gnipa_project/Work_done.md` — holiday session log + the four locked decisions.
- `gnipa_project/OPUS_HANDOVER.md` — timeless "how to work with Glenn / the game's soul".
- `gnipa_project/draft1_machines.md` — machine roadmap (§7.6 silo/dimension-block/background-yield).
- Also: `ai_algo.md`, `gem_progression.md`, `architecture_findings.md`, `sprites_prompt.md`, `blueprints.md`, `PLAYTESTER_GUIDE.md`.

> The old `next_session.md` living handover was folded into this file on
> 2026-08-01; context.md is now the single handover. Long-form session history
> lives in git and `Work_done.md`.

---

## 8. Recent shipped history (compact — git + Work_done.md carry the long form)

- **2026-08-01** (master a693b85/82481b8/4368902, 100 tests): build unbroke (versioned raylib dropped → plain `vendor:raylib`, `DrawRectangleLinesEx` for hairlines, `DrawCircleGradient` Vector2 center); **structural gravity** slice (`gravity.odin`); hold-to-place block painting; pickaxe hover-target fix.
- **2026-07-19**: **the Silo** shipped (911dec4, save v14, draft1 §7.6 step 1). **G6 fixed** (70a6500, miner catch-up amortized). Doc cleanup: deleted `FABLE_START.md`, `score.md`, `progression_review.md` (shipped/superseded, in git history).
- **2026-07-18 fix session** (commits 720b68e..a918662, 84 tests): shipped flagg.md's whole top list — both CRITICALs (Cloud Stone 20% chance-drop + puffy animated sky; Runic Dimension Spawner @ 500 Gold Bars + 20 Cloud Stone), the four locked decisions (min-1 player dmg, Garm 75/4/3 with phases 50/25, rituals B/C cost bars), G1 (same-kind spawner reclaim releases the anchor), G2 (`smash_tile` drops machine items), A1 (mote table OOB), A2 (autosave debounced 5 s). Since then on master: G5 boxed-in miner fix (5eba0f6), stuck-builder pillars up + own den never a cage (23b9132), F2 altar debug menu + sky-portal fixes (b8b35d6), stone tint alpha 210→120 (43c4633).
- **All `.md` docs live in `gnipa_project/`** since 2026-07-18 (CLAUDE.md + this file stay at root).

---

## Update ritual (do this at the end of every session)

Edit the header block (date/branch/build/tests/save version/HEAD) and §4/§5 to
match what actually shipped. Move closed items out of §5; add new owed work.
Keep it tight — this is the snapshot, not the changelog (git history + the
`gnipa_project/` docs carry the long form).
