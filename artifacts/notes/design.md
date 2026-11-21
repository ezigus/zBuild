# Design notes — issue #1764 GitHub label claim (round 33)

## Status

Two findings from the previous round fixed:

**DSFND-1**: DSADR-7 now explicitly names [DSCLA-1] as the test enforcing the §2 "shared label
is zbuild:claimed (no hostname)" statement in the ADR-005 Enforced by section. The corresponding
step was also updated to mention this addition.

**DSFND-2**: The UNCLEAR RQADR-2 line was removed. The issue's Terms section defines
"Run-status comment" as the existing ADR-064 comment (scripts/lib/run-status-comment.sh) — not
a new one — so there is nothing unclear to record.

## Architecture summary

Dependency arrow: runner.sh → claim.sh → registry.sh; claim.sh → plugin_hook_call → [subshell: plugin.sh]
- plugin.sh MUST NOT source claim.sh (no circular dependency)
- claim.sh DOES NOT source plugin.sh directly
- claim.sh sources registry.sh (idempotent)
- claim.sh uses discover_plugins to find coordinator by kind at call time
- claim.sh calls plugin_hook_call for claim/release hooks
- core/ never calls gh directly for labels (RQARC-2)
- gh calls happen only inside plugins/claim-coordinator/github-labels/plugin.sh (RQARC-1)
- When issue is empty: zbuild_claim_acquire returns 0 immediately, no discover_plugins, no hook
- When _ZBUILD_CLAIM_ACQUIRED unset: zbuild_claim_release returns 0 immediately, no hook

## Load order

runner.sh: sources claim.sh before registry.sh
claim.sh sources registry.sh at its own top (idempotent guard prevents double-load)
Registry is available when claim.sh's functions are defined and when they are called.

## Requirements coverage

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
- RQCLA-12: DSCLA-1, DSCLA-18
- RQCLA-13: DSCLA-20
- RQCLA-14: DSCLA-22
- RQLAB-1: DSCLA-1
- RQLAB-2: DSCLA-1
- RQADR-1: DSADR-4
- RQADR-2: DSADR-5
- RQADR-3: DSADR-6
- RQADR-4: DSADR-7 (§2 now names DSCLA-1 for label-name statement, plus DSCLA-2/DSCLA-12 for holder rendering)
- RQADR-5: DSADR-8
- RQDOC-1: DSCLA-14
- RQARC-1: DSCLA-18 (claim), DSCLA-20 (release)
- RQARC-2: DSCLA-19 (acquire), DSCLA-21 (release)
- RQARC-3: DSCLA-22

## SPEC id high-water marks
- DSCLA: 22 (1 removed: DSCLA-4)
- DSADR: 8
