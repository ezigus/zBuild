# Compound Negative-Critical Audit Report — Shipwright v3.2.0

**Date**: 2026-02-28
**Method**: 6 parallel audit architects applying negative-critical analysis
**Question**: What did we get wrong? Miss? Not think through? Fail to test, audit, research, validate, or prove works E2E?

---

## Executive Summary

Shipwright is **architecturally impressive and feature-complete** but **proof-incomplete and reliability-fragile**. The 6 auditors independently converged on the same systemic pattern: **Shipwright builds features faster than it proves they work.**

**By the numbers:**

- 2 CRITICAL security vulnerabilities
- 5 HIGH security vulnerabilities
- 18 reliability failure modes (10 P0, 5 P1, 3 P2)
- 7 functions deletable without test failure
- 6 daemon patrol functions with ZERO test coverage
- 0 A/B data proving memory system helps
- ~30-40% E2E proof level (target: 95%)
- 2190+ instances of `|| true` silently suppressing errors

---

## Part 1: Cross-Auditor Convergence (Highest Priority)

These areas were flagged by **3+ auditors independently** — the compound signal that these are the real blind spots:

### 1. Silent Error Suppression (Flagged by: Security, Reliability, Test, E2E)

**The Pattern**: 2190+ instances of `|| true` and `2>/dev/null` across the codebase.

- **Security**: Errors that could indicate attacks are swallowed
- **Reliability**: GitHub API failures, git operations, and state writes fail silently
- **Testing**: Tests never see failures because mocks always succeed
- **E2E**: Pipeline claims success when critical operations silently failed

**Root Cause**: `set -euo pipefail` is used correctly, but the codebase compensates by aggressively suppressing every error that _might_ happen, including ones that _must not_ be ignored.

**Impact**: The single most dangerous pattern in the codebase. A pipeline can "succeed" while:

- PR was never created (gh failed silently)
- Tests were never run (test cmd failed silently)
- State was never saved (disk full, suppressed)
- Memory was never captured (SQLite locked, suppressed)

### 2. Memory System: Claimed But Unproven (Flagged by: E2E, Test, Architecture, Completeness)

**The Pattern**: Memory system claims to "measurably improve build outcomes" but has zero measurement data.

- **E2E**: No A/B testing, no control group, no statistical validation
- **Test**: TF-IDF ranking tested for structure, not correctness
- **Architecture**: Keyword matching in bash has fundamental accuracy limits
- **Completeness**: `intelligence.ab_test_ratio: 0.2` exists in config but is never used

**Root Cause**: The feature was built before the measurement infrastructure. There's no feedback loop from "memory injected" → "did it help?"

**Impact**: Could be actively harming outcomes by injecting false patterns that increase hallucination. Opportunity cost: lookup/injection adds latency with unproven ROI.

### 3. Non-Atomic Writes → Data Corruption (Flagged by: Reliability, Security, Test, Architecture)

**The Pattern**: Critical state files written with `echo >>` or `>` instead of atomic tmp+mv.

- **Reliability**: JSONL partial writes, checkpoint corruption, state.json truncation
- **Security**: Race conditions in heartbeat files enable symlink attacks
- **Test**: No corruption recovery tests exist
- **Architecture**: Dual-write JSONL+SQLite with no consistency guarantee

**Root Cause**: Atomic write pattern (`tmp + validate + mv`) is documented as a convention but not enforced. Many scripts predate the convention.

**Impact**: Every crash or kill signal can corrupt events.jsonl, state.json, or checkpoint files. Recovery is manual and data loss is permanent.

### 4. Concurrency: Untested & Unsafe (Flagged by: Reliability, Test, E2E, Architecture)

**The Pattern**: Multi-worker, multi-daemon, multi-fleet operations use file-based locking without proper concurrency primitives.

- **Reliability**: SQLite has no `busy_timeout`, PID-file locks are raceable, two daemons can pick the same issue
- **Test**: Zero concurrent operation tests
- **E2E**: Fleet rebalancing never proven under real load
- **Architecture**: Bash has no threads, async, or proper locking primitives

**Root Cause**: System designed for single-worker use, then extended to multi-worker without revisiting concurrency model.

**Impact**: At `max_workers >= 2`, race conditions are **likely, not theoretical**. SQLite deadlock, duplicate pipeline spawns, and state corruption are all realistic.

### 5. Dashboard: Unauthenticated by Default (Flagged by: Security, E2E, Reliability)

**The Pattern**: WebSocket server allows unauthenticated connections when auth is disabled (the default).

- **Security**: Anyone on the network can read all pipeline events, costs, agents
- **E2E**: No consistency model documented; no crash recovery proven
- **Reliability**: Unbounded client connections; no rate limiting

**Root Cause**: Dashboard built for local-only use, then exposed to network without adding auth requirements.

**Impact**: Information disclosure of all pipeline data to anyone who can reach the port.

---

## Part 2: What We Got Wrong (Retrospective)

### Wrong Assumption 1: "Tests with mocks prove correctness"

**Reality**: Mocks always succeed. Real APIs fail 5-10% of the time. The entire daemon patrol (1160 lines, 6 functions) has zero test coverage because tests mock the main loop. Functions could be deleted and all 102 test suites would still pass.

### Wrong Assumption 2: "Building the feature IS proving it works"

**Reality**: Memory system, auto-scaling, fleet rebalancing, intelligence stage-skipping, and compound quality gates all exist as code but have never been measured against baselines. Features were shipped without proof they improve outcomes.

### Wrong Assumption 3: "|| true makes scripts robust"

**Reality**: `|| true` makes scripts _survivable_ but _blind_. 2190+ suppressed errors means 2190+ possible silent failures. The correct pattern is `|| { log_error "..."; handle_gracefully; }`.

### Wrong Assumption 4: "Single-worker patterns extend to multi-worker"

**Reality**: File locks, PID files, and direct SQLite writes work for one worker. At 2+ workers, you need `flock`, `PRAGMA busy_timeout`, and proper concurrent state management.

### Wrong Assumption 5: "Local dashboards don't need auth"

**Reality**: Even "local" services bind to 0.0.0.0 by default. Any device on the network can connect. WebSocket needs auth regardless of deployment context.

---

## Part 3: What We Missed (Gap Analysis)

| Category              | What's Missing                                   | Impact                                                     |
| --------------------- | ------------------------------------------------ | ---------------------------------------------------------- |
| **Measurement**       | No A/B testing framework for any feature         | Can't prove ROI of memory, intelligence, or stage-skipping |
| **Chaos testing**     | No fault injection tests                         | Don't know what happens when things break in production    |
| **Load testing**      | No concurrent worker benchmarks                  | Don't know actual scalability ceiling                      |
| **Dashboard tests**   | 5948 lines of TypeScript with zero tests         | Auth, RBAC, WebSocket all unvalidated                      |
| **Patrol testing**    | 1160 lines completely untested                   | Security scans, auto-scaling, config refresh all unproven  |
| **Secret redaction**  | No log sanitization                              | API keys could appear in error logs                        |
| **File permissions**  | Configs world-readable (644)                     | Secrets exposed on multi-user systems                      |
| **Input validation**  | Issue titles flow into bash/markdown unsanitized | Command injection and XSS vectors                          |
| **Convergence data**  | No metrics on loop completion rates              | Don't know if loops converge or timeout                    |
| **Consistency model** | Dashboard has no defined consistency guarantees  | Stale state leads to wrong decisions                       |

---

## Part 4: What We Failed to Prove (Evidence Gaps)

| Claim                                       | Evidence Level        | What's Needed                                    |
| ------------------------------------------- | --------------------- | ------------------------------------------------ |
| "Autonomous delivery from issue to PR"      | 30% (mock-based)      | 20+ real feature pipelines with metrics          |
| "Memory measurably improves outcomes"       | 0% (no data)          | A/B test: 40 pipelines, statistical significance |
| "Fleet scales across repos"                 | 5% (config only)      | 4-repo deployment, 100+ issues, 30 days          |
| "Auto-scaling responds to load"             | 10% (math documented) | Load test: 0→100 issues, measure response curve  |
| "Dashboard shows real-time state"           | 50% (server exists)   | Consistency model, crash recovery test           |
| "Compound quality catches defects"          | 30% (modules exist)   | Intentionally buggy PR, measure catch rate       |
| "Intelligence skipping improves efficiency" | 0% (no data)          | A/B test: skip vs no-skip, measure cost/quality  |
| "Self-healing loops converge"               | 40% (happy path)      | 20+ complex tasks, measure completion rates      |

---

## Part 5: Severity-Ranked Master Finding List

### P0 — Fix Before Production (1-2 sprints)

| #   | Finding                                                       | Auditors                  | Fix Effort |
| --- | ------------------------------------------------------------- | ------------------------- | ---------- |
| 1   | WebSocket auth bypass (unauthenticated by default)            | Security, E2E             | 2h         |
| 2   | SQLite `PRAGMA busy_timeout` missing → deadlock at 2+ workers | Reliability, Architecture | 1h         |
| 3   | JSONL non-atomic writes → data corruption on crash            | Reliability, Architecture | 4h         |
| 4   | Secret leakage in error logs (no redaction)                   | Security                  | 4h         |
| 5   | File permissions 644 on sensitive configs                     | Security                  | 2h         |
| 6   | tmpfile cleanup never guaranteed (no trap handlers)           | Reliability               | 4h         |
| 7   | Two daemons can race on same issue (insufficient locking)     | Reliability, Test         | 4h         |
| 8   | Daemon patrol 6 functions completely untested                 | Test                      | 8h         |
| 9   | Hook injection from malicious `.claude/` repos                | Security                  | 4h         |
| 10  | Issue title command injection / markdown injection            | Security                  | 2h         |

### P1 — Fix Within 1 Month

| #   | Finding                                                   | Auditors         | Fix Effort |
| --- | --------------------------------------------------------- | ---------------- | ---------- |
| 11  | GitHub API rate limit cascade (no backoff/retry)          | Reliability, E2E | 8h         |
| 12  | Checkpoint restore from corrupted state → data loss       | Reliability      | 4h         |
| 13  | Worktree cleanup failure → disk leak (500MB-1GB each)     | Reliability      | 4h         |
| 14  | Dashboard server zero TypeScript tests (5948 lines)       | Test             | 16h        |
| 15  | Pipeline intelligence 6 functions zero coverage           | Test             | 8h         |
| 16  | Memory system: no A/B testing, no proof of benefit        | E2E, Test        | 16h        |
| 17  | Backoff logic in daemon-poll untested                     | Test             | 4h         |
| 18  | Loop env vars not reset between iterations → cost overrun | Reliability      | 2h         |
| 19  | Auto-scaling: config exists, behavior unproven            | E2E, Test        | 8h         |
| 20  | Worktree path traversal via symlinks                      | Security         | 2h         |

### P2 — Fix Within 3 Months

| #   | Finding                                                                           | Auditors              | Fix Effort |
| --- | --------------------------------------------------------------------------------- | --------------------- | ---------- |
| 21  | Fleet rebalancing undocumented and unproven                                       | E2E                   | 16h        |
| 22  | Pipeline-stages.sh still 3078 lines (further decomposition needed)                | Architecture          | 16h        |
| 23  | Dual-write JSONL+SQLite with no consistency guarantee                             | Architecture          | 16h        |
| 24  | Intelligence stage-skipping unmeasured                                            | E2E                   | 8h         |
| 25  | Dashboard consistency model undefined                                             | E2E                   | 8h         |
| 26  | SQL injection vectors (inconsistent `_sql_escape` usage)                          | Reliability, Security | 4h         |
| 27  | Lock stale PID detection unreliable                                               | Reliability           | 4h         |
| 28  | Disabled features (adversarial, simulation, architecture) — broken or incomplete? | Completeness          | 8h         |
| 29  | Scalability ceiling ~50 workers (bash subprocess overhead)                        | Architecture          | Roadmap    |
| 30  | No chaos/fault injection test suite                                               | Test, Reliability     | 16h        |

---

## Part 6: Recommendations for Permanent Audit Loops

### 1. Add `audit` Pipeline Stage

Insert an `audit` stage after `compound_quality` that runs these automated checks:

- Secret scan (grep for API keys in artifacts)
- File permission validation
- Atomic write pattern enforcement
- `|| true` count delta (should not increase)
- Test coverage delta (should not decrease)

### 2. Memory A/B Testing Pipeline

Implement continuous A/B testing:

- 20% of pipelines run without memory injection (control)
- 80% with memory (treatment)
- Track: iterations, cost, test failures, completion rate
- Monthly significance test; disable feature if p > 0.05

### 3. Chaos Test Suite

Add `shipwright chaos` command:

- Kill random processes mid-pipeline
- Fill disk to 95% and run pipeline
- Inject network timeout on GitHub API calls
- Run 4 daemons on same repo simultaneously
- Corrupt state.json and attempt recovery

### 4. E2E Proof Dashboard

Add metrics to existing dashboard:

- Loop completion rate (target: >90%)
- Memory injection delta (iterations saved)
- Fleet rebalance latency
- Auto-scale response time
- Compound quality catch rate

### 5. Pre-Merge Audit Hook

Add a PostToolUse hook that runs before every merge:

- Verify no new `|| true` without `# Expected:` comment
- Verify no new `2>/dev/null` without error handling
- Verify atomic write pattern on state files
- Verify test coverage didn't decrease

### 6. Negative-Critical Retrospective Loop

After every pipeline run, automatically ask:

- Did any stage silently fail? (check for empty artifacts)
- Did any quality gate get skipped? (check compound_quality log)
- Did cost exceed prediction? (compare actual vs estimated)
- Did loop converge or exhaust? (check iteration count vs limit)

Capture answers in memory system for pattern detection.

---

## Conclusion

Shipwright's core architecture is sound. The codebase demonstrates sophisticated engineering: event-driven design, self-healing loops, convergence detection, memory systems, and fleet orchestration. The problem isn't what was built — it's what was never proven.

**The compound audit reveals a single systemic pattern**: features are built, tested with mocks, documented, and shipped — but never measured against reality. The fix isn't more features; it's more proof.

**Top 3 actions with highest compound impact:**

1. **Fix silent error suppression** — Replace 2190+ `|| true` with proper error handling. This single change addresses findings from all 6 auditors.

2. **Add A/B measurement framework** — Prove memory, intelligence, and stage-skipping actually help. This converts "claimed" features into "proven" features.

3. **Fix concurrency primitives** — Add `PRAGMA busy_timeout`, replace PID locks with `flock`, add concurrent operation tests. This makes multi-worker operation reliable instead of lucky.

---

_Generated by 6 Audit Architect agents in parallel negative-critical analysis mode._
_Cross-referenced across: Architecture, Test Coverage, E2E Proof, Reliability, Security, Completeness._
