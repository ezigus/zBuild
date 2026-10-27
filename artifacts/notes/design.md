# Design notes — issue #1801 (revision 10)

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

## New findings from test stage (revision 10)

**Test-stage finding 1 (SPEC-1 — one assertion fails at HEAD; code issue):**
Negctl at HEAD shows 14/15 SPEC-1 assertions pass. One fails:
`[#1801/SPEC-1] fanout strategy must propagate timed_out from _ORCH_COLLECT_OUTCOME`
Got `<empty>`.

Root cause (confirmed by reading fanout.sh lines 78–95): the strategy clears
`_ORCH_COLLECT_OUTCOME=""` before calling `orch_collect`, then checks
`${_ORCH_COLLECT_OUTCOME:-}`. If `orch_collect` is invoked via a subshell
(pipe, process substitution, etc.) the variable set inside doesn't propagate
back. The design correctly specifies both sides must work; this is a build
code issue for the build stage to fix. Scope and SPEC-1 text are unchanged.

**Test-stage finding 2 (SPEC-3 — 3 files remain at HEAD; code issue):**
Guard test at HEAD confirms: `orch-mock-test.sh`, `orch-backend-misconfigured-test.sh`,
and `.github/issues/keepers-manifest.yaml` still contain `orch-sequential`.
All 3 are in scope. SPEC-3 names each with exact line references. Build issue.

Note: a broad worktree grep found `docs/audits/adr-2026-10-03/batch-1.md`
also references `orch-sequential`, but the SPEC-3 guard only scans
`core/`, `plugins/`, `scripts/`, `config/`, `tests/`, `.github/` —
`docs/audits/` is outside its scope. No design change needed.

**Confirmed: supersedes renames already implemented:**
`exit-path-teardown-budget-guard-test.sh` at HEAD already uses
`_SPEC5_STAGE_TIMEOUT` (lines 40–68). The supersedes block is accurate.

## Passing/failing SPECs at HEAD (from test stage)
- SPEC-2: NEGCTL PASS ✓
- SPEC-4: NEGCTL PASS ✓
- SPEC-5: NEGCTL PASS ✓
- SPEC-6: NEGCTL PASS ✓
- SPEC-10: NEGCTL PASS ✓
- SPEC-1: NEGCTL FAIL (14/15 — one fanout propagation assertion) — build issue
- SPEC-3: NEGCTL FAIL (1/2 — 3 files still name orch-sequential) — build issue

## Status: COMPLETE (revision 10)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md
