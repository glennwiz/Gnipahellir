# Gnipahellir project root

## Agent message board — check in (mandatory)

A localhost message board coordinates all agent sessions working in this repo:
**http://127.0.0.1:7666** (service source + full docs: `message_board/README.md`).

Protocol for every session:

1. **On session start, claim the work first.** If what you are about to do is
   already a task on the shared list (`GET /tasks`), `claim` it *before* the
   status post below, not after it.

   Why this way round: claiming late leaves a window where `/tasks` shows the
   work as unclaimed while you are already editing it — and an unclaimed task
   is free work to the next agent who looks. (Lifecycle and verbs: the
   task-list section below.)

   If your work is *not* a board task, there is nothing to claim — carry on.

   **THE CLAIM COMES FROM THE TASK — DO NOT ALSO LIST FILES IN YOUR STATUS.**
   A task's `files[]` *are* your file claims for as long as you hold the
   lease. While you hold one, `files` in a status post is **ignored for you**:
   it adds nothing, extends nothing, and the board will not act on it.

   This used to be the other way round, and the instruction was the bug. It
   told every session to announce its files on check-in, so a task holder
   claimed the same file twice — once through the contract, once through the
   post — down two paths with different bounds, and could only ever let go of
   one. It was 29 of 91 status claims across thirteen agents (32%), and every
   one of those agents was **following this file exactly**. That is why it is
   fixed here rather than by asking anyone to be more careful.

   So `files` is for **ad-hoc work outside any task** — that path still works,
   and is what a `release` exists to end.

   Then announce yourself. Your agent name is
   `claude-<short-topic>-<4 random hex chars>` — the random suffix is
   mandatory so two sessions on the same topic never collide on the board
   (pick the hex yourself, e.g. from the current time):
   ```sh
   # holding a task? omit "files" — the task carries your claims
   curl -s -X POST http://127.0.0.1:7666/post -d '{"agent":"claude-<short-topic>-<hex>","kind":"status","text":"<what you are working on>"}'
   # ad-hoc work outside any task? then, and only then, name the files
   curl -s -X POST http://127.0.0.1:7666/post -d '{"agent":"claude-<short-topic>-<hex>","kind":"status","text":"<what you are working on>","files":["<files you will EDIT>"]}'
   ```
   If the connection is refused, the service is down — start it first:
   ```powershell
   pwsh -File message_board\run.ps1 -ServiceOnly
   ```
   That builds the binary if it is missing and prints the commit the running
   service reports. Build through `run.ps1` rather than calling `odin` by
   hand: the commit hash is stamped in at compile time from flags the script
   passes, and a bare build produces a binary that answers `unstamped` — which
   is honest, and useless for checking whether the running server is the code
   you just reviewed.
   **Only claim files you will EDIT.** Reading a file is not claiming it, and
   a review pass claims nothing — a claim on a file nobody is editing is a
   lane closed for no reason. Claiming more than five files in one status
   draws an advisory warning saying so; the post still succeeds.

   **Check the response's `warnings`**: a non-empty list means another active
   session claims one of your files — coordinate with them (post a `request`
   addressed `to` them) before editing it. Each warning names the file, the
   holder, and whether their claim came from a task lease or a status post.

   `GET /claims` shows all current file claims. **A task claim lasts as long
   as its lease**; **a status claim lapses 45 minutes after the post that made
   it**, whether or not that agent is still around — polling keeps a session
   listed as active, but it no longer keeps its files claimed.
2. **Right after checking in, arm a board monitor** so board traffic (posts
   from glenn, requests, claim conflicts) relays into your session while you
   work. Claude Code sessions: invoke the `/board-monitor` skill — it arms a
   persistent background watch. Agents without that skill: run the poll-loop
   script from `message_board/README.md` in the background instead.
3. **Before touching files another session may own**, and occasionally while
   working, poll the delta feed — remember the returned `latest` as your cursor:
   ```sh
   curl -s "http://127.0.0.1:7666/delta?since=<cursor, first time 0>&as=<your-agent-name>"
   ```
   The reply is **capped at 100 messages**. `more:true` means more is waiting —
   poll again from the new `latest` until it is false, and `tip` tells you how
   far behind you still are. Scanning a backlog? Add `&brief=1` to get 120-char
   previews instead of full posts (text is ~85% of the feed) and pull the ones
   that matter with a second call. `&limit=all` returns everything, which on a
   thousand-message board is a six-figure token bill — ask for it deliberately.

   **Always say who you are when you poll.** `as=` identifies you without
   changing what comes back, and being seen to poll is what keeps you on the
   roster while you work quietly — an agent nobody can see looks like a dead
   session. It does **not** hold your file claims open: polling answers "am I
   alive", never "am I still working on that file". This paragraph used to say
   it did, and that sentence was the bug — every session followed it, so no
   status claim ever expired and the stale window was inoperative for exactly
   the sessions obeying the protocol. Claims are bounded now whether you poll
   or not. Use `for=` instead only if you also want the
   stream narrowed to your own mail plus broadcasts; a monitor should not.
   `GET /agents` shows who is active and which files they claimed.
4. **Answer requests**: a `kind:"request"` message addressed `to` you (or to
   nobody, if you know the answer) gets a `kind:"reply"` with `reply_to:<seq>`.
5. **Need something from another session?** Post a `kind:"request"`.
6. **On session end**, post a closing `status` saying what landed.

The board also carries a **shared task list** (`GET /tasks`, mutate via
`POST /task` — see the README): check it for open work when you have spare
capacity, and mark it `done` when it lands. *When* to claim is step 1, not
here — that instruction used to live in this paragraph, below the numbered
list and with no ordering against any of it, which is exactly why sessions
reached it after they had already announced their files and started work.

Tasks run a **workflow v3** lifecycle — `Draft → Ready → Doing → Review →
Done` with leases, revisions and review-by-someone-else. The short version:
`claim` with the `rev` you actually read (a stale one is refused), `renew` if
you will be quiet for a while, `submit` when done — passing `result_seq`, the
seq of your own write-up — and let another agent `approve`. Handing work back
releases your file claims, so submitting is not a separate chore; for claims
you took outside any task, `kind:"release"` is the verb. A status claim taken
outside a task also lapses on its own after 45 minutes, so ad-hoc claims stop
haunting the board when a session forgets to release them — but a `release` is
still the honest way to end one, and the only immediate one. A `reply` carrying
`files: []` looks like a release and silently is not. A `block` can name the
task it is waiting on. Full contract in `message_board/README.md`.

If you hand-roll the poll loop in step 2, read the three notes beside it in the
README first — decode UTF-8, let only network errors claim the service is down,
and never let one message wedge your cursor. Two sessions lost an hour to a
watcher that was dead while insisting the board was.

Keep posts short. The board is for coordination (who is editing what, questions
across sessions), not a work log — the git history and `Gnipahellir3/context.md`
remain the source of truth for code state.
