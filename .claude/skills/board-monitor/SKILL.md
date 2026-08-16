---
name: board-monitor
description: Arm a persistent live watch on the agent message board (127.0.0.1:7666) that streams new posts into the session as events. Use when the user asks to monitor/watch the board, or at the start of a long working session so cross-agent traffic (requests, file-claim conflicts, posts from glenn) surfaces without polling by hand.
---

# Board Monitor

Arms a persistent background watch on the agent message board so new posts
arrive in the session as events. This is the Claude Code way to monitor the
board — a prompt-loop "monitor agent" ends with its turn; this survives the
whole session. (Non-Claude agents like Codex can't use this skill; give them
the poll-loop prompt from `message_board/README.md` instead.)

## Prerequisites

You should already be checked in per the AGENTS.md board protocol (a `status`
POST with your agent name). If not, do that first.

## Steps

1. **Verify the service**: `curl -s --max-time 3 http://127.0.0.1:7666/agents`.
   If connection refused, start it from `message_board/`:
   `Start-Process -WindowStyle Hidden -FilePath message_board\message_board.exe -WorkingDirectory message_board`
   (missing exe: `odin build message_board -out:message_board/message_board.exe`).

2. **Write the poll script** to your scratchpad directory as `board_watch.py`,
   substituting your own agent name for `SELF`:

```python
"""Poll the agent message board and emit one line per new message."""
import json
import time
import urllib.request

BASE = "http://127.0.0.1:7666"
SELF = "<your-agent-name>"  # skip our own posts, and identify us when polling


def fetch(since):
    # as=SELF says WHO is watching without narrowing WHAT is returned, and
    # both halves matter. It marks you alive on /agents, so a session that
    # watches quietly for an hour is not mistaken for a dead one. And it is
    # not `for=`: that filters to your own mail plus broadcasts, which would
    # silently blind the monitor to traffic between other agents while
    # looking like the fix.
    with urllib.request.urlopen(f"{BASE}/delta?since={since}&as={SELF}",
                                timeout=5) as r:
        return json.load(r)


# Start at the current head so history is not replayed.
cursor = fetch(0)["latest"]
down = False

while True:
    try:
        d = fetch(cursor)
        if down:
            print("[board] service is back", flush=True)
            down = False
        for m in d.get("messages", []):
            if m["agent"] == SELF:
                continue
            to = f" -> {m['to']}" if m["to"] else ""
            ref = f" (re #{m['reply_to']})" if m["reply_to"] else ""
            files = f" [{', '.join(m['files'])}]" if m["files"] else ""
            print(f"#{m['seq']} {m['kind']} {m['agent']}{to}{ref}: {m['text']}{files}",
                  flush=True)
        cursor = d["latest"]
    except Exception:
        if not down:
            print("[board] service unreachable - will keep retrying", flush=True)
            down = True
    time.sleep(30)
```

3. **Arm the watch** with the Monitor tool:
   - `command`: `python -u "<scratchpad>/board_watch.py"`
   - `description`: `new agent message board posts (127.0.0.1:7666)`
   - `persistent`: `true`

4. **Tell the user** the watch is live and note the task id so it can be
   stopped later with TaskStop.

## Handling events

Each event is one board post. When one arrives:

- **From `glenn`**: top priority — it's the user speaking through the board.
  Broadcasts may be for anyone (coordinate before claiming); messages
  addressed `to` you are direct asks — act on them.
- **A `request` addressed to you** (or to "anyone" that you can answer):
  reply with `kind:"reply"` and `reply_to:<seq>`.
- **File-claim traffic**: if another agent claims files you are editing,
  coordinate on the board before continuing.
- **Routine status posts**: no reply needed; a one-line note to the user is
  plenty. Don't echo every event back to the board.

Two gotchas learned in the field: posts that land in the seconds *before* the
watch arms are never replayed (the script starts at the current head — peek
`GET /delta?since=<last-seen>` if a gap matters), and a `reply` posted by
another agent does not clear their stale file *claims* (claims come from their
latest `status`), so verify with `git status` before treating a claim warning
as real.

## Standing down

Stop the task (TaskStop with the monitor's task id) and post a closing
`status` to the board if you are also ending your session.
