# Design — issue #1801: per-dispatch stage timeout with orch-sequential retirement

## Architectural decision summary

**Goal**: Every hung `run` hook is killed at its per-stage limit on every dispatch
route; the entire process group (not just the leader) is killed; and the
`orch-sequential` backend is retired.

**Context**: Timeouts existed at the orchestrator layer
(`ZBUILD_ORCH_TIMEOUT`) as a flat per-strategy ceiling, not per dispatch.
`_runner_dispatch_always_run` read `router.timeout_s` (a router budget knob,
not a wall-clock bound for the hook). `orch-sequential` silently discarded any
timeout it was given. `zbuild_pg_kill` existed but was not wired to stage
dispatch.

**Decision**:
1. `plugin_hook_call` (lifecycle.sh) arms a per-dispatch watchdog scoped to the
   "run" hook only. Precedence: `_TPL_STAGE_TIMEOUT_S_<stage>` (template) >
   `ZBUILD_STAGE_TIMEOUT_S` (env) > 5400 s default. The hook subshell runs
   under `set -m` so it forms its own process group; `set +m` inside the hook
   keeps the hook's own children in that same group. **A TERM trap must be
   installed after `_lc_wd_pid` is assigned and before `wait "$_lc_hook_pid"`**
   (between lifecycle.sh lines 516 and 521 in the current build). The trap kills
   both the hook group and the watchdog, then exits with status 143, so that
   when `plugin_hook_call` is externally TERMed (e.g. by `_runner_dispatch_always_run`'s
   outer watchdog) the inner hook group is not orphaned:

   ```bash
   # After:  _lc_wd_pid=$!      (line 516)
   # After:  set +m              (line 517)
   # After:  (( _lc_m_before == 1 )) && set -m  (line 520)
   trap 'zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true; zbuild_pg_kill "$_lc_wd_pid" 1 2>/dev/null || true; exit 143' TERM
   wait "$_lc_hook_pid" 2>/dev/null; rc=$?
   trap - TERM
   # Before: kill -KILL/zbuild_pg_kill on _lc_hook_pid  (line 525)
   ```

   Without `exit 143` in the trap body, bash resumes execution after the trap
   handler and the outer caller's `wait "$_ar_pid"` stalls indefinitely.

   **Why the SPEC-6b scenario requires this trap**: The test's `build_cleanup` function
   (runner-release-exit-paths-test.sh lines 128-132) spawns a TERM-ignoring child then
   calls bare `wait` — blocking until the child exits (120 s). This turns the cleanup
   hook into a blocking hook, triggering the always_run watchdog after 30 s
   (`stage_timeout_s` in simple.yaml). The watchdog calls `zbuild_pg_kill "$_ar_pid" 10`,
   which sends TERM to pgid `_ar_pid` — the process group of `plugin_hook_call`'s outer
   fork. `_runner_dispatch_always_run` runs `plugin_hook_call` in its own process group
   (outer `set -m` + `&`). The inner hook subshell is a FURTHER nested group
   (`plugin_hook_call`'s own `set -m` + `&`). When TERM arrives at `_ar_pid`'s group,
   it does NOT reach `_lc_hook_pid`'s group (different PGID). Without a TERM trap,
   `plugin_hook_call` exits on TERM before reaching line 525, and the hook child that
   ignores TERM is orphaned and survives.

2. All hand-rolled `kill -KILL/-TERM` sequences for stage dispatch are replaced
   by `zbuild_pg_kill`, specifically:
   - **lifecycle.sh line 525**: `kill -KILL -- -"$_lc_hook_pid" 2>/dev/null || true`
     → `zbuild_pg_kill "$_lc_hook_pid" 1 2>/dev/null || true`
     *(the test grep-scans lifecycle.sh for the literal pattern `kill -KILL -- -"$_lc_hook_pid"` — it fails until that exact string is absent)*
   - runner.sh lines 2486–2487: `kill -KILL/-TERM -- -"$_ar_pid"/"$_wd_pid"` → `zbuild_pg_kill`
     *(the always-run test's awk extraction stops at the first 4-space `}` inside
     `_runner_dispatch_always_run` and does not reach these lines — they are not
     caught by a currently-failing assertion, but the replacement is required by R-10)*
3. `ZBUILD_ORCH_TIMEOUT` is removed from all three strategy files; the per-
   dispatch watchdog in lifecycle.sh is the only ceiling.
4. `plugins/tool/orch-sequential/` is deleted; a `sequential` backend config
   ends the run as `misconfigured`.
5. `simple.yaml` carries `stage_timeout_s` for every stage; `release` = 30 s,
   `persist` = 120 s. `_runner_dispatch_always_run` reads
   `_TPL_STAGE_TIMEOUT_S_<stage>` (not `router.timeout_s`).
6. ADR-054 §9, ADR-017, ADR-011 gain `## Enforced by` sections; both are
   removed from `config/adr-enforcement-baseline.txt`.

**Why the flag-on assertion in runner-job-control-abort-test.sh is superseded**:
The T1 probe records `$-` *inside* `intake_run` (the hook function). lifecycle.sh
forces `set +m` at line 504 before the hook runs, so `$-` inside the hook never
has `m` even when `ZBUILD_RUNNER_JOB_CONTROL=1`. The assertion at test lines 141-147
(`if grep -q 'm' <<< "$_opts_on_1"`) therefore always fails. Replace those lines with
a structural check — verify that `lifecycle.sh` contains `set -m` (the line that
actually creates the hook's process group) — rather than probing the subshell's `$-`:

```bash
# #1801: lifecycle.sh forces set +m inside the hook subshell (SPEC-2: hook children
# stay in the hook's process group). $- inside intake_run therefore never has 'm'.
# Verify structurally that lifecycle.sh arms set -m before the hook spawn.
if grep -q 'set -m' "$REPO_ROOT/core/plugin-registry/lifecycle.sh"; then
    assert_pass "flag-on: lifecycle.sh uses set -m before hook spawn [#1801]"
else
    assert_fail "flag-on: lifecycle.sh uses set -m before hook spawn" \
        "grep 'set -m' core/plugin-registry/lifecycle.sh returned non-zero"
fi
```

**Dispatch routes and backends**: The watchdog is installed inside `plugin_hook_call`
in lifecycle.sh, which is above the orchestrator-backend layer. Every dispatch route
— map (strategies/map.sh:plugin_hook_call), fanout (strategies/fanout.sh), sequential
strategy (strategies/sequential.sh), cycle member (runner.sh:2935/3106 via
cycle/parallel orchestrators), parallel-group member (runner.sh:3106), roleless leaf
(runner.sh:3781/3845), and always_run (runner.sh:2477 background dispatch) — reaches
`plugin_hook_call`. All three backends (bash-parallel, ruflo-hive, mock) dispatch
through the same call; the watchdog therefore covers every backend by construction.

```scope
core/plugin-registry/lifecycle.sh
core/pipeline/runner.sh
core/pipeline/template.sh
core/pipeline/strategies/fanout.sh
core/pipeline/strategies/map.sh
core/pipeline/strategies/sequential.sh
core/orch/contract.sh
core/orch/local_engine.sh
scripts/lib/proc-group.sh
config/templates/simple.yaml
config/event-schema.json
config/adr-enforcement-baseline.txt
plugins/tool/orch-sequential/
plugins/tool/orch-mock/plugin.sh
plugins/tool/orch-ruflo-hive/plugin.sh
docs/adr/ADR-054-stage-contract.md
docs/adr/ADR-017-per-stage-router-config.md
docs/adr/ADR-011-pluggable-backends.md
docs/wiki/plugins/orch-sequential.md
docs/wiki/Plugins.md
.github/issues/keepers-manifest.yaml
tests/unit/stage-timeout-dispatch-test.sh
tests/unit/stage-timeout-process-group-test.sh
tests/unit/stage-timeout-precedence-test.sh
tests/unit/stage-timeout-loader-validation-test.sh
tests/unit/stage-timeout-retry-test.sh
tests/unit/stage-timeout-always-run-test.sh
tests/unit/stage-timeout-no-flat-limit-test.sh
tests/unit/orch-sequential-retired-guard-test.sh
tests/unit/orch-backend-misconfigured-test.sh
tests/unit/event-schema-emitted-coverage-test.sh
tests/integration/runner-release-exit-paths-test.sh
tests/integration/runner-job-control-abort-test.sh
tests/golden/full-pipeline/event-sequence.golden
tests/golden/parity/event-sequence.golden
tests/golden/orch-sequential-capabilities.golden
tests/unit/core-pipeline-template-test.sh
tests/unit/template-simple-yaml-test.sh
tests/unit/build-oos-pass-request-test.sh
tests/unit/change-scope-floor-test.sh
tests/unit/template-resolvability-preflight-test.sh
tests/unit/impact-prefilter-order-detector-test.sh
tests/unit/shape-floor-summary-plain-test.sh
tests/unit/shape-floor-content-stable-test.sh
tests/unit/adr059-no-tmpdir-defaults-test.sh
tests/unit/core-orch-run-id-isolation-test.sh
tests/unit/dispatch-rc-guard-test.sh
tests/unit/stdin-spawn-guard-test.sh
tests/unit/summary-mandatory-test.sh
tests/unit/plugin-artifact-goldens-test.sh
tests/unit/orch-backend-misconfigured-test.sh
```

```acceptance
SPEC-1[code]: plugin_hook_call arms a per-dispatch watchdog for the run hook that writes disposition timed_out and names the stage and limit; every dispatch route (map, fanout, sequential strategy, cycle member, parallel-group member, roleless leaf, always_run) reaches plugin_hook_call; the watchdog is above the backend layer and therefore covers bash-parallel, ruflo-hive, and mock backends by construction covers: R-1
SPEC-2[code]: killing a hung run hook stops the whole process group — hook runs under set -m creating its own pgid; plugin_hook_call's run-hook branch has a TERM trap (inserted between lifecycle.sh lines 516 and 521) that kills the inner hook group and watchdog and exits with status 143 when plugin_hook_call is externally TERMed, so the hook's children are not orphaned covers: R-2
SPEC-3[code]: timeout precedence: template stage_timeout_s beats ZBUILD_STAGE_TIMEOUT_S beats 5400 s engine default; the 5400 s tier is verified by an isolation test that runs with neither a template value nor ZBUILD_STAGE_TIMEOUT_S set and confirms 5400 s is the timeout actually used covers: R-3
SPEC-4[code]: the template loader rejects a stage_timeout_s below router.timeout_s and a non-integer value covers: R-4
SPEC-5[code]: watchdog is instantiated inside plugin_hook_call so a retried stage and each map member each receive a fresh independent timer covers: R-5
SPEC-6[code]: _runner_dispatch_always_run reads _TPL_STAGE_TIMEOUT_S_<stage> (not router.timeout_s); simple.yaml carries stage_timeout_s for every stage (release=30, persist=120) covers: R-6
SPEC-7[code]: ZBUILD_ORCH_TIMEOUT is absent from all three strategy files; a plan dispatch whose hook sleeps 310 s (inside its stage_timeout_s) completes with exit 0, proving no earlier ceiling fires covers: R-7
SPEC-8[code]: plugins/tool/orch-sequential/ directory is absent; no file outside docs/adr/ names orch-sequential; a config naming sequential as backend ends the run as misconfigured covers: R-8
SPEC-9[code]: a configured orchestrator backend that cannot be found, or an unreadable config, fails the run as misconfigured and the output names the backend in both cases (unknown-alias case and unreadable-config case) covers: R-9
SPEC-10[code]: plugin_hook_call (lifecycle.sh line 525) has no hand-rolled kill -KILL/-TERM for stage dispatch — replaced by zbuild_pg_kill "$_lc_hook_pid" 1; _runner_dispatch_always_run (runner.sh lines 2486-2487) uses zbuild_pg_kill; _orch_local_collect_results in local_engine.sh uses zbuild_pg_kill covers: R-10
SPEC-11[no-code]: ADR-054 §9, ADR-017, and ADR-011 have ## Enforced by sections naming the tests that enforce their stage-timeout and backend-retirement statements; both ADRs are removed from config/adr-enforcement-baseline.txt covers: R-12
SPEC-12[done]: timed_out is already a valid disposition word in the engine evidence: docs/adr/ADR-054-stage-contract.md:248 covers: R-1
SPEC-13[done]: zbuild_pg_kill already exists in scripts/lib/proc-group.sh evidence: scripts/lib/proc-group.sh covers: R-2
SPEC-14[done]: core/orch/contract.sh defaults the backend to bash-parallel with no fallback to orch-sequential evidence: core/orch/contract.sh covers: R-8
SPEC-15[no-code]: before writing tests, grep -rl for orch-sequential, ZBUILD_ORCH_TIMEOUT, router.timeout_s in tests/ and include every file pinning them in scope covers: R-11
SPEC-16[no-code]: npm test and npm run lint pass after all code changes are applied covers: R-13
SPEC-17[no-code]: every test that previously used orch-sequential as a fixture is updated to use orch-mock or bash-parallel; the orch-sequential-retired-guard-test assertion that no file outside docs/adr/ names orch-sequential enforces this mechanically covers: R-8
SPEC-18[code]: orch.backend.misconfigured and plugin.run.timed_out are registered as known types in config/event-schema.json; event-schema-emitted-coverage-test passes (no emitted event type is unregistered) after adding the new types covers: R-1 R-9
SPEC-19[no-code]: the orch-backend-misconfigured test includes a variant that sources contract.sh from a temp install directory produced by install.sh (i.e. rsync of the repo tree into a tmp ZBUILD_HOME, then source from $ZBUILD_HOME/core/orch/contract.sh), verifying behavior is identical from the installed layout covers: R-9
WIRING:
core/plugin-registry/lifecycle.sh
core/pipeline/runner.sh
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
SPEC-17: tests/unit/orch-sequential-retired-guard-test.sh
SPEC-18: tests/unit/event-schema-emitted-coverage-test.sh
SPEC-19: tests/unit/orch-backend-misconfigured-test.sh
```

```supersedes
tests/integration/runner-job-control-abort-test.sh flag-on: plugin_hook_call forces set +m inside the hook subshell so $- inside the hook never has 'm' — the runtime probe at test lines 141-147 must be replaced with a structural check: grep -q 'set -m' lifecycle.sh. Concrete replacement for lines 141-147: `if grep -q 'set -m' "$REPO_ROOT/core/plugin-registry/lifecycle.sh"; then assert_pass "flag-on: lifecycle.sh uses set -m before hook spawn [#1801]"; else assert_fail "flag-on: lifecycle.sh uses set -m before hook spawn" "grep 'set -m' core/plugin-registry/lifecycle.sh returned non-zero"; fi`
tests/integration/runner-release-exit-paths-test.sh [SPEC-6b]: the SPEC-6b scenario (TERM-ignoring grandchild survives) is fixed by the TERM trap in plugin_hook_call's run-hook branch (inserted between lifecycle.sh lines 516 and 521) that calls zbuild_pg_kill on both _lc_hook_pid and _lc_wd_pid then exits 143 when plugin_hook_call is externally TERMed; after the fix the assertion passes (child is dead within 5 s of runner returning)
```
