# Design notes — issue #1801 (revision 7)

## Revision 7: fix two verifier findings — add SPEC-12 for behavioral fixture migration

### Root cause of both verifier findings

Both findings: SPEC-11 covered only the pool-isolation behavioral migration from
`orch-sequential-test.sh` → `orch-mock-test.sh`. Other existing test files that use
orch-sequential as a live behavioral fixture had no SPEC requiring their coverage to
be migrated or explicitly dropped.

### Behavioral fixture files identified (grep -rl 'orch-sequential' tests/)

10 files total (previous design said 8; actual count is 10):
1. tests/unit/summary-mandatory-test.sh:111 — roster loop includes orch-sequential
2. tests/integration/orch-backend-misconfigured-test.sh — NEW test (already authored)
3. tests/unit/dispatch-rc-guard-test.sh:87 — orch-sequential/plugin.sh in _PINNED
4. tests/test-durations.tsv — just a duration entry, not a behavioral fixture
5. tests/unit/stdin-spawn-guard-test.sh:30-31 — two _pin calls on plugin.sh
6. tests/unit/orch-sequential-absent-guard-test.sh — NEW test (already authored)
7. tests/unit/map-strategy-test.sh:508 — COMMENT only, not behavioral
8. tests/unit/adr059-no-tmpdir-defaults-test.sh:65,100,102 — BEHAVIORAL: sources plugin.sh, calls _orch_seq_pool_dir
9. tests/unit/plugin-artifact-goldens-test.sh — covered by supersedes [G5]
10. tests/unit/core-orch-run-id-isolation-test.sh:77 — BEHAVIORAL: sources plugin.sh

### What each behavioral fixture needs

adr059-no-tmpdir-defaults-test.sh:
- SPEC-4 (lines 62-68): Sources orch-sequential/plugin.sh, calls _orch_seq_pool_dir.
  DROP: no-TMPDIR contract preserved by SPEC-3 (bash-parallel) and SPEC-6 (ruflo-hive)
- SPEC-8 loop (line 100): iterates orch-bash-parallel, orch-sequential, orch-ruflo-hive
  UPDATE: remove orch-sequential from loop

core-orch-run-id-isolation-test.sh:
- P4 (lines 74-81): Sources orch-sequential/plugin.sh, tests _orch_seq_pool_dir is per-run
- P5 (lines 82-85): Tests ZBUILD_POOL_ROOT override for sequential
  DROP both: run-isolation preserved by P1-P3 (bash-parallel)

dispatch-rc-guard-test.sh:
- Line 87: `plugins/tool/orch-sequential/plugin.sh|0` in _PINNED
  REMOVE the pin line (file deleted; no legacy-RC behavior to guard)

stdin-spawn-guard-test.sh:
- Lines 30-31: Two _pin calls checking orch-sequential/plugin.sh patterns
  REMOVE both (file deleted)

summary-mandatory-test.sh:
- Line 111: `for _svc in cache-local memory-sqlite orch-sequential; do`
  Has `[[ -f "$_sm" ]] || continue` so silently skips after deletion, but
  SPEC-3 guard would catch the orch-sequential string.
  REMOVE from loop

map-strategy-test.sh:
- Line 508: comment only (`orch-bash-parallel/orch-sequential`).
  SPEC-3 guard catches this — comment update required.

### Fix: SPEC-12[no-code]

Added to acceptance block. Names each file and its treatment. TESTFILES bound:
SPEC-12: tests/unit/adr059-no-tmpdir-defaults-test.sh
         tests/unit/core-orch-run-id-isolation-test.sh
         tests/unit/dispatch-rc-guard-test.sh
         tests/unit/stdin-spawn-guard-test.sh
         tests/unit/summary-mandatory-test.sh

(map-strategy-test.sh comment update is implied by SPEC-3 guard + in scope block)

### Verifier example files clarification
- stage-time-limit-test.sh: 0 orch-sequential references (grep confirmed). The
  verifier cited it as an example; it's in scope for other reasons (SPEC-1 timeout).
  No behavioral fixture migration needed.
- map-strategy-test.sh: 1 comment at line 508. Not a behavioral fixture. Comment
  cleanup required by SPEC-3 guard; covered by scope + SPEC-3.

### SPEC-11 (pool isolation) — unchanged
Pool isolation from orch-sequential-test.sh test 7 is the only behavioral gap
not covered by surviving tests. SPEC-11 adds it to orch-mock-test.sh.

### Supersedes block status (unchanged from revision 6)
- exit-path-teardown-budget-guard-test.sh [SPEC-1]: rename _SPEC5_RELEASE_TIMEOUT → _SPEC5_STAGE_TIMEOUT
- exit-path-teardown-budget-guard-test.sh [SPEC-3]: same rename in grep pattern
- plugin-artifact-goldens-test.sh [G5]: G5 block removed (golden deleted)

### R-7 grep results (corrected: 10 files, not 8)
- grep -rl 'orch-sequential' tests/ → 10 files, all in scope
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

## Status: COMPLETE (revision 7)
Design written to /home/runner/work/_temp/zbuild-state/artifacts/design-draft.md
