# Build notes — #1754

## What I found

### SPEC-1 / SPEC-2 fix (plugins/tool/test/plugin.sh)
- Line 1188: `local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"` — correct, both captured
- Line 1189: `(( _aw_rc != 0 )) && _jq_rc="$_aw_rc"` — write failure triggers broken fallback
- BOTH SPECs PASS in the test suite ✓

### SPEC-3 / SPEC-4 fix (plugins/agent/intake/plugin.sh)
- Lines 273-279: scope-manifest.md PIPESTATUS[1] check — correct ✓ (SPEC-3 PASSES)
- Lines 280-286: intake.md PIPESTATUS[1] check — correct ✓ (SPEC-4 FAILS due to mock bug)

### SPEC-4 mock bug (READ-ONLY TEST — CANNOT FIX)
- Test at `plugins/agent/intake/tests/intake-result-test.sh:465-472`
- Mock fails `atomic_write` for `*"intake.md" && != *"intake-result"*`
- `setup_test_env "plugin-intake-result"` creates TEST_TEMP_DIR = `/tmp/plugin-intake-result.XXXXXX`
- intake.md path = `$TEST_TEMP_DIR/state/intake.md` = `/tmp/plugin-intake-result.XXXXXX/state/intake.md`
- This path CONTAINS "intake-result" (from "plugin-intake-result" dir name)
- So `!= *"intake-result"*` is FALSE → mock falls through to real atomic_write
- Real atomic_write SUCCEEDS → _im_aw_rc=0 → function returns 0
- SPEC-4 cannot pass on ANY implementation; the test mock is broken
- Test file is read-only (mechanical check restores changes)

### SPEC-5/6/7/8 (lint script + wire-in + 17 annotations)
- `scripts/lib/lint-atomic-write-unchecked.sh` exists ✓
- Wired into package.json lint target ✓
- All 17 `|| true` annotations in place ✓
- ALL PASS ✓

## Current status (iteration 4)
- SPEC-1: PASS ✓
- SPEC-2: PASS ✓
- SPEC-3: PASS ✓
- SPEC-4: FAIL — mock bug in read-only test, cannot fix
- SPEC-5: PASS ✓
- SPEC-6: PASS ✓
- SPEC-7: PASS ✓
- SPEC-8: PASS ✓

## Conclusion
All implementation work is complete and correct. SPEC-4 cannot pass because the
test mock in intake-result-test.sh has a path-matching bug: the exclusion pattern
`!= *"intake-result"*` matches the temp dir name `plugin-intake-result`, preventing
the mock from intercepting the intake.md write.

No code changes made in this iteration — everything already implemented correctly
in prior iterations.
