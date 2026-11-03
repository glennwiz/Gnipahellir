#!/usr/bin/env python3
"""python3 tools/test_builder_trace.py"""
import os, sys, tempfile, unittest
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import builder_trace as bt

LOG = """\
[f0000000] === run start ===
[f0000300] pos Enemy#1 Builder (50.0,60.0) hp=10 goal=Hunt target=(0,0)
[f0000310] Builder#1 mines (51,60)
[f0000320] Vargr#2 mines (52,60)
[f0000330] Vargr#2 clears climb tile (52,59)
[f0000340] Vargr#2 places at (53,61)
[f0000350] Raider#3 mines (49,60)
[f0000360] Builder mines (50,61)
[f0000600] pos Enemy#1 Builder (50.0,60.0) hp=10 goal=Hunt target=(0,0)
"""


class Credit(unittest.TestCase):
    def test_named_digs_go_to_their_digger_only(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "action.log")
            with open(path, "w") as f:
                f.write(LOG)
            worlds, _ = bt.parse(path)
        bots = worlds[(1, 0)]
        ops = [(o[1], o[2], o[3], o[4]) for o in bots[1].ops]
        self.assertEqual(ops, [("mine", 51, 60, False), ("mine", 50, 61, True)])
        self.assertNotIn(2, bots)
        self.assertNotIn(3, bots)


if __name__ == "__main__":
    unittest.main()
