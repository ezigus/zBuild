## spec-correspondence — partial

- judged 9 SPEC(s): 4 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-14 partial: The helper correctly validates all four mandatory v2 keys in a caller-supplied result file, but as a reusable function it covers only one file per invocation — whether it is called for every terminal exit path of `_validate_agent_run_inner` cannot be established from this assertion alone.
- SPEC-15 partial: The assertion confirms `result_contract: 2` appears somewhere in the manifest file but does not verify that it resides within the `provides` block specifically.
- SPEC-16 partial: The test confirms the plugin succeeds when deploy_result is supplied via ZBUILD_STAGE_INPUTS at a non-standard path, but it does not establish the negative half of the requirement — that no hardcoded `$artifacts_dir/deploy-result.json` path construction exists — because a plugin that resolves from ZBUILD_STAGE_INPUTS and also constructs the hardcoded path as a fallback would pass this assertion equally.
- SPEC-18 partial: The assertion verifies rc=1 for four specific failure paths (missing artifact, failed probe, missing hc-plugin, missing state_file), but the requirement covers all non-zero exits from plugin.sh, leaving any other exit paths unexamined.
- SPEC-19 partial: The assertion fully establishes that `valid_verdicts` declares exactly `[healthy, error]` (presence checks plus exact-count check), but the two `assert_pass` calls for SPEC-11 and SPEC-12 coverage are unconditional — they always pass regardless of whether those assertions exist or pass — so the second half of the requirement ("validate-test.sh covers healthy and error via passing assertions") is not actually established.

