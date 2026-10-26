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

3. **EXIT trap kills watchdog on EVERY exit.** Both the `kill` and `wait`
   calls in `_runner_abort_trap` must use `:-` (empty default), not `:-0`:
   ```
   kill -KILL "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null || true
   wait "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null || true
   ```
   - `:-0` on `kill`: if `_RUNNER_WATCHDOG_PID` is empty, `kill -KILL 0`
     sends SIGKILL to the entire process group — including the test harness.
   - `:-0` on `wait`: if `_RUNNER_WATCHDOG_PID` is empty, `wait 0` waits
     for ALL background processes in the shell, blocking indefinitely.
   - `:-` (empty): both calls fail silently (caught by `2>/dev/null || true`)
     when the watchdog was never armed.
   **Root cause of the three integration-test timeouts** (core-pipeline-runner,
   core-pipeline-strategy, vision-admission-gate): the runner now always arms
   a watchdog; on exit paths where `_RUNNER_WATCHDOG_PID` could be empty
   (early exit before arming), `kill -KILL 0` nukes the test harness's
   process group. Even when PID is set, `wait 0` (expanded from `:-0` if
   the variable was not yet initialized) can cause a hang.

4. **New abort word and pipeline status.** `timed_out` is the seventh abort
   word (ADR-025) and a new pipeline status (ADR-006, ADR-015). A
   `timed_out` state is `manual_resume_only` (resume.sh). A resumed run
   receives a fresh watchdog armed from its own wall-clock start.

5. **Always-run stages (release AND persist) still execute** via
   `_runner_dispatch_always_run` in the abort trap, which fires before the
   timed_out path writes the final state. Both role types must be in the
   `timeout-with-release` test template's `always_run` list and asserted.

## Bugs that the next build pass must fix

| Bug | Affected file:line | Fix |
|-----|---------------------|-----|
| `:-0` default on BOTH kill and wait in abort trap | `core/pipeline/runner.sh:2539,2540` | change `"${_RUNNER_WATCHDOG_PID:-0}"` → `"${_RUNNER_WATCHDOG_PID:-}"` on BOTH lines; `kill -KILL ""` and `wait ""` each fail silently (2>/dev/null \|\| true) |
| `run_end_words "timed_out"` not covered in O3 loop | `tests/unit/run-open-items-test.sh` O3 for-loop | add `timed_out` to the for-loop variable list; also add an explicit `assert_contains "[O3] timed_out says wall-clock limit in words" "$(run_end_words timed_out 0)" "wall-clock limit"` |
| SPEC-3 test does not re-read state file after sleeping past max_run_s | `tests/unit/run-watchdog-clean-exit-test.sh` S3-4 | after `sleep 5` and before the sentinel check, add: `_reaped_sf="$ZBUILD_STATE_DIR/pipeline-state.json"; if [[ -f "$_reaped_sf" ]]; then _reaped_status_after="$(jq -r '.status // empty' "$_reaped_sf" 2>/dev/null \|\| true)"; assert_eq "[#1944/SPEC-3] pipeline status not timed_out after waiting past max_run_s" "" "$([[ "$_reaped_status_after" == "timed_out" ]] && echo "timed_out" \|\| echo "")"; fi` — `ZBUILD_STATE_DIR` is already set to `state-sentinel` at this point |

**Note:** The following bugs were identified in the previous design iteration but are
ALREADY FIXED in the current worktree (commit f915476a by test-author):
- `VAR=val (subshell)` syntax error at run-limit-precedence-test.sh — FIXED
- `set -e` mid-file patterns (8 occurrences across 4 files) — FIXED
- P4 only tested `release`, not `persist` — FIXED
- P2 had `assert_pass` in both if/else branches — FIXED

## Notes on acceptance gate findings

**`core/pipeline/template.sh` reachability** — cleared once the syntax error
in `run-limit-precedence-test.sh:173` was fixed. The template-layer precedence
assertion in the test runs a full runner invocation with a template containing
`max_run_s:` and confirms it takes precedence over `ZBUILD_MAX_RUN_S`.

**R-9 / §9 vs §11** — R-9's original text says "ADR-054 §9" but ADR-054's §9
is "Per-stage router configuration surface" (unchanged). The implementation
correctly placed the run-level limit content in a new **§11**. SPEC-6 reflects
§11. The issue-acceptance "NOT SURE" is a false alarm; no design change needed.

**Test stage failures vs current worktree** — the test stage ran on a state
before the test-author's latest commit (f915476a). That commit fixed the
syntax error, set-e patterns, P4, and P2 issues. The ONLY remaining
implementation bug is the `:-0` → `:-` fix in runner.sh:2539-2540. The
test-author's check for SPEC-3 was "still failing" because the test does not
re-read the state file after sleeping past max_run_s; SPEC-3 is updated below.

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
SPEC-1[code]: a run whose wall-clock time exceeds max_run_s ends with pipeline status timed_out in pipeline-state.json; pipeline.end carries status=timed_out, the in-flight stage name, and limit_s; the watchdog fires even when the engine is idle between dispatches (not only inside a stage); a stage that ignores SIGTERM is dead within TERM+10 s; release and persist always_run stages both execute on the timed-out exit path covers: R-1 R-2 R-3 R-4 R-10
SPEC-2[code]: _runner_resolve_run_limit_s resolves template max_run_s > ZBUILD_MAX_RUN_S > 20700; a non-integer or non-positive value in either source causes the runner to exit 1 with a message naming the misconfigured source before any stage dispatch covers: R-5
SPEC-3[code]: a run that finishes within max_run_s exits with its own pipeline status unchanged (not timed_out) and no timed_out event in events.jsonl; the test must then sleep past max_run_s and re-read pipeline-state.json to directly assert the status is still the stage-driven result (not timed_out); the abort sentinel must also be absent after the sleep, proving the watchdog was reaped covers: R-6
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

**Finding 1 (design — R-10 not covered by any SPEC)**: Fixed. Added `covers: R-10` to SPEC-1. R-10 ("npm test + npm run lint green") is a meta-requirement: once the implementation bugs are fixed and SPEC-1 through SPEC-6 all pass, both `npm test` and `npm run lint` are green.

**Finding 2 (test — 3 integration timeouts)**: Root cause: `:-0` in BOTH `kill` and `wait` calls in `_runner_abort_trap`. When `_RUNNER_WATCHDOG_PID` is empty, `kill -KILL 0` kills the process group (test harness) and `wait 0` hangs waiting for all background processes. Fix: `:-` (empty default) on BOTH lines 2539 and 2540 of `core/pipeline/runner.sh`. The three existing tests (core-pipeline-runner, core-pipeline-strategy, vision-admission-gate) fail because they invoke the runner and the `:-0` bug causes the EXIT trap to malfunction.

**Finding 3 (test — lint-test-errexit: 8 occurrences)**: Fixed in current worktree (f915476a). All 4 new test files now use `_rc=0; cmd || _rc=$?` pattern instead of `set +e; cmd; set -e`. The lint-test-errexit-test.sh should pass.

**Finding 4 (test — syntax error line 173)**: Fixed in current worktree (f915476a). Line 213 now correctly uses `( cd "$MISCFG_OVERLAY" && ZBUILD_MAX_RUN_S="not-a-number" bash "$RUNNER" ... )`.

**Finding 5 (issue-acceptance — R-4 persist missing)**: Fixed in current worktree. P4 in run-timed-out-test.sh tests both release (line 368) and persist (line 375) markers on the timed-out exit path. Template has both roles in always_run.

**Finding 6 (issue-acceptance — R-2 unfalsifiable P2)**: Fixed in current worktree. P2 uses conditional `assert_pass`/`assert_fail` correctly, not `assert_pass` in both branches.

**Finding 7 (issue-acceptance — R-9 §9 vs §11)**: False alarm. ADR-054 §9 is per-stage router config (unchanged). §11 is the run-level limit. SPEC-6 already says §11.

**Finding 8 (issue-acceptance — R-9 §11 content)**: Same as Finding 7. Design is correct.

**Finding 9 (issue-acceptance — template.sh inert)**: Fixed. The syntax error at run-limit-precedence-test.sh:173 is gone; the template-layer runner invocation reaches the template-layer assertion.

**Finding 10 (issue-acceptance — run-open-items.sh untested)**: Partially fixed. run-open-items.sh has the `timed_out)` case (line 107) returning "stopped: the run exceeded its wall-clock limit". But the O3 for-loop in run-open-items-test.sh still does NOT include `timed_out`. Bugs table updated.

**Finding 11 (test-author — SPEC-3 partially satisfied)**: The test-author checker found that SPEC-3's "after waiting past max_run_s the status is still the stage-driven result" is not directly verified — the test checks the state file before the sleep (S3-2) and only checks the sentinel after the sleep (S3-4). SPEC-3 updated to require explicit state-file re-read after sleeping past max_run_s. Bugs table updated with the exact assertion to add to S3-4.

**Finding 12 (test — wait 0 hang risk)**: In addition to `kill -KILL 0`, the `wait "${_RUNNER_WATCHDOG_PID:-0}"` with empty PID expands to `wait 0`. In bash, `wait 0` waits for all background processes in the current shell — this can hang indefinitely if there are orphan background processes. The fix for line 2540 (same as line 2539) is `:-` (empty default). Design and bugs table updated to cover both lines.
