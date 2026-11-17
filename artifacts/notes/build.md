# Build Notes — #1764 GitHub Label Claim (iteration 3)

## Status: COMPLETE — all tests pass

## Open findings

### acceptance-gate finding 1
"config/adr-enforcement-baseline.txt was put back to its old version on its own and every test still passed"

VERDICT: **wrong** — directly verified. I appended ADR-005-claim-coordinator.md to the baseline
and ran tests/unit/lint-adr-enforced-by-test.sh: 2 of 29 tests failed:
- [A7] the real tree passes
- [#1764/DSADR-7] ADR-005-claim-coordinator.md must be removed from config/adr-enforcement-baseline.txt

The test DOES catch the revert. The finding was based on a stale view of the test file (before
the test-author stage added the DSADR-7 assertions at lines 178-194).

### issue-acceptance finding 1
"RQCLA-2: _ZBUILD_CLAIM_HOLDER is set by zbuild_claim_acquire AFTER sidecar is spawned.
The sidecar is a separate exec bash process and cannot see _ZBUILD_CLAIM_HOLDER."

VERDICT: **real** — sidecar spawned at runner.sh:2381, zbuild_claim_acquire at ~2459.
The sidecar inherits only exported env vars at fork time. _ZBUILD_CLAIM_HOLDER is not exported
before spawn.

## Fix for issue-acceptance finding 1

Add `zbuild_claim_build_holder()` to core/claim/claim.sh:
- Builds this run's holder string (same logic as zbuild_claim_acquire success path)
- Exports _ZBUILD_CLAIM_HOLDER so child processes inherit it

Refactor zbuild_claim_acquire to use zbuild_claim_build_holder.

Call zbuild_claim_build_holder in runner.sh BEFORE _runner_status_comment_spawn,
guarded by declare -F.

## Tests verified passing before changes
- tests/unit/lint-adr-enforced-by-test.sh: 29/29
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 27/27
- tests/integration/teardown-repeat-signal-test.sh: 21/21

## Changes made this iteration

### core/claim/claim.sh
1. Added zbuild_claim_build_holder() — sets and exports _ZBUILD_CLAIM_HOLDER for this run
2. Replaced duplicate holder-building block in zbuild_claim_acquire with call to zbuild_claim_build_holder

### core/pipeline/runner.sh
1. Added declare -F guarded call to zbuild_claim_build_holder before _runner_status_comment_spawn
