#!/usr/bin/env python3
"""GNIPA_AGENT_TURBO must change the speed of a run and nothing else.
Plays one fixed script in two real games, turbo and plain, and compares what each
recorded.  Needs a display.  Usage: tools/test_agent_turbo.py [port]
Idling is off: idle ticks follow wall time in any run, so a script cannot fix them."""
import json, os, shutil, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEED = "4242"
MIN_SPEEDUP = 4  # 30 times at load 40; a run that only looks faster is load noise
SCRIPT = [
    {"frames": 30, "dismiss": True}, {"frames": 30, "dismiss": True},
    *[{"frames": 60, "move": m, "jump": j} for m, j in
      (("left", False), ("left", True), ("right", False), ("right", True))] * 2,
    {"frames": 40, "mine": [86, 55]}, {"frames": 40, "mine": [87, 55]}, {"frames": 120},
]


def connect(port):
    for _ in range(120):
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=120)
        except OSError:
            time.sleep(0.5)
    sys.exit("the game never listened")


def play(binary, folder, port, turbo):
    os.makedirs(folder)
    open(os.path.join(folder, "agent_sandbox"), "w").close()
    for name in ("sprites", "sounds"):
        os.symlink(os.path.join(ROOT, name), os.path.join(folder, name))
    env = dict(os.environ, GNIPA_SEED=SEED, GNIPA_AGENT_PORT=str(port))
    env.pop("GNIPA_AGENT_TURBO", None)
    if turbo:
        env["GNIPA_AGENT_TURBO"] = "1"
    game = subprocess.Popen([binary], cwd=folder, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        c = connect(port)
        f = c.makefile("rb")

        def ask(o):
            c.sendall((json.dumps(o) + "\n").encode())
            return json.loads(f.readline())

        ask({"cmd": "idle", "on": False})
        start = time.time()
        last = None
        for act in SCRIPT:
            last = ask({"cmd": "act", **act})
        seconds = time.time() - start
        c.close()
    finally:
        game.terminate()
        game.wait(20)
    return seconds, recorded(folder), last


def recorded(folder):
    """What a run wrote down.  Parsed, because the game writes an act's keys in map
    order; the log's first line is the wall clock."""
    with open(os.path.join(folder, "acts.jsonl")) as f:
        acts = [o for o in map(json.loads, f) if "mark" not in o]
    with open(os.path.join(folder, "action.log"), errors="replace") as f:
        log = [line for line in f if "=== run start" not in line]
    with open(os.path.join(folder, "fight.log")) as f:
        return {"acts": acts, "log": log, "fight": f.read()}


def world(reply):
    """A final state with what only the clock of the reply could move taken out."""
    return {k: reply[k] for k in ("frame", "level", "player", "inventory", "view", "items", "enemies")}


def main(argv):
    port = int(argv[0]) if argv else 7803
    tmp = os.path.join(ROOT, "build", "turbo_test")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    binary = os.path.join(tmp, "gnipa")
    subprocess.run(["odin", "build", "src", "-out:" + binary], cwd=ROOT, check=True)
    plain_s, plain, plain_end = play(binary, os.path.join(tmp, "plain"), port, False)
    turbo_s, turbo, turbo_end = play(binary, os.path.join(tmp, "turbo"), port, True)
    print(f"plain {plain_s:.1f} s, turbo {turbo_s:.1f} s, {len(plain['acts'])} acts recorded")
    failed = []
    if len(plain["acts"]) != len(SCRIPT):
        failed.append("the plain run recorded the wrong number of acts")
    failed += [f"{k} differs" for k in plain if plain[k] != turbo[k]]
    if world(plain_end) != world(turbo_end):
        failed.append("the two final states differ")
    if turbo_s * MIN_SPEEDUP > plain_s:
        failed.append(f"turbo was not {MIN_SPEEDUP} times faster")
    shutil.rmtree(tmp, ignore_errors=True)
    if failed:
        sys.exit("FAIL: " + ", ".join(failed))
    print("ok")


if __name__ == "__main__":
    main(sys.argv[1:])
