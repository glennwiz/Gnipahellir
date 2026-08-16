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
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# The suite talks to whichever board is currently running; Board.start()
# rebinds this. It is NOT a fixed port, and that is the whole point - see
# free_port below.
BASE = None
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


def headers_of(path):
    """Response headers, which call() throws away. The build stamp lives in
    one, so it needs its own door."""
    req = urllib.request.Request(BASE + path)
    with urllib.request.urlopen(req, timeout=5) as r:
        return dict(r.headers)


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


def free_port():
    """A port the OS says is free, right now.

    The suite used to hardcode 7677. Two runs on one machine then shared a
    port, and the failure was silent in the worst way: the second bind
    SUCCEEDS, the newer board hijacks the port, the older starves, and
    ownership flips again at every restart leg. The result was a random
    subset of failures on green code, plus connection resets - which reads
    exactly like flaky infrastructure, so it got diagnosed as flaky
    infrastructure. It cost a real review before it was reproduced.

    An instrument that quietly reports failures the code did not cause is
    worse than one that is merely broken, because a broken instrument is
    obvious and this one looked like evidence."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Board:
    """A board process on a scratch directory. Restartable, so replay-equivalence
    is checkable rather than assumed."""

    def __init__(self, exe, workdir):
        self.exe, self.workdir, self.proc = exe, workdir, None
        # One port per board, chosen once so a restart reconnects to the same
        # address, and never shared with another run of this suite.
        self.port = free_port()

    def start(self):
        global BASE
        BASE = f"http://127.0.0.1:{self.port}"
        self.proc = subprocess.Popen([self.exe, str(self.port)], cwd=self.workdir,
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        for _ in range(60):
            time.sleep(0.1)
            # Belt and braces: if our child is already dead, something else is
            # answering on this port and every check after this would be
            # testing a stranger. The ephemeral port is what PREVENTS that;
            # this is what makes it LOUD if it ever happens anyway, because
            # the old failure mode was invisible rather than noisy.
            if self.proc.poll() is not None:
                raise SystemExit(
                    f"board exited immediately (rc={self.proc.returncode}) - "
                    f"port {self.port} may be taken by another process")
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
    _, plan = post("planner", text="the plan for shipping the thing")
    _, r = task("draft", "planner", text="ship the thing", files=["a.odin"],
                accept="tests green", plan_id=plan["seq"], plan_seq=plan["seq"])
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
def a_block_can_name_the_task_it_waits_on(b):
    _, up = task("add", "planner", text="the thing upstream")
    _, dn = task("add", "planner", text="the thing waiting")
    task("claim", "worker", id=dn["id"])
    task("block", "worker", id=dn["id"], blocked_on=up["id"],
         text="needs the upstream lane first")
    t = tasks()[dn["id"]]
    assert t["state"] == "Blocked" and t["blocked_on"] == up["id"], t
    # The edge is the point, so it has to survive the process it outlives.
    b.restart()
    assert tasks()[dn["id"]]["blocked_on"] == up["id"]
    task("unblock", "worker", id=dn["id"])
    assert tasks()[dn["id"]]["blocked_on"] == 0, "unblock clears the edge"


@check
def a_reblock_naming_nobody_clears_a_stale_edge(b):
    _, up = task("add", "planner", text="upstream")
    _, dn = task("add", "planner", text="downstream")
    task("claim", "worker", id=dn["id"])
    task("block", "worker", id=dn["id"], blocked_on=up["id"])
    task("block", "worker", id=dn["id"], text="actually just waiting on glenn")
    assert tasks()[dn["id"]]["blocked_on"] == 0, \
        "blocked_on describes the block in force, not every block ever"


@check
def a_blocked_on_edge_must_point_somewhere_real(b):
    _, r = task("add", "planner", text="downstream")
    tid = r["id"]
    task("claim", "worker", id=tid)
    st, body = task("block", "worker", id=tid, blocked_on=99999)
    assert st == 404, (st, body)
    st, body = task("block", "worker", id=tid, blocked_on=tid)
    assert st == 400 and "itself" in body["error"], (st, body)
    assert tasks()[tid]["state"] == "Doing", "a refused block must not half-apply"


@check
def blocking_is_unchanged_for_callers_that_name_nothing(b):
    # blocked_on is additive: every existing block call must behave exactly
    # as it did, and read back 0 rather than absent.
    _, r = task("add", "planner", text="blocked on the outside world")
    tid = r["id"]
    task("claim", "worker", id=tid)
    assert task("block", "worker", id=tid, text="waiting on glenn")[0] == 200
    t = tasks()[tid]
    assert t["state"] == "Blocked" and t["blocked_on"] == 0, t
    task("unblock", "worker", id=tid)
    assert tasks()[tid]["state"] == "Doing"


# ── checks: every field that names another record ───────────────────────────
#
# Four fields point at another record. Three were unguarded, and each was
# invisible on its own: a reference that can name nothing looks exactly like
# one that cannot, at every call site, until you go looking for the class.


@check
def supersede_refuses_a_by_id_that_names_nothing(b):
    # Same validation as blocked_on, DIFFERENT justification, and the
    # difference is why this one matters more. Supersede is TERMINAL: a
    # by_id naming a phantom task is unrecoverable by any later verb, where
    # a bad blocked_on can be corrected by re-blocking. A guard on a
    # reversible field is a convenience; here it is the only chance anyone
    # gets.
    _, r = task("add", "planner", text="to be replaced")
    tid = r["id"]
    st, body = task("supersede", "planner", id=tid, by_id=99999)
    assert st == 404 and "by_id" in body["error"], (st, body)
    st, body = task("supersede", "planner", id=tid, by_id=tid)
    assert st == 400 and "itself" in body["error"], (st, body)
    assert tasks()[tid]["state"] != "Superseded", \
        "a refused supersede must not half-apply a terminal transition"

    _, r2 = task("add", "planner", text="the replacement")
    assert task("supersede", "planner", id=tid, by_id=r2["id"])[0] == 200
    assert tasks()[tid]["superseded_by"] == r2["id"]


@check
def a_post_cannot_bind_itself_to_a_phantom_task(b):
    # ...and the reason it matters is quiet: /delta?task=N would filter
    # happily on the phantom and return a clean, empty, entirely
    # honest-looking correlation trail for a task nobody ever created.
    st, body = post("worker", text="about task 99999", task_id=99999)
    assert st == 400 and "task_id" in body["error"], (st, body)
    _, r = task("add", "planner", text="real work")
    assert post("worker", text="about real work", task_id=r["id"])[0] == 200


@check
def a_draft_cannot_cite_a_plan_post_that_does_not_exist(b):
    # result_seq's class exactly, but on the INTAKE side - which is why the
    # review that guarded result_seq walked straight past it.
    st, body = task("draft", "planner", text="cites nothing", plan_seq=99999)
    assert st == 400 and "plan_seq" in body["error"], (st, body)
    _, plan = post("planner", text="the actual plan")
    st, r = task("draft", "planner", text="cites the plan", plan_seq=plan["seq"])
    assert st == 200
    tid = r["id"]
    assert tasks()[tid]["plan_id"] == plan["seq"]
    # amend carries the same field and gets the same guard.
    assert task("amend", "planner", id=tid, rev=1, plan_seq=99999)[0] == 400
    assert tasks()[tid]["rev"] == 1, "a refused amend must not bump the revision"


@check
def a_trimmed_away_plan_post_is_still_a_real_plan(b):
    # The guard must not punish longevity: a plan old enough to have been
    # archived is still a plan, so this validates through the archive like
    # every other seq lookup.
    _seed_a_trimmed_board(b, [{"seq": 8500, "unix": int(time.time()),
                               "agent": "planner", "kind": "msg",
                               "text": "a plan from last week"}])
    st, r = task("draft", "planner", text="cites the old plan", plan_seq=8500)
    assert st == 200, (st, r)
    assert tasks()[r["id"]]["plan_id"] == 8500


@check
def cycles_are_still_allowed_because_a_deadlock_is_information(b):
    # The deliberate exception to the whole class. Two tasks each waiting on
    # the other is a REAL deadlock; the point of storing the edge is to make
    # it visible, not to pretend it cannot happen.
    _, a = task("add", "planner", text="A")
    _, c = task("add", "planner", text="B")
    task("claim", "w1", id=a["id"])
    task("claim", "w2", id=c["id"])
    assert task("block", "w1", id=a["id"], blocked_on=c["id"])[0] == 200
    assert task("block", "w2", id=c["id"], blocked_on=a["id"])[0] == 200
    assert tasks()[a["id"]]["blocked_on"] == c["id"]
    assert tasks()[c["id"]]["blocked_on"] == a["id"]


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


def _seed_a_trimmed_board(b, archived):
    """Put the board in the state a trim leaves behind: `archived` messages
    live only in board_archive.jsonl, and the live log starts above them.

    This is the shape the real board reaches in a couple of days, not a
    contrived one — board_trim() appends the oldest messages to the archive
    and rewrites board.jsonl with the newest, and next_seq is derived from
    the live log alone."""
    b.stop()
    with open(os.path.join(b.workdir, "board_archive.jsonl"), "a",
              encoding="utf-8") as f:
        for m in archived:
            f.write(json.dumps(m) + "\n")
    top = max(m["seq"] for m in archived)
    with open(os.path.join(b.workdir, "board.jsonl"), "a",
              encoding="utf-8") as f:
        f.write(json.dumps({"seq": top + 1, "unix": int(time.time()),
                            "agent": "survivor", "kind": "status",
                            "text": "still on the live board"}) + "\n")
    b.start()


@check
def a_trimmed_away_result_seq_still_validates(b):
    # The breakage with a date on it: a submit points at a real report, the
    # board trims that report into the archive, and from then on the board
    # calls a message it is still storing "does not exist".
    _seed_a_trimmed_board(b, [{"seq": 8500, "unix": int(time.time()),
                               "agent": "worker", "kind": "msg",
                               "text": "the report, long since trimmed"}])
    assert call("/delta?since=0")[1]["messages"][0]["seq"] > 8500, \
        "seq 8500 must be off the live window for this check to mean anything"

    _, r = task("draft", "planner", text="cites an archived report",
                accept="must submit")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    st, body = task("submit", "worker", id=tid, rev=tasks()[tid]["rev"],
                    result_seq=8500)
    assert st == 200, (st, body)
    assert tasks()[tid]["result_seq"] == 8500


@check
def ownership_is_still_enforced_on_an_archived_result_seq(b):
    # The fallback must widen WHERE we look, not WHAT we accept. Finding the
    # message in the archive still has to prove it is the submitter's own.
    _seed_a_trimmed_board(b, [{"seq": 8500, "unix": int(time.time()),
                               "agent": "someone-else", "kind": "msg",
                               "text": "not the submitter's report"}])
    _, r = task("draft", "planner", text="cites another agent's report",
                accept="must refuse")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    st, body = task("submit", "worker", id=tid, rev=tasks()[tid]["rev"],
                    result_seq=8500)
    assert st == 400, (st, body)
    assert "someone-else" in body["error"], body


@check
def an_accept_still_resolves_a_trimmed_away_request(b):
    # Same lookup, the other caller. An open `anyone` request that outlives
    # the trim window must still be claimable.
    _seed_a_trimmed_board(b, [{"seq": 8500, "unix": int(time.time()),
                               "agent": "asker", "kind": "request",
                               "to": "anyone", "route": "anyone",
                               "text": "who will take this?"}])
    st, body = post("taker", kind="reply", accepts=8500, text="I will")
    assert st == 200, (st, body)
    # ...and first-wins arbitration still holds across the archive boundary.
    st2, body2 = post("latecomer", kind="reply", accepts=8500, text="me too")
    assert st2 == 409, (st2, body2)
    assert "taker" in json.dumps(body2), body2


@check
def a_seq_that_exists_nowhere_is_still_refused(b):
    # The fallback must not turn "unreadable archive" or "no such message"
    # into a pass. A missing archive file is the common case: no trim yet.
    _, r = task("draft", "planner", text="cites nothing real", accept="refuse")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    st, body = task("submit", "worker", id=tid, rev=tasks()[tid]["rev"],
                    result_seq=8500)
    assert st == 400 and "does not exist" in body["error"], (st, body)
    assert post("taker", kind="reply", accepts=8500, text="?")[0] == 404


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


# ── checks: liveness comes from watching, not only from talking ─────────────

def agent_row(name):
    return {x["agent"]: x for x in call("/agents")[1]}.get(name)


@check
def as_marks_you_alive_without_narrowing_what_you_see(b):
    # The inversion this fixes: for= fused identity and filtering, so a
    # monitor - which polls unfiltered ON PURPOSE, because relaying only its
    # own mail would be useless - was anonymous, while an agent reading just
    # its own mail was visible. The role whose entire job is watching was the
    # most likely to look dead.
    post("alice", kind="msg", to="bob", text="between the two of us")
    post("bob", kind="status", text="broadcast to all")
    _, d = call("/delta?since=0&as=watcher")
    texts = [m["text"] for m in d["messages"]]
    assert "between the two of us" in texts, \
        "as= must not filter - a monitor that goes half blind is worse than one that looks dead"
    assert "broadcast to all" in texts, texts
    row = agent_row("watcher")
    assert row and row["active"], "watching is working, and working is being alive"


@check
def for_still_stamps_and_still_filters(b):
    # Compat: for= keeps BOTH meanings, so no existing caller changes.
    post("alice", kind="msg", to="bob", text="not for carol")
    post("alice", kind="status", text="for everyone")
    _, d = call("/delta?since=0&for=carol")
    texts = [m["text"] for m in d["messages"]]
    assert "not for carol" not in texts, texts
    assert "for everyone" in texts, texts
    assert agent_row("carol")["active"], "for= must still stamp"


@check
def an_anonymous_poll_stamps_nobody(b):
    before = {x["agent"] for x in call("/agents")[1]}
    call("/delta?since=0")
    call("/delta?since=0&as=")
    after = {x["agent"] for x in call("/agents")[1]}
    assert before == after, ("a nameless poll must not invent an agent", after - before)


@check
def a_poll_only_agent_is_on_the_roster_at_all(b):
    # The half that made the stamp useless: liveness was recorded for agents
    # who had no ROW, because the roster was assembled from message traffic.
    # The stamp landed nowhere and the agent simply did not appear.
    call("/delta?since=0&as=probe-that-never-speaks")
    row = agent_row("probe-that-never-speaks")
    assert row is not None, "a stamp with no row to land in is not a fix"
    assert row["active"] and row["status"] == "", row


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


# ── checks: /spawn is idempotent per topic ──────────────────────────────────
#
# None of these launch a real agent. The duplicate guard returns BEFORE the
# role file is validated, so an invalid role is a clean discriminator:
#
#   topic held  -> 200 {reused: true}   (guard answers, nothing launched)
#   topic free  -> 400 no role file     (guard passed, launcher never reached)
#
# So "did the guard fire" is readable without ever starting a process.

def spawn_probe(topic, **kw):
    body = {"name": topic, "model": "haiku", "role": "no-such-role",
            "prompt": "never runs"}
    body.update(kw)
    return call("/spawn", body)


@check
def a_held_topic_returns_the_agent_that_holds_it(b):
    # GET-OR-CREATE, not refuse: a caller wanting hands gets hands. But the
    # outcome is MARKED - an unmarked no-op is the empty-files release bug
    # wearing a launcher.
    call("/herdr_state", [{"name": "claude-taken-1111", "tab": "a:1"}])
    st, r = spawn_probe("taken")
    assert st == 200, (st, r)
    assert r["reused"] is True and r["agent"] == "claude-taken-1111", r
    assert r["signal"] == "pane", r


@check
def a_working_agent_with_no_pane_still_holds_its_topic(b):
    # Pane is the honest signal, but the sidecar can be down or behind. Board
    # activity - which includes leaseholders - is the fallback, not nothing.
    call("/herdr_state", [])
    post("claude-busy-2222", kind="status", text="mid-lane")
    st, r = spawn_probe("busy")
    assert st == 200, (st, r)
    assert r["reused"] is True and r["signal"] == "activity", r


@check
def an_empty_pane_snapshot_does_not_mean_the_topic_is_free(b):
    # THE SUBTLE ONE. An absent signal is not evidence of absence: herdr may
    # simply not have reported yet, which is exactly the window after a
    # restart. Concluding "no pane, therefore free" is how a fleet doubles.
    call("/herdr_state", [])
    post("claude-quiet-3333", kind="status", text="working, sidecar is behind")
    st, r = spawn_probe("quiet")
    assert st == 200 and r["reused"] is True, (st, r)
    # ...and the same holds when the snapshot was never posted at all.
    b.restart()                      # herdr_state is in-memory only
    post("claude-quiet2-4444", kind="status", text="no snapshot has ever arrived")
    st, r = spawn_probe("quiet2")
    assert st == 200 and r["reused"] is True, (st, r)


@check
def a_stale_agent_blocks_nothing(b):
    # Identity is durable, presence is not. A topic held by someone who
    # stopped existing is a topic that is free - so this must fall THROUGH the
    # guard and reach the launcher path (400 on the bad role), not reuse.
    b.stop()
    with open(os.path.join(b.workdir, "board.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"seq": 7000, "unix": int(time.time()) - 86400,
                            "agent": "claude-ghost-5555", "kind": "status",
                            "text": "left hours ago"}) + "\n")
    b.start()
    call("/herdr_state", [])
    st, r = spawn_probe("ghost")
    assert st == 400, ("a stale holder must not reuse", st, r)


@check
def force_spawns_a_deliberate_second(b):
    # Two agents on one topic is legitimate but unusual; force says you meant
    # it. Proven by the guard being bypassed - without force this exact call
    # reuses, with force it reaches the launcher path instead.
    call("/herdr_state", [{"name": "claude-double-6666", "tab": "a:2"}])
    assert spawn_probe("double")[0] == 200, "sanity: it reuses without force"
    st, r = spawn_probe("double", force=True)
    assert st == 400, ("force must bypass the guard", st, r)


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


# ── checks: the contract IS the claim (task #36) ────────────────────────────

def claims_of(agent):
    return {c["file"] for c in call("/claims")[1] if c["agent"] == agent}


@check
def claiming_a_task_registers_its_files_with_no_status_post(b):
    # The whole point: the "claiming #N, here are my files" post was narrating
    # what the claim event already recorded.
    _, r = task("draft", "planner", text="work", files=["src/a.odin", "src/b.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    assert claims_of("worker") == set(), "nothing claimed before the claim"

    task("claim", "worker", id=tid)
    assert claims_of("worker") == {"src/a.odin", "src/b.odin"}, claims_of("worker")


@check
def a_task_claim_makes_a_silent_owner_active(b):
    _, r = task("draft", "planner", text="quiet work", files=["src/c.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "silent-worker", id=tid)
    a = {x["agent"]: x for x in call("/agents")[1]}["silent-worker"]
    assert a["active"], "holding a live lease is liveness, even having never posted"


@check
def submit_release_and_rework_let_the_files_go(b):
    for verb, setup in (("release", None), ("submit", None), ("rework", "submit")):
        _, r = task("draft", "planner", text=f"via {verb}", files=[f"src/{verb}.odin"])
        tid = r["id"]
        task("ready", "planner", id=tid)
        task("claim", "worker", id=tid)
        assert f"src/{verb}.odin" in claims_of("worker"), verb
        if setup:
            task(setup, "worker", id=tid)
        task(verb, "worker", id=tid)
        assert f"src/{verb}.odin" not in claims_of("worker"), \
            f"{verb} should have released the files"


@check
def submitting_also_drops_the_status_claims_nobody_remembers_to_release(b):
    # Sonnet's real miss: the task files let go on submit, but the files named
    # in a STATUS post stayed claimed until a separate `release` POST that is
    # easy to forget - index.html sat claimed all afternoon that way.
    post("worker", kind="status", text="editing the page by hand",
         files=["index.html"])
    assert "index.html" in claims_of("worker")
    _, r = task("draft", "planner", text="unrelated contract", accept="x")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    task("submit", "worker", id=tid, rev=tasks()[tid]["rev"])
    assert "index.html" not in claims_of("worker"), \
        "submit must be a release - that is the whole point of combining them"
    # The status TEXT survives: it is still the last thing they said.
    me = [a for a in call("/agents")[1] if a["agent"] == "worker"][0]
    assert me["status"] == "editing the page by hand", me


@check
def a_status_after_a_submit_claims_again(b):
    # The clear is a moment, not a mute. An agent picking up new work right
    # after submitting must be able to claim files the normal way.
    _, r = task("add", "planner", text="some work")
    tid = r["id"]
    task("claim", "worker", id=tid)
    task("submit", "worker", id=tid)
    time.sleep(1.1)  # these timestamps are whole seconds
    post("worker", kind="status", text="on to the next thing",
         files=["src/next.odin"])
    assert "src/next.odin" in claims_of("worker"), \
        "a submit must not deafen the agent to its own later claims"


@check
def the_release_verb_still_works_on_its_own(b):
    # Combining the two must not remove either. `release` as a message kind
    # and as a task action both still drop claims by themselves.
    post("solo", kind="status", text="ad-hoc work", files=["src/solo.odin"])
    assert "src/solo.odin" in claims_of("solo")
    post("solo", kind="release", text="done with it")
    assert "src/solo.odin" not in claims_of("solo")

    post("hand", kind="status", text="ad-hoc too", files=["src/hand.odin"])
    _, r = task("add", "planner", text="handed back")
    tid = r["id"]
    task("claim", "hand", id=tid)
    task("release", "hand", id=tid)
    assert "src/hand.odin" not in claims_of("hand"), \
        "giving the task back releases everything, same as submit"


@check
def a_submit_release_survives_a_restart(b):
    # claims_cleared is derived from the task log, so replay must rebuild it -
    # otherwise every claim an agent ever dropped comes back on restart.
    post("worker", kind="status", text="holding a file", files=["src/gone.odin"])
    _, r = task("add", "planner", text="work")
    tid = r["id"]
    task("claim", "worker", id=tid)
    task("submit", "worker", id=tid)
    assert "src/gone.odin" not in claims_of("worker")
    b.restart()
    assert "src/gone.odin" not in claims_of("worker"), \
        "a released claim must not rise from the dead on replay"


@check
def block_keeps_the_files_because_that_is_when_it_matters_most(b):
    # A blocked owner is the one most likely to have half-edited files sitting
    # in the tree - dropping the warning there removes it exactly when needed.
    _, r = task("draft", "planner", text="blocked work", files=["src/held.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    task("block", "worker", id=tid, text="waiting on glenn")
    assert tasks()[tid]["state"] == "Blocked"
    assert "src/held.odin" in claims_of("worker"), "block must KEEP the claim"


@check
def supersede_drops_the_files(b):
    _, r = task("draft", "planner", text="doomed", files=["src/gone.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    _, repl = task("add", "planner", text="the replacement")
    task("supersede", "planner", id=tid, by_id=repl["id"])
    assert "src/gone.odin" not in claims_of("worker"), "terminal work holds nothing"


@check
def an_expired_lease_sheds_task_claims_with_no_special_case(b):
    _, r = task("draft", "planner", text="lapsing", files=["src/lapse.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid, lease_secs=1)
    assert "src/lapse.odin" in claims_of("worker")
    time.sleep(2)
    assert "src/lapse.odin" not in claims_of("worker"), \
        "the lease is the bound - no state needs its own timer"


@check
def a_task_claimed_file_still_warns_another_agent(b):
    _, r = task("draft", "planner", text="contested files", files=["src/hot.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "holder", id=tid)
    _, resp = post("intruder", kind="status", text="editing", files=["src/hot.odin"])
    assert any("src/hot.odin" in w and "holder" in w for w in resp["warnings"]), resp


@check
def status_claims_still_work_for_work_outside_any_task(b):
    post("adhoc", kind="status", text="poking at something", files=["src/adhoc.odin"])
    assert "src/adhoc.odin" in claims_of("adhoc"), "the old path must keep working"
    post("adhoc", kind="release", text="done")
    assert claims_of("adhoc") == set()


# ── checks: plan refs + result_seq validation (task #23) ────────────────────

@check
def a_draft_derives_plan_id_and_rev_from_plan_seq_alone(b):
    # The contract has callers send plan_seq only. The first live v3 task came
    # out with plan_id 0 / plan_rev 0 / plan_seqs [0] while its own log line
    # held 600 - the event was right, the projection was wrong.
    _, plan = post("planner", text="the plan post itself")
    seq = plan["seq"]
    _, r = task("draft", "planner", text="planned work", plan_seq=seq)
    t = tasks()[r["id"]]
    assert t["plan_id"] == seq, t
    assert t["plan_rev"] == 1, t
    assert t["plan_seqs"] == [seq], t   # literal, not merely non-empty


@check
def plan_seqs_survive_the_request_that_created_them(b):
    # The backing store used to die with the request, so this read [0] every
    # time - deterministically, which is why no restart could mask it. Create
    # several tasks to disturb memory, then re-read them all.
    ids = []
    for i in range(5):
        _, plan = post("planner", text=f"plan post {i}")
        _, r = task("draft", "planner", text=f"plan {i}", plan_seq=plan["seq"])
        ids.append((r["id"], plan["seq"]))
    got = tasks()
    for tid, seq in ids:
        assert got[tid]["plan_seqs"] == [seq], (tid, got[tid]["plan_seqs"], seq)


@check
def amending_appends_to_the_plan_trail_and_it_survives_restart(b):
    _, p1 = post("planner", text="plan v1")
    _, r = task("draft", "planner", text="v1", plan_seq=p1["seq"])
    tid = r["id"]
    _, p2 = post("planner", text="plan v2")
    task("amend", "planner", id=tid, rev=1, text="v2", plan_seq=p2["seq"])
    trail = [p1["seq"], p2["seq"]]
    t = tasks()[tid]
    assert t["plan_seqs"] == trail, t
    assert t["plan_rev"] == 2, f"a new plan post is a new plan revision: {t}"

    b.restart()   # concrete values, not just equivalence - [0]==[0] would pass
    t = tasks()[tid]
    assert t["plan_seqs"] == trail, t
    assert t["plan_id"] == p1["seq"] and t["plan_rev"] == 2, t
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


# -- checks: the running binary can be identified --------------------------


@check
def every_response_carries_the_build_stamp(b):
    # The failure this exists for: six server fixes sat inert in production
    # because the running exe predated them, and NOTHING SERVED SAID SO. An
    # unknown parameter answers 200 and is silently ignored, so a stale
    # server looks exactly like a current one from the outside.
    for path in ("/agents", "/tasks", "/claims", "/delta?since=0"):
        h = headers_of(path)
        assert "X-Board-Build" in h, (path, sorted(h))


@check
def an_unstamped_build_says_so_instead_of_guessing(b):
    # board_check builds without -define, so this suite always runs against
    # an unstamped binary - which makes it the natural place to pin the
    # honest-default behaviour. A stamp that invented a plausible value would
    # be the original failure wearing the fix's clothes.
    assert headers_of("/agents")["X-Board-Build"].startswith("unstamped"),         headers_of("/agents")["X-Board-Build"]
    _, b_ = call("/build")
    assert b_["commit"] == "unstamped" and b_["built"] == "unstamped", b_


@check
def build_reports_when_this_process_started(b):
    # BUILD_TIME alone cannot tell the two staleness modes apart: built from
    # old source, versus built from new source and never restarted. Tonight
    # was the second one.
    _, before = call("/build")
    assert before["started"] <= int(time.time()) + 2, before
    b.restart()
    _, after = call("/build")
    assert after["started"] >= before["started"], (before, after)


@check
def the_stamp_does_not_change_any_response_body(b):
    # /agents returns a bare ARRAY. Putting the stamp in its body would have
    # meant wrapping it, breaking index.html and this suite for a diagnostic.
    assert isinstance(call("/agents")[1], list)
    assert isinstance(call("/tasks")[1], list)


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
