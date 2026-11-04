# Agent playtests

Rules for every playtest card (cards 127 on). Each card names a scenario, a seed and
its checks. An agent plays the game through the agent API as a player, writes down
what broke, and hands back a report. Glenn reads the reports; feel is still his call.

## When

- Playtests run only while Glenn is at work, or when Glenn asks for one (his rule, 2026-11-03).
  The coordinator readies them; if Glenn says he is back, finish the run in progress and stop.
- While a playtest runs, at most one other seat works on the box (Glenn, 2026-11-04), so
  the game keeps near 60 fps. The coordinator holds new seats until the run ends.

## Where and how

- Run in the shared agent checkout, `/home/glennwiz/dev/Gnipahellir-agent-api/Gnipahellir3`
  (branch `agent-api`), not in your seat worktree: a closed seat's worktree is deleted,
  and the run folder must outlive it. Merge master into `agent-api` first if it is behind.
- One run at a time on the box, on port 7777 only: `odin build src -out:build/gnipa && timeout <cap> build/gnipa --agent-run --port 7777 --seed <seed>`.
  Playtest cards are chained so they never overlap. If 7777 is taken, wait and say so.
- A card's cap counts game time (frames / 60), not wall time: the box is shared and
  the game can fall well behind the clock under load. Pass `timeout` twice the cap
  as the wall-time backstop, and give frames played and the wall time in RUN.
- Your client logs every state poll it makes to `client_state.jsonl` in the run
  folder, so the reviewer can check any value you cite.
- Drive the game only through the API: a GET on the port is the brief. Send goals over
  the socket from your own short client, one connection for the whole run; the game
  runs in real time and never waits. There is no bot code: the goal kinds in the brief
  are the whole toolset. No synthetic keys or mouse, no debug menus, no save editing.
- Afterwards, `build/gnipa --summary <run>` first; `--replay`, `--pacing` and
  `--builder-trace` are the other reports (`build/gnipa --help`).
- Never delete anything under `build/agent_runs/`. Never clear an `action.log`.
- Stop the game by pid when done, never `pkill -f`.

## What you may change

- Nothing in the repo. A game bug, an API gap or a goal gap is a finding, not a fix.
- If you need something a mouse player can see but the API does not give (a size, a
  timer, a state), that is an API gap: report it, don't guess it.
- A goal kind a player's plan needs and the queue lacks, or a goal that fails where a
  player would succeed, is a goal finding.

## The report (evidence on the card, then submit)

```
RESULT: which checks passed, failed, or were not reached
RUN: run folder, seed, wall time, frames played
FINDINGS: one line each, tagged
  [game] a bug in the game
  [api]  the API hides or blocks something a player has
  [goal] a goal kind is missing, or a goal failed where a player would succeed
  [feel] works, but Glenn should look (tuning, fun, clarity)
  each with the action.log frame(s) or line(s) that show it
ASK: anything only Glenn can decide
```

Keep it short. The coordinator turns [game], [api] and [goal] findings into cards.

## Review

The reviewer opens the run folder and checks that every finding's cited log lines
exist and say what the report claims, and that each check was attempted or its
reason for not being reached is given. The reviewer does not replay the run.
