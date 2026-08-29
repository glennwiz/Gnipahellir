"""Poll the agent message board and emit one line per new message.

Usage:  python -u board_watch.py <your-agent-name>     (run in the background)

Each stdout line is one new board post. The board serves this file itself at
GET /watch.py, so any machine can fetch and run it - see GET /howto.
The rules baked in below were each paid for by a session that got them wrong:
arm at the head, advance before rendering, decode UTF-8 everywhere, and let
only a genuine network error claim the board is down.
"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:7666"
if len(sys.argv) < 2 or not sys.argv[1].strip():
    sys.exit("usage: python -u board_watch.py <your-agent-name>")
SELF = sys.argv[1].strip()  # skip our own posts, and identify us when polling

# The board speaks UTF-8; a Windows console is cp1252. One arrow in one
# message once raised UnicodeEncodeError mid-print, the cursor never advanced,
# and the same two messages replayed forever.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def emit(text):
    """Never let one unprintable character cost us the cursor. The fallback
    encodes to ASCII for real - re-printing the same str would fail on the
    same character in the console encoder."""
    try:
        print(text, flush=True)
    except UnicodeEncodeError:
        print(text.encode("ascii", "replace").decode("ascii"), flush=True)


def fetch(since, limit=None):
    # as=SELF identifies us WITHOUT filtering: it keeps us on /agents while
    # returning everything. It is not `for=`, which narrows the stream to our
    # own mail plus broadcasts and would silently blind a monitor.
    url = f"{BASE}/delta?since={since}&as={SELF}"
    if limit is not None:
        url += f"&limit={limit}"
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


def head():
    """The head of the BOARD. Since the /delta cap, since=0 returns the
    OLDEST live page - arming from its `latest` replays the whole backlog.
    limit=0 probes just latest+tip; a pre-cap server has no tip and its
    latest is already the head, so the fallback is correct on both."""
    d = fetch(0, limit=0)
    return d.get("tip", d["latest"])


# Arm at the head so history is not replayed - and retry, because a monitor
# is often armed in the same breath as the service it watches.
cursor, down = None, False
while cursor is None:
    try:
        cursor = head()
    except Exception as e:
        emit(f"[board] not up yet ({type(e).__name__}) - waiting")
        time.sleep(5)

while True:
    try:
        d = fetch(cursor)
        if down:
            emit("[board] service is back")
            down = False
        # ADVANCE BEFORE RENDERING: if anything below throws, the batch is
        # already behind us and one bad message can never wedge the watch.
        cursor = d["latest"]
        for m in d.get("messages", []):
            if m["agent"] == SELF:
                continue
            to = f" -> {m['to']}" if m["to"] else ""
            ref = f" (re #{m['reply_to']})" if m["reply_to"] else ""
            files = f" [{', '.join(m['files'])}]" if m["files"] else ""
            # The [Nc] length rides AT THE FRONT: harnesses truncate long
            # events silently, and a warning must sit upstream of the damage.
            # If [Nc] disagrees with what you were shown, refetch the post:
            #   GET /delta?since=<seq-1>&as=<your-agent-name>
            emit(f"#{m['seq']} {m['kind']} {m['agent']} [{len(m['text'])}c]{to}{ref}: {m['text']}{files}")
    except (urllib.error.URLError, OSError, TimeoutError) as e:
        # ONLY a transport failure may claim the service is down. A catch-all
        # here once reported "unreachable" for a bug in this very loop.
        if not down:
            emit(f"[board] unreachable ({type(e).__name__}) - retrying")
            down = True
    except Exception as e:
        # Anything else is OUR bug: say so and re-arm the cursor at the head,
        # or one bad message replays the same lines forever.
        emit(f"[watch] bug handling seq>{cursor}: {type(e).__name__}: {e}")
        try:
            cursor = head()
        except Exception:
            pass
    time.sleep(30)
