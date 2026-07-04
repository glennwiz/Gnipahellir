# Builder AI — Activity & Liveliness Suggestions

## What the log reveals

**Builder#0** is completely invisible to the player. It's in a floor pocket at y=64–65
with the only available stone at y=57 (7–8 tiles up). Scaffold finds no valid placement
(tight pocket, no room). Result: Roam→Seek→Scaffold-fail→Roam every ~60 frames, forever.
The builder never touches a single tile.

**Builder#1** is actually mining (mined 6+ stones from y=73–76) but carrying fails every
single time — it mines a stone, walks toward place(168,70), can't find a path, drops the
stone back to Void, and immediately goes looking for more stone to mine. From the player's
view it looks like an entity running back and forth achieving nothing.

Both cases have the same root feel: **the builder is spinning but not visibly building**.

---

## Suggested behaviours (cheapest first)

### 1. Stockpile instead of dropping mined stone

**The problem it solves**: Builder#1 keeps mining stone and setting it back to `.Void`
when carrying fails. That stone just disappears.

**The fix**: When `Carrying` fails to find a path to `place_tile`, instead of going back
to Seeking empty-handed, **place the carried stone at the nearest open floor tile** within
reach — a "stockpile" position. The builder isn't wasting its mine trip, and it leaves a
visible pile of stones near its work area.

Stockpile tiles are still just `.Stone` — `builder_find_source` will find them next time
and prefer them (they're close, reachable).

```
Carrying path fails:
  → find open floor tile within BUILDER_REACH
  → set_tile(stockpile_pos, carry_type)      // drop here, not Void
  → push Builder_Placed event
  → Seeking                                  // find next unsatisfied step
```

This one change makes Builder#1 look like it's organising a work area.

---

### 2. Mine nearby stone when idle (local busywork)

**The problem it solves**: Builder#0 never touches anything. It looks completely frozen
even though it's looping internally.

When Roaming fails to find a build site **for N seconds** (stuck_timer threshold), enter
a **`Tidying`** state:

- Scan for the nearest solid, mineable tile within 3 tiles
- Walk to it, mine it (set to Void, emit Builder_Mined)
- Carry it to the nearest open floor tile and place it there
- Go back to Roaming

The builder is just shuffling stones around locally. It looks active, it's rearranging the
cave slightly, and it may accidentally create the standable tile that unblocks BFS later.

---

### 3. Repair / maintain completed structures

After `Satisfied`, before going to `Roaming`, scan the recently built template. If any
tile that was placed has since been destroyed (player mined it, or another builder took it
for scaffolding), immediately re-enter `Seeking` to fix it.

Builders defending and maintaining their own work makes them feel persistent and purposeful.
Very cheap — just re-check `builder_count_unsatisfied` in the `Satisfied` delay period.

---

### 4. Favour a closer source when carrying repeatedly fails

**The problem it solves**: Builder#1 keeps mining from y=73–76 (below the anchor) and
then failing to carry up. It should notice this pattern and try a different source angle.

Add a **carry-fail counter** (`carry_fails: u8`) to `Builder_State`. Each time Carrying
fails to find a path, increment it. After 3 failures on the same `place_tile`, mark that
step as **temporarily skipped** (`skip_mask: u32` bitmask over step indices) and try the
next unsatisfied step instead.

This lets the builder work on the parts of the structure it *can* reach and come back to
hard-to-reach spots later (perhaps after other steps have been placed and changed the
geometry).

---

### 5. "Look around" micro-animation when waiting

Zero gameplay change, pure visual liveliness. When `action_timer > 0` and the builder is
stationary (Seeking, Satisfied, waiting for cooldown), periodically flip `e.facing` for
0.3s then flip back. Looks like the builder is glancing around while waiting.

Can be done in `draw_builder` with a sine/cosine on `elapsed_time` per-entity — no new
state needed.

---

### 6. Push an "I'm working" particle when mining/placing

When `Builder_Mined` or `Builder_Placed` is emitted, spawn 2–3 stone-coloured particles
at the tile position (from the particle pool). Cost: one `particle_spawn` call, already
supported by the system. Makes mining and placing **visually obvious** from across the
screen — the player can tell something is happening even without watching closely.

---

### 7. Scan-then-commit site selection (don't immediately anchor)

Currently the builder finds a floor tile with clearance and instantly commits an anchor.
If the anchor zone has all its stone sources above an unreachable cliff (Builder#0's
exact situation), the builder is committed to an impossible job.

Before committing an anchor:
- Run a quick BFS-reachability pre-check: is there at least one stone tile within
  `BUILDER_SCAN_RAD` that is **standable-reachable** from the candidate floor?
- If yes, commit anchor. If no, keep roaming.

This prevents Builder#0 from anchoring in an isolated pocket with no reachable material.
One `bfs_platformer` call per site-check frame (already staggered every 30 frames) is
the cost.

---

## Priority order for implementation

| # | Suggestion | Effort | Impact |
|---|---|---|---|
| 1 | Stockpile on carry-fail | Low — change 3 lines in Carrying | High — Builder#1 immediately looks productive |
| 7 | Pre-check site reachability | Low — one BFS call before anchoring | High — prevents Builder#0's infinite isolation loop |
| 2 | Tidying state when long-roaming | Medium — one new task state | High — Builder#0 becomes visibly active |
| 6 | Particles on mine/place | Low — particle_spawn call | Medium — makes individual actions legible |
| 4 | Skip unreachable steps | Medium — bitmask + counter | Medium — Builder#1 stops spinning on one tile |
| 3 | Repair after Satisfied | Trivial — re-check unsatisfied count | Low — long-term persistence feel |
| 5 | Facing flicker animation | Trivial — draw-only change | Low — subtle but cheap |

---

## Notes on Builder#0's specific trap

Builder#0 keeps picking anchor (19–20, 62) because the Roaming site-check fires almost
immediately when it lands back on the same floor tile. The builder never gets far enough
away to find a better site before the 30-frame stagger fires again.

Two cheap fixes working together:
- After scaffold fails, set a **roam_cooldown** (e.g., 3s) before the next site-check
  can fire — forces the builder to walk further before committing again.
- Apply suggestion #7 (reachability pre-check) so even when the check fires, the pocket
  site is rejected and the builder walks on.
