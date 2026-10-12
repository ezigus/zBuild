# Design: Per-dispatch stage timeout with orch-sequential retirement (#1801)

## Summary

**Goal:** Every dispatched `run` hook is killed at a per-stage time limit on every dispatch route (map, fanout, sequential strategy, cycle member, parallel-group member, roleless leaf, `always_run`). The `orch-sequential` backend, which silently discards the limit it is given, is retired.

**Context:** `plugin_hook_call` today runs the plugin subshell with no watchdog. Flat backend timeouts (`ZBUILD_ORCH_TIMEOUT:-300`) undercut long-but-valid stages and are the only kill mechanism in the three strategy files. `_runner_dispatch_always_run` times out via the stage's `router.timeout_s` (one-model-call budget), not a whole-stage budget. `_orch_local_collect_results` kills with a 0.5 s grace, far too short to let a hook flush partial results. `orch-sequential` falls back silently when the configured backend is missing.

**Decision:** Introduce `stage_timeout_s` as a new top-level scalar parsed by `core/pipeline/template.sh` alongside the existing `router.timeout_s`. Its three-tier precedence is: template `stage_timeout_s` > `ZBUILD_STAGE_TIMEOUT_S` > 5400 s (90 min). The per-dispatch watchdog lives inside `plugin_hook_call` in `lifecycle.sh`, armed only for the `run` hook: the plugin subshell runs in a background subshell; a paired watchdog calls `zbuild_pg_kill` (TERM + 10 s grace + KILL) and writes `timed_out` via the existing disposition layer on expiry. The subshell isolation must not use `set -m` in the calling shell — the implementation must scope any job-control flag changes so monitor mode cannot leak into the runner shell after `plugin_hook_call` returns. Additionally, when the runner receives an external SIGTERM, the runner's signal handler must kill any isolated hook process group (not only the internal timeout path). Because all dispatch routes reach `plugin_hook_call`, the single watchdog covers every route and every backend. Strategy files drop `ZBUILD_ORCH_TIMEOUT` entirely. `_runner_dispatch_always_run` is updated to read `_TPL_STAGE_TIMEOUT_S_*`. `simple.yaml` gains `stage_timeout_s` on every stage at the values named in R-6. `_orch_local_collect_results` and `_orch_local_shutdown_pool` replace `_orch_local_kill_slot` with `zbuild_pg_kill`/`zbuild_pid_kill` (10 s grace). `orch_load_backend` removes all sequential fallbacks; `sequential`/`orch-sequential` as aliases emit `orch.backend.misconfigured` and return 1. `orch.backend.misconfigured` and `plugin.run.timed_out` are registered in `config/event-schema.json`. `plugins/tool/orch-sequential/` and all its files are deleted. `plugins/tool/orch-mock/plugin.sh` is updated so its `bash -c "$task_body"` dispatch closes stdin (`</dev/null`).

```scope
.github/issues/keepers-manifest.yaml
config/adr-enforcement-baseline.txt
config/event-schema.json
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
plugins/tool/orch-mock/plugin.sh
plugins/tool/orch-mock/tests/orch-mock-test.sh
plugins/tool/orch-ruflo-hive/plugin.sh
plugins/tool/orch-sequential/manifest.yaml
plugins/tool/orch-sequential/plugin.sh
plugins/tool/orch-sequential/tests/orch-sequential-test.sh
scripts/lib/proc-group.sh
tests/golden/full-pipeline/event-sequence.golden
tests/golden/orch-sequential-capabilities.golden
tests/golden/parity/event-sequence.golden
tests/integration/always-run-exit-paths-test.sh
tests/integration/router-timeout-precedence-e2e-test.sh
tests/integration/runner-job-control-abort-test.sh
tests/integration/runner-release-exit-paths-test.sh
tests/unit/adr059-no-tmpdir-defaults-test.sh
tests/unit/core-orch-run-id-isolation-test.sh
tests/unit/core-pipeline-template-cycles-test.sh
tests/unit/core-pipeline-template-parallel-test.sh
tests/unit/core-pipeline-template-test.sh
tests/unit/design-prompt-scope-charter-test.sh
tests/unit/dispatch-rc-guard-test.sh
tests/unit/event-schema-emitted-coverage-test.sh
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
tests/unit/template-loader-recursive-flow-test.sh
```

```acceptance
SPEC-1[code]: a `run` hook that hangs is killed at the per-stage timeout on every dispatch route — map, fanout, sequential strategy, roleless leaf, cycle member, parallel-group member, and always_run — under every backend (bash-parallel, ruflo-hive, mock; the watchdog is backend-agnostic because it lives in `lifecycle.sh` above the backend layer) — and the stage ends with disposition `timed_out` naming the stage and the limit covers: R-1
SPEC-2[code]: killing a hung `run` hook stops the entire process group — a child ignoring TERM leaves no process alive after TERM + 10 s grace; this holds for BOTH the internal timeout path (watchdog fires) AND the external-SIGTERM path (runner receives a kill signal) — when the runner is externally killed, its signal handler must also kill any isolated hook process group covers: R-2
SPEC-3[code]: stage_timeout_s precedence: template value beats ZBUILD_STAGE_TIMEOUT_S beats the 5400 s engine default, each tier verified in isolation covers: R-3
SPEC-4[code]: the template loader rejects a `stage_timeout_s` value below the stage's `router.timeout_s`, and rejects a non-integer value covers: R-4
SPEC-5[code]: a retried stage and each map member each receive a fresh independent timer covers: R-5
SPEC-6[code]: `_runner_dispatch_always_run` reads `stage_timeout_s` (not `router.timeout_s`) for its time limit; `simple.yaml` carries `stage_timeout_s` for all stages at the following values — release: 30 s, persist: 120 s, test: 5400 s, build: 4200 s, design: 3900 s, plan: 1200 s, test-author: 900 s, spec-coverage/acceptance-gate/issue-acceptance/spec-correspondence/review_lenses: 600 s, intake/pr/hydrate/secret-scan/shape-floor/design-gate/gate-aggregator/assertion-integrity/review-aggregator: 600 s — and `router.timeout_s` remains absent from the two always_run stages covers: R-6
SPEC-7[code]: removing ZBUILD_ORCH_TIMEOUT from all three strategy files means a plan dispatch running longer than 300 s but within its `stage_timeout_s` completes without being killed covers: R-7
SPEC-8[code]: `plugins/tool/orch-sequential/` directory is absent; a guard fails if it exists or if any file outside `docs/adr/`, `tests/golden/`, or `tests/unit/orch-backend-misconfigured-test.sh` names `orch-sequential` (the misconfigured test file mentions "orch-sequential" only in historical commentary and is explicitly excluded from the guard); configuring `sequential` as a backend ends the run as `misconfigured` covers: R-8
SPEC-9[code]: a configured orchestrator backend that cannot be found, or whose config is unreadable, fails the run as `misconfigured` naming the backend — tested from the installed tree covers: R-9
SPEC-10[code]: `_runner_dispatch_always_run` and `_orch_local_collect_results` kill through `zbuild_pg_kill`; no hand-rolled TERM/KILL sequence remains for stage dispatch covers: R-10
SPEC-11[no-code]: ADR-054 §9, ADR-017, and ADR-011 amended with `## Enforced by` sections and removed from config/adr-enforcement-baseline.txt covers: R-12
SPEC-12[done]: `timed_out` is a valid disposition word in the closed set and `disposition_unfinished` returns true for it evidence: core/pipeline/disposition.sh:64 core/pipeline/disposition.sh:150
SPEC-13[done]: `zbuild_pg_kill` (TERM + configurable grace + KILL, process-group scope) already exists in `scripts/lib/proc-group.sh` — new code sources and calls it rather than reimplementing TERM/KILL sequences evidence: scripts/lib/proc-group.sh:146
SPEC-14[done]: `core/config/config.sh` already defaults the orchestrator backend to `bash-parallel`; ADR-011 amendment aligns the spec text to the code evidence: core/config/config.sh:11
SPEC-15[no-code]: before writing tests, grep -rl for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `router.timeout_s`, and the `always_run` watchdog pattern in `tests/` is performed; every test file that pins these values is listed in this design's scope block covers: R-11
SPEC-16[no-code]: `npm test` and `npm run lint` pass after all code changes are applied covers: R-13
SPEC-18[code]: `orch.backend.misconfigured` and `plugin.run.timed_out` are registered as known types in `config/event-schema.json`; the event-schema-emitted-coverage-test passes after this change covers: R-1 R-8
WIRING:
core/pipeline/runner.sh
core/orch/contract.sh
TESTFILES:
SPEC-1: tests/unit/stage-timeout-dispatch-test.sh
SPEC-2: tests/unit/stage-timeout-process-group-test.sh tests/integration/runner-release-exit-paths-test.sh
SPEC-3: tests/unit/stage-timeout-precedence-test.sh
SPEC-4: tests/unit/stage-timeout-loader-validation-test.sh
SPEC-5: tests/unit/stage-timeout-retry-test.sh
SPEC-6: tests/unit/stage-timeout-always-run-test.sh
SPEC-7: tests/unit/stage-timeout-no-flat-limit-test.sh
SPEC-8: tests/unit/orch-sequential-retired-guard-test.sh
SPEC-9: tests/unit/orch-backend-misconfigured-test.sh
SPEC-10: tests/unit/stage-timeout-dispatch-test.sh tests/unit/stage-timeout-always-run-test.sh
SPEC-11: tests/unit/orch-sequential-retired-guard-test.sh
SPEC-18: tests/unit/event-schema-emitted-coverage-test.sh
```

```supersedes
tests/unit/template-always-run-test.sh [SPEC-1]: line 44 asserts `_TPL_STAGE_ROUTER_TIMEOUT_release = "30"` loaded from simple.yaml; after this change simple.yaml sets `stage_timeout_s: 30` for release with no `router.timeout_s`, so `_TPL_STAGE_ROUTER_TIMEOUT_release` is unset and the assertion fails — the assertion must move to `_TPL_STAGE_TIMEOUT_S_release`
tests/integration/runner-release-exit-paths-test.sh [SPEC-5]: comment and env-var pin say always_run uses `router.timeout_s` as its time limit; after this change it uses `stage_timeout_s` — the pin becomes `ZBUILD_STAGE_TIMEOUT_S` (or the template fixture value), not `ZBUILD_RELEASE_TIMEOUT`
tests/integration/runner-release-exit-paths-test.sh [SPEC-6]: comment says "30 in the template" takes precedence as `router.timeout_s`; after this change the 30 s is declared as `stage_timeout_s`, not `router.timeout_s`
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1]: guards that SPEC-5 of the above file pins `ZBUILD_RELEASE_TIMEOUT`; the pin mechanism changes to `ZBUILD_STAGE_TIMEOUT_S` after this change
tests/unit/plugin-artifact-goldens-test.sh [G5]: entire G5 section tests orch-sequential-capabilities.golden — this golden and the plugin are deleted by R-8
tests/unit/dispatch-rc-guard-test.sh [inline]: pins `plugins/tool/orch-sequential/plugin.sh` as a guarded file path; file is deleted and pin must be moved to orch-mock or removed
tests/unit/adr059-no-tmpdir-defaults-test.sh [inline]: loops over `orch-bash-parallel orch-sequential orch-ruflo-hive`; orch-sequential entry must be replaced with orch-mock
tests/unit/stdin-spawn-guard-test.sh [inline]: previously pinned orch-sequential grep assertions; after migration the guard pins `plugins/tool/orch-mock/plugin.sh` and requires the pattern `bash -c "$task_body" .* </dev/null` — `orch-mock/plugin.sh` must be updated to close stdin in its dispatch
tests/unit/core-orch-run-id-isolation-test.sh [inline]: sources `plugins/tool/orch-sequential/plugin.sh`; must source orch-mock instead
tests/unit/summary-mandatory-test.sh [inline]: loops over `cache-local memory-sqlite orch-sequential`; orch-sequential entry must be removed or replaced
tests/unit/design-prompt-scope-charter-test.sh [T6]: T6 greps the design stage block in simple.yaml for the first `timeout_s:` value and asserts it equals `600`; after this change, `stage_timeout_s: 3900` precedes `router.timeout_s: 600` in the design stage block, so the first match returns 3900 — T6 must be updated to assert `stage_timeout_s: 3900` (the whole-stage limit now owns the design stage)
```

## Scope notes

**Scope additions beyond the prior design:**

- `config/event-schema.json`: `orch.backend.misconfigured` (emitted by `contract.sh:151,180`) and `plugin.run.timed_out` (emitted by `lifecycle.sh:506`) are new core event types that must be registered as known types here; the event-schema-emitted-coverage-test enforces this.
- `tests/unit/event-schema-emitted-coverage-test.sh`: checks every emitted string literal is in the composed known set; newly fails because the two new event types are absent from the schema.
- `tests/unit/design-prompt-scope-charter-test.sh`: T6 asserts design stage `timeout_s=600`; after this change `stage_timeout_s: 3900` is the first `timeout_s` key for the design stage — T6 fails; see supersedes.
- `tests/golden/full-pipeline/event-sequence.golden` and `tests/golden/parity/event-sequence.golden`: shape-floor flags these as spelling out a count or list this change alters; added to scope so the build stage can verify and update if needed.
- `plugins/tool/orch-mock/plugin.sh`: the `bash -c "$task_body"` dispatch must close stdin (`</dev/null`) — required by `stdin-spawn-guard-test.sh` after migration from orch-sequential; the build stage hit a scope violation attempting to fix this file without it being in scope.
- `tests/integration/runner-job-control-abort-test.sh`: the implementation's `set -m` inside `plugin_hook_call` leaks monitor mode into the runner shell; this test guards against that regression.

**SPEC-17 removed (tautology):**
The prior design's SPEC-17 asserted that orch-mock/plugin.sh exists — trivially true on both old and new code. The backend-agnostic property of the watchdog is structural: it lives in `lifecycle.sh` which is called by every backend. SPEC-1 already covers all dispatch routes and implicitly all backends. SPEC-17 has been removed; its backend-coverage rationale is absorbed into SPEC-1's description.

**SPEC-8 guard exclusion:**
`tests/unit/orch-backend-misconfigured-test.sh` mentions "orch-sequential" at line 6 in a historical commentary comment ("Before this change, orch_load_backend silently fell back to orch-sequential"). The guard must explicitly exclude this file from its grep, exactly as it already excludes `docs/adr/` and `tests/golden/`. SPEC-8 wording updated accordingly.

**SPEC-2 external-SIGTERM path:**
The watchdog's use of `set -m` (or process group isolation equivalent) places the hook subshell in its own process group. An external SIGTERM to the runner no longer propagates naturally to the hook's children. SPEC-2 is expanded to require that the runner's signal handler also kills the hook's isolated process group — covering both the internal timeout path and the external kill path (which `runner-release-exit-paths-test.sh` SPEC-6b tests).

**`set -m` leakage:**
The implementation at `lifecycle.sh:487` calls `set -m` in the calling shell. Any error path that exits before the matching `set +m` leaves monitor mode set in the runner shell, causing `runner-job-control-abort-test.sh` to fail. The implementation must ensure the `m` flag is never observable in the runner shell after `plugin_hook_call` returns — either by scoping the flag change to a subshell or by using a mechanism that does not touch the calling shell's flags.

**WIRING rationale:**
- `core/pipeline/runner.sh` implements `_runner_dispatch_always_run` (SPEC-6/SPEC-10) and routes through the strategies; reverting it to today's code fails the always-run timeout test.
- `core/orch/contract.sh` routes backend selection and emits `orch.backend.misconfigured`; reverting it to the sequential fallback fails SPEC-8 and SPEC-9.

LOOP_COMPLETE
