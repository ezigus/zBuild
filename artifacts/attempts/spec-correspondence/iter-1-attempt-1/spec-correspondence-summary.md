## spec-correspondence — partial

- judged 13 SPEC(s): 6 correspond, 7 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion never checks the `reason` field in either early-exit path, yet the requirement explicitly names verdict, disposition, *and* reason as required fields; it also omits a verdict assertion for the missing-required-input path entirely.
- SPEC-3 partial: The rc=124 path asserts all four properties (result_contract=2, disposition from router_reason_disposition, reason from the rc classifier, no router_rc field), but the rc=137 path omits the reason assertion, leaving that router failure path without verification of the reason property the requirement names.
- SPEC-4 partial: The assertion confirms result_contract=2, disposition=complete, and reason non-empty, but checking `[[ -n "$_s4_reason" ]]` does not establish that reason is populated *from the verdict summary* — any non-empty string, including a fixed placeholder, satisfies it.
- SPEC-5 partial: The assertion confirms `result_contract: 2` exists somewhere in the manifest, but `grep -m1` with no context check does not verify the key appears under the `provides` section specifically, which is the full claim of the requirement.
- SPEC-6 partial: Both values are checked independently across the whole file, but neither check verifies that `timeout_s: 600` and `max_turns: 45` appear within the `config.router` block specifically — the two values could reside in unrelated sections and the assertion would still pass.
- SPEC-7 partial: The assertion checks that impact_run exits 0 and writes impact.json, but does not verify that the paths were sourced from ZBUILD_STAGE_INPUTS rather than constructed from state_file — a run that constructs paths from state_file and succeeds would satisfy both checks equally.
- SPEC-8 partial: The requirement prohibits all hardcoded artifact path constructions (the named patterns are examples, as signalled by "etc."), but the assertion checks only four specific literal patterns, leaving any other `<dir_var>/<filename>` construction undetected.

