# Gem Progression & Gem Dimensions — design draft (2026-07-13)

Status: **design agreed with Glenn, not yet built.** Extends the dimensions
pillar (`draft1_machines.md` §7, shipped spawner slice in `dimensions.odin`).

## The idea

Gems are a progression ladder of their own: each layer of the world hides a
gem the previous one didn't. Found sparsely in nature (discovery pacing), then
industrialized late-game by crafting **gem dimensions** — the recipe costs the
gem itself, so nature gives you the seed stock and dimensions give you scale.

## The ladder (natural spawns, depth-gated like silver/gold today)

| Gem         | Found naturally in            | Notes                          |
|-------------|-------------------------------|--------------------------------|
| Emerald     | Cave 1, deep rows             | first gem a new player sees    |
| Jade        | Cave 2                        |                                |
| Diamond     | Cave 3 (Gnipahellir)          |                                |
| Hel Gem     | Cave 3 boss-arena depths      | "deep hell gems"               |
| Sky Crystal | Sky levels                    | can revive the unused `Aether_Ore` tile |

Rarity in nature stays LOW — a handful per cave. Bulk comes only from
dimensions (matches §7.4: materials only economical via dimensions).

## Gem dimensions (late game)

Per gem, a themed spawner/block whose recipe costs that gem
(e.g. Emerald Dimension = N Emeralds + Cloud Stone + Stone Blocks).
After the vein-table refactor, a gem world is one row in `dimension_table`:
`{"Emerald Dimension", {{.Emerald_Ore, 12}, {.Iron_Ore, 3}, {}, {}}}`.

**Rule: richer world = nastier world.** Gem dimensions carry hazards; the
metal dimensions stay safe. Hazard knobs live in the theme table:

```odin
Dimension_Hazard :: struct {
    lava_pct:   u32,   // lava pools in bottom voids (gen_cave_level pattern)
    poison_pct: u32,   // poison gas pockets
    mobs:       [2]struct { kind: Enemy_Kind, count: int },
}
```

- **Lava** — reuse the cave-gen pool pass; works today.
- **Poison** — cheapest path: a new `Poison_Gas` terrain tile
  ({.Walkable, .Damaging}, low dps) — rides the existing hazard_timer damage
  for free. (`Tile_Flag.Poison` exists but has no behavior; don't build a
  flag system just for this.)
- **Mobs** — spawn on entry like `level_transition` spawns builders.
  **Blocked on enemy variety**: Undead/Fire_Sprite are empty enum branches
  today. Builder works now as a placeholder threat.

## Gem sinks (why gems matter — pick some)

- **Premium mana fuel**: draft1 §1.4's Crystal Resonator eats gems for burst
  power — ties gems into the mana pillar.
- **Gem-tier gear** above runic, or socketed upgrades on existing gear.
- **Boss/summon recipes** and the final industrial craft (§7.4).

## Build order (proposal)

1. ~~Natural gem veins in cave gen + items/tiles/icons~~ — **SHIPPED 2026-07-13**:
   Emerald (cave 1 deep rows), Jade (cave 2), Diamond (cave 3), Hel Gem
   (arena band), Aether_Ore revived on the two high sky bands. Sparse per
   level (≈4/9/13+8/6), gems roll before metals so they can't be masked, new
   `Pixel_Gem` draw style (crystal-in-rock, color from terrain_table).
   `gem_ladder_generation` test pins counts + drops. No save bump needed
   (append-only enums).
2. `Poison_Gas` tile + hazard struct in `Dimension_Theme`; lava pass in
   `gen_dimension`.
3. **Dimension Blocks (§7.6 step 3) before the 3rd theme** — spawner-per-theme
   stops scaling; one spawner tile + consumable blocks carrying kind+seed.
4. Gem dimension themes, one per gem, gated by owning the gem.
5. Sinks (resonator/gear/boss craft) — needs the mana MVP or gear design.

Silo (§7.6 step 1) remains the prerequisite for any of this being "bulk."
