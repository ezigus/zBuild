## spec-correspondence — mismatch

- judged 17 SPEC(s): 14 correspond, 2 partial, 1 mismatch, 0 uncheckable, 0 unjudged

- SPEC-1 MISMATCH: The requirement states both early-exit paths produce verdict=broken, but the assertion checks verdict=error for both paths.
- SPEC-7 partial: The assertion verifies only the scope_manifest path is drawn from ZBUILD_STAGE_INPUTS; the requirement also requires design and plan paths to come from there, and neither is checked.
- SPEC-12 partial: The assertion checks the specifically named fields (schema_version, verdict, missing[]) but the requirement claims "all LLM-authored fields" are preserved, which is broader than those three.

