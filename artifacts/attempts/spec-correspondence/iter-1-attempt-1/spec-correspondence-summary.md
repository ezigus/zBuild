## spec-correspondence — partial

- judged 12 SPEC(s): 8 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-7 partial: The assertion exercises only SIGTERM, but the requirement covers both SIGTERM and SIGINT, so the SIGINT case is unestablished.
- SPEC-8 partial: The assertion tests only the empty-lenses scenario; "always returns 0" across error paths (e.g., interrupted inner run) is not established by a single case.
- SPEC-9 partial: The assertion proves byte-for-byte equality for one specific input; "equivalence preserved" as a general property across all inputs cannot be established by a single example.
- SPEC-10 partial: The assertion checks only that `$OUT_JSON` contains 3 lenses without self-establishing that group env vars were set when that output was produced, so the conditional "when group env vars are set" is not verified by the assertion itself.

