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

3. **Watchdog subshell must redirect to /dev/null.** When the runner is
   invoked inside `$(bash "$RUNNER" ... 2>&1)` (as existing tests do), bash
   creates a pipe. Runner stdout/stderr are the pipe's write end. The watchdog
   subshell — and its `sleep "$_wdg_lim"` child — inherit these fds unless
   explicitly redirected. The EXIT trap kills the watchdog bash subshell with
   SIGKILL, but the subshell's child (`sleep 20700`) is ORPHANED — reparented
   to init. The orphaned sleep STILL HOLDS THE PIPE WRITE END OPEN for the
   full sleep duration. The outer `$(...)` waits for all pipe-write-end holders
   to close; the test hangs until the 480 s timeout fires.
   **Fix:** `    ) >/dev/null 2>&1 &` at line 2817 (the watchdog arm line).
   Redirect is safe: the watchdog's sentinel write and kill calls use files
   and system calls, not stdout/stderr.

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
   **Fix:** mirror the `trap ':' INT TERM` guard already used inside
   `_runner_dispatch_always_run` (line 2516) — add it before the kill/wait
   block in `_runner_abort_trap`, restoring the real handlers afterwards:
   ```
   trap ':' INT TERM
   kill -KILL "${_RUNNER_WATCHDOG_PID:-}" 2>/dev/null || true
   [[ -n "${_RUNNER_WATCHDOG_PID:-}" ]] && wait "${_RUNNER_WATCHDOG_PID}" 2>/dev/null || true
   trap '_runner_signal_trap TERM' TERM
   trap '_runner_signal_trap INT' INT
   _runner_dispatch_always_run
   ```

5. **New abort word and pipeline status.** `timed_out` is the seventh abort
   word (ADR-025) and a new pipeline status (ADR-006, ADR-015). A
   `timed_out` state is `manual_resume_only` (resume.sh). A resumed run
   receives a fresh watchdog armed from its own wall-clock start.

6. **Always-run stages (release AND persist) still execute** via
   `_runner_dispatch_always_run` in the abort trap, which fires before the
   timed_out path writes the final state. Both role types must be in the
   `timeout-with-release` test template's `always_run` list and asserted.

## Bugs that the next build pass must fix

| Bug | Affected file:line | Fix |
|-----|---------------------|-----|
| Watchdog subshell inherits stdout/stderr fds — orphaned `sleep` keeps `$(...)` pipe open | `core/pipeline/runner.sh:2817` | change `    ) &` to `    ) >/dev/null 2>&1 &`; watchdog only writes to files and sends signals, not stdout/stderr |
| Second SIGTERM (from `timeout` forwarding) interrupts `wait` in abort trap, calling `exit 1` from within EXIT trap aborts the trap before `_runner_dispatch_always_run` | `core/pipeline/runner.sh` in `_runner_abort_trap()`, lines ~2539-2543 | add `trap ':' INT TERM` before kill/wait block; restore handlers with `trap '_runner_signal_trap TERM' TERM` and `trap '_runner_signal_trap INT' INT` after wait; then call `_runner_dispatch_always_run` — mirrors line 2516 pattern |
| `run_end_words "timed_out"` not covered in O3 loop | `tests/unit/run-open-items-test.sh` O3 for-loop | add `timed_out` to the for-loop variable list; also add an explicit `assert_contains "[O3] timed_out says wall-clock limit in words" "$(run_end_words timed_out 0)" "wall-clock limit"` |
| SPEC-3 test does not re-read state file after sleeping past max_run_s | `tests/unit/run-watchdog-clean-exit-test.sh` S3-4 | after `sleep 5` and before the sentinel check, add: `_reaped_sf="$ZBUILD_STATE_DIR/pipeline-state.json"; if [[ -f "$_reaped_sf" ]]; then _reaped_status_after="$(jq -r '.status // empty' "$_reaped_sf" 2>/dev/null || true)"; assert_eq "[#1944/SPEC-3] pipeline status not timed_out after waiting past max_run_s" "" "$([[ "$_reaped_status_after" == "timed_out" ]] && echo "timed_out" || echo "")"; fi` |

**Already fixed in current worktree (commit a60f39a4):**
- `:-0` default on kill/wait in abort trap — FIXED (`${_RUNNER_WATCHDOG_PID:-}` on both lines 2539-2540)
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

**Integration hangs root cause** — the `:-0` → `:-` fix (applied in build
commit a60f39a4) was a necessary correctness fix but NOT the root cause of the
three test hangs. The root cause is Bug A (watchdog subshell fd inheritance):
the orphaned `sleep 20700` inherits the pipe's write end from the runner and
holds it open after the watchdog is killed. Bug A and Bug B (double-SIGTERM in
abort trap) are the two remaining implementation bugs.

**SPEC-5 regression (runner-release-exit-paths)** — `runner-release-exit-paths-test.sh`
SPEC-5 is an EXISTING test that the new watchdog code broke. It drives the
runner under `timeout 120`, then sends a PG-kill SIGTERM. Before this change
there was no watchdog `wait` in the abort trap, so the double-SIGTERM race
never occurred. Bug B is a direct regression. Once Bug B is fixed (trap guard),
the release markers are written and SPEC-5 passes.

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
```

## Findings

**Finding 1 (design — R-10 not covered by any SPEC)**: Fixed. Added `covers: R-10` to SPEC-1. R-10 ("npm test + npm run lint green") is a meta-requirement: once the implementation bugs are fixed and SPEC-1 through SPEC-6 all pass, both `npm test` and `npm run lint` are green.

**Finding 2 (test — 3 integration timeouts)**: Root cause updated. The original design attributed the 3 integration hangs to `:-0` in kill/wait. The `:-0` → `:-` fix was applied in commit a60f39a4 but tests STILL hang. The actual root cause is Bug A (watchdog fd inheritance): the orphaned `sleep "$_wdg_lim"` child of the watchdog subshell holds the pipe's write end open after the watchdog subshell is killed. Fix: `>/dev/null 2>&1 &` on line 2817 (the watchdog arm). See Finding 13.

**Finding 3 (test — lint-test-errexit: 8 occurrences)**: Fixed in prior worktree commit. All 4 new test files use `_rc=0; cmd || _rc=$?` pattern.

**Finding 4 (test — syntax error line 173)**: Fixed in prior worktree commit. Line 213 correctly uses `( cd "$MISCFG_OVERLAY" && ZBUILD_MAX_RUN_S="not-a-number" bash "$RUNNER" ... )`.

**Finding 5 (issue-acceptance — R-4 persist missing)**: Fixed in prior worktree commit. P4 in run-timed-out-test.sh tests both release and persist markers. Template has both roles in always_run.

**Finding 6 (issue-acceptance — R-2 unfalsifiable P2)**: Fixed in prior worktree commit. P2 uses conditional assert_pass/assert_fail correctly.

**Finding 7 (issue-acceptance — R-9 §9 vs §11)**: False alarm. ADR-054 §9 is per-stage router config (unchanged). §11 is the run-level limit. SPEC-6 already says §11.

**Finding 8 (issue-acceptance — R-9 §11 content)**: Same as Finding 7. Design is correct.

**Finding 9 (issue-acceptance — template.sh inert)**: Cleared. The syntax error at run-limit-precedence-test.sh:173 is gone; the template-layer runner invocation reaches the template-layer assertion.

**Finding 10 (issue-acceptance — run-open-items.sh untested)**: run-open-items.sh has `timed_out)` at line 107. The O3 for-loop in run-open-items-test.sh still does NOT include `timed_out`. Bugs table entry present.

**Finding 11 (test-author — SPEC-3 partially satisfied)**: SPEC-3's "after waiting past max_run_s the status is still the stage-driven result" is not directly verified — test checks state file BEFORE sleep (S3-2) and checks only sentinel after sleep (S3-4). SPEC-3 updated to require explicit state-file re-read after sleeping past max_run_s. Bugs table entry present.

**Finding 12 (test — wait 0 hang risk)**: `wait "${_RUNNER_WATCHDOG_PID:-0}"` with empty PID expands to `wait 0` in bash, which waits for ALL background processes and can hang indefinitely. This was fixed in commit a60f39a4 (both lines 2539-2540 now use `:-`). Not an outstanding bug.

**Finding 13 (build — Bug A: watchdog fd inheritance)**: After commit a60f39a4 fixed `:-0`, integration tests STILL hang. Root cause: the watchdog subshell at line 2817 `    ) &` has no stdout/stderr redirect. When the runner is invoked inside `$(bash "$RUNNER" ... 2>&1)`, the subshell inherits the pipe's write end. After the watchdog bash subshell is killed, its child `sleep "$_wdg_lim"` is orphaned and holds the pipe's write end for the full sleep duration. Fix: `    ) >/dev/null 2>&1 &`. Added to bugs table. Scope and design sections 2 and 3 updated.

**Finding 14 (build — Bug B: double-SIGTERM aborts EXIT trap)**: `runner-release-exit-paths-test.sh` SPEC-5 regression. The test drives the runner under `timeout 120`, then sends a PG-kill SIGTERM. GNU `timeout` also forwards SIGTERM to its child process group on receiving SIGTERM — the runner gets two SIGTERMs. The first fires the EXIT trap; the second arrives during `wait` in the abort trap and causes bash to re-fire `_runner_signal_trap TERM`. Calling `exit 1` from within an EXIT trap aborts the trap immediately, so `_runner_dispatch_always_run` is never called and release markers are never written. Fix: `trap ':' INT TERM` guard before kill/wait block in `_runner_abort_trap`, mirroring line 2516. Added to bugs table.

**Finding 15 (build — NEGCTL WIRING for SPEC-4)**: WIRING was `core/pipeline/runner.sh` only. SPEC-4 asserts `get_resume_recommendation(timed_out) = manual_resume_only`, which is implemented in `core/state/resume.sh`. When only runner.sh is reverted, resume.sh stays new and SPEC-4 still passes — NEGCTL would not detect a missing wiring. Added `core/state/resume.sh` to WIRING.
