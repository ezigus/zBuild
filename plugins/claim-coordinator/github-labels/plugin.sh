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
    printf 'claim-coordinator: issue #%s carries the %s label: another run is working on it. If that run is gone, remove the label: gh issue edit %s --remove-label %s\n' \
        "$issue" "$_CCGL_LABEL" "$issue" "$_CCGL_LABEL" >&2 || true
}

# ─── Concurrent claims (ADR-005 §5, #2534) ───────────────────────────────────
# Two runs that read the issue at once both add the label. So after adding it a
# claim posts its holder record, a comment "concurrent claim by `<holder>`", and
# reads every such note back once: the note GitHub timed first (then the lower
# id) wins. Only notes by the CI bot or the repository's people count, and only
# those from ZBUILD_CLAIM_RACE_WINDOW_S before this run's note on.
_CCGL_TRUSTED='(.user.login == "github-actions[bot]") or ((.author_association // "") | IN("OWNER","MEMBER","COLLABORATOR"))'
_CCGL_RACE_NOTE_PREFIX='concurrent claim by `'

# _ccgl_self_holder_v <var> — this run's holder string (CI: the run URL; else run_id/machine/pid)
_ccgl_self_holder_v() {
    local -n _ccsh="$1"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        _ccsh="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-unknown}"
    else
        _ccsh="run_id=${ZBUILD_RUN_ID:-} machine=${ZBUILD_CLAIM_MACHINE_ID:-${HOSTNAME:-unknown}} pid=$$"
    fi
    _ccsh="${_ccsh//[[:cntrl:]\`]/}"
}

# ZBUILD_CLAIM_RACE_WINDOW_S in seconds; not a number ("2m") → 120.
_ccgl_race_window_s_v() {
    local -n _crw="$1"; _crw="${ZBUILD_CLAIM_RACE_WINDOW_S:-120}"
    [[ "$_crw" =~ ^[0-9]+$ ]] || _crw=120
}

# _ccgl_race_note_post_v <id-var> <at-var> <issue> <holder> — posts this run's
# note; <id-var> gets its id, <at-var> GitHub's time for it in epoch seconds,
# each empty when GitHub's reply has none. rc 1: the post failed.
_ccgl_race_note_post_v() {
    local -n _crnp_id="$1" _crnp_at="$2"
    _crnp_id=""; _crnp_at=""
    _ccgl_gh api --repo "$_CCGL_SLUG" "repos/${_CCGL_SLUG}/issues/${3}/comments" \
        -f "body=${_CCGL_RACE_NOTE_PREFIX}${4}\`" 2>/dev/null || return 1
    { IFS= read -r -d '' _crnp_id; IFS= read -r -d '' _crnp_at; } < <(jq -j \
        '"\(.id // "")\u0000\((.created_at // "") | try fromdateiso8601 catch "")\u0000"' \
        <<< "$_CCGL_OUT" 2>/dev/null) || true
    [[ "$_crnp_id" =~ ^[0-9]+$ ]] || _crnp_id=""
    [[ "$_crnp_at" =~ ^[0-9]+$ ]] || _crnp_at=""
    return 0
}

# _ccgl_race_first_v <winner-var> <mine-var> <issue> <since> <holder> — one read
# of the issue's notes: <winner-var> gets the holder of the first trusted note
# GitHub timed at or after <since> (epoch s), <mine-var> the id of <holder>'s.
# rc 1: the notes could not be read.
_ccgl_race_first_v() {
    local -n _crf_w="$1" _crf_m="$2"
    _crf_w=""; _crf_m=""
    _ccgl_gh api --paginate --repo "$_CCGL_SLUG" "repos/${_CCGL_SLUG}/issues/${3}/comments?per_page=100" \
        2>/dev/null || return 1
    { IFS= read -r -d '' _crf_w; IFS= read -r -d '' _crf_m; } < <(jq -sj \
        --arg p "$_CCGL_RACE_NOTE_PREFIX" --argjson s "$4" --arg h "$5" "
        [.[][]? | select(${_CCGL_TRUSTED}) | select((.body // \"\") | startswith(\$p))
         | {t: ((.created_at // \"\") | try fromdateiso8601 catch null), id: (.id // 0),
            holder: (.body[(\$p | length):] | rtrimstr(\"\`\"))}
         | select(.t != null and .t >= \$s)]
        | sort_by(.t, .id)
        | \"\(.[0].holder // \"\")\u0000\(map(select(.holder == \$h)) | .[0].id // \"\")\u0000\"" \
        <<< "$_CCGL_OUT" 2>/dev/null) || true
    return 0
}

# _ccgl_race_note_delete <id> <issue> — rc 1 when it could not be removed.
_ccgl_race_note_delete() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    _ccgl_gh api -X DELETE --repo "$_CCGL_SLUG" "repos/${_CCGL_SLUG}/issues/comments/${1}" 2>/dev/null
}

# _ccgl_race_note_lost <id> <issue> <winner> — the losing run's note says it did
# not start; one that cannot be changed is removed, so no later claim counts it.
_ccgl_race_note_lost() {
    local id="$1" issue="$2" body window
    body="not started — concurrent claim: \`${3//[[:cntrl:]\`]/}\` was first"
    if [[ "$id" =~ ^[0-9]+$ ]]; then
        _ccgl_gh api -X PATCH --repo "$_CCGL_SLUG" "repos/${_CCGL_SLUG}/issues/comments/${id}" \
            -f "body=${body}" 2>/dev/null && return 0
        _ccgl_race_note_delete "$id" "$issue" && return 0
    fi
    _ccgl_race_window_s_v window
    printf 'claim-coordinator: could not mark this run'"'"'s claim note on issue #%s as not started, nor remove it: a run that claims the issue in the next %ss may be refused, as if this run had claimed first\n' \
        "$issue" "$window" >&2 || true
}

# _ccgl_race_notes_remove <issue> — removes this run's notes (at release).
_ccgl_race_notes_remove() {
    local issue="$1" holder id ok=1 window
    _ccgl_self_holder_v holder
    if _ccgl_gh api --paginate --repo "$_CCGL_SLUG" "repos/${_CCGL_SLUG}/issues/${issue}/comments?per_page=100" 2>/dev/null; then
        while IFS= read -r -d '' id; do
            _ccgl_race_note_delete "$id" "$issue" || ok=0
        done < <(jq -sj --arg b "${_CCGL_RACE_NOTE_PREFIX}${holder}\`" \
            "[.[][]? | select(${_CCGL_TRUSTED}) | select(.body == \$b) | \"\(.id)\u0000\"] | add // \"\"" \
            <<< "$_CCGL_OUT" 2>/dev/null)
    else
        ok=0
    fi
    [[ "$ok" -eq 1 ]] && return 0
    _ccgl_race_window_s_v window
    printf 'claim-coordinator: could not remove this run'"'"'s claim note from issue #%s: a run that claims the issue in the next %ss may be refused, as if this run had claimed first\n' \
        "$issue" "$window" >&2 || true
}

# _ccgl_unclaim <issue> — takes back the label a claim that cannot stand added.
_ccgl_unclaim() {
    _ccgl_remove_label "$1" "$_CCGL_LABEL" \
        || printf 'claim-coordinator: could not remove %s from issue #%s — the label may still be on the issue and will block the next run\n' \
            "$_CCGL_LABEL" "$1" >&2 || true
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
    # local-fs is serialised with flock: no race possible there.
    if [[ "${ZBUILD_CLAIM_BACKEND:-gh}" != "gh" ]]; then
        printf '{"acquired": true}\n'
        return 0
    fi
    # gh: the first of two claims made at once wins (ADR-005 §5).
    _ccgl_slug || { printf '{"acquired": true}\n'; return 0; }
    local holder="" note_id="" note_at="" winner="" mine="" window=0 since=0
    _ccgl_self_holder_v holder
    if ! _ccgl_race_note_post_v note_id note_at "$issue" "$holder"; then
        _ccgl_unclaim "$issue"
        printf '{"acquired": false, "reason": "backend_error"}\n'
        return 1
    fi
    _ccgl_race_window_s_v window
    [[ -n "$note_at" ]] && since=$(( note_at - window ))
    if ! _ccgl_race_first_v winner mine "$issue" "$since" "$holder"; then
        _ccgl_race_note_delete "$note_id" "$issue" || true
        _ccgl_unclaim "$issue"
        printf '{"acquired": false, "reason": "backend_error"}\n'
        return 1
    fi
    [[ -n "$note_id" ]] || note_id="$mine"
    if [[ -z "$note_at" ]]; then
        # Which claim was first is GitHub's time to tell, never this machine's.
        printf 'claim-coordinator: GitHub did not say when this run'"'"'s claim note on issue #%s was made, so which claim was first cannot be told — the claim is taken back\n' \
            "$issue" >&2 || true
        _ccgl_race_note_delete "$note_id" "$issue" || true
        _ccgl_unclaim "$issue"
        printf '{"acquired": false, "reason": "backend_error"}\n'
        return 1
    fi
    if [[ -z "$winner" || "$winner" == "$holder" ]]; then
        printf '{"acquired": true}\n'
        return 0
    fi
    # Another run claimed first: it holds the label, so the label stays.
    _ccgl_race_note_lost "$note_id" "$issue" "$winner"
    jq -nc --arg h "$winner" '{acquired: false, holder: $h, race_lost: true}'
    return 0
}

# ─── Hook: release <issue_id> ─────────────────────────────────────────────────
claim_coordinator_release() {
    local issue="$1"
    [[ -z "$issue" ]] && { printf 'claim_coordinator_release: missing issue id\n' >&2 || true; return 2; }
    local rc=0
    _ccgl_remove_label "$issue" "$_CCGL_LABEL" || rc=$?
    # The run's claim note goes too, so a claim made soon after never counts it
    # (ADR-005 §5). One that stays is said; the release stands.
    [[ "${ZBUILD_CLAIM_BACKEND:-gh}" == gh ]] && _ccgl_slug && _ccgl_race_notes_remove "$issue"
    [[ "$rc" -eq 0 ]] && return 0
    printf 'claim-coordinator: could not remove %s from issue #%s — remove the %s label by hand, or the next run of the issue is refused.\n' \
        "$_CCGL_LABEL" "$issue" "$_CCGL_LABEL" >&2 || true
    return 1
}

# ─── Hook: heartbeat <issue_id> ───────────────────────────────────────────────
# Labels do not expire (a stale claim is #2533's).
claim_coordinator_heartbeat() {
    return 0
}

# ─── Hook: takeover <issue> <holder> <by> <stale_s> <state_dir> ───────────────
# ADR-005 §3 (#2616): a claim another machine holds, judged on GitHub's clock
# and taken over when stale (lib/takeover.sh, loaded only here): released, and
# claimed again for this run. stdout: {"taken_over":true,"claimed":true,"age_s":N}
# | {"taken_over":false[,"failed":"<why>"]}.
claim_coordinator_takeover() {
    if ! declare -F claim_takeover_run >/dev/null 2>&1; then
        local _lrc=0
        # shellcheck source=lib/takeover.sh
        source "$_CCGL_DIR/lib/takeover.sh" 2>/dev/null || _lrc=$?
        if (( _lrc != 0 )) || ! declare -F claim_takeover_run >/dev/null 2>&1; then
            printf 'zbuild_claim_acquire: takeover.sh could not be loaded (%s) — refusing to take over %s\n' "$_CCGL_DIR/lib/takeover.sh" "${2:-}" >&2
            printf '{"taken_over":false}\n'; return 0
        fi
    fi
    claim_takeover_run "$1" "$2" "$3" "$4" "$5" claim_coordinator_release claim_coordinator_claim
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
