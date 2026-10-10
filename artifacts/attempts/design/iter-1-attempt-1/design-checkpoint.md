# Design checkpoint — issue #1932 host-wide run cap (resumed)

## Files read this session

- `ADR-059` — §4 is the keyed issue mutex; §4's own prose notes "host capacity is a counted cap" and cites #1932 explicitly. Already has `## Enforced by`. §7 will be the new cap section.
- `config/event-schema.json` — full known_types list reviewed. `pipeline.refused.issue_locked` exists. `pipeline.refused.run_cap` must be added. Golden-contracts-test only checks `plugin.(run|cleanup).complete` patterns — safe to add.
- `runner.sh:2295-2310` — issue lock acquire site. Cap admit goes BEFORE this block.
- `runner.sh:2461-2472` — issue lock release site in `_runner_abort_trap`. Cap release goes alongside `zbuild_issue_lock_release`.
- `issue-lock.sh` — structural model for run-cap.sh: ZBUILD_NO_ISSUE_LOCK=1 override, FD 201 for flock, sources resume.sh for zbuild_run_is_live, lock dir under ${ZBUILD_STATE_ROOT}/locks/.

## Conclusions

1. New module: `core/state/run-cap.sh` — mirrors issue-lock.sh
2. Off by default: ZBUILD_MAX_CONCURRENT_RUNS unset or 0 = no-op fast path
3. Override: ZBUILD_NO_RUN_CAP=1
4. Counting: marker files in `${ZBUILD_STATE_ROOT}/locks/run-cap/<run_id>`; reap with zbuild_run_is_live before counting
5. Fail-open: counting errors → warn + admit
6. Event: pipeline.refused.run_cap naming blockers
7. WIRING: core/pipeline/runner.sh (admit before issue lock; release alongside issue lock release)
8. No supersedes needed (cap is entirely new behavior)
9. Scope: 6 files total (4 existing modified + 2 new)

## Design.md — written.
