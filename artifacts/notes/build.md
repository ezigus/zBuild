# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: COMPLETE (iteration 5 — fixed review_lenses findings)

## Changes made across all iterations

1. **ADR-006 step 3.6** — Added ordering constraint phrase on a single line.
2. **cycle-orchestrator.sh** — Fixed `_start_iter` calculation for resume vs. fresh runs.
3. **runner.sh, artifact-persist.sh, hydrate/plugin.sh, ADR-050** — Full resume rehydration implementation.
4. **runner.sh (finding 1)** — Added explicit `issue` parameter to `_runner_from_stage_preflight`; updated call site to pass `$_runner_issue` explicitly.
5. **runner.sh (finding 2)** — Added `=~ ^[0-9]+$` integer validation for `_sf_issue` read from ZBUILD_STATE_FILE.
6. **artifact-persist.sh (finding 3)** — Added `[[ "$rel" == /* ]] && continue` guard against absolute path escape from strip failure.

## Acceptance test results (verified iteration 5 — post-fix)

| Test file | Status |
|-----------|--------|
| resume-rehydrate-test.sh | ✓ 45/45 pass |
| from-stage-rehydrate-test.sh | ✓ 12/12 pass |
| resume-loop-state-test.sh | ✓ 6/6 pass |
| resume-entry-points-test.sh | ✓ 14/14 pass |
| hydrate-stage-test.sh | ✓ 25/25 pass |

## review_lenses findings — resolved

### Finding 1 (medium) — runner.sh
`_runner_from_stage_preflight` now takes `issue` as explicit `$1`; call site passes `$_runner_issue`.

### Finding 2 (medium) — runner.sh
`_sf_issue` validated with `=~ ^[0-9]+$` before assignment; non-integer values (including "null") silently rejected.

### Finding 3 (low) — artifact-persist.sh
`_artifact_persist_put_back` now skips any file where `rel` is an absolute path (strip failed due to trailing slash on `$from`).

## Pre-existing failures (NOT regressions from issue-1805)

- `tests/unit/stage-retry-test.sh`: 15 of 24 fail — pre-existing from issue #2439
  - Sources: helpers.sh, test-helpers.sh, registry.sh, template.sh, verdict.sh, strategies/common.sh
  - Does NOT source any file in issue-1805's scope
- `tests/integration/write-boundary-revert-test.sh`: D7 (2 tests) — pre-existing
