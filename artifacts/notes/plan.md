# Plan notes — issue #1944 (run-level wall-clock limit) — cycle 8 (plan re-entry check)

## Status
Plan.json already reflects cycle 7 updates. No new findings in the "Previous work" section.
No changes to plan.json required.

## What was verified
- plan.json on disk has 9 steps covering all 14 findings (F1–F14) from cycle 7
- step-5 already includes the F14 fix (disarm watchdog at start of EXIT trap + persist in production always_run)
- All 10 acceptance criteria mapped to steps (AC-1 through AC-10)
- No step defers testing or adds inert files
- open_questions: 3 (ADR §9 vs §11 numbering; test timeout root cause contingency; SPEC-5 finite CI variable list adequacy)

## Acceptance criteria coverage (unchanged from cycle 7)
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

## Coverage matrix (F1–F14 → steps)
| Finding | Step |
|---|---|
| F1: Syntax error run-limit-precedence-test.sh L173 | step-1 |
| F2: lint-test-errexit 8 files | steps 1–4 |
| F3: Integration test timeouts (disown missing) | step-5 |
| F4: template.sh inert | step-6 |
| F5: run-open-items.sh untested | step-7 |
| F6: persist missing from always_run test | step-3 |
| F7: P2 unfalsifiable | step-3 |
| F8: SPEC-2 disposition=misconfigured missing | step-1 |
| F9: SPEC-3 watchdog PID not proved gone | step-2 |
| F10: Golden files not updated | step-8 |
| F11: ADR-054 §11 Enforced by entries | step-9 |
| F12: SPEC-5 finite CI variable list | open question |
| F13: SPEC-3 state-file re-read missing | step-2 |
| F14: Watchdog fires during EXIT trap, killing release | step-5 |
