# Plan notes — issue #1944 (run-level wall-clock limit) — cycle 9 (design-stage review)

## Status
Plan.json updated in cycle 9 to correct two inaccuracies revealed by the design stage.

## Design-stage findings that required plan changes

### Finding D-A (Bug A: fd inheritance — step-5 mechanism was wrong)
- Old step-5 said "disown the watchdog PID after spawning so bash job-control does not block the runner's exit"
- Design identified the real root cause: watchdog subshell inherits stdout/stderr fds; after watchdog is killed, its orphaned `sleep` child holds the pipe write-end open, so `$(bash "$RUNNER" ...)` hangs until sleep expires
- Correct fix: redirect watchdog to `/dev/null 2>&1 &` at arm time, not disown
- Updated step-5 description accordingly

### Finding D-B (Bug B: double-SIGTERM aborts EXIT trap — step-5 was incomplete)
- GNU `timeout` forwards SIGTERM to its child process group on receiving SIGTERM
- Runner gets two SIGTERMs; second arrives during `wait` in abort trap, re-fires `_runner_signal_trap TERM`, calls `exit 1` from within EXIT trap, aborting `_runner_dispatch_always_run`
- Correct fix: `trap ':' INT TERM` guard before kill/wait block in `_runner_abort_trap`, mirror line 2516 pattern
- Old step-5 described this as "kill the watchdog PID at the very start of the EXIT trap" — inaccurate mechanism
- Updated step-5 to describe the signal-guard fix

### Finding D-C (pipeline-end golden files not in step-8 areas)
- Design scope section includes `tests/golden/pipeline-end/timed_out-w80.colored.txt` and `tests/golden/pipeline-end/timed_out-w80.layout.txt`
- step-8 previously only listed event-sequence goldens
- Added both pipeline-end golden files to step-8 areas and description

### Finding D-D (ADR-025 not in step-9 areas)
- Design scope includes ADR-025-abort-propagation.md which needs Enforced by entries
- step-9 previously only listed ADR-054-stage-contract.md
- Added ADR-025-abort-propagation.md to step-9 areas

## Acceptance criteria coverage (unchanged from cycle 7, verified against design)
- AC-1 timed_out with in-flight stage name + limit → step-3
- AC-2 watchdog fires during inter-dispatch idle (falsifiable P2) → step-3
- AC-3 whole process group dies (TERM → KILL 10 s) → step-3
- AC-4 release and persist run after timed_out → step-3 + step-5
- AC-5 precedence layers + validation → step-1 + step-6
- AC-6 run inside limit untouched, watchdog gone → step-2
- AC-7 resumed run gets fresh limit → step-4
- AC-8 same locally and CI, no platform branch → SPEC-5 (open question on adequacy)
- AC-9 ADR-054 §9/§11 + ADR-025 Enforced by entries → step-9
- AC-10 npm test + npm run lint green → all steps collectively

## Coverage matrix (F1–F14 + D-A/D-B/D-C/D-D → steps)
| Finding | Step |
|---|---|
| F1: Syntax error run-limit-precedence-test.sh L173 | step-1 (already fixed per design) |
| F2: lint-test-errexit 8 files | steps 1–4 (already fixed per design) |
| F3: Integration test timeouts (fd inheritance, not disown) | step-5 (description corrected) |
| F4: template.sh inert | step-6 |
| F5: run-open-items.sh untested | step-7 |
| F6: persist missing from always_run test | step-3 (already fixed per design) |
| F7: P2 unfalsifiable | step-3 (already fixed per design) |
| F8: SPEC-2 disposition=misconfigured missing | step-1 |
| F9: SPEC-3 watchdog PID not proved gone | step-2 |
| F10: Golden files not updated | step-8 |
| F11: ADR-054 §11 Enforced by entries | step-9 |
| F12: SPEC-5 finite CI variable list | open question |
| F13: SPEC-3 state-file re-read missing | step-2 |
| F14: Watchdog fires during EXIT trap, killing release | step-5 (mechanism corrected to signal-guard) |
| D-A: fd inheritance root cause (not disown) | step-5 (corrected) |
| D-B: double-SIGTERM aborts EXIT trap | step-5 (corrected) |
| D-C: pipeline-end golden files missing from step-8 | step-8 (areas + description updated) |
| D-D: ADR-025 missing from step-9 areas | step-9 (areas updated) |

## Open questions (unchanged)
1. ADR §9 vs §11 numbering: design confirmed §11 is correct; issue text using §9 is a stale draft label
2. Test timeout root cause contingency: design confirmed fd inheritance is the root cause; disown fix not needed
3. SPEC-5 finite CI variable list adequacy: still unresolved
