# design stage notes — issue #1944

## Current pass (iter-2 design refinement)

### What changed since iter-1 design passed

Build stage (commit 741c8466) applied two fixes to runner.sh:
1. Bug B fix: added `trap ':' INT TERM` guard + trap restore to `_runner_abort_trap`
2. Bug A partial fix: `    ) &` → `    ) >/dev/null 2>&1 &` at watchdog arm (line 2827)

Test stage result after commit 741c8466:
- 817 of 821 passed
- 3 timeouts: core-pipeline-runner-test.sh, core-pipeline-strategy-test.sh, vision-admission-gate-test.sh
- 1 failure: runner-signal-rearm-test.sh [SPEC-5]
- Shape floor: golden files flagged as not updated

### Root cause of 3 remaining timeouts (Bug A incomplete)

The `>/dev/null 2>&1 &` redirect closes fds 1 and 2. BUT:
- At line 2743 (BEFORE watchdog arm at line 2802): `exec {_RUNNER_ERR_FD}>&2`
- This opens _RUNNER_ERR_FD = some fd >= 10 = fd 2 = pipe write end
  (when runner is inside `$(bash "$RUNNER" ... 2>&1)`)
- Watchdog subshell inherits _RUNNER_ERR_FD = pipe write end
- `>/dev/null 2>&1` does NOT close _RUNNER_ERR_FD
- Orphaned sleep holds _RUNNER_ERR_FD open indefinitely
- $() waits for all pipe write end holders → hangs

FIX: `    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`

Confirmed by awk check: `awk '/^main\(\) \{/{f=1} f && /exec \{/' runner.sh` finds only:
- Line 2743: `exec {_RUNNER_ERR_FD}>&2`
The only extra fd opened before watchdog arm.

fd 3 (exec 3>&2 at line 2839) is opened AFTER watchdog arm — not inherited by watchdog.

### Root cause of runner-signal-rearm-test.sh SPEC-5 failure (Bug C)

Bug B fix added `trap ':' INT TERM` inside `_runner_abort_trap()`.
`_runner_abort_trap()` is a nested function DEFINED INSIDE main() at line 2529.
Its definition precedes the startup trap installs (line 2751).

SPEC-5 awk: `awk '/^main\(\) \{/{f=1} f && /trap .* TERM$/{print; exit}'`
→ finds `trap ':' INT TERM` at line 2546 (first TERM-containing line in main())

`grep -oE "trap '[^']+' TERM"` on `        trap ':' INT TERM`:
- Tries to match `trap '...' TERM` where `...` is followed by just ` TERM`
- `trap ':' INT TERM` has `:' INT TERM` after the closing quote — not ` TERM` directly
- Returns EMPTY

So _startup_term = empty = "<startup-not-found>"
But _rearm_term = "trap '_runner_signal_trap TERM' TERM" (from _runner_rearm_traps)
Test FAILS: expected <startup-not-found>, got trap '_runner_signal_trap TERM' TERM

FIX: Change awk pattern in SPEC-5 from `/trap .* TERM$/` to `/trap '.*' TERM$/`
- Old: matches any line ending with TERM
- New: requires `trap '...' TERM` form (single-quoted handler followed by exactly ` TERM`)
- `trap ':' INT TERM` ends with ` INT TERM` not `' TERM` → NOT matched by new pattern
- Wait: `/trap '.*' TERM$/` also won't match `trap ':' INT TERM` because after the closing `'`
  we have ` INT TERM` not ` TERM`. So the pattern `trap '.*' TERM$` requires the line to
  end exactly with `' TERM`. `trap ':' INT TERM` ends with `INT TERM` not `' TERM`. ✓
- The startup install `trap '_runner_signal_trap TERM' TERM` ends with `' TERM`. ✓

### Shape floor

tests/golden/full-pipeline/event-sequence.golden and parity: in scope, already.
Shape floor flagged them but golden tests PASS (shape-floor is a heuristic).
Build must update them if they are wrong.

### Design gate failure

Previous iter-2 attempts wrote designs without `covers: R-10` (or wrote nothing).
Current design-draft.md has `covers: R-10` in SPEC-1. Re-writing with correct content.

### Scope additions

Added tests/unit/runner-signal-rearm-test.sh (Bug C fix file).

### Supersedes additions

Added runner-signal-rearm-test.sh [SPEC-5] entry.

## Prior pass notes (carried forward for reference)

- exec {_RUNNER_ERR_FD}>&2 at line 2743: ERR fd set before watchdog arm
- exec 3>&2 at line 2839: fd 3 set AFTER watchdog arm (not inherited by watchdog)
- main() starts at line 1721
- Watchdog arm at lines 2802-2828
- _runner_abort_trap defined inside main() at line 2529
- Bug B fix: trap ':' INT TERM at line 2546 (inside _runner_abort_trap, inside main())
- Startup TERM install: trap '_runner_signal_trap TERM' TERM at line 2751
- _runner_rearm_traps: lines 1716-1718, top-level, has both INT and TERM handlers
