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

# ADR-005 §3 (#2533): heartbeat and staleness thresholds.
: "${ZBUILD_CLAIM_HEARTBEAT_S:=600}"   # seconds between heartbeat flushes
: "${ZBUILD_CLAIM_STALE_S:=1800}"      # seconds before a cross-machine claim is stale

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
        # #2589: the runner's pid, so a later run on this machine can tell a
        # live holder from one that crashed (kill -0), with no slot needed.
        _zch_out="run_id=${ZBUILD_RUN_ID:-} machine=${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME:-unknown}} pid=$$"
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
    # on, and a claim this run made must be released by it. A trapped signal
    # that lands while bash waits on the hook makes `wait` return 128+signal at
    # once; on a busy runner that is often (#2591: 27 of 60 under load, Ubuntu
    # 26.04, every claim made and released).
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
        # #2589 (ADR-005): a claim this machine's own run left behind (it
        # crashed, or was killed, before releasing) is cleared, once, and the
        # claim taken again. Another machine's, or CI's, is never touched.
        local _zca_own=""; _zbuild_claim_own_v _zca_own "$_ZBUILD_CLAIM_THEIR_HOLDER"
        # A resumed run finds its own claim (same run id, this machine): it is
        # this run's again (review of #2589).
        if [[ "$_zca_own" == mine ]]; then
            _ZBUILD_CLAIM_ACQUIRED="$issue"
            eb_emit_event "pipeline.claim.acquired" "issue=$issue" "holder=$_ZBUILD_CLAIM_THEIR_HOLDER" 2>/dev/null || true
            return 0
        fi
        if [[ -z "${_ZBUILD_CLAIM_RETRIED:-}" && "$_zca_own" == stale ]]; then
            eb_emit_event "pipeline.claim.stale_cleared" "issue=$issue" "holder=$_ZBUILD_CLAIM_THEIR_HOLDER" 2>/dev/null || true
            printf 'zbuild_claim_acquire: clearing a claim this machine left (%s) on issue %s\n' "$_ZBUILD_CLAIM_THEIR_HOLDER" "$issue" >&2
            plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" release "$issue" >/dev/null 2>&1 || true
            local _zca_rc=0
            _ZBUILD_CLAIM_RETRIED=1 zbuild_claim_acquire "$issue" "$state_dir" || _zca_rc=$?
            return "$_zca_rc"
        elif [[ -z "$_zca_own" && -z "${_ZBUILD_CLAIM_RETRIED:-}" ]]; then
            # ADR-005 §3 (#2533): cross-machine stale takeover.
            # Lazily source run-status-comment.sh so its functions are available;
            # the loaded guard prevents double-sourcing.
            if [[ -z "${_ZBUILD_RUN_STATUS_COMMENT_LOADED:-}" ]]; then
                local _zca_rsc_path="${_ZBUILD_ROOT:-}/scripts/lib/run-status-comment.sh"
                if [[ ! -f "$_zca_rsc_path" ]]; then
                    printf 'zbuild_claim_acquire: run-status-comment.sh not found (%s) — refusing cross-machine takeover\n' \
                        "$_ZBUILD_CLAIM_THEIR_HOLDER" >&2
                    return 1
                fi
                # shellcheck source=../../scripts/lib/run-status-comment.sh
                source "$_zca_rsc_path" 2>/dev/null || true
                if ! declare -F rsc_takeover_note_post >/dev/null 2>&1; then
                    printf 'zbuild_claim_acquire: rsc_takeover_note_post not defined — refusing cross-machine takeover (%s)\n' \
                        "$_ZBUILD_CLAIM_THEIR_HOLDER" >&2
                    return 1
                fi
            fi
            # Determine the age of the claim from the heartbeat line, or fall back
            # to the label-added timestamp. Call via temp file so the functions run in
            # THIS shell (a $(...) subshell would prevent mock side-effects from
            # propagating back in tests, and the functions need to touch globals).
            local _zca_slug; _zca_slug="$(zbuild_repo_slug "${_ZBUILD_ROOT:-$PWD}" 2>/dev/null || true)"
            local _zca_hb_tf; _zca_hb_tf="$(mktemp "${TMPDIR:-$state_dir}/claim-hb.XXXXXX" 2>/dev/null)" || _zca_hb_tf=""
            local _zca_hb_ts=""
            rsc_heartbeat_find "$state_dir" "$_zca_slug" "$issue" > "${_zca_hb_tf:-/dev/null}" 2>/dev/null || true
            [[ -n "$_zca_hb_tf" ]] && { IFS= read -r -d '' _zca_hb_ts < "$_zca_hb_tf" || true; rm -f "$_zca_hb_tf"; }
            local _zca_ref_ts="$_zca_hb_ts"
            local _zca_used_label=0
            if [[ -z "$_zca_ref_ts" ]]; then
                local _zca_lb_tf; _zca_lb_tf="$(mktemp "${TMPDIR:-$state_dir}/claim-lb.XXXXXX" 2>/dev/null)" || _zca_lb_tf=""
                rsc_label_added_at "$state_dir" "$_zca_slug" "$issue" > "${_zca_lb_tf:-/dev/null}" 2>/dev/null || true
                [[ -n "$_zca_lb_tf" ]] && { IFS= read -r -d '' _zca_ref_ts < "$_zca_lb_tf" || true; rm -f "$_zca_lb_tf"; }
                _zca_used_label=1
            fi
            if [[ -z "$_zca_ref_ts" ]]; then
                # No timestamp available — fail closed rather than taking over blindly.
                printf 'zbuild_claim_acquire: no heartbeat or label-added timestamp for %s — refusing (fail closed)\n' \
                    "$_ZBUILD_CLAIM_THEIR_HOLDER" >&2
                return 1
            fi
            local _zca_ref_epoch=0
            _rsc_epoch_to _zca_ref_epoch "$_zca_ref_ts" 2>/dev/null || true
            local _zca_now; _zca_now="$(date +%s)"
            local _zca_age=$(( _zca_now - _zca_ref_epoch ))
            if (( _zca_ref_epoch <= 0 || _zca_age < 0 )); then
                printf 'zbuild_claim_acquire: could not parse timestamp %s — refusing (fail closed)\n' \
                    "$_zca_ref_ts" >&2
                return 1
            fi
            if (( _zca_age >= ZBUILD_CLAIM_STALE_S )); then
                # Stale: post a takeover note, release, re-acquire once.
                rsc_takeover_note_post "$state_dir" "$_zca_slug" "$issue" "$_ZBUILD_CLAIM_THEIR_HOLDER" 2>/dev/null || true
                plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" release "$issue" >/dev/null 2>&1 || true
                local _zca_rc2=0
                _ZBUILD_CLAIM_RETRIED=1 zbuild_claim_acquire "$issue" "$state_dir" || _zca_rc2=$?
                return "$_zca_rc2"
            else
                # Fresh: refuse, naming the holder.
                printf 'zbuild_claim_acquire: issue #%s is held by %s (not stale yet) — refused\n' \
                    "$issue" "$_ZBUILD_CLAIM_THEIR_HOLDER" >&2
                return 1
            fi
        fi
    fi
    # Refused — holder named in _ZBUILD_CLAIM_THEIR_HOLDER; print it for the caller.
    if [[ -n "$_ZBUILD_CLAIM_THEIR_HOLDER" ]]; then
        printf 'zbuild_claim_acquire: issue #%s is held by %s — refused\n' \
            "$issue" "$_ZBUILD_CLAIM_THEIR_HOLDER" >&2
    fi
    return 1
}

# _zbuild_claim_own_v <var> <holder> — what a local holder on this machine is to
# this run: "mine" (this run's id: a resume), "stale" (another run here whose
# pid is gone), or "" (anything else: another machine, CI, a live run, or a
# holder written before pids were — never cleared).
_zbuild_claim_own_v() {
    local -n _zco="$1"; local h="$2" me="${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME:-unknown}}"
    _zco=""
    [[ "$h" =~ ^run_id=([^[:space:]]+)[[:space:]]+machine=([^[:space:]]+)[[:space:]]+pid=([0-9]+)$ ]] || return 0
    [[ "${BASH_REMATCH[2]}" == "$me" ]] || return 0
    if [[ "${BASH_REMATCH[1]}" == "${ZBUILD_RUN_ID:-}" ]]; then _zco=mine; return 0; fi
    kill -0 "${BASH_REMATCH[3]}" 2>/dev/null || _zco=stale
    return 0
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
