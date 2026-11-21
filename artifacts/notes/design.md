# Design notes — issue #1764 GitHub label claim (round 34)

## Status

One open finding addressed this round:

**RLREDTEAM-2**: `_ccgl_read_holder` as designed read `last` from all comments matching the
`<!-- zbuild-run-status -->` marker, with no authentication check. Any GitHub user who can
comment on the issue could displace the holder string by posting a spoofed comment. Fixed in
the design by:
- Decision section: added requirement that `_ccgl_read_holder` calls `gh api user --jq .login`
  to get the authenticated actor, then filters comments to only those with `user.login` matching
  that value before scanning for the `<!-- zbuild-holder: -->` field. Local-fs test backend reads
  from `ZBUILD_CLAIM_STORE` per-issue file (no GitHub comments in that backend).
- Step 1 (plugin.sh): updated to mention the authenticated-actor filter.
- Added DSCLA-23[code] SPEC: when `_ccgl_read_holder` reads the holder, it uses only comments
  authored by the authenticated GitHub actor, not arbitrary user comments.

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
