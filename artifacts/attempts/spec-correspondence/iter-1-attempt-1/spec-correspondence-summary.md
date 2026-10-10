## spec-correspondence — partial

- judged 5 SPEC(s): 2 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion checks the correct output properties (no `%3N` literal, ISO 8601 format with milliseconds) but does not verify that the test ran under the required preconditions — ZBUILD_PLATFORM=linux and OSTYPE=darwin* — so it could pass on a Linux host where the mac-specific timestamp branch was never exercised.
- SPEC-2 partial: The assertion negatively checks that the old per-arg pattern is absent and spot-checks four named payload fields, but "byte-for-byte identical to the current output" requires full event JSON comparison, which four field extractions do not establish.
- SPEC-3 partial: The assertion tests the correct behavioral consequence (no spurious PATCH after an event is injected during flush) but does not verify the specific mechanism named in the requirement (cursor `last_size` is reset to the current byte count), so an alternative implementation that suppresses the second render by a different means would also pass.

