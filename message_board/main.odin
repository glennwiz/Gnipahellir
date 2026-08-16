// Gnipahellir agent message board.
//
// A tiny localhost HTTP service where AI agent sessions check in with what
// they are working on, leave messages for each other, and request/answer
// information across sessions. Storage is an append-only JSONL log so the
// board survives restarts and stays greppable by hand.
//
//   POST /post              — add a message (status / msg / request / reply)
//   POST /spawn             — open a terminal running a claude agent on a task
//   GET  /delta?since=N     — every message with seq > N, plus the latest seq
//   GET  /agents            — last-seen + latest status per agent
//   GET  /                  — plain-text summary for humans
//
// Build: odin build . -out:message_board.exe
// Run:   ./message_board.exe [port]        (default 7666 — Garm guards it)
package message_board

import "core:c/libc"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:encoding/json"

DEFAULT_PORT :: 7666
LOG_FILE :: "board.jsonl"
ARCHIVE_FILE :: "board_archive.jsonl"
ACCESS_LOG :: "access.log"
MAX_REQUEST :: 1 << 20 // 1 MB — nobody's status update needs more

// Retention: past MAX_MESSAGES the oldest are dropped and the log rewritten,
// keeping TRIM_TO. seq stays monotonic, so delta cursors survive a trim —
// clients just never see the discarded history again.
MAX_MESSAGES :: #config(MAX_MESSAGES, 2000)
TRIM_TO :: #config(TRIM_TO, 1000)

// An agent silent for this long is stale: still listed, but its file claims
// no longer count as conflicts. Sessions rarely say goodbye — time-decay
// beats politeness. 20 min per Glenn (seq 155): dead sessions were haunting
// their claims for two hours.
STALE_SECS :: #config(STALE_SECS, 1200)

Message :: struct {
	seq:      int      `json:"seq"`,
	unix:     i64      `json:"unix"`,     // server-side receive time, unix seconds
	agent:    string   `json:"agent"`,    // required: who is speaking
	kind:     string   `json:"kind"`,     // status | msg | request | reply
	text:     string   `json:"text"`,
	files:    []string `json:"files"`,    // files/areas the agent is touching
	to:       string   `json:"to"`,       // optional: addressed agent
	reply_to: int      `json:"reply_to"`, // optional: seq of the request this answers

	// ── v3, all additive (absent fields marshal to zero on old clients) ──
	// Routing is RESOLVED AND STORED at post time, so the log is self-
	// describing instead of relying on a reader re-deriving intent from `to`.
	route:   string `json:"route"`,   // direct | broadcast | anyone
	task_id: int    `json:"task_id"`, // optional: binds this post to a work item
	accepts: int    `json:"accepts"`, // seq of an `anyone` request this post takes up
}

// Old clients never send `route`; derive it from `to` exactly as the board has
// always behaved, so nothing changes for them.
resolve_route :: proc(route, to: string) -> string {
	if route != "" do return route
	switch to {
	case "":            return "broadcast"
	case "anyone", "all": return "anyone"
	}
	return "direct"
}

Agent_Info :: struct {
	agent:       string   `json:"agent"`,
	last_seen:   i64      `json:"last_seen"`,
	active:      bool     `json:"active"`,
	status:      string   `json:"status"`,
	status_unix: i64      `json:"status_unix"`,
	files:       []string `json:"files"`,
	// Additive: empty for every agent that never registered, so existing
	// callers and the current UI read exactly what they always did.
	role:         string   `json:"role"`,
	model:        string   `json:"model"`,
	capabilities: []string `json:"capabilities"`,
}

// Shared task list (glenn seq 175). State is a replay of an append-only event
// log, so progress survives restarts and history is never lost.
// Workflow v3 lifecycle. `status` is kept beside `state` as the legacy view
// (open|doing|done) so every existing client and the current UI keep working
// unchanged while v3 clients read `state`.
TASK_LEASE_DEFAULT :: 45 * 60   // sized so a heads-down agent never has to chatter
TASK_LEASE_MAX     :: 120 * 60  // one grant only; renew is unlimited

Task :: struct {
	id:      int    `json:"id"`,
	unix:    i64    `json:"unix"`,    // created
	updated: i64    `json:"updated"`,
	creator: string `json:"creator"`,
	owner:   string `json:"owner"`,   // set by claim/done, cleared by reopen
	text:    string `json:"text"`,    // ALWAYS the amended contract, never the original
	status:  string `json:"status"`,  // legacy view: open | doing | done

	// ── v3, all additive ────────────────────────────────────────────────
	state:         string   `json:"state"`,      // Draft|Ready|Doing|Review|Done|Blocked|Superseded
	rev:           int      `json:"rev"`,        // bumps on every amend; mutations are rev-conditional
	files:         []string `json:"files"`,      // exact file set of the contract
	accept:        string   `json:"accept"`,     // acceptance criteria, stored WITH the work item
	plan_id:       int      `json:"plan_id"`,    // seq of the original plan post
	plan_rev:      int      `json:"plan_rev"`,   // 1 + number of plan amendments
	plan_seqs:     []int    `json:"plan_seqs"`,  // ordered; last entry is binding
	lease_until:   i64      `json:"lease_until"`,// absolute unix; expiry is DERIVED, never written
	attempts:      int      `json:"attempts"`,
	result_seq:    int      `json:"result_seq"`, // board seq of the completion report
	reviewer:      string   `json:"reviewer"`,
	blocked_from:  string   `json:"blocked_from"`,
	// What this task is waiting ON — another task's id, 0 for "blocked, but
	// not on us". Written by block, cleared by unblock. This is the edge the
	// critical path is drawn from: without it the dependency lives only in
	// the coordinator's head and dies with their session.
	blocked_on:    int      `json:"blocked_on"`,
	superseded_by: int      `json:"superseded_by"`,
	origin:        string   `json:"origin"`,     // "v3" (draft-born, review required) | "legacy"
	notes:         [dynamic]string `json:"notes"`,
}

Task_Event :: struct {
	unix:   i64    `json:"unix"`,
	id:     int    `json:"id"`,
	action: string `json:"action"`, // legacy: add|claim|done|reopen · v3: see task_apply
	agent:  string `json:"agent"`,
	text:   string `json:"text"`,

	rev:          int      `json:"rev"`,
	files:        []string `json:"files"`,
	accept:       string   `json:"accept"`,
	plan_id:      int      `json:"plan_id"`,
	plan_rev:     int      `json:"plan_rev"`,
	plan_seq:     int      `json:"plan_seq"`,
	lease_secs:   int      `json:"lease_secs"`,
	result_seq:   int      `json:"result_seq"`,
	by_id:        int      `json:"by_id"`,
	blocked_on:   int      `json:"blocked_on"`,
	// Recorded at write time on a takeover so the immutable log self-documents
	// every Doing->Doing transition; expiry itself never synthesises an event.
	expired_from: string   `json:"expired_from"`,
}

// A lease that has run out makes the task claimable again, but nothing is
// written until someone actually claims it — GET never mutates the log.
task_lease_expired :: proc(t: ^Task, now: i64) -> bool {
	return t.lease_until != 0 && now > t.lease_until
}

// What a reader should see: a Doing task whose lease lapsed is served as
// Ready, because that is what the next claim will find.
task_effective_state :: proc(t: ^Task, now: i64) -> string {
	if t.state == "Doing" && task_lease_expired(t, now) do return "Ready"
	return t.state
}

Board :: struct {
	messages:  [dynamic]Message,
	next_seq:  int,
	log_fd:    ^os.File,
	access_fd: ^os.File,
	tasks:        [dynamic]Task,
	next_task_id: int,
	tasks_fd:     ^os.File,
	registry:     [dynamic]Agent_Record,  // durable identity, latest-wins
	agents_fd:    ^os.File,
	herdr_state:  string, // latest fleet snapshot from herdr_sync.py, "[]" until first post
	// Poll-based liveness (glenn task #2): a GET /delta?for=<agent> is proof
	// of life — a quietly-watching monitor stays active without posting
	// heartbeat noise. In-memory only: after a restart every live watcher
	// re-polls within its next cycle, so the map rebuilds itself.
	last_poll:    map[string]i64,
	// When each agent last handed work back (task submit/release). Status
	// claims older than this are dropped — see claims_clear. Rebuilt by the
	// task fold on every replay, so it is derived state, not remembered
	// state, and nothing synthetic is written to the message log to carry it.
	claims_cleared: map[string]i64,
}

// Mark everything `agent` had claimed as let go, as of `unix`.
//
// The alternative was for the server to append a `release` MESSAGE on the
// agent's behalf, which would have put words in their mouth in an
// append-only log that people read as testimony. This records the same fact
// where it actually happened — on the task event — and the message log stays
// something only agents write.
claims_clear :: proc(agent: string, unix: i64) {
	if agent == "" do return
	if prev, ok := board.claims_cleared[agent]; ok && prev >= unix do return
	board.claims_cleared[agent] = unix
}

// Set by send_response; safe as a package global because the server handles
// one connection at a time.
resp_status: string = "-"

board: Board

board_load :: proc() {
	board.next_seq = 1
	if data, read_err := os.read_entire_file_from_path(LOG_FILE, context.allocator); read_err == nil {
		defer delete(data)
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			if len(strings.trim_space(line)) == 0 do continue
			m: Message
			if err := json.unmarshal(transmute([]u8)strings.clone(line), &m); err != nil {
				fmt.eprintfln("skipping bad line in %s: %v", LOG_FILE, err)
				continue
			}
			// Every message written before routing existed carries no route.
			// Resolve it on the way in so consumers never re-derive intent
			// from `to` themselves — the disk stays append-only untouched,
			// only the served view is complete.
			m.route = resolve_route(m.route, m.to)
			append(&board.messages, m)
			if m.seq >= board.next_seq do board.next_seq = m.seq + 1
		}
	}

	fd, err := os.open(LOG_FILE, {.Write, .Create, .Append})
	if err != nil {
		fmt.eprintfln("cannot open %s for writing: %v", LOG_FILE, err)
		os.exit(1)
	}
	board.log_fd = fd

	if afd, aerr := os.open(ACCESS_LOG, {.Write, .Create, .Append}); aerr == nil {
		board.access_fd = afd
	} else {
		fmt.eprintfln("cannot open %s - running without access log: %v", ACCESS_LOG, aerr)
	}

	tasks_load()
	agents_load()
	task_archive_sweep()
}

TASKS_FILE         :: "tasks.jsonl"
TASKS_ARCHIVE_FILE :: "tasks_archive.jsonl"
AGENTS_FILE        :: "agents.jsonl"

// Terminal tasks leave the live log after a week. Nothing is ever deleted —
// the events move to the archive and replay reads both, so history survives
// exactly as the messages' own archive does.
TASK_RETENTION_SECS :: #config(TASK_RETENTION_SECS, 7 * 24 * 3600)

// Who an agent IS, as opposed to what it last said. Identity used to be
// inferred entirely from message traffic, so it evaporated the moment a
// session went quiet; this is a durable statement, replayed latest-wins.
Agent_Record :: struct {
	unix:         i64      `json:"unix"`,
	agent:        string   `json:"agent"`,
	role:         string   `json:"role"`,
	model:        string   `json:"model"`,
	capabilities: []string `json:"capabilities"`,
}

registry_find :: proc(name: string) -> ^Agent_Record {
	for &r in board.registry do if r.agent == name do return &r
	return nil
}

// Latest-wins PER FIELD, not per record: a register event states what the
// caller KNOWS, and silence is not an assertion of emptiness.
//
// This is not defensiveness against careless callers — the collision is
// designed in. /spawn registers {agent, model, role} because that is all it
// knows, and an agent checking in self-describes with capabilities it alone
// knows. Whole-record overwrite made the second call silently blank the
// first's fields. The cost is that omission can no longer CLEAR a field,
// which nothing wants.
registry_apply :: proc(rec: Agent_Record) {
	existing := registry_find(rec.agent)
	if existing == nil {
		append(&board.registry, rec)
		return
	}
	existing.unix = rec.unix
	if rec.role != ""            do existing.role = rec.role
	if rec.model != ""           do existing.model = rec.model
	if len(rec.capabilities) > 0 do existing.capabilities = rec.capabilities
}

registry_post :: proc(rec: Agent_Record) {
	stamped := rec
	stamped.unix = time.time_to_unix(time.now())
	if line, err := json.marshal(stamped, {}, context.temp_allocator); err == nil {
		os.write(board.agents_fd, line)
		os.write_string(board.agents_fd, "\n")
	}
	registry_apply(stamped)
}

agents_load :: proc() {
	// Same torn-tail vs corrupt-interior policy as the task log: one write per
	// line means a crash can only ever damage the last one.
	apply_agent :: proc(line: string, ok: ^bool) {
		rec: Agent_Record
		if err := json.unmarshal(transmute([]u8)strings.clone(line), &rec); err != nil {
			ok^ = false
			return
		}
		if rec.agent == "" do return
		registry_apply(rec)
	}
	replay_lines(AGENTS_FILE, apply_agent)

	fd, err := os.open(AGENTS_FILE, {.Write, .Create, .Append})
	if err != nil {
		fmt.eprintfln("cannot open %s for writing: %v", AGENTS_FILE, err)
		os.exit(1)
	}
	board.agents_fd = fd
}

// ── CRASH-SAFE APPEND, formalised ───────────────────────────────────────────
//
//  Every event is ONE os.write of ONE line. A crash can therefore only ever
//  damage the LAST line of a log — anything earlier was completed by a prior
//  write. That gives two distinct recovery rules, and the difference matters:
//
//    torn FINAL line     — expected. A power cut mid-append. Tolerated and
//                          logged quietly; the event simply never happened.
//    corrupt INTERIOR    — NOT expected, and not something a crash can cause.
//                          Real corruption or an outside editor. Skipped so
//                          the board still boots, but LOUDLY, because
//                          something is wrong that recovery cannot explain.
//
//  Reading them the same way would let genuine corruption hide behind the
//  ordinary case forever.
@(private = "file")
replay_lines :: proc(path: string, apply: proc(line: string, ok: ^bool)) {
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil do return
	defer delete(data)

	lines := make([dynamic]string, context.temp_allocator)
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if len(strings.trim_space(line)) == 0 do continue
		append(&lines, line)
	}
	for line, i in lines {
		ok := true
		apply(line, &ok)
		if ok do continue
		if i == len(lines) - 1 {
			fmt.eprintfln("%s: torn final line tolerated (crash during append)", path)
		} else {
			fmt.eprintfln("WARNING %s: CORRUPT INTERIOR LINE %d skipped - a crash cannot cause this, something else wrote to the log",
				path, i + 1)
		}
	}
}

// Events already applied from the archive, so the crash-between-archive-and-
// rewrite window cannot double-apply them. Keyed on the exact event line:
// (id,unix) was the contract, but two events for one task inside the same
// second are ordinary (claim then submit), and that key would silently drop
// the second. The archive is a byte-copy, so exact lines match exactly.
@(private = "file")
replayed: map[string]bool

tasks_load :: proc() {
	board.next_task_id = 1
	replayed = make(map[string]bool)
	defer delete(replayed)

	apply_task :: proc(line: string, ok: ^bool) {
		if line in replayed do return          // already applied from the archive
		ev: Task_Event
		if err := json.unmarshal(transmute([]u8)strings.clone(line), &ev); err != nil {
			ok^ = false
			return
		}
		replayed[strings.clone(line)] = true
		task_apply(ev)
	}
	// Archive first (older history), then the live log.
	replay_lines(TASKS_ARCHIVE_FILE, apply_task)
	replay_lines(TASKS_FILE, apply_task)

	fd, err := os.open(TASKS_FILE, {.Write, .Create, .Append})
	if err != nil {
		fmt.eprintfln("cannot open %s for writing: %v", TASKS_FILE, err)
		os.exit(1)
	}
	board.tasks_fd = fd
}

// Move events belonging to long-finished tasks out of the live log.
//
//  ORDER IS THE SAFETY: append to the archive FIRST, then rewrite the live log
//  via temp+rename. A crash anywhere in between leaves the events in BOTH
//  files and loses nothing — replay dedupes them. The reverse order would have
//  a window where they exist in NEITHER.
task_archive_sweep :: proc() {
	now := time.time_to_unix(time.now())

	// Cheap in-memory check first: no eligible task means no file I/O at all,
	// so this can hang off every mutation without cost.
	stale := make(map[int]bool, 8, context.temp_allocator)
	for &t in board.tasks {
		if (t.state == "Done" || t.state == "Superseded") &&
		   now - t.updated > TASK_RETENTION_SECS {
			stale[t.id] = true
		}
	}
	if len(stale) == 0 do return

	data, read_err := os.read_entire_file_from_path(TASKS_FILE, context.temp_allocator)
	if read_err != nil do return

	keep    := strings.builder_make(context.temp_allocator)
	archive := strings.builder_make(context.temp_allocator)
	moved   := 0
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if len(strings.trim_space(line)) == 0 do continue
		ev: Task_Event
		if err := json.unmarshal(transmute([]u8)strings.clone(line), &ev); err != nil {
			// Unreadable lines stay in the live log: this proc moves history,
			// it does not get to decide anything is beyond saving.
			strings.write_string(&keep, line)
			strings.write_string(&keep, "\n")
			continue
		}
		target := &keep
		if ev.id in stale {
			target = &archive
			moved += 1
		}
		strings.write_string(target, line)
		strings.write_string(target, "\n")
	}
	if moved == 0 do return

	// 1. Archive first — after this the events are safe even if we die here.
	if fd, err := os.open(TASKS_ARCHIVE_FILE, {.Write, .Create, .Append}); err == nil {
		os.write_string(fd, strings.to_string(archive))
		os.close(fd)
	} else {
		fmt.eprintfln("archive sweep: cannot open %s: %v", TASKS_ARCHIVE_FILE, err)
		return
	}

	// 2. Then swap the live log atomically. The append fd must be closed
	//    across the rename or it keeps writing to the replaced file.
	tmp := fmt.tprintf("%s.tmp", TASKS_FILE)
	if fd, err := os.open(tmp, {.Write, .Create, .Trunc}); err == nil {
		os.write_string(fd, strings.to_string(keep))
		os.close(fd)
	} else {
		fmt.eprintfln("archive sweep: cannot write %s: %v", tmp, err)
		return
	}
	if board.tasks_fd != nil do os.close(board.tasks_fd)
	if err := os.rename(tmp, TASKS_FILE); err != nil {
		fmt.eprintfln("archive sweep: rename failed: %v", err)
	}
	if fd, err := os.open(TASKS_FILE, {.Write, .Create, .Append}); err == nil {
		board.tasks_fd = fd
	}
	fmt.eprintfln("archived %d task events older than %d days", moved, TASK_RETENTION_SECS / 86400)
}

task_find :: proc(id: int) -> ^Task {
	for &t in board.tasks do if t.id == id do return &t
	return nil
}

// Fold one event into the task list. Shared by the replay-on-load and the
// live POST path, so the in-memory state always matches a fresh replay.
// The legacy three-value view, derived from the v3 state so old clients and
// the current UI never see a status that contradicts the lifecycle.
@(private = "file")
task_sync_status :: proc(t: ^Task) {
	switch t.state {
	case "Draft", "Ready", "Blocked": t.status = "open"
	case "Doing", "Review":           t.status = "doing"
	case:                             t.status = "done"   // Done, Superseded
	}
}

task_apply :: proc(ev: Task_Event) {
	// Legacy actions map forward forever: the 55 events already on disk replay
	// into sane v3 states, and an un-upgraded client keeps working untouched.
	switch ev.action {
	case "add", "draft":
		born := "legacy" if ev.action == "add" else "v3"
		state := "Ready" if ev.action == "add" else "Draft"
		t := Task{
			id = ev.id, unix = ev.unix, updated = ev.unix,
			creator = ev.agent, text = ev.text,
			state = state, rev = 1, origin = born,
			files = ev.files, accept = ev.accept,
			plan_id = ev.plan_id, plan_rev = ev.plan_rev,
		}
		// Callers send plan_seq alone — the contract never asked for plan_id
		// or plan_rev, so derive them. Without this the first v3-born task
		// reported plan_id 0 / plan_rev 0 while its own log line held 600.
		if t.plan_id == 0 && ev.plan_seq != 0 {
			t.plan_id, t.plan_rev = ev.plan_seq, 1
		}
		// HEAP, not a composite literal. `[]int{ev.plan_seq}` does not own its
		// backing store, so the slice outlived it and every task read [0] —
		// deterministically, in the same request, before any heap churn. The
		// event log was right the whole time; only this projection was wrong.
		if ev.plan_seq != 0 {
			seqs := make([]int, 1)
			seqs[0] = ev.plan_seq
			t.plan_seqs = seqs
		}
		task_sync_status(&t)
		append(&board.tasks, t)
		if ev.id >= board.next_task_id do board.next_task_id = ev.id + 1
		return
	}

	t := task_find(ev.id)
	if t == nil do return
	t.updated = ev.unix

	switch ev.action {
	case "ready":
		t.state = "Ready"
	case "amend":
		// THE fix for stale task text: the body IS the latest amendment, and
		// every mutation is rev-conditional, so acting on an old description
		// 409s rather than executing it.
		t.rev += 1
		if ev.text != ""   do t.text = ev.text
		if ev.accept != "" do t.accept = ev.accept
		if ev.files != nil do t.files = ev.files
		if ev.plan_rev != 0 do t.plan_rev = ev.plan_rev
		if ev.plan_seq != 0 {
			// Explicit heap allocation, same ownership rule as the draft fold:
			// whatever backs plan_seqs has to outlive this request.
			seqs := make([]int, len(t.plan_seqs) + 1)
			copy(seqs, t.plan_seqs)
			seqs[len(t.plan_seqs)] = ev.plan_seq
			t.plan_seqs = seqs
			// A new plan post IS a new plan revision — PlanRevision answers
			// "which contract", TaskRevision answers "which text of it".
			if ev.plan_rev == 0 do t.plan_rev = max(t.plan_rev, 1) + 1
			if t.plan_id == 0 do t.plan_id = ev.plan_seq
		}
	case "claim":
		lease := ev.lease_secs
		if lease <= 0 do lease = TASK_LEASE_DEFAULT
		if lease > TASK_LEASE_MAX do lease = TASK_LEASE_MAX
		t.state, t.owner = "Doing", ev.agent
		t.lease_until = ev.unix + i64(lease)
		t.attempts += 1
	case "renew":
		lease := ev.lease_secs
		if lease <= 0 do lease = TASK_LEASE_DEFAULT
		if lease > TASK_LEASE_MAX do lease = TASK_LEASE_MAX
		t.lease_until = ev.unix + i64(lease)
	case "release":
		t.state, t.owner, t.lease_until = "Ready", "", 0
		claims_clear(ev.agent, ev.unix)
	case "submit":
		t.state, t.lease_until = "Review", 0
		t.result_seq = ev.result_seq
		// SUBMIT IS A RELEASE. Handing the work back already drops the
		// task-derived claims; the status-derived ones used to survive it and
		// needed a separate `release` POST that is easy to forget — Sonnet
		// left index.html claimed all afternoon exactly this way. Four
		// actions where three would do is a class of error, not a lapse, so
		// the second one stopped being separate.
		claims_clear(ev.agent, ev.unix)
	case "approve":
		t.state, t.reviewer, t.lease_until = "Done", ev.agent, 0
	case "rework":
		t.state, t.owner, t.lease_until = "Ready", "", 0
	case "block":
		if t.state != "Blocked" do t.blocked_from = t.state
		t.state = "Blocked"
		// Assigned unconditionally, so a re-block that names nothing CLEARS a
		// stale dependency rather than leaving the panel drawing an edge to a
		// task we are no longer waiting on. blocked_on describes the block
		// currently in force, not every reason we were ever blocked.
		t.blocked_on = ev.blocked_on
	case "unblock":
		t.state = t.blocked_from if t.blocked_from != "" else "Ready"
		t.blocked_from = ""
		t.blocked_on = 0
	case "supersede":
		t.state, t.superseded_by, t.lease_until = "Superseded", ev.by_id, 0
	case "note":
		// Visibility, not workflow: annotate without claiming, so two agents
		// doing the same recon can see each other instead of colliding.
		append(&t.notes, ev.text)
	case "done":   // legacy force-complete
		t.state, t.owner, t.lease_until = "Done", ev.agent, 0
	case "reopen":
		t.state, t.owner, t.lease_until = "Ready", "", 0
	}
	task_sync_status(t)
}

task_post :: proc(ev: Task_Event) {
	stamped := ev
	stamped.unix = time.time_to_unix(time.now())
	if line, err := json.marshal(stamped, {}, context.temp_allocator); err == nil {
		os.write(board.tasks_fd, line)
		os.write_string(board.tasks_fd, "\n")
	}
	task_apply(stamped)
}

board_post :: proc(m: Message) -> Message {
	stored := m
	stored.seq = board.next_seq
	stored.unix = time.time_to_unix(time.now())
	board.next_seq += 1
	append(&board.messages, stored)

	if line, err := json.marshal(stored, {}, context.temp_allocator); err == nil {
		os.write(board.log_fd, line)
		os.write_string(board.log_fd, "\n")
	}

	if len(board.messages) > MAX_MESSAGES do board_trim()
	return stored
}

board_trim :: proc() {
	// Trimmed messages are archived, never discarded — the board's history
	// is the project's dev diary. Archive first, so a failure here leaves
	// everything still in the live log.
	cut := len(board.messages) - TRIM_TO
	if afd, aerr := os.open(ARCHIVE_FILE, {.Write, .Create, .Append}); aerr == nil {
		for m in board.messages[:cut] {
			if line, merr := json.marshal(m, {}, context.temp_allocator); merr == nil {
				os.write(afd, line)
				os.write_string(afd, "\n")
			}
		}
		os.close(afd)
	} else {
		fmt.eprintfln("trim: cannot open %s - keeping messages in live log: %v", ARCHIVE_FILE, aerr)
		return
	}

	remove_range(&board.messages, 0, cut)

	os.close(board.log_fd)
	fd, err := os.open(LOG_FILE, {.Write, .Create, .Trunc})
	if err != nil {
		fmt.eprintfln("trim: cannot rewrite %s: %v", LOG_FILE, err)
		os.exit(1)
	}
	for m in board.messages {
		if line, merr := json.marshal(m, {}, context.temp_allocator); merr == nil {
			os.write(fd, line)
			os.write_string(fd, "\n")
		}
	}
	board.log_fd = fd
	fmt.printfln("trimmed board to %d messages (oldest kept: seq %d)", TRIM_TO, board.messages[0].seq)
}

// A message is "for" an agent if addressed to them or broadcast — but never
// their own posts echoed back.
message_is_for :: proc(m: Message, name: string) -> bool {
	if m.agent == name do return false
	return m.to == "" || m.to == name || m.to == "anyone" || m.to == "all"
}

// One row per agent: last_seen from any message, claim (status + files) from
// the latest status-kind message. Claims of stale agents don't conflict.
collect_agents :: proc(allocator := context.temp_allocator) -> []Agent_Info {
	infos := make([dynamic]Agent_Info, allocator)
	index := make(map[string]int, allocator)
	for m in board.messages {
		i, seen := index[m.agent]
		if !seen {
			i = len(infos)
			index[m.agent] = i
			append(&infos, Agent_Info{agent = m.agent})
		}
		infos[i].last_seen = m.unix
		// `release` carries the claim set too — it is the explicit way to drop
		// files, and it always clears them. Without it here, a release would
		// post cleanly and change nothing, which is the exact trap it exists
		// to remove.
		if m.kind == "status" || m.kind == "release" {
			infos[i].status = m.text
			infos[i].status_unix = m.unix
			infos[i].files = m.files
		}
	}
	// A registered agent is listed even when it has never spoken: identity is
	// durable, presence is not.
	for rec in board.registry {
		if _, seen := index[rec.agent]; !seen {
			index[rec.agent] = len(infos)
			append(&infos, Agent_Info{agent = rec.agent})
		}
	}
	// ...and so is a task owner. Now that the contract IS the claim, an agent
	// can hold files having never posted a word — this list was built from
	// message traffic, so without this it would not know they exist.
	for &t in board.tasks {
		if t.owner == "" do continue
		if _, seen := index[t.owner]; !seen {
			index[t.owner] = len(infos)
			append(&infos, Agent_Info{agent = t.owner})
		}
	}

	now := time.time_to_unix(time.now())
	for &info in infos {
		if rec := registry_find(info.agent); rec != nil {
			info.role, info.model, info.capabilities = rec.role, rec.model, rec.capabilities
		}
		// A recent /delta?for= poll counts as being seen: liveness comes
		// from watching, not just talking.
		if p, polled := board.last_poll[info.agent]; polled && p > info.last_seen {
			info.last_seen = p
		}
		info.active = now - info.last_seen <= STALE_SECS

		// A submit or release since that status post means those files were
		// handed back. The status TEXT stays — it is still the last thing
		// they said and readers want it — only the claim is dropped, because
		// a claim is a statement about right now and that one expired.
		//
		// Newer-OR-EQUAL, and the equal half is load-bearing. These stamps
		// are whole seconds, and a short task genuinely finishes inside the
		// same second it was announced in — so requiring strictly-newer
		// switches the fix off for exactly the quick jobs where forgetting
		// the release is likeliest. The reverse tie (a NEW status posted in
		// the same second as a submit) loses its claim for one second and is
		// far rarer than the case this protects.
		if c, cleared := board.claims_cleared[info.agent]; cleared && c >= info.status_unix {
			info.files = nil
		}

		// THE CONTRACT IS THE CLAIM. A task's files[] register as its owner's
		// file claims for as long as they hold the lease — no status post
		// required, and none of the "claiming #N, here are my files" traffic
		// that used to narrate what the task event already recorded.
		//
		// Which states hold: Doing obviously, and Blocked because a blocked
		// owner is the agent MOST likely to have half-edited files sitting in
		// the tree — dropping the warning at block time removes it exactly
		// when it matters most. submit/release/approve hand the work back, so
		// they let go; rework drops with ownership; supersede is terminal.
		// The lease is the bound in every case: derived expiry sheds these
		// the same way it sheds everything else, so no state needs a timer.
		//
		// Status-derived claims still work for ad-hoc work outside any task,
		// and for legacy tasks that carry no files.
		for &t in board.tasks {
			if t.owner != info.agent || len(t.files) == 0 do continue
			if t.state != "Doing" && t.state != "Blocked" do continue
			if task_lease_expired(&t, now) do continue

			info.active = true   // holding a live lease is liveness
			merged := make([dynamic]string, context.temp_allocator)
			append(&merged, ..info.files)
			for f in t.files {
				already := false
				for m in merged do if m == f { already = true; break }
				if !already do append(&merged, f)
			}
			info.files = merged[:]
		}
	}
	return infos[:]
}

age_string :: proc(now, then: i64) -> string {
	d := max(now - then, 0)
	switch {
	case d < 60:    return fmt.tprintf("%ds", d)
	case d < 3600:  return fmt.tprintf("%dm", d / 60)
	case d < 86400: return fmt.tprintf("%dh", d / 3600)
	case:           return fmt.tprintf("%dd", d / 86400)
	}
}

// ---------------------------------------------------------------- HTTP layer

access_log :: proc(method, target: string, req_bytes: int) {
	if board.access_fd == nil do return
	stamp, _ := time.time_to_rfc3339(time.now(), include_nanos = false, allocator = context.temp_allocator)
	line := fmt.tprintf("%s %s %s %s req=%dB\n", stamp, resp_status[:min(3, len(resp_status))], method, target, req_bytes)
	os.write_string(board.access_fd, line)
}

send_response :: proc(client: net.TCP_Socket, status: string, content_type: string, body: string) {
	resp_status = status
	head := fmt.tprintf(
		"HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
		status, content_type, len(body),
	)
	send_all(client, head)
	send_all(client, body)
}

send_all :: proc(client: net.TCP_Socket, s: string) {
	data := transmute([]u8)s
	for len(data) > 0 {
		n, err := net.send_tcp(client, data)
		if err != nil || n <= 0 do return
		data = data[n:]
	}
}

parse_content_length :: proc(headers: string) -> int {
	it := headers
	for line in strings.split_lines_iterator(&it) {
		lower := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(lower, "content-length:") {
			v := strings.trim_space(line[len("content-length:"):])
			if n, ok := strconv.parse_int(v); ok do return n
		}
	}
	return 0
}

read_request :: proc(client: net.TCP_Socket) -> (data: []u8, header_end: int, ok: bool) {
	buf := make([dynamic]u8, 0, 8192, context.temp_allocator)
	chunk: [4096]u8
	header_end = -1
	body_len := 0
	for {
		if header_end < 0 {
			header_end = strings.index(string(buf[:]), "\r\n\r\n")
			if header_end >= 0 {
				body_len = parse_content_length(string(buf[:header_end]))
			}
		}
		if header_end >= 0 && len(buf) >= header_end + 4 + body_len {
			return buf[:], header_end, true
		}
		n, err := net.recv_tcp(client, chunk[:])
		if err != nil || n <= 0 do return nil, -1, false
		append(&buf, ..chunk[:n])
		if len(buf) > MAX_REQUEST do return nil, -1, false
	}
}

query_param :: proc(query: string, key: string) -> (string, bool) {
	it := query
	for pair in strings.split_iterator(&it, "&") {
		eq := strings.index_byte(pair, '=')
		if eq < 0 do continue
		if pair[:eq] == key do return pair[eq + 1:], true
	}
	return "", false
}

handle_connection :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	defer free_all(context.temp_allocator)

	// One line per request, whatever path the handler exits through.
	// Registered after the free_all defer so it runs before it (LIFO) —
	// the log line is built with the temp allocator.
	resp_status = "-"
	method, target := "-", "-"
	req_bytes := 0
	defer access_log(method, target, req_bytes)

	// The server is single-threaded: an idle client (e.g. a browser's
	// speculative preconnect, which sends no bytes) must never wedge the
	// accept loop. Timed-out sockets fall out of read_request as !ok.
	net.set_option(client, .Receive_Timeout, 2 * time.Second)
	net.set_option(client, .Send_Timeout, 2 * time.Second)

	data, header_end, ok := read_request(client)
	req_bytes = len(data)
	if !ok {
		send_response(client, "400 Bad Request", "text/plain", "malformed request\n")
		return
	}

	head := string(data[:header_end])
	line_end := strings.index(head, "\r\n")
	request_line := head if line_end < 0 else head[:line_end]
	fields := strings.fields(request_line, context.temp_allocator)
	if len(fields) < 2 {
		send_response(client, "400 Bad Request", "text/plain", "malformed request line\n")
		return
	}
	method, target = fields[0], fields[1]

	path, query := target, ""
	if q := strings.index_byte(target, '?'); q >= 0 {
		path, query = target[:q], target[q + 1:]
	}

	body := data[header_end + 4:]

	switch {
	case method == "OPTIONS":
		send_response(client, "204 No Content", "text/plain", "")
	case method == "POST" && path == "/post":
		handle_post(client, body)
	case method == "POST" && path == "/spawn":
		handle_spawn(client, body)
	case method == "GET" && path == "/tasks":
		handle_tasks(client)
	case method == "POST" && path == "/task":
		handle_task_mut(client, body)
	case method == "POST" && path == "/register":
		handle_register(client, body)
	case method == "POST" && path == "/kill":
		handle_kill(client, body)
	case method == "GET" && path == "/herdr":
		send_response(client, "200 OK", "application/json",
			board.herdr_state if board.herdr_state != "" else "[]")
	case method == "POST" && path == "/herdr_state":
		if len(board.herdr_state) > 0 do delete(board.herdr_state)
		board.herdr_state = strings.clone(string(body))
		send_response(client, "200 OK", "application/json", `{"ok":true}`)
	case method == "GET" && (path == "/delta" || path == "/messages"):
		handle_delta(client, query)
	case method == "GET" && path == "/agents":
		handle_agents(client)
	case method == "GET" && path == "/claims":
		handle_claims(client)
	case method == "GET" && path == "/archive":
		handle_archive(client)
	case method == "GET" && path == "/":
		handle_index(client)
	case:
		send_response(client, "404 Not Found", "text/plain", "unknown route — see GET / for the API\n")
	}
}

handle_post :: proc(client: net.TCP_Socket, body: []u8) {
	// Unmarshal with the heap allocator: the stored Message owns these strings.
	incoming: Message
	if err := json.unmarshal(body, &incoming); err != nil {
		send_response(client, "400 Bad Request", "application/json",
			fmt.tprintf(`{{"error":"bad json: %v"}}`, err))
		return
	}
	incoming.agent = strings.trim_space(incoming.agent)
	if incoming.agent == "" {
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"'agent' is required"}`)
		return
	}
	switch incoming.kind {
	case "status", "msg", "request", "reply":
	case "release":
		// An explicit verb, because the old way was a silent trap: claims ride
		// on the latest STATUS, so a `reply` carrying files=[] announced a
		// release that never happened and nothing errored. This always clears.
		incoming.files = {}
		if incoming.text == "" do incoming.text = "(claims released)"
	case "":
		incoming.kind = "msg"
	case:
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"kind must be one of: status, msg, request, reply, release"}`)
		return
	}
	incoming.route = resolve_route(incoming.route, incoming.to)

	// First-wins uptake of an `anyone` request. The accept loop is single
	// threaded, so one of two racing responders is literally second and gets a
	// 409 naming the winner — they cannot both believe they won.
	if incoming.accepts != 0 {
		target, target_ok := message_by_seq(incoming.accepts)
		if !target_ok {
			send_response(client, "404 Not Found", "application/json",
				fmt.tprintf(`{{"error":"no message with seq %d"}}`, incoming.accepts))
			return
		}
		if resolve_route(target.route, target.to) != "anyone" {
			send_response(client, "400 Bad Request", "application/json",
				`{"error":"only an 'anyone' request can be accepted"}`)
			return
		}
		for m in board.messages {
			if m.accepts == incoming.accepts {
				send_response(client, "409 Conflict", "application/json",
					fmt.tprintf(`{{"error":"already taken","accepted_by":"%s","seq":%d}}`,
						m.agent, m.seq))
				return
			}
		}
	}

	stored := board_post(incoming)

	// Conflict check at the moment it matters: does another ACTIVE agent's
	// latest status claim any of the files this post claims?
	warnings := make([dynamic]string, context.temp_allocator)
	if len(stored.files) > 0 {
		infos := collect_agents()
		for file in stored.files {
			for info in infos {
				if info.agent == stored.agent || !info.active do continue
				for theirs in info.files {
					if theirs == file {
						append(&warnings, fmt.tprintf("%s claimed by %s (%s ago)",
							file, info.agent, age_string(stored.unix, info.status_unix)))
					}
				}
			}
		}
	}

	Post_Result :: struct {
		seq:      int      `json:"seq"`,
		unix:     i64      `json:"unix"`,
		warnings: []string `json:"warnings"`,
	}
	out, _ := json.marshal(Post_Result{stored.seq, stored.unix, warnings[:]}, {}, context.temp_allocator)
	send_response(client, "200 OK", "application/json", string(out))
}

// A session describing itself on check-in. Re-registering is normal — the
// latest statement wins, and the log keeps every prior one.
handle_register :: proc(client: net.TCP_Socket, body: []u8) {
	rec: Agent_Record
	if err := json.unmarshal(body, &rec); err != nil {
		send_response(client, "400 Bad Request", "application/json",
			fmt.tprintf(`{{"error":"bad json: %v"}}`, err))
		return
	}
	rec.agent = strings.trim_space(rec.agent)
	if rec.agent == "" {
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"'agent' is required"}`)
		return
	}
	registry_post(rec)
	send_response(client, "200 OK", "application/json",
		fmt.tprintf(`{{"ok":true,"agent":"%s"}}`, rec.agent))
}

handle_tasks :: proc(client: net.TCP_Socket) {
	// Expiry is DERIVED, never written: a Doing task whose lease lapsed is
	// SERVED as Ready — which is exactly what the next claim will find — but
	// no event is synthesised, so a GET never touches the log.
	now := time.time_to_unix(time.now())
	view := make([dynamic]Task, 0, len(board.tasks), context.temp_allocator)
	for &t in board.tasks {
		shown := t
		shown.state = task_effective_state(&t, now)
		if shown.state != t.state {
			shown.owner  = ""   // the lease lapsed; nobody holds it now
			shown.status = "open"
		}
		append(&view, shown)
	}
	out, err := json.marshal(view[:], {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

handle_task_mut :: proc(client: net.TCP_Socket, body: []u8) {
	// Heap unmarshal: "add" events keep their strings in the task list.
	ev: Task_Event
	if err := json.unmarshal(body, &ev); err != nil {
		send_response(client, "400 Bad Request", "application/json",
			fmt.tprintf(`{{"error":"bad json: %v"}}`, err))
		return
	}
	ev.agent = strings.trim_space(ev.agent)
	ev.text = strings.trim_space(ev.text)
	if ev.agent == "" {
		send_response(client, "400 Bad Request", "application/json", `{"error":"'agent' is required"}`)
		return
	}
	// ── ATOMICITY LAW ───────────────────────────────────────────────────
	// The server handles ONE connection at a time (see the accept loop), so
	// every check below and the append that follows are a single indivisible
	// step: two agents racing a claim serialise, and the loser sees the
	// winner's state. Going multithreaded VOIDS this correctness for free —
	// it would need real locking around check-then-append, not just here.
	now := time.time_to_unix(time.now())

	switch ev.action {
	case "add", "draft":
		if ev.text == "" {
			send_response(client, "400 Bad Request", "application/json", `{"error":"'text' is required"}`)
			return
		}
		ev.id = board.next_task_id
	case "ready", "amend", "claim", "renew", "release", "submit", "approve",
	     "rework", "block", "unblock", "supersede", "note", "done", "reopen":
		t := task_find(ev.id)
		if t == nil {
			send_response(client, "404 Not Found", "application/json",
				fmt.tprintf(`{{"error":"no task with id %d"}}`, ev.id))
			return
		}
		// Stale-revision guard: acting on an old description is refused, so a
		// superseded contract can never be executed by mistake. rev 0 means
		// "not checking" — legacy clients keep working.
		if ev.rev != 0 && ev.rev != t.rev {
			send_response(client, "409 Conflict", "application/json",
				fmt.tprintf(`{{"error":"stale revision","rev":%d,"state":"%s","owner":"%s"}}`,
					t.rev, task_effective_state(t, now), t.owner))
			return
		}
		eff := task_effective_state(t, now)
		switch ev.action {
		case "claim":
			// Conditional claim. A Doing task is claimable ONLY when its lease
			// is provably expired, and then the takeover is recorded with the
			// prior owner — so the log documents every Doing->Doing hop and an
			// ambiguous one cannot exist.
			if eff != "Ready" {
				send_response(client, "409 Conflict", "application/json",
					fmt.tprintf(`{{"error":"not claimable","state":"%s","owner":"%s","rev":%d}}`,
						eff, t.owner, t.rev))
				return
			}
			if t.state == "Doing" do ev.expired_from = t.owner
		case "renew", "release", "submit":
			if t.owner != ev.agent {
				send_response(client, "409 Conflict", "application/json",
					fmt.tprintf(`{{"error":"not the owner","owner":"%s","state":"%s"}}`, t.owner, eff))
				return
			}
			if ev.action != "renew" && eff != "Doing" {
				send_response(client, "409 Conflict", "application/json",
					fmt.tprintf(`{{"error":"not in progress","state":"%s"}}`, eff))
				return
			}
			// result_seq is the audit link from a task to the evidence it was
			// done, and it was accepted unvalidated: a submit once pointed at
			// another agent's message about another task and nothing
			// complained. It must exist and belong to the submitter.
			// Deliberately NOT requiring task_id — legacy reports predate it.
			if ev.action == "submit" && ev.result_seq != 0 {
				found, ok := message_by_seq(ev.result_seq)
				if !ok {
					send_response(client, "400 Bad Request", "application/json",
						fmt.tprintf(`{{"error":"result_seq %d does not exist"}}`, ev.result_seq))
					return
				}
				if found.agent != ev.agent {
					send_response(client, "400 Bad Request", "application/json",
						fmt.tprintf(`{{"error":"result_seq %d belongs to %s, not you"}}`,
							ev.result_seq, found.agent))
					return
				}
			}
		case "block":
			// The panel DRAWS this edge, so a dangling one renders as a
			// phantom node and a self-edge as a task waiting on itself —
			// neither is ever what someone meant. A CYCLE is deliberately
			// allowed: two tasks each waiting on the other is a real
			// deadlock, and the whole point of recording the edge is to make
			// that visible rather than to make it unrepresentable.
			if ev.blocked_on != 0 {
				if ev.blocked_on == t.id {
					send_response(client, "400 Bad Request", "application/json",
						`{"error":"a task cannot be blocked on itself"}`)
					return
				}
				if task_find(ev.blocked_on) == nil {
					send_response(client, "404 Not Found", "application/json",
						fmt.tprintf(`{{"error":"blocked_on %d is not a task"}}`, ev.blocked_on))
					return
				}
			}
		case "approve":
			if eff != "Review" {
				send_response(client, "409 Conflict", "application/json",
					fmt.tprintf(`{{"error":"nothing to approve","state":"%s"}}`, eff))
				return
			}
			// No self-review: the human outranks the workflow, nobody else does.
			if t.owner == ev.agent && ev.agent != "glenn" {
				send_response(client, "409 Conflict", "application/json",
					`{"error":"the owner cannot approve their own work"}`)
				return
			}
		case "done":
			// A v3 contract carries acceptance criteria, so it goes through
			// review. Legacy-born tasks keep force-Done, which is safe because
			// nothing silently STRENGTHENS under an old client.
			if t.origin == "v3" && ev.agent != "glenn" {
				send_response(client, "409 Conflict", "application/json",
					`{"error":"v3 tasks complete via submit + approve (glenn may override)"}`)
				return
			}
		}
	case:
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"unknown action"}`)
		return
	}

	task_post(ev)
	// Hangs off every mutation so a long-running board still keeps its live
	// log tidy; it costs nothing until something is actually eligible.
	task_archive_sweep()
	if t := task_find(ev.id); t != nil {
		send_response(client, "200 OK", "application/json",
			fmt.tprintf(`{{"ok":true,"id":%d,"rev":%d,"state":"%s"}}`,
				ev.id, t.rev, task_effective_state(t, now)))
		return
	}
	send_response(client, "200 OK", "application/json",
		fmt.tprintf(`{{"ok":true,"id":%d}}`, ev.id))
}

// Close a board-spawned agent's herdr tab (glenn seq 226 - the roster's per-
// agent close button). The name resolves against the sidecar's latest fleet
// snapshot, so only agents herdr lists by name (board-spawned ones) can be
// closed; glenn's own unnamed sessions never match. The tab id is charset-
// checked before use.
handle_kill :: proc(client: net.TCP_Socket, body: []u8) {
	Kill_Request :: struct {
		name: string `json:"name"`,
	}
	req: Kill_Request
	if err := json.unmarshal(body, &req, allocator = context.temp_allocator); err != nil || strings.trim_space(req.name) == "" {
		send_response(client, "400 Bad Request", "application/json", `{"error":"'name' is required"}`)
		return
	}
	name := strings.trim_space(req.name)

	Herdr_Row :: struct {
		name: string `json:"name"`,
		tab:  string `json:"tab"`,
	}
	rows: []Herdr_Row
	if board.herdr_state == "" ||
	   json.unmarshal(transmute([]u8)board.herdr_state, &rows, allocator = context.temp_allocator) != nil {
		send_response(client, "500 Internal Server Error", "application/json",
			`{"error":"no herdr fleet snapshot - is herdr_sync.py running?"}`)
		return
	}
	tab := ""
	for r in rows do if r.name == name { tab = r.tab; break }
	if tab == "" {
		send_response(client, "404 Not Found", "application/json",
			fmt.tprintf(`{{"error":"herdr knows no spawned agent named %s"}}`, name))
		return
	}
	for ch in tab do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == ':') {
		send_response(client, "400 Bad Request", "application/json", `{"error":"bad tab id"}`)
		return
	}

	libc.system(strings.clone_to_cstring(fmt.tprintf("herdr tab close %s", tab), context.temp_allocator))
	board_post(Message{
		agent = "board",
		kind  = "msg",
		text  = strings.clone(fmt.tprintf("closed %s (herdr tab %s) from the board UI", name, tab)),
	})
	send_response(client, "200 OK", "application/json", `{"ok":true}`)
}

// ------------------------------------------------------------- agent spawning
//
// The task text never touches a command line: it is written to a prompt file
// and the terminal gets a fixed instruction pointing at that file. The only
// request-derived text in the command is the topic, sanitized to [a-z0-9-].

SPAWN_DIR :: "spawn_prompts"
ROLES_DIR :: "roles"

sanitize_topic :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for ch in s {
		switch ch {
		case 'a' ..= 'z', '0' ..= '9', '-':
			strings.write_rune(&b, ch)
		case 'A' ..= 'Z':
			strings.write_rune(&b, ch + 32)
		case ' ', '_':
			strings.write_rune(&b, '-')
		}
	}
	out := strings.to_string(b)
	if len(out) > 24 do out = out[:24]
	return out
}

handle_spawn :: proc(client: net.TCP_Socket, body: []u8) {
	Spawn_Request :: struct {
		name:   string `json:"name"`,
		prompt: string `json:"prompt"`,
		model:  string `json:"model"`, // "" = default; else allowlisted below
		role:   string `json:"role"`,  // "" = no role; else roles/<role>.md
	}
	req: Spawn_Request
	if err := json.unmarshal(body, &req, allocator = context.temp_allocator); err != nil {
		send_response(client, "400 Bad Request", "application/json",
			fmt.tprintf(`{{"error":"bad json: %v"}}`, err))
		return
	}
	prompt := strings.trim_space(req.prompt)
	if prompt == "" {
		send_response(client, "400 Bad Request", "application/json",
			`{"error":"'prompt' is required"}`)
		return
	}

	topic := sanitize_topic(req.name)
	topic = strings.trim_prefix(topic, "claude-") // typing the prefix must not double it
	if topic == "" do topic = "worker"
	// Unique suffix so repeat topics never collide on the board (glenn seq 163).
	tag := (u32(time.time_to_unix(time.now())) * 2654435761 + u32(board.next_seq)) & 0xFFFF
	agent := fmt.tprintf("claude-%s-%04x", topic, tag)

	wd, wd_err := os.get_working_directory(context.temp_allocator)
	if wd_err != nil {
		send_response(client, "500 Internal Server Error", "application/json",
			`{"error":"cannot resolve working directory"}`)
		return
	}
	// Role system prompt (glenn seq 368).  An APPENDED system prompt holds for
	// every turn of the session; the instruction below is only turn 1 and
	// scrolls away, which is not what "so all agents know their responsibility"
	// means.  sanitize_topic already strips everything outside [a-z0-9-], so a
	// role name can never carry dots or slashes back out of roles/.  Resolved
	// to an ABSOLUTE path because the pane's cwd is the game directory, not
	// this one — a relative path would launch the agent role-less and look
	// like success.  Validated here, before any prompt file is written, so a
	// bad role leaves no artifacts behind.
	role_file := ""
	if want := sanitize_topic(req.role); want != "" {
		role_file, _ = filepath.join({wd, ROLES_DIR, fmt.tprintf("%s.md", want)},
			context.temp_allocator)
		if !os.exists(role_file) {
			send_response(client, "400 Bad Request", "application/json",
				fmt.tprintf(`{{"error":"no role file for '%s'"}}`, want))
			return
		}
	}

	os.make_directory(SPAWN_DIR)
	prompt_path, _ := filepath.join({wd, SPAWN_DIR,
		fmt.tprintf("%s_%d.txt", topic, time.time_to_unix(time.now()))}, context.temp_allocator)
	if werr := os.write_entire_file(prompt_path, transmute([]u8)prompt); werr != nil {
		send_response(client, "500 Internal Server Error", "application/json",
			fmt.tprintf(`{{"error":"cannot write prompt file: %v"}}`, werr))
		return
	}

	work_dir, _ := filepath.join({filepath.dir(wd), "Gnipahellir3"}, context.temp_allocator)
	instruction := fmt.tprintf(
		"You are agent %s, spawned from the message board. Your task from Glenn is in the file %s - read it now and carry it out. Follow the full board protocol in CLAUDE.md as %s, including its monitor step.",
		agent, prompt_path, agent)
	// Model routing (glenn seq 180): cheap models for routine work. Strict
	// allowlist — the model string goes on the command line. Always explicit:
	// glenn's global claude default is haiku (seq 189), which would otherwise
	// silently apply to every spawn.
	model := "fable"
	switch req.model {
	case "sonnet", "opus", "haiku":
		model = req.model
	}
	// The launcher script herds the agent into a herdr pane (glenn seq 196),
	// falling back to a Windows Terminal tab. Dispatched detached via start /b:
	// herdr's readiness wait must never block this single-threaded server.
	launcher, _ := filepath.join({wd, "spawn_herdr.py"}, context.temp_allocator)
	cmd := fmt.tprintf(`cmd /c start /b "" python "%s" "%s" "%s" %s "%s" "%s"`,
		launcher, agent, work_dir, model, instruction, role_file)
	if rc := libc.system(strings.clone_to_cstring(cmd, context.temp_allocator)); rc != 0 {
		send_response(client, "500 Internal Server Error", "application/json",
			fmt.tprintf(`{{"error":"launcher exited with %d"}}`, rc))
		return
	}

	// The spawner already knows exactly who this is — model from the
	// allowlist, role from the file it just resolved — so the agent starts
	// with an identity instead of having to assert one.
	registry_post(Agent_Record{
		agent = strings.clone(agent),
		model = strings.clone(model),
		role  = strings.clone(sanitize_topic(req.role)),
	})

	board_post(Message{
		agent = "board",
		kind  = "msg",
		text  = strings.clone(fmt.tprintf("spawned %s (herdr pane, model %s) - task: %s", agent,
			model,
			prompt if len(prompt) <= 120 else fmt.tprintf("%s...", prompt[:120]))),
	})

	send_response(client, "200 OK", "application/json",
		fmt.tprintf(`{{"ok":true,"agent":"%s"}}`, agent))
}

handle_claims :: proc(client: net.TCP_Socket) {
	Claim :: struct {
		file:      string `json:"file"`,
		agent:     string `json:"agent"`,
		claimed:   i64    `json:"claimed_unix"`,
		last_seen: i64    `json:"last_seen"`,
	}
	claims := make([dynamic]Claim, context.temp_allocator)
	for info in collect_agents() {
		if !info.active do continue
		for file in info.files {
			append(&claims, Claim{file, info.agent, info.status_unix, info.last_seen})
		}
	}
	out, err := json.marshal(claims[:], {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

handle_delta :: proc(client: net.TCP_Socket, query: string) {
	since := 0
	if v, found := query_param(query, "since"); found {
		if n, ok := strconv.parse_int(v); ok do since = n
	}

	first := len(board.messages)
	for m, i in board.messages {
		if m.seq > since {
			first = i
			break
		}
	}
	fresh := board.messages[first:]

	// ?for=<agent>: only messages addressed to that agent or broadcast,
	// never the agent's own posts. Cursor semantics are unchanged — 'latest'
	// stays global, so filtered and unfiltered polls share one cursor.
	// The poll also refreshes the agent's liveness stamp: the query string
	// is temp-allocated, so the key is cloned once on first sight.
	if name, found := query_param(query, "for"); found && name != "" {
		key := name
		if key not_in board.last_poll do key = strings.clone(name)
		board.last_poll[key] = time.time_to_unix(time.now())
		filtered := make([dynamic]Message, 0, len(fresh), context.temp_allocator)
		for m in fresh {
			if message_is_for(m, name) do append(&filtered, m)
		}
		fresh = filtered[:]
	}

	// ?task=N: everything bound to one work item — the correlation trail for a
	// task, without reading the whole board.
	if v, found := query_param(query, "task"); found {
		if want, ok := strconv.parse_int(v); ok {
			bound := make([dynamic]Message, 0, len(fresh), context.temp_allocator)
			for m in fresh do if m.task_id == want do append(&bound, m)
			fresh = bound[:]
		}
	}

	Delta :: struct {
		latest:   int       `json:"latest"`,
		count:    int       `json:"count"`,
		messages: []Message `json:"messages"`,
	}
	delta := Delta{
		latest   = board.next_seq - 1,
		count    = len(fresh),
		messages = fresh,
	}
	out, err := json.marshal(delta, {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

handle_agents :: proc(client: net.TCP_Socket) {
	infos := collect_agents()
	out, err := json.marshal(infos, {}, context.temp_allocator)
	if err != nil {
		send_response(client, "500 Internal Server Error", "application/json", `{"error":"marshal failed"}`)
		return
	}
	send_response(client, "200 OK", "application/json", string(out))
}

// Find a message by seq, live window FIRST and then the archive.
//
// Every seq lookup used to search only the live window, which is fine until
// the board trims — and then a perfectly valid reference starts reporting
// "does not exist" while the message sits intact in board_archive.jsonl. At
// the rate this board runs that is days away, not someday, so it is fixed
// once here for every caller rather than patched into whichever one notices
// first.
//
// The archive is read from disk only when the live window misses, so the
// common case costs nothing.
message_by_seq :: proc(seq: int, allocator := context.temp_allocator) -> (Message, bool) {
	for &m in board.messages do if m.seq == seq do return m, true

	data, err := os.read_entire_file_from_path(ARCHIVE_FILE, allocator)
	if err != nil do return {}, false
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if len(strings.trim_space(line)) == 0 do continue
		m: Message
		if json.unmarshal(transmute([]u8)strings.clone(line, allocator), &m, allocator = allocator) != nil {
			continue
		}
		if m.seq == seq {
			m.route = resolve_route(m.route, m.to)
			return m, true
		}
	}
	return {}, false
}

// Everything ever trimmed off the live board, oldest first. The archive
// lines are already JSON objects, so the array is stitched without
// re-parsing. Empty array until the first trim happens.
handle_archive :: proc(client: net.TCP_Socket) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	first := true
	if data, err := os.read_entire_file_from_path(ARCHIVE_FILE, context.temp_allocator); err == nil {
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			l := strings.trim_space(line)
			if len(l) == 0 do continue
			if !first do strings.write_string(&b, ",")
			strings.write_string(&b, l)
			first = false
		}
	}
	strings.write_string(&b, "]")
	send_response(client, "200 OK", "application/json", strings.to_string(b))
}

handle_index :: proc(client: net.TCP_Socket) {
	// The frontend: a single dependency-free HTML file next to the exe,
	// read per request so it can be edited without a rebuild. It talks to
	// the JSON endpoints; the text summary below is the fallback.
	if page, err := os.read_entire_file_from_path("index.html", context.temp_allocator); err == nil {
		send_response(client, "200 OK", "text/html; charset=utf-8", string(page))
		return
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "Gnipahellir agent message board — %d messages, latest seq %d", len(board.messages), board.next_seq - 1)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "POST /post            body: {\"agent\":\"name\",\"kind\":\"status|msg|request|reply\",\"text\":\"...\",\"files\":[\"...\"],\"to\":\"agent\",\"reply_to\":seq}")
	fmt.sbprintln(&b, "GET  /delta?since=N   messages with seq > N  (start with since=0, then use 'latest' as your next cursor)")
	fmt.sbprintln(&b, "     &for=agent      only messages addressed to that agent or broadcast (to empty/anyone/all), excluding its own posts")
	fmt.sbprintln(&b, "GET  /agents          last-seen + latest status per agent (active = posted OR polled /delta?for= within 20 min)")
	fmt.sbprintln(&b, "GET  /claims          file -> active claimant; POST answers carry 'warnings' when your files overlap another active agent's")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "recent:")
	start := max(0, len(board.messages) - 20)
	for m in board.messages[start:] {
		addressed := "" if m.to == "" else fmt.tprintf(" -> %s", m.to)
		fmt.sbprintfln(&b, "  #%d [%s] %s%s: %s", m.seq, m.agent, m.kind, addressed, m.text)
	}
	send_response(client, "200 OK", "text/plain; charset=utf-8", strings.to_string(b))
}

// ----------------------------------------------------------------------------

main :: proc() {
	port := DEFAULT_PORT
	if len(os.args) > 1 {
		if n, ok := strconv.parse_int(os.args[1]); ok do port = n
	}

	board_load()

	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil {
		fmt.eprintfln("cannot listen on 127.0.0.1:%d: %v", port, err)
		os.exit(1)
	}
	fmt.printfln("gnipahellir message board on http://127.0.0.1:%d  (%d messages loaded from %s)", port, len(board.messages), LOG_FILE)

	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			fmt.eprintfln("accept failed: %v", accept_err)
			continue
		}
		handle_connection(client)
	}
}
