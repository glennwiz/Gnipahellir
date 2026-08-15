# Conservation Fuzz Harness — findings log

Branch `harness`, worktree off master @ fc79959 (2026-08-15). The harness is
`src/tests_conservation.odin` — a seeded, deterministic random action stream
(pickup / drop / mine / place / craft / loot-spawn) driven through the real
handlers inside a rebuilt underground arena, with a whole-grid item ledger
checked after every action. Same seed = same stream, so an iteration number
is a full repro. Run it alone with:

    odin test src -define:ODIN_TEST_NAMES=game.items_are_conserved_under_random_play

**The test is deliberately RED on this branch** — it is the reproducer for
the leaks below (CLAUDE.md §4: write the failing test first). It goes green
by fixing the handlers, not by touching the harness.

## Census (seed 0x6e697061, 3000 actions, ~0.9 s)

| action     | violations | root cause |
|------------|-----------:|------------|
| mine       | 122 | `events.odin` `handle_tile_mined` drop block: the drop is silently voided when the mined cell holds a different item pile, or a matching pile at MAX_STACK. Known hole (context.md §5, "mined-tile drops void silently"). |
| loot spawn |  52 | `loot.odin` `spawn_ground_item`: (a) last-resort clobbers the origin cell's existing pile; (b) a partial merge onto a near-full matching pile drops the remainder instead of continuing the ring search; (c) count > MAX_STACK is truncated. Known hole ("last resort clobbers"), (b)/(c) are new sub-findings. |
| pickup     |  39 | `player.odin:299` `player_pickup`: ignored partial `inventory_insert` — the fitted part is banked but the ground pile is not deducted → duplication. Known hole ("walk-over pickup dupes"). |
| craft      |   7 | `crafting.odin:184` `handle_craft_request`: ignored `inventory_insert` return — result voided when the bag can't hold it. **Already fixed in Glenn's uncommitted 2026-08-14 work in the main folder**; this branch predates it, so the fuzzer independently re-derives the bug his fix addresses. Expect this row to go to 0 on merge. |
| drop       |   0 | clean at this commit (strict-refusal semantics; re-run after merging the drag-throw rewrite). |
| place      |   0 | clean — including the legal-but-spooky "place a block onto a pile, entombing it" path, which conserves. |

Total: 220 violations in 3000 actions.

## New findings beyond the known list (context.md §5)

- `spawn_ground_item` partial-merge loss: ring search stops at the first
  matching pile even when it can only absorb part of the stack — the rest
  vanishes. Distinct from the known origin-clobber.
- Latent, not yet fuzzed: `player.odin:279` forage — if the Flower_Seed
  stack only partially fits the bag, the FULL seed count is also ground-
  dropped (dupe). Same ignored-partial-insert idiom as pickup.

## Fix direction (all one idiom)

Same recipe as the shipped shaft-dirt and craft-spill fixes: count-moved =
count-before minus count-after, deduct exactly what was banked, and route
overflow through a ring search that never clobbers and never truncates.
Fixing `spawn_ground_item` first shrinks the mine/loot rows; pickup and the
forage twin are the partial-insert deduction.

## Harness notes for the next session

- Whole-grid ledger counts: ground piles, smelter store/in buffers, bag,
  equipment, void slot. Barrels/silos/depots/golems are not in this stream —
  future scenarios.
- Scenario mutations deliberately manufacture adversarial states: capped
  piles, bricked-full bags, recipe ingredients with no room for the result,
  piles under solid rock (reachable: placement never checks the item layer).
- Widen the search by changing FUZZ_SEED; a violation report is replayed
  exactly by re-running the same seed.
