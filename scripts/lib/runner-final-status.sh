#!/usr/bin/env bash
# scripts/lib/runner-final-status.sh — pipeline final status helper (#796).
#
# Implements ADR-021 v3 R1: when a cycle exhausts max_iterations with
# on_max=continue, the pipeline final status MUST NOT be terminal failure.
# Downstream stages decide. Only on_max=abort propagates to terminal failure.

if [[ "${_ZBUILD_RUNNER_FINAL_STATUS_LOADED:-}" == "1" ]]; then
    return 0
fi
_ZBUILD_RUNNER_FINAL_STATUS_LOADED=1

_runner_compute_final_status() {
    local unconverged="${1:-0}"
    local on_max="${2:-}"
    local downstream_success="${3:-0}"
    local out_var="$4"

    # Conservative default: empty on_max treated as "abort" (preserves the
    # historical behavior where unconverged → failed regardless).
    [[ -z "$on_max" ]] && on_max="abort"

    # Downstream failure ALWAYS wins.
    if [[ "$downstream_success" != "1" ]]; then
        printf -v "$out_var" '%s' "failed"
        return 0
    fi

    # Downstream succeeded. Apply on_max semantics:
    if [[ "$unconverged" == "1" && "$on_max" == "abort" ]]; then
        printf -v "$out_var" '%s' "failed"
        return 0
    fi

    # Downstream succeeded. Distinguish converged vs unconverged:
    # on_max=continue with an unconverged cycle stamps complete_unconverged (#1479).
    if [[ "$unconverged" == "1" && "$on_max" == "continue" ]]; then
        printf -v "$out_var" '%s' "complete_unconverged"
        return 0
    fi

    printf -v "$out_var" '%s' "complete"
    return 0
}

# _runner_unconverged_msg <cycle_id> <rc> <reason> <on_max> → message on stdout.
# #938: the mid-run warning when a cycle exhausts its budget and the runner
# continues to the next dispatch unit. It MUST match the status that
# _runner_compute_final_status will compute: with on_max=continue the status is
# NOT necessarily 'failed' (it depends on the downstream verdict channel), so
# the old unconditional "pipeline_status will be 'failed'" was stale and
# misleading. #1298: updated to name no stage (ADR-047 stage-agnostic invariant).
_runner_unconverged_msg() {
    local _cyc="${1:-}" _rc="${2:-}" _reason="${3:-}" _on_max="${4:-}"
    if [[ "$_on_max" == "continue" ]]; then
        printf "Cycle %s terminated rc=%s reason=%s — continuing to next dispatch unit (on_max=continue); final pipeline_status depends on the downstream verdict channel" \
            "$_cyc" "$_rc" "$_reason"
    else
        printf "Cycle %s terminated rc=%s reason=%s — continuing to next dispatch unit so the downstream fail-closed gate runs (pipeline_status will be 'failed')" \
            "$_cyc" "$_rc" "$_reason"
    fi
}
