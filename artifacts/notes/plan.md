# Plan notes — issue #1944 (run-level wall-clock limit) — cycle 10 (design findings incorporated)

## Status
Plan.json updated in cycle 10 to address two outstanding bugs identified by the design stage
that were not reflected in the cycle-9 plan.

## Design-stage findings that required plan changes in cycle 10

### Bug A remaining (Finding 16 in design.md)
- The partial Bug A fix (`>/dev/null 2>&1 &`) was applied in a prior commit, but the
  integration tests STILL time out.
- Root cause: `exec {_RUNNER_ERR_FD}>&2` at runner.sh:2743 opens a high-numbered fd pointing
  to fd 2. When the runner is invoked inside `$(bash ... 2>&1)`, fd 2 is the pipe write end.
  The watchdog subshell inherits `_RUNNER_ERR_FD` (fd ≥ 10). The `2>&1` redirect in
  `>/dev/null 2>&1 &` only covers fds 1 and 2; `_RUNNER_ERR_FD` is NOT covered. The orphaned
  `sleep` child (from the SIGKILL'd watchdog) holds `_RUNNER_ERR_FD` indefinitely, keeping the
  pipe write end open, so `$(bash ...)` hangs until the sleep expires.
- Fix: change `    ) >/dev/null 2>&1 &` to `    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &`
  at the watchdog arm site (runner.sh:2827).
- Old step-5 said "redirect stdout and stderr to /dev/null" — that partial fix is done. The
  remaining step is adding `{_RUNNER_ERR_FD}>&-`.

### Bug C regression (Finding 17 in design.md)
- The Bug B fix (commit 741c8466) added `trap ':' INT TERM` inside `_runner_abort_trap()`,
  which is a nested function defined inside main(). This guard line ends with `INT TERM`.
- The existing `runner-signal-rearm-test.sh` SPEC-5 uses awk pattern `/trap .* TERM$/` to
  find the startup trap install. Because `_runner_abort_trap` is defined BEFORE the startup
  install in main(), the awk pattern matches the guard `trap ':' INT TERM` FIRST.
- `grep -oE "trap '[^']+' TERM"` does not match `trap ':' INT TERM` (two-signal form), so
  `_startup_term` = `<startup-not-found>` ≠ `_rearm_term`. Test fails.
- Fix: narrow awk pattern from `/trap .* TERM$/` to `/trap '.*' TERM$/` (requires a
  single-quoted handler before `TERM`), skipping the two-signal guard.
- `tests/unit/runner-signal-rearm-test.sh` was NOT in any step's areas in the cycle-9 plan.

### Already-done items removed from step-5 in cycle 10
- Bug B (double-SIGTERM guard in `_runner_abort_trap`): fixed in commit 741c8466
- Persist in always_run: fixed in prior commit (Finding 5 in design.md says "Fixed")
- The `>/dev/null 2>&1 &` partial fix (Bug A partial): applied in a prior commit

## Acceptance criteria coverage (unchanged from cycle 9)
- AC-1 timed_out with in-flight stage name + limit → step-3
- AC-2 watchdog fires during inter-dispatch idle (falsifiable P2) → step-3
- AC-3 whole process group dies (TERM → KILL 10 s) → step-3
- AC-4 release and persist run after timed_out → step-3 + step-5 (persist already in always_run)
- AC-5 precedence layers + validation → step-1 + step-6
- AC-6 run inside limit untouched, watchdog gone → step-2
- AC-7 resumed run gets fresh limit → step-4
- AC-8 same locally and CI, no platform branch → SPEC-5 (open question on adequacy)
- AC-9 ADR-054 §11 + ADR-025 Enforced by entries → step-9
- AC-10 npm test + npm run lint green → all steps collectively

## Coverage matrix after cycle 10 update
| Finding        | Step                                                                      |
|----------------|---------------------------------------------------------------------------|
| F1: Syntax error run-limit-precedence-test.sh L173         | step-1 (fixed in prior commit) |
| F2: lint-test-errexit 8 files                              | steps 1–4 (fixed in prior commit) |
| F3: Integration test timeouts (Bug A remaining)            | step-5 (description updated: {_RUNNER_ERR_FD}>&-) |
| F4: template.sh inert                                      | step-6 (cleared per Finding 9) |
| F5: run-open-items.sh untested                             | step-7 (fixed per Finding 10) |
| F6: persist missing from always_run test                   | step-3 (fixed in prior commit) |
| F7: P2 unfalsifiable                                       | step-3 (fixed in prior commit) |
| F8: SPEC-2 disposition=misconfigured missing               | step-1 |
| F9: SPEC-3 watchdog PID not proved gone                    | step-2 (fixed per Finding 11) |
| F10: Golden files not updated                              | step-8 |
| F11: ADR-054 §11 Enforced by entries                       | step-9 |
| F12: SPEC-5 finite CI variable list                        | open question |
| F13: SPEC-3 state-file re-read missing                     | step-2 (fixed per Finding 11) |
| F14: Watchdog fires during EXIT trap, killing release      | step-5 (Bug B fixed in commit 741c8466; AC-4 covered by step-3+step-5) |
| Bug A remaining: {_RUNNER_ERR_FD}>&- not yet closed        | step-5 (description updated) |
| Bug B: double-SIGTERM guard                                | DONE (commit 741c8466; removed from step-5) |
| Bug C: runner-signal-rearm-test.sh awk regression          | step-5 (areas + description updated, new file added) |
| D-A: fd inheritance root cause                             | step-5 (description updated to {_RUNNER_ERR_FD}>&-) |
| D-B: double-SIGTERM aborts EXIT trap                       | DONE (removed from step-5) |
| D-C: pipeline-end golden files                             | step-8 (areas already correct from cycle 9) |
| D-D: ADR-025 missing from step-9 areas                    | step-9 (areas already correct from cycle 9) |

## Open questions (unchanged from cycle 9)
1. ADR §9 vs §11 numbering: design confirmed §11 is correct; "§9" in issue text is a stale draft label
2. SPEC-5 finite CI variable list: whether enumerated-set grep covers the open-ended category
3. SPEC-4 NEGCTL wiring: reverting only runner.sh leaves core/state/resume.sh new; both listed in WIRING
