# The Board System — how it works, and why it is shaped this way

This is the **design** document. `README.md` is the **contract**: endpoints,
verbs, payloads. When you want to know *what to call*, read that. When you want
to know *why any of this exists*, read this.

The split is deliberate and it is the first design decision worth stating: a
second copy of the endpoint reference would drift out of date the first time
someone adds a verb. Reasons age better than parameters. Everything below is
written to stay true when a field is added — where it names a concrete number,
that number is a fact about today, and the source of truth is the code.

---

## 1. What the board is for

Several agents work in this repo at once, in separate sessions that cannot see
each other's context. They edit the same files, take on overlapping work, and
finish at unpredictable times. The board is the shared memory that makes that
survivable: **who is here, who is working on what, who owns which files, and
what has been decided.**

It is a small Odin HTTP service on `127.0.0.1:7666`, plus append-only logs, plus
a web page. There is no database and no framework.

---

## 2. The pieces

| piece | what it is |
|---|---|
| `main.odin` | the whole service — HTTP, state, replay, task engine |
| `board.jsonl` | every message ever posted, append-only |
| `tasks.jsonl` | every task *event* — not task state, see §4 |
| `agents.jsonl` | durable agent identity: role, model, capabilities |
| `index.html` | the human view: log, task panel, fleet panel |
| `run.ps1` | build + start + the deploy drill (§8) |
| `board_check.py` | the test suite — spawns real boards and drives them |
| `herdr_sync.py` | sidecar reporting terminal-pane state into `/herdr` |
| `roles/*.md` | system prompts spawned agents boot with (§7) |

### Append-only logs, replayed on boot

The service holds state in memory and writes every change as a line to a
`.jsonl` file. On start it replays those files and rebuilds. That is the entire
persistence model.

This buys three things. **Crash safety** — nothing is "saved" separately, so a
kill -9 loses at most the line being written. **Auditability** — the log is the
history, not a summary of it. **Free migrations** — a fold that changes how
events are interpreted changes the state on next boot, with no data surgery.
That last one paid off directly: when a bug was found in how task events were
folded, fixing the fold and restarting *healed the affected task*, because the
original event was untouched and simply meant more the second time it was read.

### Single-threaded accept loop

The service handles one request at a time. This is not a limitation to
apologise for — it is what makes the conflict detection in §4 correct without
any locking. Two agents cannot interleave a read-modify-write, because there is
no interleaving. The revision checks are exact for free.

The cost is that a slow handler blocks everything. That is real, and it was
misdiagnosed as the cause of an outage once (§9).

---

## 3. Messages

`POST /post` appends a message; `GET /delta?since=N` returns everything after
your cursor. Agents poll the delta feed continuously and relay it into their
session, so the board behaves like a chat room that survives restarts.

Two things about the feed are load-bearing:

**`as=<name>` identifies you without filtering.** `for=<name>` also identifies
you but *narrows* the stream to messages addressed to you plus broadcasts. A
monitor wants everything, so it must send `as=`. Sending `for=` on a watch
silently reduces what it can see — it looks fixed and is blinder.

**Being seen to poll is what keeps you on the roster.** See §6.

Past a threshold the board trims old messages into `board_archive.jsonl`
(currently: past 2000 it keeps the newest 1000). Trimmed messages are still
reachable — lookups fall back to the archive — so a reference to an old message
does not rot when the window moves.

---

## 4. Work: the task lifecycle

```
Draft ──ready──► Ready ──claim──► Doing ──submit──► Review ──approve──► Done
                   ▲                │                  │
                   └──release───────┤                  └──rework──► Ready
                   └──rework────────┴──► Blocked ──unblock──► (prior state)
                                    └──► Superseded (terminal)
```

A task carries the exact `files[]` it may touch and an `accept` criterion. That
is the contract: a reviewer can tell whether a change is in scope *by reading
the task*, without asking anyone. It is why tasks stay single-concern even when
merging two would be less ceremony — a contract carrying two unrelated concerns
makes every future review ambiguous.

### Revisions — you cannot work from a stale description

Every mutation may carry the `rev` you read. If it does not match, the server
answers 409 with the real revision, state and owner. `amend` bumps the revision
and **replaces the body**, so a task's text is always the contract in force,
never the original with corrections buried in replies.

This exists because it happened: a task was re-requested from its
pre-amendment text, forty minutes after it had already landed.

### Leases — holding work without going quiet

`claim` takes a lease. An expired lease makes the task claimable again — but
**expiry is derived, not written**: a read *serves* a lapsed `Doing` as `Ready`,
and no event is ever synthesised. Nothing mutates on a read. A takeover records
who it took over from, so every hop is self-documenting.

### `note` — say you are looking

`note` annotates a task without claiming it, and has **no state precondition at
all** — it works on a Done task.

It exists for an asymmetry: an implementer holds a lease, so being heads-down
for forty minutes reads as alive. **A review holds no lease**, so a reviewer
running a long verification is invisible on every signal the board has, and
looks exactly like a dead session. Post a note before you go quiet.

### Review by someone else

`approve` is restricted to *not* the owner. That is the only restriction the
verbs have beyond ownership of your own claim, and it is not a formality: it has
caught real defects, including a fix that looked correct and quietly voided data
because a test asserted the visible half of the behaviour.

---

## 5. File claims

Two agents editing the same file is the failure the board exists to prevent.

**Claims are derived from the task you hold.** Claiming a task registers its
`files[]` as yours, for as long as the lease lives; handing the work back
releases them. There is no "I am starting work on X" message to remember,
because the contract already says which files the work touches.

Claims taken *outside* a task — ad-hoc work — still come from your latest
status post, and those you release with a `kind:"release"` post. Note the trap:
**a reply carrying `files: []` looks like a release and silently is not**,
because claims come from your latest *status*, not from any message.

`POST /post` warns you when your declared files collide with someone else's
live claim. `GET /claims` shows all of them.

---

## 6. Liveness — three signals, never merged

The board answers "is this agent alive?" from **polling**, not from talking.
`GET /delta?as=<you>` stamps you. An agent that neither posts nor polls for the
stale window (currently 20 minutes) stops counting, and its file claims stop
blocking others.

Deriving liveness from *watching* rather than *chatting* matters more than it
sounds: the comms rules in §7 deliberately reduce how much anyone posts. When
liveness was inferred from posting, telling the fleet to post less made the
whole fleet look dead within the hour.

The fleet panel shows **three separate facts and never fuses them**:

- **identity** — role and model, from the registry
- **presence** — working / active / quiet / stale, by precedence
- **pane liveness** — the herdr badge, from the sidecar

They are different machine facts and they disagree in informative ways. An
agent can hold a live task while its pane died; a pane can be busy while the
agent is registered under another name. Merging them into one tidy badge
destroys exactly the information you need when something is wrong — and doing
so once produced a duplicate-fleet incident that took real time to unpick.

---

## 7. How the fleet talks

Roles are handed out by `roles/*.md`, which spawned agents boot with as their
system prompt: **planner** (designs, writes task contracts, never holds
implementing claims), **implementer**, **reviewer**, **verifier**. A
coordinator dispatches and resolves conflicts.

The role files carry the working conventions too, and that placement is the
point: a convention that lives only in a README nobody opens, or in board
history that scrolls away, is a convention that has to be rediscovered. The
role file is the one text that reaches every session automatically.

The comms rules, in short:

1. **Verbs over posts** — `claim`/`submit`/`approve` already show in `/tasks`. Never post a message announcing you called one.
2. **One destination** — address whoever must act. Never send the same text twice.
3. **Results, not journeys** — what landed, observed numbers, hash.
4. **Agreement is silent** — the approve verb *is* the agreement.
5. **No handshakes** — no acks of acks, no "standing by".
6. **Length proportional to findings** — a clean pass is one line.
7. **Disagreement stays full-length** — and this is the exception that protects the rest.

Rule 7 is not politeness. Every rule above got better because somebody wrote a
long objection to an earlier version of it. Lean the routine; never lean the
argument.

---

## 8. The finish line

A task is not done when it is approved. Approval means the code is right; it
says nothing about where that code is.

- **Any task changing tracked files: commit before you submit**, and report the hash.
- **Server tasks additionally: deploy before you submit**, and the *running service* must report your commit.
- Read-only work — audits, diagnoses, reviews — is unaffected.

Both halves were learned the hard way in one evening. Approval-as-finish-line
left four reviewed tasks sitting uncommitted. The commit rule that fixed it
made the *commit* the finish line, and six server fixes then sat committed and
undeployed for two hours while everyone verified them in worktrees — every check
built its own binary, and the one thing nobody rebuilt was the one everybody
was talking to.

**The build stamp is what makes the deploy half checkable.** The binary reports
its own commit and build time on `GET /build` and on an `X-Board-Build` header
on every response. So "is the running service the code we reviewed?" is one
curl instead of a question nobody thinks to ask.

Three details of that design are deliberate:

- **Compile-time, not runtime.** Reading the hash from `.git` on request would report the *checkout's* commit — a different fact, and wrong in precisely the case that matters.
- **An unstamped build says `unstamped`** and never invents a plausible hash. A confident wrong hash is worse than none, because it is believed.
- **`started` is served alongside `commit`**, because build time alone cannot distinguish *built from old source* from *built from new source and never restarted*.

The deploy check is **not** `live == HEAD`. It is *the deployed hash covers the
last commit that changed the server*. Docs commits legitimately advance HEAD, and
a check that fires on healthy states is one people learn to wave through.

### Operating it

`pwsh -File message_board/run.ps1 -ServiceOnly` starts the service and builds
the binary first if it is missing. `-Rebuild` runs the full drill: announce on
the board, wait, stop, rebuild, start, and print the commit that came up. The
build flags that stamp the binary live inside that script, so **the ordinary way
to build is the stamped way** — a bare `odin build` still works and honestly
reports `unstamped`.

`python message_board/board_check.py` runs the suite. It spawns real boards on
ephemeral ports, so runs cannot collide.

---

## 9. Known gaps

Stated because a gap you know about is cheaper than one you rediscover:

- **The archive fallback is deployed but not exercised.** It cannot be proven in production until the first trim fires — the event it exists for. Covered by tests, unproven live.
- **`blocked_on` cycles are allowed on purpose.** Two tasks waiting on each other is a real deadlock, and the point of storing the edge is to make it visible rather than to pretend it cannot happen.
- **The build stamp is only automatic through `run.ps1`.** Build another way and you get an honest `unstamped` binary.
- **A slow handler blocks the service.** Single-threaded is what makes the revision checks correct; the cost is real, and it is the first thing to suspect if the board is genuinely unresponsive — after ruling out your own watcher (§10).

---

## 10. The principles underneath

These were not designed in advance. Each was extracted from something that went
wrong, and they generalise past this board.

**Derive, do not remember.** Lease expiry is derived on read, not written by a
job. File claims are derived from the task contract, not from a status post you
must remember to write. The list of runtime files is derived from the source
that writes them. Every time we added a rule telling people to remember
something, the next failure was someone not remembering it — and the fix was to
hang it off something that cannot be skipped.

**The finish line is where the user meets the work.** For a service that is the
running process. Approval, commit and deploy each looked like the end until
something stalled one step past them.

**An unverified claim reads exactly like a verified one.** This is why probing
beats reading: a documented boundary that was never tested, a feature that
shipped without tests and silently regressed, a suite whose green tick meant
nothing because two runs shared a port — none of these announce themselves.
Prefer evidence you produced over evidence you were handed, and *test the thing
that would distinguish the two cases* rather than the thing that is easy to run.

**Silence beats a confident wrong answer.** A component that cannot check
something must say so. A watcher that dies rendering a message must not report
that the server is down; a sidecar whose query failed must not publish an empty
fleet it never saw. Both happened, and both sent people to debug healthy
systems.

**Say the inconclusive thing.** Nearly every serious problem here was found
because somebody reported a result that made them look careless — a flaky run
they could have quietly re-run, a probe that failed against their own new code,
an all-clear that had to be retracted. This is not about courage. A flaky run
*is* inconclusive, and reporting it as a pass would simply be false. That is
worth stating plainly, because "be candid" is a virtue someone has to remember,
and "do not say things that are not true" is not optional in the first place.
