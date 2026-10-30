# Plan notes — issue #1760

## What the issue requires
- `abort_when.op` is not validated at load at all — fails open (safety risk).
- Single-condition `until.op` is not validated at load (only its stage membership is checked).
- `exit_when` multi-condition form IS validated but only against `eq|ne`, not the full 8-op set.
- Evaluators implement only `eq`, `ne`, `in` — three of eight, one misspelled, one not in the ADR.
- ADR-027 §5 is the authority: `eq|neq|gt|gte|lt|lte|contains|matches`.

## Grep scan result
Ran: `grep -rln "op: *ne\b\|op: *in\b\|\"ne\"\|\"in\"" tests/ config/ .zbuild/`

Matches:
- tests/unit/core-output-stage-io-test.sh — "in" is a stage I/O direction, not a loop op
- tests/unit/core-output-stage-io-render-test.sh — same
- tests/unit/core-output-stage-io-split-test.sh — same

No file uses `op: ne` or `op: in` as a loop condition operator. No fixture updates needed.

## Step ordering rationale
- Tests first, then implementation (CLAUDE.md test-first rule).
- Separate R1/R3 tests (load rejection) from R2/R4/R5 tests (evaluator correctness).
- template.sh fix before cycle-orchestrator.sh fix — load-time gate is outermost, evaluator is inner.
- ADR amendment last, after all tests pass.
- No parallel execution with #1726 (shares template.sh).

## Open questions
None — issue is precise and the comment narrows the scope cleanly.
