# Plan Checkpoint for Issue #1730

## Files read
- intake.md: goal is to add model.route and model.outcome events to route_to_model_loop path
- scope-manifest.md: scope is ./ (whole repo)

## Key findings so far
- Bug: route_to_model_loop never calls _route_emit_model_route or _route_emit_outcome
- Sync path (route_to_model) does call both at ~line 173 and 214
- Emitters are at ~line 883 and 1273 of route.sh
- Loop path starts ~line 1501
- Updated 2026-10-08: loop never fills _ROUTE_INPUT_TOKENS or cache-token variables per iteration (parsed only on sync path ~lines 1286-1302)
- So the loop needs token parsing too, or outcome will report zeros

## Key line numbers (confirmed)
- route_to_model: line 165
- _route_emit_model_route call (sync): line 203
- _route_emit_outcome call (sync): line 244
- _route_emit_model_route fn: line 927
- Token parsing (sync success path): lines 1304-1307 (sets _ROUTE_INPUT_TOKENS, _ROUTE_OUTPUT_TOKENS, _ROUTE_CACHE_READ, _ROUTE_CACHE_CREATION)
- _route_emit_outcome fn: line 1337
- route_to_model_loop fn: line 1611
- eb_emit_event "loop.iteration": line 1827 (good place to add emit_model_route before spawn)
- Loop success path local token vars: lines 2336-2340 (in_tok, out_tok — NOT setting global _ROUTE_INPUT_TOKENS etc.)
- _route_record_call in success path: line 2343 (sets _ROUTE_CALL_COST, _ROUTE_MODEL_USED)
- _route_update_ledger in success path: line 2344 (after this is where to add emit_outcome)

## Fix plan
1. In loop per-iteration, after `eb_emit_event "loop.iteration"`, add: `_route_emit_model_route "$tier" "$secs"`
2. In loop success path, after `_route_record_call` + `_route_update_ledger`, add:
   ```
   _ROUTE_INPUT_TOKENS="$in_tok"
   _ROUTE_OUTPUT_TOKENS="$out_tok"
   _ROUTE_CACHE_READ="$(jq -r '.usage.cache_read_input_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
   _ROUTE_CACHE_CREATION="$(jq -r '.usage.cache_creation_input_tokens // 0' "$json_file" 2>/dev/null || echo 0)"
   _route_emit_outcome "$tier" "$secs"
   ```
3. New test: tests/integration/router-loop-emits-model-events-test.sh
   - Stub claude (stream-json format, returns JSON envelope)
   - Assert S1: model.route emitted with tier/model_id/provider
   - Assert S2: model.outcome with tokens and cost_usd
   - Assert S3: N-iter loop produces N events of each type
   - Assert S5: guard that both entry points reach emitters

## ADR-003 in baseline
ADR-003 is in config/adr-enforcement-baseline.txt so no ## Enforced by section needed for this PR.

