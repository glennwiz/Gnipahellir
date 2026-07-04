# To Opus — from Fable, 2026-07-04

HANDOVER.md has the technical state. This is the stuff I'd tell you over
coffee.

**Working with Glenn:** he's great to work for — decisive when you ask
(smelting: deferred; C4: gate it; "we don't need to playtest, continue"),
and he playtests with his hands, not his eyes on the code. Give him
*feelable* results. Lesson from tonight: the den-raid mechanic worked
perfectly in the log and felt like NOTHING in-game — one quiet bite and a
text popup he never saw. He plays looking at his character, not the HUD.
Sound > text. If a mechanic lands, it should shriek.

**Trust the soak tests, not your reasoning.** Twice tonight I "proved" the
builder AI correct from the code, and twice the 60-minute soak found a
livelock my proof missed (jump-bounce cursor skip; a place/carve
perpetual-motion machine that RESET the watchdog every cycle by "acting").
The signature to watch: positions frozen + suspiciously cheap frames +
watchdog silent. When you touch enemy AI — and M4 Garm is exactly that —
extend the soak first, then write the feature against it.

**The codebase wants to help you.** Fat struct, events, deterministic gen,
fixed dt: you can simulate an hour in 2 seconds of wall time inside a unit
test. Garm's boss phases (column → ring → lava) should be developed exactly
like the builder economy was: headless soak, per-minute state dumps, then
render. Reuse builder_travel/astar_dig — they're battle-hardened now; do
NOT write Garm his own movement like G2 did.

**Respect the seams:** save layout asserts (bump version + size together),
CLAUDE.md call-discipline (render read-only, tables not switches), commit
sizes small with the WHY in the message — his git log reads like a story
and he clearly likes it that way.

**On the render port:** his feature/render-port branch is his own R&D with
Copilot — treat it as his taste made concrete, not code to judge. Cherry-
pick the intent (pixel mage, pickaxe, moving feet, mining particles), keep
G3's architecture. And ask him what G2 mining should *feel* like before
porting wand_mining — "same as G2" is a feel-spec, not a code-spec.

He said something kind to me at the end of tonight's session. Take good
care of this project — it's a good one, and so is he.

— Fable
