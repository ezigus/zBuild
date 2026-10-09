# Pipeline Audit Trail — Design Document

## Goal

Add structured, compliance-grade audit logging to Shipwright pipelines so every run produces a complete traceability chain: prompt in, plan out, test evidence, audit decisions, and final outcome.

## Problem

Today the pipeline logs raw output (iteration logs, test stdout, pass/fail verdicts) but has critical gaps:

1. **Prompts are discarded** — `compose_prompt()` builds the prompt and passes it directly to `claude -p`. The input is never saved to disk.
2. **Audit verdicts are opaque** — `audit-iter-N.log` contains ~40 bytes ("verdict · recommendation") with no evidence chain or rationale.
3. **No cross-stage lineage** — plan.md, design.md, and build output are separate files with no index connecting them.
4. **Token tracking is incomplete** — `.claude-tokens-*.log` files exist but are often empty.

## Architecture

### Audit Artifacts (per pipeline run)

```
.claude/pipeline-artifacts/
├── pipeline-audit.jsonl     # Append-only structured event log (crash-safe)
├── pipeline-audit.json      # Consolidated summary (generated at end)
└── pipeline-audit.md        # Human-readable compliance report (generated at end)
```

### Raw Artifact Preservation

```
.claude/loop-logs/
├── iteration-N.prompt.txt   # NEW: Full prompt text saved before sending to Claude
├── iteration-N.log          # Claude's text response (existing)
├── iteration-N.json         # Claude's JSON response (existing)
├── test-evidence-iter-N.json # Structured test results (existing)
```

### Event Types

| Event | When | Payload |
|---|---|---|
| `pipeline.start` | Pipeline begins | Issue, goal, template, model, stages, git SHA |
| `stage.start` | Stage begins | Stage name, inputs, config |
| `stage.complete` | Stage ends | Duration, verdict, output artifact paths |
| `loop.prompt` | Before Claude call | Prompt char count, path to `.prompt.txt` |
| `loop.response` | After Claude call | Response length, exit code, token usage, path to `.json` |
| `loop.test_gate` | After test execution | Structured test evidence per command |
| `loop.audit_verdict` | After audit agent | Verdict, rationale, evidence |
| `loop.verification_gap` | Verification gap fires | Tests pass + audit disagrees, resolution |
| `pipeline.complete` | Pipeline ends | Status, duration, cost, PR URL |

### New File: `scripts/lib/audit-trail.sh`

Single library with four functions:

- `audit_init()` — Creates JSONL file, writes `pipeline.start` event
- `audit_emit(event_type, key=value...)` — Appends one JSON line
- `audit_save_prompt(prompt_text, iteration)` — Saves `iteration-N.prompt.txt`
- `audit_finalize()` — Reads JSONL, generates `.json` + `.md` reports

### Integration Points (5 files, ~30 lines total)

| File | Change |
|---|---|
| `scripts/lib/pipeline-stages.sh` | Source library, `audit_init` at start, `audit_emit` at stage transitions, `audit_finalize` at end |
| `scripts/lib/loop-iteration.sh` | `audit_save_prompt` before `claude -p`, `audit_emit` after response |
| `scripts/sw-loop.sh` | `audit_emit` in `run_test_gate()` and verification gap handler |
| `scripts/sw-loop.sh` | Source `audit-trail.sh` in imports |
| `scripts/lib/pipeline-stages.sh` | Source `audit-trail.sh` in imports |

### Fail-Open Principle

All audit calls wrapped in `|| true`. Audit is observability, never a gate. Pipeline continues unaffected if audit logging fails.

## Output Formats

### pipeline-audit.md (Compliance Report)

```markdown
# Pipeline Audit Report — Issue #192

| Field | Value |
|---|---|
| **Pipeline** | standard |
| **Issue** | #192 |
| **Model** | sonnet |
| **Started** | 2026-03-01T14:23:00Z |
| **Duration** | 24m 18s |
| **Outcome** | SUCCESS |
| **PR** | #205 |

## Stage Summary

| Stage | Duration | Verdict | Artifacts |
|---|---|---|---|
| intake | 1m 48s | pass | intake.json |
| plan | 6m 51s | pass | plan.md |
| build | 8m 22s | pass | 4 iterations |

## Build Loop Detail

### Iteration 1
- **Prompt**: 48,231 chars → iteration-1.prompt.txt
- **Response**: 12,440 chars, exit 0
- **Tests**: npm test (exit 0, 18s), bun test (exit 0, 4s)
- **Audit**: pass

## Token Usage

| Stage | Input | Output | Cost |
|---|---|---|---|
| build | 189,000 | 48,000 | $0.82 |
| **Total** | **201,000** | **51,400** | **$0.86** |
```

### pipeline-audit.json (Machine-Readable)

```json
{
  "version": "1.0",
  "pipeline_id": "pipeline-192",
  "issue": 192,
  "outcome": "success",
  "started_at": "2026-03-01T14:23:00Z",
  "duration_s": 1458,
  "stages": [...],
  "tokens": {"input": 201000, "output": 51400, "cost_usd": 0.86},
  "artifacts": ["plan.md", "design.md"]
}
```

All paths relative to `.claude/` for portability.

## Testing Strategy

1. Unit tests in `scripts/sw-lib-audit-trail-test.sh` — emit, save, finalize functions
2. Integration: run build loop with audit enabled, verify JSONL populated
3. Regression: existing tests (70/70 detection, 56/61 loop) still pass
4. E2E: run pipeline, verify `.md` and `.json` reports generated

## Non-Goals

- No external storage (S3, database) — files only
- No real-time streaming of audit events
- No retroactive audit of past pipeline runs
- No audit of non-pipeline (standalone loop) runs initially
