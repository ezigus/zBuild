# Design Stage Checkpoint — Issue #1799

## Files read and key findings

- `plugins/tool/pr-open/plugin.sh`: Entry point `pr_open_run` → `_pr_open_run_inner`. Already reads state_file for `.issue`. State_file path is available. Draft mode controlled by `_draft_bool` from `_TPL_PR_DRAFT`. Body built by `_pr_open_compose_body`.
- `plugins/tool/pr-open/lib/advisory-section.sh`: `_pr_open_compose_body(issue, plan_summary, review_json, review_verdict, advisory_report, test_verdict)` composes the PR body. No convergence state today.
- `plugins/tool/pr-open/manifest.yaml`: Current inputs: review_report, plan, test_results. No gate_aggregator_result. Events: plugin.pr_open.branch_fallback_used, plugin.pr_open.preflight_remote_has_work.
- `plugins/tool/pr-open/tests/pr-open-test.sh`: Has SPEC-5 (draft=false default) and SPEC-6 (_TPL_PR_DRAFT=true → draft=true). Tests call `_pr_open_run_inner` directly with mocked git/gh.
- `plugins/agent/pr-delivery/plugin.sh`: Calls `pr_open_run "pr" "$state_file"`. Reads `gate_aggregator_result` from ZBUILD_STAGE_INPUTS. This is the caller of the tool.
- `plugins/agent/pr-delivery/manifest.yaml`: Has `gate_aggregator_result` as optional input.
- `core/pipeline/state_helpers.sh`: State `.status` values: complete, failed, in_progress, complete_unconverged, interrupted, aborted. Set by `_set_pipeline_status`.
- `core/pipeline/cycle-orchestrator.sh`: `cycle_orchestrator_run` writes `cycle_iterations[<id>].status` = max_iterations/plateau/divergence when not converged.
- `core/pipeline/runner.sh`: On cycle rc∈{1,2,3} (max_iter/plateau/divergence), sets `_RUNNER_CYCLE_UNCONVERGED=1` and continues. On rc=8, sets pipeline_status=failed. Cycle state persisted in state file under `cycle_iterations`.
- `ADR-021`: State schema has `cycle_iterations.<id>.{status, current_iter, max_iterations}`.
- `tests/integration/pr-pipeline-test.sh`: SPEC-9 and #1844/SPEC-16 assert `data.draft=false` for passing runs (state has no `.status="failed"`).
- `tests/unit/plugin-artifact-goldens-test.sh`: Asserts golden pr-result-artifact has `draft=false`.
- `tests/golden/pr-result-artifact.golden`: Has `"draft":false` — represents passing run.
- `config/event-schema.json`: Engine events only. Plugin events go in manifest. No edit needed for new pr-open event.

## Key conclusions

1. `_pr_open_run_inner` already has access to `state_file` → can read `.status` and `.cycle_iterations` directly.
2. Draft forcing logic: after computing `_draft_bool` from `_TPL_PR_DRAFT`, add check: if `state.status=="failed"` OR any `cycle_iterations[*].status=="max_iterations"`, force `_draft_bool=true`.
3. For body convergence section (R-3, R-4): read from state_file `.cycle_iterations` and from ZBUILD_STAGE_INPUTS `.inputs.gate_aggregator_result`.
4. gate_aggregator_result JSON structure: `{"verdict":"fail","reason":"gates failed: lint coverage","failed":["lint","coverage"],...}`.
5. Existing draft=false tests (SPEC-9, SPEC-16) use state files without `.status` field → will still yield non-draft after change.
6. No changes needed to event-schema.json, runner.sh, or pr-delivery/plugin.sh.
7. wiki/plugins/pr.md is stale (shows old always_draft:true manifest) → needs update.

## WIRING
`plugins/tool/pr-open/plugin.sh` — calls `_pr_open_compose_body` with convergence args and applies new draft logic. Reverting this file fails the new tests.

## What's still unresolved
Nothing major. All data sources identified, all affected files located.
