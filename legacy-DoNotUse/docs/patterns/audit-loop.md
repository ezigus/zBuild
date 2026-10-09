# Pattern: Audit Loop

Add self-reflection and quality gates to the continuous agent loop (`shipwright loop`) to prevent premature completion, catch regressions, and enforce project-specific standards.

---

## When to Use

- Running `shipwright loop` on tasks where **correctness matters more than speed** (production features, refactors, data migrations)
- The agent keeps declaring LOOP_COMPLETE **before the work is actually done**
- You want **automated quality checks** (tests, linting, type-checking) between iterations
- Your project has a **Definition of Done** that goes beyond "code compiles"

**Don't use** for quick prototypes, throwaway scripts, or exploration tasks where speed matters more than rigor.

---

## Audit Modes

### `--audit` (Self-Reflection)

The agent pauses after each iteration to review its own work before deciding whether to continue or declare completion.

**Cost:** Minimal — adds ~30 seconds per iteration (one extra prompt to the same agent).

**Best for:** Solo agent work where you want a sanity check without the overhead of a second agent.

```bash
shipwright loop "Build user auth with JWT" --audit --test-cmd "npm test"
```

### `--audit-agent` (Separate Auditor)

Spawns a dedicated auditor agent that reviews the work agent's output each iteration. The auditor can reject LOOP_COMPLETE and send the work agent back with specific feedback.

**Cost:** Higher — each iteration runs two agents (worker + auditor). Roughly 2x the API cost.

**Best for:** Complex features, production code, or tasks where you've seen the agent cut corners.

```bash
shipwright loop "Refactor auth to use refresh tokens" --audit-agent --model sonnet
```

### `--quality-gates` (Automated Checks)

Runs your test command, linter, or type-checker between iterations. The loop only advances if gates pass.

**Cost:** Depends on your test suite. Adds wall-clock time but no extra API cost.

**Best for:** Projects with existing CI checks you want to enforce locally.

```bash
shipwright loop "Add pagination to API" --quality-gates --test-cmd "npm test && npm run lint"
```

### Combining Modes

Modes stack. The most rigorous setup combines all three:

```bash
shipwright loop "Build payment integration" \
  --audit-agent \
  --quality-gates \
  --test-cmd "npm test" \
  --definition-of-done dod.md
```

---

## Writing Effective Definition of Done Files

A good DoD file is the single most effective way to prevent premature LOOP_COMPLETE.

### Template

```bash
cp ~/.shipwright/templates/definition-of-done.example.md my-dod.md
```

### Tips

- **Be specific.** "Tests pass" is weak. "Unit tests cover the 3 API endpoints and the auth middleware" is strong.
- **Include negative checks.** "No hardcoded API keys" or "No TODO markers" catch things agents skip.
- **Keep it short.** 8-15 items. More than that and the agent loses focus.
- **Order by importance.** The agent checks items top-to-bottom. Put critical items first.

### Example: Feature DoD

```markdown
# Definition of Done — Payment Integration

- [ ] Stripe webhook handler processes charge.succeeded and charge.failed
- [ ] Idempotency keys prevent duplicate charges
- [ ] Unit tests cover success, failure, and duplicate scenarios
- [ ] Integration test hits Stripe test mode
- [ ] All amounts stored as cents (integer), never floats
- [ ] No Stripe secret keys in source code
- [ ] Error responses follow existing API error format
```

---

## Preventing Premature LOOP_COMPLETE

The most common failure mode is the agent declaring victory too early. Countermeasures:

| Technique | How it helps |
|-----------|-------------|
| `--audit` | Agent re-reads its own output and catches obvious gaps |
| `--audit-agent` | Second opinion catches blind spots the worker has |
| `--definition-of-done` | Explicit checklist the agent must verify before completing |
| `--quality-gates` | Hard gate — tests must pass or the loop continues |
| `--test-cmd` | Even without quality gates, a test command gives the agent feedback |
| `--max-iterations` | Safety net — prevents infinite loops if nothing else works |

**Pro tip:** If the agent still completes too early, make your goal statement more specific. "Build auth" is vague. "Build JWT auth with login, signup, password reset, and refresh token rotation" gives the agent a clear finish line.

---

## Example Commands

```bash
# Quick audit for a small task
shipwright loop "Fix the N+1 query in user list" --audit --test-cmd "pytest tests/test_users.py"

# Rigorous audit for production feature
shipwright loop "Add RBAC to the API" --audit-agent --quality-gates \
  --test-cmd "npm test" --definition-of-done rbac-dod.md

# Cost-conscious: quality gates only, no extra agent
shipwright loop "Migrate DB schema" --quality-gates --test-cmd "npm run db:test"

# Maximum rigor: all checks enabled
shipwright loop "PCI compliance updates" --audit-agent --quality-gates \
  --test-cmd "npm test && npm run lint && npm run typecheck" \
  --definition-of-done pci-dod.md --max-iterations 15
```

---

## Anti-Patterns

| Don't | Why |
|-------|-----|
| Use `--audit-agent` for trivial tasks | 2x cost for a one-file fix is wasteful |
| Write a 30-item DoD | The agent loses focus. Keep it under 15 items |
| Skip `--test-cmd` with `--quality-gates` | Quality gates with no test command does nothing useful |
| Set `--max-iterations 1` with `--audit` | The audit has nowhere to send feedback if there's only one iteration |
| Rely solely on `--audit` for critical work | Self-reflection catches ~60% of issues. Add `--quality-gates` for the rest |
