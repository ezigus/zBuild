# Build Notes — #1764 GitHub Label Claim

## Status: All acceptance tests pass; open findings answered

## Test results (latest run — all PASS)
- claim-coordinator-unit-test.sh: 38/38 PASS
- teardown-repeat-signal-test.sh: 29/29 PASS (from previous run)
- lint-adr-enforced-by-test.sh: 29/29 PASS

## Code state: complete and correct

All design steps implemented (confirmed by git diff 0ea71164..HEAD).

The latest commit (12e9cf5e) added only: §1(b) enforcement entry in ADR-005 ## Enforced by section
(`§1(b) enforcement plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`)

git diff HEAD only shows changes to docs/adr/ADR-005-claim-coordinator.md.

## Finding history and resolution

### BUFND-3 through BUFND-9 (from iter-1-attempt-15)
These were opened because in attempt-15 I had no answers for steps 1, 2, 3, 4, 5, 6, 8.
In attempt-16 (the current run), those steps were answered correctly by the build stage output:
- step 1: done (quote: _ccgl_read_holder() {)
- step 3: done (quote: printf '<!-- zbuild-holder: ...')
- step 4: done (quote: zbuild_claim_acquire() {)
- step 5: done (quote: "pipeline.refused.claimed",)
- step 6: done (quote: eb_emit_event "pipeline.refused.claimed")
- step 8: done (quote: - §4 (cross-machine exclusion...))
- step 2: needs "not needed" answer (README was done in prior commit, not in git diff HEAD)
Findings are now "wrong" — step answers present in current build output.

### BUFND-10 (from current run — step 7, no quote)
Step 7 requires quoting from ADR-005. The §1(b) entry IS in git diff HEAD:
  `§1(b) enforcement plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh`
Answer: done — quote from docs/adr/ADR-005-claim-coordinator.md.

### BUFND-11 (from current run — step 2 wrong quote)
README.md was not changed in the latest commit (12e9cf5e). The build stage's "this change"
refers to the current iteration's diff (git diff HEAD), not the full branch diff.
README.md was updated in commit 236cf897 (prior iteration) with zbuild:claimed content.
Answer: wrong — step 2 is not needed; README already correct from prior iteration.

### RLPERFORMANCE-1 (non-blocking)
Wrong — not reproduced. claim.sh uses jq for acquired extraction (commit 0052daee).

### RLREDTEAM-3
Wrong — not reproduced. The unfiltered fallback in _ccgl_read_holder was removed in commit
0052daee. Only actor-filtered gh api call remains; empty body → function returns empty.
