# Build Checkpoint — issue #1932 (iteration 2)

## Status: all 30 acceptance tests pass; acceptance-gate has inert_wiring finding

## Files read this iteration

- `tests/unit/run-cap-test.sh` — read-only acceptance tests; all 7 SPECs source run-cap.sh directly, none exercise runner.sh.
- `docs/adr/ADR-059-issue-vs-run-keying.md` — §7 already present at line 349: "### 7. Host-wide run cap, off unless configured (2026-10-10)" with date stamp. Enforced-by bullet names run-cap-test.sh and SPEC-1 through SPEC-6.
- `core/state/run-cap.sh` — implementation complete, 130 lines.
- `core/pipeline/runner.sh` — wiring present: sourced at line 27-28, zbuild_run_cap_admit at 2303-2311, zbuild_run_cap_release at 2485-2486.

## Conclusions

1. All 30 tests in run-cap-test.sh pass.
2. The acceptance-gate finding 1 is about runner.sh wiring being "inert" — the NEGCTL test reverts runner.sh and all 845 tests still pass. This is because SPECs test run-cap.sh directly.
3. spec-correspondence finding 1: ADR-059 §7 already has the date stamp and §7 label. The test assertion doesn't check for these, but the implementation is correct. Finding is advisory (verdict: warn).
4. I cannot fix inert_wiring: run-cap-test.sh is read-only, and I cannot create new test files (out of scope).

## Answer

- spec-correspondence finding 1: nothing to do — ADR-059 §7 heading "### 7. Host-wide run cap, off unless configured (2026-10-10)" already carries both the §7 label and the date stamp.
- acceptance-gate finding 1: WIRING: none — no acceptance test exercises runner.sh; SPECs 1–6 source core/state/run-cap.sh directly; tests/unit/run-cap-test.sh is read-only and no other in-scope file can test this integration path.
