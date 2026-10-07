# Impact Stage Checkpoint

## Files read and what they told me

- **design.md**: Change forces `_draft_bool=true` when `state.status == "failed"` or any `cycle_iterations[*].status == "max_iterations"`. Adds convergence section to PR body via `_pr_open_compose_body`. Adds `gate_aggregator_result` as optional input to pr-open manifest.

- **plan.json**: 4 steps: (1) new regression tests, (2) state-aware draft forcing in `_pr_open_run_inner`, (3) convergence section in `_pr_open_compose_body`, (4) add `gate_aggregator_result` to pr-open manifest.

- **plugins/tool/pr-open/plugin.sh**: `_pr_open_run_inner` calls `_pr_open_compose_body` on line 355 with 6 args. `_draft_bool` set from `_TPL_PR_DRAFT`. Design will add state reading + override.

- **plugins/tool/pr-open/lib/advisory-section.sh**: `_pr_open_compose_body` has 6 params. Design adds 7th `convergence_info` argument.

- **plugins/tool/pr-open/manifest.yaml**: Currently has inputs: `review_report`, `plan`, `test_results`. Will add `gate_aggregator_result`.

- **tests/golden/pr-result-artifact.golden**: `{"result_contract":2,...,"data":{"branch":...,"pr_url":...,"draft":false}}` — this is the pr-DELIVERY result, written by `_pr_delivery_write_result`.

- **core/pipeline/state_helpers.sh**: Contains `_set_pipeline_status` which writes `.status` to state file. Relevant because the change reads `.status` from state.

- **plugins/agent/pr-delivery/plugin.sh**: `_pr_delivery_write_result` reads `_TPL_PR_DRAFT` and writes `data.draft`. OVERWRITES pr-open's pr-result.json. If not updated, the final artifact shows `draft=false` even for forced-draft PRs.

- **tests/unit/pr-open-v2-result-test.sh** (NOT in scope): Tests SPEC-10 through SPEC-13. State files use `{"issue":1849,"branch":"..."}` without `.status` field → draft logic doesn't activate. Not broken.

- **tests/unit/pr-open-v2-inputs-test.sh** (NOT in scope): Checks plugin.sh constructs no hardcoded paths (`review-report.json`, `plan.json`, `test-results.json`). Change doesn't add those paths. Not broken by scope.

- **tests/unit/pr-open-advisory-review-test.sh** (NOT in scope): Calls `_pr_open_run_inner` with state file without `.status`. Not broken.

- **tests/unit/pr-open-detached-head-test.sh** (NOT in scope): Uses `gate_aggregator_result` only for merge_run tests. Not broken.

## Key conclusions reached

1. The design scope looks mostly correct. No test files I've checked are invalidated by symbol changes.

2. The `_pr_delivery_write_result` in `pr-delivery/plugin.sh` writes `data.draft` from `_TPL_PR_DRAFT` only — and it OVERWRITES pr-open's pr-result.json. The final artifact has `draft=false` even if pr-open forced draft=true. The design lists `plugins/agent/pr-delivery/plugin.sh` in scope, so this should be handled.

3. The golden file `tests/golden/pr-result-artifact.golden` is the pr-DELIVERY result. After the change, a passing/non-draft delivery still has `draft:false` in the golden — this should remain unchanged.

4. The `plugin-artifact-goldens-test.sh` asserts `data.draft == false` on the golden — this stays valid.

## What is still unresolved

- Whether `pr-open-v2-inputs-test.sh` needs to test the new `gate_aggregator_result` input reading via ZBUILD_STAGE_INPUTS (SPEC-14-style test). This could be a missing file.

- Whether any ADR needs to be amended to describe the draft-PR-on-failure behavior. No ADR found yet that governs this.

## What I would do next

- Check the ADR-013 "Enforced by" section to see if the new draft-on-fail behavior needs a new statement+test there.
- Check if `pr-open-v2-inputs-test.sh` explicitly tests the exhaustive list of declared inputs (and thus needs updating when `gate_aggregator_result` is added).
