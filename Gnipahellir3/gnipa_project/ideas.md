# ideas.md — raw idea capture

Quick-capture backlog for design ideas before they're lost. Not committed scope —
these graduate to `context.md` §5 (queued work) or `flagg.md` once picked up.
Keep entries faithful to how they were said; add just enough structure to build from.

---

## 2026-08-05 — early-zone environmental buffs (Glenn)

### 1. Persistent altar rune halo → Fly buff aura (early sky)
After the Sky Altar ritual completes, the ceremony runes shouldn't fully vanish —
leave a **smaller version of the first ritual runes spinning forever**, looping
over the Sky Altar.
- **Effect:** standing **in range of the spinning runes grants a 1-minute Fly
  buff** (refreshes/recharges while in range).
- Notes for build: this is the "leftover" state of `draw_ritual` / the rune ring
  (see context.md — ritual ceremony, `Ritual_State`, `draw_ritual`). Persistent
  visual + a proximity check around the altar tile → apply timed Fly buff. Buff
  timer is a new transient (probably) player state.

### 2. Glowing cave moss/berries → Leaf-Fall buff (first underground)
In the **first underground zone** (through the first portal), spawn **cave
moss / bush with green glowing berries**.
- **Effect:** harvesting/eating the berries gives a **20-second Leaf-Fall** effect
  (slow-fall / feather-fall — take the berry, drift down safely).
- Notes for build: new terrain/decoration tile in cave-1 gen (green glow), a
  pickup that applies a timed "Leaf_Fall" status. Pairs thematically with the
  sky Fly buff — both are early, environmental, timed-mobility boons.

**Common thread:** timed player buffs sourced from the environment, one per early
zone (sky = Fly, cave = Leaf-Fall). Suggests a small shared **timed-buff system**
(a `Buff_State` with an enum + timer) worth designing once for both.

---

## 2026-08-05 — enemy roster brainstorm (Glenn)

**The Builder DNA (why it works — reuse this):** autonomous agent with its own
agenda + player's own world verbs (mine/place/bridge/pillar via `astar_dig` +
`builder_exec_action`) + raidable den & stockpile + only hostile when provoked
(`builder_alert`). New enemies twist a facet of this, not just "walk and bite."
Two structural gaps to fill: **the sky/ascend axis has no enemies** (descending is
dangerous, ascending is a free build zone), and **nothing threatens your machines**
(the long arc is automation, but a base you never defend has no stakes).

Roster (role tags: [AGENT] autonomous · [THREAT] hunts player · [STUFF] targets your base):

1. **Draugr — dead builders** [THREAT] · *build first, cheapest.*
   A killed builder rises as an undead hunter. Slow, relentless, no economy goal —
   just the player. **Phases through the den it once built** (thematic + reuses
   door-permeability idea). Norse: draugr = grave-dweller. Reuses the builder body
   + AI with goal locked to `Hunt`; makes permadeath/combat *matter*. New
   `Enemy_Kind.Draugr`; spawn on builder death; skip den/economy goals in
   `update_builder`.

2. **Anti-machine creature — gnawer / hoard-thief** [STUFF] · *fills the biggest gap.*
   Two flavors (pick one or both):
   - **Rock-gnawer / grave-worm** — burrows its own tunnels, **eats ore piles and
     placed blocks**, chews a silo/barrel down over time. First anti-hoard threat →
     stockpiles now need walls.
   - **Magpie / hoard-thief** — darts in, grabs from a pile or open silo, flees to
     its own stash. Non-lethal but infuriating; **raid its nest to reclaim** (mirror
     of raiding a den). Turns loot into something to guard.
   Both give the automation arc real defensive stakes.

3. **Sky predator — raven / valkyrie / harpy** [THREAT] · *fills the empty ascend axis.*
   Aerial diver. Attacks while you place Cloud Stone, or **pecks apart sky
   platforms** so falling actually threatens the ascend axis. Needs a flying-body
   movement mode (no gravity/A* — steer toward target); the first non-walking enemy.
   Pairs with the queued sky Fly-buff idea (risk on the fun toy).

4. **Rival dvergr clan** [AGENT] · *three-way tension, cheap.*
   The builders are dwarves; a second clan that fights the first **and** you, racing
   for the same ore. Mostly a faction tag on existing builder AI + friend/foe checks
   in targeting; turns a level into a contest. Raid either clan's den.

**Suggested build order:** Draugr (re-skinned builder, death gains weight) →
anti-machine creature (the gap automation structurally needs) → sky predator (the
other gap) → rival clan (variety once faction plumbing exists).

**Shared tech these imply (design once):** `Enemy_Kind` already dispatches body
size/speed (`enemy_body_size`/`enemy_speed`) — extend that spine. Likely wants a
flying movement mode (sky predator), a faction/allegiance field (rival clan,
draugr-vs-builder), and an "attack nearest machine/pile" targeting goal
(anti-machine). None break the fat-struct / event-driven / table-driven laws —
new `Enemy_Kind` rows + new goal procs.

---

## 2026-08-06 — time-rewind brainstorm (Glenn) — NOT SOLD YET, parked for review

Sparked by noticing `save_game`/`load_game` round-trip nearly all of `Game_State`
as one POD `mem.copy` (`save.odin`), which makes "snapshot now, restore later"
cheap to build in principle. Glenn's opening idea: **a wearable ring that lets
time run backwards.** Nothing here is scoped — capturing the spread before it's
lost.

1. **Ring of the Norns (personal rewind)** — active ability, rewinds just the
   player (pos/vel/hp) a few seconds back. Cheap: sample only `Player` into a
   short ring buffer every frame, not the full 3.17MB `Save_Data`. Panic button
   for lava/fall/Garm-combo deaths. Cost should mirror the reward (mana drain,
   or a charge that only refills at a shrine/altar) per the design north star.

2. **Thread-snip (golem rewind)** — same trick scoped to one `Golem` — rewind a
   worker that wandered into lava or got buried, without touching the world.
   Very cheap (one small struct), and doubles as in-fiction cover for exactly
   the kind of stuck-golem recovery already being hand-tested this session.

3. **Hel's Hourglass (checkpoint item)** — rare consumable: drink to set a
   checkpoint, drink a second later to snap back to it. Full `Save_Data` cost,
   so scarce/craftable by design, one active checkpoint at a time (not a
   buffer).

4. **World-undo (dig-mistake insurance)** — periodic full checkpoints as a
   late-game machine/altar ritual: "undo the last 30 seconds of terrain
   change." Expensive and rare on purpose — fits the automation endgame more
   than an early ring.

5. **Echo/decoy** — not a rewind at all: record the last N seconds of player
   movement and spawn a replaying ghost as a combat/misdirection tool. Reuses
   the cheap position-buffer from #1 but for offense, not safety.

**Open fork:** early defensive tool (cheap, personal, frequent — #1/#2) vs.
rare/late "undo the world" item (expensive, scarce — #3/#4) — decides whether
this is a small per-frame buffer or a periodic full-state checkpoint. Also
worth deciding before building: none of these rewind transient state (camera,
particles, gravity falling-block pool, notifications, ritual swirl) since it
isn't in `Save_Data` — a restore reads as a jump-cut, not a smooth rewind.
