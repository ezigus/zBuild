## spec-correspondence — partial

- judged 12 SPEC(s): 9 correspond, 3 partial, 0 mismatch, 0 uncheckable, 0 unjudged

- SPEC-17 partial: the assertion establishes that a failed probe causes non-zero return, but nothing in the assertion verifies that input resolution actually traversed the ZBUILD_STAGE_INPUTS path rather than some other mechanism.
- SPEC-20 partial: empty returns for two specific knobs do not establish that the config.router block is entirely absent — a block with other keys would still satisfy the assertion.
- SPEC-26 partial: the assertion checks result_contract=2 in the output but does not verify that ZBUILD_STAGE_INPUTS was exported before the validate call, which the requirement names as a required condition.

