# Coordinator handover, 2026-11-02

From claude-gnipa-coord-369A to the coordinator who takes over in herdr.
This is a dated snapshot: check the board and git log before relying on it.
Glenn is your one contact. Use they/them for Glenn in text unless told otherwise.

## First steps

1. Read `ops/seat/` and this note, then `GET /api/boards/gnipahellir/tasks`.
2. Post takeover to `claude-gnipa-review-a4c7` and `claude-gnipa-impl-c3f1`: they
   still address the old name.
3. In `ops/seat/start-seat.sh` set `COORD` to your name, and commit it.
4. Tell Glenn when you are up. The old session stays open until run 4 reports.

## Git state

- `master` is at the commit of this note, on top of 5624aae. Not pushed. Never push unless Glenn asks.
- `cards`: cards 9-16 (Done, except 16), 10 commits ahead of master.
- `seat/claude-gnipa-impl-c3f1`: `cards` plus 17 (8a4dc2f), 18 (5bbfa99), 37 (3e3895e).
- Card 36 (seat script) is Done and on master; `ops/` is tracked now.
- `agent-api`: worktree `/home/glennwiz/dev/Gnipahellir-agent-api`, run 4 lives there.
- `/home/glennwiz/dev/Gnipahellir-cards` is a worktree to remove once landed.

## Board state

In Review with `claude-gnipa-review-a4c7`: 16, 17, 18, 37. It has that queue.
When they are approved:
1. Land `cards`, then the implementer's branch, to master.
2. Check each cleanly: `odin build src`, the same with `-define:GAME_DEBUG=false`, `odin test src`.
3. Close the implementer seat and remove its worktree.

Draft and held until Glenn starts them: 19-27 (design review), 29-35 (bugs from run 3).
Only the creator can ready a card, and those were created by the old name. Ask
the board how to change that; if it cannot, recreate them, or use the old name's
`ready` while that session lives.

Note: 9-15 are Done but on `cards`, not on master.

## Open with Glenn

- Must look at: card 14 fall warning (not finished until seen; it also shows on
  falls that do no harm), card 13 damage word, card 17 gauge, card 18 sounds
  (the box is muted: `wpctl set-mute @DEFAULT_AUDIO_SINK@ 0`), the wording of the
  win coda (card 9).
- Still owed: keys work after an agent disconnects; wheel while the agent thinks.
- Card 22: does quench limit which lava, or which stone? Card 27: what the risen
  hero carries when one item went to the grave.
- Agent speed, Glenn agreed in principle: a card for the game to wait a few ms
  for the next act, and for smaller act replies. Not minted. Build after run 4,
  and compare against about 20-29 frames a second.
- Frame time in a late world is unmeasured; run 3 replay ran about 31-40 fps.
- Thingvellir: `seat start` needs a working board choice and Linux paths. That
  is a v2dev matter; do not work on it here.
  Register glenn on this board.

## Run 4

Game in `build/agent_runs/20261101-232759` of the agent-api worktree, port 7777,
driven by a subagent of the old session. It dies if the old session closes.
At last check: no deaths, ritual B done, heading for gold and Garm. It was told to
stop on Garm's death or at about 90 minutes. The old session relays its report,
commits its bot and lessons changes (not `__pycache__`), and stops the game.
It tests plans and the panel in a real run.

## Decided by Glenn, do not reopen

In `Gnipahellir3/gnipa_project/design_review.md` section 6, plus: snapshots
debug-only; autosave removed on death; game ticks slowly between acts; agent
runs are for finding game bugs; a seat runs through `ops/seat/start-seat.sh`;
replay is watching a run in the window, with no rewind.

## Things that cost time

- `pkill -f` matches your own shell: stop processes by id or `pkill -x`.
- A test that hangs keeps running after its tool call is stopped. Check for it.
- Subagents share the coordinator's board tools: they must use HTTP as their own name.
- A subagent and a seat can share a board name; send work to the seat by board message.
- Full replay of run 3 was stopped at frame 44572 of 123048 with no mismatch; a
  whole long run has never been replayed.
