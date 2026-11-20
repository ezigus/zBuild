# Build Notes — #1764 GitHub Label Claim

## Status: All three acceptance tests pass; source-removal blocked by test dependency

## Test results (this iteration — all PASS)

### claim-coordinator-unit-test.sh: 37/37 PASS
### teardown-repeat-signal-test.sh: 29/29 PASS
### lint-adr-enforced-by-test.sh: 29/29 PASS

Working tree is CLEAN (git diff HEAD produces no output).

## Open findings and dispositions

### build finding 1: "step 7's quote is not a line this change added"
The line `  §1(a) enforcement \`plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh\``
IS present in docs/adr/ADR-005-claim-coordinator.md at line 117.
It was added by this branch's commit 584d38ed.
Finding does NOT hold — the line is in the file and was added by this change.

### build finding 2: Remove source of core/claim/claim.sh from plugin.sh — BLOCKED BY TEST
plugin.sh lines 236-239 source core/claim/claim.sh.
The acceptance test claim-coordinator-unit-test.sh:
- Sources only plugin.sh at line 29
- Calls zbuild_claim_acquire at line 114
- Has NO explicit source of claim.sh before line 114

Removing the source block from plugin.sh leaves zbuild_claim_acquire undefined for
DSCLA-1, DSCLA-2, DSCLA-3, DSCLA-8 (rc=127), breaking the tests.
The test file cannot be changed by this stage.
The test-author stage must add `source "$REPO_ROOT/core/claim/claim.sh"` after line 29
before this removal can happen.

### acceptance-gate-code finding 1: DOES NOT REPRODUCE
Test at lines 707-718 of claim-coordinator-unit-test.sh checks that
core/claim/claim.sh is in config/shape-change-paths.txt. Test passes 37/37.

### test-code finding 1 / issue-acceptance-code finding 1: DO NOT REPRODUCE
"claimed label contains 'claimed:' prefix" does not exist anywhere in the test file.
Test passes 37/37.

### lens-sre-code finding 1: NOT MINE
DSCLA-9 fixture is hand-written in tests/integration/teardown-repeat-signal-test.sh.
That is a test file I cannot change. This is for the test-author stage.

## Git state
HEAD: 584d38ed "amend ADR-005 Enforced by to attribute DSCLA-22 and DSCLA-9 to claim-coo"

## Changes in this branch (complete list from d4272ae5 base)

### plugins/claim-coordinator/github-labels/plugin.sh
- Uses zbuild:claimed in both claim and release
- Added _ccgl_read_holder()
- claim_coordinator_claim() returns {"acquired": false, "holder": "..."} on conflict
- NOTE: Still sources core/claim/claim.sh (test dependency prevents removal)

### core/claim/claim.sh
- Sources registry.sh; defines zbuild_claim_acquire and zbuild_claim_release
- Empty issue: returns 0 immediately
- Unsets _ZBUILD_CLAIM_ACQUIRED BEFORE release hook call (idempotency)

### scripts/lib/run-status-render.sh
- rsc_render_header adds <!-- zbuild-holder: ... -->

### core/pipeline/runner.sh
- Full claim wiring: build_holder, acquire after issue lock, release in abort trap and
  early-failure paths
- Uses printf '%s\n' for holder (not error() which uses echo -e)

### config/event-schema.json
- Has pipeline.refused.claimed

### config/shape-change-paths.txt
- Has core/claim/claim.sh

### docs/adr/ADR-005-claim-coordinator.md
- §1(a) enforcement: claim-coordinator-unit-test.sh [DSCLA-22]
- §1(c) enforcement: claim-coordinator-unit-test.sh [DSCLA-3] and [DSCLA-9]
- §2 bullet: [DSCLA-1, DSCLA-2, DSCLA-12]

### docs/adr/ADR-059-issue-vs-run-keying.md
- §4 Enforced by names [DSCLA-3]

### plugins/claim-coordinator/github-labels/README.md
- Describes zbuild:claimed, no claimed:<machine> references
