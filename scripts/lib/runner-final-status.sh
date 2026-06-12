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

    printf -v "$out_var" '%s' "complete"
    return 0
}
