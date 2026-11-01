#!/usr/bin/env python3
"""One page on an agent run, aimed at finding game bugs.
Usage: tools/agent_summary.py <run folder>"""
import collections, csv, json, os, re, sys

run = sys.argv[1]
log = open(os.path.join(run, "action.log"), errors="replace").read().splitlines()

print("== lives ==")
life, deaths = 1, collections.Counter()
last_hurt = None
for line in log:
    if m := re.search(r"Player takes (\d+) damage from (.+?) \(hp", line):
        last_hurt = m.group(2)
    if "Player dies" in line:
        cause = re.sub(r"#\d+", "", last_hurt or "unknown")
        deaths[cause] += 1
        print(f"life {life}: {line.split('] ', 1)[1]} - last hurt by {cause}")
        life += 1
    if "New game" in line:
        print("  " + line.split("] ", 1)[1])
print(f"deaths by cause: {dict(deaths)}")

print("\n== milestones ==")
for line in log:
    if re.search(r"Player enters level|Rune Scroll . from|Garm|Player crafts (Sky_Altar|Fire_Wand|Smelter)", line) and " pos " not in line and " evt " not in line:
        print(line[:100])

print("\n== bug flags ==")
# A body parked on the 5 s breadcrumbs, while not at a den or a job that stands still.
pos = collections.defaultdict(list)
for line in log:
    if m := re.match(r"\[f(\d+)\] pos (Player|Enemy#\d+)(?: (\w+))? \(([\d.]+),([\d.]+)\)", line):
        pos[m.group(2) + " " + (m.group(3) or "")].append((int(m.group(1)), m.group(4), m.group(5)))
for who, track in pos.items():
    run_len, best = 0, 0
    for a, b in zip(track, track[1:]):
        run_len = run_len + 1 if a[1:] == b[1:] and b[0] > a[0] else 0
        if run_len > best:
            best, at = run_len, b
    if best >= 6:
        print(f"stuck: {who}parked {best * 5} s at ({at[1]},{at[2]}), ending frame {at[0]}")
# The same tile mined and placed over and over.
churn = collections.Counter()
for line in log:
    if m := re.search(r"(Builder#?\d*) (mines|places) \((\d+),(\d+)\)", line):
        churn[(m.group(3), m.group(4))] += 1
for tile, n in churn.most_common(5):
    if n >= 8:
        print(f"churn: tile {tile} mined or placed {n} times by builders")
for key in ("no path", "gives up", "WARNING"):
    n = sum(key in line for line in log)
    if n:
        print(f"{key}: {n} lines")

path = os.path.join(run, "acts.jsonl")
if os.path.exists(path):
    print("\n== acts ==")
    acts = [json.loads(l) for l in open(path)]
    played = [a for a in acts if "act" in a]
    goals = []
    for a in acts:
        goal = a.get("objective", {}).get("goal")
        if goal and (not goals or goals[-1]["objective"]["goal"] != goal):
            goals.append(a)
    if goals:
        print("objectives:")
        for a, b in zip(goals, goals[1:] + [None]):
            end = b["f"] if b else acts[-1]["f"]
            note = " (failed)" if b and b["objective"].get("result") == "failed" else ""
            print(f"  f{a['f']}: {a['objective']['goal']} - {(end - a['f']) // 60} s{note}")
    print(f"{len(played)} acts, last frame {acts[-1]['f'] if acts else 0}")
    wasted = collections.Counter()
    for a, b in zip(played, played[1:]):
        same = (a["x"], a["y"], a["hp"]) == (b["x"], b["y"], b["hp"])
        verb = next((k for k in ("mine", "place", "use", "reclaim", "craft", "feed") if k in b["act"]), None)
        if same and verb:
            wasted[verb] += 1
    print(f"acts with no visible effect on the player, by verb: {dict(wasted)}")
    for a in acts:
        if "mark" in a:
            print(f"frame {a['f']}: {a['mark']}")

path = os.path.join(run, "fight.log")
if os.path.exists(path):
    print("\n== fights ==")
    kinds, near_frames = collections.Counter(), set()
    for row in csv.reader(open(path)):
        if len(row) > 3 and row[1] != "P":
            kinds[row[2]] += 1
            near_frames.add(row[0])
    print(f"{len(near_frames)} frames with enemies near; enemy-frames by kind: {dict(kinds)}")
