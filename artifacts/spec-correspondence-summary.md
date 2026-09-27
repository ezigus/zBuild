## spec-correspondence — partial

- judged 11 SPEC(s): 6 correspond, 5 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-16 partial: The assertion confirms the hardcoded path is absent and that `ZBUILD_STAGE_INPUTS` is referenced, but does not verify that the resolution uses `jq .inputs.deploy_result` specifically — the requirement names that extraction expression as the required mechanism, and a file could reference `ZBUILD_STAGE_INPUTS` for an unrelated purpose while still not resolving the input through `.inputs.deploy_result`.
- SPEC-18 partial: The assertion checks three specific exit paths (missing deploy-result, clamped rc=5 probe failure, missing hc-plugin) return rc=1, but the requirement is universal — it covers *all* non-zero exit paths from plugin.sh, so other error branches could still return rc≥2 without these three cases catching it.
- SPEC-23 partial: The grep confirms `role: validate_agent` exists somewhere in the manifest file, but does not verify the value is structurally placed under the `provides:` block — it would pass even if the key appeared under a different YAML parent, so `provides.role` placement is not established.
- SPEC-24 partial: The assertion confirms both required events are present and that exactly 2 `validate.`-prefixed events exist, but does not verify the total event count — a non-`validate.` event in the list would pass both checks while violating the "exactly" clause of the requirement.
- SPEC-25 partial: The assertion verifies that `run:` is present and `cleanup:` is absent, but does not check that no hooks other than `run` exist — so the "declares only run" part of the requirement (an exclusive claim) is not fully established.

