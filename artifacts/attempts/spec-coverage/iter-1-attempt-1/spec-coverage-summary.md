## spec-coverage — uncovered

- SPEC-2 sets a variable naming blockers but never demands that a message is emitted to the operator, leaving the "explicit" half of R-2 untested; and SPEC-1 claims R-5 but only tests the no-cap case, leaving the "runs below the cap are byte-identically unaffected" case without any SPEC.

- NOT COVERED: R-2: "Refusal is explicit and names the blocking run(s)" — SPEC-2 tests that `_ZBUILD_RUN_CAP_BLOCKERS` is set and return code is 1, but no SPEC demands that a refusal message is emitted to the operator (the "explicit" half)
- NOT COVERED: R-5: "runs below the cap, are byte-identically unaffected" — SPEC-1 covers only the no-cap (ZBUILD_MAX_CONCURRENT_RUNS unset) path
- NOT COVERED: no SPEC tests that when the cap is set but not yet reached the run is admitted and produces identical output
