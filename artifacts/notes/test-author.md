# test-author notes — issue #1805 (round 9: hydrate-stage-test.sh SPEC-13 fix)

## Status: COMPLETE — all findings addressed; hydrate-stage-test.sh fixed

## Change made in this call (hydrate-stage-test.sh only)

### Finding: SPEC-13 never ran on old code (exit 127 at line 216)

**Root cause:** `_artifact_persist_put_back` is a new function added by this change.
On old code it does not exist in `artifact-persist.sh`. Line 216 calls it directly
under `set -euo pipefail`, so the script exits with code 127 before the
`[#1805/SPEC-13]` section at (now) line 240 ever runs.

**Fix applied:** Added a conditional stub before the [SPEC-7] section (lines 218-224):
```bash
if ! declare -f _artifact_persist_put_back >/dev/null 2>&1; then
    _artifact_persist_put_back() {
        local _from="$1" _to="$2"
        mkdir -p "$_to"
        cp -r "$_from/." "$_to/"
    }
fi
```

**Why this is correct:**

On OLD code (before this change):
1. `_artifact_persist_put_back` not in artifact-persist.sh → stub is defined (copies everything)
2. Line 230: stub called → copies plan.json AND stage-io/ into _S7_TO
3. [SPEC-7] `assert_file_not_exists` for stage-io record → FAILS (stub copies it) ✓ correct failure
4. Script continues (assert records failure but doesn't exit)
5. [#1805/SPEC-13] redefines `_artifact_persist_put_back` as sentinel writer
6. `hydrate_run` on old code calls `_hydrate_put_back` inline → sentinel NOT written
7. `assert_file_exists "[#1805/SPEC-13] ..."` → FAILS (sentinel absent) ✓ correct failure for SPEC-13

On NEW code (after this change):
1. `_artifact_persist_put_back` defined in artifact-persist.sh → stub NOT activated
2. Line 230: real function called → copies plan.json, excludes stage-io
3. [SPEC-7] assertions pass ✓
4. [#1805/SPEC-13] redefines `_artifact_persist_put_back` as sentinel writer
5. `hydrate_run` on new code calls `_artifact_persist_put_back` → sentinel written
6. `assert_file_exists "[#1805/SPEC-13] ..."` → PASSES ✓

**ANSWER test finding (round 2): done — added conditional stub for `_artifact_persist_put_back`
before [SPEC-7] section so script does not exit 127 before SPEC-13 can run on old code;
SPEC-13 correctly fails on old code (sentinel not written when hydrate_run calls
_hydrate_put_back inline) and passes on new code.**

## Prior round changes (from-stage-rehydrate-test.sh, resume-rehydrate-test.sh — unchanged this round)

All other test files were confirmed correct in prior rounds:
- resume-rehydrate-test.sh: SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-14 ✓
- from-stage-rehydrate-test.sh: SPEC-3, SPEC-4, SPEC-14 ✓
- resume-loop-state-test.sh: SPEC-7 ✓
- resume-entry-points-test.sh: SPEC-9 ✓
- hydrate-stage-test.sh: SPEC-13 (fixed this round) ✓

## SPEC coverage summary (all files — final)

### hydrate-stage-test.sh — SPEC-13

**SPEC-13:**
- Stub guard at lines 218-224 prevents exit 127 on old code
- `_artifact_persist_put_back` redefined as sentinel writer at lines 243-245
- `hydrate_run` called in subshell at lines 253-254
- `assert_file_exists "[#1805/SPEC-13] ..."` at lines 259-261
  → fails on old code (hydrate_run calls _hydrate_put_back inline, not the sentinel)
  → passes on new code (hydrate_run calls _artifact_persist_put_back → sentinel written)

### resume-rehydrate-test.sh — SPEC-1, SPEC-2, SPEC-5, SPEC-6, SPEC-12, SPEC-14

**SPEC-1 (all 3 paths):** Each path asserts:
- assert_file_exists [#1805/SPEC-1]: intake-result.json in ZBUILD_ARTIFACT_DIR
- assert_contains [#1805/SPEC-1]: artifact content from git state branch
  (proves _artifact_persist_restore + _artifact_persist_put_back called)
- assert_gt [#1805/SPEC-1]: any stage dispatched > 0 (dispatch loop ran)
- assert_gt [#1805/SPEC-1]: pipeline.resume event emitted
- assert_gt [#1805/SPEC-1]: pipeline.resume precedes first stage.start
- assert_eq [#1805/SPEC-1]: intake stage.start == 0 (complete stage skipped)

**SPEC-2:** assert_eq rc==1 + assert_eq any_starts==0
**SPEC-5:** ADR-006 step 3.6 content assertions
**SPEC-6:** ADR-050 §6 boundary note assertions
**SPEC-12:** assert_eq intake==1 + assert_contains type:cycle
**SPEC-14:** assert_contains [#1805/SPEC-14] fixture has type:cycle

### from-stage-rehydrate-test.sh — SPEC-3, SPEC-4, SPEC-14

**SPEC-3 (4 tagged):** file_exists + contains (artifact from git) + intake.start==0 + cycle.start==1
**SPEC-4 (3 tagged):** exits 1 + intake in stderr + no stage.start before exit
**SPEC-14:** assert_contains [#1805/SPEC-14] fixture has type:cycle

### resume-loop-state-test.sh — SPEC-7
### resume-entry-points-test.sh — SPEC-9
