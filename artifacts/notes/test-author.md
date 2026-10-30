# test-author notes — issue #1760 (round 7 — COMPLETE)

## Issue-acceptance finding (round 6 → round 7)

The check of assertions found SPEC-3 was incomplete:
- The test checked rc=1, the loop name, and the bad op — but NOT the field or the valid set.
- SPEC-3 requires the error to name: loop, **field**, bad op, and valid set (same as SPEC-1/SPEC-2).
- Fix: added `assert_contains ... "verdict"` (field) and an 8-op loop check (valid set) to SPEC-3.

## Summary of all SPECs

All 9 SPECs have assertions in the named testfiles.

| SPEC   | File                                             | Status     |
|--------|--------------------------------------------------|------------|
| SPEC-1 | template-loader-recursive-flow-test.sh           | ✓ Fixed round 5: valid-set check loops all 8 ops with word-boundary pattern |
| SPEC-2 | template-loader-recursive-flow-test.sh           | ✓ Fixed round 6: added field assertion + 8-op valid-set loop |
| SPEC-3 | template-loader-recursive-flow-test.sh           | ✓ Fixed round 7: added field assertion + 8-op valid-set loop |
| SPEC-4 | cycle-abort-when-no-match-converges-test.sh      | ✓ Complete (all 8 ops, 2 cases each, set +e protected) |
| SPEC-5 | cycle-abort-when-no-match-converges-test.sh      | ✓ Complete (8 _cycle_load_template calls protected with _sp5_mc_rc) |
| SPEC-6 | cycle-orchestrator-abort-when-test.sh            | ✓ Complete |
| SPEC-7 | core-pipeline-cycle-events-test.sh               | ✓ Complete (protected) |
| SPEC-8 | core-pipeline-cycle-events-test.sh               | ✓ Complete (protected) |
| SPEC-9 | template-loader-recursive-flow-test.sh           | ✓ Complete (no-code SPEC) |

## Round 7 change detail

### tests/unit/template-loader-recursive-flow-test.sh — SPEC-3 field + valid-set assertions

**Problem (rounds 1–6):** The SPEC-3 block only asserted rc=1, loop name, and bad op:
  assert_eq "[#1760/SPEC-3] multi-condition bad op refused (rc!=0)" "1" "$bad_multi_rc"
  assert_contains "[#1760/SPEC-3] error names the loop" "$bad_multi_err" "the_cycle"
  assert_contains "[#1760/SPEC-3] error names the bad op" "$bad_multi_err" "ne"
The field ("verdict") and valid set (8 ops) were not asserted, so an implementation
that omitted them from the error would pass this test.

**Fix (round 7):** Added between the loop-name and bad-op checks:
  assert_contains "[#1760/SPEC-3] error names the field" "$bad_multi_err" "verdict"
And after the bad-op check, the 8-op word-boundary loop:
  for _spec3_valid_op in eq neq gt gte lt lte contains matches; do
      grep -qE "(^|[^[:alnum:]_])${_spec3_valid_op}([^[:alnum:]_]|$)" <<< "$bad_multi_err"
  done

**Why the field check FAILS before #1760:** No multi-condition op validation exists
before the change, so no error is emitted. `bad_multi_err` is empty (or contains
a load success message), so "verdict" is not found and assert_fail fires.

**Why the field check passes after #1760:** The multi-condition op validation error
must include the field name per the SPEC-3 requirement, so `bad_multi_err` will
contain "verdict" and enumerate all 8 valid ops.

**Word-boundary rationale:** Same as SPEC-1/SPEC-2: 'eq' inside 'neq', 'gt' inside
'gte', 'lt' inside 'lte', and 'contains' inside a compound op name do not satisfy
the per-op grep-qE checks. Only genuinely standalone op tokens pass.

## Round 6 change detail (kept for reference)

### tests/unit/template-loader-recursive-flow-test.sh — SPEC-2 field + valid-set assertions

**Problem (round 5):** The SPEC-2 block only asserted rc=1, loop name, and bad op.
The field ("verdict") and valid set (8 ops) were not asserted.

**Fix (round 6):** Added `assert_contains "[#1760/SPEC-2] error names the field"`
and the 8-op word-boundary valid-set loop for SPEC-2.

## Round 5 change detail (kept for reference)

### tests/unit/template-loader-recursive-flow-test.sh — SPEC-1 valid-set check

**Problem (rounds 2–4):** The valid-set check used a single grep for a subset of
ops, not verifying the complete set of 8 was enumerated.

**Fix (round 5):** Per-op loop with word-boundary pattern for all 8 ops:
  for _spec1_valid_op in eq neq gt gte lt lte contains matches; do
      grep -qE "(^|[^[:alnum:]_])${_spec1_valid_op}([^[:alnum:]_]|$)" <<< "$bad_aw_err"
  done

## Out of scope finding

tests/unit/core-pipeline-cycle-convergence-test.sh uses `op: ne` (old name)
and expects rc=0 (convergence). After #1760 rejects `ne`, that test fails.
This file is NOT in my named testfile scope — cannot be modified.
The implementation must either keep `ne` as a backward-compat alias for `neq`,
or this file's scope must be expanded in a follow-up change.
