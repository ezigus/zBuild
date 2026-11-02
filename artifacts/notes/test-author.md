# test-author notes — issue #1805 (round 2 fix: from-stage-rehydrate-test.sh)

## Status: COMPLETE — from-stage-rehydrate-test.sh bug fixed

## Round-2 checker findings for from-stage-rehydrate-test.sh

### Finding 1: SPEC-3 — artifact placement assertions were non-tagged

**Original finding:** "`assert_file_exists` and `assert_contains` calls that check
'places their artifacts in ZBUILD_ARTIFACT_DIR' are not tagged with `[#1805/SPEC-3]`"

**Status in current file:** Already resolved by a previous test-author call. Lines 113-126
carry `[#1805/SPEC-3]` tags on both the `assert_file_exists` and `assert_contains` calls.

### Finding 2: SPEC-4 — stderr-naming assertion was non-tagged

**Original finding:** "`assert_contains "$_s4_stderr" "intake"` is not tagged with `[#1805/SPEC-4]`"

**Status in current file:** Already resolved by a previous test-author call. Line 211-214
carries `[#1805/SPEC-4] stderr names the missing stage (intake)`.

## Test failure (round 2): SPEC-3 no-stage.start assertion fails with "expected: 0, got: 0"

**Root cause:** Lines 131-135 used `| grep -c '^intake$' 2>/dev/null || echo 0`.
When `grep -c` finds 0 matches:
1. `grep -c` outputs `"0"` to stdout and exits with code 1
2. `|| echo 0` fires (because grep exited 1) and outputs another `"0"` to stdout
3. Command substitution captures `"0\n0"` — two zeros, not one
4. `"0\n0"` != `"0"` → assert_eq fails, showing "expected: 0, got: 0" (the second 0
   appears on the next display line, making it look like both are 0)

**Fix applied (this call):** Replaced the buggy `grep -c ... || echo 0` with:
```bash
_s3_intake_starts="$(jq -r 'select(.type=="stage.start" and .data.stage=="intake") | .type' \
    "$S3_EVENTS_JSONL" 2>/dev/null | wc -l | tr -d ' ')"
```
- Uses jq to filter to only `stage.start` events for `intake`, outputs `.type` per match
- `wc -l` always exits 0 and outputs a count (no double-output problem)
- `tr -d ' '` strips whitespace from `wc -l` output (mac compat)
- No `|| echo 0` needed — `wc -l` never outputs a non-number

This mirrors the pattern used in SPEC-4 (lines 218-221 use `wc -l | tr -d ' '`).

## SPEC coverage summary for from-stage-rehydrate-test.sh

- SPEC-3: assert_file_exists [tagged] + assert_contains content [tagged] +
          no-intake-stage.start [tagged, fixed count] + build-is-first [tagged]
- SPEC-4: exit 1 [tagged] + no-stage.start [tagged] + stderr names stage [tagged]
- SPEC-13: type:cycle in fixture + intake dispatched in fresh run

## Other test files (fixed in prior calls)

- resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12
- resume-loop-state-test.sh — SPEC-7
- resume-entry-points-test.sh — SPEC-9
