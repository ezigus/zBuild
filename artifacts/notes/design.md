# Design notes — issue #1764 GitHub label claim (round 35)

## Status

8 findings (DSFND-3 through DSFND-10) fixed this round: each step was missing `| serves: <SPEC ids>`.
Added the serves clauses to all 8 steps:

- Step 1 (plugin.sh): serves DSCLA-1, DSCLA-3, DSCLA-9, DSCLA-18, DSCLA-20, DSCLA-23
- Step 2 (README.md): serves DSCLA-14
- Step 3 (run-status-render.sh): serves DSCLA-2, DSCLA-12
- Step 4 (claim.sh): serves DSCLA-8, DSCLA-13, DSCLA-15, DSCLA-17, DSCLA-19, DSCLA-21
- Step 5 (event-schema.json): serves DSCLA-10
- Step 6 (runner.sh): serves DSCLA-1, DSCLA-3, DSCLA-5, DSCLA-6, DSCLA-7, DSCLA-9, DSCLA-13, DSCLA-15, DSCLA-16, DSCLA-22
- Step 7 (ADR-005): serves DSADR-4, DSADR-5, DSADR-6, DSADR-7
- Step 8 (ADR-059): serves DSADR-8

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
- RQCLA-4: DSCLA-9, DSCLA-15, DSCLA-23
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
- RQADR-4: DSADR-7
- RQADR-5: DSADR-8
- RQDOC-1: DSCLA-14
- RQARC-1: DSCLA-18 (claim), DSCLA-20 (release)
- RQARC-2: DSCLA-19 (acquire), DSCLA-21 (release)
- RQARC-3: DSCLA-22

## SPEC id high-water marks
- DSCLA: 23 (1 removed: DSCLA-4)
- DSADR: 8
