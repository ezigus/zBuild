## What I read and key findings

- design.md: 7 SPECs for `core/state/run-cap.sh` (a count-based concurrent run cap)
  - Function: `zbuild_run_cap_admit <run_id> [state_file]`
  - Env vars: `ZBUILD_MAX_CONCURRENT_RUNS` (unset = no cap), `ZBUILD_NO_RUN_CAP=1` (bypass)
  - On block: sets `_ZBUILD_RUN_CAP_BLOCKERS`, emits to stderr
  - Slot dir: `$ZBUILD_STATE_ROOT/run-slots/` (by analogy to issue-lock `$ZBUILD_STATE_ROOT/locks/`)
  - Reap helper: `zbuild_run_cap_reap_stale` (called internally before counting)

- issue-lock.sh: reference for module contract (fail-open mkdir, reap-before-count, opt-out var)
- resume.sh: `zbuild_run_is_live(state_file)` — rc=0 if status=in_progress AND updated_at < 24h
- issue-lock-test.sh: pattern for test file — setup_test_env, _mk_state helper, subprocess calls
- ADR-059: §4 has the keyed mutex; §7 (to be added by this issue) is "Host-wide run cap, off unless configured"
- event-schema.json: needs `pipeline.refused.run_cap` added (currently absent)

## Conclusions

- Test file: `tests/unit/run-cap-test.sh` (new, doesn't exist yet)
- Pre-create live slot files using `_cap_admit_subprocess` helper (call zbuild_run_cap_admit in a subprocess; slot file persists after exit since no exit trap in module)
- For SPEC-3: create 1 live + 1 stale slot; cap=2; expect admission to succeed (1 live after reap < 2)
- For SPEC-5: chmod 000 on `$ZBUILD_STATE_ROOT/run-slots` before call; restore before cleanup
- Each SPEC uses its own ZBUILD_STATE_ROOT subdir to avoid state bleed

## Status

Writing tests/unit/run-cap-test.sh now (in progress).
