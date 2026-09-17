# Plan Checkpoint — Issue #1840

## Files read and what they told me

- `plugins/agent/review-lens/manifest.yaml`: Already fully migrated to v2. Has result_contract:2, valid_verdicts, provides.role:review_lens, provides.events (3 events), primary:true on lens_result output, config.router.timeout_s/max_turns, inputs with only id+required, hooks.cleanup absent with ADR-054 §7 comment.

- `plugins/agent/review-lens/plugin.sh`: Fully implemented. Has _review_lens_envelope_schema_ok (schema gate), _review_lens_write_result (v2 writer on all exit paths), _review_lens_interrupt_handler (SIGTERM/SIGINT → disposition:interrupted), _review_lens_budget_guidance/_review_lens_wallclock_guidance (ADR-063 §1), _llm_envelope_parse --schema-gate call (line 330), rc=130 interrupted branch (lines 300-304), rc=10 exhausted branch (lines 307-312), all degrade paths use _review_lens_write_result.

- `plugins/agent/review-lens/lib/charters.sh`: Per-lens charter case statement + resolve_persona_charter delegate. Unchanged.

- `plugins/agent/review-lens/tests/review-lens-test.sh`: Comprehensive test coverage, SPEC-1 through SPEC-19 all present. Tests all v2 migration acceptance criteria.

## Conclusions

The migration from v2 is ENTIRELY implemented across prior commits on branch zbuild/issue-1840-ci:
- git log shows: "Migrate review-lens to contract v2 with schema-gate, budget guidance, and rc=10 exhausted disposition"

All acceptance criteria appear satisfied by current code:
- v2 result on every exit path (done in _review_lens_write_result)
- valid_verdicts in manifest (done)
- No artifact path literals in plugin code (uses $out parameter throughout)
- Router budgets from manifest (config.router.{timeout_s,max_turns})
- Behavioral parity (SPEC-8 guards)
- primary:true declared (done)
- Schema-gate envelope parse (done, line 330)
- Budget guidance injected (done, _review_lens_budget_guidance)
- disposition:exhausted for rc=10 (done, lines 307-312)
- provides.events, provides.role declared (done)
- Name-matched inputs (id+required only, done)
- cleanup absent with ADR-054 §7 comment (done)

## What's next

The implementation agent should:
1. Run `npm test` to confirm all SPEC-1 through SPEC-19 pass green
2. Grep check: no artifact path literals in _review_lens_write_result body
3. Grep check: no merge-action coercion tokens (approve|request_changes|"block") in plugin.sh/lib/charters.sh
4. If any test fails, fix the specific gap
