#!/usr/bin/env python3
"""The title's "Let an agent play", in a real game: the address serves the brief, a
socket client plays on it through an autosave, and the human's save, stats, settings
and action.log do not change by one byte.  Nor do their write times.
Boots with GNIPA_AGENT_TITLE, which stands in for the [A] key.  Needs a display.
Usage: tools/test_agent_title.py [port] [-define:GAME_DEBUG=false]"""
import glob, hashlib, json, os, shutil, signal, socket, subprocess, sys, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "build", "agent_title_test")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 47611
DEFINES = sys.argv[2:]
HUMAN = ("gnipahellir_save.dat", "gnipahellir_stats.dat", "gnipahellir_settings.dat", "action.log")


def digest(folder):
    """Every file the human has, by bytes and by write time."""
    out = {}
    for name in sorted(os.listdir(folder)):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and name != "gnipa":
            with open(path, "rb") as f:
                out[name] = (hashlib.sha256(f.read()).hexdigest(), os.stat(path).st_mtime_ns)
    return out


def launch(binary, folder, env):
    return subprocess.Popen([binary], cwd=folder, env={**os.environ, **env}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def connect(port):
    for _ in range(120):
        try:
            return socket.create_connection(("127.0.0.1", port), timeout=120)
        except OSError:
            time.sleep(0.5)
    sys.exit("the game never listened")


def stop(game):
    """A closed window runs the quit save, where the compositor can close one for us."""
    closed = False
    if shutil.which("hyprctl"):
        subprocess.call(["hyprctl", "dispatch", "closewindow", f"pid:{game.pid}"], stdout=subprocess.DEVNULL)
        try:
            game.wait(20)
            closed = True
        except subprocess.TimeoutExpired:
            pass
    if not closed:
        game.terminate()
        game.wait(30)
    return closed


def session(c):
    f = c.makefile("rb")

    def ask(**o):
        c.sendall((json.dumps(o) + "\n").encode())
        return json.loads(f.readline())

    ask(cmd="idle", on=False)
    return ask


def dig_until_saved(ask, folder):
    """Taking up the pickaxe, which waits down the shaft, sets off the autosave."""
    for _ in range(200):
        if os.path.exists(os.path.join(folder, HUMAN[0])):
            return
        x = ask(cmd="state", w=1, h=1)["player"]["x"]
        ask(cmd="act", move="right" if x < 96.1 else "left", frames=6)
    sys.exit("the run never autosaved")


def link_assets(folder):
    for name in ("sprites", "sounds"):
        os.symlink(os.path.join(ROOT, name), os.path.join(folder, name))


def main():
    shutil.rmtree(WORK, ignore_errors=True)
    human = os.path.join(WORK, "human")
    seeded = os.path.join(WORK, "seeded")
    os.makedirs(human)
    os.makedirs(seeded)
    binary = os.path.join(human, "gnipa")
    seeder = os.path.join(seeded, "gnipa")
    subprocess.check_call(["odin", "build", "src", "-out:" + binary, *DEFINES], cwd=ROOT)
    subprocess.check_call(["odin", "build", "src", "-out:" + seeder], cwd=ROOT)
    link_assets(human)
    link_assets(seeded)

    # A real save and stats to protect: what an earlier run leaves in its folder.
    game = launch(seeder, seeded, {"GNIPA_SEED": "77", "GNIPA_AGENT_TITLE": str(PORT), "GNIPA_AGENT_TURBO": "1"})
    try:
        ask = session(connect(PORT))
        ask(cmd="act", dismiss=True, frames=2)
        played = glob.glob(os.path.join(seeded, "agent_runs", "*"))[0]
        dig_until_saved(ask, played)
    finally:
        stop(game)
    shutil.copy(os.path.join(played, HUMAN[0]), human)
    shutil.copy(os.path.join(played, HUMAN[1]), human)
    for name in HUMAN[2:]:
        with open(os.path.join(human, name), "wb") as f:
            f.write(b"the human's own " + name.encode() + b"\n")
    before = digest(human)

    game = launch(binary, human, {"GNIPA_SEED": "4242", "GNIPA_AGENT_TITLE": str(PORT), "GNIPA_AGENT_TURBO": "1"})
    try:
        connect(PORT).close()
        brief = urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=30).read().decode()
        assert f"127.0.0.1:{PORT}" in brief and "world seed: 4242" in brief, brief[:300]
        assert "screen: title" in brief, "reading the brief leaves the title up"

        ask = session(connect(PORT))
        first = ask(cmd="state")
        assert first["screen"] == "title", first["screen"]
        again = urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=30).read().decode()
        assert "another agent is connected" in again, "the brief answers while a client plays"
        reply = ask(cmd="act", dismiss=True, frames=2)
        assert reply["screen"] == "play", reply["screen"]
        assert ask(cmd="objective", goal="prove the sandbox")["ok"]
        run = glob.glob(os.path.join(human, "agent_runs", "*"))[0]
        dig_until_saved(ask, run)
    finally:
        quit_saved = stop(game)

    after = digest(human)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    assert not changed, f"the human's folder changed: {changed}"
    assert len(glob.glob(os.path.join(human, "agent_runs", "*"))) == 1
    assert os.path.exists(os.path.join(run, "agent_sandbox"))
    with open(os.path.join(run, "seed")) as f:
        assert f.read().strip() == "4242"
    with open(os.path.join(run, "acts.jsonl")) as f:
        assert any("act" in json.loads(line) for line in f)
    assert os.path.exists(os.path.join(run, HUMAN[1])), "the run's stats stayed in its folder"
    assert os.path.exists(os.path.join(run, HUMAN[0])), "the run's save stayed in its folder"
    if not DEFINES:
        with open(os.path.join(run, "action.log")) as f:
            log = f.read()
        assert "=== run start" in log and "World seed 4242" in log and "the human's own" not in log, log[:200]
    if quit_saved:
        assert os.path.exists(os.path.join(run, HUMAN[2])), "the quit save stayed in the run's folder too"
    print("ok:", "quit save run," if quit_saved else "no quit save,", len(after), "human files byte-identical, run in", os.path.relpath(run, ROOT))
    shutil.rmtree(WORK)


signal.signal(signal.SIGALRM, lambda *_: sys.exit("deadline"))  # sys.exit: stops the game on the way out
signal.alarm(240)
main()
