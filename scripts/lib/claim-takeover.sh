#!/usr/bin/env bash
# scripts/lib/claim-takeover.sh — what a cross-machine stale takeover reads and
# writes on the issue (ADR-005 §3, #2533): the claim's age, the takeover note,
# and whose note came first. Loaded lazily by core/claim/claim.sh; GitHub calls
# go through rsc_gh (run-status-comment.sh), whose timeout and log they share.
#
# Every time is GitHub's (created_at / updated_at), so two machines' clocks
# never meet; only this machine's "now" is compared with them.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_CLAIM_TAKEOVER_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_TAKEOVER_LOADED=1
# shellcheck source=run-status-comment.sh
source "${BASH_SOURCE[0]%/*}/run-status-comment.sh"

# The comments a claim decision trusts: the bot's, or the repository's own people.
_CT_TRUSTED='(.user.login == "github-actions[bot]") or ((.author_association // "") | IN("OWNER","MEMBER","COLLABORATOR"))'
_CT_NOTE_PREFIX='took over a stale claim from '

# claim_takeover_slug_v <var> — the repository the claim is on, as the
# coordinator names it: GITHUB_REPOSITORY in CI, else the run's own repository
# (the current directory's origin). "" when there is none.
claim_takeover_slug_v() {
    local -n _cts="$1"
    _cts="${GITHUB_REPOSITORY:-}"
    [[ -n "$_cts" ]] || _cts="$(zbuild_repo_slug "$PWD" 2>/dev/null || true)"
}

# claim_age_v <epoch-var> <state_dir> <slug> <issue> <holder> — when the claim
# was last shown alive, by GitHub's clock: the later of the holder's run-status
# comment's last edit (the heartbeat edits it) and the zbuild:claimed label's
# last added time. rc 1 when either read fails (never the label alone because
# the comments could not be read); rc 2 when neither time exists.
claim_age_v() {
    local -n _cae="$1"; local sd="$2" slug="$3" issue="$4" holder="$5" out c="" l=""
    _cae=0
    out="$(mktemp "${TMPDIR:-$sd}/claim-age.XXXXXX")" || return 1
    if ! rsc_gh "$sd" "$out" api --paginate "repos/${slug}/issues/${issue}/comments" 2>/dev/null \
       || ! c="$(jq -rs --arg m "$_RSC_MARKER_PREFIX" --arg h "${_RSC_HOLDER_PREFIX}${holder} -->" "
            [.[][]? | select($_CT_TRUSTED) | select((.body // \"\") | startswith(\$m) and contains(\$h))
             | .updated_at | fromdateiso8601] | max // 0" "$out" 2>/dev/null)"; then
        rm -f "$out"; return 1
    fi
    if ! rsc_gh "$sd" "$out" api --paginate "repos/${slug}/issues/${issue}/events" 2>/dev/null \
       || ! l="$(jq -rs '[.[][]? | select(.event == "labeled" and (.label.name // "") == "zbuild:claimed")
                          | .created_at | fromdateiso8601] | max // 0' "$out" 2>/dev/null)"; then
        rm -f "$out"; return 1
    fi
    rm -f "$out"
    [[ "$c" =~ ^[0-9]+$ && "$l" =~ ^[0-9]+$ ]] || return 1
    _cae=$(( c > l ? c : l ))
    (( _cae > 0 )) || return 2
    return 0
}

# claim_takeover_note_post_v <id-var> <state_dir> <slug> <issue> <holder> <by>
# — posts "took over a stale claim from `<holder>` — by `<by>`"; <id-var> gets
# the comment's id, to delete it if the takeover does not happen. rc 1 on
# failure; rc 2 when it was posted but GitHub's reply held no id.
claim_takeover_note_post_v() {
    local -n _ctn="$1"; local sd="$2" slug="$3" issue="$4" holder="${5//[[:cntrl:]\`]/}" by="${6//[[:cntrl:]\`]/}" out
    _ctn=""
    out="$(mktemp "${TMPDIR:-$sd}/claim-note.XXXXXX")" || return 1
    if ! rsc_gh "$sd" "$out" api "repos/${slug}/issues/${issue}/comments" \
            -f "body=${_CT_NOTE_PREFIX}\`${holder}\` — by \`${by}\`" >/dev/null 2>&1; then
        rm -f "$out"; return 1
    fi
    _ctn="$(jq -r '.id // empty' "$out" 2>/dev/null || true)"
    rm -f "$out"
    # A note with no id could not be deleted if the takeover does not happen:
    # rc 2, and the run does not go on (it stops counting after the window).
    [[ "$_ctn" =~ ^[0-9]+$ ]] || return 2
    return 0
}

# claim_takeover_note_delete <state_dir> <slug> <issue> <id> — removes this
# run's note when it did not take over; best-effort (the run refuses anyway).
claim_takeover_note_delete() {
    local sd="$1" slug="$2" id="${4:-}" out
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    out="$(mktemp "${TMPDIR:-$sd}/claim-note-del.XXXXXX")" || return 0
    rsc_gh "$sd" "$out" api -X DELETE "repos/${slug}/issues/comments/${id}" >/dev/null 2>&1 || true
    rm -f "$out"
    return 0
}

# claim_takeover_first_v <var> <state_dir> <slug> <issue> <holder> <since>
# — the run named by the first trusted takeover note for <holder> posted at or
# after <since> (the claim's time, claim_age_v): an older note was about an
# older claim. Ordered by GitHub's created_at, then id. rc 1 when the comments
# cannot be read.
claim_takeover_first_v() {
    local -n _ctf="$1"; local sd="$2" slug="$3" issue="$4" holder="${5//[[:cntrl:]\`]/}" since="${6:-0}" out
    _ctf=""
    out="$(mktemp "${TMPDIR:-$sd}/claim-first.XXXXXX")" || return 1
    if ! rsc_gh "$sd" "$out" api --paginate "repos/${slug}/issues/${issue}/comments" 2>/dev/null; then
        rm -f "$out"; return 1
    fi
    _ctf="$(jq -rs --arg p "${_CT_NOTE_PREFIX}\`${holder}\` — by \`" --argjson s "$since" "
        [.[][]? | select($_CT_TRUSTED) | select((.body // \"\") | startswith(\$p))
         | select((.created_at | fromdateiso8601) >= \$s)
         | {t: (.created_at | fromdateiso8601), id: (.id // 0), by: (.body[(\$p | length):] | split(\"\`\")[0])}]
        | sort_by(.t, .id) | first | .by // empty" "$out" 2>/dev/null || true)"
    rm -f "$out"
    return 0
}
