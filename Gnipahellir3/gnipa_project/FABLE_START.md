# Fable — read this first (written 2026-07-14, after the miner/endgame session)

Hei! Massive session with Glenn. Here's your running start.

## What shipped last session (all merged + pushed to master)

- **Gem ladder** — Emerald(c1)/Jade(c2)/Diamond(c3)/Hel Gem(arena band)/
  Aether in high sky. Sparse table veins, `Pixel_Gem` art.
- **Auto-Miner** (`miner.odin`, save v12) — Glenn LOVES it. Snake
  BFS-tunnels to themed ore in a dimension, wide-u32 haul on the base,
  gem-fed speed tiers, placing it ANCHORS the dimension, catch-up on
  re-entry, "played out" depletion. F1 menu has the test kit (stamp
  spawners at cursor, give miner).
- **Conway easter egg** (`life.odin`) — quarantined toy, own commit,
  NOT game content. Ignore for planning.
- 80/80 tests. `save_data_size_probe` test makes save bumps copy-paste.

## Next session: endgame tuning — DECIDED, pure execution

Read `progression_review.md` (audit + locked decisions + build order §6):
min-1 damage rule (player-only), Garm 75 HP / bite 4 / fireball 3,
**Runic Dimension spawner @ 500 Gold Bars** (fixes the unobtainable runic
tier AND lands Glenn's "1000 gold" endgame — one snake-stripped Gold
dimension pays for it), rituals B/C → 6 Silver / 10 Gold Bars.
Watch: `Ingredient.count` may be u8 (500 overflows). After that: the Silo
(moving 500 bars through 99-stacks will hurt on purpose).

## Still unplaytested in-game

Gem tile art in the caves, Gold spawner glow. Quick fly-by covers both.

## Read before coding

`CLAUDE.md` (law), `next_session.md` (freshest truth), `plan.md`.
Build `odin run src` · tests `odin test src` (cwd Gnipahellir3/).
Save layout change = bump SAVE_VERSION + size (probe test logs it).

## About Glenn

Direct, decides fast, playtests immediately, designs by conversation —
concrete options + a recommendation. Fun slice before prerequisite; keep
prerequisites visible. His favorite shape: **cost mirrors reward**. Side
quests stay isolated (own commit). He drives git himself sometimes —
check `git log` before assuming. If I'm ever gone: `OPUS_HANDOVER.md`.
