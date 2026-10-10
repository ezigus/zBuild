# Issue-acceptance checkpoint — issue #1730

## Files read and what they told me
- requirements.json: 6 requirements R-1 through R-6 confirmed
- test-results.json: 842/842 passed (0 failed), full suite green
- core/router/route.sh:1830 — `_route_emit_model_route "$tier" "$secs"` added after loop.iteration emit
- core/router/route.sh:2346-2350 — `_ROUTE_INPUT_TOKENS`, `_ROUTE_OUTPUT_TOKENS`, `_ROUTE_CACHE_READ`, `_ROUTE_CACHE_CREATION` populated per-iteration, then `_route_emit_outcome "$tier" "$secs"` called

## Conclusions per requirement
- R-1: Met. Diff adds _route_emit_model_route to loop; new test asserts tier/model_id/provider with stubbed claude; NEGCTL PASS SPEC-1 confirms red-before-green.
- R-2: Met. Diff populates all four token vars from per-iteration jq and calls _route_emit_outcome; new test asserts input_tokens=100, output_tokens=20, cache_read=50, cache_creation=10, cost_usd present and not 'unknown'; NEGCTL PASS SPEC-2.
- R-3: Met. TC-2 in new test exercises 3-iteration loop, asserts exactly 3 model.route and 3 model.outcome events matching 3 ledger rows; NEGCTL PASS SPEC-3.
- R-4: Met. SPEC-4 "already done" — sync path code at route.sh:203 and :244 confirmed; all 842 existing tests pass.
- R-5: Met. Loop path covered by new test (turns red without the fix); sync path covered by existing passing tests. Acceptance-gate also shows REACHABILITY PASS core/router/route.sh. Together both entry points are testably covered such that a regression on either would turn a test red.
- R-6: Met. 842/842 pass, 0 failed.

## Nothing unresolved
