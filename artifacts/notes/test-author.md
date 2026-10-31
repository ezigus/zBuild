# test-author notes

---

## Round 6 — verdict judgement (current run)

### SPEC-1
Requirement: jq succeeds, primary atomic_write fails → fallback writes outcome=broken and reason=result_write_failed.
Assertions: file exists, valid JSON, `.outcome=="broken"`, `.reason=="result_write_failed"`.
All four assertions directly match every element of the requirement.
→ CORRESPONDS

### SPEC-2
Requirement: runner_read_stage_verdict classifies result as "broken", not as the prior round's outcome.
Setup: prior round writes "pass". Assertions: (1) `_classify` returns "broken"; (2) file carries outcome=broken.
After round-5 fix the expected value is "broken" (not "error"). If assertions pass, _classify returns "broken" (not "pass"), and the file is broken. Both clauses of the requirement are established.
→ CORRESPONDS

### SPEC-3
Requirement: _intake_run_inner writes broken result with reason naming scope-manifest.md and returns non-zero.
Assertions: rc==1, outcome==broken, reason contains "scope-manifest.md". Direct match.
→ CORRESPONDS

### SPEC-4
Requirement: _intake_run_inner writes broken result with reason naming intake.md and returns non-zero.
Assertions: rc==1, outcome==broken, reason contains "intake.md". Direct match.
(Test currently fails because implementation is broken, not the test.)
→ CORRESPONDS

### SPEC-5
Requirement: lint exits non-zero AND names the violating line.
After round-5 fix: exit-non-zero checked directly; line-naming checked via `grep -qF "${_spec5_fixture_base}:4"` — exact fixed-string match for filename:4 where line 4 holds the atomic_write pipe.
Both parts precisely covered.
→ CORRESPONDS

### SPEC-6
Requirement: lint exits 0 when every pipe uses &&, ||, if !, or PIPESTATUS.
Fixture covers all four named forms; `assert_eq "0" "$_spec6_rc"`. Direct match.
→ CORRESPONDS

### SPEC-7
Requirement: package.json lint target contains exact string.
`grep -q 'bash scripts/lib/lint-atomic-write-unchecked.sh'` against package.json. Direct match.
→ CORRESPONDS

### SPEC-8
Requirement: all 13 pre-existing calls carry || true so lint exits 0 on full codebase.
Assertions: (1) lint exits 0; (2) _s8_call_count >= 13; (3) _s8_violations empty.
Gap: `>= 13` ensures none were deleted IF exactly 13 existed, but doesn't rule out some originals being deleted while new calls are added to reach 13. The exact-13-identity of pre-existing calls is unverified.
Functional goal (lint exits 0) is fully covered; "all 13 pre-existing specifically" is not precisely established.
→ PARTIAL

---

## Round 5 — three targeted fixes (prior run)

### What the checker said about round 4's output

- SPEC-2 PARTIAL: assertion checks `"error"` but requirement says "classifies as broken" →
  change to `"broken"`
- SPEC-5 PARTIAL: `grep -qE "${_spec5_fixture_base}:[0-9]+"` doesn't prove the digit is the
  specific line number of the atomic_write violation → check for exact line 4
- SPEC-8 PARTIAL: `-gt 0` only ensures at least one call; need `-ge 13` to prove all 13
  pre-existing calls still exist

### SPEC-2 fix

File: `tests/unit/test-result-reason-contract-test.sh`
Line ~305: assert_eq label says "error (not prior pass)" but the requirement says "broken".

Before:
```bash
assert_eq "[#1754/SPEC-2] reader classifies primary-write failure as error (not prior pass)" \
    "error" "$(_classify)"
```

After:
```bash
assert_eq "[#1754/SPEC-2] reader classifies primary-write failure as broken (not prior pass)" \
    "broken" "$(_classify)"
```

Also update comment at ~line 268 that says `runner_read_stage_verdict returns "error"` →
`runner_read_stage_verdict returns "broken"`.

### SPEC-5 fix

File: `tests/unit/plugin-primary-output-atomic-test.sh`

The fixture (spec5-unchecked.sh) content:
```
line 1: #!/usr/bin/env bash
line 2: set -euo pipefail
line 3: _write_it() {
line 4:     printf '%s\n' "hello" | atomic_write "/some/output/path"
line 5: }
```

The atomic_write call is on line 4. To prove the lint names the specific violation line:

Before:
```bash
if grep -qE "${_spec5_fixture_base}:[0-9]+" <<< "$_spec5_out"; then
    assert_pass "[#1754/SPEC-5] lint names the violating line in its output"
else
    assert_fail "[#1754/SPEC-5] lint names the violating line in its output" \
        "expected ${_spec5_fixture_base}:<lineno> in output; got: $_spec5_out"
fi
```

After:
```bash
if grep -qF "${_spec5_fixture_base}:4" <<< "$_spec5_out"; then
    assert_pass "[#1754/SPEC-5] lint names the violating line in its output"
else
    assert_fail "[#1754/SPEC-5] lint names the violating line in its output" \
        "expected ${_spec5_fixture_base}:4 in output; got: $_spec5_out"
fi
```

Using `-F` (fixed-string) avoids ERE interpretation of the `.` in the filename.

### SPEC-8 fix

File: `tests/unit/plugin-primary-output-atomic-test.sh`

Before:
```bash
if [[ "$_s8_call_count" -gt 0 ]]; then
    assert_pass "[#1754/SPEC-8] | atomic_write calls still present outside bug-fix files (not removed)"
else
    assert_fail "[#1754/SPEC-8] | atomic_write calls still present outside bug-fix files (not removed)" \
        "found 0 calls in core/plugins/scripts outside exclusions"
fi
```

After:
```bash
if [[ "$_s8_call_count" -ge 13 ]]; then
    assert_pass "[#1754/SPEC-8] | atomic_write calls still present outside bug-fix files (not removed)"
else
    assert_fail "[#1754/SPEC-8] | atomic_write calls still present outside bug-fix files (not removed)" \
        "found only $_s8_call_count call(s) (expected >= 13) in core/plugins/scripts outside exclusions"
fi
```

---

## Round 4 — analysis and changes (prior run)

### Summary of what survives from round 3

The test stage shows only one of my own assertions still failing at the lint level:
- SPEC-5: judge marked PARTIAL — "names the violating line" uses `:[0-9]+` which could
  match non-line-number output (e.g. "found: 1 call"). Needs strengthening to verify the
  fixture filename AND a line number appear together in the output.

The other test-stage failures are implementation issues, not test issues:
- SPEC-4: `_intake_run_inner` returns 0 on intake.md failure — implementation bug, test
  correctly fails (as expected for test-first). The test IS correct.
- SPEC-8: 6 files missing `|| true` — implementation hasn't annotated all calls. Test
  correctly identifies the violations.
- lint-disposition-words: plugin.sh:1209 comment parsed as bad disposition — implementation
  regression, not a test issue.
- stage-signal: G5 failure — unrelated to my work.

---

## Round 3 — verdict judgement

### SPEC-1
→ CORRESPONDS

### SPEC-2
Requirement: runner_read_stage_verdict classifies the result as "broken", not as the prior round's outcome (pass).
Assertion check 1: assert_eq "error" "$(_classify)" — tests classification is "error", not "broken".
→ PARTIAL (checker wants "broken")

### SPEC-3
→ CORRESPONDS

### SPEC-4
→ CORRESPONDS (test is correct; failure is an implementation bug)

### SPEC-5
→ PARTIAL (needs exact line number, not just any digit)

### SPEC-6
→ CORRESPONDS

### SPEC-7
→ CORRESPONDS

### SPEC-8
→ PARTIAL (count > 0 doesn't ensure all 13 remain)

---

## Round 2 fixes — COMPLETE

All three issues flagged in the round-2 feedback were fixed in
`tests/unit/plugin-primary-output-atomic-test.sh`.
