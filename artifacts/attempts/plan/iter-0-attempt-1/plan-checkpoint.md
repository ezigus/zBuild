# Plan Checkpoint — Issue #1799

## Files Read
- `plugins/tool/pr-open/plugin.sh`: `_pr_open_run_inner` drafts PR based on `_TPL_PR_DRAFT` only; no pipeline status read; `_draft_bool` set once at top; `_pr_open_compose_body` called with plan_summary, review_json, review_verdict, advisory_report, test_verdict. No convergence state passed.
- `plugins/tool/pr-open/lib/advisory-section.sh`: `_pr_open_compose_body` builds PR body. No mention of cycle iterations or convergence state. Body has plan goal, review verdict, advisory block, test verdict.
- `plugins/tool/pr-open/tests/pr-open-test.sh`: existing tests cover blocked verdict, no review signal, draft flag, advisory section. No convergence/failure tests.
- `plugins/tool/pr-open/manifest.yaml`: inputs declared: review_report, plan, test_results. No gate_aggregator_result (pr-delivery declares it).
- `plugins/agent/pr-delivery/plugin.sh`: calls `pr_open_run "pr" "$state_file"`. Reads `gate_aggregator_result` from ZBUILD_STAGE_INPUTS. The ZBUILD_STAGE_INPUTS with gate_aggregator_result is available when pr-open runs (shared process).
- `plugins/tool/gate-aggregator/plugin.sh`: gate-aggregator-result.json schema = `{verdict, reason, gates: {name:status}, failed: [names]}`.
- `core/pipeline/cycle-orchestrator.sh`: pipeline-state.json `.cycle_iterations.<cycle_id>.status` = "max_iterations" when not converged, "complete" when converged. `.cycle_iterations.<cycle_id>.current_iter` = last iteration number. `.cycle_iterations.<cycle_id>.max_iterations` = max configured.
- `core/pipeline/state_helpers.sh`: pipeline-state.json `.status` field = "failed" when pipeline failed.

## Conclusions
- Bug is in `_pr_open_run_inner`: `_draft_bool` only follows `_TPL_PR_DRAFT`; nothing reads `.status` or `cycle_iterations` from state_file.
- Fix: after resolving `_draft_bool` from `_TPL_PR_DRAFT`, check pipeline status and cycle convergence from state_file. If `status == "failed"` OR any `cycle_iterations[*].status == "max_iterations"`, force `_draft_bool = "true"`.
- Also need to read gate-aggregator-result.json from ZBUILD_STAGE_INPUTS and pass failing gates to body.
- `_pr_open_compose_body` must accept + render convergence block with: iterations used/max, "not converged" label, failing gates.
- Need to add `gate_aggregator_result` to pr-open manifest inputs (to follow ADR-055 §1 — declared inputs via engine index). Or read it from artifacts_dir directly since the path is standard. Actually ZBUILD_STAGE_INPUTS for pr-open includes whatever pr-delivery's stage inputs are, including gate_aggregator_result. So it's already accessible.
- Tests: 2 new test cases in pr-open-test.sh: (1) failed pipeline status → draft, (2) max_iterations cycle → draft. Both must fail on main before the fix.

## What Needs to Change
1. `plugins/tool/pr-open/plugin.sh`: (a) read pipeline_status + cycle_iterations from state_file; (b) read gate_aggregator_result from ZBUILD_STAGE_INPUTS; (c) force draft if failed or unconverged; (d) pass convergence info to _pr_open_compose_body.
2. `plugins/tool/pr-open/lib/advisory-section.sh`: (a) add convergence params to `_pr_open_compose_body`; (b) render convergence block in PR body.
3. `plugins/tool/pr-open/manifest.yaml`: add gate_aggregator_result as optional input (ADR-055 §1).
4. `plugins/tool/pr-open/tests/pr-open-test.sh`: add 2 regression tests (must be red on main).

## Still Unresolved
- Whether `cycle_id` is always "build_test_cycle" or if we need to scan all keys in cycle_iterations. The issue names "build_test_cycle" but the fix should be general (any cycle that hit max_iterations). Scanning all keys in cycle_iterations is safer.
- Whether to add gate_aggregator_result to pr-open's manifest or rely on pr-delivery's declaration. Reading via ZBUILD_STAGE_INPUTS is already how pr-open works (ADR-055 §1).
