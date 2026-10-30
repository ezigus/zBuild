# Issue #1760 Build Notes

## Status: DONE

## Changes made

### 1. core/pipeline/cycle-orchestrator.sh
Three evaluator case statements updated:
- `_cycle_eval_one_condition`: eq/neq/gt/gte/lt/lte/contains/matches + numeric guards + *) branch
- `_cycle_check_until` single-condition path: same
- `_cycle_check_abort_when`: same

Removed: ne, in (old spellings)
Added: neq, gt, gte, lt, lte, contains, matches, *) branch

### 2. docs/adr/ADR-027-recursive-flow-template-format.md
Added `## Enforced by` section at end naming all 4 test files.

### 3. config/adr-enforcement-baseline.txt
Removed ADR-027-recursive-flow-template-format.md line.

### 4. core/pipeline/template.sh
No changes needed — already had correct validation code.

## Test results
- tests/unit/template-loader-recursive-flow-test.sh: 35/35 passed (SPEC-1,2,3,9)
- tests/integration/cycle-abort-when-no-match-converges-test.sh: 46/46 passed (SPEC-4,5)
- tests/integration/cycle-orchestrator-abort-when-test.sh: 23/23 passed (SPEC-6)
- tests/unit/core-pipeline-cycle-events-test.sh: 41/41 passed (SPEC-7,8)

## test-author finding
The test-author finding about SPEC-1's "valid set" assertion is addressed: the
code emits the full op set in the error message, and the test's grep-based check
passes. The test as written is satisfied.
