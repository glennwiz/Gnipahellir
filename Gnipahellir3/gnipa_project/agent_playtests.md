# Agent playtests

Rules for every playtest card (cards 127 on). Each card names a scenario, a seed and
its checks. An agent plays the game through the agent API as a player, writes down
what broke, and hands back a report. Glenn reads the reports; feel is still his call.

## Where and how

- Run in the shared agent checkout, `/home/glennwiz/dev/Gnipahellir-agent-api/Gnipahellir3`
  (branch `agent-api`), not in your seat worktree: a closed seat's worktree is deleted,
  and the run folder must outlive it. Merge master into `agent-api` first if it is behind.
- One run at a time on the box, on port 7777 only: `timeout <cap> tools/agent_play.sh 7777 <seed>`.
  Playtest cards are chained so they never overlap. If 7777 is taken, wait and say so.
- Drive the game only through the API (`GET /v1/meta` is the brief, `tools/agent_bot/`
  is the bot). No synthetic keys or mouse, no debug menus, no save editing.
- Never delete anything under `build/agent_runs/`. Never clear an `action.log`.
- Stop the game by pid when done, never `pkill -f`.

## What you may change

- `tools/agent_bot/` on `agent-api`: fix the bot when the bot is wrong. Commit there.
- Nothing in `src/`. A game bug or an API gap is a finding, not a fix.
- If the bot needs something a mouse player can see but the API does not give
  (a size, a timer, a state), that is an API gap: report it, don't hard-code it in the bot.

## The report (evidence on the card, then submit)

```
RESULT: which checks passed, failed, or were not reached
RUN: run folder, seed, wall time, frames played
FINDINGS: one line each, tagged
  [game] a bug in the game
  [api]  the API hides or blocks something a player has
  [bot]  the bot was wrong (fixed in commit <sha>, or not)
  [feel] works, but Glenn should look (tuning, fun, clarity)
  each with the action.log frame(s) or line(s) that show it
ASK: anything only Glenn can decide
```

Keep it short. The coordinator turns [game] and [api] findings into cards.

## Review

The reviewer opens the run folder and checks that every finding's cited log lines
exist and say what the report claims, and that each check was attempted or its
reason for not being reached is given. The reviewer does not replay the run.
