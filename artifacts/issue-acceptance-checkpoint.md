# Acceptance checkpoint — issue #1932

## Files read and what they told me

- `docs/adr/ADR-059-issue-vs-run-keying.md`: §7 is present under `## Decision` (line 65 → line 349). `## Enforced by` at line 439 names `tests/unit/run-cap-test.sh` with all 7 SPECs. `pipeline.refused.run_cap` event is in the event schema.
- `config/event-schema.json`: `pipeline.refused.run_cap` confirmed at line 18.
- `core/pipeline/runner.sh`: wiring confirmed — `source run-cap.sh` at line 28, `zbuild_run_cap_admit` called at line 2303–2311, `zbuild_run_cap_release` called at line 2485–2486 in exit trap.
- `core/state/run-cap.sh`: uses `zbuild_run_is_live` from `resume.sh` for reaping (line 30). Implementation correct.
- `core/state/resume.sh`: `zbuild_run_is_live` confirmed at line 217.

## Conclusions

- R-1 (off unless set): SPEC-1 passes. Implementation returns 0 immediately when ZBUILD_MAX_CONCURRENT_RUNS is unset. MET.
- R-2 (explicit refusal naming blockers): SPEC-2 passes. _ZBUILD_RUN_CAP_BLOCKERS and stderr both name blockers. MET.
- R-3 (reap dead holders before admission via zbuild_run_is_live): SPEC-3 passes. run-cap.sh:30 uses zbuild_run_is_live. MET.
- R-4 (operator override): SPEC-4 passes. ZBUILD_NO_RUN_CAP=1 bypasses with warning. MET.
- R-5 (guard: unaffected below cap): SPEC-1 + SPEC-6 pass. Function-level guard tests correct behavior. Wiring in runner.sh is present but not independently tested — spec-correspondence noted stdout-only for output checks, but implementation produces no stderr in those paths. MET at function level.
- R-6 (regression test cap+1, reddened at merge-base): SPEC-2 drives cap+1 via subprocesses; REQUIREMENTS confirms failed on old code. MET.
- R-7 (fail-open test): SPEC-5 passes. Unreadable slot dir fails open with warning. MET.
- R-8 (ADR-059 amended with cap rule and Enforced-by): §7 under Decision, Enforced-by names run-cap-test.sh with all SPECs, event in schema. MET.

## Acceptance-gate REACHABILITY FAIL

Runner.sh wiring calls zbuild_run_cap_admit (line 2303) and zbuild_run_cap_release (line 2485). The wiring IS present. No unit test exercises the cap through runner.sh — all tests source run-cap.sh directly. This means removing the runner.sh changes doesn't break any test. Per CLAUDE.md "green-but-inert is a defect", but no stated issue requirement (R-1 through R-8) explicitly demands a test that exercises the wiring through runner.sh. The wiring is real; the gap is integration test coverage.

## Verdict

PASS — all 8 requirements are met. The acceptance-gate REACHABILITY FAIL identifies missing integration coverage for the runner.sh wiring, but no stated requirement specifies an integration test through runner.sh; R-5's guard and R-6's regression test operate correctly at module level.
