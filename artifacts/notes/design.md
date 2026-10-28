# design stage notes — issue #1944

## Current pass (iter-5 design refinement)

### What the latest issue-acceptance found

Issue-acceptance (previous work, verdict: fail) flagged:
1. R-4 / R-10 NOT MET: SPEC-5 in `runner-release-exit-paths-test.sh` fails — release not
   dispatched, marker empty. Identified dual causes: (a) `_runner_restore_stderr` before
   `trap ':' INT TERM`, (b) watchdog fd-close relocation.
2. NOT SURE: R-1 merge-base verification — no evidence of a merge-base run shown.
3. NOT SURE: R-9 §9 vs §11 — discrepancy between issue text and SPEC-6.

Finding 20 in the iter-4 design said "all NOT MET findings are stale". That was WRONG.
SPEC-5 still fails in the current worktree.

### Root cause analysis — iter-5

**Code verification (current worktree):**
- runner.sh:2529: `_runner_abort_trap() {`
- runner.sh:2532: `_runner_restore_stderr`          ← COMES FIRST
- runner.sh:2543: `trap ':' INT TERM`               ← COMES SECOND (race window!)
- runner.sh:2818: `exec {_RUNNER_ERR_FD}>&- || true` (Bug A — inside watchdog body) ✓
- runner-signal-rearm-test.sh:92: `/trap '.*' TERM$/` (Bug C — narrowed awk pattern) ✓

**Why SPEC-5 fails (ordering issue):**
SPEC-5 sends `kill -TERM -PG` to the runner's process group. The group includes the
`timeout 120` wrapper process. GNU timeout, on receiving SIGTERM, forwards SIGTERM to
its child (the runner) and then exits. The runner therefore gets TWO SIGTERMs in rapid
succession.

Timeline:
1. First SIGTERM → `_runner_signal_trap TERM` → `exit 1` → EXIT trap (`_runner_abort_trap`) starts
2. EXIT trap line 2532: `_runner_restore_stderr` executes (one `exec 2>&N` call)
3. BEFORE line 2543 (`trap ':' INT TERM`): second SIGTERM arrives from `timeout`
4. `_runner_signal_trap TERM` fires → `exit 1` from within EXIT trap
5. Bash aborts the EXIT trap immediately when `exit` is called inside it
6. `_runner_dispatch_always_run` (line 2558) never runs
7. Release hooks never execute → marker empty → SPEC-5 fails

**The fix:** `trap ':' INT TERM` must be the ABSOLUTE FIRST EXECUTABLE LINE of
`_runner_abort_trap` — before `_runner_restore_stderr` and before anything else.
The current code has a comment justifying placing the guard "immediately after"
`_runner_restore_stderr` because `_runner_restore_stderr` "has no wait". This
reasoning is flawed: ANY code before the guard creates a race window, not just
code that calls `wait`.

**Why Bug A (fd-close) also matters (but is not the SPEC-5 cause):**
The spawn-line form `( ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &` closes `_RUNNER_ERR_FD`
in the parent (bash evaluates the named-fd redirect before forking). This causes
`_runner_restore_stderr`'s `exec 2>&"$_RUNNER_ERR_FD"` to fail (fd closed → exec fails
under set -e → EXIT trap aborts). That was the boundary-form regression from iter-3.
The current inside-body form avoids it — `_RUNNER_ERR_FD` stays open in the parent,
`_runner_restore_stderr` succeeds. Bug A is correctly applied at runner.sh:2818.

**R-1 merge-base NOT SURE:** SPEC-1 is [code] — the test MUST fail on the merge-base.
On the merge-base, `scripts/lib/stage-limits.sh` does not exist, `_runner_resolve_run_limit_s`
is undefined, the watchdog arm is absent, and `timed_out` is not a pipeline status.
`run-timed-out-test.sh` assertions on `pipeline.end status=timed_out` and on the
`timed_out` value in `pipeline-state.json` would all fail. This is per-definition of
a [code] SPEC — no further evidence is needed in the design.

**R-9 §9 vs §11:** Already addressed in Finding 7 (iter-3). The issue text had a draft
section number (§9). The implementation correctly placed the per-run limit in ADR-054 §11.
SPEC-6 cites §11. This is settled; no design change needed.

### Design changes for iter-5

1. Decision 4: Revise to say trap guard MUST be first (before `_runner_restore_stderr`)
2. "All bugs now fixed" → rename to "Bug fix status" and show Bug B as STILL NEEDING FIX
3. "Notes on acceptance gate" — SPEC-5 entry: update from "resolved" to "still failing"
4. Finding 14: Update to note the ordering problem
5. Finding 20: Correct — was wrong to call all findings stale
6. Add Finding 21: Ordering regression in `_runner_abort_trap`
7. Add Finding 22: R-1 merge-base NOT SURE explained
8. Add Finding 23: R-9 §9 vs §11 NOT SURE resolved

## Prior pass notes (iter-4, carried forward)

### What changed in iter-4

Issue-acceptance pass 3 flagged:
1. R-4: SPEC-5 in runner-release-exit-paths proves release not dispatched (STALE — was boundary form)
2. R-4: persist stage not constructed or tested (STALE — was fixed in a60f39a4)
3. R-10: npm test exits non-zero (STALE — Bug A boundary form + Bug C caused this)
4. R-9 NOT SURE: §9 vs §11 (already addressed; issue text had a draft section number)

Those were indeed stale for that pass. But the iter-5 issue-acceptance is running against
a newer worktree state that has the inside-body fd-close but still has the ordering problem.

## Prior pass notes (iter-3, carried forward)

### Root cause: boundary `{_RUNNER_ERR_FD}>&-` vs inside-body close

The spawn-line form `( ... ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &` closes `_RUNNER_ERR_FD`
in the parent (bash evaluates the named-fd redirect before forking). `_runner_restore_stderr`
then fails. Inside-body form avoids this. Bug A is correctly applied.

### Scope addition (iter-3)
Added `tests/integration/runner-release-exit-paths-test.sh` to scope.

## Prior pass notes (iter-2, carried forward)

### Root cause of 3 remaining timeouts (Bug A incomplete)

The `>/dev/null 2>&1 &` redirect closes fds 1 and 2 but not `_RUNNER_ERR_FD`.
`exec {_RUNNER_ERR_FD}>&2` at line 2748 opens this fd pointing to fd 2 = pipe write end.
Orphaned sleep holds `_RUNNER_ERR_FD` open. Bug A fix: `exec {_RUNNER_ERR_FD}>&- || true`
inside watchdog body (applied at runner.sh:2818).

### Root cause of runner-signal-rearm-test.sh SPEC-5 failure (Bug C)

`_runner_abort_trap()` is a nested function DEFINED INSIDE main() at line 2529.
Its definition precedes the startup trap installs (line 2756).
Old awk pattern `/trap .* TERM$/` finds `trap ':' INT TERM` first.
Fix: narrow to `/trap '.*' TERM$/` (applied at runner-signal-rearm-test.sh:92).

### Key code locations (runner.sh)

- exec {_RUNNER_ERR_FD}>&2: line 2748
- _runner_abort_trap defined: line 2529 (inside main())
- _runner_restore_stderr in abort trap: line 2532 (must move AFTER trap guard)
- trap ':' INT TERM guard in abort trap: line 2543 (must move to be line 2530)
- trap '_runner_signal_trap TERM' TERM startup install: line 2756
- Watchdog arm: lines ~2807-2839
- exec {_RUNNER_ERR_FD}>&- in watchdog body: line 2818 (correct)
- exec 3>&2 (fd 3, AFTER watchdog arm): line 2851
