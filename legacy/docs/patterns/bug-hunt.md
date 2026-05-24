# Pattern: Bug Hunt

Track down complex bugs using parallel hypothesis testing with tmux teams.

---

## When to Use

- **Intermittent failures** — the bug doesn't reproduce reliably and you're not sure where to look
- **Complex root cause** — multiple possible explanations (race condition? state corruption? edge case?)
- **Large blast radius** — the symptom is far from the cause and you need to search broadly
- **Time-sensitive** — parallel investigation is faster than sequential hypothesis testing

**Don't use** for obvious bugs with clear stack traces, or when you already know the root cause and just need to fix it.

---

## Recommended Team Composition

| Role | Agent Name | Focus |
|------|-----------|-------|
| **Team Lead** | `lead` | Hypothesis formation, synthesis, fix verification |
| **Investigator 1** | `investigator-1` | Tests hypothesis A |
| **Investigator 2** | `investigator-2` | Tests hypothesis B |
| **Investigator 3** *(optional)* | `investigator-3` | Tests hypothesis C |

> **Tip:** Start with 2 investigators. Add a third only if Wave 1 produces 3+ viable hypotheses.

---

## Wave Breakdown

### Wave 1: Gather Evidence

**Goal:** Collect data from multiple angles simultaneously.

```
┌──────────────────┬──────────────────┬──────────────────┐
│  Agent: logs       │  Agent: code      │  Agent: history   │
│  Search error      │  Find related     │  Check git log    │
│  logs, stack       │  code paths,      │  for recent       │
│  traces, recent    │  identify         │  changes to       │
│  failures           │  suspects         │  affected area    │
└──────────────────┴──────────────────┴──────────────────┘
         ↓ Team lead forms hypotheses from evidence
```

**Agent instructions should be narrow:**
- Logs agent: "Search for error messages matching [pattern] in logs. Find the 5 most recent occurrences. Extract timestamps, stack traces, and request context."
- Code agent: "Read the code path for [affected operation]. Identify all places where [symptom] could originate. Check for missing error handling, race conditions, or state mutations."
- History agent: "Run `git log --since='2 weeks ago'` on [affected files]. Identify changes that could have introduced the bug. Check if the bug timing correlates with any deploy."

### Wave 2: Test Hypotheses (Parallel)

**Goal:** Each agent tests a different hypothesis simultaneously.

```
┌──────────────────┬──────────────────┬──────────────────┐
│  Agent: hypo-A     │  Agent: hypo-B    │  Agent: hypo-C    │
│  Test: race        │  Test: state      │  Test: edge case  │
│  condition in      │  corruption in    │  in input         │
│  auth middleware   │  session store    │  validation       │
└──────────────────┴──────────────────┴──────────────────┘
         ↓ Team lead evaluates which hypothesis has evidence
```

**Each agent should:**
1. Add targeted logging or assertions to test their hypothesis
2. Attempt to reproduce the bug under their hypothesis's conditions
3. Write a clear "confirmed/rejected/inconclusive" verdict with evidence

### Wave 3: Fix

**Goal:** Implement the fix based on confirmed hypothesis.

```
┌──────────────────┐
│  Agent: fixer      │
│  Implement fix     │
│  based on          │
│  confirmed         │
│  hypothesis        │
└──────────────────┘
         ↓ Team lead reviews fix
```

Usually a single agent. The team lead provides the confirmed root cause from Wave 2.

### Wave 4: Verify

**Goal:** Prove the fix works and prevent regression.

```
┌──────────────────┬──────────────────┐
│  Agent: regression │  Agent: verify    │
│  Write regression  │  Test that the    │
│  test that fails   │  original bug     │
│  without fix       │  no longer        │
│  passes with it    │  reproduces       │
└──────────────────┴──────────────────┘
         ↓ Team lead confirms: bug fixed, regression test in place
```

---

## File-Based State Example

`.claude/team-state.local.md`:

```markdown
---
wave: 2
status: in_progress
goal: "Find and fix intermittent 401 errors on /api/dashboard after session refresh"
started_at: 2026-02-07T16:00:00Z
---

## Bug Description
Users intermittently get 401 Unauthorized on /api/dashboard. Happens ~5% of the time,
mostly after browser has been idle for 10+ minutes. Session refresh should be transparent.

## Evidence (Wave 1)
- Error logs show 401s with valid-looking JWT signatures (wave-1-logs.md)
- Session refresh endpoint returns 200 but sometimes the new token isn't persisted (wave-1-code.md)
- git log shows refresh token rotation was added 3 weeks ago (wave-1-history.md)

## Hypotheses
- **A: Race condition** — refresh fires twice, second request uses revoked token
- **B: Cookie timing** — httpOnly cookie isn't set before the next API call fires
- **C: Clock skew** — JWT "not before" time is in the future on some requests

## In Progress (Wave 2)
- [ ] Testing hypothesis A: Add mutex/dedup to refresh logic
- [ ] Testing hypothesis B: Add cookie write logging, check timing
- [ ] Testing hypothesis C: Add clock skew tolerance, check JWT nbf

## Agent Outputs
- wave-1-logs.md
- wave-1-code.md
- wave-1-history.md
```

---

## Example Commands

```bash
# Create a 3-agent bug hunt team
shipwright session bug-hunt-401

# Watch all three investigators work in parallel panes
# Each pane shows a different hypothesis being tested

# Use prefix + G to zoom into the most promising investigator
# Use prefix + Alt-s to capture pane output for later review

# Monitor
shipwright status
```

---

## Tips

- **Wave 1 is about breadth, Wave 2 is about depth.** Cast a wide net first, then drill into the most promising leads.
- **Give each investigator ONE hypothesis.** Don't let agents explore multiple theories — focus produces better results.
- **Include reproduction steps in agent prompts.** If you know how to trigger the bug (even intermittently), include those exact steps.
- **The team lead forms hypotheses, not agents.** Agents gather evidence and test hypotheses. The team lead synthesizes evidence into hypotheses and decides which to pursue.
- **Add logging generously in Wave 2.** Hypothesis testing often requires instrumentation. Let agents add `console.log` or debug assertions freely — you can clean them up after.
- **Commit the fix AND the regression test together.** A fix without a regression test is a bug waiting to come back.

---

## Anti-Patterns

| Don't | Why |
|-------|-----|
| Skip evidence gathering (Wave 1) | You'll test the wrong hypotheses |
| Let agents form their own hypotheses | They lack the full picture — the team lead should synthesize |
| Test only one hypothesis at a time | That's sequential — the whole point is parallel hypothesis testing |
| Test more than 3 hypotheses per wave | Agents won't go deep enough on any of them |
| Implement a fix before confirming the root cause | You'll fix a symptom, not the cause |
| Skip the regression test (Wave 4) | The bug WILL come back |
