# Fable — read this first (written 2026-07-13, end of dimensions session)

Hei! Last session with Glenn was great. Here's your running start.

## What we're building

The **Parallel Dimensions pillar** (`draft1_machines.md` §7): craftable
spawners open ephemeral themed mining worlds. The first slice SHIPPED this
session and Glenn playtested placement — it works.

## State of the code (all on master, 72/72 tests green, save v11)

- `src/dimensions.odin` — themed spawners (Metal/Gold) crafted at the Rune
  Altar; **the recipe's metal = the world's riches** (Glenn's rule: 4 Iron
  Bars → iron-rich world, 4 Gold Bars → gold-rich). `LEVEL_DIMENSION :: 4`,
  ephemeral regen-from-seed, Dimension_Gate returns home.
- Themes are pure table data: `dimension_table` holds a
  `veins: [4]{tile, pct}` list per kind — a new world = one row, no code.
- NOT yet playtested in-game: the Gold spawner visuals (gilded glow).

## Next up (in order — details in `gem_progression.md`, design agreed)

1. **Silo machine** — bulk storage >255 (u8 ground-stack cap). Prerequisite
   for everything "1000x". (`draft1_machines.md` §7.6 step 1)
2. **Gem ladder** — Emerald(cave1)→Jade(cave2)→Diamond(cave3)→Hel Gem(boss
   depths)+Sky Crystal(sky, revive unused Aether_Ore). Sparse in nature,
   depth-gated like silver/gold. Pure table work.
3. **Dimension Blocks before any 3rd theme** (§7.6 step 3) — one spawner
   tile + consumable blocks carrying kind+seed; spawner-per-theme doesn't
   scale.
4. **Gem dimensions with hazards** — richer = nastier: lava pass (exists in
   cave gen), new Poison_Gas tile (walkable+damaging, rides hazard_timer),
   mobs-on-entry (BLOCKED: Undead/Fire_Sprite have no AI yet).

## Read before coding

`CLAUDE.md` (mandatory rules — tables not switches, fixed arrays, append-only
enums for saves), then `plan.md`, then `next_session.md`. Save layout changes
trip the size assert in `save.odin` — bump SAVE_VERSION + expected size
together (probe via a temp test logging `size_of(Save_Data)`).

## About Glenn

Direct, playtests quickly, likes designing by conversation — offer concrete
options with a recommendation. He chose the fun slice (spawner) before the
prerequisite (silo); meet that energy but keep the prerequisites visible.
Build check: `odin run src` · tests: `odin test src`.
