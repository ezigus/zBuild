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

3. **EXIT trap kills watchdog on EVERY exit.** `kill -KILL "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null || true`
   must be in the runner's EXIT trap (installed via `trap '...' EXIT`), not
   only in `_runner_abort_trap`. **Root cause of the three integration-test
   timeouts** in the previous build pass: a cleanly-exiting runner leaves the
   watchdog sleeping for up to 20700 s as an orphan in the test harness's
   session; any subsequent runner invocation in that session waits on the
   orphan and hangs past 480 s. The abort trap already kills the watchdog on
   signal/abort paths — the EXIT trap addition covers clean-exit paths.

4. **New abort word and pipeline status.** `timed_out` is the seventh abort
   word (ADR-025) and a new pipeline status (ADR-006, ADR-015). A
   `timed_out` state is `manual_resume_only` (resume.sh). A resumed run
   receives a fresh watchdog armed from its own wall-clock start.

5. **Always-run stages (release AND persist) still execute** via
   `_runner_dispatch_always_run` in the abort trap, which fires before the
   timed_out path writes the final state. Both role types must be in the
   `timeout-with-release` test template's `always_run` list and asserted.

## Bugs from the previous build pass that the implementation must fix

| Bug | Affected file:line | Fix |
|-----|---------------------|-----|
| EXIT trap does not kill watchdog | `core/pipeline/runner.sh` EXIT trap | add `kill -KILL "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null \|\| true` to EXIT trap |
| `VAR=val \( subshell \)` syntax | `tests/unit/run-limit-precedence-test.sh:173` | use `( cd "$MISCFG_OVERLAY" && ZBUILD_MAX_RUN_S="not-a-number" bash "$RUNNER" ... )` |
| `set -e` mid-file (8 occurrences) | `run-timed-out-test.sh:137,224,273,334`; `run-watchdog-clean-exit-test.sh:80,131`; `run-limit-precedence-test.sh:176`; `resume-after-run-timeout-test.sh:133` | replace `set +e; cmd; rc=$?; set -e` with `_rc=0; cmd \|\| _rc=$?` |
| P4 tests release only | `tests/integration/run-timed-out-test.sh` P4, `timeout-with-release` template | add a `persist` role stage to `always_run`; add persist-marker plugin; assert marker |
| P2 `assert_pass` in both branches | `tests/integration/run-timed-out-test.sh` P2 fast-one if/else | remove the if/else; main `assert_eq ... status=timed_out` already covers R-2 |
| `run_end_words "timed_out"` untested | `tests/unit/run-open-items-test.sh` | add assertion that `run_end_words "timed_out" 0` contains `"exceeded"` or the wall-clock message fragment |

## Notes on acceptance gate findings

**`config/adr-enforcement-baseline.txt` REACHABILITY FAIL** — expected, not a
design gap. The baseline is only checked by `lint-adr-enforced-by.sh` (`npm run
lint`), not by `npm test`. Once ADR-054 has an `## Enforced by` section (confirmed
in diff), lint passes. No test is needed for the baseline itself.

**`core/pipeline/template.sh` REACHABILITY FAIL** — will clear automatically once
the syntax error in `run-limit-precedence-test.sh:173` is fixed. The template-layer
precedence assertion invokes the runner with a template-embedded `max_run_s:` value
and confirms it takes precedence over `ZBUILD_MAX_RUN_S`. Currently this section of
the test never runs (file crashes at line 173).

**R-9 / §9 vs §11** — R-9's original text says "ADR-054 §9" but ADR-054's §9 is
"Per-stage router configuration surface" (unchanged). The implementation correctly
placed the run-level limit content in a new **§11**. SPEC-6 reflects §11. The
issue-acceptance finding is a false alarm; no design change is needed.

**NEGCTL PASS for SPEC-2/3/4** — the acceptance gate reverts only the WIRING file
(runner.sh) when running negctl checks. SPEC-2 and SPEC-3 exercise `stage-limits.sh`
behavior; SPEC-4 exercises `resume.sh` behavior. Neither depends on runner.sh being
old code. NEGCTL PASS is expected. These tests DO fail on fully-old code (before
this issue changed stage-limits.sh and resume.sh); the WIRING-only revert simply
doesn't reveal that relationship.

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

## Findings

**Finding 1 (test — 3 integration timeouts)**: Root cause confirmed: EXIT trap does not kill watchdog on clean exit. Design updated Decision point 3 to explicitly name the EXIT trap (not only abort trap) as the required kill site. Build must add the kill to the EXIT trap in `core/pipeline/runner.sh`. Finding belongs to implementation, not design scope or acceptance.

**Finding 2 (test — lint-test-errexit: 8 occurrences)**: Caused by `set -e` mid-file in 4 new test files. Bugs table updated with exact file:line for each occurrence. Fix is `cmd || _rc=$?` replacing the `set +e; cmd; rc=$?; set -e` pattern. Applies to all 8 occurrences in the TESTFILES.

**Finding 3 (test — syntax error line 173)**: `VAR=val (...)` construct in `run-limit-precedence-test.sh`. Bugs table already had this; updated to include the exact line and the precise fix (assignment moves inside the subshell before `bash`).

**Finding 4 (issue-acceptance — R-4 persist missing)**: Test only asserts `release` on the timed-out path. Fix: add `persist` role stage to the `timeout-with-release` template and assert its marker. Already in bugs table; kept.

**Finding 5 (issue-acceptance — R-2 unfalsifiable P2)**: The if/else after the main `assert_eq` in P2 has `assert_pass` in both branches. Fix: remove the if/else. Already in bugs table; kept.

**Finding 6 (issue-acceptance — R-9 §9 vs §11)**: False alarm. ADR-054 §9 is per-stage router config (unchanged). §11 is the run-level limit, which is correct. SPEC-6 already says §11. No design change.

**Finding 7 (issue-acceptance — R-9 unsure)**: Same as Finding 6. Design is correct.

**Finding 8 (acceptance-gate — template.sh inert)**: Will clear when syntax error fix makes the template-layer runner invocation reach the template-layer assertions. No scope change needed.

**Finding 9 (acceptance-gate — run-open-items.sh untested)**: No assertion exercises `run_end_words "timed_out" 0`. Bugs table updated to specify the assertion to add.

**Finding 10 (acceptance-gate — baseline untested)**: Expected — baseline is lint-only. Not a design gap.
