## spec-correspondence — partial

- judged 26 SPEC(s): 16 correspond, 10 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion checks result_contract:2 and role:merge_executor but never inspects the manifest for events:[plugin.result], which the requirement also declares.
- SPEC-6 partial: Each assertion checks only that `rc != 2` (via the ternary), which establishes "no path returns rc=2" but not the full `rc ∈ {0,1}` property — a plugin returning rc=3 or rc=127 would pass every assertion while violating the requirement.
- SPEC-7 partial: The assertion checks that merge-result.json is written with verdict=pass and mode≠pr_fallback under both a ZBUILD_STAGE_INPUTS scenario and an artifacts_dir scenario, which establishes that both resolution paths produce the expected outcome, but never verifies that no hardcoded declared-input path is used — a coincidentally matching hardcode would pass both checks.
- SPEC-8 partial: The assertion verifies result_contract:2 and that no role key is present, but never inspects the manifest for the existing events entries, which the requirement explicitly requires to be retained.
- SPEC-15 partial: The assertion checks both result_contract:2 and role:deploy_release_executor, but the requirement also requires that the existing events are retained, and no assertion inspects the events entries in the provides section.
- SPEC-17 partial: The state_file-absent path is fully established (rc=1 asserted directly), but for every other exit path the assertion only checks rc ≠ 2, not rc ∈ {0,1} — a return code of 3 or 127 would pass those assertions while violating the requirement.
- SPEC-19 partial: The assertion verifies `verdict=pass` and `data.mode=pr_fallback` for both fallback paths but never reads or asserts `result_contract:2` from `merge-result.json`.
- SPEC-26 partial: The assertion verifies only the absence of a `role:` key; it never inspects the provides block for the two named events entries (`plugin.pr_open.branch_fallback_used`, `plugin.pr_open.preflight_remote_has_work`), leaving the "retains events" half of the requirement unestablished.
- SPEC-27 partial: The assertion confirms only that `provides.role` is `deploy_release_executor`; it never inspects the manifest for the four named events entries, so the events half of the requirement is not established.
- SPEC-28 partial: The assertion confirms `cleanup:` is absent from all three manifests but does not verify that the hooks section contains *only* `run:` — other hook keys besides `cleanup:` could be present and would go undetected.

