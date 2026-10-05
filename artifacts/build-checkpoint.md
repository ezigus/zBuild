# Build Checkpoint — Issue #2032

## Files read and what they told me

- `tests/integration/cycle-member-unfinished-no-convergence-test.sh`: SPEC-1/2/6 tests — need `cycle.member_unfinished.suppressed_convergence` event in event-schema.json, cycle-orchestrator.sh needs generic suppression block after the build-specific one.
- `tests/unit/adr-063-vocabulary-test.sh`: SPEC-7/8/9 tests — ADR-063 needs Status=Accepted, remove `exhausted`/`escalate`, add timed_out/out_of_turns, per-stage budget helpers, #2187 back-pointer.
- `tests/unit/spec-coverage-test.sh`: SPEC-3 — route_to_model rc=124 → disposition=timed_out.
- `tests/unit/spec-correspondence-test.sh`: SPEC-4 — route_to_model rc=1 → disposition=unavailable.
- `tests/unit/review-report-v2-contract-test.sh`: SPEC-5 — failed lens rc=1 → disposition=unavailable.
- `core/pipeline/cycle-orchestrator.sh:2541-2580`: _iter_did_not_finish computed from all members; build-specific suppression at 2575-2580. New block goes after line 2580.
- `config/event-schema.json:105-106`: existing cycle suppressions at lines 105-106; new event goes after.
- `docs/adr/ADR-063-budget-disclosure-and-partial-output.md`: Status=Proposed; hardcodes exhausted/escalate; §1 says "One helper renders the budget block".
- `plugins/agent/spec-coverage/plugin.sh:186-187`: `_raw="$(route_to_model ... || true)"` — needs rc capture without `|| true`.
- `plugins/agent/spec-correspondence/plugin.sh:120-122`: `_sc_call` has `|| true` inside; needs temp file approach since called via $().
- `plugins/agent/review-report/plugin.sh:172-174`: `_disposition="complete"` hardcoded even when lenses fail.
- `scripts/lib/router-rc-classify.sh:259-270`: `router_reason_disposition` maps reason → disposition word.
- `scripts/lib/lint-disposition-words.sh`: requires `# disposition-ok: <service>` within 3 lines before any literal `unavailable`.

## Conclusions

All 6 changes needed:
1. `config/event-schema.json` — add `cycle.member_unfinished.suppressed_convergence`
2. `core/pipeline/cycle-orchestrator.sh` — add generic suppression block after build-specific one
3. `docs/adr/ADR-063-budget-disclosure-and-partial-output.md` — full amendment
4. `plugins/agent/spec-coverage/plugin.sh` — rc capture, _scv_write accepts disposition param
5. `plugins/agent/spec-correspondence/plugin.sh` — temp file rc capture in _sc_call, _sc_write_result accepts disposition
6. `plugins/agent/review-report/plugin.sh` — first non-zero rc classification from failed lenses

## Next if stopped

Start with event-schema.json (simplest), then cycle-orchestrator.sh, then the three plugins, then ADR-063.
