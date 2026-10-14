# Design — Issue #1944: run-level wall-clock limit

## Architectural decision

**Goal.** Enforce a per-run wall-clock ceiling so no pipeline run is unbounded.

**Context.** Only per-stage `router.timeout_s` knobs existed. A deadlock
between stages or a slow stage without a per-stage limit can run indefinitely.
CI platforms carry their own job ceilings; the engine must enforce its own
without reading platform variables (R-8).

**Decision.**

1. **Limit resolution** (`_runner_resolve_run_limit_s` in
   `scripts/lib/stage-limits.sh`): template top-level `max_run_s:` key
   (via `template_max_run_s()` in `core/pipeline/template.sh`) >
   `ZBUILD_MAX_RUN_S` env > 20700 s default. A non-integer or non-positive
   value in either source is misconfigured; the runner exits 1 before any
   stage runs.

2. **Watchdog.** A background subshell is armed in `main()` after the traps
   are installed. It sleeps for the resolved limit, writes `timed_out` to the
   abort sentinel (first-wins semantics), then sends SIGTERM to the runner's
   process group. After a 10-second grace it sends SIGKILL to the runner's
   child processes (not the runner itself, so the runner's deferred SIGTERM
   trap can fire and exit with rc=1, which lets the EXIT trap dispatch
   `always_run` stages). The watchdog ignores SIGTERM so it survives its own
   PG-wide TERM and can escalate to KILL. Raw kill (not `zbuild_pg_kill`)
   because the watchdog is in the runner's own process group, which
   `zbuild_pg_kill` refuses.

3. **EXIT trap kills watchdog on clean exit.** The runner's EXIT trap must
   send SIGKILL to `_RUNNER_WATCHDOG_PID` before the runner process exits.
   **This is the root cause of the three integration-test timeouts** in the
   previous build pass: the abort trap kills the watchdog, but without an
   EXIT-trap kill, a cleanly-exiting runner leaves the watchdog sleeping for
   up to 20700 s as an orphan in the test harness's session; test phases that
   invoke the runner wait for it and hang past 480 s.

4. **New abort word and pipeline status.** `timed_out` is the seventh abort
   word (ADR-025) and a new pipeline status (ADR-006, ADR-015). A
   `timed_out` state is `manual_resume_only` (resume.sh). A resumed run
   receives a fresh watchdog armed from its own wall-clock start.

5. **Always-run stages (release, persist) still execute** via
   `_runner_dispatch_always_run` in the abort trap, which fires before the
   timed_out path writes the final state.

## Bugs from the previous build pass that the implementation must fix

| Bug | Effect | Fix |
|-----|--------|-----|
| EXIT trap does not kill watchdog | integration tests time out (core-pipeline-runner, core-pipeline-strategy, vision-admission-gate) | add `kill -KILL "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null \|\| true` to runner EXIT trap |
| `VAR=val \( subshell \)` syntax | run-limit-precedence-test.sh line 173 crashes | use `( VAR=val bash "$RUNNER" ... )` — assign inside the subshell |
| `set +e; ...; set -e` mid-file | lint-test-errexit rejects 8 occurrences in 4 files | files have `set -uo pipefail` (no `-e`) — drop both `set` calls; `rc=$?` captures non-zero without exiting |
| P4 tests release only | R-4 "persist" requirement unmet | add a `persist` role stage to the `timeout-with-release` template's `always_run` list and assert its marker |
| P2 assert_pass in both branches | R-2 sub-requirement unfalsifiable | remove the if/else with two assert_pass branches; the `assert_eq ... status=timed_out` already covers R-2 |
| run-open-items.sh change untested at unit level | reachability check fails | add a unit assertion in run-open-items-test.sh for `run_end_words "timed_out" 0` output |
| WIRING declared as template.sh | acceptance-gate finds it inert | WIRING is `core/pipeline/runner.sh`; template.sh's new function is reachable via runner.sh → stage-limits.sh → template.sh |

```scope
config/adr-enforcement-baseline.txt
core/pipeline/runner.sh
core/pipeline/template.sh
core/state/resume.sh
docs/adr/ADR-006-resume-contract.md
docs/adr/ADR-015-stage-io-capture.md
docs/adr/ADR-025-abort-propagation.md
docs/adr/ADR-054-stage-contract.md
scripts/lib/abort-propagation.sh
scripts/lib/run-open-items.sh
scripts/lib/stage-limits.sh
tests/golden/full-pipeline/event-sequence.golden
tests/golden/parity/event-sequence.golden
tests/golden/pipeline-end/timed_out-w80.colored.txt
tests/golden/pipeline-end/timed_out-w80.layout.txt
tests/integration/resume-after-run-timeout-test.sh
tests/integration/run-timed-out-test.sh
tests/unit/abort-propagation-test.sh
tests/unit/run-limit-precedence-test.sh
tests/unit/run-open-items-test.sh
tests/unit/run-watchdog-clean-exit-test.sh
tests/unit/runner-pipeline-end-test.sh
```

```acceptance
SPEC-1[code]: a run whose wall-clock time exceeds max_run_s ends with pipeline status timed_out in pipeline-state.json; pipeline.end carries status=timed_out, the in-flight stage name, and limit_s; the watchdog fires even when the engine is idle between dispatches (not only inside a stage); a stage that ignores SIGTERM is dead within TERM+10 s; release and persist always_run stages both execute on the timed-out exit path covers: R-1 R-2 R-3 R-4
SPEC-2[code]: _runner_resolve_run_limit_s resolves template max_run_s > ZBUILD_MAX_RUN_S > 20700; a non-integer or non-positive value in either source causes the runner to exit 1 with a message naming the misconfigured source before any stage dispatch covers: R-5
SPEC-3[code]: a run that finishes within max_run_s exits with its own pipeline status unchanged (not timed_out) and no timed_out event in events.jsonl; after waiting past max_run_s the status is still the stage-driven result, proving the watchdog was reaped covers: R-6
SPEC-4[code]: get_resume_recommendation returns manual_resume_only for a timed_out pipeline state (not fresh_start, not auto_resume); a run resumed with a generous max_run_s after a timed_out state completes normally — it is not stopped immediately covers: R-7
SPEC-5[no-code]: scripts/lib/stage-limits.sh and core/pipeline/runner.sh contain no reference to GITHUB_ACTIONS, bare CI, TRAVIS, CIRCLECI, RUNNER_OS, or BUILD_BUILDID in limit-resolution code covers: R-8
SPEC-6[no-code]: ADR-025 lists timed_out in its abort-word vocabulary and has ## Enforced by entries citing the new test files; ADR-054 has a §11 for the per-run limit with ## Enforced by entries; config/adr-enforcement-baseline.txt no longer lists ADR-054-stage-contract.md covers: R-9
WIRING:
core/pipeline/runner.sh
TESTFILES:
SPEC-1: tests/integration/run-timed-out-test.sh
SPEC-2: tests/unit/run-limit-precedence-test.sh
SPEC-3: tests/unit/run-watchdog-clean-exit-test.sh
SPEC-4: tests/integration/resume-after-run-timeout-test.sh
SPEC-5: tests/unit/run-limit-precedence-test.sh
SPEC-6: tests/unit/run-limit-precedence-test.sh
```

```supersedes
tests/unit/run-open-items-test.sh [O9]: asserts the runner has exactly 5 loop-ending lines; the timed_out arm added to _runner_end_on_abort is a sixth matching line, so the correct count is 6
```
