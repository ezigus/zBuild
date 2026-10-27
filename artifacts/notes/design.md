# Design notes — issue #1801 (revision 11)

## What changed from revision 10

### Acceptance gate finding (revision 11)

The acceptance gate returned `not_passing_at_head` for SPEC-1, SPEC-3, and
reachability for fanout.sh, map.sh, sequential.sh, config/adr-enforcement-baseline.txt,
config/templates/deployed.yaml, config/templates/simple.yaml.

**Root cause — SPEC-1:** `orch-timeout-applies-test.sh` fails at HEAD because 1/15
assertions fails: `[#1801/SPEC-1] fanout strategy must propagate timed_out from
_ORCH_COLLECT_OUTCOME` — got `<empty>`. fanout.sh calls `orch_collect` across a
subshell boundary; the variable set inside doesn't propagate back. Build stage must
ensure `orch_collect` is called in the same shell context (no pipe, process-sub,
or `$()` wrapper). Scope includes fanout.sh. Code issue for build.

**Root cause — SPEC-3:** `orch-sequential-absent-guard-test.sh` fails at HEAD because
3 files still contain `orch-sequential`: orch-mock-test.sh, orch-backend-misconfigured-test.sh,
and .github/issues/keepers-manifest.yaml. SPEC-3 names the exact lines/approach.
Build issue.

**Root cause — Reachability:** All reachability failures cascade from SPEC-1 test
not passing at HEAD. The gate can't verify wiring for fanout.sh, map.sh,
sequential.sh, and config files until SPEC-1's test passes. The wiring files
are correctly listed — reverting any would regress the behavior.

**Gate confirmed PASS:** SPEC-2, 4, 5, 6, 10 NEGCTL PASS (tests correctly fail
on old code). REACHABILITY PASS for contract.sh, runner.sh, local_engine.sh.

All failures are build/implementation gaps. Design scope and acceptance contract
are correct and unchanged from revision 10. Added "Acceptance gate finding
(revision 11)" to the Findings section of design-draft.md.

## Key facts (carried from revision 10)

### keepers-manifest.yaml (4 occurrences)
- Line 2841: closed_reason for orch-contract PR
- Lines 3329, 3335, 3345: cleanup-delta-d keeper entry (orch-sequential parts)

### orch-backend-misconfigured-test.sh (3 occurrences)
- Lines 20, 51: comments
- Line 79: test description string — must be updated

### orch-mock-test.sh (1 occurrence)
- Line 3: sibling-backends comment

## Passing/failing SPECs (acceptance gate, revision 11)
- SPEC-2: NEGCTL PASS ✓
- SPEC-4: NEGCTL PASS ✓
- SPEC-5: NEGCTL PASS ✓
- SPEC-6: NEGCTL PASS ✓
- SPEC-10: NEGCTL PASS ✓
- SPEC-1: not_passing_at_head (fanout subshell issue) — build issue
- SPEC-3: not_passing_at_head (3 files still name orch-sequential) — build issue
- Reachability: cascade from SPEC-1 — build issue

## Status: COMPLETE (revision 11)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md
