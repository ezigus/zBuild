# Design notes — issue #1801 (revision 9)

## What changed from revision 8

### Fix for design findings 1–2 (SPEC-7 TESTFILES named ADR docs, not test files)

The only reason the design failed was SPEC-7 TESTFILES pointing to ADR documents
(`docs/adr/ADR-011-pluggable-backends.md`, `docs/adr/ADR-017-per-stage-router-config.md`)
which are not test files.

**Fix:** SPEC-7 TESTFILES now names `tests/unit/lint-adr-enforced-by-test.sh`.
This test exists at that path (confirmed by ls) and is specifically designed to
verify that every live ADR carries an `## Enforced by` section and is not still
in the baseline. Its A3 assertion (a live ADR with its section → pass) and A5
assertion (a baseline entry for an ADR that now has its section → fail) together
verify exactly what SPEC-7 requires: adding `## Enforced by` sections to ADR-011
and ADR-017, and removing them from `config/adr-enforcement-baseline.txt`.

### Additional scope fixes

Two files were referenced in TESTFILES but missing from the scope block:
- `tests/unit/lint-adr-enforced-by-test.sh` (now in SPEC-7 TESTFILES)
- `tests/integration/always-run-exit-paths-test.sh` (was in SPEC-5 TESTFILES since
  revision 8, but missing from scope block)

Both added to the scope block.

## Unchanged from revision 8

All other scope entries, SPEC text, supersedes block, and findings remain exactly
as in revision 8. The test-author findings (1-3) and test findings (1-23) are code
issues for the build stage, not design issues. SPEC-1, SPEC-5, and SPEC-11 already
describe the full required behavior; the test-author findings note the tests as
written were incomplete — that is fixed in the test content, not the design spec.

## Key facts confirmed by grep (carried forward from revision 8)

### keepers-manifest.yaml (4 occurrences)
- Line 2841: closed_reason for orch-contract PR — references plugins/tool/orch-sequential/
- Lines 3329, 3335, 3345: cleanup-delta-d keeper entry (memory-sqlite AND orch-sequential trial)
  Entry is closed. Strip orch-sequential parts; retain memory-sqlite parts.

### orch-backend-misconfigured-test.sh (3 occurrences)
- Line 20, 51: comments referencing orch-sequential path
- Line 79: TEST DESCRIPTION STRING (not just a comment) — must also be updated

### orch-mock-test.sh (1 occurrence)
- Line 3: sibling-backends comment

## Status: COMPLETE (revision 9)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md
