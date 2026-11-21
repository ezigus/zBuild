#!/usr/bin/env bash
# core/claim/claim.sh — Cross-machine soft claim via zbuild:claimed GitHub label (#1764)
# Sourced by runner.sh; defines zbuild_claim_acquire and zbuild_claim_release.
# Calls the claim-coordinator plugin through the plugin registry.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CLAIM_SH_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_SH_LOADED=1

# Derive _ZBUILD_ROOT from this file's location when not already set.
# claim.sh lives at core/claim/claim.sh; two levels up is the repo root.
# Needed when loaded via plugin.sh's source chain (unit-test path) where
# _ZBUILD_ROOT may not yet be set.
if [[ -z "${_ZBUILD_ROOT:-}" && "${BASH_SOURCE[0]}" == */* ]]; then
    _ZBUILD_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd)"
fi

# Source plugin registry for discover_plugins and plugin_hook_call.
# Idempotent: registry.sh has a guard. Must be sourced here because runner.sh
# sources claim.sh (line 33) before registry.sh (line 46).
# shellcheck source=../plugin-registry/registry.sh
if [[ -n "${_ZBUILD_ROOT:-}" ]]; then
    source "${_ZBUILD_ROOT}/core/plugin-registry/registry.sh"
fi

# Globals set by zbuild_claim_acquire.
# _ZBUILD_CLAIM_ACQUIRED: set when claim was successfully acquired.
# _ZBUILD_COORDINATOR_DIR: path to the coordinator plugin directory.
_ZBUILD_CLAIM_ACQUIRED=""
_ZBUILD_COORDINATOR_DIR=""

# _zbuild_claim_find_coordinator_v <var> — find the first claim-coordinator plugin.
# Two-search strategy: try ZBUILD_PLUGINS_ROOT first (finds test stubs), then fall
# back to _ZBUILD_ROOT/plugins (finds github-labels).
# DSCLA-22: stub IS in ZBUILD_PLUGINS_ROOT → found on first search.
# DSCLA-5..16: test ZBUILD_PLUGINS_ROOT has no coordinator → fallback finds github-labels.
_zbuild_claim_find_coordinator_v() {
    local -n _zccf_res="$1"
    _zccf_res=""
    local _search_root _dir _kind
    for _search_root in "${ZBUILD_PLUGINS_ROOT:-}" "${_ZBUILD_ROOT:-}/plugins"; do
        [[ -z "$_search_root" ]] && continue
        [[ -d "$_search_root" ]] || continue
        while IFS= read -r _dir; do
            [[ -d "$_dir" ]] || continue
            [[ -f "$_dir/manifest.yaml" ]] || continue
            _kind=""
            yaml_get_v _kind "$_dir/manifest.yaml" "kind" 2>/dev/null || true
            if [[ "$_kind" == "claim-coordinator" ]]; then
                _zccf_res="$_dir"
                return 0
            fi
        done < <(discover_plugins "$_search_root" 2>/dev/null || true)
        [[ -n "$_zccf_res" ]] && return 0
    done
    return 0
}

# zbuild_claim_build_holder — set and export _ZBUILD_CLAIM_HOLDER for this run.
# Must be called before the run-status sidecar is spawned (see runner.sh) so the
# sidecar inherits the holder string via its environment and rsc_render_header can
# embed it in <!-- zbuild-holder: --> (ADR-005 §2 / #1764).
zbuild_claim_build_holder() {
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        _ZBUILD_CLAIM_HOLDER="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
    else
        local run_id="${ZBUILD_RUN_ID:-}"
        # ${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME}}: ZBUILD_CLAIM_MACHINE_ID overrides for tests;
        # ${HOSTNAME} is a bash built-in — no external hostname command, no fork (ADR-005 §2).
        _ZBUILD_CLAIM_HOLDER="run_id=${run_id} machine=${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME}}"
    fi
    export _ZBUILD_CLAIM_HOLDER
}

# zbuild_claim_acquire <issue> — acquire the cross-machine claim for <issue>.
#
# Sets _ZBUILD_COORDINATOR_DIR on success. Returns:
#   0 — claim acquired, or skipped (no issue / no coordinator / backend error)
#   1 — refused: zbuild:claimed is already on the issue
#
# Graceful degradation: backend errors return 0 (the local flock still serialises
# same-machine runs). Logs the skip to stderr but never fails the run.
zbuild_claim_acquire() {
    local issue="$1"
    _ZBUILD_CLAIM_HOLDER=""

    # Empty issue or goal-only run → no-op (DSCLA-8)
    [[ -z "$issue" || "$issue" == "0" ]] && return 0

    # Find the first claim-coordinator plugin via registry discovery (RQARC-3).
    local coordinator_dir=""
    if declare -F _zbuild_claim_find_coordinator_v >/dev/null 2>&1; then
        _zbuild_claim_find_coordinator_v coordinator_dir
    fi
    if [[ -z "$coordinator_dir" ]]; then
        printf 'zbuild_claim_acquire: no claim-coordinator plugin found — skipping cross-machine claim\n' >&2 || true
        return 0
    fi
    _ZBUILD_COORDINATOR_DIR="$coordinator_dir"

    # Call the coordinator's claim hook and capture JSON stdout.
    local json_out="" hook_rc=0
    json_out="$(plugin_hook_call "$coordinator_dir" claim "$issue")" || hook_rc=$?
    if [[ "$hook_rc" -ne 0 ]]; then
        printf 'zbuild_claim_acquire: coordinator claim hook failed for issue %s — skipping\n' \
            "$issue" >&2 || true
        return 0
    fi

    # Parse JSON: extract "acquired" field.
    local _acquired_line acquired
    _acquired_line="$(grep -o '"acquired":[[:space:]]*[a-z]*' <<< "$json_out" || true)"
    acquired="$(grep -o 'true\|false' <<< "$_acquired_line" || true)"

    if [[ "$acquired" == "false" ]]; then
        # Another run holds zbuild:claimed — extract and sanitize the holder string.
        # Use jq for correct JSON decoding (handles escaped quotes in the holder value).
        local holder_value=""
        holder_value="$(jq -r '.holder // empty' <<< "$json_out" 2>/dev/null || true)"
        # Strip all ANSI/terminal escape sequences — broad coverage matching _eb_strip_ansi:
        # CSI sequences ending in any letter or ~, then bare ESC-X pairs (ADR-005 §2).
        if [[ "$holder_value" == *$'\x1b'* ]]; then
            holder_value="$(printf '%s' "$holder_value" | \
                LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[a-zA-Z~]//g; s/\x1b.//g' || true)"
        fi
        _ZBUILD_CLAIM_HOLDER="$holder_value"
        return 1
    fi

    if [[ "$acquired" == "true" ]]; then
        zbuild_claim_build_holder
        _ZBUILD_CLAIM_ACQUIRED="1"
        return 0
    fi

    # Unexpected response — treat as graceful degradation (ADR-005 soft claim).
    printf 'zbuild_claim_acquire: unexpected response from coordinator for issue %s — skipping\n' \
        "$issue" >&2 || true
    return 0
}

# zbuild_claim_release <issue> — release the cross-machine claim (advisory).
# No-op when the claim was never acquired (guards against releasing another run's claim).
zbuild_claim_release() {
    local issue="${1:-}"

    [[ -z "$issue" || "$issue" == "0" ]] && return 0

    # Only release if this process acquired the claim (DSCLA-17)
    [[ -z "${_ZBUILD_CLAIM_ACQUIRED:-}" ]] && return 0

    # Unset BEFORE the hook call: a second call is now a no-op because the
    # guard above sees an unset variable (DSCLA-13 idempotency — SIGTERM during
    # release cannot trigger a second release).
    unset _ZBUILD_CLAIM_ACQUIRED

    # Always re-discover the coordinator: _ZBUILD_COORDINATOR_DIR may be stale
    # (e.g. DSCLA-21 sets _ZBUILD_CLAIM_ACQUIRED after a test stub left
    # _ZBUILD_COORDINATOR_DIR pointing at the stub's directory).
    local coordinator_dir=""
    if declare -F _zbuild_claim_find_coordinator_v >/dev/null 2>&1; then
        _zbuild_claim_find_coordinator_v coordinator_dir
    fi
    if [[ -z "$coordinator_dir" ]]; then
        printf 'zbuild_claim_release: no claim-coordinator found — zbuild:claimed may need manual removal\n' \
            >&2 || true
        return 0
    fi

    plugin_hook_call "$coordinator_dir" release "$issue" >/dev/null || {
        printf 'zbuild_claim_release: release hook failed for issue %s (label may need manual removal)\n' \
            "$issue" >&2 || true
    }

    return 0
}
