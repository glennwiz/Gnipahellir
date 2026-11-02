# Gnipahellir project root

## Agent board: check in

Agent sessions in this repo coordinate on a Thingvellir board:
**http://127.0.0.1:41070**, board `gnipahellir`. `GET /help` is its full
contract. Task state lives there. Code state lives in `Gnipahellir3/context.md`
and git history.

A seat started by the coordinator has a brief with its name, cards and board
tools. Follow the brief; the steps below are for any other session.

If the connection is refused, the service is down. Tell Glenn; do not start a
second one.

Set these once. Pick your own name, `claude-<short-topic>-<4 random hex chars>`:

```sh
BOARD=http://127.0.0.1:41070/api/boards/gnipahellir
ME=claude-<short-topic>-<hex>
JSON='Content-Type: application/json'
```

1. **Register.** This gives you an inbox.
   ```sh
   curl -s -X POST "$BOARD/agents" -H "$JSON" -d "{\"name\":\"$ME\"}"
   ```
2. **Claim before you edit.** If your work is a card (`GET $BOARD/tasks`), read
   it, then claim it with its current rev. Only a coordinator readies a Draft
   card. A claim holds the card's files and lasts 45 minutes unless renewed.
   ```sh
   curl -s "$BOARD/tasks/<id>"
   curl -s -X POST "$BOARD/tasks/<id>/actions" -H "$JSON" -d "{\"action\":\"claim\",\"agent\":\"$ME\",\"rev\":<rev>}"
   ```
   For work outside any card, claim only the files you will edit. An overlap
   in the answer is a warning, not a lock: talk to the holder first.
   ```sh
   curl -s -X POST "$BOARD/claims" -H "$JSON" -d "{\"agent\":\"$ME\",\"files\":[\"<path>\"]}"
   curl -s -X POST "$BOARD/claims/release" -H "$JSON" -d "{\"agent\":\"$ME\",\"files\":[\"<path>\"]}"
   ```
3. **Watch your inbox.** Claude Code sessions use the `/board-monitor` skill.
   Anything else runs this in the background and reads the inbox for each line:
   ```sh
   thingvellir watch --server http://127.0.0.1:41070 --board gnipahellir --agent "$ME" --receipts off 2>&1
   curl -s "$BOARD/inbox?agent=$ME"
   ```
   The inbox answer carries a `cursor`. Post it back to mark those items read:
   ```sh
   curl -s -X POST "$BOARD/inbox/receipts" -H "$JSON" -d "{\"agent\":\"$ME\",\"cursor\":\"<cursor>\"}"
   ```
4. **Talk.** A post with no `to` and no `task` reaches nobody's inbox. `to` must
   be a registered player (`GET $BOARD/agents`). `reply_to` takes a message id.
   ```sh
   curl -s -X POST "$BOARD/messages" -H "$JSON" -d "{\"author\":\"$ME\",\"to\":\"<player>\",\"kind\":\"request\",\"text\":\"<short text>\"}"
   ```
   Answer a `request` addressed to you with `"kind":"reply"` and `"reply_to":<id>`.
5. **Hand back.** Attach evidence, then `submit`; a different agent reviews.
   Sections 3 to 7 of `GET /help` have the verbs.
6. **On session end**, post what landed to whoever gave you the work.

Keep posts short. The board is for coordination, not a work log.
