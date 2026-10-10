# Red-team lens checkpoint

## Files read
- diff.patch — confirmed exact lines changed (route.sh lines ~1830 and ~2343-2350; event-sequence.golden; new test file 221 lines)
- route.sh:880-960 — _route_emit_model_route and _route_emit_outcome helpers
- route.sh:1270-1340 — sync path outcome emission, _route_record_call
- route.sh:135-254 — route_to_model sync path (model.route at 203, outcome at 244)
- route.sh:1600-1760 — route_to_model_loop setup, $secs definition at 1703
- route.sh:1800-1875 — loop.iteration emit at 1827, new model.route at 1830
- route.sh:1940-2020 — inner retry loop starts at 1945
- route.sh:2310-2360 — success path, new token assignments + model.outcome at 2350

## Conclusions so far

1. **$secs accuracy**: Both insertion points pass `$secs` (the base timeout, resolved once at function entry, line 1703). If an inner iteration retry escalates to `_iter_local_secs`, the emitted `timeout_s` reports the BASE timeout, not the actual one used. This is low-severity (it's an observability inaccuracy, not exploitable). This was pre-existing on sync path too.

2. **model.route emitted before call, model.outcome only on success**: Asymmetric pairing in error cases (model.route with no model.outcome). Same behavior as sync path. Not introduced.

3. **Inner retry loop boundary**: Need to verify whether _route_emit_outcome (success path) is OUTSIDE the inner retry while-loop. If it's inside, it would emit once per successful try (which could be after retries), which is correct. If the retry loop can emit multiple model.route events per outer iteration — need to check.

## Still unresolved
- Where exactly the inner retry while-loop ends, to confirm _route_emit_outcome is placed correctly relative to it
- Whether test assertions can pass vacuously (false negatives)

## What to do next if stopping now
Check route.sh around lines 2080-2200 to find the end of the inner retry while-loop and confirm that model.route is 1-per-outer-iteration and model.outcome is 1-per-success-per-outer-iteration.
