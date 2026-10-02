# Plan checkpoint — issue #1844 (resumed)

## Files re-read this session
- `plugins/agent/pr-delivery/plugin.sh`: confirms all exit paths, `return 2` on missing state_file (line 38), hardcoded paths at lines 51-53 (`review.json`, `_auf_gate_json`, `_auf_report_json`). pr-open delegation path at lines 156-169 reads pr-open's rc but not its verdict — fold-in #2250 requires reading pr-open result's verdict to detect `blocked`.
- `plugins/agent/pr-delivery/manifest.yaml`: `valid_verdicts:[]`, no `result_contract:2`, no `events:`, no router block. `primary:true` on pr_url is already set. Inputs use `id:` only (no paths). No cleanup hook.
- `tests/integration/pr-pipeline-test.sh`: SPEC-1..9 present. SPEC-3 asserts dry-run exits 0 and files exist. SPEC-4 asserts block guard refuses. SPEC-5 asserts delegation with mock gh. No v2 result assertions currently.
- `tests/unit/merge-v2-result-test.sh`: reference pattern for v2 unit test structure.

## Conclusions
Plan is consistent with prior checkpoint. Additional fold-in #2250 detail: pr-delivery must read pr-open's result verdict (not just rc) to detect `verdict:blocked` (pr-open returns rc=0 but writes verdict:blocked when review signal is missing). This needs a new SPEC in the unit test and a code change in the pr-open delegation branch of plugin.sh.

## What to do next (plan)
1. tests/unit/pr-delivery-v2-result-test.sh — failing unit test (TDD first)
2. plugins/agent/pr-delivery/manifest.yaml — result_contract:2, events, valid_verdicts
3. plugins/agent/pr-delivery/plugin.sh — write_result helper, ZBUILD_STAGE_INPUTS, rc∈{0,1}, v2 on every exit, check pr-open verdict for blocked (#2250)
4. tests/integration/pr-pipeline-test.sh — additive v2 assertions on SPEC-3/4/5, SPEC for #2250
