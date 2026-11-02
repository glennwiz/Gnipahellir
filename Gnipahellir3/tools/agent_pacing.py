#!/usr/bin/env python3
"""Pacing from run logs: seconds to Scroll B and to 10 Gold Bars (design review P14).
Reads action.log, so it works on any run folder, an agent's or a playtest's.
Usage: tools/agent_pacing.py <run folder>... [--csv out.csv]

A row per life, then the median over the first life of each folder to reach each
mark. Seconds are frames / 60: the agent's fixed step, and a player's clock when
the game holds 60 fps. "before" also counts the lives lost on the way there."""
import csv, os, re, statistics, sys

FPS = 60
GOLD_GOAL = 10
FIELDS = ["run", "life", "seed", "scroll_b_s", "gold_10_s", "lasted_s", "died", "before_s"]

FRAME = re.compile(r"^\[f(\d+)\] (.*)")
SEED = re.compile(r"[Ww]orld seed (\d+)")
BARS = re.compile(r"Player takes Gold_Bar x(\d+) from smelter")
SCROLL_B = "Player takes Rune Scroll B from"


def new_life(seed=None):
    return {"seed": seed, "scroll_b_s": None, "gold_10_s": None, "lasted_s": 0.0, "died": False, "bars": 0}


def parse(lines):
    """One dict per life, in order. A New Game zeroes the frame clock."""
    lives = [new_life()]
    for line in lines:
        m = FRAME.match(line)
        if not m:
            continue
        seconds, text = int(m[1]) / FPS, m[2]
        life = lives[-1]
        if text.startswith("New game"):
            lives.append(new_life())
            life = lives[-1]
        else:
            life["lasted_s"] = max(life["lasted_s"], seconds)
        if s := SEED.search(text):
            life["seed"] = int(s[1])
        if text.startswith(SCROLL_B) and life["scroll_b_s"] is None:
            life["scroll_b_s"] = seconds
        if b := BARS.search(text):
            life["bars"] += int(b[1])
            if life["bars"] >= GOLD_GOAL and life["gold_10_s"] is None:
                life["gold_10_s"] = seconds
        if text.startswith("Player dies"):
            life["died"] = True
    return lives


def rows(run, lives):
    out, before = [], 0.0
    for i, life in enumerate(lives, 1):
        out.append({"run": run, "life": i, "before_s": before, **{k: life[k] for k in FIELDS if k in life}})
        before += life["lasted_s"]
    return out


def first(run_rows, key):
    """A run's mark: the first life that reached it, as (seconds, seconds with lost lives)."""
    for r in run_rows:
        if r[key] is not None:
            return r[key], r["before_s"] + r[key]
    return None


def median(values):
    return statistics.median(values) if values else None


def summary(runs):
    """runs: one row list per folder.  Medians over the folders that got there."""
    out = {}
    for key in ("scroll_b_s", "gold_10_s"):
        got = [m for m in (first(r, key) for r in runs) if m is not None]
        out[key] = {"reached": len(got), "of": len(runs),
                    "median_s": median([g[0] for g in got]),
                    "median_with_deaths_s": median([g[1] for g in got])}
    return out


def fmt(v):
    return "-" if v is None else f"{v:.0f}"


def main(argv):
    out_csv = None
    if "--csv" in argv:
        i = argv.index("--csv")
        out_csv = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if not argv:
        sys.exit(__doc__)
    runs = []
    for folder in argv:
        with open(os.path.join(folder, "action.log"), errors="replace") as f:
            runs.append(rows(os.path.basename(folder.rstrip("/")), parse(f)))
    print(" ".join(f"{h:>12}" for h in FIELDS))
    for r in (r for run in runs for r in run):
        print(" ".join(f"{(fmt(r[h]) if h.endswith('_s') else str(r[h])):>12}" for h in FIELDS))
    for key, s in summary(runs).items():
        print(f"{key}: reached {s['reached']} of {s['of']}, median {fmt(s['median_s'])} s, "
              f"with lost lives {fmt(s['median_with_deaths_s'])} s")
    if out_csv:
        with open(out_csv, "w", newline="") as f:
            w = csv.DictWriter(f, FIELDS)
            w.writeheader()
            w.writerows(r for run in runs for r in run)


if __name__ == "__main__":
    main(sys.argv[1:])
