# Handover — 2026-07-05 (post polish session; sprite pass next)

For the next session. Read `Plan.md` (roadmap), `Gnipahellir3/CLAUDE.md`
(architecture rules — mandatory), `Gnipahellir3/PLAYTEST.md` (controls),
`opus.md` (working notes on Glenn). Verify every change:
`odin build src` + `odin test src` from `Gnipahellir3/` (48 tests, ~2s; if the
game is running, add `-out:src_test.exe` or the linker can't write src.exe).
Commit per verified milestone. Remote: push to `origin` (private
github.com/glennwiz/Gnipahellir) — Glenn works across machines while travelling.

## >>> NEXT UP: sprite pass (the reason for the fresh session)

Wire `Gnipahellir3/sprites/gnipahellir_tile_spritesheet.png` into tile
rendering, replacing the current flat-colour + procedural pixel tiles.
- Tiles today: `render.odin` `draw_world` → `draw_tile`, dispatched by the
  `tile_draw_style` table (`.Solid` = flat `terrain_table[t].color`; `.Pixel_*`
  = hand-drawn `draw_pixel_wood/leaves/flower`). Replace/augment these with
  spritesheet blits.
- Asset load: textures load in `main.odin` (see the render-texture setup);
  raylib `LoadTexture` + `DrawTextureRec` for a source cell per tile.
- Rendering runs inside the supersampled zoom camera (SS_SCALE=3) — draw at
  float positions (`DrawTexturePro`/`Rec`) so tiles glide, like the player.
- CELL_SIZE is 10px/tile; pick a spritesheet cell size and map Tile_Type →
  source rect (a table, mirroring `tile_draw_style`).
- Ask Glenn the sheet's grid layout (cell size, which tile is where) before
  wiring — the PNG is his, added 2026-07-05.

## Done this session (all on master, tree clean)

**Phase 5 — Garm final boss: COMPLETE (M4 + M5)**
- M4: Garm AI — chases via `builder_travel`/`astar_dig` (reused, not
  reinvented) + a "smash" rule carving the extra clearance his 1.6×1.8 body
  needs through 1-tile corridors; fireballs via `spawn_projectile` (die on
  solid tiles, so cover works with no LOS test); G2's project phases as boss
  mechanics on hp thresholds: Chase → Column (≤20) → Ring (≤10) → Flood.
  Structures channeled at range, one tile/tick, all mineable stone. Lava's
  `damage_per_second` finally wired to the player.
- M5: Win — Garm dies → Hell_Key drops where he stood → pickup fires
  Boss_Defeated + Game_Won → win screen (run time, kills, runs won);
  runs_won++ persisted immediately; a won run clears the save on quit.
- `garm_fight_soak` (60s simulated fight) is a permanent test.

**Mining rework — COMPLETE + Glenn approved the feel**
- Replaces old click-at-range-5. Start with a Pickaxe: aims by rough cursor
  DIRECTION not exact tile (8-way, wide 45° horizontal band, forward carves
  head+feet rows), adjacent only, 3 chips/tile, free.
- Bench-crafted wand ladder Mine_Wand(2) → Silver(4) → Gold(8): keeps precise
  cursor aim, each tier consumes the previous, 5 mana/shot from a 100 pool,
  G2-style spark stream with delayed impact.
- F1 debug menu row 2: Ultra wand cheat (13-tile, free, 3×3 blast impact).
- Particle store is live (`mining.odin`, `particles.odin`).

SAVE_VERSION is 8. Save-layout changes trip the size assert in `save.odin` —
bump version + expected size together (probe the new size with a temp test).

**Polish session (2026-07-05, after the above) — all committed + pushed:**
pixel-art mage (animated feet, in-hand tool, swing); pickaxe found on the
grass; interactive blueprint overlay (B); data-driven structure-build templates
(`templates.odin`, per-tier altars, silver/gold placeable); reclaim any placed
structure; flashy taller RGB portals; mouse-wheel zoom + 3× supersampling
(glide); **player-built sky gate** (find Sky Blueprint → build surface altar →
portal blooms above it, `sky_altar_pos`); build ghost preview (`placement_ok`);
deselect held item (hotkey again / click slot / Esc); **autosave on every
meaningful action** (`save_dirty`, written at frame end in `main.odin`).

## Left to do

**Phase 5 playtest (only thing keeping the phase open):**
- Glenn's hand playtest of the boss fight — feel + tuning. The soak bot took
  66 hits in 60s vs player hp 10, so Garm may be tuned hot. Knobs: `GARM_*`
  in `garm.odin`. Also re-feel the new mining (pick pace + wand mana
  economics): `PICK_HITS`, `WAND_MANA_COST`, `wand_mine_range`, `pick_targets`
  direction bands.

**Boss/mining feel-tuning (still open):** full-run playtested 2026-07-05 — loop
works end to end, player died to Garm. Garm is lethal (10→0 in ~7s once bitten);
knobs `GARM_*` in `garm.odin` (bite cadence/damage) or player i-frames/hp.
The pixel-mage half of the G2 look port is DONE; the tile **sprite pass** above
is what's left of the visuals. (Old R&D branch `feature/render-port` is stale —
cherry-pick intent only, prefer master on conflict.)

**Later phases:** Phase 6 shippability (menus/settings/onboarding/death +
win-restart flow), Phase 7 juice. `suggestion.md` still has C3/C5 + 2 perf
notes open.

## Gotchas learned (timeless — keep these)
- Log ring buffer is 256 KB and silently stops — reset `gs.debug_log.pos`
  before capturing a window in long sims.
- Never clobber `action.log` (Glenn's ground truth); write diag files elsewhere.
- Diagnose builder/enemy stalls with a temporary diag test dumping per-frame
  state; frozen-position + suspiciously-cheap-frames + watchdog-silent means an
  early-return livelock. **Trust the soak, not a code proof** — it caught
  livelocks a proof missed twice.
- Odin: compound literals in conditions need a temp var; `odin test` links
  src.exe by default (collides with a running game — use `-out:src_test.exe`).
- raylib imports are pinned to `vendor:raylib/v55`; `physics.odin`'s
  `BODY_EPS < BODY_MARGIN < gravity*dt²` ordering is load-bearing.
- Glenn plays looking at his character, not the HUD — sound > text; if a
  mechanic lands, it should shriek.
