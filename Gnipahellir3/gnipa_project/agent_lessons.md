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
- Every script needs a guard in its loop: move out when `in_tile` is a hazard or
  HP is falling. Run 2's last life stood in lava for 3.5 s retrying one plan.
- A failed step must not replan the same step. Count repeats and pick another goal.
- `mine` on a tile out of reach chips the nearest reachable tile, which can dig out
  your floor. Check reach first.
- Do not path through your own altar, bench or floor.
- Before a fight, check line of sight: fire orbs into stone do nothing while a
  Builder bites round the corner.
- `feed` takes the whole stack, so split logs first if you need them.
- Read `notes` after a place or craft that did nothing: it is the only reason given.

## How the game goes
- 10 HP, no regeneration. Falls kill: run 1 lost lives to 12- and 36-tile falls.
  Pillar and bridge instead of jumping over voids.
- Order that worked: wood, bench, Fire Wand early (Builders arrive within a minute),
  Rune Scroll A at the surface chest, Sky Altar on the surface, ritual A, cave 2,
  Rune Scroll B at (12,101). Next, never reached yet: gold for ritual B, cave 3, Garm.
- Gold was slow, about 2 ore a minute. Plan for it.

## Possible game bugs seen, not yet confirmed
- The Scroll B chest chamber floods with lava at rows 100-101, and the chest was only
  reachable by tunnelling under it.
- A `Rune_Coffer` item appeared in the bag near a permanent chest being dug round.
- Sky drops float where the tile was, out of reach on foot.
- A sky tree cut at the base leaves its trunk floating.
- `feed` with a different ore queued gives no error and does nothing.
- A surface trunk sat on rock and its base could not be cut, world seed unknown.
