# Progression Review — full audit (2026-07-14)

Scope: every gate, gear tier, tool tier, and cost in the shipped code
(recipe_table, item_stat_bonus, garm.odin constants, gen code, events.odin
damage path), checked against the intended endgame: **"Garm should need end
gear, and end gear should need ~1000 gold"** (Glenn, this session).

## 1. The tracks as they exist today

### Gates (world progression) — WORKS
| Gate | Cost | Notes |
|---|---|---|
| Cave 1 | free | |
| Cave 2 | Ritual A: 8 Cloud Stone + 4 Plank | trivially cheap — fine as a teaching gate |
| Cave 3 | Ritual B: 12 Cloud Stone + 6 **Silver Ore** | raw ore, pre-bar economy |
| Garm wakes | Ritual C: 20 Cloud Stone + 10 **Gold Ore** | raw ore, pre-bar economy |

### Stations — WORKS, reads well
Bench (4 plank) → Smelter (8 stone + 2 iron ore) → Dvergr Forge (10 stone +
3 iron bar) → Rune Altar (2 gold bar + 6 cloud stone). Each tier requires
the previous tier's output. Good ladder.

### Gear (full set: sword + 5 armor pieces), cumulative stats
| Set | Attack | Defense | Max HP | Marginal cost (approx) |
|---|---|---|---|---|
| bare | 0 | 0 | 10 | — |
| Iron | 3 | 1 | 12 | ~16 iron ore + planks |
| Silver | 4 | 2 | 14 | +15 silver bars (30 ore) |
| Gold | 7 | 3 | 17 | +15 gold bars (30 ore) |
| Runic | 11 | 5 | 21 | +27 Runic Sky Ore |

### Tools — WORKS (except the top rung, see F2)
Pickaxe (adjacent) → Mine Wand (r2) → Silver (r4) → Gold (r8) → Runic (r12).
Each consumes the previous. Clean consumed-upgrade ladder.

### Bulk economy
Miner yields ~1,760 ore per Metal dimension (~1.5–2 h tier 0, ~18 min
tier 4). A Gold dimension is ~12% gold of ~10k stone ≈ **~1,200 gold ore
per world**.

## 2. Combat math vs Garm (30 HP, bite 2/1.0s, fireball 2, reach 2)

Player swing cooldown 0.35 s, same reach. Damage to player is
`max(dmg − Defense, 0)` (events.odin:57). Lava bypasses Defense
(hazard_timer path) — that part is good.

| Set | Hits to kill Garm | Garm bite after Defense | Verdict |
|---|---|---|---|
| Sword only | 15 (~5.3 s contact) | 2 (dead in 5 bites) | brutal race — the "Garm is lethal" finding |
| Iron | 10 | 1 | tight, fair fight |
| Silver | 8 | 0 bite is 2−2… **0** | already immune to bites |
| Gold | 5 (~1.8 s) | **0** (fireball also 0) | **invulnerable + melts him** |
| Runic | 3 | 0 | irrelevant — see F1/F2 |

## 3. Findings, ranked

**F1 — Defense zeroes the boss (breaks at SILVER, not even gold).**
`max(dmg − def, 0)` with bite/fireball at 2 means Defense 2 blanks bites and
Defense 3 blanks everything but lava. The final boss is a pushover at gear
tier 2 of 4. The fight the soak tests tune (66 hits landed) is a fight no
equipped player ever experiences.

**F2 — The entire Runic tier is UNOBTAINABLE.** `Runic_Sky_Ore` has a tile,
an item, an icon, and 8 recipes — and **no generation source anywhere**
(gen_sky_level places Cloud/Cloud_Ore/Aether only; sky −3 is post-launch).
Runic gear + the r12 wand exist only via the debug handout. This is the
biggest dead end in the game — bigger than the bucket.

**F3 — Nothing needs bulk. The "1000 gold" endgame has no home.** The most
expensive recipe in the game is 20 Stone Block. Full gold gear ≈ 30 gold
ore — an hour of hand-mining; you never need a dimension, a miner, or a
silo to hit the current gear cap and win. The Auto-Miner over-produces the
existing economy by ~50–100×.

**F4 — Rituals B/C cost raw ore, not bars.** The bar economy (machines-alive
session) moved Forge+ recipes to bars; the rituals were left behind. Minor
inconsistency, one-table fix.

**F5 — Gem sinks are thin (known).** Miner recipe + speed tiers only. Fine
for now; noted for completeness.

## 4. Proposal — one coherent endgame loop (Glenn's 1000-gold vision)

The pieces already on master line up almost perfectly; the fix is table
tuning plus ONE new vein row and ONE damage-rule line:

1. **Min-1 damage rule** (events.odin:57): `max(dmg − def, 1)` for damage
   to the player. Defense mitigates, never immunizes. One line.
2. **Garm becomes an end-gear check**: GARM_HP 30 → **75**, bite 2 → **4**,
   fireball 2 → **3**. Math after the change:
   - Gold set (atk 7, def 3, hp 17): 11 hits to kill (~3.9 s contact),
     taking 1/bite + 1/fireball + lava phases — losable but possible for
     a great pilot. Gold = "you can scrape a win".
   - Runic set (atk 11, def 5, hp 21): 7 hits, still 1s chip — the
     intended, comfortable win. Runic = "you out-gear hell".
3. **Runic Sky Ore gets a source that costs ~1000 gold**: a **Runic
   Dimension** — spawner (or later Dimension Block) crafted at the Rune
   Altar for **500 Gold Bars (= 1,000 gold ore)** + cloud stone; its theme
   row is `{{.Runic_Sky_Ore, 10}, {.Gold_Ore, 3}, ...}`. One fully-mined
   Gold dimension yields ~1,200 gold ore ≈ **exactly one Runic spawner** —
   the Auto-Miner (~2 h tier 0, ~20 min gem-fed) is now load-bearing for
   the endgame, precisely as designed in draft1 §7.4. Nature's 27 runic
   ore for the gear set comes from mining the runic world by hand or by
   snake. (Needs the wide-count Silo or repeated miner withdrawals to move
   500 bars — the u8/99-stack constraint finally bites, on schedule.)
4. **Rituals B/C move to bars** (6 Silver Bars / 10 Gold Bars) — costs
   roughly double in ore terms, consistent with the bar economy, and makes
   ritual C a real pre-boss checkpoint.

Resulting difficulty curve: iron→cave 2, silver→cave 3, gold→you *can*
face Garm, one strip-mined gold world→runic→you *should* face Garm.
Every system (gems, dimensions, miner, smelter chain) is on the critical
path exactly once. No new systems required — rows and constants only,
plus the Runic theme row and a `Dimension_Spawner_Runic` tile/item/recipe.

## 5. Decisions — LOCKED with Glenn (2026-07-14)

1. **Garm: 75 HP / bite 4 / fireball 3** — gold set can scrape a win,
   runic set wins comfortably.
2. **Runic Dimension spawner: 500 Gold Bars** (= 1,000 gold ore ≈ one
   snake-stripped Gold dimension).
3. **Min-1 damage rule: player-only** — `max(dmg − def, 1)` where the
   player takes damage; enemies unchanged.
4. **Rituals to bars: B = 6 Silver Bars, C = 10 Gold Bars.**

## 6. Build order (next session — tables and constants only)

1. Min-1 rule in events.odin:57 → verify: gold-set player still takes
   1/bite in a garm soak.
2. GARM_HP/BITE/FIREBALL constants → verify: garm_fight_soak retuned,
   hand-check "gold survivable, runic comfortable" math in a test.
3. `structure_costs` rituals B/C → bars → verify: existing ritual tests
   updated, notify strings show bar names.
4. Runic Dimension: theme row `{{.Runic_Sky_Ore, 10}, {.Gold_Ore, 3}}`,
   `Dimension_Spawner_Runic` tile+item+icon+glow, recipe
   `{.Gold_Bar, 500} + {.Cloud_Stone, 20}` at the Rune Altar → verify:
   spawner opens a runic-rich world; runic gear craftable from its ore.
   **Watch:** Ingredient.count type — if u8, 500 overflows; widen or split
   cost (bump SAVE_VERSION only if a saved struct changes — recipes are
   @(rodata), so likely no bump).
   **Watch:** paying 500 bars = 6 bag stacks; the crafting affordability
   check must count across stacks (it does — inventory_count sums).
5. Runic wand r12 note in PLAYTEST; playtest the full curve.
   → The Silo (draft1 §7.6 step 1) becomes the natural next build after
   this lands — moving 500 bars will make Glenn feel the u8 pain.
