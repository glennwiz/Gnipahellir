# context.md — Source of Truth

**This file is the main source of truth for Gnipahellir3. Read it first every
session; update it at the end of every session.** It is a living snapshot: what
the game is, where the code stands right now, and what's queued next. When it
disagrees with older docs, trust this file — then reconcile.

- **Last updated:** 2026-08-02
- **Branch:** master · **Build:** green (`odin run src`) · **Tests:** 112 green (`odin test src`)
- **Save version:** 15 (`gnipahellir_save.dat` ≈ 2,658,280 bytes; smelter input buffer replaced wood-fuel field in `Sim_Tile_Data` — total size unchanged, byte-*meaning* changed, so v15 rejects old v14 saves. **A v14 backup sits at `gnipahellir_save.v14.bak`.**)
- **Recent HEAD:** 8004d6d (player-permeable door) + **this session's polish/mechanics pass** (committed): dirt tile art, floating damage/heal numbers, rune-plate notifications, tutorial hints + HUD craft chip, smelter rebuilt (internal ore buffer + auto-pull, no fuel), Q-drop removed, wands are weapon-slot tools mining at all ranges, early-game healing (forage flowers → brew potions). Not yet pushed (Glenn drives git).

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
- **Mining:** Pickaxe (adjacent, direction-aimed not tile-aimed, 3 chips, free) → wand ladder Mine(2)→Silver(4)→Gold(8)→Runic(12), 5 mana/shot. **Pickaxe horizontal swing mines the body tile nearer the cursor first.**
- **Wands are weapon-slot tools (2026-08-02):** a wand equips into the `.Weapon` slot (right-click in the bag), mutually exclusive with a sword. An equipped wand is the active mining tool at **every** range — adjacent tiles included, no more free-pick fallback up close — for mana. A wand sitting in the bag no longer fires. Melee is gated to non-wand weapons (`!is_wand`), so a wand equipped never swings for 0; `held_tool`/`equipped_wand` read the weapon slot. `best_wand` is gone. Ultra-wand cheat still forces a gold wand with no equip.
- **Healing (early game, 2026-08-02):** forage surface **flowers** (walk through them → auto-plucked to the bag with a collect mote + one-shot hint; flowers were dead decoration before) → craft **Health Potion** at the bench (3 Flower → 1) → **right-click the potion in the bag to drink** (+`POTION_HEAL`=5 hp, capped, refused at full). Green heal number pops (reuses the damage-number system). `Potion_Health` stub now live + a pixel-flower inventory icon; `Potion_Mana` stays a deliberate stub (mana self-regens).
- **Combat / Garm:** retuned to **75 HP / bite 4 / fireball 3**, phases at 50/25 (column→ring→lava flood). Min-1 player damage floor. Gear ladder Iron→Silver→Gold→Runic.
- **Enemies:** cave builders (A*, dens, hunt on LOS ~12 tiles). Table-driven drops.
- **Machines / sim:** **Smelter — rebuilt 2026-08-02** as a self-contained furnace: an **internal ore buffer** (`Sim_Tile_Data.in_item`/`in_count`) fed by dragging ore onto its window (`smelter_feed`) OR **auto-pulled** from an ore pile lying on an adjacent cell (`smelter_autopull`) — so the smelter+silo+ore-pile hands-off chain still runs. **No wood fuel** (removed — the hidden fuel requirement was why it read as "broken"); 2 ore → 1 bar over `SMELT_TIME`, bar lands in the tray (or casts straight into an adjacent silo). Mining the furnace spills BOTH tray and loaded ore. Window redesigned: INPUT slot + fire + progress + TRAY (drag ore in, drag tray out). Tree Grower unchanged. **Silo** — wide u32 bulk storage counting past 99; E pours 99-stacks; a smelter beside a silo casts bars straight in (skips the 99 tray). Loaded silo refuses mining + smash. *(Note: Q-drop feeding is gone — see below; silo intake is now smelter cast-in / E-pour.)*
- **Dimensions + Auto-Miner:** spawner opens ephemeral themed worlds (Metal/Gold/Runic). Auto-Miner = snake tunneling to nearest ore, wide-count haul, gem-fed speed tiers (emerald×1.5→jade×2→diamond×3→hel×5). Anchors its dimension while working; catch-up on re-entry amortized (G6 fixed — no stall).
- **Runic tier obtainable:** Runic Dimension Spawner (500 Gold Bars + 20 Cloud Stone at Rune Altar). Cloud Stone softlock fixed (plain clouds 20% hash-drop stone; puffy animated sky).
- **Structural gravity (`gravity.odin`), now cell-aware:** faller test is `is_faller(w,x,y)` — unconditional `.Falls` types (Wood, Leaves, **Dirt**) OR a `.Falls_Placed` type on a `.Placed` cell (**placed Stone**). A faller stays up only while a 4-connected chain links it to an anchor (any solid non-faller, or the map edge). Cut the last link → the hanging piece detaches and slides at `FALL_SPEED` 3 tiles/s. **Landing: `.Settles` types (Dirt, placed Stone) re-stack as TILES sand-style** (re-marking `.Placed` so stacks keep falling); everything else crumbles to **drops** (felled tree → logs+leaves). Stacking is order-safe (`r` recomputed each frame off the live grid). Detach fires from `Tile_Mined`; motion is step 6b; `draw_falling_blocks` read-only. `Gravity_State` pool [256], NOT saved.
- **Placed-block tracking:** `Tile_Flag.Placed` set on every player placement (`placement.odin`), cleared on mine (`handle_tile_mined`) and when lifted into the fall pool, re-marked on settle. Lives in `World_Grid.tile_flags` → **saved wholesale** (persists). This is what lets placed Stone fall while identical natural cave Stone stays inert.
- **Shaft-mouth + starter-earth reward (`render.odin` / `events.odin`):** `draw_shaft_mouth` apron fade is squared falloff over `SHAFT_APRON_REACH` (=4) so the brown scuff hugs the lip. Shared const + `in_shaft_apron(w,x,y)` (world.odin) mark exactly the scuffed tiles; **mining a tile in that apron drops the rock on the ground AND banks a `Dirt` clod straight to the bag** with a **collect mote** (`spawn_collect_mote`, particles.odin — homes to the player; `Particle` gained `homing`/`target`). `Dirt` is a placeable building block (item+tile, mines back, obeys gravity).
- **Door (`door.odin`, player-permeable wall):** craft at the Bench (4 Plank), place a **2-tall** pair (foot cell + the one above). It is **solid rock to everything** — never falls, full gravity anchor, falling blocks rest on it, **enemies walled out** — with ONE exception: the **player always phases through** it (no open/close, no button). The exception lives entirely in `move_body`'s `pass_doors` (physics.odin): the player's call passes `true`, every other body keeps the default `false`. `is_solid`/gravity/placement all read the door as plain solid rock. Mining either half removes the whole door for one `Door` item. `draw_pixel_door` (Pixel_Door style) knows top/bottom via a neighbor check. **Not committed yet.**
- **Hold-to-place:** right-click held paints a run of blocks, one per tile (`Input_State.place_last` dedupes the sweep).
- **Q "drop stack ahead" REMOVED (2026-08-02):** the whole mechanic is gone — `Action.Drop_Item`, `Event_Type.Item_Dropped`, `handle_item_dropped`, the input poll, the binding + settings row. Machines are fed by dragging (smelter window) / auto-pull now, not by tossing loose stacks on the ground.
- **Floating combat text (`floating_text.odin`, 2026-08-02):** damage numbers pop off the player and rise/fade — red `DAMAGE_COLOR` on every hit taken (enemy/fireball/lava/fall), green `HEAL_COLOR` on a potion drink. Fixed pool [32] in `Game_State.floating_text` (transient, not saved); update step **9b**, `draw_floating_text` in the world camera pass. `spawn_damage_number(store, pos, value, color)` is generic — pointing it at enemies later is a one-liner.
- **Rune-plate notifications (`ui.odin` `draw_notifications`, 2026-08-02):** guidance popups are now inscribed plaques — dark bordered plate, gold corner ticks, two flanking `draw_rune` glyphs per side (Elder-Futhark-style line staves, varied per message), a slow shared gold pulse. `draw_rune(id,x,y,w,h,col,thick)` holds six glyph shapes.
- **Tutorial hints + HUD craft chip (2026-08-02):** one-shot rune-plate hints on first **pickaxe** ("hold left-click to mine"), first **wood log** ("press [C] to craft"), first **flower** ("brew potions"), first **crafted wand** ("right-click to equip it — mine at range"). Each gated by a transient `*_hint_shown` flag on `Game_State`. Plus a persistent dim `[C] Craft   [TAB] Bag` chip bottom-left in `draw_hud` (binding-driven) — hand-crafting had no world anchor, so it gets a standing reminder.
- **Dirt tile art (2026-08-02):** `Pixel_Dirt` draw style + `draw_pixel_dirt` (earthy fill + pebbles/grit, fixed pattern) — placed dirt reads as soil, not a flat brown square.

### Controls (quick ref — full in PLAYTEST.md)
A/D move · W/Space jump · L-click hold mine (equipped wand mines at range/adjacent for mana; else pickaxe; sword swings at an enemy) ·
R-click place (hold to paint), or **right-click a bag item to equip gear / drink a Health Potion** · TAB inventory · C craft ·
E interact (portal/ritual/empty silo/open station) · ESC close windows / pause · F1 debug menu · F3 debug overlay.
*(Q "drop stack" is removed. Feed the smelter by dragging ore onto its window; equip a wand from the bag to mine with it.)*

---

## 5. What's queued (open work)

### Gravity follow-ups (priority-ish)
1. **Place-anywhere ANCHOR block** — Glenn's stated endgame: a placeable tile that anchors structures in mid-air. Hook `is_anchor_cell` now cell-aware and live; `.Placed` tracking exists — so this is newly within easy reach.
2. **Placed GRASS falling** — placed **Stone** now falls sand-style (via `.Falls_Placed` + `.Placed` cell bit + `.Settles`); **Grass is the only leftover** — deliberately left surgical. Trivial add: `.Falls_Placed, .Settles` on the `Grass` terrain row. *(Placed-stone/grass falling was the old §5.2 — now mostly closed.)*
3. **Enemy/Garm smashes don't trigger falls** — only player `Tile_Mined` does (deliberate slice scope; placed Stone/Dirt follow the same rule). One call in `smash_tile` adds it if wanted.
4. **`GRAVITY_ALL` const** — flips to full cave-in physics (all mineable tiles fall, anchored only to map edges). Wired but **UNPLAYTESTED**.
5. **Save-during-fall** drops airborne blocks (pool not in `Save_Data`) — rare, cosmetic; harden only if it bites.
6. **`blueprints.md`** — blueprints A/B/C are pixel-identical; owed original art + particles (recipes already differ).

### Visual polish owed (for the concurrent Sonnet "how things look" session)
- **Entrance shaft mouth — playtested & tuned.** `draw_shaft_mouth` (render.odin, render-only) dresses the descent lip: throat walls rim→dark, cut-soil edges, lit grass rim, and a brown scuff apron that now hugs the lip (squared falloff over `SHAFT_APRON_REACH`=4). Generic (keys off terrain in the `SURFACE_Y..CAVE_TOP` cap band), guarded by `shaft_mouth_is_dressable`. The `.Cave_Entrance` tile type stays **dead** (enum kept for save compat) — don't spend art on its `{60,0,80}` purple.
- ~~Dirt tile art~~ **DONE 2026-08-02** (`Pixel_Dirt` + `draw_pixel_dirt`).
- **Collect motes home to the player, not the hotbar.** Particles are world-space (drawn under the camera); the inventory HUD is a separate screen-space pass. Retargeting the mote to the actual hotbar slot needs a screen-space collect layer — the real follow-up if the "into the bag" read should point at the UI.
- **Door polish:** the placement **ghost previews one cell**, not the full 1×2 (cosmetic — the placement itself is 2-tall and correct). The **Door recipe sits at the END of the Bench list** (appended to keep recipe indices stable for tests); reorder + fix the couple of index-based craft tests if you want it near the top. Door tile art is a simple plank leaf (`draw_pixel_door`), fine but not fancy.

### TOP PRIORITY: a big hand playtest is owed
None of the retune/Silo/gravity work has been *felt* in-game yet, and the whole 2026-08-02 pass needs eyes:
- **Smelter rebuild:** drag ore into the window → INPUT fills → bars in tray; ore pile beside it auto-pulls; smelter→silo chain still hands-off.
- **Wand-as-weapon:** equip a wand, mine adjacent + at range; confirm sword/wand swap feels OK in a fight (the exclusivity is the open question — a separate tool slot is the fallback).
- **Healing loop:** forage flowers, brew a potion, right-click to drink; heal number reads.
- **Look/feel:** rune-plate notifications (pulse intensity, rune density), floating damage/heal numbers, HUD craft chip position, dirt tile art.
- Older, still owed: Garm at 75/4/3 (losable at Gold, comfy at Runic?); puffy sky + Cloud Stone drops + Runic spawner path; Silo fly-by; fell a tree and watch it pile; gem tile art, miner snake visuals, Gold spawner world.

### Open from flagg.md (tick off there as they close)
G4 (structure templates B/C skippable), G7 (infinite ore regen — accepted v1),
G9 (permadeath soft against force-quit), A3 (debug-menu input discipline), and
the ⚪ INFO list (dead items: Iron_Bucket/potions/Gold_Rare_Ore; doc drift;
stats file has no version field). G5 + G6 already fixed — verify in the playtest.

### Deliberate stubs (don't file as bugs)
Iron_Bucket can't scoop lava; potions exist but are unobtainable/unusable.

---

## 6. How to work here

- **Verify every change:** `odin run src` builds, `odin test src` (headless, ~2 s, 107 tests). Every feature lands with tests. Extend soak tests (AI/boss), don't skip.
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

- **2026-08-02 polish + mechanics session** (112 tests, save v15): a long conversational pass. **Polish:** dirt tile art (`Pixel_Dirt`); **floating combat text** (`floating_text.odin` — red damage / green heal numbers); **rune-plate notifications** (`draw_notifications`/`draw_rune`); one-shot tutorial hints (pickaxe / wood / flower) + persistent HUD `[C] Craft` chip. **Mechanics:** **smelter rebuilt** (internal ore buffer + auto-pull, wood fuel removed, window redesigned to INPUT/fire/TRAY — save v15, old saves reset, `.v14.bak` kept); **Q "drop stack" removed** wholesale; **wands became weapon-slot tools** (equip to mine, now fire adjacent too, mutually exclusive with swords, `best_wand`→`equipped_wand`); **early-game healing** (forage flowers → brew Health Potion at bench → right-click to drink, +5 hp). New `Flower` item + pixel icon; `Potion_Health` stub activated.
- **2026-08-01 session 2** (master a6da044/375de57/838c0c9 + Door 8004d6d, 107 tests): coherent surface/build arc — shaft-mouth apron fade (squared falloff, shared `SHAFT_APRON_REACH`); **Dirt** item/tile (placeable, gravity, mines back) + shaft-apron reward (rock on ground, dirt to bag); **collect motes** (`Particle.homing`/`target`, `spawn_collect_mote`); **placed-block gravity** (`.Placed` cell bit + `.Falls_Placed`/`.Settles` → placed Stone falls sand-style, natural stays); then the **player-permeable Door** (still uncommitted). Also committed the G2 prototype's raylib unversion fix (838c0c9).
- **2026-08-01 session 1** (master a693b85/82481b8/4368902, 100 tests): build unbroke (versioned raylib dropped → plain `vendor:raylib`, `DrawRectangleLinesEx` for hairlines, `DrawCircleGradient` Vector2 center); **structural gravity** slice (`gravity.odin`); hold-to-place block painting; pickaxe hover-target fix.
- **2026-07-19**: **the Silo** shipped (911dec4, save v14, draft1 §7.6 step 1). **G6 fixed** (70a6500, miner catch-up amortized). Doc cleanup: deleted `FABLE_START.md`, `score.md`, `progression_review.md` (shipped/superseded, in git history).
- **2026-07-18 fix session** (commits 720b68e..a918662, 84 tests): shipped flagg.md's whole top list — both CRITICALs (Cloud Stone 20% chance-drop + puffy animated sky; Runic Dimension Spawner @ 500 Gold Bars + 20 Cloud Stone), the four locked decisions (min-1 player dmg, Garm 75/4/3 with phases 50/25, rituals B/C cost bars), G1 (same-kind spawner reclaim releases the anchor), G2 (`smash_tile` drops machine items), A1 (mote table OOB), A2 (autosave debounced 5 s). Since then on master: G5 boxed-in miner fix (5eba0f6), stuck-builder pillars up + own den never a cage (23b9132), F2 altar debug menu + sky-portal fixes (b8b35d6), stone tint alpha 210→120 (43c4633).
- **All `.md` docs live in `gnipa_project/`** since 2026-07-18 (CLAUDE.md + this file stay at root).

---

## Update ritual (do this at the end of every session)

Edit the header block (date/branch/build/tests/save version/HEAD) and §4/§5 to
match what actually shipped. Move closed items out of §5; add new owed work.
Keep it tight — this is the snapshot, not the changelog (git history + the
`gnipa_project/` docs carry the long form).
