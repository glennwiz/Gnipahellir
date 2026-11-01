#!/usr/bin/env python3
"""Plays a recorded agent run back in the game window, from its own binary and
seed, and checks each act lands where it did. Usage: tools/agent_replay.py <run folder> [port]"""
import json, os, socket, subprocess, sys, time

run = os.path.abspath(sys.argv[1])
port = int(sys.argv[2]) if len(sys.argv) > 2 else 7779
out = os.path.join(run, "replay-" + time.strftime("%H%M%S"))
os.makedirs(out)
open(os.path.join(out, "agent_sandbox"), "w").close()
for name in ("sprites", "sounds"):
    os.symlink(os.path.realpath(os.path.join(run, name)), os.path.join(out, name))
seed = open(os.path.join(run, "seed")).read().strip()
game = subprocess.Popen([os.path.join(run, "gnipa")], cwd=out, stdout=subprocess.DEVNULL,
                        env={**os.environ, "GNIPA_SEED": seed, "GNIPA_AGENT_PORT": str(port)})
for _ in range(120):
    if game.poll() is not None:
        sys.exit("the game exited before listening: is the port taken?")
    try:
        sock = socket.create_connection(("127.0.0.1", port))
        break
    except OSError:
        time.sleep(0.5)
else:
    sys.exit("the game did not start listening")
replies = sock.makefile("r")
sock.sendall(b'{"cmd":"idle","on":false}\n')  # recorded idle ticks are played as acts
replies.readline()

done, status = 0, 0
for raw in open(os.path.join(run, "acts.jsonl")):
    rec = json.loads(raw)
    if "mark" in rec:
        print(f"stopped at frame {rec['f']}: {rec['mark']} let wall time in, so the rest cannot be replayed")
        break
    if "idle" in rec:
        sock.sendall((json.dumps({"cmd": "wait", "frames": rec["idle"]}) + "\n").encode())
        replies.readline()
        continue
    if "objective" in rec:
        sock.sendall((json.dumps(rec["objective"]) + "\n").encode())
        replies.readline()
        continue
    if "played" in rec:  # a plan step the agent overrode part way
        rec["act"]["frames"] = rec["played"]
    sock.sendall((json.dumps({**rec["act"], "cmd": rec["act"].get("cmd", "act")}) + "\n").encode())
    reply = json.loads(replies.readline())
    p = reply["player"]
    want = (rec["f"], rec["x"], rec["y"], rec["hp"], rec["lvl"], rec["mana"])
    got = (reply["frame"], p["x"], p["y"], p["hp"], reply["level"], p["mana"])
    if want[0] != got[0] or abs(want[1] - got[1]) > 0.01 or abs(want[2] - got[2]) > 0.01 or want[3:5] != got[3:5] or abs(want[5] - got[5]) > 0.1:
        print(f"DIVERGED after {done} acts: recorded {want}, replayed {got}")
        status = 1
        break
    done += 1
print(f"{done} acts replayed; close the game window when done watching")
replies.close()
sock.close()
game.wait()
sys.exit(status)
