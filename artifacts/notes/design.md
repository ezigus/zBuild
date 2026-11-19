# Design notes — issue #1764 GitHub label claim (round 28)

## Changes this round (fixes for 4 findings from rejected design)

### Finding 1 & 2 — RQCLA-13 and RQARC-1 (release half) not covered

The rejected design had DSCLA-18 covering `claim_coordinator_claim` calling `gh issue edit` (claim
side of RQARC-1 + RQCLA-12) but nothing testing that `claim_coordinator_release` also calls
`gh issue edit`. DSCLA-5/6/7/13 only tested end-state (label absent); they would pass even if
`runner.sh` directly called `gh`, bypassing the coordinator.

Fix: Added DSCLA-20[code] specifically testing `claim_coordinator_release` calls `gh issue edit`
to remove `zbuild:claimed`. Covers RQCLA-13 and the release-half of RQARC-1.

### Finding 3 — RQARC-2 for `zbuild_claim_release` not covered

DSCLA-19 covered `zbuild_claim_acquire` having no direct `gh` calls, but `zbuild_claim_release`
in `core/claim/claim.sh` is equally "under core/" and also must not call `gh` directly.

Fix: Added DSCLA-21[code] testing `zbuild_claim_release` delegates to `claim_coordinator_release`
and makes no direct `gh` calls. Covers the release path of RQARC-2.

### Finding 4 — shape-change-paths step has no requirement backing

No requirement names `config/shape-change-paths.txt`. Removed the step entirely.

## Architecture summary

Dependency arrow: runner.sh → claim.sh → plugin.sh (one direction only).
- plugin.sh MUST NOT source claim.sh (circular dependency removed in first step)
- claim.sh calls public hooks claim_coordinator_claim / claim_coordinator_release
- claim_coordinator_claim returns {"acquired": bool, "holder": "..."} JSON
- core/ never calls gh directly for labels (RQARC-2)
- gh calls happen only inside plugins/claim-coordinator/github-labels/plugin.sh (RQARC-1)

## Base code confirmed

- core/claim/claim.sh: does NOT exist (must be created)
- plugins/claim-coordinator/github-labels/plugin.sh: uses claimed:<machine>, base code has no source of claim.sh
- Working copy plugin.sh: had circular source block (removed per first step)

## Requirements coverage

- RQCLA-1: DSCLA-1
- RQCLA-2: DSCLA-2, DSCLA-12
- RQCLA-3: DSCLA-3
- RQCLA-4: DSCLA-9, DSCLA-15
- RQCLA-5: DSCLA-5, DSCLA-11
- RQCLA-6: DSCLA-6, DSCLA-11, DSCLA-16
- RQCLA-7: DSCLA-7, DSCLA-11
- RQCLA-8: DSCLA-8, DSCLA-17
- RQCLA-9: DSCLA-3
- RQCLA-10: DSCLA-10
- RQCLA-11: DSCLA-13
- RQCLA-12: DSCLA-1, DSCLA-18
- RQCLA-13: DSCLA-20
- RQLAB-1: DSCLA-1
- RQLAB-2: DSCLA-1
- RQADR-1: DSADR-4
- RQADR-2: DSADR-5
- RQADR-3: DSADR-6
- RQADR-4: DSADR-7
- RQADR-5: DSADR-8
- RQDOC-1: DSCLA-14
- RQARC-1: DSCLA-18 (claim), DSCLA-20 (release)
- RQARC-2: DSCLA-19 (acquire path), DSCLA-21 (release path)

## SPEC id high-water marks
- DSCLA: 21 (1 removed: DSCLA-4)
- DSADR: 8

## UNCLEAR
RQADR-2: "holder is in the run-status comment." Assumed: ADR-064 comment (run-status-comment.sh),
not a new one.
