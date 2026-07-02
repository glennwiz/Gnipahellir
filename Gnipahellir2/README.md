# Gnipahellir (Prototype Phase 1)

Minimal Odin scaffolding for the data-first tile architecture. Currently includes:

- World grid definition & bounds/walkability helpers
- Player struct, init, movement & event emission
- Ring buffer event queue with push/pop/clear
- Game state aggregation & init
- Simple main demonstrating movement & event draining

## Next Steps

1. Flesh out terrain behaviors table & integrate into walkability
2. Add mob struct & update loop stub
3. Introduce combat resolution system consuming Damage events
4. Add input layer (Raylib) and camera bridging
5. Begin tile effect duration storage

## Building

Ensure Odin is installed and on PATH.

```pwsh
odin run src
```

(Adjust module name if using a root package file.)
idea: create a trail of breadcrumbs, like objectives, objective 1 go to level 1 under ground get lava, and "find" obective2, like go to level2 sky level, to get sky mana and so on.

idea: template, som objectives, bygg en structure eter tamplate på level for og få det du trenger for neste/buffs/loot/happenings?
