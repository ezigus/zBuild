# Build notes — #1805 resume and --from-stage trust-and-rehydrate

## Status: ITERATION 18 — COMPLETE

## Summary of previous iterations
- Iterations 1-13: Core implementation (artifact-persist.sh, runner.sh, cycle-orchestrator.sh, ADRs, tests)
- Iteration 14: All 882 tests passed. issue-acceptance passed. review_lenses found findings.
- Iteration 15: Fixed red-team-1 (from-stage RESUME_ACTIVE clear), red-team-3 (TOCTOU),
  correctness-3 (double-slash), sre-1 (jq warn), sre-2 (cycle.state.write.failed event),
  lens-scope (from-stage without --resume test case), moved --from-stage requires --resume
  check to after auto-resume block. All 882 tests passed.
- Iteration 16: Fixed pipeline-resume-test.sh failure: startup preflight was
  intercepting --from-stage without --resume invocations (PERSONA_MISSING in warn mode
  returns 1). Used `_spg_resume_mode` variable to avoid modifying `resume_mode` itself.
  This broke the SPEC-5 grep test which expects `"$resume_mode"` exactly.
- Iteration 17: Fixed:
  1. Removed eb_emit_event "cycle.state.write.failed" (event not in schema, can't add)
  2. Restored "$resume_mode" call in startup preflight via save/restore approach
  All 885 tests passed.
- Iteration 17 result: test passed (885/885), but issue-acceptance failed with finding 1

## Iteration 18 fix: Amend ADR-006 with full #1805 decision

The issue-acceptance finding says RQADR-1 is not fully met. While step 3.6 is present,
the full decision from the design is not documented. Missing:
1. Dispatch-loop skip guard (trust every stage that ran on resume)
2. Cycle iteration restoration (_ZBUILD_RESUME_ACTIVE + current_iter)
3. --from-stage pre-flight contract
4. Auto-resume state discovery via `latest` symlink
5. Step 3.5 contradicts actual behavior (says "re-run iter N from scratch" / "start iter N+1")

FIX: Added new amendment section at bottom of ADR-006 covering all these items:
- "## Amendment — full resume and --from-stage contract (issue #1805)"
- Section: Cycle iteration restoration (_ZBUILD_RESUME_ACTIVE)
- Section: Dispatch-loop skip guard
- Section: --from-stage <s> pre-flight contract
- Section: Auto-resume state discovery via `latest` symlink

Verified: resume-rehydrate-test.sh still passes 47/47 (DSAMDR-1 test passes).
The existing step 3.6 text is unchanged, so all DSAMDR-1 assertions still pass.

## All tests pass
- resume-rehydrate-test.sh: 47/47 (verified after iteration 18 change)
