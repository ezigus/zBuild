# test-author notes

---

## Round 3 — verdict judgement (current run)

### SPEC-1
Requirement: jq succeeds, primary atomic_write fails → fallback writes outcome=broken, reason=result_write_failed.
Assertion: overrides atomic_write to fail on call 1, calls _test_write_result, restores. Checks file exists, valid JSON, .outcome=="broken", .reason=="result_write_failed". All four tagged checks directly match the requirement.
→ CORRESPONDS

### SPEC-2
Requirement: runner_read_stage_verdict classifies the result as "broken", not as the prior round's outcome (pass).
Assertion check 1: assert_eq "error" "$(_classify)" — tests classification is "error", not "broken".
Assertion check 2: assert_eq "broken" "$(jq -r '.outcome')" — confirms file carries outcome=broken.
The requirement says "classifies ... as broken"; assertion checks _classify returns "error". The file-content check confirms it's not "pass". But the vocabulary tested ("error") differs from the requirement ("broken").
→ PARTIAL

### SPEC-3
Requirement: _intake_run_inner writes broken result with reason naming scope-manifest.md and returns non-zero.
Assertion: fails atomic_write on *scope-manifest.md*, checks rc==1, outcome==broken, reason contains "scope-manifest.md". Direct match.
→ CORRESPONDS

### SPEC-4
Requirement: _intake_run_inner writes broken result with reason naming intake.md and returns non-zero.
Assertion: fails atomic_write on *intake.md* (excluding *intake-result*), checks rc==1, outcome==broken, reason contains "intake.md". Direct match.
→ CORRESPONDS

### SPEC-5
Requirement: lint exits non-zero AND names the violating line.
Exit-non-zero: direct assert_pass/assert_fail based on rc. ✓
"Names the violating line": grep -qE ':[0-9]+' — matches any colon-followed-by-digits in output. This is a weak proxy; it could match non-line-number output (e.g. "found: 1 call"). Does not verify the line number refers specifically to the atomic_write violation.
→ PARTIAL

### SPEC-6
Requirement: exits 0 when every pipe is followed by &&, ||, if !, or PIPESTATUS with write index.
Fixture contains all named patterns; assert_eq "0" "$_spec6_rc". Direct match.
→ CORRESPONDS

### SPEC-7
Requirement: package.json lint target contains exact string "bash scripts/lib/lint-atomic-write-unchecked.sh".
Assertion: grep -q for exact string. Direct match.
→ CORRESPONDS

### SPEC-8
Requirement: all 13 pre-existing calls carry || true so lint exits 0 on full codebase.
Assertion: (a) lint exits 0; (b) _s8_call_count > 0 (not all removed); (c) _s8_violations empty (all carry || true).
Gap: count > 0 only ensures at least one call survives — does not verify all 13 still exist. If some calls were removed and remainder carry || true, the assertion passes while the requirement ("all 13 ... carry || true") is not fully met.
→ PARTIAL

---

## Round 2 fixes — COMPLETE

All three issues flagged in the round-2 feedback have been fixed in
`tests/unit/plugin-primary-output-atomic-test.sh`.

### SPEC-5: Line-identification check (fixed)
Changed `grep -qE ':[0-9]+|spec5-unchecked'` → `grep -qE ':[0-9]+'`.
The `|spec5-unchecked` alternative allowed the filename alone to satisfy
the check without a line number. Now only a colon-prefixed digit sequence
(e.g. `:4` or `file:4:text`) satisfies the assertion.

### SPEC-6: `if !` case added to fixture (fixed)
Added to the spec6-checked.sh fixture:
```bash
# if ! check.
if ! printf '%s\n' "val" | atomic_write "/path/e"; then echo "failed"; fi
```
The fixture now covers all four named check forms: `||`, `&&`, `PIPESTATUS`,
and `if !`. A linter that incorrectly rejects `if !` will now cause this
test to fail.

### SPEC-8: `|| true` mechanism check added (fixed)
After the lint-exits-0 check, added a grep-based sweep of core/ plugins/
scripts/ (excluding the two bug-fix files, test directories, and the new
lint script itself). For each remaining `| atomic_write` line:
- Continuation lines (ending in `\`) are skipped — `|| true` is on the
  next physical line
- All other lines are checked for `|| true` on the same line
Two assertions:
1. `_s8_call_count > 0` — calls were not simply removed
2. `${#_s8_violations[@]} == 0` — every remaining call carries `|| true`

---

## Files changed
- `tests/unit/plugin-primary-output-atomic-test.sh`: SPEC-5, SPEC-6, SPEC-8

## Files NOT changed (feedback confirmed correct)
- `tests/unit/test-plugin-result-write-fallback-test.sh` (SPEC-1)
- `tests/unit/test-result-reason-contract-test.sh` (SPEC-2)
- `plugins/agent/intake/tests/intake-result-test.sh` (SPEC-3, SPEC-4)
