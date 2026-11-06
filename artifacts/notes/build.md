# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 8 — CMBR-1 implementation)

## Changes made across all iterations

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.
4. **runner.sh (finding 1)** — Added explicit `issue` parameter to `_runner_from_stage_preflight`; updated call site to pass `$_runner_issue` explicitly.
5. **runner.sh (finding 2)** — Added `=~ ^[0-9]+$` integer validation for `_sf_issue` read from ZBUILD_STATE_FILE.
6. **artifact-persist.sh (finding 3)** — Added `[[ "$rel" == /* ]] && continue` guard against absolute path escape from strip failure.
7. **runner.sh (ENTR-2)** — Added auto-resume via latest symlink (per-run layout discovery).
8. **runner.sh (sre-code-4)** — Added `readlink -f` failure guard: capture result into `_lr_resolved_dir`; if empty, warn and fall back to `resume_mode=false`.
9. **cycle-orchestrator.sh (CMBR-1 iteration 8)** — Added `_resume_first_iter` parameter to `_cycle_iter_dispatch`; call site passes `true` only for `iter == _start_iter && _start_iter > 1`; skip guard checks `stage_statuses[$s]` and continues if "complete".

## Acceptance test results (iteration 8 — all passing)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 45/45 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 8/8 pass (was 6/8, CMBR-1 now passes) |
| resume-entry-points-test.sh | ✓ 18/18 pass |
| hydrate-stage-test.sh | ✓ 25/25 pass |
| cycle-member-dispatch-events-test.sh | ✓ 24/24 pass |
| cycle-inner-iter-resets-per-outer-iter-test.sh | ✓ 15/15 pass |

## Finding answers

**test finding 1** (CMBR-1): done — implemented skip-on-complete guard in `_cycle_iter_dispatch` for the first resumed iteration (ADR-006 §3.6 / #1805 CMBR-1). resume-loop-state-test.sh now 8/8.

**test finding 2** (FRSH-2 cycled_starts): nothing to do — not reproduced: tests/integration/resume-rehydrate-test.sh. The failing assertion (`_frsh2_cycled_starts==1`) is NOT present in the actual worktree file. It was removed by the test-author in a previous iteration. The previous test run's output was from a snapshot of an older worktree. FRSH-2 passes (45/45).

**acceptance-gate finding 1** (CMBR-1): done — CMBR-1 test now passes (8/8 in resume-loop-state-test.sh).

**shape-floor finding 1** (full-pipeline/event-sequence.golden): nothing to do — the full-pipeline golden file does not use cycle templates; parity-local-vs-ci-test and scope-governance tests used these files and both passed in the previous run (880 passed). CMBR-1 only affects resume paths (suppresses stage.start for complete cycle members in the first resumed iteration), not fresh runs or linear pipelines. File is still correct.

**shape-floor finding 2** (parity/event-sequence.golden): nothing to do — same reasoning as shape-floor finding 1. The parity fixture uses a linear pipeline (intake -> design -> build -> test -> pr), no cycles. File is still correct.

**Previous iteration review_lenses findings** — all answered "nothing to do" in prior iterations; design decisions Finding 20/22 are authoritative on the _cd_iter > 0 guard question.

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: pre-existing from issue #2439
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing
