# Build Checkpoint — Issue 1730

## Files read and what they told me

- `tests/integration/router-loop-emits-model-events-test.sh`: Already written. Tests emit 1 model.route + 1 model.outcome for 1-iter loop (TC-1), exactly 3 of each for 3-iter loop (TC-2). Expects `_ROUTE_CALL_COST` from `_route_record_call` and token fields from json_file.
- `core/router/route.sh`: route_to_model (sync path) calls `_route_emit_model_route` at line 203 and `_route_emit_outcome` at line 244. In the loop path:
  - `eb_emit_event "loop.iteration"` is at lines 1827-1829
  - `_route_record_call` / `_route_update_ledger` are at lines 2343-2344
  - `secs` is defined at line 1703, in scope throughout the loop
  - `in_tok` and `out_tok` are extracted at lines 2338-2339
- `tests/golden/parity/event-sequence.golden`: Already has `model.route` and `model.outcome` in the loop block (lines 35, 37).

## Conclusions

Two insertions needed in `core/router/route.sh`:
1. After line 1829 (`eb_emit_event "loop.iteration"`): add `_route_emit_model_route "$tier" "$secs"`
2. After line 2344 (`_route_update_ledger`): add token assignment + cache token parsing + `_route_emit_outcome "$tier" "$secs"`

The golden file already has the new events included — no update needed there.

## Next step if stopped

Make the two edits to core/router/route.sh, then run the new test.
