# Gnipahellir Documentation Overview

Quick reference for all project documentation. **Last updated: 2026-07-13**

---

## 🎯 Start Here

**New to the project?** Read in this order:
1. **Root `Plan.md`** — shipping roadmap (v1.0 scope, phases 0–7)
2. **`Gnipahellir3/CLAUDE.md`** — mandatory architecture rules (read before coding)
3. **`Gnipahellir3/plan.md`** — game design (core loop, progression, systems)
4. **`Gnipahellir3/PLAYTEST.md`** — controls and how to verify changes

---

## 📚 Documentation by Purpose

### Project & Collaboration
| File | Purpose | Status |
|------|---------|--------|
| `Plan.md` | v1.0 shipping roadmap, phases 0–7 | **Active** — current phase reference |
| `project.md` | Gnipahellir2 vs Gnipahellir3 comparison | Reference — useful for architecture context |

### Current Session & Next Steps
| File | Purpose | Status |
|------|---------|--------|
| `Gnipahellir3/next_session.md` | Last session's handover (2026-07-13) | **Active** — start here for work queue |
| `Gnipahellir3/OPUS_HANDOVER.md` | Timeless letter to successor models: how to work with Glenn, the architecture religion, the game's soul | **Durable** — read if you're not Fable |
| `Gnipahellir3/score.md` | Vertical slice review (2026-07-13) | **Active** — current state assessment |

### Design & Architecture
| File | Purpose | Status |
|------|---------|--------|
| **`Gnipahellir3/plan.md`** | Game design: core loop, progression, all systems | **Active** — canonical design doc |
| **`Gnipahellir3/CLAUDE.md`** | Mandatory architecture rules & patterns | **Active** — non-negotiable |
| `architecture_findings.md` | Machine dependency chain design + build plan | **Active** — foundation for mana/machine systems |
| `draft1_machines.md` | Mana economy brainstorm (7 paths, dimension spawner idea) | **Reference** — §7 spawner slice shipped 2026-07-13 |
| `Gnipahellir3/gem_progression.md` | Gem ladder + gem dimensions + hazards design | **Active** — next-session build plan |
| `suggestion.md` | Pre-Phase 4 architecture review | **ARCHIVE** — most findings implemented; kept as resolved-issues record |

### AI & Gameplay Systems
| File | Purpose | Status |
|------|---------|--------|
| `Gnipahellir3/ai_algo.md` | Builder AI: implemented algorithm, states, logic | **Active** — current implementation reference |

### Testing & Verification
| File | Purpose | Status |
|------|---------|--------|
| **`Gnipahellir3/PLAYTEST.md`** | Controls, build commands, verification checklist | **Active** — use before every commit |

### Assets
| File | Purpose | Status |
|------|---------|--------|
| `Gnipahellir3/sprites/prompt.md` | Sprite asset generation prompts | **Active** — reference for art generation |

---

## 🗑️ Consolidation Status

✅ **Cleanup complete** (2026-07-13):
- Deleted: `enemy_ai.md`, `opus.md`, `HANDOVER.md`
- Kept: Single source of truth in `next_session.md`

### KEEP (active, reference-heavy)
- **`Plan.md`** — shipping roadmap (needed every phase)
- **`Gnipahellir3/plan.md`** — design bible (add to, never delete)
- **`CLAUDE.md`** — rules (grows, never shrinks)
- **`PLAYTEST.md`** — controls & verification (update as features change)
- **`architecture_findings.md`** — machine system blueprint (foundational for §Phase 5)
- **`draft1_machines.md`** — design brainstorm (referenced in phase plans)
- **`ai_algo.md`** — implementation reference (needed for AI changes)
- **`score.md`** — current state snapshot (useful for QA & next session context; update after major milestones)
- **`project.md`** — historical reference (G2 vs G3 comparison; helps understand design decisions)

---

## 📋 File Size & Scope Quick Reference

| File | Lines | Scope |
|------|-------|-------|
| `Gnipahellir3/CLAUDE.md` | 150 | Architecture rules (mandatory) |
| `Gnipahellir3/plan.md` | 350+ | Full game design |
| `Plan.md` | 300+ | Shipping phases 0–7 |
| `architecture_findings.md` | 250+ | Machine system design + build order |
| `draft1_machines.md` | 464 | Detailed mana economy options |
| `Gnipahellir3/ai_algo.md` | 150+ | Builder AI implementation |
| `Gnipahellir3/score.md` | 100+ | Current state assessment |
| `Gnipahellir3/PLAYTEST.md` | 50+ | Controls & verification |

---

## 🔄 How to Maintain This Overview

When you:
- **Add a new doc**: add a row to the appropriate table, update the "Start Here" section if foundational
- **Delete or consolidate**: remove the row(s) and update the "Consolidation Status" section above
- **Finish a phase**: update `Plan.md` status, snapshot state in `score.md`
- **Major design decision**: add to `plan.md` or create a focused design doc (e.g., `crafting_system.md`)

---

## ⚡ TL;DR — Active Docs You'll Touch Often

- **Before coding:** `Gnipahellir3/CLAUDE.md` (mandatory rules)
- **Work queue:** `Gnipahellir3/next_session.md` (active tasks)
- **Testing:** `Gnipahellir3/PLAYTEST.md` (controls & verification)
- **Game design:** `Gnipahellir3/plan.md` (systems & progression)
- **Roadmap:** `Plan.md` (shipping phases 0–7)
- **Machine systems (Phase 5+):** `architecture_findings.md` + `draft1_machines.md`
