# Design notes — issue #1801 (revision 6)

## Revision 6: fix four verifier findings — add SPEC-11 for test migration coverage

### All four findings: same root cause

All four verifier findings from the latest design run share one root: R-3 says
"Every test that used orch-sequential as a fixture passes on orch-mock or
bash-parallel," but no SPEC required behavioral coverage to be MIGRATED rather
than simply DELETED. SPEC-3 (guard for orch-sequential references) could be
satisfied by deleting tests without replacement, and SPEC-9 (green CI) passes
equally whether coverage is preserved or removed.

### Fix: SPEC-11[no-code]

Added SPEC-11[no-code] covering pool isolation — the one ADR-011 contract
behavior NOT already covered by surviving tests.

Gap analysis of orch-sequential-test.sh (9 behaviors):
- Tests 3–5 (pass/fail/partial normalization): already in orch-mock-test.sh M1–M3
  and core-orch-contract-test.sh. [done]
- Tests 1, 2, 6, 9 (capabilities, pool-dir lifecycle, script-file work units):
  orch-sequential-specific implementation details. No equivalent in orch-mock
  (synchronous, no file-based pool state). Not required in a backend contract test.
- Test 7 (pool isolation — two simultaneous pools don't bleed results): NOT in any
  surviving test. core-orch-contract-test.sh tests two units in ONE pool, not two
  pools simultaneously.
- Test 8 (pool_id validation): covered at contract/sanitization level in
  core-orch-contract-test.sh test 8. [done]

SPEC-11 scope: add a pool-isolation assertion to plugins/tool/orch-mock/tests/orch-mock-test.sh
(already in scope). Test file is [no-code]: it adds test coverage for existing
behavior; passes on old code too (orch-mock works at merge-base), which is
acceptable for [no-code].

### Supersedes block status

The supersedes block correctly has:
- exit-path-teardown-budget-guard-test.sh [SPEC-1] and [SPEC-3]: caused by
  test-author renaming _SPEC5_RELEASE_TIMEOUT → _SPEC5_STAGE_TIMEOUT
- plugin-artifact-goldens-test.sh [G5]: orch-sequential golden deletion
- runner-release-exit-paths-test.sh [SPEC-6] REMOVED: test-author already updated

### R-7 grep results
- grep -rl 'orch-sequential' tests/ → 8 files, all in scope
- grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/ → 0 hits
- grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/ → 2 files, both in scope
- grep -rl '_orch_local_kill_slot' tests/ → 0 hits
- grep -rl 'router\.timeout_s' tests/ → 17 files (2 in scope, 15 excluded)

### Key source locations for implementation
- core/pipeline/strategies/sequential.sh:62 — ZBUILD_ORCH_TIMEOUT:-300
- core/pipeline/strategies/fanout.sh:79 — ZBUILD_ORCH_TIMEOUT:-300
- core/pipeline/strategies/map.sh:338 — ZBUILD_ORCH_TIMEOUT:-300
- core/orch/contract.sh:165-181 — orch-sequential fallback (must be removed)
- core/orch/local_engine.sh:34-40 — direct kill (must use zbuild_pg_kill)
- core/pipeline/runner.sh:2463-2465 — reads ZBUILD_RELEASE_TIMEOUT:-30
- core/pipeline/runner.sh:2493 — watchdog kill (must use zbuild_pg_kill)

## Status: COMPLETE (revision 6)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md
