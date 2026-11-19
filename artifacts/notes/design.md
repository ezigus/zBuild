# Design notes — issue #1764 GitHub label claim (round 22)

## Changes this round: design findings addressed

### Finding 1 — RQCLA-8 release side not covered

DSCLA-8 covers `zbuild_claim_acquire` called with empty issue (no gh call).
But RQCLA-8 says "calls no coordinator hook" — the release hook also must not be called.
The design says `zbuild_claim_release` skips when issue is empty OR `_ZBUILD_CLAIM_ACQUIRED` is unset.
That skip path was untested.

Fixed: Added DSCLA-17[code] — when zbuild_claim_release is called with _ZBUILD_CLAIM_ACQUIRED not
set, no gh label command is invoked. This is the unset-acquired path (goal-only run never sets it).

### Finding 2 — DSCLA-10 When describes a test action, not a software action

Previous round changed DSCLA-10 `When:` to "config/event-schema.json is read" following the
test-author's implementation (direct grep). Design checker correctly rejected this: `When:` must
describe a software action, not how a test verifies. 

Fixed: Restored DSCLA-10 to describe the event-schema emitted-coverage check as the action:
- Given: config/event-schema.json includes an entry for pipeline.refused.claimed
- When: the event-schema emitted-coverage check runs against the codebase
- Then: the check exits without reporting pipeline.refused.claimed as an unregistered event name

The test-author must invoke the coverage check to test this SPEC. The design is authoritative.

## SPEC code highest used
- DSCLA: 1-17 (DSCLA-4 REMOVED; DSCLA-10=[code]; DSCLA-11=[done]; DSCLA-12=CI render;
  DSCLA-13=second TERM; DSCLA-14=README doc; DSCLA-15=sanitization; DSCLA-16=early-failure;
  DSCLA-17=release no-op)
- DSADR: 4-8

## Requirements coverage (complete)
- RQCLA-1: DSCLA-1
- RQCLA-2: DSCLA-2, DSCLA-12
- RQCLA-3: DSCLA-3
- RQCLA-4: DSCLA-9, DSCLA-15
- RQCLA-5: DSCLA-5, DSCLA-11
- RQCLA-6: DSCLA-6, DSCLA-11, DSCLA-16
- RQCLA-7: DSCLA-7, DSCLA-11
- RQCLA-8: DSCLA-8 (acquire no-op), DSCLA-17 (release no-op)
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

## Key architectural decisions (unchanged)

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
