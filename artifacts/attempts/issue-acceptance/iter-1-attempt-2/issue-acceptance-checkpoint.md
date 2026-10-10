# Acceptance checkpoint — issue #1668 (current round)

## Current state
- TEST VERDICT: **pass** (844 passed, 0 failed) — prior round failures resolved
- Diff: all scope files updated (simple.yaml, deployed.yaml, ADR-068, test files, impact-max-turns-test.sh, template-always-run-test.sh)

## Prior round's issues resolved in this diff
- impact-max-turns-test.sh: now uses inline fixture (SPEC-8) — no longer loads simple.yaml
- template-always-run-test.sh: count updated from 20 to 19 (SPEC-9)

## Requirement-by-requirement

### R-1: Test asserting impact absent from BOTH templates, written first, reds on main, state red step in PR body
- template-simple-yaml-test.sh SPEC-18: asserts "design_verify_cycle,build_test_cycle" — would fail on main ✓
- deployed-template-e2e-test.sh SPEC-7: new assertion, comment says "fails on main (three members)" ✓
- test-author ran before build stage — consistent with test-first ordering
- "state the red step in the PR body": PR body NOT in diff — CANNOT VERIFY → UNSURE

### R-2: plugins/agent/impact/ untouched, unit tests pass
- No changes to plugins/agent/impact/ in diff ✓
- Test verdict: 844 pass, 0 fail ✓ → MET

### R-3: template-simple-yaml-test.sh and core-pipeline-cycle-build-test-wiring-test.sh reflect new roster
- Both files updated, count=19, indices shifted, acceptance-gate PASS ✓ → MET

### R-4: ADR-068 §1/§8 amended, npm run lint green
- §1: "design loop → build loop" ✓; §8: impact removed ✓; Enforced by updated ✓
- Test suite (including lint) passes ✓ → MET

### R-5: Dogfood run completes with no impact stage
- Stage summaries show impact RAN in this pipeline run (verdict: warn)
- This run used old templates; post-merge run would be needed — NOT VERIFIABLE → UNSURE

## Verdict: unsure on R-1 (PR body) and R-5 (post-merge dogfood)
