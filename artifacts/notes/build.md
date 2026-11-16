# Build Notes — #1764 GitHub Label Claim

## What needs doing

1. Create `core/claim/claim.sh` — defines `zbuild_claim_acquire` and `zbuild_claim_release`
   using the backend primitives from `plugins/claim-coordinator/github-labels/plugin.sh`.

2. At end of `plugin.sh` — source `core/claim/claim.sh` so unit test gets functions.

3. In `runner.sh`:
   - Source `core/claim/claim.sh` after issue-lock.sh (~line 31)
   - Add `zbuild_claim_acquire` call after issue lock block (~line 2453)
   - Add `zbuild_claim_release` call in `_runner_abort_trap` after issue lock release (~line 2675)

## Key behaviors

### zbuild_claim_acquire <issue>
- Empty issue / "0" → return 0 (DSCLA-8)
- Backend error → return 0 gracefully
- "zbuild:claimed" in labels → read holder.txt → set _ZBUILD_CLAIM_HOLDER → return 1 (DSCLA-3/4)
- Not present → add "zbuild:claimed", write holder info, return 0 (DSCLA-1)
  - local-fs: writes labels.txt (zbuild:claimed), comment.txt, holder.txt
  - gh: calls `gh issue edit --add-label zbuild:claimed` + `gh issue comment --body <holder>` (DSCLA-2)
- Holder string:
  - CI (GITHUB_ACTIONS=true): "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  - Local: "run_id=<ZBUILD_RUN_ID> machine=<machine>"

### zbuild_claim_release <issue>
- Empty issue / "0" → return 0
- _ZBUILD_CLAIM_ACQUIRED not set → return 0 (don't release a claim we didn't acquire)
- Remove "zbuild:claimed" from labels (DSCLA-5/6/7)
- Write "Status: finished" to comment.txt (DSCLA-5/6/7)

## Runner.sh wiring

After issue lock block (line 2452 ends the block):
```bash
# Cross-machine claim
if declare -F zbuild_claim_acquire >/dev/null 2>&1; then
    if ! zbuild_claim_acquire "${_runner_issue:-}"; then
        eb_emit_event "pipeline.refused.claimed" ...
        error "... ${_ZBUILD_CLAIM_HOLDER:-unknown}"
        zbuild_issue_lock_release || true
        zbuild_run_cap_release || true
        return 1
    fi
fi
```

In _runner_abort_trap, after zbuild_issue_lock_release (line 2674):
```bash
if declare -F zbuild_claim_release >/dev/null 2>&1; then
    zbuild_claim_release "${_runner_issue:-}" || true
fi
```

## SIGPIPE rules
- Use `grep -q ... <<< "$var"` (here-string), never `echo | grep -q`
- No `| head` in .sh files

## Status
- IN PROGRESS: writing code
