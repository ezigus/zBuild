# Design notes — issue #1801 (third refinement)

## State of worktree as of this pass (third pass)

### lifecycle.sh (confirmed FIXED by build)
- Line 572: `zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true` — kill -KILL replaced ✓
- Lines 537-556: TERM trap installed (subshell and main-shell variants) ✓
- Line 500: `kill -KILL -- -<pgid>` appears only in a comment, filtered by `grep -v '^\s*#'` ✓
- SPEC-10 assertion in stage-timeout-dispatch-test.sh: should NOW pass ✓
- SPEC-6b scenario: TERM trap fires, kills _lc_hook_pid group via zbuild_pg_kill (KILL after 1s),
  exits 143. Resolves the SPEC-6b failure from the test stage. ✓

### runner.sh lines 2486-2487 (still not fixed by build)
- `kill -KILL -- -"$_ar_pid" 2>/dev/null || true` — still present
- `kill -TERM -- -"$_wd_pid" 2>/dev/null || true` — still present
- stage-timeout-always-run-test.sh lines 147-151 check for `kill -(TERM|KILL) -- -"$_ar_pid"`
  in _runner_dispatch_always_run body → WILL FAIL on current code
- This is the remaining build gap; design correctly identifies it at decision point 2 / SPEC-10

### runner-job-control-abort-test.sh (confirmed FIXED by build)
- Lines 149-153: structural check `grep -q 'set -m'` already in place ✓
- flag-on failure in test stage was from partial build state, not current code ✓

### stage-timeout-dispatch-test.sh always_run route (design gap → updating SPEC-1)
- Lines 92-110: file-level grep for runner.sh confirms plugin_hook_call somewhere in file
- Lines 112-168: AWK-extracted body checks for cycle_dispatch_stage, parallel_dispatch_stage,
  roleless leaf — all three have named-function or pattern-based extraction
- NO AWK-extracted body check for _runner_dispatch_always_run calling plugin_hook_call
- test-author finding: couldn't add this assertion in 2 rounds; needs explicit design guidance
- AWK pattern from stage-timeout-always-run-test.sh line 33:
    `/_runner_dispatch_always_run\(\) \{/{p=1} p{print} p && /^    \}$/{exit}`
  (_runner_dispatch_always_run is an inner function with 4-space closing brace)
- runner.sh line 2477: `plugin_hook_call "$_ar_dir" run ...` — function DOES call it
- Fix: update SPEC-1 text to explicitly require this AWK-extracted body check;
  the test-author has the pattern (it's already in stage-timeout-always-run-test.sh)
  but needs the contract to specify it

## Previous notes summary (second refinement)
- lifecycle.sh TERM trap and zbuild_pg_kill fix described in detail — now applied by build ✓
- runner.sh lines 2486-2487 still pending ✓
- flag-on structural check described — now applied by build ✓
- All three test failures were build/test-author gaps, not design errors — confirmed ✓
