## Review Report

**Merge Readiness:** needs_attention

1 of 6 lens(es) did not run (correctness) — their review is missing, not clean. 7 merge-readiness finding(s) across 6 lens(es) (0 critical, 0 high).

> **Advisory:** Some lenses did not run, so this report is incomplete; re-run the review before merging. Advisory only — this does not block the pipeline.

### Lens Findings

#### correctness (score: 0/10)
No findings.

This lens did not finish — what it found before it was cut off (unfinished, not checked):
> # Correctness lens checkpoint
> 
> ## Files read and conclusions
> 
> - \`core/router/route.sh\`: Both insertion points are correct. \`$secs\` is a local set at 1703 in \`route_to_model_loop\`, in scope at both 1830 and 2350. \`_ROUTE_MODEL_ID\`/\`_ROUTE_PROVIDER\` etc. are set by \`_route_lookup_model\` at 1672 before line 1830. \`_ROUTE_CALL_COST\`/\`_ROUTE_MODEL_USED\` are set by \`_route_record_call\` at 2344 before \`_route_emit_outcome\` at 2350. \`_ROUTE_INPUT_TOKENS\`/\`_ROUTE_OUTPUT_TOKENS\` are assigned from \`in_tok\`/\`out_tok\` (extracted at 2339-2340) at 2346-2347. Cache tokens extracted at 2348-2349 from same \`$json_file\`. Order is correct. 
> 
> - \`_route_emit_model_route\` is called before the claude invocation (mirrors sync path line 203 placement). \`_route_emit_outcome\` is called only on the success path (line 2350), after \`_route_record_call\`/\`_route_update_ledger\`. No error path reaches line 2350. Consistent with sync path behavior.
> 
> - Golden file: sequence \`loop.iteration → model.route → router.max_turns.flag_omitted → model.outcome → loop.complete\` matches the code order.
> 
> - TC-2 LOOP_COMPLETE: jq interprets \`\n\` as real newline, so \`_route_has_done_sentinel\` correctly detects it on its own line.
> 
> - Ledger write: mock cost 0.0005 formats as 0.000500, which is non-zero, so ledger rows are written.
> 
> - No critical correctness issues found. Score: 9 (one low-severity finding about assert_eq arg order in SPEC-3 assertion).

#### performance (score: 9/10)
- [low] core/router/route.sh:2346 — Two separate \`jq\` subprocess invocations read the same \`$json_file\` to extract \`cache_read_input_tokens\` and \`cache_creation_input_tokens\`; a single \`jq\` call emitting both values would halve the subprocess overhead per iteration, though impact is negligible relative to the surrounding AI API call latency.

#### red-team (score: 7/10)
- [low] core/router/route.sh:1830 — On the rc=124+sentinel exit path (lines 2126-2152), the function returns 0 after emitting 'router.loop.iter.timeout_with_sentinel' and 'loop.complete' but never reaches the success block at line 2337; because _route_emit_model_route was already called at line 1830 (before the call), that iteration now produces a 'model.route' event with no matching 'model.outcome', introducing an asymmetric event pair that did not exist before this diff (previously neither event was emitted for this path).
- [low] core/router/route.sh:1830 — Both _route_emit_model_route (line 1830) and _route_emit_outcome (line 2350) are passed the base '$secs' value, but when the inner retry while-loop escalates to '_iter_local_secs' (line 2107) and the iteration ultimately succeeds on a retry, the emitted timeout_s field reports the original base timeout rather than the actual escalated timeout that was used; this is the same behaviour as the sync path, so the inaccuracy is pre-existing and not worsened by this diff.
- [low] tests/integration/router-loop-emits-model-events-test.sh — The new test exercises only the clean-exit (done_sentinel, rc=0) path; it does not cover the rc=124+done_sentinel early-return path introduced at route.sh:2126-2152, so the asymmetric model.route-without-model.outcome behaviour on that path (finding 1) cannot be caught by this test suite.
- [low] tests/integration/router-loop-emits-model-events-test.sh:185 — The cost_usd assertion only checks that the value is non-empty and not the literal string 'unknown'; it does not assert the numeric value extracted from the mock's total_cost_usd:0.0012 field, so a cost-pipeline regression that produces any non-'unknown' string (e.g. a provider name or a stale value) would still pass the assertion.
- [low] tests/integration/router-loop-emits-model-events-test.sh — Event counts are verified but intra-iteration ordering is not: no assertion confirms that each model.route precedes its paired model.outcome within the same iteration, so an implementation that emitted all model.outcome events before all model.route events would satisfy every assert_eq in this test.

#### scope (score: 10/10)
No findings.

#### security (score: 9/10)
- [low] core/router/route.sh:2348 — Cache token values extracted from the LLM provider's JSON response via \`jq -r\` are assigned to shell variables without validating they are non-negative integers before emission; if the provider returns a non-numeric value, it flows as a string into the event payload — this is safely handled by \`jq --arg\` in \`eb_emit_event\` and mirrors the pre-existing sync-path pattern at lines 1306-1307, but the loop path now introduces the same unvalidated data flow for the first time.

#### sre (score: 7/10)
- [medium] core/router/route.sh:1830 — The two new emitter calls (_route_emit_model_route at line 1830 and _route_emit_outcome at line 2350) lack the \`2>/dev/null || true\` guard that every other \`eb_emit_event\` invocation in the loop body carries (lines 1829, 1921, 2044, 2092, 2102, 2131, 2148, 2234, 2237, 2314); under \`set -euo pipefail\`, an event-bus write failure aborts the loop iteration rather than degrading gracefully, and the \`model.outcome\` case is the higher-risk path because the LLM call has already completed and its cost recorded by the time the emitter runs.
- [low] core/router/route.sh:1830 — On any failed iteration (rate-limit exhaustion, consecutive timeouts, or non-zero rc) \`model.route\` is emitted before the call but \`model.outcome\` is never emitted, producing orphaned route events in the stream; this mirrors the pre-existing sync-path asymmetry (lines 203 vs 244) but is newly introduced for the loop path, which build and design use for every iteration.
- [low] core/router/route.sh:2350 — Both \`model.route\` (line 1830) and \`model.outcome\` (line 2350) are emitted with \`$secs\`, the base timeout resolved once at loop initialisation (line 1703), not with \`_iter_local_secs\`, the per-attempt escalated timeout that ADR-029 intra-iteration retry raises (line 2107); \`timeout_s\` in both events underreports the actual timeout used whenever a retry within an iteration triggered escalation.


### Merge-Readiness Findings (de-duped)
- [low] core/router/route.sh:2348 — Cache token values extracted from the LLM provider's JSON response via \`jq -r\` are assigned to shell variables without validating they are non-negative integers before emission; if the provider returns a non-numeric value, it flows as a string into the event payload — this is safely handled by \`jq --arg\` in \`eb_emit_event\` and mirrors the pre-existing sync-path pattern at lines 1306-1307, but the loop path now introduces the same unvalidated data flow for the first time. _(lenses: security)_
- [low] core/router/route.sh:1830 — On the rc=124+sentinel exit path (lines 2126-2152), the function returns 0 after emitting 'router.loop.iter.timeout_with_sentinel' and 'loop.complete' but never reaches the success block at line 2337; because _route_emit_model_route was already called at line 1830 (before the call), that iteration now produces a 'model.route' event with no matching 'model.outcome', introducing an asymmetric event pair that did not exist before this diff (previously neither event was emitted for this path). _(lenses: red-team)_
- [medium] core/router/route.sh:1830 — On any failed iteration (rate-limit exhaustion, consecutive timeouts, or non-zero rc) \`model.route\` is emitted before the call but \`model.outcome\` is never emitted, producing orphaned route events in the stream; this mirrors the pre-existing sync-path asymmetry (lines 203 vs 244) but is newly introduced for the loop path, which build and design use for every iteration.; The two new emitter calls (_route_emit_model_route at line 1830 and _route_emit_outcome at line 2350) lack the \`2>/dev/null || true\` guard that every other \`eb_emit_event\` invocation in the loop body carries (lines 1829, 1921, 2044, 2092, 2102, 2131, 2148, 2234, 2237, 2314); under \`set -euo pipefail\`, an event-bus write failure aborts the loop iteration rather than degrading gracefully, and the \`model.outcome\` case is the higher-risk path because the LLM call has already completed and its cost recorded by the time the emitter runs. _(lenses: sre)_
- [low] core/router/route.sh:2350 — Both \`model.route\` (line 1830) and \`model.outcome\` (line 2350) are emitted with \`$secs\`, the base timeout resolved once at loop initialisation (line 1703), not with \`_iter_local_secs\`, the per-attempt escalated timeout that ADR-029 intra-iteration retry raises (line 2107); \`timeout_s\` in both events underreports the actual timeout used whenever a retry within an iteration triggered escalation. _(lenses: sre)_
- [low] core/router/route.sh:2346 — Two separate \`jq\` subprocess invocations read the same \`$json_file\` to extract \`cache_read_input_tokens\` and \`cache_creation_input_tokens\`; a single \`jq\` call emitting both values would halve the subprocess overhead per iteration, though impact is negligible relative to the surrounding AI API call latency. _(lenses: performance)_
- [low] tests/integration/router-loop-emits-model-events-test.sh — Event counts are verified but intra-iteration ordering is not: no assertion confirms that each model.route precedes its paired model.outcome within the same iteration, so an implementation that emitted all model.outcome events before all model.route events would satisfy every assert_eq in this test.; The new test exercises only the clean-exit (done_sentinel, rc=0) path; it does not cover the rc=124+done_sentinel early-return path introduced at route.sh:2126-2152, so the asymmetric model.route-without-model.outcome behaviour on that path (finding 1) cannot be caught by this test suite. _(lenses: red-team)_
- [low] tests/integration/router-loop-emits-model-events-test.sh:185 — The cost_usd assertion only checks that the value is non-empty and not the literal string 'unknown'; it does not assert the numeric value extracted from the mock's total_cost_usd:0.0012 field, so a cost-pipeline regression that produces any non-'unknown' string (e.g. a provider name or a stale value) would still pass the assertion. _(lenses: red-team)_

