# Pattern: Research & Exploration

Understand a codebase, problem space, or architecture using parallel exploration agents in tmux.

---

## When to Use

- **Onboarding** onto an unfamiliar codebase — need to map architecture, patterns, and conventions
- **Pre-implementation research** — need to understand existing code before building something new
- **Architecture review** — need a comprehensive understanding of how the system fits together
- **Dependency audits** — need to survey what's used and where

**Don't use** when you already know the codebase well, or for narrow questions where a single `grep` suffices.

---

## Recommended Team Composition

| Role | Agent Name | Focus |
|------|-----------|-------|
| **Team Lead** | `lead` | Synthesis, asks follow-up questions, produces final report |
| **Explorer 1** | `structure` | Directory layout, entry points, build system, configuration |
| **Explorer 2** | `patterns` | Code patterns, abstractions, data flow, key types |
| **Explorer 3** *(optional)* | `deps` | Dependencies, external integrations, API surface |

> **Tip:** For smaller codebases, 2 agents (structure + patterns) is enough.

---

## Wave Breakdown

### Wave 1: Broad Scan

**Goal:** Map the territory. Each agent scans a different dimension of the codebase.

```
┌──────────────────┬──────────────────┬──────────────────┐
│  Agent: structure │  Agent: patterns  │  Agent: deps      │
│  Map directories  │  Find key         │  Catalog external  │
│  Find entry       │  abstractions,    │  dependencies,     │
│  points, configs  │  patterns, types  │  API boundaries    │
└──────────────────┴──────────────────┴──────────────────┘
         ↓ Team lead synthesizes initial map
```

**Agent prompts should be specific:**
- Structure agent: "Map the directory tree, identify entry points (main files, index files), find config files (tsconfig, package.json, .env), and document the build pipeline."
- Patterns agent: "Find recurring code patterns — how are routes defined? How is state managed? What abstraction layers exist? Document with specific file:line references."
- Deps agent: "Catalog all external dependencies from package.json/go.mod/requirements.txt. Map which modules use which deps. Identify external API calls."

### Wave 2: Deep Dives

**Goal:** Based on Wave 1 findings, investigate specific areas in depth.

```
┌──────────────────┬──────────────────┐
│  Agent: deep-1    │  Agent: deep-2    │
│  Trace the auth   │  Trace the data   │
│  flow end-to-end  │  layer end-to-end │
│  (from HTTP to DB)│  (models → API)   │
└──────────────────┴──────────────────┘
         ↓ Team lead synthesizes into architecture doc
```

The team lead picks the 2-3 most important areas from Wave 1 findings and sends agents to trace them in detail.

### Wave 3: Synthesis *(team lead only)*

**Goal:** Combine all findings into a coherent report.

The team lead reads all agent output files and produces a final architecture document or research summary.

---

## File-Based State Example

`.claude/team-state.local.md`:

```markdown
---
wave: 2
status: in_progress
goal: "Map architecture of the payments service for migration planning"
started_at: 2026-02-07T09:00:00Z
---

## Completed
- [x] Directory structure mapped (wave-1-structure.md)
- [x] Key patterns identified: repository pattern, event sourcing (wave-1-patterns.md)
- [x] External deps cataloged: Stripe SDK, Redis, PostgreSQL (wave-1-deps.md)

## In Progress (Wave 2)
- [ ] Deep dive: payment processing flow (Stripe integration → event store → ledger)
- [ ] Deep dive: subscription lifecycle (create → renew → cancel → webhook handling)

## Key Findings So Far
- Entry point: src/server.ts → src/routes/index.ts
- All mutations go through event store before updating read models
- Stripe webhook handler is in src/webhooks/stripe.ts — 800 lines, needs refactoring
- No test coverage for subscription renewal edge cases

## Agent Outputs
- wave-1-structure.md
- wave-1-patterns.md
- wave-1-deps.md
```

---

## Example Commands

```bash
# Create a 2-agent exploration team
shipwright session codebase-explore

# Agents run in parallel panes — you can watch both scanning at once
# Team lead pane synthesizes results between waves

# Use tmux zoom (prefix + G) to focus on one agent's output
# Use synchronized input (prefix + S) to stop all agents at once if needed
```

---

## Tips

- **Use `haiku` for Wave 1 agents.** Broad scanning is simple work — haiku is fast and cheap for file discovery and pattern matching.
- **Use `sonnet` or `opus` for Wave 2 deep dives.** Tracing execution paths and understanding architecture requires stronger reasoning.
- **Give agents specific questions, not vague goals.** Instead of "explore the frontend," ask "How does the React app manage authentication state? Trace from login button click through to authenticated API calls."
- **Wave 1 should produce file:line references.** Agents should cite specific locations, not just describe patterns abstractly. This makes Wave 2 much more efficient.
- **The team lead's synthesis is the real deliverable.** Individual agent outputs are raw data. The team lead turns them into actionable understanding.

---

## Anti-Patterns

| Don't | Why |
|-------|-----|
| Send all agents to explore the same directories | Redundant work, wasted tokens |
| Skip Wave 1 and go straight to deep dives | You won't know which areas are worth diving into |
| Have agents write a "report" instead of citing specifics | Abstract summaries are useless — you need file:line references |
| Use more than 3 exploration agents | Diminishing returns — 3 agents cover most codebases in one wave |
| Run exploration waves beyond 3 | If you don't understand the codebase after 3 waves, the problem is prompt quality, not wave count |
