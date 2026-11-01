# test-author notes

---

## Round 22 — Final SPEC correspondence judgements (this run)

Each SPEC reviewed against the REQUIREMENT and the tagged ASSERTION lines.

| SPEC | Verdict | Reason |
|------|---------|--------|
| SPEC-1 | corresponds | All-fail mock intercepts every atomic_write; four assertions (file exists, valid JSON, outcome=broken, reason=result_write_failed) establish the full requirement; on old code fallback \| atomic_write is also intercepted → prior pass survives → assertion fails |
| SPEC-2 | corresponds | Same all-fail mock; runner_read_stage_disposition (the exact function the requirement names) asserted to return "broken"; jq check confirms file itself carries outcome=broken; on old code prior pass survives → disposition is not broken → assertion fails |
| SPEC-4 | corresponds | Mock uses `"${_aw_target##*/}" == "intake.md"` (filename-only per requirement text); all three required behaviors asserted (RC=1, outcome=broken, reason contains "intake.md"); other writes pass through real impl |
| SPEC-5 | corresponds | Lint exits non-zero AND output contains `${_spec5_fixture_base}:4`; shebang on line 1 puts atomic_write at line 4; both required behaviors (non-zero exit, named violating line) are asserted |
| SPEC-6 | corresponds | Fixture covers all required checked patterns (same-line \|\|/&&, continuation-line \|\|, PIPESTATUS, if !); single exit-0 assertion establishes requirement |
| SPEC-7 | corresponds | Two-step check extracts only the `"lint"` key line then greps that line for the exact invocation; cannot pass if string is in any other npm script target |
| SPEC-8 | corresponds | Count >=17, all carry \|\| true, secrets.sh >=1 annotated call, own-checks.sh >=3 annotated calls, non-vacuous exclusion checks on both resume.sh and stage-io.sh establish every part of the requirement |

---

## Round 21 — Performance findings answered; all tests pass

All four test files run under 1 second each (verified this round):
- tests/unit/plugin-primary-output-atomic-test.sh: 0.447s (32 pass)
- tests/unit/test-plugin-result-write-fallback-test.sh: 0.535s (45 pass)
- tests/unit/test-result-reason-contract-test.sh: 0.671s (22 pass)
- plugins/agent/intake/tests/intake-result-test.sh: 0.761s (43 pass)

The test-stage findings 1-4 (150-210s) are stale — from before Round 14's SPEC-8 performance fix
(which removed the `bash "$_LINT_SCRIPT"` no-args invocation from the SPEC-8 section).
The current test file uses grep directly for SPEC-8 (no lint script invocation).

### Finding answers

ANSWER test finding 1: done — fixed in Round 14 (removed full-codebase bash "$_LINT_SCRIPT" call from SPEC-8; now uses direct grep). File now runs in 0.447s.
ANSWER test finding 2: done — same fix as finding 1; stale result from the same pre-Round-14 run.
ANSWER test finding 3: done — same fix as finding 1; stale result from the same pre-Round-14 run.
ANSWER test finding 4: done — same fix as finding 1; stale result from the same pre-Round-14 run.

---

## Round 20 — Final SPEC correspondence verdicts (this run)

### Verdicts

| SPEC | Verdict | Reason |
|------|---------|--------|
| SPEC-1 | corresponds | All-fail mock (cat > /dev/null; return 1) intercepts every atomic_write; file-exists, valid-JSON, outcome=broken, reason=result_write_failed assertions establish the full requirement; on old code the fallback \| atomic_write is also mocked → prior pass survives → assertion fails |
| SPEC-2 | corresponds | Same all-fail mock; runner_read_stage_disposition (the exact function the requirement names) is called and asserted to return "broken"; jq check confirms the file itself carries outcome=broken |
| SPEC-4 | corresponds | Mock uses `"${_aw_target##*/}" == "intake.md"` (filename-only, as the requirement text specifies); RC=1, outcome=broken, and reason contains "intake.md" assertions establish all three behavioral parts of the requirement |
| SPEC-5 | corresponds | Lint exits non-zero AND output contains "${_spec5_fixture_base}:4"; shebang on line 1 puts atomic_write on line 4 (confirmed by in-file comment); both required behaviors (non-zero exit and named line) are asserted |
| SPEC-6 | corresponds | Fixture covers all required checked patterns (same-line ||/&&, continuation-line ||, PIPESTATUS, if !); single exit-0 assertion establishes the requirement |
| SPEC-7 | corresponds | Two-step check: extract only the `"lint"` key's line, then grep that line for the invocation; cannot pass if the string is in any other npm script target |
| SPEC-8 | corresponds | Count >=17, all carry \|\| true, secrets.sh >=1, own-checks.sh >=3, non-vacuous exclusion checks on both resume.sh and stage-io.sh establish every part of the requirement |

---

## Round 19 — Fix SPEC-1 and SPEC-2 mocks to fail ALL atomic_write calls

### Problem

The acceptance-gate finding 1 reported: "plugins/tool/test/plugin.sh was put back to its old version and every test still passed". This means SPEC-1 and SPEC-2 tests pass on OLD code, which is wrong.

**Root cause**: The current SPEC-1/SPEC-2 mocks only fail the FIRST `atomic_write` call (call #1). On OLD code, the fallback path uses `| atomic_write` too (call #2+), which passes through to the real implementation and SUCCEEDS. So even old code ends up writing `outcome=broken`. The assertion passes on old code — it shouldn't.

**Per the SPEC**: "the test mock must fail EVERY atomic_write call so only the direct-redirect fallback path (using > not | atomic_write) can write a result; on old code the fallback | atomic_write also gets intercepted → && short-circuits → stage_result_add not called → prior-round pass survives → assertion fails"

### Fix applied

**SPEC-1** (`tests/unit/test-plugin-result-write-fallback-test.sh`):
- Removed `_1754s1_aw_calls=0` counter
- Removed the `if [[ "$_1754s1_aw_calls" -eq 1 ]]` conditional
- Mock now fails ALL calls unconditionally
- Still save/restore real atomic_write using `_aw_real_1754s1` for cleanup

**SPEC-2** (`tests/unit/test-result-reason-contract-test.sh`):
- Removed `_1754s2_aw_calls=0` counter
- Removed the `if [[ "$_1754s2_aw_calls" -eq 1 ]]` conditional
- Mock now fails ALL calls unconditionally
- Still save/restore real atomic_write using `_aw_real_1754s2` (needed before reader call)

### Why this correctly distinguishes old from new code

On **old code** with all-fail mock:
- Primary `| atomic_write` fails (mocked)
- Fallback also uses `| atomic_write` → fails (mocked)
- `&&` short-circuits → `stage_result_add` not called
- Prior-round `pass` file survives unchanged
- Assertion `expected broken, got pass` → FAILS ✓

On **new code** with all-fail mock:
- Primary `| atomic_write` fails (mocked)
- New fallback uses `>` (direct redirect, no atomic_write) → NOT intercepted → SUCCEEDS
- Broken result written with `outcome=broken`
- Assertion passes ✓

### SPEC-4 status

SPEC-4 test in intake-result-test.sh is CORRECT. It correctly fails on old code:
- `_intake_run_inner returns non-zero on intake.md failure — expected: 1, got: 0` ← correct failure
- `intake-result.json carries outcome=broken — expected: broken, got: pass` ← correct failure
- `reason names intake.md — output missing: intake.md` ← correct failure

These failures are expected because the intake plugin.sh implementation hasn't been written yet.
The issue-acceptance finding 1 is a code-stage finding, not a test-author problem.

### SPEC-5, 6, 7, 8 status

All correct and passing from Round 14+. No changes needed.

### Finding answers

ANSWER acceptance-gate finding 1: done — changed SPEC-1 mock to fail ALL atomic_write calls (removed call counter and conditional), so old code's fallback | atomic_write is also intercepted → prior-round pass survives → assertion fails on old code
ANSWER issue-acceptance finding 1: nothing to do — SPEC-4 test assertions correctly FAIL on old code (no implementation yet); this is a code-stage problem, not a test-author problem
ANSWER issue-acceptance finding 2: nothing to do — SPEC-2 uses `runner_read_stage_disposition` which is what SPEC-2 explicitly requires ("runner_read_stage_disposition returns broken"); the test is correct

---

## Round 18 — SPEC correspondence judgements (final)

### Verdicts

| SPEC | Verdict | Reason |
|------|---------|--------|
| SPEC-3 | corresponds | All three tagged assertions (RC=1, outcome=broken, reason names scope-manifest.md) establish the requirement exactly; mock passes non-scope-manifest writes through real impl |
| SPEC-4 | corresponds | Mock uses `"${_aw_target##*/}" == "intake.md"` as the requirement specifies; all three behavioral assertions establish the full requirement |
| SPEC-5 | corresponds | Actual fixture has `#!/usr/bin/env bash` on line 1 (prompt omitted it); atomic_write is on line 4; `:4` check is correct (confirmed by in-file comment at lines 112–116) |
| SPEC-6 | corresponds | Fixture covers all required patterns; single exit-0 assertion establishes the requirement |
| SPEC-7 | corresponds | Assertion extracts ONLY the `"lint"` key line then checks for the invocation in that line; targets the lint script specifically (prior Round-16 "partial" verdict was for the older whole-file grep, which has since been fixed) |
| SPEC-8 | corresponds | Count >=17, all carry || true, named files spot-checked (secrets.sh >=1, own-checks.sh >=3), excluded files non-vacuously verified |

---

## Round 17 — SPEC-7 lint-target check fix

done — replaced `grep -q 'bash scripts/lib/lint-atomic-write-unchecked.sh' "$_PACKAGE_JSON"` with two-step check extracting only the `"lint"` key's line then checking that line.

---

## Round 14 — SPEC-4 mock fix + SPEC-8 performance fix

**SPEC-4 mock fix**: Changed mock to use `"${_aw_target##*/}" == "intake.md"` (filename-only check, per SPEC-4 requirement text). Root cause of old bug: mock checked `"$_aw_target" != *"intake-result"*` which matched the temp dir path `plugin-intake-result.XXXXXX`, routing intake.md through real atomic_write.

**SPEC-8 performance fix**: Removed `bash "$_LINT_SCRIPT"` full-codebase run from SPEC-8. Test now runs in 0.446s.

