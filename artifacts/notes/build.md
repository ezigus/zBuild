# Build Notes - Issue #1801

## Final State (iteration 4)

All acceptance tests pass. Two implementation changes were made in this iteration.

## Change 1: runner.sh _ZBUILD_ORCH_BACKEND_DISPOSITION gate (SPEC-4/SPEC-10)

Already implemented in the working tree before this iteration. The check at lines 68-75
of `core/pipeline/runner.sh` checks `_ZBUILD_ORCH_BACKEND_DISPOSITION` immediately after
sourcing `contract.sh` and exits 1 with a message containing both "misconfigured" and the
backend alias.

## Change 2: template-resolver.sh always_run: conditional stripping (SPEC-5)

**Problem**: The OLD-shape merge path unconditionally stripped `always_run:` from the base
template, then appended it from the per-repo file only if declared. This broke inheritance:
when `resume-minimal.yaml` extends `simple` without declaring its own `always_run:`, the
merged file had no `always_run:` at all — the `release` stage was never dispatched.

**Fix** (`core/pipeline/template-resolver.sh`): Before the base awk, detect whether the
per-repo file declares `always_run:`. If yes, strip `always_run:` from base and append
from per-repo (override path — preserves SPEC-5 always-run-spec5p → [release, persist]).
If no, keep the base's `always_run:` intact (inherit path — preserves SPEC-1..5/6 in
runner-release-exit-paths where resume-minimal inherits simple's [release, persist]).

## Test results

- tests/integration/always-run-exit-paths-test.sh: 14/14 pass
- tests/integration/runner-release-exit-paths-test.sh: 27/27 pass
- tests/integration/orch-backend-misconfigured-test.sh: 19/19 pass
- tests/integration/orch-timeout-applies-test.sh: 21/21 pass
- tests/unit/orch-sequential-absent-guard-test.sh: 3/3 pass
- tests/unit/orch-kill-uses-pg-kill-guard-test.sh: 9/9 pass
- tests/unit/lint-adr-enforced-by-test.sh: 24/24 pass
- plugins/tool/orch-mock/tests/orch-mock-test.sh: 8/8 pass
- tests/unit/adr059-no-tmpdir-defaults-test.sh: 8/8 pass (after SPEC-12 stripping)
- tests/unit/core-orch-run-id-isolation-test.sh: 7/7 pass
- tests/unit/dispatch-rc-guard-test.sh: 36/36 pass
- tests/unit/stdin-spawn-guard-test.sh: 7/7 pass
- tests/unit/summary-mandatory-test.sh: 14/14 pass
