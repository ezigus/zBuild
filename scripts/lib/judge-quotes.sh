#!/usr/bin/env bash
# scripts/lib/judge-quotes.sh — a judge's quote is checked against the file it
# names (ADR-072 §3). Sourced by judge.sh.
#
# Sourced library: no set -euo pipefail.

[[ -n "${_ZBUILD_JUDGE_QUOTES_LOADED:-}" ]] && return 0
_ZBUILD_JUDGE_QUOTES_LOADED=1

# ─── Quotes (§3) ─────────────────────────────────────────────────────────────

# _judge_words_v <var> <text> — the text with every run of spacing one space.
_judge_words_v() {
    local -n _jwo="$1"; local -a _jww=()
    read -r -d '' -a _jww <<< "$2" || true
    _jwo="${_jww[*]}"
}

# _judge_holds <text> <quote> — rc 0 when <text> holds <quote>, spacing and
# the markdown marks `*`, `_` and backticks aside (#2472: the issue wrote
# `stage *k*`, the judge quoted "stage k", as it reads).
# A quote written inside "…" escapes its quote marks and backslashes (\" and
# \\, #2487): read as written first, since code holds real backslashes, then
# with each escape read as the character it stands for.
_judge_holds() {
    local _jh_t="${1//[*_\`]/}" _jh_q="${2//[*_\`]/}" _jh_u
    _judge_words_v _jh_t "$_jh_t"; _judge_words_v _jh_q "$_jh_q"
    [[ -n "$_jh_q" ]] || return 1
    [[ " $_jh_t " == *"$_jh_q"* ]] && return 0
    [[ "$_jh_q" == *\\* ]] || return 1
    _jh_u="${_jh_q//\\\\/$'\x01'}"; _jh_u="${_jh_u//\\\"/\"}"; _jh_u="${_jh_u//$'\x01'/\\}"
    [[ " $_jh_t " == *"$_jh_u"* ]]
}

# _judge_bare_path_v <var> — the file name of a quote without the backticks or
# bold marks a model writes around it (#1805 run 42556446368): formatting is not
# the judge's to get right (#2472).
_judge_bare_path_v() {
    local -n _jbp="$1"
    while [[ "$_jbp" == [\`*]* ]]; do _jbp="${_jbp:1}"; done
    while [[ "$_jbp" == *[\`*] ]]; do _jbp="${_jbp%?}"; done
}

# _judge_quote_split <quote> — a `<file> | <text>` quote's file into _jqs_path
# and text into _jqs_txt (#2519, ADR-072 §3): rc 0 when the quote has that form,
# its file a single word. The text runs to the end, so it holds no escapes.
_judge_quote_split() {
    _jqs_path="" _jqs_txt=""
    [[ "$1" =~ ^([^|]*[^[:space:]|])[[:space:]]+\|[[:space:]]+(.*)$ ]] || return 1
    _jqs_path="${BASH_REMATCH[1]}"; _jqs_txt="${BASH_REMATCH[2]}"
    _judge_bare_path_v _jqs_path
    [[ -n "$_jqs_path" && "$_jqs_path" != *[[:space:]]* ]]
}

# judge_quote_check_v <why_var> <quote> <own_words> <repo> [base_dir] — rc 0
# when <quote> is really there: `<file> | <one line>` within one line of that
# file in the repository or in the code from before the change, or the item's
# own words as they are (#2519). Otherwise rc 1 and <why_var> says what is
# wrong, to follow "<id>'s quote " in a re-ask.
judge_quote_check_v() {
    local -n _jqw="$1"
    local _judge__q="$2" _judge__own="$3" _judge__repo="${4:+${4%/}}" _judge__base="${5:+${5%/}}" _judge__path _judge__txt _judge__f _judge__seen=0
    local _jqs_path _jqs_txt _judge__body
    _jqw=""
    _judge__q="${_judge__q#"${_judge__q%%[![:space:]]*}"}"; _judge__q="${_judge__q%"${_judge__q##*[![:space:]]}"}"
    if [[ -z "$_judge__q" ]]; then
        _jqw="is not a quote: write <file> | <one line from it, copied as it is>, or the item's own words"
        return 1
    fi
    if ! _judge_quote_split "$_judge__q"; then
        if [[ "$_judge__q" =~ ^[^\"[:space:]]+:\" ]]; then
            _jqw="is not a quote: write <file> | <one line from it, copied as it is>, with no quote marks around the line"
            return 1
        fi
        # The item's own words, as they are; a pair of quote marks around them is not theirs.
        _judge__txt="$_judge__q"
        local _judge__in=""
        [[ "$_judge__txt" =~ ^\"(.*)\"$ ]] && _judge__in="${BASH_REMATCH[1]}"
        [[ -n "$_judge__in" ]] && ! _judge_holds "$_judge__own" "$_judge__txt" && _judge__txt="$_judge__in"
        _judge_holds "$_judge__own" "$_judge__txt" && return 0
        _jqw="is not in the item's own words: $_judge__txt"
        return 1
    fi
    _judge__path="$_jqs_path"; _judge__txt="$_jqs_txt"
    case "$_judge__path" in
        "$_judge__repo"/*) _judge__path="${_judge__path#"$_judge__repo"/}" ;;
        "${_judge__base:-/nonexistent}"/*) _judge__path="${_judge__path#"$_judge__base"/}" ;;
        /*) _jqw="names $_judge__path, which is not a file of the repository"; return 1 ;;
    esac
    if [[ "/$_judge__path/" == *"/../"* ]]; then
        _jqw="names $_judge__path, which is not a file of the repository"; return 1
    fi
    for _judge__f in "$_judge__repo/$_judge__path" ${_judge__base:+"$_judge__base/$_judge__path"}; do
        [[ -f "$_judge__f" ]] || continue
        _judge__seen=1
        _judge__body="$(<"$_judge__f")"
        # One line: a mark between the lines that no quote holds keeps a match
        # inside one. A text of several lines (a lens's JSON quote) is read whole.
        [[ "$_judge__txt" == *$'\n'* ]] || _judge__body="${_judge__body//$'\n'/ $'\x1e' }"
        _judge_holds "$_judge__body" "$_judge__txt" && return 0
    done
    if (( _judge__seen )); then
        _jqw="is not in $_judge__path, on one line: $_judge__txt"
    else
        _jqw="names $_judge__path, which is not a file of the repository"
    fi
    return 1
}

# judge_quote_path_v <var> <quote> <repo> [base] — the repository path a
# `<file> | <text>` quote names, for the files a kept answer depends on; empty
# for a quote of the item's own words.
judge_quote_path_v() {
    local -n _jqp="$1"; local _judge__repo="${3:+${3%/}}" _judge__base="${4:+${4%/}}" _jqs_path _jqs_txt _jqp_q="$2"
    _jqp=""
    _jqp_q="${_jqp_q#"${_jqp_q%%[![:space:]]*}"}"
    _judge_quote_split "$_jqp_q" || return 0
    _jqp="$_jqs_path"
    _jqp="${_jqp#"$_judge__repo"/}"; [[ -n "$_judge__base" ]] && _jqp="${_jqp#"$_judge__base"/}"
    return 0
}
