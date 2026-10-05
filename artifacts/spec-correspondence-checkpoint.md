# spec-correspondence checkpoint

## Files read
- /home/runner/work/_temp/zbuild-state/artifacts/design.md — full design for #2032; confirmed all 9 SPEC texts, WIRING, and scope

## Conclusions reached

SPEC-1: corresponds — assertion checks event emitted + _CYCLE_LAST_ITERATIONS>=2 (iterates) + rc=0 (eventual convergence); covers the core claim
SPEC-2: corresponds — all-complete path, iter==1 convergence, no suppression event; directly inverts SPEC-1
SPEC-3: corresponds — rc=124 → disposition=timed_out confirmed against result file; classification not hardcode
SPEC-4: corresponds — rc=1 → disposition=unavailable; establishes classification path in place
SPEC-6: corresponds — all clauses (rc=8, reason=design_timeout_exhausted, cycle.timeout_exhausted event, suppression event, no convergence) checked
SPEC-7: partial — checks disposition:.*exhausted pattern but misses prescriptive exhausted forms not preceded by "disposition:"; vocabulary presence (timed_out/out_of_turns) is checked
SPEC-8: partial — checks absence of old phrase and presence of _*_budget_guidance pattern, but doesn't verify §1 location or that each stage is represented
SPEC-9: corresponds — checks #2187 present AND context contains amendment/vocabulary words

## Status: complete — no unresolved items
