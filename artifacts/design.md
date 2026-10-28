# Design — Issue #1801: Retire orch-sequential, harden backend errors, unify kill path

## Architectural decision summary

**Goal:** Fix stage timeouts silently not applying on the orchestrator route, and close the gaps that enable it: a fallback backend (orch-sequential) that ignores the timeout, a flat 300 s hard-coded deadline that overrides per-stage configuration, and a kill path that only signals individual PIDs rather than process groups.

**Context:** Three separate mechanisms interact to make per-stage `timeout_s:` silently ineffective on the orchestrator route. (1) The strategies pass `ZBUILD_ORCH_TIMEOUT:-300` to `orch_collect` instead of the stage's declared limit. (2) orch-sequential's `orch_collect` ignores `--timeout` entirely, so the 300 s cap never applied to it either. (3) `_runner_dispatch_always_run` reads `router.timeout_s` (the per-call model timeout) as the watchdog bound, not the whole-stage `timeout_s:`. (4) `_orch_local_kill_slot` sends individual-PID signals, leaving child processes alive when the parent ignores TERM. (5) A missing or wrong backend silently falls through to orch-sequential rather than failing fast. (6) When the backend fails to load at source time, runner.sh does not detect `_ZBUILD_ORCH_BACKEND_DISPOSITION=misconfigured` and instead proceeds with stubs that produce uninformative errors.

**Decision:**
1. Retire orch-sequential entirely: delete the plugin directory, the golden, the wiki page; change the `sequential` fallback in `_orch_load_backend` (contract.sh) to `bash-parallel` (the actual system default) — the `sequential` string must not remain anywhere; a config explicitly naming `sequential` or `orch-sequential` ends `misconfigured`.
2. Replace the `ZBUILD_ORCH_TIMEOUT:-300` literal in all three strategies with `template_stage_time_limit "$stage"`, which reads the stage's declared `timeout_s:` (default 900 s). `ZBUILD_ORCH_TIMEOUT` is no longer read.
3. Make a missing backend fatal: `orch_load_backend` no longer falls through to sequential; runner.sh checks `_ZBUILD_ORCH_BACKEND_DISPOSITION` immediately after sourcing `contract.sh` and fails the pipeline as `misconfigured` before dispatching any stage.
4. Fix `_runner_dispatch_always_run` to read `template_stage_time_limit` instead of `router.timeout_s`/`ZBUILD_RELEASE_TIMEOUT`. Move `timeout_s: 30` (release) and `timeout_s: 120` (persist) from under `router:` to the top-level stage block in both shipped templates so `template_stage_time_limit` finds them. The `always-run-minimal.yaml` fixture template must carry `timeout_s: 2` as a direct child of its `release:` block (not under `router:`) — `template_stage_time_limits_load` reads the overlay source file, not the merged template, so the fixture must carry the value explicitly at stage-block indent. Template extension via `extends:` must propagate `always_run:` lists from the extending template so persist is included in `_TPL_ALWAYS_RUN` when the extending template names it.
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
tests/fixtures/templates/always-run-minimal.yaml
.github/issues/keepers-manifest.yaml
```

```acceptance
SPEC-1[code]: A hung work unit dispatched through the fanout, map, and sequential strategies stops at its stage `timeout_s:` limit; each of the three strategies individually propagates a `timed_out` outcome naming the stage and the limit exceeded — the test for each strategy verifies the outcome variable `_ORCH_COLLECT_OUTCOME` is set to `timed_out` (not `failed`) with the stage name and limit; the strategy spy also confirms each strategy passes `template_stage_time_limit` to `orch_collect` instead of the 300 s flat deadline; the local engine's `_orch_local_collect_results` emits `timed_out` under a planted hang; the 300 s flat deadline no longer applies. covers: R-1 R-2
SPEC-2[code]: Running with a backend configured as `sequential` (or any name that resolves to no plugin) fails the run as `misconfigured` naming the backend; the sequential fallback in `orch_load_backend` is removed. covers: R-3
SPEC-3[code]: The `orch-sequential` plugin directory and `tests/golden/orch-sequential-capabilities.golden` do not exist in the installed tree; a guard test fails if the directory exists or any file (including golden files) outside `docs/adr/` still contains the literal string `orch-sequential`. All newly authored or modified test files must not contain the literal string `orch-sequential` anywhere — including comments and test description strings: (a) `orch-backend-misconfigured-test.sh` comments at lines 20 and 51 and the test description string at line 79 must have `orch-sequential` replaced with neutral phrasing (e.g. "the fallback backend via hardcoded path"); (b) `orch-mock-test.sh` sibling-backends comment at line 3 must be updated to remove `orch-sequential`; (c) `.github/issues/keepers-manifest.yaml` 4 occurrences (lines 2841, 3329, 3335, 3345) in historical closed-issue entries must be removed: at line 2841 remove `plugins/tool/orch-sequential/` from the `closed_reason`; for the `cleanup-delta-d` entry (lines 3329–3360) remove the orch-sequential title reference, body paragraphs, and test-file list that describe the now-deleted plugin, retaining the memory-sqlite portions. covers: R-3
SPEC-4[code]: A configured backend plugin that is absent from the installed tree fails the full pipeline run as `misconfigured` naming the missing backend — tested in two ways: (a) unit: `orch_load_backend "absent-name"` returns non-zero and names the backend (current test); (b) end-to-end: a minimal installed tree is created (rsync of core/plugins/config/scripts to a temp `$ZBUILD_HOME`), the configured backend plugin is removed from the temp install's plugins/ tree, and `bash $ZBUILD_HOME/core/pipeline/runner.sh --template X --goal Y` is run — the pipeline exits non-zero with `misconfigured` in stderr or pipeline-state.json; runner.sh must check `_ZBUILD_ORCH_BACKEND_DISPOSITION` immediately after sourcing `contract.sh` and fail the pipeline before dispatching any stage when the disposition is `misconfigured`. covers: R-4
SPEC-5[code]: `_runner_dispatch_always_run` bounds each always-run stage with `template_stage_time_limit`; `ZBUILD_RELEASE_TIMEOUT` and `router.timeout_s` are no longer read for this purpose; the shipped templates (`simple.yaml`, `deployed.yaml`) carry `timeout_s: 30` (release) and `timeout_s: 120` (persist) as direct stage-block children; the `always-run-minimal.yaml` fixture carries `timeout_s: 2` as a direct child of its `release:` block (not under `router:`) so `template_stage_time_limits_load` finds it — the function reads the overlay source file directly and only matches `timeout_s:` at stage-level indent + 2; template extension (`extends:`) must propagate `always_run:` from the extending template so `_TPL_ALWAYS_RUN` includes persist when the template names it; the test exercises both a hung release hook (fixture timeout_s: 2 or 3) and a hung persist hook (fixture persist.timeout_s: 4 vs router.timeout_s: 120) as separate scenarios, each verifying the watchdog kills within the stage's `timeout_s:` and not at the 300 s / 120 s / router flat values; `[SPEC-5]` cleanup (pre-existing #1829 assertion) must pass on the hard-kill exit path — the test sends TERM to the runner process group, the runner's EXIT trap dispatches teardown, and cleanup hooks write to the release marker before the kill grace expires. covers: R-5
SPEC-6[code]: The `_orch_local_kill_slot` function and the always-run watchdog kill through `zbuild_pg_kill`; a hook that spawns a child which ignores TERM leaves no running process after the watchdog fires. covers: R-6
SPEC-7[no-code]: ADR-011 and ADR-017 carry `## Enforced by` sections naming the tests that enforce each statement; both are removed from `config/adr-enforcement-baseline.txt`. covers: R-8
SPEC-8[no-code]: The scope block includes every test file discovered by `grep -rl` for `orch-sequential`, `ZBUILD_ORCH_TIMEOUT`, `ZBUILD_RELEASE_TIMEOUT`, `router.timeout_s`, and `_orch_local_kill_slot` in `tests/` that pins behavior changed by this issue (per CLAUDE.md test scope discovery). covers: R-7
SPEC-9[no-code]: `npm test` and `npm run lint` pass on the final delivered change with no failures; all new and modified test files use `cmd || rc=$?` instead of `set -e` mid-file to remain compatible with `lint-test-errexit` (repo rule: test file headers are `set -uo pipefail`, not `set -euo pipefail`). covers: R-9
SPEC-10[code]: A backend whose plugin directory is present but whose plugin.sh is unreadable (permissions, corrupt, or missing) fails the run as `misconfigured` naming the backend — tested in two ways: (a) unit: `orch_load_backend "broken-backend"` returns non-zero and names the backend (current test); (b) end-to-end: same minimal installed tree approach as SPEC-4, with the backend plugin.sh present but chmod 000 — the pipeline exits non-zero with `misconfigured`. covers: R-4
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

**Test finding 20 (SPEC-3 guard fails — 3 files still name orch-sequential):** The guard test found `orch-sequential` in `.github/issues/keepers-manifest.yaml`, `plugins/tool/orch-mock/tests/orch-mock-test.sh`, and `tests/integration/orch-backend-misconfigured-test.sh`. Fixed: all three files are in scope; SPEC-3 names all 4 occurrences and specifies the update for each.

**test-author finding 1 (SPEC-1 — all three strategies must propagate `timed_out`):** SPEC-1 now explicitly requires all three strategies (fanout, map, sequential) to each propagate `timed_out` from `_ORCH_COLLECT_OUTCOME`. The one remaining failure at HEAD — `[#1801/SPEC-1] fanout strategy must propagate timed_out from _ORCH_COLLECT_OUTCOME` — is a code issue: `orch_collect` is called across a subshell boundary, so `_ORCH_COLLECT_OUTCOME` never propagates back. The build must call `orch_collect` in the same shell context.

**test-author finding 2 (SPEC-5 — both release and persist must be separately tested):** SPEC-5 now requires both release (30 s) and persist (120 s) scenarios.

**test-author finding 3 (SPEC-11 — pool isolation test must be in orch-mock-test.sh):** SPEC-11 states the assertion carries the `[#1801/SPEC-11]` tag in `plugins/tool/orch-mock/tests/orch-mock-test.sh`.

**Test findings 3–18, 22–23 (broad pipeline failures):** Many integration tests fail with "exits 0, got: 1". These are code issues in the partial build. The design's scope already includes all affected source files.

**lint-test-errexit failures:** `orch-timeout-applies-test.sh`, `orch-backend-misconfigured-test.sh`, and `orch-kill-uses-pg-kill-guard-test.sh` use `set -e` mid-file. SPEC-9 names this constraint. Code issue for build.

**Test findings 21–22 (golden files may be stale):** Both `tests/golden/full-pipeline/event-sequence.golden` and `tests/golden/parity/event-sequence.golden` are in scope.

**R-7 (scope discovery — confirmed at HEAD):** Greps run at HEAD per CLAUDE.md confirm all affected test files:
- `grep -rl 'orch-sequential' tests/` → 9 files with behavior pins: all in scope.
- `grep -rl 'ZBUILD_ORCH_TIMEOUT' tests/` → 0 hits.
- `grep -rl 'ZBUILD_RELEASE_TIMEOUT' tests/` → 2 files (runner-release-exit-paths-test.sh, always-run-exit-paths-test.sh): both in scope.
- `grep -rl '_orch_local_kill_slot' tests/` → 0 hits (guarded by new SPEC-6 test).
- `grep -rl 'router\.timeout_s' tests/` → 22 files; 2 pin the always-run watchdog bound (in scope); remaining 20 test the per-call model-call timeout accessor (`template_stage_router_timeout`), unchanged by this issue. R-7 is met by the scope block and this Findings section.

**Template observation (implemented in build commit `ee6aab95`):** `simple.yaml` and `deployed.yaml` carry `timeout_s: 30` (release) and `timeout_s: 120` (persist) as direct stage-block children. `always-run-minimal.yaml` has `timeout_s: 2` added as a direct child of `release:` (diff confirmed). The remaining fixture gap from revision 12 is resolved.

**Supersedes updates:** The test-author renamed `_SPEC5_RELEASE_TIMEOUT` → `_SPEC5_STAGE_TIMEOUT` in `runner-release-exit-paths-test.sh`. Both exit-path-teardown-budget-guard-test.sh entries reflect this rename. Confirmed: `exit-path-teardown-budget-guard-test.sh` at HEAD already greps for `_SPEC5_STAGE_TIMEOUT` (lines 40–68), so the supersedes rename is already implemented.

**`config/adr-enforcement-baseline.txt`:** Removing ADR-011 and ADR-017 from the baseline while adding their `## Enforced by` sections is required by `lint-adr-enforced-by.sh` (part of `npm run lint`).

**Design findings 1–2 (SPEC-7 TESTFILES):** SPEC-7 TESTFILES names `tests/unit/lint-adr-enforced-by-test.sh` (not the ADR source docs).

**Test-stage finding 1 (SPEC-1 subshell boundary):** `_ORCH_COLLECT_OUTCOME` is cleared inside fanout.sh before calling `orch_collect` but does not propagate back from the collect call — code issue for build stage (fanout.sh, local_engine.sh in scope).

**Test-stage finding 2 (SPEC-3 — 3 files remain at HEAD):** All three files are in scope; SPEC-3 names the exact lines. Build issue.

**Acceptance gate finding (revision 11):** All gate failures are implementation-incomplete issues, not design issues. Reachability for fanout.sh, map.sh, sequential.sh, and config files is a cascade of the SPEC-1 subshell issue.

**Issue-acceptance findings (revision 12):**

*Finding 1 (R-5): fixture template scope gap.* `always-run-exit-paths-test.sh` [SPEC-5][guard] was failing because `always-run-minimal.yaml` had `release.router.timeout_s: 2` at indent 4 instead of `timeout_s: 2` at stage-block level. Fixed in build (diff confirmed).

*Finding 2 (R-9): `_orch_load_backend` fallback.* Fixed in build (diff: changed `sequential` fallback to `bash-parallel` in `_orch_load_backend`).

*Findings 3–6 (R-1, R-2, R-4, R-6):* Build stage timed out. All source files are in scope.

**Issue-acceptance findings (revision 13):**

*Finding 1 (R-4) — installed-tree end-to-end test absent.* The test for SPEC-4/SPEC-10 sources `contract.sh` from the checkout and calls `orch_load_backend` in isolation. R-4 requires the **pipeline run** (not just `orch_load_backend`) to fail as `misconfigured`. Fix encoded in SPEC-4 and SPEC-10 (updated this revision): the test must also run `runner.sh` end-to-end from a minimal installed tree (rsync of core/plugins/config/scripts to a temp dir) with the backend absent or unreadable; runner.sh must check `_ZBUILD_ORCH_BACKEND_DISPOSITION` immediately after sourcing `contract.sh` and fail the pipeline before dispatching any stage. This is a code change to runner.sh (already in scope) plus test extensions to `orch-backend-misconfigured-test.sh` (already in scope).

*Finding 2 (R-5): persist hook never entered.* `always-run-exit-paths-test.sh` exits in 0 s without dispatching the persist always_run stage. Root cause: the `extends:` template mechanism does not propagate `always_run: [release, persist]` from the extending template (`always-run-spec5p`); `_TPL_ALWAYS_RUN` contains only `[release]` (from the base `always-run-minimal`). Fix encoded in SPEC-5 (updated this revision): template extension must propagate `always_run:` from the extending template so `_TPL_ALWAYS_RUN` includes all entries. This is a code change to the template loader (`core/pipeline/template.sh` or `template-resolver.sh`) — these files are not yet in the scope block. Adding them: the template-loading code that builds `_TPL_ALWAYS_RUN` must be changed so `always_run:` from the extending template overrides (not is ignored by) the base. **`core/pipeline/template.sh` and `core/pipeline/template-resolver.sh` are added to scope.**

*Finding 3 (R-5): `[SPEC-5]` release cleanup regression.* `runner-release-exit-paths-test.sh` `[SPEC-5]` cleanup on the hard-kill exit path fails at both HEAD and baseline (old code + new test file). Root cause: the test-author changed the SPEC-5 case from using `timeout 6` to using `resume-timeout-bounded` with `release.timeout_s: 3` and `_SPEC5_KILL_GRACE=15` s. At baseline (old code), `router.timeout_s: 30` was used for the watchdog — 30 s > 15 s kill grace — so the KILL arrives before teardown can complete. At HEAD (new code), `template_stage_time_limit("release")=3` should complete teardown in < 3 s, but the marker remains empty. The build stage must investigate and fix the hard-kill dispatch path so `_runner_abort_trap` → `_runner_dispatch_always_run` → teardown runs correctly and writes to RELEASE_MARKER before the runner process exits. This test MUST pass (fail at baseline, pass at HEAD) as it is the observable proof that the SPEC-5 mechanism works on the hard-kill path.

*Finding 4 (R-9): 2 failing tests.* Follows from findings 2 and 3. The build must fix both code issues.

*Finding 5 (R-7 confirmed).* The scope discovery greps have been run at HEAD in this revision and results are documented above. R-7 is met. SPEC-8 is satisfied.
