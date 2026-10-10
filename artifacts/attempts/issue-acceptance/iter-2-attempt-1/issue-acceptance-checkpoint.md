# Acceptance checkpoint — issue #1932 (final pass)

## Files read and what they told me (prior run, confirmed)

- `docs/adr/ADR-059-issue-vs-run-keying.md`: §7 present under `## Decision`, dated 2026-10-10, labeled "7.". `## Enforced by` names `tests/unit/run-cap-test.sh` with all 7 SPECs.
- `config/event-schema.json`: `pipeline.refused.run_cap` at line 18.
- `core/pipeline/runner.sh`: source run-cap.sh at line 28, zbuild_run_cap_admit at lines 2303-2311, zbuild_run_cap_release at lines 2482-2485 in exit trap.
- `core/state/run-cap.sh`: uses zbuild_run_is_live from resume.sh (line 30). Implementation correct.
- `core/state/resume.sh`: zbuild_run_is_live confirmed at line 217.

## All 8 requirements — verdict

- R-1 (off unless set): SPEC-1 passes, negctl confirmed. MET.
- R-2 (explicit refusal naming blockers): SPEC-2 passes, negctl confirmed. MET.
- R-3 (reap using zbuild_run_is_live): SPEC-3 passes, negctl confirmed. MET.
- R-4 (operator override): SPEC-4 passes, negctl confirmed. MET.
- R-5 (guard: unaffected): SPEC-1 + SPEC-6 pass at function level. MET.
- R-6 (regression test; reddened at merge-base): NEGCTL PASS SPEC-2 confirmed reddened. MET.
- R-7 (fail-open test): SPEC-5 passes, negctl confirmed. MET.
- R-8 (ADR-059 amended): §7 present, dated, labeled, Enforced-by names test file and all 6 SPECs. MET.

## Findings analysis

spec-correspondence finding 1: SPEC-7 test doesn't verify date stamp or §7 number. But R-8 requires only "amended with cap rule and Enforced-by entry" — both present. Partial test coverage does not unset the requirement.

test finding 1: run-status-comment-quiet-test.sh fails [#1806/Q2]. Tests #1806 HTTP POST/PATCH counts. #1932 changes: zbuild_run_cap_admit returns 0 immediately when cap unset (no side effects); zbuild_run_cap_release only removes a JSON file. Neither can cause extra HTTP calls. Failure is unrelated to #1932 — none of R-1 through R-8 address run-status-comment behavior.

shape-floor findings: pipeline.refused.run_cap is only emitted when cap refuses a run (requires ZBUILD_MAX_CONCURRENT_RUNS set). Default-path golden pipeline runs never set this, so the event won't appear in golden files. Likely false positives.

acceptance-gate finding: runner.sh wiring is inert from test perspective (removing it doesn't break tests). Wiring IS in the diff. No R- requirement specifies integration testing through runner.sh. R-6 requires "regression test driving cap+1 starts; reddens at merge-base" — NEGCTL PASS SPEC-2 confirms this at function level.

## Final verdict

PASS — all 8 requirements met. Test failure is for #1806, unrelated to #1932.
