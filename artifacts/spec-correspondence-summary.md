## spec-correspondence — unjudged

- judged 14 SPEC(s): 7 correspond, 6 partial, 0 mismatch, 0 uncheckable, 1 unjudged

- SPEC-5 partial: The function-returns-0 half is established by the exit-code check, but the manifest half greps only for the bare string `security_lens_cleanup` anywhere in the file — a comment or unrelated section would satisfy it, so "declared in the manifest" (as a hook entry) is not fully established.
- SPEC-6 UNJUDGED (no parseable verdict in the reply)
- SPEC-7 partial: The assertion confirms both `- pass` and `- error` appear as list items in the manifest file, but does not anchor them to the `valid_verdicts` key, so a match anywhere in the file (another field, a comment) satisfies the assertion; it also does not verify the list contains exactly those two values, so an additional verdict would still pass.
- SPEC-10 partial: The first clause (missing manifest → rc=1) is fully established by the first block, but the second block tests only that a normal run produces rc=0 and one finding — it does not supply a response whose JSON is followed by a brace-bearing postamble, so the assertion does not establish that `_security_lens_envelope_schema_ok` specifically recovers from that structure.
- SPEC-11 partial: The assertion confirms `timeout_s:` and `max_turns:` appear somewhere in the manifest file, but does not verify they are nested under `config.router`, so the structural placement required by the requirement is not established.
- SPEC-12 partial: The assertion confirms the env var value reaches `route_to_model` when set, but the manifest used in the test has no `config.router.max_turns` set to a conflicting value, so the "takes precedence over" half of the requirement — that the env var wins when both are present — is never established.
- SPEC-13 partial: The assertion confirms that `primary: true` appears somewhere in the manifest file, but does not establish that it is declared specifically on the findings output — the requirement's structural constraint — so a match in any other section or entry would still pass.

