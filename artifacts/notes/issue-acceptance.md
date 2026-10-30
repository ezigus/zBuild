# Issue #1760 acceptance notes

## What I read
- template.sh lines 1210-1262: SPEC-1/2/3 load-time validation
- cycle-orchestrator.sh lines 474-499 (_cycle_eval_one_condition), 560-589 (_cycle_check_until), 804-830 (_cycle_check_abort_when): SPEC-4/5/6/7/8
- ADR-027 lines 447-462: SPEC-9 Enforced by section
- baseline.txt: ADR-027 absent (confirmed by grep returning nothing)

## SPEC-by-SPEC findings

SPEC-1 (abort_when.op load validation): template.sh 1252-1262 validates aw_op against 8-op case; error message includes cid (loop), aw_field, aw_op, valid set. Test SPEC-1 checks rc!=0, "the_cycle", "verdict", "contains_all", all 8 ops as standalone tokens. MET.

SPEC-2 (single until.op load validation): template.sh 1239-1249 validates uo against 8-op case; error message includes cid, uf, uo, valid set. Test SPEC-2 uses op: in and verifies refusal. MET.

SPEC-3 (multi exit_when op updated): template.sh 1210-1213 now uses eq|neq|gt|gte|lt|lte|contains|matches (was eq|ne|in). Test SPEC-3 uses op: ne which is now refused. MET.

SPEC-4 (8 ops in _cycle_check_until): all 8 ops implemented at lines 562-583. ne|neq handled. Tests verify each op in cycle-abort-when-no-match-converges-test.sh. MET.

SPEC-5 (8 ops in _cycle_eval_one_condition): all 8 ops implemented at lines 476-497. Tests via multi-condition mode in same test file. MET.

SPEC-6 (8 ops in _cycle_check_abort_when): lines 808-829, same pattern. Tests in cycle-orchestrator-abort-when-test.sh SPEC-6. MET.

SPEC-7 (non-numeric operand error): all three evaluators have ^-?[0-9]+$ check before gt/gte/lt/lte; return 1 + error. Tests in core-pipeline-cycle-events-test.sh SPEC-7. MET.

SPEC-8 (*) branch returns 1): all three evaluators have *) branch at lines 493, 579, 823 returning 1. Tests in core-pipeline-cycle-events-test.sh SPEC-8. MET.

SPEC-9 (ADR-027 Enforced by section): section present at ADR-027 line 447, names all 4 test files. ADR-027 absent from baseline.txt (grep confirms). Tests in template-loader-recursive-flow-test.sh SPEC-9. MET.

## Test verdict
831 assertions, 0 failures. Pass.

## Conclusion
All 9 SPECs met. VERDICT: pass.
