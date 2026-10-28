# design stage notes — issue #1944

## Current pass (iter-3 design refinement)

### What changed since iter-2

Issue-acceptance pass 2 flagged:
1. `runner-release-exit-paths-test.sh` SPEC-5 regresses after `{_RUNNER_ERR_FD}>&-` boundary change
2. Shape floor breach (golden files need updating)
3. R-4: persist "never constructed or tested" (was already fixed in iter-2; stale finding)
4. R-9: §9 vs §11 (already addressed; issue text had a draft numbering; §11 is correct)

### Root cause: boundary `{_RUNNER_ERR_FD}>&-` vs inside-body close

The previous design had Bug A fix as:
`    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`

This caused `runner-release-exit-paths-test.sh` SPEC-5 to fail:
- SPEC-5 sends SIGTERM to the runner's PG while the build stage is sleeping
- Asserts that `intake` and `build` both wrote release markers
- After the boundary form: release was NOT dispatched

"hard-kill exit path no longer dispatches release at all after the FD-close change"

This means `_runner_dispatch_always_run` was not reached. The 15s backstop SIGKILL fires and kills the runner mid-trap.

The SAFE alternative: close the fd INSIDE the watchdog body (first thing after `trap '' TERM`):
```bash
(
    trap '' TERM
    exec {_RUNNER_ERR_FD}>&- || true   # close saved-stderr fd
    _wdg_lim="${_RUNNER_MAX_RUN_S}"
    ...
) >/dev/null 2>&1 &
```

Effect:
- Watchdog body runs with fd{N} = inherited pipe
- `exec {_RUNNER_ERR_FD}>&-` closes fd{N} in the watchdog subshell
- `sleep` is forked AFTER the close → inherits fd{N}=closed
- No pipe reference in orphaned sleep
- Outer launch line stays simple: `>/dev/null 2>&1 &`
- Does NOT affect the main runner shell's fd{N}, so `_runner_restore_stderr` continues to work

### Scope addition

Added `tests/integration/runner-release-exit-paths-test.sh` to scope.
- Exercises the SIGTERM abort path with watchdog disarm
- Our watchdog arm change affects it
- Boundary form broke it; inside-body form should restore it

### Shape floor

Golden files already in scope. Shape floor breach = golden files are stale and need updating by the implementation stage. No new scope entries needed.

### Design changes summary (iter-3)

1. Decision 3: revised to describe inside-body close instead of boundary redirect
2. Bugs table: Bug A fix updated to inside-body form with explicit note against boundary form
3. Scope: added `tests/integration/runner-release-exit-paths-test.sh`
4. Notes on acceptance gate: updated "Integration hangs root cause" and "R-4 persist"
5. Finding 18: documents the boundary-form regression and the alternative fix
6. Finding 19: explains why R-4 persist from issue-acceptance is stale

## Iter-3 judgment findings

### §9 vs §11 confirmed

Read ADR-054:
- `### 9. Per-stage router configuration surface` exists as an unchanged section (line ~371)
- `### Amendment (2026-10-12, #1944) — §11: per-run wall-clock limit` is the new section
- The `## Enforced by` section (line 542) only covers §11 entries
- ADR-054 is NOT in config/adr-enforcement-baseline.txt (removed by implementation)

R-9 says "ADR-054 §9" but that was a draft-numbering error. The correct section is §11. SPEC-6 reflects §11. This is covered.

Note: The implementation has only added ## Enforced by entries for §11. Sections §1-§10 lack ## Enforced by entries but ADR-054 has been removed from the baseline. This would cause lint to fail unless §1-§10 also get ## Enforced by entries. However, this is a BUILD/implementation concern, not a DESIGN gap — the SPEC says "baseline no longer lists ADR-054" and the lint will enforce the consequence.

### R-9 coverage verdict

SPEC-6 covers R-9:
- ADR-025 gets ## Enforced by entries ✓
- ADR-054 §11 (the per-run limit section) gets ## Enforced by entries ✓
- Baseline removal forces all existing sections to get ## Enforced by entries via lint ✓

### All requirements: COVERED

- R-1: SPEC-1 (timed_out status, in-flight stage name, limit_s in pipeline.end) ✓
- R-2: SPEC-1 (watchdog fires between dispatches, not only inside a stage) ✓
- R-3: SPEC-1 (TERM-ignoring stage dead within TERM+10s) ✓
- R-4: SPEC-1 (release and persist always_run stages execute on timed-out exit path) ✓
- R-5: SPEC-2 (precedence template > env > 20700; non-integer/non-positive refused) ✓
- R-6: SPEC-3 (status unchanged after normal run; abort sentinel absent after sleep) ✓
- R-7: SPEC-4 (get_resume_recommendation=manual_resume_only; resumed run completes) ✓
- R-8: SPEC-5 (no CI env var references in limit-resolution code) ✓
- R-9: SPEC-6 (ADR-025 amended; ADR-054 §11 with ## Enforced by; baseline updated) ✓
- R-10: SPEC-1 covers tag (all SPECs passing = npm test + lint green) ✓

## Prior pass notes (iter-2, carried forward)

### Root cause of 3 remaining timeouts (Bug A incomplete)

The `>/dev/null 2>&1 &` redirect closes fds 1 and 2. BUT:
- At line 2745 (BEFORE watchdog arm): `exec {_RUNNER_ERR_FD}>&2`
- This opens _RUNNER_ERR_FD = some fd >= 10 = fd 2 = pipe write end
  (when runner is inside `$(bash "$RUNNER" ... 2>&1)`)
- Watchdog subshell inherits _RUNNER_ERR_FD = pipe write end
- `>/dev/null 2>&1` does NOT close _RUNNER_ERR_FD
- Orphaned sleep holds _RUNNER_ERR_FD open indefinitely
- $() waits for all pipe write end holders → hangs

FIX (revised): `exec {_RUNNER_ERR_FD}>&- || true` inside watchdog body (NOT at boundary)

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
- `trap ':' INT TERM` ends with ` INT TERM` not `' TERM` → NOT matched by new pattern ✓
- The startup install `trap '_runner_signal_trap TERM' TERM` ends with `' TERM`. ✓

### Key code locations (runner.sh)

- exec {_RUNNER_ERR_FD}>&2: line 2745
- _runner_abort_trap defined: line 2529 (inside main())
- trap ':' INT TERM guard in abort trap: line 2539
- trap '_runner_signal_trap TERM' TERM startup install: line 2753
- Watchdog arm: lines 2804-2830
- Watchdog launch line: line 2829
- exec 3>&2 (fd 3, AFTER watchdog arm): line 2841
