# Issue #1760 Build Notes

## Status: DONE (iteration 3)

## Issue-acceptance finding fixed (iteration 3)
The `until.op` validation error omitted the field name. R-1 requires naming the field.
- Fix 1: Read `_TPL_CYCLE_UNTIL_FIELD_${safe}` into `$uf`; changed error to include `"for field '$uf'"`
- Fix 2: Multi-condition `exit_when` error at line 1212 also omitted the field (`$ew_f`); changed to include `"(field '$ew_f')"`

Test results (iteration 3):
- tests/unit/template-loader-recursive-flow-test.sh: 60/60 passed (up from 42)
- All other acceptance tests: unchanged/passing

## Root cause of test finding 1 (iteration 1)
`tests/unit/core-pipeline-cycle-convergence-test.sh` tests `_cycle_check_until`
directly with `_CYCLE_UNTIL_OP="ne"` (bypassing load-time validation) and
expects rc=0. The previous iteration removed `ne` from the runtime evaluators,
causing the `*)` branch to fire and return rc=1.

The file is out of scope and cannot be edited. The fix is to keep `ne` as a
backward-compat alias for `neq` in all three runtime evaluators. Load-time
validation still refuses `ne` (satisfying SPEC-1/2/3); the `*)` branch still
fires on truly unrecognized ops (satisfying SPEC-8, which uses `bogus_op`).

## Changes made (iteration 2)

### core/pipeline/cycle-orchestrator.sh
- Added `ne|neq)` (was just `neq)`) in all three evaluators:
  - `_cycle_eval_one_condition` (line 478)
  - `_cycle_check_until` (line 564)
  - `_cycle_check_abort_when` (line 808)
- Updated header comment line 276 from `(eq|ne)` to the full eight-op set

## Changes made (iteration 1)

### 1. core/pipeline/cycle-orchestrator.sh
Three evaluator case statements updated:
- `_cycle_eval_one_condition`: eq/neq/gt/gte/lt/lte/contains/matches + numeric guards + *) branch
- `_cycle_check_until` single-condition path: same
- `_cycle_check_abort_when`: same

Removed: ne, in (old spellings — load-time now refuses both)
Added: neq, gt, gte, lt, lte, contains, matches, *) branch

### 2. docs/adr/ADR-027-recursive-flow-template-format.md
Added `## Enforced by` section at end naming all 4 test files.

### 3. config/adr-enforcement-baseline.txt
Removed ADR-027-recursive-flow-template-format.md line.

### 4. core/pipeline/template.sh
Added abort_when.op validation; added single-condition until.op validation;
widened multi-condition exit_when from eq|ne|in to the eight-op set.

## Test results (iteration 2)
- tests/unit/core-pipeline-cycle-convergence-test.sh: 11/11 passed (was failing)
- tests/unit/template-loader-recursive-flow-test.sh: 42/42 passed (SPEC-1,2,3,9)
- tests/integration/cycle-abort-when-no-match-converges-test.sh: 46/46 passed (SPEC-4,5)
- tests/integration/cycle-orchestrator-abort-when-test.sh: 23/23 passed (SPEC-6)
- tests/unit/core-pipeline-cycle-events-test.sh: 41/41 passed (SPEC-7,8)

## Shape-floor findings (1-9)
All 9 listed files are out of scope. All tests in those files pass in the full
test run. Per shape-floor logic: "A file that is still correct can stay as it is:
the full test run on this change shows that." No changes needed.

## Acceptance-gate findings (SPEC-5 and SPEC-8)
The pipeline flagged that SPEC-5 and SPEC-8 tests didn't run on old code (because
an earlier SPEC-4/SPEC-7 failure stopped the file). This is a test-ordering
artifact in the test-author phase that I cannot change (test files are read-only).
The implementation is correct: SPEC-5 and SPEC-8 pass with the current code.
