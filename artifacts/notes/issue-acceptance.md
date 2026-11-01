# Issue #1754 Acceptance Notes

## What I read

- `plugins/agent/intake/plugin.sh` (full file) — the current implementation
- `plugins/agent/intake/tests/intake-result-test.sh` lines 1-100 and 412-489 — SPEC-3 and SPEC-4 tests
- `tests/unit/test-result-reason-contract-test.sh` lines 260-314 — SPEC-2 test (the diff hunk)
- `tests/unit/plugin-primary-output-atomic-test.sh` lines 165-290 — SPEC-8 test
- `core/pipeline/verdict.sh` lines 369-424 — runner_read_stage_verdict implementation
- `scripts/lib/helpers.sh` lines 173-191 — atomic_write implementation
- grep results for runner_read_stage_verdict/disposition definitions
- grep results for `| atomic_write` in own-checks.sh and secrets.sh

## SPEC-by-SPEC conclusions

### SPEC-1 (test plugin fallback writes outcome=broken)
Not in failing tests. Met.

### SPEC-2 (runner_read_stage_verdict returns broken)
The diff changes the assertion from `_classify()` (which calls `runner_read_stage_verdict`) to 
`runner_read_stage_disposition`. SPEC-2 explicitly names `runner_read_stage_verdict`. 

Analysis of verdict.sh: `runner_read_stage_verdict` maps unknown verdict strings to "warn" via:
`case "$raw_verdict" in pass) cls=pass ;; fail|error) cls=fail ;; *) cls=unknown ;; esac`
followed by `if [[ "$cls" == "unknown" ]]; then _rsvo="warn"; return 0; fi`

"broken" would fall into `*)` → cls=unknown → "warn". So `runner_read_stage_verdict` likely returns "warn" 
not "broken" for a file with outcome=broken. The test change from `_classify` to `runner_read_stage_disposition` 
is pragmatically sensible but tests a DIFFERENT function from the one SPEC-2 requires. The SPEC-2 assertion 
claims `runner_read_stage_verdict` returns "broken" — which it provably does not (it returns "warn"). 

This makes the SPEC-2 requirement as written unachievable by the reader. The cross-check assertion 
(raw file has outcome=broken) does confirm the fallback write works. But the named function is not tested.
UNSURE — cannot confirm runner_read_stage_verdict returns broken; the test no longer tests it.

### SPEC-3 (intake: scope-manifest.md failure → broken + non-zero)
Tests pass in the test output. Met.

### SPEC-4 (intake: intake.md failure → broken + non-zero)
DEFINITIVELY FAILS. Test output shows:
```
✗ [#1754/SPEC-4] _intake_run_inner returns non-zero on intake.md failure — expected: 1, got: 0
✗ [#1754/SPEC-4] intake-result.json carries outcome=broken — expected: broken, got: pass
✗ [#1754/SPEC-4] reason names intake.md — output missing: intake.md
```

Plugin code at lines 280-286 shows the check exists. But the test still returns 0 and outcome=pass.
The diff provided does NOT touch intake/plugin.sh or the SPEC-4 test — it only changes the SPEC-2 
assertion in test-result-reason-contract-test.sh. The SPEC-4 failure is unresolved by this diff.

### SPEC-5 (lint exits non-zero for unchecked bare pipe)
Not in failing tests. Met.

### SPEC-6 (lint exits 0 for properly checked pipes)
Not in failing tests. Met.

### SPEC-7 (package.json lint target contains lint-atomic-write-unchecked.sh)
Not in failing tests. Met.

### SPEC-8 (17 annotated sites carry || true)
own-checks.sh:72,96,101 and secrets.sh:172 all carry `|| true` (confirmed by grep).
Test at lines 165-285 of plugin-primary-output-atomic-test.sh:
- runs lint on full codebase
- counts | atomic_write sites excluding bug-fix files, test dirs, lint script, resume.sh, stage-io.sh
- checks count >= 17
- checks all carry || true
- specifically checks secrets.sh and own-checks.sh named sites
- non-vacuously checks resume.sh and stage-io.sh exclusions

Test NOT in failing list. The test would catch it broken if || true were removed (lint would catch it)
or if sites were deleted (count check fails). Met.

## Verdict

FAIL — SPEC-4 unmet (confirmed by test suite), SPEC-2 unsure (test changed to different function).
