# Test Author Checkpoint — Issue #1801

## Status: COMPLETE — all SPECs written

## All new test files written
1. tests/unit/stage-timeout-dispatch-test.sh — SPEC-1, SPEC-10, SPEC-17
2. tests/unit/stage-timeout-always-run-test.sh — SPEC-6, SPEC-10 (all 21 stages listed in spec)
3. tests/unit/orch-sequential-retired-guard-test.sh — SPEC-8, SPEC-11 (guard excludes itself from grep)
4. tests/unit/orch-backend-misconfigured-test.sh — SPEC-9
5. tests/unit/stage-timeout-no-flat-limit-test.sh — SPEC-7
6. tests/unit/stage-timeout-precedence-test.sh — SPEC-3
7. tests/unit/stage-timeout-loader-validation-test.sh — SPEC-4
8. tests/unit/stage-timeout-retry-test.sh — SPEC-5
9. tests/unit/stage-timeout-process-group-test.sh — SPEC-2

## All existing checks updated
- template-always-run-test.sh: line 44 now checks _TPL_STAGE_TIMEOUT_S_release = "30" ✅
- runner-release-exit-paths-test.sh: SPEC-5 pin changed to ZBUILD_STAGE_TIMEOUT_S ✅
- runner-release-exit-paths-test.sh: SPEC-6 comment updated to say stage_timeout_s ✅
- exit-path-teardown-budget-guard-test.sh: checks ZBUILD_STAGE_TIMEOUT_S ✅
- plugin-artifact-goldens-test.sh: G5 section removed ✅
- dispatch-rc-guard-test.sh: orch-sequential → orch-mock ✅
- adr059-no-tmpdir-defaults-test.sh: orch-sequential → orch-mock ✅
- stdin-spawn-guard-test.sh: two orch-sequential → orch-mock ✅
- core-orch-run-id-isolation-test.sh: sources orch-mock instead of orch-sequential ✅
- summary-mandatory-test.sh: orch-sequential removed from SPEC-3 loop ✅

## SPEC-15/SPEC-16: empty testfile entries, no assertions needed

## Key corrections made in iteration 2
- stage-timeout-always-run-test.sh: added 10 missing stages (issue-acceptance,
  spec-correspondence, review_lenses, pr, secret-scan, shape-floor, design-gate,
  gate-aggregator, assertion-integrity, review-aggregator — all at 600s)
- orch-sequential-retired-guard-test.sh: excluded the guard test itself from the
  grep scan (otherwise it finds its own orch-sequential references)
