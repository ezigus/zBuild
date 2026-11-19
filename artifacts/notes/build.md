# Build Notes — #1764 GitHub Label Claim (iteration 9)

## Status: COMPLETE

## Iteration 9 changes (addressing review_lenses findings)

### core/claim/claim.sh
- _ccgl_read_holder: replaced `$(_ccgl_backend)` with `${ZBUILD_CLAIM_BACKEND:-gh}` to eliminate
  subshell (perf-change finding 2 / sre-change finding 4).
- zbuild_claim_acquire: added stderr warning via printf when _zbuild_claim_read_labels_into
  fails (sre-change finding 2); added stderr warning via printf when _zbuild_claim_add_label_direct
  fails (sre-change finding 2); sanitized raw holder via `printf '%s'` before storing in
  _ZBUILD_CLAIM_HOLDER (red-team-change finding 2).
- zbuild_claim_release: added `unset _ZBUILD_CLAIM_ACQUIRED` BEFORE `_ccgl_remove_label`
  to make second call a no-op (correctness-change finding 1 / sre-change finding 4); added
  stderr warning via printf when _ccgl_remove_label fails (sre-change finding 3).

### plugins/claim-coordinator/github-labels/plugin.sh
- Removed `$(cd ...)` subshell when sourcing claim.sh. Now uses `$_ZBUILD_ROOT` if set
  (runner.sh path), or `${BASH_SOURCE[0]%/*}` directly when BASH_SOURCE[0] has a directory
  component (unit-test path). No fork on load (perf-change finding 1 / sre-change finding 1).

### core/pipeline/runner.sh
- Changed refused-claim output: replaced `error "... ${_ZBUILD_CLAIM_HOLDER:-unknown}"` with
  `error "... is already claimed"` + `printf '%s\n' "${_ZBUILD_CLAIM_HOLDER:-unknown}" >&2`
  to prevent echo -e backslash interpretation (security-change finding 1 / DSCLA-15).
- Added zbuild_claim_release || true + zbuild_issue_lock_release || true to both early-failure
  return paths (_runner_enter_worktree failure and zbuild_run_branch_setup failure)
  (red-team-change finding 1 / DSCLA-16).

### config/shape-change-paths.txt
- Added core/claim/claim.sh (scope-change finding 1).

## Test results
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 27/27 ✓
- tests/integration/teardown-repeat-signal-test.sh: 26/26 ✓
- tests/unit/lint-adr-enforced-by-test.sh: 29/29 ✓

## Circular source dependency (plugin.sh ↔ claim.sh)
- plugin.sh still sources claim.sh at the bottom (required because unit tests source plugin.sh
  directly and then call zbuild_claim_acquire).
- The circular dependency is managed by guards:
  - claim.sh: _ZBUILD_CLAIM_SH_LOADED prevents re-entry
  - plugin.sh: _ZBUILD_CLAIM_GH_LABELS_LOADED prevents re-entry
- The $(cd ...) subshell was eliminated; now uses $_ZBUILD_ROOT or BASH_SOURCE[0]%/* directly.

## sre-code finding 1 (not mine)
- The DSCLA-9 fixture uses rsc_render_header to generate the run-status comment
  (the test file was updated by the test-author stage in a prior iteration to call
  rsc_render_header). Cannot verify by reading the test; the test-author stage updated it.
  File is read-only for this stage.
