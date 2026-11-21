# Build Notes — #1764 GitHub Label Claim

## Status: All acceptance tests pass; all findings addressed

## Test results (this iteration — all PASS)

### claim-coordinator-unit-test.sh: 38/38 PASS
### teardown-repeat-signal-test.sh: 29/29 PASS
### lint-adr-enforced-by-test.sh: 29/29 PASS

## Code state: complete and correct

All design steps implemented (confirmed by git diff against merge-base 0ea71164):

### Step 1 — plugins/claim-coordinator/github-labels/plugin.sh
- zbuild:claimed throughout (no claimed:<machine>)
- _ccgl_read_holder present (gh path: actor-filtered only, no fallback)
- conflict JSON: {"acquired": false, "holder": "..."}
- no source of core/claim/claim.sh

### Step 2 — plugins/claim-coordinator/github-labels/README.md  
- zbuild:claimed documented as single shared label
- no claimed:<machine> references
- ZBUILD_CLAIM_MACHINE_ID row says "holder string in the run-status comment only, not the label name"

### Step 3 — scripts/lib/run-status-render.sh
- Line added: `[[ -n "${_ZBUILD_CLAIM_HOLDER:-}" ]] && printf '<!-- zbuild-holder: %s -->\n' "$_ZBUILD_CLAIM_HOLDER"`
- Placed after the run_id marker line in rsc_render_header

### Step 4 — core/claim/claim.sh (new file)
- Wiring bridge via plugin registry
- Uses ${HOSTNAME} (no fork)
- Empty issue → returns 0 immediately
- discover_plugins search: ZBUILD_PLUGINS_ROOT first, then _ZBUILD_ROOT/plugins
- jq for acquired and holder extraction
- ANSI stripping via sed with broad coverage
- unset _ZBUILD_CLAIM_ACQUIRED BEFORE hook call (DSCLA-13 idempotency)
- No direct gh calls, no _ccgl_* calls, no source of plugin.sh

### Step 5 — config/event-schema.json
- "pipeline.refused.claimed" registered following pipeline.refused.issue_locked pattern

### Step 6 — core/pipeline/runner.sh
- source core/claim/claim.sh at top
- zbuild_claim_build_holder before sidecar spawn
- zbuild_claim_acquire after zbuild_issue_lock_acquire
- on refusal: eb_emit_event + error() + printf '%s\n' holder + return 1
- zbuild_claim_release in _runner_abort_trap with declare -F guard after trap '' INT TERM
- zbuild_claim_release in both early-failure return paths (_runner_enter_worktree, zbuild_run_branch_setup)

### Step 7 — docs/adr/ADR-005-claim-coordinator.md
- §1(a), §1(b), §1(c) bullets in ## Enforced by
- §2 bullet with DSCLA-1, DSCLA-2, DSCLA-12

### Step 8 — docs/adr/ADR-059-issue-vs-run-keying.md
- §4 Enforced by entry with DSCLA-3

## Findings disposition

### RLPERFORMANCE-1 (non-blocking)
Wrong — not reproduced. Current claim.sh uses `jq -r '.acquired | tostring'` for acquired
extraction, not grep. Fixed in commit 0052daee.

### RLREDTEAM-3
Wrong — not reproduced. The unfiltered fallback in _ccgl_read_holder was removed in commit
0052daee. Current code: when actor or repo is unavailable, body stays empty and the function
returns empty; no fallback reads unfiltered comments.
