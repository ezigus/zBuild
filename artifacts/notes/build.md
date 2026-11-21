# Build Notes — #1764 GitHub Label Claim

## Status: All acceptance tests and parity test pass; shape-change-paths.txt cleaned up

## Test results (this iteration — all PASS)

### claim-coordinator-unit-test.sh: 36/36 PASS
### teardown-repeat-signal-test.sh: 29/29 PASS
### lint-adr-enforced-by-test.sh: 29/29 PASS
### parity-local-vs-ci-test.sh: 15/15 PASS

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
- tests/golden/parity/event-sequence.golden: already includes plugin.claim.start/complete
  and plugin.release.start/complete events (parity test passes)
- config/shape-change-paths.txt: removed core/claim/claim.sh (no requirement asks for it)

## Findings disposition this iteration

### TEFND-1 / IAFND-2: DONE
Removed core/claim/claim.sh from config/shape-change-paths.txt — no step, SPEC, or
requirement names this entry.

### TEFND-2 / IAFND-1: WRONG (already fixed before this iteration)
parity-local-vs-ci-test.sh passes on the current tree (15/15). The golden file already
contains plugin.claim.start/complete and plugin.release.start/complete.

### lens-sre-code finding 1: NOT MINE
The DSCLA-9 fixture is hand-written inside tests/integration/teardown-repeat-signal-test.sh,
which is a test file this stage cannot change. The test-author stage must fix it.
