# Plan stage notes — issue #1801 (iter-2)

## What I read

- iter-1/plan.json — 10-step plan (written last iteration, verdict pass)
- Previous stage verdicts: build=incomplete (router_timeout, 39 files changed),
  test=fail (3 failures), spec-correspondence=partial (5 SPECs),
  shape-floor=fail (10 files), acceptance-gate=fail (SPEC-10),
  issue-acceptance=fail (R-2, R-10, R-13), design=incomplete (rate-limited),
  design-gate=fail (no scope/acceptance block)

## Findings vs. current plan

All three test failures are addressed by existing steps:

1. **monitor-mode leak** (`set -m` leaks into calling runner shell):
   - Step-4 says "scope process-group mode to the plugin subshell only"
   - ✅ covered

2. **SPEC-10 / hand-rolled kill** (`kill -KILL -- -"$_lc_hook_pid"` still in lifecycle.sh):
   - Step-4 says "remove the remaining hand-rolled kill -KILL line after wait and
     route all stage killing through zbuild_pg_kill"
   - ✅ covered

3. **SPEC-6b / process group kill incomplete** (child ignoring TERM still alive 5s):
   - Step-5 says "replace the hand-rolled TERM/KILL sequence with zbuild_pg_kill so
     a hook child that ignores TERM is killed within the grace window"
   - ✅ covered

All 5 partial SPECs from spec-correspondence are addressed by Step-1:
- SPEC-1: always_run and parallel-group routes → Step-1 ✅
- SPEC-3: isolation run for 5400s default → Step-1 ✅
- SPEC-7: live 300s+ dispatch completes → Step-1 ✅
- SPEC-9: unreadable-config path names backend in output → Step-1 ✅
- SPEC-18: event-schema-emitted-coverage-test passes → Step-1 ✅

shape-floor 10 files: → Step-10 ✅
ADR amendments: → Step-2 ✅

## Acceptance-criteria coverage check

All issue acceptance criteria map to steps:
- Hung run hook killed at limit, every route → Steps 3, 4, 5, 7
- Whole process group dies → Steps 4, 5, 6 (zbuild_pg_kill everywhere)
- Precedence: template > env > 90min, each tested → Step 3
- Loader rejects invalid stage_timeout_s → Step 3
- Retry and each map member get fresh timer → Step 4
- simple.yaml carries measured values; always_run uses stage_timeout_s → Step 9
- Strategies pass no flat ZBUILD_ORCH_TIMEOUT → Step 7
- orch-sequential gone, guard test, config naming it = misconfigured → Step 8
- Missing/unreadable backend = misconfigured, tested from installed tree → Step 8
- always_run and _orch_local_collect_results use zbuild_pg_kill → Steps 5, 6
- Scope discovery grep before writing tests → Step-1 prerequisite note
- ADR-054 §9, ADR-017, ADR-011 amended with Enforced-by entries → Step 2
- npm test + lint green → all steps collectively

## Assessment

The 10-step plan is complete and consistent. No step is inert (each is
connected to a test or live-code change). No step defers testing. No acceptance
criterion is unaddressed. The design-gate failure (no scope/acceptance block)
is a design-stage issue, not a plan issue — the plan itself names every touched
file and the SPECs that must pass. The two open questions stand.

## Plan: 10 steps — no changes required from iter-1
