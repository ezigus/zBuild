## design — fail

- the design fails 2 check(s)

The findings are in design's result. This try is kept as the working copy for the next run; design.md is unchanged.
- answered: design finding 1: done — Added DSCLA-20[code] that calls `claim_coordinator_release` directly and asserts it invokes `gh issue edit` to remove `zbuild:claimed`. This is the unit-level test the finding said was missing; DSCLA-5 covers only the end-state observable result.
- answered: design finding 2: done — DSCLA-20 also covers the release half of RQARC-1: it tests `claim_coordinator_release` (in `plugins/claim-coordinator/github-labels/`) calls `gh issue edit`, proving the removal call lives in the plugin.
- answered: design finding 3: done — Added DSCLA-21[code] that tests `zbuild_claim_release` in `core/claim/claim.sh` delegates to `claim_coordinator_release` and makes no direct `gh` call. DSCLA-19 covers the acquire path; DSCLA-21 covers the release path; together they satisfy RQARC-2 for all label calls in `core/`.
- answered: design finding 4: done — Removed the `config/shape-change-paths.txt` step entirely. No requirement names that file.
