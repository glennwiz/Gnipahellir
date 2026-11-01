# Agent lessons

Read this before an agent run, and update it after one. Keep it true, not long:
replace or delete a lesson when it stops being true.

How to run: `tools/agent_play.sh` starts the game in a new `build/agent_runs/<time>/`.
Protocol: top of `src/agent_api.odin`. Afterwards run `tools/agent_summary.py <run>`
first, then read `action.log` and `fight.log` only where it points.
`tools/agent_replay.py <run>` plays a run back in the window.
Reuse and improve `tools/agent_bot/`: a fix there lasts, a fix in your head does not.

## How the bot plays
- Hold one connection for the whole run through `bridge.py`. A disconnect lets the
  game run on in real time with the player standing there, and ends replay.
- Each life is a new world. Scripts tuned to one map fail on the next: check the
  view, and do not assume tiles.
- Every script needs a guard in its loop, flight and `noguard` loops included: leave
  when `in_tile` is a hazard or HP is falling. Runs 2 and 3 both ended in lava retrying
  one move; run 3 died holding the ring and a potion. `fly` now warps when hurt.
- A failed step must not replan the same step. Count repeats and pick another goal.
- `mine` on a tile out of reach chips the nearest reachable tile, which can dig out
  your floor. Check reach first.
- Do not path through your own altar, bench or floor.
- Before a fight, check line of sight: fire orbs into stone do nothing while a
  Builder bites round the corner.
- `feed` takes the whole stack and cannot be undone: 20 iron jammed a smelter for gold.
- `enemies` lists only what is inside the requested view, so ask for a wide view.
- Print map columns before flying to a tile. A misread cost 20 tiles of fall, hp 10 to 2.
- `harvest` on stone nets zero when it bridges gaps: use `quarry`.
- Read `notes` after a place or craft that did nothing: it is the only reason given.

## How the game goes
- 10 HP, no regeneration. Falls kill. Pillar and bridge instead of jumping over voids.
- Order that worked to Garm in 20 minutes: wood, bench, Fire Wand, Scroll A, altar,
  ritual A, cave 2 and Scroll B, gold, ritual B, sky base, Scroll C, ritual C.
- Worlds differ in cave shape by seed; ore placement looked the same between runs.
- Swirl blessing: 20 s flight at 14 tiles/s, carried through levels. Fly in 8 ways
  (`airline`): cave 3 arrives with 11 s left against 7 on the axial `flyto`.
- Gold: 20 ore and 2 Jade took about 15 minutes in west cave 2.
- Jade Ring (1 iron bar + jade) warps to the surface. Make it before Garm; it saved
  the run many times. Home to chamber is 20 s.
- Fuel is 2 logs per bar: bring 32 or more. Trees need clear Air above and grow only
  on the active level, in 40 s. Flower beds likewise, in 120 s.
- Potions: bed = 1 Dirt + 1 Plank + 5 seeds, placed on solid; gives 5-6 flowers, then
  it is gone. 3 flowers make a potion. Dirt comes only from rows 54-59 by the shaft.
  Brew before waking Garm.

## Garm
- 140 HP. Fire Wand does 3 per orb, 0.4 s cooldown, range 48. His fireball reaches 12
  and needs no line of sight, but cover stops it. He keeps HP while you are away.
- He does not hunt until first blood. Open from far: 21 tiles on the floor took him
  140 to 101 in 5 s. A perch he cannot climb took him 101 to 44 in 27 s.
- At 46 HP he starts a cage: one wall every 0.15 s round your position, then lava. Stand
  still and you are sealed in about 6 s, and walls block orbs. Keep flying; leaving the
  rect abandons it. Air at distance 13+ was safe: 44 to 35 in 4.5 s. Warp before
  flight ends, and never land there. 12 more hits would have won run 3.
- Untested: standing in the nearest wall slot may stall the cage 6 s.

## Game bugs seen, unfixed
- Garm can get stuck smashing a cage wall that re-conjures, and stops fighting
  (run 3 logs, `GARM smashes (139,96)` every 24 frames).
- Player stopped at (143,93) beside a Green_Cave_Mushroom with no solid tile there.
- `mine` on a mushroom does nothing, and a block placed in its cell fails silently.
- Player stood grounded on Void at (88-96,54) on the surface.
- Drops float where the tile was; a hanging one cannot be reached.
- Bed and other `place` failures can give no note.
- Smelter window closed by itself during an idle hover.
- Fire Sprites parked 90 s above the altar in Wave_Hunt.
- A `Rune_Coffer` item appeared in the bag near a permanent chest being dug round.
- A sky tree cut at the base leaves its trunk floating.
- A surface trunk sat on rock and its base could not be cut, world seed unknown.
