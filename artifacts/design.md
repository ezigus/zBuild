# Design: route_to_model_loop emits model.route and model.outcome per iteration

## Architectural decision summary

**Goal:** Close the observability gap between the single-shot path (`route_to_model`) and
the agentic-loop path (`route_to_model_loop`). Both paths share `_route_emit_model_route`
and `_route_emit_outcome` as helpers; the sync path already calls them; the loop does not,
so no per-iteration `model.route` or `model.outcome` event ever reaches the event bus.

**Context:** `core/router/route.sh` defines two shared emitters: `_route_emit_model_route`
(line 927) and `_route_emit_outcome` (line 1338). `route_to_model` calls them at lines
203 and 244. `route_to_model_loop` omits both calls entirely. The loop already calls
`_route_record_call` (line 2343, which sets `_ROUTE_CALL_COST` and `_ROUTE_MODEL_USED`)
and `_route_update_ledger` (line 2344), so cost recording is correct — only event
emission is missing. Cache tokens (`_ROUTE_CACHE_READ`, `_ROUTE_CACHE_CREATION`) are
not extracted in the loop's per-iteration success path either (lines 2336–2341 only
extract `in_tok`/`out_tok`), so `model.outcome` cannot carry them until that extraction
is added alongside the emitter call.

**Decision:** Add two insertion points to `route_to_model_loop` in `core/router/route.sh`:

1. After `eb_emit_event "loop.iteration"` (line 1827): call
   `_route_emit_model_route "$tier" "$secs"` — tier and timeout (`secs`) are already in
   scope at that point, and `_ROUTE_MODEL_ID`/`_ROUTE_PROVIDER` etc. are set during
   loop initialisation. This mirrors the sync path.

2. In the success path, after `_route_record_call "$(<"$json_file")"` and
   `_route_update_ledger` (lines 2343–2344): assign `_ROUTE_INPUT_TOKENS=$in_tok`,
   `_ROUTE_OUTPUT_TOKENS=$out_tok`, and parse `_ROUTE_CACHE_READ`/`_ROUTE_CACHE_CREATION`
   from `$json_file` (same jq path used by `_route_call_claude` at lines 1306–1307),
   then call `_route_emit_outcome "$tier" "$secs"`. Placement after `_route_record_call`
   ensures `_ROUTE_CALL_COST` and `_ROUTE_MODEL_USED` are populated when the emitter runs.

No new emitter functions are introduced. No event-schema changes are needed
(`model.route` and `model.outcome` are already registered in `config/event-schema.json`).
The resulting per-iteration event sequence in the parity run becomes:

```
loop.iteration
model.route        ← NEW
router.max_turns.flag_omitted
[claude call]
model.outcome      ← NEW
loop.complete
```

`tests/golden/parity/event-sequence.golden` does not currently contain these two lines
inside the build-stage loop block and must be updated in the same PR. The parity e2e test
(`parity-local-vs-ci-test.sh`) does an exact golden comparison, so it will fail until the
golden is regenerated.

```scope
core/router/route.sh
tests/integration/router-loop-emits-model-events-test.sh
tests/unit/router-provider-modules-test.sh
tests/golden/parity/event-sequence.golden
tests/golden/parity/run-fixture.sh
tests/e2e/parity-local-vs-ci-test.sh
config/event-schema.json
tests/golden/engine-event-model-route.golden
tests/golden/engine-event-model-outcome.golden
tests/golden/golden-contracts-test.sh
tests/golden/router-success-event-sequence.golden
tests/unit/engine-event-shape-test.sh
tests/integration/router-cache-metrics-test.sh
tests/integration/router-precondition-test.sh
tests/integration/core-router-route-test.sh
tests/integration/router-loop-preserves-error-artifacts-test.sh
tests/integration/router-loop-rc124-honors-sentinel-test.sh
docs/adr/ADR-003-models-as-data.md
docs/adr/ADR-018-stage-invocation-modes.md
```

```acceptance
SPEC-1[code]: route_to_model_loop emits one model.route event (containing tier, model_id, provider) per iteration, verified with a stubbed claude; the assertion fails against the unmodified merge-base covers: R-1 R-5
SPEC-2[code]: route_to_model_loop emits one model.outcome event (containing input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cost_usd) per iteration covers: R-2
SPEC-3[code]: a 3-iteration route_to_model_loop call produces exactly 3 model.route events and exactly 3 model.outcome events, matching its 3 cost-ledger rows covers: R-3
SPEC-4[done]: route_to_model already calls _route_emit_model_route and _route_emit_outcome on its success path covers: R-4 evidence: core/router/route.sh:203 core/router/route.sh:244 tests/integration/router-cache-metrics-test.sh
SPEC-5[no-code]: parity/event-sequence.golden is updated to include model.route and model.outcome in the build-stage loop block; parity-local-vs-ci-test.sh remains green covers: R-6
WIRING: core/router/route.sh
TESTFILES:
SPEC-1: tests/integration/router-loop-emits-model-events-test.sh
SPEC-2: tests/integration/router-loop-emits-model-events-test.sh
SPEC-3: tests/integration/router-loop-emits-model-events-test.sh
```

```supersedes
tests/e2e/parity-local-vs-ci-test.sh [parity event-sequence golden check]: parity/event-sequence.golden omits model.route and model.outcome inside the build-stage loop block; after the fix the loop emits them, so the exact-match comparison fails until the golden is updated to include the two new lines
```

LOOP_COMPLETE
