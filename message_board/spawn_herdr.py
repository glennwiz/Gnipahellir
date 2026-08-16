"""Board /spawn launcher: put the agent in a herdr pane (glenn seq 195/196),
falling back to a grouped Windows Terminal tab if herdr is unavailable.
All arguments are server-generated or allowlisted; the task text itself lives
in a prompt file, never on a command line."""
import datetime
import json
import subprocess
import sys

agent, work_dir, model, instruction = sys.argv[1:5]


def run(args, timeout):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def log(msg):
    with open("spawn_prompts/spawn.log", "a", encoding="utf-8") as f:
        f.write(f"{datetime.datetime.now():%H:%M:%S} {agent}: {msg}\n")


try:
    created = run(["herdr", "tab", "create", "--cwd", work_dir,
                   "--label", agent, "--no-focus"], timeout=15)
    out = json.loads(created.stdout)
    pane = out["result"]["root_pane"]["pane_id"]
    tab = out["result"]["tab"]["tab_id"]
    started = run(["herdr", "agent", "start", agent, "--kind", "claude",
                   "--pane", pane, "--timeout", "60000",
                   "--", "--model", model, instruction], timeout=90)
    if started.returncode == 0:
        log(f"OK herdr pane {pane}")
        sys.exit(0)
    log(f"agent start failed rc={started.returncode}: {started.stderr.strip()[:200]}")
    run(["herdr", "tab", "close", tab], timeout=15)
except Exception as e:
    log(f"herdr path failed: {e!r:.200}")

# herdr missing or refused - herd into the existing Windows Terminal window.
log("falling back to wt tab")
sys.exit(subprocess.call(["wt", "-w", "0", "new-tab", "--title", agent,
                          "-d", work_dir, "cmd", "/k",
                          "claude", "--model", model, instruction]))
