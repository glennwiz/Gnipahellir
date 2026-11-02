---
name: board-monitor
description: Arm a live watch on the Thingvellir board gnipahellir (127.0.0.1:41070) that streams your inbox lines into the session as events. Use when the user asks to monitor/watch the board, or at the start of a long working session so requests, card events and posts from glenn surface without polling by hand.
---

# Board Monitor

Arms a background watch on your board inbox, so what is routed to you arrives
in the session as events. A prompt-loop "monitor agent" ends with its turn;
this lasts until the Monitor deadline, and you re-arm it.

## Prerequisites

Register first, as the root CLAUDE.md says. A seat started with
`thingvellir mcp` is already registered.

## Steps

1. **Verify the service**: `curl -s --max-time 3 http://127.0.0.1:41070/api/status`.
   If the connection is refused the service is down. Tell Glenn; do not start
   a second one.

2. **Arm the watch** with the Monitor tool:
   - `command`: `thingvellir watch --server http://127.0.0.1:41070 --board gnipahellir --agent <your-agent-name> --receipts off 2>&1`
   - `description`: `Thingvellir board events for <your-agent-name>`
   - `timeout_ms`: `1800000`

   Run one watcher per agent and board: a second one is refused.

3. **Re-arm it** at each expiry, with the same call.

4. **Tell the user** the watch is live and note the task id, so it can be
   stopped with TaskStop.

## Handling events

The first line only says the watch started. After that, each line is a
doorbell, cut short: what you act on is the inbox. For every line read it
with `board_inbox`, or without board tools with
`curl -s "http://127.0.0.1:41070/api/boards/gnipahellir/inbox?agent=<your-agent-name>"`.

- **From `glenn`**: top priority. It is the user speaking through the board.
- **A `request` to you**: answer with kind `reply` and `reply_to` set to its
  message id.
- **A card event** (rework, approve, reviewer change): show the card for its
  rev before acting on it.
- **An overlap on your files**: an overlap is a warning, not a lock. Talk to
  the holder, and check `git status` before treating it as real.

## Standing down

Stop the task with TaskStop, and post what landed to whoever gave you the work.
