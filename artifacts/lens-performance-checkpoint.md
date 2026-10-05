# Performance lens checkpoint — issue #2032

## Files read
- diff.patch (full diff in the prompt)
- No additional file reads needed; the diff is self-contained for performance analysis

## Analysis

### cycle-orchestrator.sh
New `if` block: O(1) guard using pre-computed `_iter_did_not_finish`. `_cycle_emit` only fires on the error path.
No hot-path concern.

### review-report/plugin.sh
- Loop over `_RR_LENSES[]` already spawned `cat "$artifact_dir/lens-X.rc"` per lens — pre-existing.
- New additions: one `_rr_first_failed_rc` assignment per failing lens (O(1)), then one `router_reason_disposition` subshell call — both on error path only.
No concern.

### spec-coverage/plugin.sh and spec-correspondence/plugin.sh
- `mktemp` called unconditionally on EVERY invocation (not deferred to error path).
- One temp file creation per stage run, even on the success path.
- Overhead: ~1-2ms process spawn + file write + cat + rm.
- Both stages spend seconds–minutes on LLM calls, so overhead is negligible in practice.
- For spec-correspondence: mktemp is created even when n==0 (no SPECs to check), file goes unused.
- INTRODUCED by this change.

## Conclusions
All changes are either on error paths or dominated by LLM call latency. The mktemp pattern is
the only new hot-path overhead; it is low severity.

## Next if budget ran out
Nothing left to check — analysis is complete.
