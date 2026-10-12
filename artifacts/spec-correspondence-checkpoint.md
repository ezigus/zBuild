# Spec-Correspondence Checkpoint

## Files read
- tests/unit/stage-timeout-dispatch-test.sh (SPEC-1, SPEC-10)
- tests/unit/stage-timeout-always-run-test.sh (SPEC-6, SPEC-10)
- tests/unit/stage-timeout-process-group-test.sh (SPEC-2)
- tests/unit/stage-timeout-precedence-test.sh (SPEC-3)
- tests/unit/stage-timeout-loader-validation-test.sh (SPEC-4)
- tests/unit/stage-timeout-retry-test.sh (SPEC-5)
- tests/unit/stage-timeout-no-flat-limit-test.sh (SPEC-7)
- tests/unit/orch-sequential-retired-guard-test.sh (SPEC-8, SPEC-11)
- tests/unit/orch-backend-misconfigured-test.sh (SPEC-9)
- tests/unit/event-schema-emitted-coverage-test.sh (SPEC-18)

## Key findings

SPEC-6 REVISED: corresponds — full test file (lines 90-110) shows ALL explicit _check_stage_timeout calls for every named stage; snippet in problem was truncated.

SPEC-10 REVISED: corresponds — dispatch test checks no hand-rolled TERM/KILL in plugin_hook_call; always-run test checks _runner_dispatch_always_run uses zbuild_pg_kill; local_engine.sh verified via _orch_local_kill_slot absence + zbuild_pg_kill presence.

SPEC-2: partial — external-SIGTERM path (runner signal handler kills hook group) is NOT tested; test comment says "behavioral guarantee enforced by SPEC-6b in integration test".

SPEC-9: partial — "config is unreadable" case not tested; only unknown-alias + empty-plugins-root "cannot be found" cases covered.

## Final verdicts (all SPECs)
SPEC-1: partial
SPEC-2: partial
SPEC-3: partial
SPEC-4: corresponds
SPEC-5: corresponds
SPEC-6: corresponds
SPEC-7: partial
SPEC-8: corresponds
SPEC-9: partial
SPEC-10: corresponds
SPEC-11: corresponds
SPEC-18: corresponds

## Status: complete
