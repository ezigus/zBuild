## review-lens-tests — fail

- found 2 findings: 2 medium

- medium: DSRACE-2 names "first by created_at, then id" as the ordering rule, but every test fixture uses distinct created_at values; no fixture has two notes with the same created_at and different ids, so the .id secondary sort in `sort_by(.t, .id)` is never the tie-breaker — a broken `sort_by(.t)` (ignoring .id) passes every DSRACE-2 assertion. (plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh)
- medium: RQLBL-1 ("the later run exits without removing the label") is exercised at the claim.sh layer with a stub coordinator (DSRACE-4), but the coordinator unit tests that run the real plugin.sh loser path (the DSRACE-2 and DSRACE-3 fixtures) never assert that $GHS/labels still contains zbuild:claimed after claim_coordinator_claim returns; an accidental _ccgl_remove_label call in the loser branch of plugin.sh would go undetected by both DSRACE-2 and DSRACE-3. (plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh)
- score: 7
