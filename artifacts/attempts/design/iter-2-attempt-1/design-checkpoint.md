# Design checkpoint — issue #1932 host-wide run cap (iteration 2, final)

## Files read this session

- `ADR-059` — §4 is the keyed issue mutex; §4's own prose notes "host capacity is a counted cap" and cites #1932 explicitly. Already has `## Enforced by`. §7 will be the new cap section.
- `config/event-schema.json` — full known_types list reviewed. `pipeline.refused.issue_locked` exists. `pipeline.refused.run_cap` must be added. Golden-contracts-test only checks `plugin.(run|cleanup).complete` patterns — safe to add.
- `runner.sh:2287-2310` — issue lock acquire site. Cap admit goes BEFORE this block.
- `runner.sh:2461-2472` — issue lock release site in `_runner_abort_trap`. Cap release goes alongside `zbuild_issue_lock_release`.
- `issue-lock.sh` — structural model for run-cap.sh: ZBUILD_NO_ISSUE_LOCK=1 override, FD 201 for flock, sources resume.sh for zbuild_run_is_live, lock dir under ${ZBUILD_STATE_ROOT}/locks/.
- `tests/unit/issue-lock-test.sh` — structural model for run-cap-test.sh.
- `tests/golden/golden-contracts-test.sh` — only validates plugin.(run|cleanup).complete events from event-schema.json; adding pipeline.refused.run_cap does not break it.

## Conclusions

1. New module: `core/state/run-cap.sh` — mirrors issue-lock.sh
2. Off by default: ZBUILD_MAX_CONCURRENT_RUNS unset or 0 = no-op fast path
3. Override: ZBUILD_NO_RUN_CAP=1
4. Counting: marker files in `${ZBUILD_STATE_ROOT}/locks/run-cap/<run_id>`; reap with zbuild_run_is_live before counting
5. Fail-open: counting errors → warn + admit
6. Event: pipeline.refused.run_cap naming blockers
7. WIRING: core/pipeline/runner.sh (admit before issue lock; release alongside issue lock release)
8. No supersedes needed (cap is entirely new behavior)
9. Scope: 7 files total (4 existing modified + 2 new + 1 referenced)

## Spec-coverage findings addressed

**Finding 1**: SPEC-2 now requires a refusal message emitted to stderr naming blockers (the "explicit" half of R-2).

**Finding 2+3**: SPEC-1 covers no-cap (ZBUILD_MAX_CONCURRENT_RUNS unset) path for R-5.
New SPEC-6[code] covers "cap set, count below cap, run admitted, no cap-related output" for the other half of R-5.

## Design.md — WRITTEN (final).
