# Gnipahellir 3 — Playtest Guide

Build & run: `odin run src` (debug) · `odin build src -define:GAME_DEBUG=false` (release)
Tests: `odin test src` — headless, 144 tests, runs in about two seconds.

## Controls

| Key | Action |
|---|---|
| A / D (or arrows) | Move |
| W / ↑ / Space | Jump |
| Left-click (hold) | An equipped **Pickaxe** in the dedicated **PICK** slot works the tile in the cursor's rough *direction* — no aiming at tiles; point roughly and hold. Forward carves head+feet height, while pointing down/up digs those ways. 3 chips per tile, free. A Mine Wand in **WPN** takes priority on a valid precise target at range 3/4/8 (5/3/5 mana per shot) |
| Left-click equipment | Use it; ordinary mining never damages placed equipment |
| Shift + hold left-click | Reclaim adjacent equipment with an equipped pickaxe after 0.8 s. Moving off or releasing cancels; loaded equipment must be emptied first |
| Left-click on enemy | Sword swing (needs a sword equipped in **WPN**; 2-tile reach, damage = Attack stat, 0.35 s cooldown) |
| Right-click | Place selected item (8-tile reach, needs solid neighbour). In the open inventory: right-click gear to equip it; the pickaxe goes to **PICK**, while swords/wands swap through **WPN**. Right-click an equip box to take it off |
| TAB | Inventory (drag stacks to move/merge/swap; Shift-click a stack to split it) |
| C | Crafting window (rows green = affordable; click to craft) |
| E | Interact: portal travel / sky-altar ritual / collect from machines / open a station or smelter window in reach |
| ESC | Close **all** open windows; when none are open, pause menu (Resume / Settings / New Game / Save and Quit) |
| F11 | Borderless fullscreen |

Windows (inventory, crafting, smelter, blueprint) are **draggable** — grab
the header band and move them anywhere. Clicking a smelter (or pressing E
beside one) opens its furnace window: a 3×3 mirror of the tiles around the
fire with a progress bar. Drag ore **and wood** from the bag onto the window
to lay stacks beside the furnace — one log's embers fire **three** bars
(iron smelts 1:1, silver and gold 2 ore per bar) and the bars land in the
**tray**, never on the ground. Click
the tray (or drag it onto the bag) to take the bars; mining the furnace
spills a loaded tray. The **Silo** (Forge: 20 Stone Block + 4 Iron Bar) is
bulk storage that counts past 99: drag stacks from the bag onto the ground
beside it and it vacuums
them into wide slots; E beside it pours everything back out as 99-stacks.
A smelter standing NEXT to a silo casts bars straight into it, skipping
the tray — silo one side, ore+wood pile on the other, and bar production
runs hands-off. Placed equipment is protected from ordinary mining: click
it to use it, or hold Shift+left-click for 0.8 s with an equipped pickaxe to reclaim
it. Loaded machines must be emptied first. Death clears the save (roguelike). Save/log files
live in the working directory (`gnipahellir_save.dat`,
`gnipahellir_stats.dat`, `action.log`).

The charm belt has three independent sockets, **CHM1–CHM3**. Right-clicking a
charm fills the first open socket; right-click an occupied socket to remove it.
Duplicate charm types are refused, so their bonuses cannot stack. The **Void
Charm** is forged at the Dvergr Forge from 4 Silver Bars + 2 Gold Bars + 1
Emerald. While worn in any charm socket, a purple **VOID** box appears
below the bag. Drag one bag stack into it to hold it as a recoverable undo
stack; drag it back onto an empty or compatible bag slot to recover it. Dragging
a second stack into VOID permanently erases the first and retains the new one.

## Debug tools (debug builds only)

| Key | Tool |
|---|---|
| F1 | Debug menu — click to toggle: **Fly mode** (W/S or ↑/↓ vertical, no gravity, collision stays on); **Ultra wand** (13-tile mining shots, free, impact blasts a 3×3 — needs no wand in the bag); **Stamp Metal/Gold spawner** (arms the cursor: the next world click stamps the spawner tile there, free); **Give Auto-Miner** (drops one in the bag); **Game of Life** (easter egg toy, `life.odin` — not part of the game; it WILL eat the level, fly first) |
| F3 | Debug overlay: player pos/vel, builder scan rays, hover tile |

`action.log` records everything (flushed every 5 s + on quit) — after a
playtest, grep it for `strike`, `WARNING`, `Player` to reconstruct the
session. This is how the builder-freeze regression was diagnosed.

## The full loop (v1.0 progression)

1. **Cave 1**: hole in the grass at map center → shaft down. Blueprint A +
   the (locked) cave-2 portal are in the bottom-right chamber (~x 140–150).
2. **Blueprints**: walk over them — pickup *is* activation (fires
   `Blueprint_Found`; a popup shows the ritual cost). Never consumed.
3. **Sky**: gate on the surface far west (x≈6). Mine Cloud_Ore on the
   platforms. Falling below the clouds returns you to the surface.
4. **Ritual**: place a Sky_Altar, stand near, press E. Popups explain any
   missing prerequisite. Costs:
   - Tier A: 8 Cloud Stone + 4 Plank → unlocks Deep Cave (cave 2)
   - Tier B: 12 Cloud Stone + 6 Silver Ore → unlocks Gnipahellir (cave 3)
   - Tier C: 20 Cloud Stone + 10 Gold Ore → wakes Garm in cave 3
5. **Cave builders**: cave 1 and both deep caves now have 3 builders each. They compete for ore, build dens (raid
   them for the floor stockpile — the owner shrieks and defends), and hunt
   on sight (~12-tile LOS, 1 dmg/0.8 s bite). Craft a **Sword** at a bench
   (2 Iron Bars + 1 Plank) — builders die in 3 hits and retaliate when struck.
6. **The miner's ladder**: find the Pickaxe on the entrance-shaft ledge and
   right-click it in the bag to equip it into PICK (adjacent only, 3 chips per tile).
   At a bench: Mine Wand (2 Plank + 4 Iron, range 3) → Silver
   Wand (wand + 6 Silver, range 4) → Gold Wand (silver + 6 Gold, range 8).
   Each tier consumes the previous wand; shots cost 5/3/5 mana respectively
   (pool 100, regen 5/s).
   The Dvergr Forge also makes the **Void Charm** (4 Silver Bars + 2 Gold Bars
   + 1 Emerald), adding a one-stack recoverable trash buffer to the inventory.
7. **Garm** (boss gate = ritual C): awakens in the cave-3 arena. Chases,
   bites (2 dmg), throws fireballs (2 dmg, dodge or break line of sight).
   At 20 hp he raises a center column, at 10 he seals the arena, and when
   the ring closes lava floods the floor — everything he builds is mineable.
   Kill him, grab the **Hell Key** where he fell: win screen. Won runs clear
   the save like deaths do.

## The Auto-Miner (dimension automation)

Craft it at the **Rune Altar** (6 Iron Bar + 2 Gold Bar + 1 Emerald), then
place it **inside a spawned dimension** (it refuses anywhere else, one per
expedition). A metal snake grows from the base, tunneling block by block to
the nearest ore — ore and tunneled stone accumulate in the base's wide tray
(thousands fit). **E** beside the base claims the haul in 99-stacks. **Q-drop
a gem** next to the base to permanently raise its speed (emerald ×1.5 → jade
×2 → diamond ×3 → hel gem ×5; base rate one block per 3 s ≈ 1.5–2 h to strip
a world). While a miner works, its dimension is **anchored** — it stops
regenerating, other spawners refuse to open, and time away is applied in a
catch-up burst when you return. Claim the haul, equip the pickaxe, then
Shift+hold the base to release the anchor. When no ore remains the miner
sleeps: "the dimension is played out."

## Known stubs (deliberate, don't file as bugs)

- Potions exist but are unobtainable/unusable
  *(Iron_Bucket now works — right-click a water/lava cell to fill, an open cell
  to pour. One load at a time, however many buckets you carry.)*
