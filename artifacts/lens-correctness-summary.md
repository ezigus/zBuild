## review-lens-correctness — fail

- found: medium: The JSON holder extraction in `zbuild_claim_acquire` uses `grep -o '"holder":[[:space:]]*"[^"]*"'`; the `[^"]*` class stops at the first `"` character, so a holder whose JSON-escaped form contains `\"` (an escaped double-quote, written by `claim_coordinator_claim`'s `sed 's/"/\\"/g'`) is silently truncated — the regex matches only the bytes before the escaped quote. (core/claim/claim.sh) (and 1 more)

- medium: The JSON holder extraction in `zbuild_claim_acquire` uses `grep -o '"holder":[[:space:]]*"[^"]*"'`; the `[^"]*` class stops at the first `"` character, so a holder whose JSON-escaped form contains `\"` (an escaped double-quote, written by `claim_coordinator_claim`'s `sed 's/"/\\"/g'`) is silently truncated — the regex matches only the bytes before the escaped quote. (core/claim/claim.sh)
- medium: The DSCLA-4 unit-test block pre-seeds the run-status comment file with a hand-written `<!-- zbuild-holder: ... -->` line instead of calling `rsc_render_header` to generate it; if `rsc_render_header` changes its holder-comment format and `_ccgl_read_holder`'s regex is not updated to match, this test still passes (the hand-written fixture still matches the stale reader) while the production round-trip is broken. (plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh)
- the check could not be used (finding 2 has no line), so every finding stands
- score: 8
