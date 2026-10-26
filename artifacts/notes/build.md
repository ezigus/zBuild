# Build Notes - Issue #1801

## State Assessment
The test-author stage has already written acceptance tests for all SPECs. 
The implementation files have NOT yet been updated.

## Changes Required

### 1. `core/orch/contract.sh` (SPEC-2/4/10)
- Remove both fallback paths in `orch_load_backend`:
  - The sequential-by-name fallback (`if [[ "$backend" == "sequential" && -f "$sequential_sh" ]]`)
  - The general fallback to sequential for any missing backend
- Replace with hard `misconfigured` failure that names the backend
- Also need to detect unreadable plugin.sh (SPEC-10)

### 2. `core/orch/local_engine.sh` (SPEC-1/SPEC-6)
- Add `timed_out` outcome when timeout fires in `_orch_local_collect_results`
- Source `proc-group.sh` and use `zbuild_pg_kill` in `_orch_local_kill_slot`

### 3. `core/pipeline/strategies/fanout.sh` (SPEC-1)
- Replace `"${ZBUILD_ORCH_TIMEOUT:-300}"` with `"$(template_stage_time_limit "$stage")"`
- Add `timed_out` handling when `_ORCH_COLLECT_OUTCOME == "timed_out"`

### 4. `core/pipeline/strategies/sequential.sh` (SPEC-1)
- Replace `"${ZBUILD_ORCH_TIMEOUT:-300}"` with `"$(template_stage_time_limit "$stage")"`
- Add `timed_out` handling

### 5. `core/pipeline/strategies/map.sh` (SPEC-1)
- Replace `"${ZBUILD_ORCH_TIMEOUT:-300}"` with `"$(template_stage_time_limit "$stage")"`

### 6. `core/pipeline/runner.sh` (SPEC-5/SPEC-6)
- Replace `_TPL_STAGE_ROUTER_TIMEOUT_*`/`ZBUILD_RELEASE_TIMEOUT` with `template_stage_time_limit`
- Source `proc-group.sh` and use `zbuild_pg_kill` in watchdog

### 7. `config/templates/simple.yaml` (SPEC-5)
- Add `timeout_s: 30` at top-level for release stage (not under router:)
- Add `timeout_s: 120` at top-level for persist stage (not under router:)

### 8. `config/templates/deployed.yaml` (SPEC-5)  
- Same as simple.yaml

### 9. Delete orch-sequential plugin (SPEC-3)
- `plugins/tool/orch-sequential/` directory
- `tests/golden/orch-sequential-capabilities.golden`
- `docs/wiki/plugins/orch-sequential.md`

### 10. Update references to orch-sequential (SPEC-3)
- `docs/wiki/Plugins.md`
- `plugins/tool/orch-ruflo-hive/plugin.sh`
- `tests/unit/plugin-artifact-goldens-test.sh` (already changed by test-author)
- `core/orch/contract.sh` (after removing fallback)

### 11. ADRs (SPEC-7)
- `docs/adr/ADR-011-pluggable-backends.md` - already changed by test-author
- `docs/adr/ADR-017-per-stage-router-config.md` - already changed by test-author
- `config/adr-enforcement-baseline.txt` - remove ADR-011 and ADR-017

### 12. SPEC-12 test files (already changed by test-author):
- adr059-no-tmpdir-defaults-test.sh
- core-orch-run-id-isolation-test.sh
- dispatch-rc-guard-test.sh
- stdin-spawn-guard-test.sh
- summary-mandatory-test.sh

### 13. SPEC-11 orch-mock-test.sh (already changed by test-author)

## Status
- Starting implementation
