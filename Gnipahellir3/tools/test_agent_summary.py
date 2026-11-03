#!/usr/bin/env python3
"""python3 tools/test_agent_summary.py"""
import os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def summary(log):
    with tempfile.TemporaryDirectory() as run:
        with open(os.path.join(run, "action.log"), "w") as f:
            f.write(log)
        return subprocess.run([sys.executable, os.path.join(HERE, "agent_summary.py"), run],
                              capture_output=True, text=True, check=True).stdout


class Churn(unittest.TestCase):
    def test_builder_mines_and_places_count_on_one_tile(self):
        lines = ["[f0000010] Builder#1 mines (5,6)", "[f0000020] Builder#1 places at (5,6)"] * 4
        self.assertIn("churn: tile ('5', '6') mined or placed 8 times by builders", summary("\n".join(lines) + "\n"))

    def test_old_unnamed_lines_count_too(self):
        lines = ["[f0000010] Builder mines (5,6)", "[f0000020] Builder places at (5,6)"] * 4
        self.assertIn("mined or placed 8 times", summary("\n".join(lines) + "\n"))

    def test_other_kinds_are_not_builder_churn(self):
        lines = ["[f0000010] Vargr#2 mines (5,6)", "[f0000020] Vargr#2 places at (5,6)"] * 4
        self.assertNotIn("churn:", summary("\n".join(lines) + "\n"))


if __name__ == "__main__":
    unittest.main()
