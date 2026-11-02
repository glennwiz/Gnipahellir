#!/usr/bin/env python3
"""python3 tools/test_agent_pacing.py"""
import contextlib, csv, io, json, os, socket, subprocess, sys, tempfile, time, unittest
from unittest import mock
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent_bot"))
import agent_pacing as ap
import pace
import b as bot

TWO_LIVES = """\
[f0000000] === run start 2026-11-02 15:05:22 - save v28 ===
[f0000000] World seed 111
[f0000600] Player takes Gold_Bar x4 from smelter at (1,2)
[f0001200] Player dies at (40,64) after 20 s
[f0000000] New game - world seed 222
continuation line with no frame
[f0003000] Player takes Silver_Bar x9 from smelter at (1,2)
[f0006000] Player takes Rune Scroll A from permanent chest at (1,1)
[f0009000] Player takes Rune Scroll B from permanent chest at (12,101)
[f0009060] Player takes Rune Scroll B from permanent chest at (12,101)
[f0012000] Player takes Gold_Bar x9 from smelter at (1,2)
[f0012600] Player takes Gold_Bar x1 from smelter at (1,2)
[f0013000] Player takes Gold_Bar x5 from smelter at (1,2)
""".splitlines()


class Parse(unittest.TestCase):
    def setUp(self):
        self.lives = ap.parse(TWO_LIVES)

    def test_a_new_game_starts_a_life_with_its_own_seed(self):
        self.assertEqual([l["seed"] for l in self.lives], [111, 222])

    def test_marks_land_in_the_life_that_made_them(self):
        one, two = self.lives
        self.assertIsNone(one["scroll_b_s"])
        self.assertEqual(two["scroll_b_s"], 150)

    def test_scroll_a_does_not_count_and_the_first_b_does(self):
        self.assertEqual(self.lives[1]["scroll_b_s"], 9000 / 60)

    def test_ten_bars_add_up_across_collections_and_only_gold(self):
        self.assertEqual(self.lives[1]["gold_10_s"], 12600 / 60)
        self.assertEqual(self.lives[1]["bars"], 15)

    def test_bars_do_not_carry_over_a_death(self):
        self.assertIsNone(self.lives[0]["gold_10_s"])
        self.assertEqual(self.lives[0]["bars"], 4)

    def test_nine_bars_are_not_ten(self):
        lives = ap.parse(["[f0000060] Player takes Gold_Bar x9 from smelter at (1,2)"])
        self.assertIsNone(lives[0]["gold_10_s"])

    def test_exactly_ten_is_ten(self):
        lives = ap.parse(["[f0000060] Player takes Gold_Bar x10 from smelter at (1,2)"])
        self.assertEqual(lives[0]["gold_10_s"], 1)

    def test_death_and_length(self):
        self.assertTrue(self.lives[0]["died"])
        self.assertFalse(self.lives[1]["died"])
        self.assertEqual(self.lives[0]["lasted_s"], 20)
        self.assertEqual(self.lives[1]["lasted_s"], 13000 / 60)


class Rows(unittest.TestCase):
    def test_before_counts_the_lives_lost_on_the_way(self):
        r = ap.rows("a", ap.parse(TWO_LIVES))
        self.assertEqual([x["life"] for x in r], [1, 2])
        self.assertEqual([x["before_s"] for x in r], [0, 20])
        self.assertEqual(r[1]["run"], "a")

    def test_first_takes_the_earliest_life_and_adds_what_came_before(self):
        r = [{"scroll_b_s": None, "before_s": 0}, {"scroll_b_s": 5, "before_s": 7}, {"scroll_b_s": 1, "before_s": 30}]
        self.assertEqual(ap.first(r, "scroll_b_s"), (5, 12))
        self.assertIsNone(ap.first(r[:1], "scroll_b_s"))


class Summary(unittest.TestCase):
    def run_of(self, b, gold=None, before=0):
        return [{"scroll_b_s": b, "gold_10_s": gold, "before_s": before}]

    def test_medians_are_over_the_runs_that_got_there_and_say_how_many(self):
        s = ap.summary([self.run_of(10, 100), self.run_of(30), self.run_of(20, before=5), self.run_of(None)])
        self.assertEqual(s["scroll_b_s"], {"reached": 3, "of": 4, "median_s": 20, "median_with_deaths_s": 25})
        self.assertEqual(s["gold_10_s"]["reached"], 1)
        self.assertEqual(s["gold_10_s"]["median_s"], 100)

    def test_no_run_got_there(self):
        s = ap.summary([self.run_of(None)])
        self.assertIsNone(s["gold_10_s"]["median_s"])
        self.assertEqual(ap.fmt(None), "-")
        self.assertEqual(ap.fmt(149.6), "150")


class Main(unittest.TestCase):
    def test_reads_a_folder_prints_and_writes_csv(self):
        with tempfile.TemporaryDirectory() as d:
            run = os.path.join(d, "run1")
            os.mkdir(run)
            with open(os.path.join(run, "action.log"), "w") as f:
                f.write("\n".join(TWO_LIVES))
            out = os.path.join(d, "o.csv")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                ap.main([run + "/", "--csv", out])
            text = buf.getvalue()
            self.assertIn("scroll_b_s: reached 1 of 1, median 150 s, with lost lives 170 s", text)
            self.assertIn("gold_10_s: reached 1 of 1, median 210 s, with lost lives 230 s", text)
            self.assertIn("run1", text)
            with open(out) as f:
                got = list(csv.DictReader(f))
            self.assertEqual(len(got), 2)
            self.assertEqual(got[1]["seed"], "222")
            self.assertEqual(got[1]["scroll_b_s"], "150.0")
            self.assertEqual(got[0]["scroll_b_s"], "")

    def test_no_folders_says_how(self):
        with self.assertRaises(SystemExit):
            ap.main([])


class Play(unittest.TestCase):
    """pace.play with the bot and the game stubbed: codes per script run, then what shows."""

    def play(self, codes, shown, lives=3, deadline=None):
        runs = []

        def run(cmd, **kw):
            runs.append(cmd[-1])
            return mock.Mock(returncode=codes[len(runs) - 1])

        with tempfile.TemporaryDirectory() as d, mock.patch.object(pace.subprocess, "run", run), \
             mock.patch.object(pace, "screen", lambda port: shown):
            ended = pace.play(d, {}, lives, time.time() + 60 if deadline is None else deadline)
        return ended, runs

    def test_the_bot_gets_the_seed_env_and_the_screen_is_asked_through_the_bridge(self):
        envs, ports = [], []

        def run(cmd, **kw):
            envs.append(kw["env"])
            return mock.Mock(returncode=1)

        def screen(port):
            ports.append(port)
            return "dead"

        with tempfile.TemporaryDirectory() as d, mock.patch.object(pace.subprocess, "run", run), \
             mock.patch.object(pace, "screen", screen):
            pace.play(d, {"MARK": "1"}, 1, time.time() + 60)
        self.assertEqual(envs, [{"MARK": "1"}])
        self.assertEqual(ports, [pace.BRIDGE_PORT])

    def test_a_clean_seed_runs_every_script_once(self):
        self.assertEqual(self.play([0, 0], "play"), ("done", ["fast.py", "gold.py"]))

    def test_a_death_starts_the_chain_over_in_the_next_life(self):
        self.assertEqual(self.play([0, 1, 0, 0], "dead"), ("done", ["fast.py", "gold.py", "fast.py", "gold.py"]))

    def test_lives_run_out(self):
        self.assertEqual(self.play([1, 1], "dead", lives=2), ("out of lives", ["fast.py", "fast.py"]))

    def test_giving_up_alive_ends_the_seed(self):
        self.assertEqual(self.play([1], "play"), ("bot gave up alive on play", ["fast.py"]))

    def test_a_spent_deadline_runs_nothing(self):
        self.assertEqual(self.play([], "play", deadline=time.time() - 1), ("out of time", []))

    def test_a_script_past_the_deadline_is_cut_off(self):
        def run(cmd, **kw):
            self.assertLessEqual(kw["timeout"], 60)
            raise pace.subprocess.TimeoutExpired(cmd, kw["timeout"])

        with tempfile.TemporaryDirectory() as d, mock.patch.object(pace.subprocess, "run", run):
            self.assertEqual(pace.play(d, {}, 3, time.time() + 60), "out of time")


class RunSeed(unittest.TestCase):
    def test_game_and_bridge_get_the_harness_settings(self):
        seen, waited, played = [], [], []

        def popen(cmd, **kw):
            seen.append(kw["env"])
            return mock.Mock()

        def wait_port(port):
            waited.append(port)
            return True

        def play(run, env, lives, deadline):
            played.append((run, env, lives, deadline))
            return "done"

        start = time.time()
        with tempfile.TemporaryDirectory() as d, mock.patch.object(pace.subprocess, "Popen", popen), \
             mock.patch.object(pace, "wait_port", wait_port), mock.patch.object(pace, "play", play):
            pace.run_seed(d, 7, 2, 5)
            with open(os.path.join(d, "seed7", "result.json")) as f:
                self.assertEqual(json.load(f)["ended"], "done")
            with open(os.path.join(d, "seed7", "seed")) as f:
                self.assertEqual(f.read().strip(), "7")
            self.assertTrue(os.path.exists(os.path.join(d, "seed7", "agent_sandbox")))
        self.assertEqual(len(seen), 2)
        for env in seen:
            self.assertEqual(env["GNIPA_AGENT_TURBO"], "1")
            self.assertEqual(env["GNIPA_SEED"], "7")
            self.assertEqual(env["GNIPA_AGENT_PORT"], str(pace.GAME_PORT))
            self.assertEqual(env["GNIPA_BRIDGE_PORT"], str(pace.BRIDGE_PORT))
        self.assertEqual(waited, [pace.BRIDGE_PORT])
        run, env, lives, deadline = played[0]
        self.assertEqual(os.path.basename(run), "seed7")
        self.assertIs(env, seen[0], "the bot talks to the bridge the game was started with")
        self.assertEqual(lives, 2)
        self.assertAlmostEqual(deadline, start + 5 * 60, delta=5)


class PaceMain(unittest.TestCase):
    def call(self, argv):
        calls, seeds = [], []

        def run(cmd, **kw):
            calls.append(cmd)
            if cmd[0] == "odin":
                open(cmd[-1].removeprefix("-out:"), "w").close()

        def run_seed(out_dir, seed, lives, minutes):
            seeds.append((seed, lives, minutes))
            return os.path.join(out_dir, f"seed{seed}")

        with tempfile.TemporaryDirectory() as d, mock.patch.object(pace.subprocess, "run", run), \
             mock.patch.object(pace, "run_seed", run_seed):
            pace.main([d, *argv])
            self.assertFalse(os.path.exists(os.path.join(d, "gnipa")), "the run's binary is cleaned up")
            return d, calls, seeds

    def test_flags_reach_every_seed(self):
        _, _, seeds = self.call(["5", "--lives", "2", "6", "--minutes", "1.5"])
        self.assertEqual(seeds, [(5, 2, 1.5), (6, 2, 1.5)])

    def test_defaults(self):
        self.assertEqual(self.call(["5"])[2], [(5, 3, 60)])

    def test_builds_debug_first_and_reports_last(self):
        d, calls, _ = self.call(["5", "6"])
        self.assertEqual(calls[0], ["odin", "build", "src", "-out:" + os.path.join(d, "gnipa")])
        self.assertEqual(len(calls), 2)
        report = calls[1]
        self.assertTrue(report[2].endswith("agent_pacing.py"))
        self.assertEqual(report[3:], [os.path.join(d, "seed5"), os.path.join(d, "seed6"),
                                      "--csv", os.path.join(d, "pacing.csv")])

    def test_no_seeds_says_how(self):
        with self.assertRaises(SystemExit):
            pace.main(["out"])


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Bridge(unittest.TestCase):
    """The real bridge.py against a fake game: what is the first line the game hears?"""

    def first_line(self, turbo):
        game_port, bridge_port = free_port(), free_port()
        env = {k: v for k, v in os.environ.items() if k != "GNIPA_AGENT_TURBO"}
        env.update(GNIPA_AGENT_PORT=str(game_port), GNIPA_BRIDGE_PORT=str(bridge_port))
        if turbo:
            env["GNIPA_AGENT_TURBO"] = "1"
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", game_port))
            listener.listen(1)
            listener.settimeout(10)
            bridge = subprocess.Popen([sys.executable, "-B", os.path.join(os.path.dirname(pace.__file__), "bridge.py")],
                                      env=env, stdout=subprocess.DEVNULL)
            try:
                game, _ = listener.accept()
                game.settimeout(10)
                reader = game.makefile("rb")
                game_lines = []

                def answer():
                    game_lines.append(json.loads(reader.readline()))
                    game.sendall(b'{"ok":true}\n')

                if turbo:
                    answer()  # the bridge waits on this before it serves anyone
                self.assertTrue(pace.wait_port(bridge_port, 10))
                client = socket.create_connection(("127.0.0.1", bridge_port), timeout=10)
                client.sendall(b'{"cmd":"state"}\n')
                answer()
                client.close()
                game.close()
                return game_lines
            finally:
                bridge.kill()
                bridge.wait()

    def test_a_turbo_bridge_turns_idling_off_before_anything_else(self):
        self.assertEqual(self.first_line(True), [{"cmd": "idle", "on": False}, {"cmd": "state"}])

    def test_a_plain_bridge_leaves_idling_alone(self):
        self.assertEqual(self.first_line(False), [{"cmd": "state"}])


class EndPlan(unittest.TestCase):
    def thinks(self, turbo, planned=False):
        stub = mock.Mock(planned=planned)
        env = {"GNIPA_AGENT_TURBO": "1"} if turbo else {}
        with mock.patch.dict(os.environ, env):
            if not turbo:
                os.environ.pop("GNIPA_AGENT_TURBO", None)
            bot.B.endplan(stub)
        return stub.think.call_count

    def test_a_turbo_run_sends_no_plan(self):
        self.assertEqual(self.thinks(True), 0)

    def test_a_plain_run_still_leaves_one(self):
        self.assertEqual(self.thinks(False), 1)

    def test_one_already_sent_is_not_sent_twice(self):
        self.assertEqual(self.thinks(False, planned=True), 0)


class NextStep(unittest.TestCase):
    def test_a_clean_script_hands_on_and_the_last_one_ends_the_seed(self):
        self.assertEqual(pace.next_step(0, 0, "play"), ("next", ""))
        self.assertEqual(pace.next_step(len(pace.BOT_SCRIPTS) - 1, 0, "play"), ("stop", "done"))

    def test_a_death_takes_the_next_life(self):
        self.assertEqual(pace.next_step(0, 1, "dead"), ("retry", ""))

    def test_giving_up_alive_ends_the_seed_and_says_so(self):
        self.assertEqual(pace.next_step(0, 1, "play"), ("stop", "bot gave up alive on play"))
        self.assertEqual(pace.next_step(0, 1, None), ("stop", "game stopped answering"))


if __name__ == "__main__":
    unittest.main()
