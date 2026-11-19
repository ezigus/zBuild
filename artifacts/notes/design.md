# Design notes — issue #1764 GitHub label claim (round 25)

## Changes this round

### Finding — DSCLA-18 removed (out of scope)

design finding 1 said DSCLA-18 is wrong:
- No issue requirement asks for registering `core/claim/claim.sh` in `config/shape-change-paths.txt`
- The `covers: RQCLA-1` annotation was incorrect (RQCLA-1 is about runtime label behavior, fully
  covered by DSCLA-1)
- The step "Add core/claim/claim.sh to config/shape-change-paths.txt" was out of scope
- Previous round's answer to this finding incorrectly said "done — changed from [no-code] to [code]"
  instead of removing it, which is what the finding actually required

Fixed:
- Removed DSCLA-18 from acceptance block (no REMOVED line since DSCLA-18 was never in a passed design)
- Removed the step "Add core/claim/claim.sh to config/shape-change-paths.txt" from steps block
- Removed "Register core/claim/claim.sh in config/shape-change-paths.txt" from Decision prose
- Removed `REMOVED: DSCLA-4` line (DSCLA-4 was never in a passed design — iter-3-attempt-1
  did not include it, so no REMOVED line is correct per the instructions)

## SPEC codes highest used
- DSCLA: 17 (DSCLA-18 was only in rejected designs; not taken per instructions)
- DSADR: 4–8

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
