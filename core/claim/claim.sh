#!/usr/bin/env bash
# core/claim/claim.sh — the engine's side of the cross-machine claim (ADR-005).
# The engine asks the claim coordinator plugin to claim the run's issue before
# the first stage and to release it on exit, through the plugin registry. What
# a claim is (a label, a lease) is the coordinator's business, not this file's.
# Sourced by runner.sh; uses the registry and the event bus it has loaded.
# Sourced library: inherits the caller's shell options.

[[ -n "${_ZBUILD_CLAIM_SH_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_SH_LOADED=1

_ZBUILD_CLAIM_ACQUIRED=""        # the issue this run holds the claim on
_ZBUILD_COORDINATOR_DIR=""       # the coordinator that gave it
_ZBUILD_CLAIM_THEIR_HOLDER=""    # who holds the claim that refused this run

# The coordinator: the first claim-coordinator plugin under the plugins root,
# found as every other plugin is.
_zbuild_claim_coordinator_v() {
    local -n _zcc_out="$1"
    _zcc_out=""
    local -a _zcc_dirs=()
    local _zcc_d _zcc_kind
    discover_plugins_into _zcc_dirs "${ZBUILD_PLUGINS_ROOT:-$_ZBUILD_ROOT/plugins}" 2>/dev/null || return 0
    for _zcc_d in ${_zcc_dirs[@]+"${_zcc_dirs[@]}"}; do
        yaml_get_v _zcc_kind "$_zcc_d/manifest.yaml" kind 2>/dev/null || continue
        [[ "$_zcc_kind" == "claim-coordinator" ]] && { _zcc_out="$_zcc_d"; return 0; }
    done
    return 0
}

# Who this run is, as it names itself to a run that finds its claim: the CI
# run's URL, or the run id and the machine (ZBUILD_CLAIM_MACHINE_ID overrides).
_zbuild_claim_holder_v() {
    local -n _zch_out="$1"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        _zch_out="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
    else
        _zch_out="run_id=${ZBUILD_RUN_ID:-} machine=${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME:-unknown}}"
    fi
}

# A claim the engine could not make: the run goes on (ADR-005 §3), visibly.
_zbuild_claim_skipped() {
    eb_emit_event "pipeline.claim.skipped" "issue=$1" "reason=$2" 2>/dev/null || true
    printf 'zbuild: no cross-machine claim on issue #%s (%s) — the run goes on unclaimed\n' "$1" "$2" >&2 || true
}

# zbuild_claim_acquire <issue> <state_dir> — rc 0: claimed, or no claim made
# (no issue, no coordinator, the coordinator failed or skipped); rc 1: refused —
# another run holds it (its holder in _ZBUILD_CLAIM_THEIR_HOLDER), or the
# coordinator's answer cannot be read, which may hide a claim that is there.
zbuild_claim_acquire() {
    local issue="$1" state_dir="$2"
    _ZBUILD_CLAIM_THEIR_HOLDER=""
    [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 0

    _zbuild_claim_coordinator_v _ZBUILD_COORDINATOR_DIR
    if [[ -z "$_ZBUILD_COORDINATOR_DIR" ]]; then
        _zbuild_claim_skipped "$issue" "no claim-coordinator plugin installed"
        return 0
    fi

    # The reply goes through a file: a $( ) would copy the whole engine shell.
    local reply_file="$state_dir/runtime/claim-reply.json" reply="" rc=0
    [[ -d "${reply_file%/*}" ]] || mkdir -p "${reply_file%/*}" 2>/dev/null || true
    plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" claim "$issue" > "$reply_file" || rc=$?
    IFS= read -r -d '' reply < "$reply_file" || true
    # A JSON string cannot hold an unescaped quote, so a holder's text never
    # matches these. A reply that says acquired is believed whatever the hook's
    # status (#2586): an interrupt can cut the wait short after the label went
    # on, and a claim this run made must be released by it.
    if [[ "$rc" -ne 0 && ! "$reply" =~ \"acquired\"[[:space:]]*:[[:space:]]*true ]]; then
        _zbuild_claim_skipped "$issue" "the claim coordinator failed (rc=$rc)"
        return 0
    fi
    if [[ "$reply" =~ \"acquired\"[[:space:]]*:[[:space:]]*true ]]; then
        _ZBUILD_CLAIM_ACQUIRED="$issue"
        local holder; _zbuild_claim_holder_v holder
        eb_emit_event "pipeline.claim.acquired" "issue=$issue" "holder=$holder" 2>/dev/null || true
        return 0
    fi
    if [[ "$reply" =~ \"skipped\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then
        _zbuild_claim_skipped "$issue" "${BASH_REMATCH[1]//[[:cntrl:]]/}"
        return 0
    elif [[ "$reply" =~ \"skipped\"[[:space:]]*: ]]; then
        _zbuild_claim_skipped "$issue" "the claim coordinator made no claim"
        return 0
    fi
    if [[ "$reply" =~ \"acquired\"[[:space:]]*:[[:space:]]*false ]]; then
        _ZBUILD_CLAIM_THEIR_HOLDER="$(jq -r '.holder // empty' <<< "$reply" 2>/dev/null || true)"
        _ZBUILD_CLAIM_THEIR_HOLDER="${_ZBUILD_CLAIM_THEIR_HOLDER//[[:cntrl:]]/}"
    fi
    return 1
}

# zbuild_claim_release — release the claim this run holds; a no-op otherwise,
# and on a second call. Never fails the caller: a failure is an event.
zbuild_claim_release() {
    local issue="${_ZBUILD_CLAIM_ACQUIRED:-}"
    [[ -n "$issue" ]] || return 0
    _ZBUILD_CLAIM_ACQUIRED=""
    local rc=0
    plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" release "$issue" >/dev/null || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        eb_emit_event "pipeline.claim.release_failed" "issue=$issue" "rc=$rc" 2>/dev/null || true
    fi
    return 0
}
