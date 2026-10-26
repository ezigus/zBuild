# Design — Issue #1801: Retire orch-sequential, harden backend errors, unify kill path

## Architectural decision summary

**Goal:** Fix stage timeouts silently not applying on the orchestrator route, and close the gaps that enable it: a fallback backend (orch-sequential) that ignores the timeout, a flat 300 s hard-coded deadline that overrides per-stage configuration, and a kill path that only signals individual PIDs rather than process groups.

**Context:** Three separate mechanisms interact to make per-stage `timeout_s:` silently ineffective on the orchestrator route. (1) The strategies pass `ZBUILD_ORCH_TIMEOUT:-300` to `orch_collect` instead of the stage's declared limit. (2) orch-sequential's `orch_collect` ignores `--timeout` entirely, so the 300 s cap never applied to it either. (3) `_runner_dispatch_always_run` reads `router.timeout_s` (the per-call model timeout) as the watchdog bound, not the whole-stage `timeout_s:`. (4) `_orch_local_kill_slot` sends individual-PID signals, leaving child processes alive when the parent ignores TERM. (5) A missing or wrong backend silently falls through to orch-sequential rather than failing fast.

**Decision:**
1. Retire orch-sequential entirely: delete the plugin directory, the golden, the wiki page; remove the fallback from `contract.sh`; a config naming `sequential` ends `misconfigured`.
2. Replace the `ZBUILD_ORCH_TIMEOUT:-300` literal in all three strategies with `template_stage_time_limit "$stage"`, which reads the stage's declared `timeout_s:` (default 900 s). `ZBUILD_ORCH_TIMEOUT` is no longer read.
3. Make a missing backend fatal: `orch_load_backend` no longer falls through to sequential; runner.sh detects the failed load and surfaces it as `misconfigured` naming the backend.
4. Fix `_runner_dispatch_always_run` to read `template_stage_time_limit` instead of `router.timeout_s`/`ZBUILD_RELEASE_TIMEOUT`. Move `timeout_s: 30` (release) and `timeout_s: 120` (persist) from under `router:` to the top-level stage block in both shipped templates so `template_stage_time_limit` finds them.
5. Route all kills through `zbuild_pg_kill`/`zbuild_pid_kill`: source `proc-group.sh` in `local_engine.sh`; replace the bare `kill` calls in `_orch_local_kill_slot` and the watchdog in `_runner_dispatch_always_run` with the shared helper.

```scope
core/orch/contract.sh
core/orch/local_engine.sh
core/pipeline/runner.sh
core/pipeline/strategies/fanout.sh
core/pipeline/strategies/map.sh
core/pipeline/strategies/sequential.sh
scripts/lib/proc-group.sh
scripts/lib/stage-time-limit.sh
config/templates/simple.yaml
config/templates/deployed.yaml
config/adr-enforcement-baseline.txt
docs/adr/ADR-011-pluggable-backends.md
docs/adr/ADR-017-per-stage-router-config.md
docs/wiki/Plugins.md
docs/wiki/plugins/orch-sequential.md
plugins/tool/orch-sequential/plugin.sh
plugins/tool/orch-sequential/manifest.yaml
plugins/tool/orch-sequential/tests/orch-sequential-test.sh
plugins/tool/orch-mock/tests/orch-mock-test.sh
plugins/tool/orch-ruflo-hive/plugin.sh
tests/golden/orch-sequential-capabilities.golden
tests/test-durations.tsv
tests/integration/runner-release-exit-paths-test.sh
tests/integration/stage-time-limit-test.sh
tests/unit/exit-path-teardown-budget-guard-test.sh
tests/unit/summary-mandatory-test.sh
tests/unit/dispatch-rc-guard-test.sh
tests/unit/stdin-spawn-guard-test.sh
tests/unit/core-orch-run-id-isolation-test.sh
tests/unit/plugin-artifact-goldens-test.sh
tests/unit/adr059-no-tmpdir-defaults-test.sh
tests/unit/map-strategy-test.sh
tests/integration/orch-timeout-applies-test.sh
tests/unit/orch-sequential-absent-guard-test.sh
tests/integration/orch-backend-misconfigured-test.sh
tests/unit/orch-kill-uses-pg-kill-guard-test.sh
```

```acceptance
SPEC-1[code]: A hung work unit dispatched through the fanout, map, and sequential strategies stops at its stage `timeout_s:` limit, verified under bash-parallel, ruflo-hive, and mock backends: the strategy spy confirms each strategy passes `template_stage_time_limit` to `orch_collect` instead of the 300 s flat deadline (this fix applies to all three backends since all receive the timeout from the strategy); the local engine's `_orch_local_collect_results` is directly verified to emit `timed_out` outcome under a planted hang (covers bash-parallel and ruflo-hive, both of which delegate collect to the local engine); the mock backend is synchronous so timeout is accepted but inapplicable; the strategies propagate `timed_out` naming the stage and the limit exceeded; the 300 s flat deadline no longer applies. covers: R-1 R-2
SPEC-2[code]: Running with a backend configured as `sequential` (or any name that resolves to no plugin) fails the run as `misconfigured` naming the backend; the sequential fallback in `orch_load_backend` is removed. covers: R-3
SPEC-3[code]: The `orch-sequential` plugin directory and `tests/golden/orch-sequential-capabilities.golden` do not exist in the installed tree; a guard test fails if the directory exists or any file (including golden files) outside `docs/adr/` still names `orch-sequential`. covers: R-3
SPEC-4[code]: A configured backend plugin that is absent from the installed tree (not the checkout) fails the run as `misconfigured` naming the missing backend. covers: R-4
SPEC-5[code]: `_runner_dispatch_always_run` bounds each always-run stage with `template_stage_time_limit` (`timeout_s:` 30 s for release, 120 s for persist); `ZBUILD_RELEASE_TIMEOUT` and `router.timeout_s` are no longer read for this purpose. covers: R-5
SPEC-6[code]: The `_orch_local_kill_slot` function and the always-run watchdog kill through `zbuild_pg_kill`; a hook that spawns a child which ignores TERM leaves no running process after the watchdog fires. covers: R-6
SPEC-7[no-code]: ADR-011 and ADR-017 carry `## Enforced by` sections naming the tests that enforce each statement; both are removed from `config/adr-enforcement-baseline.txt`. covers: R-8
SPEC-8[no-code]: The scope block includes every test file discovered by `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s`, and `_orch_local_kill_slot` in `tests/` that pins behavior changed by this issue (per CLAUDE.md test scope discovery). covers: R-7
SPEC-9[no-code]: `npm test` and `npm run lint` pass on the final delivered change with no failures. covers: R-9
SPEC-10[code]: A backend whose plugin directory is present but whose config file is unreadable (permissions, corrupt, or missing) fails the run as `misconfigured` naming the backend — tested from the installed tree. covers: R-4
SPEC-11[no-code]: Pool isolation — two independently active pools collect without bleeding results across each other — is verified in `plugins/tool/orch-mock/tests/orch-mock-test.sh` against the orch-mock backend; the file is extended with this pool-isolation assertion and passes after the change; pass/fail/partial normalization is already covered by orch-mock-test.sh M1–M3 and core-orch-contract-test.sh; `plugins/tool/orch-sequential/tests/orch-sequential-test.sh` is not deleted without this replacement coverage in place. covers: R-3
WIRING:
core/pipeline/strategies/fanout.sh
core/pipeline/strategies/map.sh
core/pipeline/strategies/sequential.sh
core/orch/contract.sh
core/pipeline/runner.sh
core/orch/local_engine.sh
TESTFILES:
SPEC-1: tests/integration/orch-timeout-applies-test.sh
SPEC-2: tests/integration/orch-backend-misconfigured-test.sh
SPEC-3: tests/unit/orch-sequential-absent-guard-test.sh
SPEC-4: tests/integration/orch-backend-misconfigured-test.sh
SPEC-5: tests/integration/runner-release-exit-paths-test.sh
SPEC-6: tests/unit/orch-kill-uses-pg-kill-guard-test.sh
SPEC-7: docs/adr/ADR-011-pluggable-backends.md docs/adr/ADR-017-per-stage-router-config.md
SPEC-10: tests/integration/orch-backend-misconfigured-test.sh
SPEC-11: plugins/tool/orch-mock/tests/orch-mock-test.sh
```

```supersedes
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1]: asserts `ZBUILD_RELEASE_TIMEOUT` is found in the runner-release-exit-paths-test.sh SPEC-5 block; the test-author renamed the pinned variable to `_SPEC5_STAGE_TIMEOUT` — update SPEC-1 to grep for `_SPEC5_STAGE_TIMEOUT` and update the intent-comment to describe the new pin
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-3]: greps for `_SPEC5_RELEASE_TIMEOUT=[0-9]+` to extract the pinned value; after the rename `_pinned` is empty so the assertion fails with "pinned='none' grace='unevaluatable'" — update to grep for `_SPEC5_STAGE_TIMEOUT=[0-9]+` instead
tests/unit/plugin-artifact-goldens-test.sh [G5]: the G5 section asserts orch-sequential's golden exists and its `orch_capabilities()` output matches; after deletion of the plugin and golden the whole G5 block is removed
```

## Findings

**Design findings 1–4 (verifier: R-3 test migration not covered by any SPEC):** All four verifier findings point to the same gap — R-3 requires "Every test that used orch-sequential as a fixture passes on orch-mock or bash-parallel," but no SPEC prevented satisfying the guard (SPEC-3) by simply deleting tests. Fixed by adding SPEC-11[no-code].

The gap analysis: `orch-sequential-test.sh` covers 9 behaviors. Of these:
- Pass/fail/partial normalization (tests 3–5): already covered by `orch-mock-test.sh` M1–M3 and `core-orch-contract-test.sh`; these are [done] at the contract level.
- Capabilities advertisement, pool-dir lifecycle, script-file work units (tests 1, 2, 6, 9): orch-sequential-specific implementation details; no equivalent in orch-mock (synchronous, no file-based pool state).
- Pool isolation (test 7): not covered in any surviving test — `core-orch-contract-test.sh` tests two units in the same pool but not two pools simultaneously.
- Pool_id validation (test 8): covered at the contract/sanitization level in `core-orch-contract-test.sh` test 8.

SPEC-11 fills the real gap: add a pool-isolation assertion to `plugins/tool/orch-mock/tests/orch-mock-test.sh`. That file is already in scope.

**R-7 (scope discovery):** Greps per CLAUDE.md confirmed all affected test files:
- `grep -rl 'orch-sequential' tests/` → 8 files: all in scope.
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits.
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → 2 files: both in scope.
- `grep -rl '_orch_local_kill_slot' tests/` → 0 hits (guarded by new SPEC-6 test).
- `grep -rl 'router\.timeout_s' tests/` → 17 files; 2 pin the always-run watchdog bound (in scope); remaining 15 test the per-call model-call timeout accessor (`template_stage_router_timeout`), unchanged by this issue.

**Template observation:** Both templates declare `timeout_s: 30` (release) and `timeout_s: 120` (persist) under `router:`, where they set the per-call model timeout. `template_stage_time_limit` reads the top-level `timeout_s:` key. Moving those values one level up is the only template change needed; `router:` entries for release/persist may be removed since these stages make no model calls.

**Supersedes updates:** The test-author renamed `_SPEC5_RELEASE_TIMEOUT` → `_SPEC5_STAGE_TIMEOUT` in `runner-release-exit-paths-test.sh`. This breaks the budget guard's SPEC-3 (grep for `_SPEC5_RELEASE_TIMEOUT=` finds nothing) and makes SPEC-1 pass for the wrong reason (finds `ZBUILD_RELEASE_TIMEOUT` only in assertion strings, not as the pinned variable). Both entries are in the supersedes block. The `runner-release-exit-paths-test.sh [SPEC-6]` entry was removed: the test-author already updated those comments and the SPEC-6 assertion remains observationally correct.
