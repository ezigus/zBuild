# Plan checkpoint — issue #1843 (review-report → contract v2)

## Files read and what each told me

- `plugins/agent/review-report/manifest.yaml` — FULLY MIGRATED: has result_contract:2 under provides:, config.router:{timeout_s:300,max_turns:25}, primary:true, review_report_result output (required:true), cleanup:~ sentinel, valid_verdicts:[], provides.role, provides.events.
- `plugins/agent/review-report/plugin.sh` — FULLY MIGRATED: _rr_write_result on all terminal exit paths (missing_state_file→broken, missing_out_json→broken, normal→complete, any_lens_failed→exhausted). _rr_budget_guidance calls _route_resolve_max_turns/_route_resolve_timeout. Reads scope_manifest from ZBUILD_STAGE_INPUTS. Passes budget_guidance to _rr_fanout_lenses.
- `plugins/agent/review-report/lib/lenses.sh` — FULLY MIGRATED: _rr_lens_envelope_schema_ok predicate defined. _rr_parse_lens_out uses _llm_envelope_parse --schema-gate (no more extract_first_json_object). Has _rr_load_lenses, _rr_populate_artifact_registry, _rr_register_lens_artifact, _rr_lens_evidence.
- `tests/unit/review-report-plugin-test.sh` — FULLY POPULATED: SPEC-1 through SPEC-17 covering all v2 acceptance criteria. SPEC-8 asserts extract_first_json_object absent. SPEC-16 asserts disposition=exhausted on lens failure.

## Conclusions

The implementation is COMPLETE. All three source files and the test file reflect the full v2 migration including the #2035 parse fix and #2032 budget guidance. The commits `ae0c64c5` and `60444768` on branch `zbuild/issue-1843-ci` already contain the migration.

Remaining: (1) npm test must be confirmed green; (2) golden diff acceptance criterion — satisfied by SPEC-9/SPEC-10/SPEC-5 behavioral checks rather than a separate golden file (test file has no golden file assertion).

## What would come next

Emit the plan. The implement stage should execute `npm test` to confirm all SPECs pass, and verify each acceptance criterion against the committed code. No code changes are needed unless npm test reveals failures.
