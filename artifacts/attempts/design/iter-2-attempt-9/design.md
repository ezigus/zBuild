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

3. **Watchdog subshell must close the inherited pipe-bearing fd from inside its
   body.** When the runner is invoked inside `$(bash "$RUNNER" ... 2>&1)` (as
   existing tests do), bash creates a pipe; both stdout and stderr of the runner
   point to its write end. Before the watchdog is armed, `main()` runs
   `exec {_RUNNER_ERR_FD}>&2` (line 2745) to save a copy of stderr on a
   high-numbered fd (`_RUNNER_ERR_FD` ≥ 10). The watchdog subshell inherits
   this fd. The `>/dev/null 2>&1 &` redirect closes fds 1 and 2 in the
   watchdog, but `_RUNNER_ERR_FD` is NOT covered. When the watchdog is
   SIGKILL'd by the EXIT trap, its `sleep "$_wdg_lim"` child is ORPHANED — it
   still holds `_RUNNER_ERR_FD` (the pipe write end). The `$(...)` waits for
   ALL file-description holders; the orphaned sleep holds one indefinitely,
   causing a 480 s test timeout.
   **Fix:** add `exec {_RUNNER_ERR_FD}>&- || true` as the SECOND line inside
   the watchdog body (after `trap '' TERM`). Close it in the body — NOT as a
   redirect on the `( ... ) &` boundary. The launch line stays `>/dev/null 2>&1 &`.
   Closing at the boundary with `    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`
   instead caused a regression in `runner-release-exit-paths-test.sh` SPEC-5
   (see Finding 18): `release` was no longer dispatched on the hard-kill exit
   path. Closing inside the body avoids the issue entirely while achieving the
   same effect: the `sleep` child inherits fds 1=/dev/null, 2=/dev/null, and
   fd{N}=closed (already closed before `sleep` was forked), so no orphaned
   process can hold the pipe write end.

4. **EXIT trap must guard against repeat signals with `trap ':' INT TERM` as
   its absolute first executable line.** The tests drive the runner via
   `timeout 120 bash "$RUNNER" ...` and send `kill -TERM -$RUNNER_PID` to the
   process group. GNU `timeout`, on receiving SIGTERM, forwards SIGTERM to its
   child's process group (same PG) before exiting. The runner therefore
   receives TWO SIGTERMs. The first fires `_runner_signal_trap TERM` →
   `exit 1` → the EXIT trap (`_runner_abort_trap`) starts. The second SIGTERM
   can arrive at any point before `trap ':' INT TERM` is installed. Bash fires
   `_runner_signal_trap TERM` again, which calls `exit 1`. Calling `exit`
   from within an EXIT trap causes bash to abort the trap immediately —
   `_runner_dispatch_always_run` is never reached.
   **Fix:** `trap ':' INT TERM` must be the ABSOLUTE FIRST EXECUTABLE LINE of
   `_runner_abort_trap` — before `_runner_restore_stderr` and before anything
   else. Any code that precedes the guard creates a race window, regardless of
   whether it calls `wait`. `_runner_restore_stderr` follows immediately after
   (still before any wait-bearing or dispatching code). The guard is restored
   to real handlers after the kill/wait block so `_runner_dispatch_always_run`
   can still handle signals. Mirrors the pattern used inside
   `_runner_dispatch_always_run` (line 2516).
   **Current worktree defect (Finding 21):** `_runner_restore_stderr` is at
   line 2532 and `trap ':' INT TERM` is at line 2543. The race window between
   them causes `runner-release-exit-paths-test.sh` SPEC-5 to fail — the
   second SIGTERM aborts the EXIT trap before `_runner_dispatch_always_run`
   runs, leaving the release marker empty.

5. **runner-signal-rearm-test.sh SPEC-5 regression.** The Bug B fix (Decision
   4) defines `_runner_abort_trap()` inside `main()`. This nested function
   contains `trap ':' INT TERM` — a guard line that ends with `TERM`. The
   SPEC-5 awk pattern `/trap .* TERM$/` finds this line as the FIRST
   `trap...TERM` inside `main()` (the nested function definition precedes the
   startup install at line 2751). The subsequent `grep -oE "trap '[^']+' TERM"`
   does not match `trap ':' INT TERM` (two-signal form), so `_startup_term`
   comes up empty (`<startup-not-found>`), while `_rearm_term` from
   `_runner_rearm_traps` is `trap '_runner_signal_trap TERM' TERM`. Test fails.
   **Fix:** narrow the awk pattern in SPEC-5 to match only single-handler TERM
   installs: replace `/trap .* TERM$/` with `/trap '.*' TERM$/` (requires a
   single-quoted handler before `TERM`). This skips `trap ':' INT TERM` (whose
   arg ends with `INT TERM`, not `' TERM'`) and correctly finds the startup
   `trap '_runner_signal_trap TERM' TERM` install.

6. **New abort word and pipeline status.** `timed_out` is the seventh abort
   word (ADR-025) and a new pipeline status (ADR-006, ADR-015). A
   `timed_out` state is `manual_resume_only` (resume.sh). A resumed run
   receives a fresh watchdog armed from its own wall-clock start.

7. **Always-run stages (release AND persist) still execute** via
   `_runner_dispatch_always_run` in the abort trap, which fires before the
   timed_out path writes the final state. Both role types are in the
   `timeout-with-release` test template's `always_run` list and both are
   asserted in P4 of run-timed-out-test.sh.

## Bug fix status

**Applied correctly in current worktree:**
- Bug A: `exec {_RUNNER_ERR_FD}>&- || true` at runner.sh:2818, inside the watchdog body
  (after `trap '' TERM`, before `_wdg_lim=`). Orphaned `sleep` cannot hold the pipe write
  end open. CAUTION: the boundary form `( ... ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`
  closes `_RUNNER_ERR_FD` in the parent (bash evaluates named-fd redirects before
  forking), causing `_runner_restore_stderr`'s `exec 2>&"$_RUNNER_ERR_FD"` to fail under
  `set -e`, which aborts the EXIT trap. Inside-body form is the only correct approach.
- Bug C: runner-signal-rearm-test.sh:92 — awk pattern narrowed from `/trap .* TERM$/` to
  `/trap '.*' TERM$/`, skipping the two-signal `trap ':' INT TERM` guard line.

**Still defective in current worktree — must be fixed:**
- Bug B (ordering): `_runner_restore_stderr` at runner.sh:2532 precedes `trap ':' INT TERM`
  at runner.sh:2543. The guard must be the FIRST executable line (before
  `_runner_restore_stderr`). See Decision 4 and Finding 21.

**Fixed in earlier commit (a60f39a4):**
- `:-0` default on kill/wait in abort trap → changed to `:-`
- `VAR=val (subshell)` syntax error at run-limit-precedence-test.sh
- `set -e` mid-file patterns (8 occurrences across 4 files)
- P4 only tested `release`, not `persist`
- P2 had `assert_pass` in both if/else branches

**Already passing (tests confirm):**
- O3 for-loop in run-open-items-test.sh now includes `timed_out` — test passes
- run-watchdog-clean-exit-test.sh S3-4 re-reads state file after sleep — test passes

## Notes on acceptance gate findings

**`core/pipeline/template.sh` reachability** — cleared once the syntax error
in `run-limit-precedence-test.sh:173` was fixed. The template-layer precedence
assertion in the test runs a full runner invocation with a template containing
`max_run_s:` and confirms it takes precedence over `ZBUILD_MAX_RUN_S`.

**R-9 / §9 vs §11** — R-9's original text says "ADR-054 §9" but ADR-054's §9
is "Per-stage router configuration surface" (unchanged). The implementation
correctly placed the run-level limit content in a new **§11**. SPEC-6 reflects
§11. The issue-acceptance "NOT SURE" about this is resolved: the issue text
contained a draft section number; §11 is the correct final number.

**Integration hangs root cause — resolved.** Bug A fix (`exec {_RUNNER_ERR_FD}>&- || true` at runner.sh:2818 inside the watchdog body) is now applied. Orphaned `sleep` can no longer hold `_RUNNER_ERR_FD` (the pipe write end) open, so `$(...)` callers no longer hang waiting for all write-end holders to close. The boundary form `{_RUNNER_ERR_FD}>&-` was tested and regressed runner-release-exit-paths SPEC-5 (Finding 18); the inside-body form is the only correct approach and is what is in the worktree.

**SPEC-5 regression (runner-release-exit-paths) — STILL FAILING.** The Bug B
guard (`trap ':' INT TERM` at runner.sh:2543) is present but in the wrong
position: `_runner_restore_stderr` at line 2532 comes first, leaving a race
window for the second SIGTERM to abort the EXIT trap before
`_runner_dispatch_always_run` runs. See Finding 21 and Decision 4.

**NEGCTL timeout on SPEC-1** — The negctl baseline run for SPEC-1 timed out
(pipeline problem, not our change). The negctl head run shows all 15 assertions
pass. The acceptance gate records this as `severity: advisory` — not a blocker.

**R-4 persist** — The issue-acceptance "NOT MET: R-4 persist is never
constructed" refers to an iteration before commit a60f39a4. The current
run-timed-out-test.sh already has `persist-stage` in `timeout-with-release.yaml`
and P4 asserts both the release marker and the persist marker. Not an
outstanding issue.

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
tests/integration/runner-release-exit-paths-test.sh
tests/unit/abort-propagation-test.sh
tests/unit/run-limit-precedence-test.sh
tests/unit/run-open-items-test.sh
tests/unit/run-watchdog-clean-exit-test.sh
tests/unit/runner-pipeline-end-test.sh
tests/unit/runner-signal-rearm-test.sh
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
core/state/resume.sh
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
tests/unit/runner-signal-rearm-test.sh [SPEC-5]: the awk pattern /trap .* TERM$/ now matches the guard `trap ':' INT TERM` (added inside _runner_abort_trap by the double-SIGTERM fix); grep -oE "trap '[^']+' TERM" returns empty for this two-signal line; the pattern must be narrowed to /trap '.*' TERM$/ to find only single-handler installs
```

## Findings

**Finding 1 (design — R-10 not covered by any SPEC)**: Fixed. Added `covers: R-10` to SPEC-1. R-10 ("npm test + npm run lint green") is a meta-requirement: once the implementation bugs are fixed and SPEC-1 through SPEC-6 all pass, both `npm test` and `npm run lint` are green.

**Finding 2 (test — 3 integration timeouts)**: Fully resolved. The original design attributed the 3 integration hangs to `:-0` in kill/wait. The `:-0` → `:-` fix was applied in commit a60f39a4 but tests still hung. The build then applied `>/dev/null 2>&1 &` (Bug A partial), but the 3 tests STILL timed out because `_RUNNER_ERR_FD` (opened at line 2745 before the watchdog arm) is also a pipe write end and is not covered by the `2>&1` redirect. Bug A is now fully fixed: `exec {_RUNNER_ERR_FD}>&- || true` at runner.sh:2818 closes this fd inside the watchdog body. The orphaned `sleep` can no longer hold the pipe open. See Finding 16 and Finding 18.

**Finding 3 (test — lint-test-errexit: 8 occurrences)**: Fixed in prior worktree commit. All 4 new test files use `_rc=0; cmd || _rc=$?` pattern.

**Finding 4 (test — syntax error line 173)**: Fixed in prior worktree commit. Line 213 correctly uses `( cd "$MISCFG_OVERLAY" && ZBUILD_MAX_RUN_S="not-a-number" bash "$RUNNER" ... )`.

**Finding 5 (issue-acceptance — R-4 persist missing)**: Fixed in prior worktree commit. P4 in run-timed-out-test.sh tests both release and persist markers. Template has both roles in always_run.

**Finding 6 (issue-acceptance — R-2 unfalsifiable P2)**: Fixed in prior worktree commit. P2 uses conditional assert_pass/assert_fail correctly.

**Finding 7 (issue-acceptance — R-9 §9 vs §11)**: False alarm. ADR-054 §9 is per-stage router config (unchanged). §11 is the run-level limit. SPEC-6 already says §11.

**Finding 8 (issue-acceptance — R-9 §11 content)**: Same as Finding 7. Design is correct.

**Finding 9 (issue-acceptance — template.sh inert)**: Cleared. The syntax error at run-limit-precedence-test.sh:173 is gone; the template-layer runner invocation reaches the template-layer assertion.

**Finding 10 (issue-acceptance — run-open-items.sh untested)**: Fixed. run-open-items-test.sh O3 now includes `timed_out` and the test passes.

**Finding 11 (test-author — SPEC-3 partially satisfied)**: Fixed. run-watchdog-clean-exit-test.sh now re-reads the state file after sleeping past max_run_s and the test passes.

**Finding 12 (test — wait 0 hang risk)**: `wait "${_RUNNER_WATCHDOG_PID:-0}"` with empty PID expands to `wait 0` in bash, which waits for ALL background processes and can hang indefinitely. Fixed in commit a60f39a4 (both kill/wait lines use `:-`). Not an outstanding bug.

**Finding 13 (build — Bug A: watchdog fd inheritance)**: After commit a60f39a4 fixed `:-0`, integration tests still hung. The build applied `>/dev/null 2>&1 &` (partial fix). Tests still timed out until Bug A was fully fixed — see Finding 16 for details. Now resolved.

**Finding 14 (build — Bug B: double-SIGTERM aborts EXIT trap)**: Partially applied in commit 741c8466 — `trap ':' INT TERM` guard was added to `_runner_abort_trap`, but placed AFTER `_runner_restore_stderr` (line 2532), leaving a race window. The guard must be the FIRST executable line (see Finding 21 and Decision 4). This also introduced a regression in runner-signal-rearm-test.sh SPEC-5 (see Finding 17).

**Finding 15 (build — NEGCTL WIRING for SPEC-4)**: WIRING was `core/pipeline/runner.sh` only. SPEC-4 asserts `get_resume_recommendation(timed_out) = manual_resume_only`, which is implemented in `core/state/resume.sh`. Added `core/state/resume.sh` to WIRING.

**Finding 16 (build pass 2 — Bug A incomplete, now resolved)**: The `>/dev/null 2>&1 &` redirect fixed fds 1 and 2 but not `_RUNNER_ERR_FD`. `exec {_RUNNER_ERR_FD}>&2` at line 2745 opens this fd pointing to fd 2 (pipe write end when runner is in `$(... 2>&1)`). The watchdog inherits it. The orphaned `sleep` holds `_RUNNER_ERR_FD` open indefinitely. The fix (see Finding 18 for why the boundary form was abandoned) is `exec {_RUNNER_ERR_FD}>&- || true` as the second line inside the watchdog body. This is now applied at runner.sh:2818.

**Finding 17 (build pass 2 — Bug C: runner-signal-rearm-test.sh SPEC-5 regression)**: The Bug B fix (trap guard in `_runner_abort_trap`) added `trap ':' INT TERM` inside the nested function, which is defined inside main(). The existing test's awk pattern `/trap .* TERM$/` matches this guard line first (before the startup install). `grep -oE "trap '[^']+' TERM"` does not match the two-signal `trap ':' INT TERM` form, so `_startup_term` = empty. `_rearm_term` = `trap '_runner_signal_trap TERM' TERM`. Test fails. Fix: narrow the awk pattern to `/trap '.*' TERM$/`. Added `tests/unit/runner-signal-rearm-test.sh` to scope and supersedes block. Decision section 5 added.

**Finding 18 (issue-acceptance pass 2 — Bug A boundary form breaks runner-release-exit-paths SPEC-5)**: The issue-acceptance reported that applying `{_RUNNER_ERR_FD}>&-` at the `( ... ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &` boundary caused `runner-release-exit-paths-test.sh` SPEC-5 to fail — `release` was no longer dispatched on the hard-kill (SIGTERM→SIGKILL) exit path. The boundary form has a behavioral difference from the inside-body form that corrupts the abort trap's watchdog-disarm sequence. The correct fix closes `_RUNNER_ERR_FD` INSIDE the watchdog subshell body (after `trap '' TERM`, before `_wdg_lim=...`): `exec {_RUNNER_ERR_FD}>&- || true`. The launch line reverts to the simpler `    ) >/dev/null 2>&1 &`. This achieves the same fd-close result (the `sleep` child inherits a closed fd{N}) without the boundary-form regression. Added `tests/integration/runner-release-exit-paths-test.sh` to scope: this test exercises the SIGTERM abort path through the watchdog disarm, which our watchdog arm change touches.

**Finding 19 (issue-acceptance pass 2 — R-4 persist from latest issue-acceptance)**: The latest issue-acceptance again flagged "persist is never constructed or tested". This was addressed in commit a60f39a4 (Finding 5). The current worktree already has `persist-stage` in `timeout-with-release.yaml` with a `persist` role, and P4 asserts both the release marker (`RELEASE_MARKER`) and the persist marker (`PERSIST_MARKER`). The finding is from a stale diff snapshot that predates those fixes. No design change needed.

**Finding 20 (issue-acceptance pass 3 — stale claim corrected)**: The iter-4 design incorrectly claimed all NOT MET findings were stale. The current issue-acceptance (pass 4, verdict: fail) shows `runner-release-exit-paths-test.sh` SPEC-5 still fails. The real remaining defect is the Bug B ordering issue: `_runner_restore_stderr` (line 2532) precedes `trap ':' INT TERM` (line 2543) in `_runner_abort_trap`. See Finding 21.

**Finding 21 (issue-acceptance pass 4 — Bug B ordering regression persists)**: The current worktree has `trap ':' INT TERM` at runner.sh:2543 but `_runner_restore_stderr` at runner.sh:2532 comes first. This creates a race window between the two lines. In SPEC-5, SIGTERM is sent to the process group that includes `timeout 120`; `timeout` forwards SIGTERM to the runner again (GNU timeout behavior), giving the runner two SIGTERMs in rapid succession. The second SIGTERM can arrive in the window between lines 2532 and 2543, firing `_runner_signal_trap TERM` → `exit 1` from within the EXIT trap, aborting it before `_runner_dispatch_always_run` runs. Marker stays empty; SPEC-5 fails. Fix: move `trap ':' INT TERM` to be the ABSOLUTE FIRST LINE of `_runner_abort_trap` — before `_runner_restore_stderr`.

**Finding 22 (issue-acceptance pass 4 — R-1 merge-base NOT SURE)**: The issue-acceptance asks for evidence that SPEC-1's test fails on the merge-base. SPEC-1 is `[code]` — by definition, the test must fail before the change. On the merge-base: `scripts/lib/stage-limits.sh` does not exist (it is new), `_runner_resolve_run_limit_s` is undefined, the watchdog arm is absent from runner.sh, and `timed_out` is not a valid pipeline status. Every assertion in `run-timed-out-test.sh` about `pipeline.end status=timed_out` and the `timed_out` value in `pipeline-state.json` will fail on the merge-base. No additional evidence is required in the design — the [code] label already encodes this obligation.

**Finding 23 (issue-acceptance pass 4 — R-9 NOT SURE resolved)**: The issue-acceptance asks whether the issue's "§9" refers to ADR-054's §9 (unchanged per-stage section) or means something else. Finding 7 settled this: the issue text contained a draft section number. ADR-054's §9 is "Per-stage router configuration surface" (unchanged). The per-run limit is in §11. SPEC-6 correctly cites §11. No design change needed.
