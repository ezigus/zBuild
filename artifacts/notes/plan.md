# Plan stage notes — issue #1801

## What I read

- iter-0-attempt-1/plan.json — 9-step previous plan (valid, verdict pass)
- design.md — full design with SPECs, scope
- Previous stage verdicts: build=incomplete (router_timeout), test=fail (3 failures),
  spec-correspondence=partial (5 SPECs), shape-floor=fail (10 files), acceptance-gate=fail (SPEC-10),
  issue-acceptance=fail (R-2, R-10, R-13)

## Root causes of test failures

1. **SPEC-10 / hand-rolled kill**: lifecycle.sh still has `kill -KILL -- -"$_lc_hook_pid"`
   directly instead of zbuild_pg_kill. Step-4 fix: remove that line.

2. **SPEC-6b / process group kill incomplete**: hook child ignoring TERM still alive 5s
   after runner returned. Step-5 fix: replace hand-rolled watchdog with zbuild_pg_kill
   in runner.sh always_run path.

3. **Monitor mode leak**: `set -m` leaked into the calling runner shell scope.
   Step-4 fix: scope process-group flag to plugin subshell only.

## spec-correspondence gaps (5 partial SPECs)

- SPEC-1: always_run and parallel-group routes not verified
- SPEC-3: 5400s default not tested by isolation run (only grep-for-literal)
- SPEC-7: 300s+ dispatch completing not demonstrated live
- SPEC-9: unreadable-config path only checks exit code, not backend name in output
- SPEC-18: event-schema-emitted-coverage-test not confirmed passing

## shape-floor gaps: 10 files still pin old counts/lists

## ADR amendments: SPEC-11 skipped as no_code (not yet done)

## Plan: 10 steps

Keep original steps 3, 6, 7, 8, 9 — no failures against them.
Revise steps 1, 4, 5 for open bugs/partials.
Keep step 2 (ADR amendments — not done yet).
Add step 10 for shape-floor files.
