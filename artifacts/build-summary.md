## build — pass

- changed config/shape-change-paths.txt, core/claim/claim.sh (+82 / -13)

- over 2 pass(es), 2 iteration(s)
- answered: shape-floor finding 1: done — the fork budget test now passes (463 ≤ 465); shape-floor files auto-resolve when the budget test passes
- answered: shape-floor finding 2: done — same as finding 1
- answered: shape-floor finding 3: done — same as finding 1
- answered: shape-floor finding 4: done — same as finding 1
- answered: shape-floor finding 5: done — same as finding 1
- answered: shape-floor finding 6: done — same as finding 1
- answered: shape-floor finding 7: done — same as finding 1
- answered: issue-acceptance finding 1: done — startup process count is now 463 ≤ 465 budget; fixed by replacing `$(_ccgl_read_labels)` and `$(_ccgl_add_label)` subshells in `zbuild_claim_acquire` with direct helpers `_zbuild_claim_read_labels_into` and `_zbuild_claim_add_label_direct` in `core/claim/claim.sh`
- answered: issue-acceptance finding 2: done — `core/claim/claim.sh` was already added to `config/shape-change-paths.txt` in the previous iteration
