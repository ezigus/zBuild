# Build notes — #1754

## What I found

### SPEC-1 / SPEC-2 fix (plugins/tool/test/plugin.sh)
- Line 1188: `local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"` — correct, both captured
- Line 1189: `(( _aw_rc != 0 )) && _jq_rc="$_aw_rc"` — write failure triggers broken fallback
- BOTH SPECs PASS in the test suite ✓

### SPEC-3 / SPEC-4 fix (plugins/agent/intake/plugin.sh)
- Lines 273-279: scope-manifest.md PIPESTATUS[1] check — correct ✓ (SPEC-3 PASSES)
- Lines 280-286: intake.md PIPESTATUS[1] check — correct ✓ (SPEC-4 PASSES)

### SPEC-4 mock fix (test-author stage applied it)
- Test at `plugins/agent/intake/tests/intake-result-test.sh:467-474`
- Mock now uses `"${_aw_target##*/}" == "intake.md"` (filename-only check, not path)
- This correctly intercepts intake.md writes regardless of temp dir name
- SPEC-4 PASSES with this mock and the PIPESTATUS[1] fix in the plugin ✓

### SPEC-5/6/7/8 (lint script + wire-in + 17 annotations)
- `scripts/lib/lint-atomic-write-unchecked.sh` exists ✓
- Wired into package.json lint target ✓
- All 17 `|| true` annotations in place ✓
- Test timing: 0.436s (well under threshold, no full-codebase scan) ✓
- ALL PASS ✓

## Current status (iteration 5)
- SPEC-1: PASS ✓ (45/45 tests)
- SPEC-2: PASS ✓ (22/22 tests)
- SPEC-3: PASS ✓ (43/43 tests)
- SPEC-4: PASS ✓ (43/43 tests)
- SPEC-5: PASS ✓ (32/32 tests)
- SPEC-6: PASS ✓ (32/32 tests)
- SPEC-7: PASS ✓ (32/32 tests)
- SPEC-8: PASS ✓ (32/32 tests)

## Conclusion
All 8 SPECs pass. The implementation is complete:
- plugins/tool/test/plugin.sh: captures PIPESTATUS[1] alongside PIPESTATUS[0]
- plugins/agent/intake/plugin.sh: captures PIPESTATUS[1] after each | atomic_write call
- intake-result-test.sh mock: fixed to use filename-only check
- lint script: created and wired
- 17 || true annotations: all in place
- No uncommitted changes in worktree
