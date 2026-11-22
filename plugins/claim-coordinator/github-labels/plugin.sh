#!/usr/bin/env bash
# plugins/claim-coordinator/github-labels/plugin.sh — the default claim
# coordinator (ADR-005): one shared issue label, zbuild:claimed, means "a run is
# working on this issue". Who holds it is in that run's run-status comment.
# Sourced library: inherits caller's pipefail; do not add set -euo pipefail.

[[ -n "${_ZBUILD_CLAIM_GH_LABELS_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_GH_LABELS_LOADED=1

_CCGL_LABEL="zbuild:claimed"
_CCGL_DIR="${BASH_SOURCE[0]%/*}"

# Backends: `gh` (the default) talks to GitHub; `local-fs` keeps the labels in
# ZBUILD_CLAIM_STORE/<issue>/labels.txt, flock-serialised, for tests.
_ccgl_flock_timeout_sec() { echo "${ZBUILD_CLAIM_FLOCK_TIMEOUT_SEC:-5}"; }

_ccgl_lf_labels_file() {
    local issue="$1"
    local store="${ZBUILD_CLAIM_STORE:?ZBUILD_CLAIM_STORE must be set for local-fs backend}"
    mkdir -p "$store/$issue"
    echo "$store/$issue/labels.txt"
}

# Every gh call runs under the run-status comment's watchdog (rsc_gh,
# ZBUILD_STATUS_COMMENT_GH_TIMEOUT): a hung gh in the exit path could otherwise
# only be KILLed, and would leave the label behind.
_ccgl_gh_lib() {
    declare -F rsc_gh >/dev/null 2>&1 && return 0
    # shellcheck source=../../../scripts/lib/run-status-comment.sh
    source "${_ZBUILD_ROOT:-$_CCGL_DIR/../../..}/scripts/lib/run-status-comment.sh"
}
_CCGL_OUT=""
_ccgl_gh() {
    _ccgl_gh_lib || return 1
    local out rc=0
    out="$(mktemp "${TMPDIR:-/tmp}/ccgl-gh.XXXXXX")" || return 1
    rsc_gh "${ZBUILD_STATE_DIR:-${TMPDIR:-/tmp}}" "$out" "$@" || rc=$?
    _CCGL_OUT="$(cat "$out" 2>/dev/null)"
    rm -f "$out"
    return "$rc"
}

# The repository every label call and the holder reader name: one slug, the
# same for both (GITHUB_REPOSITORY in CI, else the origin's). rc 1 when none.
_CCGL_SLUG=""
_ccgl_slug() {
    [[ -n "$_CCGL_SLUG" ]] && return 0
    _ccgl_gh_lib || return 1
    _CCGL_SLUG="${GITHUB_REPOSITORY:-}"
    [[ -n "$_CCGL_SLUG" ]] || _CCGL_SLUG="$(zbuild_repo_slug 2>/dev/null || true)"
    [[ -n "$_CCGL_SLUG" ]]
}

# Labels on an issue, one a line, into _CCGL_OUT. rc 1 on a backend error.
_ccgl_read_labels() {
    local issue="$1"
    case "${ZBUILD_CLAIM_BACKEND:-gh}" in
        gh) _ccgl_slug && _ccgl_gh issue view "$issue" --json labels --jq '.labels[].name' --repo "$_CCGL_SLUG" ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            _CCGL_OUT=""
            [[ -f "$f" ]] && _CCGL_OUT="$(cat "$f")"
            return 0 ;;
        *) return 1 ;;
    esac
}

# rc 0 when <label> is on <issue> now (one read).
_ccgl_label_on() {
    local line
    _ccgl_read_labels "$1" || return 1
    while IFS= read -r line; do [[ "$line" == "$2" ]] && return 0; done <<< "$_CCGL_OUT"
    return 1
}

# Add the label. rc 0 added, 2 already there (local-fs: checked inside the lock),
# 1 backend error. A repository that does not define the label yet gets it once.
_ccgl_add_label() {
    local issue="$1" label="$2"
    case "${ZBUILD_CLAIM_BACKEND:-gh}" in
        gh)
            _ccgl_slug || return 1
            _ccgl_gh issue edit "$issue" --add-label "$label" --repo "$_CCGL_SLUG" && return 0
            if [[ "$_RSC_GH_ERR" == *"not found"* ]]; then
                _ccgl_gh label create "$label" --force --color "5319e7" \
                    --description "a zbuild run is working on this issue" --repo "$_CCGL_SLUG" || return 1
                _ccgl_gh issue edit "$issue" --add-label "$label" --repo "$_CCGL_SLUG" && return 0
            fi
            # The add may have reached GitHub with its answer lost (a timeout, a
            # dropped reply). The issue was clear when read, so a label there now
            # is this run's: say so, or nothing would ever release it.
            _ccgl_label_on "$issue" "$label"
            ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            local timeout; timeout="$(_ccgl_flock_timeout_sec)"
            (
                exec 9>"${f}.lock"
                flock -w "$timeout" 9 || exit 1
                touch "$f"
                grep -Fxq "$label" "$f" && exit 2
                echo "$label" >> "$f"
                exit 0
            )
            ;;
        *) return 1 ;;
    esac
}

_ccgl_remove_label() {
    local issue="$1" label="$2"
    case "${ZBUILD_CLAIM_BACKEND:-gh}" in
        gh) _ccgl_slug && _ccgl_gh issue edit "$issue" --remove-label "$label" --repo "$_CCGL_SLUG" ;;
        local-fs)
            local f; f="$(_ccgl_lf_labels_file "$issue")"
            [[ ! -f "$f" ]] && return 0
            local timeout; timeout="$(_ccgl_flock_timeout_sec)"
            (
                exec 9>"${f}.lock"
                flock -w "$timeout" 9 || exit 1
                grep -Fxv "$label" "$f" > "${f}.new" || true
                mv "${f}.new" "$f"
            )
            ;;
        *) return 1 ;;
    esac
}

# _ccgl_read_holder <issue> — who the newest run-status comment names as holder.
_ccgl_read_holder() {
    local issue="$1" holder=""
    _ccgl_gh_lib || return 0
    case "${ZBUILD_CLAIM_BACKEND:-gh}" in
        local-fs)
            local rsc="${ZBUILD_CLAIM_STORE:-}/$issue/run-status-comment.txt"
            [[ -f "$rsc" ]] || return 0
            rsc_holder_line_v holder "$(cat "$rsc")"
            printf '%s' "$holder"
            ;;
        gh)
            _ccgl_slug || return 0
            rsc_holder_find "${ZBUILD_STATE_DIR:-${TMPDIR:-/tmp}}" "$_CCGL_SLUG" "$issue"
            ;;
    esac
}

_ccgl_refused() {
    local issue="$1" holder
    holder="$(_ccgl_read_holder "$issue" || true)"
    jq -nc --arg h "$holder" '{acquired: false, holder: $h}'
    printf 'claim-coordinator: issue #%s carries the %s label: another run is working on it. If that run is gone, remove the %s label from the issue.\n' \
        "$issue" "$_CCGL_LABEL" "$_CCGL_LABEL" >&2 || true
}

# ─── Hook: claim <issue_id> ───────────────────────────────────────────────────
# stdout: {"acquired": true} | {"acquired": false, "holder": "<holder>"}
#         | {"acquired": false, "skipped": "<why>"} (no claim was attempted)
# rc: 0 answered, 1 backend error, 2 usage error.
claim_coordinator_claim() {
    local issue="$1"
    [[ -z "$issue" ]] && { printf 'claim_coordinator_claim: missing issue id\n' >&2 || true; return 2; }
    # The label is on GitHub (local-fs stands in for it): a run told to stay off
    # GitHub makes no claim there.
    if [[ "${NO_GITHUB:-}" == "true" ]]; then
        printf '{"acquired": false, "skipped": "NO_GITHUB=true"}\n'
        return 0
    fi

    if ! _ccgl_read_labels "$issue"; then
        printf '{"acquired": false, "reason": "backend_read_error"}\n'
        return 1
    fi
    local line
    while IFS= read -r line; do
        [[ "$line" == "$_CCGL_LABEL" ]] && { _ccgl_refused "$issue"; return 0; }
    done <<< "$_CCGL_OUT"

    # No hostname in the label: a laptop run and a CI run claim the same one.
    local add_rc=0
    _ccgl_add_label "$issue" "$_CCGL_LABEL" || add_rc=$?
    if [[ "$add_rc" -eq 2 ]]; then
        _ccgl_refused "$issue"
        return 0
    fi
    if [[ "$add_rc" -ne 0 ]]; then
        printf '{"acquired": false, "reason": "backend_error"}\n'
        return 1
    fi
    printf '{"acquired": true}\n'
    return 0
}

# ─── Hook: release <issue_id> ─────────────────────────────────────────────────
claim_coordinator_release() {
    local issue="$1"
    [[ -z "$issue" ]] && { printf 'claim_coordinator_release: missing issue id\n' >&2 || true; return 2; }
    _ccgl_remove_label "$issue" "$_CCGL_LABEL" && return 0
    printf 'claim-coordinator: could not remove %s from issue #%s — remove the %s label by hand, or the next run of the issue is refused.\n' \
        "$_CCGL_LABEL" "$issue" "$_CCGL_LABEL" >&2 || true
    return 1
}

# ─── Hook: heartbeat <issue_id> ───────────────────────────────────────────────
# Labels do not expire (a stale claim is #2533's).
claim_coordinator_heartbeat() {
    return 0
}

# ─── Hook: list_claims ────────────────────────────────────────────────────────
# stdout: JSON array of {issue, holder, acquired_at}. rc 1 on a backend error.
claim_coordinator_list_claims() {
    case "${ZBUILD_CLAIM_BACKEND:-gh}" in
        gh)
            { _ccgl_slug && _ccgl_gh issue list --label "$_CCGL_LABEL" --json number --repo "$_CCGL_SLUG"; } || {
                printf 'list_claims: gh issue list failed\n' >&2 || true
                return 1
            }
            jq -c 'map({issue: .number, holder: "unknown", acquired_at: null})' <<< "$_CCGL_OUT" 2>/dev/null \
                || printf '[]\n'
            ;;
        local-fs)
            local store="${ZBUILD_CLAIM_STORE:?}"
            local results='[]' issue_dir issue holder
            for issue_dir in "$store"/*/; do
                [[ -f "$issue_dir/labels.txt" ]] || continue
                grep -Fxq "$_CCGL_LABEL" "$issue_dir/labels.txt" 2>/dev/null || continue
                issue="${issue_dir%/}"; issue="${issue##*/}"
                holder="$(_ccgl_read_holder "$issue" || true)"
                results="$(jq -c --arg i "$issue" --arg h "$holder" \
                    '. + [{issue: ($i|tonumber), holder: $h, acquired_at: null}]' <<< "$results")"
            done
            printf '%s\n' "$results"
            ;;
        *) printf '[]\n' ;;
    esac
    return 0
}
