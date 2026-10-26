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
SPEC-1[code]: A hung work unit dispatched through the fanout, map, or sequential strategy stops at its stage template `timeout_s:` limit; the stage outcome is `timed_out` and the result names both the stage and the limit exceeded; the 300 s flat deadline no longer applies. covers: R-1 R-2
SPEC-2[code]: Running with a backend configured as `sequential` (or any name that resolves to no plugin) fails the run as `misconfigured` naming the backend; the sequential fallback in `orch_load_backend` is removed. covers: R-3
SPEC-3[code]: The `orch-sequential` plugin directory does not exist in the installed tree; a guard test fails if the directory exists or any code or config file outside `docs/adr/` still names `orch-sequential`. covers: R-3
SPEC-4[code]: A configured backend plugin that is absent from the installed tree (not the checkout) fails the run as `misconfigured` naming the missing backend. covers: R-4
SPEC-5[code]: `_runner_dispatch_always_run` bounds each always-run stage with `template_stage_time_limit` (`timeout_s:` 30 s for release, 120 s for persist); `ZBUILD_RELEASE_TIMEOUT` and `router.timeout_s` are no longer read for this purpose. covers: R-5
SPEC-6[code]: The `_orch_local_kill_slot` function and the always-run watchdog kill through `zbuild_pg_kill`; a hook that spawns a child which ignores TERM leaves no running process after the watchdog fires. covers: R-6
SPEC-7[no-code]: ADR-011 and ADR-017 carry `## Enforced by` sections naming the tests that enforce each statement; both are removed from `config/adr-enforcement-baseline.txt`. covers: R-8
SPEC-8[no-code]: The scope block includes every test file discovered by `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s`, and `_orch_local_kill_slot` in `tests/` that pins behavior changed by this issue (per CLAUDE.md test scope discovery). covers: R-7
SPEC-9[no-code]: `npm test` and `npm run lint` pass on the final delivered change with no failures. covers: R-9
SPEC-10[code]: A backend whose plugin directory is present but whose config file is unreadable (permissions, corrupt, or missing) fails the run as `misconfigured` naming the backend — tested from the installed tree. covers: R-4
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
```

```supersedes
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1]: asserts `ZBUILD_RELEASE_TIMEOUT` is found in the runner-release-exit-paths-test.sh SPEC-5 block; the test-author renamed the pinned variable to `_SPEC5_STAGE_TIMEOUT` — update SPEC-1 to grep for `_SPEC5_STAGE_TIMEOUT` and update the intent-comment to describe the new pin
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-3]: greps for `_SPEC5_RELEASE_TIMEOUT=[0-9]+` to extract the pinned value; after the rename `_pinned` is empty so the assertion fails with "pinned='none' grace='unevaluatable'" — update to grep for `_SPEC5_STAGE_TIMEOUT=[0-9]+` instead
tests/unit/plugin-artifact-goldens-test.sh [G5]: the G5 section asserts orch-sequential's golden exists and its `orch_capabilities()` output matches; after deletion of the plugin and golden the whole G5 block is removed
```

## Findings

**Design finding 1 (SPEC-1 missing "names stage and limit"):** Fixed. SPEC-1 now reads "the stage outcome is `timed_out` and the result names both the stage and the limit exceeded", covering the full R-1 requirement.

**Design finding 2 (R-4 unreadable config not covered):** Fixed. Added SPEC-10[code] covering the "backend directory present but config unreadable" branch, sharing test file `tests/integration/orch-backend-misconfigured-test.sh` with SPEC-4. R-4 has two failure modes: (a) backend not found at all — covered by SPEC-2 and SPEC-4; (b) backend directory present but config unreadable — covered by SPEC-10.

**R-7 (scope discovery):** Greps per CLAUDE.md confirmed all affected test files. Results, term by term:
- `grep -rl 'orch-sequential' tests/` → 8 files: all in scope above.
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits (env var only in source files; no test pins it).
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → 2 files: `exit-path-teardown-budget-guard-test.sh`, `runner-release-exit-paths-test.sh`; both in scope.
- `grep -rl '_orch_local_kill_slot' tests/` → 0 hits (internal function; guarded by new SPEC-6 test).
- `grep -rl 'router\.timeout_s' tests/` → 17 files. Of these, 2 pin the always-run watchdog bound (`runner-release-exit-paths-test.sh`, `exit-path-teardown-budget-guard-test.sh`; both in scope). The remaining 15 test ADR-017 per-stage model-call timeout (`template_stage_router_timeout`), which is NOT changing. Spot-checked `core-pipeline-template-test.sh` (lines 493–590): its `router.timeout_s` assertions all target `template_stage_router_timeout`, the per-call limit accessor, unchanged by this issue. Those 15 files are correctly excluded from scope.
SPEC-8[no-code] records this discovery as a required step. R-7 is now covered.

**R-9 (green CI):** Covered by SPEC-9[no-code]. This is a standing quality gate; all [code] SPECs' test files must pass after the change. R-9 is now covered.

**Template observation:** Both `config/templates/simple.yaml` and `config/templates/deployed.yaml` declare `timeout_s: 30` (release) and `timeout_s: 120` (persist) under the `router:` block, where they set `_TPL_STAGE_ROUTER_TIMEOUT_${safe}` (the per-call model timeout). `template_stage_time_limit` reads the top-level `timeout_s:` key. Moving those values one level up is the only template change needed; the `router:` entries for release/persist can be removed since these stages make no model calls.

**orch-mock and orch-ruflo-hive:** `plugins/tool/orch-mock/tests/orch-mock-test.sh` and `plugins/tool/orch-ruflo-hive/plugin.sh` each contain a comment naming `orch-sequential`; both must be updated to keep the guard clean (SPEC-3).

**`config/adr-enforcement-baseline.txt`:** ADR-011 and ADR-017 have been given `## Enforced by` sections by the test-author (ADR-011 line 206, ADR-017 line 431). Both remain in the baseline (lines 14 and 20); removing them is part of the SPEC-7 implementation — `lint-adr-enforced-by.sh` (`npm run lint`) fails until they are removed.

**Design finding 3 (supersedes entry for `runner-release-exit-paths-test.sh [SPEC-6]` removed):** The test-author already updated the SPEC-6 section comments: line 409–410 now reads "`timeout_s:` at the top-level stage block (read by template_stage_time_limit after #1801)". The `[SPEC-6]` assertion itself (runner exits in <60 s with a 120 s blocking hook) remains observationally correct after the implementation — the bound source changes but the timing behavior does not. The supersedes entry for this file has been removed.

**Design finding 4 (exit-path-teardown-budget-guard-test.sh variable rename breaks SPEC-3):** The test-author renamed `_SPEC5_RELEASE_TIMEOUT` → `_SPEC5_STAGE_TIMEOUT` in `runner-release-exit-paths-test.sh`. The guard's SPEC-3 greps for `_SPEC5_RELEASE_TIMEOUT=[0-9]+` to extract the pinned value; after the rename that grep finds nothing, `_pinned` is empty, and the assertion fails with "pinned='none' grace='unevaluatable'". Two supersedes entries for the guard file have been added (SPEC-1 and SPEC-3) specifying the exact grep patterns to update.
