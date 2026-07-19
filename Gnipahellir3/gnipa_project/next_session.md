# Next Session Handover (updated 2026-07-19)

## Where things stand

The 2026-07-18 fix session shipped flagg.md's entire top-priority list
(commits 720b68e..a918662, 84 tests green): both CRITICALs (Cloud Stone
20% chance-drop + puffy animated sky clouds; **Runic Dimension Spawner @
500 Gold Bars + 20 Cloud Stone** — the runic tier is finally obtainable),
all four locked decisions (min-1 damage player-only, Garm 75 HP / bite 4 /
fireball 3 with phases at 50/25, rituals B/C cost bars), G1 (same-kind
spawner reclaim releases the anchor), G2 (`smash_tile` drops machine
items), A1 (mote table OOB), A2 (autosave debounced 5 s).

Since then, on master: boxed-in miner gnaws through its own trail
(5eba0f6 — this is the flagg G5 fix), stuck builder pillars up and out +
own den is never a cage (23b9132), F2 altar debug menu + sky portal fixes
(b8b35d6), stone tint alpha 210 → 120 so the atlas texture shows (43c4633).

## TOP PRIORITY: hand playtest the retune

None of the above has been felt in-game yet:

- **Garm at 75/4/3 with min-1 chip** — losable at Gold set, comfortable
  win at Runic? That was the whole point of the retune.
- **Puffy animated sky** + Cloud Stone chance-drops.
- **Runic spawner path end-to-end** (500 Gold Bars via a snake-stripped
  Gold dimension → runic world → full runic gear).
- Still unseen from earlier sessions: gem tile art (`Pixel_Gem`), miner
  snake visuals (body trail, head pulse, base glow), Gold spawner world.

## Open from flagg.md (tick off there as they close)

G4 (structure templates B/C skippable), G6 (miner catch-up hitch on
dimension entry), G7 (infinite ore regen — accepted v1), G9 (permadeath
soft against force-quit), A3 (debug-menu input discipline), and the
⚪ INFO list. G5 fixed by 5eba0f6 — verify in the playtest, then mark it
in flagg.md.

## After that: the Silo (draft1_machines.md §7.6 step 1)

First bulk storage. Moving 500 bars through u8/99-stacks is meant to hurt
— Glenn will feel it on schedule. Design shape in `draft1_machines.md`;
also note flagg G8: one smelter casts 500 bars in ~25 min + ~167 logs.

## Doc cleanup (2026-07-19)

Deleted as fully shipped/superseded (content lives in git history):
`FABLE_START.md` (one-shot session brief), `score.md` (8.5/10 review,
superseded by flagg.md), `progression_review.md` (audit whose four locked
decisions all shipped; decisions restated in Work_done.md). Current doc
set: `plan.md` (bible), `flagg.md` (live audit + fix status),
`Work_done.md` (holiday log), this file (freshest truth), `PLAYTEST.md`,
`PLAYTESTER_GUIDE.md`, `OPUS_HANDOVER.md` (timeless), `ai_algo.md`,
`draft1_machines.md`, `gem_progression.md`, `architecture_findings.md`,
`sprites_prompt.md`.

## Reminders

- Read `plan.md` + `CLAUDE.md` before touching systems.
- Build check: `odin run src`; tests: `odin test src` (repo root `Gnipahellir3/`).
- Fixed arrays only, event-driven, render read-only, tables not switches.
