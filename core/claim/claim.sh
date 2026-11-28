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
_ZBUILD_CLAIM_REFUSED_WHY=""     # why, when it is not that another run holds it

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
    _ZBUILD_CLAIM_THEIR_HOLDER=""; _ZBUILD_CLAIM_REFUSED_WHY=""
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
        # ADR-005 §5 (#2534): a concurrent claim — another run posted its note first;
        # skip the stale-takeover path entirely (DSRACE-5).
        if [[ "$reply" =~ \"race_lost\"[[:space:]]*:[[:space:]]*true ]]; then
            printf 'zbuild_claim_acquire: issue #%s: concurrent claim — %s was first\n' \
                "$issue" "${_ZBUILD_CLAIM_THEIR_HOLDER:-unknown}" >&2
            return 1
        fi
        # ADR-005 §5 (#2534 R4): whether another run claimed first cannot be
        # told. The claim is taken back, and the run does not start.
        if [[ "$reply" =~ \"cannot_tell\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)\" ]]; then
            _ZBUILD_CLAIM_REFUSED_WHY="${BASH_REMATCH[1]//[[:cntrl:]]/}"
            return 1
        fi
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
            # ADR-005 §3 (#2533, #2616): cross-machine stale takeover, the
            # coordinator's (its takeover hook).
            _zbuild_claim_takeover "$issue" "$state_dir"
            return $?
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

# _zbuild_claim_stale_s_v <var> — ZBUILD_CLAIM_STALE_S as a number; one that is
# not (e.g. "30m") is the default, 1800, not 0 (#2533 review: 0 made every
# claim stale).
# One shorter than two heartbeats would make a live run stale between two of
# them: it is raised to that.
_zbuild_claim_stale_s_v() {
    local -n _zcs="$1"; local hb="${ZBUILD_CLAIM_HEARTBEAT_S:-600}"
    _zcs="${ZBUILD_CLAIM_STALE_S:-1800}"
    [[ "$_zcs" =~ ^[0-9]+$ ]] || _zcs=1800
    [[ "$hb" =~ ^[1-9][0-9]*$ ]] || hb=600
    (( _zcs >= 2 * hb )) || _zcs=$(( 2 * hb ))
}

# _zbuild_claim_takeover <issue> <state_dir> — ADR-005 §3 (#2533, #2616):
# another machine's (or CI's) claim, refused. Whether it is stale, and taking it
# over, is the coordinator's (its takeover hook); a coordinator with none refuses.
# rc as zbuild_claim_acquire.
_zbuild_claim_takeover() {
    local issue="$1" state_dir="$2" them="$_ZBUILD_CLAIM_THEIR_HOLDER" stale me reply="" rc=0 _tk=""
    yaml_get_v _tk "$_ZBUILD_COORDINATOR_DIR/manifest.yaml" hooks.takeover 2>/dev/null || _tk=""
    if [[ -z "$_tk" ]]; then
        printf 'zbuild_claim_acquire: the claim coordinator cannot judge a stale claim (no takeover hook) — refusing to take over %s\n' "$them" >&2
        return 1
    fi
    _zbuild_claim_stale_s_v stale
    _zbuild_claim_holder_v me
    local reply_file="$state_dir/runtime/claim-takeover-reply.json"
    [[ -d "${reply_file%/*}" ]] || mkdir -p "${reply_file%/*}" 2>/dev/null || true
    plugin_hook_call "$_ZBUILD_COORDINATOR_DIR" takeover "$issue" "$them" "$me" "$stale" "$state_dir" > "$reply_file" || rc=$?
    IFS= read -r -d '' reply < "$reply_file" || true
    if [[ "$reply" =~ \"taken_over\"[[:space:]]*:[[:space:]]*true ]]; then
        local age=""; [[ "$reply" =~ \"age_s\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && age="${BASH_REMATCH[1]}"
        eb_emit_event "pipeline.claim.taken_over" "issue=$issue" "holder=$them" "age_s=$age" 2>/dev/null || true
        # The coordinator claimed it again for this run (review of #2616).
        if [[ "$reply" =~ \"claimed\"[[:space:]]*:[[:space:]]*true ]]; then
            _ZBUILD_CLAIM_ACQUIRED="$issue"
            eb_emit_event "pipeline.claim.acquired" "issue=$issue" "holder=$me" 2>/dev/null || true
            return 0
        fi
        local arc=0
        _ZBUILD_CLAIM_RETRIED=1 zbuild_claim_acquire "$issue" "$state_dir" || arc=$?
        return "$arc"
    fi
    if [[ "$reply" =~ \"failed\"[[:space:]]*:[[:space:]]*\"([a-z_]+)\" ]]; then
        eb_emit_event "pipeline.claim.takeover_failed" "issue=$issue" "holder=$them" "reason=${BASH_REMATCH[1]}" 2>/dev/null || true
    elif [[ "$rc" -ne 0 || ! "$reply" =~ \"taken_over\" ]]; then
        printf 'zbuild_claim_acquire: the claim coordinator'"'"'s takeover gave no answer (rc=%s) — refusing to take over %s\n' "$rc" "$them" >&2
    fi
    return 1
}

# zbuild_claim_heartbeat_say <status-comment-pid> — R5 (#2533): a run that
# posts no run-status comment says its claim has no heartbeat, so another
# machine ages it from when its label was added. Nothing when it has one, or
# holds no claim.
zbuild_claim_heartbeat_say() {
    [[ -n "${1:-}" || -z "${_ZBUILD_CLAIM_ACQUIRED:-}" ]] && return 0
    printf 'zbuild: this run posts no run-status comment, so its claim has no heartbeat — another machine ages it from when its label was added\n' >&2
}
