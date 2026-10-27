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
tests/golden/full-pipeline/event-sequence.golden
tests/golden/parity/event-sequence.golden
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
tests/unit/lint-adr-enforced-by-test.sh
tests/integration/always-run-exit-paths-test.sh
.github/issues/keepers-manifest.yaml
```

```acceptance
SPEC-1[code]: A hung work unit dispatched through the fanout, map, and sequential strategies stops at its stage `timeout_s:` limit; each of the three strategies individually propagates a `timed_out` outcome naming the stage and the limit exceeded — the test for each strategy verifies the outcome variable `_ORCH_COLLECT_OUTCOME` is set to `timed_out` (not `failed`) with the stage name and limit; the strategy spy also confirms each strategy passes `template_stage_time_limit` to `orch_collect` instead of the 300 s flat deadline; the local engine's `_orch_local_collect_results` emits `timed_out` under a planted hang; the 300 s flat deadline no longer applies. covers: R-1 R-2
SPEC-2[code]: Running with a backend configured as `sequential` (or any name that resolves to no plugin) fails the run as `misconfigured` naming the backend; the sequential fallback in `orch_load_backend` is removed. covers: R-3
SPEC-3[code]: The `orch-sequential` plugin directory and `tests/golden/orch-sequential-capabilities.golden` do not exist in the installed tree; a guard test fails if the directory exists or any file (including golden files) outside `docs/adr/` still contains the literal string `orch-sequential`. All newly authored or modified test files must not contain the literal string `orch-sequential` anywhere — including comments and test description strings: (a) `orch-backend-misconfigured-test.sh` comments at lines 20 and 51 and the test description string at line 79 must have `orch-sequential` replaced with neutral phrasing (e.g. "the fallback backend via hardcoded path"); (b) `orch-mock-test.sh` sibling-backends comment at line 3 must be updated to remove `orch-sequential`; (c) `.github/issues/keepers-manifest.yaml` 4 occurrences (lines 2841, 3329, 3335, 3345) in historical closed-issue entries must be removed: at line 2841 remove `plugins/tool/orch-sequential/` from the `closed_reason`; for the `cleanup-delta-d` entry (lines 3329–3360) remove the orch-sequential title reference, body paragraphs, and test-file list that describe the now-deleted plugin, retaining the memory-sqlite portions. covers: R-3
SPEC-4[code]: A configured backend plugin that is absent from the installed tree (not the checkout) fails the run as `misconfigured` naming the missing backend. covers: R-4
SPEC-5[code]: `_runner_dispatch_always_run` bounds each always-run stage with `template_stage_time_limit`; `ZBUILD_RELEASE_TIMEOUT` and `router.timeout_s` are no longer read for this purpose; the test exercises both the release stage (30 s limit) and the persist stage (120 s limit) as separate hung-stage scenarios, each verifying the watchdog kills within the stage's `timeout_s:` and not beyond. covers: R-5
SPEC-6[code]: The `_orch_local_kill_slot` function and the always-run watchdog kill through `zbuild_pg_kill`; a hook that spawns a child which ignores TERM leaves no running process after the watchdog fires. covers: R-6
SPEC-7[no-code]: ADR-011 and ADR-017 carry `## Enforced by` sections naming the tests that enforce each statement; both are removed from `config/adr-enforcement-baseline.txt`. covers: R-8
SPEC-8[no-code]: The scope block includes every test file discovered by `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s`, and `_orch_local_kill_slot` in `tests/` that pins behavior changed by this issue (per CLAUDE.md test scope discovery). covers: R-7
SPEC-9[no-code]: `npm test` and `npm run lint` pass on the final delivered change with no failures; all new and modified test files use `cmd || rc=$?` instead of `set -e` mid-file to remain compatible with `lint-test-errexit` (repo rule: test file headers are `set -uo pipefail`, not `set -euo pipefail`). covers: R-9
SPEC-10[code]: A backend whose plugin directory is present but whose config file is unreadable (permissions, corrupt, or missing) fails the run as `misconfigured` naming the backend — tested from the installed tree. covers: R-4
SPEC-11[no-code]: Pool isolation — two independently active pools collect without bleeding results across each other — is verified in `plugins/tool/orch-mock/tests/orch-mock-test.sh` by an assertion tagged `[#1801/SPEC-11]` that submits work to two distinct pools concurrently and asserts results do not cross pool boundaries; this is the only behavioral gap from `orch-sequential-test.sh` test 7 (pool isolation) not already covered by surviving tests; all other behavioral tests in `orch-sequential-test.sh` are accounted for by SPEC-12. covers: R-3
SPEC-12[no-code]: Every existing test file that uses orch-sequential as a live behavioral fixture (sourcing its plugin.sh, iterating it in a backend roster, or pinning its source content) is updated so no behavioral coverage is silently dropped: (a) `adr059-no-tmpdir-defaults-test.sh` SPEC-4 (sequential pool-dir placement under `runs/<run_id>/pool`) is removed — orch-sequential is retired; the no-TMPDIR-leakage contract for the remaining backends is preserved by that file's own SPEC-3 (bash-parallel) and SPEC-6 (ruflo-hive) assertions; its SPEC-8 loop removes the orch-sequential iteration for the same reason; (b) `core-orch-run-id-isolation-test.sh` P4 and P5 (sequential pool-dir per-run namespacing) are removed — orch-sequential is retired; run-isolation for bash-parallel is preserved by P1–P3 in the same file; (c) `dispatch-rc-guard-test.sh` removes `plugins/tool/orch-sequential/plugin.sh|0` from `_PINNED` (the file no longer exists; no legacy-RC behavior to guard); (d) `stdin-spawn-guard-test.sh` removes the two orch-sequential stdin-close pins (plugin.sh deleted; the stdin-close pattern is enforced for surviving backends by their own pins); (e) `summary-mandatory-test.sh` removes orch-sequential from the SPEC-3 backend roster loop (manifest no longer present; no behavioral loss since the loop checks for absence of `summary: true`). covers: R-3
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
SPEC-5: tests/integration/runner-release-exit-paths-test.sh tests/integration/always-run-exit-paths-test.sh
SPEC-6: tests/unit/orch-kill-uses-pg-kill-guard-test.sh
SPEC-7: tests/unit/lint-adr-enforced-by-test.sh
SPEC-10: tests/integration/orch-backend-misconfigured-test.sh
SPEC-11: plugins/tool/orch-mock/tests/orch-mock-test.sh
SPEC-12: tests/unit/adr059-no-tmpdir-defaults-test.sh tests/unit/core-orch-run-id-isolation-test.sh tests/unit/dispatch-rc-guard-test.sh tests/unit/stdin-spawn-guard-test.sh tests/unit/summary-mandatory-test.sh
```

```supersedes
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-1]: asserts `ZBUILD_RELEASE_TIMEOUT` is found in the runner-release-exit-paths-test.sh SPEC-5 block; the test-author renamed the pinned variable to `_SPEC5_STAGE_TIMEOUT` — update SPEC-1 to grep for `_SPEC5_STAGE_TIMEOUT` and update the intent-comment to describe the new pin
tests/unit/exit-path-teardown-budget-guard-test.sh [SPEC-3]: greps for `_SPEC5_RELEASE_TIMEOUT=[0-9]+` to extract the pinned value; after the rename `_pinned` is empty so the assertion fails with "pinned='none' grace='unevaluatable'" — update to grep for `_SPEC5_STAGE_TIMEOUT=[0-9]+` instead
tests/unit/plugin-artifact-goldens-test.sh [G5]: the G5 section asserts orch-sequential's golden exists and its `orch_capabilities()` output matches; after deletion of the plugin and golden the whole G5 block is removed
```

## Findings

**Test finding 20 (SPEC-3 guard fails — 3 files still name orch-sequential):** The guard test (`orch-sequential-absent-guard-test.sh`) found the literal string `orch-sequential` in three files outside `docs/adr/`: `.github/issues/keepers-manifest.yaml`, `plugins/tool/orch-mock/tests/orch-mock-test.sh`, and `tests/integration/orch-backend-misconfigured-test.sh`. Fixed in this revision:
- `.github/issues/keepers-manifest.yaml` added to scope; SPEC-3 now names all 4 occurrences (lines 2841, 3329, 3335, 3345) and specifies the update for each (remove from `closed_reason`; strip orch-sequential title/body from the `cleanup-delta-d` keeper entry while retaining the memory-sqlite portions).
- `orch-backend-misconfigured-test.sh` lines 20, 51 (comments) and 79 (test description string) must replace `orch-sequential` with neutral phrasing; SPEC-3 now names these explicitly.
- `orch-mock-test.sh` line 3 (sibling-backends comment) must be updated; SPEC-3 now names this explicitly.

**test-author finding 1 (SPEC-1 — all three strategies must propagate `timed_out`):** The test-author found that propagation of `timed_out` naming the stage and limit was only asserted for the fanout strategy. SPEC-1 now explicitly requires all three strategies (fanout, map, sequential) to each propagate `timed_out` from `_ORCH_COLLECT_OUTCOME`. The test failure also showed that on the partial build the fanout implementation did not set `_ORCH_COLLECT_OUTCOME` at all (got `<empty>`); this is a code issue for the build stage to fix.

**test-author finding 2 (SPEC-5 — both release and persist must be separately tested):** SPEC-5 now requires the test to cover both the release stage (30 s) and the persist stage (120 s) as separate hung-stage scenarios. `tests/integration/always-run-exit-paths-test.sh` added to SPEC-5 TESTFILES.

**test-author finding 3 (SPEC-11 — pool isolation test must be in orch-mock-test.sh):** SPEC-11 now states the assertion carries the `[#1801/SPEC-11]` tag in `plugins/tool/orch-mock/tests/orch-mock-test.sh`, and clarifies that SPEC-12 accounts for all other behavioral tests in `orch-sequential-test.sh`.

**Test findings 3–18, 22–23 (broad pipeline failures):** Many integration tests fail with "exits 0, got: 1". These are code issues in the partial build (contract.sh sequential-fallback removal or runner.sh changes). The design's scope already includes all affected source files. Not a design issue.

**lint-test-errexit failures:** `orch-timeout-applies-test.sh`, `orch-backend-misconfigured-test.sh`, and `orch-kill-uses-pg-kill-guard-test.sh` use `set -e` mid-file in files whose headers are `set -uo pipefail`. SPEC-9 now explicitly names this constraint. Code issue for build to fix.

**Test findings 21–22 (golden files may be stale):** `tests/golden/full-pipeline/event-sequence.golden` and `tests/golden/parity/event-sequence.golden` were flagged as potentially stale. Neither references `orch-sequential`; both are added to scope in case pipeline-event changes from the implementation require updates.

**R-7 (scope discovery):** Greps per CLAUDE.md confirmed all affected test files:
- `grep -rl 'orch-sequential' tests/` → 10 files: all in scope.
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits.
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → 2 files: both in scope.
- `grep -rl '_orch_local_kill_slot' tests/` → 0 hits (guarded by new SPEC-6 test).
- `grep -rl 'router\.timeout_s' tests/` → 17 files; 2 pin the always-run watchdog bound (in scope); remaining 15 test the per-call model-call timeout accessor (`template_stage_router_timeout`), unchanged by this issue.

**Template observation:** Both templates declare `timeout_s: 30` (release) and `timeout_s: 120` (persist) under `router:`, where they set the per-call model timeout. `template_stage_time_limit` reads the top-level `timeout_s:` key. Moving those values one level up is the only template change needed.

**Supersedes updates:** The test-author renamed `_SPEC5_RELEASE_TIMEOUT` → `_SPEC5_STAGE_TIMEOUT` in `runner-release-exit-paths-test.sh`. Both exit-path-teardown-budget-guard-test.sh entries in the supersedes block reflect this rename.

**`config/adr-enforcement-baseline.txt`:** Removing ADR-011 and ADR-017 from the baseline while adding their `## Enforced by` sections is required by `lint-adr-enforced-by.sh` (part of `npm run lint`).

**Design findings 1–2 (SPEC-7 TESTFILES named ADR docs, not test files):** The previous design listed `docs/adr/ADR-011-pluggable-backends.md` and `docs/adr/ADR-017-per-stage-router-config.md` as TESTFILES for SPEC-7. These are source docs, not test files. Fixed: SPEC-7 TESTFILES now names `tests/unit/lint-adr-enforced-by-test.sh`, which verifies that every live ADR carries an `## Enforced by` section and is not in the baseline (`config/adr-enforcement-baseline.txt`). Adding the `## Enforced by` sections to ADR-011 and ADR-017 and removing them from the baseline is exactly what SPEC-7 requires; `lint-adr-enforced-by-test.sh` A3/A5 assertions enforce both checks. Both ADR files remain in the scope block (they are still changed by this issue); only the TESTFILES entry changed. `tests/unit/lint-adr-enforced-by-test.sh` and `tests/integration/always-run-exit-paths-test.sh` (already referenced in SPEC-5 TESTFILES) were also added to the scope block.
