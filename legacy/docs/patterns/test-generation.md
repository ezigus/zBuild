# Pattern: Test Generation

Build comprehensive test coverage using parallel agents that discover, generate, and validate tests iteratively.

---

## When to Use

- **Coverage campaigns** — systematically adding tests to a poorly-tested codebase
- **New feature testing** — generating unit + integration tests for freshly-built features
- **Edge case hunting** — finding and testing boundary conditions, error paths, race conditions
- **Test suite modernization** — upgrading old test patterns to current conventions

**Don't use** for writing a single test file, or when coverage is already good and you just need one more test.

---

## Recommended Team Composition

| Role | Agent Name | Focus |
|------|-----------|-------|
| **Team Lead** | `lead` | Orchestration, runs test suite, tracks coverage gaps |
| **Test Writer 1** | `unit-tests` | Unit tests for core business logic |
| **Test Writer 2** | `integration-tests` | Integration tests, API tests, cross-module tests |
| **Test Writer 3** *(optional)* | `edge-cases` | Edge cases, error paths, boundary conditions |

> **Tip:** For smaller projects, 2 agents (unit + integration) is enough. The team lead handles edge cases.

---

## Wave Breakdown

### Wave 1: Discover

**Goal:** Find what needs testing and understand existing test patterns.

```
┌──────────────────┬──────────────────┐
│  Agent: scanner    │  Agent: patterns  │
│  Find all testable │  Analyze existing │
│  functions, map    │  test patterns,   │
│  current coverage  │  fixtures, mocks  │
└──────────────────┴──────────────────┘
         ↓ Team lead identifies coverage gaps
```

**Scanner agent:** "Run the test suite with coverage reporting. List all files/functions below the coverage threshold. Identify untested public API surface."

**Patterns agent:** "Read existing test files. Document the patterns used — test runner, assertion style, mock strategy, fixture patterns. List file locations of good examples."

### Wave 2: Generate (Parallel Batches)

**Goal:** Write tests in parallel, partitioned by module or test type.

```
┌──────────────────┬──────────────────┬──────────────────┐
│  Agent: unit-tests│  Agent: int-tests │  Agent: edge-cases│
│  Unit tests for   │  Integration tests│  Edge cases for   │
│  src/services/     │  for src/api/      │  auth + payments   │
│  src/models/       │  routes             │  error paths       │
└──────────────────┴──────────────────┴──────────────────┘
         ↓ Team lead runs full test suite
```

**Critical:** Each agent writes tests in **different files**. Partition by directory or module:
- Unit tests agent → `src/services/__tests__/`, `src/models/__tests__/`
- Integration agent → `src/api/__tests__/`, `tests/integration/`
- Edge cases agent → `tests/edge-cases/`

### Wave 3: Validate & Fix

**Goal:** Run all tests, fix failures, fill remaining gaps.

```
┌──────────────────┬──────────────────┐
│  Agent: fixer-1    │  Agent: fixer-2    │
│  Fix failing unit  │  Fix failing       │
│  tests from Wave 2 │  integration tests │
└──────────────────┴──────────────────┘
         ↓ Team lead runs suite again
```

### Wave 4+: Iterate Until Green

Repeat Wave 3 until:
- All tests pass
- Coverage meets the target threshold
- No test failures remain

> **Set a wave limit.** 5-6 waves is typical for test generation. If tests aren't passing after 6 waves, the issue is likely in the code under test, not the tests themselves.

---

## File-Based State Example

`.claude/team-state.local.md`:

```markdown
---
wave: 3
status: in_progress
goal: "Achieve 80% test coverage for src/api/ and src/services/"
started_at: 2026-02-07T14:00:00Z
---

## Coverage Baseline
- src/api/: 32% → target 80%
- src/services/: 45% → target 80%
- src/models/: 71% → target 80%

## Completed
- [x] Scanned coverage, identified 23 untested functions (wave-1-scanner.md)
- [x] Documented test patterns: vitest, vi.mock(), factory fixtures (wave-1-patterns.md)
- [x] Generated 14 unit tests for src/services/ (wave-2-unit.md)
- [x] Generated 8 integration tests for src/api/ (wave-2-integration.md)
- [x] Generated 6 edge case tests for auth flows (wave-2-edge.md)

## In Progress (Wave 3)
- [ ] Fix 3 failing unit tests (mock setup issues)
- [ ] Fix 2 failing integration tests (missing test DB seed)

## Coverage After Wave 2
- src/api/: 32% → 61%
- src/services/: 45% → 74%
- src/models/: 71% → 78%

## Agent Outputs
- wave-1-scanner.md
- wave-1-patterns.md
- wave-2-unit.md
- wave-2-integration.md
- wave-2-edge.md
```

---

## Example Commands

```bash
# Create a 3-agent test generation team
shipwright session test-coverage

# Between waves, run the test suite from the lead pane:
#   pnpm test --coverage

# Watch agents writing tests in parallel across panes
# Use prefix + Ctrl-t for status dashboard

# After all waves complete
shipwright cleanup --force
```

---

## Tips

- **Always discover patterns first (Wave 1).** Agents that don't know the existing test conventions will write tests that look nothing like the rest of the suite.
- **Partition test files, not test cases.** Each agent should own entire test files, not individual test cases within a shared file. This prevents write conflicts.
- **Run the test suite between every wave.** The team lead should run tests after each wave and feed failure details into the next wave's agent prompts.
- **Include test file paths in prompts.** Don't say "write tests for the auth service." Say "write tests in `src/services/__tests__/auth.test.ts` for functions exported from `src/services/auth.ts`, using the vitest patterns shown in `src/services/__tests__/user.test.ts`."
- **Wave 3+ agents need failure context.** Copy-paste the actual test failure output into the agent's prompt so it can fix the specific issue.

---

## Anti-Patterns

| Don't | Why |
|-------|-----|
| Have two agents write to the same test file | File conflict — one agent's tests will be lost |
| Skip running tests between waves | You'll compound errors across waves |
| Generate tests without reading existing patterns | Tests will be stylistically inconsistent |
| Set coverage target at 100% | Diminishing returns — edge case tests past 85% are often brittle |
| Keep iterating past 6 waves | If tests still fail, the problem is in the code, not the tests |
