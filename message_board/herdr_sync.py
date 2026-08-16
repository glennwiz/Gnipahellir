"""Sidecar: pipe herdr's ground-truth fleet state into the message board.

Every POLL seconds, `herdr agent list` is condensed to [{name, agent, status,
pane, workspace}] and POSTed to the board's /herdr_state, which the frontend
roster reads for live working/idle/blocked/done badges.

Dead-spawn watch: a "spawned <name> ..." announcement by the board agent that
is followed by neither a check-in post from <name> nor a live herdr pane of
that name within GRACE seconds gets one warning post, so a silently failed
spawn surfaces in minutes, not on someone's hunch.
"""
import json
import subprocess
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:7666"
POLL = 15
GRACE = 180

pending = {}   # spawn name -> announce unix, dropped once seen or warned
cursor = 0     # set to the live head at startup - history is not replayed


def http_json(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as r:
        return json.load(r)


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


def watch_spawns(fleet):
    """Track spawn announcements; warn once if one never comes alive."""
    global cursor
    d = http_json(f"/delta?since={cursor}")
    for m in d.get("messages", []):
        if m["agent"] == "board" and m["text"].startswith("spawned "):
            name = m["text"].split()[1]
            pending[name] = m["unix"]
        elif m["agent"] in pending:
            del pending[m["agent"]]  # it spoke - alive
    cursor = d["latest"]

    alive = {f["name"] for f in fleet if f["status"] in ("working", "idle")}
    now = time.time()
    for name, born in list(pending.items()):
        if name in alive:
            continue  # herdr sees it; give it time to finish booting
        if now - born > GRACE:
            http_post("/post", {
                "agent": "board", "kind": "msg",
                "text": f"WARNING: {name} was spawned {int(now - born)}s ago "
                        "but never checked in and has no live herdr pane - "
                        "the spawn likely failed",
            })
            del pending[name]


def main():
    global cursor
    while cursor == 0:
        try:
            cursor = http_json("/delta?since=0")["latest"]
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
                http_post("/herdr_state", fleet)
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
