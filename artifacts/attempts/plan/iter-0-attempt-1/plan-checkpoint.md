# Plan checkpoint — issue #1844 (final)

## Files read this session
- `plugins/agent/pr-delivery/plugin.sh`: All exit paths confirmed. `return 2` at line 38 (missing state_file). Hardcoded input paths: `review_json` (line 51, dead — not a declared manifest input), `_auf_gate_json` (line 110, declared as `gate_aggregator_result`), `_auf_report_json` (line 111, declared as `review_report`). v1 JSON written on all paths (no `result_contract:2`). #2250 verdict reading already in code (lines 165-179) — reads `_po_verdict` from `pr_result_out` and handles `blocked`.
- `plugins/agent/pr-delivery/manifest.yaml`: `valid_verdicts:[]`, no `result_contract:2`, no `events:`. `provides.role:pr`, `primary:true` on `pr_url`, no `cleanup:` hook. Inputs use `id:` only — already name-matched.
- `tests/unit/pr-delivery-blocked-test.sh`: EXISTS — covers #2250 behavior (P1-P4: rc=1 on blocked, summary "No PR was opened", no "delivered", P4 pass case). Does NOT assert v2 result structure.
- `tests/integration/pr-pipeline-test.sh`: SPEC-1 through SPEC-9. No v2 result assertions yet.
- `tests/unit/merge-v2-result-test.sh`: reference pattern for the new unit test structure.
- `plugins/tool/pr-open/plugin.sh`: Shows v2 result pattern inline (jq -nc with result_contract:2, verdict, disposition, reason, data).
- `core/plugin-registry/lifecycle.sh` + various agent plugins: ZBUILD_STAGE_INPUTS is a file path; plugins read it with `jq -r '.inputs.<id> // empty' "${ZBUILD_STAGE_INPUTS}"`.

## Conclusions
1. The prior plan is accurate. No significant drift.
2. `pr-delivery-blocked-test.sh` already exists and covers behavior, so step-1 unit test focuses on v2 result structure (different coverage).
3. `review_json` is dead code (not a declared manifest input per comment) — must be removed in plugin.sh to satisfy "no artifact paths in code" acceptance criterion.
4. ZBUILD_STAGE_INPUTS pattern confirmed: `jq -r '.inputs.gate_aggregator_result // empty' "${ZBUILD_STAGE_INPUTS}"`.
5. v2 result writes: inline jq -nc with result_contract:2, verdict, disposition, reason (+ data for extra fields). Use `atomic_write` for output files.

## What to do next (plan = done)
1. tests/unit/pr-delivery-v2-result-test.sh — failing v2 unit test (TDD first)
2. plugins/agent/pr-delivery/manifest.yaml — result_contract:2, events, valid_verdicts
3. plugins/agent/pr-delivery/plugin.sh — v2 result helper, ZBUILD_STAGE_INPUTS, rc∈{0,1}, v2 on every exit, remove dead review_json
4. tests/integration/pr-pipeline-test.sh — additive v2 assertions + SPEC-10
