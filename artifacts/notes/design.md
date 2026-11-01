# Design notes — issue #1754 (revision 7 — current)

## Summary of changes in revision 7

**Root-cause audit via git history.** Reading `64960f4b^` (the pre-issue state):

- `plugins/tool/test/plugin.sh:1188` — `local _jq_rc="${PIPESTATUS[0]}" _aw_rc="${PIPESTATUS[1]}"` was PRE-EXISTING before this issue. PIPESTATUS[1] was already captured for the primary write. The actual bug was in the FALLBACK BLOCK (lines 1204–1210), which used `| atomic_write "$path" && stage_result_add "$path" broken "result_write_failed"`. With any test mock that intercepts ALL atomic_write calls, the fallback `| atomic_write` also fails → `&&` short-circuits → stage_result_add never runs → broken result not written. The fix (commit `64960f4b`) replaced this with `> "$path" 2>/dev/null || true` (direct redirect that bypasses any atomic_write mock).

- `plugins/agent/intake/plugin.sh` (scope-manifest): PIPESTATUS[1] check was PRE-EXISTING and correct (no debug lines between pipe and local). SPEC-3 → [done].

- `plugins/agent/intake/plugin.sh` (intake.md): BROKEN pre-issue. A debug printf line `printf "DEBUG_PIPE PIPESTATUS_BEFORE_LOCAL=(%s)\n" ... >> /tmp/intake_debug.txt` was inserted BETWEEN the pipe and `local _im_aw_rc="${PIPESTATUS[1]}"`, resetting PIPESTATUS. So `_im_aw_rc` was always 0. The fix removes those lines. SPEC-4 → [code].

**SPEC-1/SPEC-2: [done] WAS WRONG — now [code].**
The acceptance gate said "reverting plugins/tool/test/plugin.sh causes no test failures." Root cause: the current tests use a CALL-#1-ONLY mock. Old code fallback uses `| atomic_write` which is call #2 — not intercepted. So the old fallback succeeds anyway, writes broken result via stage_result_add, and the test passes.

To fail on old code, both SPEC-1 and SPEC-2 tests must use an ALL-FAIL mock that intercepts every atomic_write call. Then:
- Old code: fallback `| atomic_write` (call #2) fails → `&&` skips stage_result_add → no broken written → prior-round "pass" remains → assertion fails
- New code: `> "$path"` bypasses mock → broken written → assertion passes

**SPEC-3: [done] (scope-manifest check was pre-existing)**
Evidence: `plugins/agent/intake/plugin.sh:273 plugins/agent/intake/plugin.sh:274` (same lines pre-issue).

**SPEC-4: remains [code]** (intake.md PIPESTATUS was broken due to debug lines).

**WIRING update:** `plugins/tool/test/plugin.sh` added back to WIRING.

**TESTFILES update:** SPEC-1 and SPEC-2 added. SPEC-3 removed (it's [done]).

## Files read this revision

- `plugins/tool/test/plugin.sh:1185-1215` — current state: PIPESTATUS[1] at line 1188, fallback uses `>` ✓
- `git show 64960f4b^:plugins/tool/test/plugin.sh:1185-1214` — pre-issue: PIPESTATUS[1] at 1188, fallback uses `| atomic_write && stage_result_add` ← the bug
- `git show 64960f4b^:plugins/agent/intake/plugin.sh:270-295` — pre-issue: scope-manifest PIPESTATUS correct (no debug), intake.md has debug printf resetting PIPESTATUS ← the bug
- `tests/unit/test-plugin-result-write-fallback-test.sh:237-288` — SPEC-1 test uses call-#1-only mock → passes on old code (call #2 succeeds) → needs all-fail mock
- `tests/unit/test-result-reason-contract-test.sh:263-311` — SPEC-2 test uses call-#1-only mock → same issue
- `plugins/agent/intake/tests/intake-result-test.sh:440-491` — SPEC-4 mock uses `${_aw_target##*/}` == "intake.md" → correct after commit `6f9399a2`
- `git show 64960f4b` — first code stage commit: fixed fallback in test plugin, removed debug lines from intake plugin
- `git show 926ac5ac/f71aa772` — later cleanup commits
- `git show 6f9399a2` — fixed SPEC-4 mock from `*"intake.md"` glob to `${##*/}` basename (old glob excluded paths containing "intake-result" — matching the temp dir prefix)

## Prior revision history

### Revision 6

Marked SPEC-1/2 as [done] because the fix was in the worktree. This was wrong: the "fix" that was in the worktree was the PIPESTATUS[1] capture, which was pre-existing. The ACTUAL new fix (fallback block change) was not tested. The tests used call-#1-only mocks which passed on both old and new code.

### Revision 5

- Acceptance-gate finding 1: SPEC-1/SPEC-2 pass on old code
- Acceptance-gate finding 2: SPEC-4 test doesn't pass on new code (mock broken)
- Issue-acceptance finding 1: SPEC-4 unmet (mock broken in submitted diff)
- Issue-acceptance finding 2: SPEC-2 "NOT SURE" (prior-round logic not in diff)

### Original bug analysis (revision 1)

- `plugins/tool/test/plugin.sh`: only `PIPESTATUS[0]` captured — THIS WAS WRONG, PIPESTATUS[1] was pre-existing
- `plugins/agent/intake/plugin.sh:273-274`: no exit check — PARTIALLY WRONG, scope-manifest was correct; intake.md was broken by debug printf resetting PIPESTATUS

### Additional `| atomic_write` sites (revision 2)

17 unchecked sites:
- 9 files: core/detect/platforms.sh, core/pipeline/state_helpers.sh, core/output/destinations.sh, plugins/agent/pr-delivery/plugin.sh, plugins/tool/merge/plugin.sh, plugins/tool/output-github-comment/plugin.sh, plugins/tool/pr-open/plugin.sh, plugins/tool/test/lib/acceptance-reason.sh, plugins/tool/test/lib/acceptance-check.sh → get `|| true`
- 2 excluded: core/state/resume.sh (PIPESTATUS[1] on next line), core/output/stage-io.sh (if ! on same line)
- 2 additional: secrets.sh:172, own-checks.sh:72,96,101 → get `|| true`

### SPEC-2 text correction (revision 5)

`runner_read_stage_verdict` → `runner_read_stage_disposition`.
