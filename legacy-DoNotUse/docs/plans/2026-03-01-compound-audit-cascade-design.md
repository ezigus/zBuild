# Compound Audit Cascade — Design Document

## Goal

Replace the one-shot `compound_quality` stage with an adaptive multi-agent cascade that iteratively probes for bugs across specialized categories until confidence is high.

## Problem

The current `compound_quality` stage runs a single adversarial review + negative testing pass. It catches surface-level issues but misses deeper problems because:

1. **Single perspective** — one Claude call can't specialize in logic, integration, security, AND completeness simultaneously.
2. **No iteration** — runs once and moves on. If the review misses something, it stays missed.
3. **No convergence signal** — can't tell whether findings are exhaustive or just scratching the surface.
4. **No deduplication** — if multiple checks flag the same issue, they report it separately.

## Architecture

### Adaptive Cascade Loop

```
stage_compound_quality()
│
├─ Pre-flight: validate meaningful code changes exist (existing)
│
├─ Cycle 1: Core Agents (parallel via claude -p --model haiku)
│   ├─ Logic Auditor    → bugs, wrong algorithms, edge cases
│   ├─ Integration Auditor → wiring gaps, missing connections
│   └─ Completeness Auditor → spec coverage, missing features
│   │
│   └─ Dedup + Classify → { critical, high, medium, low }
│       │
│       ├─ If critical/high found → trigger specialist escalation
│       │   ├─ "security" keyword → add Security Auditor
│       │   ├─ "error handling" keyword → add Error Handling Auditor
│       │   ├─ "performance" keyword → add Performance Auditor
│       │   └─ "edge case" keyword → add Edge Case Auditor
│       │
│       └─ Check convergence → continue or stop
│
├─ Cycle 2..N: Core + Triggered Specialists (parallel)
│   └─ Run agents → dedup → classify → check convergence
│
├─ Convergence: stop when ANY of:
│   ├─ No new critical/high findings in latest cycle
│   ├─ Duplicate rate > 98% (diminishing returns)
│   └─ max_cycles reached (hard cap, default 3)
│
├─ Emit audit trail events for each cycle + finding
│
└─ Output: structured findings JSON + pass/fail verdict
```

### Agent Specializations

**Core 3 (always run):**

| Agent | Focus | Example findings |
|---|---|---|
| Logic Auditor | Control flow bugs, off-by-one, wrong conditions, null paths | "Function returns early before cleanup on error path" |
| Integration Auditor | Missing imports, broken call chains, mismatched interfaces | "Handler registered but route never wired in router" |
| Completeness Auditor | Spec vs. implementation gaps, missing tests, placeholders | "Plan requires --force flag but implementation omits it" |

**Specialists (triggered by core findings):**

| Specialist | Trigger keywords | Focus |
|---|---|---|
| Security | auth, injection, secrets, permissions, credential | OWASP top 10, credential exposure, input validation |
| Error Handling | catch, error, fail, exception, silent | Silent swallows, missing error paths, inconsistent handling |
| Performance | loop, query, memory, scale, O(n) | O(n^2) patterns, unbounded allocations, missing pagination |
| Edge Cases | boundary, limit, empty, null, zero, max | Zero-length inputs, max values, concurrent access |

### Context Bundle (shared by all agents)

Each agent receives:
- Cumulative git diff from branch point
- Test evidence JSON (from audit trail)
- Plan/spec summary (from pipeline artifacts)
- Previous cycle findings (so agents don't repeat known issues)

### Finding Schema

```json
{
  "findings": [
    {
      "severity": "critical|high|medium|low",
      "category": "logic|integration|completeness|security|error_handling|performance|edge_case",
      "file": "path/to/file.sh",
      "line": 42,
      "description": "One-sentence description",
      "evidence": "The specific code or pattern that's wrong",
      "suggestion": "How to fix it"
    }
  ]
}
```

### Deduplication Strategy

**Tier 1: Structural match (free, instant)**
- Same file + same category + lines within 5 of each other = duplicate
- Catches 60-70% of duplicates without any LLM call

**Tier 2: LLM dedup judge (cheap)**
- After all agents complete, send findings to `claude -p --model haiku`:
  "Group findings by whether they describe the SAME underlying issue. Two findings are the same if fixing one would fix the other."
- Returns groups: `[{"canonical": 0, "duplicates": [2, 5]}, ...]`
- Canonical finding in each group keeps the best description

### Convergence Calculation

```
new_unique = findings_this_cycle - duplicates_of_previous_cycles
duplicate_rate = duplicates / total_findings_this_cycle
converged = (no critical/high in new_unique) OR (duplicate_rate > 0.98) OR (cycle >= max_cycles)
```

## Implementation

### New File: `scripts/lib/compound-audit.sh`

Four functions:

| Function | Purpose |
|---|---|
| `compound_audit_run_cycle()` | Runs N agents in parallel, collects JSON findings |
| `compound_audit_dedup()` | Tier 1 structural + Tier 2 haiku judge |
| `compound_audit_escalate()` | Scans findings for trigger keywords, returns specialist list |
| `compound_audit_converged()` | Checks stop conditions |

### Integration

Replace body of `stage_compound_quality()` in `pipeline-intelligence.sh` (~line 1148). Existing pre-flight checks (bash compat, coverage) stay. Existing adversarial/negative/e2e/dod checks replaced by cascade.

### Agent Execution

Each agent: `claude -p "$prompt" --model haiku`
Core 3 run in parallel: bash background jobs (`&` + `wait`).
Parse JSON output from each agent's stdout.

### Audit Trail Events

| Event | Payload |
|---|---|
| `compound.cycle_start` | cycle, agents list |
| `compound.finding` | severity, category, file, line, description |
| `compound.dedup` | unique count, duplicate count, duplicate rate |
| `compound.cycle_complete` | new unique findings, triggered specialists |
| `compound.converged` | reason (no_criticals, dup_rate, max_cycles) |

### Template Config

```json
{
  "id": "compound_quality",
  "config": {
    "max_cycles": 3,
    "dedup_model": "haiku",
    "escalation_enabled": true,
    "block_on_critical": true
  }
}
```

### Cost Estimate

| Scenario | Agents | Cost |
|---|---|---|
| Cycle 1 (core only, clean code) | 3 + 1 dedup | ~$0.004 |
| Cycle 2 (with 2 specialists) | 5 + 1 dedup | ~$0.006 |
| Worst case (3 cycles, full escalation) | ~15 + 3 dedup | ~$0.02 |

Negligible vs. build stage costs ($0.50-2.00).

### Fail-Open Principle

All compound audit calls wrapped in `|| true`. If any agent call fails or times out, that agent's findings are skipped. The cascade continues with remaining agents. Pipeline never blocks on audit infrastructure failures.

## Testing Strategy

1. Unit tests in `scripts/sw-lib-compound-audit-test.sh` — dedup, escalation, convergence functions
2. Integration: mock agent outputs, verify cascade loop behavior
3. Regression: existing pipeline tests still pass
4. E2E: run pipeline, verify compound audit events in JSONL

## Non-Goals

- No external LLM providers — Claude Code only (`claude -p`)
- No persistent finding database — findings live in audit trail JSONL
- No auto-fix — findings are reported, not automatically resolved
- No UI — findings appear in pipeline-audit.md report only
