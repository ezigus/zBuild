# Design notes — issue #1801 (final refinement)

## Previous state summary
Build ran 39 file changes. Three tests still fail (same root causes as before).

## Root causes confirmed (unchanged from previous notes)

### 1. stage-timeout-dispatch-test.sh [#1801/SPEC-10]
lifecycle.sh line 525: `kill -KILL -- -"$_lc_hook_pid" 2>/dev/null || true`
Design says to replace with `zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true`.
Build missed this change. SPEC-10 / Decision point 2 already covers it.

### 2. runner-release-exit-paths-test.sh [SPEC-6b]
TERM trap in plugin_hook_call's run-hook branch not implemented.
When `_runner_dispatch_always_run` outer watchdog TERMs plugin_hook_call, bash exits
(no trap), inner hook group (_lc_hook_pid) is orphaned. Fix: add TERM trap at the
start of the run-hook branch that kills _lc_hook_pid's group immediately.
Design already covers this in Decision point 1 and supersedes SPEC-6b.

### 3. runner-job-control-abort-test.sh T1 flag-on
Probe runs inside hook subshell which has `set +m` (lifecycle.sh:504). `$-` inside
the hook never has 'm'. Supersedes block covers this: assertion must be a structural
check (grep lifecycle.sh/runner.sh for `set -m`), not a runtime probe.

## Spec-coverage findings addressed

### R-1 parallel-group member
The parallel-group member dispatch is at runner.sh:3106:
  `set +e; plugin_hook_call "$_pd_plugin_dir" run ...`
Adding "parallel-group member" to SPEC-1's route list.
Per-backend verification: watchdog is in plugin_hook_call (above backend layer);
SPEC-1 clarifies this means all backends are covered by the same watchdog.

### R-8 fixture migration
No test currently configures orch-sequential as a live backend fixture.
The guard test (SPEC-8) already covers this: "no file outside docs/adr names
orch-sequential" catches any fixture still using it. Adding SPEC-17[no-code] to
make this explicit in the contract.

### R-9 installed tree
The orch-backend-misconfigured test says "tested from the installed tree" but
sources from $REPO_ROOT. Adding SPEC-19[no-code]: test must include a variant
that sources contract.sh from an install.sh-produced path (temp install in
the test's tmp dir, sourcing from $ZBUILD_HOME/core/orch/contract.sh after
rsync), verifying behavior is identical post-install.

## Spec-correspondence findings addressed

### SPEC-1: always_run and parallel-group member routes
always_run calls plugin_hook_call at runner.sh:2477.
parallel-group calls plugin_hook_call at runner.sh:3106.
Both are now listed in SPEC-1's route enumeration.

### SPEC-3: tier-3 default
Strengthened: tier-3 test runs a subshell with neither _TPL_STAGE_TIMEOUT_S_*
nor ZBUILD_STAGE_TIMEOUT_S set and confirms the watchdog uses 5400 s.

### SPEC-7: runtime completion
Strengthened: test spawns a hook that sleeps 310 s (inside stage_timeout_s=3600)
and verifies it completes (exit 0), not just checks ZBUILD_ORCH_TIMEOUT absence.

### SPEC-9: unreadable-config names backend
The unreadable-config case falls through to "not found" logic in contract.sh
which includes backend name in warn() and emit_event(). Test must also check
`grep -q 'bad-backend' <<< "$_out4"` to match the requirement.

### SPEC-18: coverage test must pass
Strengthened: event-schema-emitted-coverage-test must pass (existing events
remain registered), not just that the two new types are listed.

## Files verified in worktree
- lifecycle.sh: TERM trap absent (build gap) — SPEC-2/supersedes-SPEC-6b
- lifecycle.sh line 525: kill -KILL still present (build gap) — SPEC-10
- runner.sh lines 2486-2487: kill -KILL/-TERM still present — SPEC-10
- orch-backend-misconfigured-test.sh: unreadable case checks only exit code
- runner-job-control-abort-test.sh: T1 still probes $- (runtime probe)
- parallel-group dispatch confirmed at runner.sh:3106 via plugin_hook_call
- orch-sequential: no live fixture uses; guard catches any survivors
- contract.sh orch_load_backend: names backend in warn() for all failure paths
