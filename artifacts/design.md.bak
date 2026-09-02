# Design: Remove hardcoded input-path fallbacks from build plugin

## Decision

**Goal.** Satisfy the final acceptance criterion for issue #1833 (migrate the build plugin to result_contract:2): delete the two hardcoded input-path fallbacks in `build_stage_run` and add a grep-based assertion that proves they are gone.

**Context.** `plugins/agent/build/plugin.sh:78-79` construct input artifact paths in code:

```bash
local scope_manifest="$state_dir/scope-manifest.md"
local plan_json_path="$artifacts_dir/plan.json"
```

These are the last hardcoded input paths in the plugin — a violation of ADR-055 §1, which requires that a consumer declare only artifact names and receive resolved paths from the engine via `ZBUILD_STAGE_INPUTS`. The ZBUILD_STAGE_INPUTS override block already exists at lines 82-88 to honour the ADR-055 model; the fallbacks on lines 78-79 were left as a backward-compatibility shim.

**Decision.** Delete lines 78-79, replacing them with empty local declarations (`local scope_manifest="" plan_json_path=""`). The ZBUILD_STAGE_INPUTS block becomes the sole path source; if it is absent or does not provide a path, `_build_stage_run_inner` already guards with rc=1 at its arg-emptiness check, so the plugin fails closed rather than guessing paths. All integration tests that call `build_stage_run` directly (bypassing the lifecycle's ZBUILD_STAGE_INPUTS injection) must be updated to construct and export a ZBUILD_STAGE_INPUTS index before running their driver.

**Proven by.** SPEC-20[change]: a grep assertion in build-test.sh checks that `plugin.sh` contains neither `state_dir/scope-manifest.md` nor `artifacts_dir/plan.json` as literal constructions, and must fail at merge-base (where the lines still exist).

```scope
plugins/agent/build/plugin.sh
plugins/agent/build/tests/build-test.sh
tests/integration/cycle-commit-summary-fallback-test.sh
tests/integration/cycle-multi-iter-cumulative-test.sh
tests/integration/build-no-stash-flow-test.sh
tests/integration/build-changed-files-summary-test.sh
tests/integration/cycle-commits-per-iter-test.sh
tests/integration/build-created-oos-still-violation-test.sh
tests/integration/build-test-cycle-progress-test.sh
tests/integration/cycle-scope-violation-no-commit-test.sh
tests/integration/build-preexisting-untracked-not-violation-test.sh
docs/adr/ADR-055-inter-stage-data-contract-v2.md
```

```acceptance
SPEC-20[change]: plugin.sh contains no hardcoded fallback constructions for input artifact paths (scope_manifest or plan_json_path derived from state_dir/artifacts_dir) — the grep over plugin.sh must return zero matches
WIRING: none
TESTFILES:
SPEC-20: plugins/agent/build/tests/build-test.sh
```
