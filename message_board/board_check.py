"""Behaviour checks for the board's workflow-v3 task and message model.

Runs against a THROWAWAY board on its own port with its own log files, so it
never touches the live board's history. Start nothing yourself:

    python board_check.py            # build + run everything
    python board_check.py -k claim   # only checks whose name contains "claim"

Every check is a real HTTP round trip against a real server process, because
the thing under test IS the request path: the 409s are only correct because
the accept loop is single-threaded, and that cannot be tested in isolation.
"""
import hashlib
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
sys.path.insert(0, HERE)  # so the watchdog beside us can be driven directly
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


# ── checks: state-describing fields clear on departure (task #52) ───────────
#
# THE RULE, and blocked_on above is its first instance: a field that describes
# a state must not outlive it. blocked_on is the block IN FORCE, superseded_by
# the replacement IN FORCE, result_seq the evidence CURRENTLY OFFERED.
# Direction is CLEAR, not KEEP, everywhere — a cleared field costs the next
# caller one parameter; a kept one silently attests to something no longer
# true, and nothing on the record says so.


@check
def every_verb_that_leaves_superseded_clears_the_replacement_marker(b):
    # `ready` is the departure #51 actually took, but the clear belongs to the
    # STATE and not to any one verb, so every way out gets the same answer —
    # which is also what stops a verb added later from quietly reintroducing
    # the marker.
    for verb in ("ready", "reopen", "done"):
        _, repl = task("add", "planner", text=f"the replacement, via {verb}")
        _, r = task("add", "planner", text=f"replaced then resurrected by {verb}")
        tid = r["id"]

        task("supersede", "planner", id=tid, by_id=repl["id"])
        t = tasks()[tid]
        assert t["state"] == "Superseded" and t["superseded_by"] == repl["id"], \
            ("supersede SETS the marker", verb, t)

        assert task(verb, "planner", id=tid)[0] == 200, verb
        t = tasks()[tid]
        assert t["state"] != "Superseded", (verb, t)
        assert t["superseded_by"] == 0, \
            (f"{verb} left Superseded still attesting a replacement", t)

    # ...and a task superseded a second time names the NEW replacement, not a
    # union of both. Fresh, not merged.
    _, r = task("add", "planner", text="replaced twice")
    tid = r["id"]
    _, first = task("add", "planner", text="first replacement")
    _, second = task("add", "planner", text="second replacement")
    task("supersede", "planner", id=tid, by_id=first["id"])
    task("ready", "planner", id=tid)
    task("supersede", "planner", id=tid, by_id=second["id"])
    assert tasks()[tid]["superseded_by"] == second["id"], \
        "re-supersede names the replacement in force now"


@check
def a_marker_on_a_live_task_is_the_case_that_misroutes_work(b):
    # ADDITIVE, not part of #52's acceptance — offered by claude-strict-parse-
    # 4e28 (seq 956) as the near miss they personally made an hour earlier.
    # The contract's instance is a stale marker on a FINISHED task: misleading,
    # and cheap to shrug off because the work is already done. This is the
    # marker misrouting LIVE work. #51 sat Ready with superseded_by=50 while
    # #50 sat Superseded with superseded_by=51 — a mutual pointer, and nothing
    # in the data breaks the tie. Two agents dispatched from opposite ends each
    # read a record saying the other task is the live one. That near miss was
    # broken on dispatch prose, which is not a mechanism.
    _, a = task("add", "planner", text="contract A")
    _, c = task("add", "planner", text="contract B")
    aid, bid = a["id"], c["id"]
    task("supersede", "planner", id=aid, by_id=bid)   # the merge
    task("supersede", "planner", id=bid, by_id=aid)   # ...and back
    task("ready", "planner", id=aid)                  # A is the live one

    live, dead = tasks()[aid], tasks()[bid]
    assert live["state"] == "Ready" and live["superseded_by"] == 0, \
        ("a claimable task must not point at its own replacement", live)
    assert dead["state"] == "Superseded" and dead["superseded_by"] == aid, \
        ("the marker still describes the task that really is superseded", dead)


@check
def rework_clears_the_evidence_it_declined_to_accept(b):
    _, r = task("draft", "planner", text="reworked work", accept="must be right")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    first = post("worker", text="first write-up", task_id=tid)[1]["seq"]
    task("submit", "worker", id=tid, result_seq=first)
    assert tasks()[tid]["result_seq"] == first, "submit SETS the audit link"

    task("rework", "reviewer", id=tid)
    t = tasks()[tid]
    assert t["state"] == "Ready", t
    assert t["result_seq"] == 0, \
        ("a reworked task cites nothing — the rework MEANS the evidence was "
         "not accepted", t)

    # The second attempt cites the SECOND write-up, and approval keeps it:
    # Done is where the evidence is finally, correctly, on offer.
    task("claim", "worker", id=tid)
    second = post("worker", text="second write-up", task_id=tid)[1]["seq"]
    task("submit", "worker", id=tid, result_seq=second)
    assert tasks()[tid]["result_seq"] == second, "resubmit sets fresh"
    task("approve", "reviewer", id=tid)
    t = tasks()[tid]
    assert t["state"] == "Done" and t["result_seq"] == second, t


@check
def evidence_dies_on_the_way_back_to_the_queue_not_on_the_way_to_a_grave(b):
    # THE TWO FIELDS DEPART DIFFERENTLY and one predicate for both loses an
    # audit link. superseded_by is false anywhere but Superseded. result_seq
    # is only MISLEADING when the task is back on the queue: a Ready, unowned,
    # claimable task citing evidence tells the next agent the work is done.
    # In a terminal state it is history rather than an offer, so superseding a
    # finished task must not wipe the link to the write-up it really produced.
    def finished(label):
        _, r = task("draft", "planner", text=label, accept="x")
        tid = r["id"]
        task("ready", "planner", id=tid)
        task("claim", "worker", id=tid)
        seq = post("worker", text=f"write-up for {label}", task_id=tid)[1]["seq"]
        task("submit", "worker", id=tid, result_seq=seq)
        task("approve", "reviewer", id=tid)
        assert tasks()[tid]["state"] == "Done"
        return tid, seq

    tid, seq = finished("superseded after the fact")
    _, repl = task("add", "planner", text="what replaced it")
    task("supersede", "planner", id=tid, by_id=repl["id"])
    t = tasks()[tid]
    assert t["state"] == "Superseded" and t["result_seq"] == seq, \
        ("a terminal task keeps the link to the work it really did", t)

    tid, _ = finished("reopened later")
    task("reopen", "planner", id=tid)
    t = tasks()[tid]
    assert t["state"] == "Ready" and t["result_seq"] == 0, \
        ("reopen puts it back on the queue, so it offers nothing — same shape "
         "as rework, which is why the clear is keyed on the state", t)


@check
def a_block_round_trip_is_not_a_departure(b):
    # Blocked is an OVERLAY, not a state anyone departs to: it stashes where it
    # came from and unblock puts it back. A clear that read `state` alone would
    # drop the evidence of a task blocked out of Review, and unblock would
    # return it to Review citing nothing — a loss on a transition where nobody
    # departed. Reading through blocked_from is what makes the round trip
    # lossless, and this is the leg that fails if that is dropped.
    _, r = task("draft", "planner", text="blocked mid-review", accept="x")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    seq = post("worker", text="the write-up", task_id=tid)[1]["seq"]
    task("submit", "worker", id=tid, result_seq=seq)

    task("block", "reviewer", id=tid, text="waiting on glenn to look")
    assert tasks()[tid]["state"] == "Blocked"
    task("unblock", "reviewer", id=tid)
    t = tasks()[tid]
    assert t["state"] == "Review" and t["result_seq"] == seq, \
        ("a block round trip must not eat the evidence", t)

    # Same for a superseded task: blocking it does not un-supersede it.
    _, repl = task("add", "planner", text="replacement")
    _, r2 = task("add", "planner", text="superseded then blocked")
    sid = r2["id"]
    task("supersede", "planner", id=sid, by_id=repl["id"])
    task("block", "planner", id=sid, text="parked")
    task("unblock", "planner", id=sid)
    t = tasks()[sid]
    assert t["state"] == "Superseded" and t["superseded_by"] == repl["id"], t


@check
def a_stale_marker_from_an_older_board_heals_itself_on_replay(b):
    # #51'S SHAPE, VERBATIM, and it is the leg that proves the fix is in the
    # right layer. #51 was superseded by #50 during a merge, amended, brought
    # back with `ready`, then claimed, submitted and approved — carrying
    # superseded_by=50 the whole way to Done, while #50 was itself superseded
    # by #51. A board that had already written those events cannot be fixed by
    # a new rule at the request path; it is fixed because the projection is a
    # REPLAY of an append-only log, which makes the fix its own migration.
    #
    # So this seeds the events an older binary would have left on disk and
    # boots on them. Nothing is posted through the API, and the assertion that
    # tasks.jsonl comes back byte-for-byte is the "no migration" half: history
    # is not rewritten, only re-read.
    b.stop()
    log = os.path.join(b.workdir, "tasks.jsonl")
    now = int(time.time())
    events = [
        {"action": "draft", "id": 951, "unix": now, "agent": "coordinator",
         "text": "the surviving contract", "accept": "must ship"},
        {"action": "draft", "id": 950, "unix": now, "agent": "planner",
         "text": "the merged-away twin", "accept": "must ship"},
        {"action": "supersede", "id": 951, "unix": now, "agent": "coordinator",
         "by_id": 950},
        {"action": "amend", "id": 951, "unix": now, "agent": "planner",
         "text": "the surviving contract, amended"},
        {"action": "ready", "id": 951, "unix": now, "agent": "planner"},
        {"action": "supersede", "id": 950, "unix": now, "agent": "planner",
         "by_id": 951},
        {"action": "claim", "id": 951, "unix": now, "agent": "worker",
         "lease_secs": 3600},
        {"action": "submit", "id": 951, "unix": now, "agent": "worker",
         "result_seq": 941},
        {"action": "approve", "id": 951, "unix": now, "agent": "reviewer"},
    ]
    with open(log, "a", encoding="utf-8") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    before = open(log, "rb").read()

    b.start()

    healed = tasks()[951]
    assert healed["state"] == "Done", healed
    assert healed["superseded_by"] == 0, \
        ("a Done task still attesting it was replaced — by the task it "
         "superseded", healed)
    # The heal is targeted, not a blanket wipe: everything the record is
    # entitled to keep is still there.
    assert healed["result_seq"] == 941, ("Done still offers its evidence", healed)
    assert healed["reviewer"] == "reviewer" and healed["rev"] == 2, healed
    # ...and the twin, which really IS superseded, keeps its marker.
    assert tasks()[950]["superseded_by"] == 951, tasks()[950]

    assert open(log, "rb").read() == before, \
        "the replay is the migration — it must not rewrite tasks.jsonl"


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


@check
def spawn_refuses_a_missing_name_instead_of_inventing_one(b):
    # It used to substitute the topic "worker" and LAUNCH. A typo in the
    # identity field of a process-launching endpoint started a real agent
    # under a name nobody chose - which is exactly how a probe sending
    # {"topic":...} instead of {"name":...} produced a stray.
    st, r = call("/spawn", {"prompt": "no name at all"})
    assert st == 400 and "name" in r["error"], (st, r)
    st, r = call("/spawn", {"name": "   ", "prompt": "whitespace is not a name"})
    assert st == 400 and "name" in r["error"], (st, r)


@check
def an_unusable_name_is_refused_and_says_why(b):
    # Self-explaining refusal: the caller learns the charset from the error
    # rather than from the README. Refusing loudly is only better than
    # substituting quietly if the refusal teaches.
    st, r = call("/spawn", {"name": "!!! ???", "prompt": "nothing usable"})
    assert st == 400, (st, r)
    assert "a-z0-9-" in r["error"], r
    assert "!!! ???" in r["error"], ("the refusal should quote what was sent", r)
    # ...and the echo must not break the JSON it travels in. A name carrying
    # a double quote once produced {"error":"name "x"" ..."} - the caller got
    # a parse error instead of the explanation the refusal exists to give.
    st, r = call("/spawn", {"name": '"', "prompt": "a lone double quote"})
    assert st == 400 and "error" in r, ("the refusal must stay valid JSON", st, r)
    assert '"' in r["error"], ("the quote must survive into the message", r)


@check
def a_valid_name_is_unaffected_by_the_new_refusals(b):
    # The guard must not have tightened anything else. A real name still
    # reaches the launcher path - proven by the bad role, which is refused
    # AFTER the name checks and before any process starts.
    st, r = call("/spawn", {"name": "Raids Team", "role": "no-such-role",
                            "prompt": "valid name, bad role"})
    assert st == 400 and "role" in r["error"],         ("a usable name must get past the name checks", st, r)


@check
def spawn_refuses_when_the_launcher_is_not_there(b):
    # The dispatch is `cmd /c start /b`, which returns 0 for "I started
    # something" rather than "the something worked" - so the rc check could
    # never fail, and with no launcher at all the endpoint still answered
    # ok:true and announced a herdr pane that did not exist. The scratch
    # workdir has no spawn_herdr.py, which makes this suite the natural place
    # to pin it.
    st, r = call("/spawn", {"name": "nolauncher", "prompt": "cannot possibly run"})
    assert st == 500, (st, r)
    assert "launcher" in r["error"] and "spawn_herdr.py" in r["error"], r


@check
def the_spawn_announcement_claims_only_a_request(b):
    # Wording is the fix here, not decoration: the server cannot see whether
    # a detached launch became an agent, so it must not say "spawned" or name
    # a herdr pane. The watchdog is what confirms or contradicts it.
    #
    # This has to REACH the announcement, so the workdir gets a no-op
    # launcher. Written after the first version of this check passed while
    # the old wording was restored - the 500 fired first, no announcement was
    # ever posted, and "nothing says spawned" was true because nothing was
    # said at all. A check that passes for the wrong reason is worse than
    # none: it reports coverage it does not have.
    with open(os.path.join(b.workdir, "spawn_herdr.py"), "w") as f:
        f.write("import sys; sys.exit(0)\n")
    st, r = call("/spawn", {"name": "wording", "prompt": "reaches the announcement"})
    assert st == 200, (st, r)
    assert r["launched"] == "requested", r

    texts = [m["text"] for m in call("/delta?since=0")[1]["messages"]
             if m["agent"] == "board"]
    said = [t for t in texts if "wording" in t]
    assert said, ("the announcement must exist for this check to mean anything", texts)
    assert said[0].startswith("launch requested for "), said
    assert "herdr pane" not in said[0], said


@check
def the_watchdog_drops_a_deliberately_closed_launch(b):
    # It tracked launches and cleared them when the agent SPOKE, but never
    # when the agent was CLOSED - so one killed before it ever posted was
    # reported as a probable failed spawn, contradicted by a message sitting
    # in the same delta this watcher was already reading.
    import importlib, herdr_sync as hs
    importlib.reload(hs)
    hs.BASE, hs.cursor, hs.pending = BASE, 0, {}

    post("board", kind="msg", text="launch requested for claude-ghost-9999 (model fable) - task: x")
    hs.watch_spawns([])
    assert "claude-ghost-9999" in hs.pending, hs.pending

    post("board", kind="msg", text="closed claude-ghost-9999 (herdr tab a:1) from the board UI")
    hs.watch_spawns([])
    assert hs.pending == {}, ("a deliberate close is not a failed launch", hs.pending)


@check
def the_watchdog_warns_about_facts_not_causes(b):
    # "the spawn likely failed" is a diagnosis. What the watchdog can see is
    # that nothing spoke and herdr shows no pane - naming a cause it never
    # checked is how a reader ends up debugging a launcher that was fine.
    import importlib, herdr_sync as hs
    importlib.reload(hs)
    hs.BASE, hs.cursor, hs.pending, hs.GRACE = BASE, 0, {}, -1

    post("board", kind="msg", text="launch requested for claude-mute-8888 (model fable) - task: x")
    hs.watch_spawns([])          # GRACE is negative, so it warns immediately
    warned = [m["text"] for m in call("/delta?since=0")[1]["messages"]
              if "WARNING" in m["text"]]
    assert warned, "it should have warned"
    assert "likely failed" not in warned[-1], warned[-1]
    assert "has not posted" in warned[-1] and "no pane" in warned[-1], warned[-1]


# ── checks: task #56 - the watchdog reports, it does not translate ─────────
#
# rev 1 of #56 fixed the "no pane" lie by finding a status (blocked) and
# guessing a cause (wants a keypress) from ONE observation - and was wrong an
# hour later. rev 2's fix is dead_spawn_warning(): say what herdr returned,
# verbatim, name the pane, and stop. Three legs, matching the three shapes
# watch_spawns can find a pending name in: no entry at all, an entry with a
# status that is not alive (herdr's whole enum minus working/idle, including
# one it has never heard of), and an entry WITH an alive status.

@check
def dead_spawn_warning_is_a_pure_function_of_what_herdr_returned(b):
    # Direct check of the extracted builder, no board round trip needed -
    # this is the piece the contract asks to be checkable in isolation.
    import importlib, herdr_sync as hs
    importlib.reload(hs)

    absent = hs.dead_spawn_warning("claude-x", 190, None)
    assert "no pane" in absent and "status=" not in absent, absent

    blocked = hs.dead_spawn_warning("claude-x", 190, {"status": "blocked", "pane": "w1M:p2"})
    assert "status=blocked" in blocked and "w1M:p2" in blocked, blocked
    assert "no pane" not in blocked, blocked
    # rev 1's exact defect: no cause, no instruction, however plausible.
    assert "keypress" not in blocked and "relaunch" not in blocked, blocked

    # An enum value herdr has never returned before must still degrade to
    # being named verbatim, not fall into either canned sentence - the
    # manifest is versioned and owned by another program.
    future = hs.dead_spawn_warning("claude-x", 5, {"status": "wobbling", "pane": "w2:p1"})
    assert "status=wobbling" in future, future


@check
def the_dead_spawn_warning_still_says_absent_when_herdr_has_no_pane(b):
    # Leg 1: absent. This is the one wording that must NOT change - it is the
    # one thing that genuinely differs from every other status.
    import importlib, herdr_sync as hs
    importlib.reload(hs)
    hs.BASE, hs.cursor, hs.pending, hs.GRACE = BASE, 0, {}, -1

    post("board", kind="msg", text="launch requested for claude-absent-1234 (model fable) - task: x")
    hs.watch_spawns([])   # empty fleet: herdr shows no pane for anyone
    warned = [m["text"] for m in call("/delta?since=0")[1]["messages"]
              if "WARNING" in m["text"]]
    assert warned and "claude-absent-1234" in warned[-1], warned
    assert "no pane" in warned[-1] and "status=" not in warned[-1], warned[-1]


@check
def the_dead_spawn_warning_names_herdrs_status_and_pane_instead_of_no_pane(b):
    # Leg 2: present, with a status that is not "working"/"idle" - blocked,
    # done, unknown, or anything else herdr's enum grows tomorrow. This is
    # seq 934/935's exact bug: herdr showed a pane, and the old code said
    # "no pane" anyway because "blocked" was not in its alive set.
    import importlib, herdr_sync as hs
    importlib.reload(hs)
    hs.BASE, hs.cursor, hs.pending, hs.GRACE = BASE, 0, {}, -1

    post("board", kind="msg", text="launch requested for claude-strict-parse-4e28 (model fable) - task: x")
    fleet = [{"name": "claude-strict-parse-4e28", "status": "blocked", "pane": "w1M:p2"}]
    hs.watch_spawns(fleet)
    warned = [m["text"] for m in call("/delta?since=0")[1]["messages"]
              if "WARNING" in m["text"]]
    assert warned, "a non-alive status must still warn - the filter is unchanged"
    last = warned[-1]
    assert "no pane" not in last, ("herdr showed a pane; the message must not deny it", last)
    assert "status=blocked" in last and "w1M:p2" in last, last
    assert "keypress" not in last and "relaunch" not in last, \
        ("rev 1's defect: translating a status into a cause or an instruction", last)


@check
def a_pending_spawn_herdr_shows_alive_is_given_time_not_warned(b):
    # Leg 3: present WITH an alive status - watch_spawns must still give it
    # room to finish booting rather than warn, same as before #56. Proves the
    # fix touched only the sentence, not the alive-set filter the task
    # explicitly says not to change.
    import importlib, herdr_sync as hs
    importlib.reload(hs)
    hs.BASE, hs.cursor, hs.pending, hs.GRACE = BASE, 0, {}, -1

    post("board", kind="msg", text="launch requested for claude-booting-5678 (model fable) - task: x")
    fleet = [{"name": "claude-booting-5678", "status": "working", "pane": "w1M:p3"}]
    hs.watch_spawns(fleet)
    assert "claude-booting-5678" in hs.pending, \
        "an alive status must not warn or drop the pending entry"
    warned = [m["text"] for m in call("/delta?since=0")[1]["messages"]
              if "WARNING" in m["text"]]
    assert not warned, warned


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
    # Shape-only: warnings are records, so this reads the fields rather than
    # searching a sentence. WHICH collisions warn is unchanged - that is the
    # invariant the structured record was allowed to be built under.
    assert any(w["file"] == "src/hot.odin" and w["by"] == "holder"
               for w in resp["warnings"]), resp


def one_warning(resp, path):
    """The single warning about `path`, asserted to be a RECORD.

    Against the pre-fix binary warnings are plain strings, so this fails on
    the isinstance line with the actual payload in the message - which is the
    red these legs exist to show."""
    ws = resp["warnings"]
    assert ws, f"expected a warning about {path}, got none: {resp}"
    assert all(isinstance(w, dict) for w in ws), \
        f"warnings must be structured records, not sentences: {ws!r}"
    hit = [w for w in ws if w["file"] == path]
    assert len(hit) == 1, ws
    return hit[0]


def stored_line(b, seq):
    """The message as it was WRITTEN to board.jsonl.

    Deliberately not read back through /delta: the defect this lane exists to
    fix was the response and the log DISAGREEING - warnings went out on the
    wire and were never persisted - and a check reading the API could not have
    seen it."""
    with open(os.path.join(b.workdir, "board.jsonl"), encoding="utf-8") as f:
        for ln in f:
            m = json.loads(ln)
            if m.get("seq") == seq:
                return m
    raise AssertionError(f"seq {seq} is not in board.jsonl")


@check
def a_lease_only_holder_never_reads_as_a_57_year_old_status_claim(b):
    # THE REPRO. Pre-fix this warning read:
    #   'contested.odin claimed by leaseholder (20683d ago)'
    # because the age was age_string(now, info.status_unix), and status_unix is
    # set ONLY by a status/release post. A holder that claimed its files
    # through a task lease and never posted a status carried status_unix == 0,
    # so the age was measured from the epoch. The claim was correct, current
    # and perfectly valid; only the sentence describing it was absurd.
    _, r = task("draft", "planner", text="lease-only holder",
                files=["src/lease_only.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "leaseholder", id=tid)   # deliberately never posts a status

    _, resp = post("intruder", kind="status", text="editing",
                   files=["src/lease_only.odin"])
    w = one_warning(resp, "src/lease_only.odin")
    assert w["source"] == "task" and w["task_id"] == tid, w
    assert w["status_unix"] == 0, \
        "the holder never spoke - the stamp is honestly zero, and stays zero"
    assert f"task #{tid}" in w["text"], w
    assert "ago" not in w["text"], \
        f"no age may be derived from a zero stamp: {w['text']!r}"

    # THE CONTROL, and it is what makes everything above evidence rather than
    # decoration: a file nobody holds must produce no warning at all. Without
    # it, a change that silenced the warning path entirely would satisfy every
    # "no bad age" assertion here by saying nothing whatsoever.
    _, quiet = post("intruder", kind="status", text="untouched",
                    files=["src/nobody_wants_this.odin"])
    assert quiet["warnings"] == [], quiet


@check
def claims_dates_a_lease_claim_by_its_lease_not_by_the_epoch(b):
    # Same root, second rendering. /claims built Claim{..., info.status_unix,
    # info.last_seen} while a live lease set active directly, so the endpoint
    # could report an agent as ACTIVE and last seen at the epoch in one row.
    _, r = task("draft", "planner", text="lease-only", files=["src/c.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "leaseholder", id=tid)

    rows = [c for c in call("/claims")[1] if c["agent"] == "leaseholder"]
    assert len(rows) == 1, rows
    c = rows[0]
    assert c["source"] == "task" and c["task_id"] == tid, c
    assert c["claimed_unix"] > 0, f"a lease claim is dated by its lease: {c}"
    assert c["last_seen"] > 0, f"active and last seen at the epoch is nonsense: {c}"


@check
def a_status_claim_records_source_status_and_keeps_its_wording(b):
    # The other half of the falsifier: for a status-derived claim the text is
    # BYTE-IDENTICAL to what the board has always said. The fix changes the
    # sentence exactly when a lease is involved and nowhere else.
    post("speaker", kind="status", text="I have this", files=["src/spoken.odin"])
    _, resp = post("other", kind="status", text="me too", files=["src/spoken.odin"])
    w = one_warning(resp, "src/spoken.odin")
    assert w["source"] == "status" and w["task_id"] == 0, w
    assert w["status_unix"] > 0, w
    assert re.fullmatch(r"src/spoken\.odin claimed by speaker \(\d+[smhd] ago\)",
                        w["text"]), w["text"]


@check
def claiming_the_same_file_down_both_paths_records_both(b):
    # An agent holding a file through a lease AND announcing it in a status is
    # claiming twice down two paths with different bounds. Whether that
    # duplicate should exist is someone else's question; this record is what
    # makes it answerable, so `both` has to be a value rather than a coin flip
    # between the two sources.
    _, r = task("draft", "planner", text="doubly held", files=["src/dbl.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "holder", id=tid)
    post("holder", kind="status", text="also saying it out loud",
         files=["src/dbl.odin"])

    _, resp = post("intruder", kind="status", text="editing", files=["src/dbl.odin"])
    w = one_warning(resp, "src/dbl.odin")
    assert w["source"] == "both" and w["task_id"] == tid, w
    assert w["status_unix"] > 0, w
    assert "ago" in w["text"] and f"task #{tid}" in w["text"], w["text"]


@check
def a_holder_kept_alive_only_by_polling_is_visible_in_the_record(b):
    # THE SIGNATURE, observed instead of inferred. A /delta poll carrying a
    # name refreshes last_seen, so an agent running the mandated board monitor
    # never goes inactive and its status-derived claims never stop warning.
    # That is a real question about claim expiry, and until now the data could
    # not even express it: `active` was one bool fed by speech, polls and
    # leases alike. Two separate stamps make polled-newer-than-spoke something
    # a query can COUNT.
    post("watcher", kind="status", text="holding", files=["src/watched.odin"])
    time.sleep(1.1)
    call("/delta?since=0&limit=0&as=watcher")   # what the monitor does, and only that

    _, resp = post("intruder", kind="status", text="editing",
                   files=["src/watched.odin"])
    w = one_warning(resp, "src/watched.odin")
    assert w["by_polled_unix"] > w["by_spoke_unix"], \
        f"the poll is what is keeping this claim alive, and it must show: {w}"
    assert w["status_unix"] == w["by_spoke_unix"], w


@check
def the_log_carries_the_warnings_the_response_returned(b):
    # THE POINT OF THE WHOLE LANE. Warnings were computed per request, sent,
    # and dropped - so nobody could say whether one had ever fired, and every
    # argument about file claims was inferred from overlap rather than read
    # off an observation.
    _, r = task("draft", "planner", text="held", files=["src/persist.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "holder", id=tid)

    _, resp = post("intruder", kind="status", text="editing",
                   files=["src/persist.odin"])
    assert resp["warnings"], resp
    line = stored_line(b, resp["seq"])
    assert line["warnings"] == resp["warnings"], (
        "the log must carry what the wire carried\n"
        f" wire: {resp['warnings']}\n log:  {line.get('warnings')}")

    # ...and an uncontested post records an EMPTY list, which is a reading in
    # its own right: "this post collided with nothing", not "nobody looked".
    _, clean = post("loner", kind="status", text="mine alone", files=["src/mine.odin"])
    assert clean["warnings"] == []
    assert stored_line(b, clean["seq"])["warnings"] in ([], None)


@check
def a_caller_cannot_write_its_own_warnings_into_the_log(b):
    # Server-stamped, exactly like seq and unix: a warning is the BOARD's
    # observation, and a log that accepted an agent's own account of who
    # warned it would be worthless as the evidence it is being built to be.
    _, resp = post("liar", kind="status", text="nothing to see",
                   files=["src/quiet.odin"],
                   warnings=[{"kind": "claim_conflict", "file": "src/quiet.odin",
                              "by": "somebody-else", "source": "status",
                              "text": "invented"}])
    assert resp["warnings"] == [], resp
    assert stored_line(b, resp["seq"])["warnings"] in ([], None)


@check
def warnings_survive_a_restart_and_reach_brief_readers_too(b):
    # board.jsonl is replayed verbatim, so this is really a check that the
    # field round-trips through marshal/unmarshal - and that brief responses
    # did not quietly lose it, which is the standing drift between Message and
    # Brief_Message that the two structs are spelled out separately to keep loud.
    _, r = task("draft", "planner", text="held", files=["src/replay.odin"])
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "holder", id=tid)
    _, resp = post("intruder", kind="status", text="editing",
                   files=["src/replay.odin"])
    seq = resp["seq"]
    assert resp["warnings"]

    b.restart()
    _, d = call(f"/delta?since={seq - 1}")
    full = [m for m in d["messages"] if m["seq"] == seq][0]
    assert full["warnings"] == resp["warnings"], full

    _, db = call(f"/delta?since={seq - 1}&brief=40")
    brief = [m for m in db["messages"] if m["seq"] == seq][0]
    assert brief["warnings"] == resp["warnings"], \
        "a brief reader must not silently lose the field"


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


# THE SOURCE IS NOT THE ONLY THING THAT WRITES RUNTIME FILES (task #62).
#
# The scan above derives from main.odin, so it is structurally blind to files
# the TOOLING creates: run.ps1 redirects the service and the sidecar into four
# .log files that main.odin has never heard of. Those happen to be covered by
# the blanket `*.log` rule today - which is luck holding a gap shut, and the
# gap is the same one that was found three times in main.odin. A new
# `-RedirectStandardOutput ... 'sidecar.state.json'` would be ignored by
# nothing and committed by the next person.
#
# Quoted literals, because that is how PowerShell names a path - and it is
# deliberately the same shape of derivation, matched on VALUE, so there is
# still no hand-kept list anywhere.
PS_RUNTIME_MIN = 2   # its own floor: a regex that stops matching must not pass
PS_RUNTIME_RE = re.compile(
    r"""['"]([A-Za-z0-9_.-]+\.(?:jsonl|log|json|dat))['"]""")


def ps_runtime_files(src=None):
    if src is None:
        src = open(os.path.join(HERE, "run.ps1"), encoding="utf-8").read()
    return set(PS_RUNTIME_RE.findall(src))


# CANNOT-TELL IS NOT NOT-IGNORED (task #70).
#
# git check-ignore answers with three different exit codes and the check below
# used to read only two of them:
#
#   0    ignored - there is a rule
#   1    NOT ignored - there is no rule, which is the finding
#   128  it could not answer at all - not a git repository, bad pathspec
#
# Testing `returncode != 0` folds 128 into 1, so a suite run from a tree copied
# outside git reported a specific, alarming, false thing: that named files are
# missing ignore rules. It bit f227 live during #58's variant run (seq 1203);
# they diagnosed it by running the control on an unmodified copy, which is the
# expensive way to learn your instrument was lying.
#
# The defect is the exact inverse of the rule 43f9612 put into /build twenty
# lines from here - a checker that cannot see must SAY it cannot see, never
# guess in the alarming direction. It survived because it can only be wrong
# outside a git repository, and nobody had run it there until someone did.
#
# The reason comes from git's own stderr rather than a string we compose, so
# the message stays true for the 128s nobody has met yet.
def ignore_status(name, root):
    """('ignored' | 'unignored' | 'unverifiable', detail) for one runtime file."""
    r = subprocess.run(["git", "check-ignore", "-q",
                        os.path.join("message_board", name)],
                       cwd=root, capture_output=True, text=True)
    if r.returncode == 0:
        return "ignored", ""
    if r.returncode == 1:
        return "unignored", ""
    return "unverifiable", (r.stderr.strip() or f"git exited {r.returncode}")


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


# -- checks: the sidecar can say what code IT runs (task #62) --------------


@check
def a_never_reported_sidecar_is_neither_match_nor_mismatch(b):
    # UNKNOWN IS NOT STALE. This workdir has no herdr_sync.py beside it and no
    # sidecar has ever posted, so both sides are unknown - and the honest
    # answer is "cannot tell", not an alarm. A checker that cries wolf against
    # its own fixture is one that gets waved through when it is finally right,
    # which is the failure the unstamped build stamp exists to avoid.
    sc = call("/build")[1]["sidecar"]
    assert sc["reported"] == "unreported", sc
    assert sc["disk"] == "absent", sc
    assert sc["stale"] is False, sc


@check
def a_wrong_sidecar_hash_reads_stale_and_the_real_one_does_not(b):
    # THE CROSS-LANGUAGE LEG, and the one worth the most: Python hashes the
    # file, Odin hashes the file, and nothing here assumes they agree - a
    # disagreement over line endings or encoding would make every honest
    # sidecar look permanently stale, which is indistinguishable from the
    # feature working until someone checks the bytes.
    call("/herdr_state?src=deadbeef", [])
    sc = call("/build")[1]["sidecar"]
    assert sc["reported"] == "deadbeef" and sc["disk"] == "absent", sc
    assert sc["stale"] is False, ("one side unknown is still not stale", sc)

    shutil.copy(os.path.join(HERE, "herdr_sync.py"), b.workdir)
    sc = call("/build")[1]["sidecar"]
    assert sc["disk"] != "absent", ("the file is beside the board now", sc)
    assert sc["stale"] is True, ("both known and different IS stale", sc)

    real = hashlib.sha256(
        open(os.path.join(b.workdir, "herdr_sync.py"), "rb").read()).hexdigest()
    call(f"/herdr_state?src={real}", [])
    sc = call("/build")[1]["sidecar"]
    assert sc["disk"] == real, (
        "Odin and Python disagree on the sha256 of one identical file", sc, real)
    assert sc["stale"] is False, sc


@check
def a_sidecar_that_cannot_report_does_not_erase_what_is_known(b):
    # An old sidecar sends no param at all. That must read as "no new
    # information", never as "the version is now empty" - otherwise upgrading
    # the board before the sidecar would silently blank a true answer.
    shutil.copy(os.path.join(HERE, "herdr_sync.py"), b.workdir)
    real = hashlib.sha256(
        open(os.path.join(b.workdir, "herdr_sync.py"), "rb").read()).hexdigest()
    call(f"/herdr_state?src={real}", [])
    call("/herdr_state", [])                      # the old-sidecar shape
    assert call("/build")[1]["sidecar"]["reported"] == real


@check
def the_sidecar_report_did_not_change_the_wire_shape(b):
    # The version rides as a QUERY PARAM precisely so the body stays the bare
    # array every existing caller sends and /herdr returns. A fix for a
    # version-visibility hazard that changed the wire shape would break the
    # pairing it exists to make legible.
    call("/herdr_state?src=abc123", [{"name": "x", "status": "working"}])
    assert isinstance(call("/herdr")[1], list)
    assert call("/herdr")[1][0]["name"] == "x"


@check
def the_sidecar_arms_its_watch_at_the_tip_not_at_the_first_page(b):
    # The cap (98bbb86) made `since=0` return the head of the FIRST PAGE, and
    # two start-at-head callers were seeded from it. For the SIDECAR the cost
    # is a BLIND WINDOW, not false alarms - a restarted sidecar spends ~11
    # polls (~2.75 min) walking days-old traffic and is not watching for real
    # spawns while it does. The spurious-warning story that got this noticed
    # was disproved by simulation before it was believed (seq 1170): zero
    # warnings over the real log, because the sweep needs a launch and its
    # cancel in different pages and this log cancels within 9 seqs of 100.
    # That race is latent, not retired - a spawn storm would arrange it.
    #
    # Folded into #62 because #62's own deploy step restarts the sidecar,
    # which is precisely when this fires.
    import importlib
    import herdr_sync as hs
    importlib.reload(hs)

    # The unit: tip wins, and a board too old to send one still works.
    assert hs.head_cursor({"latest": 100, "tip": 1167}) == 1167
    assert hs.head_cursor({"latest": 43}) == 43, "pre-cap board must still arm"

    # The integration, against a board with more history than one page.
    for i in range(105):
        post("filler", text=f"m{i}")
    seeded = hs.head_cursor(call("/delta?since=0&limit=0")[1])
    tip = call("/delta?since=0&limit=0")[1]["tip"]
    assert seeded == tip, (seeded, tip)
    assert call(f"/delta?since={seeded}")[1]["count"] == 0, (
        "an armed watch must see nothing yet - that is what 'at the head' is")

    # And the bug itself, so this check knows what it is preventing.
    assert call("/delta?since=0")[1]["latest"] < tip, (
        "a bare since=0 no longer reports the tip - if that ever changes, "
        "this whole check is testing a hazard that no longer exists")


# ── checks: one source for the announcement prefixes (task #62) ─────────────
#
# The watchdog in herdr_sync.py recognises launches and closes by matching the
# board's announcement text. Two files, one string, and no compiler that can
# see both: reword main.odin's emitter and the watcher silently stops matching
# - it does not crash, it just never warns again, which is the quietest
# possible failure for a thing whose whole job is noticing silence.
PREFIX_RE = re.compile(r'^(LAUNCH_PREFIX|CLOSE_PREFIX)\s*=\s*"([^"]*)"', re.M)


def announce_prefixes(src=None):
    if src is None:
        src = open(os.path.join(HERE, "herdr_sync.py"), encoding="utf-8").read()
    return dict(PREFIX_RE.findall(src))


def emitters_matching(prefixes, src=None):
    """Which prefixes main.odin actually emits, matched on VALUE."""
    if src is None:
        src = open(os.path.join(HERE, "main.odin"), encoding="utf-8").read()
    return {name for name, value in prefixes.items()
            if f'fmt.tprintf("{value}' in src}


@check
def the_announcement_prefixes_have_one_source_not_two(b):
    prefixes = announce_prefixes()
    assert set(prefixes) == {"LAUNCH_PREFIX", "CLOSE_PREFIX"}, (
        "the derivation stopped seeing herdr_sync.py's prefixes", prefixes)
    matched = emitters_matching(prefixes)
    missing = sorted(set(prefixes) - matched)
    assert not missing, (
        f"herdr_sync.py watches for {[prefixes[m] for m in missing]} but "
        "main.odin emits no announcement starting with it - the watcher is "
        "matching text nothing sends")


@check
def rewording_either_side_of_the_announcement_turns_this_red(b):
    # A derivation is only worth having if it can FAIL. Both directions, on
    # COPIES - nothing real is modified.
    odin = open(os.path.join(HERE, "main.odin"), encoding="utf-8").read()
    py = open(os.path.join(HERE, "herdr_sync.py"), encoding="utf-8").read()
    prefixes = announce_prefixes(py)

    # (a) main.odin reworded alone
    for value in prefixes.values():
        broken = odin.replace(f'fmt.tprintf("{value}', 'fmt.tprintf("REWORDED ')
        assert emitters_matching(prefixes, broken) != set(prefixes), (
            f"main.odin stopped emitting {value!r} and the check stayed green")

    # (b) herdr_sync.py reworded alone
    for name, value in prefixes.items():
        broken_py = py.replace(f'{name} = "{value}"', f'{name} = "reworded "')
        assert emitters_matching(announce_prefixes(broken_py), odin) != {
            "LAUNCH_PREFIX", "CLOSE_PREFIX"}, (
            f"{name} was reworded and the check stayed green")


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
    # run.ps1's redirects are runtime files too, and no derivation over
    # main.odin can ever see them. Its own floor, so one scan silently
    # breaking cannot be covered by the other one still finding things.
    from_ps = ps_runtime_files()
    assert len(from_ps) >= PS_RUNTIME_MIN, (
        f"only found {sorted(from_ps)} in run.ps1 - that scan has drifted, "
        "and a scan that finds nothing must never pass")
    missing, unverifiable = [], []
    for name in sorted(declared | from_ps):
        state, detail = ignore_status(name, ROOT)
        if state == "unignored":
            missing.append(name)
        elif state == "unverifiable":
            unverifiable.append(detail)
    # ASSERTED FIRST, so the true cause wins over a list of innocent files.
    #
    # THE ORDER IS LOAD-BEARING FOR A MIXED RUN, NOT FOR THE OUTSIDE-GIT CASE.
    # The first version of this comment claimed the opposite - that reversing
    # these two would restore the misleading finding - and that was a testable
    # claim nobody had tested, sealed inside the check whose entire bug was
    # asserting something it never distinguished. Caught in review (seq 1220)
    # by someone who swapped the lines and ran it.
    #
    # MEASURED, outside a repository: the order makes no difference at all.
    # Every file comes back unverifiable, so `missing` is empty and its assert
    # cannot fire whichever line it sits on. Swapped, it still says "cannot
    # verify".
    #
    # WHERE IT ACTUALLY BITES is a MIXED result inside a real repository, both
    # lists non-empty - and that is reachable rather than hypothetical, which
    # is why the ordering stays. DECLARED_RE captures [^"]+, which admits a
    # path separator, so a declared constant carrying a subpath yields a
    # pathspec git refuses (`message_board/../../x.log` -> 128) while its
    # siblings answer a clean 1. Then this order is the difference between
    # being told the cause and being handed a list of innocent files.
    # the_ignore_check_reports_the_cause_before_the_symptom pins it.
    assert not unverifiable, (
        "cannot verify ignore rules - git could not answer: "
        f"{unverifiable[0]}. This says nothing about any runtime file; run the "
        "suite from a git checkout (a worktree counts, a plain directory copy "
        "does not)")
    assert not missing, (
        f"main.odin or run.ps1 writes {missing} but message_board/.gitignore "
        "does not cover them - add a rule, or they land in the next commit")


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


@check
def the_ignore_check_can_tell_no_rule_from_no_repository(b):
    # BOTH DIRECTIONS, because a check that stops crying wolf by never barking
    # is not a fix. Everything here runs against a THROWAWAY repository built
    # in a temp dir - the real tree's .gitignore is never touched, so "the rule
    # is genuinely absent" is a fact about this fixture rather than a hazardous
    # edit to the checkout the suite is running from.
    fixture = tempfile.mkdtemp(prefix="ignorechk_")
    try:
        os.makedirs(os.path.join(fixture, "message_board"))
        subprocess.run(["git", "init", "-q"], cwd=fixture,
                       capture_output=True, check=True)
        # A rule for .log and deliberately NONE for .jsonl.
        with open(os.path.join(fixture, "message_board", ".gitignore"), "w",
                  encoding="utf-8") as f:
            f.write("*.log\n")

        # (a) the rule is there
        assert ignore_status("access.log", fixture)[0] == "ignored"

        # (b) THE RULE IS GENUINELY ABSENT - this must still go red, and it is
        # the half a lazy fix would break by treating everything as unknown.
        state, _ = ignore_status("board.jsonl", fixture)
        assert state == "unignored", (
            "a runtime file with no ignore rule must still be a finding", state)

        # (c) NOT A REPOSITORY AT ALL - the case that used to masquerade as (b).
        outside = tempfile.mkdtemp(prefix="norepo_")
        try:
            state, detail = ignore_status("board.jsonl", outside)
            assert state == "unverifiable", (
                "a tree outside git must be unverifiable, not a finding about "
                "board.jsonl", state)
            assert "not a git repository" in detail.lower(), (
                "the reason must name what git actually said", detail)
        finally:
            shutil.rmtree(outside, ignore_errors=True)
    finally:
        shutil.rmtree(fixture, ignore_errors=True)


@check
def the_ignore_check_reports_the_cause_before_the_symptom(b):
    # THE MIXED RUN the comment above rests on, tested rather than argued. The
    # first draft of that comment justified this ordering with a claim that was
    # false and unrun; replacing it with a true claim that is also unrun would
    # be the same defect with better wording.
    #
    # Drives the REAL check - shipped assertion order, no refactor of the loop -
    # by pointing its two derivations and ROOT at a throwaway repository.
    me = sys.modules[__name__]
    fixture = tempfile.mkdtemp(prefix="mixedchk_")
    saved = (me.ROOT, me.runtime_files, me.ps_runtime_files)
    try:
        os.makedirs(os.path.join(fixture, "message_board"))
        subprocess.run(["git", "init", "-q"], cwd=fixture,
                       capture_output=True, check=True)
        with open(os.path.join(fixture, "message_board", ".gitignore"), "w",
                  encoding="utf-8") as f:
            f.write("*.log\n")
        me.ROOT = fixture
        # BOTH LISTS NON-EMPTY, which is the only situation where the order can
        # decide anything: one name git refuses to answer for, one with a
        # genuinely absent rule, and enough covered siblings to clear the floor.
        me.runtime_files = lambda src=None: {
            "../../escape.log",                    # 128 - git will not answer
            "board.jsonl",                         # 1   - no rule for .jsonl
            "a.log", "b.log", "c.log", "d.log",    # 0   - covered by *.log
        }
        me.ps_runtime_files = lambda src=None: {"service.log", "sidecar.log"}

        failed = None
        try:
            me.every_runtime_file_the_source_declares_is_gitignored(b)
        except AssertionError as e:
            failed = str(e)
        assert failed is not None, "a mixed fixture must not pass the check"
        assert "could not answer" in failed, (
            "the cause must lead when both lists are non-empty", failed)
        assert "board.jsonl" not in failed, (
            "the symptom led: a file was named as missing a rule while a "
            "sibling could not even be asked about", failed)
    finally:
        me.ROOT, me.runtime_files, me.ps_runtime_files = saved
        shutil.rmtree(fixture, ignore_errors=True)


@check
def the_run_script_scan_actually_catches_a_new_redirect(b):
    # Same standard as the main.odin scan above: a derivation nobody has seen
    # fail is a derivation nobody knows works. Against a COPY of run.ps1.
    src = open(os.path.join(HERE, "run.ps1"), encoding="utf-8").read()
    base = ps_runtime_files(src)
    assert "service.log" in base and "sidecar.log" in base, (
        "the four redirects run.ps1 already writes must be visible", sorted(base))

    # Both quoting styles, and a name that looks nothing like the existing
    # ones - the point is to catch the redirect somebody adds next year.
    for fake in ("""-RedirectStandardOutput (Join-Path $here 'watchdog.state.json')""",
                 '''$p = Join-Path $here "spawn_audit.jsonl"''',
                 """$x = 'herdr.dat'"""):
        added = ps_runtime_files(src + "\n" + fake) - base
        assert added, f"a new run.ps1 runtime file escaped the scan: {fake}"


# ── checks: strict request parsing (task #51) ───────────────────────────────
#
# json.unmarshal DROPS undeclared keys, so a one-character typo was not a bad
# request - it was an ABSENT field plus ignored noise, and absent means "the
# optional thing you did not ask for". Every one of these three was run for
# real against a throwaway board and returned 200 before the fix; they are
# here so that can never quietly become true again.
#
# Each names ITS OWN KEY. A leg asserting only "st == 400" would pass on any
# refusal at all - including the unrelated ones these endpoints already have,
# which is exactly how /spawn's role-file 400 could impersonate this one.


@check
def a_misspelled_text_field_is_refused_not_posted_empty(b):
    # PROBE 1: {"txet": ...} posted a message with EMPTY text and said 200.
    before = len(call("/delta?since=0")[1]["messages"])
    st, r = call("/post", {"agent": "typo-1", "kind": "msg", "txet": "the real text"})
    assert st == 400, (st, r)
    assert "txet" in r["error"], r
    assert r["unknown"] == ["txet"], r
    after = call("/delta?since=0")[1]["messages"]
    assert len(after) == before, ("a refused post must leave nothing behind",
                                  [m["text"] for m in after[before:]])


@check
def a_misspelled_force_on_spawn_is_refused_not_inverted(b):
    # PROBE 2: {"forse": true} on a HELD topic returned 200 reused - the
    # override did the OPPOSITE of what was asked, on a process launcher.
    #
    # The discriminator matters: without force this call reuses (200), with
    # real force it reaches the launcher and dies on the bad role (400). So a
    # bare 400 would be ambiguous - the leg reads the ERROR, not the code.
    call("/herdr_state", [{"name": "claude-inverted-7777", "tab": "a:3"}])
    assert spawn_probe("inverted")[0] == 200, "sanity: it reuses without force"
    st, r = spawn_probe("inverted", forse=True)
    assert st == 400, ("a typo must not be read as absent", st, r)
    assert "forse" in r["error"], ("refused for the wrong reason", r)
    assert r["unknown"] == ["forse"], r


@check
def a_misspelled_result_seq_never_submits_without_an_audit_link(b):
    # PROBE 3, THE WORST: {"reslut_seq": ...} moved a task to Review with NO
    # result_seq recorded, skipping every validation #23 and #37 exist to
    # enforce - the audit link the whole workflow rests on, silently absent.
    _, r = task("draft", "planner", text="strict-parse subject",
                accept="must submit with a real link")
    tid = r["id"]
    task("ready", "planner", id=tid)
    task("claim", "worker", id=tid)
    seq = post("worker", text="completion write-up", task_id=tid)[1]["seq"]

    st, r = task("submit", "worker", id=tid, rev=tasks()[tid]["rev"],
                 reslut_seq=seq)
    assert st == 400, (st, r)
    assert "reslut_seq" in r["error"], r
    assert r["unknown"] == ["reslut_seq"], r
    assert tasks()[tid]["state"] == "Doing", (
        "the typo submitted anyway", tasks()[tid])

    # ...and the correctly spelled field still works, so this tightened the
    # typo and nothing else.
    st, r = task("submit", "worker", id=tid, rev=tasks()[tid]["rev"],
                 result_seq=seq)
    assert st == 200, (st, r)
    assert tasks()[tid]["result_seq"] == seq, tasks()[tid]


@check
def every_unknown_key_is_named_verbatim_not_just_the_first(b):
    # "Name every unknown key" is the contract, and it is the useful part: a
    # caller who misspelled two fields fixes one and gets refused again.
    st, r = call("/post", {"agent": "typo-2", "kind": "msg", "text": "x",
                           "zebra": 1, "alpha": 2})
    assert st == 400, (st, r)
    assert r["unknown"] == ["alpha", "zebra"], ("sorted, and all of them", r)
    assert "alpha" in r["error"] and "zebra" in r["error"], r


@check
def a_key_the_endpoint_declares_but_a_typo_of_it_does_not(b):
    # The rule is "a key unmarshal would USE", not "a key that looks familiar".
    # `to` is declared; `too` is one keystroke away and means nothing.
    assert post("addressed", kind="request", text="q", to="somebody")[0] == 200
    st, r = call("/post", {"agent": "addressed", "kind": "request",
                           "text": "q", "too": "somebody"})
    assert st == 400 and r["unknown"] == ["too"], (st, r)


@check
def register_and_kill_refuse_an_unknown_key_too(b):
    # The contract names FIVE JSON POSTs. Three earned a leg by being probed
    # for real; these two are the ones nobody has typo'd yet, and a helper
    # wired to four of five endpoints is precisely the gap this task exists
    # to close - so they are asserted rather than assumed.
    #
    # Both already 400 on a missing required field, so the STATUS CODE alone
    # proves nothing here: only `unknown` distinguishes "refused because the
    # key was dropped" from "refused because the field it fed was absent".
    st, r = call("/register", {"agent": "reg-1", "role": "implementer",
                               "modle": "opus"})
    assert st == 400 and r["unknown"] == ["modle"], (st, r)
    known = {x["agent"] for x in call("/agents")[1]}
    assert "reg-1" not in known, ("a refused register must leave no identity",
                                  known)

    call("/herdr_state", [{"name": "claude-target-1234", "tab": "a:5"}])
    st, r = call("/kill", {"nmae": "claude-target-1234"})
    assert st == 400 and r["unknown"] == ["nmae"], (st, r)


@check
def strictness_did_not_tighten_anything_else_on_any_endpoint(b):
    # THE RISK THE CONTRACT NAMED, one leg per JSON POST: unknown keys are the
    # ONLY new rejection. Absent optional fields still mean what they meant,
    # so no legitimate caller changes.
    #
    # /spawn and /kill are read through a refusal that lies BEYOND the strict
    # gate - the missing role file, the unknown pane - because their success
    # paths launch and close real processes. Reaching the far refusal is the
    # proof the gate passed.
    assert post("plain", kind="status", text="minimal, no optional fields")[0] == 200
    assert post("full", kind="msg", text="every field", files=["a.odin"],
                to="plain", reply_to=0, route="direct", task_id=0,
                accepts=0)[0] == 200

    st, r = task("add", "plain", text="ordinary task")
    assert st == 200, (st, r)

    st, r = call("/register", {"agent": "plain", "role": "implementer",
                               "model": "opus", "capabilities": ["odin"]})
    assert st == 200, (st, r)

    call("/herdr_state", [{"name": "claude-somebody-8888", "tab": "a:4"}])
    st, r = spawn_probe("unheld")
    assert st == 400 and "role" in r["error"], (
        "a valid spawn must reach the launcher path, not the strict gate", st, r)

    st, r = call("/kill", {"name": "claude-nobody-9999"})
    assert st == 404, ("a valid kill must reach the roster lookup", st, r)


@check
def a_body_that_is_not_an_object_still_reports_what_it_always_did(b):
    # The strict check DEFERS on anything it cannot diff, so the existing
    # errors keep their wording. A check that answered first would have
    # silently rewritten every malformed-body message on the board.
    st, r = call("/post", [1, 2, 3])
    assert st == 400 and "unknown" not in r, (st, r)
    st, r = call("/task", "not json at all")
    assert st == 400 and "unknown" not in r, (st, r)


# ── checks: the refusal carries the answer (task #59) ───────────────────────
#
# #51 made a typo loud. It still sent the caller to the README to find out what
# they SHOULD have written - and the coordinator, the most motivated reader on
# the board, was caught four times by the same key, the last twice AFTER
# diagnosing it and writing up the incident. Habit beats documentation. So the
# 400 now carries the settable field set, and the list has to be TRUE: a field
# the server overwrites must not appear on it, and a field kept off it must not
# be honoured. Both directions get a leg.

# The exact settable set per endpoint. Pinned rather than derived: a golden
# list is only worth having if adding a field FORCES an edit here, in the same
# diff, where a reviewer sees the decision. Derive it from the struct and this
# leg would ratify whatever the struct happened to say.
GOLDEN_SETTABLE = {
    "/post":     ["agent", "kind", "text", "files", "to", "reply_to",
                  "route", "task_id", "accepts"],
    # `assignee` joins this list rather than being tagged server-owned,
    # because a caller genuinely may set it - on `assign`, and nowhere else.
    # This edit is the forced decision point working: the field could not be
    # added without someone changing this line and a reviewer seeing it.
    "/task":     ["id", "action", "agent", "text", "rev", "files", "accept",
                  "plan_id", "plan_rev", "plan_seq", "lease_secs",
                  "result_seq", "by_id", "blocked_on", "assignee"],
    "/spawn":    ["name", "prompt", "model", "role", "force"],
    "/register": ["agent", "role", "model", "capabilities"],
    "/kill":     ["name"],
}


@check
def every_endpoint_advertises_exactly_its_settable_fields(b):
    # THE DANGEROUS DIRECTION IS A NEW SERVER-STAMPED FIELD LEFT UNTAGGED: it
    # joins the advertised list and the board starts promising callers they may
    # set something it will overwrite. That cannot land quietly - it goes red
    # here and the author must edit this dict in the same diff.
    #
    # The soft direction (a settable field wrongly tagged server) also goes red
    # here, but would fail QUIET if this leg did not exist: it costs only an
    # omission from an advisory list, and the field's own feature legs still
    # pass because sending it still works. Stated, not hidden.
    probes = {
        "/post":     {"agent": "a", "kind": "msg", "zzz_unknown": 1},
        "/task":     {"action": "note", "agent": "a", "id": 1, "zzz_unknown": 1},
        "/spawn":    {"name": "x", "prompt": "y", "zzz_unknown": 1},
        "/register": {"agent": "a", "zzz_unknown": 1},
        "/kill":     {"name": "x", "zzz_unknown": 1},
    }
    for path, body in probes.items():
        st, r = call(path, body)
        assert st == 400, (path, st, r)
        assert r["settable"] == GOLDEN_SETTABLE[path], (
            path, "settable drifted from the golden list", r.get("settable"))
        # Server-stamped fields are declared on these structs and MUST NOT be
        # advertised - that is the whole difference between `declared` and
        # `settable`, and advertising `unix` would be the false promise this
        # list exists to end, reintroduced by the fix for it.
        assert "unix" not in r["settable"], (path, r["settable"])
    assert "seq" not in call("/post", {"agent": "a", "zzz": 1})[1]["settable"]
    assert "expired_from" not in call(
        "/task", {"action": "note", "agent": "a", "id": 1, "zzz": 1})[1]["settable"]


@check
def the_measured_trap_answers_itself_without_the_readme(b):
    # THE PROBE THAT EARNED THIS TASK: `status` on /task, sent four times by
    # one caller who understood the mistake by the third. It is not a typo - it
    # is the GET /tasks response shape mirrored into a POST, so the refusal has
    # to teach both halves: what to write instead, and why they thought it was
    # right.
    st, r = call("/task", {"action": "note", "agent": "a", "id": 1,
                           "status": "open"})
    assert st == 400, (st, r)
    assert r["unknown"] == ["status"], r
    assert "status" not in r["settable"], r
    assert r["settable"] == GOLDEN_SETTABLE["/task"], r
    # ...and the sentence names the mirror trap, not just the absence.
    assert "task record" in r["error"] and "output, never input" in r["error"], r


@check
def an_ordinary_typo_is_not_given_the_mirror_explanation(b):
    # The record clause must fire only where it APPLIES. A refusal that tells
    # every caller they mirrored the response would be noise, and worse, it
    # would be wrong for the case #51 was built on.
    st, r = call("/task", {"action": "note", "agent": "a", "id": 1,
                           "reslut_seq": 1})
    assert st == 400 and r["unknown"] == ["reslut_seq"], (st, r)
    assert "task record" not in r["error"], (
        "reslut_seq is a typo, not a mirrored record field", r["error"])
    assert r["settable"] == GOLDEN_SETTABLE["/task"], r


@check
def a_quoted_key_still_returns_parseable_json_carrying_settable(b):
    # #48's hazard, extended to the new key. These strings are untrusted input
    # going back out inside JSON; the whole body rides json.marshal rather than
    # being interpolated, so a key containing a double quote cannot turn the
    # explanation into a parse error the caller sees instead of it.
    st, r = call("/post", {"agent": "a", 'we"ird': 1})
    assert st == 400, (st, r)
    assert r["unknown"] == ['we"ird'], r          # parsed, so the body was valid JSON
    assert r["settable"] == GOLDEN_SETTABLE["/post"], r


@check
def a_non_takeover_verb_cannot_forge_a_takeover_marker(b):
    # THE HIGHEST-SEVERITY ITEM IN THIS LANE, and the only one that stops a
    # false WRITE rather than a misleading read.
    #
    # expired_from is server-written on exactly one path - a claim that takes
    # over a Doing task whose lease has provably expired. On every other verb
    # nothing touched it, so a caller-sent value rode through task_post into
    # tasks.jsonl, a log that is APPEND-ONLY AND NEVER REWRITTEN. A `note`
    # could stamp a takeover that never happened, naming an owner who never
    # held it, and the record would carry it forever.
    #
    # Note what is asserted: the verb still SUCCEEDS. The request is
    # legitimate; only the field is neutralised.
    _, r = task("add", "planner", text="the subject")
    tid = r["id"]
    st, _ = task("note", "attacker", id=tid, text="innocuous",
                 expired_from="victim")
    assert st == 200, ("the verb is legitimate - only the field is not", st)

    log = os.path.join(b.workdir, "tasks.jsonl")
    events = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
    forged = [e for e in events if e.get("id") == tid
              and e.get("action") == "note" and e.get("expired_from")]
    assert not forged, ("a note stamped a takeover into the immutable log",
                        forged)

    # The same on a CLAIM that is not a takeover - the path the field belongs
    # to, exercised in the case where it must still stay empty.
    task("claim", "worker", id=tid, expired_from="victim")
    events = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
    claims = [e for e in events if e.get("id") == tid
              and e.get("action") == "claim"]
    assert claims and not claims[-1]["expired_from"], (
        "a first claim is not a takeover and must record nobody", claims[-1])

# LEG (e) - "the takeover path still records expired_from" - is NOT written
# here, deliberately. an_expired_lease_is_claimable_and_the_takeover_is_recorded
# already asserts exactly that, has since before this lane existed, and a
# duplicate would be a second copy of one claim that can drift from it. What
# this lane owes it is a SABOTAGE: move the intake clear below the verb switch
# and that inherited leg fails, which is how we know the clear did not silently
# break the audit trail it was added to protect.


# ── checks: assignment is not ownership (task #60) ──────────────────────────
#
# `owner` answered "who holds this", so unclaimed and unassigned were the same
# value and "spoken for" could not be written down at all. The hazard arms at
# Ready, where work is claimable by anyone and an intention about who should
# take it is most likely to exist and least likely to be recorded.
#
# The design choice these legs exist to hold: REFUSAL, NOT WARNING. A
# warn-and-proceed claim produces the collision the field exists to prevent -
# the lease started and the agent is already working by the time anyone reads
# the warning.


@check
def a_task_can_record_who_it_is_for_in_every_pre_claim_state(b):
    _, r = task("add", "planner", text="for someone")
    tid = r["id"]
    # ANYONE may assign - it is not an ACL. The openness is what cures a stale
    # assignment in one recorded call instead of needing a TTL.
    assert task("assign", "a-stranger", id=tid, assignee="opus")[0] == 200
    assert tasks()[tid]["assignee"] == "opus"

    _, r2 = task("draft", "planner", text="a draft")
    did = r2["id"]
    assert task("assign", "planner", id=did, assignee="opus")[0] == 200
    assert tasks()[did]["assignee"] == "opus", "Draft is a pre-claim state"

    task("block", "planner", id=tid)
    assert tasks()[tid]["state"] == "Blocked"
    assert task("assign", "someone-else", id=tid, assignee="sonnet")[0] == 200
    assert tasks()[tid]["assignee"] == "sonnet", "Blocked is a pre-claim state"

    # Rev-gated like ready/amend/rework: acting on a description you have not
    # read is refused here too.
    st, _ = task("assign", "planner", id=tid, assignee="haiku", rev=99)
    assert st == 409, "assign must be rev-gated"
    assert tasks()[tid]["assignee"] == "sonnet"


@check
def a_claim_by_anyone_but_the_assignee_is_refused_and_names_the_cure(b):
    _, r = task("add", "planner", text="spoken for")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="opus")
    before = tasks()[tid]

    st, err = task("claim", "interloper", id=tid)
    assert st == 409, (st, err)
    # Its OWN key, not prose a caller has to parse out of a sentence.
    assert err["assignee"] == "opus", err
    # The refusal teaches the takeover instead of forbidding it.
    assert "assign" in err["error"], err

    # NOTHING HAPPENED, which is the half that separates a refusal from a
    # warning. A 409 that still starts the lease is warn-and-proceed wearing
    # a status code.
    after = tasks()[tid]
    assert after["state"] == "Ready" and after["owner"] == "", after
    assert after["lease_until"] == 0, after
    assert after["attempts"] == before["attempts"], (before, after)


@check
def the_assignee_claims_it_and_the_assignment_is_spent(b):
    _, r = task("add", "planner", text="mine to take")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="opus")
    assert task("claim", "opus", id=tid)[0] == 200
    t = tasks()[tid]
    assert t["owner"] == "opus" and t["state"] == "Doing", t
    assert t["assignee"] == "", "assignment must not outlive the claim it caused"


@check
def a_claim_cannot_smuggle_an_assignee_past_its_own_refusal(b):
    # Seq 985's class. `assignee` IS a declared field, so the structural key
    # guard passes it on every verb - correctly, by its own rule. Only the
    # intake clear stops a claimant writing themselves the permission that is
    # checked one line later.
    _, r = task("add", "planner", text="guarded")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="opus")
    st, err = task("claim", "interloper", id=tid, assignee="interloper")
    assert st == 409 and err["assignee"] == "opus", (st, err)
    assert tasks()[tid]["assignee"] == "opus", "the smuggled value was honoured"


@check
def no_verb_but_assign_records_an_assignee_it_arrives_carrying(b):
    # A LOOP, NOT A CLAIM-ONLY CASE. ready/amend/note/block are the ones
    # nobody would think to send, and that is exactly what made seq 985 a
    # class rather than a single bug.
    #
    # AND IT READS THE LOG, NOT GET /tasks - which is the lesson this leg
    # carries. task_apply writes t.assignee only under `case "assign"`, so
    # the PROJECTION is safe whether the intake clear exists or not: a note
    # carrying an assignee changes nothing anybody can GET. The damage is in
    # tasks.jsonl, which is APPEND-ONLY AND NEVER REWRITTEN - a note would
    # record an assignment that was never made, permanently.
    #
    # The first version of this leg asserted only on /tasks and PASSED with
    # the intake clear deleted. Found by deleting it, not by reading it, and
    # that is why the assertion moved to the log.
    log = os.path.join(b.workdir, "tasks.jsonl")
    verbs = [("ready", {}), ("amend", {"text": "amended"}), ("note", {"text": "n"}),
             ("block", {}), ("unblock", {}), ("renew", {}), ("release", {}),
             ("submit", {}), ("approve", {}), ("rework", {}), ("done", {}),
             ("reopen", {})]
    for verb, extra in verbs:
        _, r = task("draft", "planner", text=f"carrier for {verb}")
        tid = r["id"]
        task("assign", "planner", id=tid, assignee="rightful")
        task(verb, "planner", id=tid, assignee="hijacker", **extra)

        events = [json.loads(l) for l in open(log, encoding="utf-8") if l.strip()]
        forged = [e for e in events if e.get("id") == tid
                  and e.get("action") == verb and e.get("assignee")]
        assert not forged, (verb, "recorded an assignee into the immutable log",
                            forged)
        # And the projection, which is the cheaper half of the same claim.
        got = tasks()[tid]["assignee"]
        assert got != "hijacker", (verb, got, tasks()[tid])


@check
def an_assignment_survives_a_board_restart(b):
    # THE BOARD IS A REPLAY of tasks.jsonl and task_apply is the fold. An
    # assign implemented in the handler instead of the fold passes every
    # other leg in this section and then vanishes on the next boot - which is
    # precisely what happened to plan_id/plan_seq, per the note in task_apply
    # reading "the event log was right the whole time; only this projection
    # was wrong". Proven by restarting, not by reading the handler.
    _, r = task("add", "planner", text="durable")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="opus")
    assert tasks()[tid]["assignee"] == "opus"
    b.restart()
    assert tasks()[tid]["assignee"] == "opus", "the fold does not project assignee"


@check
def an_assignment_clears_on_assign_to_empty_and_on_supersede(b):
    _, r = task("add", "planner", text="clearable")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="opus")
    assert task("assign", "planner", id=tid, assignee="")[0] == 200
    assert tasks()[tid]["assignee"] == "", "assign-to-empty must clear"

    # Whitespace is a clear, not an assignment to a name made of spaces.
    task("assign", "planner", id=tid, assignee="opus")
    task("assign", "planner", id=tid, assignee="   ")
    assert tasks()[tid]["assignee"] == ""

    task("assign", "planner", id=tid, assignee="opus")
    _, other = task("add", "planner", text="the replacement")
    task("supersede", "planner", id=tid, by_id=other["id"])
    t = tasks()[tid]
    assert t["state"] == "Superseded" and t["assignee"] == "", t


@check
def no_state_past_the_claim_ever_serves_an_assignee(b):
    _, r = task("add", "planner", text="walked through the lifecycle")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="opus")
    for verb, agent, state in [("claim", "opus", "Doing"),
                               ("submit", "opus", "Review"),
                               ("approve", "reviewer", "Done")]:
        task(verb, agent, id=tid)
        t = tasks()[tid]
        assert t["state"] == state, (verb, t)
        assert t["assignee"] == "", (state, "served an assignee", t)


@check
def assign_is_refused_once_a_task_is_past_being_claimable(b):
    _, r = task("add", "planner", text="too late to speak for")
    tid = r["id"]
    task("claim", "opus", id=tid)
    for agent, state in [("opus", "Doing"), ("opus", "Review"), ("reviewer", "Done")]:
        if state == "Review":
            task("submit", "opus", id=tid)
        elif state == "Done":
            task("approve", "reviewer", id=tid)
        st, err = task("assign", "planner", id=tid, assignee="sonnet")
        assert st == 409, (state, st, err)
        assert err["state"] == state, (state, err)
        assert state in err["error"], ("the refusal must name the state", err)
        assert tasks()[tid]["assignee"] == ""


@check
def the_expired_lease_takeover_is_untouched_by_a_prior_assignment(b):
    # The takeover path is the one thing assignment must never be able to
    # block, and it cannot BY CONSTRUCTION: the claim spent the assignment,
    # so by the time a lease can expire there is nothing left to strand.
    _, r = task("add", "planner", text="assigned, claimed, then abandoned")
    tid = r["id"]
    task("assign", "planner", id=tid, assignee="ghost")
    task("claim", "ghost", id=tid, lease_secs=1)
    assert tasks()[tid]["assignee"] == "", "spent at the claim"
    time.sleep(2)
    assert tasks()[tid]["state"] == "Ready"
    st, _ = task("claim", "rescuer", id=tid)
    assert st == 200, "an old assignment must never strand a takeover"
    assert tasks()[tid]["owner"] == "rescuer"


@check
def a_lapsed_lease_makes_a_task_assignable_again_and_the_assign_sticks(b):
    # The one place raw and effective state disagree, and the reason the
    # clearing rule reads the effective one. A lapsed task is SERVED as Ready
    # and is claimable by anyone, so it is assignable - and if the gate and
    # the clearing rule disagreed about that, assign would answer 200 here
    # and the value would be erased before the next GET. A silent no-op is
    # the failure this leg is watching for, not a refusal.
    _, r = task("add", "planner", text="lapsed and re-spoken-for")
    tid = r["id"]
    task("claim", "ghost", id=tid, lease_secs=1)
    time.sleep(2)
    assert tasks()[tid]["state"] == "Ready"
    st, _ = task("assign", "planner", id=tid, assignee="opus")
    assert st == 200, (st, "a lapsed task reads as Ready, so it is assignable")
    assert tasks()[tid]["assignee"] == "opus", "assign answered 200 and did nothing"
    # And it still refuses the wrong claimant, exactly as a Ready task would.
    assert task("claim", "interloper", id=tid)[0] == 409
    assert task("claim", "opus", id=tid)[0] == 200


@check
def the_panel_is_wired_to_show_and_set_an_assignment(b):
    # WHAT THIS PINS IS WIRING, NOT APPEARANCE, and saying so is the point -
    # a check that greps a page cannot prove a chip is visible, and claiming
    # otherwise is the "documented as enforced but never probed" defect in
    # test form. It catches the regression that actually happens: the verb
    # ships, the panel is never taught about it, and the field is invisible
    # to the person most likely to be setting one. The render itself was
    # checked in a browser against a scratch board; that is not automatable
    # here and is not pretended to be.
    page = urllib.request.urlopen(BASE + "/", timeout=5).read().decode()
    assert 'action: "assign"' in page, "the panel cannot set an assignment"
    assert "t.assignee" in page, "the panel never reads the field"
    assert "tfor" in page, "no chip distinct from the owner"
    # Pre-claim only, mirroring the server rule - a panel offering assignment
    # on a Doing task would just be manufacturing 409s for its user.
    assert 'const preClaim' in page and '"Draft"' in page, page[:0]


# ── checks: /delta paging - limit= and brief= (task #71) ────────────────────
#
# These were verified once in a scratchpad and nowhere else, which is the same
# as unverified the moment the scratchpad is gone: the suite passed 129/129
# while covering none of it. What is pinned here is one property above all -
# A CAPPED PAGE REPORTS THE LAST SEQ IT ACTUALLY SENT. `latest` is what the
# caller hands back as `since`, so a truncated page that reported the global
# tip would tell a follower it had seen messages it never received, and the
# next poll starts past them. Nothing raises an error, no count looks wrong,
# and the messages are gone. Silent loss is why this one gets a walk and not
# just an equality.

# Multibyte prose, the kind the board actually carries. An em-dash and an
# arrow are 3 bytes each and the emoji is 4, so a cut made on BYTES at 120
# lands mid-rune and the response stops being UTF-8 - the truncation bug that
# does not show up on ASCII fixtures.
BRIEF_PROSE = "em—dash and arrow→ plus emoji 🔥 " * 20


def seed_delta(n, to=None):
    """Post n messages; return their seqs in order.

    `to` is a list of recipients cycled through. Pass one and every message is
    DIRECTED - which is the difference between a real filter test and a
    worthless one, because `for=` matches broadcasts, so a seed of broadcasts
    filters nothing while looking exactly like it does."""
    seqs = []
    for i in range(n):
        body = {"kind": "status", "text": f"message number {i} " + "x" * 200}
        if to:
            body["kind"], body["to"] = "msg", to[i % len(to)]
        st, r = post(f"seeder{i % 3}", **body)
        assert st == 200, (st, r)
        seqs.append(r["seq"])
    return seqs


def walk(query, expect):
    """Follow the cursor exactly as a client does, and assert it saw everything.

    The loop IS the contract: poll, take `latest` as the next `since`, stop
    when `more` goes false. Every message that matched must arrive exactly
    once. A skip here is the failure that never announces itself in
    production."""
    seen, cursor, hops = [], 0, 0
    for _ in range(len(expect) + 50):
        st, d = call(f"/delta?since={cursor}&{query}")
        assert st == 200, (st, d)
        seen += [m["seq"] for m in d["messages"]]
        cursor = d["latest"]
        hops += 1
        if not d["more"]:
            break
    else:
        raise AssertionError(f"{query}: walk never reached the tip in {hops} hops")
    missing = sorted(set(expect) - set(seen))
    assert seen == expect, (
        f"{query}: a follower SKIPPED {len(missing)} messages it will never ask "
        f"for again: {missing[:8]}" if missing else
        f"{query}: delivered out of order or extra: got {seen[:8]}")
    dupes = sorted({s for s in seen if seen.count(s) > 1})
    assert not dupes, f"{query}: delivered twice: {dupes[:8]}"
    return seen


@check
def the_default_delta_page_is_capped_at_a_hundred_and_says_so(b):
    seqs = seed_delta(140)
    _, d = call("/delta?since=0")
    assert d["count"] == 100, ("the default cap is what stops a cold poll from "
                               "eating a context window", d["count"])
    assert d["more"] is True, "a cap that does not say it capped strands the backlog"
    assert d["tip"] == seqs[-1], ("tip is the newest seq on the board, so depth "
                                  "is visible from inside a capped page", d["tip"])


@check
def a_capped_page_reports_the_last_seq_it_actually_sent_not_the_tip(b):
    # THE cursor rule. Both halves are here on purpose: the equality states it,
    # and the walk proves the consequence - break the rule and the walk names
    # the messages the follower lost.
    seqs = seed_delta(130)
    _, d = call("/delta?since=0&limit=7")
    assert d["count"] == 7, d["count"]
    assert d["latest"] == d["messages"][-1]["seq"], \
        ("latest must be the last seq handed over", d["latest"])
    assert d["latest"] != d["tip"], \
        (f"a truncated page reporting the tip tells the caller it has seen "
         f"{d['tip'] - d['latest']} messages it has not", d["latest"], d["tip"])
    walk("limit=7", seqs)
    # And with no limit at all, so the walk crosses the DEFAULT cap - the page
    # size almost every real caller will actually meet.
    walk("as=follower", seqs)


@check
def a_capped_walk_at_the_page_boundary_delivers_everything_exactly_once(b):
    # limit=1 is the worst case (one hop per message); n-1/n/n+1 straddle the
    # point where `truncated` flips, which is where an off-by-one would drop
    # the last message or loop forever.
    seqs = seed_delta(30)
    n = len(seqs)
    for lim in (1, n - 1, n, n + 1):
        walk(f"limit={lim}", seqs)
    # The cap and the truncation are decided in one handler, so walk them
    # together at least once.
    walk("limit=3&brief=1", seqs)


@check
def limit_zero_probes_the_backlog_without_moving_the_cursor(b):
    seqs = seed_delta(40)
    tip = seqs[-1]
    _, d = call("/delta?since=0&limit=0")
    assert d["count"] == 0 and not d["messages"], d
    assert d["latest"] == 0, \
        ("a probe that advances the cursor eats the very backlog it was asked "
         "to measure", d["latest"])
    assert d["more"] is True and d["tip"] == tip, d
    _, d = call(f"/delta?since={seqs[9]}&limit=0")
    assert d["latest"] == seqs[9], ("a probe holds any cursor still, not just 0",
                                    d["latest"])
    _, d = call(f"/delta?since={tip}&limit=0")
    assert d["more"] is False and d["latest"] == tip, \
        ("a caught-up probe must not claim a backlog", d)
    # The whole point of probing: it costs nothing and consumes nothing.
    _, probe = call("/delta?since=0&limit=0")
    _, pull = call(f"/delta?since={probe['latest']}&limit=all")
    assert [m["seq"] for m in pull["messages"]] == seqs, "the probe ate messages"


@check
def limit_all_opts_out_of_the_cap_and_lands_on_the_tip(b):
    seqs = seed_delta(140)
    _, d = call("/delta?since=0&limit=all")
    assert d["count"] == len(seqs), ("limit=all is the deliberate opt-out",
                                     d["count"])
    assert d["latest"] == d["tip"] == seqs[-1], d
    assert d["more"] is False, "nothing was withheld, so nothing is waiting"
    _, d = call("/delta?since=0&limit=all&brief=1")
    assert d["count"] == len(seqs) and d["more"] is False, d


@check
def brief_truncation_counts_runes_and_text_len_carries_the_full_length(b):
    post("scribe", kind="status", text=BRIEF_PROSE)
    post("scribe", kind="status", text="short enough to survive whole")
    _, d = call("/delta?since=0&brief=1&limit=all")
    cut = [m for m in d["messages"] if m["text_len"] > 120]
    assert len(cut) == 1, [m["text_len"] for m in d["messages"]]
    m = cut[0]
    assert m["text"] == BRIEF_PROSE[:120] + "…", \
        ("brief must cut on RUNE 120, not byte 120 - a byte cut lands inside "
         "the em-dash and the response stops being valid UTF-8", m["text"][-20:])
    assert m["text_len"] == len(BRIEF_PROSE), \
        ("text_len is the FULL length the board holds, which is the only way a "
         "reader can tell how much it is missing", m["text_len"])
    short = [x for x in d["messages"] if x["text_len"] <= 120]
    assert all(not x["text"].endswith("…") for x in short), \
        ("a post that fits is passed through untouched", short)
    assert all(x["text_len"] == len(x["text"]) for x in short), short
    _, d = call("/delta?since=0&brief=25&limit=all")
    m = [x for x in d["messages"] if x["text_len"] > 25][0]
    assert m["text"] == BRIEF_PROSE[:25] + "…", ("brief=N spends N, not the "
                                                 "default", m["text"])


@check
def a_brief_message_keeps_every_key_of_a_full_one_plus_text_len(b):
    # The regression this refuses is a wire break, not a cosmetic one:
    # marshalling the brief form by EMBEDDING a Message nests every existing
    # key one level down, and every client reading m["text"] breaks at once.
    post("scribe", kind="msg", to="bob", text=BRIEF_PROSE, files=["a.odin"])
    _, full = call("/delta?since=0&limit=1")
    _, brief = call("/delta?since=0&limit=1&brief=1")
    fm, bm = full["messages"][0], brief["messages"][0]
    assert set(bm) - {"text_len"} == set(fm), \
        ("a brief message must be a full one plus text_len, flat", set(bm))
    assert set(brief) == set(full), ("the envelope keys must match too", set(brief))
    assert bm["files"] == fm["files"] and bm["to"] == fm["to"], (bm, fm)


@check
def the_capping_params_refuse_a_value_they_cannot_honour(b):
    # These two parameters exist to stop an accidental full-board pull, so a
    # value they cannot honour must never DEGRADE to no cap - the refusal is
    # the feature. `?limit` with no `=` is the trap worth naming: the shared
    # query parser skips a valueless key, so the most natural way to type it
    # by hand would have parsed as absent and dumped the board.
    seed_delta(3)
    for key in ("limit", "brief"):
        st, r = call(f"/delta?since=0&{key}")
        assert st == 400, (f"a hand-typed ?{key} must not read as absent", st, r)
        assert key in r.get("error", ""), ("the refusal must name the parameter "
                                           "and how to spell it", r)
        assert not r.get("messages"), ("a refusal must not ship the board it "
                                       "just refused to cap", r)
    for bad in ("limit=abc", "limit=-1", "brief=0", "brief=-3", "brief=xyz"):
        st, r = call(f"/delta?since=0&{bad}")
        assert st == 400 and "error" in r, (bad, st, r)
        assert bad.split("=")[0] in r["error"], (bad, r["error"])
        assert not r.get("messages"), (bad, r)


@check
def a_filtered_poll_still_reports_the_global_tip(b):
    # limit is the ONLY thing that moves `latest` off the tip. Filtered-out
    # messages were evaluated and excluded, not withheld, so re-fetching them
    # would only exclude them again - and filtered and unfiltered pollers share
    # one cursor precisely because of that. If this regressed, a monitor using
    # for= would silently skip: the same class of loss as the cursor rule.
    seqs = seed_delta(30, to=["watcher", "other1", "other2"])
    _, mine = call("/delta?since=0&for=watcher&limit=all")
    got = [m["seq"] for m in mine["messages"]]
    assert 0 < len(got) < len(seqs), \
        ("the seed must be genuinely excluded or this proves nothing",
         len(got), len(seqs))
    assert all(m["to"] == "watcher" for m in mine["messages"]), "the filter leaked"
    assert mine["latest"] == mine["tip"] == seqs[-1], \
        ("a filtered poll shares the global cursor", mine["latest"], seqs[-1])
    assert mine["more"] is False, mine

    _, plan = post("planner", text="a plan")
    _, t = task("draft", "planner", text="a task", plan_id=plan["seq"],
                plan_seq=plan["seq"])
    post("worker", text="bound to the task", task_id=t["id"])
    _, d = call(f"/delta?since=0&task={t['id']}")
    assert d["count"] == 1 and d["latest"] == d["tip"], \
        ("task= filters without moving the cursor either", d)


@check
def a_filtered_walk_under_a_cap_never_skips_the_mail_it_matches(b):
    # THE TRAP the original verification hit and disclosed: its first filtered
    # walk seeded BROADCASTS, which for= matches, so the "filtered" walk was
    # unfiltered and proved nothing about the interaction. Directed traffic
    # only here, and the exclusion is asserted before the walk is trusted.
    seqs = seed_delta(60, to=["watcher", "other1", "other2"])
    _, full = call("/delta?since=0&for=watcher&limit=all")
    mine = [m["seq"] for m in full["messages"]]
    assert len(mine) == len(seqs) // 3, \
        ("for= must genuinely exclude two thirds of this seed", len(mine))
    # Where limit and for= actually meet: a page that is NOT truncated jumps
    # latest to the global tip, so the boundary either side of the match count
    # is where a follower would lose the remainder.
    for lim in (5, len(mine) - 1, len(mine), len(mine) + 1):
        walk(f"limit={lim}&for=watcher", mine)
    _, d = call(f"/delta?since={full['latest']}&limit=5&for=watcher")
    assert d["more"] is False, ("a caught-up filtered follower must not be told "
                               "it is behind", d)


@check
def a_capped_walker_interleaved_with_live_writers_loses_nothing(b):
    # A real follower polls a board that is still being written to. Every hop
    # here leaves messages arriving after the page was cut, which is the case
    # where a cursor that overshoots loses data for good.
    seqs = seed_delta(40)
    seen, cursor, added = [], 0, []
    for step in range(10):
        _, d = call(f"/delta?since={cursor}&limit=5")
        seen += [m["seq"] for m in d["messages"]]
        cursor = d["latest"]
        _, p = post("racer", kind="status", text=f"interleaved write {step}")
        added.append(p["seq"])
    _, d = call(f"/delta?since={cursor}&limit=all")
    seen += [m["seq"] for m in d["messages"]]
    expect = sorted(seqs + added)
    missing = sorted(set(expect) - set(seen))
    assert sorted(seen) == expect, \
        (f"a follower racing live writers SKIPPED {missing[:8]}" if missing
         else f"unexpected extras: {sorted(set(seen) - set(expect))[:8]}")
    assert len(seen) == len(set(seen)), \
        f"delivered twice: {sorted({s for s in seen if seen.count(s) > 1})[:8]}"


# ── runner ──────────────────────────────────────────────────────────────────

def main():
    pattern = None
    if "-k" in sys.argv:
        pattern = sys.argv[sys.argv.index("-k") + 1]

    # --exe runs the suite against a binary that ALREADY EXISTS instead of
    # building the working tree. It is here so "this leg goes red against the
    # pre-fix binary" is a claim anyone can re-run rather than one they have
    # to take on trust: build the old commit somewhere, point the suite at
    # it, watch the leg fail. A leg that has never been seen to fail has not
    # been shown to catch anything, and without this flag the only way to see
    # it fail was to un-write the fix.
    exe = None
    if "--exe" in sys.argv:
        exe = sys.argv[sys.argv.index("--exe") + 1]
        print(f"(running against prebuilt {exe} - working tree NOT compiled)")
    if exe is None:
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
