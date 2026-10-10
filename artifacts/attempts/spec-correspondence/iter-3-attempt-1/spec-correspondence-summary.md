## spec-correspondence — partial

- judged 6 SPEC(s): 1 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion verifies the env vars are set and the timestamp regex passes, but the eb_emit_event call that wrote events.jsonl is not shown in the fragment, so it is not established that the emission occurred with ZBUILD_PLATFORM=linux and OSTYPE=darwin* in effect.
- SPEC-2 partial: The jq-call-count check establishes single-invocation accumulation, but "byte-for-byte identical to the current output" requires a full output comparison; spot-checking five named fields does not establish that no other byte differs.
- SPEC-3 partial: The assertion tests the behavioral consequence (no spurious PATCH after an event injected during flush), but does not verify that the last_size cursor was specifically updated; a different suppression mechanism would also satisfy the assertion without meeting the stated requirement.
- SPEC-4 partial: Sidecar-still-alive confirms the loop polled again but does not confirm an identical-body second flush was actually attempted; if dirty was never set for the second cycle, the absence of a PATCH is vacuously true and the suppression logic is never exercised.
- SPEC-6 partial: The assertion establishes that FORK_BUDGET < 5480 and the patched total is within budget, but does not establish that the test fails on unpatched code — the negative-control condition is not exercisable at HEAD and is absent from the assertion.

