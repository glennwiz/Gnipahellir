#!/usr/bin/env python3
"""What each Builder did, per life and level, read off a run's action.log.
Usage: tools/builder_trace.py <run folder> [--min-frames N] [--tiles N]

Reports goal time shares (from the 5 s breadcrumbs), tiles touched repeatedly,
place-then-mine pairs, A-B-A cycles of goal and position, time still while not
idle, strikes, give-ups, dens and hoards. Old logs name no Builder on `mines`,
`places` and `clears climb` lines, so those go to the nearest Builder on the
breadcrumbs and are marked ~ in the output; logs that carry the id do not need it.

A world only ticks while the player is on its level, so a level's clock here is
frames with the player there. A new life is a new world, and frames restart.
"""
import argparse, bisect, collections, os, re

POS = re.compile(r"pos Enemy#(\d+) Builder \(([\d.]+),([\d.]+)\) hp=(\d+) goal=(\w+) target=\((-?\d+),(-?\d+)\)")
PPOS = re.compile(r"pos Player \(([\d.]+),([\d.]+)\) hp=(-?\d+) mana=\S+ lvl=(\d+)")
EVENT = [
    ("harvest", re.compile(r"Builder#(\d+) harvests (\w+) at \((\d+),(\d+)\)")),
    ("encase", re.compile(r"Builder#(\d+) encases den with (\w+) at \((\d+),(\d+)\)")),
    ("build", re.compile(r"Builder#(\d+) builds (\w+) at \((\d+),(\d+)\)")),
    ("carve", re.compile(r"Builder#(\d+) (carves) \((\d+),(\d+)\)")),
    ("mine", re.compile(r"Builder#?(\d*) (mines) \((\d+),(\d+)\)")),
    ("climb", re.compile(r"Builder#?(\d*) (clears) climb tile \((\d+),(\d+)\)")),
    ("place", re.compile(r"Builder#?(\d*) (places) at \((\d+),(\d+)\)")),
]
PUTS = {"encase", "build", "place"}
TAKES = {"harvest", "carve", "mine", "climb"}
COUNTERS = [
    ("no_path", re.compile(r"Builder#(\d+) strike \d+ \(no path\)")),
    ("no_progress", re.compile(r"Builder#(\d+) strike \d+ \(no progress\)")),
    ("cant_place", re.compile(r"Builder#(\d+) strike \d+ \(can't place\)")),
    ("cant_build", re.compile(r"Builder#(\d+) strike \d+ \(can't build\)")),
    ("give_up", re.compile(r"Builder#(\d+) gives up on")),
    ("cant_home", re.compile(r"Builder#(\d+) can't get home")),
    ("abandon", re.compile(r"Builder#(\d+) abandons den site")),
    ("den_start", re.compile(r"Builder#(\d+) starts den at")),
    ("den_done", re.compile(r"Builder#(\d+) den complete")),
    ("hoard", re.compile(r"Builder#(\d+) stockpiles")),
    ("escape", re.compile(r"Builder#(\d+) escape ends")),
    ("hunt", re.compile(r"Builder#(\d+) (?:spots the player|den breached)")),
    ("dig_free", re.compile(r"Builder#(\d+) digs itself free")),
]
LOOP_ESCAPE = re.compile(r"Builder#?(\d*) loops at \((\d+),(\d+)\)")
# Lines a log only has if its build carries the run 6 instrumentation.
NAV = re.compile(r"nav#(\d+) goal=(\w+) from=\((\d+),(\d+)\) to=\((\d+),(\d+)\) stop=(\d+) budget=(\d+) ok=(\w+) complete=(\w+) len=(\d+) end=\((\d+),(\d+)\) nodes=(\d+) us=(\d+)")
BEAT = re.compile(r"beat#(\d+) lvl=\d+ \(([\d.]+),([\d.]+)\) .*goal=(\w+) resume=\w+ carry=(\w+) pocket=(\d+) anchor=\((\d+),(\d+)\) den=(\w+) step=\d+ open=(\d+)\+(\d+) hoard=(\d+)")
OWN_DEN = re.compile(r"Builder#(\d+) (?:mines|clears climb tile) \(\d+,\d+\).* was=(\w+) goal=(\w+) dbg_den=#(\d+)\(")


class Bot:
    def __init__(self):
        self.track = []  # (frame, x, y, goal, tx, ty)
        self.ops = []    # (frame, kind, x, y, attributed)
        self.count = collections.Counter()
        self.anchors = []
        self.nav = []    # (frame, goal, from, to, ok, complete, len, end, nodes, us)
        self.beats = []  # (frame, goal, open_wall, open_shell, hoard, den)
        self.signs = []  # (frame, loop name), from logs that say which Builder


def parse(path):
    worlds = collections.defaultdict(lambda: collections.defaultdict(Bot))
    clock = collections.Counter()
    orphans = collections.defaultdict(list)
    life, level, entered, frame = 1, 0, 0, 0
    with open(path, errors="replace") as f:
        for line in f:
            m = re.match(r"\[f(\d+)\] (.*)", line)
            if not m:
                continue
            frame, body = int(m.group(1)), m.group(2)
            if body.startswith("New game"):
                clock[(life, level)] += max(0, last_frame(worlds, life) - entered)
                life, level, entered = life + 1, 0, 0
                continue
            if lm := re.match(r"Player enters level (\d+)", body):
                clock[(life, level)] += frame - entered
                level, entered = int(lm.group(1)), frame
                continue
            key = (life, level)
            if nm := NAV.search(body):
                g = nm.groups()
                worlds[key][int(g[0])].nav.append((frame, g[1], (int(g[2]), int(g[3])), (int(g[4]), int(g[5])), g[8] == "true",
                                                   g[9] == "true", int(g[10]), (int(g[11]), int(g[12])), int(g[13]), int(g[14])))
                continue
            if bm := BEAT.search(body):
                g = bm.groups()
                worlds[key][int(g[0])].beats.append((frame, g[3], int(g[9]), int(g[10]), int(g[11]), g[8] == "true"))
                continue
            if om := OWN_DEN.search(body):
                if om.group(1) == om.group(4):
                    worlds[key][int(om.group(1))].count["own_den_dug"] += 1
                    worlds[key][int(om.group(1))].signs.append((frame, "wall_dig"))
                else:
                    worlds[key][int(om.group(1))].count["other_den_dug"] += 1
            if pm := POS.search(body):
                i, x, y, _, goal, tx, ty = pm.groups()
                worlds[key][int(i)].track.append((frame, float(x), float(y), goal, int(tx), int(ty)))
                continue
            for kind, rx in EVENT:
                if em := rx.search(body):
                    op = (frame, kind, int(em.group(3)), int(em.group(4)))
                    if em.group(1):
                        worlds[key][int(em.group(1))].ops.append(op + (False,))
                    else:
                        orphans[key].append(op)
                    break
            else:
                for name, rx in COUNTERS:
                    if cm := rx.search(body):
                        bot = worlds[key][int(cm.group(1))]
                        bot.count[name] += 1
                        goal = bot.beats[-1][1] if bot.beats else bot.track[-1][3] if bot.track else ""
                        if sign := loop_sign(name, goal):
                            bot.signs.append((frame, sign))
                        if name == "den_start":
                            am = re.search(r"at \((\d+),(\d+)\)", body)
                            worlds[key][int(cm.group(1))].anchors.append((frame, int(am.group(1)), int(am.group(2))))
                        break
                if lm := LOOP_ESCAPE.search(body):
                    if lm.group(1):
                        worlds[key][int(lm.group(1))].count["pillar_loop"] += 1
                        worlds[key][int(lm.group(1))].signs.append((frame, "bounce"))
                    else:
                        orphans[key].append((frame, "loop", int(lm.group(2)), int(lm.group(3))))
    clock[(life, level)] += frame - entered
    for key, ops in orphans.items():
        attribute(worlds[key], ops)
    return worlds, clock


def loop_sign(name, goal):
    """Which loop a strike line belongs to."""
    if name == "no_path":
        return "home_lockout" if goal == "Encase_Den" else "carousel"
    if name in ("give_up",):
        return "carousel"
    if name == "cant_home":
        return "home_lockout"
    if name == "no_progress":
        return "bounce"
    if name == "cant_place":
        return "slot_pinned"
    return None


def loop_minutes(bots):
    """Builder-minutes with at least one sign of each loop, and with any."""
    tally, total, any_loop = collections.Counter(), 0, 0
    for b in bots.values():
        if not b.track:
            continue
        first, last = b.track[0][0] // 3600, b.track[-1][0] // 3600
        total += last - first + 1
        minutes = collections.defaultdict(set)
        for frame, sign in b.signs:
            minutes[frame // 3600].add(sign)
        any_loop += len(minutes)
        for names in minutes.values():
            tally.update(names)
    return tally, total, any_loop


def last_frame(worlds, life):
    return max((b.track[-1][0] for k, w in worlds.items() if k[0] == life for b in w.values() if b.track), default=0)


def where(bot, frame):
    frames = [t[0] for t in bot.track]
    i = bisect.bisect_left(frames, frame)
    if i == 0:
        return bot.track[0][1:3]
    if i == len(frames):
        return bot.track[-1][1:3]
    a, b = bot.track[i - 1], bot.track[i]
    u = (frame - a[0]) / max(1, b[0] - a[0])
    return a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u


def attribute(bots, ops):
    live = {i: b for i, b in bots.items() if b.track}
    for frame, kind, x, y in ops:
        best, best_d = None, 1e9
        for i, b in live.items():
            if frame < b.track[0][0] - 600 or frame > b.track[-1][0] + 600:
                continue
            px, py = where(b, frame)
            d = max(abs(px - x), abs(py - y))
            if d < best_d:
                best, best_d = i, d
        if best is None:
            continue
        if kind == "loop":
            live[best].count["pillar_loop"] += 1
        else:
            live[best].ops.append((frame, kind, x, y, True))
    for b in bots.values():
        b.ops.sort()


def cycles(seq, min_repeats=3, max_period=8):
    """Runs where seq[i] == seq[i-p] for p*(min_repeats-1) steps and seq is not constant."""
    out, i, n = [], 0, len(seq)
    while i < n:
        best = None
        for p in range(2, max_period + 1):
            j = i
            while j + p < n and seq[j] == seq[j + p]:
                j += 1
            span = j - i + p
            if span >= p * min_repeats and len(set(seq[i:i + p])) > 1:
                if best is None or span > best[1]:
                    best = (p, span)
        if best:
            out.append((i, best[0], best[1]))
            i += best[1]
        else:
            i += 1
    return out


def place_mine_pairs(ops):
    """A tile put down, then taken again with nothing between on that tile."""
    last, pairs = {}, []
    for frame, kind, x, y, _ in ops:
        t = (x, y)
        if kind in PUTS:
            last[t] = (frame, kind)
        elif kind in TAKES and t in last:
            f0, k0 = last.pop(t)
            pairs.append((t, k0, kind, f0, frame))
    return pairs


def report_bot(i, b, clock, args):
    t = b.track
    if len(t) < 2:
        return False
    span = t[-1][0] - t[0][0]
    goals = collections.Counter(p[3] for p in t)
    total = sum(goals.values())
    share = " ".join(f"{g} {100 * n // total}%" for g, n in goals.most_common())
    print(f"\n  Builder#{i}: {total} crumbs over frames {t[0][0]}-{t[-1][0]} ({span // 60} s): {share}")

    still, still_best, run, run_at = 0, 0, 0, 0
    for a, c in zip(t, t[1:]):
        same = abs(a[1] - c[1]) < 0.6 and abs(a[2] - c[2]) < 0.6 and c[0] - a[0] <= 330
        if same and c[3] != "Cooldown" and a[3] != "Cooldown":
            still += 1
            run += 1
            if run > still_best:
                still_best, run_at = run, c
        else:
            run = 0
    pct = 100 * still // max(1, len(t) - 1)
    line = f"    still while not idle: {still * 5} s ({pct}%)"
    if still_best >= 2:
        line += f", longest {still_best * 5} s at ({run_at[1]:.1f},{run_at[2]:.1f}) {run_at[3]} ending f{run_at[0]}"
    print(line)

    goal_seq = [p[3] for p in t]
    tile_seq = [(round(p[1] / 3), round(p[2] / 3)) for p in t]
    for name, seq in (("goal", goal_seq), ("position", tile_seq)):
        found = sorted(cycles(seq), key=lambda c: -c[2])[:3]
        for s, p, n in found:
            head = [str(x) for x in seq[s:s + p]]
            if name == "position":
                head = [f"({x * 3},{y * 3})" for x, y in seq[s:s + p]]
            print(f"    {name} cycle, period {p * 5} s, {n * 5} s long, from f{t[s][0]}: {' > '.join(head)}")

    c = b.count
    keys = ["den_start", "den_done", "abandon", "hoard", "no_path", "no_progress", "cant_place",
            "cant_build", "give_up", "cant_home", "pillar_loop", "escape", "dig_free", "hunt",
            "own_den_dug", "other_den_dug"]
    print("    " + " ".join(f"{k}={c[k]}" for k in keys if c[k]))
    kinds = collections.Counter(o[1] for o in b.ops)
    guess = sum(o[4] for o in b.ops)
    print("    ops: " + " ".join(f"{k}={n}" for k, n in kinds.most_common()) + (f" (~{guess} attributed)" if guess else ""))
    report_nav(b)
    report_den(b)
    if b.anchors:
        print("    den sites: " + " ".join(f"({x},{y})@f{f}" for f, x, y in b.anchors[:12]))

    touch = collections.Counter((o[2], o[3]) for o in b.ops)
    hot = [(tile, n) for tile, n in touch.most_common(args.tiles) if n >= 3]
    if hot:
        print("    tiles touched: " + " ".join(f"({x},{y})x{n}" for (x, y), n in hot))
    pairs = place_mine_pairs(b.ops)
    if pairs:
        by = collections.Counter((k0, k1) for _, k0, k1, _, _ in pairs)
        gaps = sorted(f1 - f0 for _, _, _, f0, f1 in pairs)
        print(f"    put then taken: {len(pairs)}, median gap {gaps[len(gaps) // 2]} frames: "
              + " ".join(f"{a}>{d}={n}" for (a, d), n in by.most_common(5)))
        for tile, k0, k1, f0, f1 in pairs[:3]:
            print(f"      e.g. {tile} {k0} f{f0}, {k1} f{f1}")
    return True


def report_nav(b):
    if not b.nav:
        return
    n = len(b.nav)
    fail = sum(not x[4] for x in b.nav)
    partial = sum(x[4] and not x[5] for x in b.nav)
    ms = sum(x[9] for x in b.nav) / 1000
    full = sum(x[8] >= 4000 for x in b.nav)
    print(f"    A*: {n} searches, {fail} no route, {partial} best-effort, {full} ran the node budget, {ms:.0f} ms total")


def report_den(b):
    done = [x for x in b.beats if x[5]]
    if done:
        a, z = done[0], done[-1]
        low = min(x[2] + x[3] for x in done)
        print(f"    den: open slots {a[2]}+{a[3]} at f{a[0]}, {z[2]}+{z[3]} at f{z[0]}, lowest {low}, hoard {z[4]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--min-frames", type=int, default=600, help="skip levels played less than this")
    ap.add_argument("--tiles", type=int, default=8)
    args = ap.parse_args()
    worlds, clock = parse(os.path.join(args.run, "action.log"))
    totals = collections.Counter()
    for key in sorted(worlds):
        life, level = key
        if clock[key] < args.min_frames:
            continue
        print(f"\n== life {life} level {level}: {clock[key]} frames ({clock[key] // 60} s) with the player here ==")
        for i in sorted(worlds[key]):
            b = worlds[key][i]
            if report_bot(i, b, clock[key], args):
                totals.update(b.count)
                totals["bots"] += 1
    print("\n== loop signs by builder-minute ==")
    for key in sorted(worlds):
        tally, total, any_loop = loop_minutes(worlds[key])
        if any_loop:
            parts = " ".join(f"{k} {100 * n // total}%" for k, n in tally.most_common())
            print(f"life {key[0]} level {key[1]}: {100 * any_loop // total}% of {total} builder-minutes: {parts}")
    print("\n== run totals ==")
    print(" ".join(f"{k}={n}" for k, n in sorted(totals.items())))


if __name__ == "__main__":
    main()
