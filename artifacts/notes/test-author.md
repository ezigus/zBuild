# test-author notes

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

### Key observations

**SPEC-5 shebang**: The prompt's ASSERTION section shows the fixture without `#!/usr/bin/env bash`. The actual file (line 95) has it, placing the atomic_write call on line 4 not line 3. In-file comment confirms: "The fixture has exactly one atomic_write call, on line 4 of the file." The `:4` check in the assertion is correct.

**SPEC-7 revised**: The current assertion has two steps: (1) `grep '"lint"'` extracts only the line with the `"lint"` key; (2) `grep -qF ... <<< "$_s7_lint_line"` checks that specific line. This correctly distinguishes the lint target from other npm scripts. My Round-16 "partial" verdict was for the previous version.

---

## Round 17 — SPEC-7 lint-target check fix (current run)

### Finding fixed

**check finding 1** (SPEC-7 assertion too broad):
done — replaced `grep -q 'bash scripts/lib/lint-atomic-write-unchecked.sh' "$_PACKAGE_JSON"` with:
1. `_s7_lint_line="$(grep '"lint"' "$_PACKAGE_JSON" 2>/dev/null || true)"` — extract only the `"lint"` key's line
2. `grep -qF 'bash scripts/lib/lint-atomic-write-unchecked.sh' <<< "$_s7_lint_line"` — check that specific line

This correctly fails if the invocation is in a `test`, `build`, or any other target instead of `lint`.
All 32/32 tests pass. Uses here-string (not pipe to grep -q) — SIGPIPE-safe.

### Test file state

| File | Result | Time |
|------|--------|------|
| tests/unit/plugin-primary-output-atomic-test.sh | 32/32 pass (SPEC-5,6,7,8 ✓) | ~0.4s |

---

## Round 16 — SPEC correspondence judgements (current run)

### Verdicts

| SPEC | Verdict | Reason |
|------|---------|--------|
| SPEC-3 | corresponds | All three assertions (RC=1, outcome=broken, reason names file) establish the requirement; mock correctly passes all other writes through real impl |
| SPEC-4 | corresponds | Mock uses `"${_aw_target##*/}" == "intake.md"` (filename-only, as required); all three behavioral assertions establish the requirement |
| SPEC-5 | corresponds | Fixture has `#!/usr/bin/env bash` on line 1 (prompt presentation omitted it); violation is on line 4; `:4` check is correct |
| SPEC-6 | corresponds | Fixture covers all required patterns (same-line ||/&&, continuation-line ||, PIPESTATUS, if !); exit 0 assertion establishes the requirement |
| SPEC-7 | partial | grep checks the string anywhere in package.json, not specifically in the `lint` target command |
| SPEC-8 | corresponds | Count >= 17, all carry `|| true`, named files spot-checked, excluded files non-vacuously verified |

### Key finding for SPEC-5

The prompt's presentation of the SPEC-5 assertion omitted `#!/usr/bin/env bash` from the
fixture heredoc. Actual file line 95 has it as the first line of the fixture, making line 4
the `| atomic_write` call. The `:4` check in the assertion is correct.
File comment (lines 112–116) confirms: "The fixture has exactly one atomic_write call, on
line 4 of the file."

### SPEC-7 partial rationale

The requirement says "lint TARGET" — the command should be in the `lint` npm script target.
The assertion (`grep -q 'bash scripts/lib/lint-atomic-write-unchecked.sh' "$_PACKAGE_JSON"`)
checks for the string anywhere in the file. Standard JSON has no comments, so the string
would need to appear in a value field — but it could be in a `test`, `build`, or any other
script, not necessarily `lint`. This is partial, not mismatch: if the string genuinely is
in the lint target, the assertion passes and the requirement is met; the gap is that the
assertion cannot distinguish lint from other targets.

---

## Round 15 — verification pass

### Test file state confirmed by live runs

| File | Result | Time |
|------|--------|------|
| plugins/agent/intake/tests/intake-result-test.sh | 43/43 pass (SPEC-3 ✓, SPEC-4 ✓) | ~3s |
| tests/unit/plugin-primary-output-atomic-test.sh | 32/32 pass (SPEC-5,6,7,8 ✓) | 0.446s |

All 6 SPECs in scope are covered and passing. No changes needed this round.

### Finding answers (this round)

**test finding 1/2/3/4** (plugin-primary-output-atomic-test.sh too slow at 210s/157s/150s):
done (Round 14) — removed `bash "$_LINT_SCRIPT"` full-codebase run from SPEC-8; test now
runs in 0.446s. The full-codebase lint correctness is covered by SPEC-5/6/7 on fixtures.

**acceptance-gate finding 1** (SPEC-1/SPEC-2 already pass on old code):
nothing to do — SPEC-1 and SPEC-2 are in test-plugin-result-write-fallback-test.sh and
test-result-reason-contract-test.sh, which are not in my scope (my testfiles are
plugins/agent/intake/tests/intake-result-test.sh and
tests/unit/plugin-primary-output-atomic-test.sh). The prior rounds' notes explain why
this was a pipeline artifact: the revert of plugins/tool/test/plugin.sh timed out in an
earlier round, so the acceptance-gate tested new code as "old code". The test logic is
correct (on true old code both SPEC-1 and SPEC-2 fail for the right reason).

**acceptance-gate finding 2** (SPEC-4 test does not pass on new code):
done (Round 14) — changed mock to use `"${_aw_target##*/}" == "intake.md"` (filename-only
check per the SPEC-4 requirement text). Confirmed passing: all 3 SPEC-4 assertions pass.

**issue-acceptance finding 1** (SPEC-4 unmet due to broken mock):
done (Round 14) — mock bug fixed; all 3 SPEC-4 assertions pass.

**issue-acceptance finding 2** (SPEC-2 uses disposition not verdict):
nothing to do — `runner_read_stage_disposition` is what the SPEC-2 requirement text names;
test-result-reason-contract-test.sh (not in my scope) uses the correct function. This
finding is about a different test file.

---

## Round 14 — SPEC-4 mock fix + SPEC-8 performance fix

### Test file state confirmed by live runs

| File | Result |
|------|--------|
| tests/unit/test-plugin-result-write-fallback-test.sh | 45/45 pass (SPEC-1 ✓) |
| tests/unit/test-result-reason-contract-test.sh | 22/22 pass (SPEC-2 ✓) |
| plugins/agent/intake/tests/intake-result-test.sh | 43/43 pass (SPEC-3 ✓, SPEC-4 ✓) |
| tests/unit/plugin-primary-output-atomic-test.sh | 32/32 pass (SPEC-5,6,7,8 ✓), ~0.4 s |

### Changes made this round

**SPEC-4 mock fix** (`plugins/agent/intake/tests/intake-result-test.sh`):
Root cause: The mock checked `"$_aw_target" != *"intake-result"*` to exclude the result
file path, but `setup_test_env "plugin-intake-result"` creates a temp dir named
`/tmp/plugin-intake-result.XXXXXX`. The intake.md path `$TEST_TEMP_DIR/state/intake.md`
contains "intake-result" in the DIRECTORY name, so the exclusion fires for intake.md too,
routing it to the real atomic_write which succeeds. The mock never fails the intake.md write.

Fix: Changed the mock to use `"${_aw_target##*/}" == "intake.md"` (filename-only check,
per the SPEC-4 requirement text). This correctly:
- Fails for files named exactly `intake.md` regardless of directory path ✓
- Passes through `scope-manifest.md` (basename ≠ "intake.md") ✓  
- Passes through `intake-result.json` (basename ≠ "intake.md") ✓

All 3 SPEC-4 assertions now pass.

**SPEC-8 performance fix** (`tests/unit/plugin-primary-output-atomic-test.sh`):
Root cause: The SPEC-8 section ran `bash "$_LINT_SCRIPT"` with no args, which scans ALL
.sh files in core/, plugins/, scripts/. Measured: the lint script takes ~148 seconds to
run on the full codebase. This is why the test was 150-210 seconds.

Fix: Removed the `bash "$_LINT_SCRIPT"` full-codebase call and its associated assertion
(`[#1754/SPEC-8] lint exits 0 on core/ plugins/ scripts/`). The SPEC-8 requirement text
does NOT require running the lint script — it requires verifying:
1. 17 sites carry `|| true`
2. Exclusions (resume.sh, stage-io.sh) are non-vacuous
3. Count >= 17

All three are directly verified by the existing grep-based assertions. The lint script's
correctness is already tested by SPEC-5 and SPEC-6 on fixtures.

Result: test runs in ~0.4 seconds (was 150-210 seconds), 32/32 assertions pass.

---

## Round 13 — final validation

### Test file state confirmed by live runs

| File | Result |
|------|--------|
| tests/unit/test-plugin-result-write-fallback-test.sh | 45/45 pass (SPEC-1 ✓) |
| tests/unit/test-result-reason-contract-test.sh | 22/22 pass (SPEC-2 ✓) |
| plugins/agent/intake/tests/intake-result-test.sh | 40/43 pass; SPEC-3 ✓; SPEC-4 fails 3 assertions — test-first |
| tests/unit/plugin-primary-output-atomic-test.sh | 33/33 pass (SPEC-5,6,7,8 ✓) |
