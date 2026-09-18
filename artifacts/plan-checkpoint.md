## Files read and conclusions

- `plugins/agent/review-lens/manifest.yaml` (95 lines): has result_contract:2, valid_verdicts:[complete,degraded], provides.role:review_lens, provides.events (3 events), primary:true on lens_result, config.router.timeout_s:300 and max_turns:10, inputs with only id+required, no hooks.cleanup with ADR-054 §7 comment.

- `plugins/agent/review-lens/plugin.sh` (396 lines): has _review_lens_envelope_schema_ok schema gate, _llm_envelope_parse --schema-gate at line 330, _review_lens_write_result on all exit paths, rc=130 interrupted branch (lines 300-304), rc=10 exhausted branch (lines 310-313), _review_lens_budget_guidance from _route_resolve_max_turns, _review_lens_wallclock_guidance from _route_resolve_timeout, _review_lens_interrupt_handler trap registered.

- `plugins/agent/review-lens/tests/review-lens-test.sh` (883 lines): SPEC-1 through SPEC-19 all written, covering all acceptance criteria. Also has legacy SPEC-1 through SPEC-12 tests for prior v1 behavior.

## Conclusions

Implementation appears complete per prior commits. This is a VERIFICATION plan. The test suite is the gating check; steps 2-6 are contingency fixes for specific SPEC failures.

## What to do next

Produce the JSON plan immediately — no more exploration needed.
