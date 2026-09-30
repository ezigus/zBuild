# Plan checkpoint — review-aggregator v2 migration (#1842)

## Files read and key findings

- `plugins/agent/review-aggregator/manifest.yaml`: has `valid_verdicts: []` (no verdict), `result_contract` absent from `provides:`, `review_report_md` is `required: false` with `summary: true`. Already has `provides.role`, `provides.events`, `primary: true` output.
- `plugins/agent/review-aggregator/plugin.sh`: 452 lines. Uses glob fallback (`_ra_collect_lenses_glob`) and roster discovery. No ZBUILD_STAGE_INPUTS reading. No interrupt handling. Always returns 0. No v2 result fields written.
- `tests/unit/review-aggregator-test.sh`: SPEC-1..10, uses glob fixture. SPEC-3 explicitly asserts NO `.verdict` field — needs updating after v2 migration.
- `tests/unit/review-aggregator-roster-test.sh`: Tests roster discovery path.
- `plugins/agent/review-lens/manifest.yaml`: Reference for v2: `provides.result_contract: 2`, `valid_verdicts: [complete, degraded]`, `required: true` on summary.
- `plugins/agent/review-lens/plugin.sh`: Pattern for `_rl_input`, interrupt handler, `_review_lens_write_result`.
- `scripts/lib/stage-summary.sh`: `stage_summary_write <path> <stage> <verdict> <reason> [body]`.
- `core/pipeline/input-resolve.sh`: ZBUILD_STAGE_INPUTS index shape: `{"inputs": {"lens_result": ["/a.json", "/b.json"]}}` — a map producer yields a JSON array.

## Conclusions

1. manifest needs: `result_contract: 2` in provides, `valid_verdicts: [complete, degraded]`, `review_report_md.required: true`, cleanup-absent note.
2. plugin.sh needs: `_ra_input` helper (reads ZBUILD_STAGE_INPUTS), `_ra_collect_lenses_inputs` (reads lens_result array), remove `_ra_collect_lenses_glob`, update `_review_aggregator_run_inner` to use ZBUILD_STAGE_INPUTS primary / roster fallback, add v2 fields to result, write summary on all paths, interrupt handler.
3. New test file: `tests/unit/review-aggregator-v2-test.sh` (test-first, covers all DoD items).
4. Existing test update: SPEC-3 now must assert `.verdict == "complete"` (not absent), update glob fixtures to ZBUILD_STAGE_INPUTS.

## What to do next if stopping now

Emit the plan JSON with 4 steps in the order above. The glob removal changes unit test fixture setup; ZBUILD_STAGE_INPUTS tests need to set the env var pointing at a JSON file with the lens paths array.
