# spec-correspondence checkpoint

## Files read
- design.md: confirms SPEC-1/2/3 map to tests/integration/router-loop-emits-model-events-test.sh; design describes loop missing _route_emit_model_route and _route_emit_outcome calls; two insertion points planned.
- tests/golden/parity/event-sequence.golden: shows model.route and model.outcome already added inside the loop block (lines 35-37), consistent with the fix.
- tests/integration/router-loop-emits-model-events-test.sh: full test file read; TC-1 is 1-iteration, TC-2 is 3-iteration; each uses a stub `claude` binary; LEDGER2 is set as ZBUILD_COST_LEDGER for the 3-iteration driver.

## Conclusions reached
- SPEC-1: assertion checks count=1, tier=T2, model_id non-empty, provider non-empty using a stub. Count assertion fails against merge-base (0!=1). Covers all required fields. → corresponds
- SPEC-2: assertion checks count=1, input_tokens=100, output_tokens=20, cache_read=50, cache_creation=10, cost_usd non-empty/not-unknown. All five required fields covered. → corresponds
- SPEC-3: assertion checks route_count=3, outcome_count=3, and ledger_rows==outcome_count. Combined, these establish exactly 3 of each matching 3 ledger rows. → corresponds

## Nothing unresolved — all three pairs judged.
