"""Cross-platform launcher: the board, its sidecar and the codex coordinator,
each in its own herdr pane. Windows and Linux, stdlib only.

    python board_up.py                  # board + sidecar + coordinator
    python board_up.py --no-coordinator # just the service pair
    python board_up.py --kind claude    # a different agent CLI in the seat

Idempotent: a board that answers, a sidecar process that exists, or a herdr
tab already labelled `coordinator` is left alone rather than duplicated.
herdr is the terminal layer on both platforms; if it is absent the service
pair falls back to detached processes with logs (run.ps1's shape) and the
coordinator - which only makes sense as an interactive pane - is skipped
with a message. run.ps1 remains the richer Windows lifecycle tool (status,
stop, the rebuild drill); this script is the portable "get it running".
"""
import argparse
import json
import os
import platform
import secrets
import subprocess
import sys
import time
import urllib.request

BASE = "http://127.0.0.1:7666"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IS_WIN = platform.system() == "Windows"
EXE = os.path.join(HERE, "message_board.exe" if IS_WIN else "message_board")


def say(msg):
    print(msg, flush=True)


def board_answers():
    try:
        with urllib.request.urlopen(f"{BASE}/agents", timeout=2):
            return True
    except Exception:
        return False


def board_note(text):
    # Say it on the board. Best effort - a note that cannot land must never
    # stop the start it describes.
    body = json.dumps({"agent": "board_up.py", "kind": "status", "text": text}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(f"{BASE}/post", data=body), timeout=5)
    except Exception as e:
        say(f"[board] could not post '{text}' ({type(e).__name__}) - proceeding")


def run(args, timeout=15, cwd=None):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)


def build_board():
    # Same contract as run.ps1's Build-Board: the stamp comes from git HEAD,
    # single-quoted so Odin's -define parser reads it as a string and an
    # all-digit hash cannot silently become an integer. No git -> build
    # unstamped and let the binary say so.
    out_rel = os.path.relpath(EXE, ROOT)
    r = run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT)
    args = ["odin", "build", "message_board", f"-out:{out_rel}"]
    if r.returncode == 0 and r.stdout.strip():
        h = r.stdout.strip()
        t = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime())
        dirty = run(["git", "status", "--porcelain", "--", "*.odin"], cwd=ROOT)
        if dirty.stdout.strip():
            say("[build] WARNING: uncommitted *.odin changes - the stamp names "
                "HEAD but the compiler reads the tree (run.ps1 rebuild refuses this)")
        args += [f"-define:BUILD_HASH='{h}'", f"-define:BUILD_TIME='{t}'"]
        say(f"[build] {h} ({t})")
    else:
        say("[build] no git commit available - binary will report 'unstamped'")
    b = run(args, timeout=300, cwd=ROOT)
    if b.returncode != 0:
        sys.exit(f"[build] odin build failed:\n{b.stderr or b.stdout}")


# ── herdr layer ─────────────────────────────────────────────────────────────

def herdr(args, timeout=20):
    return run(["herdr"] + args, timeout=timeout)


def herdr_available():
    try:
        return herdr(["status"], timeout=5).returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def herdr_tab_labels():
    try:
        out = json.loads(herdr(["tab", "list"]).stdout)
        return {t.get("label", "") for t in out["result"]["tabs"]}
    except Exception:
        return set()


def herdr_tab(cwd, label):
    r = herdr(["tab", "create", "--cwd", cwd, "--label", label, "--no-focus"])
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[:300])
    out = json.loads(r.stdout)
    return out["result"]["tab"]["tab_id"], out["result"]["root_pane"]["pane_id"]


def pane_run(pane, command):
    r = herdr(["pane", "run", pane] + command)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[:300])


# ── the service pair ────────────────────────────────────────────────────────

def start_detached(cmd, out_log, err_log):
    kw = {"creationflags": 0x08000008} if IS_WIN else {"start_new_session": True}
    subprocess.Popen(cmd, cwd=HERE, stdin=subprocess.DEVNULL,
                     stdout=open(os.path.join(HERE, out_log), "ab"),
                     stderr=open(os.path.join(HERE, err_log), "ab"), **kw)


def start_in_pane_or_detached(label, command, out_log, err_log, use_herdr):
    if use_herdr:
        try:
            _, pane = herdr_tab(HERE, label)
            pane_run(pane, command)
            say(f"[{label}] running in herdr pane {pane}")
            return
        except Exception as e:
            say(f"[{label}] herdr path failed ({e}) - falling back to detached")
    start_detached(command, out_log, err_log)
    say(f"[{label}] running detached, logs {out_log} / {err_log}")


def sidecar_running():
    if IS_WIN:
        # The same filter run.ps1 uses; pgrep cannot see Windows processes.
        ps = ("(Get-CimInstance Win32_Process -Filter \"Name = 'python.exe' OR "
              "Name = 'pythonw.exe'\" | Where-Object { $_.CommandLine -match "
              "'herdr_sync\\.py' } | Measure-Object).Count")
        for shell in ("pwsh", "powershell"):
            try:
                r = run([shell, "-NoProfile", "-Command", ps], timeout=20)
                if r.returncode == 0:
                    return int(r.stdout.strip() or 0) > 0
            except (FileNotFoundError, subprocess.TimeoutExpired):
                continue
        return False
    r = run(["pgrep", "-f", "herdr_sync.py"])
    return r.returncode == 0


# ── the coordinator ─────────────────────────────────────────────────────────

COORDINATOR_BRIEF = (
    "You are {name}, the standing coordinator for the Gnipahellir agent fleet. "
    "First read http://127.0.0.1:7666/howto - it is the whole board protocol in "
    "one page - then check in on the board as {name} and arm the monitor it "
    "describes. Your role: route asks from glenn into board tasks, hand approved "
    "plans to implementers, review and approve completed work you did not "
    "author, and answer requests addressed to you. Coordinate; do not implement. "
    "Keep posts short."
)


def start_coordinator(kind):
    if "coordinator" in herdr_tab_labels():
        say("[coordinator] a herdr tab labelled 'coordinator' already exists - leaving it alone")
        return
    name = f"coordinator-{secrets.token_hex(2)}"
    tab, pane = herdr_tab(ROOT, "coordinator")
    r = herdr(["agent", "start", name, "--kind", kind, "--pane", pane,
               "--timeout", "60000"], timeout=90)
    if r.returncode != 0:
        herdr(["tab", "close", tab])
        sys.exit(f"[coordinator] agent start failed: {(r.stderr or r.stdout).strip()[:300]}")
    p = herdr(["agent", "prompt", name, COORDINATOR_BRIEF.format(name=name)], timeout=30)
    if p.returncode != 0:
        say(f"[coordinator] started but the brief was not delivered "
            f"({(p.stderr or p.stdout).strip()[:200]}) - prompt it by hand")
    say(f"[coordinator] {name} ({kind}) in herdr pane {pane}")


# ── main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--no-coordinator", action="store_true")
    ap.add_argument("--kind", default="codex",
                    help="agent CLI for the coordinator seat (default codex)")
    a = ap.parse_args()

    use_herdr = herdr_available()
    if not use_herdr:
        say("[herdr] not reachable - service pair goes detached, coordinator needs herdr")

    if board_answers():
        say("[board] already up")
    else:
        if not os.path.exists(EXE):
            say("[board] no binary yet - building")
            build_board()
        start_in_pane_or_detached("board", [EXE], "service.log", "service.err.log", use_herdr)
        for _ in range(20):
            time.sleep(0.5)
            if board_answers():
                break
        else:
            sys.exit(f"[board] did not answer on {BASE} within 10s - check the pane/logs")
        try:
            with urllib.request.urlopen(f"{BASE}/build", timeout=5) as r:
                commit = json.load(r).get("commit", "?")
        except Exception:
            commit = "pre-/build binary"
        say(f"[board] up - running {commit}")
        board_note(f"board started - running {commit} (board_up.py)")

    if sidecar_running():
        say("[sidecar] already running")
    else:
        start_in_pane_or_detached("board-sidecar", [sys.executable, "herdr_sync.py"],
                                  "sidecar.log", "sidecar.err.log", use_herdr)

    if a.no_coordinator:
        say("[coordinator] skipped (--no-coordinator)")
    elif not use_herdr:
        say("[coordinator] skipped - start herdr, then rerun")
    else:
        start_coordinator(a.kind)


if __name__ == "__main__":
    main()
