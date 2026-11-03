# Agent lessons

Read this before an agent run, and update it after one. Keep it true, not long:
replace or delete a lesson when it stops being true.

From "How the bot plays" on, this file ships in the game: the brief a GET gets ends with it.
How to run: `tools/agent_play.sh` starts the game in a new `build/agent_runs/<time>/`.
Protocol: top of `src/agent_api.odin`. Afterwards run `tools/agent_summary.py <run>`
first, then read `action.log` and `fight.log` only where it points.
`tools/agent_replay.py <run>` plays a run back in the window.
Reuse and improve `tools/agent_bot/`: a fix there lasts, a fix in your head does not.

## While you think

The game no longer stops between acts. Between tool calls it plays your plan at
about 15 ticks a second, then idles for 3 game seconds, then holds. So before a
long think, end the script with `g.plan({...},{...})` sized to the think, and
pick safe moves: a plan is blind, and only your next act overrides it. State has
`plan_left`, and `plan_stopped` if a step could not start. Keep the watcher told
with `g.goal("kill Garm", "perch at the east wall")`.
`B` now sends a default plan when a script exits (mine beside the body, else stand);
call `b.think(*acts,sec=20)` to choose your own. Never run two scripts at once.

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
- `feed` takes the whole stack unless `count` says less: 20 iron jammed a smelter for gold.
  `withdraw` and `withdraw_fuel` undo it; `smelter.fuel` in the window shows the wood.
- `enemies` lists only what is inside the requested view, so ask for a wide view.
- Warp does nothing on level 0, chamber included ("Already on the surface"). Check it
  moved you before relying on it: life 1 of run 4 walked into the shaft and fell 21 tiles.
- `walkj` along the surface walks into the shaft at x 96-97. Bridge it first.
- Falling off the sky lands you in the chamber at no cost, but a `goto` left running then
  paths on L0 for sky coordinates. Check `level` after each leg.
- Stations need a neighbour tile: a smelter in open air fails with no note. Windows close
  after an act, so `use` again before `collect`.
- Print map columns before flying to a tile. A misread cost 20 tiles of fall, hp 10 to 2.
- `harvest` on stone nets zero when it bridges gaps: use `quarry`. Solid stone is the
  rows from 104 down on L0, and rows 55-59 on the surface; the chamber is thin islands.
- Keep 20 blocks in reserve. At zero, `goto` and `harvest` loop on Pillar and burn minutes.
- `quarry` digs your own altar base logs: start it away from the base.
- `sel` returns False if the item is missing; a place after it uses whatever is held
  (a log landed where the altar should be). Check the craft worked.
- Read `notes` after a place or craft that did nothing: it is the only reason given.
- Drops fall now. Stone mined over a void falls away, so `harvest` on chamber islands nets
  zero and strands you with no blocks. Mine the ceiling above your floor, or `quarry` row 105.
  Check block count before a long `goto`: 50 rows up is 50 blocks.
- Do not stand a bench on (141,94): Scroll A needs that tile free, and also free of drops.
- A view's `solid` chars stop the body from every side, `floor` ones hold it up. Structures
  are floor but not solid; doors are neither.
- `guard` kills Builders by default. To keep an owner alive for a den test, set
  `sparebuilder`, but keep away: he bites 1 a second, and if he dies beside you he rises as
  a Draugr that claws 3 on the next frame (ended life 2 of run 5).
- Lava: move out, never jump in place; plan ticks run on while burning, so flee before any plan.
- A sky hole in the deck drops you to L0 at (147,92): free, and drops in the hole go with you.
- Plain Cloud drops 20% of the time, Cloud_Ore always.
- Check the level after every portal step: run 6 life 3 ran the sky script on L0 and flew into the shaft, 32 tiles, dead.
- Scroll C sits at (12,101) on Cave 3. A smashed L0 altar goes back on the Stone base until Scroll C is found.
- Do not let flight lapse over an island: 21 tiles is 9 damage. Over void you fall to L0 free.
- Run 7: `fight` dug toward enemies for line of sight and took the floor (fell on a Draugr, dead)
  and a pool rim (the Deep Cave pool drained). It now skips cells below the feet or by water/lava.
- A plan is blind: run 7 life 1 idled a 300-tick plan beside a hunting Builder, 10 to 3 hp.
  Do not think long with a Builder in the view; scripts set `GNIPA_AGENT_TURBO=1` to skip `endplan`.
- Walks need a stuck check: p1 jumped 30 s at a trunk at x 88. `walkj` now gives up after two
  jumps that do not move x.
- `path` refuses water; standing in spilt water there is no path at all. Set `b.waterok=True`.
  A block cannot go into a water cell ("Something is already there"), and water is no
  neighbour for placing ("It needs something solid beside it").
- Walls: a Vargr goes for natural rock first. Run 7 life 2 walled the chamber in placed stone
  and wood, and both Vargr dug in under the natural floor (placed stone took them about 4 s).
- The death screen refuses `tithe` for about 90 frames ("not ready yet"): wait, then retry.
- Sky Egg: 2 per nest, no regrowth, `equip` eats it for +2 hp.
- A Rain Wisp's drip soaks you and slows flight; a flight home ran out 3 tiles short.
- In a walled pocket, `fight`'s line-of-sight dig still opens your own wall at foot level
  (run 7 life 3 dug (108,53) and let the Vargr in). Turn it off when walled in.
- Golems cannot be given work over the API: a Gather or Build zone is a mouse drag.

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
- Cloud drops float in the cell, so stand in them. Stone bridge on row 80, wand on the roof
  above, jump under each drop: `skyfarm` took 3 columns for 5 Cloud Stone.
- Tree farm: Tree_Grower is 2 planks + 4 leaves, known once you hold planks. Needs Air
  above, so surface or sky, never a Void cave. Set in the grass the walk stays flat.
  Untested for yield: run 4 ended before a harvest, and a Vargr wave smashed 5 growers.
- An odd ore count jams a smelter on one ore. `withdraw` clears it, or feed even stacks. Mine frames of `Wood` in cave 2 are spare logs.
- Waves on L0 demolish the bench, altar and Scroll A chest while you are away. Altar and
  bench drop at their tile, and the altar must be set back on its base.
- Potions: bed = 1 Dirt + 1 Plank + 5 seeds, placed on solid; gives 5-6 flowers, then
  it is gone. 3 flowers make a potion. Bed yield 5 flowers in 120 s of active-level time. Drink via `equip`, +5 hp.
  Grass mines to Grass_Turf, not Dirt. Dirt comes only from rows 54-59 by the shaft.
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
- Untested, best idea so far: Rainbow Laser, 1 log + 1 stone at a bench, 2 damage every
  0.5 s to the nearest enemy within 8 tiles, no fuel, no aim, and the code has no line of
  sight check. The arena is empty until ritual C. Garm spawns at (168,102): fill cells
  round him before the ritual, then enter. 16 lasers in range is about 4.4 s (src reading).
  Each entry starts at (95,26), so you are far off when he wakes. 0 zaps in run 4.

## Game bugs seen, unfixed
- Garm can get stuck smashing a cage wall that re-conjures, and stops fighting
  (run 3 logs, `GARM smashes (139,96)` every 24 frames).
- Player stopped at (143,93) beside a Green_Cave_Mushroom with no solid tile there.
- `mine` on a mushroom does nothing, and a block placed in its cell fails silently.
- Player stood grounded on Void at (88-96,54) on the surface.
- Sky drops over a void fall to row 106, reachable only by flight: that Cloud Stone is lost.
- Bed and other `place` failures can give no note.
- Vargr digging a Rune_Scroll_Chest_A leaves a `Rune_Coffer` drop (run 4 f27348).
- Fire Sprites parked 90 s above the altar in Wave_Hunt.
- A sky tree cut at the base leaves its trunk floating.
- A surface trunk sat on rock and its base could not be cut, world seed unknown.
- Builder dens can hoard, but late: run 6 soaks saw 345 stockpiles in caves (first at minute 8-47,
  3 of 4 seeds) and almost none on the surface, since a haul only lands once the shell is full.
  The 25-frame re-mine is the builder leaving by his own wall, not a Fetch harvest.
- A Builder can dig through the pond bed and drain it by frame 4000 (run 5 life 3).
- Den grudges hold one at a time, so a second rob before the first is due starts no timer.
