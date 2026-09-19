## Files read and conclusions

- `plugins/agent/review-lens/manifest.yaml` (94 lines): has result_contract:2, valid_verdicts:[complete,degraded], provides.role:review_lens, provides.events (3 events), primary:true on lens_result, config.router.timeout_s:300 and max_turns:10, inputs with only id+required, no hooks.cleanup with ADR-054 §7 comment.

- `plugins/agent/review-lens/plugin.sh` (398 lines): has _review_lens_envelope_schema_ok schema gate, _llm_envelope_parse --schema-gate at line 332, _review_lens_write_result on all exit paths (rc=130 interrupted branch, rc=10 exhausted branch, broken/normalization), budget guidance from _route_resolve_max_turns/_route_resolve_timeout, _review_lens_interrupt_handler trap registered. result_contract:2 on all write paths.

- `plugins/agent/review-lens/tests/review-lens-test.sh` (912 lines): SPEC-1 through SPEC-19 all written. SPEC-1..12 cover persona/carrier logic; SPEC-7..SPEC-19 cover v2 contract, exhausted disposition, interrupted disposition, budget guidance, valid_verdicts, primary:true, provides.events, provides.role, name-matched inputs, no-path-in-code, golden diff.

## Conclusions

Implementation is fully committed on branch zbuild/issue-1840-ci. This is purely a VERIFICATION plan. All acceptance criteria appear satisfied by the existing code. Steps 2-6 are contingency-only gap fixes.

## What to do next

Emit JSON plan immediately.
