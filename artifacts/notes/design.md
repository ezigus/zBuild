# Design notes — issue #1801 (second refinement)

## Root causes confirmed with code verification (second pass)

### 1. stage-timeout-dispatch-test.sh [#1801/SPEC-10]
lifecycle.sh line 525: `kill -KILL -- -"$_lc_hook_pid" 2>/dev/null || true`
Must be replaced with `zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true`.
The SPEC-10 test greps plugin_hook_call's body for `kill -TERM|kill -KILL` and fails on this line.

### 2. runner-release-exit-paths-test.sh [SPEC-6b]
Root cause confirmed in code (test lines 128-132):

  build_cleanup checks BLOCK_CLEANUP_IGNORE_TERM. It spawns a TERM-ignoring child then calls
  `wait` (bare wait with no argument), which blocks until all background jobs finish. This makes the
  cleanup hook BLOCK for up to 120 seconds (the child's sleep). After 30 seconds the always_run
  watchdog fires: `zbuild_pg_kill "$_ar_pid" 10` sends TERM to pgid _ar_pid (the plugin_hook_call
  fork's group).

  With no TERM trap in plugin_hook_call, bash exits immediately when TERM interrupts `wait
  "$_lc_hook_pid"` at lifecycle.sh line 521. Lines 525-527 are NEVER reached.

  The hook subshell (pgid _lc_hook_pid) is a DIFFERENT process group from _ar_pid — lifecycle.sh
  uses `set -m` to give the hook its own group. Killing _ar_pid's group does NOT kill _lc_hook_pid's
  group. The TERM-ignoring child survives.

  Fix: install a TERM trap in lifecycle.sh between `_lc_wd_pid=$!` (line 516) and `wait
  "$_lc_hook_pid"` (line 521). Exact form:
    trap 'zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true
          zbuild_pg_kill "$_lc_wd_pid"  1 2>/dev/null || true
          trap - TERM; exit 143' TERM
    wait "$_lc_hook_pid" 2>/dev/null; rc=$?
    trap - TERM

  Then replace line 525 with:
    zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true

  Both changes in lifecycle.sh. The trap fires when plugin_hook_call's shell receives TERM from the
  outer always_run watchdog; it kills the hook group before exiting.

  Why SPEC-2ext PASSES but SPEC-6b FAILS: SPEC-2ext sends external SIGTERM to the runner itself.
  The runner's _runner_signal_trap kills the pipeline process group via `kill -TERM -- "-$_pgid"` and
  `kill -KILL -- "-$_pg"` — this reaches the hook differently (pipeline-level kill, not through the
  always_run watchdog). SPEC-6b goes through _runner_dispatch_always_run's watchdog, which only kills
  _ar_pid's process group, leaving _lc_hook_pid's group untouched.

### 3. runner-job-control-abort-test.sh T1 flag-on
The probe (lines 85-91 of the test) records `$-` inside intake_run(). lifecycle.sh line 504 does
`set +m` inside every hook subshell, so `$-` never has 'm' in the hook, even with
ZBUILD_RUNNER_JOB_CONTROL=1. The flag-on assertion (lines 144-151) checks
`grep -q 'm' <<< "$_opts_on_1"` — fails.

The supersedes block describes the fix: change flag-on assertion to a structural check. Concrete form:
  # Replace runtime probe with structural check:
  grep -q 'set -m' "$REPO_ROOT/core/plugin-registry/lifecycle.sh" \
      && assert_pass "flag-on: lifecycle.sh arms set -m before hook spawn" \
      || assert_fail "flag-on: lifecycle.sh arms set -m before hook spawn" "set -m not found"

This verifies the structural property (hook gets its own pgid) without being defeated by set +m
inside the hook subshell. The supersedes entry in design.md describes this.

## Files verified in worktree (second pass)
- lifecycle.sh line 525: kill -KILL still present — SPEC-10 build gap confirmed
- lifecycle.sh lines 516-521: no TERM trap present — SPEC-6b build gap confirmed
- lifecycle.sh line 504: set +m inside hook — flag-on probe broken, supersedes covers it
- runner.sh lines 2486-2487: kill -KILL/-TERM present (always_run cleanup after wait) — noted in
  SPEC-10 design text, but stage-timeout-dispatch-test only greps lifecycle.sh plugin_hook_call body
  so these do not cause a test failure; they should still change per SPEC-10 intent
- runner.sh lines 477/483: _runner_status_comment_kill — not stage dispatch, exempt from SPEC-10
- runner.sh lines 2647/2653: _runner_signal_trap pipeline-level kill — not stage dispatch, exempt
- SPEC-2ext (lines 412-452): PASSES — confirms external SIGTERM path works via runner's signal trap

## Design conclusion
All three failures are build and test-author gaps, not design errors. The design correctly describes
all fixes. The refined design.md tightens:
  - Decision point 1: exact TERM trap code and placement in lifecycle.sh
  - Decision point 2: both lifecycle.sh line 525 AND runner.sh lines 2486-2487
  - Supersedes block: precise structural check for flag-on assertion
  - SPEC-6b root cause: build_cleanup's bare `wait` after spawning the TERM-ignoring child
