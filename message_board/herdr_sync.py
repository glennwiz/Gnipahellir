"""Sidecar: pipe herdr's ground-truth fleet state into the message board.

Every POLL seconds, `herdr agent list` is condensed to [{name, agent, status,
pane, workspace}] and POSTed to the board's /herdr_state, which the frontend
roster reads for live working/idle/blocked/done badges.

Dead-spawn watch: a "launch requested for <name> ..." announcement by the
board agent that is followed by neither a check-in post from <name>, nor a
live herdr pane of that name, nor a deliberate close, within GRACE seconds
gets one warning post - so a launch that never became an agent surfaces in
minutes rather than on someone's hunch.

The warning states what was OBSERVED and stops there. It used to conclude
"the spawn likely failed", which is a diagnosis rather than an observation,
and it said exactly that about an agent that started fine and was closed on
purpose - while the message proving it had been closed sat in the same delta
this watcher was already reading.
"""
import hashlib
import json
import subprocess
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:7666"
POLL = 15
GRACE = 180


def _own_source_sha256():
    """sha256 of this file's bytes, computed once at import (task #62).

    The system is two processes and only one of them could say what code it
    runs. The board is stamped at compile time; a script has no compile step,
    so it reports the hash of the source it was STARTED from instead - and
    startup is the only honest moment to take it. Read at request time it
    would describe the file on disk, which after an edit is precisely NOT the
    code executing here, and the answer would be confidently wrong exactly
    when someone edited without restarting - the case this exists to catch.

    Bytes, never decoded text: the board hashes the same file knowing nothing
    of its encoding, and a text-mode read on Windows silently drops \\r, so
    the two languages would disagree on an identical file and the mismatch
    would look like a real staleness.

    On failure, "" - reported as nothing at all rather than as a hash. An
    unknown version is unknown; the unstamped principle, one process over.
    """
    try:
        with open(__file__, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception as e:
        print(f"[herdr_sync] cannot hash own source ({type(e).__name__}) - "
              f"reporting unversioned", flush=True)
        return ""


SRC_SHA = _own_source_sha256()

pending = {}   # spawn name -> announce unix, dropped once seen or warned
cursor = 0     # set to the live head at startup - history is not replayed


def http_json(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as r:
        return json.load(r)


def head_cursor(d):
    """The seq to ARM a new watch at, from a /delta response.

    `latest` is the cursor for FOLLOWING a stream and it is the wrong value to
    START one. Since the 100-message cap (98bbb86) a `since=0` page returns the
    head of the FIRST PAGE - measured live at latest=100 against tip=1167 - so
    arming from it starts this watcher 1067 messages in the past.

    THE COST IS A BLIND WINDOW, NOT FALSE ALARMS - and the distinction was
    measured rather than reasoned about (board seq 1170/1172). The obvious
    fear is that paging the backlog re-ingests old `launch requested for`
    announcements at their original stamps, all aged past GRACE, and posts
    dead-spawn warnings for agents that closed hours ago. Replaying the real
    1167-message log through watch_spawns' exact logic from the buggy seed,
    with the simulation deliberately rigged to favour warnings, posted ZERO:
    the sweep only fires when a launch's CANCELLING message lands in a LATER
    page than the launch, and this log cancels every one within 9 seqs where
    a page is 100. It is a page-boundary race, and a spawn storm could still
    arrange it - "not today" is not "never".

    What DOES happen every time is quieter: a restarted sidecar spends ~11
    polls at POLL=15s - about 2.75 minutes - walking days-old traffic before
    it reaches the head, and it is not watching for real spawns while it does.
    A genuine dead spawn in the first three minutes after a restart is noticed
    late or not at all. A missed warning, from the watcher whose whole job is
    noticing silence.

    `tip` is the newest seq on the board and is what "start at the head" means.
    The fallback to `latest` keeps this correct against a board older than the
    cap, where the two are the same number.
    """
    return d.get("tip", d["latest"])


def http_post(path, obj):
    req = urllib.request.Request(BASE + path, json.dumps(obj).encode(),
                                 method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def herdr_agents():
    # encoding= not text=. herdr's JSON carries each pane's terminal_title, and
    # those hold the agent spinner glyphs - multi-byte UTF-8 that a Windows
    # cp1252 default cannot decode. It fails in subprocess's reader THREAD, so
    # the caller sees a bare IndexError (empty buffer) and the real
    # UnicodeDecodeError only appears on a stderr nobody is reading.
    #
    # The cruelty is the correlation: titles carry spinner glyphs precisely
    # WHILE agents are working, so the query dies exactly when it has something
    # worth reporting and succeeds whenever the fleet is idle.
    p = subprocess.run(["herdr", "agent", "list"], capture_output=True,
                       encoding="utf-8", errors="replace", timeout=10)
    out = json.loads(p.stdout)["result"]["agents"]
    return [{
        "name": a.get("name", ""),
        "agent": a.get("agent", ""),
        "status": a.get("agent_status", "unknown"),
        "pane": a.get("pane_id", ""),
        "tab": a.get("tab_id", ""),
        "workspace": a.get("workspace_id", ""),
    } for a in out]


LAUNCH_PREFIX = "launch requested for "
CLOSE_PREFIX = "closed "


def dead_spawn_warning(name, elapsed, entry):
    """Build the warning text for a launch that has not (yet) become a live
    agent. `entry` is the fleet dict herdr returned for `name`, or None if
    herdr shows no pane for it at all - that split is the one fact this
    function is allowed to report a cause for, because it is the one thing
    this code actually checked.

    REPORT, DO NOT TRANSLATE (task #56): herdr's status is a point-in-time
    inference from terminal-title and screen heuristics (a versioned
    detection manifest owned by another program), not a fact about the
    process - it can be transiently wrong and it lags. So for anything herdr
    DOES show a pane for, this says the status and the pane VERBATIM and
    stops there. It does not translate "blocked" into "wants a keypress", or
    any other status into a cause or an instruction - rev 1 of this task did
    exactly that from a single observation and was proven wrong within the
    hour. An unrecognised status (herdr's enum is not ours to close over)
    degrades the same way: named verbatim, not funnelled into either
    sentence.
    """
    if entry is None:
        return (f"WARNING: launch requested for {name} {elapsed}s ago; "
                "it has not posted and herdr shows no pane for it")
    status = entry.get("status", "unknown")
    pane = entry.get("pane", "")
    return (f"WARNING: launch requested for {name} {elapsed}s ago; it has "
            f"not posted; herdr reports status={status} at pane {pane}")


def watch_spawns(fleet):
    """Track launch announcements; warn once if one never becomes an agent."""
    global cursor
    d = http_json(f"/delta?since={cursor}")
    for m in d.get("messages", []):
        if m["agent"] == "board" and m["text"].startswith(LAUNCH_PREFIX):
            pending[m["text"][len(LAUNCH_PREFIX):].split()[0]] = m["unix"]
        elif m["agent"] == "board" and m["text"].startswith(CLOSE_PREFIX):
            # Deliberately closed is not "never came alive". This branch was
            # missing, so an agent killed before it ever posted was reported
            # as a probable failed spawn - a conclusion contradicted by a
            # message already in this very stream.
            pending.pop(m["text"][len(CLOSE_PREFIX):].split()[0], None)
        elif m["agent"] in pending:
            del pending[m["agent"]]  # it spoke - alive
    cursor = d["latest"]

    by_name = {f["name"]: f for f in fleet}
    alive = {f["name"] for f in fleet if f["status"] in ("working", "idle")}
    now = time.time()
    for name, born in list(pending.items()):
        if name in alive:
            continue  # herdr sees it; give it time to finish booting
        if now - born > GRACE:
            # DO NOT add "blocked" (or anything else) to `alive` above to
            # silence this - that would also silence the warning for an
            # agent genuinely stuck for an hour. The bug task #56 found was
            # in this sentence, not in that filter.
            http_post("/post", {
                "agent": "board", "kind": "msg",
                "text": dead_spawn_warning(name, int(now - born), by_name.get(name)),
            })
            del pending[name]


def main():
    global cursor
    while cursor == 0:
        try:
            # limit=0 is the probe: it returns NO messages, just the cursor
            # fields. Arming a watch should not page the board at all, and
            # this way it cannot - the bug above was possible only because
            # the arming call was also a history request.
            cursor = head_cursor(http_json("/delta?since=0&limit=0"))
        except Exception:
            time.sleep(POLL)  # board still booting
    while True:
        # THE REAL DEFECT WAS HERE, not in the decode. This used to be
        # `except Exception: fleet = []`, which turns a failed query into a
        # confident assertion that the fleet is EMPTY - and downstream cannot
        # tell that apart from the truth. The badge column went blank for hours
        # and looked like a working feature with nothing to show.
        #
        # So: on failure, publish NOTHING. The board keeps its last honest
        # snapshot and the error gets named. An empty list is posted only when
        # herdr genuinely reports zero agents. Silence beats a confident wrong
        # answer.
        fleet = None
        try:
            fleet = herdr_agents()
        except Exception as e:
            print(f"[herdr_sync] query failed, keeping last snapshot: "
                  f"{type(e).__name__}: {e}", flush=True)

        if fleet is not None:
            try:
                # THE VERSION RIDES AS A QUERY PARAM, NOT IN THE BODY. The body
                # stays the bare array it has always been: a fix for a
                # version-visibility hazard must not itself change the wire
                # shape, or every old/new pairing of these two processes breaks
                # on the fix. As a param it degrades cleanly in all four - an
                # old board ignores an unknown param, a new board reads an
                # absent one as "unreported".
                #
                # Omitted entirely when unknown rather than sent empty, so the
                # board distinguishes "no version" from "a version that is the
                # empty string".
                http_post("/herdr_state" + (f"?src={SRC_SHA}" if SRC_SHA else ""),
                          fleet)
                watch_spawns(fleet)
            except (urllib.error.URLError, OSError, TimeoutError) as e:
                # Only a real transport failure means the board is unreachable.
                print(f"[herdr_sync] board unreachable ({type(e).__name__}) - "
                      f"retrying", flush=True)
            except Exception as e:
                print(f"[herdr_sync] bug posting state: {type(e).__name__}: {e}",
                      flush=True)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
