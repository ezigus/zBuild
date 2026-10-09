# Pattern: Feature Implementation

Build multi-component features using iterative parallel waves with tmux teams.

---

## When to Use

- Building a feature that spans **2+ layers** (frontend + backend, API + tests, etc.)
- Work can be **decomposed into independent modules** that different agents can build simultaneously
- You want **faster delivery** than sequential single-agent work

**Don't use** for single-file changes, tightly sequential work, or features small enough for one agent.

---

## Recommended Team Composition

| Role | Agent Name | Focus | Example Files |
|------|-----------|-------|---------------|
| **Team Lead** | `lead` | Orchestration, synthesis, integration | State file, final wiring |
| **Backend** | `backend` | Data models, API routes, services | `src/api/`, `src/services/`, `src/models/` |
| **Frontend** | `frontend` | UI components, state management | `apps/web/src/`, `*.tsx` |
| **Tests** *(optional)* | `tests` | Unit + integration tests | `src/tests/`, `*.test.ts` |

> **Tip:** For smaller features, combine frontend + tests into one agent (2-agent team).

---

## Wave Breakdown

### Wave 1: Research & Plan

**Goal:** Understand existing patterns before writing code.

```
┌──────────────────┬──────────────────┐
│  Agent: backend   │  Agent: frontend  │
│  Scan existing    │  Scan existing    │
│  API patterns,    │  component        │
│  data models,     │  patterns, state  │
│  middleware        │  management       │
└──────────────────┴──────────────────┘
         ↓ Team lead synthesizes findings
```

**Each agent writes:** `.claude/team-outputs/wave-1-{name}.md`

**Team lead then:** Reads both outputs, identifies the implementation approach, updates the state file with a plan.

### Wave 2: Parallel Implementation

**Goal:** Build independent components simultaneously.

```
┌──────────────────┬──────────────────┬──────────────────┐
│  Agent: backend   │  Agent: frontend  │  Agent: tests     │
│  Build data       │  Build UI         │  Set up test       │
│  model + API      │  components +     │  fixtures +        │
│  routes            │  state hooks      │  unit tests        │
└──────────────────┴──────────────────┴──────────────────┘
         ↓ Team lead reviews outputs, checks for errors
```

**Each agent writes:** `.claude/team-outputs/wave-2-{name}.md`

**Team lead then:** Reads outputs, runs a quick build/typecheck, identifies integration points.

### Wave 3: Integration & Validation

**Goal:** Wire components together, run tests, fix issues.

```
┌──────────────────┬──────────────────┐
│  Agent: backend   │  Agent: tests     │
│  Wire routes to   │  Run full test    │
│  frontend calls,  │  suite, write     │
│  fix type errors  │  integration tests│
└──────────────────┴──────────────────┘
         ↓ Team lead verifies everything passes
```

### Wave 4: Polish *(if needed)*

**Goal:** Fix remaining issues, documentation.

Usually a single agent handles the remaining fixes.

---

## File-Based State Example

`.claude/team-state.local.md`:

```markdown
---
wave: 2
status: in_progress
goal: "Build user authentication with JWT — login, signup, password reset"
started_at: 2026-02-07T10:00:00Z
---

## Completed
- [x] Scanned existing Express route patterns (wave-1-backend.md)
- [x] Scanned existing React component patterns (wave-1-frontend.md)
- [x] Decided: JWT with httpOnly cookies, Zod validation, React Hook Form

## In Progress (Wave 2)
- [ ] User model + auth routes (backend)
- [ ] Login/Signup/Reset components (frontend)
- [ ] Auth test fixtures + unit tests (tests)

## Blocked
- Integration tests blocked on Wave 2 completion

## Agent Outputs
- wave-1-backend.md — Express patterns, middleware chain analysis
- wave-1-frontend.md — React component patterns, existing form handling
```

---

## Example Commands

```bash
# Create the team session with 3 panes
shipwright session auth-feature

# In the team lead pane, describe the feature goal and wave plan
# The team lead spawns workers and tracks state in .claude/team-state.local.md

# Monitor progress from any terminal
shipwright status

# Clean up when done
shipwright cleanup --force
```

---

## Tips

- **Partition files strictly.** Before Wave 2, explicitly tell each agent which directories they own. File conflicts are the #1 failure mode.
- **Run typecheck between waves.** The quality gate hooks help here — `teammate-idle.sh` catches type errors before agents go idle.
- **Don't over-decompose Wave 1.** Two research agents are usually enough. More than 3 researchers creates redundant analysis.
- **Wave 3 is where things break.** Integration is inherently serial. Be ready to have the team lead handle wiring personally if agents struggle with cross-module connections.
- **Use `sonnet` for implementation, `haiku` for lookups.** Save the expensive models for the architecture decisions in Wave 1.

---

## Anti-Patterns

| Don't | Why |
|-------|-----|
| Let two agents edit the same file | One overwrites the other |
| Skip Wave 1 research | Agents will re-invent existing patterns instead of following them |
| Give agents the full feature spec | They lose focus. Give each agent only their slice |
| Run Wave 3 without checking Wave 2 outputs | You'll integrate broken code |
| Use 4+ agents for a single feature | Coordination cost exceeds the parallel benefit |
