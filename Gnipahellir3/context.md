# context.md — Source of Truth

**This file is the main source of truth for Gnipahellir3. Read it first every
session; update it at the end of every session.** It is a living snapshot: what
the game is, where the code stands right now, and what's queued next. When it
disagrees with older docs, trust this file — then reconcile.

- **Last updated:** 2026-08-04
- **Branch:** master · **Build:** green (`odin run src`) · **Tests:** 144 green (`odin test src`)
- **Save version:** 21 (`gnipahellir_save.dat` ≈ 3,160,512 bytes; **v21** appended `Equip_Slot.Charm_2/Charm_3` for the three-socket charm belt—the extra bytes consume padding, so total size is unchanged; **v20** added the Void Charm and saved buffer; **v19** added the pickaxe Tool slot. Old saves reset on each bump.)
- **Recent HEAD:** a UI/feel pass (uncommitted at session start, committed 2026-08-03): **windows auto-center as a pair** when the crafting+bag open together (no more forge spilling off-screen) yet **respect hand-drags** (`win_moved`); a **bottom-center placement chip** showing the selected block (click = open bag); a **vertical camera deadzone** so jumping doesn't bob the view when zoomed in; the **Tree Grower's sapling stalk now climbs the full trunk height** before the tree pops in; and **wands no longer strike structures** (machines/stations/spawners/altars — reclaim with the pick). Prior HEAD: blueprint seal-colors + em-dash→ASCII text fix; storage barrel + smelter wood-fuel + drag-to-drop piles. Carries Glenn's tweak: basic wand reach 2 → 3.
- **Current worktree:** player-only one-tile auto-step is in progress. Collision rises immediately, while transient `player_step_visual_y` eases the sprite upward so ledges no longer produce a visible one-block pop; consecutive stair steps preserve visual continuity. Equipped wands now paint a faint tier-colored outline plus six moving edge motes around the valid hovered mining target; the render cue shares `wand_target` validation with the actual shot. Silver-wand mana cost is tuned from 5 to 3 per shot (same cadence/reach). The base Sword and all five iron armor recipes now require Iron Bars instead of raw ore. Shift-click splits a bag stack into the first empty slot; bag-to-bag dragging moves, consolidates matching stacks to 99, or swaps unlike items without loss. Placed equipment is protected from ordinary mining: click/E interacts, while Shift+holding left-click for 0.8 s with an equipped pickaxe deliberately reclaims it; moving away or releasing cancels, and loaded or active structures refuse with a specific message. Hover labels teach both actions and a reclaim outline fills with progress. The Pickaxe is equippable in its own **PICK** (`.Tool`) slot, independent from the restored **WPN** slot for swords/wands. A valid wand target takes mining priority; otherwise the equipped pick remains the nearby fallback. Reclaim still asks the player to put an active wand away. The charm belt now has **CHM1–CHM3**: right-click fills the first empty socket, duplicates are refused, and each socket unequips independently. The forge-tier **Void Charm** (4 Silver Bars + 2 Gold Bars + 1 Emerald) works from any socket and reveals a saved VOID box below the bag: its displayed stack can be recovered until another stack replaces and permanently erases it. Cave 1 now spawns a third builder in the central cavern, matching the three-builder population of caves 2 and 3. Optional Spall profiling instrumentation is also present.

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
1 input · 2 player · 3 enemies · 4 projectiles · 5 mining · 5a equipment reclaim · 5b sim (smelters/growers) ·
5b2 miner (dimension only) · 5c station-focus · 5d recipe-unlocks · **5e ritual (offering swirl)** ·
6 process_events · **6b falling-blocks (gravity)** · 7 notifications · 8 ambience · 9 particles · 10 audio.

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
- **Door (`door.odin`, player-permeable wall):** craft at the Bench (4 Plank), place a **2-tall** pair (foot cell + the one above). It is **solid rock to everything** — never falls, full gravity anchor, falling blocks rest on it, **enemies walled out** — with ONE exception: the **player always phases through** it (no open/close, no button). The exception lives entirely in `move_body`'s `pass_doors` (physics.odin): the player's call passes `true`, every other body keeps the default `false`. `is_solid`/gravity/placement all read the door as plain solid rock. Mining either half removes the whole door for one `Door` item. `draw_pixel_door` (Pixel_Door style) knows top/bottom via a neighbor check.
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
- Also: `ai_algo.md`, `gem_progression.md`, `architecture_findings.md`, `sprites_prompt.md`, `blueprints.md`, `PLAYTESTER_GUIDE.md`.

> The old `next_session.md` living handover was folded into this file on
> 2026-08-01; context.md is now the single handover. Long-form session history
> lives in git and `Work_done.md`.

---

## 8. Recent shipped history (compact — git + Work_done.md carry the long form)

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
