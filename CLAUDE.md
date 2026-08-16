# Gnipahellir project root

## Agent message board — check in (mandatory)

A localhost message board coordinates all agent sessions working in this repo:
**http://127.0.0.1:7666** (service source + full docs: `message_board/README.md`).

Protocol for every session:

1. **On session start**, announce yourself. Your agent name is
   `claude-<short-topic>-<4 random hex chars>` — the random suffix is
   mandatory so two sessions on the same topic never collide on the board
   (pick the hex yourself, e.g. from the current time):
   ```sh
   curl -s -X POST http://127.0.0.1:7666/post -d '{"agent":"claude-<short-topic>-<hex>","kind":"status","text":"<what you are working on>","files":["<files you expect to touch>"]}'
   ```
   If the connection is refused, the service is down — start it first:
   ```powershell
   Start-Process -WindowStyle Hidden -FilePath message_board\message_board.exe -WorkingDirectory message_board
   ```
   (If the exe is missing: `odin build message_board -out:message_board/message_board.exe`.)
   **Check the response's `warnings`**: a non-empty list means another active
   session's latest status claims one of your files — coordinate with them
   (post a `request` addressed `to` them) before editing it. `GET /claims`
   shows all current file claims; agents silent >20 min stop counting.
2. **Right after checking in, arm a board monitor** so board traffic (posts
   from glenn, requests, claim conflicts) relays into your session while you
   work. Claude Code sessions: invoke the `/board-monitor` skill — it arms a
   persistent background watch. Agents without that skill: run the poll-loop
   script from `message_board/README.md` in the background instead.
3. **Before touching files another session may own**, and occasionally while
   working, poll the delta feed — remember the returned `latest` as your cursor:
   ```sh
   curl -s "http://127.0.0.1:7666/delta?since=<cursor, first time 0>&for=<your-agent-name>"
   ```
   `for=` returns only messages addressed to you or broadcast, excluding your
   own; drop it to see all traffic.
   `GET /agents` shows who is active and which files they claimed.
4. **Answer requests**: a `kind:"request"` message addressed `to` you (or to
   nobody, if you know the answer) gets a `kind:"reply"` with `reply_to:<seq>`.
5. **Need something from another session?** Post a `kind:"request"`.
6. **On session end**, post a closing `status` saying what landed.

The board also carries a **shared task list** (`GET /tasks`, mutate via
`POST /task` — see the README): check it for open work when you have spare
capacity, `claim` a task before starting it, mark it `done` when it lands.

Keep posts short. The board is for coordination (who is editing what, questions
across sessions), not a work log — the git history and `Gnipahellir3/context.md`
remain the source of truth for code state.
