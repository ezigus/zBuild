# Plan Checkpoint — Issue #1849

## Files read and what they told me

- `plugins/tool/merge/manifest.yaml`: No `provides:` section. `valid_verdicts: []`. Primary output is `merge_result` (merge-result.json). Has `pr_url` and `merge_summary` outputs. Input: `gate_aggregator_result` (required: false). NO router block (T0 tool). `review.json` explicitly noted as BY PATH read (legacy per #979).
- `plugins/tool/merge/plugin.sh`: Uses rc=2 for errors. Result JSON uses `status` field not `verdict`. Constructs `"$artifacts_dir/gate-aggregator-result.json"` for input. Constructs `"$artifacts_dir/review.json"` as undeclared by-path read (legacy). Emits `plugin.result` event. merge_cleanup function body is empty (no live resources).
- `plugins/tool/pr-open/manifest.yaml`: Has `provides:` with `events:` but NO `result_contract: 2`. `valid_verdicts: []`. `primary: true` on pr_url output. Input: `review_report` (required: false). Per-manifest comment: "Do not give it a role." review.json is BY PATH read (legacy).
- `plugins/tool/pr-open/plugin.sh`: Uses rc=2. Result JSON uses `status` field. Constructs `"$artifacts_dir/review-report.json"` for declared input. pr_open_cleanup function body is empty.
- `plugins/tool/deploy-release/manifest.yaml`: Has `provides:` with `role: deploy_release_executor`, events. NO `result_contract: 2`. `valid_verdicts: [deployed, error]`. Primary output is `deploy_result`. Input: `pr_url` (required: false). Constructs `"$artifacts_dir/pr-url.txt"` for input.
- `plugins/tool/deploy-release/plugin.sh`: Already uses `verdict` field in result JSON! rc=0 on success, rc=1 on failures. deploy_release_cleanup body is empty.
- `plugins/tool/mutation-gate/plugin.sh`: Reference v2 example. Uses `result_contract:2, verdict, disposition, reason` in result. disposition="complete" for all paths. Still constructs input paths from artifacts_dir (so v2 does NOT require ZBUILD_STAGE_INPUTS migration for all plugins — mutation-gate is v2 without it).
- `core/plugin-registry/lifecycle.sh`: Sets `ZBUILD_STAGE_INPUTS` env var when hook_name == "run". Empty cleanup hook emits `plugin.cleanup.absent` event and returns 0 (no plugin code needed for "no resources" case).

## Conclusions reached

1. All three plugins need `provides.result_contract: 2` in manifest.
2. All result JSONs need `result_contract:2, verdict, disposition, reason` top-level fields.
3. All rc=2 must become rc=1.
4. Disposition values: `complete` (normal), `interrupted` (signal death rc=130/143/124), `broken` (other errors), `unavailable` (outcome unknown after interruption for irreversible actions).
5. `merge` needs a full `provides:` section with role, events, result_contract.
6. `pr-open`: add result_contract:2 to existing provides; NO role per manifest comment.
7. `deploy-release`: add result_contract:2 to existing provides; keeps existing role+events.
8. Router budgets: T0 tools make no LLM calls → no `router:` block needed. Acceptance criterion satisfied by noting this in manifest/notes.
9. Primary outputs: already declared in all three manifests. Nothing to change.
10. For "no artifact paths in code": mutation-gate (v2) still constructs paths. This criterion likely means no hardcoded INPUT artifact filenames. Use ZBUILD_STAGE_INPUTS with fallback for library-call compat. Need to re-check if test harness can mock ZBUILD_STAGE_INPUTS.
11. `valid_verdicts` for merge: [pass, error] (pr_fallback goes in data block); pr-open: [pass, blocked, error]; deploy-release: [deployed, error] (unchanged).
12. Cleanup hooks: all three have empty cleanup sections → engine emits plugin.cleanup.absent, plugin code needs nothing extra. (The `cleanup` section in manifests stays absent.)
13. TDD: tests must be written FIRST and fail before implementation.

## What I would do next if stopping now

Write tests for merge v2 result structure first, then implement, then repeat for pr-open and deploy-release. The primary risk is the "no artifact paths in code" interpretation — whether ZBUILD_STAGE_INPUTS is required for declared inputs or whether the current fallback pattern (as in mutation-gate) is acceptable.
