# design stage notes — issue #1944

## Current pass (iter-7 design refinement)

### iter-7 additions vs iter-6

1. Bug B status corrected in design (was "still defective", now "applied correctly")
2. Decision 4 cleaned up (removed "Current worktree defect (Finding 21)")
3. Decision 8 added: sigterm-aborts-pipeline-test.sh hang root cause and fix
4. Bug fix status section updated: Bug B moved to "Applied correctly"
5. Notes on acceptance gate updated: SPEC-5 passes, sigterm-aborts is new failing test
6. Scope: added `tests/integration/sigterm-aborts-pipeline-test.sh`
7. Finding 20 updated: SPEC-5 runner-release now passes
8. Finding 21 corrected: Bug B IS fixed (guard at line 939)
9. Finding 24 added: sigterm-aborts-pipeline-test.sh 480 s hang

## Prior pass notes (iter-6, carried forward)

### What the latest issue-acceptance found

Issue-acceptance (iter-6, verdict: fail):
1. NOT MET: R-10 — `sigterm-aborts-pipeline-test.sh` times out at 480 s
   ("likely a watchdog-leak regression when runner is killed externally")
2. NOT MET: shape floor flags `tests/golden/full-pipeline/event-sequence.golden` and
   `tests/golden/parity/event-sequence.golden` as needing review
3. NOT SURE: R-1 merge-base — regression test is new, so claim holds only if reverting
   runner implementation alone makes it fail
4. NOT SURE: test output passes now but cannot confirm red-on-revert direction

### Key code reading findings for iter-6

**Bug B IS FIXED (corrects iter-5 Finding 21):**
- Read `_runner_restore_stderr` at line 928-942
- Line 939: `trap ':' INT TERM` — IS the first executable line of the function
- `_runner_abort_trap` calls `_runner_restore_stderr` first (line 2543)
- Effective order: trap guard at line 939 (inside function) → exec 2>&N (line 940) → (return)
  → trap ':' INT TERM (line 2551 in abort trap, idempotent)
- diff.patch confirms: Bug B fix moved `trap ':' INT TERM` INTO `_runner_restore_stderr` as new line 939
- Finding 21 ("Bug B ordering regression persists") was WRONG — it didn't read the function body

**Only ONE test failing (not two):**
- test-failures-summary.md: 820 passed, 1 failed
- The only failure: `sigterm-aborts-pipeline-test.sh` (480 s timeout)
- `runner-release-exit-paths-test.sh` SPEC-5 NOW PASSES (Bug B is fixed)

**Shape floor cascades from test failure:**
- `_sf_floor_verified` for event-sequence.golden returns true ONLY when `_SF_FAILED_COUNT == "0"`
- Because sigterm-aborts fails, `_SF_FAILED_COUNT > 0` → golden files cannot be auto-verified
- Fix sigterm-aborts → zero failures → golden files auto-verified via `_sf_floor_verified` logic
- Golden files need NO content changes (normal run event sequence is unchanged; watchdog arms silently)

**sigterm-aborts-pipeline-test.sh root cause:**
- Test redirects runner stdout/stderr to files (not pipes)
- `wait "$RUNNER_PID"` waits for setsid which waits for runner
- Root cause: watchdog's `sleep "$_wdg_lim"` child inherits SIGTERM=SIG_IGN from watchdog's
  `trap '' TERM` (POSIX: SIG_IGN is inherited across exec/fork). When `kill -TERM "-$RUNNER_PGID"`
  hits the process group, this `sleep` ignores SIGTERM and continues. Watchdog subshell also
  ignores SIGTERM (trap '' TERM). EXIT trap does `kill -KILL "${_RUNNER_WATCHDOG_PID}"` →
  watchdog subshell dies. But orphaned `sleep 20700` (SIGTERM=SIG_IGN) continues running.
- Something in the test environment (likely `_kill_test_children` → bare `wait` at
  test-helpers.sh:114, or setsid wait behavior) eventually blocks on this orphaned `sleep 20700`.
- With default `_RUNNER_MAX_RUN_S = 20700`, the orphaned sleep outruns the 480 s test timeout.

**Fix for sigterm hang:**
- Code change to `core/pipeline/runner.sh` (already in scope)
- In EXIT trap's watchdog cleanup block, add `pgrep -P` to find watchdog children BEFORE killing
  the watchdog subshell (to avoid race: after kill, children are reparented away from watchdog's PID)
- Then SIGKILL both watchdog and its children (children have SIGTERM=SIG_IGN, must use KILL)
- Add `tests/integration/sigterm-aborts-pipeline-test.sh` to scope

**R-1 NOT SURE (merge-base):**
- SPEC-1 is [code] → definitionally fails at merge-base
- At merge-base: `scripts/lib/stage-limits.sh` absent, watchdog absent, `timed_out` not a status
- All assertions in `run-timed-out-test.sh` about `timed_out` would fail at merge-base
- No additional evidence needed — [code] label encodes this

**R-9 NOT SURE (§9 vs §11):**
- Already resolved in Finding 7/Finding 23 — issue text had draft number, §11 is correct

### Design changes for iter-6

1. Bug fix status: move Bug B from "Still defective" to "Applied correctly"
   (trap guard IS inside `_runner_restore_stderr` at line 939)
2. Decision 4: remove "Current worktree defect (Finding 21)" — Bug B is fixed
3. Finding 21: CORRECT — guard IS inside `_runner_restore_stderr` (line 939), not a defect
4. Add Finding 24: `sigterm-aborts-pipeline-test.sh` 480 s hang (root cause: orphaned sleep
   with SIGTERM=SIG_IGN), fix (child-kill before watchdog kill in EXIT trap)
5. Scope: add `tests/integration/sigterm-aborts-pipeline-test.sh`
6. Notes on acceptance gate: update — Bug B fixed, SPEC-5 runner-release passes,
   sigterm-aborts is new failure, golden files are correct (shape floor cascades from test failure)

## Prior pass notes (iter-5, carried forward)

### What changed in iter-5

Bug B fix (moved guard inside `_runner_restore_stderr` as its first line) — this is the fix
that iter-5's design said was still needed, and iter-6's diff confirms it was applied.

Key: the iter-5 design (Finding 21) said Bug B was NOT fixed because `_runner_restore_stderr`
appeared before `trap ':' INT TERM` by line number. This was WRONG — the function body starts
with `trap ':' INT TERM`, so the guard IS first.

## Prior pass notes (iter-4, carried forward)

Stale claims from iter-4 corrected in iter-5/iter-6. R-4 persist is tested (a60f39a4).

## Prior pass notes (iter-3, carried forward)

Bug A correctly applied: `exec {_RUNNER_ERR_FD}>&- || true` inside watchdog body (line 2826).
Boundary form `{_RUNNER_ERR_FD}>&-` was tested and regressed runner-release-exit-paths SPEC-5.

## Prior pass notes (iter-2, carried forward)

Bug C: awk pattern narrowed from `/trap .* TERM$/` to `/trap '.*' TERM$/` at runner-signal-rearm-test.sh:92.

## Key code locations (runner.sh — current)

- `_runner_restore_stderr` at line 928-942, `trap ':' INT TERM` is line 939 (FIRST line) ← BUG B FIXED
- `_runner_abort_trap` at line 2540
- Calls `_runner_restore_stderr` first: line 2543
- `trap ':' INT TERM` at line 2551 (idempotent)
- Watchdog kill: line 2560 (`kill -KILL "${_RUNNER_WATCHDOG_PID:-}"`)
- Watchdog wait: line 2561 (`wait "${_RUNNER_WATCHDOG_PID}"`)
- `exec {_RUNNER_ERR_FD}>&2` at line 2756
- Watchdog arm: lines 2799-2848 (line 2826: `exec {_RUNNER_ERR_FD}>&- || true` — Bug A fixed)
- `trap '' TERM` at line 2819 (watchdog ignores SIGTERM)
- `sleep "$_wdg_lim"` at line 2830 (watchdog's foreground child, inherits SIGTERM=SIG_IGN)
- `trap '_runner_signal_trap TERM' TERM` startup install: line 2763
- Watchdog PID: `_RUNNER_WATCHDOG_PID=$!` at line 2848
