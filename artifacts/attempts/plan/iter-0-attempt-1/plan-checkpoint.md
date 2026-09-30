# Plan checkpoint — issue #1844

## Files read and what they told me

- `plugins/agent/pr-delivery/manifest.yaml`: no `result_contract:2`, no `events:`, `valid_verdicts:[]`, `provides.role: pr` already set, `primary: true` on pr_url already set, hooks has only `run:` (no cleanup — correct), inputs already use `id:`+`required:` only (no path/type)
- `plugins/agent/pr-delivery/plugin.sh`: constructs input paths in code (`$artifacts_dir/review.json`, `$artifacts_dir/gate-aggregator-result.json`, `$artifacts_dir/review-report.json`); has `return 2` on missing state_file (violates rc∈{0,1}); writes non-v2 JSON on all exit paths; no `_pr_delivery_write_result` helper
- `core/pipeline/disposition.sh`: closed vocab for disposition words; `router_reason_disposition` maps reason→disposition
- `scripts/lib/router-rc-classify.sh`: `router_reason_disposition` for LLM-call dispositions
- `plugins/agent/plan/manifest.yaml` + `plugins/agent/design/plugin.sh`: reference implementations for v2 — `result_contract:2`, `events:`, `valid_verdicts:[pass,error]`, `_<stage>_write_result` helper writing `{result_contract:2, verdict, disposition, reason, data}`
- `plugins/tool/merge/plugin.sh`: input path from `ZBUILD_STAGE_INPUTS` pattern (jq lookup); writes `{result_contract:2, verdict, disposition, reason, data}` on every exit path
- `tests/unit/merge-v2-result-test.sh`: pattern for v2 result unit test (SPECs for manifest fields + behavior)
- `tests/integration/pr-pipeline-test.sh`: existing integration tests for pr-delivery (SPEC-1..9)

## Conclusions

Exit paths in plugin.sh that need v2 result writes:
1. missing state_file → change return 2→1, write error/misconfigured
2. review verdict=block → write error/complete + reason
3. dry-run → write pass/complete
4. merge delegation success → write pass/complete
5. merge delegation failure → carry delegate's disposition, write error
6. pr-open delegation success → write pass/complete
7. pr-open delegation failure → carry delegate's disposition, write error
8. fallback gh success → write pass/complete
9. fallback gh failure → write error/unavailable

Input path constructions to remove (replace with ZBUILD_STAGE_INPUTS reads):
- `$artifacts_dir/review.json` (not in manifest inputs, referenced implicitly — remove or leave as fallback?)
- `$artifacts_dir/gate-aggregator-result.json` → read from ZBUILD_STAGE_INPUTS[gate_aggregator_result]
- `$artifacts_dir/review-report.json` → read from ZBUILD_STAGE_INPUTS[review_report]

The `review.json` path is NOT a declared input but is used for the block guard — after migration it should be removed or superseded. The `review_report` input (review-report.json) IS declared and should come from ZBUILD_STAGE_INPUTS.

## What to do next

Plan steps:
1. Write failing unit test (tests/unit/pr-delivery-v2-result-test.sh) — TDD first
2. Update manifest.yaml (result_contract:2, events, valid_verdicts:[pass,error])
3. Update plugin.sh (write_result helper, ZBUILD_STAGE_INPUTS for inputs, rc∈{0,1}, v2 on every exit)
4. Update integration test to add v2 assertions on existing SPECs
