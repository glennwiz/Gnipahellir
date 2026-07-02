# Garm AI: Current Behavior and Plan-Driven Improvements

This document summarizes Garm’s current AI behavior and outlines changes to make it less random and more plan-driven, especially for remove/build actions.

## Current Behavior (as implemented in `src/enemy.odin`)

- Core state machine
  - Idle: quickly transitions to Distracted unless player is close.
  - Wandering: rare; falls into Distracted.
  - Chasing: moves toward player; fires fireballs; jumps based on heuristics.
  - Jumping: transitional; returns to Chasing when rising ends.
  - Charging: short burst speed toward player when close.
  - Distracted: non-combat “builder” mode; main place for mining/placing.

- Movement and combat
  - Speedy movement with simple tile collisions.
  - Gravity + jump; heuristic jumps if blocked, near gaps, or for aggression.
  - Fireballs when in Chasing/Charging and within range.

- “Project” concept (builder goals)
  - project_center_x set to world center X; radius defaults to 10.
  - Phases: Center_Column → Perimeter → Filling_Lava.
  - Center_Column objective:
    - Build a Stone column at the center X.
    - Maintain a reserved void channel: the two tiles above each stone (y-1, y-2) must be empty (Air/Void depending on level).
  - Perimeter objective: build a ring at radius; sample by angle.
  - Filling_Lava objective: fill inside with Lava (mine first if solid).

- Planning system (new)
  - plan[20] circular-ish buffer; Garm generates up to 20 actions.
  - plan_lock_steps = 15; Garm must complete 15 actions before replanning.
  - Action types: MoveTo, Mine, Place, Jump.
  - Center_Column planning now:
    - MoveTo center X, then for a vertical band around current Y:
      - Place Stone at (center X, y) if empty.
      - Enforce void at (center X, y-1) and (center X, y-2) via Mine/normalize to Air/Void.
  - Execution rules:
    - MoveTo completes when horizontally close.
    - Mine/Place require proximity (≤ 2 tiles) and respect recent-mod cooldowns.
    - Never Place into reserved void tiles above the center stone.

- Anti-stuck and proximity build logic
  - When stuck, mine above or place steps below/ahead; now avoids reserved void tiles.
  - Distracted periodic actions mine/place near self, biased toward project center.

- Randomness sources (where behavior feels noisy)
  - Random material choice when placing (Stone/Grass/Wood/Leaves).
  - Random offsets for nearby build attempts when center-directed edits fail.
  - Perimeter sampling advances by index but still has randomness in materials.
  - Random aggressive jumps in Chasing.

## Problems Observed

- Remove/build actions feel too random in Distracted mode.
- Progress toward the structural goal is steady but can wander due to local random placements.
- Replanning cadence is better (15-step lock) but individual steps may not strictly follow a clear top-to-bottom or scanline order.

## Direction: Plan-Driven, Less Random

Make building deterministic and goal-first; reserve randomness only for safe tie-breaking.

- Plan structure
  - Keep 20-step plans with a 15-step lock before replanning.
  - Define phase-specific plan generators:
    - Center_Column: scan center X in a clear order (e.g., from mid-Y outward up/down) and generate Place/Mine actions for stone + void enforcement.
    - Perimeter: deterministic angle ordering; prefer nearest undone samples; avoid random materials.
    - Filling_Lava: scan interior tiles in a spiral/bbox order; mine then place lava.

- Determinism
  - Remove random material selection; use fixed materials (Stone for structure, Grass optional for top pass only if desired).
  - Replace random nearby actions with deterministic target sets derived from the phase.
  - Randomness only for tie-break between equally good next targets.

- Execution guardrails
  - Never place in reserved void positions above center stone.
  - Always Mine unsafe placements first; skip if blocked by entities/special tiles.
  - Horizontal-first MoveTo to reduce dithering.

- Replan triggers
  - After 15 steps.
  - If current step is invalidated (tile no longer editable or already correct), skip and continue; only replan early when N consecutive steps are skipped.

- Visibility and progress
  - Track simple metrics: steps completed per phase; remaining targets.
  - Optionally render debug markers for current plan targets.

## Concrete next tasks

- Center_Column
  - [x] Replace band-limited planning with a deterministic full-column sweep from mid-Y outward (up then down), generating actions until plan is full.
  - [x] Remove random placement in this phase; Stone only.

- Perimeter
  - [x] Use fixed angular stride and stable start index; no random materials.
  - [x] Prioritize nearest undone perimeter samples to reduce travel.

- Filling_Lava
  - [x] Replace random interior picks with a deterministic spiral/bbox scan toward center.

- General
  - [x] Add early-skip budget: if 5 consecutive steps become no-ops, regenerate plan immediately.
  - [ ] Optional: record simple debug overlay of plan waypoints for tuning.

## Summary

Garm now has a basic 20-step plan with a 15-step lock and enforces a stone column at center X with two void tiles above each stone. The remaining randomness in build/remove should be removed in plan generation and execution so progress is predictable. The tasks above define the next steps to make Garm consistently follow a build plan.