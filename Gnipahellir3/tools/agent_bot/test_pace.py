#!/usr/bin/env python3
"""python3 tools/agent_bot/test_pace.py  (the bot and its harness; they go with card 154)"""
import contextlib, csv, io, json, os, socket, subprocess, sys, tempfile, time, unittest
from unittest import mock
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pace
import b as bot


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
