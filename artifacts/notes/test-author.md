# test-author notes — issue #1760 (round 5 — COMPLETE)

## Summary of all SPECs

All 9 SPECs have assertions in the named testfiles.

| SPEC   | File                                             | Status     |
|--------|--------------------------------------------------|------------|
| SPEC-1 | template-loader-recursive-flow-test.sh           | ✓ Fixed round 5: valid-set check loops all 8 ops with word-boundary pattern |
| SPEC-2 | template-loader-recursive-flow-test.sh           | ✓ Complete |
| SPEC-3 | template-loader-recursive-flow-test.sh           | ✓ Complete |
| SPEC-4 | cycle-abort-when-no-match-converges-test.sh      | ✓ Complete (all 8 ops, 2 cases each, set +e protected) |
| SPEC-5 | cycle-abort-when-no-match-converges-test.sh      | ✓ Complete (8 _cycle_load_template calls protected with _sp5_mc_rc) |
| SPEC-6 | cycle-orchestrator-abort-when-test.sh            | ✓ Complete |
| SPEC-7 | core-pipeline-cycle-events-test.sh               | ✓ Complete (protected) |
| SPEC-8 | core-pipeline-cycle-events-test.sh               | ✓ Complete (protected) |
| SPEC-9 | template-loader-recursive-flow-test.sh           | ✓ Complete (no-code SPEC) |

## Round 5 change detail

### tests/unit/template-loader-recursive-flow-test.sh — SPEC-1 valid-set check

**Problem (rounds 2–4):** The valid-set check used:
  grep -qE 'neq|gte|lte|matches' <<< "$bad_aw_err"
This only confirmed that at least ONE member distinct from `contains_all` appeared
anywhere in the error string. It did not verify the COMPLETE set of 8 ops was
enumerated. A message naming only `neq` would pass, which is weaker than required.

**Fix (round 5):** Replace with a per-op loop covering all 8 ops:
  for _spec1_valid_op in eq neq gt gte lt lte contains matches; do
      grep -qE "(^|[^[:alnum:]_])${_spec1_valid_op}([^[:alnum:]_]|$)" <<< "$bad_aw_err"
  done
Each op is checked as a standalone token using word-boundary pattern
`(^|[^[:alnum:]_])op([^[:alnum:]_]|$)` so:
- 'eq' inside 'neq' does NOT match (preceded by 'n', which is alnum)
- 'gt' inside 'gte' does NOT match (followed by 'e', which is alnum)
- 'lt' inside 'lte' does NOT match (followed by 'e', which is alnum)
- 'contains' inside 'contains_all' does NOT match (followed by '_', excluded by [^[:alnum:]_])

**Why this test FAILS before #1760:** Before the change, no valid-set enumeration
appears in the error (validation of abort_when.op doesn't exist yet), so none of
the 8 per-op grep checks find a standalone token match. All 8 assert_fail calls
fire. After #1760, the error names all 8 ops; all pass.

## Out of scope finding

tests/unit/core-pipeline-cycle-convergence-test.sh uses `op: ne` (old name)
and expects rc=0 (convergence). After #1760 rejects `ne`, that test fails.
This file is NOT in my named testfile scope — cannot be modified.
The implementation must either keep `ne` as a backward-compat alias for `neq`,
or this file's scope must be expanded in a follow-up change.
