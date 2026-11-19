# Build Notes — #1764 GitHub Label Claim (iteration 12)

## Status: COMPLETE — build finding 1 fixed

## Change made this iteration
- `core/claim/claim.sh`: Changed `zbuild_claim_acquire` to call `_ccgl_read_labels` and
  `_ccgl_add_label` (the design-mandated names from plugin.sh) instead of the wrapper
  helpers `_zbuild_claim_read_labels_into` and `_zbuild_claim_add_label_direct`. Removed
  both wrapper helpers (were only used internally by acquire).
- This satisfies design step 4: "zbuild_claim_acquire calls _ccgl_read_labels/_ccgl_add_label/_ccgl_read_holder"

## Current test results (iteration 12)
- plugins/claim-coordinator/github-labels/tests/claim-coordinator-unit-test.sh: 28/28 ✓
- lint-grep-c: OK (no violations)

## State of key files (all correct)

### core/claim/claim.sh
- Sources plugin.sh using `$_ZBUILD_ROOT` (no cd subshell)
- `zbuild_claim_build_holder`: uses `${HOSTNAME}` bash built-in (no fork)
- `zbuild_claim_acquire`: calls `_ccgl_read_labels`, `_ccgl_add_label`, `_ccgl_read_holder`
  (design-mandated names from plugin.sh); printf warnings on backend errors; printf '%s' sanitization
- `zbuild_claim_release`: `unset _ZBUILD_CLAIM_ACQUIRED` BEFORE `_ccgl_remove_label`; warns on failure

### plugins/claim-coordinator/github-labels/plugin.sh
- Sources claim.sh using `$_ZBUILD_ROOT` if set, else `${BASH_SOURCE[0]%/*}/../../../core/claim/claim.sh`
- No `$(cd ...)` subshell at load time
- `claim_coordinator_claim` / `claim_coordinator_release` use `zbuild:claimed` (no hostname)
- Guard: _ZBUILD_CLAIM_GH_LABELS_LOADED prevent circular load

### core/pipeline/runner.sh
- Holder refusal: `error "issue ... is already claimed"` + `printf '%s\n' "${_ZBUILD_CLAIM_HOLDER:-unknown}" >&2`
  (holder NOT passed through error/echo -e)
- Both early-failure paths call `zbuild_claim_release || true` with declare -F guards
- `_runner_abort_trap` calls `zbuild_claim_release` with declare -F guard

### config/shape-change-paths.txt
- core/claim/claim.sh present (design Step 6)
