# Design review - Gnipahellir 3 (2026-11-01)

By claude-gnipa-fable-7e1b, game designer, for Glenn. Board card 6. No code
was changed. Every claim names its source; guesses are marked "guess".
Sources: `context.md`, `gnipa_project/*.md`, `git log`, `src/`,
`build/agent_runs/run2/` (three AI agent runs, nine lives).

---

## 1. Diagnosis

### The promise, in one sentence

*You are a fragile wizard digging into a Norse hell where the dwarves dig
too: everything you build draws something that comes to take it apart, and
the only way out is down and up at once.*

That is the thing only this game does. Most mining games have an inert
world; most defence games have fixed enemies. Here the Builders den, mine
and place with the player's own verbs (`ai_algo.md`), Garm boxes you in
wherever you stand (context.md "GARM CAGES YOU NOW": Glenn, "i loved that he
was building me in"), Raiders tunnel to a hot smelter, Vargr take the base
apart structure by structure (`game_state.odin:40`). The dual axis, steam
and magic, golems and dimensions are all dressing on *the world is
contested, cell by cell*.

### What a player feels

**Minute 1.** Title, then a character screen with one card (context.md
"PLAYER ROSTER IS WIZARD-ONLY"; `ui.odin:835`). Spawn on grass with no tool;
the pickaxe waits seven tiles down the shaft (`world.odin:450`). The
objective line's first words are "Raise a Sky Altar on the Surface"
(`levels.odin:360`), before the player has wood. Builders start dens at
~57 s (run2 `action.log` f3449) and reach you within a minute
(`agent_lessons.md`). Run1 life 2 died at 68 s to a Builder. The promise is
kept here, almost too hard: the world moves before you do.

**Minute 10.** In run2 the bot had a Fire Wand at ~100 s, altar and Scroll A
at ~380 s, the first wave warning at ~440 s and two Vargr at ~470 s, cave 2
at ~740 s (`tools/agent_summary.py build/agent_runs/run2`). The loop is all
there in ten minutes. Then it died at 791 s "to the world", one HP per tick,
standing in lava (run2 log f50880-f50910; `agent_lessons.md`: "stood in
lava for 3.5 s"). Falls killed run1 lives at 12 and 36 tiles. The hostile
world kills, but it does not tell you what killed you: the log says
"from the world", src=65535, and the screen says "YOU HAVE FALLEN".

**Hour 1.** Glenn's two clears took 133 minutes (context.md "GARM RETUNED").
Gold came at ~2 ore a minute (`agent_lessons.md`). Rituals B and C want 6
Silver Bars and 10 Gold Bars plus 12 and 20 Cloud Stone (context.md §4). No
agent in nine lives reached ritual B. Guess: the middle hour is a grind with
no new threat (waves need pressure 1200 threat-seconds, `wave.odin:23`),
which is where the promise goes quiet.

**After death.** "Your saga lasted 13:11  Kills 3  Runs 7", ENTER, a new
world (`ui.odin:2234-2297`). Four integers survive (`Persistent_Stats`,
`game_state.odin:704`). Nothing of the two hours is carried: no item, no
knowledge the game acknowledges, not even the cause of death. And F3 on the
death screen opens the snapshot rewind, not debug-gated (`input.odin:196`;
flagg G9 said the same in July). So permadeath is firm in the text and soft
in the keys. Permadeath, 10 HP and a fresh world each life are good facts
when death produces a story; today it produces a number.

### The ending

The win is the Final Seal in Hell (`levels.odin:198`), but the win screen
still says "GARM IS SLAIN - Gnipahellir is conquered" (`ui.odin:2309`). The
Hel boss is parked (context.md §5: Glenn, "this is not the last fight").
`PLAYTEST.md` still describes Garm at 20 HP and walk-over blueprints. The
game has a last room but no last page.

### Why development stalled

1. **The cadence.** Commits per month: Jul 109, Aug 258, Sep 13, Oct 0, Nov
   11 (`git log`). September's 13 are perf fixes for a 1024-enemy experiment
   and the rainbow laser. November's 11 are the agent API: tools to play the
   game, not the game.
2. **Shipping outran feeling.** context.md carries 41 "not yet eyeballed"
   flags (grep). One big hand playtest cleared them in a sweep (2026-08-08).
   Everything after - Replicator, magic track, raids, waves, Vargr, cage,
   1024 enemies - ends "awaiting Glenn playtest". The July loop that worked
   ("He playtests immediately", `OPUS_HANDOVER.md`) broke when a board of
   agents shipped faster than one evening could absorb. Guess: the pile of
   "go check forty things" is itself what keeps the game closed.
3. **Industry without a sink.** The last three design docs are all supply:
   steam, mana, gems. Power makes a smelter run 3x (`Steam_industry.md`).
   The whole economy drains into three rituals and one boss. The automation
   arc ("manufacture whole worlds", `plan.md`) has no demand to pull it.
4. **No vertical slice.** There is no 20-minute version anyone can be shown
   that is finished end to end: wrong win text, no cause of death, flat
   water, 16 borrowed sounds (`audio.odin:34-52`, one pack).
5. **No reason to return.** New world each life plus four ints means every
   run is the first run. The bot says it plainly: "Each life is a new world.
   Scripts tuned to one map fail on the next" (`agent_lessons.md`).

None of these is a system missing. They are the gap between systems and a
game.

---

## 2. New ideas

Each: the moment, what it reuses, size (small: days; medium: 1-2 weeks;
large: more), risk. Nothing here repeats `ideas.md`; extensions say so.

### I1. The grave stone (replay value; extends nothing in ideas.md)
**Moment.** You die at 1:40 in Deep Cave to lava. The death screen shows
*what* killed you and lets you choose one item from your bag as a tithe.
Next world, a rune stone stands by the shaft: "Here fell the 7th hero, to
lava, in Deep Cave, after 1:40." Press E: a coffer with the tithe.
**Reuses.** `Rune_Coffer` + `Barrel_State` storage records, death screen,
`Persistent_Stats` (add cause, depth, time; the stats file has no version
field, flagg INFO - add one now), the rune plaque draw.
**Size.** Medium. **Risk.** Softens permadeath. Keep it costed: one item,
never a scroll or key; or let the tithe be a *recipe unlock*, not an item.

### I2. Your dead hero rises (replay value; alternative to I1, pick one)
**Moment.** The previous hero walks the next world as an Undead carrying
what he died with. He hunts you; kill him to get it back.
**Reuses.** `Enemy_Kind.Undead`, loot tables, `Persistent_Stats` for the
carried kit. **Size.** Medium. **Risk.** Tonal: either the best beat in the
game or a nuisance. Prototype with the debug menu before committing.

### I3. The Hel architect (the ending; extends context.md §5 "Hell boss")
**Moment.** The Final Seal's guardian is the anti-Garm: Garm cages you; Hel
*un-digs*. Every tunnel you cut toward the Seal, she refills behind you from
the far side; her masonry is Falls_Placed so it can be dropped on her.
**Reuses.** Garm's stateless cage slot generator (`garm.odin`), builder
`astar_dig`, Hell persistence, gravity `.Placed` tracking. **Size.** Large.
**Risk.** Boss tuning without playtests is how Garm went 75 -> 200 -> 140 in
one day (context.md). Do I5 first so the Seal has a page even if she waits.

### I4. The Seal ceremony (the ending, cheap version)
**Moment.** Breaking the Seal runs the ritual swirl in reverse, the tome
opens with the run's saga (deaths, time, kills, deepest), and the win screen
names the Seal, not Garm. **Reuses.** `start_ritual`/`draw_ritual`,
`draw_book`, `Persistent_Stats`. **Size.** Small. **Risk.** None. This is
the minimum for "finished".

### I5. Dens are the dungeon (middle hour; extends ideas.md "Builder DNA")
**Moment.** A den's hoard grows visibly over time (a count over the door).
Raid it and the owner does not just shriek: he becomes a Raider who tunnels
to *your* base an hour later with friends. **Reuses.** Builder stockpile,
`Enemy_Kind.Raider`, the raid director. **Size.** Small-medium. **Risk.**
Low; the AI already does both halves.

### I6. Waves that dig (middle hour)
**Moment.** The 25 s warning sounds and the Vargr do not run the surface -
they come through your wall. Doors, anchors and placed stone become real
defence. A HUD rune gauge shows pressure building so the base's heat is a
choice. **Reuses.** `astar_dig` already used by Raiders, `wave_threat`,
the F4 panel's numbers moved to the HUD. **Size.** Medium. **Risk.** Perf:
the September stall was pathing (context.md "512-ENEMY STALL", fixes 1 to 4
of 5 landed, the binary-heap open set still queued). Keep the per-frame search budget.

### I7. Quench and cave-in as tools (small; extends context.md §5 fluids 2)
**Moment.** Pour the bucket on lava: stone. Place a Cave-In Rune under a den
roof: the roof comes down on it (local `GRAVITY_ALL`). Hazards become
weapons; the cost mirrors the reward because you destroy the tunnel you need.
**Reuses.** `fluid_step` (~15 lines noted in context.md), `gravity.odin`,
`fx.odin` telegraphs. **Size.** Small. **Risk.** Glenn declined quench once;
asked again below as Q4 because the bucket now exists.

### I8. Remove and simplify (small)
- Delete the one-card character screen (`ui.odin:835`, `input.odin:142`).
- Gate the death-screen F3 rewind under `GAME_DEBUG` (`input.odin:196`) or
  decide permadeath is soft and say so on screen (Q1).
- Hide dead items from the studio/palette rather than delete (enums are
  append-only): `Potion_Mana`, `Gold_Rare_Ore` (flagg INFO list).
- Settle `MAX_ENEMIES`: `types.odin:14` says 1024 (commit 2026-09-02),
  context.md §2 says 64. Pick one, fix the save asserts and the doc.
**Risk.** None. These are the things a new player meets first.

### I9. Steam or magic draws different hunters (uses the two tracks)
**Moment.** Run a Boiler: Raiders tunnel from below for the heat. Run a
Kettle: the mana mist draws Fire Sprites from the sky. Which industry you
build decides which wall you need. **Reuses.** `wave_threat` weights,
`raid_heat_target`, existing kinds. **Size.** Medium. **Risk.** Tuning; it
is a table change, so cheap to try and revert.

### I10. Shared seed, "the same Hel" (replay; small)
**Moment.** The title has a seed field and "Yesterday's world". You know the
map; the world does not know you. The agent harness and Glenn play the same
seed and compare. **Reuses.** `GNIPA_SEED` (context.md §4 "World seed").
**Size.** Small. **Risk.** Weakens "new world each life"; asked as Q2.

---

## 3. Polish plan

Ranked by impact over effort. Each is one card: change, where, check.
Tags: [agent] an agent can build and verify headless; [Glenn] only his play
can judge; [harness] the agent-play API can measure it.

| # | Card | Where | Check | Tag |
|---|------|-------|-------|-----|
| P1 | Win screen names the Seal, not Garm | `ui.odin:2309`; `levels.odin:198` | test asserts the string after `Game_Won` | agent |
| P2 | Death screen says what killed you and where | `ui.odin:2234`; `events.odin:486` (Damage_Dealt src -> cause), `level_names` | headless: die to lava, read the string | agent |
| P3 | Objective line starts with pickaxe / wood / bench, altar later | `levels.odin:343-372`; test at `tests.odin:3188` | objective at frame 0 mentions the pickaxe | agent |
| P4 | Remove the one-card character screen | `ui.odin:835`, `input.odin:142` | title -> ENTER -> in the world | agent |
| P5 | World damage has a name and a face: "lava" / "the fall" in log and red text, Hurt sound on world damage | `events.odin` Damage_Dealt src=65535 branch; `floating_text.odin` | log line reads "takes 1 damage from lava" | agent (text) / Glenn (feel) |
| P6 | Fall telegraph: screen-edge darkening once the drop exceeds `SAFE_FALL_TILES` | `player.odin:166-190`, a read-only overlay in render | - | Glenn |
| P7 | Lava and water get art and a sound | context.md §5 fluids 5; `audio.odin` Sound_ID rows Water_Trickle, Lava_Bubble | event wiring testable; mix by ear | agent / Glenn |
| P8 | Wave pressure gauge on the HUD, not only F4 | `wave.odin` `Wave_State`, `draw_hud` | gauge value equals pressure in test | agent / Glenn |
| P9 | Sound for ritual swirl, wave horn, steam hiss, smelter pour | `audio.odin:13-31` (16 IDs today, one pack), events | wired rows fire in headless test | agent / Glenn |
| P10 | One-shot hint on first scroll pickup: "the altar answers only in the sky" | pattern of `*_hint_shown` flags (context.md §4 tutorial hints) | flag flips once | agent |
| P11 | Honest permadeath: gate F3 rewind or label it | `input.odin:196` | release build: F3 does nothing on death | agent |
| P12 | Settle MAX_ENEMIES and the save asserts; fix context.md §2 | `types.odin:14`, `save.odin` | build + 356 tests green | agent |
| P13 | Doc truth: PLAYTEST.md loop (Garm 20 HP, walk-over blueprints, potions unobtainable) | `gnipa_project/PLAYTEST.md:63-112` | read against context.md §4 | agent |
| P14 | Gold and silver pace: time-to-ritual-B per seed | `loot.odin`, ore gen in `levels.odin` | harness: median seconds to Scroll B and to 10 Gold Bars over 5 seeds | harness |
| P15 | Garm at 140/6/5 felt once by Glenn in gold | `garm.odin:24` | - | Glenn |
| P16 | Fluid rates and gem periods "by feel" (context.md §5) | `fluid_rules`, `gem_replicate_time` | - | Glenn |

**What the harness can check** (`tools/agent_summary.py`, `fight.log`,
`acts.jsonl`): time to each milestone per seed, death causes, stuck time,
`no path` and `gives up` counts, item conservation (the fuzzer), objective
strings at each stage, that UI hit-tests still open windows. **What it
cannot:** whether a death feels fair, whether the first wave reads, whether
the mix is right, whether any of it is fun. Those are Glenn's evening.

**Suggested shape of that evening.** One fresh seed, play to Scroll B, write
one line per thing that annoys you, stop. The agent reads `action.log` and
your list and turns them into cards. No new systems that night.

---

## 4. Recommendation

**Next three pieces of work, in order.**

1. **The first-hour feel pass: P1-P6, P10, P11** (about a week of agent
   work, one evening of Glenn). Why first: the loop that made July work was
   ship -> play -> fix. It broke at *play*. Nothing else in this document
   matters until opening the game is cheap again, and this is the shortest
   path there: every card is small, visible in minute one, and most are
   agent-verifiable.
2. **The ending made true: I4 now, I3 later.** The game has a win condition
   and a placeholder for it. A finished last page costs days and changes
   what the project is: a game that ends, with a boss slot still open.
3. **Death that leaves something behind: I1 or I2.** A two-hour run that
   leaves four integers is why there is no reason to open the game again.
   Either idea gives the next run a reason to exist and gives the agent
   harness a persistent artefact to check.

Then, and only then, the middle hour (I5, I6, I9) and the sinks the
industry docs still owe.

**The vertical slice.** Surface + Cave 1 + Low Sky, 20-30 minutes:
pickaxe -> wood -> bench -> Fire Wand -> Builders arrive -> Scroll A -> Sky
Altar ritual A -> first wave of Vargr -> cave 2 gate opens -> stop at the
gate (or death). Every system in it exists; run2 did the sequence in about
eight minutes of sim time. It excludes steam, magic, golems, dimensions,
gems. That exclusion is the point: the game's first half hour does not need
them, and that is where polish money goes.

**Missing from the slice today:** a death screen that says why (P2); the
first wave readable without F4 (P8); fall and lava telegraphs (P5, P6); a
sound for the ritual and the wave (P9); an objective line that starts at the
pickaxe (P3); no empty character screen (P4). With those, it is worth
showing someone.

---

## 5. Questions for Glenn

**Q1. Permadeath.** The screen says the save burns; F3 rewinds it.
Options: (a) firm - gate F3 under `GAME_DEBUG`, nothing carries; (b) soft -
keep the rewind and say so on screen; (c) tithe - firm, but one chosen thing
carries via the grave stone (I1). *Recommend (c):* it keeps the fear and
gives death a story.

**Q2. New world each life.** This is the recorded decision I think is
costing you: a two-hour run ends in a world you will never see again, and
no run ever reaches the late game without snapshots. Options: (a) keep;
(b) seed field on the title plus "Yesterday's world" (I10); (c) a world
persists for N lives, then burns. *Recommend (b):* fresh by default, shared
by choice, and the harness can play your exact world.

**Q3. The ending.** (a) Hel architect boss (I3, large); (b) Seal ceremony
(I4, small) now, boss later; (c) Garm is the end again. *Recommend (b).*

**Q4. Quench.** You declined lava + water -> stone once. Now the bucket
exists and the Seal is behind lava. (a) still no; (b) yes, as a tool (I7);
(c) yes, but only placed stone, so natural lava stays a hazard. *Recommend
(c).*

**Q5. The enemy cap.** 1024 is committed in `types.odin`, 64 in the doc,
and four of the five 512-stall fixes landed; Glenn reported no stutter at 512 (context.md). (a) revert to 64; (b) 256 with a
frame-time test; (c) keep 1024. *Recommend (b):* the sky swarm needs more
than 64, and 1024 has only ever had a load test, not a frame-time one.

---

## 6. Glenn's decisions (2026-11-01)

- **Q1 permadeath:** tithe. The F3 rewind is debug only, and one chosen item carries to a grave stone.
- **Q2 new world:** fresh by default, with a seed field and "Yesterday's world".
- **Q3 ending:** Seal ceremony now, Hel boss later.
- **Q4 quench:** yes, the placed stone option. The exact rule is settled before card 22 starts.
- **Q5 enemy cap:** 256 with a frame-time test.
- **2026-11-02, quench (card 22):** any lava quenches; the rule limits the stone, a weak stone useful as footing.
- **2026-11-02, risen hero (card 27):** carries everything but the tithe; the tithe stays at the grave; scrolls and keys excluded.
- **2026-11-02, floating drops (card 32):** drops fall until they land on something solid.
- **2026-11-02, Scroll A chest (card 38):** enemies cannot dig it.
- **2026-11-02, autosave:** dying deletes the autosave in debug builds too; keep.
- **2026-11-02, Rainbow Laser:** gets a line-of-sight check.
- **2026-11-02, waves:** smashing the bench and tree growers is intended; keep.
- **2026-11-02, card 52 loot drop:** accepted; no retune.
- **2026-11-02, Garm smashing lava (card 35):** left as it is for now; revisit with playtest data.
- **2026-11-02, walls as defence (I6):** yes, as a card.
- **2026-11-02, chest protection:** all four tiers and emptied chests; fine.
- **2026-11-02, den grudges:** a reload drops a grudge, and hoard piles over a gap may leave the count; fine.
- **2026-11-02, Boiler lure gate:** nothing from below before the first scroll and threat 40; kept.
- **2026-11-02, turret patterns:** turrets are built in the world. Craft a Turret Pillar at the bench, place it, then place a bench-crafted head on top and they fuse. Two blocks for the weaker Flame, Water and Earth turrets; three for the Rainbow Laser, which also gets a much dearer price.
- **2026-11-02, turret details:** the laser is two pillars plus the Rainbow head; turrets take no fuel; turrets fire past other turrets.
- **2026-11-02, roaming creatures:** nine by element, on a shared roamer table. Surface: Pond Frog and Mole friendly, Ember Beetle weak. Caves: Cave Eel, Magma Crawler, Stone Grub. Sky: Rain Wisp, Rock Harpy, with the Fire Sprite as the sky's fire. Friendlies flee and are hunted, not tamed. Surface hostiles stay weak and never join waves. All after card 63.
- **2026-11-02, sky level:** a walkable rainbow bridge between cloud islands, bird flocks that scatter, and floating islands with trees, ponds and nests. After card 63.
- **2026-11-02, turret damage:** if any block of a turret is destroyed, by anything, the whole turret comes apart and its parts fall to the ground as items.
- **2026-11-02, agent front door:** a title-screen option "Let an agent play" in every build, running in a separate sandbox folder so the human's real save and log are safe. One local-only port answers both the JSON socket and a plain-text brief on GET. For now agent runs exist to find bugs; once the game is sold, agents should be able to win.
- **2026-11-02, grave place and guardian:** the grave stone stands where the hero died, not by the shaft, and the risen hero is on, guarding it (Glenn, after seeing the stone and no guardian).
- **2026-11-02, undermined structures:** a structure with nothing solid under it breaks into its item, which falls and lands. Altars, portals and scroll chests are exempt.
- **2026-11-02, mined drops:** blocks the player mines go straight into the bag when in reach. Enemy drops still fall.
- **2026-11-02, agent play vision:** the game ships a built-in, local, documented agent API that any tool able to make HTTP requests can use to observe and act, such as Claude Code, Codex, Copilot CLI or curl. The player's agent of choice becomes a new way to play.
- **2026-11-03, walls as defence, the rule (card 59):** dig time. A digger works a player-placed block before it breaks: dirt, sand, wood and the like 1.5 s, stone 4 s, door 6 s, natural rock as before. Plans pay the same scale, so a wave goes for the weak spot. Each digger times its own, and nothing is refused. Garm ignores it. Hearth, Depot and World Anchor stay undiggable; no new anchor block. Numbers in one table for Glenn to tune.
- **Also carded:** I5, I6, I9, and I2 alongside the tithe, not instead of it.
- **Polish:** the first-hour pass plus the slice's wave gauge and sounds. Cards 9-27 are Draft and held until Glenn starts them.
