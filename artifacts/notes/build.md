# Build notes for #1951 (iteration 2)

## Current state (iteration 2)

All data changes were applied in the previous build (commit 20a236d3):
1. config/event-schema.json: persist.* (6) and hydrate.* (5) entries removed
2. plugins/agent/security-lens/manifest.yaml: plugin.result removed
3. plugins/tool/merge/manifest.yaml: plugin.result removed (no events section)
4. docs/adr/ADR-001-plugin-contract.md: ## Enforced by section added
5. config/adr-enforcement-baseline.txt: ADR-001-plugin-contract.md removed

The second test-author (commit 280b8651) fixed the SPEC-1/SPEC-2 test logic:
- SPEC-1: uses all-but-last namespace (plugin.pr_open.X → plugin.pr_open, not plugin)
- SPEC-2: has pr-open exception for plugin.<name>.* events

## VERIFIED (iteration 2): all SPECs pass

Ran tests/unit/event-schema-emitted-coverage-test.sh → All 14 tests passed
- SPEC-1 ✓ (all-but-last namespace: plugin.pr_open not in engine ns check)
- SPEC-2 ✓ (pr-open exception correctly applied)
- SPEC-3 ✓ (persist/hydrate absent from event-schema.json)
- SPEC-4 ✓ (plugin.result absent from both manifests)

Ran tests/unit/lint-adr-enforced-by-test.sh → All 27 tests passed
- SPEC-5 ✓

## BLOCKED: pre-existing tests out of scope

Two pre-existing tests now FAIL because they assert plugin.result IS present
(the old state), but SPEC-4 correctly removed it:

1. plugins/agent/security-lens/tests/security-lens-test.sh [SPEC-16]
   - Asserts "manifest provides.events contains plugin.result"
   - NOT in plan.files[] - out of scope

2. tests/unit/merge-v2-result-test.sh [SPEC-1]
   - Asserts "manifest provides.events includes plugin.result"
   - NOT in plan.files[] - out of scope

These need scope expansion to fix. Cannot change without going out of scope.

## Findings from previous test run (iteration 1)

Finding 1: security-lens-test.sh [SPEC-16] → BLOCKED (out of scope)
Finding 2: coverage-test SPEC-1 → NOT REPRODUCED (new test code 280b8651 fixes it)
Finding 3: merge-v2-result-test.sh [SPEC-1] → BLOCKED (out of scope)
Finding 4-5: golden files → unaffected (persist/hydrate events still known via manifests)
Findings 6-12: shape-floor alerts → not actual failures, no updates needed
Finding 13: SPEC-1/SPEC-2 don't pass → NOT REPRODUCED (new test code 280b8651 fixes it)
