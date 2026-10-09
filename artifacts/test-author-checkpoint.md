# Test-author checkpoint — issue #1730

## What I read and what it told me

- design.md: Adds `_route_emit_model_route` and `_route_emit_outcome` calls to `route_to_model_loop`. Currently 0 model.route/model.outcome events emitted from the loop path.
- core/router/route.sh: `_route_emit_model_route` (line 927), `_route_emit_outcome` (line 1338), `_route_record_call`+`_route_update_ledger` already at lines 2343-2344. `loop.iteration` emitted at line 1827.
- `provider_anthropic_call_cost` reads `.total_cost_usd` from JSON → sets `_ROUTE_CALL_COST` → `_route_emit_outcome` writes as `cost_usd`.
- Cost ledger already written per iteration on merge-base (lines 2343-2344).
- Driver pattern: separate bash subshell script that sources libs + calls route_to_model_loop; events go to ZBUILD_EVENTS_JSONL.
- `_route_loop_capture_diff` calls `git add -N .` so untracked files show in `git diff HEAD`.
- parity golden: build-stage block was `loop.iteration / router.max_turns.flag_omitted / loop.complete`. After fix: `loop.iteration / model.route / router.max_turns.flag_omitted / model.outcome / loop.complete`.

## Files written

1. tests/integration/router-loop-emits-model-events-test.sh — DONE
   - TC-1 (1 iteration): asserts model.route count=1, tier=T2, model_id non-empty, provider non-empty [SPEC-1]; asserts model.outcome count=1, input_tokens=100, output_tokens=20, cache_read=50, cache_creation=10, cost_usd non-"unknown" [SPEC-2]. All fail on merge-base (0 events emitted).
   - TC-2 (3 iterations): counter-file stub writes files for non-empty diffs, LOOP_COMPLETE on iter 3. Asserts model.route count=3, model.outcome count=3, outcome count matches ledger rows=3. All fail on merge-base. [SPEC-3]

2. tests/golden/parity/event-sequence.golden — DONE
   - Added `model.route` after `loop.iteration` and `model.outcome` before `loop.complete` in the build-stage loop block. [SPEC-5]

## Status

ALL SPECs done. LOOP_COMPLETE.
