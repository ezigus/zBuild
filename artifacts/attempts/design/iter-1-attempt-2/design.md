# Design: Host-wide concurrent run cap (issue #1932)

## Architectural decision summary

**Goal.** Add a configurable, off-by-default, host-wide counted cap on concurrent pipeline
runs: when more than N runs are live on one host, the next admission attempt refuses
explicitly, emits a refusal message naming the blockers, and returns 1. Dead holders are
reaped before counting using the same predicate ADR-059 §4 already uses
(`zbuild_run_is_live`). The cap fails open. An operator override bypasses it entirely.

**Context.** ADR-059 §4 serialises concurrent same-issue runs with a keyed mutex
(`core/state/issue-lock.sh`). That decides _which_ issue can run; it says nothing about
_how many_ runs the host can support simultaneously. `issue-lock.sh:22–24` already names
this gap: *"NOT A CAPACITY CAP … zBuild still lacks it (#1932). Issue exclusivity is a keyed
mutex; host capacity is a counted cap."* ADR-059 §4 also cites the legacy control directly:
`legacy-DoNotUse/scripts/sw-pipeline.sh:325` had a flat PID-keyed count, fail-on-exceed,
dead-holder reap — the same shape this issue now brings to zBuild.

**Decision.** Introduce `core/state/run-cap.sh` as a new state module following the same
structural contract as `issue-lock.sh` (fail-open mkdir, reap-before-count, explicit opt-out
env var, explicit release in the exit trap). Integrate three call sites in
`core/pipeline/runner.sh`: source the module alongside `issue-lock.sh` (runner.sh:25–26),
call `zbuild_run_cap_admit` before the issue lock acquire (runner.sh:2302 — cap is the
coarser resource gate; fail fast), and call `zbuild_run_cap_release` in
`_runner_abort_trap` (runner.sh:2461) alongside `zbuild_issue_lock_release`.
Amend ADR-059 with a new §7. Add `pipeline.refused.run_cap` to `config/event-schema.json`.

**Race window.** On hosts without `flock`, two runs starting simultaneously can both pass a
cap of 1 (count-then-write race). This mirrors the no-flock weakness already stated and
accepted in `issue-lock.sh:141–149`, and is documented in §7 rather than hidden.

```scope
core/state/run-cap.sh
core/pipeline/runner.sh
core/state/resume.sh
core/state/issue-lock.sh
docs/adr/ADR-059-issue-vs-run-keying.md
config/event-schema.json
tests/unit/run-cap-test.sh
```

```acceptance
SPEC-1[code]: when ZBUILD_MAX_CONCURRENT_RUNS is unset zbuild_run_cap_admit returns 0, writes no slot file, and produces no cap-related output covers: R-1 R-5
SPEC-2[code]: with cap N set and N live slot files present zbuild_run_cap_admit returns 1, sets _ZBUILD_RUN_CAP_BLOCKERS naming each blocking run_id, and emits a refusal message to stderr that names every blocker covers: R-2 R-6
SPEC-3[code]: a slot whose state file fails zbuild_run_is_live is removed by zbuild_run_cap_reap_stale before counting so it does not block admission covers: R-3
SPEC-4[code]: ZBUILD_NO_RUN_CAP=1 causes zbuild_run_cap_admit to return 0 and emit a warning regardless of cap value and live slot count covers: R-4
SPEC-5[code]: when the slot directory is unreadable zbuild_run_cap_admit warns on stderr and returns 0 admitting the run covers: R-7
SPEC-6[code]: with cap N set and fewer than N live slot files present zbuild_run_cap_admit returns 0, writes a slot file for the current run, and produces no cap-related output covers: R-5
SPEC-7[no-code]: ADR-059 gains dated §7 "Host-wide run cap, off unless configured" under Decision and an Enforced-by bullet naming tests/unit/run-cap-test.sh and its six spec statements; pipeline.refused.run_cap is added to config/event-schema.json covers: R-8
WIRING: core/pipeline/runner.sh
TESTFILES:
SPEC-1: tests/unit/run-cap-test.sh
SPEC-2: tests/unit/run-cap-test.sh
SPEC-3: tests/unit/run-cap-test.sh
SPEC-4: tests/unit/run-cap-test.sh
SPEC-5: tests/unit/run-cap-test.sh
SPEC-6: tests/unit/run-cap-test.sh
SPEC-7: tests/unit/run-cap-test.sh
```

LOOP_COMPLETE
