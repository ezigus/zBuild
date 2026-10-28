# Plan notes — issue #1944 (run-level wall-clock limit) — cycle 12 (design Finding 24 / Bug D added)

## Status
Plan.json updated in cycle 12 to add step-8 (Bug D) and revise old step-8 → step-9 (golden
files, event-sequence files removed from scope), old step-9 → step-10 (ADR amendments).

## What changed from cycle 11

### New step-8: Bug D (orphaned watchdog sleep)
Design Finding 24 identified a new defect still in the worktree:
- The EXIT trap's watchdog cleanup sends SIGKILL to the watchdog bash PID only.
- The watchdog's `sleep "$_wdg_lim"` child inherits SIGTERM=SIG_IGN (POSIX: SIG_IGN
  is inherited across exec) from the watchdog's `trap '' TERM`.
- After SIGKILL kills the watchdog bash PID, the sleep child is orphaned and reparented
  to PID 1; it holds `_RUNNER_ERR_FD` (the pipe write end) open for up to 20700 s.
- The test framework's `_kill_test_children` (test-helpers.sh:114) calls bare `wait`,
  blocking until ALL background descendants are done, hitting the 480 s test timeout.
- Fix: `pgrep -P "${_RUNNER_WATCHDOG_PID}"` BEFORE SIGKILL collects children; then
  SIGKILL both watchdog PID and children.
- `tests/integration/sigterm-aborts-pipeline-test.sh` (an existing test for #686) is
  the test that regresses on this defect and is added to step-8's areas.

### Old step-8 (golden files) → new step-9, event-sequence files removed
Design clarified: "Golden files contain NO new content from this change; the normal-run
event sequence is unaffected. The shape-floor check flags the two event-sequence golden
files only because `_SF_FAILED_COUNT > 0` (sigterm-aborts failing). Once Bug D is fixed
and sigterm-aborts passes, `_SF_FAILED_COUNT == 0` and the shape-floor check auto-verifies
the golden files with no content change needed."
- Removed from step-9 areas: tests/golden/full-pipeline/event-sequence.golden,
  tests/golden/parity/event-sequence.golden
- Kept in step-9 areas: timed_out-w80.colored.txt, timed_out-w80.layout.txt,
  runner-pipeline-end-test.sh (these are new/updated pipeline-end rendering files)

### Old step-9 (ADR amendments) → new step-10
Unchanged in content; renumbered to step-10.

## Acceptance criteria coverage (updated for cycle 12)
- AC-1 timed_out with in-flight stage name + limit → step-3
- AC-2 watchdog fires during inter-dispatch idle (falsifiable P2) → step-3
- AC-3 whole process group dies (TERM → KILL 10 s) → step-3 + step-8 (Bug D)
- AC-4 release and persist run after timed_out → step-3
- AC-5 precedence layers + validation → step-1 + step-6
- AC-6 run inside limit untouched, watchdog gone → step-2 + step-8 (Bug D: no orphan)
- AC-7 resumed run gets fresh limit → step-4
- AC-8 same locally and CI, no platform branch → SPEC-5 (open question on adequacy)
- AC-9 ADR-054 §11 + ADR-025 Enforced by entries → step-10
- AC-10 npm test + npm run lint green → all steps collectively

## Design-stage confirmed status per step (cycle 12)
- step-1: DONE (syntax error + lint-test-errexit + SPEC-2 misconfigured)
- step-2: DONE (run-watchdog-clean-exit-test.sh SPEC-3 state-file re-read)
- step-3: DONE (run-timed-out-test.sh lint + P2 falsifiability + persist P4)
- step-4: DONE (resume-after-run-timeout-test.sh lint + SPEC-4 timing)
- step-5: DONE (Bug A inside-body form + Bug C awk pattern)
- step-6: DONE (template.sh wiring + template-layer test)
- step-7: DONE (run-open-items-test.sh timed_out arm)
- step-8: OUTSTANDING — Bug D: pgrep children before SIGKILL in EXIT trap watchdog cleanup
- step-9: OUTSTANDING — pipeline-end timed_out golden files
- step-10: OUTSTANDING — ADR-054 §11 + ADR-025 Enforced by

## Coverage matrix (cycle 12 — adds Bug D)
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
| F10/D-C: Golden files not updated                   | step-9 (outstanding, event-seq removed) |
| F11: ADR-054 §11 Enforced by entries                | step-10 (outstanding)       |
| F12: SPEC-5 finite CI variable list                 | open question               |
| F13: SPEC-3 state-file re-read missing              | step-2 (done)               |
| F14: Watchdog fires during EXIT trap                | step-3+step-5 (done)        |
| Bug A: boundary form regresses release exit path    | step-5 (inside-body, done)  |
| Bug B: double-SIGTERM aborts EXIT trap              | DONE (commit 741c8466)      |
| Bug C: runner-signal-rearm awk pattern regression   | step-5 (awk fix, done)      |
| Bug D: orphaned watchdog sleep (Finding 24)         | step-8 (outstanding)        |
| D-A: fd inheritance root cause                      | step-5 (inside-body, done)  |
| D-B: double-SIGTERM aborts EXIT trap                | DONE (removed from step-5)  |
| D-D: ADR-025 missing from step-9 areas             | step-10 (correct)           |
| F18: boundary form regresses runner-release-exit-paths | step-5 areas (done)      |
| F24: sigterm-aborts-pipeline-test 480 s hang       | step-8 (outstanding)        |

## Open questions (cycle 12 — one remaining)
1. SPEC-5 finite CI variable list: whether enumerated-set grep covers the open-ended
   "no platform variable" category — confirm whether the finite-list approach is accepted
   as sufficient coverage or whether the test must be extended.
