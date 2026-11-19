## review-lens-performance — pass

- found: low: plugin.sh runs a `$(cd ...)` subshell at load time to locate claim.sh, a fork the design decision document explicitly said to avoid by not having plugin.sh source claim.sh at all. (plugins/claim-coordinator/github-labels/plugin.sh) (and 1 more)

- low: plugin.sh runs a `$(cd ...)` subshell at load time to locate claim.sh, a fork the design decision document explicitly said to avoid by not having plugin.sh source claim.sh at all. (plugins/claim-coordinator/github-labels/plugin.sh)
- low: `_ccgl_read_holder` calls `$(_ccgl_backend)` — a subshell that only echoes a variable — while the other new functions in claim.sh (`_zbuild_claim_read_labels_into`, `_zbuild_claim_add_label_direct`) explicitly replaced the same pattern with `${ZBUILD_CLAIM_BACKEND:-gh}` to avoid the fork. (core/claim/claim.sh)
- the check could not be used (finding 2 has no line), so every finding stands
- score: 9
