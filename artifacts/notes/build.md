# Build Notes — #1764 GitHub Label Claim

## Status: All three acceptance tests pass; no code changes needed this iteration

## Test results (this iteration — all PASS)

### claim-coordinator-unit-test.sh: 36/36 PASS
### teardown-repeat-signal-test.sh: 29/29 PASS
### lint-adr-enforced-by-test.sh: 29/29 PASS
### claim-race-test.sh: 9/9 PASS (was flaky in previous pipeline run — passes now)

## Code state: complete and correct

All design steps are implemented:
- plugin.sh: zbuild:claimed used, _ccgl_read_holder present, conflict return, source block removed,
  race-prevention logic (exit 2 from flock, add_rc handling in claim_coordinator_claim)
- README.md: zbuild:claimed documented, no claimed:<machine> references
- run-status-render.sh: <!-- zbuild-holder: ... --> in rsc_render_header
- core/claim/claim.sh: wiring bridge via plugin registry
- config/event-schema.json: pipeline.refused.claimed registered
- runner.sh: full claim wiring (acquire/release/event/printf)
- ADR-005: Enforced by section with §1 and §2 bullets
- ADR-059: §4 Enforced by entry with DSCLA-3
- config/shape-change-paths.txt: core/claim/claim.sh present

## Known non-acceptance-test failure (NOT mine)

### tests/e2e/parity-local-vs-ci-test.sh
- Golden file tests/golden/parity/event-sequence.golden is stale: our new claim mechanism
  emits plugin.claim.start, plugin.claim.complete, plugin.release.start, plugin.release.complete.
- Golden diff: 2a3,4 (> plugin.claim.start, > plugin.claim.complete) and 114a117,118
  (> plugin.release.start, > plugin.release.complete)
- File is in tests/golden/ — off-limits (fixture belongs to test-author stage).
- No finding was opened for this by the test stage (it's not an acceptance test).
- Test-author stage must run UPDATE_GOLDEN=1 to regenerate.

## Open findings disposition

### BUFND-1: ANSWERED THIS ITERATION
Step 1's correct answer: done — the add_rc=2 race path in claim_coordinator_claim is new.
The representative line added by this change:
  plugins/claim-coordinator/github-labels/plugin.sh:
  `    _ccgl_add_label "$issue" "zbuild:claimed" || add_rc=$?`
This line is in the diff from HEAD~1 to HEAD (commit 2097be7d). It captures the return code
from _ccgl_add_label so that add_rc=2 (already-present) triggers {"acquired": false, "holder": "..."}.

### acceptance-gate-code finding 1: NOT MINE
The finding requires adding a test that checks core/claim/claim.sh is in
config/shape-change-paths.txt. I cannot add tests (test folders off-limits).
The file already has the entry (confirmed current state). The test-author stage must add
the assertion.

### lens-sre-code finding 1: NOT MINE
The DSCLA-9 fixture is hand-written in tests/integration/teardown-repeat-signal-test.sh.
I cannot change test files. Test-author stage must fix it.
