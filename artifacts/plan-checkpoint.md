# Plan Checkpoint — Issue #1849

## Files read and what they told me

- `plugins/tool/merge/manifest.yaml`: No `provides:` section. `valid_verdicts: []`. Primary output `merge_result` (primary: true). Input `gate_aggregator_result` (required: false). review.json is BY PATH (legacy). No router block (T0).
- `plugins/tool/merge/plugin.sh`: rc=2 at 6 places (lines 38, 113, 137, 149, 174, 189). Result uses `status` not `verdict`. Constructs `$artifacts_dir/gate-aggregator-result.json` (declared input). BY PATH: `review.json` (legacy, not declared). Cleanup is empty.
- `plugins/tool/pr-open/manifest.yaml`: Has `provides:` with `events:` but NO `result_contract: 2`. `valid_verdicts: []`. `pr_url` output has `primary: true`. Comment says "Do not give it a role". Input `review_report` (required: false).
- `plugins/tool/pr-open/plugin.sh`: rc=2 at many places. Result uses `status` field. Constructs `$artifacts_dir/review-report.json` (declared input). BY PATH: `review.json` (legacy). Cleanup is empty.
- `plugins/tool/deploy-release/manifest.yaml`: Has `provides:` with `role` and `events`. NO `result_contract: 2`. `valid_verdicts: [deployed, error]` (correct). `deploy_result` has `primary: true`. Input `pr_url`.
- `plugins/tool/deploy-release/plugin.sh`: Already uses `verdict` field! rc=0/1 for most paths, rc=2 at line 29 (state_file absent). Constructs `$artifacts_dir/pr-url.txt` (declared input). Cleanup is empty.
- Existing tests: `pr-open-zero-commits-halts-test.sh` checks event verdict=error (not result JSON status), `template-merge-policy-test.sh` checks template parsing (not result shapes). Both may need minor v2 result field additions.

## Conclusions reached

1. All three need `provides.result_contract: 2`.
2. All result JSONs need `result_contract:2, verdict, disposition, reason` top-level.
3. All rc=2 → rc=1.
4. Disposition: `complete` (normal), `interrupted` (rc=130/143/124), `broken` (other errors), `unavailable` (outcome unknown after interruption for irreversible actions).
5. merge needs full `provides:` (role, events, result_contract). pr-open adds result_contract to existing provides (no role per constraint). deploy-release adds result_contract to existing provides.
6. Router budgets: T0 → no `router:` block needed.
7. Primary outputs: all three already declared. No changes needed.
8. Cleanup hooks: all three empty → stay absent in manifests.
9. For "no paths in code": replace DECLARED input constructions with ZBUILD_STAGE_INPUTS + fallback. Legacy BY PATH reads (review.json) stay.
10. valid_verdicts: merge=[pass, error]; pr-open=[pass, blocked, error]; deploy-release=[deployed, error] (unchanged).

## What to do next

TDD first: write tests (steps 1, 4, 7), then manifest changes (steps 2, 5, 8), then plugin.sh migrations (steps 3, 6, 9), then regression fixes (step 10).
