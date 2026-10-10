# Build checkpoint — issue #1668 — ITERATION 2 ANALYSIS

All in-scope changes were made in iteration 1. Two new failing tests surfaced in the test run that
are out of scope.

## Changes made (iteration 1, already committed)

1. **simple.yaml**: Removed `- impact` from delivery_loop.flow; removed impact stage section.
2. **deployed.yaml**: Same.
3. **run-status-comment-mock-roster.sh**: Removed `_make_impact_plugin()` + `_make_plugin "impact"` call.
4. **cycle-gate-unavailable-aborts-run-test.sh**: Same removals.
5. **cycle-rate-limit-aborts-run-test.sh**: Same removals.
6. **cycle-acceptance-terminal-failure-test.sh**: Same removals.
7. **cycle-on-max-pipeline-continues-test.sh**: Removed `_make_plugin "impact"` call; updated comment.
8. **ADR-068**: Updated §1/§8; added "Amended 2026-10-10"; updated Enforced by §1.

## Out-of-scope failures in iteration 2

### tests/unit/impact-max-turns-test.sh (3 failures)
- Loads simple.yaml and reads `_TPL_STAGE_ROUTER_MAX_TURNS_impact` and `_TPL_STAGE_ROUTER_TIMEOUT_impact`
- These vars are empty because impact's stage section was removed from simple.yaml
- Comment in test: "#979: standard.yaml retired; simple.yaml's impact stage carries the same router.max_turns:45"
- This test is NOT in scope — it needs to be updated to use a fixture or different template
- BLOCKED: requires tests/unit/impact-max-turns-test.sh (out of scope)

### tests/unit/template-always-run-test.sh (1 failure)
- Asserts `${#_TPL_STAGES[@]}` == 20 but count is now 19 (impact removed)
- Test is NOT in scope — the count assertion needs updating from 20 → 19
- BLOCKED: requires tests/unit/template-always-run-test.sh (out of scope)

### tests/golden/full-pipeline/event-sequence.golden and parity/event-sequence.golden
- Shape-floor flagged these as potentially needing updates
- Ran impact-prefilter-test.sh (uses both goldens): ALL 18 tests PASS
- Grep found no "impact" in either golden file — they are correct as-is
- NOTHING TO DO: golden files are still correct

## What needs to happen next (if scope is expanded)
1. Update tests/unit/impact-max-turns-test.sh to load a template that still has impact (or read the plugin config directly)
2. Update tests/unit/template-always-run-test.sh SPEC-2 count from 20 to 19

---
# Build checkpoint — issue #1668 — ITERATION 2 (continued)

## Summary of iteration 2 analysis

All acceptance tests (SPEC-1, SPEC-2, SPEC-3, SPEC-7) PASS on the current tree:
- tests/unit/template-simple-yaml-test.sh: 105/105 pass
- tests/integration/core-pipeline-cycle-build-test-wiring-test.sh: 30/30 pass

## Failing tests — both out of scope

### tests/unit/impact-max-turns-test.sh
- Loads simple.yaml and reads `_TPL_STAGE_ROUTER_MAX_TURNS_impact`
- Impact's stage section was removed from simple.yaml → variable empty → 3 failures
- File NOT in scope — cannot edit
- Cannot restore impact's stage config to simple.yaml without it appearing in a flow (template.sh only
  populates `_TPL_STAGE_ROUTER_MAX_TURNS_*` for stages that appear in a flow)

### tests/unit/template-always-run-test.sh
- Asserts `${#_TPL_STAGES[@]}` == 20 (stale; was correct before impact removed)
- Current count is 19 (correct per SPEC-2 acceptance test)
- File NOT in scope — cannot edit
- Direct conflict: acceptance SPEC-2 requires 19; this test requires 20 — cannot satisfy both

## Golden files — no action needed
- tests/golden/full-pipeline/event-sequence.golden: 0 "impact" occurrences — correct
- tests/golden/parity/event-sequence.golden: 0 "impact" occurrences — correct
- Tests using these goldens all pass

## BLOCKED
- BLOCKED: test gate requires tests/unit/impact-max-turns-test.sh (out of scope)
- BLOCKED: test gate requires tests/unit/template-always-run-test.sh (out of scope)
