# Gnipahellir — Ship Plan

Goal: merge Gnipahellir2 and Gnipahellir3 into one polished, shippable game.
Strategy: **G3 is the base** (cleaner architecture, superior Builder AI). Port G2's
mature systems into it. Every phase ends with a playable build.

See `project.md` for the full comparison of the two versions.
Note: `Gnipahellir3/plan.md` is the game *design* doc; this file is the *shipping* roadmap.

---

## v1.0 Scope (locked)

- Surface + **3 cave levels** + **1 sky tier**
- **Garm as final boss** in cave 3, driven by G3's dig-aware A*
- Builders in every cave (resource competition + raidable dens)
- Full loop: mine → craft → build sky ritual → unlock next cave → kill Garm → win screen
- Save/load, persistent stats, audio, settings, pause menu
- **Cut from v1.0** (post-launch candidates): caves 4–8, sky tiers 2–4, Undead, Fire_Sprite

---

## Phase 0 — Foundation fixes (do first, everything depends on them)

- [x] **Resolution independence in G3.** Game renders to a fixed 1920×1080 render texture,
      scaled letterboxed to the real window. Starts 1280×720 windowed, resizable, **F11**
      toggles borderless fullscreen. Mouse input transformed from window → virtual space.
- [x] **Git hygiene.** Repo initialized with baseline commit (done manually). `.gitignore`
      added at root (exes, pdb, logs, save data); stale artifacts untracked.
- [x] **Debug/release build flag.** `GAME_DEBUG` in `types.odin` (default **true** so
      `odin run src` keeps full debug tooling). Release: `odin build src -define:GAME_DEBUG=false`
      — strips action log, F3 overlay, and scan rays (scan rays also moved from always-on
      to F3-only in debug builds).

**Milestone:** G3 runs windowed and fullscreen on any monitor, repo under version control.

## Phase 1 — Port persistence (from G2)

- [x] Port binary save/load (`src/save.odin`): versioned POD snapshot of world, player,
      enemies, sim, progression, elapsed time + frame counter. Size/version-checked;
      corrupt or stale saves fall back to a fresh run (verified).
- [x] Persistent stats persistence (`gnipahellir_stats.dat`), loaded at launch, saved on
      quit and immediately on player death. Note: G3 tracks 4 metrics so far — G2's
      fuller 20-metric set lands with the systems that feed it (Phases 3–5).
- [x] Builder state in save — rides along in `Enemy_Store` (goal, den anchor, shell
      progress, carried block are all flat fields). Verified: builders resume existing
      dens after relaunch instead of starting new ones.
- [x] Save-on-quit + auto-continue-on-launch. Dead runs clear the save (roguelike
      semantics). Main-menu continue flow arrives with the menu in Phase 6.

**Milestone reached:** quit mid-run, relaunch, continue exactly where you left off —
frame counter and builder dens verified continuous across sessions.

## Phase 2 — Port audio (from G2)

- [x] Port audio system (`src/audio.odin`) — table-driven rework of G2's engine: sounds
      keyed by `Sound_ID` enum (no linear search), music streaming. G2's dynamic
      file-scanner subsystem was dropped: it allocates strings at runtime and only fed
      G2's sound-debug browser window.
- [x] Sound triggers wired to G3's existing semantic events (Tile_Mined, Damage_Dealt,
      Entity_Died, Item_Pickup, Tile_Placed) plus a generic Play_Sound event for
      one-offs (player jump).
- [x] Copied `sounds/` library (199 WAVs); 9 mapped so far — jump, mine, place, pickup,
      hurt, death, kill, builder dig, builder place. More get mapped as systems land.
- [x] Builder work sounds attenuate with distance (48-tile hearing range, floor gain
      0.1) — distant digging is audible before the builder is visible.
- [x] Cave ambience: `sound_horror_ambience.wav` as a looping stream whose volume
      follows player depth (silent on surface, full ~12 tiles below). No suitable
      surface-loop asset exists yet — sourcing one is a Phase 7 (juice) item.
- [ ] Master/SFX/Music volume fields exist in `Audio_State`; sliders + persistence land
      with the settings screen in Phase 6.

**Milestone reached:** every current player and builder action has sound; the cave has
atmosphere. Verified: all sounds + ambience stream load cleanly at runtime.

## Phase 3 — Port game loop systems (from G2)

- [x] Crafting system (recipes at Crafting_Bench; start with G2's 5, extend per G3's plan.md)
- [x] Item placement with validation rules (drag from inventory to world)
- [x] UI windows: inventory (B), character (C), crafting (bench proximity), tooltips
- [x] Multi-level plumbing: level generation/save/transition for surface + 3 caves + 1 sky tier
- [x] Wire G3's progression: blueprint drops → sky ritual (consumes materials) → cave unlock

**Milestone:** the full design loop is playable start to finish, even if rough.

### Phase 3 status (implementation done; playtest pending)

New files: `items.odin`, `crafting.odin`, `placement.odin`, `ui.odin`, `levels.odin`.

**Code-verified + smoke-tested** (builds, runs, renders, save v2 round-trips at 1.78 MB):
- Item pickup: walk over drops → inventory (stacking to 99); drops render as glinting squares
- Inventory UI (TAB): 8×3 grid, click or keys 1–8 to select, hover shows item name
- Placement: right-click places selected item; validated (reach 5, open tile, solid
  neighbour, never sealing the player in); UI clicks don't leak into mining
- Crafting (C window): 6 recipes — Plank + Crafting_Bench by hand; Smelter, Tree_Grower,
  Iron_Bucket, Sky_Altar at a bench (range 3)
- Levels: 0 surface+cave1, 1 Deep Cave, 2 Gnipahellir, 3 Low Sky. Portals at fixed
  coords (gen is deterministic), E to travel, locked portals draw red runic seals.
  Levels freeze when left; 3 builders spawn in each deep cave; sky has cloud platforms
  with Cloud_Ore, falling below the clouds returns you to the surface
- Progression: Blueprint A (cave-1 portal chamber), B and C (deep-cave vaults) →
  Blueprint_Found; sky-altar ritual (E near altar) consumes tier costs →
  Structure_Complete fanfare → cave unlock. Tier costs: A = 8 Cloud Stone + 4 Plank;
  B = 12 Cloud Stone + 6 Silver Ore; C = 20 Cloud Stone + 10 Gold Ore (boss gate, Phase 5)
- HUD: HP/mana bars, level name, selected item

**Automated test suite** (`src/tests.odin`, run with `odin test src` — 9 tests, all green):
- [x] Pickup collects drops + stacks; blueprint pickup fires Blueprint_Found
- [x] Placement: valid placement consumes; floating and out-of-reach rejected
- [x] Crafting: hand recipe works; bench recipe fails without bench, works beside one
- [x] Ritual: rejected without materials; consumes and unlocks cave 2 with them
- [x] Locked portal blocks travel, opens after unlock; cave 2 generates with builders
- [x] Level state persists across transitions in both directions
- [x] Sky fall-through returns the player to the surface
- [x] Cave 2 gen: iron + silver present, majority open space, blueprint + portal placed

**Human playtest — DONE 2026-07-04:**
- [x] UI feel: all six craftables built by hand in one session
- [x] Full loop by hand: all three rituals completed, every level visited,
      run ended by a builder kill in cave 3 (roguelike save-clear verified)

Playtest findings (tracked for later phases):
- **Ritual failure is silent** — the tester pressed E ~20 times at the altar
  with materials missing; the reason only reaches the debug log. Needs an
  on-screen notification (same handler Level_Locked needs). Phase 6 item,
  strong candidate to pull earlier.
- **Blueprints aren't inspectable** — ritual costs are invisible in-game;
  the design doc's "inspect in inventory" feature is unimplemented. Phase 6.
- **No player attack** — a hunting builder is a death sentence. Fine pre-
  Phase 5, but combat ordering within Phase 5 should account for it.
- Playtest also caught a physics regression (builders frozen against 1-high
  steps) — fixed same day with a permanent soak regression test.

**Known gaps (deliberate, tracked for later phases):**
- Smelter places but doesn't smelt — ores are used raw; smelting recipes need a Phase 3.5
  or Phase 4 slot if we want metal bars in costs
- Tree_Grower places but doesn't grow (sim system still stubbed — lava spread too)
- Iron_Bucket craftable but lava scooping not implemented
- Q (drop item) reads input but does nothing yet
- Mining costs no mana yet despite the wand flavor

## Phase 4 — Builder economy (the differentiator)

- [ ] **Shared resource pool:** builders visibly deplete the same ore veins the player wants
- [ ] **Raidable dens:** builder stockpile stored inside the den as loot; breaking in
      triggers Hunt on the intruder
- [ ] **Fix conjured bridge blocks:** builders spend carried/stockpiled blocks to bridge,
      or visibly detour to fetch one — no free matter
- [ ] Tune fetch round-trip time (~40–60s currently) against player mining speed so
      competition is felt but not oppressive
- [ ] **AI soak test:** headless/fast-forward mode; run builders for simulated hours,
      assert the progress watchdog never enters repeated 3-strike loops; soak-test the
      "player escapes hunt" transition (currently code-verified only)

**Milestone:** a player who ignores builders loses ore; a player who raids them gains it — and risks it.

## Phase 5 — Garm as final boss

- [ ] Port Garm to G3, replacing his old planner with `astar_dig`
- [ ] Keep his project phases as boss mechanics: builds center column → perimeter ring →
      floods arena with lava over the fight's duration
- [ ] Fireball attack + jump heuristics on the new pathfinding
- [ ] Boss arena in cave 3 (generated room, not open cave)
- [ ] Win condition: Garm dies → Hell_Key → win screen with run stats

**Milestone:** the game can be *beaten*.

## Phase 6 — Shippability pass

- [ ] Pause menu, quit-with-confirm (port from G2)
- [ ] Settings screen: resolution/fullscreen, volumes, key rebinding — all persisted
- [ ] Onboarding: contextual first-time prompts ("Left-click to mine"), no text walls
- [ ] Death screen: cause of death + run stats (nearly free via ported stats system)
- [ ] Main menu polish, save-slot handling, corrupt-save resilience

**Milestone:** a stranger can install, learn, play, die, and quit without confusion or a crash.

## Phase 7 — Juice pass (last, one focused week)

- [ ] Screen shake on Garm attacks and explosions
- [ ] Hit-stop on melee connects
- [ ] Mining crack decals (tile damage states before break)
- [ ] Port G2 particle effects (sparks, lava bubbles, magic sparkles, death explosions)
- [ ] Music: surface theme, cave ambience, boss track with fade transitions

**Milestone:** it *feels* good. Ship it.

---

## Working rules

- Both codebases' existing rules stay in force (G2 `RULES.md`, G3 `CLAUDE.md`):
  fat struct, event-driven, fixed buffers, no gameplay allocations, render read-only.
- Ported G2 code is **adapted to G3 idiom**, not copy-pasted (grid size, tile size,
  event enum, terrain table all differ).
- Every phase ends on a playable, committed milestone before the next begins.
- Playtest after every phase; tuning notes go in this file under the phase.

## Current status

- [x] project.md comparison written
- [x] Phase 0 complete — resolution independence, git hygiene, debug build flag
- [x] Phase 1 complete — save/load + stats persistence, verified round trip
- [x] Phase 2 complete — audio engine, event triggers, builder attenuation, cave ambience
      (volume sliders deferred to Phase 6 with the settings screen)
- [x] Phase 3 complete — automated suite green (18 tests) AND human-playtested
      end to end (2026-07-04). Known gaps (smelting, sim, bucket) tracked above;
      decide at Phase 4 kickoff whether smelting rides along.
- [x] Architecture review (suggestion.md) — all findings closed except C3/C4/C5
      (small, homes assigned) and two profile-first perf notes. Unified physics
      landed and playtest-verified.
- [ ] Phase 4 next — builder economy (shared ore pool, raidable dens, honest
      bridging, AI soak test — a minimal soak already exists in tests.odin)
