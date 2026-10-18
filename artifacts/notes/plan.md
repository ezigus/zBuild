# Plan stage notes — issue #1801 (iter-4)

## What I read

- iter-3/plan.json — 10-step plan (verdict: pass from iter-3 plan stage)
- test-author: fail — 1 finding (SPEC-1 always_run route not individually asserted)
- Build stage: timed_out (router_timeout), only 2 files changed in final run; iter-1-attempt-4 had 39 files
- Test stage: fail — 3 failures (same as iter-3):
  1. `flag-on: monitor mode ON in runner shell` (set -m leaks from plugin_hook_call)
  2. `[SPEC-6b] a hook child that ignores TERM does not outlive the run`
  3. `[#1801/SPEC-10] plugin_hook_call has no hand-rolled TERM/KILL for stage dispatch`
- Issue-acceptance: fail — R-2, R-10, R-13 (same 3 test failures)

## New finding vs. current plan

**test-author finding (new):** SPEC-1 in `stage-timeout-dispatch-test.sh` covers the
always_run route via a file-level grep on `runner.sh` only. That grep passes whether or
not `_runner_dispatch_always_run` specifically calls `plugin_hook_call`, so the route is
not individually established.

Current Step 1 says: "verify the always_run and parallel-group dispatch routes reach the
watchdog (SPEC-1)". The finding confirms the always_run gap is real — the step already
names it. The description needs to be sharpened to state that the assertion must
individually target `_runner_dispatch_always_run` (not rely on a file-level grep that
passes for any call in runner.sh).

test-author did NOT flag the parallel-group route as a gap, so the open question about
that route can be closed.

## Remaining test failures

All three failures are unchanged and map to Steps 4 and 5, which were not fully applied
because the build was cut short at router_timeout:

1. monitor-mode leak → Step 4 (scope set -m to plugin subshell)
2. SPEC-10 hand-rolled kill -KILL in lifecycle.sh → Step 4 (remove, route through zbuild_pg_kill)
3. SPEC-6b child ignoring TERM survives → Step 5 (replace watchdog TERM/KILL with zbuild_pg_kill)

## Plan changes

- **Step 1**: tighten the always_run assertion description — the test must individually
  verify the dispatch function rather than rely on a file-level grep that does not distinguish
  the always_run path from any other call in runner.sh.
- **Open questions**: drop the parallel-group route question (test-author found no gap there);
  keep the SPEC-7 live-completion question (build was cut short before it could be verified).

## Acceptance coverage check (unchanged from iter-3)

- Hung run hook killed at limit, every route → Steps 3, 4, 5, 7
- Whole process group dies → Steps 4, 5, 6
- Precedence: template > env > 90 min, each tested → Step 3
- Loader rejects invalid stage_timeout_s → Step 3
- Retry and each map member get fresh timer → Step 4
- simple.yaml carries measured values; always_run uses stage_timeout_s → Step 9
- Strategies pass no flat ZBUILD_ORCH_TIMEOUT → Step 7
- orch-sequential gone, guard test, config naming it = misconfigured → Step 8
- Missing/unreadable backend = misconfigured, tested from installed tree → Step 8
- always_run and _orch_local_collect_results use zbuild_pg_kill → Steps 5, 6
- ADR-054 §9, ADR-017, ADR-011 amended with Enforced-by entries → Step 2
- npm test + lint green → all steps collectively

## Plan: 10 steps — Step 1 description updated; one open question resolved
