# Design Checkpoint — Issue #1730

## Files read so far
- plan.json: 4-step TDD plan. Add _route_emit_model_route + _route_emit_outcome calls in route_to_model_loop's per-iteration success path. New test file: tests/integration/router-loop-emits-model-events-test.sh
- requirements.json: R-1 through R-6 as expected
- core/router/route.sh (2572 lines): 
  - route_to_model (line 165): calls _route_emit_model_route at line 203, then _route_call_claude, then _route_emit_outcome at line 244, then _route_update_ledger
  - _route_emit_model_route (line 927): emits model.route with tier, model_id, provider, etc.
  - _route_emit_outcome (line 1338): emits model.outcome with token counts from _ROUTE_INPUT_TOKENS/_ROUTE_OUTPUT_TOKENS/_ROUTE_CACHE_READ/_ROUTE_CACHE_CREATION and _ROUTE_CALL_COST
  - route_to_model_loop (line 1611): per-iteration success path: extracts in_tok/out_tok from json_file (lines 2336-2341), then calls _route_record_call/$(<"$json_file") at line 2343, _route_update_ledger at 2344. The loop emits loop.iteration at line 1827. Currently NO call to _route_emit_model_route or _route_emit_outcome in loop.
  - Loop emits loop.iteration at line 1827 (after redaction, before spawn). 
  - Token extraction in loop success path (lines 2336-2341): extracts in_tok, out_tok for _ROUTE_LOOP_INPUT_TOKENS/_ROUTE_LOOP_OUTPUT_TOKENS accumulation.
  - _route_record_call (line 1358): sets _ROUTE_CALL_COST and _ROUTE_MODEL_USED from provider.
  - Cache tokens (CACHE_READ/CACHE_CREATION) are NOT extracted in loop success path yet.

## Key conclusions
- route_to_model_loop missing _route_emit_model_route and _route_emit_outcome entirely
- The emitters themselves are shared helpers; no code change needed there
- Two insertion points needed in route.sh:
  1. After eb_emit_event "loop.iteration" (line ~1829): add _route_emit_model_route "$tier" "$secs"
  2. In success path after _route_record_call/_route_update_ledger (line ~2344): set _ROUTE_INPUT_TOKENS=$in_tok, _ROUTE_OUTPUT_TOKENS=$out_tok, parse cache tokens from json_file, then call _route_emit_outcome "$tier" "$secs"
- Test must: stub claude returning stream-json envelope with .usage; assert model.route and model.outcome per iteration; assert N loop = N events; call both route_to_model and route_to_model_loop to assert shared emitters

## Scope confirmed
- core/router/route.sh — main implementation change
- tests/integration/router-loop-emits-model-events-test.sh — new test file
- config/event-schema.json — already has model.route + model.outcome (lines 52-53), no change needed
- tests/golden/engine-event-model-route.golden — no change expected (same function)
- tests/golden/engine-event-model-outcome.golden — no change expected (same function)
- tests/golden/golden-contracts-test.sh — references the golden files above; no model.route/outcome shape change
- tests/integration/router-cache-metrics-test.sh — tests model.route/outcome on sync path; not affected
- tests/integration/router-precondition-test.sh — guard test for route_to_model; not affected by loop addition
- tests/integration/core-router-route-test.sh — tests route_to_model directly; not affected

## What's next
Write design.md now.
