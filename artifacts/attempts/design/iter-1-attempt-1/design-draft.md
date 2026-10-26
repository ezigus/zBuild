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
SPEC-1[code]: A hung work unit dispatched through the fanout, map, or sequential strategy stops at its stage template `timeout_s:` limit and the stage outcome is `timed_out`; the 300 s flat deadline no longer applies. covers: R-1 R-2
SPEC-2[code]: Running with a backend configured as `sequential` (or any name that resolves to no plugin) fails the run as `misconfigured` naming the backend; the sequential fallback in `orch_load_backend` is removed. covers: R-3
SPEC-3[code]: The `orch-sequential` plugin directory does not exist in the installed tree; a guard test fails if the directory exists or any code or config file outside `docs/adr/` still names `orch-sequential`. covers: R-3
SPEC-4[code]: A configured backend plugin that is absent from the installed tree (not the checkout) fails the run as `misconfigured` naming the missing backend. covers: R-4
SPEC-5[code]: `_runner_dispatch_always_run` bounds each always-run stage with `template_stage_time_limit` (`timeout_s:` 30 s for release, 120 s for persist); `ZBUILD_RELEASE_TIMEOUT` and `router.timeout_s` are no longer read for this purpose. covers: R-5
SPEC-6[code]: The `_orch_local_kill_slot` function and the always-run watchdog kill through `zbuild_pg_kill`; a hook that spawns a child which ignores TERM leaves no running process after the watchdog fires. covers: R-6
SPEC-7[no-code]: ADR-011 and ADR-017 carry `## Enforced by` sections naming the tests that enforce each statement; both are removed from `config/adr-enforcement-baseline.txt`. covers: R-8
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
```

```supersedes
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1]: currently asserts that `ZBUILD_RELEASE_TIMEOUT` is pinned in `runner-release-exit-paths-test.sh` SPEC-5 block; after the fix that env var is not read, so the assertion is wrong — update to check for the `timeout_s:` fixture instead
tests/integration/runner-release-exit-paths-test.sh [SPEC-6]: comments say the bound is "the release stage's own router.timeout_s (30 in the template)"; after the fix the bound is `timeout_s:` at the top-level stage block — update comment and fixture
tests/unit/plugin-artifact-goldens-test.sh [G5]: the G5 section asserts orch-sequential's golden exists and its `orch_capabilities()` output matches; after deletion of the plugin and golden the whole G5 block is removed
```

## Findings

No prior-stage findings to address. This design covers all nine requirements (R-1 through R-9) directly.

**R-7 (scope discovery):** Greps per CLAUDE.md confirmed all affected test files:
- `grep -rl 'orch-sequential' tests/` → 8 test files + test-durations.tsv; all in scope above.
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits (env var only in source files).
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → `exit-path-teardown-budget-guard-test.sh`, `runner-release-exit-paths-test.sh`; both in scope.
- `grep -rl 'router\.timeout_s' tests/` → 16 files; the only files where `router.timeout_s` specifically refers to the always-run bound are `runner-release-exit-paths-test.sh` and `exit-path-teardown-budget-guard-test.sh`; the remaining 14 test ADR-017 per-stage config (unchanged by this issue).
- `grep -rl '_orch_local_kill_slot' tests/` → 0 hits (internal function; guarded by the new SPEC-6 test).

**Template observation:** Both `config/templates/simple.yaml` and `config/templates/deployed.yaml` already declare `timeout_s: 30` (release) and `timeout_s: 120` (persist) — but those values live under the `router:` block, where they set `_TPL_STAGE_ROUTER_TIMEOUT_${safe}` (the per-call model timeout). `template_stage_time_limit` reads the top-level `timeout_s:` key. Moving those values one level up is the only template change needed; the `router:` block entries for release/persist can be removed (these stages make no model calls, so the per-call limit is irrelevant).

**Conflict with ADR-017 tests:** Tests in the `router.timeout_s` list (14 files) test per-stage template router config, which is unchanged. They are NOT in scope.

**orch-mock comment:** `plugins/tool/orch-mock/tests/orch-mock-test.sh:3` and `plugins/tool/orch-ruflo-hive/plugin.sh:35` each contain a comment naming `orch-sequential`; both must be updated to keep the guard clean.

**`config/adr-enforcement-baseline.txt`:** Removing ADR-011 and ADR-017 from the baseline while adding their `## Enforced by` sections is required by `lint-adr-enforced-by.sh` (part of `npm run lint`).
