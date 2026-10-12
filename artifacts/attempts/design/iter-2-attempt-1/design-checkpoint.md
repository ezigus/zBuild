# Design Checkpoint — Issue #1801 (iteration 2)

## Files read
- design.md (prior design - complete, has the 4 gaps below)
- config/templates/simple.yaml (full - confirms router.timeout_s on release/persist; no stage_timeout_s anywhere yet)
- runner.sh grep (cycle_orchestrator_run line 3236, parallel_group_run line 3363, always_run 2398)
- cycle-orchestrator.sh / parallel-orchestrator.sh (route through runner hooks, not direct plugin_hook_call)
- router.timeout_s grep in tests/ (17 files; key new one: router-timeout-precedence-e2e-test.sh)

## Gaps being fixed in design.md

### Gap 1: R-11 not covered
Add SPEC-15[no-code]: grep for orch-sequential/ZBUILD_ORCH_TIMEOUT/router.timeout_s/always_run watchdog documented and all matching test files in scope covers: R-11

### Gap 2: R-13 not covered
Add SPEC-16[no-code]: npm test + npm run lint pass covers: R-13

### Gap 3: SPEC-1 omits cycle member, parallel-group member, always_run
Update SPEC-1 to list ALL dispatch routes explicitly (was: map, fanout, sequential strategy, roleless leaf)

### Gap 4: No multi-backend SPEC (R-1)
Add SPEC-17[code]: timeout kill confirmed under orch-mock; ruflo-hive unaffected (lifecycle.sh is backend-agnostic) covers: R-1

### Gap 5: SPEC-6 covers only release/persist (R-6)
Expand SPEC-6 to list all simple.yaml stage_timeout_s values:
test=5400s, build=4200s, design=3900s, plan=1200s, test-author=900s,
spec-coverage/acceptance-gate/issue-acceptance/spec-correspondence/review_lenses=600s,
intake/pr/hydrate/secret-scan/shape-floor/design-gate/gate-aggregator/assertion-integrity/review-aggregator=600s

## Scope additions
- tests/integration/router-timeout-precedence-e2e-test.sh (R-11: matches router.timeout_s grep in tests/)

## Writing design.md now
