## spec-correspondence — partial

- judged 6 SPEC(s): 0 correspond, 6 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion verifies the timestamp has no `%3N` and matches the ISO 8601 regex, but does not verify the required preconditions (ZBUILD_PLATFORM=linux and OSTYPE=darwin*) were in effect, so it could pass on a Linux host without ever exercising the macOS code path.
- SPEC-2 partial: The jq-call-count check establishes the accumulation mechanism, but the "byte-for-byte identical" half of the requirement demands full output equivalence; four spot-checked fields leave all other envelope fields unverified.
- SPEC-3 partial: The assertion verifies the behavioral consequence (no spurious PATCH), but the requirement specifies the mechanism (cursor reset); a different implementation that prevents the second render without updating `last_size` would also pass.
- SPEC-4 partial: The assertion confirms no PATCH after setup but does not verify that an identical-body second flush was actually attempted; if no second flush occurs the zero-PATCH count is vacuously true and the suppression logic is never exercised.
- SPEC-5 partial: The assertion checks all events present in SC5_EVENTS for the stage field but does not verify that `redaction.applied` events specifically appear in that file; if those events are absent or written elsewhere the "(including redaction.applied)" condition the requirement calls out is established only vacuously.
- SPEC-6 partial: The assertion verifies the patched code is within FORK_BUDGET, but does not establish that FORK_BUDGET was set below the merge-base measurement nor that unpatched code would fail the check — both are required parts of the requirement.

