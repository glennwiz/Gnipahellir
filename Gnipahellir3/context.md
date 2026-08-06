# context.md — Source of Truth

**This file is the main source of truth for Gnipahellir3. Read it first every
session; update it at the end of every session.** It is a living snapshot: what
the game is, where the code stands right now, and what's queued next. When it
disagrees with older docs, trust this file — then reconcile.

- **Last updated:** 2026-08-06
- **Branch:** master · **Build:** green (`odin build src`) · **Tests:** 195 green (`odin test src -all-packages`)
- **Player walks through structures (not raw terrain):** `move_body`'s `is_player` flag (physics.odin, was `pass_doors`) now waives collision for the player on doors AND every `is_structure_tile`/blueprint-chest tile, but only sideways — the X sweep and step-up probe pass `horizontal=true`, both Y sweeps pass `false`, so the player still lands and stands on top of a bench/barrel/chest like solid ground. Enemies/golems are unaffected (still full solid). Not yet eyeballed in-game.
- **Golem stuck-loop fixed + Quick Clay shipped (2026-08-06):** a real playtest save had a golem looping forever near a Golem_Marked resource just below its (tiny) Gather-zone rectangle. Root cause: `golem_assign_gather`'s "climb back, I must have fallen" heuristic (`T.y>w.max.y+2`) fired even when a marked resource legitimately explained the depth, yanking the worker into a pointless climb-and-return cycle that re-picked the same never-consumed target forever — fixed by exempting the heuristic when `golem_find_marked_resource` still finds something reachable there (verified by headlessly replaying the actual stuck save 60 simulated seconds: golem now finishes the mine, delivers, keeps working). Separately, at Glenn's request, self-locomotion (bridging a gap, pillaring up during vertical recovery) no longer spends real pack material at all: `golem_place_quick_clay`/`golem_dissolve_quick_clay`/`golem_tick_quick_clay` (golem.odin) give a worker a free, instant, always-succeeding `.Quick_Clay` foothold (solid, never `.Mineable`, never player-placeable) tracked in a small transient per-owner pool (`Golem_Quick_Clay_State`, NOT saved — same pattern as `golem_grace`); once the worker strays more than `GOLEM_QUICK_CLAY_LINGER`=2 tiles away (or breaks/recalls/changes level), it dissolves back to Air/Void with a `spawn_clay_drip` particle. Replaces `golem_exec_path_bridge`'s and `golem_update_recovery`'s real-block placement; `golem_set_target`'s A* `bridge_budget` is now unlimited (`MAX_NAV_PATH`) instead of pocket-material-limited. Real pack material (`Stone_Block`, etc.) is now spent only for actual delivery/monument-building jobs, never for a worker's own movement. Removed now-dead `golem_take_nav_block`/`golem_nav_block_count`/`golem_nav_tile`/`golem_nav_tile_table`/`golem_recovery_scavenge`/`GOLEM_RECOVERY_MINE_REACH` (the old material-scarcity scavenging fallback is moot when footing is free). The pre-existing block-grace/`.Golem_Placed` cleanup-scanning machinery (next bullet) is left untouched for legacy-save compatibility even though nothing writes new grace entries anymore.
- **Golem block grace:** fresh bridge/recovery masonry has a transient three-second owner grace. The placing worker may reclaim it immediately; every other golem skips it during job selection and obstruction mining until expiry. *(As of 2026-08-06, new bridge/pillar placement no longer creates this kind of masonry at all — see Quick Clay above — but this machinery still governs any legacy `.Golem_Placed` blocks from older saves and the "treat golem masonry as lowest-priority Gather-zone cleanup" scan.)*
- **Gather completion:** a marked Gather rectangle is explicit demolition permission for ordinary player-placed masonry, which is selected only after natural resources and golem navigation cleanup; player structures and placed blocks outside the rectangle remain protected. Falling golem masonry now keeps its ownership marker and remaining grace when it settles. The 2026-08-06 save's final placed Stone at `(74,58)` is recognized by all three workers and the exact replay reaches zero remaining blocks in under ten seconds.
- **Precision excavation:** with the Command Wand equipped, normal left-drag still paints a bounded Gather rectangle; Shift+left-drag paints persistent per-block excavation tags and Shift+right-drag erases them, while direct Shift-click on a golem still recalls it. Tagged mineable terrain is rendered with a pulsing green rune, outranks rectangle work, is cooperatively claimed, can be carved anywhere without an active rectangle, and consumes its tag when mined; structures and den shells cannot be tagged.
- **Portal pixel-art pass:** live portals no longer use smooth ellipses, gradients, spiral dots, or sub-pixel rims. Cave gates are floor-anchored basalt arches with block courses, green rune stones, stepped ember bands, and a physical barred seal when locked; the Low Sky return remains a pale cloud-stone doorway with cyan runes, vertical light shards, and square motes. The surface Sky Altar instead projects a clearly round 36x36 stepped sky-well with a broken octagonal rim and four rune clasps. The one-cell altar itself receives a 26x27 render-only shrine silhouette with layered masonry, forked uprights, rune plates, and a bobbing faceted crystal; its offering also animates on snapped pixel beats.
- **Connected Tier-A altar:** when a Sky Altar caps the exact five-Stone/three-Wood starter template, those eight real support cells receive one connected foreground shrine skin: a five-block dressed-stone course, one bound three-panel oak beam, stepped braces, iron collars, and a cyan rune spine continuing into the capstone. Incomplete foundations retain ordinary block art.
- **Smelter pixel-art pass:** the one-cell Smelter now renders as a larger hard-edged firebrick furnace with stepped shoulders, capped soot chimney, iron bands/rivets, arched firebox, fuel rack, casting tray, ore glints, an integrated progress bar, and square smoke. Its flame, input ore, stored output, fuel and casting progress are all driven by the real `Sim_Tile_Data` buffers.
- **Save version:** 23 (`gnipahellir_save.dat` ≈ 3,171,464 bytes; **v23** saves each Clay Golem's eight-block internal pack and vertical-recovery state, with an explicit **v22 → v23 migration** that preserves the active playtest run; **v22** added the original golem system. Older incompatible saves reset.)
- **Recent HEAD:** a UI/feel pass (uncommitted at session start, committed 2026-08-03): **windows auto-center as a pair** when the crafting+bag open together (no more forge spilling off-screen) yet **respect hand-drags** (`win_moved`); a **bottom-center placement chip** showing the selected block (click = open bag); a **vertical camera deadzone** so jumping doesn't bob the view when zoomed in; the **Tree Grower's sapling stalk now climbs the full trunk height** before the tree pops in; and **wands no longer strike structures** (machines/stations/spawners/altars — reclaim with the pick). Prior HEAD: blueprint seal-colors + em-dash→ASCII text fix; storage barrel + smelter wood-fuel + drag-to-drop piles. Carries Glenn's tweak: basic wand reach 2 → 3.
- **Current worktree:** the **Clay Golem automation vertical slice** is implemented. Damp Clay seams and water pockets appear in upper cave 1; Bench recipes create a Command Wand and individual workers. The wand binds 1 golem, upgrades at a golem-built Clay Hearth to 5 with Emerald and 15 with a Hel Gem, deploys/recalls workers, paints bounded Gather zones, toggles individual or whole-crew Gather/Build modes, and places monument ghosts. The F1 cheat menu includes **Give Command Wand** and an armed **Place Clay Golem** action whose next valid grounded world click deploys a ready worker. Command-wand left-click priority is interaction-safe: exact machines/chests win, golems use a padded visible-body hitbox with a bright hover frame, and empty-world presses preserve the old Gather zone unless they become a deliberate six-screen-pixel drag reaching a different tile (so accidental one-block zones are impossible). Golems reuse dig-aware navigation, prioritize smelters → Golem Depots → barrels/open blueprint chests → silos, and cooperatively fetch/consume materials for the Clay Hearth, Golem Depot, and World Anchor templates. Each worker has a saved eight-block internal pack: every resource and access block it mines enters that pack, the visible carried icon/count exposes its cargo, delivery fully unloads both its hand and pack before returning to work (rerouting if a destination fills). **(2026-08-06: bridges and vertical-recovery pillars now cost nothing** — a free, self-dissolving Quick Clay foothold, not real pack material; see the Quick Clay header bullet.) A worker below an exhausted zone returns toward it even with no remaining resource target. Build mode now means Build exclusively: without an active monument project, a worker unloads all leftover cargo and waits Idle instead of silently mining the Gather zone; both its toggle notification and command strip explain that the player must select a monument and click its anchor. If ordinary A* cannot get upward, it carves headroom when blocked (still real mining, drops still bank to the pack) and pillars back toward the objective on free Quick Clay footholds (2026-08-06: this now DOES conjure the footing itself, deliberately — see the Quick Clay header bullet; only headroom removal is still real material). Recovery now uses the active job's real interaction reach (Mine/Seek 1, transfer 3, build 5), eliminating the two-tile dead band; unreachable far storage is rejected before vertical recovery so the worker uses its reachable local stockpile instead, and a full pack caches one item when headroom must be mined. Navigation masonry is tagged separately: golems may reclaim their own bridge/pillar blocks, while player-placed blocks remain protected and A* routes around them. Gather includes Grass and Dirt as its lowest-priority natural clearing materials; once natural work is exhausted, it treats golem-created masonry inside the marked zone as cleanup work and hauls the real material away, while never selecting player-placed masonry. The 2026-08-06 live zone contained 10 natural Grass cells, four golem-placed Grass cells, and one player Stone: all four workers now receive jobs immediately, natural Grass reaches zero in about 30 replayed seconds, cleanup continues afterward, and only the player Stone remains protected. Recovery side-scavenging never mines placed masonry or the natural support directly beneath it, preventing adjacent workers from dismantling each other's live pillars; the exact two-worker loop at `[81..82,49..50]` now climbs out and exits recovery in about three replayed seconds. Saved-path validation covers the complete upward takeoff arc and rejects waypoints more than two rows above or two columns away after a fall. A fallen worker whose objective remains above immediately pillars from its landing instead of jumping at the abandoned ledge or taking a map-wide detour. When A* snaps a precariously perched body to nearby standable ground, that assumed origin is now emitted as a real first waypoint instead of returning an empty route; a three-second no-waypoint-progress watchdog additionally forces replanning or local recovery. Gather assignment now separates desirability from reachability: it skips up to sixteen path-rejected resource candidates in one tick, accepts only a real route (not an impossible sideways "recovery"), and leaves successful targets claimed so a clustered crew spreads out. The exact stuck save's four overlapping workers all leave `[35,73]` on separate active routes within five replayed seconds and continue working through a 40-second replay. Mining, loose-item collection, storage withdrawal/deposit, field caching, bridge/pillar work, and monument placement emit directional five-mote cargo streams between the worker and the action tile, with a bright lead spark and item-colored trail. Embedded workers are ejected to the nearest safe cell without losing cargo or objectives and immediately recover toward an upper target; future falling blocks that would settle inside a golem crumble into a recoverable ground item instead. The exact live save now unloads its two Leaves and waits empty in Build mode when no project exists; its earlier recovery still climbs from (80,104) through the mineral den shell instead of aborting at y=77. Ordinary routes still protect structures and dens; only an active narrow self-rescue shaft may punch through a den shell that would otherwise trap the worker. v22 migrates intact to v23. Native visual playtest is still owed.

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
1 input · 2 player · **2c clay golems** · 3 enemies · 4 projectiles · 5 mining · 5a equipment reclaim · 5b sim (smelters/growers) ·
5b2 miner (dimension only) · 5c station-focus · 5d recipe-unlocks · **5e ritual (offering swirl)** ·
6 process_events · **6b falling-blocks (gravity)** · 7 notifications · 8 ambience · 9 particles · 10 audio.

---

## 3. Source layout (`src/`)

`main.odin` loop · `types.odin` flags/consts/enums/events · `game_state.odin` fat struct ·
`world.odin` terrain table + grid/gen · `levels.odin` level store/portals/ritual/gen ·
`physics.odin` AABB `move_body` · `player.odin` · `enemy.odin` builder AI · `garm.odin` boss ·
`input.odin` · `events.odin` dispatch · `update.odin` order · `crafting.odin` recipes/stations ·
`dimensions.odin` ephemeral worlds · `miner.odin` snake miner · `golem.odin` clay-worker automation · `sim.odin` machine tick ·
`silo.odin` bulk storage · `gravity.odin` structural falling · `placement.odin` · `items.odin` ·
`loot.odin` drops · `notify.odin` popups · `audio.odin` · `render.odin` · `ui.odin` ·
`save.odin` versioned binary · `debug_log.odin` action log · `tests.odin` headless suite ·
`life.odin` Game-of-Life easter-egg toy (debug only, NOT game content) · `templates.odin` build templates.

---

## 4. Where the code stands (systems that work)

- **UI/feel pass (2026-08-03):** five small quality fixes.
  - **Floating-window auto-layout that respects drags** (`ui.odin`/`input.odin`/
    `game_state.odin`): the bag+forge together are 990px wide on a 1280 canvas, so
    the old "center the bag alone" default spilled the crafting panel ~52px off
    the right. Now `place_craft_pair` centers the **pair** whenever crafting opens
    beside the bag (C hotkey and station-open), and `place_bag_centered` centers
    the bag for TAB-alone. A new `UI_State.win_moved[UI_Window]` flag is set on any
    header-drag; auto-layout **skips a hand-placed window**, so custom positions
    hold for the session. Transient (not saved) — resets to sane defaults on a
    fresh launch.
  - **Selected-block placement chip** (`draw_sel_chip`, bottom-center HUD):
    always shows what right-click will place — icon + count, name label tinted
    gold when placeable (`place_tile != .Air`, dimmed otherwise), "no block" when
    nothing's selected. **Click it → toggles the bag** (`sel_chip_hovered`, wired
    in `cursor_over_ui` so mining/placing is suppressed under it; click handler in
    input.odin). Replaced the old top-left `[item xN]` text.
  - **Vertical camera deadzone** (`render.odin` `update_camera`/`camera_snap_y`,
    step **2b** in game_update; `gs.cam_y`, transient): camera **X** follows the
    player exactly, **Y** tracks an anchor that only moves when the player leaves a
    ±3.5-tile band (`CAM_DEADZONE_Y`). A jump arc (~3 tiles) stays inside → the
    view holds still; falling/climbing past the band drags it. Snapped (no slide)
    on level transition / spawn / load / new game. Only felt when zoomed in (at
    zoom 1 the camera clamps Y to level-center anyway). *(Pure deadzone: after a
    big fall/climb the player rests at the band edge until they move vertically —
    a grounded re-center lerp is the follow-up if that reads odd.)*
  - **Tree Grower stalk climbs to full length** (`draw_machine_progress`): the
    growing green sapling now rises to `TREE_MAX_H`×`CELL_SIZE` (5 tiles / 50px)
    over the timer, with tip leaves + side sprigs, instead of a 7px stub that
    popped straight to a tree. Clearance is guaranteed (tick_grower checks to
    `TREE_MAX_H`). Grow **time** unchanged (20 s).
  - **Wands never strike structures** (`world.odin` `is_structure_tile` table +
    `mining.odin` guard): a wand aimed at a machine/station/spawner/altar does
    nothing (no shot, no mana) — you **reclaim a structure with the pick, up
    close** by Shift-holding left-click for 0.8 s. Ordinary clicks interact and
    never damage equipment; releasing or moving off cancels, and loaded machines
    must be emptied first. Fixed the "wand-mines the smelter from range" bug.
    Tests cover both protected mining and deliberate reclaim.
- **Sky-Altar ritual ceremony (2026-08-02, uncommitted):** the offering was
  instant — E at the altar consumed materials and unlocked the cave in one
  frame. Now it's a staged ritual: `handle_ritual_request` (levels.odin)
  validates as before, then `start_ritual` begins a **2 s swirl** (`Ritual_State`
  in Game_State, transient/not saved; `RITUAL_DURATION`) — `update_ritual`
  (game_update **step 5e**) spawns `spawn_ritual_swirl` rainbow motes each frame
  and `draw_ritual` (render, world-space, read-only) orbits the **ingredient
  icons** + a counter-rotating **rune ring** around a swelling glow over the
  altar. **Materials aren't consumed until the finishing flash** (re-validated
  in `update_ritual`), so a mid-swirl save/interrupt loses nothing. At the end:
  `spawn_ritual_flash` (white/gold burst), push `Structure_Complete` (unchanged
  cave-unlock/Garm path), and open an **instruction tome** — `draw_book`
  (ui.odin), a full-screen leather-and-parchment modal with a white flash-in
  (`gs.frame - book_open_frame`, frame counts while paused) and per-tier
  `book_title`/`book_lines` naming the freshly-unsealed portal (Deep Cave →
  Gnipahellir → GARM). Sim frozen while the tome is up (game_update freeze +
  input early-return); **E/ESC/click** closes it and the world resumes same
  frame. Tests: `ritual_consumes_and_unlocks` + the Garm-wake test now drive the
  swirl to completion; new `ritual_swirls_then_leaves_a_tome` covers the
  re-entry guard, deferred consumption, and the tome. **Not yet eyeballed
  in-game** — the swirl geometry/tome layout want a visual playtest. *(Open:
  "leave a book" is a modal tome here; a physical, re-readable book at the altar
  is the alternative if Glenn wants it tangible.)*
- **Crafting window redesigned (2026-08-02):** was a text-row list + a drag-to-anvil "takes shape" model — now a **two-column forge panel** (`draw_crafting`): a **grid of recipe icon-cards** on the left (framed slot per recipe, faint-green border when craftable now, gold when selected/hovered, dimmed icon when you lack materials, count badge) and a **detail column** on the right — big result icon, name, **ingredient rows with have/need counts** (green satisfied / red short), and a **CRAFT button** that pulses gold when affordable and greys with a reason ("need more materials" / "stand by the station") when not. Wrapped in the Norse panel (gold frame, corner ticks, rune strip). **The anvil model is gone** — `craft_offer`/`offer_matches`/the anvil hit-testers removed; new state is `UI_State.craft_selected` (recipe index) resolved via `craft_selected_recipe` (falls back to first visible). Input: click a card to select, click CRAFT to forge (`Craft_Request`); crafting no longer uses bag-drag (smelter still does). Hit-testers: `craft_card_at_cursor`, `craft_button_hovered`. **Not yet eyeballed in-game — layout math checked, needs a visual playtest.**
- **Recipe unlock tree (2026-08-02):** the craft window was a firehose (every bench recipe at once). Now recipes are **hidden until you first hold their gating material** — a paced tech-tree reveal. Keyed by each recipe's (unique) **result item** in `recipe_unlock` (crafting.odin): Plank/Bench known from the start → wood unlocks Tree_Grower/Door → flowers unlock potions/beds → **Iron_Ore** reveals Smelter/Sword/Wand → **Iron_Bar** reveals armor + Forge + Silo → Silver/Gold bars → Cloud_Stone (Rune Altar) → Runic_Sky_Ore (runic tier). Unlock is **sticky** (`Progression_State.recipe_unlocked[Item]`, saved) — stays revealed after the material is spent. `update_recipe_unlocks` (game_update step 5d) polls inventory, flips new unlocks, and pops one **"New recipe: X (+N more)"** note. `visible_recipes` hides locked rows (the player-facing gate); `recipe_craftable` is NOT gated (tests craft directly, and clicks only reach visible rows). **Tune early-game pacing by editing `recipe_unlock`.**
- **World seed (2026-08-02):** level generation is seeded — `gs.world_seed` is mixed (additively) into the gen hashes for the surface, cave 1, caves 2/3, and sky, so **every New Game gets a fresh world** (seed from `time.now()`). Override with the **`GNIPA_SEED` env var** (a number → reproducible/shareable worlds; used for debugging a specific layout). Seed **0 reproduces the original fixed world** — `game_state_init`'s default, so the boot title screen and all headless tests stay deterministic. The seed is **not saved** (the world grid is saved wholesale; seed only matters at gen time — minor caveat: a level first generated *after* a reload uses the default seed, not the run's original). Dimensions keep their position-derived seed (unchanged). New-game seed is logged to `action.log`.
- **Full v1 loop is beatable:** Cave 1→Blueprint A→Sky→Sky Altar ritual→cave-2 unlock→…→Garm→Hell_Key→win. Death/win clear the save.
- **Progression:** every world blueprint now waits in a **solid permanent Blueprint Chest**. Click/E in range opens the same normal 4×4 storage inventory as a barrel and seeds the blueprint into one ordinary slot; every slot accepts normal items immediately. Dragging the blueprint into the bag activates progression, while the chest and its remaining storage stay forever. A full bag leaves the blueprint inside. The opening Sky chest, delayed Blueprint A chest, and generated B/C cave chests share a compact 16×11 arched-oak/iron pixel silhouette with sky/bronze/silver/gold rune locks. Opened chests use saved `Barrel_State` records; old v21 loose drops are sealed on load, and dropped blueprints re-seal instead of becoming piles. Sky Altar rituals: A: 8 Cloud Stone + 4 Plank; B: 12 Cloud Stone + 6 Silver **Bar**; C: 20 Cloud Stone + 10 Gold **Bar**; sequential cave gates.
- **Mining:** equipped Pickaxe (adjacent, direction-aimed not tile-aimed, 3 chips, free) → wand ladder Mine(3)→Silver(4)→Gold(8)→Runic(12), with 5/3/5/5 mana costs. **Pickaxe horizontal swing mines the body tile nearer the cursor first.** **Bare hands (no equipped pickaxe) can still knock down trees — Wood tiles only, at `BARE_HAND_MULT`=3× the hits (9); no other tile yields to fists** (2026-08-02). *(Basic-wand reach bumped 2→3 by Glenn's playtest.)*
- **Dedicated PICK + WPN slots:** the Pickaxe equips into appended `.Tool`; swords and wands remain mutually exclusive in `.Weapon`. A valid equipped-wand target takes priority, but the pick stays equipped and supplies the old close-range fallback when the wand cannot fire. A bagged pick cannot mine/reclaim. Reclaim refuses while a wand is active so dismantling remains deliberate. Melee is gated by `is_melee_weapon`, excluding tools even if armor adds Attack. Ultra-wand cheat remains equip-free.
- **Healing + flower farming (early game, 2026-08-02):** forage surface **flowers** (walk through them → auto-plucked; wild-flower spawn is a **level total of 5–8** across the whole surface, deliberately scarce — beds are how you scale up) → each harvested bloom gives **1 Flower + 2–5 Flower_Seed** (`FLOWER_SEED_MIN/MAX`) → craft **Health Potion** at the bench (3 Flower → 1) → **right-click the potion in the bag to drink** (+`POTION_HEAL`=5 hp, capped, refused at full; green heal number). **Flower farming loop:** craft a **Flower Bed** (1 Dirt + 1 Plank + 5 Flower_Seed) → place it → it **grows over `FLOWER_BED_GROW_TIME`=120 s (~2 min)** via `tick_flower_bed` (sim step, `growth_timer` in sim_data, saved) — only when **ripe** do the **`FLOWER_BED_BLOOMS`=5** blooms yield; walk through to harvest all 5 (each → Flower + seeds), tile reverts to Air. `draw_pixel_flower_bed` reads growth and animates the stages (sprout→stem→bud→swaying bloom), stalks spilling up into the cell above for a taller-than-one-cell sprite. Self-sustaining (5 blooms → up to 25 seeds → more beds — *exponential, tunable via the seed constants if it needs reining in*). New items `Flower`/`Flower_Seed`/`Flower_Bed` + icons, `Flower_Bed` tile (`Pixel_Flower_Bed`, walk-harvested not mined). `Potion_Health` stub now live; `Potion_Mana` stays a deliberate stub (mana self-regens). Harvest logic lives in `player_pickup`.
- **Combat / Garm:** retuned to **75 HP / bite 4 / fireball 3**, phases at 50/25 (column→ring→lava flood). Min-1 player damage floor. Gear ladder Iron→Silver→Gold→Runic.
- **Enemies:** three builders in each cave level (A*, dens, hunt on LOS ~12 tiles). Table-driven drops.
- **Machines / sim:** **Smelter** — self-contained furnace with TWO internal buffers: **ore** (`Sim_Tile_Data.in_item`/`in_count`) and **wood fuel** (`fuel_count`, added 2026-08-02, save v18). Both fed by dragging onto its window (`smelter_feed` routes by item — ore→INPUT, `Wood_Log`→FUEL) OR **auto-pulled** from adjacent piles (`smelter_autopull` now handles ore AND wood — lay ore one side, wood the other, hands-off). Smelt gate: `in_count ≥ ore_per_bar` AND `fuel_count ≥ FUEL_PER_BAR`(=2) → 2 ore + 2 wood → 1 bar over `SMELT_TIME`, into the tray (or straight into an adjacent silo). **Wood fuel is BACK** (was removed 2026-08-02, re-added at Glenn's request — this time a **visible FUEL slot**, not the old hidden gate). **Pull ore back out**: drag the INPUT slot onto the bag (`smelter_withdraw`). Mining the furnace spills tray + ore + fuel. Window: INPUT (drag-out to unload) · FUEL (orange when stocked) · fire/progress · TRAY. Tree Grower unchanged. **Silo** — wide u32 bulk storage past 99; E pours 99-stacks; a smelter beside a silo casts bars straight in. Loaded silo refuses mining + smash.
- **Storage Barrel (`barrel.odin`, 2026-08-02, save v17):** a wooden **4×4 chest** crafted at the Bench (8 Planks; unlocks the moment you hold a Plank). Placed like a machine; **click it to open a 16-slot grid** you drag stacks to/from the bag (`barrel_store`/`barrel_take`). Records in `Sim_State.barrels` [16], keyed by (level, tile), saved; needs lasting ground + a free record (mirrors the silo). A **loaded barrel refuses the pick** until emptied (nothing lost). Hand-organized overflow — distinct from the silo's proximity-fed bulk u32. Reuses the smelter drag plumbing (`ui.drag_barrel`, -1 = from bag).
- **Drag-to-drop ground piles (2026-08-02):** the **Q "drop stack" replacement** — with the bag open, **drag any stack out onto an open ground cell** to lay a pile (`Item_Drop` event → `handle_item_drop`, placement.odin). Lands on the exact cursor cell (stacks to 99), refused with a notify if solid / occupied by another item / out of `PLAYER_REACH` / full — nothing lost. This is how you **feed the smelter/silo auto-pull hoppers by hand**, and the reusable primitive for future automation pipelines. Built on the same bag-drag as the smelter/barrel windows (release over world instead of a window).
- **Dimensions + Auto-Miner:** spawner opens ephemeral themed worlds (Metal/Gold/Runic). Auto-Miner = snake tunneling to nearest ore, wide-count haul, gem-fed speed tiers (emerald×1.5→jade×2→diamond×3→hel×5). Anchors its dimension while working; catch-up on re-entry amortized (G6 fixed — no stall).
- **Runic tier obtainable:** Runic Dimension Spawner (500 Gold Bars + 20 Cloud Stone at Rune Altar). Cloud Stone softlock fixed (plain clouds 20% hash-drop stone; puffy animated sky).
- **Structural gravity (`gravity.odin`), now cell-aware:** faller test is `is_faller(w,x,y)` — unconditional `.Falls` types (Wood, Leaves, **Dirt**) OR a `.Falls_Placed` type on a `.Placed` cell (**placed Stone**). A faller stays up only while a 4-connected chain links it to an anchor (any solid non-faller, or the map edge). Cut the last link → the hanging piece detaches and slides at `FALL_SPEED` 3 tiles/s. **Landing: `.Settles` types (Dirt, placed Stone) re-stack as TILES sand-style** (re-marking `.Placed` so stacks keep falling); everything else crumbles to **drops** (felled tree → logs+leaves). Stacking is order-safe (`r` recomputed each frame off the live grid). Detach fires from `Tile_Mined`; motion is step 6b; `draw_falling_blocks` read-only. `Gravity_State` pool [256], NOT saved.
- **Placed-block tracking:** `Tile_Flag.Placed` set on every player placement (`placement.odin`), cleared on mine (`handle_tile_mined`) and when lifted into the fall pool, re-marked on settle. Lives in `World_Grid.tile_flags` → **saved wholesale** (persists). This is what lets placed Stone fall while identical natural cave Stone stays inert.
- **Shaft-mouth + starter-earth reward (`render.odin` / `events.odin`):** `draw_shaft_mouth` apron fade is squared falloff over `SHAFT_APRON_REACH` (=4) so the brown scuff hugs the lip. Shared const + `in_shaft_apron(w,x,y)` (world.odin) mark exactly the scuffed tiles; **mining a tile in that apron drops the rock on the ground AND banks a `Dirt` clod straight to the bag** with a **collect mote** (`spawn_collect_mote`, particles.odin — homes to the player; `Particle` gained `homing`/`target`). `Dirt` is a placeable building block (item+tile, mines back, obeys gravity). **Detailed 2026-08-02:** the apron cap-band **stone now renders as soil-veined loam** (`draw_pixel_loam_stone`, hashed per cell) instead of flat gray — so the dirt-yielding stratum reads distinct; plus **grit in the throat walls + roots dangling from the lip** added to `draw_shaft_mouth`.
- **Door (`door.odin`, player-permeable wall):** craft at the Bench (4 Plank), place a **2-tall** pair (foot cell + the one above). It is **solid rock to everything** — never falls, full gravity anchor, falling blocks rest on it, **enemies walled out** — with ONE exception: the **player always phases through** it (no open/close, no button). The exception lives entirely in `move_body`'s `is_player` (physics.odin, renamed from `pass_doors` 2026-08-06 when the same exception grew to cover structures too — see the header bullet): the player's call passes `true`, every other body keeps the default `false`. `is_solid`/gravity/placement all read the door as plain solid rock. Mining either half removes the whole door for one `Door` item. `draw_pixel_door` (Pixel_Door style) knows top/bottom via a neighbor check.
- **Hold-to-place:** right-click held paints a run of blocks, one per tile (`Input_State.place_last` dedupes the sweep).
- **Q "drop stack ahead" REMOVED (2026-08-02), replaced by drag-to-drop:** the old *keybind* mechanic is gone (`Action.Drop_Item`, `Event_Type.Item_Dropped`, its poll/binding/settings row). Dropping is now a **deliberate drag** out of the bag onto a ground cell (see "Drag-to-drop ground piles" above) — precise, refused on invalid targets, no "toss ahead" guesswork.
- **Floating combat text (`floating_text.odin`, 2026-08-02):** damage numbers pop off the player and rise/fade — red `DAMAGE_COLOR` on every hit taken (enemy/fireball/lava/fall), green `HEAL_COLOR` on a potion drink. Fixed pool [32] in `Game_State.floating_text` (transient, not saved); update step **9b**, `draw_floating_text` in the world camera pass. `spawn_damage_number(store, pos, value, color)` is generic — pointing it at enemies later is a one-liner.
- **Rune-plate notifications (`ui.odin` `draw_notifications`, 2026-08-02):** guidance popups are now inscribed plaques — dark bordered plate, gold corner ticks, two flanking `draw_rune` glyphs per side (Elder-Futhark-style line staves, varied per message), a slow shared gold pulse. `draw_rune(id,x,y,w,h,col,thick)` holds six glyph shapes.
- **Tutorial hints + HUD craft chip (2026-08-02):** one-shot rune-plate hints on first **pickaxe** ("right-click into PICK, then hold left-click"), first **wood log** ("press [C] to craft"), first **flower** ("brew potions"), first **crafted wand** ("right-click to equip it — mine at range"). Each gated by a transient `*_hint_shown` flag on `Game_State`. Plus a persistent dim `[C] Craft   [TAB] Bag` chip bottom-left in `draw_hud` (binding-driven) — hand-crafting had no world anchor, so it gets a standing reminder.
- **Dirt tile art (2026-08-02):** `Pixel_Dirt` draw style + `draw_pixel_dirt` (earthy fill + pebbles/grit, fixed pattern) — placed dirt reads as soil, not a flat brown square.

### Controls (quick ref — full in PLAYTEST.md)
A/D move · W/Space jump · L-click hold mine (PICK mines adjacent; a valid WPN wand target takes priority; WPN sword swings at an enemy) ·
R-click place (hold to paint), or **right-click a bag item to equip gear / drink a Health Potion** · TAB inventory · C craft ·
E interact (portal/ritual/blueprint chest/empty silo/open station/open barrel) · ESC close windows / pause · F1 debug menu · F3 debug overlay.
*(Click a barrel/smelter/silo tile in reach to open it. In the smelter: drag ore→INPUT, wood→FUEL, drag INPUT out to unload, drag TRAY out to collect. **With the bag open, drag a stack out onto the ground to drop a pile** (feeds the auto-pull hoppers). Equip a wand from the bag to mine with it.)*

---

## 5. What's queued (open work)

> **Raw idea backlog: `gnipa_project/ideas.md`** — unscoped design ideas parked
> before they're lost (2026-08-05: persistent altar rune-halo → 1-min Fly buff in
> range; cave glowing-berry moss → 20-sec Leaf-Fall in cave 1). Graduate them here
> when picked up.

### Gravity follow-ups (priority-ish)
1. **Place-anywhere ANCHOR block** — Glenn's stated endgame: a placeable tile that anchors structures in mid-air. Hook `is_anchor_cell` now cell-aware and live; `.Placed` tracking exists — so this is newly within easy reach.
2. **Placed GRASS falling** — placed **Stone** now falls sand-style (via `.Falls_Placed` + `.Placed` cell bit + `.Settles`); **Grass is the only leftover** — deliberately left surgical. Trivial add: `.Falls_Placed, .Settles` on the `Grass` terrain row. *(Placed-stone/grass falling was the old §5.2 — now mostly closed.)*
3. **Enemy/Garm smashes don't trigger falls** — only player `Tile_Mined` does (deliberate slice scope; placed Stone/Dirt follow the same rule). One call in `smash_tile` adds it if wanted.
4. **`GRAVITY_ALL` const** — flips to full cave-in physics (all mineable tiles fall, anchored only to map edges). Wired but **UNPLAYTESTED**.
5. **Save-during-fall** drops airborne blocks (pool not in `Save_Data`) — rare, cosmetic; harden only if it bites.
6. **`blueprints.md`** — blueprints A/B/C read apart by **seal color** (bronze/silver/gold, matching each ritual's material cost). Their new world chests now carry that color on a distinct rune-lock silhouette; the bag icons themselves are still owed distinct silhouettes + ritual particles if they want to go further.

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
**Golems are not attackable by Builders or Garm** (2026-08-06, Glenn's call
after `architecture_findings.md` flagged it): golems never register in
`entity_map` and are found only via a bespoke scan (`nearest_deployed_golem`)
called exclusively by Draugr — so only Draugr can ever damage a deployed
golem. This is intentional, not a gap to close reflexively — it mirrors
`den_protected` already shielding golem work from builder interference.
Automation-base defense (the "nothing threatens your machines" gap
`ideas.md`'s enemy-roster brainstorm names) is left for a **future dedicated
enemy** (the anti-machine gnawer/hoard-thief idea), not by teaching existing
Builder/Garm AI to target golems.

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
- `pixel_style.md` (root) — reusable art direction for the dark, richly shaded Norse pixel style established by the blueprint chest; includes palettes, material recipes, procedural-rendering rules, character/environment direction, and a generation prompt.
- `upgrade_system.md` (root) — design plan for a wand/gear upgrade GUI (not built).
- Also: `ai_algo.md` (Builder AI algorithm), `gem_progression.md` (gem ladder + gem dimensions, partly shipped).

> The old `next_session.md` living handover was folded into this file on
> 2026-08-01; context.md is now the single handover. Long-form session history
> lives in git and `Work_done.md`.

---

## 8. Recent shipped history (compact — git + Work_done.md carry the long form)

- **2026-08-06 walk-through structures + golem stuck-loop fix + Quick Clay** (195 tests): three-part session. **Player passes through structures** (bench/barrel/smelter/silo/altars/blueprint chests) sideways only, still lands on top — `move_body`'s door-only `pass_doors` flag generalized to `is_player` with a new `horizontal` axis split (see header bullet). **Root-caused and fixed a real stuck-golem save**: `golem_assign_gather`'s zone-distance climb-back heuristic misfired on a legitimate marked-resource trip, verified fixed via a 60-simulated-second headless replay of the actual save file (`load_game` into a throwaway diagnostic test, never written back). **Quick Clay** (Glenn's request): golem self-locomotion (bridging, vertical-recovery pillaring) now costs nothing — a free, instant, self-dissolving `.Quick_Clay` foothold replaces real pack material for movement only; monument/delivery jobs still spend real material. See header bullets for both.
- **2026-08-05 cursor-centered wheel zoom** (147 tests): ordinary wheel zoom now captures the world pixel beneath the mouse and adjusts a transient `cam_pan` throughout the existing eased zoom so that pixel stays under the pointer—no modifier required. Once the player starts moving, the offset gently eases home to the normal player-centered view; level/spawn camera snaps clear it immediately, and level-edge clamping still wins. Shift remains dedicated to deliberate equipment reclaim. Camera state is transient and does not affect saves.
- **2026-08-05 builder art pass** (146 tests): replaced the Builder's two flat brown rectangles with a compact **12×14 chest-style dvergr sprite**: heavy charcoal outline, shaded rust-red beard, leather work clothes, iron brow band/bracers/boots, amber eyes, and a pixel masonry pick. Two footfall frames animate from world movement; the AI's existing state now drives distinct visuals—carried blocks use their actual terrain color, while hunting/escaping/recent work raises the pick and hunting turns the eyes ember-red. Physics remains the original 0.8×1 tile body. Concept: `sprites/builder_concept.png`.
- **2026-08-05 workbench art pass** (146 tests): replaced the placed Bench's generic full-cell glowing inventory icon with a dedicated **20×14 chest-style Norse workbench** (`draw_crafting_benches` / `draw_pixel_crafting_bench`): thick highlighted oak slab, dark iron corner caps/foot shoes, rivets, braced legs, vise, resting mallet, and one restrained pulsing brass rune boss. It is a render-only overlay; placement, interaction, and collision remain one cell. Concept sheet: `sprites/crafting_bench_concept.png`.
- **2026-08-05 notifications always on top** (146 tests): `draw_notifications` is now the final call in `draw_ui`, after floating inventory/storage/crafting windows, tooltips, dragged icons, books, menus, and full-screen modals. Blueprint pickup and other important feedback can no longer be hidden behind an open inventory.
- **2026-08-05 falling-tree visual parity** (146 tests): kept the reverted/original square tree art and fixed the actual transition mismatch. `Falling_Block.source_*` retains each airborne tile's original coordinate, so falling Wood reuses the exact atlas variant it showed while standing instead of switching to the fallback procedural texture. Leaves already share `draw_pixel_leaves` in both states. The richer experimental direction remains documented only in `pixel_style.md` for a later pass.
- **2026-08-04 blueprint chests** (146 tests): replaced all four loose world blueprints with solid permanent rune-locked coffers (`blueprint_chest.odin`). First click/E creates a saved normal 4×4 storage record with the blueprint in one ordinary slot; the full inventory accepts other items immediately, and the chest remains usable after the blueprint is taken. Bag-full refusal is lossless, old v21 loose drops migrate on load, and manually dropped blueprints re-seal. New compact 16×11 procedural pixel art: arched oak, iron straps/rivets, pulsing sky/bronze/silver/gold rune locks; generated concept sheet saved at `sprites/blueprint_chests_concept.png`.
- **2026-08-02 blueprint-colors + text fix** (build green): merged the `visuals/blueprint-art` worktree (branch was 18 behind, 0 ahead — clean auto-merge) — the three blueprints stop being pixel-identical, each tier gets a **seal-wax color** (bronze A / silver B / gold C, echoing its ritual's material cost) across the icon, ground/table swatch, and the ground-drop pulse glow (`item_art.odin`/`items.odin`/`render.odin`). Then a text bug: raylib's default font is ASCII-only, so every **em-dash (`—`) in drawn text rendered as `?`** — the title showed `? III ?`, the char-pick line had two. Replaced `—`→`-` inside string literals across 13 files (70 lines; comment em-dashes left intact).
- **2026-08-02 storage + smelter-fuel + drops session** (124 tests, save v18): the door committed, then four features. **Storage Barrel** (`barrel.odin`, save v17) — 4×4 chest, Bench recipe (8 Planks), click-to-open drag grid, records in `Sim_State.barrels`. **Smelter wood fuel re-added** (save v18, `Sim_Tile_Data.fuel_count`) — visible FUEL slot, 2 wood/bar, auto-pull now grabs wood too; plus **pull ore back out** (`smelter_withdraw`, drag INPUT→bag). **Drag-to-drop ground piles** (`Item_Drop`/`handle_item_drop`) — the Q-drop replacement, feeds the auto-pull hoppers, primitive for future automation. **Shaft-mouth detail** — soil-veined loam stone (`draw_pixel_loam_stone`) + throat grit + dangling roots. Carried Glenn's playtest tweak (basic wand reach 2→3, mining.odin reformatted to tabs); reconciled `wand_mines_at_range_for_mana`. Also wrote `upgrade_system.md` (design plan for a future wand/gem upgrade GUI — not built).
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
