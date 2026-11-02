#!/usr/bin/env python3
"""Runs the bot over seeds, one game at a time, for tools/agent_pacing.py (design review P14).
Usage: tools/agent_bot/pace.py <out folder> <seed>... [--lives N] [--minutes M]

Each seed gets its own run folder under <out folder>, holding the game's logs, the
bot's output and its result. A death moves on to the next life of that seed, which
is a new world. A bot that gives up alive ends the seed: the game has no way to
start over from there, and the same seed would fail the same way."""
import json, os, signal, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
GAME_PORT = 7801
BRIDGE_PORT = 7802
BOT_SCRIPTS = ("fast.py", "gold.py")


def wait_port(port, seconds=120):
    end = time.time() + seconds
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            return True
        except OSError:
            time.sleep(1)
    return False


def screen(port):
    """What the game is showing now, or None if it stopped answering."""
    try:
        c = socket.create_connection(("127.0.0.1", port), timeout=10)
        c.settimeout(30)
        c.sendall(b'{"cmd":"state","x":0,"y":0,"w":1,"h":1}\n')
        reply = c.makefile("rb").readline()
        c.close()
        return json.loads(reply).get("screen")
    except (OSError, ValueError):
        return None


def next_step(script_index, exit_code, shown):
    """After a bot script: 'next' script, 'retry' the chain in a new life, or 'stop' and why."""
    if exit_code == 0:
        return ("next", "") if script_index + 1 < len(BOT_SCRIPTS) else ("stop", "done")
    if shown == "dead":
        return "retry", ""
    return "stop", f"bot gave up alive on {shown}" if shown else "game stopped answering"


def play(run, env, lives, deadline):
    """Plays every life of one seed.  Returns how it ended."""
    for life in range(lives):
        for i, script in enumerate(BOT_SCRIPTS):
            left = deadline - time.time()
            if left <= 0:
                return "out of time"
            with open(os.path.join(run, "bot.out"), "a") as out:
                out.write(f"--- life {life + 1} {script}\n")
                out.flush()
                try:
                    code = subprocess.run([sys.executable, "-B", script], cwd=HERE, env=env, stdout=out,
                                          stderr=subprocess.STDOUT, timeout=left).returncode
                except subprocess.TimeoutExpired:
                    return "out of time"
            what, why = next_step(i, code, screen(BRIDGE_PORT))
            if what == "stop":
                return why
            if what == "retry":
                break
    return "out of lives"


def run_seed(out_dir, seed, lives, minutes):
    run = os.path.join(out_dir, f"seed{seed}")
    os.makedirs(run)
    open(os.path.join(run, "agent_sandbox"), "w").close()
    with open(os.path.join(run, "seed"), "w") as f:
        f.write(f"{seed}\n")
    for name in ("sprites", "sounds"):
        os.symlink(os.path.join(ROOT, name), os.path.join(run, name))
    binary = os.path.join(out_dir, "gnipa")
    env = dict(os.environ, GNIPA_SEED=str(seed), GNIPA_AGENT_PORT=str(GAME_PORT),
               GNIPA_BRIDGE_PORT=str(BRIDGE_PORT), GNIPA_AGENT_TURBO="1")
    start = time.time()
    with open(os.path.join(run, "game.out"), "w") as out:
        game = subprocess.Popen([binary], cwd=run, env=env, stdout=out, stderr=subprocess.STDOUT)
        bridge = subprocess.Popen([sys.executable, "-B", os.path.join(HERE, "bridge.py")], env=env,
                                  stdout=out, stderr=subprocess.STDOUT)
        try:
            ended = "bridge never came up"
            if wait_port(BRIDGE_PORT):
                ended = play(run, env, lives, start + minutes * 60)
        finally:
            for p in (bridge, game):
                p.send_signal(signal.SIGTERM)
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()
    with open(os.path.join(run, "result.json"), "w") as f:
        json.dump({"seed": seed, "ended": ended, "wall_s": round(time.time() - start)}, f)
    print(f"seed {seed}: {ended}", flush=True)
    return run


def main(argv):
    lives, minutes = 3, 60
    if "--lives" in argv:
        i = argv.index("--lives")
        lives = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if "--minutes" in argv:
        i = argv.index("--minutes")
        minutes = float(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if len(argv) < 2:
        sys.exit(__doc__)
    out_dir = os.path.abspath(argv[0])
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run(["odin", "build", "src", "-out:" + os.path.join(out_dir, "gnipa")], cwd=ROOT, check=True)
    runs = [run_seed(out_dir, int(s), lives, minutes) for s in argv[1:]]
    report = os.path.join(ROOT, "tools", "agent_pacing.py")
    subprocess.run([sys.executable, "-B", report, *runs, "--csv", os.path.join(out_dir, "pacing.csv")])
    os.remove(os.path.join(out_dir, "gnipa"))


if __name__ == "__main__":
    main(sys.argv[1:])
