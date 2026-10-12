# Design: Per-dispatch stage timeout with orch-sequential retirement (#1801)

## Summary

**Goal:** Every dispatched `run` hook is killed at a per-stage time limit on every dispatch route (map, fanout, sequential strategy, cycle member, parallel-group member, roleless leaf, `always_run`). The `orch-sequential` backend, which silently discards the limit it is given, is retired.

**Context:** `plugin_hook_call` today runs the plugin subshell with no watchdog. Flat backend timeouts (`ZBUILD_ORCH_TIMEOUT:-300`) undercut long-but-valid stages and are the only kill mechanism in the three strategy files. `_runner_dispatch_always_run` times out via the stage's `router.timeout_s` (one-model-call budget), not a whole-stage budget. `_orch_local_collect_results` kills with a 0.5 s grace, far too short to let a hook flush partial results. `orch-sequential` falls back silently when the configured backend is missing.

**Decision:** Introduce `stage_timeout_s` as a new top-level scalar parsed by `core/pipeline/template.sh` alongside the existing `router.timeout_s`. Its three-tier precedence is: template `stage_timeout_s` > `ZBUILD_STAGE_TIMEOUT_S` > 5400 s (90 min). The per-dispatch watchdog lives inside `plugin_hook_call` in `lifecycle.sh`, armed only for the `run` hook: the plugin subshell runs under `set -m` in the background; a paired watchdog calls `zbuild_pg_kill` (TERM + 10 s grace + KILL) and writes `timed_out` via the existing disposition layer on expiry. Strategy files drop `ZBUILD_ORCH_TIMEOUT` entirely — the per-dispatch timer is the only stage limit. `_runner_dispatch_always_run` is updated to read `_TPL_STAGE_TIMEOUT_S_*` (not `_TPL_STAGE_ROUTER_TIMEOUT_*`). `_orch_local_collect_results` and `_orch_local_shutdown_pool` replace `_orch_local_kill_slot` with `zbuild_pg_kill` / `zbuild_pid_kill` (10 s grace). `orch_load_backend` removes all sequential fallbacks; `_orch_load_backend` defaults to `bash-parallel`; `sequential` / `orch-sequential` as aliases emit `orch.backend.misconfigured`. The `plugins/tool/orch-sequential/` directory, its tests, the capabilities golden, and its wiki page are deleted.

```scope
.github/issues/keepers-manifest.yaml
config/adr-enforcement-baseline.txt
config/templates/simple.yaml
core/config/config.sh
core/orch/contract.sh
core/orch/local_engine.sh
core/pipeline/disposition.sh
core/pipeline/runner.sh
core/pipeline/strategies/fanout.sh
core/pipeline/strategies/map.sh
core/pipeline/strategies/sequential.sh
core/pipeline/template.sh
core/pipeline/verdict.sh
core/plugin-registry/lifecycle.sh
docs/adr/ADR-011-pluggable-backends.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-035-orchestrator-run-state-isolation.md
docs/adr/ADR-054-stage-contract.md
docs/audits/adr-2026-10-03/batch-1.md
docs/wiki/Plugins.md
docs/wiki/plugins/orch-sequential.md
plugins/tool/orch-mock/tests/orch-mock-test.sh
plugins/tool/orch-ruflo-hive/plugin.sh
plugins/tool/orch-sequential/manifest.yaml
plugins/tool/orch-sequential/plugin.sh
plugins/tool/orch-sequential/tests/orch-sequential-test.sh
scripts/lib/proc-group.sh
tests/golden/orch-sequential-capabilities.golden
tests/integration/runner-release-exit-paths-test.sh
tests/unit/adr059-no-tmpdir-defaults-test.sh
tests/unit/core-orch-run-id-isolation-test.sh
tests/unit/dispatch-rc-guard-test.sh
tests/unit/exit-path-teardown-budget-guard-test.sh
tests/unit/map-strategy-test.sh
tests/unit/orch-backend-misconfigured-test.sh
tests/unit/orch-sequential-retired-guard-test.sh
tests/unit/plugin-artifact-goldens-test.sh
tests/unit/stage-timeout-always-run-test.sh
tests/unit/stage-timeout-dispatch-test.sh
tests/unit/stage-timeout-loader-validation-test.sh
tests/unit/stage-timeout-no-flat-limit-test.sh
tests/unit/stage-timeout-precedence-test.sh
tests/unit/stage-timeout-process-group-test.sh
tests/unit/stage-timeout-retry-test.sh
tests/unit/stdin-spawn-guard-test.sh
tests/unit/summary-mandatory-test.sh
tests/unit/template-always-run-test.sh
```

```acceptance
SPEC-1[code]: a `run` hook that hangs is killed at the per-stage timeout on every dispatch route (map, fanout, sequential strategy, roleless leaf) and the stage ends with disposition `timed_out` naming the stage and the limit covers: R-1
SPEC-2[code]: killing a hung `run` hook stops the entire process group — a child ignoring TERM leaves no process alive after TERM + 10 s grace covers: R-2
SPEC-3[code]: stage_timeout_s precedence: template value beats ZBUILD_STAGE_TIMEOUT_S beats the 5400 s engine default, each tier verified in isolation covers: R-3
SPEC-4[code]: the template loader rejects a `stage_timeout_s` value below the stage's `router.timeout_s`, and rejects a non-integer value covers: R-4
SPEC-5[code]: a retried stage and each map member each receive a fresh independent timer covers: R-5
SPEC-6[code]: `_runner_dispatch_always_run` reads `stage_timeout_s` (not `router.timeout_s`) for its time limit; `release` and `persist` in simple.yaml declare `stage_timeout_s` at 30 s and 120 s respectively; `router.timeout_s` remains absent from both always_run stages covers: R-6
SPEC-7[code]: removing ZBUILD_ORCH_TIMEOUT from all three strategy files means a plan dispatch running longer than 300 s but within its `stage_timeout_s` completes without being killed covers: R-7
SPEC-8[code]: `plugins/tool/orch-sequential/` directory is absent; a guard fails if it exists or any file outside `docs/adr/` names `orch-sequential`; configuring `sequential` as a backend ends the run as `misconfigured` covers: R-8
SPEC-9[code]: a configured orchestrator backend that cannot be found, or whose config is unreadable, fails the run as `misconfigured` naming the backend — tested from the installed tree covers: R-9
SPEC-10[code]: `_runner_dispatch_always_run` and `_orch_local_collect_results` kill through `zbuild_pg_kill`; no hand-rolled TERM/KILL sequence remains for stage dispatch covers: R-10
SPEC-11[no-code]: ADR-054 §9, ADR-017, and ADR-011 amended with `## Enforced by` sections and removed from config/adr-enforcement-baseline.txt covers: R-12
SPEC-12[done]: `timed_out` is a valid disposition word in the closed set and `disposition_unfinished` returns true for it evidence: core/pipeline/disposition.sh:64 core/pipeline/disposition.sh:150
SPEC-13[done]: `zbuild_pg_kill` (TERM + configurable grace + KILL, process-group scope) already exists in `scripts/lib/proc-group.sh` — new code sources and calls it rather than reimplementing TERM/KILL sequences evidence: scripts/lib/proc-group.sh:146
SPEC-14[done]: `core/config/config.sh` already defaults the orchestrator backend to `bash-parallel`; ADR-011 amendment aligns the spec text to the code evidence: core/config/config.sh:11
WIRING:
core/pipeline/runner.sh
core/orch/contract.sh
TESTFILES:
SPEC-1: tests/unit/stage-timeout-dispatch-test.sh
SPEC-2: tests/unit/stage-timeout-process-group-test.sh
SPEC-3: tests/unit/stage-timeout-precedence-test.sh
SPEC-4: tests/unit/stage-timeout-loader-validation-test.sh
SPEC-5: tests/unit/stage-timeout-retry-test.sh
SPEC-6: tests/unit/stage-timeout-always-run-test.sh
SPEC-7: tests/unit/stage-timeout-no-flat-limit-test.sh
SPEC-8: tests/unit/orch-sequential-retired-guard-test.sh
SPEC-9: tests/unit/orch-backend-misconfigured-test.sh
SPEC-10: tests/unit/stage-timeout-dispatch-test.sh tests/unit/stage-timeout-always-run-test.sh
SPEC-11: tests/unit/orch-sequential-retired-guard-test.sh
```

```supersedes
tests/unit/template-always-run-test.sh [SPEC-1]: line 44 asserts `_TPL_STAGE_ROUTER_TIMEOUT_release = "30"` loaded from simple.yaml; after this change simple.yaml sets `stage_timeout_s: 30` for release with no `router.timeout_s`, so `_TPL_STAGE_ROUTER_TIMEOUT_release` is unset and the assertion fails — the assertion must move to `_TPL_STAGE_TIMEOUT_S_release`
tests/integration/runner-release-exit-paths-test.sh [SPEC-5]: comment and env-var pin say always_run uses `router.timeout_s` as its time limit; after this change it uses `stage_timeout_s` — the pin becomes `ZBUILD_STAGE_TIMEOUT_S` (or the template fixture value), not `ZBUILD_RELEASE_TIMEOUT`
tests/integration/runner-release-exit-paths-test.sh [SPEC-6]: comment says "30 in the template" takes precedence as `router.timeout_s`; after this change the 30 s is declared as `stage_timeout_s`, not `router.timeout_s`
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1]: guards that SPEC-5 of the above file pins `ZBUILD_RELEASE_TIMEOUT`; the pin mechanism changes to `ZBUILD_STAGE_TIMEOUT_S` after this change
tests/unit/plugin-artifact-goldens-test.sh [G5]: entire G5 section tests orch-sequential-capabilities.golden — this golden and the plugin are deleted by R-8
tests/unit/dispatch-rc-guard-test.sh [inline]: pins `plugins/tool/orch-sequential/plugin.sh` as a guarded file path; file is deleted and pin must be moved to orch-mock or removed
tests/unit/adr059-no-tmpdir-defaults-test.sh [inline]: loops over `orch-bash-parallel orch-sequential orch-ruflo-hive`; orch-sequential entry must be replaced with orch-mock
tests/unit/stdin-spawn-guard-test.sh [inline]: pins two orch-sequential grep assertions; these become orch-mock assertions after migration
tests/unit/core-orch-run-id-isolation-test.sh [inline]: sources `plugins/tool/orch-sequential/plugin.sh`; must source orch-mock instead
tests/unit/summary-mandatory-test.sh [inline]: loops over `cache-local memory-sqlite orch-sequential`; orch-sequential entry must be removed or replaced
```

## Scope notes

**Additional files beyond seed (why each is included):**

- `core/config/config.sh`: already defaults orchestrator backend to `bash-parallel` (line 11); ADR-011 amendment aligns the spec to this existing code behaviour.
- `core/pipeline/disposition.sh` + `core/pipeline/verdict.sh`: referenced but not modified; the `timed_out` write in `plugin_hook_call` must use `_verdict_write_result`'s exact call shape (CLAUDE.md "data another part of the engine writes" rule).
- `scripts/lib/proc-group.sh`: new code sources and calls `zbuild_pg_kill`; in scope as a load-time dependency.
- `tests/unit/template-always-run-test.sh`: SPEC-1 at line 44 asserts `_TPL_STAGE_ROUTER_TIMEOUT_release = "30"` against `simple.yaml`; this fails after R-6 removes `router.timeout_s` from always_run stages — a direct supersede.
- `plugins/tool/orch-ruflo-hive/plugin.sh`, `plugins/tool/orch-mock/tests/orch-mock-test.sh`, `tests/unit/map-strategy-test.sh`: each contains a comment naming `orch-sequential`; R-8 requires a guard test that fails if any non-docs/adr/ file names `orch-sequential`, so these comments must be removed.
- `docs/adr/ADR-035-orchestrator-run-state-isolation.md`, `docs/audits/adr-2026-10-03/batch-1.md`, `.github/issues/keepers-manifest.yaml`: prose references to `orch-sequential` outside `docs/adr/ADR-011`; the guard test's scan scope determines whether these must be cleaned. Include in scope so the implementer verifies each against the guard's file pattern.

**WIRING rationale:**

- `core/pipeline/runner.sh` implements `_runner_dispatch_always_run` (SPEC-6/SPEC-10) and routes through the strategies; reverting it to today's code fails the always-run timeout test.
- `core/orch/contract.sh` is the only file that routes backend selection; reverting its `orch_load_backend` to the sequential fallback fails SPEC-8 and SPEC-9 guard tests.

LOOP_COMPLETE
