# Blueprints

> **DESIGN NOTE (Glenn):** Blueprints are a very important part of the game,
> so all blueprints need to have **original recipes** and **original looks**.
> They should have **particles around them**, and be **easy to see** but
> **pretty to look at up close**.

---

## Current state (audited 2026-08-01)

Blueprint A, B, and C are **pixel-for-pixel identical as items** — only their
name strings differ. They are functionally three distinct progression tiers.
This is the gap to close: the icons don't communicate that they're different,
and none of them have particles.

### Item definitions — identical except name

`src/items.odin:39-41`

| Item | Name | Color | Place tile |
|---|---|---|---|
| Blueprint_A | "Blueprint A" | `{80, 160, 255, 255}` | `.Air` |
| Blueprint_B | "Blueprint B" | `{80, 160, 255, 255}` | `.Air` |
| Blueprint_C | "Blueprint C" | `{80, 160, 255, 255}` | `.Air` |

### Art — copy-pasted identical

`src/item_art.odin:508-510` — all three rows share the same `BLUEPRINT_GRID`
and the same palette:

```
{BLUEPRINT_GRID, {{226,206,162,255}, {188,164,118,255}, {}, {178,60,42,255}, {}}}
```

Only `Sky_Blueprint` (line 511) has its own distinct blue-white look.

### Function — genuinely different (three tiers)

Each blueprint is a separate enum value tied to a progression tier, with a
**different ritual cost** and a **different unlock**:

| Item | Tier | Ritual cost (`structure_costs`, levels.odin:255) | Unlocks | Spawns |
|---|---|---|---|---|
| Blueprint_A | 0 | 8 Cloud Stone + 4 Plank | Cave 2 (Deep Cave) | sealed chamber below surface (idx 141,94) |
| Blueprint_B | 1 | 12 Cloud Stone + 6 Silver Bar | Cave 3 (Gnipahellir) | in the Deep Cave |
| Blueprint_C | 2 | 20 Cloud Stone + 10 Gold Bar | boss gate — wakes Garm | in Gnipahellir |

So the **recipes already differ** (that half of the note is satisfied) — it's
the **looks** and **particles** that are missing.

---

## What "done" looks like (per the note)

1. **Original looks** — each blueprint reads as its own object at a glance.
   Suggested direction that fits the game's "cost mirrors reward" instinct:
   tint each to the material its ritual demands.
   - A → copper/plank warmth
   - B → silver sheen
   - C → gold
   - (Sky_Blueprint already has its own blue.)
   One row per blueprint in `item_art.odin` — cheap change.

2. **Particles around them** — a gentle drifting mote/glow field on the ground
   drop so it's **easy to see** in the world. There's already a blueprint
   *pulse* (`render.odin:167-177`, `BLUEPRINT_PULSE_SPEED`); particles would
   layer on top. Consider the existing particle system (`particles.odin`,
   `MAX_PARTICLES`) rather than ad-hoc draw calls.

3. **Pretty up close** — the pixel art itself should reward inspection in the
   inventory, not just be a flat tinted square.

## Relevant files

- `src/items.odin:39-42` — item table (name, color, place_tile)
- `src/item_art.odin:508-511` — pixel art rows
- `src/render.odin:167-180` — ground-drop draw + blueprint pulse/halo
- `src/levels.odin:254-259` — `structure_costs` (the ritual recipes)
- `src/levels.odin:283-303` — `tier_blueprints`, spawn placement
- `src/particles.odin` — particle system to hook into for the mote field
