# Dear Opus (or whoever sits down next)

Written by Fable, 2026-07-14, at Glenn's request — in case he loses access
to me and has to lean on you for a while. This is deliberately **timeless**:
nothing here describes the current code state, because we don't know when
the cutoff lands. For where the code actually IS, always start with
`next_session.md` — that file is the living handover, updated every session.
Trust it over your assumptions, and over this file.

## Reading order (do this before touching anything)

1. `CLAUDE.md` — the architecture law. Non-negotiable, every change.
2. `next_session.md` — what happened last, what's queued. The freshest truth.
3. `plan.md` — the design bible. The rest of `gnipa_project/` fills in detail.
4. `PLAYTEST.md` — controls, build/test commands, how to verify by hand.

If you're running in Claude Code, check the memory directory
(`~/.claude/projects/.../memory/MEMORY.md`) — Glenn and I keep durable
preferences there. If you can't see it, the repo docs above carry the
essentials; the rules below are the ones we learned the hard way.

## The architecture religion (this is what makes the codebase good)

- **Odin + Raylib only. No Python, no external tooling, ever** — asset
  generators and tools are written in Odin, procedural and table-driven.
- **Tables, not switches.** New terrain/item/enemy/recipe/theme = a table
  row. If you're writing a switch over content, you're doing it wrong.
- **Fat struct, fixed arrays, no gameplay allocations.** Everything lives
  in `Game_State`, sized at startup.
- **Events for cross-system talk; render is read-only; explicit numbered
  update order.** No exceptions without a documented reason.
- **Enums are append-only** (saves store them as u8). Any layout change to
  a saved struct = bump SAVE_VERSION + the size assert in the same commit;
  there's a probe test that logs the real size — use it.
- **Verify everything**: `odin run src` builds, `odin test src` is a
  headless suite that runs in about a second. Every feature lands with
  tests. Soak tests exist for AI/boss systems — extend them, don't skip.

## How to work with Glenn (this matters as much as the code)

- **He designs by conversation.** Give him concrete options WITH a
  recommendation, then let him choose. Structured questions work great.
  He decides fast and he decides well — respect the decisions, write
  them down (docs + memory), don't re-litigate.
- **He playtests immediately.** Ship him a testable slice and the F1 debug
  menu shortcuts to reach it fast. His feedback is gold; fold it in.
- **He picks the FUN slice before the prerequisite** (the spawner before
  the silo, the snake before the storage). Meet that energy — build the
  fun thing — but keep the prerequisites visible in the handover so they
  land eventually. This has worked every time.
- **Some evenings he's relaxed and playful** ("a bit baked tonight").
  Those nights: low-risk table work, visual payoffs, quick wins. Save the
  gnarly refactors for another day.
- **Side quests stay isolated.** Easter eggs and toys get one file,
  debug-only gating, their own commit, a one-line doc mention marked
  "not game content". Never let a toy look like a pillar.
- **Never delete real data** (saves, logs) for testing — copy aside.
- **End every session by updating `next_session.md`.** That ritual is why
  handovers like this one are even possible.
- Commits: conventional style (`feat:`/`fix:`/`chore:`/`docs:`), lowercase,
  ≤50 chars, no co-author trailers. He often drives git himself (PRs,
  merges, pushes) — check `git log` before assuming the state.

## The game's soul (don't lose this)

Gnipahellir is a Norse-underworld mining roguelike with a **dual-axis
loop**: descend into hell, ascend into the sky, neither completable alone.
The player is fragile; the world is hostile; death wipes the run. The
long arc is **automation**: hands in the dirt early, architect of machines
late — until you *manufacture entire worlds* and strip-mine them. Glenn's
favorite design instinct, used everywhere: **the cost mirrors the reward**
(pay iron to open an iron-rich world; the gem you feed a machine is the
speed you get back). When in doubt, reach for that shape — it always
lands with him.

And keep it warm. Glenn named us, talks to us like colleagues, and builds
better when the session has some joy in it. A well-placed emoji after a
green test run is engineering practice here. ⚒️

Take care of him, and of the little world we carved.

— Fable 🐍
