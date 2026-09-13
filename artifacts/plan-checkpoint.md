# Plan checkpoint — issue #1843 (review-report → contract v2)

## Files read and what each told me

- `plugins/agent/review-report/manifest.yaml` — already has `primary: true` on `review_report` output, `provides.role: review_report`, `provides.events`, `valid_verdicts: []`. Missing: `result_contract: 2`, `router:` budget block under config.
- `plugins/agent/review-report/plugin.sh` — the main hook `review_report_run` + inner `_rr_run_inner`. Currently writes no v2 result file (result_contract/verdict/disposition/reason). Returns bare rc=0 always. On fatal error (missing state_file, missing out_json) it returns 2.
- `plugins/agent/review-report/lib/lenses.sh:145` — `_rr_parse_lens_out` uses bare `extract_first_json_object` (LAST-wins), not `_llm_envelope_parse --schema-gate`. This is the live defect from #2035.
- `plugins/tool/teardown/plugin.sh:255` — canonical v2 result pattern: `{result_contract:2, verdict, disposition, reason}` via heredoc + `atomic_write`.
- `core/contract/version.sh` — defines `_ZBUILD_CONTRACT_V2=2`; min/max are 1..2.
- `core/pipeline/disposition.sh` — closed set: complete, interrupted, throttled, exhausted, unavailable, broken.
- `plugins/agent/design/plugin.sh` — shows `_design_write_result`, `_design_budget_guidance`, `_route_resolve_max_turns`, `_route_resolve_timeout`, and how `exhausted` disposition is emitted.
- `core/plugin-registry/manifest-router-budget.sh` — manifest declares `config.router.timeout_s`, `config.router.max_turns`, `config.router.retries`.
- `plugins/agent/security-lens/plugin.sh:42,140` — canonical `_llm_envelope_parse --schema-gate` pattern to copy for the parse fix.
- `tests/unit/review-report-plugin-test.sh` — existing test stubs `route_to_model`, tests lens fan-out. Will need new SPEC assertions for v2 result, envelope parse, budget guidance.

## Conclusions

1. **Manifest**: add `result_contract: 2` under `provides:`, add `config.router:` block with `timeout_s` and `max_turns`.
2. **plugin.sh**: write v2 result (result_contract/verdict/disposition/reason/data) on every terminal exit path; emit `disposition: exhausted` when router signals budget exhaustion; inject budget guidance from `_route_resolve_max_turns`/`_route_resolve_timeout` into each lens prompt.
3. **lenses.sh**: replace `extract_first_json_object` with `_llm_envelope_parse --schema-gate _rr_lens_envelope_schema_ok`; add the schema predicate function. Keep failure behaviour identical (emit `review_report.lens.unparseable`, degrade to empty).
4. **No path construction to remove**: plugin.sh already receives paths as arguments; lenses.sh writes per-lens artifacts to `$artifact_dir`; no hardcoded paths in plugin code.
5. **Tests**: amend `tests/unit/review-report-plugin-test.sh` with SPEC assertions for: (a) v2 result written, (b) correct disposition on each exit path, (c) envelope parse recovery, (d) budget block in prompt, (e) exhausted disposition.

## What would come next
Write tests first (red), then implement in manifest → plugin.sh → lenses.sh, confirm green.
