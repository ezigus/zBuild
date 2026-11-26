#!/usr/bin/env bash
# plugins/claim-coordinator/github-labels/lib/takeover.sh — the github-labels
# coordinator's stale takeover (ADR-005 §3, #2533; moved from the engine, #2616):
# the claim's age, the takeover note, whose note came first, and the old
# holder's comment marked. Loaded lazily by the coordinator's takeover hook;
# GitHub calls go through rsc_gh (run-status-comment.sh), whose timeout and log
# they share.
#
# Every time is GitHub's: the claim's (created_at / updated_at) and now (the
# Date of GitHub's reply), so no machine's clock is compared with GitHub's.
#
# Sourced library: no set -euo pipefail.
[[ -n "${_ZBUILD_CLAIM_TAKEOVER_LOADED:-}" ]] && return 0
_ZBUILD_CLAIM_TAKEOVER_LOADED=1
# shellcheck source=../../../../scripts/lib/run-status-comment.sh
declare -F rsc_gh >/dev/null 2>&1 || source "${_ZBUILD_ROOT:-${BASH_SOURCE[0]%/*}/../../../..}/scripts/lib/run-status-comment.sh"

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

# claim_github_now_v <epoch-var> <state_dir> <slug> — now, by GitHub's clock:
# the Date of its reply to a read of the repository (#2616). rc 1 when it
# cannot be read.
claim_github_now_v() {
    local -n _cgn="$1"; local sd="$2" slug="$3" out l d=""
    _cgn=0
    out="$(mktemp "${TMPDIR:-$sd}/claim-now.XXXXXX")" || return 1
    if ! rsc_gh "$sd" "$out" api -i "repos/${slug}" 2>/dev/null; then rm -f "$out"; return 1; fi
    while IFS= read -r l || [[ -n "$l" ]]; do
        l="${l%$'\r'}"; [[ -z "$l" ]] && break
        [[ "${l,,}" == date:* ]] && { d="${l#*:}"; d="${d# }"; break; }
    done < "$out"
    rm -f "$out"
    [[ -n "$d" ]] || return 1
    _cgn="$(jq -rn --arg d "$d" '$d | strptime("%a, %d %b %Y %H:%M:%S GMT") | mktime' 2>/dev/null)" || _cgn=0
    [[ "$_cgn" =~ ^[0-9]+$ && "$_cgn" -gt 0 ]] || { _cgn=0; return 1; }
    return 0
}

# claim_takeover_mark_old <state_dir> <slug> <issue> <holder> <by> <now> — the
# old holder's run-status comment says it was taken over (#2616): its
# "still running" line becomes "taken over — <when> — by <by>". Best-effort:
# rc 1 when it could not be marked; the takeover stands.
claim_takeover_mark_old() {
    local sd="$1" slug="$2" issue="$3" holder="$4" by="${5//[[:cntrl:]]/}" now="$6" out id body when line
    out="$(mktemp "${TMPDIR:-$sd}/claim-mark.XXXXXX")" || return 1
    if ! rsc_gh "$sd" "$out" api --paginate "repos/${slug}/issues/${issue}/comments" 2>/dev/null; then rm -f "$out"; return 1; fi
    id="$(jq -rs --arg m "$_RSC_MARKER_PREFIX" --arg h "${_RSC_HOLDER_PREFIX}${holder} -->" "
        [.[][]? | select($_CT_TRUSTED) | select((.body // \"\") | startswith(\$m) and contains(\$h))]
        | sort_by(.updated_at) | last | .id // empty" "$out" 2>/dev/null)"
    body="$(jq -rs --argjson i "${id:-0}" '[.[][]? | select(.id == $i)] | first | .body // empty' "$out" 2>/dev/null)"
    [[ "$id" =~ ^[0-9]+$ && -n "$body" ]] || { rm -f "$out"; return 1; }
    printf -v when '%(%Y-%m-%dT%H:%M:%SZ)T' "$now"
    line="taken over — $when — by $by"
    if [[ "$body" == *$'\n'"still running — "* || "$body" == "still running — "* ]]; then
        body="$(awk -v t="$line" '/^still running — / { print t; next } { print }' <<< "$body")"
    else
        body="$(awk -v t="$line" -v h="$_RSC_HOLDER_PREFIX" '{ print } !done && index($0, h) == 1 { print t; done = 1 }' <<< "$body")"
    fi
    jq -n --arg b "$body" '{body: $b}' > "$out.json" 2>/dev/null || { rm -f "$out" "$out.json"; return 1; }
    local rc=0
    rsc_gh "$sd" "$out" api -X PATCH "repos/${slug}/issues/comments/${id}" --input "$out.json" >/dev/null 2>&1 || rc=1
    rm -f "$out" "$out.json"
    return "$rc"
}

# claim_takeover_run <issue> <holder> <by> <stale_s> <state_dir> <release_fn>
# — the takeover (ADR-005 §3): stdout {"taken_over":true,"age_s":N},
# {"taken_over":false} or {"taken_over":false,"failed":"release_failed"}; what
# happened is said on stderr. Every way it cannot tell refuses (fail closed).
claim_takeover_run() {
    local issue="$1" them="$2" me="$3" stale="$4" state_dir="$5" release_fn="$6"
    local slug; claim_takeover_slug_v slug
    if [[ -z "$slug" ]]; then
        printf 'zbuild_claim_acquire: no repository to read the claim from (no GITHUB_REPOSITORY, no origin here) — refusing to take over %s\n' "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    local at=0 arc=0 now=0 age
    claim_age_v at "$state_dir" "$slug" "$issue" "$them" || arc=$?
    if (( arc == 1 )); then
        printf 'zbuild_claim_acquire: could not read the claim'"'"'s age from GitHub (%s#%s) — refusing to take over %s\n' "$slug" "$issue" "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    elif (( arc != 0 )); then
        printf 'zbuild_claim_acquire: %s has no run-status comment and no label time on #%s — refusing (fail closed)\n' "$them" "$issue" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    if ! claim_github_now_v now "$state_dir" "$slug"; then
        printf 'zbuild_claim_acquire: could not read GitHub'"'"'s time (%s) — refusing to take over %s\n' "$slug" "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    age=$(( now - at ))
    if (( age < stale )); then
        printf 'zbuild_claim_acquire: issue #%s is held by %s (not stale yet: last seen %ss ago, stale at %ss) — refused\n' \
            "$issue" "${them:-an unnamed holder}" "$(( age < 0 ? 0 : age ))" "$stale" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    # Stale: a note, then — only when this run's note is the first since the
    # claim's time — release and claim. A run that does not go on deletes its note.
    local id="" first="" nrc=0
    claim_takeover_note_post_v id "$state_dir" "$slug" "$issue" "$them" "$me" || nrc=$?
    if (( nrc == 2 )); then
        printf 'zbuild_claim_acquire: the takeover note was posted without an id in GitHub'"'"'s reply, so it could not be deleted — refusing to take over %s\n' "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    elif (( nrc != 0 )); then
        printf 'zbuild_claim_acquire: the takeover note could not be posted — refusing to take over %s\n' "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    # A note counts only since the claim's time and within the takeover's own
    # window (four gh timeouts): one left by a killed run does not block later ones.
    local gt="${ZBUILD_STATUS_COMMENT_GH_TIMEOUT:-30}" since
    [[ "$gt" =~ ^[0-9]+$ ]] || gt=30
    since=$(( now - 4 * gt )); (( since > at )) || since="$at"
    if ! claim_takeover_first_v first "$state_dir" "$slug" "$issue" "$them" "$since" || [[ -z "$first" ]]; then
        claim_takeover_note_delete "$state_dir" "$slug" "$issue" "$id"
        printf 'zbuild_claim_acquire: could not read the takeover notes back — refusing to take over %s\n' "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    if [[ "$first" != "$me" ]]; then
        claim_takeover_note_delete "$state_dir" "$slug" "$issue" "$id"
        printf 'zbuild_claim_acquire: another run took over first: %s — refused (%s was stale)\n' "$first" "$them" >&2
        printf '{"taken_over":false}\n'; return 0
    fi
    if ! "$release_fn" "$issue" >/dev/null 2>&1; then
        claim_takeover_note_delete "$state_dir" "$slug" "$issue" "$id"
        printf 'zbuild_claim_acquire: releasing %s'"'"'s claim failed — refused; the claim is still theirs\n' "$them" >&2
        printf '{"taken_over":false,"failed":"release_failed"}\n'; return 0
    fi
    claim_takeover_mark_old "$state_dir" "$slug" "$issue" "$them" "$me" "$now" \
        || printf 'zbuild_claim_acquire: the old holder'"'"'s run-status comment could not be marked as taken over\n' >&2
    printf 'zbuild_claim_acquire: took over a stale claim from %s (last seen %ss ago) on issue #%s\n' "$them" "$age" "$issue" >&2
    printf '{"taken_over":true,"age_s":%s}\n' "$age"
}
