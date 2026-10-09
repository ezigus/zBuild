# Pattern: Refactoring

Perform large-scale code transformations safely using a 2-agent team with strict file ownership and iterative validation.

---

## When to Use

- **Pattern migration** — converting callbacks to async/await, class components to hooks, etc.
- **Architecture changes** — extracting modules, reorganizing directories, splitting monoliths
- **API redesign** — changing function signatures, renaming across the codebase
- **Dependency replacement** — swapping one library for another throughout the project

**Don't use** for small renames in 1-2 files, or cosmetic changes like formatting.

---

## Recommended Team Composition

| Role | Agent Name | Focus | Owns |
|------|-----------|-------|------|
| **Team Lead** | `lead` | Orchestration, runs tests between waves | State file |
| **Refactorer** | `refactor` | Source code transformations | Production source files |
| **Consumers** | `consumers` | Updates tests, imports, dependents | Test files, config files, docs |

> This is intentionally a **2-agent** pattern. Refactoring requires tight coordination — more agents means more conflict risk. The team lead runs tests.

---

## Wave Breakdown

### Wave 1: Map

**Goal:** Find all instances of the old pattern and understand the dependency graph.

```
┌──────────────────┬──────────────────┐
│  Agent: refactor   │  Agent: consumers │
│  Find all          │  Find all tests,  │
│  instances of old  │  imports, and     │
│  pattern in source │  dependents of    │
│  code               │  affected modules │
└──────────────────┴──────────────────┘
         ↓ Team lead builds the transformation plan
```

**This wave is critical.** The team lead uses both outputs to:
1. Identify the full blast radius of the change
2. Order the transformation (leaf nodes first)
3. Assign specific files to each agent

### Wave 2: Transform (Leaf Nodes First)

**Goal:** Change the code, starting with modules that nothing else depends on.

```
┌──────────────────┬──────────────────┐
│  Agent: refactor   │  Agent: consumers │
│  Transform leaf    │  Update tests for │
│  modules — files   │  leaf modules,    │
│  with zero         │  fix imports      │
│  dependents        │                    │
└──────────────────┴──────────────────┘
         ↓ Team lead runs tests — should still pass
```

**Why leaf nodes first?** If you change a core module first, everything that depends on it breaks simultaneously. By starting with leaf nodes, you keep the test suite green between waves.

### Wave 3: Transform Core

**Goal:** Transform the remaining core modules, now that leaf nodes are done.

```
┌──────────────────┬──────────────────┐
│  Agent: refactor   │  Agent: consumers │
│  Transform core    │  Update remaining │
│  modules           │  tests, fix type  │
│                    │  errors           │
└──────────────────┴──────────────────┘
         ↓ Team lead runs full test suite
```

### Wave 4+: Fix Breakage

**Goal:** Iteratively fix test failures and type errors until green.

```
┌──────────────────┬──────────────────┐
│  Agent: refactor   │  Agent: consumers │
│  Fix source code   │  Fix test         │
│  issues from test  │  failures,        │
│  failures           │  update snapshots │
└──────────────────┴──────────────────┘
         ↓ Team lead verifies: all tests pass, no type errors
```

---

## File-Based State Example

`.claude/team-state.local.md`:

```markdown
---
wave: 3
status: in_progress
goal: "Convert all callback-based code in src/services/ to async/await"
started_at: 2026-02-07T11:00:00Z
---

## Transformation Map (from Wave 1)
Leaf nodes (no dependents):
- src/services/email.ts (5 callbacks)
- src/services/logger.ts (2 callbacks)

Core modules (have dependents):
- src/services/db.ts (12 callbacks) → used by 8 other files
- src/services/auth.ts (7 callbacks) → used by 4 other files

## Completed
- [x] Mapped all 26 callback instances across 4 files (wave-1-refactor.md)
- [x] Found 14 test files and 6 other dependents (wave-1-consumers.md)
- [x] Converted email.ts and logger.ts to async/await (wave-2)
- [x] Updated tests for email.ts and logger.ts (wave-2)

## In Progress (Wave 3)
- [ ] Convert db.ts (12 callbacks → async/await)
- [ ] Convert auth.ts (7 callbacks → async/await)
- [ ] Update 14 test files for new signatures
- [ ] Fix imports in 6 dependent modules

## Test Status
- After Wave 2: 142/142 passing
- After Wave 3: TBD

## Agent Outputs
- wave-1-refactor.md — Full callback inventory with file:line
- wave-1-consumers.md — Dependency map of affected modules
```

---

## Example Commands

```bash
# Create a 2-agent refactoring team
shipwright session refactor-async

# In the lead pane, describe the refactoring goal
# Team lead assigns specific files to each agent per wave

# Run tests between waves from the lead pane:
#   pnpm test

# Monitor agents in their panes
shipwright status

# Clean up
shipwright cleanup --force
```

---

## Tips

- **Always map before transforming.** Wave 1 is non-negotiable. Skipping it leads to missed instances and cascading breakage.
- **Transform leaf nodes first.** This keeps the test suite green through intermediate waves, which gives you confidence that each wave's changes are correct.
- **The team lead must run tests between every wave.** This is the safety net. If tests break, you know which wave caused it.
- **Strict file ownership.** The refactorer owns production files. The consumers agent owns test files and config. Never overlap.
- **Use git commits between waves.** After each successful wave (tests pass), commit. This gives you rollback points if a later wave goes wrong.

---

## Anti-Patterns

| Don't | Why |
|-------|-----|
| Transform everything at once | If it breaks, you won't know which change caused it |
| Let both agents edit the same file | Write conflicts |
| Skip running tests between waves | You lose the ability to isolate which wave broke things |
| Start with core modules | Everything that depends on them breaks simultaneously |
| Use 3+ agents for refactoring | The file ownership partition becomes too fragmented |
| Refactor and add features simultaneously | One change at a time — refactoring should be behavior-preserving |
