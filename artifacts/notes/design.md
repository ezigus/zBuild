# Design notes — issue #1764 GitHub label claim (round 19)

## Critical fix this round: DSCLA-10 restored to [code] with Given/When/Then

Design finding 1 from the rejected run said DSCLA-10 was [no-code] but must be [code].
In the design-draft.md before this round, line 145 had `DSCLA-10[no-code]`.
Fixed to [code] with Given/When/Then (matches the passing iter-3-attempt-1 version):
- Given: runner.sh emits pipeline.refused.claimed during a run refusal
- When: the event-schema emitted-coverage check runs against the codebase
- Then: the check exits without reporting pipeline.refused.claimed as an unregistered event name

The design checker requires [code] because adding pipeline.refused.claimed to event-schema.json
changes behaviour: the coverage check passes for this event name where it would fail before.

The previous round's answer tried to change to [no-code] — the design checker rejected that.
Going back to [code] with Given/When/Then is the correct fix.

## Supersedes block removed

All supersedes entries were stale. Verified against actual test files:
- claim-coordinator-unit-test.sh: DSCLA-2 assertions say "gh issue comment was NOT called"
  (already aligned — no separate claim comment)
- claim-coordinator-unit-test.sh: no DSCLA-4 assertions exist (DSCLA-4 was REMOVED)
- teardown-repeat-signal-test.sh: DSCLA-5/6/7 assertions check zbuild:claimed absence (correct)
- teardown-repeat-signal-test.sh: DSCLA-9 reads holder from run-status comment mock (correct)
Since all tests are already correctly aligned with the design, supersedes block is empty → removed.

## New requirements handled (RQDOC-1, RQCLA-11)

DSCLA-13[code] covers RQCLA-11: second TERM during release doesn't prevent label removal.
Mechanism: _runner_abort_trap already does `trap '' INT TERM` early (blocks SIGTERM re-entry
for entire cleanup); zbuild_claim_release also unsets _ZBUILD_CLAIM_ACQUIRED before backend
call (makes second call a no-op). Both layers work together.

DSCLA-14[doc] covers RQDOC-1: README.md must not reference claimed:<machine>.
Current README base code line 9 says "claimed:<machine>". Step and doc SPEC added.

## test-author finding 1: not mine

The finding says the DSCLA-10 test uses grep on the JSON file instead of running the coverage
check. All items are tagged "FIX IN TEST." The design SPEC correctly specifies Given/When/Then.
The test author must rewrite the DSCLA-10 test to run the coverage check, not check file content.

## SPEC code highest used
- DSCLA: 1-14 (DSCLA-4 REMOVED; DSCLA-10=[code]; DSCLA-11=[done]; DSCLA-12=CI render;
  DSCLA-13=second TERM; DSCLA-14=README doc)
- DSADR: 4-8

## Requirements coverage (complete)
- RQCLA-1: DSCLA-1
- RQCLA-2: DSCLA-2, DSCLA-12
- RQCLA-3: DSCLA-3
- RQCLA-4: DSCLA-9
- RQCLA-5: DSCLA-5, DSCLA-11
- RQCLA-6: DSCLA-6, DSCLA-11
- RQCLA-7: DSCLA-7, DSCLA-11
- RQCLA-8: DSCLA-8
- RQCLA-9: DSCLA-3
- RQCLA-10: DSCLA-10
- RQCLA-11: DSCLA-13
- RQLAB-1: DSCLA-1
- RQLAB-2: DSCLA-1
- RQADR-1: DSADR-4
- RQADR-2: DSADR-5
- RQADR-3: DSADR-6
- RQADR-4: DSADR-7
- RQADR-5: DSADR-8
- RQDOC-1: DSCLA-14

## Key architectural decisions (unchanged from prior rounds)

Dependency direction: runner.sh -> claim.sh -> plugin.sh (one direction only).
Path resolution: claim.sh uses $_ZBUILD_ROOT (set by runner.sh). No $(cd ...) subshell.
Holder string: Local: run_id=X machine=${HOSTNAME} (bash built-in, no fork).
  CI: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}.
  Built before sidecar spawn so sidecar inherits via environment.
RQCLA-11: _runner_abort_trap `trap '' INT TERM` guard blocks SIGTERM re-entry.
  zbuild_claim_release unsets _ZBUILD_CLAIM_ACQUIRED before gh call (no-op on re-entry).
Run-status comment: ADR-064 comment (scripts/lib/run-status-comment.sh), not a new one.
  Holder added via <!-- zbuild-holder: --> HTML comment in rsc_render_header.

## UNCLEAR (unchanged)
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment, not a new one.
