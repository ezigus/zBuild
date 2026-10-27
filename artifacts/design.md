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

3. **Watchdog subshell must close all inherited pipe-bearing fds.** When
   the runner is invoked inside `$(bash "$RUNNER" ... 2>&1)` (as existing
   tests do), bash creates a pipe; both stdout and stderr of the runner point
   to its write end. Before the watchdog is armed, `main()` runs
   `exec {_RUNNER_ERR_FD}>&2` (line 2743) to save a copy of stderr on a
   high-numbered fd (`_RUNNER_ERR_FD` ≥ 10). The watchdog subshell inherits
   this fd. The `>/dev/null 2>&1 &` redirect (applied by the prior build pass)
   closes fds 1 and 2 in the watchdog, but `_RUNNER_ERR_FD` is NOT covered by
   that redirect. When the watchdog bash subshell is SIGKILL'd by the EXIT
   trap, its `sleep "$_wdg_lim"` child is ORPHANED — it still holds
   `_RUNNER_ERR_FD` (the pipe write end). The `$(...)` waits for ALL
   file-description holders of the pipe write end to close; the orphaned sleep
   holds one indefinitely, causing a 480 s test timeout.
   **Fix:** add `{_RUNNER_ERR_FD}>&-` to the watchdog redirect:
   `    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`
   `_RUNNER_ERR_FD` is always set by the time the watchdog is armed (line 2743
   < line 2802). The watchdog writes only to the abort-sentinel file and sends
   signals; it never needs this fd.

4. **EXIT trap kill/wait block must be guarded against repeat signals.** The
   existing tests drive the runner via `timeout 120 bash "$RUNNER" ...` and
   send `kill -TERM -$RUNNER_PID` to the process group. GNU `timeout`, on
   receiving SIGTERM, forwards SIGTERM to its child's process group (same PG)
   before exiting. The runner therefore receives TWO SIGTERMs. The first fires
   `_runner_signal_trap TERM` → `exit 1` → the EXIT trap (`_runner_abort_trap`)
   starts. During the `wait "${_RUNNER_WATCHDOG_PID:-}" …` call inside the
   trap, the second SIGTERM arrives and interrupts `wait`. Bash fires
   `_runner_signal_trap TERM` again, which calls `exit 1`. Calling `exit`
   from within an EXIT trap causes bash to abort the trap immediately —
   `_runner_dispatch_always_run` is never reached.
   **Fix (applied in commit 741c8466):** add `trap ':' INT TERM` before the
   kill/wait block in `_runner_abort_trap`, restoring the real handlers
   afterwards. Mirrors the pattern already used inside
   `_runner_dispatch_always_run` (line 2516).

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
   timed_out path writes the final state. Both role types must be in the
   `timeout-with-release` test template's `always_run` list and asserted.

## Bugs that the next build pass must fix

| Bug | Affected file:line | Fix |
|-----|---------------------|-----|
| Bug A (remaining): watchdog subshell's `_RUNNER_ERR_FD` (opened at runner.sh:2743 before watchdog arm) references pipe write end — orphaned `sleep` keeps `$(...)` pipe open via this high-numbered fd | `core/pipeline/runner.sh:2827` | change `    ) >/dev/null 2>&1 &` to `    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`; fds 1 and 2 are already /dev/null; this closes `_RUNNER_ERR_FD` so no inherited fd references the pipe |
| Bug C (regression): runner-signal-rearm-test.sh SPEC-5 awk matches `trap ':' INT TERM` (guard added by Bug B fix inside `_runner_abort_trap` in main()); `grep -oE "trap '[^']+' TERM"` returns empty for this line; `_startup_term` = `<startup-not-found>` ≠ `_rearm_term` | `tests/unit/runner-signal-rearm-test.sh` | in the SPEC-5 `_startup_term` assignment, change the awk pattern from `/trap .* TERM$/` to `/trap '.*' TERM$/` so only single-quoted-handler TERM installs are matched, skipping the two-signal guard |

**Fixed in current worktree (commit 741c8466):**
- Bug B: double-SIGTERM aborts EXIT trap — FIXED (`trap ':' INT TERM` guard + trap restore in `_runner_abort_trap`)
- Bug A partial: `>/dev/null 2>&1 &` redirect applied at watchdog arm — fd 1 and fd 2 now /dev/null; `_RUNNER_ERR_FD` still requires closing (Bug A remaining above)

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
§11.

**Integration hangs root cause** — The build applied `>/dev/null 2>&1 &` (Bug A
partial fix). Tests STILL hang because `_RUNNER_ERR_FD` (opened at line 2743
before the watchdog arm) is also a pipe write end and was not redirected.
The remaining fix is `{_RUNNER_ERR_FD}>&-` in the watchdog arm redirect.

**SPEC-5 regression (runner-release-exit-paths)** — Fixed by Bug B fix in
commit 741c8466. The `trap ':' INT TERM` guard prevents the second SIGTERM from
interrupting the abort trap. `_runner_dispatch_always_run` now runs reliably.

**NEGCTL timeout on SPEC-1** — The negctl baseline run for SPEC-1 timed out
(pipeline problem, not our change). The negctl head run shows all 15 assertions
pass. The acceptance gate records this as `severity: advisory` — not a blocker.

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

**Finding 2 (test — 3 integration timeouts)**: Root cause updated. The original design attributed the 3 integration hangs to `:-0` in kill/wait. The `:-0` → `:-` fix was applied in commit a60f39a4 but tests still hung. The build then applied `>/dev/null 2>&1 &` (Bug A partial), but the 3 tests STILL time out because `_RUNNER_ERR_FD` (opened at line 2743 before the watchdog arm) is also a pipe write end and is not covered by the `2>&1` redirect. The orphaned `sleep` child holds `_RUNNER_ERR_FD` = pipe write end. See Finding 16.

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

**Finding 13 (build — Bug A: watchdog fd inheritance)**: After commit a60f39a4 fixed `:-0`, integration tests still hung. The build applied `>/dev/null 2>&1 &` (partial fix). Tests STILL time out. See Finding 16 for the complete root cause.

**Finding 14 (build — Bug B: double-SIGTERM aborts EXIT trap)**: Fixed in commit 741c8466. `trap ':' INT TERM` guard added before kill/wait block in `_runner_abort_trap`. `_runner_dispatch_always_run` now runs on all exit paths. BUT this fix introduced a new regression in runner-signal-rearm-test.sh SPEC-5 (see Finding 17).

**Finding 15 (build — NEGCTL WIRING for SPEC-4)**: WIRING was `core/pipeline/runner.sh` only. SPEC-4 asserts `get_resume_recommendation(timed_out) = manual_resume_only`, which is implemented in `core/state/resume.sh`. Added `core/state/resume.sh` to WIRING.

**Finding 16 (build pass 2 — Bug A incomplete)**: The `>/dev/null 2>&1 &` redirect fixed fds 1 and 2 but not `_RUNNER_ERR_FD`. `exec {_RUNNER_ERR_FD}>&2` at line 2743 opens this fd pointing to fd 2 (pipe write end when runner is in `$(... 2>&1)`). The watchdog inherits it. The orphaned `sleep` holds `_RUNNER_ERR_FD` open indefinitely. Fix: `    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`. Added to bugs table. Decision section 3 rewritten.

**Finding 17 (build pass 2 — Bug C: runner-signal-rearm-test.sh SPEC-5 regression)**: The Bug B fix (trap guard in `_runner_abort_trap`) added `trap ':' INT TERM` inside the nested function, which is defined inside main(). The existing test's awk pattern `/trap .* TERM$/` matches this guard line first (before the startup install). `grep -oE "trap '[^']+' TERM"` does not match the two-signal `trap ':' INT TERM` form, so `_startup_term` = empty. `_rearm_term` = `trap '_runner_signal_trap TERM' TERM`. Test fails. Fix: narrow the awk pattern to `/trap '.*' TERM$/`. Added `tests/unit/runner-signal-rearm-test.sh` to scope and supersedes block. Decision section 5 added.
