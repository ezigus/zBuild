## spec-correspondence — partial

- judged 21 SPEC(s): 17 correspond, 4 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-11 partial: The negative check (no state_file-derived paths) operates on non-comment lines, but the positive ZBUILD_ARTIFACT_DIR check runs against the whole file including comments, so a comment reference alone would satisfy it without the code actually deriving the output path from that variable.
- SPEC-12 partial: The negative check correctly excludes comment lines, but the positive ZBUILD_STAGE_INPUTS check greps the full file including comments, so a comment-only reference satisfies the assertion without establishing that the code resolves inputs through that variable.
- SPEC-15 partial: The assertion tests only that manifest_router_knob returns empty for those two keys, but does not verify the absence of a config.router block — a manifest with a config.router block that lacks those specific keys would also satisfy the assertion.
- SPEC-18 partial: The assertion checks that a run: key exists and that it is the only hook, but never checks that the value is deploy_agent_run, so run: some_other_function would pass while violating the requirement.

