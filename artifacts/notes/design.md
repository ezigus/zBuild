# Design notes — issue #1764 GitHub label claim (round 17)

## What was changed this round

### DSCLA-10: Reverted to iter-3-attempt-1 formulation (design check violation fix)
The design-draft for round 16 had:
  When: config/event-schema.json is searched for the string "pipeline.refused.claimed"
  Then: the string "pipeline.refused.claimed" is found in the file
The Then violates the SPEC rule "never what a file contains." Reverted to iter-3-attempt-1
version that passed the design check:
  Given: zbuild:claimed is on the issue
  When: the run is refused and emits pipeline.refused.claimed
  Then: the event-schema emitted-coverage check does not fail on pipeline.refused.claimed as an unregistered event
This is an observable behavior (the check's pass/fail), not file content.

### DSADR-7: Extended to cover §2 Enforced by with DSCLA-12 (design finding 1 fix)
Previous DSADR-7 only mentioned §1(c) with DSCLA-3/DSCLA-9. The design check found it silent
about adding DSCLA-12 to the §2 Enforced by bullet. DSADR-7 now explicitly says the ## Enforced
by section in ADR-005 must name DSCLA-12 for the §2 CI-holder case.

## Open findings from previous work

### issue-acceptance finding 2 (ADR-059 Enforced by "unasked")
The issue-acceptance says no requirement asks for the Enforced by entry in ADR-059 for the §4
cross-machine statement. CLAUDE.md requires "A new or changed statement ships with its test in the
same PR." Since RQADR-5 adds a new §4 statement, CLAUDE.md mandates the Enforced by entry.
The design retains this in DSADR-8 and the ADR-059 step. The design prose calls this out explicitly.

## SPEC codes highest used
DSCLA: 1-12 (DSCLA-4 removed via REMOVED line; DSCLA-10 = event-schema; DSCLA-11 = [done]; DSCLA-12 = CI render case)
DSADR: 4-8 (all this issue)

## ADR state in base code vs working tree

### Base code ADR-005
Has original content: "The engine has no built-in mechanism", claimed:<machine>, etc.
Working tree ADR-005 (from previous build iteration) has §1-§3 and partial ## Enforced by.
The Enforced by is missing DSCLA-3/DSCLA-9 from §1 bullet and DSCLA-12 from §2 bullet.
The design step and DSADR-7 now explicitly cover all three.

### Base code ADR-059
Has §4 flock text but no claim coordinator mentions. No cross-machine Enforced by entry.
Working tree ADR-059 has §4 cross-machine text but Enforced by is missing for that statement.
The design step adds the Enforced by entry for §4 (required by CLAUDE.md).

## Key architectural decisions

### Dependency direction
runner.sh -> claim.sh -> plugin.sh (one direction only)
No back-reference from plugin.sh to claim.sh. Tests source both explicitly.

### Path resolution
claim.sh uses $_ZBUILD_ROOT (set by runner.sh). No $(cd ...) subshell.

### Holder string
- Local: run_id=X machine=${HOSTNAME} (bash built-in, no fork)
- CI: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}
- Built before sidecar spawn so sidecar inherits via environment

### Run-status comment as the progress comment
ADR-064 comment (scripts/lib/run-status-comment.sh), not a new one.
Holder added via <!-- zbuild-holder: --> HTML comment in rsc_render_header.

### ADR-005 §1 three-statement breakdown
(a) engine calls claim after admission lock, before first stage -> DSCLA-1
(b) engine releases in every EXIT path -> DSCLA-5, DSCLA-6, DSCLA-7
(c) on conflict: emit pipeline.refused.claimed, print holder, return non-zero, no stage -> DSCLA-3, DSCLA-9

### ADR-059 §4 Enforced by
New statement "cross-machine exclusion is the coordinator's job" -> DSCLA-3.
No requirement names this but CLAUDE.md mandates it for new/changed statements.

## UNCLEAR
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment
(scripts/lib/run-status-comment.sh), not a new comment.
