# Plan notes — issue #1944 (run-level wall-clock limit) — cycle 11 (design stage confirmed)

## Status
Plan.json updated in cycle 11 to reflect design-stage confirmation of all three bugs fixed
and two resolved open questions removed.

## What changed from cycle 10

### Step-5 description corrected (Bug A fix form)
The cycle-10 plan described the Bug A fix as changing the watchdog launch line to
`    ) >/dev/null 2>&1 {_RUNNER_ERR_FD}>&- &` (boundary form).
The design stage (Finding 18) confirmed the boundary form was TESTED and caused a
regression: `runner-release-exit-paths-test.sh` SPEC-5 (release not dispatched on
hard-kill path). The correct fix is to add `exec {_RUNNER_ERR_FD}>&- || true` as the
SECOND LINE INSIDE the watchdog subshell body (after `trap '' TERM`, before
`_wdg_lim=`). The launch line stays `>/dev/null 2>&1 &`.
Design confirms this form is applied at runner.sh:2818 and passes.

### Step-5 areas updated — runner-release-exit-paths-test.sh added
Finding 18 identified that `tests/integration/runner-release-exit-paths-test.sh` exercises
the SIGTERM abort path through the watchdog disarm, which the watchdog arm change touches.
This file was missing from step-5's areas in cycle 10; added now.

### Open questions resolved by design stage
- OQ #1 (ADR §9 vs §11): Design confirmed §11 is correct; the issue text contained a stale
  draft section number. SPEC-6 already uses §11. Resolved — removed from plan.
- OQ #3 (SPEC-4 NEGCTL wiring): Design Finding 15 added core/state/resume.sh to WIRING.
  The resume recommendation for timed_out is implemented there. Resolved — removed from plan.
- OQ #2 (SPEC-5 finite CI variable list) remains open.

## Acceptance criteria coverage (unchanged from cycle 9/10)
- AC-1 timed_out with in-flight stage name + limit → step-3
- AC-2 watchdog fires during inter-dispatch idle (falsifiable P2) → step-3
- AC-3 whole process group dies (TERM → KILL 10 s) → step-3
- AC-4 release and persist run after timed_out → step-3
- AC-5 precedence layers + validation → step-1 + step-6
- AC-6 run inside limit untouched, watchdog gone → step-2
- AC-7 resumed run gets fresh limit → step-4
- AC-8 same locally and CI, no platform branch → SPEC-5 (open question on adequacy)
- AC-9 ADR-054 §11 + ADR-025 Enforced by entries → step-9
- AC-10 npm test + npm run lint green → all steps collectively

## Design-stage confirmed status per step
- step-1: Syntax error + lint-test-errexit + SPEC-2 misconfigured — fixed in prior commit
- step-2: run-watchdog-clean-exit-test.sh SPEC-3 state-file re-read — fixed and passing
- step-3: run-timed-out-test.sh lint + P2 falsifiability + persist P4 — fixed and passing
- step-4: resume-after-run-timeout-test.sh lint + SPEC-4 timing — fixed and passing
- step-5: Bug A inside-body form (runner.sh:2818) + Bug C awk pattern (runner-signal-rearm-test.sh:92) — fixed and passing per Finding 20
- step-6: template.sh wiring + template-layer test — cleared per Finding 9
- step-7: run-open-items-test.sh timed_out arm — fixed and passing per Finding 10
- step-8: golden files — scope listed in design; update still required
- step-9: ADR-054 §11 + ADR-025 Enforced by — listed in design scope; amendment still required

## Coverage matrix (cycle 11)
| Finding        | Step                                                                              |
|----------------|-----------------------------------------------------------------------------------|
| F1: Syntax error run-limit-precedence-test.sh L173  | step-1 (done)               |
| F2: lint-test-errexit 8 files                       | steps 1–4 (done)            |
| F3: Integration test timeouts (Bug A)               | step-5 (inside-body fix, done) |
| F4: template.sh inert                               | step-6 (done)               |
| F5: run-open-items.sh untested                      | step-7 (done)               |
| F6: persist missing from always_run test            | step-3 (done)               |
| F7: P2 unfalsifiable                                | step-3 (done)               |
| F8: SPEC-2 disposition=misconfigured missing        | step-1 (done)               |
| F9: SPEC-3 watchdog PID not proved gone             | step-2 (done)               |
| F10: Golden files not updated                       | step-8 (outstanding)        |
| F11: ADR-054 §11 Enforced by entries                | step-9 (outstanding)        |
| F12: SPEC-5 finite CI variable list                 | open question               |
| F13: SPEC-3 state-file re-read missing              | step-2 (done)               |
| F14: Watchdog fires during EXIT trap                | step-3+step-5 (done)        |
| Bug A: boundary form regresses release exit path    | step-5 (inside-body, done)  |
| Bug B: double-SIGTERM aborts EXIT trap              | DONE (commit 741c8466)      |
| Bug C: runner-signal-rearm awk pattern regression   | step-5 (awk fix, done)      |
| D-A: fd inheritance root cause                      | step-5 (inside-body, done)  |
| D-B: double-SIGTERM aborts EXIT trap                | DONE (removed from step-5)  |
| D-C: pipeline-end golden files                      | step-8 (outstanding)        |
| D-D: ADR-025 missing from step-9 areas             | step-9 (correct)            |
| F18: boundary form regresses runner-release-exit-paths | step-5 areas updated      |

## Open questions (cycle 11 — one remaining)
1. SPEC-5 finite CI variable list: whether enumerated-set grep covers the open-ended
   "no platform variable" category — confirm whether the finite-list approach is accepted
   as sufficient coverage or whether the test must be extended.
