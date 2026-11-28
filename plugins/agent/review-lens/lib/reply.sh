#!/usr/bin/env bash
# plugins/agent/review-lens/lib/reply.sh — the lens's reply read: its JSON, and
# what is wrong with its findings' quotes, triggers and accepted_if (ADR-072 §3).
# Split from plugin.sh (#2571: under 500 lines); its callers are there.
#
# Sourced library: inherits the caller's pipefail/errexit; do not set them here.

[[ -n "${_ZBUILD_REVIEW_LENS_REPLY_LOADED:-}" ]] && return 0
_ZBUILD_REVIEW_LENS_REPLY_LOADED=1

# shellcheck source=reply-lines.sh
source "${BASH_SOURCE[0]%/*}/reply-lines.sh"

# _rl_reply_problem <reply> <json-var> <problem-var> — the lens's answer, read
# from its lines (#2598), or what is wrong with it in plain words (ADR-060 §7).
_rl_reply_problem() {
    local -n _rp_json="$2" _rp_why="$3"
    _rp_json=""; _rp_why=""
    _rl_reply_lines_v _rp_json "$1"
    # A field line outside any finding (review on #2598) is no answer either.
    if [[ -n "$_rp_json" && "$_rp_json" != *'"score":null'* && "$_rp_json" != *'"stray":true'* ]]; then return 0; fi
    # #2640: the reason says what is wrong — a field line outside any finding
    # is named, not reported as a SCORE line the reply has.
    local _rp_stray=""
    [[ -n "$_rp_json" && "$_rp_json" != *'"score":null'* && "$_rp_json" =~ \"stray_line\":\"${ZB_JSON_STR_RE}\" ]] \
        && zb_json_unescape_v _rp_stray "${BASH_REMATCH[1]}"
    _rp_json=""
    if [[ -n "$_rp_stray" ]]; then
        _rp_why="it is not in the asked form: a field line outside any FINDING or SUSPICION, \"${_rp_stray:0:120}\" — each finding starts with a FINDING line, its fields one per line under it, as the OUTPUT CONTRACT says"
        return 0
    fi
    _rp_why='it is not in the asked form: a line SCORE: <0-10>, then each finding as FINDING and its fields, one per line, as the OUTPUT CONTRACT says — no JSON'
}

# _rl_quote_problem_v <var> <json> <base> <repo> [patch] — what is wrong with
# the report's quotes (#2464, ADR-072 §3): a finding with none, or one that is
# in neither its file as it is now nor as it was at the commit the branch
# started from (<base>: a line the change removed), nor — with no starting
# commit known — the change's patch. Empty when every quote is there. Sets
# _RL_QUOTE_FILES: the files the findings name, which a kept report depends on,
# and _RL_BAD_AT: each finding's problems, by its index (#2598: a finding that cannot be checked costs only
# itself).
declare -gA _RL_BAD_AT=()
_rl_quote_problem_v() {
    local -n _rqp="$1"; local _rqp_n=0 _rqp_f _rqp_q _rqp_w _rqp_old
    local -a _rqp_bad=()
    _rqp=""; _RL_QUOTE_FILES=(); _RL_BAD_AT=()
    # No findings, nothing to check; a finding of any form is read (a plain
    # string has no quote or trigger — lens review on #2552).
    [[ "$2" =~ \"findings\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\] || "$2" != *'"findings"'* ]] && return 0
    local _rqp_t _rqp_a
    while IFS=$'\037' read -r -d '' _rqp_f _rqp_q _rqp_t _rqp_a; do
        _rqp_n=$(( _rqp_n + 1 ))
        # #2552 (ADR-038): every finding says what makes it happen.
        # Filler is no trigger (lens review on #2552).
        local _rqp_tl="${_rqp_t,,}"; _rqp_tl="${_rqp_tl//[[:space:].]/}"
        [[ -n "$_rqp_tl" && ! "$_rqp_tl" =~ ^(unknown|n/a|na|none|tbd|-+|null|\[\]|\{\})$ ]] \
            || { _rqp_bad+=("finding $_rqp_n has no trigger: say what makes it happen on a real run"); _RL_BAD_AT[$(( _rqp_n - 1 ))]+="${_RL_BAD_AT[$(( _rqp_n - 1 ))]:+; }${_rqp_bad[-1]}"; }
        # #2569 (ADR-038, ADR-072 §3): every finding says what would be accepted.
        _rqp_tl="${_rqp_a,,}"; _rqp_tl="${_rqp_tl//[[:space:].]/}"
        [[ -n "$_rqp_tl" && ! "$_rqp_tl" =~ ^(unknown|n/a|na|none|tbd|-+|null|\[\]|\{\})$ ]] \
            || { _rqp_bad+=("finding $_rqp_n has no accepted_if: say what must be true for it to be accepted, in the issue's words"); _RL_BAD_AT[$(( _rqp_n - 1 ))]+="${_RL_BAD_AT[$(( _rqp_n - 1 ))]:+; }${_rqp_bad[-1]}"; }
        [[ -n "$_rqp_f" && "$_rqp_f" != unknown ]] && _RL_QUOTE_FILES+=("$4/$_rqp_f")
        if [[ -z "${_rqp_q//[[:space:]]/}" ]]; then _rqp_bad+=("finding $_rqp_n has no quote"); _RL_BAD_AT[$(( _rqp_n - 1 ))]+="${_RL_BAD_AT[$(( _rqp_n - 1 ))]:+; }${_rqp_bad[-1]}"; continue; fi
        judge_quote_check_v _rqp_w "$_rqp_f | $_rqp_q" "" "$4" && continue
        # #2507 (ADR-072 §7): a removed line is in the file as it was — one git
        # call, only for a quote not found as the file is now.
        if [[ -n "$3" && -n "$_rqp_f" && "$_rqp_f" != unknown ]]; then
            _rqp_old="$(git -C "$4" show "$3:$_rqp_f" 2>/dev/null)" && _judge_holds "$_rqp_old" "$_rqp_q" && continue
        fi
        [[ -n "${5:-}" ]] && _judge_holds "$5" "$_rqp_q" && continue
        _rqp_bad+=("finding $_rqp_n's quote $_rqp_w")
        _RL_BAD_AT[$(( _rqp_n - 1 ))]+="${_RL_BAD_AT[$(( _rqp_n - 1 ))]:+; }${_rqp_bad[-1]}"
    # One record per finding, as tool-hook.sh reads a tool's fields: its file
    # and quote split by a unit separator and ended by a NUL, so a quote keeps
    # its line breaks and every other character as written (#2545). @tsv would
    # double a backslash in the quote.
    done < <(jq -j '(.findings // [])[]? | [(if type == "object" then (.file // "") else "" end), (if type == "object" then (.quote // "") else "" end), (if type == "object" then (.trigger // "") else "" end), (if type == "object" then (.accepted_if // "") else "" end)] | map(tostring | gsub("\u001f"; " ")) | join("\u001f") + "\u0000"' <<< "$2" 2>/dev/null)
    [[ ${#_rqp_bad[@]} -gt 0 ]] || return 0
    judge_problems_join_v _rqp _rqp_bad
}

# _rl_also_at_hold_v <var> <normalized> <base> <repo> [patch] — <normalized>
# with each finding's other places (also_at, "<file> | <line>") held to the
# change as its quote is (#2584, ADR-038): one whose line is not in its file
# now, in the file as it was, or in the round's patch is left out, a line in
# _RL_ALSO_NOTES for each. One jq to read them, one to drop, only when any is.
_RL_ALSO_NOTES=""
_rl_also_at_hold_v() {
    local -n _rah="$1"; local _rah_n _rah_p _rah_f _rah_q _rah_w _rah_old _rah_d=""
    _rah="$2"; _RL_ALSO_NOTES=""
    [[ "$2" == *'"also_at":["'* ]] || return 0
    while IFS=$'\037' read -r -d '' _rah_n _rah_p; do
        _rah_f="${_rah_p%% | *}" _rah_q="${_rah_p#* | }"
        if [[ "$_rah_p" == *" | "* && -n "${_rah_q//[[:space:]]/}" && -n "${_rah_f//[[:space:]]/}" ]]; then
            judge_quote_check_v _rah_w "$_rah_p" "" "$4" && continue
            if [[ -n "$3" ]]; then
                _rah_old="$(git -C "$4" show "$3:$_rah_f" 2>/dev/null)" && _judge_holds "$_rah_old" "$_rah_q" && continue
            fi
            [[ -n "${5:-}" ]] && _judge_holds "$5" "$_rah_q" && continue
        fi
        _rah_d+="${_rah_d:+,}[$_rah_n]"
        _RL_ALSO_NOTES+="a place the same kind of problem is also at was left out, its line not found as quoted: ${_rah_p:0:200}"$'\n'
    done < <(jq -j '.findings | to_entries[] | .key as $i | (.value.also_at // []) | to_entries[]
        | "\($i),\(.key)\u001f\(.value | gsub("\u001f"; " "))\u0000"' <<< "$2" 2>/dev/null)
    [[ -n "$_rah_d" ]] || return 0
    _rah="$(jq -c --argjson d "[$_rah_d]" 'reduce ($d | sort | reverse)[] as $p (.; del(.findings[$p[0]].also_at[$p[1]]))' <<< "$2" 2>/dev/null)" || _rah="$2"
    [[ -n "$_rah" ]] || _rah="$2"
}
