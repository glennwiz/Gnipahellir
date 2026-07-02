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

- [ ] Port binary save/load (world grids, player position + inventory, enemy state, current level)
- [ ] Port persistent stats system (20+ metrics: deaths, depth, ore collected, distance, etc.)
- [ ] Extend save format for Builder state (goal, den anchor, shell progress, carried block)
- [ ] Save-on-quit + continue-from-main-menu flow

**Milestone:** quit mid-run, relaunch, continue exactly where you left off — builders included.

## Phase 2 — Port audio (from G2)

- [ ] Port audio system (64 slots, 16 channels, music streaming, fades)
- [ ] Re-map G2's event-driven sound triggers onto G3's event types
- [ ] Copy `sounds/` asset library; audit which of the 97 sounds map to G3 actions
- [ ] **New:** builder work sounds — distant digging/placing audible before visual contact
- [ ] Ambient cave loop + surface loop
- [ ] Master/SFX/Music volume sliders (persisted)

**Milestone:** every player and builder action has sound; caves have atmosphere.

## Phase 3 — Port game loop systems (from G2)

- [ ] Crafting system (recipes at Crafting_Bench; start with G2's 5, extend per G3's plan.md)
- [ ] Item placement with validation rules (drag from inventory to world)
- [ ] UI windows: inventory (B), character (C), crafting (bench proximity), tooltips
- [ ] Multi-level plumbing: level generation/save/transition for surface + 3 caves + 1 sky tier
- [ ] Wire G3's progression: blueprint drops → sky ritual (consumes materials) → cave unlock

**Milestone:** the full design loop is playable start to finish, even if rough.

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
- [ ] Phase 1 next — port save/load + persistent stats from G2
