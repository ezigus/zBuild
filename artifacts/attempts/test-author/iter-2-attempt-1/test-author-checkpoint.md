## What I read and key findings

- design.md: 7 SPECs for `core/state/run-cap.sh` (a count-based concurrent run cap)
  - Function: `zbuild_run_cap_admit <run_id> [state_file]`
  - Env vars: `ZBUILD_MAX_CONCURRENT_RUNS` (unset = no cap), `ZBUILD_NO_RUN_CAP=1` (bypass)
  - On block: sets `_ZBUILD_RUN_CAP_BLOCKERS`, emits to stderr
  - Slot dir: `$ZBUILD_STATE_ROOT/run-slots/` (by analogy to issue-lock `$ZBUILD_STATE_ROOT/locks/`)
  - Reap helper: `zbuild_run_cap_reap_stale` (called internally before counting)
  - WIRING: core/pipeline/runner.sh (from design.md)

- issue-lock.sh: reference for module contract (fail-open mkdir, reap-before-count, opt-out var)
- resume.sh: `zbuild_run_is_live(state_file)` — rc=0 if status=in_progress AND updated_at < 24h
- issue-lock-test.sh: pattern for test file — setup_test_env, _mk_state helper, subprocess calls
- ADR-059: §4 has the keyed mutex; §7 (to be added) is "Host-wide run cap, off unless configured"
- event-schema.json: needs `pipeline.refused.run_cap` added (currently absent)
- tests/unit/run-cap-test.sh: already written at 264 lines; needs 3 fixes:
  1. SPEC-1: uses 2>&1 combined — must separate stdout/stderr to assert both are empty
  2. SPEC-6: same issue — must capture stdout/stderr separately
  3. SPEC-7: need to check §7 is "under Decision" section, Enforced-by bullet contains test file,
     and all six SPEC statements (SPEC-1..SPEC-6) individually named in Enforced-by

## Conclusions

- Fix SPEC-1: redirect stdout/stderr separately, assert both empty
- Fix SPEC-6: redirect stdout/stderr separately, assert both empty
- Fix SPEC-7: awk to extract Decision section, check §7 within it;
  awk to extract Enforced-by section, check test file in a bullet and each SPEC-1..SPEC-6 named
- acceptance-gate finding 1: design says WIRING=runner.sh but that's implementation scope;
  my SPECs don't include a wiring test — answer: WIRING: none (not in SPEC contract)

## Status

Writing corrected tests/unit/run-cap-test.sh now.
