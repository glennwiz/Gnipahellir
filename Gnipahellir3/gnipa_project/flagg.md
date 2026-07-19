# flagg.md — Full Gameplay + Architecture Review

**Date:** 2026-07-18 · **Commit:** 8009eac (master) · **Build:** `odin build src` PASS · **Tests:** 80/80 green

Two parallel audits: gameplay/progression/balance and architecture-vs-CLAUDE.md.
Severity: 🔴 CRITICAL (breaks a run or crashes) · 🟡 WARN (real risk, act soon) · ⚪ INFO (note, low stakes).

> **STATUS 2026-07-18 (same-day fix session, commits 720b68e..a918662, 84 tests):**
> ✅ RESOLVED: C1 (plain Cloud 20% chance-drops Cloud Stone via new `drop_pct` table
> field; sky gen is now puffy multi-row clouds, animated in render), C2 + Decision 3
> (Runic Dimension Spawner, 500 Gold Bars + 20 Cloud Stone), Decisions 1/2/4 (min-1
> dmg, Garm 75/4/3 with phases 50/25 + soak hand-math, rituals B/C cost bars),
> G1 (any same-kind spawner reclaim releases the anchor), G2 (`smash_tile` drops
> machine items), A1 (mote table sized [NUM_LEVELS]), A2 (autosave debounced 5 s),
> and G3/G8 by way of Decisions 1–3. G5 fixed later same day (5eba0f6: boxed-in
> miner gnaws through its own trail).
> ⏳ STILL OPEN: G4, G6, G7 (accepted v1), G9, A3, and the ⚪ INFO section.

---

## 🔴 CRITICAL

### C1. Cloud Stone hard softlock — 42 exist, win path needs 40, side-crafts push you under
`src/levels.odin:524-569` (gen), `src/levels.odin:101` (level frozen after first gen), `src/levels.odin:231-234` (ritual costs), `src/crafting.odin:72,101-102` (competing sinks)

Sky generation is deterministic: **exactly 42 Cloud_Ore tiles per run**, non-renewable, non-recoverable once spent (`place_tile = .Air`). Rituals A+B+C need 40. The Rune Altar (6) and each dimension spawner (8) also cost Cloud Stone. Crafting the Rune Altar before finishing all three rituals — the natural order — makes the run **unwinnable**, invisibly, discovered only when ritual B/C refuses.

**Also blocks Decision 3:** the locked Runic spawner recipe adds another 20 Cloud Stone. Fix first: make cloud regrow, make plain Cloud tiles drop stone, or add cloud veins to a dimension theme.

### C2. Runic tier still unobtainable (known issue F2, re-confirmed)
`src/crafting.odin:107-113` (8 recipes consume it), no generation site anywhere; only source is debug handout `src/levels.odin:608`

Runic_Sky_Ore has recipes but no tile placement in caves, sky, or dimension themes. The r12 wand and top gear rung are debug-only. Fix is locked Decision 3 (Runic Dimension Spawner) — but see C1 for its Cloud Stone cost.

---

## The Four Locked Decisions — all verified STILL UNIMPLEMENTED

| # | Decision | Current code | Target |
|---|----------|--------------|--------|
| 1 | Min-1 player damage | `src/events.odin:57` — `max(dmg - def, 0)` | `max(dmg - def, 1)` player-only |
| 2 | Garm retune | `src/garm.odin:23,26,31` — HP 30, bite 2, fireball 2 | 75 / 4 / 3 |
| 3 | Runic Dimension Spawner | No tile/item/theme; `Dimension_Kind` = {Metal, Gold} (`src/dimensions.odin:16-19`) | 500 Gold Bars + 20 Cloud Stone |
| 4 | Rituals B/C to bars | `src/levels.odin:230-235` — still 6 Silver Ore / 10 Gold Ore | 6 Silver Bars / 10 Gold Bars |

- **Watch item RESOLVED:** `Ingredient.count` is `int` (`src/crafting.odin:48`), `Inventory_Slot.count` is `int` — 500 does not overflow, and `inventory_count` sums across stacks. No type obstacle to Decision 3.
- **Decision 2 addendum:** phase thresholds `GARM_PHASE2_HP :: 20` / `GARM_PHASE3_HP :: 10` (`src/garm.odin:36-37`) must rescale with HP 75 or phases only trigger in the last quarter.
- **Decision 2 addendum:** `garm_fight_soak` (`src/tests.odin:1554-1638`) is a liveness test, not a balance test — needs new hand-math assertions after retune.

---

## 🟡 WARN — Gameplay

### G1. Anchored-dimension lockout if the spawner is lost
`src/dimensions.odin:70-83`, anchor release only via mining the miner base *inside* the world (`src/events.odin:316-319`)

Dimension seed hashes the spawner's tile. While a miner is anchored, `dimension_enter` refuses any (seed, kind) mismatch. Lose the spawner (player-mineable; also builder/Garm-destructible, see G2) and re-place one tile off → the anchored world is unreachable **and every spawner in the game refuses to open**. Recovery only by luckily re-placing on the exact original tile. Needs a release valve (reclaiming any spawner of that kind clears the anchor, or a timeout).

### G2. Builders and Garm destroy player machines with no drop
`src/enemy.odin:141-144` (`is_builder_mineable` = the `.Mineable` flag), `src/enemy.odin:699-707` (sets `.Void`, no drop), `src/garm.odin:246-249` (same test)

Every placed station (Bench/Smelter/Forge/Rune Altar/Sky Altar/spawners/Auto_Miner) carries `.Mineable`. A builder tunneling through a base silently deletes a Rune Altar or Dimension Spawner — feeding the G1 lockout. Recraftable but an invisible loss.

### G3. Gear ladder trivializes all combat (known issue F1, re-confirmed with numbers)
`src/items.odin:110-147`, `src/events.odin:57`, `src/enemy.odin:44`

Cumulative sets: Iron 3/1/12 → Silver 4/2/14 → Gold 7/3/17 → Runic 11/5/21 (atk/def/hp). Any chestplate makes builders (atk 1) literally harmless; gold set is immune to everything Garm does except lava and kills him in ~1.8 s of contact. Fixed by Decisions 1+2 — only lava (which correctly bypasses armor, `src/player.odin:88,198`) threatens a geared player today.

### G4. Structure templates B/C are skippable
`src/levels.odin:315-357` (ritual runs at *any* Sky_Altar), `src/placement.odin:30-32` (foundation checked only at placement time)

One tier-A altar placed early serves all three rituals; the grander B/C foundations (gold/silver blocks, `src/templates.odin:52-71`) never engage. Conversely, placing your *first* altar after finding Blueprint B/C forces the expensive foundation immediately.

### G5. Miner snake can wall itself in and sleep permanently on a live world
`src/miner.odin:115-117` (Miner_Body impassable to snake), `src/miner.odin:97-101` (`asleep` never resets)

If the trail seals the head off from remaining ore, the miner declares "played out" with ore left. Hand-mining the body doesn't wake it; only recovery is withdraw + reclaim (losing the anchor). Either let the head chew its own body as last resort, or reset `asleep` when reachable ore reappears.

### G6. Miner catch-up can hitch hard on dimension entry
`src/miner.odin:75-95` — replays every missed tick in one frame, each a full-grid BFS (3 × ~20k-cell buffers, `src/miner.odin:122-154`). Hours away at tier 4 (0.6 s/tick) = thousands of BFS passes in a single frame. Cap the replay or amortize over frames.

### G7. Ephemeral regen = every spawner is an infinite ore source
`src/dimensions.odin:80` drops `generated` on entry, restocking from seed. Intended v1 behavior, but note: the "1 strip-mined Gold world ≈ 1 Runic spawner" economy is a *time* cost only; one 4-bar spawner ultimately funds unlimited runic spawners.

### G8. No bulk sinks yet (known issue F3, re-confirmed)
Most expensive shipped recipe is 20 Stone_Block; full gold gear ≈ 30+30 ore, hand-gatherable. Miner over-produces ~50×. Decision 3 is the intended fix. Related: smelter tray caps at one 99-stack (`src/sim.odin:83-84`) — casting 500 bars ≈ 25 min through one smelter + ~167 logs of fuel. The Silo need is real and on schedule.

### G9. Permadeath is soft against force-quit
`src/save.odin:100-108` (deletion only in `save_on_quit`), `src/save.odin:68` (load rejects dead player)

Killing the process on the death screen resurrects the last autosave. Known roguelike-lite tradeoff — decide if permadeath should be firm.

---

## 🟡 WARN — Architecture

### A1. Latent out-of-bounds panic: `level_mote_colors` has 4 entries, NUM_LEVELS is 5
`src/particles.odin:129-134` (table), `src/particles.odin:154` (index by `gs.level_index`), `src/levels.odin:17-18` (`LEVEL_DIMENSION = 4`)

`update_ambience` indexes the table whenever the probed tile is `.Air`. Dimensions currently never generate Air, but any future gen change — or the F1 debug stamp (`src/input.odin:288`) — placing Air in a dimension is an instant bounds panic. One-line fix: size the table `[NUM_LEVELS]` or clamp.

### A2. 2.6 MB heap alloc + synchronous disk write per autosave, inside the frame loop
`src/save.odin:39` (`new(Save_Data)`), `src/main.odin:65-68` (fires whenever `save_dirty`), `src/events.odin:38-41` (`save_dirty` on every Tile_Mined/Item_Pickup)

Rapid mining = one 2.6 MB alloc + blocking write per mined-tile frame. The only heap allocation and blocking I/O in the gameplay loop. Debounce (e.g. save at most every N seconds while dirty).

### A3. Debug-menu writes violate input.odin discipline (GAME_DEBUG-gated)
`src/input.odin:288` (`set_tile` stamp), `src/input.odin:300-313` (writes player hp/mana, inventory)

Literal violations of "input.odin never writes World_Grid or entity data," all behind `when GAME_DEBUG`. Cleaner: route through events (e.g. `Debug_Stamp_Request`). Low priority; decide and either fix or document the debug exemption in CLAUDE.md.

---

## ⚪ INFO

**Dead / unobtainable items**
- `Iron_Bucket` — craftable (`src/crafting.odin:64`) but `Player.bucket_lava` (`src/game_state.odin:141`) is never read or written; item does nothing (plan.md promises lava pickup).
- `Potion_Health` / `Potion_Mana` — no source, no consume code.
- `Gold_Rare_Ore` — full plumbing exists (tile, item, 1:1 smelt rule, builder interest) but **no generation code places it**; debug only. Also: Work_done.md's "gold smelts 1:1" claim is doc drift — regular gold smelts 2:1 (`src/sim.odin:25-30`).

**Gem sinks thin (known issue F5, quantified)** — Jade/Diamond/Hel Gem each have exactly one sink (miner speed tier, `src/miner.odin:23-28`). Hel Gem is worst: arena-band only, behind ritual C — by the time you hold one, the content a ×5 miner accelerates is over. Becomes load-bearing only with Decision 3. Emerald is healthy. Aether_Crystal: exactly 6/run, one sink (Aether_Charm), fine.

**Combat/UX notes**
- Bare hands cannot attack (`src/player.odin:126`, base Attack 0) — weaponless player can only flee. Not a softlock (Sword = 2 iron ore + 1 plank).
- Win fires on Hell_Key **pickup** (`src/events.odin:119-120`), not the plan.md "Victory Altar interact" — works, doc drift.
- `spawn_ground_item` fallback can clobber another stack when 25 nearby cells are full (`src/loot.odin:80-83`) — protects the Hell Key by design; negligible in practice.
- `spawn_ground_item` silently truncates stacks > 99 (`src/loot.odin:60`) — unreachable today, but the miner's u32 hauls must never route through it.

**Save system**
- `Persistent_Stats` file has no version field — raw memcpy with size check only (`src/save.odin:158-170`); next struct change should add a version int.
- `deepest_cave` stat (`src/game_state.odin:316`) is never written — saves as 0 forever.
- `ambience_timer` (`src/game_state.odin:332`) unsaved and uncommented as intentionally-transient.
- Autosave result ignored (`src/main.odin:67`) — persistent disk failure is invisible.

**Minor architecture**
- `build_templates` (`src/enemy.odin:96-99`) is the one non-`@(rodata)` global (slice initializers can't be constant) — documented, but writable-by-accident.
- One bare `enemy_free` at `src/enemy.odin:619` — spawn-abort before entity-map entry exists; compliant in spirit.
- `handle_entity_died` (`src/events.odin:286-296`) calls `despawn_enemy` with an unvalidated index; safe only because `despawn_enemy` re-checks bounds (`src/enemy.odin:646`) — never remove that inner check.
- `log_action` can panic on a single log line ≥ ~246 chars (`src/debug_log.odin:23,34`) — debug builds only, no current line comes close.
- Dead constants: `MAX_AUDIO`, `MAX_LEVELS` (`src/types.odin:19-20`) referenced nowhere.
- Mixed audio idiom: some code pushes `Play_Sound` events, siblings call `audio_play` directly (`src/sim.odin:107` vs `175`; `src/miner.odin:212-243`) — pick one.
- Vein-count doc claims (~4/9/13+8/6) plausible from rates (expected ~7/~12/~12) but only sky counts (42 cloud, 6 aether) verified exactly; gem test asserts only `>0 && <40`.

---

## ✅ Positive confirmations

- **Architecture law holds:** no `[dynamic]`/`append` anywhere; render provably read-only (no mutation, no update/input calls); sim never calls draw/input; types/game_state pure; behavior table-driven (34 `@(rodata)` tables); entity-map discipline honored incl. `despawn_enemy` routing; `game_update` fully explicit and ordered; zero TODOs; all fixed stores bounds-checked (events drop-with-telemetry, particles/projectiles skip, notifications evict).
- **Gate chain sound:** Bench→Smelter→Forge→Rune Altar ladder enforced; rituals strictly sequential; no dig-around sequence breaks (levels are separate grids); Hell_Key drop guaranteed and non-losable; Sky Altar not softlockable via mining.
- **Save/dimension interplay sound:** full Level_Store + Dimension_State (incl. miner + haul) saved; quit-inside-dimension resumes; won/dead runs clear the save; size tripwire `#assert` in place.
- **Stack plumbing ready for 500 bars:** `Ingredient.count`/`Inventory_Slot.count` are `int`; bag holds 2,376 of one item; miner haul u32 withdrawn in 99-batches.
- **Miner clear-time and world-yield doc claims check out** (~2,300 ore/Metal world, ~1,270 gold/Gold world, tier-4 ≈ 20 min region).

---

## Priority order (recommended)

1. **C1** Cloud Stone softlock — must land before/with Decision 3 (its recipe adds +20 cloud).
2. **The four locked decisions** — no obstacles remain; build order already in Work_done.md.
3. **G1 + G2** — anchor release valve, machine-destruction drop (they compound each other).
4. **A1** — one-line OOB fix; **A2** — autosave debounce.
5. **G4, G5, G6** — template skip, miner self-trap, catch-up hitch.
6. INFO cleanup opportunistically (dead items, doc drift, stats versioning).

*Compiled by Fable from two parallel sub-agent audits (architecture: 57 tool calls; gameplay: 34 tool calls), 2026-07-18.*
