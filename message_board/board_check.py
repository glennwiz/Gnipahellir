"""Behaviour checks for the board's workflow-v3 task and message model.

Runs against a THROWAWAY board on its own port with its own log files, so it
never touches the live board's history. Start nothing yourself:

    python board_check.py            # build + run everything
    python board_check.py -k claim   # only checks whose name contains "claim"

Every check is a real HTTP round trip against a real server process, because
the thing under test IS the request path: the 409s are only correct because
the accept loop is single-threaded, and that cannot be tested in isolation.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

PORT = 7677
BASE = f"http://127.0.0.1:{PORT}"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

checks = []
def check(fn):
    checks.append(fn)
    return fn


# ── plumbing ────────────────────────────────────────────────────────────────

def call(path, body=None, method=None):
    """Return (status, parsed-json). A 4xx/5xx is data here, not an exception:
    half these checks are asserting the REFUSAL."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method=method or ("POST" if data else "GET"))
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw}


def post(agent, **kw):
    body = {"agent": agent}
    body.update(kw)
    return call("/post", body)


def task(action, agent, **kw):
    body = {"action": action, "agent": agent}
    body.update(kw)
    return call("/task", body)


def tasks():
    return {t["id"]: t for t in call("/tasks")[1]}


class Board:
    """A board process on a scratch directory. Restartable, so replay-equivalence
    is checkable rather than assumed."""

    def __init__(self, exe, workdir):
        self.exe, self.workdir, self.proc = exe, workdir, None

    def start(self):
        self.proc = subprocess.Popen([self.exe, str(PORT)], cwd=self.workdir,
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        for _ in range(60):
            time.sleep(0.1)
            try:
                call("/agents")
                return
            except Exception:
                pass
        raise SystemExit(f"board did not come up on {BASE}")

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None

    def restart(self):
        self.stop()
        time.sleep(0.3)
        self.start()


# ── checks: task lifecycle + conditional claims ─────────────────────────────

@check
def draft_ready_claim_submit_approve_is_the_v3_path(b):
    _, r = task("draft", "planner", text="ship the thing",
                files=["a.odin"], accept="tests green", plan_id=42, plan_seq=42)
    tid = r["id"]
    assert tasks()[tid]["state"] == "Draft", tasks()[tid]
    task("ready", "planner", id=tid)
    assert tasks()[tid]["state"] == "Ready"

    st, r = task("claim", "worker", id=tid)
    assert st == 200 and tasks()[tid]["state"] == "Doing"
    assert tasks()[tid]["owner"] == "worker"
    assert tasks()[tid]["attempts"] == 1
    assert tasks()[tid]["lease_until"] > time.time()

    # result_seq must point at a real message the submitter actually wrote -
    # this used to pass a made-up 99, which the #23 validation now refuses.
    _, report = post("worker", text="completion write-up", task_id=tid)
    task("submit", "worker", id=tid, result_seq=report["seq"])
    assert tasks()[tid]["state"] == "Review"
    assert tasks()[tid]["result_seq"] == report["seq"]

    st, _ = task("approve", "reviewer", id=tid)
    assert st == 200
    t = tasks()[tid]
    assert t["state"] == "Done" and t["reviewer"] == "reviewer"
    assert t["status"] == "done", "legacy view must agree with the lifecycle"


@check
def a_second_claim_409s_and_names_the_holder(b):
    _, r = task("add", "planner", text="contested")
    tid = r["id"]
    st, _ = task("claim", "first", id=tid)
    assert st == 200
    st, err = task("claim", "second", id=tid)
    assert st == 409, (st, err)
    assert err["owner"] == "first", err
    assert tasks()[tid]["owner"] == "first"
    assert tasks()[tid]["attempts"] == 1, "a refused claim must not count as an attempt"


@check
def a_stale_revision_is_refused(b):
    _, r = task("draft", "planner", text="v1")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("amend", "planner", id=tid, rev=1, text="v2 - the real contract")

    st, err = task("claim", "worker", id=tid, rev=1)
    assert st == 409 and err["error"] == "stale revision", (st, err)
    assert err["rev"] == 2
    st, _ = task("claim", "worker", id=tid, rev=2)
    assert st == 200
    assert tasks()[tid]["text"] == "v2 - the real contract", \
        "the body must BE the amendment, not the original"


@check
def only_the_owner_may_renew_release_or_submit(b):
    _, r = task("add", "planner", text="owned")
    tid = r["id"]
    task("claim", "owner", id=tid)
    for action in ("renew", "release", "submit"):
        st, err = task(action, "impostor", id=tid)
        assert st == 409 and err["error"] == "not the owner", (action, st, err)
    assert task("release", "owner", id=tid)[0] == 200
    assert tasks()[tid]["state"] == "Ready" and tasks()[tid]["owner"] == ""


@check
def an_expired_lease_is_claimable_and_the_takeover_is_recorded(b):
    _, r = task("add", "planner", text="abandoned")
    tid = r["id"]
    task("claim", "ghost", id=tid, lease_secs=1)
    assert tasks()[tid]["state"] == "Doing"
    time.sleep(2)
    # Derived expiry: nothing was written, but the task now READS as Ready.
    assert tasks()[tid]["state"] == "Ready", "an expired lease serves as Ready"

    st, _ = task("claim", "rescuer", id=tid)
    assert st == 200
    t = tasks()[tid]
    assert t["owner"] == "rescuer" and t["attempts"] == 2

    # ...and the log self-documents the Doing->Doing hop.
    log = os.path.join(b.workdir, "tasks.jsonl")
    events = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
    takeover = [e for e in events
                if e.get("id") == tid and e.get("action") == "claim"
                and e.get("expired_from")]
    assert takeover and takeover[0]["expired_from"] == "ghost", events[-3:]


@check
def renewing_keeps_a_lease_alive(b):
    _, r = task("add", "planner", text="long job")
    tid = r["id"]
    task("claim", "worker", id=tid, lease_secs=2)
    time.sleep(1)
    assert task("renew", "worker", id=tid, lease_secs=60)[0] == 200
    time.sleep(1.5)
    assert tasks()[tid]["state"] == "Doing", "renew should have moved the deadline"
    st, err = task("claim", "thief", id=tid)
    assert st == 409, (st, err)


@check
def a_v3_task_cannot_be_force_done_but_glenn_may(b):
    _, r = task("draft", "planner", text="needs review")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    st, err = task("done", "worker", id=tid)
    assert st == 409, (st, err)
    assert tasks()[tid]["state"] == "Doing"
    assert task("done", "glenn", id=tid)[0] == 200, "the human outranks the workflow"
    assert tasks()[tid]["state"] == "Done"


@check
def the_owner_cannot_approve_their_own_work(b):
    _, r = task("draft", "planner", text="self review")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    task("submit", "worker", id=tid)
    st, err = task("approve", "worker", id=tid)
    assert st == 409, (st, err)
    assert task("approve", "someone-else", id=tid)[0] == 200


@check
def block_remembers_where_it_came_from(b):
    _, r = task("add", "planner", text="blocked work")
    tid = r["id"]
    task("claim", "worker", id=tid)
    task("block", "worker", id=tid, text="waiting on glenn")
    assert tasks()[tid]["state"] == "Blocked"
    task("unblock", "worker", id=tid)
    assert tasks()[tid]["state"] == "Doing", "unblock returns to the prior state"


@check
def legacy_actions_still_work_untouched(b):
    _, r = task("add", "old-client", text="legacy task")
    tid = r["id"]
    assert tasks()[tid]["state"] == "Ready" and tasks()[tid]["status"] == "open"
    assert task("claim", "old-client", id=tid)[0] == 200
    assert tasks()[tid]["status"] == "doing"
    assert task("done", "old-client", id=tid)[0] == 200
    assert tasks()[tid]["status"] == "done" and tasks()[tid]["state"] == "Done"
    assert task("reopen", "old-client", id=tid)[0] == 200
    assert tasks()[tid]["status"] == "open"


# ── checks: message routing ─────────────────────────────────────────────────

@check
def routing_is_resolved_and_stored_for_old_clients(b):
    post("a", text="to nobody")
    post("a", text="to someone", to="b")
    post("a", text="to whoever", to="anyone")
    _, d = call("/delta?since=0")
    got = {m["text"]: m["route"] for m in d["messages"] if m["agent"] == "a"}
    assert got["to nobody"] == "broadcast", got
    assert got["to someone"] == "direct", got
    assert got["to whoever"] == "anyone", got


@check
def an_anyone_request_can_only_be_taken_once(b):
    _, r = post("asker", kind="request", to="anyone", text="who wants this")
    seq = r["seq"]
    st, _ = post("first", text="taking it", accepts=seq)
    assert st == 200
    st, err = post("second", text="also taking it", accepts=seq)
    assert st == 409, (st, err)
    assert err["accepted_by"] == "first", err


@check
def only_an_anyone_request_can_be_accepted(b):
    _, r = post("asker", kind="request", to="somebody", text="direct ask")
    st, err = post("other", text="me!", accepts=r["seq"])
    assert st == 400, (st, err)


@check
def release_clears_claims_where_a_reply_never_did(b):
    post("holder", kind="status", text="working", files=["shared.odin"])
    claims = {c["file"]: c["agent"] for c in call("/claims")[1]}
    assert claims.get("shared.odin") == "holder", claims

    # The old trap: a non-status post with files=[] looks like a release.
    post("holder", kind="reply", text="done here", files=[])
    claims = {c["file"]: c["agent"] for c in call("/claims")[1]}
    assert claims.get("shared.odin") == "holder", \
        "a reply must NOT silently release - that was the bug"

    post("holder", kind="release", text="releasing")
    claims = {c["file"]: c["agent"] for c in call("/claims")[1]}
    assert "shared.odin" not in claims, claims


@check
def posts_can_be_bound_to_a_task_and_filtered(b):
    _, r = task("add", "planner", text="correlated")
    tid = r["id"]
    post("worker", text="unrelated chatter")
    post("worker", text="progress on the task", task_id=tid)
    _, d = call(f"/delta?since=0&task={tid}")
    texts = [m["text"] for m in d["messages"]]
    assert texts == ["progress on the task"], texts


# ── checks: durability ──────────────────────────────────────────────────────

@check
def routes_are_resolved_for_messages_written_before_routing_existed(b):
    # Every message on the live board predates the route field. Replay must
    # fill it in, or the UI and every reader would have to re-derive intent
    # from `to` themselves.
    b.stop()
    log = os.path.join(b.workdir, "board.jsonl")
    with open(log, "a", encoding="utf-8") as f:
        for i, to in enumerate(["", "someone", "anyone"]):
            f.write(json.dumps({"seq": 9000 + i, "unix": int(time.time()),
                                "agent": "ancient", "kind": "msg",
                                "text": f"old-{i}", "to": to}) + "\n")
    b.start()
    _, d = call("/delta?since=8999")
    got = {m["text"]: m["route"] for m in d["messages"]}
    assert got == {"old-0": "broadcast", "old-1": "direct", "old-2": "anyone"}, got


@check
def state_survives_a_restart_by_pure_replay(b):
    _, r = task("draft", "planner", text="durable", accept="must survive")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("amend", "planner", id=tid, rev=1, text="durable v2")
    task("claim", "worker", id=tid, lease_secs=600)
    task("note", "onlooker", id=tid, text="reading this one too")
    before = tasks()[tid]

    b.restart()

    after = tasks()[tid]
    for field in ("state", "rev", "owner", "text", "accept", "attempts",
                  "lease_until", "notes", "origin"):
        assert before[field] == after[field], (field, before[field], after[field])


@check
def a_torn_final_line_is_tolerated(b):
    _, r = task("add", "planner", text="before the crash")
    tid = r["id"]
    b.stop()
    log = os.path.join(b.workdir, "tasks.jsonl")
    with open(log, "a", encoding="utf-8") as f:
        f.write('{"action":"claim","id":')   # power cut mid-append
    b.start()
    assert tasks()[tid]["state"] == "Ready", "a torn tail must not lose the log"
    # ...and the board is still writable afterwards.
    assert task("claim", "worker", id=tid)[0] == 200


@check
def a_held_lease_keeps_file_claims_alive(b):
    # The two windows must not disagree: a quiet agent holding a lease is not
    # stale, or its files would silently stop conflicting mid-edit.
    _, r = task("add", "planner", text="long edit")
    tid = r["id"]
    post("quiet", kind="status", text="editing", files=["contested.odin"])
    task("claim", "quiet", id=tid, lease_secs=3600)
    agents = {a["agent"]: a for a in call("/agents")[1]}
    assert agents["quiet"]["active"], "a lease holder is alive by definition"


# ── checks: agent registry (task #21) ───────────────────────────────────────

@check
def registering_gives_an_agent_a_durable_identity(b):
    st, r = call("/register", {"agent": "worker-1", "role": "implementer",
                               "model": "opus", "capabilities": ["odin", "git"]})
    assert st == 200 and r["agent"] == "worker-1", (st, r)
    a = {x["agent"]: x for x in call("/agents")[1]}["worker-1"]
    assert a["role"] == "implementer" and a["model"] == "opus"
    assert a["capabilities"] == ["odin", "git"], a


@check
def a_registered_agent_is_listed_before_it_ever_speaks(b):
    call("/register", {"agent": "silent-one", "role": "reviewer", "model": "sonnet"})
    names = [x["agent"] for x in call("/agents")[1]]
    assert "silent-one" in names, names
    # Identity is durable; presence is not. It is listed, but not active.
    a = {x["agent"]: x for x in call("/agents")[1]}["silent-one"]
    assert not a["active"], "never having spoken is not liveness"


@check
def re_registering_is_latest_wins_per_field(b):
    call("/register", {"agent": "shifty", "role": "planner", "model": "fable"})
    call("/register", {"agent": "shifty", "role": "implementer", "model": "opus",
                       "capabilities": ["odin"]})
    a = {x["agent"]: x for x in call("/agents")[1]}["shifty"]
    assert a["role"] == "implementer" and a["model"] == "opus", a
    assert a["capabilities"] == ["odin"], a


@check
def a_partial_register_never_blanks_what_is_already_known(b):
    # The designed collision: /spawn knows {model, role} and nothing else; the
    # agent itself knows its capabilities and nothing else. Whole-record
    # overwrite made the second call erase the first's work.
    call("/register", {"agent": "spawned", "role": "implementer", "model": "opus"})
    call("/register", {"agent": "spawned", "capabilities": ["odin", "git"]})
    a = {x["agent"]: x for x in call("/agents")[1]}["spawned"]
    assert a["role"] == "implementer", f"role was blanked by a partial register: {a}"
    assert a["model"] == "opus", f"model was blanked by a partial register: {a}"
    assert a["capabilities"] == ["odin", "git"], a

    # ...and it holds across a restart, since the fold is what replay uses.
    b.restart()
    a = {x["agent"]: x for x in call("/agents")[1]}["spawned"]
    assert (a["role"], a["model"], a["capabilities"]) == ("implementer", "opus", ["odin", "git"]), a


@check
def the_registry_survives_a_restart_by_replay(b):
    call("/register", {"agent": "durable", "role": "verifier", "model": "haiku",
                       "capabilities": ["build", "test"]})
    call("/register", {"agent": "durable", "role": "verifier", "model": "haiku",
                       "capabilities": ["build", "test", "grep"]})
    before = {x["agent"]: x for x in call("/agents")[1]}["durable"]
    b.restart()
    after = {x["agent"]: x for x in call("/agents")[1]}["durable"]
    for f in ("role", "model", "capabilities"):
        assert before[f] == after[f], (f, before[f], after[f])
    assert after["capabilities"] == ["build", "test", "grep"], "latest-wins must survive replay"


@check
def registration_requires_an_agent_name(b):
    st, err = call("/register", {"role": "nobody"})
    assert st == 400, (st, err)


@check
def registry_fields_are_absent_not_wrong_for_unregistered_agents(b):
    # Every agent that predates the registry must read exactly as before.
    post("old-timer", kind="status", text="been here for ages")
    a = {x["agent"]: x for x in call("/agents")[1]}["old-timer"]
    assert a["role"] == "" and a["model"] == "" and a["status"] == "been here for ages"
    assert a["active"], "message traffic still drives liveness"


@check
def a_refused_spawn_registers_nobody(b):
    # /spawn auto-registers, but only AFTER the launcher actually starts - a
    # rejected request must leave no identity behind. Testing the refusal path
    # is safe; the success path would launch a real agent, so it is verified by
    # placement (registry_post sits after the launcher's error check) and by
    # the live board, not here.
    before = {x["agent"] for x in call("/agents")[1]}
    st, err = call("/spawn", {"name": "ghost", "model": "haiku",
                              "role": "no-such-role", "prompt": "never runs"})
    assert st == 400, (st, err)
    after = {x["agent"] for x in call("/agents")[1]}
    assert before == after, after - before


# ── checks: crash safety + retention (task #18) ─────────────────────────────

@check
def a_corrupt_interior_line_is_skipped_loudly_and_the_rest_survives(b):
    # A crash can only ever damage the LAST line, so damage in the middle means
    # something else wrote to the log. The board must still boot, but the two
    # cases must not be treated alike or real corruption hides forever.
    _, r1 = task("add", "planner", text="first")
    _, r2 = task("add", "planner", text="second")
    b.stop()
    log = os.path.join(b.workdir, "tasks.jsonl")
    lines = open(log, encoding="utf-8").read().splitlines()
    lines.insert(1, '{"action":"claim","id":' )        # corrupt, NOT final
    open(log, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    b.start()
    got = tasks()
    assert r1["id"] in got and r2["id"] in got, got
    assert got[r2["id"]]["text"] == "second"


@check
def terminal_tasks_older_than_the_window_move_to_the_archive(b):
    _, r = task("add", "planner", text="ancient history")
    tid = r["id"]
    task("done", "planner", id=tid)
    b.stop()

    # Backdate the whole task so it falls outside the retention window.
    log = os.path.join(b.workdir, "tasks.jsonl")
    old = int(time.time()) - (8 * 24 * 3600)
    out = []
    for line in open(log, encoding="utf-8"):
        if not line.strip():
            continue
        ev = json.loads(line)
        if ev.get("id") == tid:
            ev["unix"] = old
        out.append(json.dumps(ev))
    open(log, "w", encoding="utf-8").write("\n".join(out) + "\n")
    b.start()   # boot sweep runs here

    # The task is still THERE - archiving moves events, it never loses state.
    assert tid in tasks(), "archived tasks must still exist"
    assert tasks()[tid]["state"] == "Done"

    arch = os.path.join(b.workdir, "tasks_archive.jsonl")
    assert os.path.exists(arch), "the archive should have been created"
    archived_ids = {json.loads(l)["id"] for l in open(arch, encoding="utf-8") if l.strip()}
    assert tid in archived_ids, archived_ids
    live_ids = {json.loads(l).get("id") for l in open(log, encoding="utf-8") if l.strip()}
    assert tid not in live_ids, "the live log should no longer carry it"


@check
def a_crash_between_archive_and_rewrite_loses_nothing(b):
    # The dangerous window: events appended to the archive, live log NOT yet
    # rewritten, so they exist twice. Replay must dedupe rather than double-apply.
    _, r = task("add", "planner", text="duplicated by a crash")
    tid = r["id"]
    task("claim", "worker", id=tid)
    b.stop()

    log = os.path.join(b.workdir, "tasks.jsonl")
    arch = os.path.join(b.workdir, "tasks_archive.jsonl")
    lines = [l for l in open(log, encoding="utf-8") if l.strip()]
    mine = [l for l in lines if json.loads(l).get("id") == tid]
    with open(arch, "a", encoding="utf-8") as f:     # archived...
        f.writelines(mine)
    # ...and the live log still has them: exactly the crash-between state.
    b.start()

    assert len([t for t in call("/tasks")[1] if t["id"] == tid]) == 1, \
        "the same event in both logs must not create the task twice"
    assert tasks()[tid]["owner"] == "worker"
    assert tasks()[tid]["attempts"] == 1, "a re-applied claim would double the attempts"


@check
def archived_history_still_replays_after_a_restart(b):
    _, r = task("add", "planner", text="survives archiving")
    tid = r["id"]
    task("done", "planner", id=tid)
    b.stop()
    log = os.path.join(b.workdir, "tasks.jsonl")
    old = int(time.time()) - (30 * 24 * 3600)
    out = []
    for line in open(log, encoding="utf-8"):
        if line.strip():
            ev = json.loads(line)
            if ev.get("id") == tid:
                ev["unix"] = old
            out.append(json.dumps(ev))
    open(log, "w", encoding="utf-8").write("\n".join(out) + "\n")
    b.start()          # sweep moves it out
    before = tasks()[tid]
    b.restart()        # and it must come back from the archive alone
    assert tasks()[tid] == before, (before, tasks()[tid])


# ── checks: plan refs + result_seq validation (task #23) ────────────────────

@check
def a_draft_derives_plan_id_and_rev_from_plan_seq_alone(b):
    # The contract has callers send plan_seq only. The first live v3 task came
    # out with plan_id 0 / plan_rev 0 / plan_seqs [0] while its own log line
    # held 600 - the event was right, the projection was wrong.
    _, r = task("draft", "planner", text="planned work", plan_seq=600)
    t = tasks()[r["id"]]
    assert t["plan_id"] == 600, t
    assert t["plan_rev"] == 1, t
    assert t["plan_seqs"] == [600], t   # literal, not merely non-empty


@check
def plan_seqs_survive_the_request_that_created_them(b):
    # The backing store used to die with the request, so this read [0] every
    # time - deterministically, which is why no restart could mask it. Create
    # several tasks to disturb memory, then re-read them all.
    ids = []
    for i in range(5):
        _, r = task("draft", "planner", text=f"plan {i}", plan_seq=700 + i)
        ids.append((r["id"], 700 + i))
    got = tasks()
    for tid, seq in ids:
        assert got[tid]["plan_seqs"] == [seq], (tid, got[tid]["plan_seqs"], seq)


@check
def amending_appends_to_the_plan_trail_and_it_survives_restart(b):
    _, r = task("draft", "planner", text="v1", plan_seq=800)
    tid = r["id"]
    task("amend", "planner", id=tid, rev=1, text="v2", plan_seq=801)
    t = tasks()[tid]
    assert t["plan_seqs"] == [800, 801], t
    assert t["plan_rev"] == 2, f"a new plan post is a new plan revision: {t}"

    b.restart()   # concrete values, not just equivalence - [0]==[0] would pass
    t = tasks()[tid]
    assert t["plan_seqs"] == [800, 801], t
    assert t["plan_id"] == 800 and t["plan_rev"] == 2, t
    assert t["text"] == "v2", t


@check
def submit_refuses_a_result_seq_that_does_not_exist(b):
    _, r = task("add", "planner", text="needs evidence")
    tid = r["id"]
    task("claim", "worker", id=tid)
    st, err = task("submit", "worker", id=tid, result_seq=999999)
    assert st == 400 and "does not exist" in err["error"], (st, err)
    assert tasks()[tid]["state"] == "Doing", "a refused submit must not advance the task"


@check
def submit_refuses_someone_elses_message_as_evidence(b):
    # The real incident: a submit pointed at another agent's message about
    # another task, and the server accepted it silently.
    _, other = post("bystander", text="unrelated chatter")
    _, r = task("add", "planner", text="needs evidence")
    tid = r["id"]
    task("claim", "worker", id=tid)
    st, err = task("submit", "worker", id=tid, result_seq=other["seq"])
    assert st == 400 and "belongs to bystander" in err["error"], (st, err)

    # ...and the owner's own report is accepted.
    _, mine = post("worker", text="here is what I did", task_id=tid)
    st, _ = task("submit", "worker", id=tid, result_seq=mine["seq"])
    assert st == 200
    assert tasks()[tid]["result_seq"] == mine["seq"]


@check
def submit_without_a_result_seq_still_works_for_legacy_callers(b):
    _, r = task("add", "planner", text="no evidence ref")
    tid = r["id"]
    task("claim", "worker", id=tid)
    st, _ = task("submit", "worker", id=tid)
    assert st == 200, "omitting result_seq must stay legal"
    assert tasks()[tid]["state"] == "Review"


# ── checks: the runtime-file ignore rule (task #22) ─────────────────────────

# Every runtime file the service writes, DERIVED FROM main.odin — matched on
# the constant's VALUE, never its name.
#
# There is deliberately no hand-maintained copy of this list. The first version
# had one, and that second source of truth is exactly what hid the bug: the
# derivation matched `^[A-Z_]*FILE`, missed ACCESS_LOG entirely, and the check
# still passed because the Python list happened to contain access.log anyway.
# It was green for the wrong reason. One source, or none.
RUNTIME_MIN = 6   # floor: a regex that silently stops matching must not pass
DECLARED_RE = re.compile(
    r'^[A-Z_][A-Z_0-9]*\s*::\s*(?:#config\([^,]+,\s*)?"([^"]+\.(?:jsonl|log|json|dat))"',
    re.M)


def runtime_files(src=None):
    if src is None:
        src = open(os.path.join(HERE, "main.odin"), encoding="utf-8").read()
    return set(DECLARED_RE.findall(src))


@check
def every_runtime_file_the_source_declares_is_gitignored(b):
    # Fixing the missing rules fixed instances; this fixes the pattern. The
    # hole was found three times today — tasks.jsonl (a73cfb7), then
    # agents.jsonl + tasks_archive.jsonl (#18 review), then this check's own
    # name-shaped regex (#22 review) — because it kept relying on someone
    # remembering. Now it cannot be forgotten.
    declared = runtime_files()
    assert len(declared) >= RUNTIME_MIN, (
        f"only found {sorted(declared)} - the scan has drifted from main.odin, "
        "and a scan that finds nothing must never pass")
    missing = []
    for name in sorted(declared):
        r = subprocess.run(["git", "check-ignore", "-q",
                            os.path.join("message_board", name)],
                           cwd=ROOT, capture_output=True)
        if r.returncode != 0:
            missing.append(name)
    assert not missing, (
        f"main.odin writes {missing} but message_board/.gitignore does not "
        "cover them - add a rule, or they land in the next commit")


@check
def the_declaration_scan_actually_catches_a_new_runtime_file(b):
    # A derivation is only worth having if it can FAIL and say so. Sonnet
    # proved the old one could not — a fake constant sailed straight past it.
    # These run against a COPY of the source; nothing real is modified.
    src = open(os.path.join(HERE, "main.odin"), encoding="utf-8").read()
    base = runtime_files(src)
    assert "access.log" in base, "ACCESS_LOG must be visible - that was the reworked bug"

    # Deliberately hostile names: none of them end in FILE, which is precisely
    # what the first version keyed on.
    for fake in ('SESSIONS_LOG :: "sessions.jsonl"',
                 'AUDIT :: "audit.log"',
                 'SNAPSHOT :: "state.dat"',
                 'CONF :: "settings.json"',
                 'X :: #config(X, "tuned.jsonl")'):
        added = runtime_files(src + "\n" + fake) - base
        assert added, f"a new runtime constant escaped the scan: {fake}"


# ── runner ──────────────────────────────────────────────────────────────────

def main():
    pattern = None
    if "-k" in sys.argv:
        pattern = sys.argv[sys.argv.index("-k") + 1]

    exe = os.path.join(tempfile.mkdtemp(prefix="boardchk_"), "board_check.exe")
    build = subprocess.run(["odin", "build", "message_board", "-out:" + exe],
                           cwd=ROOT, capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stdout + build.stderr)
        raise SystemExit("build failed")

    selected = [c for c in checks if not pattern or pattern in c.__name__]
    failed = []
    for c in selected:
        work = tempfile.mkdtemp(prefix="board_")
        shutil.copy(os.path.join(HERE, "index.html"), work)
        b = Board(exe, work)
        b.start()
        try:
            c(b)
            print(f"  ok   {c.__name__}")
        except Exception as e:
            failed.append(c.__name__)
            print(f"  FAIL {c.__name__}: {type(e).__name__}: {e}")
        finally:
            b.stop()
            shutil.rmtree(work, ignore_errors=True)

    print(f"\n{len(selected) - len(failed)}/{len(selected)} checks passed")
    if failed:
        print("failed: " + ", ".join(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
