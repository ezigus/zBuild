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

# _judge_uncomment_v <var> <text> — <text> with each line's leading comment mark
# (#, //, --) and the spaces after it left out: a comment quoted across its
# lines is the words the comment says (#2517). Builtins only.
_judge_uncomment_v() {
    local -n _juc="$1"; local _juc_l
    _juc=""
    while IFS= read -r _juc_l || [[ -n "$_juc_l" ]]; do
        _juc_l="${_juc_l#"${_juc_l%%[![:space:]]*}"}"
        case "$_juc_l" in
            '#'*)  _juc_l="${_juc_l#"${_juc_l%%[!#]*}"}" ;;
            '//'*) _juc_l="${_juc_l#//}" ;;
            '--'*) _juc_l="${_juc_l#--}" ;;
        esac
        _juc+="$_juc_l"$'\n'
    done <<< "$2"
}

# _judge_bare_path_v <var> — the file name of a quote without the backticks or
# bold marks a model writes around it (#1805 run 42556446368): formatting is not
# the judge's to get right (#2472).
_judge_bare_path_v() {
    local -n _jbp="$1"
    while [[ "$_jbp" == [\`*]* ]]; do _jbp="${_jbp:1}"; done
    while [[ "$_jbp" == *[\`*] ]]; do _jbp="${_jbp%?}"; done
}

# judge_quote_check_v <why_var> <quote> <own_words> <repo> [base_dir] — rc 0
# when <quote> is really there: `"text"` in the item's own words, or
# `file:"text"` in that file in the repository or in the code from before the
# change. Otherwise rc 1 and <why_var> says what is wrong, to follow "<id>'s
# quote " in a re-ask.
judge_quote_check_v() {
    local -n _jqw="$1"
    local _judge__q="$2" _judge__own="$3" _judge__repo="${4:+${4%/}}" _judge__base="${5:+${5%/}}" _judge__path _judge__txt _judge__f _judge__seen=0
    _jqw=""
    _judge__q="${_judge__q#"${_judge__q%%[![:space:]]*}"}"; _judge__q="${_judge__q%"${_judge__q##*[![:space:]]}"}"
    if [[ "$_judge__q" =~ ^\"(.*)\"$ ]]; then
        _judge__txt="${BASH_REMATCH[1]}"
        _judge_holds "$_judge__own" "$_judge__txt" && return 0
        _jqw="is not in the item's own words: \"$_judge__txt\""
        return 1
    fi
    if [[ ! "$_judge__q" =~ ^([^\"]+):\"(.*)\"$ ]]; then
        _jqw="is not a quote: write \"<the exact words>\" or <file>:\"<its exact text>\""
        return 1
    fi
    _judge__path="${BASH_REMATCH[1]}"; _judge__txt="${BASH_REMATCH[2]}"
    _judge_bare_path_v _judge__path
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
        local _judge__body _judge__plain; _judge__body="$(<"$_judge__f")"
        _judge_holds "$_judge__body" "$_judge__txt" && return 0
        _judge_uncomment_v _judge__plain "$_judge__body"
        _judge_holds "$_judge__plain" "$_judge__txt" && return 0
    done
    if (( _judge__seen )); then
        _jqw="is not in $_judge__path: \"$_judge__txt\""
    else
        _jqw="names $_judge__path, which is not a file of the repository"
    fi
    return 1
}

# judge_quote_path_v <var> <quote> <repo> [base] — the repository path a
# `file:"text"` quote names, for the files a kept answer depends on; empty for
# a quote of the item's own words.
judge_quote_path_v() {
    local -n _jqp="$1"; local _judge__repo="${3:+${3%/}}" _judge__base="${4:+${4%/}}"
    _jqp=""
    [[ "$2" =~ ^[[:space:]]*([^\"[:space:]][^\"]*):\" ]] || return 0
    _jqp="${BASH_REMATCH[1]}"; _judge_bare_path_v _jqp
    _jqp="${_jqp#"$_judge__repo"/}"; [[ -n "$_judge__base" ]] && _jqp="${_jqp#"$_judge__base"/}"
    return 0
}
