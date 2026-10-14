# Design notes — issue #1801 (retry)

## Previous notes summary
Previous build ran (39 files changed). Three tests still fail.

## Root causes confirmed

### 1. stage-timeout-dispatch-test.sh SPEC-10
lifecycle.sh line 525: `kill -KILL -- -"$_lc_hook_pid" 2>/dev/null || true`
Test greps for kill -KILL / kill -TERM in plugin_hook_call body.
Fix: replace with `zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true`

### 2. runner-release-exit-paths-test.sh SPEC-6b
Outer watchdog in _runner_dispatch_always_run kills `plugin_hook_call` (the _ar_pid
process) via TERM. Bash exits on TERM (no trap). The inner hook group (_lc_hook_pid)
is orphaned. The inner watchdog fires late. Fix: TERM trap inside the run-hook branch
of plugin_hook_call that kills _lc_hook_pid group before exiting.

### 3. runner-job-control-abort-test.sh T1 flag-on
Plugin subshell always has `set +m` now. The T1 probe records $- inside the plugin.
$- never has m. Fix: update T1 assertion to structural check (grep runner.sh/lifecycle.sh).

## SPEC-6b deeper analysis
_runner_dispatch_always_run outer watchdog: zbuild_pg_kill "$_ar_pid" 10
  → TERM to _ar_pid's group (only plugin_hook_call process, since _lc_hook_pid is
    a separate group created by set -m inside plugin_hook_call)
  → plugin_hook_call receives TERM, bash exits (default TERM action)
  → _lc_hook_pid's group orphaned

Inner watchdog: (set +m; sleep 30; zbuild_pg_kill "$_lc_hook_pid" 10 ...) &
  → still alive (in its own group), fires 30s after dispatch
  → TERM to _lc_hook_pid group, wait 10s, KILL
  → child dies at ~40s after dispatch start

Runner returns at ~30s (after _ar_pid dies). Test polls for 5s (30-35s).
Child alive at 35s → SPEC-6b fails.

Fix: trap TERM in plugin_hook_call run-hook branch:
trap 'zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true; ...' TERM
This kills the inner group immediately when plugin_hook_call receives TERM from the outer watchdog.

## Design document structure
design.md written to /home/runner/work/_temp/zbuild-state/artifacts/design.md.
Complete scope and acceptance blocks covering R-1..R-13 with 18 SPECs.
Supersedes block covers runner-job-control-abort-test.sh flag-on and SPEC-6b.
