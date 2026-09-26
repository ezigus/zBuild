## spec-correspondence — partial

- judged 25 SPEC(s): 18 correspond, 7 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 partial: The assertion checks result_contract:2 and role:merge_executor but never inspects the manifest for events:[plugin.result].
- SPEC-8 partial: The assertion checks result_contract:2 and that no role is present, but never verifies that the existing events entries are retained.
- SPEC-15 partial: The assertion checks only result_contract:2; it does not verify that role:deploy_release_executor, events, or valid_verdicts are retained.
- SPEC-21 partial: The assertion verifies halt before gh pr create via the GH_SENTINEL check, but has no sentinel or equivalent check to confirm halt before the push step specifically.
- SPEC-26 partial: The assertion verifies no role is present but never checks that events:[plugin.pr_open.branch_fallback_used, plugin.pr_open.preflight_remote_has_work] are retained.
- SPEC-27 partial: The assertion verifies role:deploy_release_executor is present but never checks that the four named events entries are retained.
- SPEC-28 partial: The assertion verifies no cleanup: key in any manifest, but does not check that plugin.sh files have empty cleanup function bodies or that the engine emits plugin.cleanup.absent rc=0.

