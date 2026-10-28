# design stage notes — issue #1944

## Current pass (iter-8 design refinement)

### iter-8 additions vs iter-7

1. Bug D moved from "Still defective" to "Applied correctly" — pgrep+kill fix IS in the code
   (runner.sh lines 2566-2578, added by commit 9e7ad118)
2. Added Bug E / Finding 25: sigterm-aborts STILL fails (480s) despite Bug D fix
   - tree_sha of test run (4e0a75df) matches current HEAD tree — test ran on fixed code
   - The runner bash doesn't exit within 480s (wait "$RUNNER_PID" hangs in the test)
   - Root cause unknown from static analysis; the pgrep+kill approach is correct in theory
   - The hang is at `wait "$RUNNER_PID"` in the test (line 173), confirming runner doesn't exit
3. Notes on acceptance gate updated: acceptance gate PASSED (all 4 code SPECs + 2 no-code)
   but full test suite (npm test) still fails due to sigterm-aborts
4. Decision 8 updated: Bug D is applied; test still fails; possible additional cause noted

### What I verified in iter-8

**Bug D IS applied (runner.sh lines 2566-2578):**
```bash
local _wdg_orphans=""
if [[ -n "${_RUNNER_WATCHDOG_PID:-}" ]] && command -v pgrep >/dev/null 2>&1; then
    _wdg_orphans="$(pgrep -P "${_RUNNER_WATCHDOG_PID}" 2>/dev/null || true)"
fi
kill -KILL "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null || true
[[ -n "${_RUNNER_WATCHDOG_PID:-}" ]] && wait "${_RUNNER_WATCHDOG_PID}" 2>/dev/null || true
if [[ -n "$_wdg_orphans" ]]; then
    local _wc; while IFS= read -r _wc; do
        [[ -n "$_wc" ]] && kill -KILL "$_wc" 2>/dev/null || true
    done <<< "$_wdg_orphans"
fi
```

**Test run confirmed on current HEAD:**
- test-results.json tree_sha = 4e0a75df92c0510383f280eeefe371b8c74bb046
- git log --format="%T" -1 2595a712 = 4e0a75df92c0510383f280eeefe371b8c74bb046
- They match → test stage ran on current HEAD (which includes Bug D fix, commit 9e7ad118)
- sigterm-aborts STILL times out at 480s

**Acceptance gate PASSED:**
- SPEC-1 through SPEC-4 [code]: all pass negctl (fail on old, pass on new)
- SPEC-5 and SPEC-6 [no-code]: skipped (as expected)
- All WIRING reachability checks pass

**sigterm-aborts hang analysis:**
- Test hangs at `wait "$RUNNER_PID"` (line 173) — no assertions are printed
- This means the runner bash (the setsid process) has not exited within 480s
- The runner's EXIT trap must be stuck
- All EXIT trap steps should be fast (dispatch skips unresolvable plugins, no status comment PID)
- The `wait "${_RUNNER_WATCHDOG_PID}"` (after SIGKILL) should be instant
- Root cause unknown; possible additional bug in the EXIT trap flow

## Prior pass notes (iter-7, carried forward)

### iter-7 additions vs iter-6

1. Bug B status corrected in design (was "still defective", now "applied correctly")
2. Decision 4 cleaned up (removed "Current worktree defect (Finding 21)")
3. Decision 8 added: sigterm-aborts-pipeline-test.sh hang root cause and fix
4. Bug fix status section updated: Bug B moved to "Applied correctly"
5. Notes on acceptance gate updated: SPEC-5 passes, sigterm-aborts is new failing test
6. Scope: added `tests/integration/sigterm-aborts-pipeline-test.sh`
7. Finding 20 updated: SPEC-5 runner-release now passes
8. Finding 21 corrected: Bug B IS fixed (guard at line 939)
9. Finding 24 added: sigterm-aborts-pipeline-test.sh 480 s hang

## Key code locations (runner.sh — current)

- `_runner_restore_stderr` at line 928-942, `trap ':' INT TERM` is line 939 (FIRST line) ← BUG B FIXED
- `_runner_abort_trap` at line 2540
- Calls `_runner_restore_stderr` first: line 2543
- `trap ':' INT TERM` at line 2551 (idempotent)
- Watchdog children collect: lines 2566-2569 (BUG D FIXED)
- Watchdog kill: line 2570 (`kill -KILL "${_RUNNER_WATCHDOG_PID:-}"`)
- Watchdog wait: line 2571 (`wait "${_RUNNER_WATCHDOG_PID}"`)
- Orphan kill loop: lines 2572-2578
- `exec {_RUNNER_ERR_FD}>&2` at line 2773
- Watchdog arm: lines 2832-2865 (line 2843: `exec {_RUNNER_ERR_FD}>&- || true` — Bug A fixed)
- `trap '' TERM` at line 2836 (watchdog ignores SIGTERM)
- `sleep "$_wdg_lim"` at line 2847 (watchdog's foreground child, inherits SIGTERM=SIG_IGN)
- `trap '_runner_signal_trap TERM' TERM` startup install: line 2781
- Watchdog PID: `_RUNNER_WATCHDOG_PID=$!` at line 2865
