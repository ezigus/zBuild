# Plan stage notes — issue #1801 (iter-3)

## What I read

- iter-2/plan.json — 10-step plan (verdict: pass from iter-2 plan stage)
- Build stage: incomplete (router_timeout), 39 files changed over 4 passes/12 iterations
- Test stage: fail — 3 failures:
  1. `flag-on: monitor mode ON in runner shell` (set -m leaks from plugin_hook_call into runner shell)
  2. `[SPEC-6b] a hook child that ignores TERM does not outlive the run` (process group kill incomplete)
  3. `[#1801/SPEC-10] plugin_hook_call has no hand-rolled TERM/KILL for stage dispatch`
     (kill -KILL -- -"$_lc_hook_pid" still present in lifecycle.sh)
- Issue-acceptance: fail — R-2, R-10, R-13 (the same 3 test failures)

## Findings vs. current plan

The build was cut short by router_timeout, meaning Steps 4 and 5 were not fully applied yet.
All three test failures trace to exactly those two steps:

1. **monitor-mode leak** (`set -m` leaks into calling runner shell):
   - Step-4: "scope process-group mode to the plugin subshell only"
   - ✅ covered

2. **SPEC-10 / hand-rolled kill** (`kill -KILL -- -"$_lc_hook_pid"` still in lifecycle.sh):
   - Step-4: "remove the remaining hand-rolled kill -KILL line after wait and route all
     stage killing through zbuild_pg_kill"
   - ✅ covered

3. **SPEC-6b / process group kill incomplete** (child ignoring TERM still alive 5s):
   - Step-5: "replace the hand-rolled TERM/KILL sequence with zbuild_pg_kill so a hook
     child that ignores TERM is killed within the grace window"
   - ✅ covered

## Assessment

The 10-step plan is correct and complete. All three open test failures map to
incomplete work within existing steps (4 and 5); no structural change is needed.

Every acceptance criterion from the issue is covered:
- Hung run hook killed at limit, every route → Steps 3, 4, 5, 7
- Whole process group dies → Steps 4, 5, 6
- Precedence: template > env > 90min, each tested → Step 3
- Loader rejects invalid stage_timeout_s → Step 3
- Retry and each map member get fresh timer → Step 4
- simple.yaml carries measured values; always_run uses stage_timeout_s → Step 9
- Strategies pass no flat ZBUILD_ORCH_TIMEOUT → Step 7
- orch-sequential gone, guard test, config naming it = misconfigured → Step 8
- Missing/unreadable backend = misconfigured, tested from installed tree → Step 8
- always_run and _orch_local_collect_results use zbuild_pg_kill → Steps 5, 6
- ADR-054 §9, ADR-017, ADR-011 amended with Enforced-by entries → Step 2
- npm test + lint green → all steps collectively

No step is inert. No acceptance criterion is unaddressed. Two open questions stand.

## Plan: 10 steps — no changes required from iter-2
